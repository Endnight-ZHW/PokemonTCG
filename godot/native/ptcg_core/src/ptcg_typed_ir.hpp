#pragma once

#include "ptcg_typed_state.hpp"
#include "ptcg_value.hpp"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <variant>
#include <vector>

namespace ptcg::ai::typed {

enum class VmOp : std::uint8_t {
    invalid,
    apply_attack_lock_basic,
    apply_dazzling_beam,
    apply_outgoing_damage_reduction,
    apply_self_attack_lock,
    apply_status,
    attach_energy,
    attach_energy_from_discard,
    choose_damage_target,
    choose_heal_damage,
    conditional,
    conditional_damage,
    conditional_damage_then_heal,
    conditional_search,
    conditional_status,
    deal_bench_damage,
    deal_damage,
    deal_damage_per_discard_psychic,
    deal_damage_per_energy,
    deal_damage_per_evolved,
    deal_damage_per_hand_size,
    deal_damage_per_self_damage,
    deal_damage_per_self_energy,
    deal_damage_per_self_energy_type,
    deal_damage_plus_bench,
    deal_damage_then_heal,
    deal_damage_with_self_penalty,
    discard_cards,
    discard_energy,
    discard_energy_then_damage,
    discard_hand_then_damage,
    discard_then_draw_cards,
    discard_then_revive,
    draw_and_attach_energy,
    draw_cards,
    draw_until,
    draw_until_more_than_opponent,
    evolve_skip_stage,
    fail_attack,
    flip_coin,
    flip_coin_repeat_damage,
    flip_coin_then_discard_energy,
    flip_coin_then_ko,
    flip_until_tails,
    hand_to_bottom_draw_until,
    hand_to_bottom_then_draw,
    heal_all,
    heal_damage,
    judge,
    look_top_attach_energy,
    look_top_deck,
    mill_then_damage,
    place_counters_then_self_discard,
    place_damage_counters,
    prevent_all,
    prevent_damage,
    prevent_effects,
    register_aura_damage_boost,
    register_aura_damage_reduction,
    register_conditional_hp_boost,
    register_conditional_zero_retreat,
    register_reactive_thorns,
    register_tool_exp_share,
    register_tool_modifier,
    recover_clara,
    relocate_energy,
    return_to_hand,
    search_any_and_switch,
    search_cards,
    search_item_and_tool,
    set_attack_damage_formula,
    set_attack_flags,
    shuffle_from_discard_to_deck,
    shuffle_then_draw_cards,
    switch_pokemon,
    trekking_shoes,
    trigger_draw_cards,
    trigger_move_basic_energy,
    trigger_place_damage_counters,
    trigger_switch_with_active,
    zinnia_resolve,
};

VmOp vm_op_from_string(std::string_view value) noexcept;
std::string_view vm_op_to_string(VmOp value) noexcept;

enum class VmArgKey : std::uint8_t {
    invalid,
    amount,
    target,
    scope,
    attack_name,
    status,
    filter,
    from_zone,
    going_second_bonus,
    max_per_target,
    min_select,
    optional,
    select_source,
    to,
    energy_type,
    same_target,
    target_pokemon_type,
    bench_skips_type_matchups,
    player,
    condition,
    base,
    bonus,
    default_count,
    max_count,
    choose_targets,
    count,
    formula_ast,
    ignore_defender_damage_effects,
    ignore_weakness,
    damage,
    heal,
    from,
    per_energy,
    base_damage,
    threshold,
    discard_amount,
    discard_hand,
    draw,
    draw_amount,
    card_id,
    energy_count,
    skip_to,
    damage_per_head,
    flips,
    per_head,
    target_hand_size,
    destination,
    shuffle_rest,
    take,
    mill_count,
    damage_per,
    counters,
    damage_kind,
    pokemon_count,
    attacker_subtype,
    defender_type,
    before_weakness,
    reduction,
    requires_active,
    requires_attached_energy,
    filter_names,
    per_pokemon,
    effect,
    from_self,
    source_slot,
    switch_optional,
    reveal,
    filter_name,
    ignore_resistance,
    affect,
    shuffle_hand,
    you_choose,
    stadium_type,
};

VmArgKey vm_arg_key_from_string(std::string_view value) noexcept;
std::string_view vm_arg_key_to_string(VmArgKey value) noexcept;

enum class FormulaOp : std::uint8_t {
    invalid,
    constant,
    damage_counters,
    bench_count,
    hand_size,
    discard_count,
    energy_count,
    evolved_count,
    subtract,
    add,
    multiply,
    conditional,
};

struct FormulaFilter {
    std::string card_type;
    std::string energy_type;
};

struct Formula {
    FormulaOp op = FormulaOp::invalid;
    std::int64_t constant = 0;
    std::string player;
    std::string target;
    std::string scope;
    std::string energy_type;
    std::string condition;
    FormulaFilter filter;
    std::vector<Formula> operands;
};

struct VmCardId {
    CardId value = EMPTY_CARD_ID;
};

using VmArgumentValue = std::variant<
    bool,
    std::int64_t,
    double,
    std::string,
    VmCardId,
    std::vector<std::string>,
    Formula
>;

struct VmArgument {
    VmArgKey key = VmArgKey::invalid;
    VmArgumentValue value = std::int64_t{0};
};

enum class VmBranchKey : std::uint8_t {
    cost,
    on_pay,
    on_heads,
    on_tails,
};

struct VmProgram;

struct VmBranch {
    VmBranchKey key = VmBranchKey::cost;
    std::shared_ptr<const VmProgram> program;
};

struct VmCommand {
    VmOp op = VmOp::invalid;
    std::vector<VmArgument> arguments;
    std::vector<VmBranch> branches;
};

struct VmProgram {
    std::vector<VmCommand> commands;
};

struct NamedVmProgram {
    std::string name;
    std::string trigger;
    VmProgram program;
};

enum class EnergyEffectKind : std::uint8_t {
    provide_energy,
    modifier,
    trigger,
};

enum class EnergyHook : std::uint8_t {
    none,
    modify_damage,
    on_attach,
    after_damage,
    on_prize_revealed,
};

enum class EnergyEffectOp : std::uint8_t {
    none,
    switch_with_active,
    draw_cards,
    attach_to_benched_pokemon,
};

struct EnergyCondition {
    Zone from_zone = Zone::none;
    Zone source_zone = Zone::none;
    Slot target = Slot::none;
    ModifierScope scope = ModifierScope::self;
    std::int64_t min_damage = 0;
};

struct EnergyEffect {
    EnergyEffectKind kind = EnergyEffectKind::provide_energy;
    EnergyHook hook = EnergyHook::none;
    EnergyEffectOp operation = EnergyEffectOp::none;
    ModifierScope scope = ModifierScope::self;
    std::vector<std::string> provided_types;
    bool downgrade_if_other_special = false;
    bool optional = false;
    std::int64_t priority = 0;
    std::int64_t amount = 0;
    std::int64_t delta = 0;
    EnergyCondition condition;
    VmProgram compiled_commands;
};

struct CompiledCardIr {
    CardId card_id = EMPTY_CARD_ID;
    VmProgram trainer;
    std::vector<EnergyEffect> energy_effects;
    std::vector<NamedVmProgram> attacks;
    std::vector<NamedVmProgram> abilities;
};

class VmCatalog {
public:
    VmCatalog(
        const Value &cards,
        std::shared_ptr<const CardStringTable> card_strings
    );

    bool valid() const noexcept;
    const std::string &error() const noexcept;
    std::size_t card_count() const noexcept;
    std::size_t program_count() const noexcept;
    std::size_t command_count() const noexcept;
    const CompiledCardIr *card(CardId id) const noexcept;

private:
    std::shared_ptr<const CardStringTable> card_strings_;
    std::vector<std::optional<CompiledCardIr>> cards_;
    std::size_t program_count_ = 0;
    std::size_t command_count_ = 0;
    std::string error_;
};

bool compile_vm_program(
    const Value &source,
    const CardStringTable &cards,
    VmProgram &target,
    std::string *error = nullptr
);

} // namespace ptcg::ai::typed
