#include "decision_budget.hpp"

#include <iostream>
#include <stdexcept>

using namespace ptcg::ai;

void require(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(message);
}

int main() {
    try {
        auto time = DecisionBudget::TimePoint{};
        std::atomic<bool> cancelled{false};
        DecisionBudget budget(time, 5000, &cancelled, [&] { return time; });
        {
            DecisionPhaseScope initial(&budget, DecisionPhase::Initial);
            time += std::chrono::milliseconds(999);
            require(budget.status() == EvaluationStatus::Complete, "initial stopped early");
            auto value = budget.evaluate([&] { time += std::chrono::milliseconds(2); return 42; });
            require(value.status == EvaluationStatus::BudgetExhausted && !value.value,
                "unfinished evaluation was committed");
        }
        require(budget.status() == EvaluationStatus::Complete, "initial exhausted the whole request");
        time = DecisionBudget::TimePoint{} + std::chrono::milliseconds(4750);
        require(budget.status() == EvaluationStatus::BudgetExhausted, "validation reserve was spent");
        {
            DecisionPhaseScope validation(&budget, DecisionPhase::Validation);
            require(budget.evaluate([] { return 7; }).value == 7, "reserved validation failed");
            time += std::chrono::milliseconds(250);
            require(!budget.evaluate([] { return 8; }), "hard deadline ignored");
        }
        cancelled = true;
        require(budget.status() == EvaluationStatus::Cancelled, "deadline hid explicit cancellation");
        DecisionBudget fixed(time, 0, &cancelled, [&] { return time; });
        require(fixed.status() == EvaluationStatus::Cancelled, "fixed work ignored cancellation");
        cancelled = false;
        time += std::chrono::hours(24);
        require(fixed.evaluate([] { return 9; }).value == 9, "fixed work acquired a deadline");
        for (const auto phase : {DecisionPhase::Initial, DecisionPhase::Search, DecisionPhase::Validation}) {
            time = DecisionBudget::TimePoint{};
            DecisionBudget interrupted(time, 5000, nullptr, [&] { return time; });
            interrupted.set_phase(phase);
            time += std::chrono::milliseconds(phase == DecisionPhase::Initial ? 999
                : phase == DecisionPhase::Search ? 4749 : 4999);
            require(!interrupted.evaluate([&] { time += std::chrono::milliseconds(2); return 123; }),
                "phase committed a result completed after its deadline");
            require(interrupted.interrupted_evaluations() == 1, "interrupted operation was not counted");
        }
        std::cout << "DECISION_BUDGET_OK phase_limits, reserve, incomplete_scores, cancellation, fixed_work\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
