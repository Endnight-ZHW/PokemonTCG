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

bool resume_vm_damage(
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
    if (!(
        op == "discard_cards"
        || op == "discard_energy"
        || op == "draw_and_attach_energy"
        || op == "evolve_skip_stage"
        || op == "flip_coin"
        || op == "flip_coin_repeat_damage"
        || op == "flip_coin_then_discard_energy"
        || op == "flip_coin_then_ko"
        || op == "flip_until_tails"
    )) return false;
    const Value *spec = continuation.find("command_spec");
    Value &self = player(result.state, actor);
    Value &opponent = player(result.state, 1 - actor);
    auto next = [&result](Value request, Value next_continuation) {
        increment_integer(result.state, "choice_sequence");
        result.pending = std::move(request);
        result.continuation = std::move(next_continuation);
    };

        if (op == "discard_cards") {
            const std::string zone = string_arg(
                args,
                "from",
                string_arg(args, "from_zone", "hand")
            );
            const std::int64_t amount = std::max<std::int64_t>(
                0,
                integer_arg(args, "amount", 1)
            );
            if (
                selected_options.as_array().size()
                != static_cast<std::size_t>(amount)
            ) {
                throw std::invalid_argument(
                    "discard_selection_count_invalid"
                );
            }
            selected_zone_card_ids(
                self,
                selected_options,
                zone,
                actor
            );
            Array discarded_ids = selected_card_id_values(
                selected_options);
            const std::size_t removed = discard_selected(
                self,
                zone,
                selected_options
            );
            if (removed > 0) {
                append_card_zone_event(
                    result,
                    "cards_discarded",
                    actor,
                    std::move(discarded_ids),
                    zone,
                    "discard",
                    "public"
                );
            }
        } else if (op == "discard_energy") {
            const bool own = string_arg(args, "from", "self") == "self";
            Value &owner = own ? self : opponent;
            const std::int32_t owner_index = own ? actor : 1 - actor;
            Value *target = pokemon(owner, "active");
            if (target == nullptr) {
                throw std::invalid_argument("energy_discard_target_missing");
            }
            Array &energy = required(*target, "energy_card_ids").as_array();
            const std::string filter = string_arg(args, "filter", "any");
            const std::int64_t matching_count = static_cast<std::int64_t>(
                std::count_if(
                    energy.begin(),
                    energy.end(),
                    [&cards, target, &energy, &filter](const Value &entry) {
                        const std::size_t index = static_cast<std::size_t>(
                            &entry - energy.data()
                        );
                        return attached_energy_card_matches(
                            cards, *target, index, filter);
                    }
                )
            );
            const std::int64_t expected_count = std::min<std::int64_t>(
                std::max<std::int64_t>(0, integer_arg(args, "amount", 1)),
                matching_count
            );
            if (
                selected_options.as_array().size()
                != static_cast<std::size_t>(expected_count)
            ) {
                throw std::invalid_argument(
                    "energy_discard_selection_count_invalid"
                );
            }
            std::vector<std::size_t> indices;
            for (const Value &entry : selected_options.as_array()) {
                const std::int64_t raw_index = integer_arg(
                    entry, "index", -1);
                if (
                    !entry.is_object()
                    || string_arg(entry, "kind") != "attachment"
                    || string_arg(entry, "attachment_type") != "energy"
                    || integer_arg(entry, "player", -1) != owner_index
                    || string_arg(entry, "slot") != "active"
                    || raw_index < 0
                    || static_cast<std::size_t>(raw_index) >= energy.size()
                    || energy[static_cast<std::size_t>(raw_index)].string_or()
                        != string_arg(entry, "card_id")
                    || !attached_energy_card_matches(
                        cards,
                        *target,
                        static_cast<std::size_t>(raw_index),
                        filter
                    )
                ) {
                    throw std::invalid_argument(
                        "energy_discard_selection_invalid"
                    );
                }
                indices.push_back(static_cast<std::size_t>(raw_index));
            }
            std::sort(indices.begin(), indices.end());
            if (
                std::adjacent_find(indices.begin(), indices.end())
                != indices.end()
            ) {
                throw std::invalid_argument(
                    "duplicate_energy_discard_selection"
                );
            }
            Array &discard = required(owner, "discard").as_array();
            for (const std::size_t index : indices) {
                if (index >= energy.size()) {
                    throw std::invalid_argument(
                        "energy_attachment_out_of_range"
                    );
                }
                discard.push_back(energy[index]);
            }
            for (auto index = indices.rbegin(); index != indices.rend(); ++index) {
                energy.erase(
                    energy.begin() + static_cast<std::ptrdiff_t>(*index)
                );
            }
            if (!indices.empty()) {
                result.event_types.emplace_back("cards_discarded");
            }
        } else if (op == "draw_and_attach_energy") {
            const std::string filter = string_arg(
                args,
                "energy_type",
                "Grass"
            );
            Array &hand = required(self, "hand").as_array();
            validate_energy_distribution_selection(
                selected_options.as_array(),
                true,
                std::max<std::int64_t>(
                    0,
                    integer_arg(args, "energy_count", 2)
                )
            );
            const std::string forced_target_slot = (
                selected_options.as_array().empty()
            ) ? std::string{} : string_arg(
                selected_options.as_array().front(),
                "slot"
            );
            for (const Value &selected : selected_options.as_array()) {
                const auto energy = std::find_if(
                    hand.begin(),
                    hand.end(),
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
                if (energy == hand.end()) {
                    throw std::invalid_argument(
                        "energy_attachment_source_missing"
                    );
                }
                Value *target = pokemon(
                    self,
                    forced_target_slot.empty()
                        ? string_arg(selected, "slot")
                        : forced_target_slot
                );
                if (target == nullptr) {
                    throw std::invalid_argument(
                        "energy_attachment_target_missing"
                    );
                }
                required(
                    *target,
                    "energy_card_ids"
                ).as_array().push_back(std::move(*energy));
                hand.erase(energy);
                result.event_types.emplace_back("energy_attached");
            }
        } else if (op == "evolve_skip_stage") {
            if (
                selected_options.as_array().size() != 1
                || !selected_options.as_array().front().is_object()
            ) {
                throw std::invalid_argument("evolution_card_required");
            }
            const Value &selected = selected_options.as_array().front();
            Array &hand = required(self, "hand").as_array();
            const std::int64_t selected_index = integer_arg(
                selected,
                "index",
                -1
            );
            if (
                selected_index < 0
                || static_cast<std::size_t>(selected_index) >= hand.size()
                || hand[static_cast<std::size_t>(selected_index)].string_or()
                    != string_arg(selected, "card_id")
            ) {
                throw std::invalid_argument("evolution_card_stale");
            }
            Value removed = std::move(
                hand[static_cast<std::size_t>(selected_index)]
            );
            hand.erase(
                hand.begin()
                    + static_cast<std::ptrdiff_t>(selected_index)
            );
            const Value *evolution = card_definition(
                cards,
                removed.string_or()
            );
            const std::string skipped_stage_name = evolution == nullptr
                ? std::string{}
                : string_arg(*evolution, "evolves_from");
            std::string basic_name;
            if (!skipped_stage_name.empty()) {
                for (const auto &[unused_id, definition] : cards.as_object()) {
                    (void)unused_id;
                    if (
                        definition.is_object()
                        && string_arg(definition, "name")
                            == skipped_stage_name
                    ) {
                        basic_name = string_arg(
                            definition,
                            "evolves_from"
                        );
                        break;
                    }
                }
            }
            std::string target_slot = string_arg(
                selected,
                "target_slot"
            );
            if (target_slot.empty()) {
                const std::string option_id = string_arg(
                    selected,
                    "option_id"
                );
                constexpr const char *prefix = "rare_candy:";
                if (option_id.rfind(prefix, 0) == 0) {
                    const std::size_t end = option_id.find(
                        ':',
                        std::char_traits<char>::length(prefix)
                    );
                    if (end != std::string::npos) {
                        target_slot = option_id.substr(
                            std::char_traits<char>::length(prefix),
                            end - std::char_traits<char>::length(prefix)
                        );
                    }
                }
            }
            Value *target = target_slot.empty()
                ? nullptr
                : pokemon(self, target_slot);
            if (target == nullptr && target_slot.empty()) {
                for (Value *candidate : all_pokemon(self)) {
                    const Value *definition = card_definition(
                        cards,
                        card_id(*candidate)
                    );
                    if (
                        card_has_subtype(
                            cards,
                            card_id(*candidate),
                            "Basic"
                        )
                        && (
                            basic_name.empty()
                            || (
                                definition != nullptr
                                && string_arg(*definition, "name")
                                    == basic_name
                            )
                        )
                    ) {
                        target = candidate;
                        break;
                    }
                }
            }
            if (target == nullptr) {
                throw std::invalid_argument("evolution_target_missing");
            }
            const Value *target_definition = card_definition(
                cards,
                card_id(*target)
            );
            if (
                !card_has_subtype(cards, card_id(*target), "Basic")
                || (
                    !basic_name.empty()
                    && (
                        target_definition == nullptr
                        || string_arg(*target_definition, "name")
                            != basic_name
                    )
                )
            ) {
                throw std::invalid_argument("evolution_target_stale");
            }
            required(
                *target,
                "evolution_stack_ids"
            ).as_array().emplace_back(card_id(*target));
            (*target)["card_id"] = std::move(removed);
            (*target)["can_evolve_this_turn"] = Value(false);
            result.event_types.emplace_back("pokemon_evolved");
        } else if (
            op == "flip_coin"
            || op == "flip_coin_repeat_damage"
            || op == "flip_coin_then_discard_energy"
            || op == "flip_coin_then_ko"
            || op == "flip_until_tails"
        ) {
            const Value *flip_value = continuation.find("flips");
            if (flip_value == nullptr || !flip_value->is_array()) {
                throw std::invalid_argument("coin_results_missing");
            }
            const Array &flips = flip_value->as_array();
            const std::int64_t heads = static_cast<std::int64_t>(
                std::count_if(
                    flips.begin(),
                    flips.end(),
                    [](const Value &entry) { return entry.as_bool(); }
                )
            );
            if (stage == 0) {
                result.event_types.emplace_back("coin_flip");
                append_event(
                    result,
                    "coin_flip",
                    Object{{"results", Value(flips)}}
                );
            }
            if (op == "flip_coin") {
                const Value *branches = spec->find("branches");
                const Value *branch = (
                    branches != nullptr && branches->is_object()
                ) ? branches->find(
                    !flips.empty() && flips.front().as_bool()
                        ? "on_heads"
                        : "on_tails"
                ) : nullptr;
                if (branch != nullptr && branch->is_array()) {
                    for (const Value &branch_spec : branch->as_array()) {
                        if (
                            bool_arg(result.context, "defer_coin_post_damage")
                            && coin_branch_runs_after_attack_damage(
                                string_arg(branch_spec, "op")
                            )
                        ) {
                            Value *deferred = result.context.find(
                                "deferred_attack_effects"
                            );
                            if (deferred == nullptr || !deferred->is_array()) {
                                result.context["deferred_attack_effects"] =
                                    Value::make_array();
                                deferred = result.context.find(
                                    "deferred_attack_effects"
                                );
                            }
                            deferred->as_array().push_back(branch_spec);
                            continue;
                        }
                        VmExecutionResult following = kernel.execute(
                            std::move(result.state),
                            branch_spec,
                            actor,
                            source_slot,
                            rng.state(),
                            string_arg(
                                continuation,
                                "context_mode"
                            ),
                            result.context
                        );
                        if (!following.success) {
                            throw std::invalid_argument(
                                following.error_code
                            );
                        }
                        result.state = std::move(following.state);
                        result.context = std::move(following.context);
                        rng.set_state(following.rng_state);
                        result.event_types.insert(
                            result.event_types.end(),
                            following.event_types.begin(),
                            following.event_types.end()
                        );
                        append_events(result.events, following.events);
                        if (!following.pending.as_object().empty()) {
                            result.pending = std::move(following.pending);
                            result.continuation = std::move(
                                following.continuation
                            );
                            break;
                        }
                    }
                }
            } else if (op == "flip_coin_repeat_damage") {
                set_attack_damage(
                    result.context,
                    heads * integer_arg(args, "damage_per_head", 10),
                    true
                );
            } else if (op == "flip_coin_then_discard_energy") {
                if (stage == 0) {
                    if (!flips.empty() && flips.front().as_bool()) {
                        Array options;
                        auto append_attachments = [
                            &options,
                            &opponent,
                            actor
                        ](const std::string &slot) {
                            Value *target = pokemon(opponent, slot);
                            if (target == nullptr) {
                                return;
                            }
                            const Array &energy = required(
                                *target,
                                "energy_card_ids"
                            ).as_array();
                            for (
                                std::size_t index = 0;
                                index < energy.size();
                                ++index
                            ) {
                                options.push_back(attachment_option(
                                    energy[index].string_or(),
                                    1 - actor,
                                    slot,
                                    static_cast<std::int64_t>(index)
                                ));
                            }
                        };
                        append_attachments("active");
                        const Array &bench = required(
                            opponent,
                            "bench"
                        ).as_array();
                        for (
                            std::size_t index = 0;
                            index < bench.size();
                            ++index
                        ) {
                            append_attachments(
                                "bench_" + std::to_string(index)
                            );
                        }
                        if (!options.empty()) {
                            Value continued = continuation;
                            continued["stage"] = Value(1);
                            next(
                                pending_request(
                                    "select_attachment",
                                    actor,
                                    1,
                                    1,
                                    false,
                                    false,
                                    std::move(options),
                                    "discard_attachment"
                                ),
                                std::move(continued)
                            );
                        }
                    }
                } else {
                    if (
                        selected_options.as_array().size() != 1
                        || string_arg(
                            selected_options.as_array().front(),
                            "kind"
                        ) != "attachment"
                    ) {
                        throw std::invalid_argument(
                            "selected_attachment_invalid"
                        );
                    }
                    const Value &selection =
                        selected_options.as_array().front();
                    if (integer_arg(selection, "player", -1) != 1 - actor) {
                        throw std::invalid_argument(
                            "selected_attachment_owner_invalid"
                        );
                    }
                    Value *target = pokemon(
                        opponent,
                        string_arg(selection, "slot")
                    );
                    if (target == nullptr) {
                        throw std::invalid_argument(
                            "selected_attachment_target_missing"
                        );
                    }
                    Array &energy = required(
                        *target,
                        "energy_card_ids"
                    ).as_array();
                    const std::int64_t raw_index = integer_arg(
                        selection,
                        "index",
                        -1
                    );
                    if (
                        raw_index < 0
                        || static_cast<std::size_t>(raw_index)
                            >= energy.size()
                        || energy[static_cast<std::size_t>(raw_index)]
                                .string_or()
                            != string_arg(selection, "card_id")
                    ) {
                        throw std::invalid_argument(
                            "selected_attachment_stale"
                        );
                    }
                    required(
                        opponent,
                        "discard"
                    ).as_array().push_back(std::move(
                        energy[static_cast<std::size_t>(raw_index)]
                    ));
                    energy.erase(
                        energy.begin()
                            + static_cast<std::ptrdiff_t>(raw_index)
                    );
                    result.event_types.emplace_back("cards_discarded");
                }
            } else if (op == "flip_until_tails") {
                set_attack_damage(
                    result.context,
                    heads * integer_arg(args, "per_head", 20),
                    true
                );
            } else if (stage == 0 && heads == 2) {
                Value *target = pokemon(opponent, "active");
                if (
                    target != nullptr
                    && !(
                        string_arg(continuation, "context_mode") == "attack"
                        && prevents_attack_effects(*target)
                    )
                ) {
                    const std::string defeated_id = card_id(*target);
                    const Value *defeated_definition = card_definition(
                        cards,
                        defeated_id
                    );
                    const std::int64_t prize_value = std::max<std::int64_t>(
                        1,
                        defeated_definition == nullptr
                            ? 1
                            : integer_arg(
                                *defeated_definition,
                                "prize_value",
                                1
                            )
                    );
                    discard_pokemon(opponent, "active");
                    result.event_types.emplace_back(
                        "direct_knockout_applied"
                    );
                    result.event_types.emplace_back("pokemon_ko");
                    result.event_types.emplace_back("card_moved");
                    if (!pokemon_options(
                            opponent,
                            1 - actor,
                            false,
                            true
                        ).empty()) {
                        required(
                            result.state,
                            "pending_promotions"
                        ).as_array().emplace_back(1 - actor);
                    }
                    Value *fact_book = result.state.find("turn_fact_book");
                    if (fact_book != nullptr && fact_book->is_object()) {
                        Value *current = fact_book->find("current_turn");
                        if (current != nullptr && current->is_object()) {
                            Value *knockouts = current->find("knockouts");
                            if (knockouts != nullptr && knockouts->is_array()) {
                                Object fact;
                                fact["card_id"] = Value(defeated_id);
                                fact["cause_detail"] = Value("");
                                fact["cause_kind"] = Value(
                                    "direct_knockout"
                                );
                                fact["defeated_player"] = Value(1 - actor);
                                fact["slot"] = Value("active");
                                fact["source_kind"] = Value(
                                    "attack_effect"
                                );
                                fact["source_player"] = Value(actor);
                                fact["turn"] = Value(get_integer(
                                    result.state,
                                    "turn_number"
                                ));
                                knockouts->as_array().emplace_back(
                                    std::move(fact)
                                );
                            }
                        }
                    }
                    Array prize_options;
                    const Array &prizes = required(
                        self,
                        "prizes"
                    ).as_array();
                    for (std::size_t index = 0; index < prizes.size(); ++index) {
                        prize_options.push_back(id_option(
                            "prize:" + std::to_string(index)
                        ));
                    }
                    Value continued = continuation;
                    continued["stage"] = Value(1);
                    continued["remaining_prizes"] = Value(
                        std::max<std::int64_t>(0, prize_value - 1)
                    );
                    next(
                        pending_request(
                            "select_prize",
                            actor,
                            1,
                            1,
                            false,
                            false,
                            std::move(prize_options),
                            "select_prize"
                        ),
                        std::move(continued)
                    );
                }
            } else if (stage == 1) {
                if (
                    selected_options.as_array().size() != 1
                    || !selected_options.as_array().front().is_object()
                ) {
                    throw std::invalid_argument(
                        "prize_selection_invalid"
                    );
                }
                const std::string selected = string_arg(
                    selected_options.as_array().front(),
                    "option_id"
                );
                const std::size_t separator = selected.find(':');
                if (
                    selected.rfind("prize:", 0) != 0
                    || separator == std::string::npos
                    || separator + 1 >= selected.size()
                ) {
                    throw std::invalid_argument(
                        "prize_selection_invalid"
                    );
                }
                const std::size_t index = static_cast<std::size_t>(
                    std::stoul(selected.substr(separator + 1))
                );
                Array &prizes = required(self, "prizes").as_array();
                Array &hand = required(self, "hand").as_array();
                if (index >= prizes.size()) {
                    throw std::invalid_argument("prize_index_invalid");
                }
                hand.push_back(std::move(prizes[index]));
                prizes.erase(
                    prizes.begin() + static_cast<std::ptrdiff_t>(index)
                );
                result.event_types.clear();
                result.event_types.emplace_back("prize_taken");
                const std::int64_t remaining = std::max<std::int64_t>(
                    0,
                    integer_arg(continuation, "remaining_prizes")
                );
                if (remaining > 0 && !prizes.empty()) {
                    Array prize_options;
                    for (
                        std::size_t prize_index = 0;
                        prize_index < prizes.size();
                        ++prize_index
                    ) {
                        prize_options.push_back(id_option(
                            "prize:" + std::to_string(prize_index)
                        ));
                    }
                    Value continued = continuation;
                    continued["remaining_prizes"] = Value(remaining - 1);
                    next(
                        pending_request(
                            "select_prize",
                            actor,
                            1,
                            1,
                            false,
                            false,
                            std::move(prize_options),
                            "select_prize"
                        ),
                        std::move(continued)
                    );
                }
            }
        }

    return true;
}

} // namespace ptcg::ai::rules_detail
