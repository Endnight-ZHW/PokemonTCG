#pragma once

#include "ptcg_rules_session.hpp"
#include "ptcg_value.hpp"
#include "decision_context.hpp"

#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <map>
#include <string>
#include <vector>

namespace ptcg::ai {

struct RankedAction {
    Value action = Value::make_object();
    std::int64_t score_milli = 0;
    std::string signature;
    std::string semantic_bucket;
    std::string purpose_bucket;
    std::size_t source_index = 0;
};

struct SearchResult {
    bool success = false;
    bool cancelled = false;
    std::string error;
    Value selected = Value::make_object();
    Value::Array sequence;
    Value::Array cache_preconditions;
    Value::Array root_candidates;
    Value::Array root_evaluations;
    std::int64_t score_milli = 0;
    std::int64_t worst_score_milli = 0;
    std::uint64_t nodes_expanded = 0;
    std::size_t requested_depth = 0;
    std::size_t completed_depth = 0;
    std::size_t max_path_depth = 0;
    std::size_t reply_completed_depth = 0;
    bool reply_depth_applicable = false;
    std::string completion_reason;
    std::string trajectory_hash;
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

struct ChoiceTrace {
    bool had_choice = false;
    bool unpredictable = false;
};

// Shared rules/semantic boundary for deck_planner_v1.
// Traversals own ordering; providers own game policy and information views.
class SearchProvider {
  public:
    virtual ~SearchProvider() = default;
    virtual bool preserve_best_action(const RulesSession &, std::int32_t) { return true; }
    const std::shared_ptr<DecisionContext> &search_context() const noexcept { return context_; }
    void set_deadline(std::chrono::steady_clock::time_point deadline) noexcept {
        deadline_ = deadline;
    }
    bool time_budget_exhausted() const noexcept {
        if (context_->budget)
            return context_->budget->status() == EvaluationStatus::BudgetExhausted;
        return deadline_ != std::chrono::steady_clock::time_point{} &&
               std::chrono::steady_clock::now() >= deadline_;
    }
    bool search_stopped() const {
        return context_->budget ? context_->budget->status() != EvaluationStatus::Complete
                                : time_budget_exhausted();
    }
    template <class Compute>
    auto evaluate(Compute &&compute) -> SearchEvaluation<decltype(compute())> {
        if (context_->budget)
            return context_->budget->evaluate(std::forward<Compute>(compute));
        if (time_budget_exhausted())
            return {EvaluationStatus::BudgetExhausted, std::nullopt};
        return {EvaluationStatus::Complete, compute()};
    }
    SearchEvaluation<std::int64_t> evaluate_state(const RulesSession &position,
                                                  std::int32_t actor) {
        return evaluate([&] { return state_score_milli(position, actor); });
    }

    virtual std::unique_ptr<RulesSession> determinize(std::size_t sample_index,
                                                      std::uint32_t seed) = 0;
    virtual std::unique_ptr<RulesSession> reply_information_view(const RulesSession &position,
                                                                 std::int32_t actor,
                                                                 std::uint32_t seed) = 0;
    virtual std::vector<RankedAction> ranked_actions(const RulesSession &position,
                                                     std::int32_t actor,
                                                     const Value &supplied_actions,
                                                     std::size_t limit) = 0;
    virtual std::int64_t state_score_milli(const RulesSession &position,
                                           std::int32_t root_actor) = 0;
    virtual bool resolve_pending(RulesSession &position, std::int32_t decision_actor,
                                 std::uint64_t &nodes_expanded, ChoiceTrace &trace) = 0;
    virtual std::int32_t decision_actor(const RulesSession &position) = 0;
    virtual bool terminal(const RulesSession &position) = 0;
    virtual std::string state_fingerprint(const RulesSession &position) = 0;
    virtual bool action_ends_turn(const Value &action) = 0;
    virtual Value bind_action(const Value &candidate, const RulesSession &position,
                              std::int32_t actor, const std::string &action_id) = 0;
    virtual std::string sha256_text(const std::string &value) = 0;
    virtual std::string deck_key_for_actor(const RulesSession &position, std::int32_t actor) = 0;
    virtual std::string strategy_id_for_actor(const RulesSession &position, std::int32_t actor) = 0;
    virtual Value cache_precondition(const RulesSession &position, std::int32_t actor) = 0;

  private:
    std::shared_ptr<DecisionContext> context_ = std::make_shared<DecisionContext>();
    std::chrono::steady_clock::time_point deadline_{};
};

} // namespace ptcg::ai
