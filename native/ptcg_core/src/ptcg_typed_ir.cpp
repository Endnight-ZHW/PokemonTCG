#include "ptcg_typed_ir.hpp"

#include <array>
#include <utility>

namespace ptcg::ai::typed {

namespace {

template <typename Enum, std::size_t Size>
Enum enum_from_string(
    std::string_view value,
    const std::array<std::pair<std::string_view, Enum>, Size> &rows,
    Enum fallback
) noexcept {
    for (const auto &[name, entry] : rows) {
        if (value == name) return entry;
    }
    return fallback;
}

template <typename Enum, std::size_t Size>
std::string_view enum_to_string(
    Enum value,
    const std::array<std::pair<std::string_view, Enum>, Size> &rows
) noexcept {
    for (const auto &[name, entry] : rows) {
        if (value == entry) return name;
    }
    return {};
}

#define PTCG_VM_OP_ROW(name) std::pair<std::string_view, VmOp>{#name, VmOp::name}
constexpr std::array VM_OP_ROWS{
    PTCG_VM_OP_ROW(apply_attack_lock_basic),
    PTCG_VM_OP_ROW(apply_dazzling_beam),
    PTCG_VM_OP_ROW(apply_outgoing_damage_reduction),
    PTCG_VM_OP_ROW(apply_self_attack_lock),
    PTCG_VM_OP_ROW(apply_status),
    PTCG_VM_OP_ROW(attach_energy),
    PTCG_VM_OP_ROW(attach_energy_from_discard),
    PTCG_VM_OP_ROW(choose_damage_target),
    PTCG_VM_OP_ROW(choose_heal_damage),
    PTCG_VM_OP_ROW(conditional),
    PTCG_VM_OP_ROW(conditional_damage),
    PTCG_VM_OP_ROW(conditional_damage_then_heal),
    PTCG_VM_OP_ROW(conditional_search),
    PTCG_VM_OP_ROW(conditional_status),
    PTCG_VM_OP_ROW(deal_bench_damage),
    PTCG_VM_OP_ROW(deal_damage),
    PTCG_VM_OP_ROW(deal_damage_per_discard_psychic),
    PTCG_VM_OP_ROW(deal_damage_per_energy),
    PTCG_VM_OP_ROW(deal_damage_per_evolved),
    PTCG_VM_OP_ROW(deal_damage_per_hand_size),
    PTCG_VM_OP_ROW(deal_damage_per_self_damage),
    PTCG_VM_OP_ROW(deal_damage_per_self_energy),
    PTCG_VM_OP_ROW(deal_damage_per_self_energy_type),
    PTCG_VM_OP_ROW(deal_damage_plus_bench),
    PTCG_VM_OP_ROW(deal_damage_then_heal),
    PTCG_VM_OP_ROW(deal_damage_with_self_penalty),
    PTCG_VM_OP_ROW(discard_cards),
    PTCG_VM_OP_ROW(discard_energy),
    PTCG_VM_OP_ROW(discard_energy_then_damage),
    PTCG_VM_OP_ROW(discard_hand_then_damage),
    PTCG_VM_OP_ROW(discard_then_draw_cards),
    PTCG_VM_OP_ROW(discard_then_revive),
    PTCG_VM_OP_ROW(draw_and_attach_energy),
    PTCG_VM_OP_ROW(draw_cards),
    PTCG_VM_OP_ROW(draw_until),
    PTCG_VM_OP_ROW(draw_until_more_than_opponent),
    PTCG_VM_OP_ROW(evolve_skip_stage),
    PTCG_VM_OP_ROW(fail_attack),
    PTCG_VM_OP_ROW(flip_coin),
    PTCG_VM_OP_ROW(flip_coin_repeat_damage),
    PTCG_VM_OP_ROW(flip_coin_then_discard_energy),
    PTCG_VM_OP_ROW(flip_coin_then_ko),
    PTCG_VM_OP_ROW(flip_until_tails),
    PTCG_VM_OP_ROW(hand_to_bottom_draw_until),
    PTCG_VM_OP_ROW(hand_to_bottom_then_draw),
    PTCG_VM_OP_ROW(heal_all),
    PTCG_VM_OP_ROW(heal_damage),
    PTCG_VM_OP_ROW(judge),
    PTCG_VM_OP_ROW(look_top_attach_energy),
    PTCG_VM_OP_ROW(look_top_deck),
    PTCG_VM_OP_ROW(mill_then_damage),
    PTCG_VM_OP_ROW(place_counters_then_self_discard),
    PTCG_VM_OP_ROW(place_damage_counters),
    PTCG_VM_OP_ROW(prevent_all),
    PTCG_VM_OP_ROW(prevent_damage),
    PTCG_VM_OP_ROW(prevent_effects),
    PTCG_VM_OP_ROW(register_aura_damage_boost),
    PTCG_VM_OP_ROW(register_aura_damage_reduction),
    PTCG_VM_OP_ROW(register_conditional_hp_boost),
    PTCG_VM_OP_ROW(register_conditional_zero_retreat),
    PTCG_VM_OP_ROW(register_reactive_thorns),
    PTCG_VM_OP_ROW(register_tool_exp_share),
    PTCG_VM_OP_ROW(register_tool_modifier),
    PTCG_VM_OP_ROW(recover_clara),
    PTCG_VM_OP_ROW(relocate_energy),
    PTCG_VM_OP_ROW(return_to_hand),
    PTCG_VM_OP_ROW(search_any_and_switch),
    PTCG_VM_OP_ROW(search_cards),
    PTCG_VM_OP_ROW(search_item_and_tool),
    PTCG_VM_OP_ROW(set_attack_damage_formula),
    PTCG_VM_OP_ROW(set_attack_flags),
    PTCG_VM_OP_ROW(shuffle_from_discard_to_deck),
    PTCG_VM_OP_ROW(shuffle_then_draw_cards),
    PTCG_VM_OP_ROW(switch_pokemon),
    PTCG_VM_OP_ROW(trekking_shoes),
    PTCG_VM_OP_ROW(trigger_draw_cards),
    PTCG_VM_OP_ROW(trigger_move_basic_energy),
    PTCG_VM_OP_ROW(trigger_place_damage_counters),
    PTCG_VM_OP_ROW(trigger_switch_with_active),
    PTCG_VM_OP_ROW(zinnia_resolve),
};
#undef PTCG_VM_OP_ROW

#define PTCG_VM_ARG_ROW(name) std::pair<std::string_view, VmArgKey>{#name, VmArgKey::name}
constexpr std::array VM_ARG_ROWS{
    PTCG_VM_ARG_ROW(amount), PTCG_VM_ARG_ROW(target),
    PTCG_VM_ARG_ROW(scope), PTCG_VM_ARG_ROW(attack_name),
    PTCG_VM_ARG_ROW(status), PTCG_VM_ARG_ROW(filter),
    PTCG_VM_ARG_ROW(from_zone), PTCG_VM_ARG_ROW(going_second_bonus),
    PTCG_VM_ARG_ROW(max_per_target), PTCG_VM_ARG_ROW(min_select),
    PTCG_VM_ARG_ROW(optional), PTCG_VM_ARG_ROW(select_source),
    PTCG_VM_ARG_ROW(to), PTCG_VM_ARG_ROW(energy_type),
    PTCG_VM_ARG_ROW(same_target), PTCG_VM_ARG_ROW(target_pokemon_type),
    PTCG_VM_ARG_ROW(bench_skips_type_matchups), PTCG_VM_ARG_ROW(player),
    PTCG_VM_ARG_ROW(condition), PTCG_VM_ARG_ROW(base),
    PTCG_VM_ARG_ROW(bonus), PTCG_VM_ARG_ROW(default_count),
    PTCG_VM_ARG_ROW(max_count), PTCG_VM_ARG_ROW(choose_targets),
    PTCG_VM_ARG_ROW(count), PTCG_VM_ARG_ROW(formula_ast),
    PTCG_VM_ARG_ROW(ignore_defender_damage_effects),
    PTCG_VM_ARG_ROW(ignore_weakness), PTCG_VM_ARG_ROW(damage),
    PTCG_VM_ARG_ROW(heal), PTCG_VM_ARG_ROW(from),
    PTCG_VM_ARG_ROW(per_energy), PTCG_VM_ARG_ROW(base_damage),
    PTCG_VM_ARG_ROW(threshold), PTCG_VM_ARG_ROW(discard_amount),
    PTCG_VM_ARG_ROW(discard_hand), PTCG_VM_ARG_ROW(draw),
    PTCG_VM_ARG_ROW(draw_amount), PTCG_VM_ARG_ROW(card_id),
    PTCG_VM_ARG_ROW(energy_count), PTCG_VM_ARG_ROW(skip_to),
    PTCG_VM_ARG_ROW(damage_per_head), PTCG_VM_ARG_ROW(flips),
    PTCG_VM_ARG_ROW(per_head), PTCG_VM_ARG_ROW(target_hand_size),
    PTCG_VM_ARG_ROW(destination), PTCG_VM_ARG_ROW(shuffle_rest),
    PTCG_VM_ARG_ROW(take), PTCG_VM_ARG_ROW(mill_count),
    PTCG_VM_ARG_ROW(damage_per), PTCG_VM_ARG_ROW(counters),
    PTCG_VM_ARG_ROW(damage_kind), PTCG_VM_ARG_ROW(pokemon_count),
    PTCG_VM_ARG_ROW(attacker_subtype), PTCG_VM_ARG_ROW(defender_type),
    PTCG_VM_ARG_ROW(before_weakness), PTCG_VM_ARG_ROW(reduction),
    PTCG_VM_ARG_ROW(requires_active), PTCG_VM_ARG_ROW(requires_attached_energy),
    PTCG_VM_ARG_ROW(filter_names), PTCG_VM_ARG_ROW(per_pokemon),
    PTCG_VM_ARG_ROW(effect), PTCG_VM_ARG_ROW(from_self),
    PTCG_VM_ARG_ROW(source_slot), PTCG_VM_ARG_ROW(switch_optional),
    PTCG_VM_ARG_ROW(reveal), PTCG_VM_ARG_ROW(filter_name),
    PTCG_VM_ARG_ROW(ignore_resistance), PTCG_VM_ARG_ROW(affect),
    PTCG_VM_ARG_ROW(shuffle_hand), PTCG_VM_ARG_ROW(you_choose),
    PTCG_VM_ARG_ROW(stadium_type),
};
#undef PTCG_VM_ARG_ROW

const Value *field(const Value &value, std::string_view key) noexcept {
    return value.is_object() ? value.find(std::string(key)) : nullptr;
}

std::string string_field(
    const Value &value,
    std::string_view key,
    std::string fallback = {}
) {
    const Value *entry = field(value, key);
    return entry != nullptr && entry->is_string()
        ? entry->as_string() : std::move(fallback);
}

bool fail(std::string *error, std::string message) {
    if (error != nullptr) *error = std::move(message);
    return false;
}

FormulaOp formula_op_from_string(std::string_view value) noexcept {
    if (value == "damage_counters") return FormulaOp::damage_counters;
    if (value == "bench_count") return FormulaOp::bench_count;
    if (value == "hand_size") return FormulaOp::hand_size;
    if (value == "discard_count") return FormulaOp::discard_count;
    if (value == "energy_count") return FormulaOp::energy_count;
    if (value == "evolved_count") return FormulaOp::evolved_count;
    if (value == "sub") return FormulaOp::subtract;
    if (value == "add") return FormulaOp::add;
    if (value == "mul" || value == "multiply") return FormulaOp::multiply;
    if (value == "if") return FormulaOp::conditional;
    return FormulaOp::invalid;
}

bool compile_formula(
    const Value &source,
    Formula &target,
    std::string *error
) {
    if (!source.is_object()) return fail(error, "typed_vm_formula_not_object");
    if (const Value *constant = field(source, "const")) {
        if (!constant->is_number()) {
            return fail(error, "typed_vm_formula_invalid_constant");
        }
        target.op = FormulaOp::constant;
        target.constant = constant->as_integer();
        return true;
    }
    target.op = formula_op_from_string(string_field(source, "op"));
    if (target.op == FormulaOp::invalid) {
        return fail(error, "typed_vm_formula_unknown_op");
    }
    target.player = string_field(source, "player");
    target.target = string_field(source, "target");
    target.scope = string_field(source, "scope");
    target.energy_type = string_field(source, "energy_type");
    target.condition = string_field(source, "condition");
    if (const Value *filter = field(source, "filter")) {
        if (!filter->is_object()) return fail(error, "typed_vm_formula_invalid_filter");
        target.filter.card_type = string_field(*filter, "card_type");
        target.filter.energy_type = string_field(*filter, "energy_type");
    }
    const auto append_operand = [&](const Value &entry) {
        Formula operand;
        if (!compile_formula(entry, operand, error)) return false;
        target.operands.push_back(std::move(operand));
        return true;
    };
    for (const char *key : {"lhs", "rhs", "then", "else"}) {
        if (const Value *entry = field(source, key)) {
            if (!append_operand(*entry)) return false;
        }
    }
    for (const char *key : {"terms", "factors"}) {
        const Value *entries = field(source, key);
        if (entries == nullptr) continue;
        if (!entries->is_array()) return fail(error, "typed_vm_formula_invalid_operands");
        for (const Value &entry : entries->as_array()) {
            if (!append_operand(entry)) return false;
        }
    }
    return true;
}

std::optional<VmBranchKey> branch_key(std::string_view value) noexcept {
    if (value == "cost") return VmBranchKey::cost;
    if (value == "on_pay") return VmBranchKey::on_pay;
    if (value == "on_heads") return VmBranchKey::on_heads;
    if (value == "on_tails") return VmBranchKey::on_tails;
    return std::nullopt;
}

bool compile_argument(
    std::string_view name,
    const Value &source,
    const CardStringTable &cards,
    VmArgument &target,
    std::string *error
) {
    target.key = vm_arg_key_from_string(name);
    if (target.key == VmArgKey::invalid) {
        return fail(error, "typed_vm_unknown_arg:" + std::string(name));
    }
    if (target.key == VmArgKey::formula_ast) {
        Formula formula;
        if (!compile_formula(source, formula, error)) return false;
        target.value = std::move(formula);
        return true;
    }
    if (target.key == VmArgKey::card_id) {
        if (!source.is_string()) return fail(error, "typed_vm_invalid_card_id_arg");
        const CardId id = cards.find(source.as_string());
        if (id == EMPTY_CARD_ID) return fail(error, "typed_vm_unknown_card_id_arg");
        target.value = VmCardId{id};
        return true;
    }
    if (source.is_bool()) {
        target.value = source.as_bool();
        return true;
    }
    if (source.is_integer()) {
        target.value = source.as_integer();
        return true;
    }
    if (source.type() == Value::Type::number) {
        target.value = source.as_number();
        return true;
    }
    if (source.is_string()) {
        target.value = source.as_string();
        return true;
    }
    if (source.is_array()) {
        std::vector<std::string> values;
        values.reserve(source.as_array().size());
        for (const Value &entry : source.as_array()) {
            if (!entry.is_string()) return fail(error, "typed_vm_invalid_string_array_arg");
            values.push_back(entry.as_string());
        }
        target.value = std::move(values);
        return true;
    }
    return fail(error, "typed_vm_unsupported_arg_type:" + std::string(name));
}

std::size_t count_commands(const VmProgram &program) {
    std::size_t result = program.commands.size();
    for (const VmCommand &command : program.commands) {
        for (const VmBranch &branch : command.branches) {
            if (branch.program) result += count_commands(*branch.program);
        }
    }
    return result;
}

bool compile_named_programs(
    const Value *rows,
    const CardStringTable &cards,
    std::vector<NamedVmProgram> &target,
    std::size_t &program_count,
    std::size_t &command_count,
    std::string *error
) {
    if (rows == nullptr) return true;
    if (!rows->is_array()) return fail(error, "typed_vm_named_programs_not_array");
    target.reserve(rows->as_array().size());
    for (const Value &row : rows->as_array()) {
        if (!row.is_object()) return fail(error, "typed_vm_named_program_not_object");
        NamedVmProgram program;
        program.name = string_field(row, "name");
        program.trigger = string_field(row, "trigger");
        const Value *commands = field(row, "compiled_effects");
        if (commands == nullptr) commands = field(row, "commands");
        if (commands == nullptr) continue;
        if (!compile_vm_program(*commands, cards, program.program, error)) return false;
        ++program_count;
        command_count += count_commands(program.program);
        target.push_back(std::move(program));
    }
    return true;
}

EnergyHook energy_hook_from_string(std::string_view value) noexcept {
    if (value == "MODIFY_DAMAGE") return EnergyHook::modify_damage;
    if (value == "ON_ATTACH") return EnergyHook::on_attach;
    if (value == "AFTER_DAMAGE") return EnergyHook::after_damage;
    if (value == "ON_PRIZE_REVEALED") return EnergyHook::on_prize_revealed;
    return EnergyHook::none;
}

EnergyEffectOp energy_effect_op_from_string(std::string_view value) noexcept {
    if (value == "switch_with_active") return EnergyEffectOp::switch_with_active;
    if (value == "draw_cards") return EnergyEffectOp::draw_cards;
    if (value == "attach_to_benched_pokemon") {
        return EnergyEffectOp::attach_to_benched_pokemon;
    }
    return EnergyEffectOp::none;
}

ModifierScope modifier_scope_from_energy(std::string_view value) noexcept {
    if (value == "attached_attacker") return ModifierScope::attached_attacker;
    if (value == "attached_defender") return ModifierScope::attached_defender;
    return ModifierScope::self;
}

Zone zone_from_energy(std::string_view value) noexcept {
    if (value == "deck") return Zone::deck;
    if (value == "hand") return Zone::hand;
    if (value == "discard") return Zone::discard;
    if (value == "prizes") return Zone::prizes;
    return Zone::none;
}

Slot slot_from_energy(std::string_view value) noexcept {
    if (value == "active") return Slot::active;
    // "bench" is a target class rather than one concrete slot. Slot::bench_0
    // is the typed sentinel; the concrete target is carried by the Action.
    if (value == "bench") return Slot::bench_0;
    return Slot::none;
}

bool compile_energy_effects(
    const Value *rows,
    const CardStringTable &cards,
    std::vector<EnergyEffect> &target,
    std::size_t &program_count,
    std::size_t &command_count,
    std::string *error
) {
    if (rows == nullptr) return true;
    if (!rows->is_array()) return fail(error, "typed_energy_effects_not_array");
    target.reserve(rows->as_array().size());
    for (const Value &row : rows->as_array()) {
        if (!row.is_object()) return fail(error, "typed_energy_effect_not_object");
        EnergyEffect descriptor;
        const std::string kind = string_field(row, "kind");
        if (kind == "provide_energy") {
            descriptor.kind = EnergyEffectKind::provide_energy;
        } else if (kind == "modifier") {
            descriptor.kind = EnergyEffectKind::modifier;
        } else if (kind == "trigger") {
            descriptor.kind = EnergyEffectKind::trigger;
        } else {
            return fail(error, "typed_energy_effect_unknown_kind:" + kind);
        }
        descriptor.hook = energy_hook_from_string(string_field(row, "hook"));
        descriptor.scope = modifier_scope_from_energy(string_field(row, "scope"));
        descriptor.priority = field(row, "priority")
            ? field(row, "priority")->as_integer() : 0;
        descriptor.optional = field(row, "optional")
            ? field(row, "optional")->as_bool() : false;
        descriptor.downgrade_if_other_special =
            field(row, "downgrade_if_other_special")
            ? field(row, "downgrade_if_other_special")->as_bool() : false;
        if (const Value *types = field(row, "types")) {
            if (!types->is_array()) return fail(error, "typed_energy_types_not_array");
            for (const Value &entry : types->as_array()) {
                if (!entry.is_string()) return fail(error, "typed_energy_type_not_string");
                descriptor.provided_types.push_back(entry.as_string());
            }
        }
        if (const Value *condition = field(row, "condition")) {
            if (!condition->is_object()) return fail(error, "typed_energy_condition_not_object");
            descriptor.condition.from_zone = zone_from_energy(
                string_field(*condition, "from_zone"));
            descriptor.condition.source_zone = zone_from_energy(
                string_field(*condition, "source_zone"));
            descriptor.condition.target = slot_from_energy(
                string_field(*condition, "target"));
            descriptor.condition.scope = modifier_scope_from_energy(
                string_field(*condition, "scope"));
            descriptor.condition.min_damage = field(*condition, "min_damage")
                ? field(*condition, "min_damage")->as_integer() : 0;
        }
        if (const Value *effect = field(row, "effect")) {
            if (!effect->is_object()) return fail(error, "typed_energy_effect_payload_not_object");
            descriptor.operation = energy_effect_op_from_string(
                string_field(*effect, "op"));
            descriptor.amount = field(*effect, "amount")
                ? field(*effect, "amount")->as_integer() : 0;
            descriptor.delta = field(*effect, "delta")
                ? field(*effect, "delta")->as_integer() : 0;
        }
        if (const Value *commands = field(row, "compiled_commands")) {
            if (!compile_vm_program(
                *commands, cards, descriptor.compiled_commands, error)) {
                return false;
            }
            ++program_count;
            command_count += count_commands(descriptor.compiled_commands);
        }
        target.push_back(std::move(descriptor));
    }
    return true;
}

} // namespace

VmOp vm_op_from_string(std::string_view value) noexcept {
    return enum_from_string(value, VM_OP_ROWS, VmOp::invalid);
}

std::string_view vm_op_to_string(VmOp value) noexcept {
    return enum_to_string(value, VM_OP_ROWS);
}

VmArgKey vm_arg_key_from_string(std::string_view value) noexcept {
    return enum_from_string(value, VM_ARG_ROWS, VmArgKey::invalid);
}

std::string_view vm_arg_key_to_string(VmArgKey value) noexcept {
    return enum_to_string(value, VM_ARG_ROWS);
}

bool compile_vm_program(
    const Value &source,
    const CardStringTable &cards,
    VmProgram &target,
    std::string *error
) {
    if (!source.is_array()) return fail(error, "typed_vm_program_not_array");
    target.commands.clear();
    target.commands.reserve(source.as_array().size());
    for (const Value &row : source.as_array()) {
        if (!row.is_object()) return fail(error, "typed_vm_command_not_object");
        VmCommand command;
        command.op = vm_op_from_string(string_field(row, "op"));
        if (command.op == VmOp::invalid) {
            return fail(error, "typed_vm_unknown_op:" + string_field(row, "op"));
        }
        const Value *arguments = field(row, "args");
        if (arguments != nullptr) {
            if (!arguments->is_object()) return fail(error, "typed_vm_args_not_object");
            command.arguments.reserve(arguments->as_object().size());
            for (const auto &[name, value] : arguments->as_object()) {
                VmArgument argument;
                if (!compile_argument(name, value, cards, argument, error)) return false;
                command.arguments.push_back(std::move(argument));
            }
        }
        const Value *branches = field(row, "branches");
        if (branches != nullptr) {
            if (!branches->is_object()) return fail(error, "typed_vm_branches_not_object");
            command.branches.reserve(branches->as_object().size());
            for (const auto &[name, value] : branches->as_object()) {
                const auto key = branch_key(name);
                if (!key.has_value()) return fail(error, "typed_vm_unknown_branch:" + name);
                auto program = std::make_shared<VmProgram>();
                if (!compile_vm_program(value, cards, *program, error)) return false;
                command.branches.push_back(VmBranch{*key, std::move(program)});
            }
        }
        target.commands.push_back(std::move(command));
    }
    if (error != nullptr) error->clear();
    return true;
}

VmCatalog::VmCatalog(
    const Value &cards,
    std::shared_ptr<const CardStringTable> card_strings
) : card_strings_(std::move(card_strings)) {
    if (!card_strings_ || !cards.is_object()) {
        error_ = "typed_vm_catalog_invalid_input";
        return;
    }
    cards_.resize(card_strings_->size() + 1);
    for (const auto &[card_name, row] : cards.as_object()) {
        const CardId id = card_strings_->find(card_name);
        if (id == EMPTY_CARD_ID || !row.is_object()) {
            error_ = "typed_vm_catalog_invalid_card";
            return;
        }
        CompiledCardIr card;
        card.card_id = id;
        const auto compile_direct = [&](const char *key, VmProgram &program) {
            const Value *commands = field(row, key);
            if (commands == nullptr) return true;
            if (!compile_vm_program(*commands, *card_strings_, program, &error_)) {
                return false;
            }
            ++program_count_;
            command_count_ += count_commands(program);
            return true;
        };
        if (!compile_direct("compiled_trainer_effects", card.trainer)
            || !compile_energy_effects(
                field(row, "energy_effects"), *card_strings_, card.energy_effects,
                program_count_, command_count_, &error_)
            || !compile_named_programs(
                field(row, "attacks"), *card_strings_, card.attacks,
                program_count_, command_count_, &error_)
            || !compile_named_programs(
                field(row, "abilities"), *card_strings_, card.abilities,
                program_count_, command_count_, &error_)) {
            return;
        }
        cards_[id] = std::move(card);
    }
}

bool VmCatalog::valid() const noexcept { return error_.empty(); }
const std::string &VmCatalog::error() const noexcept { return error_; }
std::size_t VmCatalog::card_count() const noexcept {
    std::size_t count = 0;
    for (const auto &entry : cards_) count += entry.has_value() ? 1U : 0U;
    return count;
}
std::size_t VmCatalog::program_count() const noexcept { return program_count_; }
std::size_t VmCatalog::command_count() const noexcept { return command_count_; }
const CompiledCardIr *VmCatalog::card(CardId id) const noexcept {
    return id < cards_.size() && cards_[id].has_value() ? &*cards_[id] : nullptr;
}

} // namespace ptcg::ai::typed
