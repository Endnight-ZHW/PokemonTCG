#pragma once
#include "search_types.hpp"

namespace ptcg::ai {
inline constexpr const char *DECK_PLANNER_ENGINE_ID = "deck_planner_v1";

struct TurnPlannerConfig {
    std::size_t node_budget = 192;
    std::size_t belief_samples = 3;
    std::size_t worker_count = 1;
    std::size_t max_depth = 10;
    bool shallow = false;
};

// All three horizons use the same turn expansion and choice implementation.
class TurnPlanner {
  public:
    TurnPlanner(SearchProvider &provider, TurnPlannerConfig config);
    SearchResult decide(std::int32_t actor, std::uint32_t seed, const Value &actions,
                        const std::atomic<bool> *cancel = nullptr);

  private:
    SearchProvider &provider_;
    TurnPlannerConfig config_;
};
} // namespace ptcg::ai
