#include "ptcg_game.hpp"
#include "ptcg_game_internal.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <limits>
#include <stdexcept>
#include <string>
#include <string_view>
#include <unordered_set>
#include <utility>

namespace ptcg::ai {

using namespace game_detail;

Value NativeGameKernel::legal_actions(
    const Value &state,
    std::int32_t actor
) const {
    Array actions;
    if (
        (actor != 0 && actor != 1)
        || !state.is_object()
        || string_arg(state, "result_status", "ONGOING") != "ONGOING"
    ) {
        return Value(std::move(actions));
    }
    const Value *resolution_stack = state.find("resolution_stack");
    if (resolution_stack != nullptr && resolution_stack->is_object()) {
        const Value *pending = resolution_stack->find("pending_request");
        if (pending != nullptr && !pending->is_null()) {
            return Value(std::move(actions));
        }
    }

    const Value &owner = player(state, actor);
    const Value *promotions = state.find("pending_promotions");
    if (
        promotions != nullptr
        && promotions->is_array()
        && !promotions->as_array().empty()
    ) {
        if (promotions->as_array().front().as_integer(-1) != actor) {
            return Value(std::move(actions));
        }
        const Array &bench = required(owner, "bench").as_array();
        for (std::size_t index = 0; index < bench.size(); ++index) {
            if (!bench[index].is_object()) {
                continue;
            }
            actions.push_back(make_action(
                state,
                "PROMOTE",
                actor,
                Value(),
                pokemon_ref(
                    actor,
                    "bench_" + std::to_string(index),
                    bench[index]
                )
            ));
        }
        return Value(std::move(actions));
    }

    const std::string phase = string_arg(state, "phase");
    if (phase == "SETUP") {
        if (integer_arg(state, "setup_actor_idx", -1) != actor) {
            return Value(std::move(actions));
        }
        const std::string stage = string_arg(state, "setup_stage");
        if (
            stage != "INITIAL_PLACEMENT"
            && stage != "BONUS_PLACEMENT"
        ) {
            return Value(std::move(actions));
        }
        const Value *setup_ready = state.find("setup_ready");
        if (
            stage == "INITIAL_PLACEMENT"
            && setup_ready != nullptr
            && setup_ready->is_array()
            && setup_ready->as_array().at(
                static_cast<std::size_t>(actor)
            ).as_bool()
        ) {
            return Value(std::move(actions));
        }
        const Array &hand = required(owner, "hand").as_array();
        const Value *active = owner.find("active");
        const bool has_active = active != nullptr && active->is_object();
        const Array *bonus_ids = nullptr;
        const Value *bonus_rows = state.find("setup_bonus_card_ids");
        if (
            bonus_rows != nullptr
            && bonus_rows->is_array()
            && bonus_rows->as_array().size() == 2
            && bonus_rows->as_array()[
                static_cast<std::size_t>(actor)
            ].is_array()
        ) {
            bonus_ids = &bonus_rows->as_array()[
                static_cast<std::size_t>(actor)
            ].as_array();
        }
        for (std::size_t hand_index = 0; hand_index < hand.size(); ++hand_index) {
            const std::string card_id = hand[hand_index].string_or();
            const Value *card = card_definition(cards_, card_id);
            if (card == nullptr || !is_basic_pokemon(*card)) {
                continue;
            }
            if (
                stage == "BONUS_PLACEMENT"
                && (
                    bonus_ids == nullptr
                    || std::none_of(
                        bonus_ids->begin(),
                        bonus_ids->end(),
                        [&card_id](const Value &value) {
                            return value.string_or() == card_id;
                        }
                    )
                )
            ) {
                continue;
            }
            const Value source = card_ref(
                actor,
                "hand",
                hand_index,
                card_id
            );
            if (stage == "INITIAL_PLACEMENT" && !has_active) {
                actions.push_back(make_action(
                    state,
                    "PLAY_BASIC",
                    actor,
                    source,
                    slot_ref(actor, "active")
                ));
            } else if (has_active) {
                const Array &bench = required(owner, "bench").as_array();
                for (std::size_t index = 0; index < bench.size(); ++index) {
                    if (bench[index].is_null()) {
                        actions.push_back(make_action(
                            state,
                            "PLAY_BASIC",
                            actor,
                            source,
                            slot_ref(
                                actor,
                                "bench_" + std::to_string(index)
                            )
                        ));
                    }
                }
            }
        }
        if (stage == "BONUS_PLACEMENT" || has_active) {
            actions.push_back(make_action(
                state,
                "SETUP_DONE",
                actor
            ));
        }
        return Value(std::move(actions));
    }

    if (phase == "ATTACK") {
        if (integer_arg(state, "active_player_idx", -1) == actor) {
            actions.push_back(make_action(
                state,
                "END_TURN",
                actor
            ));
        }
        return Value(std::move(actions));
    }
    if (
        phase != "MAIN"
        || integer_arg(state, "active_player_idx", -1) != actor
    ) {
        return Value(std::move(actions));
    }

    std::vector<std::pair<std::string, const Value *>> pokemon_rows;
    append_pokemon_rows(owner, pokemon_rows);
    std::vector<std::string> empty_bench;
    const Array &bench = required(owner, "bench").as_array();
    for (std::size_t index = 0; index < bench.size(); ++index) {
        if (bench[index].is_null()) {
            empty_bench.push_back("bench_" + std::to_string(index));
        }
    }

    const Array &hand = required(owner, "hand").as_array();
    for (std::size_t hand_index = 0; hand_index < hand.size(); ++hand_index) {
        const std::string card_id = hand[hand_index].string_or();
        const Value *card = card_definition(cards_, card_id);
        if (card == nullptr) {
            continue;
        }
        const Value source = card_ref(
            actor,
            "hand",
            hand_index,
            card_id
        );
        if (is_basic_pokemon(*card)) {
            for (const std::string &slot : empty_bench) {
                actions.push_back(make_action(
                    state,
                    "PLAY_BASIC",
                    actor,
                    source,
                    slot_ref(actor, slot)
                ));
            }
            continue;
        }
        if (
            is_pokemon_card(*card)
            && (
                card_has_subtype(*card, "Stage 1")
                || card_has_subtype(*card, "Stage 2")
            )
            && !is_player_first_turn(state, actor)
        ) {
            const std::string evolves_from = string_arg(
                *card,
                "evolves_from"
            );
            for (const auto &[slot, target] : pokemon_rows) {
                if (
                    bool_arg(*target, "placed_this_turn")
                    || !bool_arg(*target, "can_evolve_this_turn", true)
                ) {
                    continue;
                }
                const Value *target_card = card_definition(
                    cards_,
                    string_arg(*target, "card_id")
                );
                if (
                    target_card == nullptr
                    || string_arg(*target_card, "name") != evolves_from
                ) {
                    continue;
                }
                actions.push_back(make_action(
                    state,
                    "EVOLVE",
                    actor,
                    source,
                    pokemon_ref(actor, slot, *target)
                ));
            }
            continue;
        }
        if (
            is_energy_card(*card)
            && !bool_arg(owner, "energy_attached_this_turn")
        ) {
            for (const auto &[slot, target] : pokemon_rows) {
                actions.push_back(make_action(
                    state,
                    "ATTACH_ENERGY",
                    actor,
                    source,
                    pokemon_ref(actor, slot, *target)
                ));
            }
            continue;
        }
        if (!is_trainer_card(*card)) {
            continue;
        }
        if (is_supporter_card(*card)) {
            if (
                bool_arg(owner, "supporter_played_this_turn")
                || integer_arg(state, "turn_number") == 1
            ) {
                continue;
            }
        } else if (is_stadium_card(*card)) {
            const Value *stadium = state.find("stadium_card_id");
            const Value *current_card = stadium != nullptr
                ? card_definition(cards_, stadium->string_or())
                : nullptr;
            if (
                bool_arg(owner, "stadium_played_this_turn")
                || (
                    current_card != nullptr
                    && string_arg(*current_card, "name")
                        == string_arg(*card, "name")
                )
            ) {
                continue;
            }
        }
        if (is_tool_card(*card)) {
            for (const auto &[slot, target] : pokemon_rows) {
                if (!string_arg(*target, "attached_tool_id").empty()) {
                    continue;
                }
                actions.push_back(make_action(
                    state,
                    "PLAY_TRAINER",
                    actor,
                    source,
                    pokemon_ref(actor, slot, *target)
                ));
            }
        } else {
            actions.push_back(make_action(
                state,
                "PLAY_TRAINER",
                actor,
                source
            ));
        }
    }

    for (const auto &[slot, target] : pokemon_rows) {
        const Value *definition = card_definition(
            cards_,
            string_arg(*target, "card_id")
        );
        const Value *abilities = definition != nullptr
            ? definition->find("abilities")
            : nullptr;
        if (abilities == nullptr || !abilities->is_array()) {
            continue;
        }
        for (const Value &ability : abilities->as_array()) {
            if (
                !ability.is_object()
                || ability_is_discard_revive(ability)
            ) {
                continue;
            }
            const Value *compiled_effects = ability.find(
                "compiled_effects"
            );
            if (
                compiled_effects != nullptr
                && compiled_effects->is_array()
                && !ability_effect_list_has_visible_target(
                    cards_,
                    state,
                    actor,
                    *compiled_effects,
                    slot
                )
            ) {
                continue;
            }
            const std::string trigger = string_arg(ability, "trigger");
            if (
                trigger == "passive"
                || trigger == "on_enter_play"
                || trigger == "on_damaged"
            ) {
                continue;
            }
            const std::string name = string_arg(ability, "name");
            if (
                trigger != "repeatable"
                && array_contains_string(
                    target->find("used_abilities"),
                    name
                )
            ) {
                continue;
            }
            actions.push_back(make_action(
                state,
                "USE_ABILITY",
                actor,
                pokemon_ref(actor, slot, *target),
                Value(),
                Value(Object{{"ability_name", Value(name)}})
            ));
        }
    }

    if (hand.empty() && !empty_bench.empty()) {
        const Array &discard = required(owner, "discard").as_array();
        for (std::size_t index = 0; index < discard.size(); ++index) {
            const std::string card_id = discard[index].string_or();
            const Value *definition = card_definition(cards_, card_id);
            const Value *abilities = definition != nullptr
                ? definition->find("abilities")
                : nullptr;
            if (abilities == nullptr || !abilities->is_array()) {
                continue;
            }
            for (const Value &ability : abilities->as_array()) {
                if (!ability.is_object()
                    || !ability_is_discard_revive(ability)) {
                    continue;
                }
                actions.push_back(make_action(
                    state,
                    "USE_ABILITY",
                    actor,
                    card_ref(actor, "discard", index, card_id),
                    Value(),
                    Value(Object{{
                        "ability_name",
                        Value(string_arg(ability, "name")),
                    }})
                ));
            }
        }
    }

    const std::string stadium_id = string_arg(state, "stadium_card_id");
    const Value *stadium = card_definition(cards_, stadium_id);
    if (
        !stadium_id.empty()
        && stadium != nullptr
        && !bool_arg(owner, "stadium_used_this_turn")
        && stadium_has_activation(*stadium)
    ) {
        actions.push_back(make_action(
            state,
            "USE_STADIUM",
            actor,
            card_ref(actor, "stadium", 0, stadium_id)
        ));
    }

    const Value *active = owner.find("active");
    if (active != nullptr && active->is_object()) {
        const Value *active_card = card_definition(
            cards_,
            string_arg(*active, "card_id")
        );
        const bool special_condition_blocks_action = (
            array_contains_string(
                active->find("status_conditions"),
                "ASLEEP"
            )
            || array_contains_string(
                active->find("status_conditions"),
                "PARALYZED"
            )
        );
        if (
            !bool_arg(owner, "retreated_this_turn")
            && !special_condition_blocks_action
        ) {
            const std::size_t available_units = energy_units(
                cards_,
                *active
            ).size();
            const std::int64_t retreat_cost = effective_retreat_cost(
                cards_,
                state,
                *active,
                active_card
            );
            if (available_units >= static_cast<std::size_t>(
                std::max<std::int64_t>(0, retreat_cost)
            )) {
                for (std::size_t index = 0; index < bench.size(); ++index) {
                    if (!bench[index].is_object()) {
                        continue;
                    }
                    actions.push_back(make_action(
                        state,
                        "RETREAT",
                        actor,
                        pokemon_ref(actor, "active", *active),
                        pokemon_ref(
                            actor,
                            "bench_" + std::to_string(index),
                            bench[index]
                        )
                    ));
                }
            }
        }

        if (
            integer_arg(state, "turn_number") != 1
            && !special_condition_blocks_action
        ) {
            const Value *attacks = active_card != nullptr
                ? active_card->find("attacks")
                : nullptr;
            if (attacks != nullptr && attacks->is_array()) {
                for (
                    std::size_t attack_index = 0;
                    attack_index < attacks->as_array().size();
                    ++attack_index
                ) {
                    const Value &attack = attacks->as_array()[attack_index];
                    const Value *cost = attack.find("cost");
                    if (
                        attack_is_locked(
                            *active,
                            string_arg(attack, "name")
                        )
                        || player_attack_name_is_locked(
                            owner,
                            string_arg(attack, "name"),
                            integer_arg(state, "turn_number")
                        )
                        || (
                            cost != nullptr
                            && !can_pay_attack_cost(
                                cards_,
                                *active,
                                *cost
                            )
                        )
                    ) {
                        continue;
                    }
                    actions.push_back(make_action(
                        state,
                        "DECLARE_ATTACK",
                        actor,
                        pokemon_ref(actor, "active", *active),
                        Value(),
                        Value(Object{{
                            "attack_index",
                            Value(static_cast<std::int64_t>(
                                attack_index
                            )),
                        }})
                    ));
                }
            }
        }
    }

    // Keep legality information-set stable. In particular, never dry-run a
    // deck effect here: the pending options could depend on a hidden deck
    // order and make one action appear/disappear across determinizations.
    // Only public/visible target checks belong in this query.
    actions.erase(
        std::remove_if(
            actions.begin(),
            actions.end(),
            [this, &state, actor](const Value &action) {
                const std::string kind = string_arg(action, "kind");
                if (kind != "PLAY_TRAINER") {
                    return false;
                }
                const Value *source = action.find("source");
                if (source == nullptr || !source->is_object()) {
                    return false;
                }
                const Value *definition = card_definition(
                    cards_,
                    string_arg(*source, "card_id")
                );
                const Value *effects = definition != nullptr
                    ? definition->find("compiled_trainer_effects")
                    : nullptr;
                if (effects == nullptr || !effects->is_array()) {
                    return false;
                }
                return !effect_list_has_visible_target(
                    cards_,
                    state,
                    actor,
                    *effects,
                    static_cast<std::size_t>(
                        integer_arg(*source, "index", -1)
                    )
                );
            }
        ),
        actions.end()
    );
    actions.push_back(make_action(state, "END_TURN", actor));
    return Value(std::move(actions));
}


} // namespace ptcg::ai
