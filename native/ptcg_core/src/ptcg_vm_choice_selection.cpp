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

bool resume_vm_choices(
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
        op == "hand_to_bottom_draw_until"
        || op == "hand_to_bottom_then_draw"
        || op == "look_top_attach_energy"
        || op == "look_top_deck"
        || op == "place_counters_then_self_discard"
        || op == "recover_clara"
    )) return false;
    Value &self = player(result.state, actor);
    Value &opponent = player(result.state, 1 - actor);
    auto next = [&result](Value request, Value next_continuation) {
        increment_integer(result.state, "choice_sequence");
        result.pending = std::move(request);
        result.continuation = std::move(next_continuation);
    };

        if (
            op == "hand_to_bottom_draw_until"
            || op == "hand_to_bottom_then_draw"
        ) {
            if (
                op == "hand_to_bottom_draw_until"
                && selected_options.as_array().size() != 1
            ) {
                throw std::invalid_argument(
                    "hand_bottom_selection_count_invalid"
                );
            }
            selected_zone_card_ids(
                self,
                selected_options,
                "hand",
                actor
            );
            std::vector<Value> removed = remove_selected(
                self,
                "hand",
                selected_options
            );
            Array returned_ids = card_id_values(removed);
            Array &deck = required(self, "deck").as_array();
            deck.insert(
                deck.begin(),
                std::make_move_iterator(removed.begin()),
                std::make_move_iterator(removed.end())
            );
            append_card_zone_event(
                result,
                "cards_selected",
                actor,
                std::move(returned_ids),
                "hand",
                "deck",
                "owner"
            );
            const std::int64_t draw_count = (
                op == "hand_to_bottom_then_draw"
            ) ? static_cast<std::int64_t>(removed.size()) : std::max<std::int64_t>(
                0,
                integer_arg(args, "target_hand_size", 5)
                    - static_cast<std::int64_t>(
                        required(self, "hand").as_array().size()
                    )
            );
            const auto drawn = draw_cards(self, draw_count);
            append_cards_drawn_event(
                result, actor, drawn, "hand_to_bottom");
        } else if (
            op == "look_top_attach_energy"
            || op == "look_top_deck"
        ) {
            const bool bench_energy = (
                op == "look_top_deck"
                && string_arg(args, "destination", "hand")
                    == "bench_energy"
            );
            Array bench_targets;
            if (bench_energy) {
                const std::string target_type = string_arg(
                    args,
                    "target_pokemon_type",
                    "Lightning"
                );
                for (Value &option : pokemon_options(
                    self,
                    actor,
                    false,
                    true
                )) {
                    Value *target = pokemon(
                        self,
                        string_arg(option, "slot")
                    );
                    const Value *definition = target == nullptr
                        ? nullptr
                        : card_definition(cards, card_id(*target));
                    if (
                        definition != nullptr
                        && (
                            target_type.empty()
                            || string_array_contains_ci(
                                definition->find("energy_types"),
                                target_type
                            )
                        )
                    ) {
                        bench_targets.push_back(std::move(option));
                    }
                }
            }
            Array look_top_targets;
            if (op == "look_top_attach_energy") {
                look_top_targets = pokemon_options(
                    self,
                    actor,
                    true,
                    true
                );
            }
            if (
                op == "look_top_attach_energy"
                && stage == 0
                && !selected_options.as_array().empty()
                && look_top_targets.size() > 1
            ) {
                Value continued = continuation;
                continued["stage"] = Value(1);
                continued["selected_cards"] = selected_options;
                Array revealed_card_ids;
                for (const Value &selected : selected_options.as_array()) {
                    revealed_card_ids.emplace_back(
                        string_arg(selected, "card_id")
                    );
                }
                Value request = pending_request(
                    "select_energy_target",
                    actor,
                    1,
                    1,
                    false,
                    false,
                    std::move(look_top_targets),
                    "look_top_attach_target"
                );
                request["metadata"] = Value(Object{
                    {"domain", Value("select_energy_target")},
                    {"purpose", Value("look_top_attach_target")},
                    {"revealed_card_ids", Value(
                        std::move(revealed_card_ids)
                    )},
                    {"source_player", Value(actor)},
                    {"source_zone", Value("deck")},
                });
                next(
                    std::move(request),
                    std::move(continued)
                );
                result.event_types.emplace_back("cards_selected");
            } else {
                const Value &card_selection = (
                    (op == "look_top_attach_energy" && stage == 1)
                    || (bench_energy && stage == 1)
                ) ? required(continuation, "selected_cards")
                  : selected_options;
                if (
                    bench_energy
                    && stage == 0
                    && !card_selection.as_array().empty()
                    && !bench_targets.empty()
                    && !(
                        bench_targets.size() == 1
                        && card_selection.as_array().size() <= 1
                    )
                ) {
                    Array options;
                    for (const Value &target : bench_targets) {
                        for (
                            std::size_t energy_index = 0;
                            energy_index < card_selection.as_array().size();
                            ++energy_index
                        ) {
                            Value option = target;
                            const Value &selected_card =
                                card_selection.as_array()[energy_index];
                            decorate_energy_distribution_option(
                                option,
                                actor,
                                static_cast<std::int64_t>(energy_index),
                                string_arg(selected_card, "card_id")
                            );
                            options.push_back(std::move(option));
                        }
                    }
                    Value continued = continuation;
                    continued["stage"] = Value(1);
                    continued["selected_cards"] = card_selection;
                    const std::int64_t count =
                        static_cast<std::int64_t>(
                            card_selection.as_array().size()
                        );
                    Array revealed_card_ids;
                    for (const Value &selected : card_selection.as_array()) {
                        revealed_card_ids.emplace_back(
                            string_arg(selected, "card_id")
                        );
                    }
                    Value card_ids_value(revealed_card_ids);
                    Value request = pending_request(
                        "distribute_energy",
                        actor,
                        count,
                        count,
                        false,
                        false,
                        std::move(options),
                        "look_top_bench_energy_distribution"
                    );
                    request["metadata"] = Value(Object{
                        {"card_ids", std::move(card_ids_value)},
                        {"domain", Value("distribute_energy")},
                        {"purpose", Value(
                            "look_top_bench_energy_distribution"
                        )},
                        {"revealed_card_ids", Value(
                            std::move(revealed_card_ids)
                        )},
                        {"source_player", Value(actor)},
                        {"source_zone", Value("deck")},
                    });
                    next(
                        std::move(request),
                        std::move(continued)
                    );
                    result.event_types.emplace_back("cards_selected");
                    result.success = true;
                    result.rng_state = rng.state();
                    early_return = true; return true;
                }
                Array &deck = required(self, "deck").as_array();
                const std::size_t top_count = static_cast<std::size_t>(
                    std::min<std::int64_t>(
                        integer_arg(args, "count"),
                        static_cast<std::int64_t>(deck.size())
                    )
                );
                const std::size_t first_top = deck.size() - top_count;
                const std::vector<std::string> selected_card_ids =
                    selected_zone_card_ids(
                        self,
                        card_selection,
                        "deck",
                        actor
                    );
                if (
                    selected_card_ids.size()
                    > static_cast<std::size_t>(std::max<std::int64_t>(
                        0,
                        integer_arg(args, "take", 1)
                    ))
                ) {
                    throw std::invalid_argument(
                        "look_top_selection_count_exceeded"
                    );
                }
                const std::string card_filter = string_arg(
                    args, "filter", "any");
                for (const std::string &selected_id : selected_card_ids) {
                    if (!card_matches_filter(
                        cards, selected_id, card_filter
                    )) {
                        throw std::invalid_argument(
                            "look_top_selection_filter_mismatch"
                        );
                    }
                }
                const std::vector<std::size_t> selected = selected_indices(
                    card_selection,
                    "deck"
                );
                for (const std::size_t index : selected) {
                    if (index < first_top || index >= deck.size()) {
                        throw std::invalid_argument("stale_choice");
                    }
                }
                Array chosen_cards;
                Array remaining_top;
                for (std::size_t position = 0; position < top_count; ++position) {
                    const std::size_t index = deck.size() - 1 - position;
                    if (
                        std::binary_search(
                            selected.begin(),
                            selected.end(),
                            index
                        )
                    ) {
                        chosen_cards.push_back(deck[index]);
                    } else {
                        remaining_top.push_back(deck[index]);
                    }
                }
                deck.erase(
                    deck.begin() + static_cast<std::ptrdiff_t>(first_top),
                    deck.end()
                );
                if (op == "look_top_attach_energy") {
                    const std::string target_slot = stage == 1
                        ? selected_slot(selected_options)
                        : (
                            look_top_targets.empty()
                            ? std::string{}
                            : string_arg(
                                look_top_targets.front(),
                                "slot"
                            )
                        );
                    Value *target = pokemon(self, target_slot);
                    if (target == nullptr) {
                        throw std::invalid_argument(
                            "look_top_energy_target_missing"
                        );
                    }
                    Array &energy = required(
                        *target,
                        "energy_card_ids"
                    ).as_array();
                    for (Value &entry : chosen_cards) {
                        energy.push_back(std::move(entry));
                        result.event_types.emplace_back(
                            "energy_attached"
                        );
                    }
                } else if (bench_energy) {
                    std::vector<bool> attached(
                        chosen_cards.size(),
                        false
                    );
                    if (stage == 0 && bench_targets.size() == 1) {
                        Value *target = pokemon(
                            self,
                            string_arg(bench_targets.front(), "slot")
                        );
                        if (target == nullptr) {
                            throw std::invalid_argument(
                                "look_top_energy_target_missing"
                            );
                        }
                        Array &energy = required(
                            *target,
                            "energy_card_ids"
                        ).as_array();
                        for (
                            std::size_t index = 0;
                            index < chosen_cards.size();
                            ++index
                        ) {
                            energy.push_back(
                                std::move(chosen_cards[index])
                            );
                            attached[index] = true;
                            result.event_types.emplace_back(
                                "energy_attached"
                            );
                        }
                    } else if (stage == 1) {
                        if (
                            selected_options.as_array().size()
                            != chosen_cards.size()
                        ) {
                            throw std::invalid_argument(
                                "look_top_energy_target_count_invalid"
                            );
                        }
                        validate_energy_distribution_selection(
                            selected_options.as_array(),
                            false,
                            static_cast<std::int64_t>(chosen_cards.size())
                        );
                        for (
                            const Value &target_option
                                : selected_options.as_array()
                        ) {
                            const std::size_t energy_index =
                                static_cast<std::size_t>(
                                    energy_option_index(target_option)
                                );
                            if (
                                energy_index >= chosen_cards.size()
                                || attached[energy_index]
                            ) {
                                throw std::invalid_argument(
                                    "look_top_energy_selection_invalid"
                                );
                            }
                            const std::string target_slot = string_arg(
                                target_option, "slot");
                            const bool valid_target = std::any_of(
                                bench_targets.begin(),
                                bench_targets.end(),
                                [&target_slot, &target_option](
                                    const Value &candidate
                                ) {
                                    return string_arg(candidate, "slot")
                                            == target_slot
                                        && integer_arg(
                                            target_option, "player", -1)
                                            == integer_arg(
                                                candidate, "player", -2)
                                        && string_arg(
                                            target_option, "card_id")
                                            == string_arg(
                                                candidate, "card_id");
                                }
                            );
                            Value *target = pokemon(
                                self,
                                target_slot
                            );
                            if (!valid_target || target == nullptr) {
                                throw std::invalid_argument(
                                    "look_top_energy_target_missing"
                                );
                            }
                            const std::string selected_energy_id =
                                energy_option_card_id(target_option);
                            if (
                                !selected_energy_id.empty()
                                && selected_energy_id
                                    != chosen_cards[energy_index].string_or()
                            ) {
                                throw std::invalid_argument(
                                    "look_top_energy_selection_stale"
                                );
                            }
                            required(
                                *target,
                                "energy_card_ids"
                            ).as_array().push_back(
                                std::move(chosen_cards[energy_index])
                            );
                            attached[energy_index] = true;
                            result.event_types.emplace_back(
                                "energy_attached"
                            );
                        }
                    }
                    for (
                        std::size_t index = 0;
                        index < chosen_cards.size();
                        ++index
                    ) {
                        if (!attached[index]) {
                            remaining_top.push_back(
                                std::move(chosen_cards[index])
                            );
                        }
                    }
                } else {
                    Array selected_ids = card_id_values(selected_card_ids);
                    Array &hand = required(self, "hand").as_array();
                    for (Value &entry : chosen_cards) {
                        hand.push_back(std::move(entry));
                    }
                    append_card_zone_event(
                        result,
                        "cards_selected",
                        actor,
                        std::move(selected_ids),
                        "deck",
                        "hand",
                        bool_arg(args, "reveal") ? "public" : "owner"
                    );
                }
                for (Value &entry : remaining_top) {
                    if (bool_arg(args, "shuffle_rest")) {
                        deck.push_back(std::move(entry));
                    } else if (bool_arg(args, "rest_bottom", true)) {
                        deck.insert(deck.begin(), std::move(entry));
                    } else {
                        deck.push_back(std::move(entry));
                    }
                }
                if (bool_arg(args, "shuffle_rest")) {
                    shuffle_array(deck, rng);
                    result.event_types.emplace_back("deck_shuffled");
                } else if (!bool_arg(args, "rest_bottom", true)) {
                    std::reverse(
                        deck.end()
                            - static_cast<std::ptrdiff_t>(
                                remaining_top.size()
                            ),
                        deck.end()
                    );
                }
            }
        } else if (op == "place_counters_then_self_discard") {
            const std::string target_slot = selected_slot(selected_options);
            Value *target = pokemon(
                opponent,
                target_slot
            );
            if (target == nullptr) {
                throw std::invalid_argument("counter_target_missing");
            }
            const std::int64_t amount = integer_arg(
                args, "counters", 2) * 10;
            add_damage(*target, amount);
            const std::int64_t maximum_hp = pokemon_hp(cards, *target);
            if (
                maximum_hp > 0
                && integer_arg(*target, "damage_counters") * 10
                    >= maximum_hp
                && target->find("pending_ko_source_kind") == nullptr
            ) {
                (*target)["pending_ko_source_kind"] = Value(
                    "damage_counters"
                );
            }
            append_damage_feedback_event(
                result,
                "damage_counters_placed",
                actor,
                1 - actor,
                target_slot,
                amount
            );
            discard_pokemon(self, source_slot);
            if (
                source_slot == "active"
                && !pokemon_options(
                    self,
                    actor,
                    false,
                    true
                ).empty()
            ) {
                required(
                    result.state,
                    "pending_promotions"
                ).as_array().emplace_back(actor);
            }
            result.event_types.emplace_back("cards_discarded");
        } else if (op == "recover_clara") {
            const std::int64_t max_energy = std::max<std::int64_t>(
                0,
                integer_arg(args, "energy_count", 2)
            );
            const std::int64_t max_pokemon = std::max<std::int64_t>(
                0,
                integer_arg(args, "pokemon_count", 2)
            );
            const std::vector<std::string> selected_ids =
                selected_zone_card_ids(
                    self,
                    selected_options,
                    "discard",
                    actor
                );
            if (
                selected_ids.size()
                > static_cast<std::size_t>(max_energy + max_pokemon)
            ) {
                throw std::invalid_argument(
                    "clara_selection_count_exceeded"
                );
            }
            std::int64_t energy_count = 0;
            std::int64_t pokemon_count = 0;
            for (const std::string &id : selected_ids) {
                if (card_matches_energy(cards, id, "basic")) {
                    ++energy_count;
                } else if (card_is_pokemon(cards, id)) {
                    ++pokemon_count;
                } else {
                    throw std::invalid_argument(
                        "clara_selection_category_invalid"
                    );
                }
            }
            if (
                energy_count > max_energy
                || pokemon_count > max_pokemon
            ) {
                throw std::invalid_argument(
                    "clara_category_limit_exceeded"
                );
            }
            std::vector<Value> removed = remove_selected(
                self,
                "discard",
                selected_options
            );
            Array recovered_ids = card_id_values(removed);
            Array &hand = required(self, "hand").as_array();
            for (Value &entry : removed) {
                hand.push_back(std::move(entry));
            }
            append_card_zone_event(
                result,
                "cards_selected",
                actor,
                std::move(recovered_ids),
                "discard",
                "hand",
                "public"
            );
        }

    return true;
}

} // namespace ptcg::ai::rules_detail
