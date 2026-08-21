#pragma once

#include "ptcg_game.hpp"
#include "ptcg_value.hpp"

#include <cstdint>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace ptcg::ai {

inline constexpr int NATIVE_RULES_SESSION_ABI_VERSION = 2;
inline constexpr int MATCH_JOURNAL_FORMAT_VERSION = 1;
inline constexpr int SNAPSHOT_SCHEMA_VERSION = 3;

struct RulesSessionResult {
    bool success = false;
    std::string error_code;
    std::string message_key;
    Value state = Value::make_object();
    Value pending = Value();
    std::vector<Value> events;
    std::uint32_t rng_state = 0;
    std::int32_t winner = -1;
    bool terminal = false;
};

// Stateful, dependency-free owner for one authoritative match.  Godot and
// Python bindings expose this object; neither binding is allowed to mutate the
// state or RNG independently.
class RulesSession {
public:
    explicit RulesSession(Value cards = Value::make_object());
    RulesSession(const RulesSession &) = default;
    RulesSession &operator=(const RulesSession &) = default;

    void set_cards(Value cards);
    bool initialized() const noexcept;

    RulesSessionResult create(
        const Value &catalog,
        const Value &decks,
        const Value &match_config,
        std::uint32_t seed
    );
    RulesSessionResult create(
        const Value &decks,
        const Value &match_config,
        std::uint32_t seed
    );
    RulesSessionResult load_scenario(
        const Value &snapshot,
        std::uint32_t rng_state,
        const Value &match_config = Value::make_object()
    );

    Value legal_actions(std::int32_t actor) const;
    std::int64_t pokemon_max_hp(const Value &pokemon) const;
    std::int64_t pokemon_current_hp(const Value &pokemon) const;
    std::int64_t estimate_public_damage(
        std::int32_t actor,
        const Value &attacker,
        const Value &defender,
        std::int64_t base_damage
    ) const;
    Value pending_choice(std::int32_t viewer) const;
    // Native AI-only continuation handoff. Bindings deliberately do not
    // expose this value; it stays inside the C++ actor/search boundary.
    Value search_continuation() const;
    RulesSessionResult apply_action(const Value &action);
    RulesSessionResult apply_choice(const Value &response);
    RulesSessionResult concede(std::int32_t actor);

    Value view_for(std::int32_t viewer) const;
    Value snapshot() const;
    bool restore(
        const Value &snapshot,
        std::uint32_t rng_state,
        std::string *error = nullptr
    );
    std::unique_ptr<RulesSession> fork() const;
    // AI-only immutable branch operation. The parent state/RNG is untouched;
    // the returned copy starts the next simulated action from the supplied
    // deterministic RNG state.
    std::unique_ptr<RulesSession> fork_for_search(
        std::uint32_t rng_state
    ) const;

    Value contract() const;
    Value journal() const;
    std::string state_hash() const;
    std::uint32_t rng_state() const noexcept;
    std::int64_t revision() const noexcept;

private:
    struct CatalogContext {
        Value cards;
        NativeGameKernel game;

        explicit CatalogContext(Value value)
            : cards(std::move(value)), game(cards) {}
    };

    // Card definitions and rule kernels are immutable after a session starts.
    // Search forks share this context instead of copying the full catalog twice
    // for every expanded node.
    std::shared_ptr<const CatalogContext> catalog_;
    Value state_ = Value::make_object();
    Value pending_;
    Value pending_raw_;
    Value continuation_;
    Value match_config_ = Value::make_object();
    Value journal_entries_ = Value::make_array();
    std::string card_ir_content_fingerprint_;
    std::string card_ir_contract_fingerprint_;
    std::string vm_descriptor_digest_;
    std::uint32_t initial_seed_ = 0;
    std::uint32_t rng_state_ = 0;
    bool initialized_ = false;
    bool search_mode_ = false;

    const Value &cards() const noexcept;
    const NativeGameKernel &game() const noexcept;

    RulesSessionResult commit_game_result(
        const GameExecutionResult &result,
        const std::string &entry_kind,
        const Value &input,
        std::int64_t revision_before
    );
    RulesSessionResult result(
        bool success,
        std::string error_code = {},
        std::string message_key = {},
        std::vector<Value> events = {}
    ) const;
    void materialize_resolution_stack();
    void clear_resolution_stack();
    void set_pending(Value pending, Value continuation);
    void append_journal_entry(
        const std::string &kind,
        const Value &input,
        std::int64_t revision_before,
        const std::vector<Value> &events
    );
};

std::string canonical_value_hash(const Value &value);

} // namespace ptcg::ai
