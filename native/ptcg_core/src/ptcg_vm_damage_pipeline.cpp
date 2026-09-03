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

bool execute_vm_damage_pipeline(
    const Value &cards,
    const Value &command_spec,
    const std::string &op,
    const Value &args,
    std::int32_t actor,
    const std::string &source_slot,
    const std::string &context_mode,
    XorShift32 &rng,
    VmExecutionResult &result,
    bool &early_return
) {
    if (!(
        op == "choose_damage_target"
        || op == "choose_heal_damage"
        || op == "conditional"
        || op == "conditional_damage"
        || op == "conditional_damage_then_heal"
        || op == "conditional_search"
        || op == "deal_damage"
        || op == "deal_damage_per_discard_psychic"
        || op == "deal_damage_per_energy"
        || op == "deal_damage_per_evolved"
        || op == "deal_damage_per_hand_size"
        || op == "deal_damage_per_self_damage"
        || op == "deal_damage_per_self_energy"
        || op == "deal_damage_per_self_energy_type"
        || op == "deal_damage_plus_bench"
        || op == "deal_damage_with_self_penalty"
        || op == "deal_bench_damage"
        || op == "discard_cards"
        || op == "discard_energy"
        || op == "discard_energy_then_damage"
        || op == "discard_hand_then_damage"
        || op == "discard_then_draw_cards"
        || op == "discard_then_revive"
        || op == "draw_and_attach_energy"
        || op == "deal_damage_then_heal"
    )) return false;
    Value &self = player(result.state, actor);
    Value &opponent = player(result.state, 1 - actor);
    Value *source = pokemon(self, source_slot);
    Value *opponent_active = pokemon(opponent, "active");
    auto suspend = [&result](Value request, Value continuation) {
        increment_integer(result.state, "choice_sequence");
        result.pending = std::move(request);
        result.continuation = std::move(continuation);
    };

        if (
            op == "choose_damage_target"
            || op == "choose_heal_damage"
        ) {
            const bool damage = op == "choose_damage_target";
            Value &target_player = damage ? opponent : self;
            Array options = pokemon_options(
                target_player,
                damage ? 1 - actor : actor,
                true,
                true
            );
            if (!damage) {
                options.erase(
                    std::remove_if(
                        options.begin(),
                        options.end(),
                        [&target_player](const Value &entry) {
                            const Value *target = pokemon(
                                target_player,
                                string_arg(entry, "slot")
                            );
                            return target == nullptr
                                || get_integer(
                                    *target,
                                    "damage_counters"
                                ) <= 0;
                        }
                    ),
                    options.end()
                );
                if (options.size() == 1) {
                    const std::string target_slot = string_arg(
                        options.front(), "slot");
                    Value *target = pokemon(
                        target_player,
                        target_slot
                    );
                    const std::int64_t healed = target == nullptr
                        ? 0 : heal_damage(
                            *target, integer_arg(args, "amount", 30));
                    if (healed > 0) {
                        self["healed_this_turn"] = Value(true);
                        append_healed_event(
                            result, actor, actor, target_slot, healed);
                    }
                    result.success = true;
                    result.rng_state = rng.state();
                    early_return = true; return true;
                }
            }
            suspend(
                pending_request(
                    damage ? "damage_target" : "select_heal_target",
                    actor,
                    1,
                    1,
                    false,
                    false,
                    std::move(options),
                    damage ? "damage_target" : "heal_target"
                ),
                make_continuation(
                    op,
                    command_spec,
                    actor,
                    source_slot
                )
            );
        } else if (op == "conditional") {
            Array options = zone_options(
                cards,
                self,
                actor,
                "hand",
                "any"
            );
            if (options.size() < 2) {
                throw std::invalid_argument(
                    "conditional_cost_cards_insufficient"
                );
            }
            Value continued = make_continuation(
                op,
                command_spec,
                actor,
                source_slot
            );
            if (options.size() == 2) {
                // The authoritative VM does not publish a decision when the
                // cost has only one legal payment: it discards both cards
                // and advances directly to the search request. Keep that
                // forced transition out of the information-set tree.
                const std::size_t removed = discard_selected(
                    self,
                    "hand",
                    Value(std::move(options))
                );
                if (removed > 0) {
                    result.event_types.emplace_back("cards_discarded");
                }
                continued["stage"] = Value(1);
                Array search_options = zone_options(
                    cards, self, actor, "deck", "pokemon");
                if (required(self, "deck").as_array().empty()) {
                    shuffle_array(required(self, "deck").as_array(), rng);
                    result.event_types.emplace_back("deck_shuffled");
                } else {
                    const std::int64_t search_maximum =
                        search_options.empty() ? 0 : 1;
                    Value request = pending_request(
                        "search_move",
                        actor,
                        0,
                        search_maximum,
                        false,
                        false,
                        std::move(search_options),
                        "search_move"
                    );
                    decorate_deck_search_request(
                        request, cards, self, actor);
                    suspend(
                        std::move(request),
                        std::move(continued)
                    );
                }
            } else {
                suspend(
                    pending_request(
                        "discard_cards",
                        actor,
                        2,
                        2,
                        false,
                        false,
                        std::move(options),
                        "discard_cards"
                    ),
                    std::move(continued)
                );
            }
        } else if (op == "conditional_damage") {
            if (
                condition_applies(
                    cards,
                    result.state,
                    actor,
                    string_arg(args, "condition")
                )
            ) {
                set_attack_damage(
                    result.context,
                    integer_arg(args, "bonus"),
                    true
                );
            }
        } else if (op == "conditional_damage_then_heal") {
            const bool healed = source != nullptr
                && bool_arg(*source, "healed_this_turn");
            const std::int64_t total = integer_arg(args, "base", 60)
                + (healed ? integer_arg(args, "bonus", 90) : 0);
            set_attack_damage(result.context, total, true);
        } else if (op == "conditional_search") {
            const bool going_second_first_turn = (
                actor != integer_arg(result.state, "first_player_idx")
                && actor == integer_arg(result.state, "active_player_idx")
                && integer_arg(result.state, "turn_number") == 2
            );
            const std::int64_t requested = going_second_first_turn
                ? integer_arg(args, "max_count", 3)
                : integer_arg(args, "default_count", 1);
            Array options = zone_options(
                cards,
                self,
                actor,
                "deck",
                string_arg(args, "filter", "any")
            );
            if (required(self, "deck").as_array().empty()) {
                shuffle_array(required(self, "deck").as_array(), rng);
                result.event_types.emplace_back("deck_shuffled");
                result.success = true;
                result.rng_state = rng.state();
                early_return = true; return true;
            }
            const std::int64_t count = std::min<std::int64_t>(
                requested,
                static_cast<std::int64_t>(options.size())
            );
            const std::int64_t minimum = 0;
            if (count <= 0) {
                options.clear();
            }
            Value request = pending_request(
                "search_move",
                actor,
                minimum,
                count,
                false,
                count > 0,
                std::move(options),
                "search_move"
            );
            decorate_deck_search_request(
                request, cards, self, actor);
            suspend(
                std::move(request),
                make_continuation(
                    op,
                    command_spec,
                    actor,
                    source_slot
                )
            );
        } else if (op == "deal_damage") {
            const Value *formula = args.find("formula_ast");
            const std::int64_t amount = formula == nullptr
                ? integer_arg(args, "amount")
                : std::max<std::int64_t>(
                    0,
                    evaluate_formula_ast(
                        *formula,
                        cards,
                        result.state,
                        actor
                    )
                );
            const std::string target = string_arg(
                args,
                "target",
                "opponent_active"
            );
            Value *target_pokemon = target == "self"
                ? source
                : opponent_active;
            if (context_mode == "attack") {
                set_attack_damage(result.context, amount, true);
                for (const std::string &key : {
                    "ignore_weakness",
                    "ignore_resistance",
                    "ignore_defender_damage_effects",
                }) {
                    if (bool_arg(args, key)) {
                        result.context[key] = Value(true);
                    }
                }
            } else if (target_pokemon != nullptr) {
                add_damage(*target_pokemon, amount);
                append_damage_feedback_event(
                    result,
                    "damage_dealt",
                    actor,
                    target == "self" ? actor : 1 - actor,
                    target == "self" ? source_slot : "active",
                    amount
                );
            }
        } else if (
            op == "deal_damage_per_discard_psychic"
            || op == "deal_damage_per_energy"
            || op == "deal_damage_per_evolved"
            || op == "deal_damage_per_hand_size"
            || op == "deal_damage_per_self_damage"
            || op == "deal_damage_per_self_energy"
            || op == "deal_damage_per_self_energy_type"
            || op == "deal_damage_plus_bench"
            || op == "deal_damage_with_self_penalty"
        ) {
            std::int64_t total = 0;
            if (op == "deal_damage_per_discard_psychic") {
                std::int64_t count = 0;
                for (const Value &entry : required(self, "discard").as_array()) {
                    const std::string id = entry.string_or();
                    const Value *definition = card_definition(cards, id);
                    if (
                        card_is_pokemon(cards, id)
                        && definition != nullptr
                        && string_array_contains_ci(
                            definition->find("energy_types"),
                            "Psychic"
                        )
                    ) {
                        ++count;
                    }
                }
                total = integer_arg(args, "base", 80)
                    + count * integer_arg(args, "per_card", 10);
            } else if (op == "deal_damage_per_energy") {
                const std::string count_from = string_arg(
                    args,
                    "count_from",
                    "self"
                );
                std::int64_t count = 0;
                if (count_from == "opponent_active") {
                    count = energy_units(cards, opponent_active);
                } else if (count_from == "all_opponent") {
                    for (const Value *entry : all_pokemon(opponent)) {
                        count += energy_units(cards, entry);
                    }
                } else {
                    count = energy_units(cards, source);
                }
                total = integer_arg(args, "base")
                    + count * integer_arg(args, "per_energy");
            } else if (op == "deal_damage_per_evolved") {
                std::int64_t count = 0;
                for (const Value *entry : all_pokemon(self)) {
                    if (!card_has_subtype(
                        cards,
                        card_id(*entry),
                        "Basic"
                    )) {
                        ++count;
                    }
                }
                total = count * integer_arg(args, "per_evolved", 50);
            } else if (op == "deal_damage_per_hand_size") {
                total = static_cast<std::int64_t>(
                    required(self, "hand").as_array().size()
                ) * integer_arg(args, "per");
            } else if (op == "deal_damage_per_self_damage") {
                total = integer_arg(args, "base")
                    + (
                        source == nullptr
                        ? 0
                        : get_integer(*source, "damage_counters")
                    ) * integer_arg(args, "per_counter");
            } else if (
                op == "deal_damage_per_self_energy"
                || op == "deal_damage_per_self_energy_type"
            ) {
                const std::string filter = string_arg(
                    args,
                    op == "deal_damage_per_self_energy"
                        ? "energy_filter"
                        : "energy_type"
                );
                total = integer_arg(args, "base")
                    + energy_units(cards, source, filter)
                        * integer_arg(args, "per_energy");
            } else if (op == "deal_damage_plus_bench") {
                total = integer_arg(args, "base")
                    + bench_count(self) * integer_arg(args, "per_bench");
            } else {
                total = std::max<std::int64_t>(
                    0,
                    integer_arg(args, "base")
                        - (
                            source == nullptr
                            ? 0
                            : get_integer(*source, "damage_counters")
                        ) * integer_arg(args, "per_counter")
                );
            }
            set_attack_damage(result.context, total, true);
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
            Array options = pokemon_options(
                target_player,
                target_owner,
                false,
                true
            );
            const std::int64_t actual_count = std::min<std::int64_t>(
                std::max<std::int64_t>(
                    0,
                    integer_arg(args, "count", 1)
                ),
                static_cast<std::int64_t>(options.size())
            );
            if (
                bool_arg(args, "choose_targets")
                && options.size() > 1
                && actual_count > 0
            ) {
                suspend(
                    pending_request(
                        "select_bench_targets",
                        actor,
                        actual_count,
                        actual_count,
                        false,
                        false,
                        std::move(options),
                        "deal_bench_damage"
                    ),
                    make_continuation(
                        op,
                        command_spec,
                        actor,
                        source_slot
                    )
                );
            } else {
                const std::int64_t amount = std::max<std::int64_t>(
                    0,
                    integer_arg(args, "amount")
                );
                for (
                    std::int64_t index = 0;
                    index < actual_count;
                    ++index
                ) {
                    const std::string slot = string_arg(
                        options.at(static_cast<std::size_t>(index)),
                        "slot"
                    );
                    Value *target = pokemon(target_player, slot);
                    if (target == nullptr) {
                        continue;
                    }
                    if (context_mode == "attack") {
                        Value *packets = result.context.find(
                            "damage_packets"
                        );
                        if (packets == nullptr || !packets->is_array()) {
                            result.context["damage_packets"] =
                                Value::make_array();
                            packets = result.context.find(
                                "damage_packets"
                            );
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
            }
        } else if (op == "discard_cards") {
            const std::int64_t amount = integer_arg(args, "amount", 1);
            const std::string zone = string_arg(
                args,
                "from",
                string_arg(args, "from_zone", "hand")
            );
            suspend(
                pending_request(
                    "discard_cards",
                    actor,
                    amount,
                    amount,
                    false,
                    false,
                    zone_options(
                        cards,
                        self,
                        actor,
                        zone,
                        "any"
                    ),
                    "discard_cards"
                ),
                make_continuation(
                    op,
                    command_spec,
                    actor,
                    source_slot
                )
            );
        } else if (op == "discard_energy") {
            Value &target_player = string_arg(
                args,
                "from",
                "self"
            ) == "self" ? self : opponent;
            Value *target = pokemon(target_player, "active");
            Array options;
            if (target != nullptr) {
                const Array &energy = required(
                    *target,
                    "energy_card_ids"
                ).as_array();
                for (std::size_t index = 0; index < energy.size(); ++index) {
                    if (attached_energy_card_matches(
                        cards,
                        *target,
                        index,
                        string_arg(args, "filter", "any")
                    )) {
                        options.push_back(attachment_option(
                            energy[index].string_or(),
                            string_arg(args, "from", "self") == "self"
                                ? actor
                                : 1 - actor,
                            "active",
                            static_cast<std::int64_t>(index)
                        ));
                    }
                }
            }
            const std::int64_t amount = std::min<std::int64_t>(
                integer_arg(args, "amount", 1),
                static_cast<std::int64_t>(options.size())
            );
            if (amount == 0) {
                result.success = true;
                result.rng_state = rng.state();
                early_return = true; return true;
            }
            if (
                static_cast<std::int64_t>(options.size()) == amount
            ) {
                Array &energy = required(
                    *target,
                    "energy_card_ids"
                ).as_array();
                std::vector<std::size_t> indices;
                std::vector<Value> removed;
                for (const Value &option : options) {
                    const std::size_t index = static_cast<std::size_t>(
                        integer_arg(option, "index", -1)
                    );
                    indices.push_back(index);
                    removed.push_back(energy.at(index));
                }
                std::sort(indices.begin(), indices.end());
                for (
                    auto iterator = indices.rbegin();
                    iterator != indices.rend();
                    ++iterator
                ) {
                    energy.erase(
                        energy.begin()
                            + static_cast<std::ptrdiff_t>(*iterator)
                    );
                }
                Array &discard = required(
                    target_player,
                    "discard"
                ).as_array();
                for (Value &entry : removed) {
                    discard.push_back(std::move(entry));
                }
                result.event_types.emplace_back("cards_discarded");
                result.success = true;
                result.rng_state = rng.state();
                early_return = true; return true;
            }
            suspend(
                pending_request(
                    "select_attachment",
                    actor,
                    amount,
                    amount,
                    false,
                    false,
                    std::move(options),
                    "discard_energy_attachments"
                ),
                make_continuation(
                    op,
                    command_spec,
                    actor,
                    source_slot
                )
            );
        } else if (op == "discard_energy_then_damage") {
            if (source != nullptr) {
                Array &attached = required(
                    *source,
                    "energy_card_ids"
                ).as_array();
                Array &discard = required(self, "discard").as_array();
                std::int64_t discarded = 0;
                for (std::size_t index = 0; index < attached.size();) {
                    if (!attached_energy_card_matches(
                        cards,
                        *source,
                        index,
                        "fighting"
                    )) {
                        ++index;
                        continue;
                    }
                    discard.push_back(std::move(attached[index]));
                    attached.erase(
                        attached.begin()
                            + static_cast<std::ptrdiff_t>(index)
                    );
                    ++discarded;
                }
                set_attack_damage(
                    result.context,
                    integer_arg(args, "base", 10)
                        + discarded * integer_arg(args, "per_energy", 60),
                    true
                );
                if (discarded > 0) {
                    result.event_types.emplace_back("cards_discarded");
                }
            }
        } else if (op == "discard_hand_then_damage") {
            Array &hand = required(self, "hand").as_array();
            Array &discard = required(self, "discard").as_array();
            const std::int64_t count = static_cast<std::int64_t>(
                hand.size()
            );
            for (Value &entry : hand) {
                discard.push_back(std::move(entry));
            }
            hand.clear();
            set_attack_damage(
                result.context,
                integer_arg(args, "base_damage", 60)
                    + (
                        count >= integer_arg(args, "threshold", 5)
                        ? integer_arg(args, "bonus", 150)
                        : 0
                    ),
                true
            );
            if (count > 0) {
                result.event_types.emplace_back("cards_discarded");
            }
        } else if (op == "discard_then_draw_cards") {
            Array &hand = required(self, "hand").as_array();
            Array &discard = required(self, "discard").as_array();
            const bool discard_hand = bool_arg(
                args,
                "discard_hand"
            );
            const std::int64_t discard_amount = std::max<std::int64_t>(
                0,
                integer_arg(args, "discard_amount", 1)
            );
            const std::int64_t draw_amount = integer_arg(
                args,
                "draw_amount",
                integer_arg(args, "draw", 7)
            );
            if (
                !discard_hand
                && !hand.empty()
                && static_cast<std::int64_t>(hand.size()) > discard_amount
            ) {
                suspend(
                    pending_request(
                        "search_move",
                        actor,
                        1,
                        discard_amount,
                        false,
                        false,
                        zone_options(
                            cards,
                            self,
                            actor,
                            "hand",
                            "any"
                        ),
                        "discard_hand_then_draw"
                    ),
                    make_continuation(
                        op,
                        command_spec,
                        actor,
                        source_slot
                    )
                );
                result.success = true;
                result.rng_state = rng.state();
                early_return = true; return true;
            }
            const std::size_t discarded_count = discard_hand
                ? hand.size()
                : std::min<std::size_t>(
                    hand.size(),
                    static_cast<std::size_t>(discard_amount)
                );
            Array discarded_ids;
            if (discard_hand || discarded_count == hand.size()) {
                discarded_ids.reserve(hand.size());
                for (Value &entry : hand) {
                    discarded_ids.emplace_back(entry.string_or());
                    discard.push_back(std::move(entry));
                }
                hand.clear();
            }
            const auto drawn = discard_hand || discarded_count > 0
                ? draw_cards(self, draw_amount)
                : std::vector<std::string>{};
            if (discarded_count > 0) {
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
            append_cards_drawn_event(
                result, actor, drawn, "discard_then_draw");
        } else if (op == "discard_then_revive") {
            Array &discard = required(self, "discard").as_array();
            Array &bench = required(self, "bench").as_array();
            const std::string wanted = string_arg(args, "card_id");
            const auto found = std::find_if(
                discard.begin(),
                discard.end(),
                [&wanted](const Value &entry) {
                    return entry.string_or() == wanted;
                }
            );
            const auto empty = std::find_if(
                bench.begin(),
                bench.end(),
                [](const Value &entry) { return entry.is_null(); }
            );
            if (found != discard.end() && empty != bench.end()) {
                *empty = new_pokemon(cards, wanted);
                discard.erase(found);
                result.event_types.emplace_back("card_moved");
                const auto drawn = draw_cards(self, 3);
                append_cards_drawn_event(
                    result, actor, drawn, "discard_then_revive");
            }
        } else if (op == "draw_and_attach_energy") {
            const auto drawn = draw_cards(
                self,
                2
            );
            append_cards_drawn_event(
                result, actor, drawn, "draw_and_attach_energy");
            if (drawn.empty()) {
                result.success = true;
                result.rng_state = rng.state();
                early_return = true; return true;
            }
            const std::string filter = string_arg(
                args,
                "energy_type",
                "Grass"
            );
            const Array &hand = required(self, "hand").as_array();
            const std::int64_t matching = static_cast<std::int64_t>(
                std::count_if(
                    hand.begin(),
                    hand.end(),
                    [&cards, &filter](const Value &entry) {
                        return card_matches_energy(
                            cards,
                            entry.string_or(),
                            filter
                        );
                    }
                )
            );
            const std::int64_t maximum = std::min<std::int64_t>(
                integer_arg(args, "energy_count", 2),
                matching
            );
            Array targets = pokemon_options(
                self,
                actor,
                false,
                true
            );
            if (maximum <= 0 || targets.empty()) {
                result.success = true;
                result.rng_state = rng.state();
                early_return = true; return true;
            }
            const std::int64_t minimum = std::min<std::int64_t>(
                integer_arg(args, "min_select"),
                maximum
            );
            Array options;
            std::vector<std::string> matching_energy_ids;
            for (const Value &entry : hand) {
                if (card_matches_energy(
                    cards,
                    entry.string_or(),
                    filter
                )) {
                    matching_energy_ids.push_back(entry.string_or());
                }
            }
            matching_energy_ids.resize(
                static_cast<std::size_t>(maximum)
            );
            for (const Value &target : targets) {
                for (
                    std::int64_t index = 0;
                    index < maximum;
                    ++index
                ) {
                    Value option = target;
                    decorate_energy_distribution_option(
                        option,
                        actor,
                        index,
                        matching_energy_ids[
                            static_cast<std::size_t>(index)
                        ]
                    );
                    options.push_back(std::move(option));
                }
            }
            if (
                targets.size() == 1
                && minimum == maximum
            ) {
                Value *target = pokemon(
                    self,
                    string_arg(targets.front(), "slot")
                );
                Array &mutable_hand = required(self, "hand").as_array();
                for (
                    std::int64_t count = 0;
                    count < maximum;
                    ++count
                ) {
                    const auto energy = std::find_if(
                        mutable_hand.begin(),
                        mutable_hand.end(),
                        [&cards, &filter](const Value &entry) {
                            return card_matches_energy(
                                cards,
                                entry.string_or(),
                                filter
                            );
                        }
                    );
                    if (energy == mutable_hand.end()) {
                        break;
                    }
                    required(
                        *target,
                        "energy_card_ids"
                    ).as_array().push_back(std::move(*energy));
                    mutable_hand.erase(energy);
                    result.event_types.emplace_back("energy_attached");
                }
                result.success = true;
                result.rng_state = rng.state();
                early_return = true; return true;
            }
            Value request = pending_request(
                    "distribute_energy",
                    actor,
                    minimum,
                    maximum,
                    false,
                    false,
                    std::move(options),
                    "draw_attach_distribution"
                );
            Array presented_energy_ids;
            for (const std::string &card_id : matching_energy_ids) {
                presented_energy_ids.emplace_back(card_id);
            }
            request["metadata"] = Value(Object{
                {"card_ids", Value(std::move(presented_energy_ids))},
                {"domain", Value("distribute_energy")},
                {"energy_type", Value(filter)},
                {"max_per_target", Value(maximum)},
                {"purpose", Value("draw_attach_distribution")},
                {"same_target", Value(true)},
                {"source_player", Value(actor)},
                {"source_zone", Value("hand")},
            });
            suspend(
                std::move(request),
                make_continuation(
                    op,
                    command_spec,
                    actor,
                    source_slot
                )
            );
        } else if (op == "deal_damage_then_heal") {
            set_attack_damage(
                result.context,
                integer_arg(args, "damage", 10),
                true
            );
            const std::int64_t healed = source == nullptr
                ? 0 : heal_damage(
                    *source, integer_arg(args, "heal", 10));
            if (healed > 0) {
                self["healed_this_turn"] = Value(true);
                append_healed_event(
                    result, actor, actor, source_slot, healed);
            }
        }

    return true;
}

} // namespace ptcg::ai::rules_detail
