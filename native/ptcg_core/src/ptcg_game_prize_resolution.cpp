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

namespace ptcg::ai::game_detail {

using Array = Value::Array;
using Object = Value::Object;

bool prize_attaches_to_bench(
    const Value &cards,
    const std::string &prize_card_id
) {
    const Value *definition = card_definition(cards, prize_card_id);
    const Value *effects = definition == nullptr
        ? nullptr
        : definition->find("energy_effects");
    if (effects == nullptr || !effects->is_array()) {
        return false;
    }
    return std::any_of(
        effects->as_array().begin(),
        effects->as_array().end(),
        [](const Value &descriptor) {
            const Value *condition = descriptor.find("condition");
            const Value *effect = descriptor.find("effect");
            return descriptor.is_object()
                && string_arg(descriptor, "kind") == "trigger"
                && string_arg(descriptor, "hook")
                    == "ON_PRIZE_REVEALED"
                && condition != nullptr
                && condition->is_object()
                && string_arg(*condition, "source_zone") == "prizes"
                && effect != nullptr
                && effect->is_object()
                && string_arg(*effect, "op")
                    == "attach_to_benched_pokemon";
        }
    );
}

void continue_after_prize_selection(
    GameExecutionResult &result,
    const Value &cards,
    const Value &continuation
) {
    const Value *remaining_prizes = continuation.find(
        "remaining_prize_players"
    );
    if (
        remaining_prizes != nullptr
        && remaining_prizes->is_array()
        && !remaining_prizes->as_array().empty()
    ) {
        std::vector<std::int32_t> queue;
        queue.reserve(remaining_prizes->as_array().size());
        for (const Value &entry : remaining_prizes->as_array()) {
            const std::int32_t prize_player =
                static_cast<std::int32_t>(entry.as_integer(-1));
            if (prize_player != 0 && prize_player != 1) {
                throw std::invalid_argument(
                    "prize_queue_player_invalid"
                );
            }
            queue.push_back(prize_player);
        }
        suspend_prize_queue(
            result,
            queue,
            static_cast<std::int32_t>(integer_arg(
                continuation,
                "resume_attack_actor",
                -1
            )),
            continuation.find("resume_attack_context") != nullptr
                ? *continuation.find("resume_attack_context")
                : Value::make_object()
        );
        if (bool_arg(continuation, "finish_attack_after_prizes")) {
            result.continuation["finish_attack_after_prizes"] =
                Value(true);
        }
        if (bool_arg(continuation, "finish_checkup_after_prizes")) {
            result.continuation["finish_checkup_after_prizes"] =
                Value(true);
            result.continuation["resume_checkup_actor"] = Value(
                integer_arg(
                    continuation,
                    "resume_checkup_actor",
                    -1
                )
            );
        }
        return;
    }
    evaluate_terminal_result(result.state);
    if (string_arg(result.state, "phase") == "GAME_OVER") {
        required(
            result.state,
            "pending_promotions"
        ).as_array().clear();
        append_event(
            result,
            "game_over",
            Object{
                {
                    "winner",
                    Value(integer_arg(result.state, "winner", -1)),
                },
                {
                    "result_status",
                    Value(string_arg(result.state, "result_status")),
                },
                {"reason", Value("knockout")},
                {
                    "conditions",
                    required(result.state, "result_conditions"),
                },
            }
        );
    } else if (bool_arg(
        continuation,
        "finish_attack_after_prizes"
    )) {
        const std::int32_t attack_actor =
            static_cast<std::int32_t>(integer_arg(
                continuation,
                "resume_attack_actor",
                -1
            ));
        if (
            (attack_actor != 0 && attack_actor != 1)
            || string_arg(result.state, "phase") != "ATTACK"
        ) {
            throw std::invalid_argument(
                "prize_attack_resume_context_invalid"
            );
        }
        const Value *promotions = result.state.find(
            "pending_promotions"
        );
        if (
            promotions == nullptr
            || !promotions->is_array()
            || promotions->as_array().empty()
        ) {
            finish_turn(result, cards, attack_actor);
        }
    } else if (bool_arg(
        continuation,
        "finish_checkup_after_prizes"
    )) {
        const std::int32_t outgoing_actor =
            static_cast<std::int32_t>(integer_arg(
                continuation,
                "resume_checkup_actor",
                -1
            ));
        if (
            (outgoing_actor != 0 && outgoing_actor != 1)
            || string_arg(result.state, "phase")
                != "POKEMON_CHECKUP"
            || integer_arg(result.state, "active_player_idx")
                != outgoing_actor
        ) {
            throw std::invalid_argument(
                "prize_checkup_resume_context_invalid"
            );
        }
        const Value *promotions = result.state.find(
            "pending_promotions"
        );
        if (
            promotions == nullptr
            || !promotions->is_array()
            || promotions->as_array().empty()
        ) {
            complete_checkup_transition(
                result.state,
                outgoing_actor,
                result.event_types
            );
        }
    } else if (
        continuation.find("resume_attack_context") != nullptr
    ) {
        Value resumed_context = required(
            continuation,
            "resume_attack_context"
        );
        finish_attack_resolution(
            result,
            cards,
            static_cast<std::int32_t>(integer_arg(
                continuation,
                "resume_attack_actor",
                -1
            )),
            resumed_context
        );
    }
}

void suspend_exp_share_confirmation(
    GameExecutionResult &result,
    std::int32_t defeated_owner,
    std::int32_t attack_actor,
    const Value &continuation,
    std::int64_t remaining,
    bool remaining_requires_order
) {
    increment(result.state, "choice_sequence");
    result.pending = action_pending(
        "confirm_trigger",
        defeated_owner,
        1,
        1,
        false,
        {
            Value(Object{
                {"kind", Value("id")},
                {"option_id", Value("confirm:yes")},
            }),
            Value(Object{
                {"kind", Value("id")},
                {"option_id", Value("confirm:no")},
            }),
        },
        "confirm_exp_share_trigger",
        true
    );
    result.continuation = continuation;
    result.continuation["kind"] = Value(
        "confirm_exp_share_trigger"
    );
    result.continuation["actor"] = Value(defeated_owner);
    result.continuation["attack_actor"] = Value(attack_actor);
    result.continuation["remaining_exp_share_triggers"] =
        Value(remaining);
    result.continuation["remaining_exp_share_requires_order"] =
        Value(remaining_requires_order);
}

void suspend_exp_share_order(
    GameExecutionResult &result,
    std::int32_t defeated_owner,
    std::int32_t attack_actor,
    const Value &continuation,
    std::int64_t count
) {
    if (count < 2 || count > 8) {
        throw std::invalid_argument("exp_share_order_count_invalid");
    }
    Array options;
    options.reserve(static_cast<std::size_t>(count));
    for (std::int64_t index = 0; index < count; ++index) {
        options.emplace_back(Object{
            {"kind", Value("id")},
            {
                "option_id",
                Value("trigger:" + std::to_string(index)),
            },
        });
    }
    increment(result.state, "choice_sequence");
    result.pending = action_pending(
        "choose_trigger_order",
        defeated_owner,
        1,
        1,
        false,
        std::move(options),
        "public_exp_share_order",
        true
    );
    result.continuation = continuation;
    result.continuation["kind"] = Value(
        "public_exp_share_order"
    );
    result.continuation["actor"] = Value(defeated_owner);
    result.continuation["attack_actor"] = Value(attack_actor);
    result.continuation["exp_share_order_count"] = Value(count);
}

void validate_public_exp_share_spec(
    const Value &state,
    std::int32_t actor,
    const Value &spec
) {
    if (!spec.is_object()) {
        throw std::invalid_argument("public_exp_share_spec_invalid");
    }
    const std::int32_t from_player = static_cast<std::int32_t>(
        integer_arg(spec, "from_player", -1)
    );
    const std::int32_t to_player = static_cast<std::int32_t>(
        integer_arg(spec, "to_player", -1)
    );
    const std::string from_slot = string_arg(spec, "from_slot");
    const std::string to_slot = string_arg(spec, "to_slot");
    const Value *source = (
        from_player == actor
    ) ? pokemon(player(state, from_player), from_slot) : nullptr;
    const Value *target = (
        to_player == actor
    ) ? pokemon(player(state, to_player), to_slot) : nullptr;
    if (
        from_player != actor
        || to_player != actor
        || from_slot != "active"
        || to_slot.rfind("bench_", 0) != 0
        || source == nullptr
        || target == nullptr
        || string_arg(*source, "card_id")
            != string_arg(spec, "from_card_id")
        || string_arg(*target, "card_id")
            != string_arg(spec, "to_card_id")
        || string_arg(*target, "attached_tool_id")
            != string_arg(spec, "target_tool_id")
        || string_arg(spec, "target_tool_id").empty()
    ) {
        throw std::invalid_argument("public_exp_share_spec_invalid");
    }
}

void suspend_public_exp_share_spec_order(
    GameExecutionResult &result,
    std::int32_t actor,
    std::int32_t attack_actor,
    const Value &continuation,
    Array trigger_specs
) {
    if (trigger_specs.size() < 2 || trigger_specs.size() > 8) {
        throw std::invalid_argument("public_exp_share_order_count_invalid");
    }
    Array options;
    options.reserve(trigger_specs.size());
    for (std::size_t index = 0; index < trigger_specs.size(); ++index) {
        validate_public_exp_share_spec(result.state, actor, trigger_specs[index]);
        options.emplace_back(Object{
            {"kind", Value("id")},
            {"option_id", Value("trigger:" + std::to_string(index))},
        });
    }
    increment(result.state, "choice_sequence");
    result.pending = action_pending(
        "choose_trigger_order",
        actor,
        1,
        1,
        false,
        std::move(options),
        "public_exp_share_spec_order",
        true
    );
    result.continuation = continuation;
    result.continuation["kind"] = Value(
        "public_exp_share_spec_order"
    );
    result.continuation["actor"] = Value(actor);
    result.continuation["attack_actor"] = Value(attack_actor);
    result.continuation["exp_share_trigger_specs"] = Value(
        std::move(trigger_specs)
    );
}

void suspend_public_exp_share_spec_confirmation(
    GameExecutionResult &result,
    std::int32_t actor,
    std::int32_t attack_actor,
    const Value &outer_continuation,
    Value chosen,
    Array remaining
) {
    validate_public_exp_share_spec(result.state, actor, chosen);
    const Value *knockout_entries = outer_continuation.find(
        "knockout_entries"
    );
    if (knockout_entries == nullptr || !knockout_entries->is_array()) {
        throw std::invalid_argument("exp_share_knockout_batch_invalid");
    }
    chosen["knockout_entries"] = *knockout_entries;
    chosen["remaining_exp_share_trigger_specs"] = Value(
        std::move(remaining)
    );
    suspend_exp_share_confirmation(
        result,
        actor,
        attack_actor,
        chosen,
        0,
        false
    );
}

bool continue_public_exp_share_spec_queue(
    GameExecutionResult &result,
    std::int32_t actor,
    std::int32_t attack_actor,
    const Value &continuation
) {
    const Value *remaining_value = continuation.find(
        "remaining_exp_share_trigger_specs"
    );
    if (remaining_value == nullptr) {
        return false;
    }
    if (!remaining_value->is_array()) {
        throw std::invalid_argument("public_exp_share_queue_invalid");
    }
    Array remaining = remaining_value->as_array();
    if (remaining.size() > 8) {
        throw std::invalid_argument("public_exp_share_queue_invalid");
    }
    if (remaining.empty()) {
        return false;
    }
    if (remaining.size() > 1) {
        suspend_public_exp_share_spec_order(
            result,
            actor,
            attack_actor,
            continuation,
            std::move(remaining)
        );
        return true;
    }
    Value chosen = std::move(remaining.front());
    remaining.clear();
    suspend_public_exp_share_spec_confirmation(
        result,
        actor,
        attack_actor,
        continuation,
        std::move(chosen),
        std::move(remaining)
    );
    return true;
}

void continue_after_exp_share_trigger(
    GameExecutionResult &result,
    const Value &cards,
    std::int32_t defeated_owner,
    std::int32_t attack_actor,
    const Value &continuation
) {
    if (continue_public_exp_share_spec_queue(
        result,
        defeated_owner,
        attack_actor,
        continuation
    )) {
        return;
    }
    const std::int64_t remaining = std::max<std::int64_t>(
        0,
        integer_arg(
            continuation,
            "remaining_exp_share_triggers"
        )
    );
    const bool remaining_requires_order = bool_arg(
        continuation,
        "remaining_exp_share_requires_order"
    );
    Value *source = pokemon(
        player(result.state, defeated_owner),
        string_arg(continuation, "from_slot", "active")
    );
    Value *target = pokemon(
        player(result.state, defeated_owner),
        string_arg(continuation, "to_slot")
    );
    const bool basic_energy_available = (
        source != nullptr
        && std::any_of(
            required(*source, "energy_card_ids").as_array().begin(),
            required(*source, "energy_card_ids").as_array().end(),
            [&cards](const Value &entry) {
                return is_basic_energy_id(cards, entry.string_or());
            }
        )
    );
    if (
        remaining > 0
        && basic_energy_available
        && target != nullptr
        && string_arg(*source, "card_id")
            == string_arg(continuation, "from_card_id")
        && string_arg(*target, "card_id")
            == string_arg(continuation, "to_card_id")
        && string_arg(*target, "attached_tool_id")
            == string_arg(continuation, "target_tool_id")
    ) {
        if (remaining_requires_order && remaining > 1) {
            suspend_exp_share_order(
                result,
                defeated_owner,
                attack_actor,
                continuation,
                remaining
            );
        } else {
            suspend_exp_share_confirmation(
                result,
                defeated_owner,
                attack_actor,
                continuation,
                remaining - 1,
                false
            );
        }
        return;
    }

    const Value *knockout_entries = continuation.find(
        "knockout_entries"
    );
    if (knockout_entries != nullptr) {
        if (
            !knockout_entries->is_array()
            || knockout_entries->as_array().empty()
            || knockout_entries->as_array().size() > 12
        ) {
            throw std::invalid_argument(
                "exp_share_knockout_batch_invalid"
            );
        }
        struct PublicKnockout {
            std::int32_t owner = -1;
            std::string slot;
            std::string card_id;
            std::int64_t prize_count = 0;
            std::string source_kind;
        };
        std::vector<PublicKnockout> entries;
        entries.reserve(knockout_entries->as_array().size());
        std::unordered_set<std::string> seen_slots;
        bool source_seen = false;
        for (const Value &entry : knockout_entries->as_array()) {
            const std::int32_t owner =
                static_cast<std::int32_t>(integer_arg(
                    entry,
                    "player_idx",
                    -1
                ));
            const std::string slot = string_arg(entry, "slot");
            const std::string card_id = string_arg(
                entry,
                "card_id"
            );
            const std::int64_t prize_count = integer_arg(
                entry,
                "prize_count",
                -1
            );
            const std::string source_kind = string_arg(
                entry,
                "source_kind",
                owner == defeated_owner && slot == "active"
                    ? "attack_damage" : "attack_effect"
            );
            const std::string key =
                std::to_string(owner) + ":" + slot;
            Value *target = (
                owner == 0 || owner == 1
            ) ? pokemon(player(result.state, owner), slot) : nullptr;
            static const std::unordered_set<std::string> source_kinds = {
                "attack_damage",
                "attack_effect",
                "damage_counters",
                "ability_effect",
                "trainer_effect",
                "effect",
            };
            const std::string actual_source_kind = target == nullptr
                ? std::string{}
                : string_arg(*target, "pending_ko_source_kind");
            if (
                target == nullptr
                || card_id.empty()
                || string_arg(*target, "card_id") != card_id
                || prize_count < 1
                || prize_count > 3
                || prize_count != knockout_prize_value(
                    cards,
                    card_id
                )
                || !seen_slots.insert(key).second
                || pokemon_hp(cards, *target) <= 0
                || integer_arg(*target, "damage_counters") * 10
                    < pokemon_hp(cards, *target)
                || source_kinds.find(source_kind) == source_kinds.end()
                || (
                    !actual_source_kind.empty()
                    && actual_source_kind != source_kind
                )
            ) {
                throw std::invalid_argument(
                    "exp_share_knockout_entry_changed"
                );
            }
            source_seen = source_seen || (
                owner == defeated_owner
                && slot == string_arg(
                    continuation,
                    "from_slot",
                    "active"
                )
                && card_id == string_arg(
                    continuation,
                    "from_card_id"
                )
            );
            entries.push_back(PublicKnockout{
                owner,
                slot,
                card_id,
                prize_count,
                source_kind,
            });
        }
        if (!source_seen) {
            throw std::invalid_argument(
                "exp_share_knockout_source_missing"
            );
        }

        std::array<std::size_t, 2> available_prizes = {
            required(
                player(result.state, 0),
                "prizes"
            ).as_array().size(),
            required(
                player(result.state, 1),
                "prizes"
            ).as_array().size(),
        };
        std::vector<std::int32_t> prize_players;
        for (const PublicKnockout &entry : entries) {
            Value &owner_state = player(result.state, entry.owner);
            const bool attack_damage =
                entry.source_kind == "attack_damage";
            if (attack_damage) {
                owner_state["was_ko_by_attack"] = Value(true);
            }
            append_knockout_fact(
                result.state,
                entry.card_id,
                entry.owner,
                attack_actor,
                attack_damage
                    ? "damage"
                    : (entry.source_kind == "damage_counters"
                        ? "damage_counters" : "effect"),
                entry.source_kind,
                entry.slot
            );
            discard_pokemon(owner_state, entry.slot);
            result.event_types.emplace_back("pokemon_ko");
            result.event_types.emplace_back("card_moved");
            const std::int32_t prize_player = 1 - entry.owner;
            const std::size_t count = std::min<std::size_t>(
                available_prizes[
                    static_cast<std::size_t>(prize_player)
                ],
                static_cast<std::size_t>(entry.prize_count)
            );
            available_prizes[
                static_cast<std::size_t>(prize_player)
            ] -= count;
            prize_players.insert(
                prize_players.end(),
                count,
                prize_player
            );
        }
        queue_promotion_if_possible(
            result.state,
            1 - attack_actor
        );
        queue_promotion_if_possible(result.state, attack_actor);
        const Value finish_continuation = Value(Object{
            {"finish_attack_after_prizes", Value(true)},
            {"resume_attack_actor", Value(attack_actor)},
        });
        if (!prize_players.empty()) {
            suspend_prize_queue(
                result,
                prize_players,
                attack_actor,
                Value::make_object()
            );
            result.continuation["finish_attack_after_prizes"] =
                Value(true);
        } else {
            continue_after_prize_selection(
                result,
                cards,
                finish_continuation
            );
        }
        return;
    }

    finalize_active_knockout(
        result,
        cards,
        defeated_owner,
        attack_actor
    );
    queue_promotion_if_possible(result.state, attack_actor);
    if (
        result.pending.is_object()
        && !result.pending.as_object().empty()
    ) {
        result.continuation["finish_attack_after_prizes"] =
            Value(true);
        result.continuation["resume_attack_actor"] =
            Value(attack_actor);
        return;
    }
    continue_after_prize_selection(
        result,
        cards,
        Value(Object{
            {"finish_attack_after_prizes", Value(true)},
            {"resume_attack_actor", Value(attack_actor)},
        })
    );
}


} // namespace ptcg::ai::game_detail
