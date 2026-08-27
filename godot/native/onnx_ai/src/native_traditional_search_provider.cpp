#include "native_traditional_search_provider.hpp"

#include "native_traditional_support.hpp"
#include "ptcg_godot_value.hpp"
#include "ptcg_traditional_evaluator.hpp"
#include "ptcg_traditional_mandatory.hpp"
#include "ptcg_traditional_policy.hpp"
#include "ptcg_traditional_strategy.hpp"
#include "ptcg_traditional_trusted.hpp"

#include <godot_cpp/classes/json.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

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

namespace godot {

namespace {

using namespace native_traditional;

class NativeTraditionalSearchProviderImpl final
    : public NativeTraditionalSearchProvider {
public:
    NativeTraditionalSearchProviderImpl(
        Callable provider,
        ptcg::ai::Value catalog,
        ptcg::ai::Value decks,
        ptcg::ai::Value strategies,
        std::int32_t root_actor,
        const ptcg::ai::TraditionalInformationSet *information_set = nullptr,
        bool debug_trajectory = false,
        bool strict_native_choices = false
    ) : provider_(std::move(provider)), catalog_(std::move(catalog)),
        decks_(std::move(decks)), evaluator_(catalog_),
        strategy_catalog_(std::move(strategies), catalog_),
        trusted_evaluator_(catalog_, decks_),
        information_set_(information_set), root_actor_(root_actor),
        debug_trajectory_(debug_trajectory),
        strict_native_choices_(strict_native_choices) {
        const ptcg::ai::Value *cards = catalog_.find("cards");
        cards_ = cards != nullptr && cards->is_object() ? *cards : catalog_;
        if (provider_.is_valid()) {
            const Variant capabilities_value = provider_.call(
                "capabilities", Dictionary());
            ++provider_callbacks_;
            if (capabilities_value.get_type() == Variant::DICTIONARY) {
                const Dictionary capabilities = capabilities_value;
                trusted_leaf_enabled_ = bool(capabilities.get(
                    "trusted_leaf", false));
                trusted_action_enabled_ = bool(capabilities.get(
                    "trusted_action", false));
            }
        } else {
            trusted_leaf_enabled_ = true;
            trusted_action_enabled_ = true;
        }
    }

    bool trusted_leaf_enabled() const noexcept {
        return trusted_leaf_enabled_;
    }
    const std::vector<std::string> &debug_trajectory_events() const noexcept {
        return debug_trajectory_events_;
    }
    const Dictionary &first_rank_mismatch() const noexcept {
        return first_rank_mismatch_;
    }
    const Dictionary &first_state_score_mismatch() const noexcept {
        return first_state_score_mismatch_;
    }

    const Dictionary &first_choice_mismatch() const noexcept {
        return first_choice_mismatch_;
    }
    const Dictionary &debug_actions_by_signature() const noexcept {
        return debug_actions_by_signature_;
    }
    Dictionary debug_states_by_fingerprint() const {
        Dictionary states;
        std::lock_guard<std::mutex> lock(debug_state_mutex_);
        for (const auto &[fingerprint, state] : debug_states_by_fingerprint_) {
            states[String::utf8(fingerprint.c_str())] =
                ptcg::ai::value_to_godot(state);
        }
        return states;
    }
    Dictionary performance_counters() const {
        Dictionary counters;
        counters["determinizations"] = static_cast<int64_t>(
            determinizations_.load(std::memory_order_relaxed));
        counters["ranked_action_queries"] = static_cast<int64_t>(
            ranked_queries_.load(std::memory_order_relaxed));
        counters["state_score_queries"] = static_cast<int64_t>(
            state_score_queries_.load(std::memory_order_relaxed));
        counters["choice_resolutions"] = static_cast<int64_t>(
            choice_resolutions_.load(std::memory_order_relaxed));
        counters["native_forced_choice_resolutions"] = static_cast<int64_t>(
            native_forced_choice_resolutions_.load(std::memory_order_relaxed));
        counters["native_choice_resolutions"] = static_cast<int64_t>(
            native_choice_resolutions_.load(std::memory_order_relaxed));
        counters["provider_callbacks"] = static_cast<int64_t>(
            provider_callbacks_.load(std::memory_order_relaxed));
        counters["action_score_callbacks"] = static_cast<int64_t>(
            action_score_callbacks_.load(std::memory_order_relaxed));
        counters["native_trusted_action_scores"] = static_cast<int64_t>(
            native_trusted_action_scores_.load(std::memory_order_relaxed));
        counters["oracle_trusted_action_scores"] = static_cast<int64_t>(
            oracle_trusted_action_scores_.load(std::memory_order_relaxed));
        counters["choice_callbacks"] = static_cast<int64_t>(
            choice_callbacks_.load(std::memory_order_relaxed));
        counters["simulated_action_score_calls"] = static_cast<int64_t>(
            simulated_action_score_calls_.load(std::memory_order_relaxed));
        return counters;
    }

    bool select_external_choice(
        const ptcg::ai::RulesSession &position,
        const ptcg::ai::Value &pending,
        ptcg::ai::Value &response
    ) {
        const auto strings = std::make_shared<
            ptcg::ai::typed::CardStringTable>(cards_);
        const ptcg::ai::typed::StateCodec codec(strings);
        ptcg::ai::typed::ChoiceView typed_pending;
        std::string error;
        if (!codec.decode_choice_view(pending, typed_pending, &error)) return false;
        ++choice_resolutions_;
        if (forced_choice_response(
            position.search_state(), pending, typed_pending, response)) {
            ++native_forced_choice_resolutions_;
            return true;
        }
        if (confirm_choice_response(position, pending, typed_pending, response)
            || arven_choice_response(position, pending, typed_pending, response)
            || duplicate_energy_choice_response(
                position, pending, typed_pending, response)
            || single_choice_response(position, pending, typed_pending, response)) {
            ++native_choice_resolutions_;
            return true;
        }
        return false;
    }

    ptcg::ai::Value post_plan_tactical_guard(
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
            if (!(forced_choice_response(
                    simulation->search_state(), pending, *typed_pending, response)
                || confirm_choice_response(
                    *simulation, pending, *typed_pending, response)
                || arven_choice_response(
                    *simulation, pending, *typed_pending, response)
                || duplicate_energy_choice_response(
                    *simulation, pending, *typed_pending, response)
                || single_choice_response(
                    *simulation, pending, *typed_pending, response))) {
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

    std::unique_ptr<ptcg::ai::RulesSession> determinize(
        std::size_t sample_index,
        std::uint32_t seed
    ) override {
        ++determinizations_;
        if (information_set_ != nullptr && information_set_->valid()) {
            ptcg::ai::Value snapshot = information_set_->sample_state(seed);
            if (!snapshot.is_object()) return {};
            auto session = std::make_unique<ptcg::ai::RulesSession>(catalog_);
            std::string error;
            if (!session->restore(snapshot, seed, &error)) return {};
            return session;
        }
        Dictionary payload;
        payload["sample_index"] = static_cast<int64_t>(sample_index);
        payload["seed"] = static_cast<int64_t>(seed);
        const Dictionary response = call_dictionary("determinize", payload);
        const Variant snapshot_value = response.get("snapshot", Variant());
        if (
            !bool(response.get("success", false))
            || snapshot_value.get_type() != Variant::DICTIONARY
        ) {
            return {};
        }
        auto session = std::make_unique<ptcg::ai::RulesSession>(catalog_);
        std::string error;
        if (!session->restore(
            ptcg::ai::value_from_godot(snapshot_value),
            static_cast<std::uint32_t>(int64_t(response.get("rng_state", seed))),
            &error
        )) {
            return {};
        }
        return session;
    }

    std::vector<ptcg::ai::TraditionalRankedAction> ranked_actions(
        const ptcg::ai::RulesSession &position,
        std::int32_t actor,
        const ptcg::ai::Value &supplied_actions,
        std::size_t limit
    ) override {
        ++ranked_queries_;
        const ptcg::ai::Value &effective_actions = supplied_actions.is_array()
            && !supplied_actions.as_array().empty()
            ? supplied_actions
            : position.search_legal_action_candidates(actor);
        if (!effective_actions.is_array()) return {};

        const ptcg::ai::Value::Array &actions = effective_actions.as_array();
        Dictionary payload;
        Array components;
        const bool needs_trusted_action_components =
            trusted_action_enabled_ && actor == root_actor_;
        if (needs_trusted_action_components) {
            components.resize(static_cast<int64_t>(actions.size()));
            ptcg::ai::Value::Array oracle_actions;
            std::vector<std::size_t> oracle_indices;
            oracle_actions.reserve(actions.size());
            oracle_indices.reserve(actions.size());
            for (std::size_t index = 0; index < actions.size(); ++index) {
                const std::optional<double> native_score =
                    trusted_evaluator_.action_score(position, actor, actions[index]);
                if (native_score.has_value()) {
                    Dictionary component;
                    component["index"] = static_cast<int64_t>(index);
                    component["trusted_valid"] = true;
                    component["trusted_value"] = *native_score;
                    component["strategy_valid"] = false;
                    component["strategy_value"] = 0.0;
                    components[static_cast<int64_t>(index)] = component;
                    ++native_trusted_action_scores_;
                } else {
                    oracle_indices.push_back(index);
                    oracle_actions.push_back(actions[index]);
                }
            }
            if (!oracle_actions.empty()) {
                payload["snapshot"] = dictionary_from_value(position.snapshot());
                payload["actor"] = actor;
                payload["supplied_actions"] = ptcg::ai::value_to_godot(
                    ptcg::ai::Value(oracle_actions));
                const Variant response = provider_.call(
                    "action_score_components", payload);
                ++provider_callbacks_;
                ++action_score_callbacks_;
                oracle_trusted_action_scores_.fetch_add(
                    oracle_actions.size(), std::memory_order_relaxed);
                if (response.get_type() != Variant::ARRAY) return {};
                const Array oracle_components = response;
                if (oracle_components.size()
                    != static_cast<int64_t>(oracle_indices.size())) return {};
                for (std::size_t offset = 0;
                    offset < oracle_indices.size(); ++offset) {
                    components[static_cast<int64_t>(oracle_indices[offset])] =
                        oracle_components[static_cast<int64_t>(offset)];
                }
            }
        }
        std::vector<ptcg::ai::TraditionalRankedAction> output;
        output.reserve(actions.size());
        for (std::size_t index = 0; index < actions.size(); ++index) {
            const Dictionary component = index < static_cast<std::size_t>(components.size())
                && components[static_cast<int64_t>(index)].get_type() == Variant::DICTIONARY
                ? Dictionary(components[static_cast<int64_t>(index)]) : Dictionary();
            std::int64_t score = evaluator_.default_action_score_milli(actions[index]);
            if (bool(component.get("trusted_valid", false))) {
                score = ptcg::ai::TraditionalPositionEvaluator::quantize(
                    double(component.get("trusted_value", 0.0)));
            }
            const double native_strategy = strategy_catalog_.action_score(
                position.search_state(), actor, actions[index]);
            score += std::max<std::int64_t>(-250000, std::min<std::int64_t>(
                250000,
                ptcg::ai::TraditionalPositionEvaluator::quantize(native_strategy)));
            output.push_back(ptcg::ai::TraditionalRankedAction{
                actions[index],
                score,
                {},
                {},
                {},
                index,
            });
        }
        const auto stable = [](const ptcg::ai::Value &value) {
            return utf8(stable_value_signature(value));
        };
        const auto sha = [](const std::string &value) {
            return utf8(String::utf8(value.c_str()).sha256_text());
        };
        for (auto &row : output) {
            row.signature = ptcg::ai::traditional_action_signature(
                row.action, stable, sha);
            row.semantic_bucket = ptcg::ai::traditional_semantic_bucket(
                row.action, stable);
            row.purpose_bucket = ptcg::ai::traditional_action_purpose(row.action);
            if (debug_trajectory_) {
                debug_actions_by_signature_[String::utf8(row.signature.c_str())] =
                    ptcg::ai::value_to_godot(row.action);
            }
        }
        ptcg::ai::traditional_sort_ranked_actions(output);
        auto selected = ptcg::ai::traditional_diverse_top_actions(output, limit);
        if (debug_trajectory_ && first_rank_mismatch_.is_empty()) {
            if (payload.get("snapshot", Variant()).get_type()
                != Variant::DICTIONARY) {
                payload["snapshot"] = dictionary_from_value(position.snapshot());
            }
            payload["actor"] = actor;
            payload["supplied_actions"] = ptcg::ai::value_to_godot(
                effective_actions);
            payload["limit"] = static_cast<int64_t>(limit);
            const Variant oracle_value = provider_.call("ranked_actions", payload);
            ++provider_callbacks_;
            if (oracle_value.get_type() == Variant::ARRAY) {
                const Array oracle = oracle_value;
                bool mismatch = oracle.size() != static_cast<int64_t>(selected.size());
                Array native_rows;
                for (const auto &row : selected) {
                    Dictionary native_row;
                    native_row["signature"] = String::utf8(row.signature.c_str());
                    native_row["score_milli"] = row.score_milli;
                    native_row["action"] = ptcg::ai::value_to_godot(row.action);
                    native_rows.push_back(native_row);
                }
                if (!mismatch) {
                    for (std::size_t index = 0; index < selected.size(); ++index) {
                        const Dictionary oracle_row = oracle[static_cast<int64_t>(index)];
                        if (
                            String::utf8(selected[index].signature.c_str())
                                != String(oracle_row.get("signature", ""))
                            || selected[index].score_milli
                                != int64_t(oracle_row.get("score_milli", 0))
                        ) {
                            mismatch = true;
                            break;
                        }
                    }
                }
                if (mismatch) {
                    first_rank_mismatch_["actor"] = actor;
                    first_rank_mismatch_["state"] = dictionary_from_value(
                        position.snapshot());
                    first_rank_mismatch_["native"] = native_rows;
                    first_rank_mismatch_["oracle"] = oracle;
                    first_rank_mismatch_["components"] = components;
                    const Variant oracle_components = provider_.call(
                        "action_score_components", payload);
                    ++provider_callbacks_;
                    if (oracle_components.get_type() == Variant::ARRAY) {
                        first_rank_mismatch_["oracle_components"] =
                            oracle_components;
                    }
                }
            }
        }
        // The traversal owns diversity selection. Returning the full stable
        // ranking preserves TraditionalTurnPlanner's two-stage contract:
        // freeze a root set once, then re-filter/re-diversify it per belief.
        return output;
    }

    std::int64_t state_score_milli(
        const ptcg::ai::RulesSession &position,
        std::int32_t root_actor
    ) override {
        ++state_score_queries_;
        const ptcg::ai::Value &state = position.search_state();
        if (
            string_field(state, "result_status", "ONGOING") != "ONGOING"
            || string_field(state, "phase") == "GAME_OVER"
        ) {
            return evaluator_.base_state_score_milli(position, root_actor);
        }
        const std::int64_t base_score = evaluator_.base_state_score_milli(
            position, root_actor);
        std::int64_t score = base_score;
        std::int64_t trusted_score = 0;
        if (trusted_leaf_enabled_) {
            trusted_score = std::max<std::int64_t>(-210000, std::min<std::int64_t>(
                210000,
                ptcg::ai::TraditionalPositionEvaluator::quantize(
                    trusted_evaluator_.leaf_score(position, root_actor) * 0.35)));
            score += trusted_score;
        }
        const double native_strategy = strategy_catalog_.state_score(
            position.search_state(), root_actor);
        const std::int64_t strategy_score = std::max<std::int64_t>(
            -300000, std::min<std::int64_t>(
            300000,
            ptcg::ai::TraditionalPositionEvaluator::quantize(native_strategy)));
        score += strategy_score;
        if (debug_trajectory_ && first_state_score_mismatch_.is_empty()) {
            Dictionary payload;
            payload["snapshot"] = dictionary_from_value(position.snapshot());
            payload["actor"] = root_actor;
            const Variant oracle_value = provider_.call("state_score_milli", payload);
            ++provider_callbacks_;
            const std::int64_t oracle_score = int64_t(oracle_value);
            if (oracle_score != score) {
                first_state_score_mismatch_["actor"] = root_actor;
                first_state_score_mismatch_["state"] = payload["snapshot"];
                first_state_score_mismatch_["native_total"] = score;
                first_state_score_mismatch_["oracle_total"] = oracle_score;
                first_state_score_mismatch_["native_base"] = base_score;
                first_state_score_mismatch_["native_trusted"] = trusted_score;
                first_state_score_mismatch_["native_strategy"] = strategy_score;
                first_state_score_mismatch_["native_strategy_value"] = native_strategy;
                first_state_score_mismatch_["native_trusted_components"] =
                    ptcg::ai::value_to_godot(
                        trusted_evaluator_.debug_components(position, root_actor));
                const Variant adjustments = provider_.call(
                    "state_score_adjustments", payload);
                ++provider_callbacks_;
                if (adjustments.get_type() == Variant::DICTIONARY) {
                    first_state_score_mismatch_["oracle_adjustments"] = adjustments;
                }
            }
        }
        return score;
    }

    bool resolve_pending(
        ptcg::ai::RulesSession &position,
        std::int32_t decision_player,
        std::uint64_t &nodes_expanded,
        ptcg::ai::TraditionalChoiceTrace &trace
    ) override {
        (void)nodes_expanded;
        (void)decision_player;
        for (std::size_t guard = 0; guard < 32; ++guard) {
            const ptcg::ai::Value *pending = &position.search_pending_choice(0);
            std::int32_t pending_player = 0;
            if (pending->is_null()) {
                pending = &position.search_pending_choice(1);
                pending_player = 1;
            }
            if (pending->is_null()) return true;
            const ptcg::ai::typed::ChoiceView *typed_pending =
                position.typed_search_pending_choice(pending_player);
            if (typed_pending == nullptr) return false;
            trace.had_choice = true;
            ++choice_resolutions_;
            ptcg::ai::Value response;
            bool used_native_choice = false;
            if (forced_choice_response(
                position.search_state(), *pending, *typed_pending, response)) {
                ++native_forced_choice_resolutions_;
                used_native_choice = true;
            } else if (confirm_choice_response(
                position, *pending, *typed_pending, response)) {
                ++native_choice_resolutions_;
                used_native_choice = true;
            } else if (arven_choice_response(
                position, *pending, *typed_pending, response)) {
                ++native_choice_resolutions_;
                used_native_choice = true;
            } else if (duplicate_energy_choice_response(
                position, *pending, *typed_pending, response)) {
                ++native_choice_resolutions_;
                used_native_choice = true;
            } else if (single_choice_response(
                position, *pending, *typed_pending, response)) {
                ++native_choice_resolutions_;
                used_native_choice = true;
            } else {
                if (strict_native_choices_) return false;
                Dictionary payload;
                payload["snapshot"] = dictionary_from_value(position.snapshot());
                payload["rng_state"] = static_cast<int64_t>(position.rng_state());
                payload["actor"] = pending_player;
                const Dictionary selected = call_dictionary(
                    "select_pending_choice", payload);
                ++provider_callbacks_;
                ++choice_callbacks_;
                const Variant response_value = selected.get(
                    "response", Variant());
                if (!bool(selected.get("success", false))
                    || response_value.get_type() != Variant::DICTIONARY) {
                    return false;
                }
                response = ptcg::ai::value_from_godot(response_value);
            }
            if (debug_trajectory_ && used_native_choice
                && first_choice_mismatch_.is_empty()) {
                Dictionary payload;
                payload["snapshot"] = dictionary_from_value(position.snapshot());
                payload["rng_state"] = static_cast<int64_t>(position.rng_state());
                payload["actor"] = pending_player;
                const Dictionary selected = call_dictionary(
                    "select_pending_choice", payload);
                ++provider_callbacks_;
                const Variant oracle_variant = selected.get("response", Variant());
                if (bool(selected.get("success", false))
                    && oracle_variant.get_type() == Variant::DICTIONARY) {
                    const ptcg::ai::Value oracle = ptcg::ai::value_from_godot(
                        oracle_variant);
                    if (stable_value_signature(response)
                        != stable_value_signature(oracle)) {
                        first_choice_mismatch_["state"] = payload["snapshot"];
                        first_choice_mismatch_["pending"] =
                            ptcg::ai::value_to_godot(*pending);
                        first_choice_mismatch_["native"] =
                            ptcg::ai::value_to_godot(response);
                        first_choice_mismatch_["oracle"] = oracle_variant;
                    }
                }
            }
            const ptcg::ai::RulesSessionResult applied = position.apply_choice(
                response);
            if (!applied.success) return false;
            for (const ptcg::ai::Value &event : applied.events) {
                const ptcg::ai::Value *event_type = event.find("event_type");
                const std::string type = event_type == nullptr
                    ? std::string{} : event_type->string_or();
                if (type == "coin_flip"
                    || type.find("shuffle") != std::string::npos
                    || type.find("draw") != std::string::npos
                    || type.find("random") != std::string::npos) {
                    trace.unpredictable = true;
                }
            }
        }
        return false;
    }

    std::int32_t decision_actor(
        const ptcg::ai::RulesSession &position
    ) override {
        const ptcg::ai::Value &snapshot = position.search_state();
        const ptcg::ai::Value *promotions = snapshot.find("pending_promotions");
        if (
            promotions != nullptr && promotions->is_array()
            && !promotions->as_array().empty()
        ) {
            return static_cast<std::int32_t>(
                promotions->as_array().front().as_integer(-1));
        }
        if (string_field(snapshot, "phase") == "SETUP") {
            return static_cast<std::int32_t>(integer_field(
                snapshot, "setup_actor_idx", -1));
        }
        return static_cast<std::int32_t>(integer_field(
            snapshot, "active_player_idx", -1));
    }

    bool terminal(const ptcg::ai::RulesSession &position) override {
        const ptcg::ai::Value &snapshot = position.search_state();
        return string_field(snapshot, "result_status", "ONGOING") != "ONGOING"
            || string_field(snapshot, "phase") == "GAME_OVER";
    }

    std::string state_fingerprint(
        const ptcg::ai::RulesSession &position
    ) override {
        const std::string fingerprint = utf8(
            traditional_state_fingerprint(position));
        if (debug_trajectory_) {
            std::lock_guard<std::mutex> lock(debug_state_mutex_);
            debug_states_by_fingerprint_.try_emplace(
                fingerprint, position.search_state());
        }
        return fingerprint;
    }

    bool action_ends_turn(const ptcg::ai::Value &action) override {
        const std::string kind = string_field(action, "kind");
        return kind == "DECLARE_ATTACK" || kind == "END_TURN"
            || kind == "SETUP_DONE";
    }

    ptcg::ai::Value bind_action(
        const ptcg::ai::Value &candidate,
        const ptcg::ai::RulesSession &position,
        std::int32_t actor,
        const std::string &action_id
    ) override {
        ptcg::ai::Value result = candidate;
        result["schema_version"] = ptcg::ai::Value(4);
        result["action_id"] = ptcg::ai::Value(action_id);
        result["base_revision"] = ptcg::ai::Value(position.revision());
        result["actor"] = ptcg::ai::Value(actor);
        return result;
    }

    std::uint32_t branch_seed(
        std::uint32_t base_seed,
        std::size_t depth,
        const std::string &root_signature,
        const std::string &sequence_signature,
        std::size_t action_index
    ) override {
        const int64_t mixed = static_cast<int64_t>(base_seed)
            ^ static_cast<int64_t>(String::utf8(root_signature.c_str()).hash())
            ^ static_cast<int64_t>(
                String::utf8(sequence_signature.c_str()).hash())
            ^ static_cast<int64_t>(depth * 32452843ULL)
            ^ static_cast<int64_t>((action_index + 1ULL) * 49979687ULL);
        const std::uint64_t magnitude = mixed < 0
            ? static_cast<std::uint64_t>(-(mixed + 1)) + 1ULL
            : static_cast<std::uint64_t>(mixed);
        return static_cast<std::uint32_t>(magnitude + 1ULL);
    }

    std::string trace_seed() override {
        return sha256_text("turn_beam_v2:trajectory:v1");
    }

    std::string trace_event(
        const std::string &previous_hash,
        const std::string &event
    ) override {
        if (debug_trajectory_) debug_trajectory_events_.push_back(event);
        return sha256_text(previous_hash + "\n" + event);
    }

    std::string sha256_text(const std::string &value) override {
        return utf8(String::utf8(value.c_str()).sha256_text());
    }

    std::string deck_key_for_actor(
        const ptcg::ai::RulesSession &position,
        std::int32_t actor
    ) override {
        const ptcg::ai::Value &snapshot = position.search_state();
        const ptcg::ai::Value *keys = snapshot.find("public_deck_keys");
        if (
            keys == nullptr || !keys->is_array() || actor < 0
            || static_cast<std::size_t>(actor) >= keys->as_array().size()
        ) {
            return {};
        }
        return keys->as_array()[static_cast<std::size_t>(actor)].string_or();
    }

    std::string strategy_id_for_actor(
        const ptcg::ai::RulesSession &position,
        std::int32_t actor
    ) override {
        return strategy_catalog_.strategy_id(
            deck_key_for_actor(position, actor));
    }

    ptcg::ai::Value cache_precondition(
        const ptcg::ai::RulesSession &position,
        std::int32_t actor
    ) override {
        ptcg::ai::TraditionalInformationSet information;
        std::string error;
        if (!information.capture(
            position.search_state(), actor, catalog_, decks_,
            ptcg::ai::Value::make_array(),
            ptcg::ai::Value::make_array(),
            0,
            &error
        )) {
            return ptcg::ai::Value::make_object();
        }
        ptcg::ai::Value payload = information.public_snapshot();
        for (const char *key : {
            "legal_actions", "public_history", "perspective", "match_seed",
        }) payload.erase(key);
        const std::string fingerprint = utf8(
            information_value_signature(payload).sha256_text());
        const ptcg::ai::Value *observed_actor = information.public_snapshot().find("actor");
        const ptcg::ai::Value *phase = information.public_snapshot().find("phase");
        return ptcg::ai::Value(ptcg::ai::Value::Object{
            {"expected_public_fingerprint", ptcg::ai::Value(
                "public:" + fingerprint)},
            {"expected_actor", observed_actor == nullptr
                ? ptcg::ai::Value(-1) : *observed_actor},
            {"expected_phase", phase == nullptr
                ? ptcg::ai::Value("") : *phase},
        });
    }

private:
    bool duplicate_energy_choice_response(
        const ptcg::ai::RulesSession &position,
        const ptcg::ai::Value &pending,
        const ptcg::ai::typed::ChoiceView &choice,
        ptcg::ai::Value &response
    ) const {
        if (!choice.allow_duplicates || choice.request_type != "distribute_energy") {
            return false;
        }
        const ptcg::ai::Value *options_value = pending.find("options");
        const ptcg::ai::Value *presentation_value = pending.find("presentation");
        if (options_value == nullptr || !options_value->is_array()
            || presentation_value == nullptr || !presentation_value->is_object()) {
            return false;
        }
        const auto &options = options_value->as_array();
        const ptcg::ai::Value &presentation = *presentation_value;
        const std::int64_t maximum = std::max<std::int64_t>(0, choice.max_select);
        const std::int64_t minimum = std::max<std::int64_t>(0, choice.min_select);
        const std::int64_t max_per_target = std::max<std::int64_t>(
            0, integer_field(presentation, "max_per_target", 2147483647));
        const bool same_target = bool_field(presentation, "same_target");
        if (same_target) {
            struct Row {
                std::size_t index = 0;
                double score = 0.0;
                std::int64_t useful_count = 0;
            };
            std::vector<Row> ranked;
            ranked.reserve(options.size());
            for (std::size_t index = 0; index < options.size(); ++index) {
                const std::optional<double> base =
                    trusted_evaluator_.choice_option_score(
                        position, choice.player, pending, options[index]);
                const ptcg::ai::Value plan =
                    trusted_evaluator_.energy_target_prefix_plan(
                        position, choice.player, pending,
                        options[index], maximum);
                const std::int64_t count = integer_field(plan, "count");
                // Public ChoiceView options can be shape-valid even when a
                // synthetic/minimal projected state cannot resolve the target
                // for semantic scoring. Cardinality is still authoritative:
                // use deterministic public order as the fallback score.
                const double base_score = base.value_or(0.0);
                double score = count <= 0 ? -10000.0 : base_score
                    + std::max(0.0, std::min(180.0,
                        (plan.find("gain") == nullptr ? 0.0
                            : plan.find("gain")->as_number()) * 0.35));
                score += strategy_catalog_.choice_score(
                    position.search_state(), choice.player,
                    pending, options[index]);
                ranked.push_back({index, score, count});
            }
            const auto approximately_equal = [](double left, double right) {
                const double tolerance = 0.00001
                    * std::max(1.0, std::max(std::abs(left), std::abs(right)));
                return std::abs(left - right) <= tolerance;
            };
            std::stable_sort(ranked.begin(), ranked.end(),
                [&approximately_equal](const Row &left, const Row &right) {
                    if (approximately_equal(left.score, right.score)) {
                        return left.index < right.index;
                    }
                    return left.score > right.score;
                });
            if (ranked.empty()) return false;
            const Row *selected_row = nullptr;
            for (const Row &row : ranked) {
                if (minimum <= 0 && row.score <= 0.0) break;
                if (!string_field(options[row.index], "option_id").empty()) {
                    selected_row = &row;
                    break;
                }
            }
            ptcg::ai::Value::Array selected;
            if (selected_row != nullptr) {
                std::int64_t count = maximum;
                if (selected_row->useful_count >= 0) {
                    count = std::max(minimum,
                        std::min(maximum, selected_row->useful_count));
                }
                count = std::min(count, max_per_target);
                const std::string option_id = string_field(
                    options[selected_row->index], "option_id");
                for (std::int64_t index = 0; index < count; ++index) {
                    selected.emplace_back(option_id);
                }
            }
            if (selected.size() < static_cast<std::size_t>(minimum)) return false;
            const bool cancelled = selected.empty() && choice.can_cancel;
            response = ptcg::ai::Value(ptcg::ai::Value::Object{
                {"request_id", ptcg::ai::Value(choice.request_id)},
                {"option_ids", ptcg::ai::Value(std::move(selected))},
                {"cancelled", ptcg::ai::Value(cancelled)},
            });
            return true;
        }

        if (maximum < 2 || maximum > 3) return false;
        const auto generic_public_distribution = [&] () {
            struct RankedOption {
                std::size_t index = 0;
                double score = 0.0;
            };
            std::vector<RankedOption> ranked;
            ranked.reserve(options.size());
            for (std::size_t index = 0; index < options.size(); ++index) {
                const std::optional<double> base =
                    trusted_evaluator_.choice_option_score(
                        position, choice.player, pending, options[index]);
                if (!base.has_value()) return false;
                ranked.push_back({
                    index,
                    *base + strategy_catalog_.choice_score(
                        position.search_state(), choice.player,
                        pending, options[index]),
                });
            }
            std::stable_sort(
                ranked.begin(), ranked.end(),
                [](const RankedOption &left, const RankedOption &right) {
                    const double tolerance = 0.00001 * std::max(
                        1.0, std::max(std::abs(left.score), std::abs(right.score)));
                    if (std::abs(left.score - right.score) <= tolerance) {
                        return left.index < right.index;
                    }
                    return left.score > right.score;
                });
            std::vector<std::size_t> allowed;
            for (const RankedOption &row : ranked) {
                if (minimum <= 0 && row.score <= 0.0) continue;
                allowed.push_back(row.index);
            }
            if (allowed.empty() && minimum > 0) {
                for (const RankedOption &row : ranked) allowed.push_back(row.index);
            }
            const std::int64_t target_count = minimum <= 0
                ? (allowed.empty() ? 0 : maximum)
                : std::max(minimum, maximum);
            ptcg::ai::Value::Array selected;
            std::map<std::string, std::int64_t> per_target;
            std::string selected_target;
            while (selected.size() < static_cast<std::size_t>(target_count)) {
                bool appended = false;
                for (const std::size_t option_index : allowed) {
                    const std::string option_id = string_field(
                        options[option_index], "option_id");
                    const ptcg::ai::Value *reference = options[option_index].find("ref");
                    const std::string target_key = reference != nullptr
                        && reference->is_object()
                        ? std::to_string(integer_field(
                            *reference, "player", choice.player)) + ":"
                            + string_field(*reference, "slot")
                        : option_id;
                    if (option_id.empty()
                        || (same_target && !selected_target.empty()
                            && target_key != selected_target)
                        || per_target[target_key] >= max_per_target) continue;
                    selected.emplace_back(option_id);
                    if (selected_target.empty()) selected_target = target_key;
                    ++per_target[target_key];
                    appended = true;
                    break;
                }
                if (!appended) break;
            }
            if (selected.size() < static_cast<std::size_t>(minimum)) return false;
            const bool cancelled = selected.empty() && choice.can_cancel;
            response = ptcg::ai::Value(ptcg::ai::Value::Object{
                {"request_id", ptcg::ai::Value(choice.request_id)},
                {"option_ids", ptcg::ai::Value(std::move(selected))},
                {"cancelled", ptcg::ai::Value(cancelled)},
            });
            return true;
        };
        const ptcg::ai::Value *card_ids_value = presentation.find("card_ids");
        if (card_ids_value == nullptr || !card_ids_value->is_array()
            || card_ids_value->as_array().size()
                < static_cast<std::size_t>(maximum)) {
            return generic_public_distribution();
        }
        std::vector<std::string> energy_ids;
        energy_ids.reserve(static_cast<std::size_t>(maximum));
        for (std::int64_t index = 0; index < maximum; ++index) {
            const std::string id = card_ids_value->as_array()[
                static_cast<std::size_t>(index)].string_or();
            const ptcg::ai::Value *definition = cards_.find(id);
            if (definition == nullptr || string_field(*definition, "supertype")
                != "Energy") return false;
            energy_ids.push_back(id);
        }
        struct Target {
            std::size_t option_index = 0;
            std::string option_id;
            std::string slot;
        };
        std::vector<Target> targets;
        std::set<std::string> seen_slots;
        std::set<std::string> seen_ids;
        const ptcg::ai::Value &state = position.search_state();
        const ptcg::ai::Value *players = state.find("players");
        if (players == nullptr || !players->is_array() || choice.player < 0
            || static_cast<std::size_t>(choice.player)
                >= players->as_array().size()) return false;
        const ptcg::ai::Value &owner = players->as_array()[
            static_cast<std::size_t>(choice.player)];
        for (std::size_t index = 0; index < options.size(); ++index) {
            const ptcg::ai::Value &option = options[index];
            const std::string option_id = string_field(option, "option_id");
            const ptcg::ai::Value *reference = option.find("ref");
            const std::string slot = reference != nullptr && reference->is_object()
                ? string_field(*reference, "slot") : std::string{};
            const std::int64_t target_player = reference != nullptr
                && reference->is_object()
                ? integer_field(*reference, "player", choice.player)
                : choice.player;
            if (option_id.empty() || slot.empty() || target_player != choice.player
                || seen_slots.count(slot) || seen_ids.count(option_id)) continue;
            const ptcg::ai::Value *pokemon = nullptr;
            if (slot == "active") pokemon = owner.find("active");
            else if (slot.rfind("bench_", 0) == 0) {
                try {
                    const std::size_t bench_index = static_cast<std::size_t>(
                        std::stoll(slot.substr(6)));
                    const ptcg::ai::Value *bench = owner.find("bench");
                    if (bench != nullptr && bench->is_array()
                        && bench_index < bench->as_array().size()) {
                        pokemon = &bench->as_array()[bench_index];
                    }
                } catch (const std::exception &) {}
            }
            if (pokemon == nullptr || !pokemon->is_object()) continue;
            const std::string public_card = reference != nullptr
                && reference->is_object()
                ? string_field(*reference, "card_id") : std::string{};
            if (!public_card.empty()
                && public_card != string_field(*pokemon, "card_id")) continue;
            seen_slots.insert(slot);
            seen_ids.insert(option_id);
            targets.push_back({index, option_id, slot});
        }
        if (targets.empty()) return false;
        const std::string purpose = string_field(presentation, "purpose");
        const bool relocation = purpose.rfind("energy_relocate", 0) == 0
            || purpose.rfind("relocate_energy", 0) == 0;
        if (relocation && minimum != maximum) return false;
        std::unique_ptr<ptcg::ai::RulesSession> simulation =
            position.fork_for_search(position.rng_state());
        if (!simulation) return false;
        bool found = false;
        double best_score = -std::numeric_limits<double>::infinity();
        ptcg::ai::Value::Array best_ids;
        for (std::int64_t count = minimum; count <= maximum; ++count) {
            std::uint64_t assignment_count = 1;
            for (std::int64_t index = 0; index < count; ++index) {
                assignment_count *= static_cast<std::uint64_t>(targets.size());
            }
            for (std::uint64_t ordinal = 0; ordinal < assignment_count; ++ordinal) {
                std::uint64_t encoded = ordinal;
                std::vector<std::size_t> assignment(static_cast<std::size_t>(count));
                // GDScript expands the leftmost position first. Decode in base N
                // with the last position changing fastest to preserve that order.
                for (std::size_t reverse = assignment.size(); reverse > 0; --reverse) {
                    assignment[reverse - 1] = static_cast<std::size_t>(
                        encoded % targets.size());
                    encoded /= targets.size();
                }
                std::map<std::string, std::int64_t> target_counts;
                bool shape_ok = true;
                for (std::size_t target_index : assignment) {
                    if (++target_counts[targets[target_index].slot] > max_per_target) {
                        shape_ok = false;
                        break;
                    }
                }
                if (!shape_ok) continue;
                ptcg::ai::Value snapshot = position.snapshot();
                ptcg::ai::Value *snapshot_players = snapshot.find("players");
                if (snapshot_players == nullptr || !snapshot_players->is_array()) {
                    return false;
                }
                ptcg::ai::Value &mutable_owner = snapshot_players->as_array()[
                    static_cast<std::size_t>(choice.player)];
                if (relocation) {
                    const std::int32_t source_player = static_cast<std::int32_t>(
                        integer_field(
                            presentation,
                            "source_player",
                            choice.player));
                    const std::string source_slot = string_field(
                        presentation, "source_slot");
                    const ptcg::ai::Value *refs = presentation.find("attachment_refs");
                    if (source_player != choice.player || source_slot.empty()
                        || refs == nullptr || !refs->is_array()
                        || refs->as_array().size() < static_cast<std::size_t>(maximum)) {
                        return false;
                    }
                    ptcg::ai::Value *source = source_slot == "active"
                        ? mutable_owner.find("active") : nullptr;
                    if (source == nullptr && source_slot.rfind("bench_", 0) == 0) {
                        try {
                            const std::size_t index = static_cast<std::size_t>(
                                std::stoll(source_slot.substr(6)));
                            ptcg::ai::Value *bench = mutable_owner.find("bench");
                            if (bench != nullptr && bench->is_array()
                                && index < bench->as_array().size()) {
                                source = &bench->as_array()[index];
                            }
                        } catch (const std::exception &) {}
                    }
                    if (source == nullptr || !source->is_object()) return false;
                    ptcg::ai::Value *attached = source->find("energy_card_ids");
                    if (attached == nullptr || !attached->is_array()) return false;
                    std::vector<std::size_t> indices;
                    std::set<std::size_t> seen;
                    for (std::int64_t index = 0; index < maximum; ++index) {
                        const ptcg::ai::Value &reference = refs->as_array()[
                            static_cast<std::size_t>(index)];
                        const std::int64_t attachment_index = integer_field(
                            reference, "index", -1);
                        if (!reference.is_object() || attachment_index < 0
                            || static_cast<std::size_t>(attachment_index)
                                >= attached->as_array().size()
                            || seen.count(static_cast<std::size_t>(attachment_index))
                            || string_field(reference, "kind") != "attachment"
                            || integer_field(reference, "player", -1) != source_player
                            || string_field(reference, "slot") != source_slot
                            || string_field(reference, "attachment_type") != "energy"
                            || string_field(reference, "card_id") != energy_ids[
                                static_cast<std::size_t>(index)]
                            || attached->as_array()[static_cast<std::size_t>(
                                attachment_index)].string_or() != energy_ids[
                                    static_cast<std::size_t>(index)]) return false;
                        seen.insert(static_cast<std::size_t>(attachment_index));
                        indices.push_back(static_cast<std::size_t>(attachment_index));
                    }
                    std::sort(indices.rbegin(), indices.rend());
                    for (std::size_t index : indices) {
                        attached->as_array().erase(attached->as_array().begin()
                            + static_cast<std::ptrdiff_t>(index));
                    }
                }
                ptcg::ai::Value::Array candidate_ids;
                for (std::size_t position_index = 0;
                    position_index < assignment.size(); ++position_index) {
                    const Target &target = targets[assignment[position_index]];
                    candidate_ids.emplace_back(target.option_id);
                    ptcg::ai::Value *pokemon = target.slot == "active"
                        ? mutable_owner.find("active") : nullptr;
                    if (pokemon == nullptr && target.slot.rfind("bench_", 0) == 0) {
                        const std::size_t index = static_cast<std::size_t>(
                            std::stoll(target.slot.substr(6)));
                        ptcg::ai::Value *bench = mutable_owner.find("bench");
                        if (bench != nullptr && bench->is_array()
                            && index < bench->as_array().size()) {
                            pokemon = &bench->as_array()[index];
                        }
                    }
                    if (pokemon != nullptr && pokemon->is_object()) {
                        ptcg::ai::Value *attached = pokemon->find("energy_card_ids");
                        if (attached == nullptr || !attached->is_array()) {
                            (*pokemon)["energy_card_ids"] =
                                ptcg::ai::Value::make_array();
                            attached = pokemon->find("energy_card_ids");
                        }
                        attached->as_array().emplace_back(
                            energy_ids[position_index]);
                    }
                }
                std::string restore_error;
                if (!simulation->restore(
                    snapshot, position.rng_state(), &restore_error)) return false;
                const double score = trusted_evaluator_
                    .energy_distribution_board_utility(*simulation, choice.player);
                if (!found || score > best_score + 0.001) {
                    found = true;
                    best_score = score;
                    best_ids = std::move(candidate_ids);
                }
            }
        }
        if (!found) return false;
        const bool cancelled = best_ids.empty() && choice.can_cancel;
        response = ptcg::ai::Value(ptcg::ai::Value::Object{
            {"request_id", ptcg::ai::Value(choice.request_id)},
            {"option_ids", ptcg::ai::Value(std::move(best_ids))},
            {"cancelled", ptcg::ai::Value(cancelled)},
        });
        return true;
    }

    bool confirm_choice_response(
        const ptcg::ai::RulesSession &position,
        const ptcg::ai::Value &pending,
        const ptcg::ai::typed::ChoiceView &choice,
        ptcg::ai::Value &response
    ) const {
        if (choice.request_kind != ptcg::ai::typed::ChoiceRequestKind::confirm) {
            return false;
        }
        const std::optional<bool> confirmed = trusted_evaluator_.confirm_choice(
            position, choice.player, pending);
        if (!confirmed.has_value()) return false;
        const std::string expected = *confirmed ? "confirm:yes" : "confirm:no";
        if (std::none_of(choice.options.begin(), choice.options.end(),
            [&expected](const ptcg::ai::typed::ChoiceOption &option) {
                return option.option_id == expected;
            })) return false;
        response = ptcg::ai::Value(ptcg::ai::Value::Object{
            {"request_id", ptcg::ai::Value(choice.request_id)},
            {"option_ids", ptcg::ai::Value(ptcg::ai::Value::Array{
                ptcg::ai::Value(expected),
            })},
            {"cancelled", ptcg::ai::Value(false)},
        });
        return true;
    }

    std::string resolved_option_card_id(
        const ptcg::ai::Value &option
    ) const {
        const ptcg::ai::Value *reference = option.find("ref");
        if (reference != nullptr && reference->is_object()) {
            const std::string id = string_field(*reference, "card_id");
            if (!id.empty()) return id;
        }
        const std::string option_id = string_field(option, "option_id");
        const std::size_t separator = option_id.rfind(':');
        if (separator == std::string::npos || separator + 1 >= option_id.size()) {
            return {};
        }
        const std::string candidate = option_id.substr(separator + 1);
        return cards_.find(candidate) != nullptr ? candidate : std::string{};
    }

    bool arven_choice_response(
        const ptcg::ai::RulesSession &position,
        const ptcg::ai::Value &pending,
        const ptcg::ai::typed::ChoiceView &choice,
        ptcg::ai::Value &response
    ) const {
        if (choice.request_type != "arven") return false;
        const ptcg::ai::Value *options_value = pending.find("options");
        if (options_value == nullptr || !options_value->is_array()
            || options_value->as_array().empty()) return false;
        const auto &options = options_value->as_array();
        const auto has_subtype = [this](const std::string &card_id,
                                        const std::string &subtype) {
            const ptcg::ai::Value *definition = cards_.find(card_id);
            const ptcg::ai::Value *subtypes = definition != nullptr
                && definition->is_object() ? definition->find("subtypes") : nullptr;
            return subtypes != nullptr && subtypes->is_array()
                && std::any_of(subtypes->as_array().begin(), subtypes->as_array().end(),
                    [&subtype](const ptcg::ai::Value &entry) {
                        return entry.string_or() == subtype;
                    });
        };
        std::int64_t best_item = -1;
        std::int64_t best_tool = -1;
        double best_item_score = -std::numeric_limits<double>::infinity();
        double best_tool_score = -std::numeric_limits<double>::infinity();
        for (std::size_t index = 0; index < options.size(); ++index) {
            const std::optional<double> score = trusted_evaluator_.choice_option_score(
                position, choice.player, pending, options[index]);
            if (!score.has_value()) return false;
            const std::string card_id = resolved_option_card_id(options[index]);
            if (has_subtype(card_id, "Item") && *score > best_item_score) {
                best_item = static_cast<std::int64_t>(index);
                best_item_score = *score;
            } else if (has_subtype(card_id, "Tool") && *score > best_tool_score) {
                best_tool = static_cast<std::int64_t>(index);
                best_tool_score = *score;
            }
        }

        const ptcg::ai::Value &state = position.search_state();
        const ptcg::ai::Value *keys = state.find("public_deck_keys");
        const std::string key = keys != nullptr && keys->is_array()
            && choice.player >= 0
            && static_cast<std::size_t>(choice.player) < keys->as_array().size()
            ? keys->as_array()[static_cast<std::size_t>(choice.player)].string_or()
            : std::string{};
        if (
            key == "psychic" && string_field(state, "phase") == "MAIN"
            && integer_field(state, "active_player_idx", -1) == choice.player
            && integer_field(state, "first_player_idx", -1) != choice.player
            && integer_field(state, "turn_number") == 2
        ) {
            const ptcg::ai::Value *players = state.find("players");
            if (players != nullptr && players->is_array()
                && choice.player >= 0
                && static_cast<std::size_t>(choice.player) < players->as_array().size()) {
                const ptcg::ai::Value &owner = players->as_array()[
                    static_cast<std::size_t>(choice.player)];
                const ptcg::ai::Value *active = owner.find("active");
                const auto &hand = owner.find("hand") != nullptr
                    && owner.find("hand")->is_array()
                    ? owner.find("hand")->as_array()
                    : ptcg::ai::Value::Array{};
                bool has_switch = std::any_of(hand.begin(), hand.end(),
                    [](const ptcg::ai::Value &entry) {
                        return entry.string_or() == "sv1-150";
                    });
                std::int64_t cresselia_index = -1;
                const ptcg::ai::Value *bench = owner.find("bench");
                if (bench != nullptr && bench->is_array()) {
                    for (std::size_t index = 0; index < bench->as_array().size(); ++index) {
                        if (bench->as_array()[index].is_object()
                            && string_field(bench->as_array()[index], "card_id")
                                == "sv1-113") {
                            cresselia_index = static_cast<std::int64_t>(index);
                            break;
                        }
                    }
                }
                bool can_pay = false;
                if (cresselia_index >= 0 && bench != nullptr) {
                    const ptcg::ai::Value &cresselia = bench->as_array()[
                        static_cast<std::size_t>(cresselia_index)];
                    const ptcg::ai::Value *energy = cresselia.find("energy_card_ids");
                    can_pay = energy != nullptr && energy->is_array()
                        && std::any_of(energy->as_array().begin(), energy->as_array().end(),
                            [](const ptcg::ai::Value &entry) {
                                return entry.string_or() == "sv1-ener-5";
                            });
                    can_pay = can_pay || (!bool_field(owner,
                        "energy_attached_this_turn")
                        && std::any_of(hand.begin(), hand.end(),
                            [](const ptcg::ai::Value &entry) {
                                return entry.string_or() == "sv1-ener-5";
                            }));
                }
                bool direct_retreat = false;
                if (cresselia_index >= 0) {
                    const ptcg::ai::Value &actions =
                        position.search_legal_action_candidates(choice.player);
                    if (actions.is_array()) {
                        for (const ptcg::ai::Value &action : actions.as_array()) {
                            const ptcg::ai::Value *target = action.find("target");
                            if (string_field(action, "kind") == "RETREAT"
                                && target != nullptr && target->is_object()
                                && string_field(*target, "slot")
                                    == "bench_" + std::to_string(cresselia_index)) {
                                direct_retreat = true;
                                break;
                            }
                        }
                    }
                }
                if (active != nullptr && active->is_object()
                    && string_field(*active, "card_id") != "sv1-113"
                    && !has_switch && cresselia_index >= 0 && can_pay
                    && !direct_retreat) {
                    for (std::size_t index = 0; index < options.size(); ++index) {
                        if (resolved_option_card_id(options[index]) == "sv1-150") {
                            best_item = static_cast<std::int64_t>(index);
                            break;
                        }
                    }
                }
            }
        }

        ptcg::ai::Value::Array selected;
        if (best_item >= 0) selected.emplace_back(string_field(
            options[static_cast<std::size_t>(best_item)], "option_id"));
        if (best_tool >= 0
            && selected.size() < static_cast<std::size_t>(
                std::max<std::int64_t>(0, choice.max_select))) {
            selected.emplace_back(string_field(
                options[static_cast<std::size_t>(best_tool)], "option_id"));
        }
        if (selected.empty() && choice.min_select > 0) {
            std::size_t fallback = 0;
            double fallback_score = trusted_evaluator_.choice_option_score(
                position, choice.player, pending, options[0]).value_or(0.0);
            for (std::size_t index = 1; index < options.size(); ++index) {
                const double score = trusted_evaluator_.choice_option_score(
                    position, choice.player, pending, options[index]).value_or(0.0);
                if (score > fallback_score) {
                    fallback = index;
                    fallback_score = score;
                }
            }
            selected.emplace_back(string_field(options[fallback], "option_id"));
        }
        response = ptcg::ai::Value(ptcg::ai::Value::Object{
            {"request_id", ptcg::ai::Value(choice.request_id)},
            {"option_ids", ptcg::ai::Value(std::move(selected))},
            {"cancelled", ptcg::ai::Value(false)},
        });
        return true;
    }

    bool sequential_discard_response(
        const ptcg::ai::RulesSession &position,
        const ptcg::ai::Value &pending,
        const ptcg::ai::typed::ChoiceView &choice,
        ptcg::ai::Value &response
    ) const {
        const ptcg::ai::Value *options_value = pending.find("options");
        if (options_value == nullptr || !options_value->is_array()) return false;
        const auto &options = options_value->as_array();
        const std::size_t maximum = static_cast<std::size_t>(
            std::max<std::int64_t>(0, std::min<std::int64_t>(
                choice.max_select, static_cast<std::int64_t>(options.size()))));
        if (maximum <= 1 || choice.allow_duplicates) return false;
        ptcg::ai::Value virtual_state = position.snapshot();
        virtual_state["apply_type_matchups"] = ptcg::ai::Value(false);
        std::vector<std::size_t> selected_indices;
        ptcg::ai::Value::Array selected_ids;
        selected_indices.reserve(maximum);
        selected_ids.reserve(maximum);
        const auto is_hand_card = [](const ptcg::ai::Value &option) {
            const ptcg::ai::Value *reference = option.find("ref");
            if (reference != nullptr && reference->is_object()) {
                if (reference->find("zone") != nullptr) {
                    return string_field(*reference, "zone") == "hand";
                }
                if (string_field(*reference, "kind") == "attachment") return false;
            }
            return true;
        };
        const auto approximately_equal = [](double left, double right) {
            const double tolerance = 0.00001
                * std::max(1.0, std::max(std::abs(left), std::abs(right)));
            return std::abs(left - right) <= tolerance;
        };
        for (std::size_t selection_index = 0;
            selection_index < maximum; ++selection_index) {
            std::unique_ptr<ptcg::ai::RulesSession> virtual_position =
                position.fork_for_search(position.rng_state());
            std::string restore_error;
            if (!virtual_position || !virtual_position->restore(
                virtual_state, position.rng_state(), &restore_error)) return false;
            std::int64_t best_index = -1;
            double best_score = -std::numeric_limits<double>::infinity();
            std::string best_tiebreak;
            for (std::size_t option_index = 0;
                option_index < options.size(); ++option_index) {
                if (std::find(selected_indices.begin(), selected_indices.end(),
                    option_index) != selected_indices.end()) continue;
                const ptcg::ai::Value &option = options[option_index];
                const std::optional<double> base =
                    trusted_evaluator_.choice_option_score(
                        *virtual_position, choice.player, pending, option);
                if (!base.has_value()) return false;
                const double score = *base + strategy_catalog_.choice_score(
                    virtual_state, choice.player, pending, option);
                const std::string card_id = resolved_option_card_id(option);
                const std::string tiebreak = card_id + "|"
                    + string_field(option, "option_id");
                if (
                    best_index < 0 || score > best_score + 0.001
                    || (approximately_equal(score, best_score)
                        && tiebreak < best_tiebreak)
                ) {
                    best_index = static_cast<std::int64_t>(option_index);
                    best_score = score;
                    best_tiebreak = tiebreak;
                }
            }
            if (best_index < 0) return false;
            if (selection_index >= static_cast<std::size_t>(
                std::max<std::int64_t>(0, choice.min_select))
                && best_score <= 0.0) break;
            const std::size_t chosen = static_cast<std::size_t>(best_index);
            const ptcg::ai::Value &option = options[chosen];
            const std::string option_id = string_field(option, "option_id");
            if (option_id.empty()) return false;
            selected_indices.push_back(chosen);
            selected_ids.emplace_back(option_id);
            if (is_hand_card(option)) {
                const std::string card_id = resolved_option_card_id(option);
                ptcg::ai::Value *players = virtual_state.find("players");
                if (players == nullptr || !players->is_array()
                    || choice.player < 0
                    || static_cast<std::size_t>(choice.player)
                        >= players->as_array().size()) return false;
                ptcg::ai::Value &owner = players->as_array()[
                    static_cast<std::size_t>(choice.player)];
                ptcg::ai::Value *hand = owner.find("hand");
                if (hand != nullptr && hand->is_array()) {
                    auto &cards = hand->as_array();
                    const auto found = std::find_if(
                        cards.begin(), cards.end(), [&card_id](const ptcg::ai::Value &entry) {
                            return entry.string_or() == card_id;
                        });
                    if (found != cards.end()) cards.erase(found);
                }
            }
        }
        if (selected_ids.size() < static_cast<std::size_t>(
            std::max<std::int64_t>(0, choice.min_select))) return false;
        response = ptcg::ai::Value(ptcg::ai::Value::Object{
            {"request_id", ptcg::ai::Value(choice.request_id)},
            {"option_ids", ptcg::ai::Value(std::move(selected_ids))},
            {"cancelled", ptcg::ai::Value(false)},
        });
        return true;
    }

    bool single_choice_response(
        const ptcg::ai::RulesSession &position,
        const ptcg::ai::Value &pending,
        const ptcg::ai::typed::ChoiceView &choice,
        ptcg::ai::Value &response
    ) const {
        using Kind = ptcg::ai::typed::ChoiceRequestKind;
        if (
            choice.options.empty() || choice.allow_duplicates
            || choice.request_kind == Kind::confirm
            || choice.request_kind == Kind::confirm_trigger
            || choice.request_kind == Kind::choose_turn_order
            || choice.request_kind == Kind::choose_mulligan_draw_count
            || choice.request_kind == Kind::select_prize
            || choice.request_kind == Kind::select_retreat_payment
            || choice.request_type == "arven"
        ) return false;
        const ptcg::ai::Value *options_value = pending.find("options");
        if (options_value == nullptr || !options_value->is_array()
            || options_value->as_array().size() != choice.options.size()) {
            return false;
        }
        const ptcg::ai::Value *presentation_probe = pending.find("presentation");
        static const ptcg::ai::Value empty_presentation =
            ptcg::ai::Value::make_object();
        const ptcg::ai::Value &presentation_for_mode =
            presentation_probe != nullptr && presentation_probe->is_object()
            ? *presentation_probe : empty_presentation;
        const std::string request_type = string_field(pending, "request_type");
        const std::string purpose = string_field(
            presentation_for_mode, "purpose");
        const bool attachment_discard = request_type == "select_attachment"
            && purpose != "discard_energy"
            && purpose != "discard_energy_attachments"
            && purpose.rfind("energy_relocate", 0) != 0
            && purpose.rfind("relocate_energy", 0) != 0;
        const bool discard_purpose = purpose == "discard_then_draw"
            || purpose == "discard_hand_then_draw"
            || purpose == "discard_cards" || purpose == "hand_bottom_draw"
            || purpose == "houb" || purpose == "zinnia"
            || purpose == "discard" || purpose == "discard_cost"
            || purpose == "bottom_deck";
        if (choice.max_select > 1 && (attachment_discard || discard_purpose)) {
            return sequential_discard_response(
                position, pending, choice, response);
        }
        const std::int32_t actor = choice.player;
        struct ScoredOption {
            std::size_t index = 0;
            double score = 0.0;
        };
        std::vector<ScoredOption> ranked;
        ranked.reserve(choice.options.size());
        for (std::size_t index = 0; index < choice.options.size(); ++index) {
            const ptcg::ai::Value &option = options_value->as_array()[index];
            const std::optional<double> base = trusted_evaluator_.choice_option_score(
                position, actor, pending, option);
            if (!base.has_value()) return false;
            ranked.push_back({
                index,
                *base + strategy_catalog_.choice_score(
                    position.search_state(), actor, pending, option),
            });
        }
        const auto approximately_equal = [](double left, double right) {
            const double tolerance = 0.00001
                * std::max(1.0, std::max(std::abs(left), std::abs(right)));
            return std::abs(left - right) <= tolerance;
        };
        std::stable_sort(ranked.begin(), ranked.end(),
            [&approximately_equal](const ScoredOption &left,
                                    const ScoredOption &right) {
                if (approximately_equal(left.score, right.score)) {
                    return left.index < right.index;
                }
                return left.score > right.score;
            });

        const ptcg::ai::Value *presentation_value = pending.find("presentation");
        static const ptcg::ai::Value empty = ptcg::ai::Value::make_object();
        const ptcg::ai::Value &presentation = presentation_value != nullptr
            && presentation_value->is_object() ? *presentation_value : empty;
        const std::int64_t max_per_target = std::max<std::int64_t>(
            0, integer_field(presentation, "max_per_target", 2147483647));
        const ptcg::ai::Value *category_limits = presentation.find(
            "category_limits");
        const auto category_for = [this](const ptcg::ai::Value &option) {
            const ptcg::ai::Value *reference = option.find("ref");
            const std::string card_id = reference != nullptr
                && reference->is_object()
                ? string_field(*reference, "card_id") : std::string{};
            if (card_id.empty()) return std::string{};
            const ptcg::ai::Value *definition = cards_.find(card_id);
            if (definition == nullptr || !definition->is_object()) return std::string{};
            const std::string supertype = string_field(*definition, "supertype");
            const ptcg::ai::Value *subtypes = definition->find("subtypes");
            const auto has_subtype = [&subtypes](const std::string &needle) {
                if (subtypes == nullptr || !subtypes->is_array()) return false;
                return std::any_of(
                    subtypes->as_array().begin(), subtypes->as_array().end(),
                    [&needle](const ptcg::ai::Value &entry) {
                        return entry.string_or() == needle;
                    });
            };
            if (supertype == "Pokémon") return std::string("pokemon");
            if (supertype == "Energy") return std::string("energy");
            if (supertype == "Trainer" && has_subtype("Item")) {
                return std::string("item");
            }
            if (supertype == "Trainer" && has_subtype("Tool")) {
                return std::string("tool");
            }
            if (supertype == "Trainer") return std::string("trainer");
            return std::string{};
        };
        const auto category_limit = [&](const std::string &category) {
            if (category.empty()) return std::int64_t{2147483647};
            if (category_limits != nullptr && category_limits->is_object()) {
                const ptcg::ai::Value *explicit_limit = category_limits->find(category);
                if (explicit_limit != nullptr) {
                    return std::max<std::int64_t>(0, explicit_limit->as_integer());
                }
            }
            const ptcg::ai::Value *count_field = presentation.find(
                category + "_count");
            return count_field != nullptr && count_field->is_integer()
                ? std::max<std::int64_t>(0, count_field->as_integer())
                : std::int64_t{2147483647};
        };

        const bool same_target = bool_field(presentation, "same_target");
        const auto target_key_for = [](const ptcg::ai::Value &option) {
            const ptcg::ai::Value *reference = option.find("ref");
            if (reference != nullptr && reference->is_object()) {
                const std::string slot = string_field(*reference, "slot");
                if (!slot.empty()) {
                    return std::to_string(integer_field(*reference, "player", -1))
                        + ":" + slot;
                }
            }
            return "option:" + string_field(option, "option_id");
        };
        const std::size_t maximum = static_cast<std::size_t>(
            std::max<std::int64_t>(0, std::min<std::int64_t>(
                choice.max_select,
                static_cast<std::int64_t>(choice.options.size()))));
        std::size_t desired_count = maximum;
        if (choice.min_select <= 0) {
            desired_count = std::min(maximum, static_cast<std::size_t>(
                std::count_if(ranked.begin(), ranked.end(),
                    [](const ScoredOption &row) { return row.score > 0.0; })));
        }
        ptcg::ai::Value::Array selected_ids;
        std::map<std::string, std::int64_t> per_target;
        std::map<std::string, std::int64_t> per_category;
        std::set<std::string> used_option_ids;
        std::string selected_target;
        if (desired_count > 0 && max_per_target > 0) {
            std::size_t optional_candidates_seen = 0;
            for (const ScoredOption &row : ranked) {
                if (choice.min_select <= 0) {
                    if (row.score <= 0.0 || optional_candidates_seen >= maximum) {
                        break;
                    }
                    ++optional_candidates_seen;
                }
                const ptcg::ai::Value &option = options_value->as_array()[row.index];
                const std::string option_id = string_field(option, "option_id");
                if (option_id.empty() || used_option_ids.count(option_id)) continue;
                const std::string target_key = target_key_for(option);
                if (same_target && !selected_target.empty()
                    && target_key != selected_target) continue;
                if (per_target[target_key] >= max_per_target) continue;
                const std::string category = category_for(option);
                if (per_category[category] >= category_limit(category)) continue;
                selected_ids.emplace_back(option_id);
                used_option_ids.insert(option_id);
                if (selected_target.empty()) selected_target = target_key;
                ++per_target[target_key];
                if (!category.empty()) ++per_category[category];
                if (selected_ids.size() >= desired_count) break;
            }
        }
        const bool cancelled = selected_ids.empty()
            && choice.min_select <= 0 && choice.can_cancel;
        response = ptcg::ai::Value(ptcg::ai::Value::Object{
            {"request_id", ptcg::ai::Value(choice.request_id)},
            {"option_ids", ptcg::ai::Value(std::move(selected_ids))},
            {"cancelled", ptcg::ai::Value(cancelled)},
        });
        return choice.min_select <= 0 || !response.find("option_ids")
            ->as_array().empty();
    }

    bool forced_choice_response(
        const ptcg::ai::Value &state,
        const ptcg::ai::Value &pending,
        const ptcg::ai::typed::ChoiceView &choice,
        ptcg::ai::Value &response
    ) const {
        if (!pending.is_object()) return false;
        const ptcg::ai::Value *options_value = pending.find("options");
        if (options_value == nullptr || !options_value->is_array()) {
            return false;
        }
        ptcg::ai::Value::Array selected_ids;
        bool cancelled = false;
        if (choice.options.empty()) {
            cancelled = choice.can_cancel && choice.min_select <= 0;
        } else if (
            choice.options.size() == 1
            && choice.min_select == 1 && choice.max_select == 1
            && !choice.allow_duplicates
        ) {
            selected_ids.emplace_back(choice.options.front().option_id);
        } else {
            using Kind = ptcg::ai::typed::ChoiceRequestKind;
            if (choice.request_kind == Kind::choose_turn_order) {
                selected_ids.emplace_back("turn:first");
            } else if (
                choice.request_kind == Kind::choose_mulligan_draw_count
            ) {
                std::int64_t largest_draw = -1;
                for (const ptcg::ai::typed::ChoiceOption &option
                    : choice.options) {
                    const std::string &option_id = option.option_id;
                    constexpr std::string_view prefix = "draw:";
                    if (option_id.rfind(prefix, 0) != 0) continue;
                    std::int64_t count = 0;
                    const char *begin = option_id.data() + prefix.size();
                    const char *end = option_id.data() + option_id.size();
                    const auto parsed = std::from_chars(begin, end, count);
                    if (parsed.ec == std::errc{} && parsed.ptr == end) {
                        largest_draw = std::max(largest_draw, count);
                    }
                }
                selected_ids.emplace_back(
                    "draw:" + std::to_string(std::max<std::int64_t>(
                        0, largest_draw)));
            } else if (choice.request_kind == Kind::select_prize) {
                std::int64_t lowest_prize = 999;
                for (const ptcg::ai::typed::ChoiceOption &option
                    : choice.options) {
                    const std::string &option_id = option.option_id;
                    constexpr std::string_view prefix = "prize:";
                    if (option_id.rfind(prefix, 0) != 0) continue;
                    std::int64_t index = 0;
                    const char *begin = option_id.data() + prefix.size();
                    const char *end = option_id.data() + option_id.size();
                    const auto parsed = std::from_chars(begin, end, index);
                    if (parsed.ec == std::errc{} && parsed.ptr == end) {
                        lowest_prize = std::min(lowest_prize, index);
                    }
                }
                selected_ids.emplace_back(
                    "prize:" + std::to_string(
                        lowest_prize == 999 ? 0 : lowest_prize));
            } else if (choice.request_kind == Kind::select_retreat_payment) {
                return retreat_payment_response(state, pending, response);
            } else if (choice.request_kind == Kind::confirm_trigger) {
                selected_ids.emplace_back(choice.options.front().option_id);
            } else if (choice.request_kind == Kind::confirm) {
                const ptcg::ai::Value *presentation = pending.find(
                    "presentation");
                static const ptcg::ai::Value empty =
                    ptcg::ai::Value::make_object();
                const ptcg::ai::Value &view = presentation != nullptr
                    && presentation->is_object() ? *presentation : empty;
                const std::string purpose = string_field(view, "purpose");
                if (
                    purpose == "trekking_shoes"
                    || !string_field(view, "top_card_id").empty()
                    || purpose == "confirm_switch"
                    || purpose == "search_any_switch_confirm"
                    || purpose == "switch"
                ) {
                    return false;
                }
                bool confirmed = true;
                if (purpose == "heal") {
                    confirmed = false;
                    const std::int32_t actor = choice.player;
                    const ptcg::ai::Value *players = state.find("players");
                    if (
                        players != nullptr && players->is_array()
                        && actor >= 0
                        && static_cast<std::size_t>(actor)
                            < players->as_array().size()
                    ) {
                        const ptcg::ai::Value &owner = players->as_array()[
                            static_cast<std::size_t>(actor)];
                        const ptcg::ai::Value *active = owner.find("active");
                        confirmed = active != nullptr && active->is_object()
                            && integer_field(*active, "damage_counters") > 0;
                        const ptcg::ai::Value *bench = owner.find("bench");
                        if (!confirmed && bench != nullptr && bench->is_array()) {
                            confirmed = std::any_of(
                                bench->as_array().begin(),
                                bench->as_array().end(),
                                [](const ptcg::ai::Value &pokemon) {
                                    return pokemon.is_object()
                                        && integer_field(
                                            pokemon, "damage_counters") > 0;
                                });
                        }
                    }
                }
                selected_ids.emplace_back(
                    confirmed ? "confirm:yes" : "confirm:no");
            } else {
                return false;
            }
        }
        response = ptcg::ai::Value(ptcg::ai::Value::Object{
            {"request_id", ptcg::ai::Value(choice.request_id)},
            {"option_ids", ptcg::ai::Value(std::move(selected_ids))},
            {"cancelled", ptcg::ai::Value(cancelled)},
        });
        return true;
    }

    bool retreat_payment_response(
        const ptcg::ai::Value &state,
        const ptcg::ai::Value &pending,
        ptcg::ai::Value &response
    ) const {
        const ptcg::ai::Value *presentation = pending.find("presentation");
        const std::int64_t required_units = std::max<std::int64_t>(
            0,
            presentation != nullptr && presentation->is_object()
                ? integer_field(*presentation, "required_units") : 0);
        ptcg::ai::Value::Array selected_ids;
        bool cancelled = false;
        const auto finish = [&]() {
            response = ptcg::ai::Value(ptcg::ai::Value::Object{
                {"request_id", ptcg::ai::Value(string_field(
                    pending, "request_id"))},
                {"option_ids", ptcg::ai::Value(std::move(selected_ids))},
                {"cancelled", ptcg::ai::Value(cancelled)},
            });
            return true;
        };
        if (required_units <= 0) return finish();
        const std::int32_t actor = static_cast<std::int32_t>(integer_field(
            pending, "player", -1));
        const ptcg::ai::Value *players = state.find("players");
        if (
            actor < 0 || actor > 1 || players == nullptr
            || !players->is_array()
            || static_cast<std::size_t>(actor) >= players->as_array().size()
        ) {
            cancelled = bool_field(pending, "can_cancel");
            return finish();
        }
        const ptcg::ai::Value &owner = players->as_array()[
            static_cast<std::size_t>(actor)];
        const ptcg::ai::Value *active = owner.find("active");
        const ptcg::ai::Value *energy_value = active != nullptr
            && active->is_object() ? active->find("energy_card_ids") : nullptr;
        if (energy_value == nullptr || !energy_value->is_array()) {
            cancelled = bool_field(pending, "can_cancel");
            return finish();
        }
        const ptcg::ai::Value::Array &energy_ids = energy_value->as_array();
        const ptcg::ai::Value *options_value = pending.find("options");
        if (options_value == nullptr || !options_value->is_array()) {
            cancelled = bool_field(pending, "can_cancel");
            return finish();
        }
        struct Candidate {
            std::string option_id;
            std::int64_t units = 0;
            std::int64_t attachment_index = -1;
            std::size_t option_order = 0;
        };
        std::vector<Candidate> candidates;
        const auto &options = options_value->as_array();
        candidates.reserve(options.size());
        for (std::size_t order = 0; order < options.size(); ++order) {
            const ptcg::ai::Value *ref = options[order].find("ref");
            if (ref == nullptr || !ref->is_object()) continue;
            const std::int64_t index = integer_field(*ref, "index", -1);
            if (
                string_field(*ref, "kind") != "attachment"
                || string_field(*ref, "attachment_type") != "energy"
                || integer_field(*ref, "player", -1) != actor
                || string_field(*ref, "slot") != "active"
                || index < 0
                || static_cast<std::size_t>(index) >= energy_ids.size()
                || string_field(*ref, "card_id")
                    != energy_ids[static_cast<std::size_t>(index)].string_or()
            ) continue;
            const std::int64_t units = energy_units_provided_by_card(
                energy_ids, static_cast<std::size_t>(index));
            if (units <= 0) continue;
            candidates.push_back(Candidate{
                string_field(options[order], "option_id"),
                units,
                index,
                order,
            });
        }
        std::stable_sort(
            candidates.begin(), candidates.end(),
            [](const Candidate &left, const Candidate &right) {
                if (left.units != right.units) return left.units > right.units;
                if (left.attachment_index != right.attachment_index) {
                    return left.attachment_index < right.attachment_index;
                }
                return left.option_order < right.option_order;
            });
        std::vector<Candidate> selected;
        std::int64_t paid_units = 0;
        for (const Candidate &candidate : candidates) {
            selected.push_back(candidate);
            paid_units += candidate.units;
            if (paid_units >= required_units) break;
        }
        if (paid_units < required_units) {
            cancelled = bool_field(pending, "can_cancel");
            return finish();
        }
        for (std::size_t cursor = selected.size(); cursor > 0; --cursor) {
            const std::size_t index = cursor - 1;
            if (paid_units - selected[index].units >= required_units) {
                paid_units -= selected[index].units;
                selected.erase(selected.begin() + static_cast<std::ptrdiff_t>(
                    index));
            }
        }
        selected_ids.reserve(selected.size());
        for (const Candidate &candidate : selected) {
            selected_ids.emplace_back(candidate.option_id);
        }
        return finish();
    }

    std::int64_t energy_units_provided_by_card(
        const ptcg::ai::Value::Array &attached,
        std::size_t index
    ) const {
        if (index >= attached.size()) return 0;
        const ptcg::ai::Value *definition = cards_.find(
            attached[index].string_or());
        if (definition == nullptr || !definition->is_object()) return 0;
        const ptcg::ai::Value *provided = definition->find("provides_energy");
        if (provided == nullptr || !provided->is_array()) return 0;
        // Downgrading a Rainbow unit to Colorless does not change how many
        // retreat units the physical Energy card provides.
        return static_cast<std::int64_t>(provided->as_array().size());
    }

    static std::string utf8(const String &value) {
        const CharString bytes = value.utf8();
        return std::string(bytes.get_data(), bytes.length());
    }

    static std::string string_field(
        const ptcg::ai::Value &value,
        const char *key,
        const std::string &fallback = {}
    ) {
        const ptcg::ai::Value *found = value.find(key);
        return found == nullptr ? fallback : found->string_or(fallback);
    }

    static std::int64_t integer_field(
        const ptcg::ai::Value &value,
        const char *key,
        std::int64_t fallback = 0
    ) {
        const ptcg::ai::Value *found = value.find(key);
        return found == nullptr ? fallback : found->as_integer(fallback);
    }

    static bool bool_field(
        const ptcg::ai::Value &value,
        const char *key,
        bool fallback = false
    ) {
        const ptcg::ai::Value *found = value.find(key);
        return found == nullptr ? fallback : found->as_bool(fallback);
    }

    Dictionary call_dictionary(
        const String &method,
        const Dictionary &payload
    ) const {
        if (!provider_.is_valid()) return Dictionary();
        const Variant value = provider_.call(method, payload);
        return value.get_type() == Variant::DICTIONARY
            ? Dictionary(value) : Dictionary();
    }

    Callable provider_;
    ptcg::ai::Value catalog_;
    ptcg::ai::Value cards_ = ptcg::ai::Value::make_object();
    ptcg::ai::Value decks_;
    ptcg::ai::TraditionalPositionEvaluator evaluator_;
    ptcg::ai::TraditionalStrategyCatalog strategy_catalog_;
    ptcg::ai::TraditionalTrustedEvaluator trusted_evaluator_;
    const ptcg::ai::TraditionalInformationSet *information_set_ = nullptr;
    std::int32_t root_actor_ = -1;
    bool debug_trajectory_ = false;
    bool strict_native_choices_ = false;
    std::vector<std::string> debug_trajectory_events_;
    Dictionary first_rank_mismatch_;
    Dictionary first_state_score_mismatch_;
    Dictionary first_choice_mismatch_;
    Dictionary debug_actions_by_signature_;
    mutable std::mutex debug_state_mutex_;
    std::map<std::string, ptcg::ai::Value> debug_states_by_fingerprint_;
    std::atomic<std::uint64_t> determinizations_{0};
    std::atomic<std::uint64_t> ranked_queries_{0};
    std::atomic<std::uint64_t> state_score_queries_{0};
    std::atomic<std::uint64_t> choice_resolutions_{0};
    std::atomic<std::uint64_t> native_forced_choice_resolutions_{0};
    std::atomic<std::uint64_t> native_choice_resolutions_{0};
    std::atomic<std::uint64_t> provider_callbacks_{0};
    std::atomic<std::uint64_t> action_score_callbacks_{0};
    std::atomic<std::uint64_t> native_trusted_action_scores_{0};
    std::atomic<std::uint64_t> oracle_trusted_action_scores_{0};
    std::atomic<std::uint64_t> choice_callbacks_{0};
    std::atomic<std::uint64_t> simulated_action_score_calls_{0};
    bool trusted_leaf_enabled_ = false;
    bool trusted_action_enabled_ = false;
};

} // namespace

std::unique_ptr<NativeTraditionalSearchProvider>
make_native_traditional_search_provider(
    Callable provider,
    ptcg::ai::Value catalog,
    ptcg::ai::Value decks,
    ptcg::ai::Value strategies,
    std::int32_t root_actor,
    const ptcg::ai::TraditionalInformationSet *information_set,
    bool debug_trajectory,
    bool strict_native_choices
) {
    return std::make_unique<NativeTraditionalSearchProviderImpl>(
        std::move(provider),
        std::move(catalog),
        std::move(decks),
        std::move(strategies),
        root_actor,
        information_set,
        debug_trajectory,
        strict_native_choices
    );
}

} // namespace godot
