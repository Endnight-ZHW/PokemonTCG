#include "ptcg_rules.hpp"
#include "ptcg_rules_internal.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <cmath>
#include <iterator>
#include <limits>
#include <stdexcept>
#include <string_view>
#include <unordered_set>


namespace ptcg::ai::rules_detail {

using Array = Value::Array;
using Object = Value::Object;

bool resume_vm_cards(
    const NativeRulesKernel &kernel,
    const Value &cards,
    const Value &continuation,
    const Value &selected_options,
    bool cancelled,
    const std::string &op,
    const Value &args,
    std::int32_t actor,
    const std::string &source_slot,
    std::int64_t stage,
    XorShift32 &rng,
    VmExecutionResult &result,
    bool &early_return
) {
    (void)kernel;
    if (!(
        op == "attach_energy"
        || op == "discard_then_draw_cards"
        || op == "attach_energy_from_discard"
        || op == "deal_bench_damage"
        || op == "choose_damage_target"
        || op == "choose_heal_damage"
        || op == "conditional"
        || op == "conditional_search"
        || op == "search_cards"
        || op == "search_item_and_tool"
    )) return false;
    Value &self = player(result.state, actor);
    Value &opponent = player(result.state, 1 - actor);
    auto next = [&result](Value request, Value next_continuation) {
        increment_integer(result.state, "choice_sequence");
        result.pending = std::move(request);
        result.continuation = std::move(next_continuation);
    };

        if (op == "attach_energy") {
            const std::string from_zone = string_arg(
                args,
                "from_zone",
                "hand"
            );
            Array &source_cards = required(self, from_zone).as_array();
            const std::string filter = string_arg(
                args,
                "filter",
                "any"
            );
            const bool distribution = bool_arg(
                continuation,
                "distribution"
            );
            if (selected_options.as_array().empty()) {
                const bool optional_choice = bool_arg(args, "optional")
                    || args.find("min_select") != nullptr
                    || (
                        integer_arg(args, "going_second_bonus")
                            > integer_arg(args, "amount", 1)
                        && actor
                            != integer_arg(
                                result.state,
                                "first_player_idx",
                                -1
                            )
                        && integer_arg(result.state, "turn_number") == 2
                    );
                if (!optional_choice) {
                    throw std::invalid_argument(
                        "energy_attachment_target_missing"
                    );
                }
                if (from_zone == "deck") {
                    shuffle_array(source_cards, rng);
                    result.event_types.emplace_back("deck_shuffled");
                }
                result.success = true;
                result.rng_state = rng.state();
                early_return = true; return true;
            }
            std::int64_t remaining = integer_arg(
                continuation,
                "effective_amount",
                integer_arg(args, "amount", 1)
            );
            if (distribution) {
                remaining = std::min<std::int64_t>(
                    remaining,
                    static_cast<std::int64_t>(
                        selected_options.as_array().size()
                    )
                );
            }
            std::size_t selection_index = 0;
            const std::string target_kind = string_arg(
                args,
                "to",
                source_slot
            );
            const bool same_target = bool_arg(args, "same_target")
                || target_kind == "any"
                || target_kind == "self_basic";
            const std::int64_t max_per_target = std::max<std::int64_t>(
                0,
                target_kind == "bench"
                    ? integer_arg(args, "max_per_target", 99)
                    : integer_arg(
                        continuation,
                        "effective_amount",
                        integer_arg(args, "amount", 1)
                    )
            );
            if (distribution) {
                validate_energy_distribution_selection(
                    selected_options.as_array(),
                    same_target,
                    max_per_target
                );
            }
            const std::string forced_target_slot = (
                distribution
                && same_target
                && !selected_options.as_array().empty()
            ) ? string_arg(
                selected_options.as_array().front(),
                "slot"
            ) : std::string{};
            while (remaining-- > 0) {
                const Value &selected = distribution
                    ? selected_options.as_array().at(selection_index++)
                    : selected_options.as_array().front();
                const std::string selected_target_slot =
                    forced_target_slot.empty()
                    ? string_arg(selected, "slot")
                    : forced_target_slot;
                Value *target = pokemon(
                    self,
                    selected_target_slot
                );
                if (target == nullptr) {
                    throw std::invalid_argument(
                        "energy_attachment_target_missing"
                    );
                }
                const auto energy = std::find_if(
                    source_cards.begin(),
                    source_cards.end(),
                    [&cards, &filter, &selected](const Value &entry) {
                        const std::string selected_id =
                            energy_option_card_id(selected);
                        return card_matches_energy(
                            cards,
                            entry.string_or(),
                            filter
                        ) && (
                            selected_id.empty()
                            || entry.string_or() == selected_id
                        );
                    }
                );
                if (energy == source_cards.end()) {
                    throw std::invalid_argument(
                        "energy_attachment_source_missing"
                    );
                }
                required(
                    *target,
                    "energy_card_ids"
                ).as_array().push_back(std::move(*energy));
                source_cards.erase(energy);
                result.event_types.emplace_back("energy_attached");
            }
            if (from_zone == "deck") {
                shuffle_array(source_cards, rng);
                result.event_types.emplace_back("deck_shuffled");
            }
        } else if (op == "discard_then_draw_cards") {
            const std::int64_t discard_amount = std::max<std::int64_t>(
                0,
                integer_arg(args, "discard_amount", 1)
            );
            if (
                selected_options.as_array().empty()
                || static_cast<std::int64_t>(
                    selected_options.as_array().size()
                ) > discard_amount
            ) {
                throw std::invalid_argument(
                    "discard_hand_selection_invalid"
                );
            }
            selected_zone_card_ids(
                self,
                selected_options,
                "hand",
                actor
            );
            Array discarded_ids = selected_card_id_values(
                selected_options);
            const std::size_t removed = discard_selected(
                self,
                "hand",
                selected_options
            );
            if (removed != selected_options.as_array().size()) {
                throw std::invalid_argument(
                    "discard_hand_selection_out_of_range"
                );
            }
            if (removed > 0) {
                append_card_zone_event(
                    result,
                    "cards_discarded",
                    actor,
                    std::move(discarded_ids),
                    "hand",
                    "discard",
                    "public"
                );
            }
            const auto drawn = draw_cards(
                self,
                integer_arg(
                    args,
                    "draw_amount",
                    integer_arg(args, "draw", 7)
                )
            );
            append_cards_drawn_event(
                result, actor, drawn, "discard_then_draw");
        } else if (op == "attach_energy_from_discard") {
            Array &discard = required(self, "discard").as_array();
            const std::string filter = string_arg(
                args,
                "energy_type",
                "basic"
            );
            const Array &targets = selected_options.as_array();
            const bool same_target = bool_arg(args, "same_target")
                || string_arg(args, "target", "self") == "self"
                || string_arg(args, "target", "self") == "self_or_bench"
                || (
                    !targets.empty()
                    && std::all_of(
                        targets.begin(),
                        targets.end(),
                        [&targets](const Value &entry) {
                            return string_arg(entry, "slot")
                                == string_arg(targets.front(), "slot");
                        }
                    )
                );
            validate_energy_distribution_selection(
                targets,
                same_target,
                same_target
                    ? std::max<std::int64_t>(
                        0,
                        integer_arg(args, "amount", 1)
                    )
                    : 99
            );
            const std::string forced_target_slot = (
                same_target && !targets.empty()
            ) ? string_arg(targets.front(), "slot") : std::string{};
            for (std::size_t index = 0; index < targets.size(); ++index) {
                const std::string slot = forced_target_slot.empty()
                    ? string_arg(targets[index], "slot")
                    : forced_target_slot;
                Value *target = pokemon(self, slot);
                if (target == nullptr) {
                    throw std::invalid_argument(
                        "energy_attachment_target_missing"
                    );
                }
                const std::string selected_id =
                    energy_option_card_id(targets[index]);
                const auto source = std::find_if(
                    discard.begin(),
                    discard.end(),
                    [&cards, &filter, &selected_id](const Value &entry) {
                        return card_matches_energy(
                            cards,
                            entry.string_or(),
                            filter
                        ) && (
                            selected_id.empty()
                            || entry.string_or() == selected_id
                        );
                    }
                );
                if (source == discard.end()) {
                    throw std::invalid_argument(
                        "energy_attachment_source_missing"
                    );
                }
                required(
                    *target,
                    "energy_card_ids"
                ).as_array().push_back(std::move(*source));
                discard.erase(source);
                result.event_types.emplace_back("energy_attached");
            }
        } else if (op == "deal_bench_damage") {
            const bool targets_self = string_arg(
                args,
                "player",
                "opponent"
            ) == "self";
            const std::int32_t target_owner = targets_self
                ? actor
                : 1 - actor;
            Value &target_player = targets_self ? self : opponent;
            const std::int64_t expected_count = std::min<std::int64_t>(
                std::max<std::int64_t>(
                    0,
                    integer_arg(args, "count", 1)
                ),
                static_cast<std::int64_t>(
                    pokemon_options(
                        target_player,
                        target_owner,
                        false,
                        true
                    ).size()
                )
            );
            if (
                expected_count <= 0
                || selected_options.as_array().size()
                    != static_cast<std::size_t>(expected_count)
            ) {
                throw std::invalid_argument(
                    "bench_damage_selection_invalid"
                );
            }
            std::unordered_set<std::string> selected_slots;
            const std::int64_t amount = std::max<std::int64_t>(
                0,
                integer_arg(args, "amount")
            );
            for (const Value &selected : selected_options.as_array()) {
                const std::string slot = string_arg(selected, "slot");
                Value *target = pokemon(target_player, slot);
                if (
                    slot.rfind("bench_", 0) != 0
                    || !selected_slots.insert(slot).second
                    || target == nullptr
                    || integer_arg(selected, "player", target_owner)
                        != target_owner
                    || (
                        !string_arg(selected, "card_id").empty()
                        && string_arg(selected, "card_id")
                            != string_arg(*target, "card_id")
                    )
                ) {
                    throw std::invalid_argument(
                        "bench_damage_selection_invalid"
                    );
                }
                if (
                    string_arg(continuation, "context_mode")
                        == "attack"
                ) {
                    Value *packets = result.context.find(
                        "damage_packets"
                    );
                    if (packets == nullptr || !packets->is_array()) {
                        result.context["damage_packets"] =
                            Value::make_array();
                        packets = result.context.find("damage_packets");
                    }
                    packets->as_array().emplace_back(Object{
                        {"target_player", Value(target_owner)},
                        {"target_slot", Value(slot)},
                        {"amount", Value(amount)},
                    });
                } else {
                    std::int64_t applied = amount;
                    if (bool_arg(*target, "damage_prevented")) {
                        applied = 0;
                    }
                    add_damage(*target, applied);
                    append_damage_feedback_event(
                        result,
                        "damage_dealt",
                        actor,
                        target_owner,
                        slot,
                        applied
                    );
                    const std::int64_t maximum_hp = pokemon_hp(
                        cards,
                        *target
                    );
                    if (
                        maximum_hp > 0
                        && integer_arg(
                            *target,
                            "damage_counters"
                        ) * 10 >= maximum_hp
                        && target->find("pending_ko_source_kind") == nullptr
                    ) {
                        (*target)["pending_ko_source_kind"] = Value(
                            "attack_effect"
                        );
                    }
                }
            }
        } else if (
            op == "choose_damage_target"
            || op == "choose_heal_damage"
        ) {
            const bool damage = op == "choose_damage_target";
            Value &target_player = damage ? opponent : self;
            const std::string target_slot = selected_slot(
                selected_options
            );
            Value *target = pokemon(
                target_player,
                target_slot
            );
            if (target == nullptr) {
                throw std::invalid_argument("selected_target_missing");
            }
            if (damage) {
                std::int64_t amount = std::max<std::int64_t>(
                    0,
                    integer_arg(args, "amount")
                );
                if (
                    string_arg(continuation, "context_mode") == "attack"
                ) {
                    Value *packets = result.context.find("damage_packets");
                    if (packets == nullptr || !packets->is_array()) {
                        result.context["damage_packets"] = Value::make_array();
                        packets = result.context.find("damage_packets");
                    }
                    packets->as_array().emplace_back(Object{
                        {"target_player", Value(1 - actor)},
                        {"target_slot", Value(target_slot)},
                        {"amount", Value(amount)},
                    });
                } else {
                    if (bool_arg(*target, "damage_prevented")) {
                        amount = 0;
                    }
                    add_damage(*target, amount);
                    append_damage_feedback_event(
                        result,
                        "damage_dealt",
                        actor,
                        1 - actor,
                        target_slot,
                        amount
                    );
                    const std::int64_t maximum_hp = pokemon_hp(
                        cards,
                        *target
                    );
                    if (
                        maximum_hp > 0
                        && integer_arg(
                            *target,
                            "damage_counters"
                        ) * 10 >= maximum_hp
                        && target->find("pending_ko_source_kind") == nullptr
                    ) {
                        (*target)["pending_ko_source_kind"] = Value(
                            "attack_effect"
                        );
                    }
                }
            } else {
                const std::int64_t healed = heal_damage(
                    *target, integer_arg(args, "amount", 30));
                if (healed > 0) {
                    self["healed_this_turn"] = Value(true);
                    append_healed_event(
                        result, actor, actor, target_slot, healed);
                }
            }
        } else if (op == "conditional") {
            if (stage == 0) {
                if (selected_options.as_array().size() != 2) {
                    throw std::invalid_argument(
                        "conditional_cost_selection_count_invalid"
                    );
                }
                selected_zone_card_ids(
                    self,
                    selected_options,
                    "hand",
                    actor
                );
                Array discarded_ids = selected_card_id_values(
                    selected_options);
                const std::size_t removed = discard_selected(
                    self,
                    "hand",
                    selected_options
                );
                if (removed > 0) {
                    append_card_zone_event(
                        result,
                        "cards_discarded",
                        actor,
                        std::move(discarded_ids),
                        "hand",
                        "discard",
                        "public"
                    );
                }
                Array options = zone_options(
                    cards,
                    self,
                    actor,
                    "deck",
                    "pokemon"
                );
                if (options.empty()) {
                    shuffle_array(
                        required(self, "deck").as_array(),
                        rng
                    );
                    result.event_types.emplace_back("deck_shuffled");
                    result.success = true;
                    result.rng_state = rng.state();
                    early_return = true; return true;
                }
                Value continued = continuation;
                continued["stage"] = Value(1);
                next(
                    pending_request(
                        "search_move",
                        actor,
                        0,
                        1,
                        false,
                        false,
                        std::move(options),
                        "search_move"
                    ),
                    std::move(continued)
                );
            } else {
                if (selected_options.as_array().size() > 1) {
                    throw std::invalid_argument(
                        "conditional_search_selection_count_invalid"
                    );
                }
                for (const std::string &selected_id : selected_zone_card_ids(
                    self,
                    selected_options,
                    "deck",
                    actor
                )) {
                    if (!card_is_pokemon(cards, selected_id)) {
                        throw std::invalid_argument(
                            "conditional_search_selection_invalid"
                        );
                    }
                }
                std::vector<Value> removed = remove_selected(
                    self,
                    "deck",
                    selected_options
                );
                Array selected_ids = card_id_values(removed);
                Array &hand = required(self, "hand").as_array();
                for (Value &entry : removed) {
                    hand.push_back(std::move(entry));
                }
                append_card_zone_event(
                    result,
                    "cards_selected",
                    actor,
                    std::move(selected_ids),
                    "deck",
                    "hand",
                    "public"
                );
                shuffle_array(required(self, "deck").as_array(), rng);
                result.event_types.emplace_back("deck_shuffled");
            }
        } else if (
            op == "conditional_search"
            || op == "search_cards"
            || op == "search_item_and_tool"
        ) {
            std::vector<Value> removed;
            if (op == "search_item_and_tool") {
                const std::vector<std::string> selected_ids =
                    selected_zone_card_ids(
                        self,
                        selected_options,
                        "deck",
                        actor
                    );
                if (selected_ids.size() > 2) {
                    throw std::invalid_argument(
                        "arven_selection_count_exceeded"
                    );
                }
                std::int64_t item_count = 0;
                std::int64_t tool_count = 0;
                for (const std::string &selected_id : selected_ids) {
                    const Value *definition = card_definition(
                        cards, selected_id);
                    const std::string kind = definition == nullptr
                        ? std::string{}
                        : lower_ascii(string_arg(
                            *definition,
                            "trainer_type"
                        ));
                    if (kind == "item") {
                        ++item_count;
                    } else if (kind == "tool") {
                        ++tool_count;
                    } else {
                        throw std::invalid_argument(
                            "arven_selection_category_invalid"
                        );
                    }
                }
                if (item_count > 1 || tool_count > 1) {
                    throw std::invalid_argument(
                        "arven_category_limit_exceeded"
                    );
                }
                removed = remove_selected(
                    self,
                    "deck",
                    selected_options
                );
            } else {
                const std::string source_zone = op == "search_cards"
                    ? string_arg(args, "from_zone", "deck")
                    : "deck";
                const std::string filter = string_arg(args, "filter", "any");
                const std::string filter_name = op == "search_cards"
                    ? string_arg(args, "filter_name")
                    : std::string{};
                const std::vector<std::string> selected_ids =
                    selected_zone_card_ids(
                        self,
                        selected_options,
                        source_zone,
                        actor
                    );
                std::int64_t maximum = integer_arg(args, "count", 1);
                if (op == "conditional_search") {
                    const bool going_second_first_turn = (
                        actor != integer_arg(
                            result.state, "first_player_idx")
                        && actor == integer_arg(
                            result.state, "active_player_idx")
                        && integer_arg(result.state, "turn_number") == 2
                    );
                    maximum = going_second_first_turn
                        ? integer_arg(args, "max_count", 3)
                        : integer_arg(args, "default_count", 1);
                }
                if (
                    selected_ids.size()
                    > static_cast<std::size_t>(
                        std::max<std::int64_t>(0, maximum))
                ) {
                    throw std::invalid_argument(
                        "search_selection_count_exceeded"
                    );
                }
                for (const std::string &selected_id : selected_ids) {
                    const Value *definition = card_definition(
                        cards, selected_id);
                    if (
                        !card_matches_filter(cards, selected_id, filter)
                        || (
                            !filter_name.empty()
                            && (
                                definition == nullptr
                                || string_arg(*definition, "name")
                                    != filter_name
                            )
                        )
                    ) {
                        throw std::invalid_argument(
                            "search_selection_filter_mismatch"
                        );
                    }
                }
                if (
                    op == "search_cards"
                    && string_arg(args, "destination", "hand") == "bench"
                    && selected_options.as_array().size()
                        > static_cast<std::size_t>(
                            std::max<std::int64_t>(0, 5 - bench_count(self))
                        )
                ) {
                    throw std::invalid_argument(
                        "bench_destination_capacity_exceeded"
                    );
                }
                removed = remove_selected(
                    self,
                    source_zone,
                    selected_options
                );
            }
            const std::string destination = op == "search_cards"
                ? string_arg(args, "destination", "hand")
                : "hand";
            if (destination == "bench") {
                Array &bench = required(self, "bench").as_array();
                for (Value &entry : removed) {
                    const auto empty = std::find_if(
                        bench.begin(),
                        bench.end(),
                        [](const Value &value) { return value.is_null(); }
                    );
                    if (empty == bench.end()) {
                        break;
                    }
                    *empty = new_pokemon(cards, entry.string_or());
                    result.event_types.emplace_back("card_moved");
                }
            } else {
                Array selected_ids = card_id_values(removed);
                Array &hand = required(self, "hand").as_array();
                for (Value &entry : removed) {
                    hand.push_back(std::move(entry));
                }
                const std::string source_zone = op == "search_cards"
                    ? string_arg(args, "from_zone", "deck")
                    : "deck";
                const bool public_identity = source_zone == "discard"
                    || op == "conditional_search"
                    || op == "search_item_and_tool"
                    || bool_arg(args, "reveal");
                append_card_zone_event(
                    result,
                    "cards_selected",
                    actor,
                    std::move(selected_ids),
                    source_zone,
                    "hand",
                    public_identity ? "public" : "owner"
                );
            }
            if (
                op != "search_cards"
                || string_arg(args, "from_zone", "deck") == "deck"
            ) {
                shuffle_array(required(self, "deck").as_array(), rng);
                result.event_types.emplace_back("deck_shuffled");
            }
        }

    return true;
}

} // namespace ptcg::ai::rules_detail
