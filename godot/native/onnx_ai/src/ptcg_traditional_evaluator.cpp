#include "ptcg_traditional_evaluator.hpp"
#include "ptcg_traditional_card.hpp"
#include "ptcg_traditional_value.hpp"

#include <algorithm>
#include <cmath>
#include <string>
#include <string_view>
#include <vector>

namespace ptcg::ai {

namespace {

using traditional_value::array_contains;
using traditional_value::bool_field;
using traditional_value::field;
using traditional_value::integer_field;
using traditional_value::string_field;
using traditional_card::card;
using traditional_card::energy_units;

std::int64_t missing_energy_units(
    std::vector<std::string> available,
    const Value *cost
) {
    if (cost == nullptr || !cost->is_array()) return 0;
    std::int64_t missing = 0;
    std::int64_t colorless = 0;
    for (const Value &required_value : cost->as_array()) {
        const std::string required = required_value.string_or();
        if (required == "Colorless") {
            ++colorless;
            continue;
        }
        auto found = std::find(available.begin(), available.end(), required);
        if (found == available.end()) {
            found = std::find(available.begin(), available.end(), "Rainbow");
        }
        if (found == available.end()) ++missing;
        else available.erase(found);
    }
    return missing + std::max<std::int64_t>(
        0, colorless - static_cast<std::int64_t>(available.size()));
}

bool modifier_operation_matches(
    const Value &pokemon,
    const std::string &kind,
    const std::string &text = {}
) {
    const Value *modifiers = field(pokemon, "modifiers");
    if (modifiers == nullptr || !modifiers->is_array()) return false;
    for (const Value &modifier : modifiers->as_array()) {
        const Value *operation = field(modifier, "operation");
        if (operation == nullptr || !operation->is_object()
            || string_field(*operation, "kind") != kind) continue;
        if (text.empty()) return true;
        const std::string operation_text = string_field(
            *operation, "attack_name", string_field(*operation, "reason"));
        if (operation_text == text || operation_text == "__all__") return true;
    }
    return false;
}

struct AttackProfile {
    std::int64_t useful_units = 0;
    std::int64_t stranded_units = 0;
    std::int64_t minimum_missing = 99;
    double ready_ratio = 0.0;
    double gate_probability = 1.0;
};

AttackProfile public_attack_profile(
    const Value &cards,
    const Value &pokemon
) {
    AttackProfile result;
    const std::vector<std::string> available = energy_units(cards, pokemon);
    const Value *definition = card(
        cards, string_field(pokemon, "card_id"));
    const Value *attacks = definition == nullptr
        ? nullptr : field(*definition, "attacks");
    std::int64_t eligible = 0;
    std::int64_t ready = 0;
    if (attacks != nullptr && attacks->is_array()) {
        for (const Value &attack : attacks->as_array()) {
            if (!attack.is_object()) continue;
            const Value *cost = field(attack, "cost");
            const std::int64_t cost_size = cost != nullptr && cost->is_array()
                ? static_cast<std::int64_t>(cost->as_array().size()) : 0;
            const std::int64_t missing = missing_energy_units(available, cost);
            result.useful_units = std::max(
                result.useful_units, std::max<std::int64_t>(0, cost_size - missing));
            const std::string name = string_field(attack, "name");
            if (modifier_operation_matches(pokemon, "attack_lock", name)) continue;
            ++eligible;
            result.minimum_missing = std::min(result.minimum_missing, missing);
            if (missing == 0) ++ready;
        }
    }
    result.stranded_units = std::max<std::int64_t>(
        0, static_cast<std::int64_t>(available.size()) - result.useful_units);
    result.ready_ratio = eligible > 0
        ? static_cast<double>(ready) / static_cast<double>(eligible) : 0.0;
    const Value *statuses = field(pokemon, "status_conditions");
    if (array_contains(statuses, "ASLEEP") || array_contains(statuses, "PARALYZED")) {
        result.gate_probability = 0.0;
    } else {
        if (array_contains(statuses, "CONFUSED")) result.gate_probability *= 0.5;
        if (modifier_operation_matches(pokemon, "attack_gate_coin", "dazzled")) {
            result.gate_probability *= 0.5;
        }
    }
    return result;
}

double pokemon_board_score(
    const RulesSession &position,
    const Value &cards,
    const Value &pokemon,
    bool active
) {
    const std::int64_t remaining_hp = position.pokemon_current_hp(pokemon);
    const double slot_weight = active ? 1.2 : 1.0;
    const AttackProfile profile = public_attack_profile(cards, pokemon);
    double score = static_cast<double>(remaining_hp) * 0.35 * slot_weight;
    score += static_cast<double>(profile.useful_units) * 12.0;
    score -= static_cast<double>(profile.stranded_units) * 7.0;
    const Value *evolutions = field(pokemon, "evolution_stack_ids");
    score += static_cast<double>(
        evolutions != nullptr && evolutions->is_array()
            ? evolutions->as_array().size() : 0U) * 18.0;
    double preparation = 0.0;
    if (profile.minimum_missing == 0) preparation = 1.0;
    else if (profile.minimum_missing == 1) preparation = 0.55;
    else if (profile.minimum_missing == 2) preparation = 0.20;
    score += preparation * (active ? 26.0 : 14.0);
    if (active) {
        score += 45.0 * profile.ready_ratio * profile.gate_probability;
    }
    const Value *definition = card(
        cards, string_field(pokemon, "card_id"));
    score += static_cast<double>(definition == nullptr
        ? 1 : integer_field(*definition, "prize_value", 1)) * 2.0;
    return score;
}

double board_score(
    const RulesSession &position,
    const Value &cards,
    const Value &player
) {
    double score = 0.0;
    const Value *active = field(player, "active");
    if (active != nullptr && active->is_object()) {
        score += pokemon_board_score(position, cards, *active, true);
    }
    const Value *bench = field(player, "bench");
    if (bench != nullptr && bench->is_array()) {
        for (const Value &pokemon : bench->as_array()) {
            if (pokemon.is_object()) {
                score += pokemon_board_score(position, cards, pokemon, false);
            }
        }
    }
    return score;
}

std::size_t array_size(const Value &object, const char *key) noexcept {
    const Value *value = field(object, key);
    return value != nullptr && value->is_array() ? value->as_array().size() : 0;
}

double expected_attack_damage(const Value &attack) {
    double expected = static_cast<double>(integer_field(attack, "damage"));
    const Value *commands = field(attack, "compiled_effects");
    if (commands == nullptr || !commands->is_array()) return expected;
    for (const Value &command : commands->as_array()) {
        const std::string op = string_field(command, "op");
        const Value *args = field(command, "args");
        if (args == nullptr || !args->is_object()) continue;
        if (op == "flip_coin_repeat_damage") {
            expected = static_cast<double>(integer_field(*args, "flips"))
                * 0.5
                * static_cast<double>(integer_field(*args, "damage_per_head"));
        } else if (op == "flip_until_tails") {
            expected = static_cast<double>(integer_field(*args, "per_head"));
        }
    }
    return expected;
}

} // namespace

TraditionalPositionEvaluator::TraditionalPositionEvaluator(Value catalog) {
    const Value *cards = catalog.find("cards");
    cards_ = cards != nullptr && cards->is_object() ? *cards : std::move(catalog);
}

std::int64_t TraditionalPositionEvaluator::base_state_score_milli(
    const RulesSession &position,
    std::int32_t actor
) const {
    if (actor != 0 && actor != 1) return -1000000000LL;
    const Value &state = position.search_state();
    if (string_field(state, "result_status", "ONGOING") != "ONGOING"
        || string_field(state, "phase") == "GAME_OVER") {
        if (string_field(state, "result_status") == "DRAW") return 0;
        return integer_field(state, "winner", -1) == actor
            ? 1000000000LL : -1000000000LL;
    }
    const Value *players = field(state, "players");
    if (players == nullptr || !players->is_array()
        || players->as_array().size() != 2) return -1000000000LL;
    const Value &own = players->as_array()[static_cast<std::size_t>(actor)];
    const Value &opponent = players->as_array()[static_cast<std::size_t>(1 - actor)];
    double score = static_cast<double>(
        static_cast<std::int64_t>(array_size(opponent, "prizes"))
        - static_cast<std::int64_t>(array_size(own, "prizes"))) * 150.0;
    score += static_cast<double>(
        static_cast<std::int64_t>(array_size(own, "hand"))
        - static_cast<std::int64_t>(array_size(opponent, "hand"))) * 2.0;
    score += static_cast<double>(
        static_cast<std::int64_t>(array_size(own, "deck"))
        - static_cast<std::int64_t>(array_size(opponent, "deck"))) * 0.05;
    score += board_score(position, cards_, own)
        - board_score(position, cards_, opponent);
    if (bool_field(own, "retreated_this_turn")) score -= 42.0;
    if (bool_field(opponent, "retreated_this_turn")) score += 42.0;
    return quantize(score);
}

std::int64_t TraditionalPositionEvaluator::default_action_score_milli(
    const Value &action
) const {
    const std::string kind = string_field(action, "kind");
    double priority = 0.0;
    if (kind == "DECLARE_ATTACK") {
        priority = 500.0;
        const Value *source = field(action, "source");
        const Value *payload = field(action, "payload");
        const Value *definition = source == nullptr ? nullptr
            : card(cards_, string_field(*source, "card_id"));
        const Value *attacks = definition == nullptr
            ? nullptr : field(*definition, "attacks");
        const std::int64_t attack_index = payload == nullptr
            ? -1 : integer_field(*payload, "attack_index", -1);
        if (attacks != nullptr && attacks->is_array() && attack_index >= 0
            && static_cast<std::size_t>(attack_index) < attacks->as_array().size()) {
            priority += expected_attack_damage(
                attacks->as_array()[static_cast<std::size_t>(attack_index)]);
        }
    } else if (kind == "USE_ABILITY") priority = 420.0;
    else if (kind == "PLAY_TRAINER") priority = 360.0;
    else if (kind == "EVOLVE") priority = 320.0;
    else if (kind == "ATTACH_ENERGY") priority = 280.0;
    else if (kind == "PLAY_BASIC") priority = 220.0;
    else if (kind == "USE_STADIUM") priority = 180.0;
    else if (kind == "RETREAT" || kind == "PROMOTE") priority = 140.0;
    else if (kind == "SETUP_DONE") priority = 40.0;
    else if (kind == "END_TURN") priority = -100.0;
    return quantize(priority);
}

std::int64_t TraditionalPositionEvaluator::quantize(double score) noexcept {
    return static_cast<std::int64_t>(std::round(score * 1000.0));
}

} // namespace ptcg::ai
