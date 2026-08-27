#pragma once

#include "ptcg_value.hpp"
#include "ptcg_traditional_strategy.hpp"
#include "ptcg_traditional_trusted.hpp"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include <atomic>
#include <cstdint>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>

namespace ptcg::ai {
class TraditionalInformationSet;
struct TraditionalSearchResult;
}

namespace godot {

// Persistent gameplay-facing owner for the callback-free native traditional
// policy. Shadow/debug entrypoints are registered only in debug builds.
class NativeTraditionalAI : public RefCounted {
    GDCLASS(NativeTraditionalAI, RefCounted)

protected:
    static void _bind_methods();

public:
    Dictionary configure(
        const Dictionary &catalog,
        const Dictionary &decks,
        const Dictionary &strategies
    );
    Dictionary decide(
        const Dictionary &request,
        int64_t generation
    );
#ifdef DEBUG_ENABLED
    Dictionary debug_decide_with_provider(
        const Dictionary &request,
        int64_t generation,
        const Callable &provider
    );
    Dictionary debug_determinize(
        const Dictionary &public_state,
        int64_t actor,
        int64_t seed,
        int64_t match_seed = 0
    ) const;
    Dictionary debug_strategy_scores(
        const Dictionary &state,
        int64_t actor,
        const Array &actions
    ) const;
    Dictionary debug_strategy_choice_scores(
        const Dictionary &state,
        int64_t actor,
        const Dictionary &choice_view,
        const Array &options
    ) const;
    Dictionary debug_trusted_leaf_score(
        const Dictionary &snapshot,
        int64_t actor,
        int64_t rng_state = 1
    ) const;
    Dictionary debug_trusted_action_scores(
        const Dictionary &snapshot,
        int64_t actor,
        const Array &actions,
        int64_t rng_state = 1
    ) const;
    Dictionary debug_tactical_candidates(
        const Dictionary &public_state,
        int64_t actor,
        const Array &actions,
        int64_t sample_seed,
        int64_t candidate_seed,
        int64_t match_seed = 0
    ) const;
    Dictionary debug_mandatory_tactics(
        const Dictionary &public_state,
        int64_t actor,
        const Array &actions,
        int64_t seed = 1,
        int64_t match_seed = 0,
        int64_t node_budget = 192
    ) const;
#endif
    void cancel(int64_t generation) noexcept;
    void reset_match(const String &match_instance_id);
    Dictionary get_contract() const;
    bool is_configured() const noexcept;

private:
    Dictionary decide_controller(
        const Dictionary &request,
        int64_t generation,
        const Callable &provider,
        bool require_native_choices
    );

    struct ActionCycleEntry {
        std::string last_state_fingerprint;
        std::string last_action_signature;
        std::int64_t last_revision = -1;
        std::map<std::string, std::set<std::string>> blocked_by_state;
    };
    struct CachedPlanStep {
        ptcg::ai::Value action = ptcg::ai::Value::make_object();
        ptcg::ai::Value precondition = ptcg::ai::Value::make_object();
        std::string signature;
    };
    struct CachedPlanEntry {
        std::vector<CachedPlanStep> steps;
        std::int64_t last_revision = -1;
    };

    ptcg::ai::Value filter_root_actions(
        const Dictionary &request,
        const ptcg::ai::Value &public_state,
        const ptcg::ai::Value &actions
    );
    void record_action_cycle_selection(
        const Dictionary &request,
        const ptcg::ai::Value &public_state,
        const ptcg::ai::Value &action
    );
    std::string turn_plan_cache_key(
        const Dictionary &request,
        const ptcg::ai::TraditionalInformationSet &information_set
    ) const;
    ptcg::ai::Value take_cached_turn_action(
        const std::string &cache_key,
        std::int64_t revision,
        const ptcg::ai::Value &actions,
        const ptcg::ai::Value &precondition,
        std::int32_t actor
    );
    void store_turn_plan(
        const std::string &cache_key,
        std::int64_t revision,
        const ptcg::ai::TraditionalSearchResult &result
    );
    Dictionary decide_choice(
        const Dictionary &request,
        int64_t generation
    );

    Dictionary catalog_;
    Dictionary decks_;
    Dictionary strategies_;
    String active_match_instance_id_;
    std::atomic<int64_t> cancelled_through_generation_{0};
    std::atomic<int64_t> active_generation_{0};
    std::atomic<bool> cancel_requested_{false};
    ptcg::ai::Value catalog_value_ = ptcg::ai::Value::make_object();
    ptcg::ai::Value decks_value_ = ptcg::ai::Value::make_object();
    ptcg::ai::Value strategies_value_ = ptcg::ai::Value::make_object();
    std::unique_ptr<ptcg::ai::TraditionalStrategyCatalog> strategy_catalog_;
    std::unique_ptr<ptcg::ai::TraditionalTrustedEvaluator> trusted_evaluator_;
    std::map<std::string, ActionCycleEntry> action_cycle_ledger_;
    std::vector<std::string> action_cycle_order_;
    std::map<std::string, CachedPlanEntry> turn_plan_cache_;
    std::vector<std::string> turn_plan_cache_order_;
    bool configured_ = false;
};

} // namespace godot
