#include "planner_v3/safety_validator.hpp"

#include "challenge_search_support.hpp"
#include "ptcg_traditional_value.hpp"

#include <algorithm>
#include <memory>

namespace ptcg::ai::planner_v3 {
namespace {

std::size_t prizes_remaining(const RulesSession &position, std::int32_t actor) {
    using namespace traditional_value;
    const Value *players = field(position.search_state(), "players");
    if (players == nullptr || !players->is_array() || actor < 0
        || static_cast<std::size_t>(actor) >= players->as_array().size()) {
        return 0;
    }
    return array_field(
        players->as_array()[static_cast<std::size_t>(actor)], "prizes").size();
}

std::size_t prize_gain(
    std::size_t before,
    const RulesSession &after,
    std::int32_t actor
) {
    const std::size_t remaining = prizes_remaining(after, actor);
    return before > remaining ? before - remaining : 0;
}

struct ReplayResult {
    bool valid = false;
    bool attacked = false;
    bool ended = false;
    bool terminal = false;
    std::int32_t winner = -1;
    std::size_t prizes = 0;
    std::string reason;
};

ReplayResult replay_sequence(
    const Value::Array &sequence,
    const Value &authoritative_actions,
    const RulesSession &position,
    std::int32_t actor,
    std::uint32_t seed,
    TraditionalSearchProvider &provider,
    bool require_turn_boundary
) {
    ReplayResult output;
    if (sequence.empty() || !authoritative_actions.is_array()) {
        output.reason = "empty_or_invalid_plan";
        return output;
    }
    auto branch = position.fork_for_search(seed);
    if (!branch) {
        output.reason = "rules_fork_failed";
        return output;
    }
    const std::size_t before = prizes_remaining(position, actor);
    for (std::size_t index = 0; index < sequence.size(); ++index) {
        const Value &planned = sequence[index];
        if (!planned.is_object()) {
            output.reason = "invalid_action_shape";
            return output;
        }
        const Value legal = index == 0
            ? authoritative_actions
            : branch->search_legal_action_candidates(actor);
        if (!legal.is_array()) {
            output.reason = "legal_actions_unavailable";
            return output;
        }
        const std::string signature = challenge::value_action_signature(planned);
        const Value *matched = challenge::find_action_by_signature(legal, signature);
        if (matched == nullptr) {
            output.reason = index == 0
                ? "action_no_longer_legal" : "plan_step_no_longer_legal";
            return output;
        }
        const std::string kind = traditional_value::string_field(
            *matched, "kind");
        output.attacked = output.attacked || kind == "DECLARE_ATTACK";
        const Value bound = provider.bind_action(
            *matched,
            *branch,
            actor,
            "strategic-intent-safety-" + std::to_string(index));
        const RulesSessionResult applied = branch->apply_action_for_search(bound);
        if (!applied.success) {
            output.reason = "rules_rejected_plan_step";
            return output;
        }
        std::uint64_t ignored_nodes = 0;
        TraditionalChoiceTrace trace;
        if (!provider.resolve_pending(*branch, actor, ignored_nodes, trace)) {
            output.reason = "predicted_choice_unresolved";
            return output;
        }
        const bool terminal = provider.terminal(*branch);
        const bool ended = terminal || provider.action_ends_turn(*matched)
            || provider.decision_actor(*branch) != actor;
        if (ended) {
            output.ended = true;
            if (index + 1 != sequence.size()) {
                output.reason = "plan_continues_after_turn_boundary";
                return output;
            }
            break;
        }
    }
    if (require_turn_boundary && !output.ended) {
        output.reason = "plan_does_not_reach_turn_boundary";
        return output;
    }
    output.prizes = prize_gain(before, *branch, actor);
    output.terminal = provider.terminal(*branch);
    output.winner = static_cast<std::int32_t>(traditional_value::integer_field(
        branch->search_state(), "winner", -1));
    output.valid = true;
    output.reason = "validated";
    return output;
}

} // namespace

ValidationResult SafetyValidator::validate(
    const Value::Array &sequence,
    const Value::Array &legacy_sequence,
    const Value &authoritative_actions,
    const RulesSession &position,
    std::int32_t actor,
    std::uint32_t seed,
    TraditionalSearchProvider &provider,
    bool require_terminal_win
) const {
    const ReplayResult selected = replay_sequence(
        sequence,
        authoritative_actions,
        position,
        actor,
        seed,
        provider,
        true);
    if (!selected.valid) return {false, selected.reason};
    if (require_terminal_win
        && (!selected.terminal || selected.winner != actor)) {
        return {false, "terminal_win_not_reproduced"};
    }
    if (require_terminal_win) {
        constexpr std::size_t terminal_scenario_samples = 9;
        for (std::size_t sample = 1; sample < terminal_scenario_samples; ++sample) {
            const std::uint32_t sample_seed = seed
                + static_cast<std::uint32_t>(sample * 1000003ULL);
            auto scenario = provider.determinize(sample, sample_seed);
            if (!scenario) return {false, "terminal_scenario_unavailable"};
            const Value &scenario_actions =
                scenario->search_legal_action_candidates(actor);
            const ReplayResult outcome = replay_sequence(
                sequence,
                scenario_actions,
                *scenario,
                actor,
                sample_seed,
                provider,
                true);
            if (!outcome.valid || !outcome.terminal || outcome.winner != actor) {
                return {false, "terminal_win_not_robust"};
            }
        }
    }

    if (!legacy_sequence.empty()) {
        const ReplayResult legacy = replay_sequence(
            legacy_sequence,
            authoritative_actions,
            position,
            actor,
            seed + 104729U,
            provider,
            false);
        if (!legacy.valid) return {false, "legacy_shadow_replay_failed"};
        if (legacy.attacked && !selected.attacked) {
            return {false, "sacrificed_legacy_attack"};
        }
        if (legacy.prizes > selected.prizes) {
            return {false, "missed_deterministic_prize"};
        }
        if (legacy.terminal && legacy.winner == actor
            && (!selected.terminal || selected.winner != actor)) {
            return {false, "sacrificed_legacy_win"};
        }
    }
    return {true, require_terminal_win
        ? "validated_terminal_scenarios" : "validated"};
}

} // namespace ptcg::ai::planner_v3
