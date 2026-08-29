#include "ptcg_traditional_evaluation_detail.hpp"

namespace ptcg::ai::traditional_trusted_detail {

std::string choice_option_card_id(
    const Value &option,
    const Value &cards
){
    const Value *reference = field(option, "ref");
    if (reference != nullptr && reference->is_object()) {
        const std::string id = string_field(*reference, "card_id");
        if (!id.empty()) return id;
    }
    const std::string option_id = string_field(option, "option_id");
    const std::size_t separator = option_id.rfind(':');
    if (separator != std::string::npos && separator + 1 < option_id.size()) {
        const std::string candidate = option_id.substr(separator + 1);
        if (card(cards, candidate) != nullptr) return candidate;
    }
    return {};
}

std::string choice_option_slot(const Value &option){
    const Value *reference = field(option, "ref");
    if (reference != nullptr && reference->is_object()) {
        const std::string slot = string_field(*reference, "slot");
        if (!slot.empty()) return slot;
    }
    const std::string id = string_field(option, "option_id");
    const std::size_t first = id.find(':');
    const std::size_t second = first == std::string::npos
        ? std::string::npos : id.find(':', first + 1);
    if (second == std::string::npos) return {};
    const std::string prefix = id.substr(0, first);
    return prefix == "pokemon" || prefix == "attachment"
        ? id.substr(second + 1) : std::string{};
}

std::int32_t choice_option_player(
    const Value &option,
    std::int32_t fallback
){
    const Value *reference = field(option, "ref");
    if (reference != nullptr && reference->is_object()
        && field(*reference, "player") != nullptr) {
        return static_cast<std::int32_t>(integer_field(*reference, "player", fallback));
    }
    const std::string id = string_field(option, "option_id");
    const std::size_t first = id.find(':');
    const std::size_t second = first == std::string::npos
        ? std::string::npos : id.find(':', first + 1);
    const std::string prefix = first == std::string::npos
        ? std::string{} : id.substr(0, first);
    if ((prefix != "pokemon" && prefix != "attachment")
        || second == std::string::npos) return fallback;
    try {
        return static_cast<std::int32_t>(std::stoll(
            id.substr(first + 1, second - first - 1)));
    } catch (const std::exception &) {
        return fallback;
    }
}

bool choice_option_is_hand_card(const Value &option){
    const Value *reference = field(option, "ref");
    if (reference != nullptr && reference->is_object()) {
        if (field(*reference, "zone") != nullptr) {
            return string_field(*reference, "zone") == "hand";
        }
        if (string_field(*reference, "kind") == "attachment") return false;
    }
    return true;
}

std::string choice_energy_card_id(
    const Value &presentation,
    const Value &cards
){
    for (const Value &entry : array_field(presentation, "card_ids")) {
        const std::string id = entry.string_or();
        if (is_energy(cards, id)) return id;
    }
    const std::string id = string_field(presentation, "card_id");
    return is_energy(cards, id) ? id : std::string{};
}

std::string choice_option_energy_card_id(
    const Value &option,
    const Value &cards
){
    const std::string id = string_field(option, "option_id");
    constexpr std::string_view prefix = "energy:";
    if (id.rfind(prefix, 0) != 0) return {};
    const std::size_t index_separator = id.find(':', prefix.size());
    const std::size_t target_separator = index_separator == std::string::npos
        ? std::string::npos : id.find("->", index_separator + 1);
    if (index_separator == std::string::npos
        || target_separator == std::string::npos
        || target_separator <= index_separator + 1) return {};
    const std::string card_id = id.substr(
        index_separator + 1, target_separator - index_separator - 1);
    return is_energy(cards, card_id) ? card_id : std::string{};
}

std::string choice_score_mode(
    const Value &choice,
    std::int32_t actor
){
    const Value *presentation_value = field(choice, "presentation");
    static const Value empty = Value::make_object();
    const Value &presentation = presentation_value != nullptr
        && presentation_value->is_object() ? *presentation_value : empty;
    const std::string request = string_field(choice, "request_type");
    const std::string purpose = string_field(presentation, "purpose");
    if (request == "select_attachment") {
        if (purpose == "discard_energy" || purpose == "discard_energy_attachments") {
            return integer_field(presentation, "source_player", actor) == actor
                ? "energy_source" : "target";
        }
        return purpose.rfind("energy_relocate", 0) == 0
            || purpose.rfind("relocate_energy", 0) == 0
            ? "energy_source" : "discard";
    }
    static const std::set<std::string> discard_purposes{
        "discard_then_draw", "discard_hand_then_draw", "discard_cards",
        "hand_bottom_draw", "houb", "zinnia",
    };
    if (discard_purposes.count(purpose)) return "discard";
    if (request == "select_energy_source" || purpose == "energy_relocate_source") {
        return "energy_source";
    }
    if (request == "select_energy_target" || request == "distribute_energy"
        || request == "look_top_attach_energy") return "energy";
    if (request == "select_heal_target" || purpose == "heal") return "heal";
    if (
        request == "select_opponent_bench" || request == "bench_damage_target"
        || request == "damage_target" || request == "place_counters_self_discard"
    ) return "target";
    if (request == "select_bench"
        && (purpose == "switch" || purpose == "search_any_switch_bench")) {
        return "self_switch";
    }
    if (purpose == "discard" || purpose == "discard_cost"
        || purpose == "bottom_deck") return "discard";
    return "search";
}

bool discard_fuels_damage_plan(
    const Value &state,
    std::int32_t actor,
    const std::string &card_id,
    const Value &cards
){
    const Value *discarded = card(cards, card_id);
    if (discarded == nullptr || !is_pokemon(cards, card_id)
        || !array_contains(array_field(*discarded, "energy_types"), "Psychic")) {
        return false;
    }
    std::vector<std::string> attacker_ids;
    for (const Value *pokemon : board(state, actor)) {
        attacker_ids.push_back(string_field(*pokemon, "card_id"));
    }
    const Value &owner = player(state, actor);
    for (const char *zone : {"hand", "deck", "discard"}) {
        for (const Value &entry : array_field(owner, zone)) {
            if (is_pokemon(cards, entry.string_or())) {
                attacker_ids.push_back(entry.string_or());
            }
        }
    }
    for (const std::string &attacker_id : attacker_ids) {
        const Value *definition = card(cards, attacker_id);
        if (definition == nullptr) continue;
        for (const Value &attack : array_field(*definition, "attacks")) {
            for (const Value *effect : flatten_effects(array_field(attack, "effects"))) {
                if (string_field(*effect, "effect_type")
                    == "damage_per_discard_psychic") return true;
            }
        }
    }
    return false;
}

double discard_choice_score(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const std::string &card_id,
    const std::string &key,
    const Value &cards,
    const Value &decks,
    bool removing_from_hand
){
    const Value &owner = player(state, actor);
    double score = -card_keep_value(
        position, state, actor, card_id, key,
        cards, decks, removing_from_hand);
    if (removing_from_hand) {
        const std::int64_t duplicates = count_in_zone(
            array_field(owner, "hand"), card_id);
        if (duplicates > 1) score += std::min(
            120.0, static_cast<double>(duplicates - 1) * 55.0);
        if (is_energy(cards, card_id)
            && bool_field(owner, "energy_attached_this_turn")) score += 35.0;
        const Value *definition = card(cards, card_id);
        if (definition != nullptr && is_trainer(cards, card_id)
            && bool_field(owner, "supporter_played_this_turn")
            && has_subtype(*definition, "Supporter")) score += 30.0;
    }
    if (discard_fuels_damage_plan(state, actor, card_id, cards)) score += 76.0;
    return score;
}

double energy_choice_target_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const std::string &slot,
    const std::string &energy_card_id,
    const std::string &key,
    const Value &cards
){
    const Value *pokemon = pokemon_at(player(state, actor), slot);
    if (pokemon == nullptr) return -std::numeric_limits<double>::infinity();
    const bool has_energy = !energy_card_id.empty()
        && is_energy(cards, energy_card_id);
    const std::int64_t before = best_missing(cards, pokemon);
    const Value probe = has_energy
        ? pokemon_with_extra_energy(*pokemon, energy_card_id) : *pokemon;
    const std::int64_t after = has_energy ? best_missing(cards, &probe) : before;
    const std::int64_t progress = std::max<std::int64_t>(0, before - after);
    const std::int64_t power_before = high_impact_missing_energy(
        position, state, actor, *pokemon, slot, {}, cards);
    const std::int64_t power_after = has_energy
        ? high_impact_missing_energy(
            position, state, actor, *pokemon, slot, energy_card_id, cards)
        : power_before;
    const std::int64_t power_progress = std::max<std::int64_t>(
        0, power_before - power_after);
    const std::int64_t damage = best_pokemon_damage_for_state(
        position, state, actor, *pokemon, slot, cards);
    const std::int64_t ready_after = best_ready_damage_for_pokemon(
        position, state, actor, probe, slot, cards);
    const DeckProfile deck = profile(cards, key);
    double value = static_cast<double>(progress) * 85.0;
    if (before > 0 && after == 0) {
        value += ready_after <= 0 && power_after > 0
            ? 55.0 : 155.0 + static_cast<double>(damage) * 0.25;
    } else if (before > 1 && after == 1) value += 65.0;
    if (damage >= deck.high_impact_damage_floor() && power_progress > 0) {
        value += static_cast<double>(power_progress) * 105.0;
        if (power_after == 0) value += 165.0 + static_cast<double>(damage) * 0.25;
        else if (power_after == 1) value += 115.0;
    }
    if (deck.contains("core", string_field(*pokemon, "card_id"))) value += 65.0;
    value += energy_plan_target_bonus(
        position, state, actor, *pokemon, slot,
        energy_card_id, key, cards);
    if (before == 0 && progress == 0 && power_progress == 0) value -= 60.0;
    if (slot == "active") value += 28.0;
    return value;
}

double energy_source_choice_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const std::string &slot,
    const Value &presentation,
    const std::string &key,
    const Value &cards
){
    const Value *pokemon = pokemon_at(player(state, actor), slot);
    if (pokemon == nullptr) return -std::numeric_limits<double>::infinity();
    const auto &attached = array_field(*pokemon, "energy_card_ids");
    std::size_t energy_index = attached.size();
    const std::string energy_type = string_field(presentation, "energy_type", "any");
    for (std::size_t index = 0; index < attached.size(); ++index) {
        if (energy_card_matches_type_at(cards, attached, index, energy_type)) {
            energy_index = index;
            break;
        }
    }
    if (energy_index >= attached.size()) {
        return -std::numeric_limits<double>::infinity();
    }
    const std::int64_t before_missing = best_missing(cards, pokemon);
    const std::int64_t before_high = high_impact_missing_energy(
        position, state, actor, *pokemon, slot, {}, cards);
    const std::int64_t before_ready = best_ready_damage_for_pokemon(
        position, state, actor, *pokemon, slot, cards);
    const std::int64_t damage = best_pokemon_damage_for_state(
        position, state, actor, *pokemon, slot, cards);
    Value probe = *pokemon;
    Value::Array kept = attached;
    kept.erase(kept.begin() + static_cast<std::ptrdiff_t>(energy_index));
    probe["energy_card_ids"] = Value(std::move(kept));
    const std::int64_t after_missing = best_missing(cards, &probe);
    const std::int64_t after_high = high_impact_missing_energy(
        position, state, actor, probe, slot, {}, cards);
    const std::int64_t after_ready = best_ready_damage_for_pokemon(
        position, state, actor, probe, slot, cards);
    double cost = 0.0;
    if (before_missing == 0 && after_missing > 0) {
        cost += 220.0 + static_cast<double>(std::max(before_ready, damage)) * 0.45;
    } else if (after_missing > before_missing) {
        cost += static_cast<double>(after_missing - before_missing) * 95.0;
    }
    const DeckProfile deck = profile(cards, key);
    if (damage >= deck.high_impact_damage_floor()
        && before_high == 0 && after_high > 0) {
        cost += 190.0 + static_cast<double>(damage) * 0.35;
    } else if (after_high > before_high) {
        cost += static_cast<double>(after_high - before_high) * 70.0;
    }
    cost += static_cast<double>(std::max<std::int64_t>(
        0, before_ready - after_ready)) * 0.55;
    if (slot == "active") {
        cost += 80.0;
        if (before_ready > 0) {
            cost += 60.0 + static_cast<double>(before_ready) * 0.35;
        }
        const Value *definition = card(cards, string_field(*pokemon, "card_id"));
        const std::int64_t max_hp = definition == nullptr
            ? 0 : integer_field(*definition, "hp");
        if (static_cast<double>(position.pokemon_current_hp(*pokemon))
            <= std::max(40.0, static_cast<double>(max_hp) * 0.35)) cost -= 60.0;
    }
    const std::string pokemon_id = string_field(*pokemon, "card_id");
    if (deck.contains("core", pokemon_id)) cost += 65.0;
    if (deck.contains("engine", pokemon_id) && !deck.contains("core", pokemon_id)) {
        cost -= 35.0;
    }
    if (energy_unit_count(cards, pokemon) >= 3
        && after_missing == 0 && after_ready >= before_ready) cost -= 100.0;
    else if (before_missing >= 2 && before_high >= 2) cost -= 45.0;
    return -cost;
}

double switch_opponent_attack_route_bonus(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    std::int32_t target_player,
    const Value &target,
    std::string target_slot,
    const Value &cards
){
    std::replace(target_slot.begin(), target_slot.end(), ':', '_');
    if (target_player != 1 - actor || target_slot.rfind("bench_", 0) != 0) {
        return 0.0;
    }
    std::int64_t bench_index = -1;
    try { bench_index = std::stoll(target_slot.substr(6)); }
    catch (const std::exception &) { return 0.0; }
    Value simulation = state;
    Value *players = simulation.find("players");
    if (players == nullptr || !players->is_array()
        || static_cast<std::size_t>(target_player) >= players->as_array().size()) {
        return 0.0;
    }
    Value &opponent = players->as_array()[static_cast<std::size_t>(target_player)];
    Value *bench = opponent.find("bench");
    Value *active_value = opponent.find("active");
    if (bench == nullptr || !bench->is_array() || active_value == nullptr
        || !active_value->is_object() || bench_index < 0
        || static_cast<std::size_t>(bench_index) >= bench->as_array().size()) {
        return 0.0;
    }
    Value original_active = *active_value;
    *active_value = target;
    bench->as_array()[static_cast<std::size_t>(bench_index)] = std::move(original_active);
    const Value *attacker = active(simulation, actor);
    const std::int64_t damage = attacker == nullptr ? 0
        : best_ready_damage_for_pokemon(
            position, simulation, actor, *attacker, "active", cards);
    if (damage <= 0) return 0.0;
    const std::int64_t hp = position.pokemon_current_hp(target);
    if (damage >= hp) {
        const Value *definition = card(cards, string_field(target, "card_id"));
        return 1100.0 + static_cast<double>(definition == nullptr
            ? 1 : integer_field(*definition, "prize_value", 1)) * 430.0
            - static_cast<double>(std::max<std::int64_t>(0, damage - hp)) * 0.25;
    }
    return static_cast<double>(std::min(damage, hp)) * 1.4;
}

double target_choice_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &choice,
    std::int32_t target_player,
    const Value &pokemon,
    const std::string &slot,
    const Value &presentation,
    const Value &cards
){
    const std::int64_t amount = std::max<std::int64_t>(
        0, integer_field(presentation, "amount"));
    double value = tactical_target_priority(position, pokemon, cards);
    if (string_field(choice, "request_type") == "select_opponent_bench"
        || string_field(presentation, "purpose") == "switch_opponent") {
        value += switch_opponent_attack_route_bonus(
            position, state, actor, target_player, pokemon, slot, cards);
    }
    if (amount <= 0) return value;
    const std::int64_t hp = position.pokemon_current_hp(pokemon);
    value += static_cast<double>(std::min(amount, hp)) * 2.5;
    if (amount >= hp) {
        const Value *definition = card(cards, string_field(pokemon, "card_id"));
        value += 900.0 + static_cast<double>(definition == nullptr
            ? 1 : integer_field(*definition, "prize_value", 1)) * 420.0;
        value -= static_cast<double>(std::max<std::int64_t>(0, amount - hp)) * 0.4;
    }
    if (string_field(presentation, "purpose") == "place_counters_self_discard"
        && string_field(presentation, "source_card_id") == "sv2-starm"
        && integer_field(presentation, "source_player", actor) == actor
        && target_player == 1 - actor && slot == "active") {
        value += starmie_torrent_followup_value(
            position, state, actor,
            string_field(presentation, "source_slot"), cards);
    }
    return value;
}

std::optional<double> base_choice_option_score(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &choice,
    const Value &option,
    const Value &cards,
    const Value &decks
){
    if (actor != 0 && actor != 1) return std::nullopt;
    const Value *presentation_value = field(choice, "presentation");
    static const Value empty = Value::make_object();
    const Value &presentation = presentation_value != nullptr
        && presentation_value->is_object() ? *presentation_value : empty;
    const std::string key = deck_key(state, actor);
    const std::string mode = choice_score_mode(choice, actor);
    const std::string card_id = choice_option_card_id(option, cards);
    if (mode == "discard") return discard_choice_score(
        position, state, actor, card_id, key, cards, decks,
        choice_option_is_hand_card(option));
    const std::string slot = choice_option_slot(option);
    const std::int32_t target_player = choice_option_player(option, actor);
    if (mode == "energy_source") return energy_source_choice_value(
        position, state, target_player, slot, presentation, key, cards);
    double score = mode == "search" ? card_keep_value(
        position, state, actor, card_id, key, cards, decks) : 0.0;
    const Value *pokemon = pokemon_at(player(state, target_player), slot);
    if (pokemon == nullptr) return score;
    if (mode == "target" || target_player != actor) {
        score += target_choice_value(
            position, state, actor, choice, target_player,
            *pokemon, slot, presentation, cards);
    } else if (mode == "heal") {
        score += static_cast<double>(integer_field(*pokemon, "damage_counters")) * 30.0;
    } else if (mode == "energy") {
        std::string energy_id = choice_option_energy_card_id(option, cards);
        if (energy_id.empty()) energy_id = choice_energy_card_id(presentation, cards);
        score += energy_choice_target_value(
            position, state, target_player, slot, energy_id, key, cards);
    } else if (mode == "self_switch") {
        score += promotion_value(
            position, state, target_player, *pokemon, slot, key, cards);
    } else {
        score += static_cast<double>(energy_unit_count(cards, pokemon)) * 12.0;
        if (slot == "active") score += 20.0;
    }
    return score;
}

std::vector<std::string> energy_plan_evolution_descendants(
    const Value &cards,
    const Value &decks,
    const std::string &source_card_id,
    const std::string &key
){
    std::vector<std::string> result;
    if (key.empty() || source_card_id.empty()) return result;
    const Value::Array deck_cards = expand_deck(decks, key);
    std::vector<std::string> frontier{source_card_id};
    std::set<std::string> seen{source_card_id};
    for (std::size_t depth = 0; depth < 2; ++depth) {
        std::vector<std::string> next;
        for (const std::string &parent_id : frontier) {
            const Value *parent = card(cards, parent_id);
            const std::string parent_name = parent == nullptr
                ? parent_id : string_field(*parent, "name", parent_id);
            for (const Value &candidate_value : deck_cards) {
                const std::string candidate_id = candidate_value.string_or();
                if (seen.count(candidate_id) || !is_pokemon(cards, candidate_id)) {
                    continue;
                }
                const Value *candidate = card(cards, candidate_id);
                if (candidate == nullptr
                    || string_field(*candidate, "evolves_from") != parent_name) {
                    continue;
                }
                seen.insert(candidate_id);
                result.push_back(candidate_id);
                next.push_back(candidate_id);
            }
        }
        frontier = std::move(next);
        if (frontier.empty()) break;
    }
    return result;
}

double energy_attack_plan_for_card(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &source,
    const std::string &slot,
    const std::string &card_id,
    std::int64_t opponent_hp,
    std::int64_t opponent_prizes,
    const Value &cards
){
    const Value *definition = card(cards, card_id);
    const auto &attacks = definition == nullptr
        ? Value::Array{} : array_field(*definition, "attacks");
    if (attacks.empty()) return -99.0;
    Value probe = source;
    if (card_id != string_field(source, "card_id")) {
        Value *stack = probe.find("evolution_stack_ids");
        if (stack == nullptr || !stack->is_array()) {
            probe["evolution_stack_ids"] = Value::make_array();
            stack = probe.find("evolution_stack_ids");
        }
        stack->as_array().emplace_back(string_field(source, "card_id"));
        probe["card_id"] = Value(card_id);
    }
    double best = -std::numeric_limits<double>::infinity();
    for (std::size_t index = 0; index < attacks.size(); ++index) {
        const std::int64_t missing = missing_energy(
            cards, probe, array_field(attacks[index], "cost"));
        const std::int64_t damage = estimated_damage_for_pokemon(
            position, state, actor, probe, slot, index, cards);
        double value = static_cast<double>(damage)
            - static_cast<double>(missing) * 50.0;
        if (missing == 0 && damage > 0) {
            value += 80.0;
            if (opponent_hp > 0 && damage >= opponent_hp) {
                value += 220.0 + static_cast<double>(opponent_prizes) * 100.0;
            }
        }
        best = std::max(best, value);
    }
    return best;
}

double energy_attack_plan_utility(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &pokemon,
    const std::string &slot,
    const std::string &key,
    const Value &cards,
    const Value &decks
){
    const Value *opponent_active = active(state, 1 - actor);
    const std::int64_t opponent_hp = opponent_active == nullptr
        ? 0 : position.pokemon_current_hp(*opponent_active);
    const Value *opponent_definition = opponent_active == nullptr
        ? nullptr : card(cards, string_field(*opponent_active, "card_id"));
    const std::int64_t opponent_prizes = opponent_definition == nullptr
        ? 0 : integer_field(*opponent_definition, "prize_value", 1);
    double best = energy_attack_plan_for_card(
        position, state, actor, pokemon, slot,
        string_field(pokemon, "card_id"), opponent_hp,
        opponent_prizes, cards);
    for (const std::string &descendant : energy_plan_evolution_descendants(
        cards, decks, string_field(pokemon, "card_id"), key)) {
        best = std::max(best, energy_attack_plan_for_card(
            position, state, actor, pokemon, slot,
            descendant, opponent_hp, opponent_prizes, cards) * 0.75);
    }
    return best;
}

double public_energy_distribution_board_utility(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &cards
){
    const std::string key = deck_key(state, actor);
    const Value *opponent_active = active(state, 1 - actor);
    const std::int64_t opponent_hp = opponent_active == nullptr
        ? 0 : position.pokemon_current_hp(*opponent_active);
    const Value *opponent_definition = opponent_active == nullptr
        ? nullptr : card(cards, string_field(*opponent_active, "card_id"));
    const std::int64_t opponent_prizes = opponent_definition == nullptr
        ? 0 : integer_field(*opponent_definition, "prize_value", 1);
    double score = 0.0;
    const auto rows = board(state, actor);
    for (std::size_t board_index = 0; board_index < rows.size(); ++board_index) {
        const Value *pokemon = rows[board_index];
        const Value *definition = card(cards, string_field(*pokemon, "card_id"));
        const auto &attacks = definition == nullptr
            ? Value::Array{} : array_field(*definition, "attacks");
        double best = -std::numeric_limits<double>::infinity();
        for (const Value &attack : attacks) {
            const std::int64_t missing = missing_energy(
                cards, *pokemon, array_field(attack, "cost"));
            const std::int64_t damage = integer_field(attack, "damage");
            double value = static_cast<double>(damage)
                - static_cast<double>(missing) * 55.0;
            if (missing == 0 && damage > 0) {
                value += 80.0;
                if (damage >= profile(cards, key).high_impact_damage_floor()) value += 70.0;
                if (opponent_hp > 0 && damage >= opponent_hp) {
                    value += 200.0
                        + static_cast<double>(opponent_prizes) * 100.0;
                }
            } else if (missing == 1
                && damage >= profile(cards, key).high_impact_damage_floor()) value += 25.0;
            best = std::max(best, value);
        }
        if (std::isfinite(best)) {
            score += best * (board_index == 0
                && active(state, actor) == pokemon ? 1.0 : 0.9);
        }
    }
    return score;
}

} // namespace ptcg::ai::traditional_trusted_detail
