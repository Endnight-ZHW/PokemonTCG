#include "planner_v3/strategic_facts.hpp"
#include "ptcg_traditional_evaluation_detail.hpp"

#include <functional>
#include <numeric>

namespace ptcg::ai::planner_v3 {
namespace {
using namespace traditional_trusted_detail;

// Forecast only resources in the sampled accessible zones. Prizes are never
// searched, and the forecast never exposes a sampled identity to a real choice.
bool accessible(const Value &owner, const std::string &id) {
    return array_contains(field(owner, "hand"), id)
        || array_contains(field(owner, "deck"), id);
}

Value fund_attack(const Value &cards, const Value &owner, Value pokemon,
    const Value::Array &cost) {
    Value::Array pool = array_field(owner, "hand");
    const auto &deck = array_field(owner, "deck");
    pool.insert(pool.end(), deck.begin(), deck.end());
    std::sort(pool.begin(), pool.end(), [](const Value &a, const Value &b) { return a.string_or() < b.string_or(); });
    for (std::size_t step = 0; step < cost.size(); ++step) {
        const auto before = missing_energy(cards, pokemon, cost);
        if (before == 0) break;
        std::size_t best = pool.size();
        auto best_missing = before;
        for (std::size_t index = 0; index < pool.size(); ++index) {
            if (!is_energy(cards, pool[index].string_or())) continue;
            const auto after = missing_energy(cards,
                pokemon_with_extra_energy(pokemon, pool[index].string_or()), cost);
            if (after < best_missing) { best = index; best_missing = after; }
        }
        if (best == pool.size()) break;
        pokemon = pokemon_with_extra_energy(pokemon, pool[best].string_or());
        pool.erase(pool.begin() + static_cast<std::ptrdiff_t>(best));
    }
    return pokemon;
}

double discard_units(const Value &effects, double attached, double probability = 1.0) {
    if (effects.is_array()) {
        double total = 0.0;
        for (const auto &entry : effects.as_array()) total += discard_units(entry, attached, probability);
        return total;
    }
    if (!effects.is_object()) return 0.0;
    const std::string op = string_field(effects, "op");
    const Value *args = field(effects, "args");
    double total = 0.0;
    if (op == "discard_energy_then_damage") total = probability * attached;
    if (op == "discard_energy" && args != nullptr
        && string_field(*args, "from", "self") == "self") {
        total = probability * std::min(attached,
            static_cast<double>(integer_field(*args, "amount", 1)));
    }
    const Value *branches = field(effects, "branches");
    if (branches != nullptr && branches->is_object()) {
        for (const auto &[name, branch] : branches->as_object()) {
            const bool coin = name == "on_heads" || name == "on_tails";
            total += discard_units(branch, attached, probability * (coin ? 0.5 : 1.0));
        }
    }
    return total;
}

long double combinations(std::size_t n, std::size_t k) {
    if (k > n) return 0;
    k = std::min(k, n - k);
    long double result = 1;
    for (std::size_t index = 1; index <= k; ++index) result *= static_cast<long double>(n - k + index) / index;
    return result;
}

double knockout_probability(const RulesSession &position, const Value &state,
    std::int32_t actor, const Value &pokemon, const std::string &slot,
    const Value &attack, std::int64_t expected_damage, const Value &cards) {
    const Value *defender = active(state, 1 - actor);
    if (defender == nullptr) return 0;
    const auto hp = position.pokemon_current_hp(*defender);
    double probability = expected_damage >= hp ? 1.0 : 0.0;
    Value simulation = state;
    place_candidate_in_active(simulation, actor, pokemon, slot);
    const auto lethal = [&](std::int64_t base) {
        return reference_modified_attack_damage(simulation, actor, pokemon, *defender,
            base, cards, false) >= hp;
    };
    for (const Value &command : array_field(attack, "compiled_effects")) {
        const std::string op = string_field(command, "op");
        const Value *args = field(command, "args");
        if (op == "flip_coin_then_ko") probability = modifier_kind(defender, "prevent_effects") ? 0.0 : 0.25;
        if (op == "flip_coin_repeat_damage" && args != nullptr) {
            const auto flips = static_cast<std::size_t>(std::clamp<std::int64_t>(integer_field(*args, "flips", 3), 0, 16));
            probability = 0;
            for (std::size_t heads = 0; heads <= flips; ++heads) {
                if (lethal(static_cast<std::int64_t>(heads) * integer_field(*args, "damage_per_head", 10))) {
                    probability += static_cast<double>(combinations(flips, heads)) * std::pow(0.5, static_cast<double>(flips));
                }
            }
        }
        if (op == "flip_until_tails" && args != nullptr) {
            probability = 0;
            for (std::size_t heads = 1; heads <= 64; ++heads) {
                if (lethal(static_cast<std::int64_t>(heads) * integer_field(*args, "per_head", 20))) {
                    probability = std::pow(0.5, static_cast<double>(heads));
                    break;
                }
            }
        }
        if (op == "mill_then_damage" && args != nullptr) {
            const auto &deck = array_field(player(state, actor), "deck");
            const auto draws = std::min<std::size_t>(deck.size(), static_cast<std::size_t>(
                std::max<std::int64_t>(0, integer_field(*args, "mill_count", 5))));
            const auto energies = static_cast<std::size_t>(std::count_if(deck.begin(), deck.end(),
                [&](const Value &entry) { return is_energy(cards, entry.string_or()); }));
            const long double denominator = combinations(deck.size(), draws);
            probability = 0;
            for (std::size_t count = 0; count <= draws && denominator > 0; ++count) {
                if (lethal(static_cast<std::int64_t>(count) * integer_field(*args, "damage_per", 80))) {
                    probability += static_cast<double>(combinations(energies, count)
                        * combinations(deck.size() - energies, draws - count) / denominator);
                }
            }
        }
    }
    for (const Value &effect : array_field(attack, "effects")) {
        const auto kind = string_field(effect, "effect_type");
        const Value *params = field(effect, "params");
        if (kind == "coin_flip" && params != nullptr
            && branch_has_effect(field(*params, "on_tails"), "attack_fail")) {
            probability = lethal(integer_field(attack, "damage")) ? 0.5 : 0.0;
        }
    }
    if (array_contains(field(pokemon, "status_conditions"), "CONFUSED")) probability *= 0.5;
    if (modifier_kind(&pokemon, "attack_gate_coin", "dazzled")) probability *= 0.5;
    return std::clamp(probability, 0.0, 1.0);
}

// Count usable engine activations, including their source-zone and target
// constraints. A support attack consumes the turn, so it is not a free ability.
struct EnergyAccess {
    std::size_t units;
    std::size_t engine_units;
    Value charged;
    Value remaining;
};
EnergyAccess engine_attachments(const RulesSession &position, const Value &cards, const Value &state,
    std::int32_t actor, const Value &pokemon, const std::string &slot, const Value::Array &cost,
    bool manual_available) {
    const Value &owner = player(state, actor);
    Value available = owner;
    Value charged = pokemon;
    std::size_t count = 0;
    const auto accepts = [&](const std::string &id, std::string filter) {
        if (!is_energy(cards, id)) return false;
        filter = lower_ascii(filter);
        if (filter.rfind("basic_", 0) == 0) {
            if (!is_basic_energy(cards, id)) return false;
            filter.erase(0, 6);
        }
        if (filter.size() > 7 && filter.substr(filter.size() - 7) == "_energy") filter.resize(filter.size() - 7);
        if (filter != "any" && filter != "energy" && !filter.empty()) {
            Value single = Value::make_object();
            single["energy_card_ids"] = Value(Value::Array{Value(id)});
            if (energy_type_count(cards, &single, filter) == 0) return false;
        }
        return missing_energy(cards, pokemon_with_extra_energy(charged, id), cost)
            < missing_energy(cards, charged, cost);
    };
    const auto consume = [&](Value::Array &pool, const std::string &filter, std::size_t limit) {
        for (auto iterator = pool.begin(); iterator != pool.end() && limit > 0;) {
            const std::string id = iterator->string_or();
            if (!accepts(id, filter)) { ++iterator; continue; }
            const auto before = missing_energy(cards, charged, cost);
            charged = pokemon_with_extra_energy(charged, id);
            count += static_cast<std::size_t>(before - missing_energy(cards, charged, cost));
            iterator = pool.erase(iterator);
            --limit;
        }
    };
    std::size_t manual_units = 0;
    if (manual_available) {
        auto &hand = available["hand"].as_array();
        std::stable_sort(hand.begin(), hand.end(), [&](const Value &left, const Value &right) {
            const auto deficit = [&](const Value &entry) {
                return !is_energy(cards, entry.string_or()) ? std::int64_t{99}
                    : missing_energy(cards, pokemon_with_extra_energy(pokemon, entry.string_or()), cost);
            };
            return deficit(left) < deficit(right);
        });
        consume(hand, "any", 1);
        manual_units = count;
    }
    for (const Value *engine : board(state, actor)) {
        const auto *definition = card(cards, string_field(*engine, "card_id"));
        if (definition == nullptr) continue;
        for (const Value &ability : array_field(*definition, "abilities")) {
            if (array_contains(field(*engine, "used_abilities"), string_field(ability, "name"))) continue;
            bool lethal_cost = false;
            for (const Value &effect : array_field(ability, "effects")) {
                const Value *args = field(effect, "params");
                if (string_field(effect, "effect_type") == "damage_counter_self" && args != nullptr
                    && integer_field(*args, "amount") >= position.pokemon_current_hp(*engine)) lethal_cost = true;
            }
            if (lethal_cost) continue;
            for (const Value &effect : array_field(ability, "effects")) {
                const std::string kind = string_field(effect, "effect_type");
                const Value *args = field(effect, "params");
                if (args == nullptr) continue;
                if (kind != "energy_attach" && kind != "attach_from_discard"
                    && kind != "energy_relocate") continue;
                const std::string target = string_field(*args, "to", string_field(*args, "target"));
                if (target == "bench" && slot == "active") continue;
                if (target == "self" && engine != &pokemon) continue;
                const std::string filter = string_field(*args, "filter",
                    string_field(*args, "energy_type", "basic_energy"));
                if (kind == "energy_relocate") {
                    const auto transfer = [&](Value &donor, const std::string &donor_slot) {
                        if (!donor.is_object() || donor_slot == slot) return;
                        auto &energies = donor["energy_card_ids"].as_array();
                        consume(energies, filter, energies.size());
                    };
                    transfer(available["active"], "active");
                    auto &bench = available["bench"].as_array();
                    for (std::size_t index = 0; index < bench.size(); ++index) {
                        transfer(bench[index], "bench_" + std::to_string(index));
                    }
                } else {
                    const std::string zone = kind == "attach_from_discard"
                        ? "discard" : string_field(*args, "from_zone", "hand");
                    Value *pool = available.find(zone);
                    if (pool != nullptr && pool->is_array()) consume(pool->as_array(), filter,
                        static_cast<std::size_t>(std::max<std::int64_t>(0, integer_field(*args, "amount", 1))));
                }
            }
        }
    }
    return {count, count - manual_units, std::move(charged), std::move(available)};
}
} // namespace

AttackerClock StrategicAnalyzer::combat_clock(const RulesSession &position,
    const Value &state, std::int32_t actor, const Value &pokemon,
    const std::string &slot) const {
    AttackerClock result;
    result.slot = slot;
    result.card_id = string_field(pokemon, "card_id");
    result.planned_card_id = result.card_id;
    const Value &owner = player(state, actor);
    const Value *current = card(cards_, result.card_id);
    if (current == nullptr) return result;
    result.prizes_exposed = static_cast<std::size_t>(std::max<std::int64_t>(1, integer_field(*current, "prize_value", 1)));
    result.primary_role = strategies_.card_has_role(state, actor, result.card_id, "primary_attacker");
    result.secondary_role = strategies_.card_has_role(state, actor, result.card_id, "secondary_attacker");
    result.engine_role = strategies_.card_has_role(state, actor, result.card_id, "bench_engine");
    const bool our_turn = integer_field(state, "active_player_idx", -1) == actor;
    const bool manual_available = !our_turn || !bool_field(owner, "energy_attached_this_turn");
    const auto &hand = array_field(owner, "hand");
    if (slot != "active") {
        const Value *front = active(state, actor);
        const Value *front_card = front == nullptr ? nullptr : card(cards_, string_field(*front, "card_id"));
        const bool switch_in_hand = std::any_of(hand.begin(), hand.end(), [&](const Value &entry) {
            return strategies_.card_has_role(state, actor, entry.string_or(), "switch");
        });
        if (front_card != nullptr && !switch_in_hand
            && integer_field(*front_card, "retreat_cost") > energy_unit_count(cards_, front)) {
            result.promotion_delay = 1;
        }
    }

    struct Evolution { std::string id; std::size_t steps; double access; };
    std::vector<Evolution> options{{result.card_id, 0, 1.0}};
    const std::string name = string_field(*current, "name");
    for (const auto &[id, definition] : cards_.as_object()) {
        if (!definition.is_object() || !accessible(owner, id)) continue;
        const std::string previous = string_field(definition, "evolves_from");
        std::size_t steps = previous == name ? 1 : 0;
        double prerequisite_access = 1.0;
        if (steps == 0 && !previous.empty()) {
            const auto middle = evolves_from_by_name_.find(previous);
            if (middle != evolves_from_by_name_.end() && middle->second == name) {
                const bool candy = accessible(owner, "sv1-152");
                bool middle_accessible = false;
                bool middle_in_hand = false;
                for (const auto &[mid_id, mid] : cards_.as_object()) {
                    if (string_field(mid, "name") == previous && accessible(owner, mid_id)) {
                        middle_accessible = true;
                        middle_in_hand = middle_in_hand || array_contains(field(owner, "hand"), mid_id);
                    }
                }
                if (candy || middle_accessible) steps = candy ? 1 : 2;
                if (candy && !array_contains(field(owner, "hand"), "sv1-152")) prerequisite_access = 0.55;
                if (!candy && !middle_in_hand) prerequisite_access = 0.55;
            }
        }
        if (steps == 0) continue;
        const double access = (array_contains(field(owner, "hand"), id) ? 1.0 : 0.55) * prerequisite_access;
        options.push_back({id, steps, access});
    }
    double best_value = -1.0;
    for (const Evolution &evolution : options) {
        Value probe = pokemon;
        probe["card_id"] = Value(evolution.id);
        if (evolution.steps > 0) probe["status_conditions"] = Value::make_array();
        const Value *definition = card(cards_, evolution.id);
        if (definition == nullptr) continue;
        const auto &attacks = array_field(*definition, "attacks");
        for (std::size_t index = 0; index < attacks.size(); ++index) {
            const auto &cost = array_field(attacks[index], "cost");
            const auto energy_access = engine_attachments(position, cards_, state, actor, pokemon, slot, cost, manual_available);
            const auto missing = static_cast<std::size_t>(std::max<std::int64_t>(0, missing_energy(cards_, probe, cost)));
            Value prepared = probe;
            prepared["energy_card_ids"] = Value(array_field(energy_access.charged, "energy_card_ids"));
            const Value funded = fund_attack(cards_, energy_access.remaining, std::move(prepared), cost);
            const bool accessible_energy = missing_energy(cards_, funded, cost) == 0;
            Value projected_state = state;
            projected_state["players"].as_array()[static_cast<std::size_t>(actor)] = energy_access.remaining;
            const auto damage = std::max<std::int64_t>(0, estimated_damage_for_pokemon(
                position, projected_state, actor, funded, slot, index, cards_));
            if (evolution.steps == 0 && missing == 0) {
                result.expected_damage = std::max(result.expected_damage,
                    estimated_damage_for_pokemon(position, state, actor, pokemon, slot, index, cards_));
                result.ready_ko_probability = std::max(result.ready_ko_probability,
                    knockout_probability(position, state, actor, pokemon, slot, attacks[index],
                        estimated_damage_for_pokemon(position, state, actor, pokemon, slot, index, cards_), cards_));
            }
            std::size_t delay = missing > energy_access.units ? missing - energy_access.units : 0;
            std::size_t evolution_delay = evolution.steps;
            if (evolution.steps > 0 && evolution.access == 1.0
                && !bool_field(pokemon, "placed_this_turn")
                && bool_field(pokemon, "can_evolve_this_turn", true)
                && integer_field(state, "turn_number") >= 3) --evolution_delay;
            delay = std::max(delay, evolution_delay);
            if (!accessible_energy) delay = std::max<std::size_t>(delay, 4);
            const Value *commands = field(attacks[index], "compiled_effects");
            const double reload = std::max(0.0, discard_units(
                commands == nullptr ? Value() : *commands,
                static_cast<double>(energy_unit_count(cards_, &funded)))
                - static_cast<double>(energy_access.engine_units) - 1.0);
            const double access = evolution.access * (accessible_energy ? 1.0 : 0.1);
            const double value = static_cast<double>(damage) * access
                / (1.0 + static_cast<double>(delay) * 0.65 + reload * 0.25);
            if (value <= best_value) continue;
            best_value = value;
            result.planned_card_id = evolution.id;
            result.attack_index = index;
            result.missing_energy = missing;
            result.missing_evolution_steps = evolution.steps;
            result.max_relevant_damage = damage;
            result.earliest_ready_turn = delay;
            result.reload_turns = reload;
            result.access_probability = access;
            result.forecast_pokemon = funded;
            result.forecast_owner = energy_access.remaining;
            result.planned_ko_probability = knockout_probability(position, projected_state, actor,
                funded, slot, attacks[index], damage, cards_);
        }
    }
    result.readiness_probability = result.access_probability
        / (1.0 + static_cast<double>(result.earliest_ready_turn)
            + static_cast<double>(result.promotion_delay) * 0.5);
    if (result.max_relevant_damage <= 0) result.readiness_probability *= 0.25;
    if (slot == "active" && (array_contains(field(pokemon, "status_conditions"), "PARALYZED")
        || array_contains(field(pokemon, "status_conditions"), "ASLEEP"))) {
        result.expected_damage = 0;
        result.ready_ko_probability = 0;
        result.readiness_probability *= 0.5;
    }
    if (our_turn && integer_field(state, "turn_number") == 1
        && integer_field(state, "first_player_idx", -1) == actor) {
        result.expected_damage = 0;
        result.ready_ko_probability = 0;
        result.earliest_ready_turn = std::max<std::size_t>(1, result.earliest_ready_turn);
    }
    return result;
}

namespace {
double pipeline_readiness_value(const AttackerPipeline &pipeline) {
    double readiness = 0.0;
    for (const auto &clock : pipeline.attackers) {
        readiness += clock.readiness_probability * std::min<std::int64_t>(250, clock.max_relevant_damage);
    }
    return readiness * 1.25;
}
}

double StrategicAnalyzer::readiness_value(const RulesSession &position, const Value &state,
    std::int32_t actor) const {
    return pipeline_readiness_value(attacker_pipeline(position, state, actor));
}

double StrategicAnalyzer::resource_value(const RulesSession &position, const Value &state,
    std::int32_t actor) const {
    const auto pipeline = attacker_pipeline(position, state, actor);
    const auto &hand = array_field(player(state, actor), "hand");
    const bool gust = std::any_of(hand.begin(), hand.end(), [&](const Value &entry) {
        return semantics_.profile(entry.string_or()).gust;
    });
    return pipeline_readiness_value(pipeline)
        - prize_route(position, state, actor, pipeline, gust ? 0.5 : 0.0) * 20.0;
}

double StrategicAnalyzer::prize_route(const RulesSession &position, const Value &state,
    std::int32_t actor, const AttackerPipeline &pipeline, double gust_probability) const {
    using namespace traditional_trusted_detail;
    const auto remaining = array_field(player(state, actor), "prizes").size();
    if (remaining == 0) return 0.0;
    if (pipeline.attackers.empty()) return 20.0;
    struct Target { Value pokemon; std::string slot; double hp; std::size_t prizes; bool active; };
    std::vector<Target> targets;
    const Value &opponent = player(state, 1 - actor);
    const auto add_target = [&](const Value *pokemon, const std::string &slot) {
        if (pokemon == nullptr || !pokemon->is_object()) return;
        const auto *definition = card(cards_, string_field(*pokemon, "card_id"));
        targets.push_back({*pokemon, slot, static_cast<double>(position.pokemon_current_hp(*pokemon)),
            static_cast<std::size_t>(std::max<std::int64_t>(1, definition == nullptr ? 1 : integer_field(*definition, "prize_value", 1))),
            slot == "active"});
    };
    add_target(active(state, 1 - actor), "active");
    const auto &bench = array_field(opponent, "bench");
    for (std::size_t index = 0; index < bench.size(); ++index) {
        add_target(&bench[index], "bench_" + std::to_string(index));
    }
    double best = 20.0;
    for (const AttackerClock &attacker : pipeline.attackers) {
        if (attacker.max_relevant_damage <= 0 || attacker.access_probability <= 0.1) continue;
        const Value *source = pokemon_at(player(state, actor), attacker.slot);
        const Value *definition = card(cards_, attacker.planned_card_id);
        if (source == nullptr || definition == nullptr) continue;
        const auto &moves = array_field(*definition, "attacks");
        if (attacker.attack_index >= moves.size()) continue;
        const Value &forecast = attacker.forecast_pokemon;
        std::vector<std::size_t> hits_to_ko;
        for (const Target &target : targets) {
            Value simulation = state;
            simulation["players"].as_array()[static_cast<std::size_t>(actor)] = attacker.forecast_owner;
            place_candidate_in_active(simulation, actor, forecast, attacker.slot);
            place_candidate_in_active(simulation, 1 - actor, target.pokemon, target.slot);
            std::size_t hits = 0;
            auto &defender = simulation["players"].as_array()[static_cast<std::size_t>(1 - actor)]["active"];
            while (hits < 4 && position.pokemon_current_hp(defender) > 0) {
                const auto damage = estimated_attack_damage(position, simulation, actor, attacker.attack_index, cards_);
                if (damage <= 0) { hits = 4; break; }
                defender["damage_counters"] = Value(integer_field(defender, "damage_counters") + damage / 10);
                ++hits;
            }
            hits_to_ko.push_back(std::max<std::size_t>(1, hits));
        }
        // Three concrete attack opportunities. A target can pay prizes once;
        // unobserved future targets yield a conservative single prize each.
        std::function<void(std::size_t, std::size_t, unsigned, double, bool)> visit;
        visit = [&](std::size_t attacks, std::size_t taken, unsigned used, double turns, bool gust_used) {
            if (taken >= remaining) { best = std::min(best, turns); return; }
            if (attacks == 3) {
                best = std::min(best, turns + static_cast<double>(remaining - taken) * (1.0 + attacker.reload_turns));
                return;
            }
            bool advanced = false;
            std::size_t promoted = targets.size();
            double worst_exchange = -1.0;
            for (std::size_t index = 0; index < targets.size(); ++index) {
                if ((used & (1U << index)) != 0) continue;
                if (used == 0 && targets[index].active) { promoted = index; break; }
                const double exchange = static_cast<double>(hits_to_ko[index]) / targets[index].prizes;
                if (exchange > worst_exchange) { worst_exchange = exchange; promoted = index; }
            }
            for (std::size_t index = 0; index < targets.size(); ++index) {
                if ((used & (1U << index)) != 0) continue;
                const Target &target = targets[index];
                const bool gust = index != promoted;
                if (gust && (gust_used || gust_probability <= 0.0)) continue;
                const auto hits = hits_to_ko[index];
                if (hits + attacks > 3) continue;
                const double cost = static_cast<double>(hits)
                    + static_cast<double>(hits - (attacks == 0 ? 1 : 0)) * attacker.reload_turns
                    + (gust ? (1.0 - gust_probability) * 2.0 : 0.0);
                if (targets.size() == 1 && attacks == 0 && hits == 1
                    && attacker.earliest_ready_turn == 0 && attacker.promotion_delay == 0
                    && attacker.access_probability == 1.0) {
                    best = std::min(best, turns + cost);
                    continue;
                }
                visit(attacks + hits, taken + target.prizes, used | (1U << index), turns + cost, gust_used || gust);
                advanced = true;
            }
            if (!advanced) best = std::min(best, turns
                + static_cast<double>(remaining - taken) * 2.0 * (1.0 + attacker.reload_turns));
        };
        visit(0, 0, 0, static_cast<double>(attacker.earliest_ready_turn + attacker.promotion_delay)
            + (1.0 - attacker.access_probability) * 2.0, false);
    }
    return std::clamp(best, 0.0, 20.0);
}
} // namespace ptcg::ai::planner_v3
