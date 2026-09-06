#include "decision_search_context.hpp"

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
        std::cout << "SEARCH_CONTEXT_OK cow, mutation, rng, perspective, policy, basis, parallel\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
