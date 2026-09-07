#include "decision_search_context.hpp"
#include "planner_v3/energy_transfer_cycle.hpp"

#include <atomic>
#include <iostream>
#include <stdexcept>
#include <thread>
#include <vector>

using namespace ptcg::ai;

void require(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(message);
}

int main() {
    try {
        DecisionSearchContext context;
        Value state(Value::Object{{"hand", Value(Value::Array{Value("energy")})},
            {"rules", Value("standard")}});
        Value basis = state;
        int calls = 0;
        const auto read = [&](const Value &view, std::uint32_t rng = 17,
                              std::int32_t actor = 0, std::uint64_t policy = 1) {
            return context.memoize_values<int>(SearchMemo::Resources, basis,
                view, rng, actor, policy, [&] { return ++calls; });
        };
        require(read(state) == 1 && read(state) == 1, "identical immutable state missed");
        Value fork = state;
        require(read(fork) == 1, "COW fork did not share exact evaluation");
        fork["hand"].as_array().emplace_back("drawn-card");
        require(read(fork) == 2 && read(state) == 1, "mutation reused stale evaluation");
        require(read(state, 19) == 3, "different random state aliased");
        require(read(state, 17, 1) == 4, "different perspective aliased");
        require(read(state, 17, 0, 2) == 5, "different evaluation policy aliased");
        basis["rules"] = Value("different-rules");
        require(read(state) == 6, "changed rules basis reused a projection");
        Value equivalent = state.deep_clone();
        require(read(equivalent) == 7, "unproven value equivalence was assumed");
        context.memoization_enabled = false;
        require(read(state) == 8 && read(state) == 9, "ablation did not bypass cache");

        DecisionSearchContext ranking;
        Value actions(Value::Array{Value("attach"), Value("end")});
        int ranked = 0;
        const auto rank = [&](const Value &legal) {
            return ranking.memoize_values<int>(SearchMemo::Ranking, legal, state, 17, 0,
                ranking.ranking_policy(true), [&] { return ++ranked; });
        };
        ranking.set_incumbent(Value("attach"));
        require(rank(actions) == 1 && rank(actions) == 1, "ranking did not reuse the same legal set");
        ranking.set_incumbent(Value("end"));
        require(rank(actions) == 2, "protected incumbent did not invalidate ranking");
        ranking.set_incumbent(Value("end"));
        require(rank(actions) == 2, "unchanged incumbent invalidated ranking");
        Value filtered(Value::Array{Value("end")});
        require(rank(filtered) == 3, "filtered actions reused an unfiltered ranking");

        DecisionSearchContext interrupted;
        auto now = DecisionBudget::TimePoint{};
        interrupted.budget = std::make_shared<DecisionBudget>(now, 10, nullptr, [&] { return now; });
        const auto late = interrupted.budget->evaluate([&] {
            return interrupted.memoize_values<int>(SearchMemo::StateScore, basis, state, 17, 0, 0, [&] {
                now += std::chrono::milliseconds(11);
                return 123;
            });
        });
        require(!late, "late result escaped its evaluation status");
        interrupted.budget.reset();
        require(interrupted.memoize_values<int>(SearchMemo::StateScore, basis, state, 17, 0, 0,
            [] { return 456; }) == 456, "interrupted evaluation polluted a later phase");

        DecisionSearchContext parallel;
        std::atomic<bool> valid{true};
        std::vector<std::thread> workers;
        for (int worker = 0; worker < 3; ++worker) workers.emplace_back([&] {
            for (int index = 0; index < 100; ++index) {
                const auto result = parallel.memoize_values<int>(SearchMemo::StateScore,
                    basis, state, 17, 0, 0, [] { return 123; });
                if (result != 123) valid = false;
            }
        });
        for (auto &worker : workers) worker.join();
        require(valid, "parallel cache returned inconsistent results");
        const Value position(Value::Object{
            {"players", Value(Value::Array{Value(Value::Object{{"energy", Value("active")},
                {"retreated_this_turn", Value(false)}, {"damage", Value(0)}}), Value::make_object()})},
            {"revision", Value(1)}, {"action_log", Value::make_array()},
            {"turn_fact_book", Value::make_object()},
            {"resolution_stack", Value(Value::Object{{"frames", Value::make_array()},
                {"pending_request", Value()}, {"sequence", Value(0)}, {"context", Value::make_object()}})}
        });
        Value cycled = position;
        cycled["revision"] = Value(5);
        cycled["action_log"].as_array().emplace_back("energy moved out and back");
        cycled["resolution_stack"]["sequence"] = Value(4);
        require(planner_v3::same_energy_transfer_position(position, cycled), "physical transfer cycle was missed");
        Value advanced = cycled;
        advanced["players"].as_array()[0]["energy"] = Value("bench");
        require(!planner_v3::same_energy_transfer_position(position, advanced), "energy preparation was pruned as a cycle");
        advanced = cycled;
        advanced["players"].as_array()[0]["retreated_this_turn"] = Value(true);
        require(!planner_v3::same_energy_transfer_position(position, advanced), "spent retreat was ignored");
        advanced = cycled;
        advanced["players"].as_array()[0]["damage"] = Value(10);
        require(!planner_v3::same_energy_transfer_position(position, advanced), "damage change was ignored");
        advanced = cycled;
        advanced["turn_fact_book"]["knockout"] = Value(true);
        require(!planner_v3::same_energy_transfer_position(position, advanced), "relevant turn history was ignored");
        advanced = cycled;
        advanced["resolution_stack"]["pending_request"] = Value::make_object();
        require(!planner_v3::same_energy_transfer_position(position, advanced), "pending resolution was treated as complete");
        DecisionSearchContext cycle_cache;
        require(cycle_cache.memoize_values<int>(SearchMemo::StateScore, position, position, 17, 0, 0,
            [] { return 1; }) == 1, "initial policy score missing");
        require(cycle_cache.memoize_values<int>(SearchMemo::StateScore, cycled, cycled, 17, 0, 0,
            [] { return 2; }) == 2, "physical cycle equivalence leaked into policy score caching");
        std::cout << "SEARCH_CONTEXT_OK cow, mutation, rng, perspective, policy, basis, parallel\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
