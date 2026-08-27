#pragma once

#include "ptcg_traditional_infoset.hpp"
#include "ptcg_traditional_search.hpp"
#include "ptcg_traditional_strategy.hpp"
#include "ptcg_traditional_trusted.hpp"

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <string>

namespace ptcg::ai {

struct TraditionalMandatoryResult {
    bool resolved = false;
    bool cancelled = false;
    Value action = Value::make_object();
    std::string reason = "search_required";
    std::uint64_t nodes_expanded = 0;
    std::string debug_last_step_error;
    Value debug_last_state = Value::make_object();
};

// Exact native counterpart of AIMandatoryTactics.  It deliberately accepts
// only a captured public information set plus its sampled RulesSession; hidden
// deck/Prize identities never cross this boundary.
class TraditionalMandatoryTactics {
public:
    TraditionalMandatoryTactics(
        Value catalog,
        const TraditionalStrategyCatalog &strategies,
        const TraditionalTrustedEvaluator &trusted
    );

    TraditionalMandatoryResult resolve(
        const TraditionalInformationSet &information_set,
        const RulesSession &position,
        std::int32_t actor,
        const Value &actions,
        TraditionalSearchProvider &provider,
        std::uint32_t seed = 1,
        std::uint64_t node_budget = 192,
        const std::atomic<bool> *cancel_requested = nullptr
    ) const;

private:
    Value cards_ = Value::make_object();
    const TraditionalStrategyCatalog &strategies_;
    const TraditionalTrustedEvaluator &trusted_;
};

} // namespace ptcg::ai
