#pragma once

#include "ptcg_rules_session.hpp"
#include "decision_budget.hpp"

#include <any>
#include <array>
#include <atomic>
#include <cstdint>
#include <mutex>
#include <optional>
#include <unordered_map>

namespace ptcg::ai {

enum class SearchMemo : std::uint8_t {
    Pipeline, Resources, Zones, StateScore, Fingerprint, Preconditions, Ranking,
    Count
};

// Request-scoped exact memoization. A retained COW Value owns each identity:
// mutations detach, and allocator address reuse cannot turn into a cache hit.
// Include the rules basis as well as the projected state (choice projections
// are evaluated against their original session), perspective and RNG state.
// No normalized public/cycle fingerprint is used as an equivalence proof.
class DecisionSearchContext {
public:
    bool memoization_enabled = true;
    bool shortlist_enabled = false;
    std::shared_ptr<DecisionBudget> budget;
    const Value &incumbent_action() const noexcept { return incumbent_action_; }
    void set_incumbent(const Value &action) {
        if (!(incumbent_action_ == action)) { incumbent_action_ = action; ++ranking_epoch_; }
    }
    std::uint64_t ranking_policy(bool optimized) const noexcept {
        return ranking_epoch_ * 4 + (shortlist_enabled ? 2 : 0) + (optimized ? 1 : 0);
    }
    struct Plan {
        std::shared_ptr<RulesSession> state;
        Value action;
        Value::Array sequence, preconditions;
        std::string root_signature, sequence_signature;
        std::uint32_t seed = 0;
        bool ended = false, unpredictable = false;
    };
    // Published in sample order after workers join. These are private sampled
    // positions, never DTO fields or cross-request continuation memory.
    std::vector<Plan> initial_plans;
    std::atomic<std::uint64_t> rule_actions{0}, rule_choices{0};
    std::atomic<std::uint64_t> ranked_input_actions{0}, detailed_action_scores{0};
    std::atomic<std::uint64_t> completed_comparisons{0}, candidate_batches{0};
    std::atomic<std::uint64_t> replay_cache_hits{0}, exchange_cache_hits{0};
    std::atomic<std::uint64_t> reused_initial_plans{0};
    std::atomic<std::uint64_t> classic_routes_retained{0}, classic_candidates_compared{0};
    std::atomic<std::uint64_t> energy_transfer_cycles_pruned{0};
    std::size_t worker_count = 1;

    template<class T> std::optional<T> find_result(const std::string &key) {
        std::lock_guard<std::mutex> lock(mutex_);
        const auto found = results_.find(key);
        return found == results_.end() ? std::optional<T>{} : std::any_cast<T>(found->second);
    }
    template<class T> void remember_result(const std::string &key, const T &result) {
        if (budget && budget->status() != EvaluationStatus::Complete) return;
        std::lock_guard<std::mutex> lock(mutex_);
        if (results_.size() < 512) results_.emplace(key, result);
    }

    template<class Compute>
    std::unique_ptr<RulesSession> sample(std::size_t sample_index, std::uint32_t seed, Compute &&compute) {
        const std::uint64_t key = (static_cast<std::uint64_t>(sample_index) << 32) | seed;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            const auto found = samples_.find(key);
            if (found != samples_.end()) {
                ++sample_hits_;
                return found->second->fork_for_search(seed);
            }
        }
        auto root = compute();
        if (!root) return {};
        auto fork = root->fork_for_search(seed);
        {
            std::lock_guard<std::mutex> lock(mutex_);
            samples_.emplace(key, std::shared_ptr<RulesSession>(root.release()));
        }
        return fork;
    }

    template<class T, class Compute>
    T memoize(SearchMemo kind, const RulesSession &position, const Value &state,
        std::int32_t actor, std::uint64_t policy, Compute &&compute) {
        return memoize_values<T>(kind, position.search_state(), state,
            position.rng_state(), actor, policy, std::forward<Compute>(compute));
    }

    template<class T, class Compute>
    T memoize_values(SearchMemo kind, const Value &basis, const Value &state,
        std::uint32_t rng, std::int32_t actor, std::uint64_t policy, Compute &&compute) {
        const auto identity = [](const Value &value) -> const void * {
            if (value.is_object()) return &value.as_object();
            if (value.is_array()) return &value.as_array();
            return nullptr;
        };
        if (!memoization_enabled || !identity(state) || !identity(basis)) return compute();
        const Key key{identity(state), identity(basis), rng,
            actor, policy, kind};
        const auto index = static_cast<std::size_t>(kind);
        {
            std::lock_guard<std::mutex> lock(mutex_);
            const auto found = entries_.find(key);
            if (found != entries_.end()) {
                ++hits_[index];
                return std::any_cast<T>(found->second.result);
            }
        }
        ++misses_[index];
        T result = compute();
        if (budget && budget->status() != EvaluationStatus::Complete) return result;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            // Bounded per decision; returned values own their data and remain
            // valid across eviction. Cache races may duplicate work, not values.
            if (entries_.size() >= 4096) entries_.clear();
            entries_.emplace(key, Entry{state, basis, result});
        }
        return result;
    }

    Value counters() const {
        static constexpr const char *names[] = {
            "pipeline", "resources", "zones", "state_score", "fingerprint",
            "preconditions", "ranking"};
        Value result = Value::make_object();
        result["rule_action_applications"] = Value(static_cast<std::int64_t>(rule_actions.load()));
        result["rule_choice_applications"] = Value(static_cast<std::int64_t>(rule_choices.load()));
        result["ranked_input_actions"] = Value(static_cast<std::int64_t>(ranked_input_actions.load()));
        result["detailed_action_scores"] = Value(static_cast<std::int64_t>(detailed_action_scores.load()));
        result["sample_cache_hits"] = Value(static_cast<std::int64_t>(sample_hits_.load()));
        result["completed_plan_comparisons"] = Value(static_cast<std::int64_t>(completed_comparisons.load()));
        result["candidate_batches"] = Value(static_cast<std::int64_t>(candidate_batches.load()));
        result["plan_replay_cache_hits"] = Value(static_cast<std::int64_t>(replay_cache_hits.load()));
        result["exchange_cache_hits"] = Value(static_cast<std::int64_t>(exchange_cache_hits.load()));
        result["reused_initial_plans"] = Value(static_cast<std::int64_t>(reused_initial_plans.load()));
        result["classic_routes_retained"] = Value(static_cast<std::int64_t>(classic_routes_retained.load()));
        result["classic_candidates_compared"] = Value(static_cast<std::int64_t>(classic_candidates_compared.load()));
        result["energy_transfer_cycles_pruned"] = Value(static_cast<std::int64_t>(energy_transfer_cycles_pruned.load()));
        if (budget) {
            const auto status = budget->status();
            result["budget_status"] = Value(status == EvaluationStatus::Complete ? "available"
                : status == EvaluationStatus::Cancelled ? "cancelled" : "exhausted");
            result["budget_last_stop_reason"] = Value(budget->last_stop_reason());
            result["initial_phase_ms"] = Value(budget->elapsed_ms(DecisionPhase::Initial));
            result["search_phase_ms"] = Value(budget->elapsed_ms(DecisionPhase::Search));
            result["validation_phase_ms"] = Value(budget->elapsed_ms(DecisionPhase::Validation));
            result["interrupted_evaluations"] = Value(static_cast<std::int64_t>(budget->interrupted_evaluations()));
        }
        for (std::size_t index = 0; index < hits_.size(); ++index) {
            result[std::string("memo_") + names[index] + "_hits"] =
                Value(static_cast<std::int64_t>(hits_[index].load()));
            result[std::string("memo_") + names[index] + "_computations"] =
                Value(static_cast<std::int64_t>(misses_[index].load()));
        }
        return result;
    }

private:
    Value incumbent_action_;
    std::uint64_t ranking_epoch_ = 0;
    struct Key {
        const void *state;
        const void *basis;
        std::uint32_t rng;
        std::int32_t actor;
        std::uint64_t policy;
        SearchMemo kind;
        bool operator==(const Key &other) const noexcept {
            return state == other.state && basis == other.basis && rng == other.rng
                && actor == other.actor && policy == other.policy && kind == other.kind;
        }
    };
    struct Hash {
        std::size_t operator()(const Key &key) const noexcept {
            std::size_t hash = reinterpret_cast<std::uintptr_t>(key.state);
            const auto mix = [&](std::size_t value) {
                hash ^= value + 0x9e3779b9U + (hash << 6) + (hash >> 2);
            };
            mix(reinterpret_cast<std::uintptr_t>(key.basis));
            mix(key.rng); mix(static_cast<std::size_t>(key.actor));
            mix(static_cast<std::size_t>(key.policy));
            mix(static_cast<std::size_t>(key.kind));
            return hash;
        }
    };
    struct Entry { Value state; Value basis; std::any result; };
    std::mutex mutex_;
    std::unordered_map<Key, Entry, Hash> entries_;
    std::unordered_map<std::uint64_t, std::shared_ptr<RulesSession>> samples_;
    std::unordered_map<std::string, std::any> results_;
    std::atomic<std::uint64_t> sample_hits_{0};
    std::array<std::atomic<std::uint64_t>, static_cast<std::size_t>(SearchMemo::Count)> hits_{};
    std::array<std::atomic<std::uint64_t>, static_cast<std::size_t>(SearchMemo::Count)> misses_{};
};

} // namespace ptcg::ai
