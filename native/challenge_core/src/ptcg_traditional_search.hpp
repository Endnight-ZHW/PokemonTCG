#pragma once

#include "ptcg_rules_session.hpp"
#include "ptcg_value.hpp"

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <map>
#include <string>
#include <vector>

namespace ptcg::ai {

inline constexpr int NATIVE_TRADITIONAL_SEARCH_VERSION = 1;

struct TraditionalSearchConfig {
    std::size_t root_actions = 8;
    std::size_t per_root_width = 2;
    std::size_t max_depth = 8;
    std::size_t actions_per_node = 8;
    std::size_t reply_depth = 3;
    std::size_t reply_width = 4;
    std::size_t reply_actions_per_node = 4;
    std::size_t belief_samples = 3;
    // One keeps evaluation batches single-threaded. Gameplay may raise this
    // to the platform default while result reduction remains sample-ordered.
    std::size_t worker_count = 1;

    void validate() const;
};

struct TraditionalRankedAction {
    Value action = Value::make_object();
    std::int64_t score_milli = 0;
    std::string signature;
    std::string semantic_bucket;
    std::string purpose_bucket;
    std::size_t source_index = 0;
};

struct TraditionalSearchResult {
    bool success = false;
    bool cancelled = false;
    std::string error;
    Value selected = Value::make_object();
    Value::Array sequence;
    Value::Array cache_preconditions;
    Value::Array root_candidates;
    std::int64_t score_milli = 0;
    std::int64_t worst_score_milli = 0;
    std::uint64_t nodes_expanded = 0;
    std::size_t completed_depth = 0;
    std::size_t max_path_depth = 0;
    std::size_t reply_completed_depth = 0;
    bool reply_depth_applicable = false;
    std::string completion_reason;
    std::string trajectory_hash;
    std::uint64_t trajectory_events = 0;
    std::size_t belief_samples = 0;
    std::size_t belief_consensus = 0;
    std::vector<std::string> root_signatures_attempted;
    std::map<std::string, std::size_t> root_sample_counts;
    std::string belief_seed_hash;
    std::string opponent_strategy_id;
    std::size_t layers_completed = 0;
    std::vector<std::string> reply_completion_reasons;
    std::string reply_completion_reason = "not_applicable";
};

struct TraditionalChoiceTrace {
    bool had_choice = false;
    bool unpredictable = false;
};

struct TraditionalReplyEvaluation {
    std::int64_t score_milli = 0;
    std::uint64_t nodes_expanded = 0;
    bool cancelled = false;
    bool applicable = false;
    std::size_t completed_depth = 0;
    std::string completion_reason;
    std::shared_ptr<RulesSession> resulting_position;
};

// Shared rules/semantic boundary for turn_beam_v2 and strategic_intent_v3.
// Traversals own their ordering and seed derivation; providers own game policy.
class TraditionalSearchProvider {
public:
    virtual ~TraditionalSearchProvider() = default;

    virtual std::unique_ptr<RulesSession> determinize(
        std::size_t sample_index,
        std::uint32_t seed
    ) = 0;
    virtual std::vector<TraditionalRankedAction> ranked_actions(
        const RulesSession &position,
        std::int32_t actor,
        const Value &supplied_actions,
        std::size_t limit
    ) = 0;
    virtual std::int64_t state_score_milli(
        const RulesSession &position,
        std::int32_t root_actor
    ) = 0;
    virtual bool resolve_pending(
        RulesSession &position,
        std::int32_t decision_actor,
        std::uint64_t &nodes_expanded,
        TraditionalChoiceTrace &trace
    ) = 0;
    virtual std::int32_t decision_actor(const RulesSession &position) = 0;
    virtual bool terminal(const RulesSession &position) = 0;
    virtual std::string state_fingerprint(const RulesSession &position) = 0;
    virtual bool action_ends_turn(const Value &action) = 0;
    virtual Value bind_action(
        const Value &candidate,
        const RulesSession &position,
        std::int32_t actor,
        const std::string &action_id
    ) = 0;
    virtual std::uint32_t branch_seed(
        std::uint32_t base_seed,
        std::size_t depth,
        const std::string &root_signature,
        const std::string &sequence_signature,
        std::size_t action_index
    ) = 0;
    virtual std::string trace_seed() = 0;
    virtual std::string trace_event(
        const std::string &previous_hash,
        const std::string &event
    ) = 0;
    virtual std::string sha256_text(const std::string &value) = 0;
    virtual std::string deck_key_for_actor(
        const RulesSession &position,
        std::int32_t actor
    ) = 0;
    virtual std::string strategy_id_for_actor(
        const RulesSession &position,
        std::int32_t actor
    ) = 0;
    virtual Value cache_precondition(
        const RulesSession &position,
        std::int32_t actor
    ) = 0;
};

class TraditionalTurnBeamSearch {
public:
    TraditionalTurnBeamSearch(
        TraditionalSearchProvider &provider,
        TraditionalSearchConfig config = {}
    );

    TraditionalSearchResult search(
        std::int32_t actor,
        std::uint32_t seed,
        const Value &root_actions,
        const std::atomic<bool> *cancel_requested = nullptr
    );

    TraditionalReplyEvaluation evaluate_reply(
        const RulesSession &post_turn_position,
        std::int32_t actor,
        std::uint32_t seed,
        const std::atomic<bool> *cancel_requested = nullptr
    );

private:
    TraditionalSearchProvider &provider_;
    TraditionalSearchConfig config_;
};

} // namespace ptcg::ai
