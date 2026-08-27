#pragma once

#include "ptcg_value.hpp"

#include <array>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace ptcg::ai::typed {

using CardId = std::uint32_t;
inline constexpr CardId EMPTY_CARD_ID = 0;

// Match-local card ids are interned once with the immutable catalog.  The
// numeric representation is never exposed through Snapshot 3 or Action v4.
class CardStringTable {
public:
    explicit CardStringTable(const Value &cards = Value::make_object());

    CardId find(std::string_view value) const noexcept;
    const std::string &resolve(CardId value) const noexcept;
    std::size_t size() const noexcept;

private:
    std::vector<std::string> values_{std::string{}};
    std::unordered_map<std::string, CardId> ids_;
};

enum class Phase : std::uint8_t {
    setup,
    draw,
    main,
    attack,
    checkup,
    game_over,
};

enum class SetupStage : std::uint8_t {
    turn_order,
    initial_placement,
    bonus_draw,
    bonus_placement,
    complete,
};

enum class EntityKind : std::uint8_t {
    none,
    card,
    pokemon,
    slot,
    attachment,
};

enum class Zone : std::uint8_t {
    none,
    deck,
    hand,
    discard,
    prizes,
    stadium,
};

enum class Slot : std::int8_t {
    none = -1,
    active = 0,
    bench_0 = 1,
    bench_1 = 2,
    bench_2 = 3,
    bench_3 = 4,
    bench_4 = 5,
};

enum class AttachmentType : std::uint8_t {
    none,
    energy,
    tool,
};

enum class ActionKind : std::uint8_t {
    play_basic,
    evolve,
    attach_energy,
    play_trainer,
    use_ability,
    use_stadium,
    retreat,
    declare_attack,
    promote,
    setup_done,
    end_turn,
    noop,
};

struct EntityRef {
    EntityKind kind = EntityKind::none;
    std::int32_t player = -1;
    Zone zone = Zone::none;
    Slot slot = Slot::none;
    std::int32_t index = -1;
    AttachmentType attachment_type = AttachmentType::none;
    CardId card_id = EMPTY_CARD_ID;

    bool operator==(const EntityRef &other) const noexcept {
        return kind == other.kind
            && player == other.player
            && zone == other.zone
            && slot == other.slot
            && index == other.index
            && attachment_type == other.attachment_type
            && card_id == other.card_id;
    }
};

struct Action {
    ActionKind kind = ActionKind::noop;
    std::int32_t actor = -1;
    std::int64_t base_revision = -1;
    std::string action_id;
    std::optional<EntityRef> source;
    std::optional<EntityRef> target;
    std::optional<std::int64_t> attack_index;
    std::string ability_name;
};

enum class ChoiceRequestKind : std::uint8_t {
    other,
    choose_turn_order,
    choose_mulligan_draw_count,
    select_prize,
    select_retreat_payment,
    confirm_trigger,
    confirm,
    coin_flip,
};

struct ChoiceOption {
    std::string option_id;
    std::string label;
    std::optional<EntityRef> ref;
    // Preserve forward-compatible producer metadata while hot-path selectors
    // consume the typed members above.
    Value wire = Value::make_object();
};

struct ChoiceView {
    std::int64_t schema_version = 2;
    std::string request_id;
    std::int64_t base_revision = -1;
    std::int32_t player = -1;
    ChoiceRequestKind request_kind = ChoiceRequestKind::other;
    std::string request_type;
    std::string prompt;
    std::vector<ChoiceOption> options;
    std::int64_t min_select = 0;
    std::int64_t max_select = 0;
    bool allow_duplicates = false;
    bool can_cancel = false;
    Value presentation = Value::make_object();
};

enum class ModifierHook : std::uint8_t {
    modify_damage,
    max_hp,
    can_retreat,
    can_attack,
    prevent_effects,
};

enum class ModifierLayer : std::uint8_t {
    base_replacement,
    attacker_adjust,
    weakness,
    resistance,
    defender_adjust,
    prevent,
    clamp,
    base,
    add,
    set,
    permission,
    gate,
};

enum class ModifierScope : std::uint8_t {
    self,
    attached_attacker,
    attached_defender,
    active,
    allied_board,
};

enum class ModifierDuration : std::uint8_t {
    persistent,
    until_leave_play,
    until_switch_or_evolve,
    until_end_of_turn,
    until_end_of_opponents_next_turn,
    until_next_attack,
};

enum class ModifierStacking : std::uint8_t {
    stack,
    replace_same_source,
    maximum,
    unique,
};

enum class ModifierConflict : std::uint8_t {
    commutative,
    controller_choice,
};

enum class ModifierOperationKind : std::uint8_t {
    damage_delta,
    prevent_damage,
    hp_delta,
    retreat_delta,
    retreat_set,
    attack_lock,
    attack_gate_coin,
    prevent_effects,
};

struct ModifierCondition {
    std::optional<std::string> attacker_subtype;
    std::optional<std::string> defender_type;
    std::optional<bool> requires_attached_energy;
    std::optional<std::string> energy_type;
    std::optional<std::int64_t> threshold;
    std::optional<bool> behind_on_prizes;
    std::optional<bool> target_active;
    std::optional<std::string> target_stage;
    std::optional<bool> target_basic;
    std::optional<std::int64_t> expires_after_turn;
};

struct ModifierOperation {
    ModifierOperationKind kind = ModifierOperationKind::damage_delta;
    std::int64_t number = 0;
    std::string text;
};

struct Modifier {
    ModifierHook hook = ModifierHook::modify_damage;
    ModifierLayer layer = ModifierLayer::attacker_adjust;
    std::int64_t priority = 0;
    std::int32_t controller = 0;
    EntityRef source_ref;
    ModifierScope scope = ModifierScope::self;
    ModifierDuration duration = ModifierDuration::persistent;
    ModifierStacking stacking = ModifierStacking::stack;
    ModifierConflict conflict = ModifierConflict::commutative;
    ModifierCondition condition;
    ModifierOperation operation;
};

struct PokemonState {
    CardId card_id = EMPTY_CARD_ID;
    std::int64_t damage_counters = 0;
    std::vector<CardId> energy_card_ids;
    CardId attached_tool_id = EMPTY_CARD_ID;
    std::vector<std::string> status_conditions;
    std::vector<CardId> evolution_stack_ids;
    bool can_evolve_this_turn = true;
    bool placed_this_turn = true;
    bool damage_prevented = false;
    bool all_prevented = false;
    std::int64_t outgoing_damage_reduction = 0;
    // Frozen GameState.clone_state() intentionally omits these legacy DTO
    // compatibility fields. Preserve their wire presence independently from
    // their typed value so a typed authoritative round-trip remains byte exact.
    bool has_damage_prevented_field = true;
    bool has_all_prevented_field = true;
    bool has_outgoing_damage_reduction_field = true;
    std::vector<std::string> used_abilities;
    bool healed_this_turn = false;
    std::vector<Modifier> modifiers;
    std::int64_t paralyzed_since_turn = 0;
};

struct PlayerState {
    std::string name;
    std::vector<CardId> deck;
    std::vector<CardId> hand;
    std::vector<CardId> discard;
    std::vector<CardId> prizes;
    std::optional<PokemonState> active;
    std::array<std::optional<PokemonState>, 5> bench;
    bool supporter_played_this_turn = false;
    bool energy_attached_this_turn = false;
    bool retreated_this_turn = false;
    bool stadium_played_this_turn = false;
    bool stadium_used_this_turn = false;
    bool healed_this_turn = false;
    bool vstar_power_used = false;
    bool was_ko_by_attack = false;
    std::unordered_map<std::string, std::int64_t> attack_locked_names;
};

struct KnockoutFact {
    std::int32_t defeated_player = -1;
    std::int32_t source_player = -1;
    std::string source_kind;
    std::string cause_kind;
    std::string cause_detail;
    CardId card_id = EMPTY_CARD_ID;
    std::string slot = "active";
    std::int64_t turn = 0;
};

struct TurnFactBook {
    std::vector<KnockoutFact> current_turn_knockouts;
    std::vector<KnockoutFact> previous_turn_knockouts;
};

enum class ResolutionFrameKind : std::uint8_t {
    command,
    continuation,
    trigger_batch,
    trigger,
    barrier,
};

// Frame payload variants are migrated independently from the match state.  A
// Raw payload is retained only by the boundary codec; RulesSession never
// reads it through string-key lookup after the typed executor is enabled.
struct ResolutionFrame {
    ResolutionFrameKind kind = ResolutionFrameKind::command;
    Value wire_payload = Value::make_object();
};

struct ResolutionStack {
    std::int64_t schema_version = 3;
    std::vector<ResolutionFrame> frames;
    Value pending_request;
    std::int64_t sequence = 0;
    Value context = Value::make_object();
};

struct GameState {
    std::array<PlayerState, 2> players;
    std::int32_t active_player_idx = 0;
    Phase phase = Phase::setup;
    std::int64_t turn_number = 0;
    std::int32_t first_player_idx = 0;
    CardId stadium_card_id = EMPTY_CARD_ID;
    std::int32_t stadium_owner_idx = -1;
    std::int32_t winner = -1;
    std::string result_status = "ONGOING";
    std::string result_reason;
    std::array<std::vector<std::string>, 2> result_conditions;
    std::int64_t revision = 0;
    std::int64_t choice_sequence = 0;
    std::array<std::string, 2> public_deck_keys;
    bool apply_type_matchups = false;
    std::string rules_profile_id = "CN_MAINLAND_3_1_0";
    std::vector<std::string> action_log;
    std::array<std::int64_t, 2> mulligan_count{0, 0};
    std::array<std::int64_t, 2> extra_draws{0, 0};
    std::array<bool, 2> setup_ready{false, false};
    SetupStage setup_stage = SetupStage::turn_order;
    std::int32_t setup_actor_idx = -1;
    std::int32_t opening_coin_winner_idx = -1;
    std::int64_t mulligan_bonus_max = 0;
    std::array<std::vector<CardId>, 2> setup_bonus_card_ids;
    std::vector<std::int32_t> pending_promotions;
    std::vector<std::string> processed_action_ids;
    TurnFactBook turn_fact_book;
    ResolutionStack resolution_stack;
};

class StateCodec {
public:
    explicit StateCodec(std::shared_ptr<const CardStringTable> cards);

    bool decode_state(
        const Value &source,
        GameState &target,
        std::string *error = nullptr
    ) const;
    Value encode_state(const GameState &source) const;

    bool decode_action(
        const Value &source,
        Action &target,
        std::string *error = nullptr
    ) const;
    Value encode_action(const Action &source) const;

    bool decode_choice_view(
        const Value &source,
        ChoiceView &target,
        std::string *error = nullptr
    ) const;
    Value encode_choice_view(const ChoiceView &source) const;

    const CardStringTable &cards() const noexcept;

private:
    std::shared_ptr<const CardStringTable> cards_;
};

} // namespace ptcg::ai::typed
