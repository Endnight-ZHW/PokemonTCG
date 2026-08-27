#pragma once

#include "ptcg_traditional_search.hpp"

#include <cstddef>
#include <functional>
#include <string>
#include <vector>

namespace ptcg::ai {

using TraditionalStableSignature = std::function<std::string(const Value &)>;

std::string traditional_action_purpose(const Value &action);
std::string traditional_action_signature(
    const Value &action,
    const TraditionalStableSignature &stable_signature,
    const std::function<std::string(const std::string &)> &sha256_text
);
std::string traditional_semantic_bucket(
    const Value &action,
    const TraditionalStableSignature &stable_signature
);
bool traditional_action_is_terminal(const Value &action) noexcept;

void traditional_sort_ranked_actions(
    std::vector<TraditionalRankedAction> &ranked
);
std::vector<TraditionalRankedAction> traditional_diverse_top_actions(
    const std::vector<TraditionalRankedAction> &ranked,
    std::size_t count
);

} // namespace ptcg::ai
