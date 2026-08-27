#include "ptcg_traditional_evaluation_detail.hpp"

namespace ptcg::ai::traditional_trusted_detail {

Value::Array expand_deck(const Value &decks, const std::string &key){
    const Value *definition = decks.find(key);
    if (definition == nullptr) return {};
    const Value *rows = definition->is_object() ? field(*definition, "cards") : nullptr;
    if (definition->is_array()) return definition->as_array();
    if (rows == nullptr || !rows->is_array()) return {};
    Value::Array result;
    for (const Value &row : rows->as_array()) {
        const std::string id = string_field(row, "card_id");
        for (std::int64_t copy = 0; copy < integer_field(row, "count"); ++copy) result.emplace_back(id);
    }
    return result;
}

std::vector<std::string> pre_evolution_ids(
    const Value &cards,
    const Value &decks,
    const std::string &card_id,
    const std::string &key
){
    const Value *definition = card(cards, card_id);
    const std::string previous = definition == nullptr
        ? std::string{} : string_field(*definition, "evolves_from");
    std::vector<std::string> result;
    if (previous.empty() || key.empty()) return result;
    for (const Value &candidate_value : expand_deck(decks, key)) {
        const std::string candidate = candidate_value.string_or();
        if (contains(result, candidate)) continue;
        const Value *candidate_card = card(cards, candidate);
        if (candidate_card != nullptr && is_pokemon(cards, candidate)
            && string_field(*candidate_card, "name", candidate) == previous) result.push_back(candidate);
    }
    return result;
}

LineParts line_parts(
    const Value &cards,
    const Value &decks,
    const std::string &core,
    const std::string &key
){
    LineParts result;
    if (is_stage2(cards, core)) {
        result.stage1 = pre_evolution_ids(cards, decks, core, key);
        for (const std::string &stage1 : result.stage1) {
            for (const std::string &basic : pre_evolution_ids(cards, decks, stage1, key)) {
                if (!contains(result.basic, basic)) result.basic.push_back(basic);
            }
        }
    } else if (is_stage1(cards, core)) {
        result.basic = pre_evolution_ids(cards, decks, core, key);
    }
    return result;
}

bool zone_has(const Value::Array &zone, const std::vector<std::string> &ids){
    return std::any_of(zone.begin(), zone.end(), [&ids](const Value &entry) {
        return contains(ids, entry.string_or());
    });
}

bool in_play(const Value &state, std::int32_t actor, const std::vector<std::string> &ids){
    const auto rows = board(state, actor);
    return std::any_of(rows.begin(), rows.end(),
        [&ids](const Value *pokemon) { return contains(ids, string_field(*pokemon, "card_id")); });
}

std::string primary_core(
    const Value &cards,
    const Value &decks,
    const std::string &key
){
    for (const std::string &core : profile(key).core) {
        if (!is_pokemon(cards, core)) continue;
        const LineParts parts = line_parts(cards, decks, core, key);
        if (!parts.stage1.empty() || !parts.basic.empty()) return core;
    }
    return {};
}

double active_evolve_blocking_penalty(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &evolve_target,
    const std::string &evolved_card_id,
    const std::string &key,
    const Value &cards,
    const Value &decks
){
    const std::string primary = primary_core(cards, decks, key);
    if (
        primary.empty() || evolved_card_id == primary
        || !contains(profile(key).core, evolved_card_id)
    ) return 0.0;

    Value evolved = evolve_target;
    Value *stack = evolved.find("evolution_stack_ids");
    if (stack == nullptr || !stack->is_array()) {
        evolved["evolution_stack_ids"] = Value::make_array();
        stack = evolved.find("evolution_stack_ids");
    }
    stack->as_array().emplace_back(string_field(evolve_target, "card_id"));
    evolved["card_id"] = Value(evolved_card_id);
    const std::int64_t evolved_ready = best_ready_damage_for_pokemon(
        position, state, actor, evolved, "active", cards);
    if (evolved_ready >= profile(key).high_impact_damage_floor) return 0.0;

    const Value *before_definition = card(
        cards, string_field(evolve_target, "card_id"));
    const Value *after_definition = card(cards, evolved_card_id);
    if (before_definition == nullptr || after_definition == nullptr) return 0.0;
    const std::int64_t before_retreat = integer_field(
        *before_definition, "retreat_cost");
    const std::int64_t after_retreat = integer_field(
        *after_definition, "retreat_cost");
    const std::int64_t attached = energy_unit_count(cards, &evolve_target);
    double penalty = 0.0;
    if (after_retreat > before_retreat) {
        penalty += 115.0
            + static_cast<double>(after_retreat - before_retreat) * 55.0;
    }
    if (after_retreat > attached) penalty += 90.0;

    const LineParts primary_parts = line_parts(cards, decks, primary, key);
    std::vector<std::string> primary_ids{primary};
    primary_ids.insert(
        primary_ids.end(),
        primary_parts.stage1.begin(), primary_parts.stage1.end());
    primary_ids.insert(
        primary_ids.end(),
        primary_parts.basic.begin(), primary_parts.basic.end());
    const Value &owner = player(state, actor);
    if (
        in_play(state, actor, primary_ids)
        || zone_has(array_field(owner, "hand"), primary_ids)
        || zone_has(array_field(owner, "deck"), primary_ids)
    ) penalty += 115.0;

    const auto &bench = array_field(owner, "bench");
    for (std::size_t index = 0; index < bench.size(); ++index) {
        if (!bench[index].is_object()) continue;
        const std::string slot = "bench_" + std::to_string(index);
        const std::int64_t ready = best_ready_damage_for_pokemon(
            position, state, actor, bench[index], slot, cards);
        const std::int64_t missing = best_missing(cards, &bench[index]);
        if (
            ready >= std::max<std::int64_t>(80, evolved_ready + 40)
            || (
                contains(primary_ids, string_field(bench[index], "card_id"))
                && (energy_unit_count(cards, &bench[index]) >= 1 || missing <= 1)
            )
        ) {
            penalty += 115.0;
            break;
        }
    }
    if (after_retreat >= 2 && evolved_ready <= 40) penalty += 70.0;
    return std::min(430.0, penalty);
}

double promotion_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &pokemon,
    const std::string &slot,
    const std::string &key,
    const Value &cards
){
    const std::int64_t missing = best_missing(cards, &pokemon);
    const std::int64_t ready_damage = best_ready_damage_for_pokemon(
        position, state, actor, pokemon, slot, cards);
    const std::int64_t energy_count = energy_unit_count(cards, &pokemon);
    const std::int64_t current_hp = position.pokemon_current_hp(pokemon);
    double value = static_cast<double>(current_hp)
        + static_cast<double>(ready_damage) * 2.0
        + static_cast<double>(energy_count) * 35.0;
    const Value *opponent_active = active(state, 1 - actor);
    const bool can_take_prize = opponent_active != nullptr
        && ready_damage >= position.pokemon_current_hp(*opponent_active);
    if (missing == 0) {
        value += 140.0 + static_cast<double>(ready_damage) * 0.85;
        if (can_take_prize) {
            const Value *definition = card(
                cards, string_field(*opponent_active, "card_id"));
            value += 420.0 + static_cast<double>(definition == nullptr
                ? 1 : integer_field(*definition, "prize_value", 1)) * 180.0;
        }
    } else if (missing == 1) {
        value += 55.0
            + static_cast<double>(printed_best_damage(cards, &pokemon)) * 0.20;
    } else {
        value -= std::min(120.0, static_cast<double>(missing) * 35.0);
    }
    value += static_cast<double>(energy_count) * 18.0;

    Value simulation = state;
    Value *players = simulation.find("players");
    std::int64_t opponent_damage = 0;
    if (
        players != nullptr && players->is_array() && actor >= 0
        && static_cast<std::size_t>(actor) < players->as_array().size()
    ) {
        Value &owner = players->as_array()[static_cast<std::size_t>(actor)];
        if (slot == "active") {
            opponent_damage = best_available_damage(
                position, simulation, 1 - actor, cards);
        }
        Value original_active = field(owner, "active") == nullptr
            ? Value() : *field(owner, "active");
        if (slot.rfind("bench_", 0) == 0) {
            std::int64_t index = -1;
            try {
                index = std::stoll(slot.substr(6));
            } catch (const std::exception &) {
                index = -1;
            }
            Value *bench = owner.find("bench");
            if (
                bench != nullptr && bench->is_array() && index >= 0
                && static_cast<std::size_t>(index) < bench->as_array().size()
            ) {
                bench->as_array()[static_cast<std::size_t>(index)] =
                    std::move(original_active);
                owner["active"] = pokemon;
                opponent_damage = best_available_damage(
                    position, simulation, 1 - actor, cards);
            }
        }
    }
    const bool survives = opponent_damage <= 0 || opponent_damage < current_hp;
    if (survives) {
        value += 90.0 + static_cast<double>(ready_damage) * 0.35
            + static_cast<double>(current_hp) * 0.18;
    } else {
        const Value *definition = card(cards, string_field(pokemon, "card_id"));
        const double asset = card_priority(
            cards, string_field(pokemon, "card_id"), key)
            + static_cast<double>(energy_count) * 45.0
            + static_cast<double>(array_field(
                pokemon, "evolution_stack_ids").size()) * 45.0
            + static_cast<double>(definition == nullptr
                ? 1 : integer_field(*definition, "prize_value", 1)) * 120.0;
        value -= std::min(260.0, asset * 0.35);
    }
    if (opponent_damage >= current_hp) {
        value -= 85.0;
        if (!can_take_prize) {
            value -= 90.0;
            const std::string card_id = string_field(pokemon, "card_id");
            if (contains(profile(key).core, card_id)) value -= 85.0;
            if (contains(profile(key).engine, card_id)) value -= 45.0;
        }
    }
    if (
        missing > 0
        && contains(profile(key).bench, string_field(pokemon, "card_id"))
        && !contains(profile(key).setup, string_field(pokemon, "card_id"))
    ) {
        value -= 70.0 + std::min(
            80.0, static_cast<double>(missing) * 24.0);
    }
    return value;
}

bool redundant_same_pokemon_retreat(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &active_pokemon,
    const Value &target,
    const std::string &target_slot,
    const std::string &key,
    const Value &cards
){
    if (string_field(target, "card_id")
        != string_field(active_pokemon, "card_id")) return false;
    if (!array_field(active_pokemon, "status_conditions").empty()
        || integer_field(active_pokemon, "paralyzed_since_turn") > 0) {
        return false;
    }
    for (const Value &modifier : array_field(active_pokemon, "modifiers")) {
        const std::string duration = string_field(modifier, "duration");
        if (duration != "persistent" && duration != "until_leave_play") {
            return false;
        }
    }
    if (position.pokemon_current_hp(target)
        > position.pokemon_current_hp(active_pokemon)) return false;
    const std::int64_t active_ready = best_ready_damage_for_pokemon(
        position, state, actor, active_pokemon, "active", cards);
    const std::int64_t target_ready = best_ready_damage_for_pokemon(
        position, state, actor, target, target_slot, cards);
    if (target_ready > active_ready) return false;
    const double active_value = promotion_value(
        position, state, actor, active_pokemon, "active", key, cards);
    const double target_value = promotion_value(
        position, state, actor, target, target_slot, key, cards);
    return target_value <= active_value + 0.001;
}

bool retreat_has_good_target(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &active_pokemon,
    const Value &target,
    const std::string &target_slot,
    const std::string &key,
    const Value &cards
){
    if (redundant_same_pokemon_retreat(
        position, state, actor, active_pokemon,
        target, target_slot, key, cards)) return false;
    const Value *opponent_active = active(state, 1 - actor);
    const std::int64_t target_ready = best_ready_damage_for_pokemon(
        position, state, actor, target, target_slot, cards);
    const std::int64_t active_ready = best_ready_damage_for_pokemon(
        position, state, actor, active_pokemon, "active", cards);
    if (
        opponent_active != nullptr
        && target_ready >= position.pokemon_current_hp(*opponent_active)
        && active_ready < position.pokemon_current_hp(*opponent_active)
    ) return true;
    const std::int64_t opponent_damage = best_available_damage(
        position, state, 1 - actor, cards);
    const bool active_survives = opponent_damage
        < position.pokemon_current_hp(active_pokemon);
    const bool target_falls = opponent_damage >= position.pokemon_current_hp(target);
    if (active_survives && target_falls) return false;
    const std::string target_id = string_field(target, "card_id");
    const bool target_is_core = contains(profile(key).core, target_id);
    const bool target_is_engine = contains(profile(key).engine, target_id)
        || contains(profile(key).bench, target_id);
    const Value *active_definition = card(
        cards, string_field(active_pokemon, "card_id"));
    const std::int64_t max_hp = active_definition == nullptr
        ? 0 : integer_field(*active_definition, "hp");
    const bool active_safe = array_field(
        active_pokemon, "status_conditions").empty()
        && static_cast<double>(position.pokemon_current_hp(active_pokemon))
            > std::max(50.0, static_cast<double>(max_hp) * 0.45);
    if (active_safe && !target_is_core && target_is_engine && target_ready < 70) {
        return false;
    }
    const double active_value = promotion_value(
        position, state, actor, active_pokemon, "active", key, cards);
    const double target_value = promotion_value(
        position, state, actor, target, target_slot, key, cards);
    if (
        !array_field(active_pokemon, "status_conditions").empty()
        || static_cast<double>(position.pokemon_current_hp(active_pokemon))
            <= std::max(40.0, static_cast<double>(max_hp) * 0.35)
    ) return target_value > active_value - 20.0;
    return target_value > active_value + 25.0;
}

double focus_multiplier(
    const Value &state,
    std::int32_t actor,
    const Value &cards,
    const Value &decks,
    const std::string &core,
    const std::string &key
){
    const std::string primary = primary_core(cards, decks, key);
    if (primary.empty() || core == primary) return 1.0;
    if (in_play(state, actor, {primary})) return 0.72;
    LineParts parts = line_parts(cards, decks, primary, key);
    std::vector<std::string> ids{primary};
    ids.insert(ids.end(), parts.stage1.begin(), parts.stage1.end());
    ids.insert(ids.end(), parts.basic.begin(), parts.basic.end());
    const Value &owner = player(state, actor);
    if (in_play(state, actor, ids) || zone_has(array_field(owner, "hand"), ids)
        || zone_has(array_field(owner, "deck"), ids)) return 0.42;
    return 0.65;
}

double core_line_value(
    const Value &state,
    std::int32_t actor,
    const Value &cards,
    const Value &decks,
    const std::string &key
){
    if (key.empty()) return 0.0;
    const Value &owner = player(state, actor);
    double total = 0.0;
    for (const std::string &core : profile(key).core) {
        if (!is_pokemon(cards, core)) continue;
        const LineParts parts = line_parts(cards, decks, core, key);
        if (parts.stage1.empty() && parts.basic.empty()) continue;
        const bool has_core = in_play(state, actor, {core});
        const bool has_stage1 = in_play(state, actor, parts.stage1);
        const bool has_basic = in_play(state, actor, parts.basic);
        const bool core_available = zone_has(array_field(owner, "hand"), {core})
            || zone_has(array_field(owner, "deck"), {core});
        const bool stage1_available = zone_has(array_field(owner, "hand"), parts.stage1)
            || zone_has(array_field(owner, "deck"), parts.stage1);
        const bool basic_available = zone_has(array_field(owner, "hand"), parts.basic)
            || zone_has(array_field(owner, "deck"), parts.basic);
        double line = 0.0;
        if (has_core) line += 112.0;
        else if (has_stage1) { line += 86.0; if (core_available) line += 56.0; }
        else if (has_basic) {
            line += 62.0;
            if (stage1_available) line += 48.0;
            if (core_available) line += 22.0;
        } else if (basic_available) {
            line += 34.0;
            if (stage1_available) line += 18.0;
        }
        if (is_stage2(cards, core)) line *= 1.18;
        const Value *definition = card(cards, core);
        if (definition != nullptr && integer_field(*definition, "prize_value", 1) >= 2) line *= 1.1;
        line *= focus_multiplier(state, actor, cards, decks, core, key);
        total += std::min(165.0, line);
    }
    return std::min(260.0, total * 0.72 + 86.0 * 0.25);
}

double active_prize_threat(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &cards
){
    const Value *target = active(state, 1 - actor);
    if (target == nullptr) return 0.0;
    const auto damage = best_available_damage(position, state, actor, cards);
    if (damage <= 0) return 0.0;
    double value = std::min(90.0, static_cast<double>(damage) * 0.28);
    if (damage >= position.pokemon_current_hp(*target)) {
        const Value *definition = card(cards, string_field(*target, "card_id"));
        value += 170.0 + static_cast<double>(definition == nullptr
            ? 1 : integer_field(*definition, "prize_value", 1)) * 115.0;
    }
    return value;
}

double ready_attackers(
    const Value &state,
    std::int32_t actor,
    const Value &cards,
    const std::string &key
){
    double value = 0.0;
    const auto rows = board(state, actor);
    for (std::size_t index = 0; index < rows.size(); ++index) {
        const Value *pokemon = rows[index];
        const double multiplier = index == 0 && active(state, actor) == pokemon ? 1.0 : 0.45;
        const auto missing = best_missing(cards, pokemon);
        const auto damage = printed_best_damage(cards, pokemon);
        if (missing == 0 && damage > 0) {
            value += (58.0 + std::min(70.0, static_cast<double>(damage) * 0.22)) * multiplier;
        } else if (missing == 1 && damage >= profile(key).high_impact_damage_floor) {
            value += (34.0 + std::min(45.0, static_cast<double>(damage) * 0.12)) * multiplier;
        }
    }
    return value;
}

double active_ko_risk(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &cards,
    const std::string &key
){
    const Value *own_active = active(state, actor);
    if (own_active == nullptr) return 420.0;
    const auto opponent_damage = best_available_damage(position, state, 1 - actor, cards);
    if (opponent_damage <= 0) return 0.0;
    const auto hp = position.pokemon_current_hp(*own_active);
    if (opponent_damage < hp) return static_cast<double>(opponent_damage) >= static_cast<double>(hp) * 0.65
        ? 62.0 : 0.0;
    const Value *definition = card(cards, string_field(*own_active, "card_id"));
    double risk = 170.0 + static_cast<double>(definition == nullptr
        ? 1 : integer_field(*definition, "prize_value", 1)) * 105.0;
    risk += static_cast<double>(energy_unit_count(cards, own_active)) * 30.0;
    if (contains(profile(key).core, string_field(*own_active, "card_id"))) risk += 70.0;
    return risk;
}

bool has_energy_target(const Value &state, std::int32_t actor, const Value &cards){
    for (const Value *pokemon : board(state, actor)) {
        const auto best = best_missing(cards, pokemon);
        if (best > 0 && best < 99) return true;
        const Value *definition = card(cards, string_field(*pokemon, "card_id"));
        if (definition == nullptr) continue;
        for (const Value &attack : array_field(*definition, "attacks")) {
            const auto missing = missing_energy(cards, *pokemon, array_field(attack, "cost"));
            if (missing > 0 && missing <= 2) return true;
        }
    }
    return false;
}

double resource_outs(
    const Value &state,
    std::int32_t actor,
    const Value &cards,
    const Value &decks,
    const std::string &key
){
    const Value &owner = player(state, actor);
    double value = 0.0;
    if (has_energy_target(state, actor, cards)) {
        std::int64_t outs = 0;
        for (const char *zone : {"hand", "deck"}) {
            for (const Value &entry : array_field(owner, zone)) {
                const std::string id = entry.string_or();
                if (is_energy(cards, id) && (key.empty() || energy_matches_profile(cards, id, key))) ++outs;
            }
        }
        value += std::min(110.0, static_cast<double>(outs) * 32.0);
    }
    std::int64_t evolution_outs = 0;
    for (const Value *pokemon : board(state, actor)) {
        if (!bool_field(*pokemon, "can_evolve_this_turn", true)) continue;
        bool found = false;
        for (const char *zone : {"hand", "deck"}) {
            for (const Value &entry : array_field(owner, zone)) {
                const std::string id = entry.string_or();
                if (is_pokemon(cards, id) && contains(profile(key).evolution, id)
                    && card_priority(cards, id, key) > 0.0) { found = true; break; }
            }
            if (found) break;
        }
        if (found) ++evolution_outs;
    }
    value += std::min(90.0, static_cast<double>(evolution_outs) * 34.0);
    value += core_line_value(state, actor, cards, decks, key);
    return value;
}

std::int64_t count_in_play(
    const Value &state,
    std::int32_t actor,
    const std::vector<std::string> &ids
){
    std::int64_t count = 0;
    for (const Value *pokemon : board(state, actor)) {
        if (contains(ids, string_field(*pokemon, "card_id"))) ++count;
    }
    return count;
}

std::int64_t count_in_zone(
    const Value::Array &zone,
    const std::string &card_id
){
    return static_cast<std::int64_t>(std::count_if(
        zone.begin(), zone.end(), [&card_id](const Value &entry) {
            return entry.string_or() == card_id;
        }));
}

double core_evolution_line_card_bonus(
    const Value &state,
    std::int32_t actor,
    const std::string &card_id,
    const std::string &key,
    const Value &cards,
    const Value &decks,
    bool removing_one
){
    if (key.empty() || !is_pokemon(cards, card_id)) return 0.0;
    const Value &owner = player(state, actor);
    double best = 0.0;
    for (const std::string &core : profile(key).core) {
        if (core.empty() || !is_pokemon(cards, core)) continue;
        const LineParts parts = line_parts(cards, decks, core, key);
        if (parts.stage1.empty() && parts.basic.empty()) continue;
        const bool has_core = in_play(state, actor, {core});
        const bool has_stage1 = in_play(state, actor, parts.stage1);
        const bool has_basic = in_play(state, actor, parts.basic);
        const bool has_rare_candy = array_contains(
            array_field(owner, "hand"), "sv1-152");
        const std::int64_t stage1_count = count_in_play(
            state, actor, parts.stage1);
        const std::int64_t basic_count = count_in_play(
            state, actor, parts.basic);
        const std::int64_t receivers = is_stage2(cards, core)
            ? stage1_count + (has_rare_candy ? basic_count : 0)
            : basic_count;
        const std::int64_t core_supply = std::max<std::int64_t>(
            0, count_in_zone(array_field(owner, "hand"), core)
                - (removing_one && card_id == core ? 1 : 0));
        double bonus = 0.0;
        if (card_id == core) {
            const bool surplus = removing_one
                ? core_supply >= receivers : core_supply > receivers;
            if (surplus) bonus = -180.0;
            else if (is_stage2(cards, core)) {
                if (has_stage1) bonus = 170.0;
                else if (has_basic && has_rare_candy) bonus = 70.0;
                else if (has_basic) bonus = -35.0;
                else if (!has_core) bonus = -145.0;
                else bonus = -180.0;
            } else if (is_stage1(cards, core)) {
                if (has_basic) bonus = 130.0;
                else if (!has_core) bonus = -55.0;
                else bonus = -120.0;
            }
        } else if (contains(parts.stage1, card_id)) {
            const std::int64_t supply = std::max<std::int64_t>(
                0, count_in_zone(array_field(owner, "hand"), card_id)
                    - (removing_one ? 1 : 0));
            const bool surplus = removing_one
                ? supply >= basic_count : supply > basic_count;
            if (surplus) bonus = -120.0;
            else if (has_basic) bonus = 145.0;
            else if (!has_stage1 && !has_core) bonus = 25.0;
        } else if (contains(parts.basic, card_id)) {
            const std::int64_t supply_after = std::max<std::int64_t>(
                0, count_in_zone(array_field(owner, "hand"), card_id)
                    - (removing_one ? 1 : 0));
            if (
                removing_one && supply_after >= 1
                && !has_basic && !has_stage1 && !has_core
            ) bonus = -80.0;
            else if (!has_basic && !has_stage1 && !has_core) bonus = 155.0;
            else if (has_basic && !has_stage1 && !has_core) bonus = 55.0;
        }
        if (is_stage2(cards, core)) bonus *= 1.15;
        const Value *definition = card(cards, core);
        if (definition != nullptr
            && integer_field(*definition, "prize_value", 1) >= 2) bonus *= 1.1;
        bonus *= focus_multiplier(state, actor, cards, decks, core, key);
        if (std::abs(bonus) > std::abs(best)) best = bonus;
    }
    return best;
}

bool energy_improves_attack_readiness(
    const Value &state,
    std::int32_t actor,
    const std::string &energy_card_id,
    const Value &cards
){
    if (!is_energy(cards, energy_card_id)) return false;
    for (const Value *pokemon : board(state, actor)) {
        const Value *definition = card(cards, string_field(*pokemon, "card_id"));
        if (definition == nullptr) continue;
        const Value probe = pokemon_with_extra_energy(*pokemon, energy_card_id);
        for (const Value &attack : array_field(*definition, "attacks")) {
            const auto &cost = array_field(attack, "cost");
            const std::int64_t before = missing_energy(cards, *pokemon, cost);
            if (before > 0 && missing_energy(cards, probe, cost) < before) return true;
        }
    }
    return false;
}

std::int64_t helpful_hand_energy_count(
    const Value &state,
    std::int32_t actor,
    const Value &cards
){
    std::int64_t result = 0;
    for (const Value &entry : array_field(player(state, actor), "hand")) {
        if (energy_improves_attack_readiness(
            state, actor, entry.string_or(), cards)) ++result;
    }
    return result;
}

double lone_active_backup_search_bonus(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &cards
){
    const Value *own_active = active(state, actor);
    if (own_active == nullptr || bench_count(player(state, actor)) > 0) return 0.0;
    const Value *opponent_active = active(state, 1 - actor);
    if (opponent_active == nullptr) return 80.0;
    const std::int64_t hp = position.pokemon_current_hp(*own_active);
    const std::int64_t ready = best_available_damage(
        position, state, 1 - actor, cards);
    const std::int64_t potential = printed_best_damage(cards, opponent_active);
    const std::int64_t missing = best_missing(cards, opponent_active);
    return ready >= hp || (missing <= 1 && potential >= hp) ? 300.0 : 80.0;
}

bool has_core_basic_out_in_deck(
    const Value &state,
    std::int32_t actor,
    const std::string &key,
    const Value &cards
){
    if (key.empty()) return false;
    const DeckProfile &deck = profile(key);
    for (const Value &entry : array_field(player(state, actor), "deck")) {
        const std::string id = entry.string_or();
        if (is_basic_pokemon(cards, id)
            && (contains(deck.setup, id) || contains(deck.bench, id)
                || contains(deck.core, id))) return true;
    }
    return false;
}

double bench_setup_search_card_bonus(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const std::string &card_id,
    const std::string &key,
    const Value &cards
){
    const Value &owner = player(state, actor);
    if (bench_count(owner) >= 3) return 0.0;
    const Value *definition = card(cards, card_id);
    if (definition == nullptr) return 0.0;
    bool finds_basic = false;
    for (const Value *effect : flatten_effects(
        array_field(*definition, "trainer_effects"))) {
        const Value *params = field(*effect, "params");
        if (
            string_field(*effect, "effect_type") == "search"
            && params != nullptr && params->is_object()
            && string_field(*params, "destination") == "bench"
            && string_field(*params, "filter") == "basic_pokemon"
        ) {
            finds_basic = true;
            break;
        }
    }
    if (!finds_basic) return 0.0;
    std::int64_t basic_outs = 0;
    for (const Value &entry : array_field(owner, "deck")) {
        if (is_basic_pokemon(cards, entry.string_or())) ++basic_outs;
    }
    if (basic_outs <= 0) return 0.0;
    double value = 55.0 + std::min(
        80.0, static_cast<double>(basic_outs) * 10.0);
    if (bench_count(owner) == 0) value += 150.0;
    else if (bench_count(owner) == 1) value += 75.0;
    const Value *own_active = active(state, actor);
    if (own_active != nullptr
        && best_available_damage(position, state, 1 - actor, cards)
            >= position.pokemon_current_hp(*own_active)) value += 95.0;
    if (has_core_basic_out_in_deck(state, actor, key, cards)) value += 55.0;
    return value;
}

} // namespace ptcg::ai::traditional_trusted_detail
