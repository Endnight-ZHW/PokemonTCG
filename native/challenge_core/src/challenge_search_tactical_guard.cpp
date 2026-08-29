#include "challenge_search_provider_internal.hpp"


#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <functional>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <string>
#include <utility>
#include <vector>
namespace ptcg::ai::challenge_detail {

using namespace challenge;

    ptcg::ai::Value ChallengeSearchProviderImpl::post_plan_tactical_guard(
        const ptcg::ai::RulesSession &position,
        std::int32_t actor,
        const ptcg::ai::Value &preferred,
        const ptcg::ai::Value &actions,
        std::uint32_t seed,
        bool &changed
    ) {
        changed = false;
        if (!preferred.is_object() || !actions.is_array()) return preferred;
        const std::string preferred_signature = value_action_signature(preferred);
        const auto has_belief_sampling = [&](const ptcg::ai::Value &action) {
            if (string_field(action, "kind") != "DECLARE_ATTACK") return false;
            const ptcg::ai::Value *source = action.find("source");
            const ptcg::ai::Value *payload = action.find("payload");
            const std::string card_id = source != nullptr && source->is_object()
                ? string_field(*source, "card_id") : std::string{};
            const std::int64_t attack_index = payload != nullptr
                && payload->is_object()
                ? integer_field(*payload, "attack_index", -1) : -1;
            const ptcg::ai::Value *definition = cards_.find(card_id);
            const ptcg::ai::Value *attacks = definition != nullptr
                ? definition->find("attacks") : nullptr;
            if (attacks == nullptr || !attacks->is_array() || attack_index < 0
                || static_cast<std::size_t>(attack_index)
                    >= attacks->as_array().size()) return false;
            const ptcg::ai::Value *commands = attacks->as_array()[
                static_cast<std::size_t>(attack_index)].find("compiled_effects");
            std::function<bool(const ptcg::ai::Value &)> visit = [&visit](
                const ptcg::ai::Value &value
            ) {
                if (!value.is_array()) return false;
                for (const ptcg::ai::Value &command : value.as_array()) {
                    if (!command.is_object()) continue;
                    const std::string op = string_field(command, "op");
                    if (op.rfind("flip_coin", 0) == 0 || op == "flip_until_tails"
                        || op == "draw_and_attach_energy"
                        || op == "look_top_attach_energy"
                        || op == "look_top_deck" || op == "mill_then_damage"
                        || op == "trekking_shoes") return true;
                    const ptcg::ai::Value *branches = command.find("branches");
                    if (branches == nullptr || !branches->is_object()) continue;
                    for (const auto &[key, branch] : branches->as_object()) {
                        (void)key;
                        if (visit(branch)) return true;
                    }
                }
                return false;
            };
            return commands != nullptr && visit(*commands);
        };
        const auto simulate = [&](
            const ptcg::ai::Value &action,
            std::uint32_t action_seed,
            bool *immediate_loss,
            bool *made_progress,
            std::unique_ptr<ptcg::ai::RulesSession> *result_position = nullptr,
            bool count_simulated_score = false
        ) {
            if (count_simulated_score) ++simulated_action_score_calls_;
            auto simulation = position.fork_for_search(action_seed);
            if (!simulation) return false;
            const ptcg::ai::Value bound = bind_action(
                action, *simulation, actor,
                "tactical_guard_" + std::to_string(action_seed));
            const ptcg::ai::RulesSessionResult step = simulation->apply_action(bound);
            if (!step.success) return false;
            std::uint64_t ignored_nodes = 0;
            ptcg::ai::TraditionalChoiceTrace trace;
            if (!resolve_pending(*simulation, actor, ignored_nodes, trace)) return false;
            if (immediate_loss != nullptr) {
                const ptcg::ai::Value &state = simulation->search_state();
                *immediate_loss = !has_belief_sampling(action)
                    && (string_field(state, "result_status", "ONGOING") != "ONGOING"
                        || string_field(state, "phase") == "GAME_OVER")
                    && integer_field(state, "winner", -1) == 1 - actor;
            }
            if (made_progress != nullptr) {
                *made_progress = state_fingerprint(*simulation)
                    != state_fingerprint(position);
            }
            if (result_position != nullptr) *result_position = std::move(simulation);
            return true;
        };
        const auto first_choice_cancelled = [&] (
            const ptcg::ai::Value &action,
            std::uint32_t action_seed
        ) {
            auto simulation = position.fork_for_search(action_seed);
            if (!simulation) return false;
            const ptcg::ai::Value bound = bind_action(
                action, *simulation, actor,
                "tactical_first_choice_" + std::to_string(action_seed));
            const ptcg::ai::RulesSessionResult step = simulation->apply_action(bound);
            if (!step.success) return false;
            const ptcg::ai::Value &pending = simulation->search_pending_choice(actor);
            const ptcg::ai::typed::ChoiceView *typed_pending =
                simulation->typed_search_pending_choice(actor);
            if (pending.is_null() || typed_pending == nullptr
                || typed_pending->player != actor) return false;
            ptcg::ai::Value response;
            if (!(arven_choice_response(
                    *simulation, pending, *typed_pending, response)
                || confirm_choice_response(
                    *simulation, pending, *typed_pending, response)
                || duplicate_energy_choice_response(
                    *simulation, pending, *typed_pending, response)
                || single_choice_response(
                    *simulation, pending, *typed_pending, response)
                || forced_choice_response(
                    simulation->search_state(), pending, *typed_pending, response))) {
                return false;
            }
            return bool_field(response, "cancelled");
        };
        const auto should_avoid_repeating_ability = [&] (
            const ptcg::ai::Value &action
        ) {
            if (string_field(action, "kind") != "USE_ABILITY") return false;
            const ptcg::ai::Value *payload = action.find("payload");
            const std::string ability_name = payload != nullptr
                && payload->is_object()
                ? string_field(*payload, "ability_name") : std::string{};
            return !ability_name.empty()
                && value_ability_is_repeatable(
                    position.search_state(), actor, action, ability_name, cards_)
                && repeatable_ability_uses_this_turn(
                    position.search_state(), actor, action, ability_name, cards_) > 0;
        };
        const auto is_major_hand_refresh = [&] (
            const ptcg::ai::Value &action
        ) {
            if (string_field(action, "kind") != "PLAY_TRAINER") return false;
            const ptcg::ai::Value *source = action.find("source");
            const ptcg::ai::Value *definition = source != nullptr
                && source->is_object()
                ? cards_.find(string_field(*source, "card_id")) : nullptr;
            const ptcg::ai::Value *effects = definition != nullptr
                ? definition->find("trainer_effects") : nullptr;
            static const std::set<std::string> refresh_types{
                "discard_draw", "shuffle_draw", "judge",
                "hand_to_bottom_draw", "discard_then_draw",
            };
            std::function<bool(const ptcg::ai::Value &)> visit = [&visit](
                const ptcg::ai::Value &rows
            ) {
                if (!rows.is_array()) return false;
                for (const ptcg::ai::Value &effect : rows.as_array()) {
                    if (!effect.is_object()) continue;
                    if (refresh_types.count(string_field(
                        effect, "effect_type")) != 0) return true;
                    const ptcg::ai::Value *params = effect.find("params");
                    if (params == nullptr || !params->is_object()) continue;
                    for (const char *key : {
                        "on_heads", "on_tails", "on_success",
                        "on_fail", "on_pay", "cost",
                    }) {
                        const ptcg::ai::Value *branch = params->find(key);
                        if (branch == nullptr) continue;
                        if (branch->is_array() && visit(*branch)) return true;
                        if (branch->is_object()) {
                            ptcg::ai::Value wrapper = ptcg::ai::Value(
                                ptcg::ai::Value::Array{*branch});
                            if (visit(wrapper)) return true;
                        }
                    }
                }
                return false;
            };
            return effects != nullptr && visit(*effects);
        };
        const auto ranked = ranked_actions(
            position, actor, actions, actions.as_array().size());
        const auto canonical_score = [&](const ptcg::ai::Value &action) {
            const std::string signature = value_action_signature(action);
            const auto found = std::find_if(
                ranked.begin(), ranked.end(), [&signature](const auto &row) {
                    return row.signature == signature;
                });
            return found == ranked.end() ? std::int64_t{0} : found->score_milli;
        };
        const auto best_productive_excluding = [&] (
            const ptcg::ai::Value *excluded,
            const ptcg::ai::Value *additional_excluded,
            std::uint32_t candidate_seed
        ) {
            static const std::set<std::string> productive{
                "ATTACH_ENERGY", "EVOLVE", "USE_ABILITY", "PLAY_TRAINER",
                "PLAY_BASIC", "USE_STADIUM",
            };
            const double base_score = trusted_evaluator_.raw_evaluation(
                position, actor);
            const std::string excluded_kind = excluded == nullptr
                ? std::string{} : string_field(*excluded, "kind");
            const ptcg::ai::Value *best = nullptr;
            double best_value = -std::numeric_limits<double>::infinity();
            for (std::size_t index = 0; index < actions.as_array().size(); ++index) {
                const ptcg::ai::Value &action = actions.as_array()[index];
                if (excluded != nullptr
                    && value_action_signature(action)
                        == value_action_signature(*excluded)) continue;
                if (additional_excluded != nullptr
                    && value_action_signature(action)
                        == value_action_signature(*additional_excluded)) continue;
                const std::string action_kind = string_field(action, "kind");
                if (productive.count(action_kind) == 0) continue;
                if (should_avoid_repeating_ability(action)) continue;
                if (action_kind == "PLAY_TRAINER"
                    && first_choice_cancelled(
                        action,
                        candidate_seed
                            + static_cast<std::uint32_t>(index * 3917U))) {
                    continue;
                }
                const std::optional<double> development =
                    trusted_evaluator_.development_action_value(
                        position, actor, action);
                if (!development.has_value() || *development <= 0.0) continue;
                bool progress = false;
                std::unique_ptr<ptcg::ai::RulesSession> simulation;
                if (simulate(
                    action,
                    candidate_seed + static_cast<std::uint32_t>(index * 7919U),
                    nullptr,
                    &progress,
                    &simulation,
                    true
                ) && progress && simulation) {
                    const double delta = trusted_evaluator_.raw_evaluation(
                        *simulation, actor) - base_score;
                    double value = *development + delta * 0.45
                        + static_cast<double>(canonical_score(action))
                            / 1000.0 * 0.04;
                    if (action_kind == "PLAY_BASIC") {
                        const ptcg::ai::Value &owner = value_player(
                            position.search_state(), actor);
                        const ptcg::ai::Value *bench = owner.find("bench");
                        const std::size_t count = bench != nullptr && bench->is_array()
                            ? static_cast<std::size_t>(std::count_if(
                                bench->as_array().begin(), bench->as_array().end(),
                                [](const ptcg::ai::Value &row) {
                                    return row.is_object();
                                })) : 0;
                        if (count < 2) value += 45.0;
                    }
                    if (action_kind == "EVOLVE") value += 35.0;
                    else if (action_kind == "ATTACH_ENERGY") value += 30.0;
                    const bool semantic_pre_attack = excluded_kind == "DECLARE_ATTACK"
                        && *development >= 55.0 && delta >= -20.0;
                    if (value < 80.0 && delta < 8.0 && !semantic_pre_attack) continue;
                    if (value > best_value) {
                        best = &action;
                        best_value = value;
                    }
                }
            }
            return best == nullptr ? ptcg::ai::Value() : *best;
        };
        const auto best_productive = [&] (
            const ptcg::ai::Value *excluded,
            std::uint32_t candidate_seed
        ) {
            return best_productive_excluding(
                excluded, nullptr, candidate_seed);
        };
        const auto best_productive_attack = [&] (
            const ptcg::ai::Value *excluded,
            std::uint32_t candidate_seed
        ) {
            const ptcg::ai::Value *best = nullptr;
            double best_value = -std::numeric_limits<double>::infinity();
            std::string best_signature;
            for (const ptcg::ai::Value &action : actions.as_array()) {
                if (string_field(action, "kind") != "DECLARE_ATTACK") continue;
                const std::string signature = value_action_signature(action);
                if (excluded != nullptr
                    && signature == value_action_signature(*excluded)) continue;
                if (trusted_evaluator_.attack_tactically_unsafe(
                    position, actor, action)) continue;
                bool loses = false;
                if (!simulate(
                    action, candidate_seed + 104729U, &loses, nullptr)
                    || loses) continue;
                const std::optional<double> base =
                    trusted_evaluator_.productive_attack_value(
                        position, actor, action);
                if (!base.has_value()) continue;
                const double value = *base
                    + static_cast<double>(canonical_score(action))
                        / 1000.0 * 0.05;
                if (value <= 0.0) continue;
                const bool better = best == nullptr || value > best_value
                    || (std::abs(value - best_value) <= 0.000001
                        && signature < best_signature);
                if (better) {
                    // Match the fixed profile counter for the successful
                    // _action_executes_successfully() probe performed only for
                    // a candidate that becomes the deterministic best.
                    ++simulated_action_score_calls_;
                    best = &action;
                    best_value = value;
                    best_signature = signature;
                }
            }
            return best == nullptr ? ptcg::ai::Value() : *best;
        };
        const auto best_damaging_attack = [&] (std::uint32_t candidate_seed) {
            const double base_score = trusted_evaluator_.raw_evaluation(
                position, actor);
            const ptcg::ai::Value *best = nullptr;
            double best_value = -std::numeric_limits<double>::infinity();
            for (const ptcg::ai::Value &action : actions.as_array()) {
                if (string_field(action, "kind") != "DECLARE_ATTACK"
                    || trusted_evaluator_.attack_tactically_unsafe(
                        position, actor, action)) continue;
                bool loses = false;
                if (!simulate(
                    action, candidate_seed + 130363U, &loses, nullptr)
                    || loses) continue;
                const ptcg::ai::Value *payload = action.find("payload");
                const std::int64_t attack_index = payload != nullptr
                    && payload->is_object()
                    ? integer_field(*payload, "attack_index", 0) : 0;
                const std::int64_t damage =
                    trusted_evaluator_.action_estimated_damage(
                        position, actor, action);
                const std::optional<double> productive =
                    trusted_evaluator_.productive_attack_value(
                        position, actor, action);
                if (!productive.has_value()) continue;
                const double effect_value = *productive
                    - static_cast<double>(damage) * 1.2;
                if (damage <= 0 && effect_value <= 0.0) continue;
                std::unique_ptr<ptcg::ai::RulesSession> simulation;
                if (!simulate(
                    action,
                    candidate_seed + static_cast<std::uint32_t>(
                        std::max<std::int64_t>(0, attack_index) * 9973),
                    nullptr,
                    nullptr,
                    &simulation,
                    true
                ) || !simulation) continue;
                const double value = trusted_evaluator_.raw_evaluation(
                        *simulation, actor) - base_score
                    + static_cast<double>(damage) * 0.55
                    + effect_value * 0.35;
                if (best == nullptr || value > best_value) {
                    best = &action;
                    best_value = value;
                }
            }
            return best == nullptr ? ptcg::ai::Value() : *best;
        };
        const auto find_action = [&] (const std::string &wanted_kind) {
            const auto found = std::find_if(
                actions.as_array().begin(), actions.as_array().end(),
                [&wanted_kind](const ptcg::ai::Value &action) {
                    return string_field(action, "kind") == wanted_kind;
                });
            return found == actions.as_array().end()
                ? ptcg::ai::Value() : *found;
        };
        const auto best_immediate_loss_escape = [&] (
            std::uint32_t candidate_seed
        ) {
            const ptcg::ai::Value *best = nullptr;
            double best_value = -std::numeric_limits<double>::infinity();
            std::string best_signature;
            for (std::size_t index = 0; index < actions.as_array().size(); ++index) {
                const ptcg::ai::Value &candidate = actions.as_array()[index];
                const std::string candidate_kind = string_field(candidate, "kind");
                if (candidate_kind == "DECLARE_ATTACK"
                    || candidate_kind == "END_TURN") continue;
                std::unique_ptr<ptcg::ai::RulesSession> simulation;
                if (!simulate(
                    candidate,
                    candidate_seed + static_cast<std::uint32_t>(index * 7919U),
                    nullptr, nullptr, &simulation, true
                ) || !simulation) continue;
                const std::optional<double> development =
                    trusted_evaluator_.development_action_value(
                        position, actor, candidate);
                double value = trusted_evaluator_.raw_evaluation(
                    *simulation, actor) + development.value_or(0.0);
                if (candidate_kind == "EVOLVE") value += 80.0;
                else if (candidate_kind == "RETREAT") value += 60.0;
                else if (candidate_kind == "PLAY_BASIC") value += 40.0;
                const std::string signature = value_action_signature(candidate);
                if (best == nullptr || value > best_value
                    || (std::abs(value - best_value) <= 0.000001
                        && signature < best_signature)) {
                    best = &candidate;
                    best_value = value;
                    best_signature = signature;
                }
            }
            if (best != nullptr) return *best;
            const ptcg::ai::Value end_turn = find_action("END_TURN");
            if (!end_turn.is_null() && simulate(
                end_turn, candidate_seed + 100003U,
                nullptr, nullptr, nullptr, true)) {
                return end_turn;
            }
            return ptcg::ai::Value();
        };
        const auto best_pre_attack_development = [&] (
            const ptcg::ai::Value &attack,
            const ptcg::ai::Value *additional_excluded,
            std::uint32_t candidate_seed
        ) {
            if (string_field(attack, "kind") != "DECLARE_ATTACK") {
                return ptcg::ai::Value();
            }
            const std::int64_t damage =
                trusted_evaluator_.action_estimated_damage(
                    position, actor, attack);
            const ptcg::ai::Value *opponent_active = value_pokemon_at(
                position.search_state(), 1 - actor, "active");
            if (opponent_active != nullptr
                && damage >= position.pokemon_current_hp(*opponent_active)) {
                return ptcg::ai::Value();
            }
            const std::string attack_signature = value_action_signature(attack);
            const std::string additional_signature = additional_excluded == nullptr
                ? std::string{} : value_action_signature(*additional_excluded);
            const ptcg::ai::Value &owner = value_player(
                position.search_state(), actor);
            const ptcg::ai::Value *bench = owner.find("bench");
            const std::size_t bench_size = bench != nullptr && bench->is_array()
                ? static_cast<std::size_t>(std::count_if(
                    bench->as_array().begin(), bench->as_array().end(),
                    [](const ptcg::ai::Value &row) { return row.is_object(); }))
                : 0;
            const ptcg::ai::Value *best = nullptr;
            double best_value = -std::numeric_limits<double>::infinity();
            for (std::size_t index = 0; index < actions.as_array().size(); ++index) {
                const ptcg::ai::Value &candidate = actions.as_array()[index];
                const std::string signature = value_action_signature(candidate);
                if (signature == attack_signature
                    || (!additional_signature.empty()
                        && signature == additional_signature)) continue;
                const std::string candidate_kind = string_field(candidate, "kind");
                const ptcg::ai::Value *source = candidate.find("source");
                const ptcg::ai::Value *target = candidate.find("target");
                const std::string card_id = source != nullptr && source->is_object()
                    ? string_field(*source, "card_id") : std::string{};
                const std::string target_slot = target != nullptr
                    && target->is_object()
                    ? string_field(*target, "slot") : std::string{};
                if (candidate_kind == "PLAY_BASIC") {
                    if (target_slot.rfind("bench_", 0) != 0 || bench_size >= 4
                        || !(trusted_evaluator_.deck_profile_contains(
                                position, actor, "setup", card_id)
                            || trusted_evaluator_.deck_profile_contains(
                                position, actor, "bench", card_id)
                            || trusted_evaluator_.deck_profile_contains(
                                position, actor, "core", card_id))) {
                        continue;
                    }
                } else if (candidate_kind == "EVOLVE") {
                    if (target_slot.rfind("bench_", 0) != 0) continue;
                    const ptcg::ai::Value *definition = cards_.find(card_id);
                    bool on_enter = false;
                    const ptcg::ai::Value *abilities = definition != nullptr
                        ? definition->find("abilities") : nullptr;
                    if (abilities != nullptr && abilities->is_array()) {
                        on_enter = std::any_of(
                            abilities->as_array().begin(),
                            abilities->as_array().end(),
                            [](const ptcg::ai::Value &ability) {
                                return string_field(ability, "trigger")
                                    == "on_enter_play";
                            });
                    }
                    if (on_enter) continue;
                } else {
                    continue;
                }
                std::unique_ptr<ptcg::ai::RulesSession> simulation;
                if (!simulate(
                    candidate,
                    candidate_seed + 500009U
                        + static_cast<std::uint32_t>(index * 7919U),
                    nullptr, nullptr, &simulation
                ) || !simulation) continue;
                const ptcg::ai::Value &followup =
                    simulation->search_legal_action_candidates(actor);
                if (!followup.is_array() || std::none_of(
                    followup.as_array().begin(), followup.as_array().end(),
                    [&](const ptcg::ai::Value &action) {
                        return value_action_signature(action) == attack_signature;
                    })) continue;
                const std::optional<double> development =
                    trusted_evaluator_.development_action_value(
                        position, actor, candidate);
                const std::optional<double> action_score =
                    trusted_evaluator_.action_score(position, actor, candidate);
                if (!development.has_value() || !action_score.has_value()) continue;
                double value = *development + *action_score * 0.08;
                if (candidate_kind == "EVOLVE") value += 35.0;
                if (value > best_value) {
                    best = &candidate;
                    best_value = value;
                }
            }
            if (best != nullptr) return *best;
            const bool weak = damage < 80
                || (opponent_active != nullptr
                    && static_cast<double>(damage)
                        < static_cast<double>(position.pokemon_current_hp(
                            *opponent_active)) * 0.45);
            const std::int64_t active_missing =
                trusted_evaluator_.active_missing_energy(position, actor);
            if (!weak && active_missing <= 0) return ptcg::ai::Value();
            return best_productive_excluding(
                &attack, additional_excluded, candidate_seed);
        };
        const auto validate_replacement_attack = [&] (
            const ptcg::ai::Value &replacement,
            const ptcg::ai::Value &rejected,
            std::uint32_t candidate_seed
        ) {
            if (replacement.is_null()
                || string_field(replacement, "kind") != "DECLARE_ATTACK") {
                return replacement;
            }
            const ptcg::ai::Value development = best_pre_attack_development(
                replacement, &rejected, candidate_seed);
            return development.is_null() ? replacement : development;
        };
        const std::string kind = string_field(preferred, "kind");
        if (kind == "DECLARE_ATTACK") {
            bool loses = false;
            if (simulate(preferred, seed + 3U, &loses, nullptr) && loses) {
                const ptcg::ai::Value safe_attack = best_productive_attack(
                    &preferred, seed + 4U);
                if (!safe_attack.is_null()) {
                    changed = true;
                    return validate_replacement_attack(
                        safe_attack, preferred, seed + 400U);
                }
                const ptcg::ai::Value escape = best_immediate_loss_escape(
                    seed + 5U);
                if (!escape.is_null()) {
                    changed = true;
                    return escape;
                }
            }
            if (trusted_evaluator_.attack_tactically_unsafe(
                position, actor, preferred)) {
                const ptcg::ai::Value safe_attack = best_productive_attack(
                    nullptr, seed + 11U);
                if (!safe_attack.is_null()) {
                    changed = true;
                    return validate_replacement_attack(
                        safe_attack, preferred, seed + 1100U);
                }
                const ptcg::ai::Value development = best_productive(
                    &preferred, seed + 12U);
                if (!development.is_null()) {
                    changed = true;
                    return development;
                }
                const ptcg::ai::Value end_turn = find_action("END_TURN");
                if (!end_turn.is_null()
                    && simulate(
                        end_turn, seed + 13U,
                        nullptr, nullptr, nullptr, true)) {
                    changed = true;
                    return end_turn;
                }
            }
            const ptcg::ai::Value pre_attack = best_pre_attack_development(
                preferred, nullptr, seed + 17U);
            if (!pre_attack.is_null()) {
                changed = true;
                return pre_attack;
            }
        }
        if (should_avoid_repeating_ability(preferred)) {
            const ptcg::ai::Value follow_up_attack = best_productive_attack(
                nullptr, seed + 14U);
            if (!follow_up_attack.is_null()) {
                changed = true;
                return validate_replacement_attack(
                    follow_up_attack, preferred, seed + 1400U);
            }
            const ptcg::ai::Value follow_up_development = best_productive(
                &preferred, seed + 15U);
            if (!follow_up_development.is_null()) {
                changed = true;
                return follow_up_development;
            }
            const ptcg::ai::Value follow_up_end = find_action("END_TURN");
            if (!follow_up_end.is_null()) {
                changed = true;
                return follow_up_end;
            }
        }
        if (kind == "RETREAT"
            && !trusted_evaluator_.retreat_action_has_good_target(
                position, actor, preferred)) {
            const ptcg::ai::Value retained_attack = best_productive_attack(
                nullptr, seed + 18U);
            if (!retained_attack.is_null()) {
                changed = true;
                return validate_replacement_attack(
                    retained_attack, preferred, seed + 1800U);
            }
            const ptcg::ai::Value safe_development = best_productive(
                &preferred, seed + 19U);
            if (!safe_development.is_null()) {
                changed = true;
                return safe_development;
            }
            const ptcg::ai::Value safe_end = find_action("END_TURN");
            if (!safe_end.is_null()
                && simulate(
                    safe_end, seed + 20U,
                    nullptr, nullptr, nullptr, true)) {
                changed = true;
                return safe_end;
            }
        }
        if (kind == "END_TURN" || kind == "RETREAT") {
            const ptcg::ai::Value development = best_productive(
                &preferred, seed + 19U);
            if (!development.is_null()) {
                changed = true;
                return development;
            }
            if (kind == "END_TURN") {
                const ptcg::ai::Value productive_attack = best_productive_attack(
                    nullptr, seed + 29U);
                if (!productive_attack.is_null()) {
                    changed = true;
                    return validate_replacement_attack(
                        productive_attack, preferred, seed + 3900U);
                }
                const ptcg::ai::Value damaging_attack = best_damaging_attack(
                    seed + 31U);
                if (!damaging_attack.is_null()) {
                    changed = true;
                    return validate_replacement_attack(
                        damaging_attack, preferred, seed + 4100U);
                }
            }
        }
        if (is_major_hand_refresh(preferred)) {
            // The frozen GDScript planner returns a freshly generated
            // authoritative GameAction, while the guard receives the original
            // request action array. Its reference-identity exclusion therefore
            // does not remove the semantically identical refresh action. Keep
            // that observable behavior at the native boundary: the refresh may
            // rank itself first, in which case the guard is a no-op.
            const ptcg::ai::Value before_refresh = best_productive(
                nullptr, seed + 23U);
            if (!before_refresh.is_null()) {
                if (value_action_signature(before_refresh)
                    != preferred_signature) {
                    changed = true;
                    return before_refresh;
                }
                // GDScript returns the selected refresh immediately even when
                // it is only semantically (not referentially) the same action.
                // Do not fall through to a second profiled execution probe.
                return preferred;
            }
        }
        if (kind == "PLAY_TRAINER"
            && first_choice_cancelled(preferred, seed + 24U)) {
            const ptcg::ai::Value cancelled_attack = best_productive_attack(
                nullptr, seed + 25U);
            if (!cancelled_attack.is_null()) {
                changed = true;
                return validate_replacement_attack(
                    cancelled_attack, preferred, seed + 2500U);
            }
            const ptcg::ai::Value cancelled_damage = best_damaging_attack(
                seed + 26U);
            if (!cancelled_damage.is_null()) {
                changed = true;
                return validate_replacement_attack(
                    cancelled_damage, preferred, seed + 2600U);
            }
            const ptcg::ai::Value cancelled_development = best_productive(
                &preferred, seed + 27U);
            if (!cancelled_development.is_null()) {
                changed = true;
                return cancelled_development;
            }
            const ptcg::ai::Value cancelled_end = find_action("END_TURN");
            if (!cancelled_end.is_null()
                && simulate(
                    cancelled_end, seed + 28U,
                    nullptr, nullptr, nullptr, true)) {
                changed = true;
                return cancelled_end;
            }
        }
        const std::optional<double> preferred_development =
            trusted_evaluator_.development_action_value(
                position, actor, preferred);
        if (
            (kind == "PLAY_TRAINER" || kind == "USE_ABILITY"
                || kind == "USE_STADIUM")
            && preferred_development.has_value()
            && *preferred_development <= 0.0
        ) {
            const ptcg::ai::Value active_attack = best_productive_attack(
                nullptr, seed + 25U);
            if (!active_attack.is_null()) {
                changed = true;
                return validate_replacement_attack(
                    active_attack, preferred, seed + 3500U);
            }
            const ptcg::ai::Value active_damage = best_damaging_attack(
                seed + 26U);
            if (!active_damage.is_null()) {
                changed = true;
                return validate_replacement_attack(
                    active_damage, preferred, seed + 3600U);
            }
            const ptcg::ai::Value development = best_productive(
                &preferred, seed + 27U);
            if (!development.is_null()) {
                changed = true;
                return development;
            }
            const ptcg::ai::Value active_end = find_action("END_TURN");
            if (!active_end.is_null()
                && simulate(
                    active_end, seed + 28U,
                    nullptr, nullptr, nullptr, true)) {
                changed = true;
                return active_end;
            }
        }
        if (simulate(
            preferred, seed + 33U,
            nullptr, nullptr, nullptr, true
        )) return preferred;
        for (const auto &row : ranked) {
            if (row.signature == preferred_signature) continue;
            if (simulate(
                row.action, seed + 39U,
                nullptr, nullptr, nullptr, true)) {
                changed = true;
                return validate_replacement_attack(
                    row.action, preferred, seed + 4900U);
            }
        }
        return preferred;
    }


} // namespace ptcg::ai::challenge_detail
