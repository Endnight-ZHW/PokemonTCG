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

void append_serialized_modifier(
    Value &target,
    Object descriptor
);

void append_canonical_modifier(
    Value &target,
    const Value &source,
    const std::string &op,
    const Value &args,
    std::int32_t actor,
    const std::string &source_slot,
    std::int32_t target_player,
    std::int64_t turn
) {
    if (op == "prevent_all") {
        append_canonical_modifier(
            target,
            source,
            "prevent_damage",
            args,
            actor,
            source_slot,
            target_player,
            turn
        );
        append_canonical_modifier(
            target,
            source,
            "prevent_effects",
            args,
            actor,
            source_slot,
            target_player,
            turn
        );
        return;
    }
    Value *modifiers = target.find("modifiers");
    if (modifiers == nullptr || !modifiers->is_array()) {
        target["modifiers"] = Value::make_array();
        modifiers = target.find("modifiers");
    } else {
        modifiers->as_array().erase(
            std::remove_if(
                modifiers->as_array().begin(),
                modifiers->as_array().end(),
                [](const Value &entry) {
                    return entry.is_object()
                        && entry.find("native_op") != nullptr;
                }
            ),
            modifiers->as_array().end()
        );
    }
    Object descriptor;
    descriptor["condition"] = Value::make_object();
    descriptor["conflict_policy"] = Value("commutative");
    descriptor["controller"] = Value(target_player);
    descriptor["priority"] = Value(0);
    descriptor["scope"] = Value("self");
    descriptor["source_ref"] = Value(Object{
        {"card_id", Value(string_arg(source, "card_id"))},
        {"kind", Value("pokemon")},
        {"player", Value(actor)},
        {"slot", Value(source_slot)},
    });
    descriptor["stacking"] = Value("replace_same_source");
    if (op == "prevent_damage") {
        descriptor["duration"] = Value("until_end_of_opponents_next_turn");
        descriptor["hook"] = Value("MODIFY_DAMAGE");
        descriptor["layer"] = Value("prevent");
        descriptor["operation"] = Value(Object{
            {"kind", Value("prevent_damage")},
        });
        descriptor["condition"] = Value(Object{
            {"expires_after_turn", Value(turn + 1)},
        });
    } else if (op == "prevent_effects") {
        descriptor["duration"] = Value("until_end_of_opponents_next_turn");
        descriptor["hook"] = Value("PREVENT_EFFECTS");
        descriptor["layer"] = Value("prevent");
        descriptor["operation"] = Value(Object{
            {"kind", Value("prevent_effects")},
        });
        descriptor["condition"] = Value(Object{
            {"expires_after_turn", Value(turn + 1)},
        });
    } else if (op == "apply_attack_lock_basic") {
        descriptor["duration"] = Value("until_end_of_turn");
        descriptor["hook"] = Value("CAN_ATTACK");
        descriptor["layer"] = Value("permission");
        descriptor["operation"] = Value(Object{
            {"attack_name", Value("__all__")},
            {"kind", Value("attack_lock")},
        });
        descriptor["condition"] = Value(Object{
            {"expires_after_turn", Value(turn + 1)},
            {"target_basic", Value(true)},
        });
    } else if (op == "apply_dazzling_beam") {
        descriptor["duration"] = Value("until_next_attack");
        descriptor["hook"] = Value("CAN_ATTACK");
        descriptor["layer"] = Value("gate");
        descriptor["operation"] = Value(Object{
            {"kind", Value("attack_gate_coin")},
            {"reason", Value("dazzled")},
        });
        descriptor["condition"] = Value(Object{
            {"expires_after_turn", Value(turn + 1)},
        });
    } else if (op == "apply_outgoing_damage_reduction") {
        descriptor["duration"] = Value("until_end_of_turn");
        descriptor["hook"] = Value("MODIFY_DAMAGE");
        descriptor["layer"] = Value("attacker_adjust");
        descriptor["operation"] = Value(Object{
            {
                "amount",
                Value(-std::abs(integer_arg(args, "amount")))
            },
            {"kind", Value("damage_delta")},
        });
        descriptor["condition"] = Value(Object{
            {
                "expires_after_turn",
                Value(turn + (target_player == actor ? 0 : 1))
            },
        });
        descriptor["stacking"] = Value("maximum");
    } else if (op == "apply_self_attack_lock") {
        const std::string lock_key = (
            string_arg(args, "scope") == "all"
        ) ? "__all__" : string_arg(args, "attack_name");
        descriptor["duration"] = Value("until_end_of_opponents_next_turn");
        descriptor["hook"] = Value("CAN_ATTACK");
        descriptor["layer"] = Value("permission");
        descriptor["operation"] = Value(Object{
            {"attack_name", Value(lock_key)},
            {"kind", Value("attack_lock")},
        });
        descriptor["condition"] = Value(Object{
            {"expires_after_turn", Value(turn + 2)},
        });
    } else {
        return;
    }
    append_serialized_modifier(target, std::move(descriptor));
}

bool same_modifier_source(
    const Value *left,
    const Value *right
) {
    if (
        left == nullptr
        || right == nullptr
        || !left->is_object()
        || !right->is_object()
    ) {
        return false;
    }
    return string_arg(*left, "kind") == string_arg(*right, "kind")
        && integer_arg(*left, "player", -1)
            == integer_arg(*right, "player", -1)
        && string_arg(*left, "slot") == string_arg(*right, "slot")
        && string_arg(*left, "card_id")
            == string_arg(*right, "card_id");
}

void append_serialized_modifier(
    Value &target,
    Object descriptor
) {
    Value *modifiers = target.find("modifiers");
    if (modifiers == nullptr || !modifiers->is_array()) {
        target["modifiers"] = Value::make_array();
        modifiers = target.find("modifiers");
    }
    const Value descriptor_value(std::move(descriptor));
    const Value *operation = descriptor_value.find("operation");
    const Value *source_ref = descriptor_value.find("source_ref");
    const std::string operation_kind = operation == nullptr
        ? std::string{}
        : string_arg(*operation, "kind");
    const std::string stacking = string_arg(
        descriptor_value,
        "stacking"
    );
    if (stacking == "maximum") {
        const std::int64_t candidate = operation == nullptr
            ? 0
            : std::abs(integer_arg(*operation, "amount"));
        const bool stronger_exists = std::any_of(
            modifiers->as_array().begin(),
            modifiers->as_array().end(),
            [&operation_kind, candidate](const Value &entry) {
                const Value *existing = entry.find("operation");
                return existing != nullptr
                    && existing->is_object()
                    && string_arg(*existing, "kind")
                        == operation_kind
                    && std::abs(integer_arg(*existing, "amount"))
                        >= candidate;
            }
        );
        if (stronger_exists) {
            return;
        }
        modifiers->as_array().erase(
            std::remove_if(
                modifiers->as_array().begin(),
                modifiers->as_array().end(),
                [&operation_kind](const Value &entry) {
                    const Value *existing = entry.find("operation");
                    return existing != nullptr
                        && existing->is_object()
                        && string_arg(*existing, "kind")
                            == operation_kind;
                }
            ),
            modifiers->as_array().end()
        );
        modifiers->as_array().push_back(descriptor_value);
        return;
    }
    modifiers->as_array().erase(
        std::remove_if(
            modifiers->as_array().begin(),
            modifiers->as_array().end(),
            [&operation_kind, source_ref](const Value &entry) {
                const Value *existing_operation = entry.find("operation");
                return entry.is_object()
                    && existing_operation != nullptr
                    && string_arg(*existing_operation, "kind")
                        == operation_kind
                    && same_modifier_source(
                        entry.find("source_ref"),
                        source_ref
                    );
            }
        ),
        modifiers->as_array().end()
    );
    modifiers->as_array().push_back(descriptor_value);
}

void canonicalize_vm_modifiers(
    Value &state,
    std::int32_t actor,
    const std::string &source_slot
) {
    static const std::unordered_set<std::string> canonical_ops = {
        "apply_attack_lock_basic",
        "apply_dazzling_beam",
        "apply_outgoing_damage_reduction",
        "apply_self_attack_lock",
        "prevent_all",
        "prevent_damage",
        "prevent_effects",
    };
    const Value *source = pokemon(player(state, actor), source_slot);
    const Value source_snapshot = source == nullptr
        ? Value::make_object()
        : *source;
    const std::array<std::string, 6> slots = {
        "active",
        "bench_0",
        "bench_1",
        "bench_2",
        "bench_3",
        "bench_4",
    };
    for (std::int32_t owner = 0; owner < 2; ++owner) {
        for (const std::string &slot : slots) {
            Value *target = pokemon(player(state, owner), slot);
            if (target == nullptr) {
                continue;
            }
            Value *modifiers = target->find("modifiers");
            if (modifiers == nullptr || !modifiers->is_array()) {
                continue;
            }
            std::vector<std::pair<std::string, Value>> pending;
            Array retained;
            for (const Value &entry : modifiers->as_array()) {
                const std::string op = entry.is_object()
                    ? string_arg(entry, "native_op")
                    : std::string{};
                if (canonical_ops.find(op) == canonical_ops.end()) {
                    retained.push_back(entry);
                    continue;
                }
                const Value *args = entry.find("args");
                pending.emplace_back(
                    op,
                    args != nullptr && args->is_object()
                        ? *args
                        : Value::make_object()
                );
            }
            if (pending.empty()) {
                continue;
            }
            *modifiers = Value(std::move(retained));
            const Value &modifier_source = source_snapshot.is_object()
                && !string_arg(source_snapshot, "card_id").empty()
                ? source_snapshot
                : *target;
            for (const auto &[op, args] : pending) {
                append_canonical_modifier(
                    *target,
                    modifier_source,
                    op,
                    args,
                    actor,
                    source_slot,
                    owner,
                    integer_arg(state, "turn_number")
                );
            }
        }
    }
}

void append_tool_modifiers(
    Value &target,
    const Value &definition,
    std::int32_t actor,
    const std::string &slot
) {
    const Value *effects = definition.find("compiled_trainer_effects");
    if (effects == nullptr || !effects->is_array()) {
        return;
    }
    for (const Value &effect : effects->as_array()) {
        if (string_arg(effect, "op") != "register_tool_modifier") {
            continue;
        }
        const Value *args_ptr = effect.find("args");
        const Value empty_args = Value::make_object();
        const Value &args = (
            args_ptr != nullptr && args_ptr->is_object()
        ) ? *args_ptr : empty_args;
        const std::string effect_name = string_arg(args, "effect");
        Object condition;
        Object operation;
        std::string hook;
        std::string layer;
        std::string scope = "self";
        if (effect_name == "damage_boost_10") {
            hook = "MODIFY_DAMAGE";
            layer = "attacker_adjust";
            scope = "attached_attacker";
            condition["target_active"] = Value(true);
            operation["amount"] = Value(10);
            operation["kind"] = Value("damage_delta");
        } else if (effect_name == "damage_boost_when_behind") {
            hook = "MODIFY_DAMAGE";
            layer = "attacker_adjust";
            scope = "attached_attacker";
            condition["behind_on_prizes"] = Value(true);
            condition["target_active"] = Value(true);
            operation["amount"] = Value(30);
            operation["kind"] = Value("damage_delta");
        } else if (effect_name == "damage_reduction_stage1") {
            hook = "MODIFY_DAMAGE";
            layer = "defender_adjust";
            scope = "attached_defender";
            condition["target_stage"] = Value("stage1");
            operation["amount"] = Value(
                -std::abs(integer_arg(args, "amount", 30))
            );
            operation["kind"] = Value("damage_delta");
        } else if (effect_name == "hp_boost_basic") {
            hook = "MAX_HP";
            layer = "add";
            condition["target_basic"] = Value(true);
            operation["amount"] = Value(
                integer_arg(args, "amount", 50)
            );
            operation["kind"] = Value("hp_delta");
        } else {
            continue;
        }
        Object descriptor;
        descriptor["condition"] = Value(std::move(condition));
        descriptor["conflict_policy"] = Value("commutative");
        descriptor["controller"] = Value(actor);
        descriptor["duration"] = Value("until_leave_play");
        descriptor["hook"] = Value(std::move(hook));
        descriptor["layer"] = Value(std::move(layer));
        descriptor["operation"] = Value(std::move(operation));
        descriptor["priority"] = Value(
            integer_arg(args, "priority", 0)
        );
        descriptor["scope"] = Value(std::move(scope));
        descriptor["source_ref"] = Value(Object{
            {"card_id", Value(string_arg(target, "card_id"))},
            {"kind", Value("pokemon")},
            {"player", Value(actor)},
            {"slot", Value(slot)},
        });
        descriptor["stacking"] = Value("replace_same_source");
        append_serialized_modifier(target, std::move(descriptor));
    }
}

bool replaces_attack_damage(const std::string &op) {
    return op == "conditional_damage_then_heal"
        || op == "deal_damage"
        || op == "deal_damage_then_heal"
        || op.rfind("deal_damage_per_", 0) == 0
        || op == "deal_damage_plus_bench"
        || op == "deal_damage_with_self_penalty"
        || op == "discard_energy_then_damage"
        || op == "discard_hand_then_damage"
        || op == "flip_coin_repeat_damage"
        || op == "flip_until_tails"
        || op == "mill_then_damage"
        || op == "set_attack_damage_formula";
}

const Value *find_named_ability(
    const Value &definition,
    const std::string &name
) {
    const Value *abilities = definition.find("abilities");
    if (abilities == nullptr || !abilities->is_array()) {
        return nullptr;
    }
    const auto found = std::find_if(
        abilities->as_array().begin(),
        abilities->as_array().end(),
        [&name](const Value &ability) {
            return string_arg(ability, "name") == name;
        }
    );
    return found == abilities->as_array().end() ? nullptr : &*found;
}

Value canonical_params(const Value &action, const std::string &kind) {
    const Value *value = action.find("params");
    Value result = value != nullptr && value->is_object()
        ? *value
        : Value::make_object();
    const Value *payload = action.find("payload");
    if (payload != nullptr && payload->is_object()) {
        result = *payload;
    }
    const Value *source = action.find("source");
    const Value *target = action.find("target");
    if (
        source != nullptr
        && source->is_object()
        && string_arg(*source, "zone") == "hand"
    ) {
        result["hand_idx"] = Value(integer_arg(*source, "index", -1));
    }
    const std::string target_slot = (
        target != nullptr && target->is_object()
    ) ? string_arg(*target, "slot") : std::string{};
    if (kind == "PLAY_BASIC" && !target_slot.empty()) {
        result["target"] = Value(target_slot);
    } else if (kind == "EVOLVE" && !target_slot.empty()) {
        result["slot"] = Value(target_slot);
    } else if (
        kind == "ATTACH_ENERGY"
        || kind == "PLAY_TRAINER"
    ) {
        if (!target_slot.empty()) {
            result["target_slot"] = Value(target_slot);
        }
    } else if (kind == "USE_ABILITY" && source != nullptr
        && source->is_object()) {
        if (string_arg(*source, "zone") == "discard") {
            result["slot"] = Value(
                "discard_"
                + std::to_string(integer_arg(*source, "index", -1))
            );
        } else {
            result["slot"] = Value(string_arg(*source, "slot"));
        }
    } else if (
        (kind == "RETREAT" || kind == "PROMOTE")
        && target_slot.rfind("bench_", 0) == 0
    ) {
        result["bench_idx"] = Value(
            static_cast<std::int64_t>(std::stoll(
                target_slot.substr(6)
            ))
        );
    } else if (kind == "DECLARE_ATTACK") {
        result["attack_idx"] = Value(integer_arg(
            result,
            "attack_index",
            integer_arg(result, "attack_idx", -1)
        ));
    }
    return result;
}

void attach_game_continuation(
    GameExecutionResult &result,
    const VmExecutionResult &vm,
    std::int32_t actor,
    bool finish_attack,
    Value remaining,
    std::string source_slot,
    std::string context_mode
) {
    result.pending = vm.pending;
    Value *metadata = result.pending.find("metadata");
    if (metadata == nullptr || !metadata->is_object()) {
        result.pending["metadata"] = Value::make_object();
        metadata = result.pending.find("metadata");
    }
    (*metadata)["continuation_kind"] = Value(
        string_arg(result.pending, "continuation_kind")
    );
    if (finish_attack) {
        (*metadata)["finish_attack_actor"] = Value(actor);
    }
    result.pending.erase("continuation_kind");
    Object continuation;
    continuation["kind"] = Value("vm");
    continuation["actor"] = Value(actor);
    continuation["finish_attack"] = Value(finish_attack);
    continuation["vm"] = vm.continuation;
    continuation["context"] = vm.context;
    continuation["remaining_effects"] = std::move(remaining);
    continuation["source_slot"] = Value(std::move(source_slot));
    continuation["context_mode"] = Value(std::move(context_mode));
    result.continuation = Value(std::move(continuation));
}

Value remaining_effects(
    const Array &effects,
    std::size_t first
) {
    Array result;
    if (first >= effects.size()) {
        return Value(std::move(result));
    }
    result.reserve(effects.size() - first);
    for (std::size_t index = first; index < effects.size(); ++index) {
        result.push_back(effects[index]);
    }
    return Value(std::move(result));
}

std::int64_t calculated_attack_damage(
    const Value &state,
    const Value &cards,
    std::int32_t actor,
    const Value &context
) {
    if (
        bool_arg(context, "attack_failed")
        || bool_arg(context, "damage_applied")
    ) {
        return 0;
    }
    const Value *attacker = pokemon(
        player(state, actor),
        "active"
    );
    const Value *defender = pokemon(
        player(state, 1 - actor),
        "active"
    );
    if (defender == nullptr) {
        return 0;
    }
    const std::int64_t base_damage = integer_arg(
        context,
        "base_damage"
    );
    if (base_damage <= 0) {
        return 0;
    }
    std::int64_t damage = std::max<std::int64_t>(
        0,
        base_damage
            + (
                attacker == nullptr
                ? 0
                : attached_attack_damage_delta(
                    cards,
                    state,
                    actor,
                    *attacker,
                    true
                )
            )
            + (
                attacker == nullptr
                ? 0
                : field_aura_attack_damage_delta(
                    cards,
                    state,
                    actor,
                    *attacker,
                    *defender,
                    true
                )
            )
            + (
                bool_arg(context, "ignore_defender_damage_effects")
                ? 0
                : aura_damage_reduction_delta(
                    cards,
                    *defender,
                    true,
                    true
                )
            )
            + (
                bool_arg(context, "ignore_defender_damage_effects")
                ? 0
                : opponent_active_aura_attack_damage_delta(
                    cards,
                    state,
                    actor,
                    true
                )
            )
    );
    if (attacker != nullptr) {
        damage = apply_active_type_matchups(
            cards,
            state,
            *attacker,
            *defender,
            damage,
            bool_arg(context, "ignore_weakness"),
            bool_arg(context, "ignore_resistance")
        );
    }
    if (!bool_arg(context, "ignore_defender_damage_effects")) {
        damage = std::max<std::int64_t>(
            0,
            damage + attached_defender_damage_delta(
                cards,
                *defender,
                true
            )
        );
        if (defender_prevents_attack_damage(*defender)) {
            damage = 0;
        }
    }
    return damage;
}

std::int64_t after_damage_energy_draw_count(
    const Value &cards,
    const Value *holder,
    const std::string &scope,
    std::int64_t damage
) {
    if (holder == nullptr || damage <= 0) {
        return 0;
    }
    const Value *energy = holder->find("energy_card_ids");
    if (energy == nullptr || !energy->is_array()) {
        return 0;
    }
    std::int64_t draw_count = 0;
    for (const Value &energy_id : energy->as_array()) {
        const Value *definition = card_definition(
            cards,
            energy_id.string_or()
        );
        const Value *effects = definition == nullptr
            ? nullptr
            : definition->find("energy_effects");
        if (effects == nullptr || !effects->is_array()) {
            continue;
        }
        for (const Value &descriptor : effects->as_array()) {
            if (
                string_arg(descriptor, "kind") != "trigger"
                || string_arg(descriptor, "hook") != "AFTER_DAMAGE"
            ) {
                continue;
            }
            const Value *condition = descriptor.find("condition");
            const Value *effect = descriptor.find("effect");
            if (
                condition == nullptr
                || !condition->is_object()
                || effect == nullptr
                || !effect->is_object()
                || string_arg(*condition, "scope") != scope
                || damage < integer_arg(*condition, "min_damage", 1)
                || string_arg(*effect, "op") != "draw_cards"
            ) {
                continue;
            }
            draw_count += std::max<std::int64_t>(
                0,
                integer_arg(*effect, "amount")
            );
        }
    }
    return draw_count;
}

void apply_attack_damage_before_effect(
    GameExecutionResult &result,
    const Value &cards,
    std::int32_t actor,
    Value &context
) {
    struct DamageTarget {
        std::int32_t player;
        std::string slot;
        std::int64_t amount;
        std::int64_t calculated = 0;
    };
    std::vector<DamageTarget> targets;
    const std::int64_t base_damage = integer_arg(context, "base_damage");
    if (base_damage > 0) {
        targets.push_back(DamageTarget{
            1 - actor,
            "active",
            base_damage,
        });
    }
    const Value *packets = context.find("damage_packets");
    if (packets != nullptr && packets->is_array()) {
        for (const Value &packet : packets->as_array()) {
            const std::int32_t target_player =
                static_cast<std::int32_t>(integer_arg(
                    packet,
                    "target_player",
                    1 - actor
                ));
            const std::string target_slot = string_arg(
                packet,
                "target_slot",
                "active"
            );
            const std::int64_t amount = std::max<std::int64_t>(
                0,
                integer_arg(packet, "amount")
            );
            const auto existing = std::find_if(
                targets.begin(),
                targets.end(),
                [target_player, &target_slot](const DamageTarget &target) {
                    return target.player == target_player
                        && target.slot == target_slot;
                }
            );
            if (existing == targets.end()) {
                targets.push_back(DamageTarget{
                    target_player,
                    target_slot,
                    amount,
                });
            } else {
                existing->amount += amount;
            }
        }
    }
    const Value *attacker = pokemon(
        player(result.state, actor),
        "active"
    );
    for (DamageTarget &target : targets) {
        Value *defender = (
            target.player == 0 || target.player == 1
        ) ? pokemon(
            player(result.state, target.player),
            target.slot
        ) : nullptr;
        if (defender == nullptr || target.amount <= 0) {
            continue;
        }
        Value packet_context = context;
        packet_context["base_damage"] = Value(target.amount);
        packet_context["damage_applied"] = Value(false);
        target.calculated = calculated_attack_damage(
            result.state,
            cards,
            actor,
            packet_context
        );
        if (target.slot != "active" || target.player != 1 - actor) {
            std::int64_t damage = std::max<std::int64_t>(
                0,
                target.amount
                    + (
                        attacker == nullptr
                        ? 0
                        : attached_attack_damage_delta(
                            cards,
                            result.state,
                            actor,
                            *attacker,
                            false
                        )
                    )
                    + (
                        bool_arg(
                            context,
                            "ignore_defender_damage_effects"
                        )
                        ? 0
                        : opponent_active_aura_attack_damage_delta(
                            cards,
                            result.state,
                            actor,
                            true
                        )
                    )
            );
            if (!bool_arg(
                context,
                "ignore_defender_damage_effects"
            )) {
                damage = std::max<std::int64_t>(
                    0,
                    damage + attached_defender_damage_delta(
                        cards,
                        *defender,
                        false
                    )
                );
                if (defender_prevents_attack_damage(*defender)) {
                    damage = 0;
                }
            }
            target.calculated = damage;
        }
    }
    std::int64_t active_damage = 0;
    for (const DamageTarget &target : targets) {
        Value *defender = (
            target.player == 0 || target.player == 1
        ) ? pokemon(
            player(result.state, target.player),
            target.slot
        ) : nullptr;
        if (defender == nullptr || target.calculated <= 0) {
            continue;
        }
        if (target.player == 1 - actor && target.slot == "active") {
            active_damage += target.calculated;
            context["after_damage_draw_attacker"] = Value(
                after_damage_energy_draw_count(
                    cards,
                    attacker,
                    "attached_attacker",
                    target.calculated
                )
            );
            context["after_damage_draw_defender"] = Value(
                after_damage_energy_draw_count(
                    cards,
                    defender,
                    "attached_defender",
                    target.calculated
                )
            );
        }
        const std::int64_t maximum_hp = pokemon_hp(cards, *defender);
        add_damage(*defender, target.calculated);
        if (
            maximum_hp > 0
            && integer_arg(*defender, "damage_counters") * 10
                >= maximum_hp
            && defender->find("pending_ko_source_kind") == nullptr
        ) {
            (*defender)["pending_ko_source_kind"] = Value(
                "attack_damage"
            );
        }
        result.event_types.emplace_back("damage_dealt");
        append_event(result, "damage_dealt", Object{
            {"actor", Value(actor)},
            {"player", Value(target.player)},
            {"target_player", Value(target.player)},
            {"target_slot", Value(target.slot)},
            {"slot", Value(target.slot)},
            {"amount", Value(target.calculated)},
            {"counter_count", Value((target.calculated + 9) / 10)},
            {"damage_kind", Value("attack_damage")},
            {"visibility", Value("public")},
        });
    }
    if (!targets.empty()) {
        Value *mutable_attacker = pokemon(
            player(result.state, actor),
            "active"
        );
        if (mutable_attacker != nullptr) {
            (*mutable_attacker)["outgoing_damage_reduction"] = Value(0);
        }
    }
    context.erase("damage_packets");
    context["final_damage"] = Value(active_damage);
    context["damage_applied"] = Value(true);
}

void apply_reactive_thorns(
    GameExecutionResult &result,
    const Value &cards,
    std::int32_t actor,
    Value &context
) {
    if (
        bool_arg(context, "reactive_thorns_applied")
        || integer_arg(context, "final_damage") <= 0
    ) {
        return;
    }
    context["reactive_thorns_applied"] = Value(true);
    Value &defending_player = player(result.state, 1 - actor);
    Value *defender = pokemon(defending_player, "active");
    Value *attacker = pokemon(player(result.state, actor), "active");
    if (defender == nullptr || attacker == nullptr) {
        return;
    }
    const Value *definition = card_definition(
        cards,
        string_arg(*defender, "card_id")
    );
    const Value *abilities = definition == nullptr
        ? nullptr
        : definition->find("abilities");
    if (abilities == nullptr || !abilities->is_array()) {
        return;
    }
    for (const Value &ability : abilities->as_array()) {
        const Value *effects = ability.find("compiled_effects");
        if (effects == nullptr || !effects->is_array()) {
            continue;
        }
        for (const Value &effect : effects->as_array()) {
            if (string_arg(effect, "op") != "register_reactive_thorns") {
                continue;
            }
            const Value *args = effect.find("args");
            if (args == nullptr || !args->is_object()) {
                continue;
            }
            const Value *names = args->find("filter_names");
            std::int64_t matching = 0;
            const std::array<std::string, 6> slots = {
                "active",
                "bench_0",
                "bench_1",
                "bench_2",
                "bench_3",
                "bench_4",
            };
            for (const std::string &slot : slots) {
                const Value *candidate = pokemon(defending_player, slot);
                const Value *candidate_definition = candidate == nullptr
                    ? nullptr
                    : card_definition(
                        cards,
                        string_arg(*candidate, "card_id")
                    );
                if (
                    candidate_definition != nullptr
                    && array_contains_string(
                        names,
                        string_arg(*candidate_definition, "name")
                    )
                ) {
                    ++matching;
                }
            }
            if (matching > 0) {
                const std::int64_t amount = matching
                    * integer_arg(*args, "per_pokemon", 3) * 10;
                const std::int64_t maximum_hp = pokemon_hp(cards, *attacker);
                const bool was_knocked_out = maximum_hp > 0
                    && integer_arg(*attacker, "damage_counters") * 10
                        >= maximum_hp;
                add_damage(
                    *attacker,
                    amount
                );
                if (
                    !was_knocked_out
                    && maximum_hp > 0
                    && integer_arg(*attacker, "damage_counters") * 10
                        >= maximum_hp
                    && attacker->find("pending_ko_source_kind") == nullptr
                ) {
                    (*attacker)["pending_ko_source_kind"] = Value(
                        "damage_counters");
                }
                result.event_types.emplace_back(
                    "damage_counters_placed"
                );
                append_event(result, "damage_counters_placed", Object{
                    {"actor", Value(1 - actor)},
                    {"player", Value(actor)},
                    {"target_player", Value(actor)},
                    {"target_slot", Value("active")},
                    {"slot", Value("active")},
                    {"amount", Value(amount)},
                    {"counter_count", Value((amount + 9) / 10)},
                    {"damage_kind", Value("damage_counters")},
                    {"visibility", Value("public")},
                });
            }
            return;
        }
    }
}

bool attack_effect_runs_before_damage(
    const std::string &op,
    const Value &args
) {
    if (op == "deal_damage") {
        return string_arg(
            args,
            "target",
            "opponent_active"
        ) != "self";
    }
    static const std::unordered_set<std::string> before_damage = {
        "choose_damage_target",
        "conditional_damage",
        "conditional_damage_then_heal",
        "deal_damage_per_discard_psychic",
        "deal_damage_per_energy",
        "deal_damage_per_evolved",
        "deal_damage_per_hand_size",
        "deal_damage_per_self_damage",
        "deal_damage_per_self_energy",
        "deal_damage_per_self_energy_type",
        "deal_damage_then_heal",
        "deal_damage_with_self_penalty",
        "deal_bench_damage",
        "discard_energy_then_damage",
        "discard_hand_then_damage",
        "fail_attack",
        "flip_coin",
        "flip_coin_repeat_damage",
        "flip_coin_then_ko",
        "flip_until_tails",
        "mill_then_damage",
        "set_attack_damage_formula",
        "set_attack_flags",
    };
    return before_damage.find(op) != before_damage.end();
}

void finish_attack_resolution(
    GameExecutionResult &result,
    const Value &cards,
    std::int32_t actor,
    Value &context
) {
    if (
        !bool_arg(context, "attack_failed")
        && !bool_arg(context, "damage_applied")
    ) {
        apply_attack_damage_before_effect(
            result,
            cards,
            actor,
            context
        );
    }
    if (!bool_arg(context, "after_damage_triggers_applied")) {
        const std::array groups{
            std::pair{
                actor,
                integer_arg(context, "after_damage_draw_attacker")
            },
            std::pair{
                1 - actor,
                integer_arg(context, "after_damage_draw_defender")
            },
        };
        context["after_damage_triggers_applied"] = Value(true);
        for (std::size_t group_index = 0;
             group_index < groups.size();
             ++group_index) {
            const auto [owner, count] = groups[group_index];
            // Lucky Energy copies all perform the same mandatory draw. Their
            // relative order cannot change the state, so resolve the full group
            // directly instead of asking the player to rank identical effects.
            for (std::int64_t index = 0; index < count; ++index) {
                draw_one_with_payload(
                    result, owner, "after_damage_trigger");
            }
        }
    }
    apply_reactive_thorns(result, cards, actor, context);

    struct KnockoutEntry {
        std::int32_t owner;
        std::string slot;
        std::string card_id;
        std::int64_t prize_value;
        std::string source_kind;
    };
    std::vector<KnockoutEntry> knockout_entries;
    for (const std::int32_t owner : {1 - actor, actor}) {
        Value &owner_state = player(result.state, owner);
        const std::array<std::string, 6> slots = {
            "active",
            "bench_0",
            "bench_1",
            "bench_2",
            "bench_3",
            "bench_4",
        };
        for (const std::string &slot : slots) {
            Value *target = pokemon(owner_state, slot);
            if (
                target == nullptr
                || pokemon_hp(cards, *target) <= 0
                || integer_arg(*target, "damage_counters") * 10
                    < pokemon_hp(cards, *target)
            ) {
                continue;
            }
            const std::string defeated_id = string_arg(
                *target,
                "card_id"
            );
            const Value *definition = card_definition(
                cards,
                defeated_id
            );
            knockout_entries.push_back(KnockoutEntry{
                owner,
                slot,
                defeated_id,
                std::max<std::int64_t>(
                    1,
                    definition == nullptr
                        ? 1
                        : integer_arg(*definition, "prize_value", 1)
                ),
                string_arg(
                    *target,
                    "pending_ko_source_kind",
                    "attack_effect"
                ),
            });
        }
    }
    if (suspend_exp_share_trigger_if_available(result, cards, actor)) {
        return;
    }
    if (knockout_entries.size() > 1) {
        std::array<std::size_t, 2> prizes_remaining = {
            required(player(result.state, 0), "prizes").as_array().size(),
            required(player(result.state, 1), "prizes").as_array().size(),
        };
        std::vector<std::int32_t> prize_players;
        for (const KnockoutEntry &entry : knockout_entries) {
            Value &owner_state = player(result.state, entry.owner);
            const bool attack_damage = entry.source_kind == "attack_damage";
            if (attack_damage) {
                owner_state["was_ko_by_attack"] = Value(true);
            }
            append_knockout_fact(
                result.state,
                entry.card_id,
                entry.owner,
                actor,
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
            for (
                std::int64_t prize = 0;
                prize < entry.prize_value
                && prizes_remaining[static_cast<std::size_t>(
                    1 - entry.owner)] > 0;
                ++prize
            ) {
                prize_players.push_back(1 - entry.owner);
                --prizes_remaining[static_cast<std::size_t>(
                    1 - entry.owner)];
            }
        }
        queue_promotion_if_possible(result.state, 1 - actor);
        queue_promotion_if_possible(result.state, actor);
        if (!prize_players.empty()) {
            suspend_prize_queue(
                result,
                prize_players,
                actor,
                context
            );
        } else {
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
                            Value(integer_arg(
                                result.state,
                                "winner",
                                -1
                            )),
                        },
                        {
                            "result_status",
                            Value(string_arg(
                                result.state,
                                "result_status"
                            )),
                        },
                        {"reason", Value("knockout")},
                        {
                            "conditions",
                            required(
                                result.state,
                                "result_conditions"
                            ),
                        },
                    }
                );
            }
        }
        return;
    }

    std::vector<std::int32_t> bench_prize_players;
    for (std::int32_t owner = 0; owner < 2; ++owner) {
        Value &owner_state = player(result.state, owner);
        Array &bench = required(owner_state, "bench").as_array();
        for (std::size_t index = 0; index < bench.size(); ++index) {
            if (
                !bench[index].is_object()
                || pokemon_hp(cards, bench[index]) <= 0
                || integer_arg(
                    bench[index],
                    "damage_counters"
                ) * 10 < pokemon_hp(cards, bench[index])
            ) {
                continue;
            }
            const std::string slot =
                "bench_" + std::to_string(index);
            const std::string defeated_id = string_arg(
                bench[index],
                "card_id"
            );
            const std::string source_kind = string_arg(
                bench[index],
                "pending_ko_source_kind",
                "attack_effect"
            );
            const bool attack_damage = source_kind == "attack_damage";
            const Value *definition = card_definition(
                cards,
                defeated_id
            );
            const std::int64_t prize_value = std::max<std::int64_t>(
                1,
                definition == nullptr
                    ? 1
                    : integer_arg(*definition, "prize_value", 1)
            );
            if (attack_damage) {
                owner_state["was_ko_by_attack"] = Value(true);
            }
            append_knockout_fact(
                result.state,
                defeated_id,
                owner,
                actor,
                attack_damage
                    ? "damage"
                    : (source_kind == "damage_counters"
                        ? "damage_counters" : "effect"),
                source_kind,
                slot
            );
            discard_pokemon(owner_state, slot);
            result.event_types.emplace_back("pokemon_ko");
            result.event_types.emplace_back("card_moved");
            const std::size_t available_prizes = required(
                player(result.state, 1 - owner), "prizes").as_array().size();
            const std::size_t prizes_to_take = std::min<std::size_t>(
                available_prizes,
                static_cast<std::size_t>(prize_value)
            );
            for (std::size_t prize = 0; prize < prizes_to_take; ++prize) {
                bench_prize_players.push_back(1 - owner);
            }
        }
    }
    if (!bench_prize_players.empty()) {
        suspend_prize_queue(
            result,
            bench_prize_players,
            actor,
            context
        );
        return;
    }

    Value *attacker = pokemon(player(result.state, actor), "active");
    if (
        attacker != nullptr
        && pokemon_hp(cards, *attacker) > 0
        && integer_arg(*attacker, "damage_counters") * 10
            >= pokemon_hp(cards, *attacker)
    ) {
        const std::string defeated_id = string_arg(*attacker, "card_id");
        const std::string source_kind = string_arg(
            *attacker, "pending_ko_source_kind", "attack_effect");
        discard_active(player(result.state, actor));
        queue_promotion_if_possible(result.state, actor);
        append_knockout_fact(
            result.state,
            defeated_id,
            actor,
            actor,
            source_kind == "damage_counters"
                ? "damage_counters" : "effect",
            source_kind
        );
        result.event_types.emplace_back("pokemon_ko");
        result.event_types.emplace_back("card_moved");
        suspend_knockout_prizes(
            result,
            cards,
            defeated_id,
            1 - actor
        );
        return;
    }
    Value *defender = pokemon(player(result.state, 1 - actor), "active");
    if (
        defender != nullptr
        && pokemon_hp(cards, *defender) > 0
        && integer_arg(*defender, "damage_counters") * 10
            >= pokemon_hp(cards, *defender)
    ) {
        const std::string source_kind = string_arg(
            *defender,
            "pending_ko_source_kind",
            "attack_effect"
        );
        const bool attack_damage = source_kind == "attack_damage";
        Array &pending = required(
            result.state,
            "pending_promotions"
        ).as_array();
        pending.erase(
            std::remove_if(
                pending.begin(),
                pending.end(),
                [actor](const Value &entry) {
                    return entry.as_integer(-1) == actor;
                }
            ),
            pending.end()
        );
        const Array &defending_bench = required(
            player(result.state, 1 - actor),
            "bench"
        ).as_array();
        if (std::any_of(
            defending_bench.begin(),
            defending_bench.end(),
            [](const Value &entry) { return entry.is_object(); }
        )) {
            pending.emplace_back(1 - actor);
        }
        queue_promotion_if_possible(result.state, actor);
        const std::string defeated_id = string_arg(
            *defender,
            "card_id"
        );
        discard_active(player(result.state, 1 - actor));
        if (attack_damage) {
            player(result.state, 1 - actor)["was_ko_by_attack"] =
                Value(true);
        }
        queue_promotion_if_possible(result.state, 1 - actor);
        append_knockout_fact(
            result.state,
            defeated_id,
            1 - actor,
            actor,
            attack_damage
                ? "damage"
                : (source_kind == "damage_counters"
                    ? "damage_counters" : "effect"),
            source_kind
        );
        result.event_types.emplace_back("pokemon_ko");
        result.event_types.emplace_back("card_moved");
        suspend_knockout_prizes(
            result,
            cards,
            defeated_id,
            actor
        );
        if (pokemon(player(result.state, actor), "active") == nullptr) {
            const Array &attacking_bench = required(
                player(result.state, actor),
                "bench"
            ).as_array();
            if (std::any_of(
                attacking_bench.begin(),
                attacking_bench.end(),
                [](const Value &entry) { return entry.is_object(); }
            )) {
                Array &pending = required(
                    result.state,
                    "pending_promotions"
                ).as_array();
                if (std::none_of(
                    pending.begin(),
                    pending.end(),
                    [actor](const Value &entry) {
                        return entry.as_integer(-1) == actor;
                    }
                )) {
                    pending.emplace_back(actor);
                }
            }
        }
        return;
    }
    if (
        pokemon(player(result.state, actor), "active") == nullptr
    ) {
        queue_promotion_if_possible(result.state, actor);
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
                        Value(integer_arg(
                            result.state,
                            "winner",
                            -1
                        )),
                    },
                    {
                        "result_status",
                        Value(string_arg(
                            result.state,
                            "result_status"
                        )),
                    },
                    {"reason", Value("knockout")},
                    {
                        "conditions",
                        required(
                            result.state,
                            "result_conditions"
                        ),
                    },
                }
            );
        }
        return;
    }
    const Value *promotions = result.state.find("pending_promotions");
    if (
        promotions != nullptr
        && promotions->is_array()
        && !promotions->as_array().empty()
    ) {
        return;
    }
    if (finalize_terminal_if_needed(result)) {
        return;
    }
    finish_turn(result, cards, actor);
}

} // namespace ptcg::ai::game_detail
