#include "ptcg_traditional_trusted.hpp"

#include "ptcg_traditional_trusted_choice.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <optional>
#include <string>
#include <vector>

namespace ptcg::ai {

using namespace traditional_trusted_detail;

TraditionalTrustedEvaluator::TraditionalTrustedEvaluator(Value catalog, Value decks)
    : decks_(std::move(decks)) {
    const Value *cards = catalog.find("cards");
    cards_ = cards != nullptr && cards->is_object() ? *cards : std::move(catalog);
}

double TraditionalTrustedEvaluator::leaf_score(
    const RulesSession &position,
    std::int32_t perspective
) const {
    if (perspective != 0 && perspective != 1) return 0.0;
    const Value &state = position.search_state();
    return player_score(position, state, perspective, cards_, decks_)
        - player_score(position, state, 1 - perspective, cards_, decks_);
}

std::optional<double> TraditionalTrustedEvaluator::action_score(
    const RulesSession &position,
    std::int32_t actor,
    const Value &action
) const {
    if (actor != 0 && actor != 1) return std::nullopt;
    const Value &state = position.search_state();
    if (bool_field(state, "apply_type_matchups")) return std::nullopt;
    const std::string kind = string_field(action, "kind");
    const Value &owner = player(state, actor);
    if (kind == "END_TURN") return -220.0;
    if (kind == "SETUP_DONE") {
        return bench_count(owner) < 2 ? -30.0 : 0.0;
    }
    if (
        kind != "PLAY_BASIC" && kind != "EVOLVE" && kind != "ATTACH_ENERGY"
        && kind != "PLAY_TRAINER" && kind != "USE_ABILITY"
        && kind != "USE_STADIUM"
        && kind != "PROMOTE" && kind != "RETREAT"
        && kind != "DECLARE_ATTACK"
    ) return std::nullopt;

    const Value *source = field(action, "source");
    const Value *target = field(action, "target");
    const std::string card_id = source != nullptr
        ? string_field(*source, "card_id") : std::string{};
    const std::string target_slot = target != nullptr
        ? string_field(*target, "slot") : std::string{};
    const std::string key = deck_key(state, actor);
    const DeckProfile &deck = profile(key);
    if (kind == "PLAY_TRAINER") {
        const Value *definition = card(cards_, card_id);
        if (definition == nullptr) return std::nullopt;
        const std::optional<double> tactical = simple_effects_tactical_value(
            position, state, actor, array_field(*definition, "trainer_effects"),
            "active", key, cards_, decks_);
        if (!tactical.has_value()) return std::nullopt;
        double development = *tactical;
        if (contains(deck.trainer, card_id)) development += 45.0;
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
        const std::string ability_name = payload != nullptr
            && payload->is_object()
            ? string_field(*payload, "ability_name") : std::string{};
        std::string source_slot = source != nullptr
            ? string_field(*source, "slot") : std::string{};
        if (source_slot.empty()) source_slot = target_slot.empty()
            ? "active" : target_slot;
        const Value *pokemon = pokemon_at(owner, source_slot);
        const std::string resolved_card_id = pokemon == nullptr
            ? std::string{} : string_field(*pokemon, "card_id");
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
            // GameAction.primary_slot("active") resolves a discard-origin
            // ability against the current Active. The frozen GDScript scorer
            // therefore sees no matching board ability and assigns zero
            // development instead of evaluating the discard card metadata.
            return card_priority(cards_, card_id, key) - 220.0;
        }
        const std::optional<double> tactical = simple_effects_tactical_value(
            position, state, actor, array_field(*ability, "effects"),
            source_slot, key, cards_, decks_);
        if (!tactical.has_value()) return std::nullopt;
        double development = 65.0 + *tactical;
        if (resolved_card_id == "sv2-starm") {
            development += starmie_torrent_followup_value(
                position, state, actor, source_slot, cards_);
        }
        double score = card_priority(cards_, card_id, key);
        if (development > 0.0) {
            score += 190.0 + development * 0.75;
        } else {
            score -= 220.0;
        }
        if (string_field(*ability, "trigger") == "repeatable") {
            const auto &log = array_field(state, "action_log");
            const std::string player_name = string_field(owner, "name");
            const std::string card_name = string_field(*definition, "name");
            const std::string canonical = player_name
                + " 使用了特性「" + ability_name + "」。";
            const std::string legacy = card_name
                + "使用特性" + ability_name + "。";
            const std::string suffix = "使用特性" + ability_name + "。";
            const std::size_t start = log.size() > 6 ? log.size() - 6 : 0;
            for (std::size_t index = start; index < log.size(); ++index) {
                const std::string entry = log[index].string_or();
                const bool suffix_match = entry.size() >= suffix.size()
                    && entry.compare(
                        entry.size() - suffix.size(), suffix.size(), suffix) == 0;
                if (
                    entry == canonical
                    || (!card_name.empty() && entry == legacy)
                    || (card_name.empty() && suffix_match)
                ) {
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
        if (definition == nullptr) return std::nullopt;
        const std::optional<double> tactical = simple_effects_tactical_value(
            position, state, actor, array_field(*definition, "trainer_effects"),
            "active", key, cards_, decks_);
        if (!tactical.has_value()) return std::nullopt;
        double score = card_priority(cards_, card_id, key);
        if (*tactical > 0.0) score += 190.0 + *tactical * 0.75;
        else score -= 220.0;
        return score;
    }
    if (kind == "ATTACH_ENERGY") {
        const Value *target_pokemon = pokemon_at(owner, target_slot);
        if (
            target_pokemon == nullptr || card_id.empty()
            || !is_energy(cards_, card_id)
        ) return std::nullopt;
        const std::int64_t before = best_missing(cards_, target_pokemon);
        const Value probe = pokemon_with_extra_energy(*target_pokemon, card_id);
        const std::int64_t after = best_missing(cards_, &probe);
        const std::int64_t progress = std::max<std::int64_t>(0, before - after);
        const std::int64_t damage_ceiling = best_pokemon_damage_for_state(
            position, state, actor, *target_pokemon, target_slot, cards_);
        const std::int64_t ready_damage_after = best_ready_damage_for_pokemon(
            position, state, actor, probe, target_slot, cards_);
        const std::int64_t power_before = high_impact_missing_energy(
            position, state, actor, *target_pokemon,
            target_slot, {}, cards_);
        const std::int64_t power_after = high_impact_missing_energy(
            position, state, actor, *target_pokemon,
            target_slot, card_id, cards_);
        const std::int64_t power_progress = std::max<std::int64_t>(
            0, power_before - power_after);

        double development = static_cast<double>(progress) * 95.0;
        if (before > 0 && after == 0) {
            development += ready_damage_after <= 0 && power_after > 0
                ? 65.0
                : 175.0 + static_cast<double>(damage_ceiling) * 0.25;
        } else if (before > 1 && after == 1) {
            development += 70.0;
        }
        if (
            damage_ceiling >= deck.high_impact_damage_floor
            && power_progress > 0
        ) {
            development += static_cast<double>(power_progress) * 120.0;
            if (power_after == 0) {
                development += 190.0
                    + static_cast<double>(damage_ceiling) * 0.25;
            } else if (power_after == 1) {
                development += 135.0;
            }
        }
        if (contains(deck.core, string_field(*target_pokemon, "card_id"))) {
            development += 85.0;
        }
        development += energy_plan_target_bonus(
            position, state, actor, *target_pokemon, target_slot,
            card_id, key, cards_);
        if (target_slot == "active") {
            development += 35.0;
            if (before > 0) development += 55.0;
            if (has_better_bench_energy_plan(
                position, state, actor, card_id, key, cards_)) {
                development -= 135.0;
            }
        } else if (before > 0 && after == 0) {
            development += 35.0;
        }
        if (energy_matches_profile(cards_, card_id, key)) development += 45.0;
        if (before == 0 && progress == 0 && power_progress == 0) {
            development -= 85.0;
            if (!contains(deck.core, string_field(*target_pokemon, "card_id"))) {
                development -= 45.0;
            }
        }
        if (target_slot == "active") {
            const std::int64_t opponent_damage =
                best_deterministic_available_damage(
                    position, state, 1 - actor, cards_);
            if (opponent_damage >= position.pokemon_current_hp(*target_pokemon)) {
                const std::int64_t units_before = energy_unit_count(
                    cards_, target_pokemon);
                const std::int64_t units_after = energy_unit_count(cards_, &probe);
                const Value *target_definition = card(
                    cards_, string_field(*target_pokemon, "card_id"));
                const std::int64_t retreat_cost = target_definition == nullptr
                    ? 0 : integer_field(*target_definition, "retreat_cost");
                const bool unlocks_attack = before > 0 && after == 0;
                const bool unlocks_retreat = units_before < retreat_cost
                    && units_after >= retreat_cost;
                if (!unlocks_attack && !unlocks_retreat) development -= 520.0;
            }
        }
        double score = card_priority(cards_, card_id, key) + 220.0;
        if (target_slot == "active") score += 40.0;
        score += development * 0.8;
        return score;
    }
    if (kind == "PROMOTE") {
        const Value *candidate = pokemon_at(owner, target_slot);
        return candidate == nullptr ? std::nullopt
            : std::optional<double>(promotion_value(
                position, state, actor, *candidate,
                target_slot, key, cards_));
    }
    if (kind == "RETREAT") {
        const Value *active_pokemon = field(owner, "active");
        const Value *candidate = pokemon_at(owner, target_slot);
        if (
            active_pokemon == nullptr || !active_pokemon->is_object()
            || candidate == nullptr || target_slot.rfind("bench_", 0) != 0
        ) return std::nullopt;
        double score = card_priority(cards_, card_id, key) + 70.0;
        if (redundant_same_pokemon_retreat(
            position, state, actor, *active_pokemon,
            *candidate, target_slot, key, cards_)) {
            score -= 1800.0;
        } else if (retreat_has_good_target(
            position, state, actor, *active_pokemon,
            *candidate, target_slot, key, cards_)) {
            score += 180.0;
        } else {
            score -= 420.0;
        }
        score += static_cast<double>(
            printed_best_damage(cards_, candidate)
            - printed_best_damage(cards_, active_pokemon)) * 1.3;
        return score;
    }
    if (kind == "DECLARE_ATTACK") {
        const Value *definition = card(cards_, card_id);
        const Value *payload = field(action, "payload");
        const std::int64_t attack_index = payload != nullptr
            && payload->is_object()
            ? integer_field(*payload, "attack_index", -1) : -1;
        const auto &attacks = definition == nullptr
            ? Value::Array{} : array_field(*definition, "attacks");
        if (attack_index < 0
            || static_cast<std::size_t>(attack_index) >= attacks.size()) {
            return std::nullopt;
        }
        const auto &attack_effects = array_field(
            attacks[static_cast<std::size_t>(attack_index)], "effects");
        const std::optional<double> tactical_value =
            simple_effects_tactical_value(
                position, state, actor, attack_effects,
                "active", key, cards_, decks_);
        if (!tactical_value.has_value()) return std::nullopt;
        const Value *opponent_active = active(state, 1 - actor);
        const std::int64_t damage = estimated_attack_damage(
            position, state, actor,
            static_cast<std::size_t>(attack_index), cards_);
        const double tactical = *tactical_value;
        double score = card_priority(cards_, card_id, key) + 360.0
            + static_cast<double>(damage) * 3.4 + tactical;
        if (
            opponent_active != nullptr
            && damage >= position.pokemon_current_hp(*opponent_active)
        ) score += 900.0;
        else if (damage <= 30 && tactical <= 0.0) score -= 260.0;
        if (attack_draw_pressure_is_unsafe(state, actor, attack_effects)) {
            score -= 450.0;
        }
        if (attack_feeds_dangerous_retaliation(
            position, state, actor, damage, cards_)) score -= 420.0;
        return score;
    }
    if (card_id.empty()) return std::nullopt;
    if (kind == "EVOLVE") {
        const std::string source_kind = source != nullptr
            ? string_field(*source, "kind") : std::string{};
        const std::string source_slot = source_kind == "pokemon"
            || source_kind == "slot" || source_kind == "attachment"
            ? string_field(*source, "slot") : std::string{};
        const std::string evolve_slot = source_slot.empty()
            ? target_slot : source_slot;
        const Value *evolve_target = pokemon_at(owner, evolve_slot);
        const Value *evolved_definition = card(cards_, card_id);
        if (evolve_target == nullptr || evolved_definition == nullptr) {
            return std::nullopt;
        }
        const std::int64_t energy_count = energy_unit_count(
            cards_, evolve_target);
        const double evolved_strength = static_cast<double>(integer_field(
            *evolved_definition, "hp"))
            + static_cast<double>(action_strength_damage(
                cards_, *evolved_definition, nullptr, energy_count)) * 2.0
            + static_cast<double>(energy_count) * 35.0;
        const Value *current_definition = card(
            cards_, string_field(*evolve_target, "card_id"));
        if (current_definition == nullptr) return std::nullopt;
        const double current_strength = static_cast<double>(
            position.pokemon_current_hp(*evolve_target))
            + static_cast<double>(action_strength_damage(
                cards_, *current_definition, evolve_target, energy_count)) * 2.0
            + static_cast<double>(energy_count) * 35.0;
        double development = 145.0
            + std::max(0.0, evolved_strength - current_strength) * 0.75;
        if (contains(deck.core, card_id)) development += 95.0;
        if (contains(deck.evolution, card_id)) development += 70.0;
        if (evolve_slot == "active") {
            development -= active_evolve_blocking_penalty(
                position, state, actor, *evolve_target,
                card_id, key, cards_, decks_);
        }
        return card_priority(cards_, card_id, key) + 320.0
            + development * 0.7;
    }
    double score = card_priority(cards_, card_id, key) + 180.0;
    if (target_slot == "active") {
        score += 200.0;
        if (key == "water") {
            if (card_id == "sv2-tatsu"
                && actor != integer_field(state, "first_player_idx")) {
                score += 240.0;
            } else if (
                card_id == "sv2-staryu"
                && array_contains(array_field(owner, "hand"), "sv2-tatsu")
                && actor != integer_field(state, "first_player_idx")
            ) {
                score -= 180.0;
            }
        }
        if (contains(deck.bench, card_id) && !contains(deck.setup, card_id)) {
            const bool has_alternative = std::any_of(
                array_field(owner, "hand").begin(),
                array_field(owner, "hand").end(),
                [&](const Value &entry) {
                    const std::string candidate = entry.string_or();
                    return candidate != card_id
                        && is_basic_pokemon(cards_, candidate)
                        && contains(deck.setup, candidate);
                });
            if (has_alternative) score -= 260.0;
        }
    }
    if (contains(deck.setup, card_id)) {
        score += 160.0;
    } else if (target_slot != "active" && contains(deck.bench, card_id)) {
        score += 70.0;
    }

    double development = 0.0;
    if (bench_count(owner) < 5) {
        development = 90.0 + card_priority(cards_, card_id, key) * 0.7;
        if (bench_count(owner) < 2) development += 70.0;
        if (contains(deck.setup, card_id)) development += 80.0;
        if (target_slot != "active" && contains(deck.bench, card_id)) {
            development += 70.0;
        }
    }
    score += development * 0.5;
    return score;
}

double TraditionalTrustedEvaluator::raw_evaluation(
    const RulesSession &position,
    std::int32_t actor
) const {
    if (actor != 0 && actor != 1) return 0.0;
    const Value &state = position.search_state();
    const std::string status = string_field(state, "result_status", "ONGOING");
    if (status == "DRAW") return 0.0;
    const std::int64_t winner = integer_field(state, "winner", -1);
    if (winner >= 0) return winner == actor ? 1800.0 : -1800.0;
    const Value &own = player(state, actor);
    const Value &opponent = player(state, 1 - actor);
    double score = static_cast<double>(
        static_cast<std::int64_t>(array_field(opponent, "prizes").size())
        - static_cast<std::int64_t>(array_field(own, "prizes").size())) * 220.0;
    score += static_cast<double>(
        static_cast<std::int64_t>(array_field(own, "hand").size())
        - static_cast<std::int64_t>(array_field(opponent, "hand").size())) * 4.0;
    score += static_cast<double>(
        static_cast<std::int64_t>(array_field(own, "deck").size())
        - static_cast<std::int64_t>(array_field(opponent, "deck").size())) * 0.5;
    const auto pokemon_strength = [&](const Value &pokemon) {
        const Value *definition = card(
            cards_, string_field(pokemon, "card_id"));
        const std::int64_t strength_damage = definition == nullptr
            ? 0 : action_strength_damage(
                cards_, *definition, &pokemon,
                energy_unit_count(cards_, &pokemon));
        return static_cast<double>(position.pokemon_current_hp(pokemon))
            + static_cast<double>(strength_damage) * 2.0
            + static_cast<double>(energy_unit_count(cards_, &pokemon)) * 35.0;
    };
    for (const Value *pokemon : board(state, actor)) score += pokemon_strength(*pokemon);
    for (const Value *pokemon : board(state, 1 - actor)) score -= pokemon_strength(*pokemon);
    return score + leaf_score(position, actor);
}

std::optional<double> TraditionalTrustedEvaluator::development_action_value(
    const RulesSession &position,
    std::int32_t actor,
    const Value &action
) const {
    if (actor != 0 && actor != 1) return std::nullopt;
    const Value &state = position.search_state();
    const Value &owner = player(state, actor);
    const std::string kind = string_field(action, "kind");
    const Value *source = field(action, "source");
    const Value *target = field(action, "target");
    const std::string card_id = source != nullptr && source->is_object()
        ? string_field(*source, "card_id") : std::string{};
    const std::string target_slot = target != nullptr && target->is_object()
        ? string_field(*target, "slot") : std::string{};
    const std::string key = deck_key(state, actor);
    const DeckProfile &deck = profile(key);
    const std::optional<double> full_score = action_score(position, actor, action);
    if (!full_score.has_value()) return std::nullopt;
    const double priority = card_priority(cards_, card_id, key);
    if (kind == "ATTACH_ENERGY") {
        const double base = priority + 220.0
            + (target_slot == "active" ? 40.0 : 0.0);
        return (*full_score - base) / 0.8;
    }
    if (kind == "EVOLVE") {
        return (*full_score - priority - 320.0) / 0.7;
    }
    if (kind == "PLAY_BASIC") {
        if (card_id.empty() || bench_count(owner) >= 5) return 0.0;
        double value = 90.0 + priority * 0.7;
        if (bench_count(owner) < 2) value += 70.0;
        if (contains(deck.setup, card_id)) value += 80.0;
        if (target_slot != "active" && contains(deck.bench, card_id)) value += 70.0;
        return value;
    }
    if (kind == "PLAY_TRAINER") {
        const Value *definition = card(cards_, card_id);
        if (definition == nullptr) return std::nullopt;
        const std::optional<double> tactical = simple_effects_tactical_value(
            position, state, actor, array_field(*definition, "trainer_effects"),
            "active", key, cards_, decks_);
        if (!tactical.has_value()) return std::nullopt;
        return *tactical + (contains(deck.trainer, card_id) ? 45.0 : 0.0);
    }
    if (kind == "USE_ABILITY") {
        const Value *payload = field(action, "payload");
        const std::string ability_name = payload != nullptr && payload->is_object()
            ? string_field(*payload, "ability_name") : std::string{};
        std::string slot = source != nullptr && source->is_object()
            ? string_field(*source, "slot") : std::string{};
        if (slot.empty()) slot = target_slot.empty() ? "active" : target_slot;
        const Value *pokemon = pokemon_at(owner, slot);
        const std::string resolved_card_id = pokemon == nullptr
            ? std::string{} : string_field(*pokemon, "card_id");
        const Value *definition = card(cards_, resolved_card_id);
        if (pokemon == nullptr || definition == nullptr) return std::nullopt;
        for (const Value &ability : array_field(*definition, "abilities")) {
            if (string_field(ability, "name") != ability_name) continue;
            const std::optional<double> tactical = simple_effects_tactical_value(
                position, state, actor, array_field(ability, "effects"),
                slot, key, cards_, decks_);
            if (!tactical.has_value()) return std::nullopt;
            double value = 65.0 + *tactical;
            if (resolved_card_id == "sv2-starm") {
                value += starmie_torrent_followup_value(
                    position, state, actor, slot, cards_);
            }
            return value;
        }
        return 0.0;
    }
    if (kind == "USE_STADIUM") {
        const Value *definition = card(
            cards_, string_field(state, "stadium_card_id"));
        if (definition == nullptr) return std::nullopt;
        return simple_effects_tactical_value(
            position, state, actor, array_field(*definition, "trainer_effects"),
            "active", key, cards_, decks_);
    }
    return 0.0;
}

std::int64_t TraditionalTrustedEvaluator::action_estimated_damage(
    const RulesSession &position,
    std::int32_t actor,
    const Value &action
) const {
    if (actor != 0 && actor != 1 || string_field(action, "kind") != "DECLARE_ATTACK") {
        return 0;
    }
    const Value *payload = field(action, "payload");
    const std::int64_t index = payload != nullptr && payload->is_object()
        ? integer_field(*payload, "attack_index", -1) : -1;
    return index < 0 ? 0 : ptcg::ai::estimated_attack_damage(
        position,
        position.search_state(),
        actor,
        static_cast<std::size_t>(index),
        cards_);
}

std::int64_t TraditionalTrustedEvaluator::active_missing_energy(
    const RulesSession &position,
    std::int32_t actor
) const {
    return actor == 0 || actor == 1
        ? best_missing(cards_, active(position.search_state(), actor))
        : 99;
}

bool TraditionalTrustedEvaluator::deck_profile_contains(
    const RulesSession &position,
    std::int32_t actor,
    const std::string &role,
    const std::string &card_id
) const {
    if ((actor != 0 && actor != 1) || card_id.empty()) return false;
    const DeckProfile &deck = profile(deck_key(position.search_state(), actor));
    if (role == "core") return contains(deck.core, card_id);
    if (role == "engine") return contains(deck.engine, card_id);
    if (role == "setup") return contains(deck.setup, card_id);
    if (role == "bench") return contains(deck.bench, card_id);
    if (role == "evolution") return contains(deck.evolution, card_id);
    if (role == "trainer") return contains(deck.trainer, card_id);
    return false;
}

bool TraditionalTrustedEvaluator::attack_tactically_unsafe(
    const RulesSession &position,
    std::int32_t actor,
    const Value &action
) const {
    if ((actor != 0 && actor != 1)
        || string_field(action, "kind") != "DECLARE_ATTACK") return false;
    const Value &state = position.search_state();
    const Value *own_active = active(state, actor);
    const Value *opponent_active = active(state, 1 - actor);
    if (own_active == nullptr || opponent_active == nullptr) return false;
    const Value *definition = card(cards_, string_field(*own_active, "card_id"));
    const Value *payload = field(action, "payload");
    const std::int64_t index = payload != nullptr && payload->is_object()
        ? integer_field(*payload, "attack_index", -1) : -1;
    const auto &attacks = definition == nullptr
        ? Value::Array{} : array_field(*definition, "attacks");
    if (index < 0 || static_cast<std::size_t>(index) >= attacks.size()) return false;
    const auto &effects = array_field(attacks[static_cast<std::size_t>(index)], "effects");
    if (attack_draw_pressure_is_unsafe(state, actor, effects)) return true;
    const std::int64_t damage = estimated_attack_damage(
        position, state, actor, static_cast<std::size_t>(index), cards_);
    if (attack_feeds_dangerous_retaliation(
        position, state, actor, damage, cards_)) return true;

    // Frozen fire-deck guard for Chimchar's non-KO Spark: preserve the lone
    // Energy/evolution route when no public replacement Energy or backup exists.
    if (deck_key(state, actor) != "fire"
        || string_field(*own_active, "card_id") != "svi-chim"
        || bench_count(player(state, actor)) != 0
        || energy_unit_count(cards_, own_active) != 1
        || helpful_hand_energy_count(state, actor, cards_) > 0) return false;
    bool discards_self_energy = false;
    for (const Value *effect : flatten_effects(effects)) {
        if (string_field(*effect, "effect_type") != "energy_discard") continue;
        const Value *params = field(*effect, "params");
        const std::string from = params != nullptr && params->is_object()
            ? string_field(*params, "from", "self") : std::string("self");
        if (from.empty() || from == "self") {
            discards_self_energy = true;
            break;
        }
    }
    return discards_self_energy && damage < position.pokemon_current_hp(*opponent_active);
}

std::optional<double> TraditionalTrustedEvaluator::productive_attack_value(
    const RulesSession &position,
    std::int32_t actor,
    const Value &action
) const {
    if ((actor != 0 && actor != 1)
        || string_field(action, "kind") != "DECLARE_ATTACK") {
        return std::nullopt;
    }
    const Value &state = position.search_state();
    const Value *own_active = active(state, actor);
    if (own_active == nullptr) return std::nullopt;
    const Value *definition = card(cards_, string_field(*own_active, "card_id"));
    const Value *payload = field(action, "payload");
    const std::int64_t index = payload != nullptr && payload->is_object()
        ? integer_field(*payload, "attack_index", -1) : -1;
    const auto &attacks = definition == nullptr
        ? Value::Array{} : array_field(*definition, "attacks");
    if (index < 0 || static_cast<std::size_t>(index) >= attacks.size()) {
        return std::nullopt;
    }
    const std::optional<double> tactical = simple_effects_tactical_value(
        position,
        state,
        actor,
        array_field(attacks[static_cast<std::size_t>(index)], "effects"),
        "active",
        deck_key(state, actor),
        cards_,
        decks_);
    if (!tactical.has_value()) return std::nullopt;
    const std::int64_t damage = estimated_attack_damage(
        position, state, actor, static_cast<std::size_t>(index), cards_);
    return static_cast<double>(damage) * 1.2 + *tactical;
}

bool TraditionalTrustedEvaluator::retreat_action_has_good_target(
    const RulesSession &position,
    std::int32_t actor,
    const Value &action
) const {
    if ((actor != 0 && actor != 1) || string_field(action, "kind") != "RETREAT") {
        return false;
    }
    const Value &state = position.search_state();
    const Value *active_pokemon = active(state, actor);
    const Value *target_ref = field(action, "target");
    const std::string target_slot = target_ref != nullptr && target_ref->is_object()
        ? string_field(*target_ref, "slot") : std::string{};
    const Value *target = pokemon_at(player(state, actor), target_slot);
    return active_pokemon != nullptr && target != nullptr
        && ptcg::ai::retreat_has_good_target(
            position, state, actor, *active_pokemon, *target, target_slot,
            deck_key(state, actor), cards_);
}

std::optional<double> TraditionalTrustedEvaluator::choice_option_score(
    const RulesSession &position,
    std::int32_t actor,
    const Value &choice_view,
    const Value &option
) const {
    if (bool_field(position.search_state(), "apply_type_matchups")) {
        return std::nullopt;
    }
    return base_choice_option_score(
        position, position.search_state(), actor,
        choice_view, option, cards_, decks_);
}

std::optional<bool> TraditionalTrustedEvaluator::confirm_choice(
    const RulesSession &position,
    std::int32_t actor,
    const Value &choice_view
) const {
    if (actor != 0 && actor != 1) return std::nullopt;
    const Value &state = position.search_state();
    const Value *presentation_value = field(choice_view, "presentation");
    static const Value empty = Value::make_object();
    const Value &presentation = presentation_value != nullptr
        && presentation_value->is_object() ? *presentation_value : empty;
    const std::string purpose = string_field(presentation, "purpose");
    const std::string key = deck_key(state, actor);
    if (purpose == "trekking_shoes"
        || !string_field(presentation, "top_card_id").empty()) {
        std::string card_id = string_field(
            presentation, "top_card_id", string_field(presentation, "card_id"));
        if (card_id.empty()) {
            const auto &deck = array_field(player(state, actor), "deck");
            if (!deck.empty()) card_id = deck.back().string_or();
        }
        if (card_id.empty()) return false;
        const DeckProfile &deck = profile(key);
        if (contains(deck.core, card_id) || contains(deck.evolution, card_id)
            || contains(deck.engine, card_id)) return true;
        if (is_energy(cards_, card_id) && has_energy_target(state, actor, cards_)) {
            return true;
        }
        return card_keep_value(
            position, state, actor, card_id,
            key, cards_, decks_) >= 55.0;
    }
    const auto switch_self_has_good_target = [&](std::int32_t chooser) {
        const Value *active_pokemon = active(state, chooser);
        if (active_pokemon == nullptr) return false;
        const auto &bench = array_field(player(state, chooser), "bench");
        for (std::size_t index = 0; index < bench.size(); ++index) {
            if (!bench[index].is_object()) continue;
            const std::string slot = "bench_" + std::to_string(index);
            if (retreat_has_good_target(
                position, state, chooser, *active_pokemon,
                bench[index], slot, deck_key(state, chooser), cards_)) return true;
        }
        return false;
    };
    const auto switch_opponent_has_good_target = [&] (
        std::int32_t chooser,
        std::int32_t target_player
    ) {
        const Value *target_active = active(state, target_player);
        const auto &bench = array_field(player(state, target_player), "bench");
        if (target_active == nullptr || bench.empty()) return false;
        const double active_priority = tactical_target_priority(
            position, *target_active, cards_);
        double best = -std::numeric_limits<double>::infinity();
        for (const Value &pokemon : bench) {
            if (pokemon.is_object()) best = std::max(best,
                tactical_target_priority(position, pokemon, cards_));
        }
        if (!std::isfinite(best) || best <= active_priority + 20.0) return false;
        if (active(state, chooser) != nullptr
            && best_available_damage(position, state, chooser, cards_)
                >= position.pokemon_current_hp(*target_active)) return false;
        return true;
    };
    if (purpose == "confirm_switch" || purpose == "search_any_switch_confirm") {
        const std::int32_t chooser = static_cast<std::int32_t>(integer_field(
            presentation, "source_player", actor));
        const std::int32_t target_player = static_cast<std::int32_t>(integer_field(
            presentation, "target_player", actor));
        return target_player == chooser
            ? switch_self_has_good_target(chooser)
            : switch_opponent_has_good_target(chooser, target_player);
    }
    if (purpose == "switch") return switch_self_has_good_target(actor);
    if (purpose == "heal") {
        for (const Value *pokemon : board(state, actor)) {
            if (integer_field(*pokemon, "damage_counters") > 0) return true;
        }
        return false;
    }
    return true;
}

Value TraditionalTrustedEvaluator::energy_target_prefix_plan(
    const RulesSession &position,
    std::int32_t actor,
    const Value &choice_view,
    const Value &option,
    std::int64_t max_count
) const {
    Value result = Value::make_object();
    result["count"] = Value(max_count);
    result["gain"] = Value(0.0);
    if (actor != 0 && actor != 1 || max_count <= 0) return result;
    const Value *presentation_value = field(choice_view, "presentation");
    static const Value empty = Value::make_object();
    const Value &presentation = presentation_value != nullptr
        && presentation_value->is_object() ? *presentation_value : empty;
    if (!bool_field(choice_view, "allow_duplicates")
        || !bool_field(presentation, "same_target")) return result;
    const Value &state = position.search_state();
    const std::int32_t target_player = choice_option_player(option, actor);
    const std::string slot = choice_option_slot(option);
    const Value *pokemon = pokemon_at(player(state, target_player), slot);
    if (pokemon == nullptr) return result;
    std::vector<std::string> energy_ids;
    for (const Value &entry : array_field(presentation, "card_ids")) {
        if (is_energy(cards_, entry.string_or())) {
            energy_ids.push_back(entry.string_or());
        }
    }
    const std::string fallback = choice_energy_card_id(presentation, cards_);
    if (energy_ids.empty() && !fallback.empty()) energy_ids.push_back(fallback);
    if (energy_ids.empty()) return result;
    const std::string key = deck_key(state, target_player);
    const double baseline = energy_attack_plan_utility(
        position, state, target_player, *pokemon,
        slot, key, cards_, decks_);
    double best = baseline;
    std::int64_t best_count = 0;
    Value probe = *pokemon;
    for (std::int64_t prefix = 0; prefix < max_count; ++prefix) {
        const std::string &energy_id = energy_ids[static_cast<std::size_t>(
            std::min<std::int64_t>(
                prefix, static_cast<std::int64_t>(energy_ids.size()) - 1))];
        if (energy_id.empty() || !is_energy(cards_, energy_id)) break;
        Value *attached = probe.find("energy_card_ids");
        if (attached == nullptr || !attached->is_array()) {
            probe["energy_card_ids"] = Value::make_array();
            attached = probe.find("energy_card_ids");
        }
        attached->as_array().emplace_back(energy_id);
        const std::int64_t count = prefix + 1;
        const double utility = energy_attack_plan_utility(
            position, state, target_player, probe,
            slot, key, cards_, decks_) - static_cast<double>(count) * 25.0;
        if (utility > best + 0.001) {
            best = utility;
            best_count = count;
        }
    }
    result["count"] = Value(best_count);
    result["gain"] = Value(std::max(0.0, best - baseline));
    return result;
}

double TraditionalTrustedEvaluator::energy_distribution_board_utility(
    const RulesSession &position,
    std::int32_t actor
) const {
    return actor == 0 || actor == 1
        ? public_energy_distribution_board_utility(
            position, position.search_state(), actor, cards_)
        : 0.0;
}

Value TraditionalTrustedEvaluator::debug_components(
    const RulesSession &position,
    std::int32_t perspective
) const {
    Value result = Value::make_object();
    if (perspective != 0 && perspective != 1) return result;
    const Value &state = position.search_state();
    result["perspective"] = player_score_components(
        position, state, perspective, cards_, decks_);
    result["opponent"] = player_score_components(
        position, state, 1 - perspective, cards_, decks_);
    result["delta"] = Value(leaf_score(position, perspective));
    return result;
}

} // namespace ptcg::ai
