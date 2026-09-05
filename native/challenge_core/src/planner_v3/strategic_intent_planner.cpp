#include "planner_v3/strategic_intent_planner.hpp"

#include "challenge_search_support.hpp"
#include "ptcg_traditional_policy.hpp"
#include "ptcg_traditional_value.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <limits>
#include <map>
#include <memory>
#include <numeric>
#include <set>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace ptcg::ai::planner_v3 {
namespace {

using namespace traditional_value;

bool cancelled(const std::atomic<bool> *flag) noexcept {
    return flag != nullptr && flag->load(std::memory_order_relaxed);
}

std::string action_card_id(const Value &action) {
    for (const char *container : {"source", "target", "payload"}) {
        const Value *entry = field(action, container);
        if (entry == nullptr || !entry->is_object()) continue;
        const std::string card_id = string_field(*entry, "card_id");
        if (!card_id.empty()) return card_id;
    }
    return {};
}

std::string action_slot(const Value &action) {
    for (const char *container : {"target", "source", "payload"}) {
        const Value *entry = field(action, container);
        if (entry == nullptr || !entry->is_object()) continue;
        const std::string slot = string_field(*entry, "slot");
        if (!slot.empty()) return slot;
    }
    return {};
}

using challenge::ExpandedAction;
using challenge::apply_action;

double readiness_sum(const AttackerPipeline &pipeline) {
    double result = 0.0;
    for (const AttackerClock &clock : pipeline.attackers) {
        const double role_multiplier = clock.primary_role ? 1.35
            : (clock.secondary_role ? 1.15
                : (clock.engine_role ? 0.45 : 0.75));
        result += clock.readiness_probability * role_multiplier;
    }
    return result;
}

PlanScore score_plan(
    const StrategicFacts &initial,
    const StrategicFacts &current,
    IntentKind intent,
    bool unpredictable
) {
    PlanScore score;
    if (current.terminal) {
        score.terminal_rank = current.winner == initial.actor ? 3
            : (current.winner < 0 ? 1 : 0);
    } else {
        score.terminal_rank = 2;
    }
    score.catastrophe_probability = current.threats.catastrophe_probability;
    score.prize_clock_margin = current.prize_race.clock_margin;
    score.guaranteed_prize_value = static_cast<double>(std::max<std::int64_t>(
        0,
        initial.prize_race.own_prizes_remaining
            - current.prize_race.own_prizes_remaining));
    score.next_attacker_readiness = current.own_attackers.next_readiness;
    score.resource_flexibility = current.resources.flexibility;
    score.strategic_progress =
        (readiness_sum(current.own_attackers)
            - readiness_sum(initial.own_attackers)) * 3.0
        + static_cast<double>(current.energy_schedule.ready_attackers) * 0.5
        - static_cast<double>(current.energy_schedule.total_missing_energy) * 0.08;
    switch (intent) {
        case IntentKind::WinNow:
        case IntentKind::TakePrizeSafely:
            score.strategic_progress += score.guaranteed_prize_value * 8.0;
            if (current.active_can_take_prize) score.strategic_progress += 1.5;
            break;
        case IntentKind::PreventImmediateLoss:
            score.strategic_progress +=
                (initial.threats.catastrophe_probability
                    - current.threats.catastrophe_probability) * 12.0;
            if (!initial.has_backup && current.has_backup) {
                score.strategic_progress += 5.0;
            }
            break;
        case IntentKind::PrepareNextAttacker:
        case IntentKind::AdvanceAttackerLine:
            score.strategic_progress +=
                (current.own_attackers.next_readiness
                    - initial.own_attackers.next_readiness) * 10.0;
            break;
        case IntentKind::EstablishEngine:
            score.strategic_progress += static_cast<double>(
                current.resources.bench_count - std::min(
                    current.resources.bench_count,
                    initial.resources.bench_count)) * 2.0;
            break;
        case IntentKind::ImproveHand:
            score.strategic_progress += static_cast<double>(
                current.resources.hand_size) * 0.08;
            break;
        case IntentKind::DisruptOpponent:
        case IntentKind::RecoverResources:
        case IntentKind::EndTurnSafely:
            break;
    }
    score.variance = unpredictable ? 1.0 : 0.0;
    if (initial.risk_mode == RiskMode::LowVariance) score.variance *= 1.5;
    else if (initial.risk_mode == RiskMode::SeekUpside) score.variance *= 0.5;
    return score;
}

struct ExpansionChoice {
    TraditionalRankedAction row;
    IntentKind intent = IntentKind::EndTurnSafely;
    double priority = 0.0;
    ActionFootprint footprint;
};

double intent_action_priority(
    const TurnIntent &intent,
    const StrategicFacts &facts,
    const MatchPlan &plan,
    const Value &state,
    std::int32_t actor,
    const Value &action,
    const CardSemanticModel &semantics,
    const TraditionalStrategyCatalog &strategies
) {
    const std::string kind = string_field(action, "kind");
    const std::string card_id = action_card_id(action);
    const std::string slot = action_slot(action);
    const CardSemanticProfile semantic = semantics.profile(card_id);
    double value = static_cast<double>(intent.priority);
    if (kind == "DECLARE_ATTACK") {
        value += facts.active_can_take_prize ? 180.0 : 55.0;
        if (intent.kind == IntentKind::WinNow) value += 250.0;
        if (intent.kind == IntentKind::PreventImmediateLoss
            && facts.threats.board_loss_threat) value += 45.0;
    } else if (kind == "ATTACH_ENERGY") {
        value += 35.0;
        const std::string priority_slot = facts.energy_schedule.priority_slot;
        if (!priority_slot.empty() && slot == priority_slot) value += 125.0;
        if (!plan.next_attacker_slot.empty()
            && slot == plan.next_attacker_slot) value += 65.0;
        if (facts.active_can_attack && slot == "active"
            && facts.own_attackers.next_readiness < 1.0) value -= 55.0;
    } else if (kind == "PLAY_BASIC") {
        value += facts.has_backup ? 18.0 : 135.0;
        if (strategies.card_has_role(
                state, actor, card_id, "primary_attacker")) value += 80.0;
        if (strategies.card_has_role(
                state, actor, card_id, "secondary_attacker")) value += 55.0;
        if (strategies.card_has_role(
                state, actor, card_id, "bench_engine")) value += 42.0;
        if (facts.resources.bench_slots_free == 0) value -= 200.0;
    } else if (kind == "EVOLVE") {
        value += 65.0;
        if (slot == plan.next_attacker_slot || slot == "active") value += 75.0;
        if (strategies.card_has_role(
                state, actor, card_id, "primary_attacker")) value += 60.0;
    } else if (kind == "RETREAT") {
        value += facts.threats.active_ko_threat ? 80.0 : -35.0;
        if (slot == plan.next_attacker_slot) value += 35.0;
    } else if (kind == "PLAY_TRAINER" || kind == "USE_ABILITY"
        || kind == "USE_STADIUM") {
        value += 20.0;
        if (semantic.search) value += 42.0;
        if (semantic.draw) value += 30.0;
        if (semantic.acceleration
            && (intent.kind == IntentKind::PrepareNextAttacker
                || intent.kind == IntentKind::AdvanceAttackerLine)) value += 75.0;
        if (semantic.gust
            && (intent.kind == IntentKind::TakePrizeSafely
                || intent.kind == IntentKind::WinNow)) value += 90.0;
        if (semantic.self_switch
            && intent.kind == IntentKind::PreventImmediateLoss) value += 65.0;
        if (semantic.recovery
            && intent.kind == IntentKind::RecoverResources) value += 55.0;
        if (semantic.hand_disruption
            && intent.kind == IntentKind::DisruptOpponent) value += 55.0;
    } else if (kind == "PROMOTE") {
        value += slot == plan.next_attacker_slot ? 120.0 : 45.0;
    } else if (kind == "END_TURN" || kind == "SETUP_DONE") {
        value -= facts.active_can_attack ? 140.0 : 30.0;
    }
    switch (intent.kind) {
        case IntentKind::WinNow:
        case IntentKind::TakePrizeSafely:
            if (kind == "DECLARE_ATTACK" || semantic.gust
                || semantic.acceleration || semantic.search) value += 50.0;
            if (intent.kind == IntentKind::WinNow) {
                if (kind == "PLAY_BASIC") value -= 180.0;
                if (kind == "END_TURN" && facts.opponent_deck_size == 0) {
                    value += 400.0;
                }
            }
            break;
        case IntentKind::PreventImmediateLoss:
            if (kind == "PLAY_BASIC" || kind == "RETREAT"
                || semantic.self_switch || semantic.heal
                || semantic.prevent_damage) value += 70.0;
            break;
        case IntentKind::PrepareNextAttacker:
        case IntentKind::AdvanceAttackerLine:
            if (kind == "ATTACH_ENERGY" || kind == "EVOLVE"
                || kind == "PLAY_BASIC" || semantic.acceleration
                || semantic.search) value += 65.0;
            break;
        case IntentKind::EstablishEngine:
            if (kind == "PLAY_BASIC" || kind == "EVOLVE"
                || kind == "USE_ABILITY" || semantic.search
                || semantic.draw) value += 45.0;
            break;
        case IntentKind::ImproveHand:
            if (semantic.draw || semantic.search) value += 55.0;
            break;
        case IntentKind::DisruptOpponent:
            if (semantic.gust || semantic.hand_disruption
                || semantic.energy_denial) value += 55.0;
            break;
        case IntentKind::RecoverResources:
            if (semantic.recovery) value += 70.0;
            break;
        case IntentKind::EndTurnSafely:
            break;
    }
    return value;
}

std::vector<ExpansionChoice> expansion_choices(
    TraditionalSearchProvider &provider,
    const RulesSession &position,
    std::int32_t actor,
    const Value &supplied,
    const std::vector<TurnIntent> &intents,
    const StrategicFacts &facts,
    const MatchPlan &plan,
    const CardSemanticModel &semantics,
    const TraditionalStrategyCatalog &strategies,
    std::size_t limit,
    const std::string &required_signature = {}
) {
    const std::size_t query_limit = supplied.is_array()
        ? supplied.as_array().size() : static_cast<std::size_t>(64);
    const auto ranked = provider.ranked_actions(
        position, actor, supplied, std::max<std::size_t>(1, query_limit));
    std::vector<ExpansionChoice> result;
    result.reserve(ranked.size());
    for (const TraditionalRankedAction &row : ranked) {
        ExpansionChoice choice;
        choice.row = row;
        choice.footprint = semantics.action_footprint(row.action);
        choice.priority = -std::numeric_limits<double>::infinity();
        for (const TurnIntent &intent : intents) {
            const double priority = intent_action_priority(
                intent,
                facts,
                plan,
                position.search_state(),
                actor,
                row.action,
                semantics,
                strategies);
            if (priority > choice.priority) {
                choice.priority = priority;
                choice.intent = intent.kind;
            }
        }
        // Existing ranking is a deterministic tie-break and domain prior, not
        // a second leaf score.
        choice.priority += std::max(-30.0, std::min(
            30.0, static_cast<double>(row.score_milli) / 10000.0));
        result.push_back(std::move(choice));
    }
    std::stable_sort(
        result.begin(), result.end(),
        [](const ExpansionChoice &left, const ExpansionChoice &right) {
            if (left.priority != right.priority) {
                return left.priority > right.priority;
            }
            if (left.row.score_milli != right.row.score_milli) {
                return left.row.score_milli > right.row.score_milli;
            }
            return left.row.signature < right.row.signature;
        });
    const std::string legacy_first = !required_signature.empty()
        ? required_signature
        : (ranked.empty() ? std::string{} : ranked.front().signature);
    if (result.size() > limit) result.resize(limit);
    if (!legacy_first.empty()
        && std::none_of(
            result.begin(), result.end(), [&legacy_first](const auto &entry) {
                return entry.row.signature == legacy_first;
            })) {
        const auto legacy = std::find_if(
            ranked.begin(), ranked.end(), [&legacy_first](const auto &entry) {
                return entry.signature == legacy_first;
            });
        if (legacy != ranked.end()) {
            ExpansionChoice choice;
            choice.row = *legacy;
            choice.footprint = semantics.action_footprint(legacy->action);
            choice.intent = intents.empty()
                ? IntentKind::EndTurnSafely : intents.front().kind;
            choice.priority = -1.0e12;
            if (result.empty()) result.push_back(std::move(choice));
            else result.back() = std::move(choice);
        }
    }
    return result;
}

struct PlanNode {
    std::shared_ptr<RulesSession> state;
    Value root_action = Value::make_object();
    Value::Array sequence;
    Value::Array preconditions;
    std::string root_signature;
    std::string sequence_signature;
    std::string fingerprint;
    StrategicFacts facts;
    PlanScore score;
    IntentKind intent = IntentKind::EndTurnSafely;
    std::size_t depth = 0;
    bool ended = false;
    bool unpredictable = false;
    bool cacheable = true;
    double scenario_utility = -std::numeric_limits<double>::infinity();
    double worst_scenario_utility = -std::numeric_limits<double>::infinity();
    std::size_t scenario_count = 1;
};

std::optional<PlanNode> evaluate_fixed_sequence(
    TraditionalSearchProvider &provider,
    std::unique_ptr<RulesSession> root_owner,
    const Value::Array &sequence,
    const StrategicFacts &initial,
    const StrategicAnalyzer &analyzer,
    const BeliefSummary &belief,
    std::int32_t actor,
    std::uint32_t seed,
    IntentKind intent,
    std::uint64_t &nodes_expanded
) {
    if (!root_owner || sequence.empty()) return std::nullopt;
    std::shared_ptr<RulesSession> root(root_owner.release());
    PlanNode node;
    node.intent = intent;
    node.cacheable = true;
    for (std::size_t depth = 0; depth < sequence.size(); ++depth) {
        const std::string expected = challenge::value_action_signature(
            sequence[depth]);
        const Value &legal = root->search_legal_action_candidates(actor);
        const Value *matched = challenge::find_action_by_signature(legal, expected);
        if (matched == nullptr) return std::nullopt;
        if (depth == 0) {
            node.root_action = *matched;
            node.root_signature = expected;
            node.sequence_signature = expected;
        } else {
            node.sequence_signature += "|" + expected;
        }
        node.preconditions.push_back(provider.cache_precondition(*root, actor));
        ExpandedAction expanded = apply_action(
            provider,
            *root,
            actor,
            *matched,
            provider.branch_seed(
                seed,
                depth + 1,
                node.root_signature,
                node.sequence_signature,
                depth),
            "strategic-legacy-shadow-" + std::to_string(depth),
            nodes_expanded);
        if (!expanded.state) return std::nullopt;
        node.sequence.push_back(*matched);
        node.unpredictable = node.unpredictable || expanded.trace.unpredictable;
        node.cacheable = node.cacheable && !expanded.trace.unpredictable;
        root = std::move(expanded.state);
        node.depth = depth + 1;
        node.ended = provider.terminal(*root)
            || provider.action_ends_turn(*matched)
            || provider.decision_actor(*root) != actor;
        if (node.ended && depth + 1 != sequence.size()) return std::nullopt;
    }
    node.state = std::move(root);
    node.fingerprint = provider.state_fingerprint(*node.state);
    node.facts = analyzer.analyze(*node.state, belief, actor);
    node.score = score_plan(initial, node.facts, intent, node.unpredictable);
    node.scenario_utility = plan_score_utility(node.score);
    node.worst_scenario_utility = node.scenario_utility;
    return node;
}

struct ThreatScenarioComparison {
    bool valid = false;
    bool cancelled = false;
    std::size_t samples = 0;
    std::uint64_t nodes_expanded = 0;
    std::int64_t minimum_gain_milli = std::numeric_limits<std::int64_t>::max();
    std::int64_t mean_gain_milli = 0;
};

struct RecoveryEvaluation {
    bool valid = false;
    bool cancelled = false;
    std::int64_t score_milli = 0;
    std::uint64_t nodes_expanded = 0;
};

RecoveryEvaluation evaluate_recovery_turn(
    TraditionalSearchProvider &provider,
    const std::shared_ptr<RulesSession> &position,
    std::int32_t actor,
    std::uint32_t seed,
    const std::atomic<bool> *cancel_requested
) {
    RecoveryEvaluation output;
    if (!position) return output;
    output.score_milli = provider.state_score_milli(*position, actor);
    if (provider.terminal(*position)) {
        output.valid = true;
        return output;
    }
    if (provider.decision_actor(*position) != actor) return output;

    struct RecoveryNode {
        std::shared_ptr<RulesSession> state;
        std::int64_t score_milli = 0;
        std::string sequence_signature;
    };
    constexpr std::size_t max_depth = 3;
    constexpr std::size_t beam_width = 2;
    constexpr std::size_t actions_per_node = 3;
    std::vector<RecoveryNode> frontier{
        RecoveryNode{position, output.score_milli, std::string{}}};
    RecoveryNode best_complete;
    bool have_complete = false;
    for (std::size_t depth = 1; depth <= max_depth; ++depth) {
        if (frontier.empty()) break;
        std::vector<RecoveryNode> next;
        for (const RecoveryNode &parent : frontier) {
            if (cancelled(cancel_requested)) {
                output.cancelled = true;
                return output;
            }
            if (provider.terminal(*parent.state)
                || provider.decision_actor(*parent.state) != actor) {
                if (!have_complete
                    || parent.score_milli > best_complete.score_milli
                    || (parent.score_milli == best_complete.score_milli
                        && parent.sequence_signature
                            < best_complete.sequence_signature)) {
                    best_complete = parent;
                    have_complete = true;
                }
                continue;
            }
            const auto ranked = provider.ranked_actions(
                *parent.state, actor, Value(), 16);
            const auto candidates = traditional_diverse_top_actions(
                ranked, actions_per_node);
            for (std::size_t index = 0; index < candidates.size(); ++index) {
                const TraditionalRankedAction &candidate = candidates[index];
                const std::string sequence = parent.sequence_signature
                    + "|" + candidate.signature;
                ExpandedAction expanded = apply_action(
                    provider,
                    *parent.state,
                    actor,
                    candidate.action,
                    provider.branch_seed(
                        seed, depth, "strategic-recovery", sequence, index),
                    "strategic-recovery-" + std::to_string(depth)
                        + "-" + std::to_string(index),
                    output.nodes_expanded);
                if (!expanded.state) continue;
                RecoveryNode child{
                    std::move(expanded.state), 0, sequence};
                child.score_milli = provider.state_score_milli(
                    *child.state, actor);
                const bool ended = provider.terminal(*child.state)
                    || provider.action_ends_turn(candidate.action)
                    || provider.decision_actor(*child.state) != actor;
                if (ended) {
                    if (!have_complete
                        || child.score_milli > best_complete.score_milli
                        || (child.score_milli == best_complete.score_milli
                            && child.sequence_signature
                                < best_complete.sequence_signature)) {
                        best_complete = std::move(child);
                        have_complete = true;
                    }
                } else {
                    next.push_back(std::move(child));
                }
            }
        }
        std::stable_sort(
            next.begin(), next.end(),
            [](const RecoveryNode &left, const RecoveryNode &right) {
                return left.score_milli != right.score_milli
                    ? left.score_milli > right.score_milli
                    : left.sequence_signature < right.sequence_signature;
            });
        if (next.size() > beam_width) next.resize(beam_width);
        frontier = std::move(next);
    }
    if (!have_complete) return output;
    output.valid = true;
    output.score_milli = best_complete.score_milli;
    return output;
}

bool deterministic_extension_of_legacy(
    const PlanNode &candidate,
    const PlanNode &legacy,
    const CardSemanticModel &semantics
) {
    if (candidate.sequence.size() < 2 || legacy.sequence.empty()) return false;
    const std::string legacy_root = challenge::value_action_signature(
        legacy.sequence.front());
    std::size_t matched_index = candidate.sequence.size();
    for (std::size_t index = 0; index < candidate.sequence.size(); ++index) {
        if (challenge::value_action_signature(candidate.sequence[index])
            == legacy_root) {
            matched_index = index;
            break;
        }
    }
    if (matched_index == 0 || matched_index + 1 != candidate.sequence.size()) {
        return false;
    }
    for (std::size_t index = 0; index < matched_index; ++index) {
        const ActionFootprint footprint = semantics.action_footprint(
            candidate.sequence[index]);
        if (footprint.random || footprint.reveals_information
            || footprint.terminal) return false;
    }
    return true;
}

bool reallocates_legacy_energy(
    const PlanNode &candidate,
    const PlanNode &legacy
) {
    const Value *candidate_attachment = nullptr;
    const Value *legacy_attachment = nullptr;
    for (const Value &action : candidate.sequence) {
        if (string_field(action, "kind") == "ATTACH_ENERGY") {
            candidate_attachment = &action;
            break;
        }
    }
    for (const Value &action : legacy.sequence) {
        if (string_field(action, "kind") == "ATTACH_ENERGY") {
            legacy_attachment = &action;
            break;
        }
    }
    if (candidate_attachment == nullptr || legacy_attachment == nullptr) {
        return false;
    }
    // This authority is specifically for allocating the same scarce energy
    // to a different attacker, not for approving an unrelated line that also
    // happens to attach another energy card.
    return action_card_id(*candidate_attachment)
            == action_card_id(*legacy_attachment)
        && action_slot(*candidate_attachment) != action_slot(*legacy_attachment);
}

constexpr std::size_t threat_scenario_samples = 5;
using LegacyScenarioCache = std::array<
    std::optional<RecoveryEvaluation>, threat_scenario_samples>;

RecoveryEvaluation evaluate_threat_scenario(
    TraditionalSearchProvider &provider,
    TraditionalTurnBeamSearch &reply_search,
    const PlanNode &plan,
    const StrategicFacts &initial,
    const StrategicAnalyzer &analyzer,
    const BeliefSummary &belief,
    std::int32_t actor,
    std::size_t sample,
    std::uint32_t sample_seed,
    const std::atomic<bool> *cancel_requested
) {
    RecoveryEvaluation output;
    std::optional<PlanNode> replay;
    const PlanNode *node = &plan;
    if (sample > 0) {
        replay = evaluate_fixed_sequence(
            provider, provider.determinize(sample, sample_seed), plan.sequence,
            initial, analyzer, belief, actor, sample_seed, plan.intent,
            output.nodes_expanded);
        if (!replay.has_value() || !replay->ended) return output;
        node = &*replay;
    }
    const auto reply = reply_search.evaluate_reply(
        *node->state, actor, sample_seed + 17U, cancel_requested);
    output.nodes_expanded += reply.nodes_expanded;
    if (reply.cancelled) {
        output.cancelled = true;
        return output;
    }
    auto recovery = evaluate_recovery_turn(
        provider, reply.resulting_position, actor, sample_seed + 101U,
        cancel_requested);
    recovery.nodes_expanded += output.nodes_expanded;
    return recovery;
}

ThreatScenarioComparison compare_threat_scenarios(
    TraditionalSearchProvider &provider,
    const PlanNode &candidate,
    const PlanNode &legacy,
    LegacyScenarioCache &legacy_scenarios,
    const StrategicFacts &initial,
    const StrategicAnalyzer &analyzer,
    const BeliefSummary &belief,
    std::int32_t actor,
    std::uint32_t seed,
    std::int64_t minimum_required_gain_milli,
    const std::atomic<bool> *cancel_requested
) {
    ThreatScenarioComparison output;
    if (!candidate.ended || !legacy.ended
        || !candidate.state || !legacy.state) {
        return output;
    }
    TraditionalSearchConfig reply_config;
    reply_config.reply_depth = 2;
    reply_config.reply_width = 3;
    reply_config.reply_actions_per_node = 3;
    reply_config.belief_samples = 1;
    reply_config.worker_count = 1;
    TraditionalTurnBeamSearch reply_search(provider, reply_config);
    long double total_gain = 0.0L;
    for (std::size_t sample = 0; sample < threat_scenario_samples; ++sample) {
        if (cancelled(cancel_requested)) {
            output.cancelled = true;
            return output;
        }
        const std::uint32_t sample_seed = seed
            + static_cast<std::uint32_t>(sample * 1000003ULL + 700001ULL);
        const RecoveryEvaluation candidate_recovery = evaluate_threat_scenario(
            provider, reply_search, candidate, initial, analyzer, belief,
            actor, sample, sample_seed, cancel_requested);
        output.nodes_expanded += candidate_recovery.nodes_expanded;
        if (candidate_recovery.cancelled || cancelled(cancel_requested)) {
            output.cancelled = true;
            return output;
        }
        if (!candidate_recovery.valid) return output;
        auto &cached = legacy_scenarios[sample];
        if (!cached.has_value()) {
            const auto recovery = evaluate_threat_scenario(
                provider, reply_search, legacy, initial, analyzer, belief,
                actor, sample, sample_seed, cancel_requested);
            output.nodes_expanded += recovery.nodes_expanded;
            if (recovery.cancelled || cancelled(cancel_requested)) {
                output.cancelled = true;
                return output;
            }
            cached = recovery;
        }
        const RecoveryEvaluation &legacy_recovery = *cached;
        if (!legacy_recovery.valid) return output;
        const std::int64_t gain = candidate_recovery.score_milli
            - legacy_recovery.score_milli;
        output.minimum_gain_milli = std::min(
            output.minimum_gain_milli, gain);
        total_gain += static_cast<long double>(gain);
        ++output.samples;
        // The authority gate is defined by the worst paired sample.  Once a
        // sample misses that floor, later samples cannot make the candidate
        // eligible, so avoid spending reply/recovery search on them.
        if (gain < minimum_required_gain_milli) return output;
    }
    output.valid = output.samples == threat_scenario_samples;
    if (output.valid) {
        output.mean_gain_milli = static_cast<std::int64_t>(std::llround(
            total_gain / static_cast<long double>(output.samples)));
    }
    return output;
}

bool node_better(const PlanNode &left, const PlanNode &right) {
    if (left.scenario_count > 1 && right.scenario_count > 1
        && left.scenario_utility != right.scenario_utility
        && std::isfinite(left.scenario_utility)
        && std::isfinite(right.scenario_utility)) {
        return left.scenario_utility > right.scenario_utility;
    }
    const int compared = compare_plan_score(left.score, right.score);
    if (compared != 0) return compared > 0;
    if (left.ended != right.ended) return left.ended;
    if (left.depth != right.depth) return left.depth > right.depth;
    return left.sequence_signature < right.sequence_signature;
}

struct CompilationResult {
    std::vector<PlanNode> candidates;
    std::vector<std::string> root_order;
    std::uint64_t nodes_expanded = 0;
    std::size_t completed_depth = 0;
    std::size_t max_path_depth = 0;
    std::size_t partial_order_pruned = 0;
    std::string trajectory_hash;
    std::uint64_t trajectory_events = 0;
};

CompilationResult compile_turn_plans(
    TraditionalSearchProvider &provider,
    std::unique_ptr<RulesSession> root_owner,
    const Value &root_actions,
    std::int32_t actor,
    std::uint32_t seed,
    const StrategicFacts &initial,
    const MatchPlan &match_plan,
    const std::vector<TurnIntent> &intents,
    DeliberationLevel level,
    const CardSemanticModel &semantics,
    const TraditionalStrategyCatalog &strategies,
    const StrategicAnalyzer &analyzer,
    const BeliefSummary &belief,
    const std::string &legacy_signature,
    std::uint64_t node_budget,
    bool smoke,
    const std::atomic<bool> *cancel_requested
) {
    CompilationResult output;
    if (!root_owner) return output;
    std::shared_ptr<RulesSession> root(root_owner.release());
    const bool terminal_focus = initial.opponent_deck_size == 0
        || initial.prize_race.own_prizes_remaining <= 4;
    const std::size_t max_depth = smoke ? 1
        : (terminal_focus ? 8
            : (level == DeliberationLevel::D1 ? 2
                : (level == DeliberationLevel::D2 ? 5 : 6)));
    const std::size_t beam_width = smoke ? 2
        : (terminal_focus ? 6
            : (level == DeliberationLevel::D1 ? 3
                : (level == DeliberationLevel::D2 ? 5 : 6)));
    const std::size_t actions_per_node = smoke ? 2
        : (terminal_focus ? 4
            : (level == DeliberationLevel::D1 ? 3
                : (level == DeliberationLevel::D2 ? 4 : 5)));
    const std::size_t root_limit = smoke ? 2
        : (terminal_focus ? 8
            : (level == DeliberationLevel::D1 ? 4 : 6));
    node_budget = std::max<std::uint64_t>(1, node_budget);
    const std::string root_fingerprint = provider.state_fingerprint(*root);
    const Value root_precondition = provider.cache_precondition(*root, actor);
    std::vector<PlanNode> frontier;
    std::unordered_map<std::string, PlanNode> best_by_root;
    std::unordered_map<std::string, std::pair<PlanScore, std::string>> seen;
    output.trajectory_hash = provider.sha256_text(
        "strategic_intent_v3:trajectory:v1");
    auto trace = [&](const std::string &event) {
        output.trajectory_hash = provider.trace_event(
            output.trajectory_hash, event);
        ++output.trajectory_events;
    };
    auto record = [&](const PlanNode &node) {
        const auto previous = seen.find(node.fingerprint);
        if (previous != seen.end()) {
            const int compared = compare_plan_score(
                node.score, previous->second.first);
            if (compared < 0 || (compared == 0
                    && previous->second.second <= node.sequence_signature)) {
                ++output.partial_order_pruned;
                return false;
            }
        }
        seen[node.fingerprint] = {node.score, node.sequence_signature};
        // A compiler candidate is an executable turn plan, not an attractive
        // intermediate state.  Previously a high-scoring partial node could
        // overwrite a completed line for the same root and was then rejected
        // later by the safety gate, effectively hiding the valid plan.
        if (node.ended) {
            const auto current = best_by_root.find(node.root_signature);
            if (current == best_by_root.end()
                || node_better(node, current->second)) {
                best_by_root[node.root_signature] = node;
            }
        }
        return true;
    };

    const auto roots = expansion_choices(
        provider,
        *root,
        actor,
        root_actions,
        intents,
        initial,
        match_plan,
        semantics,
        strategies,
        root_limit,
        legacy_signature);
    for (std::size_t index = 0; index < roots.size(); ++index) {
        if (cancelled(cancel_requested) || output.nodes_expanded >= node_budget) {
            break;
        }
        const ExpansionChoice &choice = roots[index];
        output.root_order.push_back(choice.row.signature);
        ExpandedAction expanded = apply_action(
            provider,
            *root,
            actor,
            choice.row.action,
            provider.branch_seed(
                seed, 1, choice.row.signature, choice.row.signature, index),
            "strategic-intent-root-" + std::to_string(index),
            output.nodes_expanded);
        if (!expanded.state) {
            trace("root|" + choice.row.signature + "|failed");
            continue;
        }
        const std::string fingerprint = provider.state_fingerprint(*expanded.state);
        const bool ended = provider.terminal(*expanded.state)
            || provider.action_ends_turn(choice.row.action)
            || provider.decision_actor(*expanded.state) != actor;
        if (!ended && fingerprint == root_fingerprint) continue;
        PlanNode node;
        node.state = std::move(expanded.state);
        node.root_action = choice.row.action;
        node.sequence = Value::Array{choice.row.action};
        node.preconditions = Value::Array{root_precondition};
        node.root_signature = choice.row.signature;
        node.sequence_signature = choice.row.signature;
        node.fingerprint = fingerprint;
        node.facts = analyzer.analyze(*node.state, belief, actor);
        node.intent = choice.intent;
        node.depth = 1;
        node.ended = ended;
        node.unpredictable = expanded.trace.unpredictable;
        node.cacheable = !expanded.trace.unpredictable;
        node.score = score_plan(initial, node.facts, node.intent, node.unpredictable);
        node.scenario_utility = plan_score_utility(node.score);
        node.worst_scenario_utility = node.scenario_utility;
        trace("root|" + choice.row.signature + "|intent="
            + intent_name(node.intent) + "|state=" + fingerprint);
        record(node);
        if (!ended && max_depth > 1) frontier.push_back(std::move(node));
        output.max_path_depth = 1;
    }
    output.completed_depth = roots.empty() ? 0 : 1;
    std::stable_sort(frontier.begin(), frontier.end(), node_better);
    if (frontier.size() > beam_width) frontier.resize(beam_width);

    for (std::size_t depth = 2; depth <= max_depth; ++depth) {
        if (frontier.empty() || output.nodes_expanded >= node_budget
            || cancelled(cancel_requested)) break;
        std::vector<PlanNode> next;
        for (const PlanNode &parent : frontier) {
            if (output.nodes_expanded >= node_budget
                || cancelled(cancel_requested)) break;
            const auto choices = expansion_choices(
                provider,
                *parent.state,
                actor,
                Value(),
                intents,
                parent.facts,
                match_plan,
                semantics,
                strategies,
                actions_per_node);
            for (std::size_t index = 0; index < choices.size(); ++index) {
                if (output.nodes_expanded >= node_budget) break;
                const ExpansionChoice &choice = choices[index];
                if (parent.sequence.size() >= 2) {
                    const ActionFootprint previous = semantics.action_footprint(
                        parent.sequence.back());
                    if (footprints_commute(previous, choice.footprint)
                        && choice.footprint.canonical_key
                            < previous.canonical_key) {
                        ++output.partial_order_pruned;
                        continue;
                    }
                }
                const std::string sequence_signature =
                    parent.sequence_signature + "|" + choice.row.signature;
                ExpandedAction expanded = apply_action(
                    provider,
                    *parent.state,
                    actor,
                    choice.row.action,
                    provider.branch_seed(
                        seed,
                        depth,
                        parent.root_signature,
                        sequence_signature,
                        index),
                    "strategic-intent-" + std::to_string(depth)
                        + "-" + std::to_string(index),
                    output.nodes_expanded);
                if (!expanded.state) continue;
                const std::string fingerprint = provider.state_fingerprint(
                    *expanded.state);
                const bool ended = provider.terminal(*expanded.state)
                    || provider.action_ends_turn(choice.row.action)
                    || provider.decision_actor(*expanded.state) != actor;
                if (!ended && fingerprint == parent.fingerprint) continue;
                PlanNode node = parent;
                node.state = std::move(expanded.state);
                node.sequence.push_back(choice.row.action);
                node.preconditions.push_back(provider.cache_precondition(
                    *parent.state, actor));
                node.sequence_signature = sequence_signature;
                node.fingerprint = fingerprint;
                node.facts = analyzer.analyze(*node.state, belief, actor);
                node.depth = depth;
                node.ended = ended;
                node.unpredictable = parent.unpredictable
                    || expanded.trace.unpredictable;
                node.cacheable = parent.cacheable
                    && !expanded.trace.unpredictable;
                node.score = score_plan(
                    initial, node.facts, node.intent, node.unpredictable);
                node.scenario_utility = plan_score_utility(node.score);
                node.worst_scenario_utility = node.scenario_utility;
                trace("depth=" + std::to_string(depth) + "|root="
                    + node.root_signature + "|action=" + choice.row.signature
                    + "|state=" + fingerprint);
                if (record(node) && !ended && depth < max_depth) {
                    next.push_back(std::move(node));
                }
                output.max_path_depth = std::max(
                    output.max_path_depth, depth);
            }
        }
        output.completed_depth = depth;
        std::stable_sort(next.begin(), next.end(), node_better);
        if (next.size() > beam_width) next.resize(beam_width);
        frontier = std::move(next);
    }
    for (const std::string &signature : output.root_order) {
        const auto found = best_by_root.find(signature);
        if (found != best_by_root.end()) {
            output.candidates.push_back(found->second);
        }
    }
    std::stable_sort(
        output.candidates.begin(), output.candidates.end(), node_better);
    return output;
}

std::optional<PlanScore> replay_plan_score(
    TraditionalSearchProvider &provider,
    std::unique_ptr<RulesSession> root,
    const PlanNode &candidate,
    const StrategicFacts &initial,
    const StrategicAnalyzer &analyzer,
    const BeliefSummary &belief,
    std::int32_t actor,
    std::uint32_t seed,
    std::uint64_t &nodes_expanded,
    bool &unpredictable
) {
    if (!root) return std::nullopt;
    for (std::size_t depth = 0; depth < candidate.sequence.size(); ++depth) {
        const std::string expected = challenge::value_action_signature(
            candidate.sequence[depth]);
        const Value &legal = root->search_legal_action_candidates(actor);
        const Value *matched = challenge::find_action_by_signature(legal, expected);
        if (matched == nullptr) break;
        ExpandedAction expanded = apply_action(
            provider,
            *root,
            actor,
            *matched,
            provider.branch_seed(
                seed, depth + 1, candidate.root_signature,
                candidate.sequence_signature, depth),
            "strategic-scenario-" + std::to_string(depth),
            nodes_expanded);
        if (!expanded.state) return std::nullopt;
        unpredictable = unpredictable || expanded.trace.unpredictable;
        root.reset(new RulesSession(*expanded.state));
        if (provider.terminal(*root)
            || provider.action_ends_turn(*matched)
            || provider.decision_actor(*root) != actor) break;
    }
    const StrategicFacts facts = analyzer.analyze(*root, belief, actor);
    return score_plan(initial, facts, candidate.intent, unpredictable);
}

void evaluate_scenarios(
    CompilationResult &compiled,
    TraditionalSearchProvider &provider,
    const StrategicAnalyzer &analyzer,
    const BeliefSummary &belief,
    const StrategicFacts &initial,
    std::int32_t actor,
    std::uint32_t seed,
    std::size_t belief_samples,
    RiskMode risk_mode,
    const std::atomic<bool> *cancel_requested
) {
    if (belief_samples <= 1 || compiled.candidates.empty()) return;
    const std::size_t evaluated = compiled.candidates.size();
    for (std::size_t index = 0; index < evaluated; ++index) {
        if (cancelled(cancel_requested)) return;
        PlanNode &candidate = compiled.candidates[index];
        std::vector<double> utilities{plan_score_utility(candidate.score)};
        for (std::size_t sample = 1; sample < belief_samples; ++sample) {
            const std::uint32_t sample_seed = seed
                + static_cast<std::uint32_t>(sample * 1000003ULL);
            bool unpredictable = false;
            const auto score = replay_plan_score(
                provider,
                provider.determinize(sample, sample_seed),
                candidate,
                initial,
                analyzer,
                belief,
                actor,
                sample_seed,
                compiled.nodes_expanded,
                unpredictable);
            utilities.push_back(score.has_value()
                ? plan_score_utility(*score) : -1'000'000.0);
        }
        const double total = std::accumulate(
            utilities.begin(), utilities.end(), 0.0);
        const double mean = total / static_cast<double>(utilities.size());
        const double worst = *std::min_element(
            utilities.begin(), utilities.end());
        const double lambda = risk_mode == RiskMode::LowVariance ? 0.45
            : (risk_mode == RiskMode::SeekUpside ? 0.10 : 0.25);
        candidate.scenario_utility = mean + lambda * (worst - mean);
        candidate.worst_scenario_utility = worst;
        candidate.scenario_count = utilities.size();
    }
    std::stable_sort(
        compiled.candidates.begin(), compiled.candidates.end(), node_better);
}

Value intents_value(const std::vector<TurnIntent> &intents) {
    Value::Array result;
    result.reserve(intents.size());
    for (const TurnIntent &intent : intents) {
        result.emplace_back(Value::Object{
            {"kind", Value(intent_name(intent.kind))},
            {"target_slot", Value(intent.target_slot)},
            {"required_damage", Value(intent.required_damage)},
            {"minimum_survival_probability", Value(
                intent.minimum_survival_probability)},
            {"preserve_next_attacker", Value(intent.preserve_next_attacker)},
            {"priority", Value(intent.priority)},
        });
    }
    return Value(std::move(result));
}

std::int64_t utility_milli(double utility) {
    const double bounded = std::max(-2'000'000'000.0,
        std::min(2'000'000'000.0, utility));
    return static_cast<std::int64_t>(std::llround(bounded));
}

} // namespace

MatchPlan HorizonPlanner::update_plan(
    const StrategicFacts &facts,
    const std::string &match_id,
    const std::optional<MatchPlan> &previous
) const {
    MatchPlan plan = previous.value_or(MatchPlan{});
    plan.match_id = match_id;
    plan.actor = facts.actor;
    plan.primary_attacker_slot = facts.own_attackers.current_slot;
    const auto slot_still_present = [&](const std::string &slot) {
        return !slot.empty() && std::any_of(
            facts.own_attackers.attackers.begin(),
            facts.own_attackers.attackers.end(),
            [&slot](const AttackerClock &clock) {
                return clock.slot == slot;
            });
    };
    if (!slot_still_present(plan.next_attacker_slot)) {
        plan.next_attacker_slot = facts.own_attackers.next_slot;
    }
    if (!slot_still_present(plan.backup_attacker_slot)
        || plan.backup_attacker_slot == plan.next_attacker_slot) {
        plan.backup_attacker_slot = facts.own_attackers.backup_slot;
    }
    plan.risk_mode = facts.risk_mode;
    plan.updated_turn = facts.turn_number;
    return plan;
}

std::vector<TurnIntent> HorizonPlanner::propose_intents(
    const StrategicFacts &facts,
    const MatchPlan &plan
) const {
    std::vector<TurnIntent> result;
    const bool potential_winning_line = facts.opponent_deck_size == 0
        || (facts.prize_race.own_prizes_remaining <= 4
            && !facts.own_attackers.attackers.empty()
            && facts.own_attackers.attackers.front().max_relevant_damage > 0);
    if ((facts.active_can_take_prize
            && facts.prize_race.own_prizes_remaining
                <= facts.prize_race.active_target_prizes)
        || potential_winning_line) {
        result.push_back(TurnIntent{
            IntentKind::WinNow,
            "opponent_active",
            facts.opponent_attackers.attackers.empty() ? 0
                : facts.opponent_attackers.attackers.front().expected_damage,
            0.0,
            false,
            300,
        });
    }
    if (facts.threats.board_loss_threat
        || facts.prize_race.opponent_turns_to_win <= 1.0) {
        result.push_back(TurnIntent{
            IntentKind::PreventImmediateLoss,
            "active",
            0,
            0.85,
            true,
            240,
        });
    }
    if (facts.active_can_take_prize) {
        result.push_back(TurnIntent{
            IntentKind::TakePrizeSafely,
            "opponent_active",
            0,
            facts.risk_mode == RiskMode::LowVariance ? 0.75 : 0.55,
            true,
            210,
        });
    }
    if (!plan.next_attacker_slot.empty()
        && facts.own_attackers.next_readiness < 0.999) {
        result.push_back(TurnIntent{
            IntentKind::PrepareNextAttacker,
            plan.next_attacker_slot,
            0,
            0.0,
            true,
            facts.active_can_attack ? 190 : 155,
        });
    }
    const bool needs_line = std::any_of(
        facts.own_attackers.attackers.begin(),
        facts.own_attackers.attackers.end(),
        [](const AttackerClock &clock) {
            return clock.missing_evolution_steps > 0;
        });
    if (needs_line) {
        result.push_back(TurnIntent{
            IntentKind::AdvanceAttackerLine,
            plan.next_attacker_slot,
            0,
            0.0,
            true,
            145,
        });
    }
    if (facts.turn_number <= 3 || facts.resources.bench_count < 2) {
        result.push_back(TurnIntent{
            IntentKind::EstablishEngine,
            "bench",
            0,
            0.0,
            true,
            120,
        });
    }
    if (facts.resources.hand_size <= 3) {
        result.push_back(TurnIntent{
            IntentKind::ImproveHand,
            "hand",
            0,
            0.0,
            true,
            90,
        });
    }
    result.push_back(TurnIntent{
        IntentKind::EndTurnSafely,
        "active",
        0,
        0.0,
        true,
        10,
    });
    return result;
}

DeliberationLevel DeliberationGate::select(
    const StrategicFacts &facts,
    const std::vector<TurnIntent> &intents,
    std::size_t legal_action_count
) const {
    if (legal_action_count <= 1 || (!intents.empty()
            && intents.front().kind == IntentKind::WinNow)) {
        return DeliberationLevel::D0;
    }
    const double uncertainty = std::max({
        facts.belief.p_has_gust,
        facts.belief.p_has_energy_out,
        facts.belief.p_has_hand_disruption,
    });
    if (facts.threats.catastrophe_probability >= 0.5
        || (facts.prize_race.own_turns_to_win <= 2.0
            && facts.prize_race.opponent_turns_to_win <= 2.0)
        || (uncertainty > 0.25 && facts.threats.active_ko_threat)) {
        return DeliberationLevel::D3;
    }
    if (facts.energy_schedule.attachment_available
        || facts.resources.bench_slots_free <= 1
        || intents.size() >= 4) {
        return DeliberationLevel::D2;
    }
    return DeliberationLevel::D1;
}

StrategicIntentPlanner::StrategicIntentPlanner(
    Value catalog,
    Value decks,
    const TraditionalStrategyCatalog &strategies
) : catalog_(std::move(catalog)), decks_(std::move(decks)),
    strategies_(strategies), semantics_(catalog_),
    belief_tracker_(catalog_, strategies_),
    analyzer_(catalog_, decks_, strategies_) {}

std::string StrategicIntentPlanner::memory_key(
    const std::string &match_id,
    std::int32_t actor
) const {
    return match_id + "|" + std::to_string(actor);
}

StrategicPlannerResult StrategicIntentPlanner::decide(
    const std::string &match_id,
    const TraditionalInformationSet &information,
    TraditionalSearchProvider &provider,
    std::int32_t actor,
    std::uint32_t seed,
    const Value &root_actions,
    StrategicPlannerConfig config,
    const std::atomic<bool> *cancel_requested
) {
    StrategicPlannerResult output;
    if (actor < 0 || actor > 1 || !root_actions.is_array()
        || root_actions.as_array().empty() || !information.valid()) {
        output.fallback_requested = true;
        output.fallback_reason = "invalid_strategic_root";
        return output;
    }
    if (cancelled(cancel_requested)) {
        output.plan.cancelled = true;
        output.plan.error = "cancelled";
        return output;
    }
    analyzer_.set_strategy_optimization(config.strategy_optimization);
    auto root = provider.determinize(0, seed);
    if (!root) {
        output.fallback_requested = true;
        output.fallback_reason = "strategic_determinization_failed";
        return output;
    }
    const BeliefSummary belief = belief_tracker_.summarize(
        information, information.public_snapshot(), actor);
    const StrategicFacts initial = analyzer_.analyze(*root, belief, actor);
    output.strategic_facts = strategic_facts_value(initial);
    const std::string key = memory_key(match_id, actor);
    const auto previous = match_plans_.find(key);
    MatchPlan match_plan = horizon_planner_.update_plan(
        initial,
        match_id,
        previous == match_plans_.end()
            ? std::optional<MatchPlan>{}
            : std::optional<MatchPlan>{previous->second});
    std::vector<TurnIntent> intents = horizon_planner_.propose_intents(
        initial, match_plan);
    output.deliberation = deliberation_gate_.select(
        initial, intents, root_actions.as_array().size());
    if (config.evaluation_smoke
        && output.deliberation > DeliberationLevel::D1) {
        output.deliberation = DeliberationLevel::D1;
    }
    output.intent = intents.empty()
        ? IntentKind::EndTurnSafely : intents.front().kind;
    match_plan.current_intent = output.intent;
    match_plans_[key] = match_plan;
    output.match_plan = match_plan_value(match_plan);

    // Dominance: unique legal action and a RulesSession-proven immediate win
    // need no heuristic search.
    const Value root_precondition = provider.cache_precondition(*root, actor);
    if (root_actions.as_array().size() == 1) {
        output.plan.success = true;
        output.plan.selected = root_actions.as_array().front();
        output.plan.sequence = Value::Array{output.plan.selected};
        output.plan.cache_preconditions = Value::Array{root_precondition};
        output.plan.root_candidates = Value::Array{output.plan.selected};
        output.plan.completion_reason = "dominance_unique_action";
        output.plan.trajectory_hash = provider.sha256_text(
            "strategic_intent_v3|dominance_unique_action|"
            + challenge::value_action_signature(output.plan.selected));
        output.plan.belief_samples = 1;
        output.plan.belief_consensus = 1;
        output.plan.root_signatures_attempted = {
            challenge::value_action_signature(output.plan.selected)};
        output.plan.root_sample_counts[
            output.plan.root_signatures_attempted.front()] = 1;
        output.dominance_resolved = true;
        output.cacheable = false;
        output.explanation = Value(Value::Object{
            {"dominance", Value("unique_legal_action")},
            {"intents", intents_value(intents)},
        });
        return output;
    }
    const auto ranked_roots = provider.ranked_actions(
        *root, actor, root_actions, root_actions.as_array().size());
    for (std::size_t index = 0; index < ranked_roots.size(); ++index) {
        if (string_field(ranked_roots[index].action, "kind")
            != "DECLARE_ATTACK") continue;
        std::uint64_t nodes = 0;
        ExpandedAction expanded = apply_action(
            provider,
            *root,
            actor,
            ranked_roots[index].action,
            provider.branch_seed(
                seed, 0, ranked_roots[index].signature,
                ranked_roots[index].signature, index),
            "strategic-dominance-win",
            nodes);
        if (!expanded.state) continue;
        const StrategicFacts after = analyzer_.analyze(
            *expanded.state, belief, actor);
        if (after.terminal && after.winner == actor
            && !expanded.trace.unpredictable) {
            output.plan.success = true;
            output.plan.selected = ranked_roots[index].action;
            output.plan.sequence = Value::Array{output.plan.selected};
            output.plan.cache_preconditions = Value::Array{root_precondition};
            output.plan.root_candidates = Value::Array{output.plan.selected};
            output.plan.nodes_expanded = nodes;
            output.plan.completion_reason = "dominance_immediate_win";
            output.plan.trajectory_hash = provider.sha256_text(
                "strategic_intent_v3|dominance_immediate_win|"
                + ranked_roots[index].signature);
            output.plan.belief_samples = 1;
            output.plan.belief_consensus = 1;
            output.plan.root_signatures_attempted = {
                ranked_roots[index].signature};
            output.plan.root_sample_counts[ranked_roots[index].signature] = 1;
            output.plan.score_milli = 2'000'000'000;
            output.plan.worst_score_milli = output.plan.score_milli;
            output.dominance_resolved = true;
            output.intent = IntentKind::WinNow;
            output.plan_score = plan_score_value(score_plan(
                initial, after, IntentKind::WinNow,
                expanded.trace.unpredictable));
            output.explanation = Value(Value::Object{
                {"dominance", Value("rules_proven_immediate_win")},
                {"intents", intents_value(intents)},
            });
            return output;
        }
    }

    if (string_field(root->search_state(), "phase") == "SETUP") {
        output.fallback_requested = true;
        output.fallback_reason = "setup_uses_frozen_public_policy";
        output.explanation = Value(Value::Object{
            {"fallback", Value(output.fallback_reason)},
            {"intents", intents_value(intents)},
        });
        return output;
    }

    if (config.legacy_decision) {
        const Value &legacy = config.legacy_decision();
        if (cancelled(cancel_requested) || bool_field(legacy, "cancelled")) {
            output.plan.cancelled = true;
            output.plan.error = "cancelled";
            return output;
        }
        const Value *action = legacy.find("action");
        if (action != nullptr) config.legacy_action = *action;
        config.legacy_sequence = array_field(legacy, "sequence");
    }
    const std::string legacy_signature = config.legacy_action.is_object()
            && !config.legacy_action.as_object().empty()
        ? challenge::value_action_signature(config.legacy_action)
        : (ranked_roots.empty() ? std::string{}
            : ranked_roots.front().signature);

    // Compile once at the first energy-allocation decision of a turn, before
    // that scarce commitment is made, then re-check at the attack/end
    // boundary.  A per-turn marker bounds the additional search.
    const std::string shadow_kind = config.legacy_action.is_object()
        ? string_field(config.legacy_action, "kind") : std::string{};
    const bool terminal_window = initial.opponent_deck_size == 0
        || initial.prize_race.own_prizes_remaining <= 4;
    const bool reply_comparison_window = shadow_kind == "DECLARE_ATTACK"
        || shadow_kind == "END_TURN";
    const auto attempted_turn = turn_compilation_attempts_.find(key);
    const bool turn_opening_window = shadow_kind == "ATTACH_ENERGY"
        && (attempted_turn == turn_compilation_attempts_.end()
            || attempted_turn->second != initial.turn_number);
    if (!terminal_window && !reply_comparison_window
        && !turn_opening_window) {
        output.fallback_requested = true;
        output.fallback_reason = "no_proof_obligation";
        output.explanation = Value(Value::Object{
            {"fallback", Value(output.fallback_reason)},
            {"legacy_root", Value(legacy_signature)},
            {"intents", intents_value(intents)},
        });
        return output;
    }
    turn_compilation_attempts_[key] = initial.turn_number;

    config.belief_samples = std::max<std::size_t>(1,
        std::min<std::size_t>(3, config.belief_samples));
    config.node_budget = std::max<std::uint64_t>(1, config.node_budget);
    CompilationResult compiled = compile_turn_plans(
        provider,
        std::move(root),
        root_actions,
        actor,
        seed,
        initial,
        match_plan,
        intents,
        output.deliberation,
        semantics_,
        strategies_,
        analyzer_,
        belief,
        legacy_signature,
        config.node_budget,
        config.evaluation_smoke,
        cancel_requested);
    if (cancelled(cancel_requested)) {
        output.plan.cancelled = true;
        output.plan.error = "cancelled";
        return output;
    }
    if (compiled.candidates.empty()) {
        output.fallback_requested = true;
        output.fallback_reason = "no_compilable_intent_plan";
        return output;
    }
    const std::size_t scenario_samples = output.deliberation
            == DeliberationLevel::D3
        ? config.belief_samples : 1;
    evaluate_scenarios(
        compiled,
        provider,
        analyzer_,
        belief,
        initial,
        actor,
        seed,
        scenario_samples,
        initial.risk_mode,
        cancel_requested);
    output.plan.nodes_expanded = compiled.nodes_expanded;
    output.plan.completed_depth = compiled.completed_depth;
    output.plan.max_path_depth = compiled.max_path_depth;
    if (cancelled(cancel_requested)) {
        output.plan.cancelled = true;
        output.plan.error = "cancelled";
        return output;
    }
    std::optional<PlanNode> actual_legacy;
    if (!config.legacy_sequence.empty()) {
        std::uint64_t legacy_nodes = 0;
        actual_legacy = evaluate_fixed_sequence(
            provider,
            provider.determinize(0, seed),
            config.legacy_sequence,
            initial,
            analyzer_,
            belief,
            actor,
            seed,
            IntentKind::EndTurnSafely,
            legacy_nodes);
        compiled.nodes_expanded += legacy_nodes;
    }
    const PlanNode *legacy = nullptr;
    if (actual_legacy.has_value()) {
        legacy = &*actual_legacy;
    } else {
        for (const PlanNode &candidate : compiled.candidates) {
            if (candidate.root_signature == legacy_signature) {
                legacy = &candidate;
                break;
            }
        }
    }
    // Migration is shadow-gated against the complete legacy controller for
    // this exact state.  A strategic root must finish the turn and prove a
    // concrete outcome improvement; heuristic risk/readiness deltas alone are
    // not sufficient authority to bypass mature mandatory/guard logic.
    const bool have_actual_legacy = config.legacy_action.is_object()
        && !config.legacy_action.as_object().empty();
    const PlanNode *best_ptr = &compiled.candidates.front();
    ThreatScenarioComparison threat_comparison;
    LegacyScenarioCache legacy_scenarios;
    bool selected_extension_dominance = false;
    bool selected_direct_attack_dominance = false;
    bool selected_general_plan_dominance = false;
    if (best_ptr->score.terminal_rank != 3 && legacy != nullptr) {
        constexpr std::size_t scenario_candidate_limit = 2;
        const std::size_t evaluated = std::min(
            scenario_candidate_limit, compiled.candidates.size());
        const PlanNode *scenario_choice = nullptr;
        ThreatScenarioComparison scenario_choice_comparison;
        bool scenario_choice_extension = false;
        bool scenario_choice_direct_attack = false;
        bool scenario_choice_general_plan = false;
        for (std::size_t index = 0; index < evaluated; ++index) {
            const PlanNode &candidate = compiled.candidates[index];
            if (candidate.root_signature == legacy_signature
                || candidate.score.guaranteed_prize_value
                    < legacy->score.guaranteed_prize_value
                || candidate.score.catastrophe_probability
                    > legacy->score.catastrophe_probability + 1e-9
                || candidate.score.prize_clock_margin
                    < legacy->score.prize_clock_margin - 1e-9) {
                continue;
            }
            const bool extension_shape = deterministic_extension_of_legacy(
                candidate, *legacy, semantics_);
            const bool direct_attack_shape = candidate.sequence.size() == 1
                && legacy->sequence.size() == 1
                && string_field(candidate.root_action, "kind")
                    == "DECLARE_ATTACK"
                && string_field(legacy->root_action, "kind")
                    == "DECLARE_ATTACK"
                && action_card_id(candidate.root_action)
                    == action_card_id(legacy->root_action);
            const bool energy_reallocation_shape = reallocates_legacy_energy(
                candidate, *legacy);
            if (!extension_shape && !direct_attack_shape
                && !energy_reallocation_shape) {
                continue;
            }
            ThreatScenarioComparison comparison = compare_threat_scenarios(
                provider,
                candidate,
                *legacy,
                legacy_scenarios,
                initial,
                analyzer_,
                belief,
                actor,
                seed,
                direct_attack_shape ? 50000 : 100000,
                cancel_requested);
            compiled.nodes_expanded += comparison.nodes_expanded;
            if (index == 0) threat_comparison = comparison;
            if (!comparison.valid) continue;
            const bool extension = extension_shape
                && comparison.minimum_gain_milli >= 100000
                && comparison.mean_gain_milli >= 120000;
            const bool direct_attack = direct_attack_shape
                && comparison.minimum_gain_milli >= 50000
                && comparison.mean_gain_milli >= 50000;
            // Permit a whole-line replacement when it reallocates the turn's
            // single energy commitment to another attacker.  Every sampled
            // worst reply plus recovery turn must still dominate materially,
            // after the immediate prize/clock/risk non-regression checks.
            const bool general_plan = energy_reallocation_shape
                && comparison.minimum_gain_milli >= 100000
                && comparison.mean_gain_milli >= 120000;
            if (!extension && !direct_attack && !general_plan) continue;
            if (scenario_choice == nullptr
                || comparison.minimum_gain_milli
                    > scenario_choice_comparison.minimum_gain_milli
                || (comparison.minimum_gain_milli
                        == scenario_choice_comparison.minimum_gain_milli
                    && comparison.mean_gain_milli
                        > scenario_choice_comparison.mean_gain_milli)) {
                scenario_choice = &candidate;
                scenario_choice_comparison = comparison;
                scenario_choice_extension = extension;
                scenario_choice_direct_attack = direct_attack;
                scenario_choice_general_plan = general_plan
                    && !extension && !direct_attack;
            }
        }
        if (scenario_choice != nullptr) {
            best_ptr = scenario_choice;
            threat_comparison = scenario_choice_comparison;
            selected_extension_dominance = scenario_choice_extension;
            selected_direct_attack_dominance = scenario_choice_direct_attack;
            selected_general_plan_dominance = scenario_choice_general_plan;
        }
    }
    const PlanNode &best = *best_ptr;
    const bool best_finishes_turn = best.ended;
    bool confident = best.score.terminal_rank == 3 && best_finishes_turn;
    std::string confidence_reason = confident ? "terminal_win"
        : (best.root_signature == legacy_signature
            ? "no_strategic_root_delta" : "strategic_override_ambiguous");
    const bool legacy_extension = legacy != nullptr
        && deterministic_extension_of_legacy(best, *legacy, semantics_);
    if (!confident && threat_comparison.valid && legacy != nullptr
        && (selected_extension_dominance
            || selected_direct_attack_dominance
            || selected_general_plan_dominance)
    ) {
        confident = true;
        confidence_reason = selected_direct_attack_dominance
            ? "reply_scenario_attack_dominance"
            : (selected_general_plan_dominance
                ? "reply_scenario_plan_dominance"
                : "reply_scenario_dominance");
    }
    if (!confident) {
        output.plan.nodes_expanded = compiled.nodes_expanded;
        output.fallback_requested = true;
        output.fallback_reason = confidence_reason;
        output.explanation = Value(Value::Object{
            {"fallback", Value(output.fallback_reason)},
            {"selected_root", Value(best.root_signature)},
            {"legacy_root", Value(legacy_signature)},
            {"actual_legacy", Value(have_actual_legacy)},
            {"proposed_sequence", Value(best.sequence)},
            {"proposed_score", plan_score_value(best.score)},
            {"legacy_score", legacy == nullptr
                ? Value::make_object() : plan_score_value(legacy->score)},
            {"proposed_ended", Value(best.ended)},
            {"proposed_unpredictable", Value(best.unpredictable)},
            {"reply_scenarios_valid", Value(threat_comparison.valid)},
            {"reply_scenario_samples", Value(static_cast<std::int64_t>(
                threat_comparison.samples))},
            {"reply_minimum_gain_milli", Value(
                threat_comparison.minimum_gain_milli
                    == std::numeric_limits<std::int64_t>::max()
                ? 0 : threat_comparison.minimum_gain_milli)},
            {"reply_mean_gain_milli", Value(
                threat_comparison.mean_gain_milli)},
            {"deterministic_legacy_extension", Value(legacy_extension)},
            {"intents", intents_value(intents)},
            {"partial_order_pruned", Value(static_cast<std::int64_t>(
                compiled.partial_order_pruned))},
        });
        return output;
    }
    auto validation_root = provider.determinize(0, seed);
    if (!validation_root) {
        output.fallback_requested = true;
        output.fallback_reason = "safety_determinization_failed";
        return output;
    }
    Value::Array legacy_validation_sequence = config.legacy_sequence;
    if (legacy_validation_sequence.empty() && have_actual_legacy) {
        legacy_validation_sequence.push_back(config.legacy_action);
    }
    const ValidationResult validation = safety_validator_.validate(
        best.sequence,
        legacy_validation_sequence,
        root_actions,
        *validation_root,
        actor,
        provider.branch_seed(
            seed, 991, best.root_signature, best.sequence_signature, 0),
        provider,
        confidence_reason == "terminal_win");
    if (!validation.valid) {
        output.fallback_requested = true;
        output.fallback_reason = "safety_rejected:" + validation.reason;
        return output;
    }

    output.plan.success = true;
    output.plan.selected = best.root_action;
    output.plan.sequence = best.sequence;
    output.plan.cache_preconditions = best.preconditions;
    for (const PlanNode &candidate : compiled.candidates) {
        output.plan.root_candidates.push_back(candidate.root_action);
        output.plan.root_signatures_attempted.push_back(
            candidate.root_signature);
        output.plan.root_sample_counts[candidate.root_signature] =
            candidate.scenario_count;
    }
    output.plan.score_milli = utility_milli(best.scenario_utility);
    output.plan.worst_score_milli = utility_milli(
        best.worst_scenario_utility);
    output.plan.nodes_expanded = compiled.nodes_expanded;
    output.plan.completed_depth = compiled.completed_depth;
    output.plan.max_path_depth = compiled.max_path_depth;
    output.plan.reply_completed_depth = 0;
    output.plan.reply_depth_applicable = false;
    output.plan.completion_reason = "intent_compiled";
    output.plan.trajectory_hash = compiled.trajectory_hash;
    output.plan.trajectory_events = compiled.trajectory_events;
    output.plan.belief_samples = scenario_samples;
    output.plan.belief_consensus = best.scenario_count;
    std::string seed_wire;
    for (std::size_t sample = 0; sample < scenario_samples; ++sample) {
        if (!seed_wire.empty()) seed_wire += ',';
        seed_wire += std::to_string(
            seed + static_cast<std::uint32_t>(sample * 1000003ULL));
    }
    output.plan.belief_seed_hash = provider.sha256_text(seed_wire);
    output.plan.layers_completed = compiled.completed_depth;
    output.intent = best.intent;
    match_plan.current_intent = best.intent;
    match_plans_[key] = match_plan;
    output.match_plan = match_plan_value(match_plan);
    output.plan_score = plan_score_value(best.score);
    output.cacheable = best.cacheable && best.sequence.size() > 1;
    output.explanation = Value(Value::Object{
        {"confidence", Value(confidence_reason)},
        {"selected_intent", Value(intent_name(best.intent))},
        {"deliberation", Value(deliberation_name(output.deliberation))},
        {"selected_root", Value(best.root_signature)},
        {"legacy_root", Value(legacy_signature)},
        {"root_changed", Value(best.root_signature != legacy_signature)},
        {"scenario_utility", Value(best.scenario_utility)},
        {"worst_scenario_utility", Value(best.worst_scenario_utility)},
        {"scenario_count", Value(static_cast<std::int64_t>(
            best.scenario_count))},
        {"reply_scenarios_valid", Value(threat_comparison.valid)},
        {"reply_scenario_samples", Value(static_cast<std::int64_t>(
            threat_comparison.samples))},
        {"reply_minimum_gain_milli", Value(
            threat_comparison.minimum_gain_milli
                == std::numeric_limits<std::int64_t>::max()
            ? 0 : threat_comparison.minimum_gain_milli)},
        {"reply_mean_gain_milli", Value(
            threat_comparison.mean_gain_milli)},
        {"deterministic_legacy_extension", Value(legacy_extension)},
        {"partial_order_pruned", Value(static_cast<std::int64_t>(
            compiled.partial_order_pruned))},
        {"safety", Value(validation.reason)},
        {"cacheable", Value(output.cacheable)},
        {"intents", intents_value(intents)},
    });
    return output;
}

void StrategicIntentPlanner::reset_match(const std::string &match_id) {
    if (active_match_id_ != match_id) {
        match_plans_.clear();
        turn_compilation_attempts_.clear();
    }
    active_match_id_ = match_id;
}

} // namespace ptcg::ai::planner_v3
