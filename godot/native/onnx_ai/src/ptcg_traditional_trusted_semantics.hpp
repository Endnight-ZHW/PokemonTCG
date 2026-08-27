#pragma once

#include "ptcg_traditional_trusted_board.hpp"

namespace ptcg::ai::traditional_trusted_detail {

inline double card_keep_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const std::string &card_id,
    const std::string &key,
    const Value &cards,
    const Value &decks,
    bool removing_one = false
) {
    if (card_id.empty()) return 0.0;
    const Value &owner = player(state, actor);
    const Value *definition = card(cards, card_id);
    double value = card_priority(cards, card_id, key);
    if (is_pokemon(cards, card_id)) {
        value += static_cast<double>(definition == nullptr
            ? 0 : integer_field(*definition, "hp")) * 0.25;
        if (is_basic_pokemon(cards, card_id)
            && active(state, actor) != nullptr && bench_count(owner) == 0) {
            value += lone_active_backup_search_bonus(
                position, state, actor, cards);
        }
        value += core_evolution_line_card_bonus(
            state, actor, card_id, key, cards, decks, removing_one);
    }
    if (is_energy(cards, card_id)) {
        if (has_energy_target(state, actor, cards)) value += 50.0;
        if (
            removing_one
            && energy_improves_attack_readiness(state, actor, card_id, cards)
            && helpful_hand_energy_count(state, actor, cards) <= 1
        ) value += 230.0;
    }
    if (is_trainer(cards, card_id)) {
        value += 18.0;
        value += bench_setup_search_card_bonus(
            position, state, actor, card_id, key, cards);
    }
    const std::int64_t duplicate_count = count_in_zone(
        array_field(owner, "hand"), card_id);
    const std::int64_t remaining = std::max<std::int64_t>(
        0, duplicate_count - (removing_one ? 1 : 0));
    if (
        remaining >= 1 && is_pokemon(cards, card_id)
        && (contains(profile(key).core, card_id)
            || contains(profile(key).evolution, card_id))
    ) {
        value -= std::min(120.0, static_cast<double>(remaining) * 45.0);
    } else if (removing_one && remaining >= 1) {
        value -= std::min(90.0, static_cast<double>(remaining) * 60.0);
    } else if (remaining >= 2) {
        value -= std::min(90.0, static_cast<double>(remaining - 1) * 35.0);
    }
    return value;
}

inline double deck_outs_quality(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const std::string &key,
    const Value &cards,
    const Value &decks
) {
    const auto &deck = array_field(player(state, actor), "deck");
    double total = 0.0;
    for (const Value &entry : deck) {
        total += std::max(0.0, card_keep_value(
            position, state, actor, entry.string_or(),
            key, cards, decks));
    }
    return total / static_cast<double>(std::max<std::size_t>(1, deck.size()));
}

inline double hand_size_plan(
    const Value &state,
    std::int32_t actor,
    const Value &cards,
    const std::string &deck_key
);

inline double semantic_draw_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    std::int64_t amount,
    bool refresh,
    const std::string &key,
    const Value &cards,
    const Value &decks
) {
    if (amount <= 0) return 0.0;
    const Value &owner = player(state, actor);
    const std::int64_t deck_size = static_cast<std::int64_t>(
        array_field(owner, "deck").size());
    const std::int64_t hand_size = static_cast<std::int64_t>(
        array_field(owner, "hand").size());
    if (deck_size <= amount) {
        return -300.0 - static_cast<double>(amount - deck_size) * 45.0;
    }
    const std::int64_t draw_count = std::min<std::int64_t>(amount, 7);
    const std::int64_t projected_deck = deck_size - draw_count;
    double value = static_cast<double>(draw_count) * 27.0;
    if (refresh) value += 54.0;
    const double hand_plan = hand_size_plan(state, actor, cards, key);
    if (hand_size <= 3) value += 86.0;
    else if (hand_size <= 5) value += 34.0;
    else if (hand_size >= 8) {
        if (refresh) value -= 115.0 + static_cast<double>(draw_count) * 24.0;
        else value -= 45.0 + static_cast<double>(draw_count) * 8.0;
        if (hand_plan > 0.0 && !refresh) {
            value += std::min(85.0, hand_plan * 0.38);
        } else if (hand_plan > 0.0) {
            value += std::min(70.0, hand_plan * 0.30);
        }
    } else if (hand_size >= 6) {
        value -= 25.0;
        if (hand_plan > 0.0) value += std::min(45.0, hand_plan * 0.22);
    }
    if (hand_plan > 0.0 && (hand_size < 8 || !refresh)) {
        const std::int64_t projected_hand = hand_size + draw_count;
        if (projected_hand >= 5) value += std::min(70.0, hand_plan * 0.25);
        else if (projected_hand >= 4) {
            value += std::min(35.0, hand_plan * 0.16);
        }
    }
    value += std::min(75.0, deck_outs_quality(
        position, state, actor, key, cards, decks) * 0.18);
    if (projected_deck <= 2) {
        value -= 96.0 + 165.0
            + static_cast<double>(3 - projected_deck) * 70.0;
    } else if (projected_deck <= 5) {
        value -= 58.0 + static_cast<double>(6 - projected_deck) * 20.0
            + static_cast<double>(std::max<std::int64_t>(0, draw_count - 2)) * 54.0;
    } else if (projected_deck <= 8) {
        value -= 58.0 + static_cast<double>(9 - projected_deck) * 18.0
            + static_cast<double>(std::max<std::int64_t>(0, draw_count - 3)) * 34.0;
    } else if (projected_deck <= 12 && refresh) {
        value -= 58.0 + static_cast<double>(13 - projected_deck) * 12.0;
    }
    if (refresh && deck_size <= 15) {
        value -= 46.0 + static_cast<double>(16 - deck_size) * 8.0;
    }
    if (
        hand_plan > 0.0 && !refresh && draw_count <= 2
        && projected_deck >= 3
    ) value += std::min(105.0, hand_plan * 0.9);
    return value;
}

inline bool card_matches_filter(
    const Value &cards,
    const std::string &card_id,
    const std::string &filter
) {
    const Value *definition = card(cards, card_id);
    if (definition == nullptr) return filter.empty() || filter == "any";
    if (filter.empty() || filter == "any") return true;
    if (filter == "basic_pokemon") return is_basic_pokemon(cards, card_id);
    if (filter == "pokemon") return is_pokemon(cards, card_id);
    if (filter == "basic" || filter == "basic_energy") {
        return is_basic_energy(cards, card_id);
    }
    if (filter == "energy") return is_energy(cards, card_id);
    if (filter == "supporter") return is_trainer(cards, card_id)
        && has_subtype(*definition, "Supporter");
    if (filter == "item") return is_trainer(cards, card_id)
        && has_subtype(*definition, "Item");
    if (filter == "item_or_tool") return is_trainer(cards, card_id)
        && (has_subtype(*definition, "Item") || has_subtype(*definition, "Tool"));
    if (filter == "pokemon_and_energy") {
        return is_pokemon(cards, card_id) || is_basic_energy(cards, card_id);
    }
    if (filter == "grass_pokemon") return is_pokemon(cards, card_id)
        && array_contains(array_field(*definition, "energy_types"), "Grass");
    if (filter == "water_pokemon_and_energy") {
        return (is_pokemon(cards, card_id)
                && array_contains(array_field(*definition, "energy_types"), "Water"))
            || (is_basic_energy(cards, card_id)
                && array_contains(array_field(*definition, "provides_energy"), "Water"));
    }
    if (filter == "lightning_energy") return is_basic_energy(cards, card_id)
        && array_contains(array_field(*definition, "provides_energy"), "Lightning");
    return true;
}

inline Value::Array filter_cards(
    const Value::Array &zone,
    const std::string &filter,
    const Value &cards
) {
    Value::Array result;
    for (const Value &entry : zone) {
        if (card_matches_filter(cards, entry.string_or(), filter)) {
            result.push_back(entry);
        }
    }
    return result;
}

inline double semantic_search_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &params,
    const std::string &key,
    const Value &cards,
    const Value &decks
) {
    const Value &owner = player(state, actor);
    const auto &deck = array_field(owner, "deck");
    if (deck.empty()) return -90.0;
    const std::string filter = string_field(
        params, "filter", string_field(params, "filter_type",
            string_field(params, "card_filter", "any")));
    Value::Array candidates = filter_cards(deck, filter, cards);
    if (candidates.empty()) candidates = deck;
    double best = -std::numeric_limits<double>::infinity();
    for (const Value &entry : candidates) {
        best = std::max(best, card_keep_value(
            position, state, actor, entry.string_or(), key, cards, decks));
    }
    double value = 84.0 + std::max(0.0, best) * 0.42;
    if (bench_count(owner) < 2) value += 45.0;
    if (has_energy_target(state, actor, cards)
        && std::any_of(candidates.begin(), candidates.end(),
            [&cards](const Value &entry) {
                return is_energy(cards, entry.string_or());
            })) value += 56.0;
    if (std::any_of(candidates.begin(), candidates.end(),
        [&cards, &key](const Value &entry) {
            const std::string id = entry.string_or();
            return is_pokemon(cards, id)
                && contains(profile(key).evolution, id);
        })) value += 48.0;
    return value;
}

inline Value::Array public_unseen_deck_pool(
    const Value &state,
    std::int32_t actor,
    const std::string &key,
    const Value &cards,
    const Value &decks
) {
    Value::Array pool = expand_deck(decks, key);
    const Value &owner = player(state, actor);
    Value::Array public_cards;
    public_cards.insert(public_cards.end(),
        array_field(owner, "hand").begin(), array_field(owner, "hand").end());
    public_cards.insert(public_cards.end(),
        array_field(owner, "discard").begin(), array_field(owner, "discard").end());
    for (const Value *pokemon : board(state, actor)) {
        public_cards.emplace_back(string_field(*pokemon, "card_id"));
        public_cards.insert(public_cards.end(),
            array_field(*pokemon, "evolution_stack_ids").begin(),
            array_field(*pokemon, "evolution_stack_ids").end());
        public_cards.insert(public_cards.end(),
            array_field(*pokemon, "energy_card_ids").begin(),
            array_field(*pokemon, "energy_card_ids").end());
        const std::string tool = string_field(*pokemon, "attached_tool_id");
        if (!tool.empty()) public_cards.emplace_back(tool);
    }
    for (const Value &visible : public_cards) {
        const std::string id = visible.string_or();
        const auto found = std::find_if(pool.begin(), pool.end(),
            [&id](const Value &entry) { return entry.string_or() == id; });
        if (found != pool.end()) pool.erase(found);
    }
    (void)cards;
    return pool;
}

inline double semantic_look_top_deck_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &params,
    const std::string &key,
    const Value &cards,
    const Value &decks
) {
    const Value &owner = player(state, actor);
    const std::int64_t deck_size = static_cast<std::int64_t>(
        array_field(owner, "deck").size());
    const std::int64_t top_count = std::min<std::int64_t>(
        std::max<std::int64_t>(0, integer_field(params, "count")), deck_size);
    if (top_count <= 0) return -160.0;
    const Value::Array unseen = public_unseen_deck_pool(
        state, actor, key, cards, decks);
    if (unseen.empty()) return -90.0;
    const Value::Array hits = filter_cards(
        unseen, string_field(params, "filter", "any"), cards);
    const double expected = static_cast<double>(hits.size())
        * static_cast<double>(top_count) / static_cast<double>(unseen.size());
    double value = expected * 52.0;
    if (expected >= 3.0) value += 55.0;
    else if (expected < 1.0) value -= 85.0;
    if (has_energy_target(state, actor, cards)) {
        value += std::min(65.0, expected * 12.0);
    }
    if (bench_count(owner) < 2) value += std::min(55.0, expected * 10.0);
    if (deck_size <= 3) value -= 210.0;
    (void)position;
    return value;
}

inline double semantic_houb_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    std::int64_t target_hand_size,
    const std::string &key,
    const Value &cards,
    const Value &decks
) {
    const Value &owner = player(state, actor);
    const std::int64_t hand_size = static_cast<std::int64_t>(
        array_field(owner, "hand").size());
    const std::int64_t hand_after_cost = std::max<std::int64_t>(0, hand_size - 2);
    const std::int64_t draw_count = std::max<std::int64_t>(
        0, target_hand_size - hand_after_cost);
    if (draw_count <= 0) return -175.0
        - static_cast<double>(std::max<std::int64_t>(
            0, hand_after_cost - target_hand_size)) * 28.0;
    if (array_field(owner, "deck").size()
        <= static_cast<std::size_t>(draw_count)) return -280.0;
    double value = static_cast<double>(draw_count) * 27.0;
    if (hand_size <= 3) value += 115.0;
    else if (hand_size <= 5) value += 45.0;
    value += std::min(55.0, deck_outs_quality(
        position, state, actor, key, cards, decks) * 0.14);
    double cheapest = std::numeric_limits<double>::infinity();
    for (const Value &entry : array_field(owner, "hand")) {
        const std::string id = entry.string_or();
        const Value *definition = card(cards, id);
        bool is_houb = false;
        if (definition != nullptr) {
            for (const Value *effect : flatten_effects(
                array_field(*definition, "trainer_effects"))) {
                if (string_field(*effect, "effect_type") == "houb") {
                    is_houb = true;
                    break;
                }
            }
        }
        if (!is_houb) cheapest = std::min(cheapest, card_keep_value(
            position, state, actor, id, key, cards, decks));
    }
    if (std::isfinite(cheapest)) value -= std::max(0.0, cheapest) * 0.22;
    return value;
}

inline double clara_recovery_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const std::string &key,
    const Value &cards,
    const Value &decks
) {
    const Value &owner = player(state, actor);
    std::int64_t positive = 0;
    double best = -std::numeric_limits<double>::infinity();
    for (const Value &entry : array_field(owner, "discard")) {
        const std::string id = entry.string_or();
        if (!is_pokemon(cards, id) && !is_basic_energy(cards, id)) continue;
        double target = card_keep_value(
            position, state, actor, id, key, cards, decks);
        if (is_basic_energy(cards, id)
            && !has_energy_target(state, actor, cards)) target -= 70.0;
        best = std::max(best, target);
        if (target > 0.0) ++positive;
    }
    if (positive == 0) return -180.0;
    return 70.0 + static_cast<double>(std::min<std::int64_t>(positive, 4)) * 35.0
        + std::max(0.0, best) * 0.35;
}

inline double tactical_target_priority(
    const RulesSession &position,
    const Value &pokemon,
    const Value &cards
) {
    const Value *definition = card(cards, string_field(pokemon, "card_id"));
    const std::int64_t max_hp = definition == nullptr
        ? 0 : integer_field(*definition, "hp");
    const std::int64_t current_hp = position.pokemon_current_hp(pokemon);
    const std::int64_t prizes = definition == nullptr
        ? 1 : integer_field(*definition, "prize_value", 1);
    return static_cast<double>(prizes) * 160.0
        + static_cast<double>(std::max<std::int64_t>(0, max_hp - current_hp)) * 2.0
        + static_cast<double>(energy_unit_count(cards, &pokemon)) * 26.0
        + static_cast<double>(printed_best_damage(cards, &pokemon)) * 0.35
        - static_cast<double>(current_hp) * 0.45;
}

inline double semantic_energy_accel_value(
    const Value &state,
    std::int32_t actor,
    const std::string &key,
    const Value &cards
) {
    double best = -70.0;
    const auto rows = board(state, actor);
    for (std::size_t index = 0; index < rows.size(); ++index) {
        const Value *pokemon = rows[index];
        const std::int64_t missing = best_missing(cards, pokemon);
        if (missing >= 99) continue;
        const std::int64_t damage = printed_best_damage(cards, pokemon);
        double candidate = 112.0;
        if (missing == 0) candidate -= 65.0;
        else if (missing == 1) {
            candidate += 150.0 + static_cast<double>(damage) * 0.22;
        } else {
            candidate += std::min(95.0, static_cast<double>(damage) * 0.16);
        }
        if (index == 0 && active(state, actor) == pokemon) candidate += 32.0;
        if (contains(profile(key).core, string_field(*pokemon, "card_id"))) {
            candidate += 70.0;
        }
        best = std::max(best, candidate);
    }
    return best;
}

inline double semantic_healing_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &cards
) {
    double value = 0.0;
    const std::int64_t opponent_damage = best_available_damage(
        position, state, 1 - actor, cards);
    for (const Value *pokemon : board(state, actor)) {
        const std::int64_t counters = integer_field(*pokemon, "damage_counters");
        if (counters <= 0) continue;
        double target = std::min(150.0, static_cast<double>(counters) * 24.0);
        if (opponent_damage >= position.pokemon_current_hp(*pokemon)) {
            target += 70.0;
        }
        value += target;
    }
    return value;
}

inline double semantic_switch_self_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const std::string &key,
    const Value &cards
) {
    const Value &owner = player(state, actor);
    const Value *active_pokemon = active(state, actor);
    if (active_pokemon == nullptr || bench_count(owner) <= 0) return -100.0;
    const double active_value = promotion_value(
        position, state, actor, *active_pokemon, "active", key, cards);
    double best = -std::numeric_limits<double>::infinity();
    const auto &bench = array_field(owner, "bench");
    for (std::size_t index = 0; index < bench.size(); ++index) {
        if (!bench[index].is_object()) continue;
        const std::string slot = "bench_" + std::to_string(index);
        double delta = promotion_value(
            position, state, actor, bench[index], slot, key, cards) - active_value;
        if (retreat_has_good_target(
            position, state, actor, *active_pokemon,
            bench[index], slot, key, cards)) delta += 72.0;
        best = std::max(best, delta);
    }
    return std::isfinite(best) ? best : -100.0;
}

inline double semantic_switch_opponent_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &cards
) {
    const Value &opponent = player(state, 1 - actor);
    const Value *opponent_active = active(state, 1 - actor);
    if (opponent_active == nullptr || bench_count(opponent) <= 0) return -100.0;
    const double active_priority = tactical_target_priority(
        position, *opponent_active, cards);
    double best_bench = -std::numeric_limits<double>::infinity();
    for (const Value &pokemon : array_field(opponent, "bench")) {
        if (pokemon.is_object()) {
            best_bench = std::max(best_bench,
                tactical_target_priority(position, pokemon, cards));
        }
    }
    if (!std::isfinite(best_bench)) return -100.0;
    double value = best_bench - active_priority + 72.0;
    if (best_available_damage(position, state, actor, cards)
        >= position.pokemon_current_hp(*opponent_active)) value -= 120.0;
    return value;
}

inline double semantic_energy_disruption_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &cards
) {
    const Value *opponent_active = active(state, 1 - actor);
    if (opponent_active == nullptr
        || array_field(*opponent_active, "energy_card_ids").empty()) return -45.0;
    const std::int64_t before = best_available_damage(
        position, state, 1 - actor, cards);
    double value = 65.0
        + static_cast<double>(energy_unit_count(cards, opponent_active)) * 32.0;
    const Value *own_active = active(state, actor);
    if (own_active != nullptr
        && before >= position.pokemon_current_hp(*own_active)) value += 78.0;
    return value;
}

inline bool energy_card_matches_type_at(
    const Value &cards,
    const Value::Array &attached,
    std::size_t card_index,
    std::string energy_type
) {
    if (card_index >= attached.size()) return false;
    const std::string card_id = attached[card_index].string_or();
    energy_type = lower_ascii(std::move(energy_type));
    if (energy_type.empty() || energy_type == "any" || energy_type == "energy") {
        return is_energy(cards, card_id);
    }
    const Value *definition = card(cards, card_id);
    if (energy_type == "basic" || energy_type == "basic_energy") {
        return definition != nullptr && is_energy(cards, card_id)
            && has_subtype(*definition, "Basic");
    }
    if (definition == nullptr || !is_energy(cards, card_id)) return false;
    bool downgrade = false;
    if (downgrades_rainbow(*definition)) {
        for (std::size_t other = 0; other < attached.size(); ++other) {
            if (other != card_index
                && is_special_energy(cards, attached[other].string_or())) {
                downgrade = true;
                break;
            }
        }
    }
    for (const Value &provided : array_field(*definition, "provides_energy")) {
        std::string unit = provided.string_or();
        if (downgrade && unit == "Rainbow") unit = "Colorless";
        const std::string normalized = lower_ascii(std::move(unit));
        if (normalized == energy_type || normalized == "rainbow") return true;
    }
    return false;
}

inline double energy_relocate_value(
    const Value &state,
    std::int32_t actor,
    const Value &params,
    const Value &cards
) {
    const Value &owner = player(state, actor);
    if (active(state, actor) == nullptr || bench_count(owner) <= 0) return -120.0;
    const std::string energy_type = string_field(
        params, "energy_type", string_field(params, "filter", "any"));
    struct BoardRow {
        const Value *pokemon = nullptr;
        std::string slot;
    };
    std::vector<BoardRow> rows;
    if (const Value *active_pokemon = active(state, actor)) {
        rows.push_back({active_pokemon, "active"});
    }
    const auto &bench = array_field(owner, "bench");
    for (std::size_t index = 0; index < bench.size(); ++index) {
        if (bench[index].is_object()) {
            rows.push_back({&bench[index], "bench_" + std::to_string(index)});
        }
    }
    double best = -120.0;
    for (const BoardRow &source : rows) {
        const auto &attached = array_field(*source.pokemon, "energy_card_ids");
        for (std::size_t energy_index = 0;
            energy_index < attached.size(); ++energy_index) {
            if (!energy_card_matches_type_at(
                cards, attached, energy_index, energy_type)) continue;
            const std::string energy_id = attached[energy_index].string_or();
            for (const BoardRow &target : rows) {
                if (target.slot == source.slot) continue;
                const std::int64_t before = best_missing(cards, target.pokemon);
                const std::int64_t after = best_missing_with_extra(
                    cards, target.pokemon, energy_id);
                if (after >= before) continue;
                double value = static_cast<double>(before - after) * 85.0;
                if (target.slot == "active") value += 90.0;
                if (after == 0) {
                    value += 130.0
                        + static_cast<double>(printed_best_damage(
                            cards, target.pokemon)) * 0.20;
                }
                if (source.slot == "active" && target.slot != "active") {
                    value -= 80.0;
                }
                best = std::max(best, value);
            }
        }
    }
    return best;
}

inline double self_energy_discard_cost(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const std::string &source_slot,
    std::int64_t requested_amount,
    const Value &cards
) {
    const Value *source = pokemon_at(player(state, actor), source_slot);
    if (source == nullptr) return 0.0;
    const auto &attached = array_field(*source, "energy_card_ids");
    const std::int64_t discard_count = std::min<std::int64_t>(
        static_cast<std::int64_t>(attached.size()),
        std::max<std::int64_t>(0, requested_amount));
    if (discard_count <= 0) return 0.0;
    const std::int64_t before_missing = best_missing(cards, source);
    const std::int64_t before_ready = best_ready_damage_for_pokemon(
        position, state, actor, *source, source_slot, cards);
    Value probe = *source;
    Value::Array kept = attached;
    kept.resize(kept.size() - static_cast<std::size_t>(discard_count));
    probe["energy_card_ids"] = Value(std::move(kept));
    const std::int64_t after_missing = best_missing(cards, &probe);
    const std::int64_t after_ready = best_ready_damage_for_pokemon(
        position, state, actor, probe, source_slot, cards);
    double cost = static_cast<double>(discard_count) * 65.0;
    if (discard_count >= static_cast<std::int64_t>(attached.size())) cost += 60.0;
    cost += static_cast<double>(std::max<std::int64_t>(
        0, after_missing - before_missing)) * 55.0;
    cost += static_cast<double>(std::max<std::int64_t>(
        0, before_ready - after_ready)) * 0.45;
    return cost;
}

inline double self_fighting_energy_discard_cost(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const std::string &source_slot,
    const Value &cards
) {
    const Value *source = pokemon_at(player(state, actor), source_slot);
    if (source == nullptr) return 0.0;
    const auto &attached = array_field(*source, "energy_card_ids");
    Value::Array kept;
    std::int64_t removed = 0;
    for (std::size_t index = 0; index < attached.size(); ++index) {
        if (energy_card_matches_type_at(cards, attached, index, "Fighting")) {
            ++removed;
        } else {
            kept.push_back(attached[index]);
        }
    }
    if (removed <= 0) return 0.0;
    const std::int64_t before_missing = best_missing(cards, source);
    const std::int64_t before_ready = best_ready_damage_for_pokemon(
        position, state, actor, *source, source_slot, cards);
    Value probe = *source;
    probe["energy_card_ids"] = Value(std::move(kept));
    const std::int64_t after_missing = best_missing(cards, &probe);
    const std::int64_t after_ready = best_ready_damage_for_pokemon(
        position, state, actor, probe, source_slot, cards);
    double cost = static_cast<double>(removed) * 65.0;
    cost += static_cast<double>(std::max<std::int64_t>(
        0, after_missing - before_missing)) * 55.0;
    cost += static_cast<double>(std::max<std::int64_t>(
        0, before_ready - after_ready)) * 0.45;
    return cost;
}

inline double expected_self_energy_discard_cost(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value::Array &effects,
    const std::string &source_slot,
    const Value &cards,
    double probability = 1.0
) {
    double total = 0.0;
    for (const Value &effect : effects) {
        if (!effect.is_object()) continue;
        const Value *params_value = field(effect, "params");
        static const Value empty = Value::make_object();
        const Value &params = params_value != nullptr && params_value->is_object()
            ? *params_value : empty;
        const std::string type = string_field(effect, "effect_type");
        if (type == "energy_discard"
            && string_field(params, "from", "opponent") == "self") {
            total += probability * self_energy_discard_cost(
                position, state, actor, source_slot,
                integer_field(params, "amount", 1), cards);
        } else if (type == "discard_fighting_energy_damage") {
            total += probability * self_fighting_energy_discard_cost(
                position, state, actor, source_slot, cards);
        }
        for (const char *key : {
            "on_heads", "on_tails", "on_success", "on_fail", "on_pay", "cost",
        }) {
            const Value *branch = field(params, key);
            if (branch == nullptr) continue;
            Value::Array nested;
            if (branch->is_object()) nested.push_back(*branch);
            else if (branch->is_array()) nested = branch->as_array();
            if (nested.empty()) continue;
            double branch_probability = probability;
            if (
                std::string_view(key) == "on_heads"
                || std::string_view(key) == "on_tails"
                || std::string_view(key) == "on_success"
                || std::string_view(key) == "on_fail"
            ) branch_probability *= 0.5;
            total += expected_self_energy_discard_cost(
                position, state, actor, nested,
                source_slot, cards, branch_probability);
        }
    }
    return total;
}

inline double semantic_hand_disruption_value(
    const Value &state,
    std::int32_t actor
) {
    const Value &opponent = player(state, 1 - actor);
    const Value &owner = player(state, actor);
    double value = 65.0 + std::min(
        90.0, static_cast<double>(array_field(opponent, "hand").size()) * 14.0);
    if (array_field(owner, "prizes").size()
        > array_field(opponent, "prizes").size()) value += 38.0;
    if (array_field(opponent, "hand").size() <= 1) value -= 55.0;
    return value;
}

inline double semantic_status_effect_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const std::string &effect_type,
    const Value &params,
    const Value &cards
) {
    const Value *opponent_active = active(state, 1 - actor);
    if (opponent_active == nullptr) return -30.0;
    double value = 58.0;
    const std::string status = lower_ascii(string_field(params, "status"));
    if (
        status == "paralyzed" || effect_type == "attack_lock_basic"
        || effect_type == "dazzling_beam" || effect_type == "self_attack_lock"
    ) value += 72.0;
    else if (status == "asleep") value += 34.0;
    const Value *own_active = active(state, actor);
    if (own_active != nullptr
        && best_available_damage(position, state, 1 - actor, cards)
            >= position.pokemon_current_hp(*own_active)) value += 86.0;
    if (!array_field(*opponent_active, "status_conditions").empty()
        || modifier_kind(opponent_active, "attack_lock")) value -= 35.0;
    return value;
}

inline double self_discard_source_cost(
    const Value &state,
    std::int32_t actor,
    const std::string &source_slot,
    const Value &cards
) {
    const Value *source = pokemon_at(player(state, actor), source_slot);
    if (source == nullptr) return 320.0;
    const Value *definition = card(cards, string_field(*source, "card_id"));
    double cost = 120.0 + static_cast<double>(definition == nullptr
        ? 1 : integer_field(*definition, "prize_value", 1)) * 80.0;
    cost += static_cast<double>(energy_unit_count(cards, source)) * 45.0;
    cost += static_cast<double>(
        array_field(*source, "evolution_stack_ids").size()) * 30.0;
    if (!string_field(*source, "attached_tool_id").empty()) cost += 35.0;
    return cost;
}

inline double semantic_best_bench_damage_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    std::int64_t damage,
    const Value &cards
) {
    double best = 0.0;
    for (const Value &pokemon : array_field(player(state, 1 - actor), "bench")) {
        if (!pokemon.is_object()) continue;
        double target = tactical_target_priority(position, pokemon, cards) * 0.25;
        if (damage >= position.pokemon_current_hp(pokemon)) {
            const Value *definition = card(cards, string_field(pokemon, "card_id"));
            target += 150.0 + static_cast<double>(definition == nullptr
                ? 1 : integer_field(*definition, "prize_value", 1)) * 95.0;
        }
        best = std::max(best, target);
    }
    return best;
}

inline double semantic_damage_effect_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &effect,
    const std::string &source_slot,
    const Value &cards
) {
    const std::int64_t damage = effect_damage(
        position, state, actor, effect, cards);
    double value = static_cast<double>(damage) * 1.15;
    const std::string type = string_field(effect, "effect_type");
    const Value *opponent_active = active(state, 1 - actor);
    if (opponent_active != nullptr
        && damage >= position.pokemon_current_hp(*opponent_active)) {
        const Value *definition = card(
            cards, string_field(*opponent_active, "card_id"));
        value += 190.0 + static_cast<double>(definition == nullptr
            ? 1 : integer_field(*definition, "prize_value", 1)) * 120.0;
    } else if (type == "bench_damage" || type == "any_pokemon_damage") {
        value += semantic_best_bench_damage_value(
            position, state, actor, damage, cards);
    }
    if (type == "place_counters_and_self_discard") {
        value -= self_discard_source_cost(state, actor, source_slot, cards);
    }
    return value;
}

inline std::optional<double> simple_effects_tactical_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value::Array &effects,
    const std::string &source_slot,
    const std::string &key,
    const Value &cards,
    const Value &decks
) {
    double value = -expected_self_energy_discard_cost(
        position, state, actor, effects, source_slot, cards);
    static const std::set<std::string> zero_value_effects{
        "attack_flags",
        "attack_fail",
        "coin_flip",
        "coin_flip_double_ko",
        "coin_flip_triple",
        "coin_flip_until_tails",
        "conditional",
        "damage_per_self_damage",
        "damage_per_self_energy",
        "damage_per_self_energy_type",
        "damage_plus_bench",
        "damage_per_hand_size",
        "damage_per_energy",
        "damage_per_evolved",
        "damage_self_penalty",
        "damage_per_discard_psychic",
        "conditional_damage_heal",
        "mill_and_damage_per_energy",
        "trekking_shoes",
        "zinnia_resolve",
    };
    for (const Value *effect : flatten_effects(effects)) {
        const std::string type = string_field(*effect, "effect_type");
        static const Value empty = Value::make_object();
        const Value *params_value = field(*effect, "params");
        const Value &params = params_value != nullptr && params_value->is_object()
            ? *params_value : empty;
        if (zero_value_effects.count(type)) continue;
        if (type == "draw" || type == "draw_until" || type == "draw_until_more") {
            value += semantic_draw_value(
                position, state, actor,
                integer_field(params, "amount", integer_field(params, "target", 2)),
                false, key, cards, decks);
        } else if (
            type == "discard_draw" || type == "shuffle_draw" || type == "judge"
            || type == "hand_to_bottom_draw" || type == "discard_then_draw"
        ) {
            value += semantic_draw_value(
                position, state, actor,
                integer_field(params, "draw", integer_field(params, "amount", 4)),
                true, key, cards, decks);
        } else if (
            type == "search" || type == "conditional_search_extra"
            || type == "search_any_and_switch" || type == "arven"
        ) {
            value += semantic_search_value(
                position, state, actor, params, key, cards, decks);
        } else if (type == "houb") {
            value += semantic_houb_value(
                position, state, actor,
                integer_field(params, "target_hand_size", 5),
                key, cards, decks);
        } else if (type == "look_top_deck") {
            value += semantic_look_top_deck_value(
                position, state, actor, params, key, cards, decks);
        } else if (type == "clara") {
            value += clara_recovery_value(
                position, state, actor, key, cards, decks);
        } else if (
            type == "energy_attach" || type == "draw_and_attach_energy"
            || type == "attach_from_discard" || type == "look_top_attach_energy"
        ) {
            value += semantic_energy_accel_value(state, actor, key, cards);
        } else if (type == "energy_relocate") {
            value += energy_relocate_value(state, actor, params, cards);
        } else if (
            type == "heal" || type == "heal_all" || type == "potion_heal"
            || type == "damage_and_self_heal"
        ) {
            value += semantic_healing_value(position, state, actor, cards);
        } else if (type == "switch_self") {
            value += semantic_switch_self_value(
                position, state, actor, key, cards);
        } else if (type == "switch_opponent") {
            value += semantic_switch_opponent_value(
                position, state, actor, cards);
        } else if (type == "energy_discard" || type == "coin_flip_energy_discard") {
            if (string_field(params, "from", "opponent") != "self") {
                value += semantic_energy_disruption_value(
                    position, state, actor, cards);
            }
        } else if (type == "discard" || type == "discard_hand_conditional_bonus") {
            value += semantic_hand_disruption_value(state, actor);
        } else if (
            type == "prevent_damage" || type == "prevent_all"
            || type == "prevent_effects"
        ) {
            value += 76.0 + active_ko_risk(
                position, state, actor, cards, key) * 0.45;
        } else if (
            type == "status" || type == "conditional_status"
            || type == "dazzling_beam" || type == "attack_lock_basic"
            || type == "apply_outgoing_damage_reduction"
            || type == "self_attack_lock"
        ) {
            value += semantic_status_effect_value(
                position, state, actor, type, params, cards);
        } else if (
            type == "damage" || type == "any_pokemon_damage"
            || type == "place_counters_and_self_discard"
            || type == "bench_damage"
        ) {
            value += semantic_damage_effect_value(
                position, state, actor, *effect, source_slot, cards);
        } else if (type == "damage_counter_self") {
            value -= static_cast<double>(integer_field(
                params, "amount", integer_field(params, "damage", 20)));
        } else if (
            type == "attack_damage_formula" || type == "conditional_damage_bonus"
            || type == "discard_fighting_energy_damage"
        ) {
            value += semantic_damage_effect_value(
                position, state, actor, *effect, source_slot, cards);
        } else if (type == "shuffle_from_discard"
            || type == "ability_discard_revive") {
            value += 60.0 + resource_outs(
                state, actor, cards, decks, key) * 0.35;
        } else if (type == "tool" || type == "tool_exp_share") {
            value += 52.0 + active_ko_risk(
                position, state, actor, cards, key) * 0.12;
        } else if (type == "evolve_skip_stage") {
            value += 145.0 + resource_outs(
                state, actor, cards, decks, key) * 0.35;
        } else if (type == "return_to_hand") {
            double return_value = active_ko_risk(
                position, state, actor, cards, key) * 0.35;
            const Value *source = pokemon_at(player(state, actor), source_slot);
            if (source != nullptr
                && contains(profile(key).core, string_field(*source, "card_id"))) {
                return_value += 35.0;
            }
            value += return_value;
        } else {
            return std::nullopt;
        }
    }
    return value;
}

inline double starmie_torrent_followup_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const std::string &source_slot,
    const Value &cards
) {
    const Value *target = active(state, 1 - actor);
    if (target == nullptr) return 0.0;
    const Value &owner = player(state, actor);
    const Value *attacker = active(state, actor);
    std::string attacker_slot = "active";
    if (attacker == nullptr || string_field(*attacker, "card_id") != "sv2-grex") {
        attacker = nullptr;
        if (source_slot != "active") return 0.0;
        const auto &bench = array_field(owner, "bench");
        for (std::size_t index = 0; index < bench.size(); ++index) {
            if (bench[index].is_object()
                && string_field(bench[index], "card_id") == "sv2-grex") {
                attacker = &bench[index];
                attacker_slot = "bench_" + std::to_string(index);
                break;
            }
        }
    }
    if (attacker == nullptr) return 0.0;
    const Value *definition = card(cards, "sv2-grex");
    const auto &attacks = definition == nullptr
        ? Value::Array{} : array_field(*definition, "attacks");
    if (attacks.size() <= 1
        || missing_energy(cards, *attacker, array_field(attacks[1], "cost")) > 0) {
        return 0.0;
    }
    const std::int64_t before_damage = estimated_damage_for_pokemon(
        position, state, actor, *attacker, attacker_slot, 1, cards);
    const std::int64_t before_hp = position.pokemon_current_hp(*target);
    constexpr std::int64_t added_counters = 2;
    Value simulation = state;
    Value *players = simulation.find("players");
    if (players == nullptr || !players->is_array()
        || static_cast<std::size_t>(1 - actor) >= players->as_array().size()) {
        return 0.0;
    }
    Value &opponent = players->as_array()[static_cast<std::size_t>(1 - actor)];
    Value *simulated_target = opponent.find("active");
    if (simulated_target == nullptr || !simulated_target->is_object()) return 0.0;
    (*simulated_target)["damage_counters"] = Value(
        integer_field(*simulated_target, "damage_counters") + added_counters);
    const Value *simulated_attacker = pokemon_at(
        player(simulation, actor), attacker_slot);
    if (simulated_attacker == nullptr) return 0.0;
    const std::int64_t after_damage = estimated_damage_for_pokemon(
        position, simulation, actor, *simulated_attacker,
        attacker_slot, 1, cards);
    const std::int64_t after_hp = position.pokemon_current_hp(*simulated_target);
    double bonus = static_cast<double>(std::max<std::int64_t>(
        0, after_damage - before_damage)) * 3.0;
    if (before_damage < before_hp && after_damage >= after_hp) {
        const Value *target_definition = card(
            cards, string_field(*target, "card_id"));
        bonus += 1050.0 + static_cast<double>(target_definition == nullptr
            ? 1 : integer_field(*target_definition, "prize_value", 1)) * 360.0;
    }
    return bonus;
}

inline bool attack_draw_pressure_is_unsafe(
    const Value &state,
    std::int32_t actor,
    const Value::Array &effects
) {
    std::int64_t amount = 0;
    for (const Value *effect : flatten_effects(effects)) {
        const std::string type = string_field(*effect, "effect_type");
        if (type != "draw" && type != "draw_until" && type != "draw_until_more") {
            continue;
        }
        const Value *params = field(*effect, "params");
        amount += params != nullptr && params->is_object()
            ? integer_field(*params, "amount", 2) : 2;
    }
    return amount > 0 && array_field(player(state, actor), "deck").size()
        <= static_cast<std::size_t>(amount);
}

inline std::int64_t best_potential_retaliation_damage(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &cards
) {
    const Value *pokemon = active(state, actor);
    if (pokemon == nullptr) return 0;
    const Value *definition = card(cards, string_field(*pokemon, "card_id"));
    const auto &attacks = definition == nullptr
        ? Value::Array{} : array_field(*definition, "attacks");
    std::int64_t best = 0;
    for (std::size_t index = 0; index < attacks.size(); ++index) {
        if (missing_energy(cards, *pokemon, array_field(attacks[index], "cost")) <= 1) {
            best = std::max(best, estimated_attack_damage(
                position, state, actor, index, cards));
        }
    }
    return best;
}

inline bool attack_feeds_dangerous_retaliation(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    std::int64_t damage,
    const Value &cards
) {
    const Value *own_active = active(state, actor);
    const Value *opponent_active = active(state, 1 - actor);
    if (own_active == nullptr || opponent_active == nullptr
        || damage <= 0 || damage >= position.pokemon_current_hp(*opponent_active)) {
        return false;
    }
    const Value *opponent_definition = card(
        cards, string_field(*opponent_active, "card_id"));
    bool has_scaler = false;
    if (opponent_definition != nullptr) {
        for (const Value &attack : array_field(*opponent_definition, "attacks")) {
            for (const Value *effect : flatten_effects(array_field(attack, "effects"))) {
                if (string_field(*effect, "effect_type") == "damage_per_self_damage") {
                    has_scaler = true;
                    break;
                }
            }
            if (has_scaler) break;
        }
    }
    if (!has_scaler) return false;
    const std::int64_t before = best_potential_retaliation_damage(
        position, state, 1 - actor, cards);
    Value simulation = state;
    Value *players = simulation.find("players");
    if (players == nullptr || !players->is_array()
        || static_cast<std::size_t>(1 - actor) >= players->as_array().size()) {
        return false;
    }
    Value &opponent = players->as_array()[static_cast<std::size_t>(1 - actor)];
    Value *simulated_active = opponent.find("active");
    if (simulated_active == nullptr || !simulated_active->is_object()) return false;
    (*simulated_active)["damage_counters"] = Value(
        integer_field(*simulated_active, "damage_counters")
            + std::max<std::int64_t>(1, damage / 10));
    const std::int64_t after = best_potential_retaliation_damage(
        position, simulation, 1 - actor, cards);
    if (after >= position.pokemon_current_hp(*own_active)) return true;
    return damage < 100 && after > before + 30 && after >= 90;
}

inline double hand_size_plan(
    const Value &state,
    std::int32_t actor,
    const Value &cards,
    const std::string &deck_key
);

// _hand_size_attack_plan_value is a narrow public-state heuristic. The exact
// implementation is below after its helper declarations.
inline double hand_size_plan(
    const Value &state,
    std::int32_t actor,
    const Value &cards,
    const std::string &deck_key
) {
    const Value &owner = player(state, actor);
    const auto hand_size = static_cast<std::int64_t>(array_field(owner, "hand").size());
    double best = 0.0;
    for (const Value *pokemon : board(state, actor)) {
        const Value *definition = card(cards, string_field(*pokemon, "card_id"));
        if (definition == nullptr) continue;
        for (const Value &attack : array_field(*definition, "attacks")) {
            const auto missing = missing_energy(cards, *pokemon, array_field(attack, "cost"));
            double readiness = 0.0;
            if (missing == 0) readiness = 1.0;
            else if (missing == 1) readiness = 0.62;
            else if (missing == 2) readiness = 0.32;
            if (readiness <= 0.0) continue;
            for (const Value *effect : flatten_effects(array_field(attack, "effects"))) {
                const std::string kind = string_field(*effect, "effect_type");
                const Value *params = field(*effect, "params");
                if (params == nullptr) continue;
                if (kind == "damage_per_hand_size") {
                    const auto projected = hand_size * integer_field(*params, "per");
                    best = std::max(best, std::min(190.0,
                        static_cast<double>(projected) * 0.72 * readiness));
                } else if (kind == "discard_hand_conditional_bonus") {
                    const auto threshold = integer_field(*params, "threshold", 5);
                    const auto base = integer_field(*params, "base_damage",
                        integer_field(*params, "base"));
                    const auto bonus = integer_field(*params, "bonus");
                    const auto gap = std::max<std::int64_t>(0, threshold - hand_size);
                    const auto threshold_damage = base + bonus - gap * 34;
                    best = std::max(best, std::min(210.0,
                        static_cast<double>(threshold_damage) * 0.52 * readiness));
                }
            }
        }
    }
    if (best <= 0.0) return 0.0;
    if (deck_key == "colorless") best += 92.0 * 0.35;
    return best;
}

inline double status_lock(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value *pokemon,
    const Value &cards
) {
    if (pokemon == nullptr) return 0.0;
    double value = 0.0;
    const auto &statuses = array_field(*pokemon, "status_conditions");
    if (array_contains(statuses, "ASLEEP")) value += 35.0;
    if (array_contains(statuses, "PARALYZED")) value += 118.0;
    if (modifier_kind(pokemon, "attack_lock")) value += 118.0;
    if (modifier_kind(pokemon, "attack_gate_coin", "dazzled")) value += 45.0;
    if (value > 0.0) value += std::min(70.0,
        static_cast<double>(best_available_damage(position, state, actor, cards)) * 0.18);
    return value;
}

inline double protection(
    const RulesSession &position,
    const Value *pokemon
) {
    if (pokemon == nullptr) return 0.0;
    double value = 0.0;
    if (modifier_kind(pokemon, "prevent_effects")) {
        value += 126.0 + static_cast<double>(position.pokemon_current_hp(*pokemon)) * 0.18;
    } else if (modifier_kind(pokemon, "prevent_damage")) {
        value += 78.0 + static_cast<double>(position.pokemon_current_hp(*pokemon)) * 0.12;
    }
    const auto reduction = std::max<std::int64_t>(0, -modifier_sum(pokemon, "damage_delta"));
    if (reduction > 0) value -= std::min(80.0, static_cast<double>(reduction) * 1.5);
    return value;
}

inline double player_score(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &cards,
    const Value &decks
) {
    const Value &own = player(state, actor);
    const Value &opponent = player(state, 1 - actor);
    const std::string key = deck_key(state, actor);
    double score = active_prize_threat(position, state, actor, cards);
    score += ready_attackers(state, actor, cards, key);
    score += resource_outs(state, actor, cards, decks, key);
    score += hand_size_plan(state, actor, cards, key);
    score += protection(position, active(state, actor));
    score += status_lock(position, state, 1 - actor, active(state, 1 - actor), cards) * 0.45;
    score -= active_ko_risk(position, state, actor, cards, key);
    score -= status_lock(position, state, actor, active(state, actor), cards);
    score -= deck_pressure(own);
    const Value *own_active = active(state, actor);
    const Value *opponent_active = active(state, 1 - actor);
    if (own_active != nullptr && opponent_active != nullptr) {
        const auto own_prizes = array_field(own, "prizes").size();
        const auto opponent_prizes = array_field(opponent, "prizes").size();
        if (own_prizes <= 2 && best_available_damage(position, state, actor, cards)
            >= position.pokemon_current_hp(*opponent_active)) {
            score += static_cast<double>(3 - own_prizes) * 42.0;
        }
        if (opponent_prizes <= 2 && best_available_damage(position, state, 1 - actor, cards)
            >= position.pokemon_current_hp(*own_active)) {
            score -= static_cast<double>(3 - opponent_prizes) * 42.0;
        }
    }
    return score;
}

inline Value player_score_components(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &cards,
    const Value &decks
) {
    const Value &own = player(state, actor);
    const Value &opponent = player(state, 1 - actor);
    const std::string key = deck_key(state, actor);
    Value result = Value::make_object();
    result["active_prize_threat"] = Value(
        active_prize_threat(position, state, actor, cards));
    result["ready_attackers"] = Value(
        ready_attackers(state, actor, cards, key));
    result["resource_outs"] = Value(
        resource_outs(state, actor, cards, decks, key));
    result["hand_size_plan"] = Value(
        hand_size_plan(state, actor, cards, key));
    result["protection"] = Value(protection(position, active(state, actor)));
    result["opponent_status_bonus"] = Value(
        status_lock(position, state, 1 - actor, active(state, 1 - actor), cards)
        * 0.45);
    result["active_ko_risk"] = Value(
        -active_ko_risk(position, state, actor, cards, key));
    result["own_status"] = Value(
        -status_lock(position, state, actor, active(state, actor), cards));
    result["deck_pressure"] = Value(-deck_pressure(own));
    double closeout = 0.0;
    const Value *own_active = active(state, actor);
    const Value *opponent_active = active(state, 1 - actor);
    if (own_active != nullptr && opponent_active != nullptr) {
        const auto own_prizes = array_field(own, "prizes").size();
        const auto opponent_prizes = array_field(opponent, "prizes").size();
        if (own_prizes <= 2 && best_available_damage(position, state, actor, cards)
            >= position.pokemon_current_hp(*opponent_active)) {
            closeout += static_cast<double>(3 - own_prizes) * 42.0;
        }
        if (opponent_prizes <= 2
            && best_available_damage(position, state, 1 - actor, cards)
                >= position.pokemon_current_hp(*own_active)) {
            closeout -= static_cast<double>(3 - opponent_prizes) * 42.0;
        }
    }
    result["closeout"] = Value(closeout);
    result["total"] = Value(player_score(
        position, state, actor, cards, decks));
    return result;
}

} // namespace ptcg::ai::traditional_trusted_detail
