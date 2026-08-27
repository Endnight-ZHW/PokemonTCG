#include "ptcg_traditional_search.hpp"
#include "ptcg_traditional_policy.hpp"

#include <algorithm>
#include <future>
#include <limits>
#include <map>
#include <set>
#include <sstream>
#include <stdexcept>
#include <unordered_map>
#include <utility>

namespace ptcg::ai {

namespace {

bool cancelled(const std::atomic<bool> *flag) noexcept {
    return flag != nullptr && flag->load(std::memory_order_relaxed);
}

std::string boolean_text(bool value) {
    return value ? "true" : "false";
}

struct Trace {
    TraditionalSearchProvider &provider;
    std::string hash;
    std::uint64_t events = 0;

    void append(const std::string &event) {
        hash = provider.trace_event(hash, event);
        ++events;
    }
};

struct Node {
    std::shared_ptr<RulesSession> state;
    Value root_action = Value::make_object();
    Value::Array sequence;
    Value::Array cache_preconditions;
    std::string root_signature;
    std::string sequence_signature;
    std::string state_fingerprint;
    std::int64_t score_milli = std::numeric_limits<std::int64_t>::min();
    std::size_t depth = 0;
    bool ended = false;
    bool cache_open = false;
};

bool node_better(const Node &left, const Node &right) {
    return left.score_milli != right.score_milli
        ? left.score_milli > right.score_milli
        : left.sequence_signature < right.sequence_signature;
}

bool partial_better(const Node &left, const Node &right) {
    return left.depth != right.depth
        ? left.depth > right.depth
        : node_better(left, right);
}

std::vector<Node> top_nodes_per_root(
    std::vector<Node> nodes,
    std::size_t count,
    const std::vector<std::string> &root_order
) {
    std::vector<Node> output;
    output.reserve(root_order.size() * count);
    for (const std::string &root : root_order) {
        std::vector<Node> group;
        for (const Node &node : nodes) {
            if (node.root_signature == root) group.push_back(node);
        }
        std::stable_sort(group.begin(), group.end(), node_better);
        if (group.size() > count) group.resize(count);
        output.insert(output.end(), group.begin(), group.end());
    }
    return output;
}

struct RootPlan {
    std::string signature;
    Value action = Value::make_object();
    Value::Array sequence;
    Value::Array cache_preconditions;
    std::int64_t score_milli = 0;
    std::string opponent_strategy_id;
};

struct SampleResult {
    bool success = false;
    bool cancelled = false;
    std::string error;
    std::vector<RootPlan> root_plans;
    std::vector<std::string> root_order;
    std::uint64_t nodes_expanded = 0;
    std::size_t completed_depth = 0;
    std::size_t max_path_depth = 0;
    std::size_t layers_completed = 0;
    std::size_t reply_completed_depth = 0;
    bool reply_depth_applicable = false;
    std::set<std::string> reply_completion_reasons;
    std::string completion_reason;
    std::string trajectory_hash;
    std::uint64_t trajectory_events = 0;
};

struct ExpandedAction {
    std::shared_ptr<RulesSession> state;
    RulesSessionResult step;
    TraditionalChoiceTrace trace;
};

bool event_is_unpredictable(const Value &event) {
    const Value *type_value = event.find("event_type");
    const std::string type = type_value == nullptr
        ? std::string{} : type_value->string_or();
    return type == "coin_flip" || type.find("shuffle") != std::string::npos
        || type.find("draw") != std::string::npos
        || type.find("random") != std::string::npos;
}

ExpandedAction apply_action(
    TraditionalSearchProvider &provider,
    const RulesSession &parent,
    std::int32_t actor,
    const Value &candidate,
    std::uint32_t seed,
    const std::string &action_id,
    std::uint64_t &nodes_expanded
) {
    auto branch = parent.fork_for_search(seed);
    Value bound = provider.bind_action(candidate, *branch, actor, action_id);
    RulesSessionResult applied = branch->apply_action_for_search(bound);
    ++nodes_expanded;
    if (!applied.success) return {};
    TraditionalChoiceTrace trace;
    trace.unpredictable = std::any_of(
        applied.events.begin(), applied.events.end(), event_is_unpredictable);
    if (!provider.resolve_pending(
        *branch, actor, nodes_expanded, trace)) return {};
    return ExpandedAction{
        std::shared_ptr<RulesSession>(branch.release()),
        std::move(applied),
        trace,
    };
}

struct ReplyResult {
    std::int64_t score_milli = 0;
    std::uint64_t nodes_expanded = 0;
    bool cancelled = false;
    bool applicable = false;
    std::size_t completed_depth = 0;
    std::string completion_reason = "frontier_exhausted";
    std::string opponent_strategy_id;
};

ReplyResult score_opponent_response(
    TraditionalSearchProvider &provider,
    const TraditionalSearchConfig &config,
    const Node &root_node,
    std::int32_t actor,
    std::uint32_t seed,
    Trace &trace,
    const std::atomic<bool> *cancel_requested
) {
    ReplyResult output;
    output.score_milli = provider.state_score_milli(*root_node.state, actor);
    if (provider.terminal(*root_node.state)) return output;
    auto projected_reply = root_node.state->fork_for_reply_search();
    std::shared_ptr<RulesSession> reply_root(projected_reply.release());

    if (provider.decision_actor(*reply_root) == actor) {
        const auto legal = provider.ranked_actions(
            *reply_root, actor, Value(), config.actions_per_node);
        const TraditionalRankedAction *yield = nullptr;
        for (const auto &row : legal) {
            const std::string kind = row.action.find("kind") == nullptr
                ? std::string{} : row.action.find("kind")->string_or();
            if (kind == "END_TURN") {
                yield = &row;
                break;
            }
            if (kind == "SETUP_DONE") yield = &row;
        }
        if (yield == nullptr) return output;
        ExpandedAction yielded = apply_action(
            provider,
            *reply_root,
            actor,
            yield->action,
            provider.branch_seed(seed, 0, "yield", "yield", 0),
            "native-turn-beam-reply-yield",
            output.nodes_expanded
        );
        if (!yielded.state) {
            trace.append("reply_yield|failed");
            return output;
        }
        reply_root = std::move(yielded.state);
        trace.append(
            "reply_yield|state=" + provider.state_fingerprint(*reply_root));
        output.score_milli = provider.state_score_milli(*reply_root, actor);
    }
    const std::int32_t opponent = 1 - actor;
    if (
        provider.terminal(*reply_root)
        || provider.decision_actor(*reply_root) != opponent
    ) {
        output.score_milli = provider.state_score_milli(*reply_root, actor);
        return output;
    }

    output.applicable = true;
    const std::string opponent_deck_key = provider.deck_key_for_actor(
        *reply_root, opponent);
    output.opponent_strategy_id = provider.strategy_id_for_actor(
        *reply_root, opponent);
    struct ReplyNode {
        std::shared_ptr<RulesSession> state;
        std::int64_t score_milli = 0;
        std::string sequence_signature;
    };
    std::vector<ReplyNode> frontier{
        ReplyNode{reply_root, output.score_milli, std::string{}}};
    ReplyNode worst_complete;
    bool have_complete = false;
    output.completion_reason = "depth_complete";
    for (
        std::size_t depth = 1;
        depth <= config.reply_depth;
        ++depth
    ) {
        if (frontier.empty()) {
            output.completion_reason = "frontier_exhausted";
            break;
        }
        std::vector<ReplyNode> next;
        for (const ReplyNode &parent : frontier) {
            if (cancelled(cancel_requested)) {
                output.cancelled = true;
                output.completed_depth = depth - 1;
                output.completion_reason = "cancelled";
                return output;
            }
            if (provider.decision_actor(*parent.state) != opponent) {
                if (
                    !have_complete
                    || parent.score_milli < worst_complete.score_milli
                    || (
                        parent.score_milli == worst_complete.score_milli
                        && parent.sequence_signature
                            < worst_complete.sequence_signature
                    )
                ) {
                    worst_complete = parent;
                    have_complete = true;
                }
                continue;
            }
            const auto ranked = provider.ranked_actions(
                *parent.state, opponent, Value(),
                config.reply_actions_per_node);
            const auto candidates = traditional_diverse_top_actions(
                ranked, config.reply_actions_per_node);
            for (std::size_t index = 0; index < candidates.size(); ++index) {
                const auto &candidate = candidates[index];
                const std::string sequence = parent.sequence_signature
                    + "|" + candidate.signature;
                ExpandedAction expanded = apply_action(
                    provider,
                    *parent.state,
                    opponent,
                    candidate.action,
                    provider.branch_seed(
                        seed,
                        depth,
                        opponent_deck_key,
                        sequence,
                        index
                    ),
                    "native-turn-beam-reply-" + std::to_string(depth)
                        + "-" + std::to_string(index),
                    output.nodes_expanded
                );
                if (!expanded.state) {
                    trace.append(
                        "reply_depth=" + std::to_string(depth)
                        + "|deck=" + opponent_deck_key
                        + "|action=" + candidate.signature + "|failed");
                    continue;
                }
                std::shared_ptr<RulesSession> child = std::move(expanded.state);
                ReplyNode node{
                    child,
                    provider.state_score_milli(*child, actor),
                    sequence,
                };
                const std::string fingerprint = provider.state_fingerprint(*child);
                const bool ended = provider.terminal(*child)
                    || provider.action_ends_turn(candidate.action)
                    || provider.decision_actor(*child) != opponent;
                trace.append(
                    "reply_depth=" + std::to_string(depth)
                    + "|deck=" + opponent_deck_key
                    + "|action=" + candidate.signature
                    + "|state=" + fingerprint
                    + "|ended=" + boolean_text(ended)
                    + "|score=" + std::to_string(node.score_milli));
                if (ended) {
                    if (
                        !have_complete
                        || node.score_milli < worst_complete.score_milli
                        || (
                            node.score_milli == worst_complete.score_milli
                            && node.sequence_signature
                                < worst_complete.sequence_signature
                        )
                    ) {
                        worst_complete = node;
                        have_complete = true;
                    }
                } else {
                    next.push_back(std::move(node));
                }
            }
        }
        output.completed_depth = depth;
        std::stable_sort(
            next.begin(), next.end(),
            [](const ReplyNode &left, const ReplyNode &right) {
                return left.score_milli != right.score_milli
                    ? left.score_milli < right.score_milli
                    : left.sequence_signature < right.sequence_signature;
            });
        if (next.size() > config.reply_width) next.resize(config.reply_width);
        frontier = std::move(next);
        if (depth < config.reply_depth && frontier.empty()) {
            output.completion_reason = "frontier_exhausted";
            break;
        }
    }
    if (have_complete) {
        output.score_milli = worst_complete.score_milli;
    } else if (!frontier.empty()) {
        output.score_milli = std::min_element(
            frontier.begin(), frontier.end(),
            [](const ReplyNode &left, const ReplyNode &right) {
                return left.score_milli != right.score_milli
                    ? left.score_milli < right.score_milli
                    : left.sequence_signature < right.sequence_signature;
            })->score_milli;
    }
    return output;
}

SampleResult run_sample(
    TraditionalSearchProvider &provider,
    const TraditionalSearchConfig &config,
    std::int32_t actor,
    std::uint32_t seed,
    std::size_t sample_index,
    const Value &root_actions,
    const std::set<std::string> &fixed_root_signatures,
    const std::atomic<bool> *cancel_requested,
    std::unique_ptr<RulesSession> precomputed_root = {},
    const std::vector<TraditionalRankedAction> *precomputed_roots = nullptr
) {
    SampleResult output;
    auto root = precomputed_root != nullptr
        ? std::move(precomputed_root)
        : provider.determinize(sample_index, seed);
    if (!root) {
        output.error = "determinization_failed";
        return output;
    }
    auto ranked_roots = precomputed_roots != nullptr
        ? *precomputed_roots
        : provider.ranked_actions(
            *root, actor, root_actions, config.root_actions);
    ranked_roots.erase(
        std::remove_if(
            ranked_roots.begin(), ranked_roots.end(),
            [&](const TraditionalRankedAction &row) {
                return !fixed_root_signatures.empty()
                    && !fixed_root_signatures.count(row.signature);
            }),
        ranked_roots.end());
    auto roots = traditional_diverse_top_actions(
        ranked_roots, config.root_actions);
    if (roots.empty()) {
        output.error = "no_ranked_root_action";
        return output;
    }

    Trace trace{provider, provider.trace_seed(), 0};
    std::string joined_roots;
    for (std::size_t index = 0; index < roots.size(); ++index) {
        if (index > 0) joined_roots += ',';
        joined_roots += roots[index].signature;
    }
    trace.append("seed=" + std::to_string(seed) + "|roots=" + joined_roots);

    std::vector<Node> frontier;
    std::unordered_map<std::string, Node> best_complete;
    std::unordered_map<std::string, Node> best_partial;
    std::unordered_map<std::string, std::pair<std::int64_t, std::string>> seen;
    std::vector<std::string> root_order;
    const std::string root_fingerprint = provider.state_fingerprint(*root);
    const Value root_precondition = provider.cache_precondition(*root, actor);

    const auto action_allows_cache = [](const Value &action,
                                        const ExpandedAction &expanded) {
        const Value *kind_value = action.find("kind");
        const std::string kind = kind_value == nullptr
            ? std::string{} : kind_value->string_or();
        return expanded.state != nullptr && !expanded.trace.unpredictable
            && kind != "DECLARE_ATTACK" && kind != "END_TURN"
            && kind != "SETUP_DONE";
    };

    const auto record = [&](const Node &node) {
        const std::string seen_key = node.root_signature
            + "|" + node.state_fingerprint;
        const auto previous = seen.find(seen_key);
        if (
            previous != seen.end()
            && (
                previous->second.first > node.score_milli
                || (
                    previous->second.first == node.score_milli
                    && previous->second.second <= node.sequence_signature
                )
            )
        ) {
            return false;
        }
        seen[seen_key] = {node.score_milli, node.sequence_signature};
        auto &target = node.ended ? best_complete : best_partial;
        const auto current = target.find(node.root_signature);
        if (
            current == target.end()
            || (node.ended
                ? node_better(node, current->second)
                : partial_better(node, current->second))
        ) {
            target[node.root_signature] = node;
        }
        return true;
    };

    for (std::size_t root_index = 0; root_index < roots.size(); ++root_index) {
        if (cancelled(cancel_requested)) {
            output.cancelled = true;
            output.error = "cancelled";
            return output;
        }
        const auto &row = roots[root_index];
        if (std::find(root_order.begin(), root_order.end(), row.signature)
            == root_order.end()) {
            root_order.push_back(row.signature);
        }
        ExpandedAction expanded = apply_action(
            provider,
            *root,
            actor,
            row.action,
            provider.branch_seed(
                seed, 1, row.signature, row.signature, root_index),
            "native-turn-beam-root-" + std::to_string(root_index),
            output.nodes_expanded
        );
        if (!expanded.state) {
            trace.append(
                "root=" + std::to_string(root_index)
                + "|" + row.signature + "|failed");
            continue;
        }
        std::shared_ptr<RulesSession> child = expanded.state;
        const std::string fingerprint = provider.state_fingerprint(*child);
        const bool ended = provider.terminal(*child)
            || provider.action_ends_turn(row.action)
            || provider.decision_actor(*child) != actor;
        if (!ended && fingerprint == root_fingerprint) continue;
        const std::int64_t score = provider.state_score_milli(*child, actor);
        trace.append(
            "root=" + std::to_string(root_index)
            + "|" + row.signature
            + "|state=" + fingerprint
            + "|ended=" + boolean_text(ended)
            + "|score=" + std::to_string(score));
        Node node{
            child,
            row.action,
            Value::Array{row.action},
            Value::Array{root_precondition},
            row.signature,
            row.signature,
            fingerprint,
            score,
            1,
            ended,
            action_allows_cache(row.action, expanded),
        };
        record(node);
        if (!ended && config.max_depth > 1) frontier.push_back(node);
        output.max_path_depth = std::max<std::size_t>(output.max_path_depth, 1);
    }
    output.completed_depth = 1;
    output.layers_completed = 1;
    frontier = top_nodes_per_root(
        std::move(frontier), config.per_root_width, root_order);
    output.completion_reason = config.max_depth == 1
        ? "depth_complete" : std::string{};

    for (std::size_t depth = 2; depth <= config.max_depth; ++depth) {
        if (frontier.empty()) {
            output.completion_reason = "frontier_exhausted";
            break;
        }
        std::vector<Node> next;
        for (const Node &parent : frontier) {
            if (cancelled(cancel_requested)) {
                output.cancelled = true;
                output.error = "cancelled";
                return output;
            }
            if (provider.decision_actor(*parent.state) != actor) continue;
            const auto ranked = provider.ranked_actions(
                *parent.state, actor, Value(), config.actions_per_node);
            const auto candidates = traditional_diverse_top_actions(
                ranked, config.actions_per_node);
            for (std::size_t index = 0; index < candidates.size(); ++index) {
                const auto &candidate = candidates[index];
                const std::string sequence = parent.sequence_signature
                    + "|" + candidate.signature;
                Value::Array cache_preconditions = parent.cache_preconditions;
                if (parent.cache_open) {
                    cache_preconditions.push_back(
                        provider.cache_precondition(*parent.state, actor));
                }
                ExpandedAction expanded = apply_action(
                    provider,
                    *parent.state,
                    actor,
                    candidate.action,
                    provider.branch_seed(
                        seed,
                        depth,
                        parent.root_signature,
                        parent.sequence_signature,
                        index
                    ),
                    "native-turn-beam-" + std::to_string(depth)
                        + "-" + std::to_string(index),
                    output.nodes_expanded
                );
                if (!expanded.state) {
                    trace.append(
                        "depth=" + std::to_string(depth)
                        + "|root=" + parent.root_signature
                        + "|parent=" + parent.sequence_signature
                        + "|action=" + candidate.signature + "|failed");
                    continue;
                }
                std::shared_ptr<RulesSession> child = expanded.state;
                const std::string fingerprint = provider.state_fingerprint(*child);
                const bool ended = provider.terminal(*child)
                    || provider.action_ends_turn(candidate.action)
                    || provider.decision_actor(*child) != actor;
                if (!ended && fingerprint == parent.state_fingerprint) continue;
                const std::int64_t score = provider.state_score_milli(*child, actor);
                trace.append(
                    "depth=" + std::to_string(depth)
                    + "|root=" + parent.root_signature
                    + "|parent=" + parent.sequence_signature
                    + "|action=" + candidate.signature
                    + "|state=" + fingerprint
                    + "|ended=" + boolean_text(ended)
                    + "|score=" + std::to_string(score));
                Node node{
                    child,
                    parent.root_action,
                    parent.sequence,
                    std::move(cache_preconditions),
                    parent.root_signature,
                    sequence,
                    fingerprint,
                    score,
                    depth,
                    ended,
                    parent.cache_open
                        && action_allows_cache(candidate.action, expanded),
                };
                node.sequence.push_back(candidate.action);
                if (record(node) && !ended && depth < config.max_depth) {
                    next.push_back(std::move(node));
                }
                output.max_path_depth = std::max(output.max_path_depth, depth);
            }
        }
        output.completed_depth = depth;
        ++output.layers_completed;
        frontier = top_nodes_per_root(
            std::move(next), config.per_root_width, root_order);
        if (depth == config.max_depth) {
            output.completion_reason = "depth_complete";
        } else if (frontier.empty()) {
            output.completion_reason = "frontier_exhausted";
            break;
        }
    }
    if (output.completion_reason.empty()) {
        output.completion_reason = output.completed_depth >= config.max_depth
            ? "depth_complete" : "frontier_exhausted";
    }

    output.reply_completed_depth = config.reply_depth;
    for (const std::string &root_signature : root_order) {
        Node selected;
        bool have_selected = false;
        const auto complete = best_complete.find(root_signature);
        if (complete != best_complete.end()) {
            selected = complete->second;
            have_selected = true;
        } else {
            const auto partial = best_partial.find(root_signature);
            if (partial != best_partial.end()) {
                selected = partial->second;
                have_selected = true;
            }
        }
        if (!have_selected) continue;
        ReplyResult reply = score_opponent_response(
            provider,
            config,
            selected,
            actor,
            provider.branch_seed(
                seed, 97, root_signature, root_signature, 0),
            trace,
            cancel_requested
        );
        output.nodes_expanded += reply.nodes_expanded;
        if (reply.cancelled) {
            output.cancelled = true;
            output.error = "cancelled";
            return output;
        }
        if (reply.applicable) {
            output.reply_depth_applicable = true;
            output.reply_completed_depth = std::min(
                output.reply_completed_depth, reply.completed_depth);
            output.reply_completion_reasons.insert(reply.completion_reason);
        }
        output.root_plans.push_back(RootPlan{
            root_signature,
            selected.root_action,
            selected.sequence,
            selected.cache_preconditions,
            reply.score_milli,
            reply.opponent_strategy_id,
        });
    }
    if (output.root_plans.empty()) {
        output.error = "no_simulatable_action";
        return output;
    }
    if (!output.reply_depth_applicable) output.reply_completed_depth = 0;
    std::stable_sort(
        output.root_plans.begin(), output.root_plans.end(),
        [](const RootPlan &left, const RootPlan &right) {
            return left.score_milli != right.score_milli
                ? left.score_milli > right.score_milli
                : left.signature < right.signature;
        });
    output.root_order = std::move(root_order);
    output.trajectory_hash = std::move(trace.hash);
    output.trajectory_events = trace.events;
    output.success = true;
    return output;
}

} // namespace

void TraditionalSearchConfig::validate() const {
    if (
        root_actions == 0 || root_actions > 8
        || per_root_width == 0 || per_root_width > 2
        || max_depth == 0 || max_depth > 8
        || actions_per_node == 0 || actions_per_node > 8
        || reply_depth == 0 || reply_depth > 3
        || reply_width == 0 || reply_width > 4
        || reply_actions_per_node == 0 || reply_actions_per_node > 4
        || belief_samples == 0 || belief_samples > 3
        || worker_count == 0 || worker_count > 3
    ) {
        throw std::invalid_argument("invalid_traditional_search_config");
    }
}

TraditionalTurnBeamSearch::TraditionalTurnBeamSearch(
    TraditionalSearchProvider &provider,
    TraditionalSearchConfig config
) : provider_(provider), config_(config) {
    config_.validate();
}

TraditionalSearchResult TraditionalTurnBeamSearch::search(
    std::int32_t actor,
    std::uint32_t seed,
    const Value &root_actions,
    const std::atomic<bool> *cancel_requested
) {
    TraditionalSearchResult result;
    if (actor < 0 || actor > 1 || !root_actions.is_array()
        || root_actions.as_array().empty()) {
        result.error = "invalid_traditional_search_root";
        return result;
    }
    auto sample_zero = provider_.determinize(0, seed);
    if (!sample_zero) {
        result.error = "determinization_failed";
        return result;
    }
    const auto initial_ranked = provider_.ranked_actions(
        *sample_zero, actor, root_actions, config_.root_actions);
    const auto initial_roots = traditional_diverse_top_actions(
        initial_ranked, config_.root_actions);
    std::set<std::string> fixed_roots;
    std::vector<std::string> fixed_root_order;
    for (const auto &row : initial_roots) {
        if (!row.signature.empty() && fixed_roots.insert(row.signature).second) {
            fixed_root_order.push_back(row.signature);
            result.root_candidates.push_back(row.action);
        }
    }
    if (fixed_roots.empty()) {
        result.error = "no_ranked_root_action";
        return result;
    }

    struct Aggregate {
        std::size_t count = 0;
        std::int64_t total = 0;
        std::int64_t worst = std::numeric_limits<std::int64_t>::max();
        RootPlan representative;
        bool has_representative = false;
    };
    std::map<std::string, Aggregate> aggregate;
    std::set<std::string> completion_reasons;
    std::set<std::string> reply_completion_reasons;
    result.completed_depth = config_.max_depth;
    result.reply_completed_depth = config_.reply_depth;
    std::size_t layers_completed = config_.max_depth;
    std::vector<std::uint32_t> belief_seeds;
    belief_seeds.reserve(config_.belief_samples);
    for (std::size_t sample = 0; sample < config_.belief_samples; ++sample) {
        belief_seeds.push_back(seed
            + static_cast<std::uint32_t>(sample * 1000003ULL));
    }
    std::string aggregate_trace = provider_.sha256_text(
        "traditional_turn_planner:v2:trajectory:v1");

    // Samples are independent after the root set has been frozen. Run a
    // bounded prefix concurrently, then reduce every result strictly in the
    // original sample order so worker scheduling cannot affect traces, node
    // counts, tie-breaking, or the selected action.
    std::vector<SampleResult> sample_rows(config_.belief_samples);
    const std::size_t parallel_workers = std::min(
        config_.worker_count, config_.belief_samples);
    std::vector<std::future<SampleResult>> futures;
    futures.reserve(parallel_workers > 0 ? parallel_workers - 1 : 0);
    for (std::size_t sample = 1; sample < parallel_workers; ++sample) {
        const std::uint32_t sample_seed = belief_seeds[sample];
        futures.push_back(std::async(
            std::launch::async,
            [&, sample, sample_seed]() {
                return run_sample(
                    provider_, config_, actor, sample_seed, sample,
                    root_actions, fixed_roots, cancel_requested);
            }));
    }
    sample_rows[0] = run_sample(
        provider_, config_, actor, belief_seeds[0], 0,
        root_actions, fixed_roots, cancel_requested,
        std::move(sample_zero), &initial_ranked);
    for (std::size_t sample = 1; sample < parallel_workers; ++sample) {
        sample_rows[sample] = futures[sample - 1].get();
    }
    for (std::size_t sample = parallel_workers;
        sample < config_.belief_samples; ++sample) {
        sample_rows[sample] = run_sample(
            provider_, config_, actor, belief_seeds[sample], sample,
            root_actions, fixed_roots, cancel_requested);
    }

    for (std::size_t sample = 0; sample < config_.belief_samples; ++sample) {
        if (cancelled(cancel_requested)) {
            result.cancelled = true;
            result.error = "cancelled";
            return result;
        }
        const std::uint32_t sample_seed = belief_seeds[sample];
        SampleResult row = std::move(sample_rows[sample]);
        result.nodes_expanded += row.nodes_expanded;
        aggregate_trace = provider_.sha256_text(
            aggregate_trace
            + "|sample=" + std::to_string(sample)
            + "|seed=" + std::to_string(sample_seed)
            + "|trace=" + row.trajectory_hash
            + "|nodes=" + std::to_string(row.nodes_expanded)
            + "|reason=" + row.completion_reason);
        if (row.cancelled) {
            result.cancelled = true;
            result.error = "cancelled";
            return result;
        }
        if (!row.success) {
            result.error = row.error.empty() ? "planner_failed" : row.error;
            return result;
        }
        result.completed_depth = std::min(
            result.completed_depth, row.completed_depth);
        result.max_path_depth = std::max(
            result.max_path_depth, row.max_path_depth);
        layers_completed = std::min(layers_completed, row.layers_completed);
        if (row.reply_depth_applicable) {
            result.reply_depth_applicable = true;
            result.reply_completed_depth = std::min(
                result.reply_completed_depth, row.reply_completed_depth);
            reply_completion_reasons.insert(
                row.reply_completion_reasons.begin(),
                row.reply_completion_reasons.end());
        }
        completion_reasons.insert(row.completion_reason);
        for (const RootPlan &plan : row.root_plans) {
            Aggregate &entry = aggregate[plan.signature];
            ++entry.count;
            entry.total += plan.score_milli;
            entry.worst = std::min(entry.worst, plan.score_milli);
            if (!entry.has_representative) {
                entry.representative = plan;
                entry.has_representative = true;
            }
        }
        result.trajectory_events += row.trajectory_events;
    }

    const Aggregate *best = nullptr;
    std::string best_signature;
    for (const std::string &signature : fixed_root_order) {
        const auto found = aggregate.find(signature);
        if (found == aggregate.end()
            || found->second.count != config_.belief_samples) continue;
        const Aggregate &candidate = found->second;
        if (best == nullptr) {
            best = &candidate;
            best_signature = signature;
            continue;
        }
        const auto rounded_mean = [](const Aggregate &value) {
            const double mean = static_cast<double>(value.total)
                / static_cast<double>(value.count);
            return static_cast<std::int64_t>(
                mean >= 0.0 ? mean + 0.5 : mean - 0.5);
        };
        const std::int64_t candidate_mean = rounded_mean(candidate);
        const std::int64_t best_mean = rounded_mean(*best);
        if (
            candidate_mean > best_mean
            || (
                candidate_mean == best_mean
                && (
                    candidate.worst > best->worst
                    || (candidate.worst == best->worst
                        && signature < best_signature)
                )
            )
        ) {
            best = &candidate;
            best_signature = signature;
        }
    }
    if (best == nullptr || !best->has_representative) {
        result.error = "no_root_compared_across_all_beliefs";
        return result;
    }
    const double mean = static_cast<double>(best->total)
        / static_cast<double>(best->count);
    result.score_milli = static_cast<std::int64_t>(
        mean >= 0.0 ? mean + 0.5 : mean - 0.5);
    result.worst_score_milli = best->worst;
    result.selected = best->representative.action;
    result.sequence = best->representative.sequence;
    result.cache_preconditions = best->representative.cache_preconditions;
    result.opponent_strategy_id = best->representative.opponent_strategy_id;
    result.completion_reason = completion_reasons.size() == 1
        && completion_reasons.count("depth_complete")
        ? "depth_complete" : "frontier_exhausted";
    if (!result.reply_depth_applicable) result.reply_completed_depth = 0;
    result.reply_completion_reasons.assign(
        reply_completion_reasons.begin(), reply_completion_reasons.end());
    result.reply_completion_reason = !result.reply_depth_applicable
        ? "not_applicable"
        : (reply_completion_reasons.size() == 1
            && reply_completion_reasons.count("depth_complete")
            ? "depth_complete" : "frontier_exhausted");
    result.belief_samples = config_.belief_samples;
    result.belief_consensus = config_.belief_samples;
    result.root_signatures_attempted = fixed_root_order;
    for (const std::string &signature : fixed_root_order) {
        const auto found = aggregate.find(signature);
        result.root_sample_counts[signature] = found == aggregate.end()
            ? 0 : found->second.count;
    }
    std::string seed_wire = "[";
    for (std::size_t index = 0; index < belief_seeds.size(); ++index) {
        if (index > 0) seed_wire += ',';
        seed_wire += std::to_string(belief_seeds[index]);
    }
    seed_wire += ']';
    result.belief_seed_hash = provider_.sha256_text(seed_wire);
    result.layers_completed = layers_completed;
    result.trajectory_hash = std::move(aggregate_trace);
    result.success = true;
    return result;
}

} // namespace ptcg::ai
