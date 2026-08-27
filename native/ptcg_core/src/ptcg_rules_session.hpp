#pragma once

#include "ptcg_game.hpp"
#include "ptcg_typed_ir.hpp"
#include "ptcg_typed_state.hpp"
#include "ptcg_value.hpp"

#include <cstdint>
#include <memory>
#include <optional>
#include <stdexcept>
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
    // Ungrouped, state-bound candidates for the native search controller.
    // The reference remains valid until this session mutates or another actor
    // is queried. Public bindings continue to expose grouped Action v4 data.
    const Value &search_legal_action_candidates(std::int32_t actor) const;
    std::int64_t pokemon_max_hp(const Value &pokemon) const;
    std::int64_t pokemon_current_hp(const Value &pokemon) const;
    std::int64_t estimate_public_damage(
        std::int32_t actor,
        const Value &attacker,
        const Value &defender,
        std::int64_t base_damage
    ) const;
    Value pending_choice(std::int32_t viewer) const;
    // Search-only borrowed view. It remains valid until the session mutates.
    const Value &search_pending_choice(std::int32_t viewer) const noexcept;
    const typed::ChoiceView *typed_search_pending_choice(
        std::int32_t viewer
    ) const;
    // Native AI-only continuation handoff. Bindings deliberately do not
    // expose this value; it stays inside the C++ actor/search boundary.
    Value search_continuation() const;
    RulesSessionResult apply_action(const Value &action);
    // AI-only strict fast path. The action must be one of the candidates
    // generated for this exact revision/actor. Public callers continue to use
    // apply_action(), which always performs an independent legality query.
    RulesSessionResult apply_action_for_search(const Value &action);
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
    // Frozen turn_beam_v2 clones a DTO before searching opponent replies.
    // This compact COW projection preserves that clone's exact field semantics
    // without serializing or deep-copying the complete Snapshot 3 payload.
    std::unique_ptr<RulesSession> fork_for_reply_search() const;

    Value contract() const;
    Value journal() const;
    std::string state_hash() const;
    std::uint32_t rng_state() const noexcept;
    std::int64_t revision() const noexcept;
    // Read-only C++ search view. This deliberately has no binding surface:
    // callers inside the native planner may inspect recursively-COW state
    // without allocating a Snapshot 3 clone at every node.
    const Value &search_state() const noexcept;
    const typed::GameState &typed_search_state() const;

private:
    struct CatalogContext {
        Value cards;
        std::shared_ptr<const typed::CardStringTable> card_strings;
        typed::StateCodec state_codec;
        typed::VmCatalog vm_catalog;
        NativeGameKernel game;

        explicit CatalogContext(Value value)
            : cards(std::move(value)),
              card_strings(std::make_shared<typed::CardStringTable>(cards)),
              state_codec(card_strings),
              vm_catalog(cards, card_strings),
              game(cards) {}
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
    mutable std::int64_t legal_cache_revision_ = -1;
    mutable std::int32_t legal_cache_actor_ = -1;
    mutable Value legal_cache_candidates_ = Value::make_array();
    mutable std::shared_ptr<const std::vector<typed::Action>>
        typed_legal_cache_;
    // The typed state is authoritative after every successful transaction.
    // state_ is a recursively-COW, byte-equivalent VM execution projection.
    std::shared_ptr<const typed::GameState> authoritative_state_;
    mutable std::optional<typed::ChoiceView> typed_pending_cache_;
    mutable std::int64_t typed_pending_cache_revision_ = -1;
    mutable std::string typed_pending_cache_request_id_;

    const Value &cards() const noexcept;
    const NativeGameKernel &game() const noexcept;
    const typed::GameState &typed_state() const;
    bool commit_authoritative_state(std::string *error = nullptr);
    bool populate_legal_cache(std::int32_t actor) const;
    RulesSessionResult apply_action_impl(
        const Value &action,
        bool use_search_candidate_cache
    );

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
