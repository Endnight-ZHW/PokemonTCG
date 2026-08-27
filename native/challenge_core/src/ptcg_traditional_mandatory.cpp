#include "ptcg_traditional_mandatory.hpp"
#include "ptcg_traditional_card.hpp"
#include "ptcg_traditional_value.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <sstream>
#include <string_view>
#include <utility>
#include <vector>

namespace ptcg::ai {

namespace {

constexpr double IMMINENT_LETHAL_MIN_PROBABILITY = 0.65;
constexpr std::uint64_t MIN_TACTICAL_ATTACK_SCAN = 3;
constexpr double SURVIVAL_BACKUP_SCORE_EPSILON = 0.001;

using traditional_value::array_contains;
using traditional_value::array_field;
using traditional_value::bool_field;
using traditional_value::field;
using traditional_value::integer_field;
using traditional_value::string_field;
using traditional_card::active;
using traditional_card::bench_count;
using traditional_card::card;
using traditional_card::catalog_cards;
using traditional_card::is_basic_pokemon;
using traditional_card::is_energy;
using traditional_card::missing_energy;
using traditional_card::player;

std::size_t prize_count(const Value &state, std::int32_t actor) {
    return array_field(player(state, actor), "prizes").size();
}

std::string action_kind(const Value &action) {
    return string_field(action, "kind");
}

std::int32_t action_actor(const Value &action) {
    return static_cast<std::int32_t>(integer_field(action, "actor", -1));
}

const Value *action_source(const Value &action) {
    const Value *value = field(action, "source");
    return value != nullptr && value->is_object() ? value : nullptr;
}

const Value *action_target(const Value &action) {
    const Value *value = field(action, "target");
    return value != nullptr && value->is_object() ? value : nullptr;
}

const Value &action_payload(const Value &action) {
    static const Value empty = Value::make_object();
    const Value *value = field(action, "payload");
    return value != nullptr && value->is_object() ? *value : empty;
}

std::string action_card_id(const Value &action) {
    const Value *source = action_source(action);
    return source == nullptr ? std::string{} : string_field(*source, "card_id");
}

void append_stable_text(const Value &value, std::ostringstream &output) {
    switch (value.type()) {
        case Value::Type::null_value: output << 'n'; break;
        case Value::Type::boolean: output << (value.as_bool() ? "t" : "f"); break;
        case Value::Type::integer: output << 'i' << value.as_integer(); break;
        case Value::Type::number: output << 'd' << value.as_number(); break;
        case Value::Type::string:
            output << 's' << value.as_string().size() << ':' << value.as_string();
            break;
        case Value::Type::array:
            output << '[';
            for (const Value &entry : value.as_array()) append_stable_text(entry, output);
            output << ']';
            break;
        case Value::Type::object:
            output << '{';
            for (const auto &[key, entry] : value.as_object()) {
                output << key.size() << ':' << key;
                append_stable_text(entry, output);
            }
            output << '}';
            break;
    }
}

std::string stable_text(const Value &value) {
    std::ostringstream output;
    append_stable_text(value, output);
    return output.str();
}

std::string action_signature(const Value &action) {
    Value identity(Value::Object{
        {"kind", Value(action_kind(action))},
        {"actor", Value(action_actor(action))},
        {"source", action_source(action) == nullptr ? Value() : *action_source(action)},
        {"target", action_target(action) == nullptr ? Value() : *action_target(action)},
        {"payload", action_payload(action)},
    });
    return stable_text(identity);
}

const Value *find_legal_equivalent(
    const Value &candidate,
    const Value::Array &actions
) {
    const std::string signature = action_signature(candidate);
    for (const Value &action : actions) {
        if (action_signature(action) == signature) return &action;
    }
    return nullptr;
}

std::string survival_semantic_key(const Value &action) {
    Value payload = action_payload(action);
    payload.erase("hand_idx");
    payload.erase("hand_index");
    const Value *target = action_target(action);
    return action_card_id(action) + "|"
        + (target == nullptr ? std::string{} : string_field(*target, "slot"))
        + "|" + stable_text(payload);
}

bool has_modifier_operation(
    const Value &pokemon,
    const std::string &operation_kind,
    const std::string &string_value = {}
) {
    for (const Value &descriptor : array_field(pokemon, "modifiers")) {
        const Value *operation = field(descriptor, "operation");
        if (operation == nullptr || !operation->is_object()
            || string_field(*operation, "kind") != operation_kind) continue;
        if (string_value.empty()) return true;
        const std::string value = string_field(
            *operation, "attack_name", string_field(*operation, "reason"));
        if (value == string_value || value == "__all__") return true;
    }
    return false;
}

bool status_contains(const Value &pokemon, const std::string &status) {
    return array_contains(array_field(pokemon, "status_conditions"), status);
}

bool commands_require_belief_sampling(const Value &commands) {
    if (!commands.is_array()) return false;
    for (const Value &command : commands.as_array()) {
        if (!command.is_object()) continue;
        const std::string op = string_field(command, "op");
        if (op.rfind("flip_coin", 0) == 0 || op == "flip_until_tails"
            || op == "draw_and_attach_energy"
            || op == "look_top_attach_energy"
            || op == "look_top_deck"
            || op == "mill_then_damage"
            || op == "trekking_shoes") return true;
        const Value *branches = field(command, "branches");
        if (branches == nullptr || !branches->is_object()) continue;
        for (const auto &[key, branch] : branches->as_object()) {
            (void)key;
            if (commands_require_belief_sampling(branch)) return true;
        }
    }
    return false;
}

bool commands_have_coin_randomness(const Value &commands) {
    if (!commands.is_array()) return false;
    for (const Value &command : commands.as_array()) {
        if (!command.is_object()) continue;
        const std::string op = string_field(command, "op");
        if (op.rfind("flip_coin", 0) == 0 || op == "flip_until_tails") return true;
        const Value *branches = field(command, "branches");
        if (branches == nullptr || !branches->is_object()) continue;
        for (const auto &[key, branch] : branches->as_object()) {
            (void)key;
            if (commands_have_coin_randomness(branch)) return true;
        }
    }
    return false;
}

bool command_replaces_base_damage(const std::string &op) {
    return op == "conditional_damage_then_heal"
        || op == "deal_damage_per_discard_psychic"
        || op == "deal_damage_per_energy"
        || op == "deal_damage_per_evolved"
        || op == "deal_damage_per_hand_size"
        || op == "deal_damage_per_self_damage"
        || op == "deal_damage_per_self_energy"
        || op == "deal_damage_per_self_energy_type"
        || op == "deal_damage_plus_bench"
        || op == "deal_damage_then_heal"
        || op == "deal_damage_with_self_penalty"
        || op == "discard_energy_then_damage"
        || op == "discard_hand_then_damage"
        || op == "flip_coin_repeat_damage"
        || op == "flip_until_tails"
        || op == "mill_then_damage"
        || op == "place_counters_then_self_discard"
        || op == "set_attack_damage_formula";
}

bool commands_can_invalidate_base_damage(const Value &commands) {
    if (!commands.is_array()) return false;
    for (const Value &command : commands.as_array()) {
        if (!command.is_object()) continue;
        const std::string op = string_field(command, "op");
        const std::string semantic_kind = string_field(command, "semantic_kind");
        const Value *args = field(command, "args");
        if (bool_field(command, "replaces_base_damage")
            || command_replaces_base_damage(op)
            || (op == "deal_damage" && args != nullptr && args->is_object()
                && field(*args, "formula_ast") != nullptr)
            || semantic_kind == "mill_and_damage_per_energy"
            || semantic_kind == "place_counters_and_self_discard") return true;
        const Value *branches = field(command, "branches");
        if (branches == nullptr || !branches->is_object()) continue;
        for (const auto &[key, branch] : branches->as_object()) {
            (void)key;
            if (commands_can_invalidate_base_damage(branch)) return true;
        }
    }
    return false;
}

bool commands_have_defensive_effect(const Value &commands) {
    if (!commands.is_array()) return false;
    for (const Value &command : commands.as_array()) {
        if (!command.is_object()) continue;
        const std::string op = string_field(command, "op");
        if (op == "apply_attack_lock_basic"
            || op == "apply_status"
            || op == "choose_heal_damage"
            || op == "conditional_status"
            || op == "deal_damage_then_heal"
            || op == "heal_all"
            || op == "heal_damage"
            || op == "prevent_all"
            || op == "prevent_damage"
            || op == "prevent_effects"
            || op == "search_any_and_switch"
            || op == "switch_pokemon") return true;
        const Value *branches = field(command, "branches");
        if (branches == nullptr || !branches->is_object()) continue;
        for (const auto &[key, branch] : branches->as_object()) {
            (void)key;
            if (commands_have_defensive_effect(branch)) return true;
        }
    }
    return false;
}

const Value *attack_definition(
    const Value &cards,
    const Value &action
) {
    const Value *definition = card(cards, action_card_id(action));
    const std::int64_t index = integer_field(
        action_payload(action), "attack_index",
        integer_field(action_payload(action), "attack_idx", -1));
    const Value::Array &attacks = definition == nullptr
        ? Value::Array{} : array_field(*definition, "attacks");
    return index >= 0 && static_cast<std::size_t>(index) < attacks.size()
        ? &attacks[static_cast<std::size_t>(index)] : nullptr;
}

const Value &compiled_commands(const Value &definition, const char *key) {
    static const Value empty = Value::make_array();
    const Value *commands = field(definition, key);
    return commands != nullptr && commands->is_array() ? *commands : empty;
}

bool attack_has_random_effect(const Value &cards, const Value &action) {
    const Value *attack = attack_definition(cards, action);
    return attack != nullptr
        && commands_require_belief_sampling(compiled_commands(*attack, "compiled_effects"));
}

const Value &commands_for_action(const Value &cards, const Value &action) {
    static const Value empty = Value::make_array();
    const Value *definition = card(cards, action_card_id(action));
    if (definition == nullptr) return empty;
    const std::string kind = action_kind(action);
    if (kind == "DECLARE_ATTACK") {
        const Value *attack = attack_definition(cards, action);
        return attack == nullptr ? empty : compiled_commands(*attack, "compiled_effects");
    }
    if (kind == "PLAY_TRAINER" || kind == "USE_STADIUM") {
        return compiled_commands(*definition, "compiled_trainer_effects");
    }
    if (kind == "USE_ABILITY") {
        const std::string ability_name = string_field(action_payload(action), "ability_name");
        for (const Value &ability : array_field(*definition, "abilities")) {
            if (string_field(ability, "name") == ability_name) {
                return compiled_commands(ability, "compiled_effects");
            }
        }
    }
    return empty;
}

bool card_has_on_enter_play_effect(
    const Value &cards,
    const std::string &card_id
) {
    const Value *definition = card(cards, card_id);
    if (definition == nullptr) return true;
    for (const Value &ability : array_field(*definition, "abilities")) {
        if (string_field(ability, "trigger") == "on_enter_play") return true;
    }
    return false;
}

bool is_terminal(const RulesSession &position) {
    const Value &state = position.search_state();
    return string_field(state, "result_status", "ONGOING") != "ONGOING"
        || string_field(state, "phase") == "GAME_OVER";
}

std::int32_t winner(const RulesSession &position) {
    return static_cast<std::int32_t>(integer_field(
        position.search_state(), "winner", -1));
}

bool is_cancelled(const std::atomic<bool> *cancel_requested) {
    return cancel_requested != nullptr
        && cancel_requested->load(std::memory_order_acquire);
}

bool resolve_choices(
    RulesSession &position,
    std::int32_t actor,
    TraditionalSearchProvider &provider
) {
    std::uint64_t ignored_nodes = 0;
    TraditionalChoiceTrace trace;
    return provider.resolve_pending(position, actor, ignored_nodes, trace);
}

bool has_hidden_or_random_event(const RulesSessionResult &step) {
    for (const Value &event : step.events) {
        const std::string type = string_field(event, "event_type");
        if (type == "cards_drawn" || type == "cards_revealed"
            || type == "deck_shuffled" || type == "coin_flip") return true;
    }
    return false;
}

TraditionalMandatoryResult resolved(
    const Value &action,
    std::string reason,
    std::uint64_t nodes
) {
    TraditionalMandatoryResult result;
    result.resolved = true;
    result.action = action;
    result.reason = std::move(reason);
    result.nodes_expanded = nodes;
    return result;
}

TraditionalMandatoryResult unresolved(
    std::string reason,
    std::uint64_t nodes,
    bool cancelled = false
) {
    TraditionalMandatoryResult result;
    result.cancelled = cancelled;
    result.reason = std::move(reason);
    result.nodes_expanded = nodes;
    return result;
}

const Value *survival_backup_action(
    const RulesSession &position,
    std::int32_t actor,
    const Value::Array &actions,
    const TraditionalStrategyCatalog &strategies,
    const TraditionalTrustedEvaluator &trusted
) {
    const Value &state = position.search_state();
    const Value &owner = player(state, actor);
    if (active(state, actor) == nullptr || bench_count(owner) != 0) return nullptr;
    const Value *selected = nullptr;
    double selected_score = -std::numeric_limits<double>::infinity();
    std::string selected_key;
    for (const Value &action : actions) {
        const Value *target = action_target(action);
        if (action_actor(action) != actor || action_kind(action) != "PLAY_BASIC"
            || target == nullptr
            || string_field(*target, "slot").rfind("bench_", 0) != 0) continue;
        double score = trusted.action_score(position, actor, action).value_or(0.0);
        score += strategies.action_score(state, actor, action);
        const std::string key = survival_semantic_key(action);
        const double delta = score - selected_score;
        if (selected == nullptr || delta > SURVIVAL_BACKUP_SCORE_EPSILON
            || (std::abs(delta) <= SURVIVAL_BACKUP_SCORE_EPSILON
                && key < selected_key)) {
            selected = &action;
            selected_score = score;
            selected_key = key;
        }
    }
    return selected;
}

struct DevelopmentResult {
    const Value *action = nullptr;
    std::uint64_t nodes = 0;
};

DevelopmentResult safe_pre_knockout_development_action(
    const RulesSession &position,
    std::int32_t actor,
    const Value::Array &actions,
    const Value &forced_knockout,
    const Value &cards,
    const TraditionalStrategyCatalog &strategies,
    const TraditionalTrustedEvaluator &trusted,
    TraditionalSearchProvider &provider,
    std::uint32_t seed,
    std::uint64_t node_budget,
    const std::atomic<bool> *cancel_requested
) {
    DevelopmentResult result;
    if (action_kind(forced_knockout) != "DECLARE_ATTACK" || node_budget < 2) {
        return result;
    }
    struct Candidate {
        const Value *action = nullptr;
        double score = 0.0;
        std::string key;
    };
    std::vector<Candidate> candidates;
    for (const Value &action : actions) {
        const Value *target = action_target(action);
        if (action_actor(action) != actor || action_kind(action) != "EVOLVE"
            || action_source(action) == nullptr || target == nullptr
            || string_field(*target, "slot").rfind("bench_", 0) != 0
            || card_has_on_enter_play_effect(cards, action_card_id(action))) continue;
        candidates.push_back(Candidate{
            &action,
            strategies.action_score(position.search_state(), actor, action)
                + trusted.action_score(position, actor, action).value_or(0.0),
            action_signature(action),
        });
    }
    std::stable_sort(candidates.begin(), candidates.end(), [](const Candidate &left,
                                                               const Candidate &right) {
        const double scale = std::max({1.0, std::abs(left.score), std::abs(right.score)});
        if (std::abs(left.score - right.score) <= 0.00001 * scale) {
            return left.key < right.key;
        }
        return left.score > right.score;
    });
    for (std::size_t index = 0; index < candidates.size(); ++index) {
        if (is_cancelled(cancel_requested) || result.nodes + 2 > node_budget) break;
        std::unique_ptr<RulesSession> simulation = position.fork_for_search(
            seed + static_cast<std::uint32_t>(index * 104729U));
        if (!simulation) continue;
        ++result.nodes;
        const Value bound_development = provider.bind_action(
            *candidates[index].action,
            *simulation,
            actor,
            "mandatory_development_" + std::to_string(index));
        const RulesSessionResult development = simulation->apply_action(
            bound_development);
        if (!development.success || is_terminal(*simulation)
            || has_hidden_or_random_event(development)
            || !simulation->search_pending_choice(0).is_null()
            || !simulation->search_pending_choice(1).is_null()) continue;
        const Value &followup_value = simulation->search_legal_action_candidates(actor);
        if (!followup_value.is_array()) continue;
        const Value *followup = find_legal_equivalent(
            forced_knockout, followup_value.as_array());
        if (followup == nullptr) continue;
        const std::size_t prizes_before = prize_count(simulation->search_state(), actor);
        ++result.nodes;
        const Value bound_followup = provider.bind_action(
            *followup,
            *simulation,
            actor,
            "mandatory_followup_" + std::to_string(index));
        const RulesSessionResult attack = simulation->apply_action_for_search(
            bound_followup);
        if (!attack.success || !resolve_choices(*simulation, actor, provider)) continue;
        if ((is_terminal(*simulation) && winner(*simulation) == actor)
            || (!is_terminal(*simulation)
                && prize_count(simulation->search_state(), actor) < prizes_before)) {
            result.action = candidates[index].action;
            return result;
        }
    }
    return result;
}

struct DrawProfile {
    std::int64_t count = 0;
    bool discards_hand = false;
    bool valid = false;
};

DrawProfile deterministic_draw_profile(
    const Value &cards,
    const std::string &card_id
) {
    const Value *definition = card(cards, card_id);
    if (definition == nullptr) return {};
    const Value &commands = compiled_commands(*definition, "compiled_trainer_effects");
    if (!commands.is_array() || commands.as_array().size() != 1
        || commands_have_coin_randomness(commands)) return {};
    const Value &command = commands.as_array().front();
    const Value *branches = field(command, "branches");
    if (branches != nullptr && branches->is_object()
        && !branches->as_object().empty()) return {};
    const Value *args = field(command, "args");
    if (args == nullptr || !args->is_object()) return {};
    const std::string op = string_field(command, "op");
    if (op == "draw_cards") {
        return {integer_field(*args, "amount"), false, true};
    }
    if (op == "discard_then_draw_cards" && bool_field(*args, "discard_hand")) {
        return {integer_field(*args, "draw"), true, true};
    }
    return {};
}

double at_least_one_success_probability(
    std::size_t population,
    std::size_t successes,
    std::size_t draws
) {
    if (population == 0 || successes == 0 || draws == 0) return 0.0;
    double failure = 1.0;
    for (std::size_t index = 0; index < std::min(draws, population); ++index) {
        const std::size_t remaining_population = population - index;
        const std::int64_t remaining_failures = static_cast<std::int64_t>(
            population - successes) - static_cast<std::int64_t>(index);
        if (remaining_failures <= 0) return 1.0;
        failure *= static_cast<double>(remaining_failures)
            / static_cast<double>(remaining_population);
    }
    return std::clamp(1.0 - failure, 0.0, 1.0);
}

bool has_deterministic_defense_action(
    std::int32_t actor,
    const Value::Array &actions,
    const Value &cards
) {
    for (const Value &action : actions) {
        if (action_actor(action) != actor) continue;
        const Value *target = action_target(action);
        if (action_kind(action) == "EVOLVE" && target != nullptr
            && string_field(*target, "slot") == "active") return true;
        const Value &commands = commands_for_action(cards, action);
        if (!commands.is_array() || commands.as_array().empty()
            || commands_have_coin_randomness(commands)) continue;
        if (commands_have_defensive_effect(commands)) return true;
    }
    return false;
}

double public_imminent_lethal_attack_probability(
    const TraditionalInformationSet &information_set,
    const RulesSession &position,
    std::int32_t actor,
    const Value &cards
) {
    const Value &state = position.search_state();
    const Value *defender = active(state, actor);
    const Value *attacker = active(state, 1 - actor);
    if (defender == nullptr || attacker == nullptr
        || has_modifier_operation(*defender, "prevent_damage")
        || status_contains(*attacker, "ASLEEP")
        || status_contains(*attacker, "PARALYZED")
        || status_contains(*attacker, "CONFUSED")
        || has_modifier_operation(*attacker, "attack_gate_coin")) return 0.0;
    const Value *definition = card(cards, string_field(*attacker, "card_id"));
    if (definition == nullptr) return 0.0;
    struct AttackRow {
        const Value *attack = nullptr;
        std::int64_t damage = 0;
    };
    std::vector<AttackRow> deterministic;
    const Value::Array &attacks = array_field(*definition, "attacks");
    for (const Value &attack : attacks) {
        const std::string attack_name = string_field(attack, "name");
        if (has_modifier_operation(*attacker, "attack_lock", attack_name)) continue;
        const Value &commands = compiled_commands(attack, "compiled_effects");
        if (commands_require_belief_sampling(commands)
            || commands_can_invalidate_base_damage(commands)) continue;
        const std::int64_t damage = integer_field(attack, "damage");
        if (damage <= 0) continue;
        deterministic.push_back({&attack, damage});
        if (missing_energy(cards, *attacker, array_field(attack, "cost")) == 0
            && position.estimate_public_damage(
                1 - actor, *attacker, *defender, damage)
                >= position.pokemon_current_hp(*defender)) return 1.0;
    }
    if (deterministic.empty()) return 0.0;
    const std::int32_t opponent = 1 - actor;
    if (!information_set.has_published_deck(opponent)) return 0.0;
    const Value &public_state = information_set.public_snapshot();
    const Value &opponent_row = player(public_state, opponent);
    const std::size_t hand_count = array_field(opponent_row, "hand").size();
    const std::size_t deck_count = array_field(opponent_row, "deck").size();
    const std::size_t prize_count_value = array_field(opponent_row, "prizes").size();
    if (deck_count == 0) return 0.0;
    const Value::Array &pool = information_set.remaining_pool(opponent);
    if (pool.size() != hand_count + deck_count + prize_count_value) return 0.0;
    std::size_t lethal_energy_count = 0;
    for (const Value &card_id_value : pool) {
        const std::string energy_card_id = card_id_value.string_or();
        if (!is_energy(cards, energy_card_id)) continue;
        Value future = *attacker;
        Value *attached = future.find("energy_card_ids");
        if (attached == nullptr || !attached->is_array()) {
            future["energy_card_ids"] = Value::make_array();
            attached = future.find("energy_card_ids");
        }
        attached->as_array().emplace_back(energy_card_id);
        bool enables_lethal = false;
        for (const AttackRow &row : deterministic) {
            if (missing_energy(cards, future, array_field(*row.attack, "cost")) != 0) {
                continue;
            }
            if (position.estimate_public_damage(
                    1 - actor, future, *defender, row.damage)
                    >= position.pokemon_current_hp(*defender)) {
                enables_lethal = true;
                break;
            }
        }
        if (enables_lethal) ++lethal_energy_count;
    }
    return at_least_one_success_probability(
        pool.size(), lethal_energy_count, std::min(pool.size(), hand_count + 1));
}

const Value *seek_only_backup_out_action(
    const TraditionalInformationSet &information_set,
    const RulesSession &position,
    std::int32_t actor,
    const Value::Array &actions,
    const Value &cards,
    const TraditionalStrategyCatalog &strategies,
    const TraditionalTrustedEvaluator &trusted
) {
    const Value &state = position.search_state();
    const Value &owner = player(state, actor);
    if (active(state, actor) == nullptr || bench_count(owner) != 0
        || survival_backup_action(position, actor, actions, strategies, trusted)
            != nullptr) return nullptr;
    if (public_imminent_lethal_attack_probability(
            information_set, position, actor, cards)
        < IMMINENT_LETHAL_MIN_PROBABILITY) return nullptr;
    if (has_deterministic_defense_action(actor, actions, cards)) return nullptr;
    if (!information_set.has_published_deck(actor)) return nullptr;
    const Value &public_owner = player(information_set.public_snapshot(), actor);
    const std::size_t deck_count = array_field(public_owner, "deck").size();
    const std::size_t prize_count_value = array_field(public_owner, "prizes").size();
    if (deck_count == 0) return nullptr;
    const Value::Array &pool = information_set.remaining_pool(actor);
    if (pool.size() != deck_count + prize_count_value) return nullptr;
    const std::size_t basic_count = static_cast<std::size_t>(std::count_if(
        pool.begin(), pool.end(), [&cards](const Value &entry) {
            return is_basic_pokemon(cards, entry.string_or());
        }));
    if (basic_count == 0) return nullptr;
    const Value *best = nullptr;
    double best_probability = 0.0;
    bool best_discards_hand = true;
    std::string best_key;
    for (const Value &action : actions) {
        const Value *source = action_source(action);
        if (action_actor(action) != actor || action_kind(action) != "PLAY_TRAINER"
            || source == nullptr || string_field(*source, "zone") != "hand") continue;
        const DrawProfile profile = deterministic_draw_profile(
            cards, string_field(*source, "card_id"));
        if (!profile.valid || profile.count <= 0
            || deck_count < static_cast<std::size_t>(profile.count)) continue;
        const std::size_t draws = std::min<std::size_t>(
            deck_count, static_cast<std::size_t>(profile.count));
        const double probability = at_least_one_success_probability(
            pool.size(), basic_count, draws);
        if (probability <= 0.0) continue;
        const std::string key = action_signature(action);
        if (best == nullptr || probability > best_probability + 0.000001
            || (std::abs(probability - best_probability) <= 0.000001
                && best_discards_hand && !profile.discards_hand)
            || (std::abs(probability - best_probability) <= 0.000001
                && profile.discards_hand == best_discards_hand
                && key < best_key)) {
            best = &action;
            best_probability = probability;
            best_discards_hand = profile.discards_hand;
            best_key = key;
        }
    }
    return best;
}

} // namespace

TraditionalMandatoryTactics::TraditionalMandatoryTactics(
    Value catalog,
    const TraditionalStrategyCatalog &strategies,
    const TraditionalTrustedEvaluator &trusted
) : cards_(catalog_cards(catalog)), strategies_(strategies), trusted_(trusted) {}

TraditionalMandatoryResult TraditionalMandatoryTactics::resolve(
    const TraditionalInformationSet &information_set,
    const RulesSession &position,
    std::int32_t actor,
    const Value &actions_value,
    TraditionalSearchProvider &provider,
    std::uint32_t seed,
    std::uint64_t node_budget,
    const std::atomic<bool> *cancel_requested
) const {
    if (!information_set.valid() || !position.initialized()
        || actor < 0 || actor > 1 || !actions_value.is_array()) {
        return unresolved("invalid_input", 0);
    }
    if (is_cancelled(cancel_requested)) return unresolved("cancelled", 0, true);
    const Value::Array &actions = actions_value.as_array();
    if (actions.empty()) return unresolved("no_legal_actions", 0);
    if (actions.size() == 1) return resolved(actions.front(), "only_legal_action", 0);

    const Value *backup = survival_backup_action(
        position, actor, actions, strategies_, trusted_);
    const Value *forced_knockout = nullptr;
    std::string debug_last_step_error;
    Value debug_last_state = Value::make_object();
    std::uint64_t expanded = 0;
    std::uint64_t deterministic_attack_count = 0;
    for (const Value &candidate : actions) {
        if (action_kind(candidate) == "DECLARE_ATTACK"
            && !attack_has_random_effect(cards_, candidate)) {
            ++deterministic_attack_count;
        }
    }
    std::uint64_t tactical_budget = node_budget;
    if (tactical_budget > 0) {
        tactical_budget = std::max(
            tactical_budget,
            std::min(MIN_TACTICAL_ATTACK_SCAN, deterministic_attack_count));
    }
    for (std::size_t index = 0; index < actions.size(); ++index) {
        if (is_cancelled(cancel_requested)) {
            return unresolved("cancelled", expanded, true);
        }
        const Value &action = actions[index];
        if (action_kind(action) != "DECLARE_ATTACK"
            || attack_has_random_effect(cards_, action)) continue;
        if (expanded >= tactical_budget) {
            if (backup != nullptr) return resolved(*backup, "establish_only_backup", expanded);
            if (forced_knockout != nullptr) {
                return resolved(*forced_knockout, "immediate_knockout", expanded);
            }
            return unresolved("node_budget", expanded);
        }
        ++expanded;
        std::unique_ptr<RulesSession> simulation = position.fork_for_search(
            seed + static_cast<std::uint32_t>(index * 104729U));
        if (!simulation) continue;
        const Value bound_action = provider.bind_action(
            action,
            *simulation,
            actor,
            "mandatory_attack_" + std::to_string(index));
        const RulesSessionResult step = simulation->apply_action(bound_action);
        if (!step.success) {
            debug_last_step_error = step.error_code;
            continue;
        }
        if (!resolve_choices(*simulation, actor, provider)) {
            debug_last_step_error = "choice_resolution_failed";
            debug_last_state = simulation->snapshot();
            continue;
        }
        debug_last_state = simulation->snapshot();
        if (is_terminal(*simulation)) {
            if (winner(*simulation) == actor) {
                return resolved(action, "immediate_match_win", expanded);
            }
            continue;
        }
        if (prize_count(simulation->search_state(), actor)
            < prize_count(position.search_state(), actor)) {
            forced_knockout = &action;
        }
    }
    if (backup != nullptr) return resolved(*backup, "establish_only_backup", expanded);
    if (forced_knockout != nullptr) {
        const std::uint64_t remaining = node_budget > expanded
            ? node_budget - expanded : 0;
        const DevelopmentResult development = safe_pre_knockout_development_action(
            position, actor, actions, *forced_knockout, cards_, strategies_, trusted_,
            provider, seed + 600013U, remaining, cancel_requested);
        expanded += std::min(remaining, development.nodes);
        if (development.action != nullptr) {
            return resolved(
                *development.action, "safe_development_before_knockout", expanded);
        }
        return resolved(*forced_knockout, "immediate_knockout", expanded);
    }
    const Value *backup_draw = seek_only_backup_out_action(
        information_set, position, actor, actions, cards_, strategies_, trusted_);
    if (backup_draw != nullptr) {
        return resolved(*backup_draw, "seek_only_backup_out", expanded);
    }
    TraditionalMandatoryResult result = unresolved("search_required", expanded);
    result.debug_last_step_error = std::move(debug_last_step_error);
    result.debug_last_state = std::move(debug_last_state);
    return result;
}

} // namespace ptcg::ai
