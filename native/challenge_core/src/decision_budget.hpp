#pragma once

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <functional>
#include <optional>
#include <utility>

namespace ptcg::ai {

enum class EvaluationStatus { Complete, BudgetExhausted, Cancelled };
enum class DecisionPhase : std::size_t { Initial, Search, Validation, Count };

template<class T> struct SearchEvaluation {
    EvaluationStatus status = EvaluationStatus::Complete;
    std::optional<T> value;
    explicit operator bool() const noexcept {
        return status == EvaluationStatus::Complete && value.has_value();
    }
};

// One cooperative deadline for every search participant. Phase changes are
// made by the coordinator only while its sample workers are joined. A phase
// owns no quota that can be lost: unused initial time remains available later.
class DecisionBudget {
public:
    using Clock = std::chrono::steady_clock;
    using TimePoint = Clock::time_point;
    using Now = std::function<TimePoint()>;

    DecisionBudget(TimePoint started, std::int64_t milliseconds,
        const std::atomic<bool> *cancel = nullptr, Now now = Clock::now)
        : started_(started), duration_ms_(std::max<std::int64_t>(0, milliseconds)),
          cancel_(cancel), now_(std::move(now)), phase_started_(started_) {
        const auto duration = std::chrono::milliseconds(duration_ms_);
        hard_deadline_ = started_ + duration;
        search_deadline_ = hard_deadline_ - std::chrono::milliseconds(
            std::min<std::int64_t>(250, duration_ms_ / 20));
        initial_deadline_ = started_ + duration / 5;
    }

    EvaluationStatus status() const {
        if (cancel_ && cancel_->load(std::memory_order_relaxed)) {
            last_stop_.store(4, std::memory_order_relaxed);
            return EvaluationStatus::Cancelled;
        }
        if (duration_ms_ == 0) return EvaluationStatus::Complete;
        const auto phase = phase_.load(std::memory_order_relaxed);
        const auto deadline = phase == DecisionPhase::Initial ? initial_deadline_
            : (phase == DecisionPhase::Validation ? hard_deadline_ : search_deadline_);
        if (now_() < deadline) return EvaluationStatus::Complete;
        last_stop_.store(phase == DecisionPhase::Initial ? 1
            : phase == DecisionPhase::Validation ? 3 : 2, std::memory_order_relaxed);
        return EvaluationStatus::BudgetExhausted;
    }

    const char *last_stop_reason() const noexcept {
        static constexpr const char *reasons[] = {"none", "initial_limit", "search_limit", "hard_deadline", "cancelled"};
        return reasons[last_stop_.load(std::memory_order_relaxed)];
    }

    bool timed() const noexcept { return duration_ms_ > 0; }
    DecisionPhase phase() const noexcept { return phase_.load(std::memory_order_relaxed); }
    void set_phase(DecisionPhase next) {
        const auto now = now_();
        elapsed_[static_cast<std::size_t>(phase())] += now - phase_started_;
        phase_started_ = now;
        phase_.store(next, std::memory_order_relaxed);
    }
    double elapsed_ms(DecisionPhase requested) const {
        auto elapsed = elapsed_[static_cast<std::size_t>(requested)];
        if (requested == phase()) elapsed += now_() - phase_started_;
        return std::chrono::duration<double, std::milli>(elapsed).count();
    }
    double remaining_ms() const {
        if (!timed()) return 0;
        return std::max(0.0, std::chrono::duration<double, std::milli>(search_deadline_ - now_()).count());
    }

    template<class Compute>
    auto evaluate(Compute &&compute) -> SearchEvaluation<decltype(compute())> {
        using T = decltype(compute());
        const auto before = status();
        if (before != EvaluationStatus::Complete) return {before, std::nullopt};
        T result = compute();
        const auto after = status();
        if (after != EvaluationStatus::Complete) {
            ++interrupted_evaluations_;
            return {after, std::nullopt};
        }
        return {EvaluationStatus::Complete, std::move(result)};
    }
    std::uint64_t interrupted_evaluations() const { return interrupted_evaluations_.load(); }

private:
    TimePoint started_, hard_deadline_, search_deadline_, initial_deadline_;
    std::int64_t duration_ms_;
    const std::atomic<bool> *cancel_;
    Now now_;
    std::atomic<DecisionPhase> phase_{DecisionPhase::Search};
    TimePoint phase_started_;
    std::array<Clock::duration, static_cast<std::size_t>(DecisionPhase::Count)> elapsed_{};
    std::atomic<std::uint64_t> interrupted_evaluations_{0};
    mutable std::atomic<unsigned> last_stop_{0};
};

class DecisionPhaseScope {
public:
    DecisionPhaseScope(DecisionBudget *budget, DecisionPhase phase)
        : budget_(budget), previous_(budget ? budget->phase() : DecisionPhase::Search) {
        if (budget_) budget_->set_phase(phase);
    }
    ~DecisionPhaseScope() { if (budget_) budget_->set_phase(previous_); }
    DecisionPhaseScope(const DecisionPhaseScope &) = delete;
    DecisionPhaseScope &operator=(const DecisionPhaseScope &) = delete;
private:
    DecisionBudget *budget_;
    DecisionPhase previous_;
};

} // namespace ptcg::ai
