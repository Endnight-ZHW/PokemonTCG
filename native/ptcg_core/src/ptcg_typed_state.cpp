#include "ptcg_typed_state.hpp"

#include <algorithm>
#include <limits>
#include <stdexcept>
#include <utility>

namespace ptcg::ai::typed {

namespace {

using Array = Value::Array;
using Object = Value::Object;

const Value *field(const Value &value, const std::string &key) noexcept {
    return value.find(key);
}

std::string string_field(
    const Value &value,
    const std::string &key,
    std::string fallback = {}
) {
    const Value *item = field(value, key);
    return item != nullptr && item->is_string()
        ? item->as_string() : std::move(fallback);
}

std::int64_t integer_field(
    const Value &value,
    const std::string &key,
    std::int64_t fallback = 0
) noexcept {
    const Value *item = field(value, key);
    return item != nullptr && item->is_number()
        ? item->as_integer(fallback) : fallback;
}

bool bool_field(
    const Value &value,
    const std::string &key,
    bool fallback = false
) noexcept {
    const Value *item = field(value, key);
    return item != nullptr && item->is_bool()
        ? item->as_bool(fallback) : fallback;
}

bool fail(std::string *error, const std::string &message) {
    if (error != nullptr) {
        *error = message;
    }
    return false;
}

Phase phase_from_string(const std::string &value) {
    if (value == "SETUP") return Phase::setup;
    if (value == "DRAW") return Phase::draw;
    if (value == "MAIN") return Phase::main;
    if (value == "ATTACK") return Phase::attack;
    if (value == "POKEMON_CHECKUP" || value == "CHECKUP") {
        return Phase::checkup;
    }
    if (value == "GAME_OVER") return Phase::game_over;
    throw std::invalid_argument("invalid_typed_phase");
}

const char *phase_to_string(Phase value) noexcept {
    switch (value) {
        case Phase::setup: return "SETUP";
        case Phase::draw: return "DRAW";
        case Phase::main: return "MAIN";
        case Phase::attack: return "ATTACK";
        case Phase::checkup: return "POKEMON_CHECKUP";
        case Phase::game_over: return "GAME_OVER";
    }
    return "SETUP";
}

SetupStage setup_stage_from_string(const std::string &value) {
    if (value == "TURN_ORDER") return SetupStage::turn_order;
    if (value == "INITIAL_PLACEMENT") return SetupStage::initial_placement;
    if (value == "BONUS_DRAW") return SetupStage::bonus_draw;
    if (value == "BONUS_PLACEMENT") return SetupStage::bonus_placement;
    if (value == "COMPLETE") return SetupStage::complete;
    throw std::invalid_argument("invalid_typed_setup_stage");
}

const char *setup_stage_to_string(SetupStage value) noexcept {
    switch (value) {
        case SetupStage::turn_order: return "TURN_ORDER";
        case SetupStage::initial_placement: return "INITIAL_PLACEMENT";
        case SetupStage::bonus_draw: return "BONUS_DRAW";
        case SetupStage::bonus_placement: return "BONUS_PLACEMENT";
        case SetupStage::complete: return "COMPLETE";
    }
    return "TURN_ORDER";
}

EntityKind entity_kind_from_string(const std::string &value) {
    if (value == "card") return EntityKind::card;
    if (value == "pokemon") return EntityKind::pokemon;
    if (value == "slot") return EntityKind::slot;
    if (value == "attachment") return EntityKind::attachment;
    if (value.empty()) return EntityKind::none;
    throw std::invalid_argument("invalid_typed_entity_kind");
}

const char *entity_kind_to_string(EntityKind value) noexcept {
    switch (value) {
        case EntityKind::none: return "";
        case EntityKind::card: return "card";
        case EntityKind::pokemon: return "pokemon";
        case EntityKind::slot: return "slot";
        case EntityKind::attachment: return "attachment";
    }
    return "";
}

Zone zone_from_string(const std::string &value) {
    if (value == "deck") return Zone::deck;
    if (value == "hand") return Zone::hand;
    if (value == "discard") return Zone::discard;
    if (value == "prizes") return Zone::prizes;
    if (value == "stadium") return Zone::stadium;
    if (value.empty()) return Zone::none;
    throw std::invalid_argument("invalid_typed_zone");
}

const char *zone_to_string(Zone value) noexcept {
    switch (value) {
        case Zone::none: return "";
        case Zone::deck: return "deck";
        case Zone::hand: return "hand";
        case Zone::discard: return "discard";
        case Zone::prizes: return "prizes";
        case Zone::stadium: return "stadium";
    }
    return "";
}

Slot slot_from_string(const std::string &value) {
    if (value == "active") return Slot::active;
    if (value == "bench_0") return Slot::bench_0;
    if (value == "bench_1") return Slot::bench_1;
    if (value == "bench_2") return Slot::bench_2;
    if (value == "bench_3") return Slot::bench_3;
    if (value == "bench_4") return Slot::bench_4;
    if (value.empty()) return Slot::none;
    throw std::invalid_argument("invalid_typed_slot");
}

const char *slot_to_string(Slot value) noexcept {
    switch (value) {
        case Slot::none: return "";
        case Slot::active: return "active";
        case Slot::bench_0: return "bench_0";
        case Slot::bench_1: return "bench_1";
        case Slot::bench_2: return "bench_2";
        case Slot::bench_3: return "bench_3";
        case Slot::bench_4: return "bench_4";
    }
    return "";
}

AttachmentType attachment_from_string(const std::string &value) {
    if (value == "energy") return AttachmentType::energy;
    if (value == "tool") return AttachmentType::tool;
    if (value.empty()) return AttachmentType::none;
    throw std::invalid_argument("invalid_typed_attachment_type");
}

const char *attachment_to_string(AttachmentType value) noexcept {
    switch (value) {
        case AttachmentType::none: return "";
        case AttachmentType::energy: return "energy";
        case AttachmentType::tool: return "tool";
    }
    return "";
}

ActionKind action_kind_from_string(const std::string &value) {
    if (value == "PLAY_BASIC") return ActionKind::play_basic;
    if (value == "EVOLVE") return ActionKind::evolve;
    if (value == "ATTACH_ENERGY") return ActionKind::attach_energy;
    if (value == "PLAY_TRAINER") return ActionKind::play_trainer;
    if (value == "USE_ABILITY") return ActionKind::use_ability;
    if (value == "USE_STADIUM") return ActionKind::use_stadium;
    if (value == "RETREAT") return ActionKind::retreat;
    if (value == "DECLARE_ATTACK") return ActionKind::declare_attack;
    if (value == "PROMOTE") return ActionKind::promote;
    if (value == "SETUP_DONE") return ActionKind::setup_done;
    if (value == "END_TURN") return ActionKind::end_turn;
    if (value == "NOOP") return ActionKind::noop;
    throw std::invalid_argument("invalid_typed_action_kind");
}

const char *action_kind_to_string(ActionKind value) noexcept {
    switch (value) {
        case ActionKind::play_basic: return "PLAY_BASIC";
        case ActionKind::evolve: return "EVOLVE";
        case ActionKind::attach_energy: return "ATTACH_ENERGY";
        case ActionKind::play_trainer: return "PLAY_TRAINER";
        case ActionKind::use_ability: return "USE_ABILITY";
        case ActionKind::use_stadium: return "USE_STADIUM";
        case ActionKind::retreat: return "RETREAT";
        case ActionKind::declare_attack: return "DECLARE_ATTACK";
        case ActionKind::promote: return "PROMOTE";
        case ActionKind::setup_done: return "SETUP_DONE";
        case ActionKind::end_turn: return "END_TURN";
        case ActionKind::noop: return "NOOP";
    }
    return "NOOP";
}

ChoiceRequestKind choice_request_kind_from_string(
    const std::string &value
) noexcept {
    if (value == "choose_turn_order") {
        return ChoiceRequestKind::choose_turn_order;
    }
    if (value == "choose_mulligan_draw_count") {
        return ChoiceRequestKind::choose_mulligan_draw_count;
    }
    if (value == "select_prize") return ChoiceRequestKind::select_prize;
    if (value == "select_retreat_payment") {
        return ChoiceRequestKind::select_retreat_payment;
    }
    if (value == "confirm_trigger") {
        return ChoiceRequestKind::confirm_trigger;
    }
    if (value == "confirm") return ChoiceRequestKind::confirm;
    if (value == "coin_flip") return ChoiceRequestKind::coin_flip;
    return ChoiceRequestKind::other;
}

#define PTCG_ENUM_CODEC(name, ...) \
    name name##_from_string(const std::string &value) { __VA_ARGS__ \
        throw std::invalid_argument("invalid_typed_" #name); \
    }

ModifierHook modifier_hook_from_string(const std::string &value) {
    if (value == "MODIFY_DAMAGE") return ModifierHook::modify_damage;
    if (value == "MAX_HP") return ModifierHook::max_hp;
    if (value == "CAN_RETREAT") return ModifierHook::can_retreat;
    if (value == "CAN_ATTACK") return ModifierHook::can_attack;
    if (value == "PREVENT_EFFECTS") return ModifierHook::prevent_effects;
    throw std::invalid_argument("invalid_typed_modifier_hook");
}

const char *modifier_hook_to_string(ModifierHook value) noexcept {
    switch (value) {
        case ModifierHook::modify_damage: return "MODIFY_DAMAGE";
        case ModifierHook::max_hp: return "MAX_HP";
        case ModifierHook::can_retreat: return "CAN_RETREAT";
        case ModifierHook::can_attack: return "CAN_ATTACK";
        case ModifierHook::prevent_effects: return "PREVENT_EFFECTS";
    }
    return "MODIFY_DAMAGE";
}

ModifierLayer modifier_layer_from_string(const std::string &value) {
    if (value == "base_replacement") return ModifierLayer::base_replacement;
    if (value == "attacker_adjust") return ModifierLayer::attacker_adjust;
    if (value == "weakness") return ModifierLayer::weakness;
    if (value == "resistance") return ModifierLayer::resistance;
    if (value == "defender_adjust") return ModifierLayer::defender_adjust;
    if (value == "prevent") return ModifierLayer::prevent;
    if (value == "clamp") return ModifierLayer::clamp;
    if (value == "base") return ModifierLayer::base;
    if (value == "add") return ModifierLayer::add;
    if (value == "set") return ModifierLayer::set;
    if (value == "permission") return ModifierLayer::permission;
    if (value == "gate") return ModifierLayer::gate;
    throw std::invalid_argument("invalid_typed_modifier_layer");
}

const char *modifier_layer_to_string(ModifierLayer value) noexcept {
    switch (value) {
        case ModifierLayer::base_replacement: return "base_replacement";
        case ModifierLayer::attacker_adjust: return "attacker_adjust";
        case ModifierLayer::weakness: return "weakness";
        case ModifierLayer::resistance: return "resistance";
        case ModifierLayer::defender_adjust: return "defender_adjust";
        case ModifierLayer::prevent: return "prevent";
        case ModifierLayer::clamp: return "clamp";
        case ModifierLayer::base: return "base";
        case ModifierLayer::add: return "add";
        case ModifierLayer::set: return "set";
        case ModifierLayer::permission: return "permission";
        case ModifierLayer::gate: return "gate";
    }
    return "attacker_adjust";
}

ModifierScope modifier_scope_from_string(const std::string &value) {
    if (value == "self") return ModifierScope::self;
    if (value == "attached_attacker") return ModifierScope::attached_attacker;
    if (value == "attached_defender") return ModifierScope::attached_defender;
    if (value == "active") return ModifierScope::active;
    if (value == "allied_board") return ModifierScope::allied_board;
    throw std::invalid_argument("invalid_typed_modifier_scope");
}

const char *modifier_scope_to_string(ModifierScope value) noexcept {
    switch (value) {
        case ModifierScope::self: return "self";
        case ModifierScope::attached_attacker: return "attached_attacker";
        case ModifierScope::attached_defender: return "attached_defender";
        case ModifierScope::active: return "active";
        case ModifierScope::allied_board: return "allied_board";
    }
    return "self";
}

ModifierDuration modifier_duration_from_string(const std::string &value) {
    if (value == "persistent") return ModifierDuration::persistent;
    if (value == "until_leave_play") return ModifierDuration::until_leave_play;
    if (value == "until_switch_or_evolve") return ModifierDuration::until_switch_or_evolve;
    if (value == "until_end_of_turn") return ModifierDuration::until_end_of_turn;
    if (value == "until_end_of_opponents_next_turn") return ModifierDuration::until_end_of_opponents_next_turn;
    if (value == "until_next_attack") return ModifierDuration::until_next_attack;
    throw std::invalid_argument("invalid_typed_modifier_duration");
}

const char *modifier_duration_to_string(ModifierDuration value) noexcept {
    switch (value) {
        case ModifierDuration::persistent: return "persistent";
        case ModifierDuration::until_leave_play: return "until_leave_play";
        case ModifierDuration::until_switch_or_evolve: return "until_switch_or_evolve";
        case ModifierDuration::until_end_of_turn: return "until_end_of_turn";
        case ModifierDuration::until_end_of_opponents_next_turn: return "until_end_of_opponents_next_turn";
        case ModifierDuration::until_next_attack: return "until_next_attack";
    }
    return "persistent";
}

ModifierStacking modifier_stacking_from_string(const std::string &value) {
    if (value == "stack") return ModifierStacking::stack;
    if (value == "replace_same_source") return ModifierStacking::replace_same_source;
    if (value == "maximum") return ModifierStacking::maximum;
    if (value == "unique") return ModifierStacking::unique;
    throw std::invalid_argument("invalid_typed_modifier_stacking");
}

const char *modifier_stacking_to_string(ModifierStacking value) noexcept {
    switch (value) {
        case ModifierStacking::stack: return "stack";
        case ModifierStacking::replace_same_source: return "replace_same_source";
        case ModifierStacking::maximum: return "maximum";
        case ModifierStacking::unique: return "unique";
    }
    return "stack";
}

ModifierConflict modifier_conflict_from_string(const std::string &value) {
    if (value == "commutative") return ModifierConflict::commutative;
    if (value == "controller_choice") return ModifierConflict::controller_choice;
    throw std::invalid_argument("invalid_typed_modifier_conflict");
}

const char *modifier_conflict_to_string(ModifierConflict value) noexcept {
    return value == ModifierConflict::controller_choice
        ? "controller_choice" : "commutative";
}

ModifierOperationKind modifier_operation_from_string(const std::string &value) {
    if (value == "damage_delta") return ModifierOperationKind::damage_delta;
    if (value == "prevent_damage") return ModifierOperationKind::prevent_damage;
    if (value == "hp_delta") return ModifierOperationKind::hp_delta;
    if (value == "retreat_delta") return ModifierOperationKind::retreat_delta;
    if (value == "retreat_set") return ModifierOperationKind::retreat_set;
    if (value == "attack_lock") return ModifierOperationKind::attack_lock;
    if (value == "attack_gate_coin") return ModifierOperationKind::attack_gate_coin;
    if (value == "prevent_effects") return ModifierOperationKind::prevent_effects;
    throw std::invalid_argument("invalid_typed_modifier_operation");
}

const char *modifier_operation_to_string(ModifierOperationKind value) noexcept {
    switch (value) {
        case ModifierOperationKind::damage_delta: return "damage_delta";
        case ModifierOperationKind::prevent_damage: return "prevent_damage";
        case ModifierOperationKind::hp_delta: return "hp_delta";
        case ModifierOperationKind::retreat_delta: return "retreat_delta";
        case ModifierOperationKind::retreat_set: return "retreat_set";
        case ModifierOperationKind::attack_lock: return "attack_lock";
        case ModifierOperationKind::attack_gate_coin: return "attack_gate_coin";
        case ModifierOperationKind::prevent_effects: return "prevent_effects";
    }
    return "damage_delta";
}

ResolutionFrameKind resolution_frame_from_string(const std::string &value) {
    if (value == "command") return ResolutionFrameKind::command;
    if (value == "continuation") return ResolutionFrameKind::continuation;
    if (value == "trigger_batch") return ResolutionFrameKind::trigger_batch;
    if (value == "trigger") return ResolutionFrameKind::trigger;
    if (value == "barrier") return ResolutionFrameKind::barrier;
    throw std::invalid_argument("invalid_typed_resolution_frame");
}

bool decode_entity_ref(
    const Value &source,
    const CardStringTable &cards,
    EntityRef &target
) {
    if (!source.is_object()) return false;
    target.kind = entity_kind_from_string(string_field(source, "kind"));
    target.player = static_cast<std::int32_t>(integer_field(source, "player", -1));
    target.zone = zone_from_string(string_field(source, "zone"));
    target.slot = slot_from_string(string_field(source, "slot"));
    target.index = static_cast<std::int32_t>(integer_field(source, "index", -1));
    target.attachment_type = attachment_from_string(
        string_field(source, "attachment_type"));
    const std::string card = string_field(source, "card_id");
    target.card_id = card.empty() ? EMPTY_CARD_ID : cards.find(card);
    return card.empty() || target.card_id != EMPTY_CARD_ID;
}

Value encode_entity_ref(const EntityRef &source, const CardStringTable &cards) {
    Object result;
    result["kind"] = Value(entity_kind_to_string(source.kind));
    result["player"] = Value(source.player);
    switch (source.kind) {
        case EntityKind::card:
            result["zone"] = Value(zone_to_string(source.zone));
            result["index"] = Value(source.index);
            result["card_id"] = Value(cards.resolve(source.card_id));
            break;
        case EntityKind::pokemon:
            result["slot"] = Value(slot_to_string(source.slot));
            result["card_id"] = Value(cards.resolve(source.card_id));
            break;
        case EntityKind::slot:
            result["slot"] = Value(slot_to_string(source.slot));
            break;
        case EntityKind::attachment:
            result["slot"] = Value(slot_to_string(source.slot));
            result["attachment_type"] = Value(
                attachment_to_string(source.attachment_type));
            result["index"] = Value(source.index);
            result["card_id"] = Value(cards.resolve(source.card_id));
            break;
        case EntityKind::none:
            break;
    }
    return Value(std::move(result));
}

bool decode_card_ids(
    const Value *source,
    const CardStringTable &cards,
    std::vector<CardId> &target
) {
    target.clear();
    if (source == nullptr || !source->is_array()) return false;
    target.reserve(source->as_array().size());
    for (const Value &entry : source->as_array()) {
        if (!entry.is_string()) return false;
        const CardId id = cards.find(entry.as_string());
        if (id == EMPTY_CARD_ID) return false;
        target.push_back(id);
    }
    return true;
}

Value encode_card_ids(
    const std::vector<CardId> &source,
    const CardStringTable &cards
) {
    Array result;
    result.reserve(source.size());
    for (CardId id : source) result.emplace_back(cards.resolve(id));
    return Value(std::move(result));
}

bool decode_strings(const Value *source, std::vector<std::string> &target) {
    target.clear();
    if (source == nullptr || !source->is_array()) return false;
    target.reserve(source->as_array().size());
    for (const Value &entry : source->as_array()) {
        if (!entry.is_string()) return false;
        target.push_back(entry.as_string());
    }
    return true;
}

Value encode_strings(const std::vector<std::string> &source) {
    Array result;
    result.reserve(source.size());
    for (const std::string &entry : source) result.emplace_back(entry);
    return Value(std::move(result));
}

bool decode_modifier(
    const Value &source,
    const CardStringTable &cards,
    Modifier &target
) {
    if (!source.is_object()) return false;
    target.hook = modifier_hook_from_string(string_field(source, "hook"));
    target.layer = modifier_layer_from_string(string_field(source, "layer"));
    target.priority = integer_field(source, "priority");
    target.controller = static_cast<std::int32_t>(integer_field(source, "controller"));
    const Value *source_ref = field(source, "source_ref");
    if (source_ref == nullptr || !decode_entity_ref(*source_ref, cards, target.source_ref)) {
        return false;
    }
    target.scope = modifier_scope_from_string(string_field(source, "scope"));
    target.duration = modifier_duration_from_string(string_field(source, "duration"));
    target.stacking = modifier_stacking_from_string(string_field(source, "stacking"));
    target.conflict = modifier_conflict_from_string(
        string_field(source, "conflict_policy"));
    const Value *condition = field(source, "condition");
    if (condition == nullptr || !condition->is_object()) return false;
    const auto optional_string = [&](const std::string &key) -> std::optional<std::string> {
        const Value *value = field(*condition, key);
        return value != nullptr && value->is_string()
            ? std::optional<std::string>(value->as_string()) : std::nullopt;
    };
    const auto optional_bool = [&](const std::string &key) -> std::optional<bool> {
        const Value *value = field(*condition, key);
        return value != nullptr && value->is_bool()
            ? std::optional<bool>(value->as_bool()) : std::nullopt;
    };
    const auto optional_integer = [&](const std::string &key) -> std::optional<std::int64_t> {
        const Value *value = field(*condition, key);
        return value != nullptr && value->is_number()
            ? std::optional<std::int64_t>(value->as_integer()) : std::nullopt;
    };
    target.condition.attacker_subtype = optional_string("attacker_subtype");
    target.condition.defender_type = optional_string("defender_type");
    target.condition.requires_attached_energy = optional_bool("requires_attached_energy");
    target.condition.energy_type = optional_string("energy_type");
    target.condition.threshold = optional_integer("threshold");
    target.condition.behind_on_prizes = optional_bool("behind_on_prizes");
    target.condition.target_active = optional_bool("target_active");
    target.condition.target_stage = optional_string("target_stage");
    target.condition.target_basic = optional_bool("target_basic");
    target.condition.expires_after_turn = optional_integer("expires_after_turn");
    const Value *operation = field(source, "operation");
    if (operation == nullptr || !operation->is_object()) return false;
    target.operation.kind = modifier_operation_from_string(
        string_field(*operation, "kind"));
    target.operation.number = integer_field(
        *operation,
        target.operation.kind == ModifierOperationKind::retreat_set
            ? "value" : "amount",
        0
    );
    target.operation.text = string_field(
        *operation,
        target.operation.kind == ModifierOperationKind::attack_lock
            ? "attack_name" : "reason"
    );
    return true;
}

Value encode_modifier(const Modifier &source, const CardStringTable &cards) {
    Object condition;
    const auto add_string = [&](const char *key, const std::optional<std::string> &value) {
        if (value.has_value()) condition[key] = Value(*value);
    };
    const auto add_bool = [&](const char *key, const std::optional<bool> &value) {
        if (value.has_value()) condition[key] = Value(*value);
    };
    const auto add_integer = [&](const char *key, const std::optional<std::int64_t> &value) {
        if (value.has_value()) condition[key] = Value(*value);
    };
    add_string("attacker_subtype", source.condition.attacker_subtype);
    add_string("defender_type", source.condition.defender_type);
    add_bool("requires_attached_energy", source.condition.requires_attached_energy);
    add_string("energy_type", source.condition.energy_type);
    add_integer("threshold", source.condition.threshold);
    add_bool("behind_on_prizes", source.condition.behind_on_prizes);
    add_bool("target_active", source.condition.target_active);
    add_string("target_stage", source.condition.target_stage);
    add_bool("target_basic", source.condition.target_basic);
    add_integer("expires_after_turn", source.condition.expires_after_turn);

    Object operation{{"kind", Value(modifier_operation_to_string(source.operation.kind))}};
    switch (source.operation.kind) {
        case ModifierOperationKind::damage_delta:
        case ModifierOperationKind::hp_delta:
        case ModifierOperationKind::retreat_delta:
            operation["amount"] = Value(source.operation.number);
            break;
        case ModifierOperationKind::retreat_set:
            operation["value"] = Value(source.operation.number);
            break;
        case ModifierOperationKind::attack_lock:
            operation["attack_name"] = Value(source.operation.text);
            break;
        case ModifierOperationKind::attack_gate_coin:
            operation["reason"] = Value(source.operation.text);
            break;
        case ModifierOperationKind::prevent_damage:
        case ModifierOperationKind::prevent_effects:
            break;
    }
    return Value(Object{
        {"hook", Value(modifier_hook_to_string(source.hook))},
        {"layer", Value(modifier_layer_to_string(source.layer))},
        {"priority", Value(source.priority)},
        {"controller", Value(source.controller)},
        {"source_ref", encode_entity_ref(source.source_ref, cards)},
        {"scope", Value(modifier_scope_to_string(source.scope))},
        {"duration", Value(modifier_duration_to_string(source.duration))},
        {"stacking", Value(modifier_stacking_to_string(source.stacking))},
        {"conflict_policy", Value(modifier_conflict_to_string(source.conflict))},
        {"condition", Value(std::move(condition))},
        {"operation", Value(std::move(operation))},
    });
}

bool decode_pokemon(
    const Value &source,
    const CardStringTable &cards,
    PokemonState &target
) {
    if (!source.is_object()) return false;
    target.card_id = cards.find(string_field(source, "card_id"));
    if (target.card_id == EMPTY_CARD_ID) return false;
    target.damage_counters = integer_field(source, "damage_counters");
    if (!decode_card_ids(field(source, "energy_card_ids"), cards, target.energy_card_ids)) {
        return false;
    }
    const std::string tool = string_field(source, "attached_tool_id");
    target.attached_tool_id = tool.empty() ? EMPTY_CARD_ID : cards.find(tool);
    if (!tool.empty() && target.attached_tool_id == EMPTY_CARD_ID) return false;
    if (!decode_strings(field(source, "status_conditions"), target.status_conditions)) {
        return false;
    }
    if (!decode_card_ids(
        field(source, "evolution_stack_ids"), cards, target.evolution_stack_ids
    )) {
        return false;
    }
    target.can_evolve_this_turn = bool_field(source, "can_evolve_this_turn", true);
    target.placed_this_turn = bool_field(source, "placed_this_turn", true);
    target.damage_prevented = bool_field(source, "damage_prevented");
    target.all_prevented = bool_field(source, "all_prevented");
    target.outgoing_damage_reduction = integer_field(
        source, "outgoing_damage_reduction");
    target.has_damage_prevented_field = field(source, "damage_prevented") != nullptr;
    target.has_all_prevented_field = field(source, "all_prevented") != nullptr;
    target.has_outgoing_damage_reduction_field =
        field(source, "outgoing_damage_reduction") != nullptr;
    if (!decode_strings(field(source, "used_abilities"), target.used_abilities)) {
        return false;
    }
    target.healed_this_turn = bool_field(source, "healed_this_turn");
    target.modifiers.clear();
    const Value *modifiers = field(source, "modifiers");
    if (modifiers != nullptr) {
        if (!modifiers->is_array()) return false;
        target.modifiers.reserve(modifiers->as_array().size());
        for (const Value &entry : modifiers->as_array()) {
            Modifier descriptor;
            if (!decode_modifier(entry, cards, descriptor)) return false;
            target.modifiers.push_back(std::move(descriptor));
        }
    }
    target.paralyzed_since_turn = integer_field(source, "paralyzed_since_turn");
    return true;
}

Value encode_pokemon(const PokemonState &source, const CardStringTable &cards) {
    Object result{
        {"card_id", Value(cards.resolve(source.card_id))},
        {"damage_counters", Value(source.damage_counters)},
        {"energy_card_ids", encode_card_ids(source.energy_card_ids, cards)},
        {"attached_tool_id", Value(cards.resolve(source.attached_tool_id))},
        {"status_conditions", encode_strings(source.status_conditions)},
        {"evolution_stack_ids", encode_card_ids(source.evolution_stack_ids, cards)},
        {"can_evolve_this_turn", Value(source.can_evolve_this_turn)},
        {"placed_this_turn", Value(source.placed_this_turn)},
        {"used_abilities", encode_strings(source.used_abilities)},
        {"healed_this_turn", Value(source.healed_this_turn)},
        {"paralyzed_since_turn", Value(source.paralyzed_since_turn)},
    };
    if (source.has_damage_prevented_field) {
        result["damage_prevented"] = Value(source.damage_prevented);
    }
    if (source.has_all_prevented_field) {
        result["all_prevented"] = Value(source.all_prevented);
    }
    if (source.has_outgoing_damage_reduction_field) {
        result["outgoing_damage_reduction"] = Value(
            source.outgoing_damage_reduction);
    }
    if (!source.modifiers.empty()) {
        Array modifiers;
        modifiers.reserve(source.modifiers.size());
        for (const Modifier &entry : source.modifiers) {
            modifiers.push_back(encode_modifier(entry, cards));
        }
        result["modifiers"] = Value(std::move(modifiers));
    }
    return Value(std::move(result));
}

bool decode_player(
    const Value &source,
    const CardStringTable &cards,
    PlayerState &target
) {
    if (!source.is_object()) return false;
    target.name = string_field(source, "name", "玩家");
    if (!decode_card_ids(field(source, "deck"), cards, target.deck)
        || !decode_card_ids(field(source, "hand"), cards, target.hand)
        || !decode_card_ids(field(source, "discard"), cards, target.discard)
        || !decode_card_ids(field(source, "prizes"), cards, target.prizes)) {
        return false;
    }
    const Value *active = field(source, "active");
    target.active.reset();
    if (active != nullptr && !active->is_null()) {
        PokemonState pokemon;
        if (!decode_pokemon(*active, cards, pokemon)) return false;
        target.active = std::move(pokemon);
    }
    const Value *bench = field(source, "bench");
    if (bench == nullptr || !bench->is_array() || bench->as_array().size() != 5) {
        return false;
    }
    for (std::size_t index = 0; index < target.bench.size(); ++index) {
        const Value &entry = bench->as_array()[index];
        target.bench[index].reset();
        if (entry.is_null()) continue;
        PokemonState pokemon;
        if (!decode_pokemon(entry, cards, pokemon)) return false;
        target.bench[index] = std::move(pokemon);
    }
    target.supporter_played_this_turn = bool_field(source, "supporter_played_this_turn");
    target.energy_attached_this_turn = bool_field(source, "energy_attached_this_turn");
    target.retreated_this_turn = bool_field(source, "retreated_this_turn");
    target.stadium_played_this_turn = bool_field(source, "stadium_played_this_turn");
    target.stadium_used_this_turn = bool_field(source, "stadium_used_this_turn");
    target.healed_this_turn = bool_field(source, "healed_this_turn");
    target.vstar_power_used = bool_field(source, "vstar_power_used");
    target.was_ko_by_attack = bool_field(source, "was_ko_by_attack");
    target.attack_locked_names.clear();
    const Value *locks = field(source, "attack_locked_names");
    if (locks != nullptr) {
        if (!locks->is_object()) return false;
        for (const auto &[name, value] : locks->as_object()) {
            if (!value.is_number()) return false;
            target.attack_locked_names[name] = value.as_integer();
        }
    }
    return true;
}

Value encode_player(const PlayerState &source, const CardStringTable &cards) {
    Array bench;
    bench.reserve(source.bench.size());
    for (const auto &entry : source.bench) {
        bench.push_back(entry.has_value()
            ? encode_pokemon(*entry, cards) : Value());
    }
    Object result{
        {"name", Value(source.name)},
        {"deck", encode_card_ids(source.deck, cards)},
        {"hand", encode_card_ids(source.hand, cards)},
        {"discard", encode_card_ids(source.discard, cards)},
        {"prizes", encode_card_ids(source.prizes, cards)},
        {"active", source.active.has_value()
            ? encode_pokemon(*source.active, cards) : Value()},
        {"bench", Value(std::move(bench))},
        {"supporter_played_this_turn", Value(source.supporter_played_this_turn)},
        {"energy_attached_this_turn", Value(source.energy_attached_this_turn)},
        {"retreated_this_turn", Value(source.retreated_this_turn)},
        {"stadium_played_this_turn", Value(source.stadium_played_this_turn)},
        {"stadium_used_this_turn", Value(source.stadium_used_this_turn)},
        {"healed_this_turn", Value(source.healed_this_turn)},
        {"vstar_power_used", Value(source.vstar_power_used)},
        {"was_ko_by_attack", Value(source.was_ko_by_attack)},
    };
    if (!source.attack_locked_names.empty()) {
        Object locks;
        for (const auto &[name, value] : source.attack_locked_names) {
            locks[name] = Value(value);
        }
        result["attack_locked_names"] = Value(std::move(locks));
    }
    return Value(std::move(result));
}

bool decode_knockouts(
    const Value *turn,
    const CardStringTable &cards,
    std::vector<KnockoutFact> &target
) {
    target.clear();
    if (turn == nullptr || !turn->is_object()) return false;
    const Value *rows = field(*turn, "knockouts");
    if (rows == nullptr || !rows->is_array()) return false;
    target.reserve(rows->as_array().size());
    for (const Value &entry : rows->as_array()) {
        if (!entry.is_object()) return false;
        KnockoutFact fact;
        fact.defeated_player = static_cast<std::int32_t>(
            integer_field(entry, "defeated_player", -1));
        fact.source_player = static_cast<std::int32_t>(
            integer_field(entry, "source_player", -1));
        fact.source_kind = string_field(entry, "source_kind");
        fact.cause_kind = string_field(entry, "cause_kind");
        fact.cause_detail = string_field(entry, "cause_detail");
        const std::string card = string_field(entry, "card_id");
        fact.card_id = card.empty() ? EMPTY_CARD_ID : cards.find(card);
        if (!card.empty() && fact.card_id == EMPTY_CARD_ID) return false;
        fact.slot = string_field(entry, "slot", "active");
        fact.turn = integer_field(entry, "turn");
        target.push_back(std::move(fact));
    }
    return true;
}

Value encode_knockouts(
    const std::vector<KnockoutFact> &source,
    const CardStringTable &cards
) {
    Array rows;
    rows.reserve(source.size());
    for (const KnockoutFact &fact : source) {
        rows.emplace_back(Object{
            {"card_id", Value(cards.resolve(fact.card_id))},
            {"cause_detail", Value(fact.cause_detail)},
            {"cause_kind", Value(fact.cause_kind)},
            {"defeated_player", Value(fact.defeated_player)},
            {"slot", Value(fact.slot)},
            {"source_kind", Value(fact.source_kind)},
            {"source_player", Value(fact.source_player)},
            {"turn", Value(fact.turn)},
        });
    }
    return Value(Object{{"knockouts", Value(std::move(rows))}});
}

} // namespace

CardStringTable::CardStringTable(const Value &cards) {
    if (!cards.is_object()) return;
    values_.reserve(cards.as_object().size() + 1);
    ids_.reserve(cards.as_object().size());
    for (const auto &[key, ignored] : cards.as_object()) {
        (void)ignored;
        const CardId id = static_cast<CardId>(values_.size());
        values_.push_back(key);
        ids_.emplace(key, id);
    }
}

CardId CardStringTable::find(std::string_view value) const noexcept {
    if (value.empty()) return EMPTY_CARD_ID;
    const auto found = ids_.find(std::string(value));
    return found == ids_.end() ? EMPTY_CARD_ID : found->second;
}

const std::string &CardStringTable::resolve(CardId value) const noexcept {
    static const std::string empty;
    return value < values_.size() ? values_[value] : empty;
}

std::size_t CardStringTable::size() const noexcept {
    return values_.size() > 0 ? values_.size() - 1 : 0;
}

StateCodec::StateCodec(std::shared_ptr<const CardStringTable> cards)
    : cards_(std::move(cards)) {
    if (!cards_) throw std::invalid_argument("typed_state_cards_are_null");
}

bool StateCodec::decode_state(
    const Value &source,
    GameState &target,
    std::string *error
) const {
    try {
        if (!source.is_object()) return fail(error, "typed_state_not_object");
        const Value *players = field(source, "players");
        if (players == nullptr || !players->is_array()
            || players->as_array().size() != 2) {
            return fail(error, "typed_state_invalid_players");
        }
        for (std::size_t index = 0; index < target.players.size(); ++index) {
            if (!decode_player(players->as_array()[index], *cards_, target.players[index])) {
                return fail(error, "typed_state_invalid_player");
            }
        }
        target.active_player_idx = static_cast<std::int32_t>(
            integer_field(source, "active_player_idx"));
        target.phase = phase_from_string(string_field(source, "phase"));
        target.turn_number = integer_field(source, "turn_number");
        target.first_player_idx = static_cast<std::int32_t>(
            integer_field(source, "first_player_idx"));
        const std::string stadium = string_field(source, "stadium_card_id");
        target.stadium_card_id = stadium.empty()
            ? EMPTY_CARD_ID : cards_->find(stadium);
        if (!stadium.empty() && target.stadium_card_id == EMPTY_CARD_ID) {
            return fail(error, "typed_state_unknown_stadium");
        }
        target.stadium_owner_idx = static_cast<std::int32_t>(
            integer_field(source, "stadium_owner_idx", -1));
        target.winner = static_cast<std::int32_t>(integer_field(source, "winner", -1));
        target.result_status = string_field(source, "result_status", "ONGOING");
        target.result_reason = string_field(source, "result_reason");
        const Value *conditions = field(source, "result_conditions");
        if (conditions == nullptr || !conditions->is_array()
            || conditions->as_array().size() != 2) {
            return fail(error, "typed_state_invalid_result_conditions");
        }
        for (std::size_t index = 0; index < target.result_conditions.size(); ++index) {
            if (!decode_strings(
                &conditions->as_array()[index], target.result_conditions[index]
            )) {
                return fail(error, "typed_state_invalid_result_condition");
            }
        }
        target.revision = integer_field(source, "revision");
        target.choice_sequence = integer_field(source, "choice_sequence");
        const Value *deck_keys = field(source, "public_deck_keys");
        if (deck_keys == nullptr || !deck_keys->is_array()
            || deck_keys->as_array().size() != 2) {
            return fail(error, "typed_state_invalid_public_deck_keys");
        }
        for (std::size_t index = 0; index < target.public_deck_keys.size(); ++index) {
            if (!deck_keys->as_array()[index].is_string()) {
                return fail(error, "typed_state_invalid_public_deck_key");
            }
            target.public_deck_keys[index] = deck_keys->as_array()[index].as_string();
        }
        target.apply_type_matchups = bool_field(source, "apply_type_matchups");
        target.rules_profile_id = string_field(
            source, "rules_profile_id", "CN_MAINLAND_3_1_0");
        if (!decode_strings(field(source, "action_log"), target.action_log)) {
            return fail(error, "typed_state_invalid_action_log");
        }
        const auto decode_pair = [&] (
            const char *key,
            auto &destination,
            auto convert
        ) {
            const Value *values = field(source, key);
            if (values == nullptr || !values->is_array()
                || values->as_array().size() != 2) return false;
            for (std::size_t index = 0; index < 2; ++index) {
                destination[index] = convert(values->as_array()[index]);
            }
            return true;
        };
        if (!decode_pair("mulligan_count", target.mulligan_count,
                [](const Value &v) { return v.as_integer(); })
            || !decode_pair("extra_draws", target.extra_draws,
                [](const Value &v) { return v.as_integer(); })
            || !decode_pair("setup_ready", target.setup_ready,
                [](const Value &v) { return v.as_bool(); })) {
            return fail(error, "typed_state_invalid_setup_pair");
        }
        target.setup_stage = setup_stage_from_string(
            string_field(source, "setup_stage"));
        target.setup_actor_idx = static_cast<std::int32_t>(
            integer_field(source, "setup_actor_idx", -1));
        target.opening_coin_winner_idx = static_cast<std::int32_t>(
            integer_field(source, "opening_coin_winner_idx", -1));
        target.mulligan_bonus_max = integer_field(source, "mulligan_bonus_max");
        const Value *bonus = field(source, "setup_bonus_card_ids");
        if (bonus == nullptr || !bonus->is_array() || bonus->as_array().size() != 2) {
            return fail(error, "typed_state_invalid_setup_bonus_cards");
        }
        for (std::size_t index = 0; index < 2; ++index) {
            if (!decode_card_ids(
                &bonus->as_array()[index], *cards_, target.setup_bonus_card_ids[index]
            )) {
                return fail(error, "typed_state_invalid_setup_bonus_card");
            }
        }
        target.pending_promotions.clear();
        const Value *promotions = field(source, "pending_promotions");
        if (promotions == nullptr || !promotions->is_array()) {
            return fail(error, "typed_state_invalid_pending_promotions");
        }
        for (const Value &entry : promotions->as_array()) {
            if (!entry.is_number()) return fail(error, "typed_state_invalid_promotion");
            target.pending_promotions.push_back(
                static_cast<std::int32_t>(entry.as_integer()));
        }
        if (!decode_strings(
            field(source, "processed_action_ids"), target.processed_action_ids
        )) {
            return fail(error, "typed_state_invalid_processed_ids");
        }
        const Value *fact_book = field(source, "turn_fact_book");
        if (fact_book == nullptr || !fact_book->is_object()
            || !decode_knockouts(
                field(*fact_book, "current_turn"), *cards_,
                target.turn_fact_book.current_turn_knockouts)
            || !decode_knockouts(
                field(*fact_book, "previous_turn"), *cards_,
                target.turn_fact_book.previous_turn_knockouts)) {
            return fail(error, "typed_state_invalid_turn_fact_book");
        }
        const Value *resolution = field(source, "resolution_stack");
        if (resolution == nullptr || !resolution->is_object()) {
            return fail(error, "typed_state_invalid_resolution_stack");
        }
        target.resolution_stack.schema_version = integer_field(
            *resolution, "schema_version", 3);
        target.resolution_stack.sequence = integer_field(*resolution, "sequence");
        target.resolution_stack.pending_request = field(*resolution, "pending_request")
            ? field(*resolution, "pending_request")->deep_clone() : Value();
        target.resolution_stack.context = field(*resolution, "context")
            ? field(*resolution, "context")->deep_clone() : Value::make_object();
        target.resolution_stack.frames.clear();
        const Value *frames = field(*resolution, "frames");
        if (frames == nullptr || !frames->is_array()) {
            return fail(error, "typed_state_invalid_resolution_frames");
        }
        target.resolution_stack.frames.reserve(frames->as_array().size());
        for (const Value &entry : frames->as_array()) {
            if (!entry.is_object()) return fail(error, "typed_state_invalid_resolution_frame");
            ResolutionFrame frame;
            frame.kind = resolution_frame_from_string(string_field(entry, "kind"));
            frame.wire_payload = entry.deep_clone();
            target.resolution_stack.frames.push_back(std::move(frame));
        }
        if (error != nullptr) error->clear();
        return true;
    } catch (const std::exception &exception) {
        return fail(error, exception.what());
    }
}

Value StateCodec::encode_state(const GameState &source) const {
    Array players;
    players.reserve(2);
    for (const PlayerState &player : source.players) {
        players.push_back(encode_player(player, *cards_));
    }
    Array result_conditions;
    for (const auto &row : source.result_conditions) {
        result_conditions.push_back(encode_strings(row));
    }
    Array public_deck_keys{
        Value(source.public_deck_keys[0]),
        Value(source.public_deck_keys[1]),
    };
    Array mulligans{Value(source.mulligan_count[0]), Value(source.mulligan_count[1])};
    Array extra{Value(source.extra_draws[0]), Value(source.extra_draws[1])};
    Array ready{Value(source.setup_ready[0]), Value(source.setup_ready[1])};
    Array bonus{
        encode_card_ids(source.setup_bonus_card_ids[0], *cards_),
        encode_card_ids(source.setup_bonus_card_ids[1], *cards_),
    };
    Array promotions;
    for (std::int32_t player : source.pending_promotions) {
        promotions.emplace_back(player);
    }
    Array frames;
    frames.reserve(source.resolution_stack.frames.size());
    for (const ResolutionFrame &frame : source.resolution_stack.frames) {
        frames.push_back(frame.wire_payload.deep_clone());
    }
    Value resolution(Object{
        {"schema_version", Value(source.resolution_stack.schema_version)},
        {"frames", Value(std::move(frames))},
        {"pending_request", source.resolution_stack.pending_request.deep_clone()},
        {"sequence", Value(source.resolution_stack.sequence)},
        {"context", source.resolution_stack.context.deep_clone()},
    });
    return Value(Object{
        {"players", Value(std::move(players))},
        {"active_player_idx", Value(source.active_player_idx)},
        {"phase", Value(phase_to_string(source.phase))},
        {"turn_number", Value(source.turn_number)},
        {"first_player_idx", Value(source.first_player_idx)},
        {"stadium_card_id", Value(cards_->resolve(source.stadium_card_id))},
        {"stadium_owner_idx", Value(source.stadium_owner_idx)},
        {"winner", Value(source.winner)},
        {"result_status", Value(source.result_status)},
        {"result_reason", Value(source.result_reason)},
        {"result_conditions", Value(std::move(result_conditions))},
        {"revision", Value(source.revision)},
        {"choice_sequence", Value(source.choice_sequence)},
        {"public_deck_keys", Value(std::move(public_deck_keys))},
        {"apply_type_matchups", Value(source.apply_type_matchups)},
        {"rules_profile_id", Value(source.rules_profile_id)},
        {"rules_options", Value(Object{
            {"apply_type_matchups", Value(source.apply_type_matchups)}})},
        {"action_log", encode_strings(source.action_log)},
        {"mulligan_count", Value(std::move(mulligans))},
        {"extra_draws", Value(std::move(extra))},
        {"setup_ready", Value(std::move(ready))},
        {"setup_stage", Value(setup_stage_to_string(source.setup_stage))},
        {"setup_actor_idx", Value(source.setup_actor_idx)},
        {"opening_coin_winner_idx", Value(source.opening_coin_winner_idx)},
        {"mulligan_bonus_max", Value(source.mulligan_bonus_max)},
        {"setup_bonus_card_ids", Value(std::move(bonus))},
        {"pending_promotions", Value(std::move(promotions))},
        {"processed_action_ids", encode_strings(source.processed_action_ids)},
        {"resolution_stack", std::move(resolution)},
        {"turn_fact_book", Value(Object{
            {"current_turn", encode_knockouts(
                source.turn_fact_book.current_turn_knockouts, *cards_)},
            {"previous_turn", encode_knockouts(
                source.turn_fact_book.previous_turn_knockouts, *cards_)},
        })},
    });
}

bool StateCodec::decode_action(
    const Value &source,
    Action &target,
    std::string *error
) const {
    try {
        if (!source.is_object()) return fail(error, "typed_action_not_object");
        if (integer_field(source, "schema_version", -1) != 4) {
            return fail(error, "typed_action_schema");
        }
        target.kind = action_kind_from_string(string_field(source, "kind"));
        target.actor = static_cast<std::int32_t>(integer_field(source, "actor", -1));
        target.base_revision = integer_field(source, "base_revision", -1);
        target.action_id = string_field(source, "action_id");
        target.source.reset();
        target.target.reset();
        for (const auto &[key, destination] : std::array{
            std::pair<const char *, std::optional<EntityRef> *>("source", &target.source),
            std::pair<const char *, std::optional<EntityRef> *>("target", &target.target),
        }) {
            const Value *entry = field(source, key);
            if (entry == nullptr || entry->is_null()) continue;
            EntityRef reference;
            if (!decode_entity_ref(*entry, *cards_, reference)) {
                return fail(error, "typed_action_invalid_ref");
            }
            *destination = reference;
        }
        target.attack_index.reset();
        target.ability_name.clear();
        const Value *payload = field(source, "payload");
        if (payload == nullptr || !payload->is_object()) {
            return fail(error, "typed_action_invalid_payload");
        }
        if (target.kind == ActionKind::declare_attack) {
            const Value *index = field(*payload, "attack_index");
            if (index == nullptr || !index->is_number()) {
                return fail(error, "typed_action_missing_attack_index");
            }
            target.attack_index = index->as_integer();
        } else if (target.kind == ActionKind::use_ability) {
            target.ability_name = string_field(*payload, "ability_name");
            if (target.ability_name.empty()) {
                return fail(error, "typed_action_missing_ability_name");
            }
        }
        if (error != nullptr) error->clear();
        return true;
    } catch (const std::exception &exception) {
        return fail(error, exception.what());
    }
}

Value StateCodec::encode_action(const Action &source) const {
    Object payload;
    if (source.kind == ActionKind::declare_attack && source.attack_index.has_value()) {
        payload["attack_index"] = Value(*source.attack_index);
    } else if (source.kind == ActionKind::use_ability) {
        payload["ability_name"] = Value(source.ability_name);
    }
    return Value(Object{
        {"schema_version", Value(4)},
        {"action_id", Value(source.action_id)},
        {"base_revision", Value(source.base_revision)},
        {"actor", Value(source.actor)},
        {"kind", Value(action_kind_to_string(source.kind))},
        {"source", source.source.has_value()
            ? encode_entity_ref(*source.source, *cards_) : Value()},
        {"target", source.target.has_value()
            ? encode_entity_ref(*source.target, *cards_) : Value()},
        {"payload", Value(std::move(payload))},
    });
}

bool StateCodec::decode_choice_view(
    const Value &source,
    ChoiceView &target,
    std::string *error
) const {
    try {
        if (!source.is_object()) return fail(error, "typed_choice_not_object");
        if (integer_field(source, "schema_version", -1) != 2) {
            return fail(error, "typed_choice_schema");
        }
        target.schema_version = 2;
        target.request_id = string_field(source, "request_id");
        target.base_revision = integer_field(source, "base_revision", -1);
        target.player = static_cast<std::int32_t>(integer_field(
            source, "player", -1));
        target.request_type = string_field(source, "request_type");
        target.request_kind = choice_request_kind_from_string(
            target.request_type);
        target.prompt = string_field(source, "prompt");
        target.min_select = integer_field(source, "min_select", -1);
        target.max_select = integer_field(source, "max_select", -1);
        const Value *allow_duplicates = field(source, "allow_duplicates");
        const Value *can_cancel = field(source, "can_cancel");
        const Value *options = field(source, "options");
        const Value *presentation = field(source, "presentation");
        if (
            target.request_id.empty() || target.base_revision < 0
            || target.player < 0 || target.player > 1
            || target.request_type.empty() || target.min_select < 0
            || target.max_select < target.min_select
            || allow_duplicates == nullptr || !allow_duplicates->is_bool()
            || can_cancel == nullptr || !can_cancel->is_bool()
            || options == nullptr || !options->is_array()
            || presentation == nullptr || !presentation->is_object()
        ) return fail(error, "typed_choice_invalid_shape");
        target.allow_duplicates = allow_duplicates->as_bool();
        target.can_cancel = can_cancel->as_bool();
        target.presentation = presentation->deep_clone();
        target.options.clear();
        target.options.reserve(options->as_array().size());
        for (const Value &wire : options->as_array()) {
            if (!wire.is_object()) return fail(
                error, "typed_choice_invalid_option");
            ChoiceOption option;
            option.option_id = string_field(wire, "option_id");
            option.label = string_field(wire, "label");
            option.wire = wire.deep_clone();
            if (option.option_id.empty()) return fail(
                error, "typed_choice_missing_option_id");
            const Value *reference = field(wire, "ref");
            if (reference != nullptr && !reference->is_null()) {
                EntityRef decoded;
                if (!decode_entity_ref(*reference, *cards_, decoded)) {
                    // ChoiceView is a public presentation envelope and its
                    // structurally valid refs are not required to name a card
                    // from the local catalog (tests and remote producers may
                    // use opaque public identities). Keep such a ref in the
                    // preserved wire; typed selectors currently consume only
                    // its public option id/player/slot. Invalid enum/shape data
                    // still throws or fails at the public boundary.
                    if (string_field(*reference, "card_id").empty()) {
                        return fail(error, "typed_choice_invalid_ref");
                    }
                } else {
                    option.ref = decoded;
                }
            }
            target.options.push_back(std::move(option));
        }
        if (error != nullptr) error->clear();
        return true;
    } catch (const std::exception &exception) {
        return fail(error, exception.what());
    }
}

Value StateCodec::encode_choice_view(const ChoiceView &source) const {
    Array options;
    options.reserve(source.options.size());
    for (const ChoiceOption &option : source.options) {
        Value wire = option.wire.is_object()
            ? option.wire.deep_clone() : Value::make_object();
        wire["option_id"] = Value(option.option_id);
        if (wire.contains("label")) wire["label"] = Value(option.label);
        if (option.ref.has_value()) {
            wire["ref"] = encode_entity_ref(*option.ref, *cards_);
        }
        options.push_back(std::move(wire));
    }
    return Value(Object{
        {"schema_version", Value(2)},
        {"request_id", Value(source.request_id)},
        {"base_revision", Value(source.base_revision)},
        {"player", Value(source.player)},
        {"request_type", Value(source.request_type)},
        {"prompt", Value(source.prompt)},
        {"options", Value(std::move(options))},
        {"min_select", Value(source.min_select)},
        {"max_select", Value(source.max_select)},
        {"allow_duplicates", Value(source.allow_duplicates)},
        {"can_cancel", Value(source.can_cancel)},
        {"presentation", source.presentation.deep_clone()},
    });
}

const CardStringTable &StateCodec::cards() const noexcept {
    return *cards_;
}

} // namespace ptcg::ai::typed
