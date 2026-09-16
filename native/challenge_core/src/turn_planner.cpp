#include "turn_planner.hpp"
#include "challenge_search_support.hpp"
#include "ptcg_traditional_policy.hpp"
#include "ptcg_traditional_value.hpp"

#include <algorithm>
#include <future>
#include <limits>
#include <map>
#include <set>
#include <stdexcept>

namespace ptcg::ai {
namespace {
using namespace challenge;
using namespace traditional_value;

struct Line {
    std::shared_ptr<RulesSession> position;
    Value action;
    Value::Array sequence, preconditions;
    std::vector<std::string> visited;
    std::string root_signature, signature;
    std::int64_t score = 0;
    bool ended = false, unpredictable = false, cache_open = true;
};

bool better(const Line &left, const Line &right) {
    if (left.score != right.score)
        return left.score > right.score;
    // Equal outcomes should not spend resources or run repeatable abilities.
    if (left.sequence.size() != right.sequence.size())
        return left.sequence.size() < right.sequence.size();
    return left.signature < right.signature;
}

struct TurnResult {
    std::vector<Line> lines;
    std::uint64_t nodes = 0;
    std::size_t depth = 0;
    bool stopped = false;
};

bool stopped(SearchProvider &provider, const std::atomic<bool> *cancel) {
    return provider.search_stopped() || (cancel && cancel->load(std::memory_order_relaxed));
}

// The same expansion is used for our turn, the reply and the recovery turn.
// Every child is settled by RulesSession, including all mandatory choices.
TurnResult expand_turn(SearchProvider &provider, const RulesSession &position, std::int32_t actor,
                       const Value &root_actions, std::size_t max_depth, std::size_t node_budget,
                       std::size_t root_width, const std::atomic<bool> *cancel) {
    TurnResult output;
    auto ranked = provider.ranked_actions(position, actor, root_actions, root_width);
    const bool preserve_best = provider.preserve_best_action(position, actor);
    auto roots = traditional_diverse_top_actions(ranked, root_width, preserve_best);
    if (roots.empty())
        return output;
    const std::string initial_fingerprint = provider.state_fingerprint(position);
    std::vector<Line> frontier;
    std::map<std::string, Line> complete, partial;
    std::map<std::string, std::size_t> seen;
    const auto remember = [&](Line line, std::vector<Line> &next) {
        const auto key = line.root_signature + "|" + provider.state_fingerprint(*line.position);
        const auto found = seen.find(key);
        if (found != seen.end() && found->second <= line.sequence.size())
            return;
        seen[key] = line.sequence.size();
        auto &table = line.ended ? complete : partial;
        const auto previous = table.find(line.root_signature);
        if (previous == table.end() || better(line, previous->second))
            table[line.root_signature] = line;
        if (!line.ended)
            next.push_back(std::move(line));
    };
    const auto apply = [&](const Line *parent, const RankedAction &row, std::size_t depth,
                           std::size_t index) -> std::optional<Line> {
        if (stopped(provider, cancel) || output.nodes >= node_budget)
            return {};
        const auto &basis = parent ? *parent->position : position;
        const std::string root_signature = parent ? parent->root_signature : row.signature;
        const std::string parent_signature = parent ? parent->signature : std::string{};
        auto child = apply_action(provider, basis, actor, row.action,
                                  "deck-plan-" + std::to_string(actor) + "-" +
                                      std::to_string(basis.revision()) + "-" +
                                      std::to_string(depth) + "-" + std::to_string(index),
                                  output.nodes);
        if (!child.state)
            return {};
        Line line;
        line.position = child.state;
        line.action = parent ? parent->action : row.action;
        line.root_signature = root_signature;
        line.signature = parent_signature + "|" + row.signature;
        if (parent) {
            line.sequence = parent->sequence;
            line.preconditions = parent->preconditions;
            line.visited = parent->visited;
            line.cache_open = parent->cache_open;
            line.unpredictable = parent->unpredictable;
        } else
            line.visited.push_back(initial_fingerprint);
        line.sequence.push_back(row.action);
        if (line.cache_open)
            line.preconditions.push_back(provider.cache_precondition(basis, actor));
        line.unpredictable = line.unpredictable || child.trace.unpredictable;
        line.cache_open = line.cache_open && !child.trace.unpredictable;
        line.ended = provider.terminal(*line.position) || provider.action_ends_turn(row.action) ||
                     provider.decision_actor(*line.position) != actor;
        const auto fingerprint = provider.state_fingerprint(*line.position);
        if (!line.ended &&
            std::find(line.visited.begin(), line.visited.end(), fingerprint) != line.visited.end())
            return {};
        line.visited.push_back(fingerprint);
        const auto score = provider.evaluate_state(*line.position, actor);
        if (!score)
            return {};
        line.score = *score.value;
        output.depth = std::max(output.depth, depth);
        return line;
    };
    for (std::size_t index = 0; index < roots.size(); ++index) {
        if (auto line = apply(nullptr, roots[index], 1, index))
            remember(std::move(*line), frontier);
        if (stopped(provider, cancel) || output.nodes >= node_budget)
            break;
    }
    for (std::size_t depth = 2; depth <= max_depth && !frontier.empty(); ++depth) {
        if (stopped(provider, cancel) || output.nodes >= node_budget)
            break;
        std::vector<Line> next;
        for (const auto &parent : frontier) {
            auto children = traditional_diverse_top_actions(
                provider.ranked_actions(*parent.position, actor, Value(), 4), 4, preserve_best);
            // Ensure a development prefix can finish this turn. An unfinished
            // reply is never represented as a completed exchange.
            const auto legal = parent.position->search_legal_action_candidates(actor);
            if (legal.is_array())
                for (const auto &action : legal.as_array()) {
                    if (string_field(action, "kind") != "END_TURN" &&
                        string_field(action, "kind") != "SETUP_DONE")
                        continue;
                    const auto signature = value_action_signature(action);
                    if (std::none_of(children.begin(), children.end(),
                                     [&](const auto &row) { return row.signature == signature; }))
                        children.push_back({action, 0, signature, "end", "end", 0});
                }
            // Close the best prefix before spending the remaining quota on
            // optional branches; the resulting state still receives its real score.
            std::stable_sort(children.begin(), children.end(), [&](const auto &a, const auto &b) {
                return provider.action_ends_turn(a.action) > provider.action_ends_turn(b.action);
            });
            for (std::size_t index = 0; index < children.size(); ++index) {
                if (auto line = apply(&parent, children[index], depth, index))
                    remember(std::move(*line), next);
                if (stopped(provider, cancel) || output.nodes >= node_budget)
                    break;
            }
            if (stopped(provider, cancel) || output.nodes >= node_budget)
                break;
        }
        std::stable_sort(next.begin(), next.end(), better);
        frontier.clear();
        std::set<std::string> retained;
        for (auto &line : next) {
            if (retained.insert(line.root_signature).second)
                frontier.push_back(std::move(line));
        }
    }
    for (const auto &root : roots) {
        const auto ready = complete.find(root.signature);
        if (ready != complete.end())
            output.lines.push_back(ready->second);
        else if (const auto found = partial.find(root.signature); found != partial.end())
            output.lines.push_back(found->second);
    }
    output.stopped = stopped(provider, cancel);
    std::stable_sort(output.lines.begin(), output.lines.end(), better);
    return output;
}

struct Sample {
    TurnResult turn;
    std::map<std::string, std::int64_t> exchanges;
    std::uint64_t exchange_nodes = 0;
    bool exchanges_complete = false;
    std::string exchange_reason = "not_applicable";
};

Sample evaluate_sample(SearchProvider &provider, const TurnPlannerConfig &config,
                       std::int32_t actor, std::uint32_t seed, std::size_t sample,
                       const Value &actions, const std::atomic<bool> *cancel) {
    Sample output;
    auto root = provider.determinize(sample, seed);
    if (!root)
        return output;
    output.turn =
        expand_turn(provider, *root, actor, actions, config.shallow ? 3 : config.max_depth,
                    config.node_budget, config.shallow ? 3 : 8, cancel);
    return output;
}

void evaluate_exchanges(SearchProvider &provider, std::int32_t actor, std::uint32_t seed,
                        Sample &output, const std::set<std::string> &roots,
                        const std::atomic<bool> *cancel) {
    output.exchanges_complete = !roots.empty();
    output.exchange_reason = roots.empty() ? "no_turn_candidate" : "complete_exchange";
    for (const Line &line : output.turn.lines) {
        if (!roots.count(line.root_signature))
            continue;
        if (provider.terminal(*line.position)) {
            output.exchanges[line.root_signature] = line.score;
            continue;
        }
        if (!line.ended || stopped(provider, cancel)) {
            output.exchanges_complete = false;
            output.exchange_reason = "own_turn_incomplete";
            break;
        }
        // The opponent chooses from its own observation. It must not optimize
        // against the exact private hand known to the root player.
        auto reply_root =
            provider.reply_information_view(*line.position, 1 - actor, seed + 500009U);
        if (!reply_root) {
            output.exchanges_complete = false;
            output.exchange_reason = "reply_view_unavailable";
            break;
        }
        const auto opponent = provider.decision_actor(*reply_root);
        if (opponent != 1 - actor) {
            output.exchanges_complete = false;
            output.exchange_reason =
                "opponent_not_ready:" + string_field(reply_root->search_state(), "phase");
            break;
        }
        auto reply = expand_turn(provider, *reply_root, opponent, Value(), 6, 32, 2, cancel);
        output.exchange_nodes += reply.nodes;
        auto best_reply = std::find_if(reply.lines.begin(), reply.lines.end(),
                                       [](const auto &candidate) { return candidate.ended; });
        if (reply.stopped || best_reply == reply.lines.end()) {
            output.exchanges_complete = false;
            output.exchange_reason = "reply_incomplete";
            break;
        }
        // Replay that response in the original world before valuing recovery.
        // Resampling the opponent's knowledge must never replace our real hand.
        std::shared_ptr<RulesSession> replied(line.position->fork_for_reply_search().release());
        bool replayed = true;
        for (const auto &action : best_reply->sequence) {
            auto child = apply_action(provider, *replied, opponent, action,
                                      "deck-response-" + std::to_string(opponent) + "-" +
                                          std::to_string(replied->revision()),
                                      output.exchange_nodes);
            if (!child.state) {
                replayed = false;
                break;
            }
            replied = std::move(child.state);
            if (provider.terminal(*replied))
                break;
        }
        if (!replayed) {
            output.exchanges_complete = false;
            output.exchange_reason = "reply_replay_incomplete";
            break;
        }
        const auto replied_score = provider.evaluate_state(*replied, actor);
        if (!replied_score) {
            output.exchanges_complete = false;
            output.exchange_reason = "reply_score_incomplete";
            break;
        }
        if (provider.terminal(*replied)) {
            output.exchanges[line.root_signature] = *replied_score.value;
            continue;
        }
        auto recovery_root = replied->fork_for_reply_search();
        if (provider.decision_actor(*recovery_root) != actor) {
            output.exchanges_complete = false;
            output.exchange_reason =
                "recovery_not_ready:" + string_field(recovery_root->search_state(), "phase");
            break;
        }
        auto recovery = expand_turn(provider, *recovery_root, actor, Value(), 6, 24, 2, cancel);
        output.exchange_nodes += recovery.nodes;
        const auto best_recovery =
            std::find_if(recovery.lines.begin(), recovery.lines.end(),
                         [](const auto &candidate) { return candidate.ended; });
        if (recovery.stopped || best_recovery == recovery.lines.end()) {
            output.exchanges_complete = false;
            output.exchange_reason = "recovery_incomplete";
            break;
        }
        output.exchanges[line.root_signature] =
            (line.score + *replied_score.value + best_recovery->score) / 3;
    }
}
} // namespace

TurnPlanner::TurnPlanner(SearchProvider &provider, TurnPlannerConfig config)
    : provider_(provider), config_(config) {
    if (config_.node_budget == 0 || config_.belief_samples == 0 || config_.belief_samples > 3 ||
        config_.worker_count == 0 || config_.worker_count > 3)
        throw std::invalid_argument("invalid_deck_planner_config");
}

SearchResult TurnPlanner::decide(std::int32_t actor, std::uint32_t seed, const Value &actions,
                                 const std::atomic<bool> *cancel) {
    SearchResult result;
    if (actor < 0 || actor > 1 || !actions.is_array() || actions.as_array().empty()) {
        result.error = "invalid_deck_planner_root";
        return result;
    }
    std::vector<Sample> samples(config_.belief_samples);
    const auto workers = std::min(config_.worker_count, config_.belief_samples);
    std::vector<std::future<Sample>> futures;
    for (std::size_t index = 1; index < workers; ++index) {
        futures.push_back(std::async(std::launch::async, [&, index] {
            return evaluate_sample(provider_, config_, actor,
                                   seed + static_cast<std::uint32_t>(index * 1000003), index,
                                   actions, cancel);
        }));
    }
    samples[0] = evaluate_sample(provider_, config_, actor, seed, 0, actions, cancel);
    for (std::size_t index = 1; index < workers; ++index)
        samples[index] = futures[index - 1].get();
    for (std::size_t index = workers; index < config_.belief_samples && !stopped(provider_, cancel);
         ++index)
        samples[index] = evaluate_sample(provider_, config_, actor,
                                         seed + static_cast<std::uint32_t>(index * 1000003), index,
                                         actions, cancel);

    // Select the reply candidates once across all worlds. Intersecting each
    // world's independently selected top three could leave a single mediocre
    // root and discard every alternative without a comparable reply search.
    std::map<std::string, std::pair<std::int64_t, std::size_t>> preliminary;
    std::size_t sampled_worlds = 0;
    for (const auto &sample : samples) {
        if (sample.turn.lines.empty())
            continue;
        ++sampled_worlds;
        for (const auto &line : sample.turn.lines) {
            auto &row = preliminary[line.root_signature];
            row.first += line.score;
            ++row.second;
        }
    }
    std::vector<std::pair<std::int64_t, std::string>> shortlist;
    for (const auto &[signature, row] : preliminary)
        if (row.second == sampled_worlds)
            shortlist.emplace_back(row.first, signature);
    std::sort(shortlist.begin(), shortlist.end(), [](const auto &a, const auto &b) {
        return a.first != b.first ? a.first > b.first : a.second < b.second;
    });
    std::set<std::string> exchange_roots;
    if (!config_.shallow)
        for (std::size_t i = 0; i < std::min<std::size_t>(3, shortlist.size()); ++i)
            exchange_roots.insert(shortlist[i].second);
    if (!exchange_roots.empty() && !stopped(provider_, cancel)) {
        std::vector<std::future<void>> refinements;
        const auto refine = [&](std::size_t index) {
            if (!samples[index].turn.lines.empty())
                evaluate_exchanges(provider_, actor,
                                   seed + static_cast<std::uint32_t>(index * 1000003),
                                   samples[index], exchange_roots, cancel);
        };
        for (std::size_t index = 1; index < workers; ++index)
            refinements.push_back(std::async(std::launch::async, refine, index));
        refine(0);
        for (auto &future : refinements)
            future.get();
        for (std::size_t index = workers; index < config_.belief_samples; ++index)
            refine(index);
    }
    if (cancel && cancel->load(std::memory_order_relaxed)) {
        result.cancelled = true;
        result.error = "cancelled";
        return result;
    }

    struct Aggregate {
        Line line;
        std::int64_t total = 0, worst = std::numeric_limits<std::int64_t>::max();
        std::size_t count = 0;
    };
    std::map<std::string, Aggregate> aggregate;
    const bool exchanges = !exchange_roots.empty() &&
                           std::all_of(samples.begin(), samples.end(), [](const auto &sample) {
                               return sample.turn.lines.empty() || sample.exchanges_complete;
                           });
    std::string trace;
    for (const auto &sample : samples) {
        result.nodes_expanded += sample.turn.nodes + sample.exchange_nodes;
        result.reply_completion_reasons.push_back(sample.exchange_reason);
        if (sample.turn.lines.empty())
            continue;
        ++result.belief_samples;
        result.completed_depth = std::max(result.completed_depth, sample.turn.depth);
        for (const auto &line : sample.turn.lines) {
            if (exchanges && !exchange_roots.count(line.root_signature))
                continue;
            const auto score = exchanges ? sample.exchanges.at(line.root_signature) : line.score;
            auto &row = aggregate[line.root_signature];
            if (row.count == 0)
                row.line = line;
            row.total += score;
            row.worst = std::min(row.worst, score);
            ++row.count;
            trace += line.signature + ":" + std::to_string(score) + "|";
        }
    }
    const Aggregate *best = nullptr;
    for (const auto &[signature, row] : aggregate) {
        result.root_signatures_attempted.push_back(signature);
        result.root_sample_counts[signature] = row.count;
        result.root_candidates.push_back(row.line.action);
        result.root_evaluations.push_back(Value(Value::Object{
            {"signature", Value(signature)},
            {"mean_score_milli", Value(row.total / static_cast<std::int64_t>(row.count))},
            {"worst_score_milli", Value(row.worst)},
            {"samples", Value(static_cast<std::int64_t>(row.count))},
            {"horizon", Value(exchanges ? "reply_and_recovery" : "own_turn")},
            {"complete_turn", Value(row.line.ended)},
        }));
        if (row.count != result.belief_samples)
            continue;
        if (!best || row.total > best->total ||
            (row.total == best->total &&
             (row.worst > best->worst ||
              (row.worst == best->worst && better(row.line, best->line)))))
            best = &row;
    }
    if (!best) {
        result.error = "no_completed_plan_comparison";
        return result;
    }
    result.success = true;
    result.selected = best->line.action;
    result.sequence = best->line.sequence;
    // Only the deterministic prefix can be replayed against the live match.
    if (!provider_.time_budget_exhausted())
        result.cache_preconditions = best->line.preconditions;
    result.score_milli = best->total / static_cast<std::int64_t>(best->count);
    result.worst_score_milli = best->worst;
    result.requested_depth = config_.shallow ? 3 : config_.max_depth;
    result.max_path_depth = best->line.sequence.size();
    result.layers_completed = result.completed_depth;
    result.reply_depth_applicable = exchanges;
    result.reply_completed_depth = exchanges ? 6 : 0;
    result.reply_completion_reason = exchanges ? "complete_exchange" : "not_applicable";
    result.completion_reason =
        provider_.time_budget_exhausted() ? "time_budget_exhausted" : "turn_planned";
    result.belief_consensus = result.belief_samples;
    result.belief_seed_hash =
        provider_.sha256_text(std::to_string(seed) + "|" + std::to_string(config_.belief_samples));
    result.trajectory_hash = provider_.sha256_text(trace);
    result.opponent_strategy_id = provider_.strategy_id_for_actor(*best->line.position, 1 - actor);
    if (exchanges)
        ++provider_.search_context()->completed_comparisons;
    return result;
}
} // namespace ptcg::ai
