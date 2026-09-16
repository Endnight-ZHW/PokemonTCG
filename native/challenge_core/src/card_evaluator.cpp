#include "card_evaluator.hpp"

#include "card_evaluation_detail.hpp"
#include "deck_policy_registry.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <optional>
#include <string>
#include <vector>

namespace ptcg::ai {

using namespace card_evaluation;

CardEvaluator::CardEvaluator(Value catalog, Value decks, const DeckPolicyRegistry &strategies)
    : policies_(strategies), decks_(std::move(decks)) {
    const Value *cards = catalog.find("cards");
    Value card_rows = cards != nullptr && cards->is_object() ? *cards : std::move(catalog);
    cards_ = Value(Value::Object{
        {"cards", std::move(card_rows)},
        {"deck_plans", strategies.deck_plan_profiles()},
    });
}

std::optional<double> CardEvaluator::action_score(const RulesSession &position, std::int32_t actor,
                                                  const Value &action) const {
    const auto base = semantic_action_score(position, actor, action);
    if (!base)
        return base;
    return *base + policies_.policy_for(deck_key(position.search_state(), actor))
                       .action_bonus(position, actor, action, cards_);
}

double CardEvaluator::leaf_score(const RulesSession &position, std::int32_t perspective) const {
    if (perspective != 0 && perspective != 1)
        return 0.0;
    const Value &state = position.search_state();
    return player_score(position, state, perspective, cards_, decks_) -
           player_score(position, state, 1 - perspective, cards_, decks_);
}

std::optional<double> CardEvaluator::semantic_action_score(const RulesSession &position,
                                                           std::int32_t actor,
                                                           const Value &action) const {
    if (actor != 0 && actor != 1)
        return std::nullopt;
    const Value &state = position.search_state();
    const std::string kind = string_field(action, "kind");
    const Value &owner = player(state, actor);
    if (kind == "END_TURN")
        return -220.0;
    if (kind == "SETUP_DONE") {
        return bench_count(owner) < 2 ? -30.0 : 0.0;
    }
    if (kind != "PLAY_BASIC" && kind != "EVOLVE" && kind != "ATTACH_ENERGY" &&
        kind != "PLAY_TRAINER" && kind != "USE_ABILITY" && kind != "USE_STADIUM" &&
        kind != "PROMOTE" && kind != "RETREAT" && kind != "DECLARE_ATTACK")
        return std::nullopt;

    const Value *source = field(action, "source");
    const Value *target = field(action, "target");
    const std::string card_id =
        source != nullptr ? string_field(*source, "card_id") : std::string{};
    const std::string target_slot =
        target != nullptr ? string_field(*target, "slot") : std::string{};
    const std::string key = deck_key(state, actor);
    const DeckProfile deck = profile(cards_, key);
    if (kind == "PLAY_TRAINER") {
        const Value *definition = card(cards_, card_id);
        if (definition == nullptr)
            return std::nullopt;
        const std::optional<double> tactical = simple_effects_tactical_value(
            position, state, actor, array_field(*definition, "trainer_effects"), "active", key,
            cards_, decks_);
        if (!tactical.has_value())
            return std::nullopt;
        double development = *tactical;
        if (deck.contains("trainer", card_id))
            development += 45.0;
        double score = card_priority(cards_, card_id, key) + 160.0;
        if (development > 0.0) {
            score += development * 0.75;
        } else {
            score -= 360.0;
            score += std::max(-260.0, development * 0.35);
        }
        return score;
    }
    if (kind == "USE_ABILITY") {
        const Value *payload = field(action, "payload");
        const std::string ability_name = payload != nullptr && payload->is_object()
                                             ? string_field(*payload, "ability_name")
                                             : std::string{};
        std::string source_slot = source != nullptr ? string_field(*source, "slot") : std::string{};
        if (source_slot.empty())
            source_slot = target_slot.empty() ? "active" : target_slot;
        const Value *pokemon = pokemon_at(owner, source_slot);
        const std::string resolved_card_id =
            pokemon == nullptr ? std::string{} : string_field(*pokemon, "card_id");
        const Value *definition = card(cards_, resolved_card_id);
        if (pokemon == nullptr || definition == nullptr || ability_name.empty()) {
            return card_priority(cards_, card_id, key) - 220.0;
        }
        const Value *ability = nullptr;
        for (const Value &candidate : array_field(*definition, "abilities")) {
            if (string_field(candidate, "name") == ability_name) {
                ability = &candidate;
                break;
            }
        }
        if (ability == nullptr) {
            // A discard-origin ability has no matching board ability here.
            return card_priority(cards_, card_id, key) - 220.0;
        }
        const std::optional<double> tactical =
            simple_effects_tactical_value(position, state, actor, array_field(*ability, "effects"),
                                          source_slot, key, cards_, decks_);
        if (!tactical.has_value())
            return std::nullopt;
        double development = 65.0 + *tactical;

        double score = card_priority(cards_, card_id, key);
        if (development > 0.0) {
            score += 190.0 + development * 0.75;
        } else {
            score -= 220.0;
        }
        if (string_field(*ability, "trigger") == "repeatable") {
            const auto &log = array_field(state, "action_log");
            const std::string player_name = string_field(owner, "name");
            const std::string canonical = player_name + " 使用了特性「" + ability_name + "」。";
            const std::size_t start = log.size() > 6 ? log.size() - 6 : 0;
            for (std::size_t index = start; index < log.size(); ++index) {
                const std::string entry = log[index].string_or();
                if (entry == canonical) {
                    score -= 650.0;
                    break;
                }
            }
        }
        return score;
    }
    if (kind == "USE_STADIUM") {
        const std::string stadium_id = string_field(state, "stadium_card_id");
        const Value *definition = card(cards_, stadium_id);
        if (definition == nullptr)
            return std::nullopt;
        const std::optional<double> tactical = simple_effects_tactical_value(
            position, state, actor, array_field(*definition, "trainer_effects"), "active", key,
            cards_, decks_);
        if (!tactical.has_value())
            return std::nullopt;
        double score = card_priority(cards_, card_id, key);
        if (*tactical > 0.0)
            score += 190.0 + *tactical * 0.75;
        else
            score -= 220.0;
        return score;
    }
    if (kind == "ATTACH_ENERGY") {
        const Value *target_pokemon = pokemon_at(owner, target_slot);
        if (target_pokemon == nullptr || card_id.empty() || !is_energy(cards_, card_id))
            return std::nullopt;
        const std::int64_t before = best_missing(cards_, target_pokemon);
        const Value probe = pokemon_with_extra_energy(*target_pokemon, card_id);
        const std::int64_t after = best_missing(cards_, &probe);
        const std::int64_t progress = std::max<std::int64_t>(0, before - after);
        const std::int64_t damage_ceiling = best_pokemon_damage_for_state(
            position, state, actor, *target_pokemon, target_slot, cards_);
        const std::int64_t ready_damage_after =
            best_ready_damage_for_pokemon(position, state, actor, probe, target_slot, cards_);
        const std::int64_t power_before = high_impact_missing_energy(
            position, state, actor, *target_pokemon, target_slot, {}, cards_);
        const std::int64_t power_after = high_impact_missing_energy(
            position, state, actor, *target_pokemon, target_slot, card_id, cards_);
        const std::int64_t power_progress = std::max<std::int64_t>(0, power_before - power_after);

        double development = static_cast<double>(progress) * 95.0;
        if (before > 0 && after == 0) {
            development += ready_damage_after <= 0 && power_after > 0
                               ? 65.0
                               : 175.0 + static_cast<double>(damage_ceiling) * 0.25;
        } else if (before > 1 && after == 1) {
            development += 70.0;
        }
        if (damage_ceiling >= deck.high_impact_damage_floor() && power_progress > 0) {
            development += static_cast<double>(power_progress) * 120.0;
            if (power_after == 0) {
                development += 190.0 + static_cast<double>(damage_ceiling) * 0.25;
            } else if (power_after == 1) {
                development += 135.0;
            }
        }
        if (deck.contains("core", string_field(*target_pokemon, "card_id"))) {
            development += 85.0;
        }
        development += energy_plan_target_bonus(position, state, actor, *target_pokemon,
                                                target_slot, card_id, key, cards_);
        if (target_slot == "active") {
            development += 35.0;
            if (before > 0)
                development += 55.0;
            if (has_better_bench_energy_plan(position, state, actor, card_id, key, cards_)) {
                development -= 135.0;
            }
        } else if (before > 0 && after == 0) {
            development += 35.0;
        }
        if (energy_matches_profile(cards_, card_id, key))
            development += 45.0;
        if (before == 0 && progress == 0 && power_progress == 0) {
            development -= 85.0;
            if (!deck.contains("core", string_field(*target_pokemon, "card_id"))) {
                development -= 45.0;
            }
        }
        if (target_slot == "active") {
            const std::int64_t opponent_damage =
                best_deterministic_available_damage(position, state, 1 - actor, cards_);
            if (opponent_damage >= position.pokemon_current_hp(*target_pokemon)) {
                const std::int64_t units_before = energy_unit_count(cards_, target_pokemon);
                const std::int64_t units_after = energy_unit_count(cards_, &probe);
                const Value *target_definition =
                    card(cards_, string_field(*target_pokemon, "card_id"));
                const std::int64_t retreat_cost =
                    target_definition == nullptr
                        ? 0
                        : integer_field(*target_definition, "retreat_cost");
                const bool unlocks_attack = before > 0 && after == 0;
                const bool unlocks_retreat =
                    units_before < retreat_cost && units_after >= retreat_cost;
                if (!unlocks_attack && !unlocks_retreat)
                    development -= 520.0;
            }
        }
        double score = card_priority(cards_, card_id, key) + 220.0;
        if (target_slot == "active")
            score += 40.0;
        score += development * 0.8;
        return score;
    }
    if (kind == "PROMOTE") {
        const Value *candidate = pokemon_at(owner, target_slot);
        return candidate == nullptr
                   ? std::nullopt
                   : std::optional<double>(promotion_value(position, state, actor, *candidate,
                                                           target_slot, key, cards_));
    }
    if (kind == "RETREAT") {
        const Value *active_pokemon = field(owner, "active");
        const Value *candidate = pokemon_at(owner, target_slot);
        if (active_pokemon == nullptr || !active_pokemon->is_object() || candidate == nullptr ||
            target_slot.rfind("bench_", 0) != 0)
            return std::nullopt;
        double score = card_priority(cards_, card_id, key) + 70.0;
        if (redundant_same_pokemon_retreat(position, state, actor, *active_pokemon, *candidate,
                                           target_slot, key, cards_)) {
            score -= 1800.0;
        } else if (retreat_has_good_target(position, state, actor, *active_pokemon, *candidate,
                                           target_slot, key, cards_)) {
            score += 180.0;
        } else {
            score -= 420.0;
        }
        score += static_cast<double>(printed_best_damage(cards_, candidate) -
                                     printed_best_damage(cards_, active_pokemon)) *
                 1.3;
        return score;
    }
    if (kind == "DECLARE_ATTACK") {
        const Value *definition = card(cards_, card_id);
        const Value *payload = field(action, "payload");
        const std::int64_t attack_index = payload != nullptr && payload->is_object()
                                              ? integer_field(*payload, "attack_index", -1)
                                              : -1;
        const auto &attacks =
            definition == nullptr ? Value::Array{} : array_field(*definition, "attacks");
        if (attack_index < 0 || static_cast<std::size_t>(attack_index) >= attacks.size()) {
            return std::nullopt;
        }
        const auto &attack_effects =
            array_field(attacks[static_cast<std::size_t>(attack_index)], "effects");
        const std::optional<double> tactical_value = simple_effects_tactical_value(
            position, state, actor, attack_effects, "active", key, cards_, decks_);
        if (!tactical_value.has_value())
            return std::nullopt;
        const Value *opponent_active = active(state, 1 - actor);
        const std::int64_t damage = estimated_attack_damage(
            position, state, actor, static_cast<std::size_t>(attack_index), cards_);
        const double tactical = *tactical_value;
        double score = card_priority(cards_, card_id, key) + 360.0 +
                       static_cast<double>(damage) * 3.4 + tactical;
        if (opponent_active != nullptr && damage >= position.pokemon_current_hp(*opponent_active))
            score += 900.0;
        else if (damage <= 30 && tactical <= 0.0)
            score -= 260.0;
        if (attack_draw_pressure_is_unsafe(state, actor, attack_effects)) {
            score -= 450.0;
        }
        if (attack_feeds_dangerous_retaliation(position, state, actor, damage, cards_))
            score -= 420.0;
        return score;
    }
    if (card_id.empty())
        return std::nullopt;
    if (kind == "EVOLVE") {
        const std::string source_kind =
            source != nullptr ? string_field(*source, "kind") : std::string{};
        const std::string source_slot =
            source_kind == "pokemon" || source_kind == "slot" || source_kind == "attachment"
                ? string_field(*source, "slot")
                : std::string{};
        const std::string evolve_slot = source_slot.empty() ? target_slot : source_slot;
        const Value *evolve_target = pokemon_at(owner, evolve_slot);
        const Value *evolved_definition = card(cards_, card_id);
        if (evolve_target == nullptr || evolved_definition == nullptr) {
            return std::nullopt;
        }
        const std::int64_t energy_count = energy_unit_count(cards_, evolve_target);
        const double evolved_strength =
            static_cast<double>(integer_field(*evolved_definition, "hp")) +
            static_cast<double>(
                action_strength_damage(cards_, *evolved_definition, nullptr, energy_count)) *
                2.0 +
            static_cast<double>(energy_count) * 35.0;
        const Value *current_definition = card(cards_, string_field(*evolve_target, "card_id"));
        if (current_definition == nullptr)
            return std::nullopt;
        const double current_strength =
            static_cast<double>(position.pokemon_current_hp(*evolve_target)) +
            static_cast<double>(
                action_strength_damage(cards_, *current_definition, evolve_target, energy_count)) *
                2.0 +
            static_cast<double>(energy_count) * 35.0;
        double development = 145.0 + std::max(0.0, evolved_strength - current_strength) * 0.75;
        if (deck.contains("core", card_id))
            development += 95.0;
        if (deck.contains("evolution", card_id))
            development += 70.0;
        if (evolve_slot == "active") {
            development -= active_evolve_blocking_penalty(position, state, actor, *evolve_target,
                                                          card_id, key, cards_, decks_);
        }
        return card_priority(cards_, card_id, key) + 320.0 + development * 0.7;
    }
    double score = card_priority(cards_, card_id, key) + 180.0;
    if (target_slot == "active") {
        score += 200.0;

        if (deck.contains("bench", card_id) && !deck.contains("setup", card_id)) {
            const bool has_alternative =
                std::any_of(array_field(owner, "hand").begin(), array_field(owner, "hand").end(),
                            [&](const Value &entry) {
                                const std::string candidate = entry.string_or();
                                return candidate != card_id &&
                                       is_basic_pokemon(cards_, candidate) &&
                                       deck.contains("setup", candidate);
                            });
            if (has_alternative)
                score -= 260.0;
        }
    }
    if (deck.contains("setup", card_id)) {
        score += 160.0;
    } else if (target_slot != "active" && deck.contains("bench", card_id)) {
        score += 70.0;
    }

    double development = 0.0;
    if (bench_count(owner) < 5) {
        development = 90.0 + card_priority(cards_, card_id, key) * 0.7;
        if (bench_count(owner) < 2)
            development += 70.0;
        if (deck.contains("setup", card_id))
            development += 80.0;
        if (target_slot != "active" && deck.contains("bench", card_id)) {
            development += 70.0;
        }
    }
    score += development * 0.5;
    return score;
}

std::optional<double> CardEvaluator::choice_option_score(const RulesSession &position,
                                                         std::int32_t actor, const Value &choice,
                                                         const Value &option) const {
    const auto base = base_choice_option_score(position, position.search_state(), actor, choice,
                                               option, cards_, decks_);
    if (!base)
        return base;
    return *base + policies_.policy_for(deck_key(position.search_state(), actor))
                       .choice_bonus(position, actor, choice, option, cards_);
}

std::optional<bool> CardEvaluator::confirm_choice(const RulesSession &position, std::int32_t actor,
                                                  const Value &choice_view) const {
    const auto opinion = policies_.policy_for(deck_key(position.search_state(), actor))
                             .confirm_choice(position, actor, choice_view, cards_);
    if (opinion.has_value())
        return opinion;

    if (actor != 0 && actor != 1)
        return std::nullopt;
    const Value &state = position.search_state();
    const Value *presentation_value = field(choice_view, "presentation");
    static const Value empty = Value::make_object();
    const Value &presentation = presentation_value != nullptr && presentation_value->is_object()
                                    ? *presentation_value
                                    : empty;
    const std::string purpose = string_field(presentation, "purpose");
    const std::string key = deck_key(state, actor);
    if (purpose == "trekking_shoes" || !string_field(presentation, "top_card_id").empty()) {
        std::string card_id =
            string_field(presentation, "top_card_id", string_field(presentation, "card_id"));
        if (card_id.empty()) {
            const auto &deck = array_field(player(state, actor), "deck");
            if (!deck.empty())
                card_id = deck.back().string_or();
        }
        if (card_id.empty())
            return false;
        const DeckProfile deck = profile(cards_, key);
        if (deck.contains("core", card_id) || deck.contains("evolution", card_id) ||
            deck.contains("engine", card_id))
            return true;
        if (is_energy(cards_, card_id) && has_energy_target(state, actor, cards_)) {
            return true;
        }
        return card_keep_value(position, state, actor, card_id, key, cards_, decks_) >= 55.0;
    }
    const auto switch_self_has_good_target = [&](std::int32_t chooser) {
        const Value *active_pokemon = active(state, chooser);
        if (active_pokemon == nullptr)
            return false;
        const auto &bench = array_field(player(state, chooser), "bench");
        for (std::size_t index = 0; index < bench.size(); ++index) {
            if (!bench[index].is_object())
                continue;
            const std::string slot = "bench_" + std::to_string(index);
            if (retreat_has_good_target(position, state, chooser, *active_pokemon, bench[index],
                                        slot, deck_key(state, chooser), cards_))
                return true;
        }
        return false;
    };
    const auto switch_opponent_has_good_target = [&](std::int32_t chooser,
                                                     std::int32_t target_player) {
        const Value *target_active = active(state, target_player);
        const auto &bench = array_field(player(state, target_player), "bench");
        if (target_active == nullptr || bench.empty())
            return false;
        const double active_priority = tactical_target_priority(position, *target_active, cards_);
        double best = -std::numeric_limits<double>::infinity();
        for (const Value &pokemon : bench) {
            if (pokemon.is_object())
                best = std::max(best, tactical_target_priority(position, pokemon, cards_));
        }
        if (!std::isfinite(best) || best <= active_priority + 20.0)
            return false;
        if (active(state, chooser) != nullptr &&
            best_available_damage(position, state, chooser, cards_) >=
                position.pokemon_current_hp(*target_active))
            return false;
        return true;
    };
    if (purpose == "confirm_switch" || purpose == "search_any_switch_confirm") {
        const std::int32_t chooser =
            static_cast<std::int32_t>(integer_field(presentation, "source_player", actor));
        const std::int32_t target_player =
            static_cast<std::int32_t>(integer_field(presentation, "target_player", actor));
        return target_player == chooser ? switch_self_has_good_target(chooser)
                                        : switch_opponent_has_good_target(chooser, target_player);
    }
    if (purpose == "switch")
        return switch_self_has_good_target(actor);
    if (purpose == "heal") {
        for (const Value *pokemon : board(state, actor)) {
            if (integer_field(*pokemon, "damage_counters") > 0)
                return true;
        }
        return false;
    }
    return true;
}

Value CardEvaluator::energy_target_prefix_plan(const RulesSession &position, std::int32_t actor,
                                               const Value &choice_view, const Value &option,
                                               std::int64_t max_count) const {
    Value result = Value::make_object();
    result["count"] = Value(max_count);
    result["gain"] = Value(0.0);
    if (actor != 0 && actor != 1 || max_count <= 0)
        return result;
    const Value *presentation_value = field(choice_view, "presentation");
    static const Value empty = Value::make_object();
    const Value &presentation = presentation_value != nullptr && presentation_value->is_object()
                                    ? *presentation_value
                                    : empty;
    if (!bool_field(choice_view, "allow_duplicates") || !bool_field(presentation, "same_target"))
        return result;
    const Value &state = position.search_state();
    const std::int32_t target_player = choice_option_player(option, actor);
    const std::string slot = choice_option_slot(option);
    const Value *pokemon = pokemon_at(player(state, target_player), slot);
    if (pokemon == nullptr)
        return result;
    std::vector<std::string> energy_ids;
    for (const Value &entry : array_field(presentation, "card_ids")) {
        if (is_energy(cards_, entry.string_or())) {
            energy_ids.push_back(entry.string_or());
        }
    }
    const std::string fallback = choice_energy_card_id(presentation, cards_);
    if (energy_ids.empty() && !fallback.empty())
        energy_ids.push_back(fallback);
    if (energy_ids.empty())
        return result;
    const std::string key = deck_key(state, target_player);
    const double baseline = energy_attack_plan_utility(position, state, target_player, *pokemon,
                                                       slot, key, cards_, decks_);
    double best = baseline;
    std::int64_t best_count = 0;
    Value probe = *pokemon;
    for (std::int64_t prefix = 0; prefix < max_count; ++prefix) {
        const std::string &energy_id = energy_ids[static_cast<std::size_t>(
            std::min<std::int64_t>(prefix, static_cast<std::int64_t>(energy_ids.size()) - 1))];
        if (energy_id.empty() || !is_energy(cards_, energy_id))
            break;
        Value *attached = probe.find("energy_card_ids");
        if (attached == nullptr || !attached->is_array()) {
            probe["energy_card_ids"] = Value::make_array();
            attached = probe.find("energy_card_ids");
        }
        attached->as_array().emplace_back(energy_id);
        const std::int64_t count = prefix + 1;
        const double utility = energy_attack_plan_utility(position, state, target_player, probe,
                                                          slot, key, cards_, decks_) -
                               static_cast<double>(count) * 25.0;
        if (utility > best + 0.001) {
            best = utility;
            best_count = count;
        }
    }
    result["count"] = Value(best_count);
    result["gain"] = Value(std::max(0.0, best - baseline));
    return result;
}

double CardEvaluator::energy_distribution_board_utility(const RulesSession &position,
                                                        std::int32_t actor) const {
    return actor == 0 || actor == 1 ? public_energy_distribution_board_utility(
                                          position, position.search_state(), actor, cards_)
                                    : 0.0;
}

} // namespace ptcg::ai
