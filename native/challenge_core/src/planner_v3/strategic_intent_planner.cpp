#include "planner_v3/strategic_intent_planner.hpp"

#include "challenge_search_support.hpp"
#include "ptcg_traditional_policy.hpp"
#include "ptcg_traditional_value.hpp"

#include <algorithm>
#include <future>
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
    for (const auto &row : ranked) {
        if (!provider.action_ends_turn(row.action)) continue;
        if (std::none_of(result.begin(), result.end(), [&](const auto &entry) { return entry.row.signature == row.signature; })) {
            result.push_back({row, intents.empty() ? IntentKind::EndTurnSafely : intents.front().kind,
                -1.0e12, semantics.action_footprint(row.action)});
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
    if (!root_owner || sequence.empty() || provider.search_stopped()) return std::nullopt;
    const auto root_key = provider.search_context()->memoize<std::string>(SearchMemo::Fingerprint,
        *root_owner, root_owner->search_state(), -1, 1, [&] {
            return provider.sha256_text(challenge::information_value_signature(root_owner->search_state()));
        });
    // Include the complete root and RNG, not just the supplied scenario seed:
    // another provider may produce different beliefs for the same seed.
    std::string replay_key = "replay|" + root_key + "|" + std::to_string(root_owner->rng_state())
        + "|" + std::to_string(seed) + "|" + intent_name(intent);
    for (const auto &action : sequence) replay_key += "|" + challenge::value_action_signature(action);
    if (const auto cached = provider.search_context()->find_result<PlanNode>(replay_key)) {
        ++provider.search_context()->replay_cache_hits;
        return *cached;
    }
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
        // The next state replaces root and destroys its legal-action cache.
        // Keep a value before advancing so the turn-boundary check stays valid.
        const Value action = *matched;
        if (depth == 0) {
            node.root_action = action;
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
            action,
            provider.branch_seed(
                seed,
                depth + 1,
                node.root_signature,
                node.sequence_signature,
                depth),
            "strategic-legacy-shadow-" + std::to_string(depth),
            nodes_expanded);
        if (!expanded.state) return std::nullopt;
        node.sequence.push_back(action);
        node.unpredictable = node.unpredictable || expanded.trace.unpredictable;
        node.cacheable = node.cacheable && !expanded.trace.unpredictable;
        root = std::move(expanded.state);
        node.depth = depth + 1;
        node.ended = provider.terminal(*root)
            || provider.action_ends_turn(action)
            || provider.decision_actor(*root) != actor;
        if (node.ended && depth + 1 != sequence.size()) return std::nullopt;
    }
    node.state = std::move(root);
    node.fingerprint = provider.state_fingerprint(*node.state);
    const auto facts = provider.evaluate([&] { return analyzer.analyze(*node.state, belief, actor); });
    if (!facts) return std::nullopt;
    node.facts = *facts.value;
    node.score = score_plan(initial, node.facts, intent, node.unpredictable);
    node.scenario_utility = plan_score_utility(node.score);
    node.worst_scenario_utility = node.scenario_utility;
    if (node.ended) provider.search_context()->remember_result(replay_key, node);
    return node;
}

struct ThreatScenarioComparison {
    bool valid = false;
    bool cancelled = false;
    std::size_t samples = 0;
    std::uint64_t nodes_expanded = 0;
    std::int64_t minimum_gain_milli = std::numeric_limits<std::int64_t>::max();
    std::int64_t mean_gain_milli = 0;
    std::size_t reply_completed_depth = 6;
};

struct RecoveryEvaluation {
    bool valid = false;
    bool cancelled = false;
    std::int64_t score_milli = 0;
    std::uint64_t nodes_expanded = 0;
    std::size_t reply_completed_depth = 0;
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
    const auto initial_score = provider.evaluate_state(*position, actor);
    if (!initial_score) return output;
    output.score_milli = *initial_score.value;
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
    constexpr std::size_t max_depth = 6;
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
            if (cancelled(cancel_requested)) { output.cancelled = true; return output; }
            if (provider.search_stopped()) return output;
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
            auto candidates = traditional_diverse_top_actions(
                ranked, actions_per_node);
            for (const auto &row : ranked) {
                if (provider.action_ends_turn(row.action)
                    && std::none_of(candidates.begin(), candidates.end(), [&](const auto &other) {
                        return other.signature == row.signature;
                    })) candidates.push_back(row);
            }
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
                const auto score = provider.evaluate_state(*child.state, actor);
                if (!score) return output;
                child.score_milli = *score.value;
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
    if (!have_complete || provider.search_stopped()) return output;
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

constexpr std::size_t threat_scenario_samples = 3;

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
    if (provider.search_stopped()) return output;
    auto sample_root = sample > 0 ? provider.determinize(sample, sample_seed) : std::unique_ptr<RulesSession>{};
    const RulesSession *cache_root = sample == 0 ? plan.state.get() : sample_root.get();
    if (!cache_root) return output;
    const auto root_key = provider.search_context()->memoize<std::string>(SearchMemo::Fingerprint,
        *cache_root, cache_root->search_state(), -1, 1, [&] {
            return provider.sha256_text(challenge::information_value_signature(cache_root->search_state()));
        });
    const auto cache_key = "exchange|" + std::to_string(actor) + "|" + std::to_string(sample_seed)
        + "|" + plan.sequence_signature + "|" + root_key + "|" + std::to_string(cache_root->rng_state())
        + "|policy=" + std::to_string(provider.search_context()->ranking_policy(false));
    if (auto cached = provider.search_context()->find_result<RecoveryEvaluation>(cache_key)) {
        ++provider.search_context()->exchange_cache_hits;
        cached->nodes_expanded = 0;
        return *cached;
    }
    std::optional<PlanNode> replay;
    const PlanNode *node = &plan;
    if (sample > 0) {
        replay = evaluate_fixed_sequence(
            provider, std::move(sample_root), plan.sequence,
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
    if (provider.search_stopped() || reply.completion_reason == "time_budget_exhausted") return output;
    auto recovery = evaluate_recovery_turn(provider, reply.resulting_position, actor, sample_seed + 101U, cancel_requested);
    recovery.nodes_expanded += output.nodes_expanded;
    recovery.reply_completed_depth = reply.completed_depth;
    if (recovery.valid && !recovery.cancelled) provider.search_context()->remember_result(cache_key, recovery);
    return recovery;
}

ThreatScenarioComparison compare_threat_scenarios(
    TraditionalSearchProvider &provider,
    const PlanNode &candidate,
    const PlanNode &legacy,
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
    struct Pair {
        bool valid = false; bool cancelled = false;
        std::int64_t gain = 0; std::uint64_t nodes = 0;
        std::size_t reply_completed_depth = 0;
    };
    const auto evaluate_pair = [&](std::size_t sample, bool parallel_sides) {
        Pair result;
        TraditionalSearchConfig reply_config;
        reply_config.reply_depth = 6; reply_config.reply_width = 3;
        reply_config.reply_actions_per_node = 3; reply_config.belief_samples = 1;
        reply_config.complete_turn_replies = true;
        TraditionalTurnBeamSearch reply_search(provider, reply_config);
        const auto sample_seed = seed + static_cast<std::uint32_t>(sample * 1000003ULL);
        const auto run = [&](const PlanNode &plan) { return evaluate_threat_scenario(provider,
            reply_search, plan, initial, analyzer, belief, actor, sample, sample_seed, cancel_requested); };
        RecoveryEvaluation own, prior;
        if (parallel_sides) {
            auto future = std::async(std::launch::async, [&] { return run(candidate); });
            prior = run(legacy); own = future.get();
        } else { own = run(candidate); prior = run(legacy); }
        result.nodes = own.nodes_expanded + prior.nodes_expanded;
        result.cancelled = own.cancelled || prior.cancelled || cancelled(cancel_requested);
        result.valid = own.valid && prior.valid && !result.cancelled && !provider.search_stopped();
        result.gain = own.score_milli - prior.score_milli;
        result.reply_completed_depth = std::min(own.reply_completed_depth, prior.reply_completed_depth);
        return result;
    };
    std::int64_t total = 0;
    const auto reduce = [&](const Pair &pair) {
        output.nodes_expanded += pair.nodes;
        output.cancelled = output.cancelled || pair.cancelled;
        if (!pair.valid) return false;
        ++output.samples;
        output.reply_completed_depth = std::min(output.reply_completed_depth, pair.reply_completed_depth);
        output.minimum_gain_milli = std::min(output.minimum_gain_milli, pair.gain);
        total += pair.gain;
        return pair.gain >= minimum_required_gain_milli;
    };
    const bool parallel = provider.search_context()->worker_count > 1;
    if (!reduce(evaluate_pair(0, parallel))) return output;
    // A bad first paired sample rejects cheaply. Remaining samples may run
    // concurrently, but reductions and tie breaks always use sample order.
    Pair second, third;
    if (parallel) {
        auto future = std::async(std::launch::async, [&] { return evaluate_pair(1, false); });
        third = evaluate_pair(2, false); second = future.get();
    } else {
        second = evaluate_pair(1, false);
        if (!reduce(second)) return output;
        third = evaluate_pair(2, false);
    }
    if (parallel) {
        const bool second_ok = reduce(second);
        const bool third_ok = reduce(third); // Count actual completed work even on rejection.
        if (!second_ok || !third_ok) return output;
    } else if (!reduce(third)) return output;
    output.valid = output.samples == threat_scenario_samples;
    if (output.valid) {
        output.mean_gain_milli = static_cast<std::int64_t>(std::llround(static_cast<double>(total) / output.samples));
        ++provider.search_context()->completed_comparisons;
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
    std::vector<PlanNode> prior_candidates;
    std::vector<std::string> root_order;
    std::uint64_t nodes_expanded = 0;
    std::size_t completed_depth = 0, max_path_depth = 0, partial_order_pruned = 0, requested_depth = 0;
    std::string trajectory_hash;
    std::uint64_t trajectory_events = 0;
    // Continuation is retained between work batches, including an unfinished
    // layer and its already-ranked next actions. No prefix is searched twice.
    std::vector<PlanNode> frontier, next;
    std::vector<ExpansionChoice> pending_choices;
    std::map<std::string, PlanNode> best_by_root;
    std::set<std::string> seen;
    std::size_t parent_index = 0, action_index = 0, depth = 1;
    bool initialized = false, done = false;
};

void advance_turn_plans(
    CompilationResult &output,
    TraditionalSearchProvider &provider,
    const std::shared_ptr<RulesSession> &root,
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
    bool anytime,
    const std::atomic<bool> *cancel_requested
) {
    if (!root || output.done) return;
    ++provider.search_context()->candidate_batches;
    const bool terminal_focus = initial.opponent_deck_size == 0 || initial.prize_race.own_prizes_remaining <= 4;
    const std::size_t normal_depth = smoke ? 1 : terminal_focus ? 8
        : level == DeliberationLevel::D1 ? 2 : level == DeliberationLevel::D2 ? 5 : 6;
    const std::size_t max_depth = anytime && !smoke ? std::min<std::size_t>(10, normal_depth + 2) : normal_depth;
    output.requested_depth = max_depth;
    const std::size_t actions_per_node = smoke ? 2 : terminal_focus ? 4 : level == DeliberationLevel::D1 ? 3 : 5;
    const std::size_t root_limit = smoke ? 2 : terminal_focus ? 8 : level == DeliberationLevel::D1 ? 4 : 6;
    // Root coverage must not consume the entire beam. Keep the guaranteed
    // route per root, then award a comparable amount of additional capacity
    // to the best preparations; the shared deadline bounds the extra work.
    const std::size_t beam_width = anytime && !smoke ? root_limit * 2
        : smoke ? 2 : terminal_focus ? 6 : level == DeliberationLevel::D1 ? 3 : 6;
    if (!output.initialized) {
        PlanNode node;
        node.state = root; node.facts = initial; node.fingerprint = provider.state_fingerprint(*root);
        output.frontier.push_back(std::move(node));
        output.trajectory_hash = provider.sha256_text("strategic_intent_v3:progressive:v1");
        output.initialized = true;
    }
    const auto target_nodes = output.nodes_expanded + std::max<std::uint64_t>(1, node_budget);
    const auto trace = [&](const std::string &event) {
        output.trajectory_hash = provider.trace_event(output.trajectory_hash, event);
        ++output.trajectory_events;
    };
    const auto can_extend = [&](const PlanNode &parent) {
        if (output.depth <= normal_depth) return true;
        if (parent.sequence.empty()) return false;
        const auto kind = string_field(parent.sequence.back(), "kind");
        const bool resource = kind == "ATTACH_ENERGY" || kind == "EVOLVE"
            || kind == "PLAY_TRAINER" || kind == "USE_ABILITY" || kind == "RETREAT";
        return resource && (parent.facts.active_can_attack
            || parent.facts.energy_schedule.priority_missing_energy <= 1);
    };
    while (!output.frontier.empty() && output.depth <= max_depth
        && output.nodes_expanded < target_nodes && !provider.search_stopped()
        && !cancelled(cancel_requested)) {
        if (output.parent_index >= output.frontier.size()) {
            output.completed_depth = output.depth;
            std::stable_sort(output.next.begin(), output.next.end(), node_better);
            std::vector<PlanNode> frontier;
            std::set<std::string> represented;
            if (anytime) {
                // Keep preparation routes alive across the first layers. Facts
                // may be shared, but root/intent/path metadata remain distinct.
                for (const auto &node : output.next) {
                    if (represented.insert(node.root_signature).second) frontier.push_back(node);
                }
            }
            const auto width = std::max(beam_width, frontier.size());
            for (const auto &node : output.next) {
                if (frontier.size() >= width) break;
                if (std::none_of(frontier.begin(), frontier.end(), [&](const PlanNode &other) {
                    return other.sequence_signature == node.sequence_signature;
                })) frontier.push_back(node);
            }
            output.frontier = std::move(frontier);
            output.next.clear(); output.parent_index = 0; output.action_index = 0;
            output.pending_choices.clear(); ++output.depth;
            continue;
        }
        const PlanNode &parent = output.frontier[output.parent_index];
        if (!can_extend(parent)) { ++output.parent_index; output.pending_choices.clear(); output.action_index = 0; continue; }
        if (output.pending_choices.empty()) {
            output.pending_choices = expansion_choices(provider, *parent.state, actor,
                output.depth == 1 ? root_actions : Value(), intents, parent.facts, match_plan,
                semantics, strategies, output.depth == 1 ? root_limit : actions_per_node,
                output.depth == 1 ? legacy_signature : std::string{});
        }
        if (output.action_index >= output.pending_choices.size()) {
            ++output.parent_index; output.pending_choices.clear(); output.action_index = 0; continue;
        }
        const auto index = output.action_index++;
        const ExpansionChoice choice = output.pending_choices[index];
        if (parent.sequence.size() >= 2 && footprints_commute(
                semantics.action_footprint(parent.sequence.back()), choice.footprint)
            && choice.footprint.canonical_key < semantics.action_footprint(parent.sequence.back()).canonical_key) {
            ++output.partial_order_pruned; continue;
        }
        const auto signature = parent.sequence_signature.empty() ? choice.row.signature
            : parent.sequence_signature + "|" + choice.row.signature;
        const auto root_signature = parent.root_signature.empty() ? choice.row.signature : parent.root_signature;
        ExpandedAction expanded = apply_action(provider, *parent.state, actor, choice.row.action,
            provider.branch_seed(seed, output.depth, root_signature, signature, index),
            "strategic-intent-" + std::to_string(output.depth) + "-" + std::to_string(index), output.nodes_expanded);
        if (!expanded.state) continue;
        const auto fingerprint = provider.state_fingerprint(*expanded.state);
        const bool ended = provider.terminal(*expanded.state) || provider.action_ends_turn(choice.row.action)
            || provider.decision_actor(*expanded.state) != actor;
        if (!ended && fingerprint == parent.fingerprint) continue;
        // Only deterministic paths are deduplicated, with the policy's complete
        // action history retained. Cycle fingerprints alone omit that history.
        const auto *history = field(expanded.state->search_state(), "action_log");
        const auto history_key = history ? challenge::stable_value_signature(*history) : std::string{};
        const auto seen_key = root_signature + "|" + fingerprint + "|" + history_key;
        if (!parent.unpredictable && !expanded.trace.unpredictable && !output.seen.insert(seen_key).second) {
            ++output.partial_order_pruned; continue;
        }
        const auto facts = provider.evaluate([&] { return analyzer.analyze(*expanded.state, belief, actor); });
        if (!facts) break;
        PlanNode node = parent;
        node.state = std::move(expanded.state);
        if (output.depth == 1) {
            node.root_action = choice.row.action; node.root_signature = root_signature;
            node.intent = choice.intent;
            output.root_order.push_back(root_signature);
        }
        node.sequence.push_back(choice.row.action);
        node.preconditions.push_back(provider.cache_precondition(*parent.state, actor));
        node.sequence_signature = signature; node.fingerprint = fingerprint;
        node.facts = *facts.value; node.depth = output.depth; node.ended = ended;
        node.unpredictable = parent.unpredictable || expanded.trace.unpredictable;
        node.cacheable = parent.cacheable && !expanded.trace.unpredictable;
        node.score = score_plan(initial, node.facts, node.intent, node.unpredictable);
        node.scenario_utility = node.worst_scenario_utility = plan_score_utility(node.score);
        trace("depth=" + std::to_string(output.depth) + "|root=" + root_signature + "|state=" + fingerprint);
        output.max_path_depth = std::max(output.max_path_depth, output.depth);
        if (ended) {
            const auto found = output.best_by_root.find(root_signature);
            if (found == output.best_by_root.end() || node_better(node, found->second)) output.best_by_root[root_signature] = node;
        } else if (output.depth < max_depth) output.next.push_back(std::move(node));
    }
    output.done = output.frontier.empty() || output.depth > max_depth;
    output.candidates.clear();
    for (const auto &[signature, node] : output.best_by_root) output.candidates.push_back(node);
    for (const auto &node : output.prior_candidates) {
        if (std::none_of(output.candidates.begin(), output.candidates.end(), [&](const PlanNode &other) {
            return other.sequence_signature == node.sequence_signature;
        })) output.candidates.push_back(node);
    }
    std::stable_sort(output.candidates.begin(), output.candidates.end(), node_better);
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
    auto replay = evaluate_fixed_sequence(provider, std::move(root), candidate.sequence,
        initial, analyzer, belief, actor, seed, candidate.intent, nodes_expanded);
    if (!replay || !replay->ended) return std::nullopt;
    unpredictable = replay->unpredictable;
    return replay->score;
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
    const std::size_t evaluated = std::min<std::size_t>(4, compiled.candidates.size());
    for (std::size_t index = 0; index < evaluated; ++index) {
        if (provider.time_budget_exhausted()) return;
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
            if (provider.search_stopped()) return;
            utilities.push_back(score.has_value() ? plan_score_utility(*score) : -1'000'000.0);
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
    // Slots are locations, not Pokemon identities. Re-evaluate commitments
    // after a promotion, evolution, loss, or a newly accessible resource.
    plan.next_attacker_slot = facts.own_attackers.next_slot;
    plan.backup_attacker_slot = facts.own_attackers.backup_slot;
    plan.next_attacker_card_id.clear();
    plan.backup_attacker_card_id.clear();
    for (const AttackerClock &clock : facts.own_attackers.attackers) {
        if (clock.slot == plan.next_attacker_slot) plan.next_attacker_card_id = clock.card_id;
        if (clock.slot == plan.backup_attacker_slot) plan.backup_attacker_card_id = clock.card_id;
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
    if (facts.resources.disruption_outs_visible > 0) {
        result.push_back(TurnIntent{IntentKind::DisruptOpponent, "opponent", 0,
            0.0, true, facts.threats.active_ko_threat ? 200 : 100});
    }
    if (facts.resources.recovery_outs_visible > 0
        && (facts.energy_schedule.total_missing_energy > 0
            || facts.own_attackers.next_readiness < 0.75)) {
        result.push_back(TurnIntent{IntentKind::RecoverResources,
            plan.next_attacker_slot, 0, 0.0, true, 160});
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
    if (legal_action_count <= 1) {
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
    if (provider.time_budget_exhausted()) {
        output.fallback_requested = true;
        output.fallback_reason = "time_budget_exhausted";
        return output;
    }
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
    analyzer_.set_search_context(provider.search_context());
    auto root = provider.determinize(0, seed);
    if (!root) {
        output.fallback_requested = true;
        output.fallback_reason = "strategic_determinization_failed";
        return output;
    }
    // Dominance: unique legal action and a RulesSession-proven immediate win
    // need no heuristic search.
    const Value root_precondition = provider.cache_precondition(*root, actor);
    const auto unique_action_result = [&]() {
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
        });
        return output;
    };
    if (root_actions.as_array().size() == 1 && !config.full_diagnostics) return unique_action_result();

    const BeliefSummary belief = belief_tracker_.summarize(
        information, information.public_snapshot(), actor);
    const auto initial_evaluation = provider.evaluate([&] { return analyzer_.analyze(*root, belief, actor); });
    if (!initial_evaluation) {
        output.fallback_requested = true;
        output.fallback_reason = "time_budget_exhausted";
        return output;
    }
    const StrategicFacts initial = *initial_evaluation.value;
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
    if (root_actions.as_array().size() == 1) return unique_action_result();

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
        if (provider.terminal(*expanded.state)
            && integer_field(expanded.state->search_state(), "winner", -1) == actor
            && !expanded.trace.unpredictable) {
            const auto after_evaluation = provider.evaluate([&] {
                return analyzer_.analyze(*expanded.state, belief, actor);
            });
            if (!after_evaluation) break;
            const auto &after = *after_evaluation.value;
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
    if (provider.time_budget_exhausted()) {
        output.fallback_requested = true;
        output.fallback_reason = "time_budget_exhausted";
        return output;
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
    const bool resource_window = shadow_kind == "PLAY_TRAINER"
        || shadow_kind == "USE_ABILITY" || shadow_kind == "RETREAT";
    if (!config.anytime_search && !terminal_window && !reply_comparison_window
        && !turn_opening_window && !resource_window) {
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

    config.belief_samples = std::clamp<std::size_t>(config.belief_samples, 1, 3);
    config.node_budget = std::max<std::uint64_t>(1, config.node_budget);
    std::shared_ptr<RulesSession> shared_root(root.release());
    CompilationResult compiled;
    std::optional<PlanNode> anchor;
    // Import the initial policy's actual sampled terminal state. Legal guards
    // may replace its sequence, in which case replay is required instead.
    for (const auto &snapshot : provider.search_context()->initial_plans) {
        if (snapshot.seed != seed || !snapshot.state || !snapshot.ended) continue;
        PlanNode node;
        node.state = snapshot.state; node.root_action = snapshot.action;
        node.sequence = snapshot.sequence; node.preconditions = snapshot.preconditions;
        node.root_signature = snapshot.root_signature;
        for (const auto &action : node.sequence) {
            if (!node.sequence_signature.empty()) node.sequence_signature += '|';
            node.sequence_signature += challenge::value_action_signature(action);
        }
        node.depth = node.sequence.size(); node.ended = true;
        node.unpredictable = snapshot.unpredictable; node.cacheable = !snapshot.unpredictable;
        double priority = -std::numeric_limits<double>::infinity();
        for (const auto &intent : intents) {
            const auto value = intent_action_priority(intent, initial, match_plan,
                shared_root->search_state(), actor, node.root_action, semantics_, strategies_);
            if (value > priority) { priority = value; node.intent = intent.kind; }
        }
        const auto facts = provider.evaluate([&] { return analyzer_.analyze(*node.state, belief, actor); });
        if (!facts) break;
        node.facts = *facts.value; node.score = score_plan(initial, node.facts, node.intent, node.unpredictable);
        node.scenario_utility = node.worst_scenario_utility = plan_score_utility(node.score);
        if (snapshot.root_signature == legacy_signature && snapshot.sequence == config.legacy_sequence) anchor = node;
        compiled.prior_candidates.push_back(std::move(node));
        ++provider.search_context()->reused_initial_plans;
    }
    if (!anchor && !config.legacy_sequence.empty()) {
        anchor = evaluate_fixed_sequence(provider, provider.determinize(0, seed), config.legacy_sequence,
            initial, analyzer_, belief, actor, seed, IntentKind::EndTurnSafely, compiled.nodes_expanded);
    }
    std::optional<PlanNode> selected;
    ThreatScenarioComparison selected_comparison;
    std::string confidence_reason;
    // Candidate ordering uses the same completed own-turn horizon. The new
    // path spends its additional beliefs on paired reply + recovery directly,
    // avoiding a separate replay stage over another set of hidden samples.
    std::size_t scenario_samples = !config.anytime_search && output.deliberation == DeliberationLevel::D3
        ? config.belief_samples : 1;
    do {
        if (provider.search_stopped() || cancelled(cancel_requested)) break;
        advance_turn_plans(compiled, provider, shared_root, root_actions, actor, seed,
            initial, match_plan, intents, output.deliberation, semantics_, strategies_, analyzer_, belief,
            legacy_signature, config.node_budget, config.evaluation_smoke, config.anytime_search, cancel_requested);
        if (compiled.candidates.empty()) continue;
        if (!anchor || !anchor->ended) {
            // Mature the incumbent's root in the shared candidate tree. A
            // completed END_TURN from another root cannot defeat an unfinished
            // development line just by being the first complete candidate.
            const auto complete = std::find_if(compiled.candidates.begin(), compiled.candidates.end(),
                [&](const PlanNode &node) { return node.root_signature == legacy_signature && node.ended; });
            if (complete != compiled.candidates.end()) anchor = *complete;
        }
        evaluate_scenarios(compiled, provider, analyzer_, belief, initial, actor, seed,
            scenario_samples, initial.risk_mode, cancel_requested);
        const auto batch_anchor = anchor;
        std::optional<PlanNode> batch_best;
        ThreatScenarioComparison batch_comparison;
        const auto candidate_count = std::min<std::size_t>(3, compiled.candidates.size());
        for (std::size_t index = 0; index < candidate_count; ++index) {
            const auto &candidate = compiled.candidates[index];
            if (!candidate.ended) continue;
            const bool win = candidate.score.terminal_rank == 3 && !candidate.unpredictable;
            if (!win && (!batch_anchor || !batch_anchor->ended)) continue;
            if (!win && batch_anchor && candidate.sequence_signature == batch_anchor->sequence_signature) continue;
            ThreatScenarioComparison comparison;
            std::string reason = win ? "terminal_win" : "reply_scenario_plan_dominance";
            if (!win && batch_anchor && batch_anchor->ended) {
                if (provider.search_stopped()) break;
                comparison = compare_threat_scenarios(provider, candidate, *batch_anchor,
                    initial, analyzer_, belief, actor, seed,
                    initial.risk_mode == RiskMode::SeekUpside ? -30000 : 0, cancel_requested);
                compiled.nodes_expanded += comparison.nodes_expanded;
                if (!comparison.valid || comparison.mean_gain_milli < 30000) continue;
                if (batch_best && (comparison.minimum_gain_milli < batch_comparison.minimum_gain_milli
                    || (comparison.minimum_gain_milli == batch_comparison.minimum_gain_milli
                        && comparison.mean_gain_milli <= batch_comparison.mean_gain_milli))) continue;
                reason = deterministic_extension_of_legacy(candidate, *batch_anchor, semantics_)
                    ? "reply_scenario_dominance" : candidate.sequence.size() == 1 && batch_anchor->sequence.size() == 1
                    && string_field(candidate.root_action, "kind") == "DECLARE_ATTACK"
                    && string_field(batch_anchor->root_action, "kind") == "DECLARE_ATTACK"
                    ? "reply_scenario_attack_dominance" : "reply_scenario_plan_dominance";
            } else if (!win && batch_best) continue;
            // Validate each provisional improvement now. An interrupted later
            // competitor must not erase the last fully validated incumbent.
            DecisionPhaseScope validation_phase(provider.search_context()->budget.get(), DecisionPhase::Validation);
            auto validation_root = provider.determinize(0, seed);
            if (!validation_root) continue;
            const auto validation = safety_validator_.validate(candidate.sequence,
                batch_anchor ? batch_anchor->sequence : Value::Array{}, root_actions,
                *validation_root, actor, provider.branch_seed(seed, 991, candidate.root_signature,
                    candidate.sequence_signature, 0), provider, win);
            if (!validation.valid) continue;
            selected = candidate; selected_comparison = comparison; confidence_reason = reason;
            batch_best = candidate; batch_comparison = comparison;
            if (win) break;
        }
        if (batch_best) {
            anchor = *batch_best;
            provider.search_context()->set_incumbent(batch_best->root_action);
        }
        if (confidence_reason == "terminal_win") break;
    } while (config.anytime_search && !config.evaluation_smoke && provider.search_context()->budget
        && provider.search_context()->budget->timed() && !compiled.done && !provider.search_stopped());

    output.plan.nodes_expanded = compiled.nodes_expanded;
    output.plan.requested_depth = compiled.requested_depth;
    output.plan.completed_depth = compiled.completed_depth;
    output.plan.max_path_depth = compiled.max_path_depth;
    if (cancelled(cancel_requested)) { output.plan.cancelled = true; output.plan.error = "cancelled"; return output; }
    if (!selected) {
        output.fallback_requested = true;
        output.fallback_reason = provider.time_budget_exhausted() ? "time_budget_exhausted"
            : compiled.candidates.empty() ? "no_compilable_intent_plan" : "strategic_override_ambiguous";
        output.explanation = Value(Value::Object{{"fallback", Value(output.fallback_reason)},
            {"legacy_root", Value(legacy_signature)}, {"intents", intents_value(intents)},
            {"partial_order_pruned", Value(static_cast<std::int64_t>(compiled.partial_order_pruned))}});
        return output;
    }
    const auto &best = *selected;
    output.plan.success = true;
    output.plan.selected = best.root_action; output.plan.sequence = best.sequence;
    output.plan.cache_preconditions = best.preconditions;
    for (const auto &candidate : compiled.candidates) {
        output.plan.root_candidates.push_back(candidate.root_action);
        output.plan.root_signatures_attempted.push_back(candidate.root_signature);
        output.plan.root_sample_counts[candidate.root_signature] = candidate.scenario_count;
    }
    output.plan.root_sample_counts[best.root_signature] = best.scenario_count;
    output.plan.score_milli = utility_milli(best.scenario_utility);
    output.plan.worst_score_milli = utility_milli(best.worst_scenario_utility);
    output.plan.reply_completed_depth = selected_comparison.valid ? selected_comparison.reply_completed_depth : 0;
    output.plan.reply_depth_applicable = selected_comparison.valid;
    output.plan.completion_reason = provider.time_budget_exhausted() ? "budget_with_validated_plan" : "intent_compiled";
    output.plan.trajectory_hash = compiled.trajectory_hash; output.plan.trajectory_events = compiled.trajectory_events;
    output.plan.belief_samples = scenario_samples; output.plan.belief_consensus = best.scenario_count;
    output.plan.belief_seed_hash = provider.sha256_text("progressive|" + std::to_string(seed) + "|" + std::to_string(scenario_samples));
    output.plan.layers_completed = compiled.completed_depth;
    output.intent = best.intent; match_plan.current_intent = best.intent; match_plans_[key] = match_plan;
    output.match_plan = match_plan_value(match_plan); output.plan_score = plan_score_value(best.score);
    output.cacheable = best.cacheable && best.sequence.size() > 1;
    output.explanation = Value(Value::Object{{"confidence", Value(confidence_reason)},
        {"selected_intent", Value(intent_name(best.intent))}, {"selected_root", Value(best.root_signature)},
        {"legacy_root", Value(legacy_signature)}, {"root_changed", Value(best.root_signature != legacy_signature)},
        {"scenario_count", Value(static_cast<std::int64_t>(best.scenario_count))},
        {"reply_scenarios_valid", Value(selected_comparison.valid)},
        {"reply_scenario_samples", Value(static_cast<std::int64_t>(selected_comparison.samples))},
        {"reply_minimum_gain_milli", Value(selected_comparison.valid ? selected_comparison.minimum_gain_milli : 0)},
        {"reply_mean_gain_milli", Value(selected_comparison.mean_gain_milli)},
        {"partial_order_pruned", Value(static_cast<std::int64_t>(compiled.partial_order_pruned))},
        {"safety", Value("validated")}, {"cacheable", Value(output.cacheable)}, {"intents", intents_value(intents)}});
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
