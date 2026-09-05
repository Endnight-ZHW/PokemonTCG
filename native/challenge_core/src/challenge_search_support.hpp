#pragma once

#include "challenge_support.hpp"
#include "ptcg_traditional_search.hpp"

#include <algorithm>
#include <memory>

namespace ptcg::ai::challenge {

inline const Value *find_action_by_signature(
    const Value &actions,
    const std::string &signature
) {
    if (!actions.is_array()) return nullptr;
    for (const Value &action : actions.as_array()) {
        if (value_action_signature(action) == signature) return &action;
    }
    return nullptr;
}

inline bool event_is_unpredictable(const Value &event) {
    const std::string type = value_string_field(event, "event_type");
    return type == "coin_flip" || type.find("shuffle") != std::string::npos
        || type.find("draw") != std::string::npos
        || type.find("random") != std::string::npos;
}

struct ExpandedAction {
    std::shared_ptr<RulesSession> state;
    TraditionalChoiceTrace trace;
};

// Seed derivation and sequence termination belong to each traversal. Only
// the atomic rules transition and choice/randomness handling are shared.
inline ExpandedAction apply_action(
    TraditionalSearchProvider &provider,
    const RulesSession &parent,
    std::int32_t actor,
    const Value &candidate,
    std::uint32_t seed,
    const std::string &action_id,
    std::uint64_t &nodes_expanded
) {
    auto branch = parent.fork_for_search(seed);
    if (!branch) return {};
    const Value bound = provider.bind_action(candidate, *branch, actor, action_id);
    const RulesSessionResult applied = branch->apply_action_for_search(bound);
    ++nodes_expanded;
    if (!applied.success) return {};
    TraditionalChoiceTrace trace;
    trace.unpredictable = std::any_of(
        applied.events.begin(), applied.events.end(), event_is_unpredictable);
    if (!provider.resolve_pending(*branch, actor, nodes_expanded, trace)) return {};
    return {std::shared_ptr<RulesSession>(branch.release()), trace};
}

} // namespace ptcg::ai::challenge
