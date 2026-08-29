#include "ptcg_traditional_evaluation_detail.hpp"

namespace ptcg::ai::traditional_trusted_detail {

const Value::Array &DeckProfile::cards(const char *role) const {
    static const Value::Array empty;
    if (value == nullptr || !value->is_object()) return empty;
    return array_field(*value, role);
}

bool DeckProfile::contains(
    const char *role,
    const std::string &card_id
) const {
    return !card_id.empty() && array_contains(cards(role), card_id);
}

std::int64_t DeckProfile::high_impact_damage_floor() const {
    return value == nullptr ? 110
        : integer_field(*value, "high_impact_damage_floor", 110);
}

DeckProfile profile(const Value &catalog, const std::string &deck_key) {
    const Value *plans = field(catalog, "deck_plans");
    if (plans == nullptr || !plans->is_object()) return {};
    const Value *value = plans->find(deck_key);
    if (value == nullptr || !value->is_object()) value = plans->find("fallback");
    return {value != nullptr && value->is_object() ? value : nullptr};
}

bool contains(const std::vector<std::string> &values, const std::string &needle){
    return std::find(values.begin(), values.end(), needle) != values.end();
}

std::vector<const Value *> board(const Value &state, std::int32_t actor){
    std::vector<const Value *> result;
    const Value &owner = player(state, actor);
    const Value *active_value = field(owner, "active");
    if (active_value != nullptr && active_value->is_object()) result.push_back(active_value);
    for (const Value &pokemon : array_field(owner, "bench")) {
        if (pokemon.is_object()) result.push_back(&pokemon);
    }
    return result;
}

bool had_knockout(const Value &state, std::int32_t defeated, bool attack_only){
    const Value *book = field(state, "turn_fact_book");
    const Value *previous = book == nullptr ? nullptr : field(*book, "previous_turn");
    const Value *facts = previous == nullptr ? nullptr : field(*previous, "knockouts");
    if (facts == nullptr || !facts->is_array()) return false;
    for (const Value &fact : facts->as_array()) {
        if (integer_field(fact, "defeated_player", -1) != defeated
            || integer_field(fact, "source_player", -1) < 0) continue;
        if (!attack_only) return true;
        if (integer_field(fact, "source_player", defeated) != defeated
            && string_field(fact, "source_kind") == "attack_damage"
            && string_field(fact, "cause_kind") == "damage") return true;
    }
    return false;
}

void append_flattened_effect(
    const Value &effect,
    std::vector<const Value *> &result
){
    if (!effect.is_object()) return;
    result.push_back(&effect);
    const Value *params = field(effect, "params");
    if (params == nullptr || !params->is_object()) return;
    for (const char *key : {
        "on_heads", "on_tails", "on_success", "on_fail", "on_pay", "cost",
    }) {
        const Value *branch = field(*params, key);
        if (branch == nullptr) continue;
        if (branch->is_object()) {
            append_flattened_effect(*branch, result);
        } else if (branch->is_array()) {
            for (const Value &nested : branch->as_array()) {
                append_flattened_effect(nested, result);
            }
        }
    }
}

std::vector<const Value *> flatten_effects(const Value::Array &effects){
    std::vector<const Value *> result;
    for (const Value &effect : effects) append_flattened_effect(effect, result);
    return result;
}

bool branch_has_effect(const Value *branch, const std::string &kind){
    if (branch == nullptr) return false;
    Value::Array effects;
    if (branch->is_object()) effects.push_back(*branch);
    else if (branch->is_array()) effects = branch->as_array();
    for (const Value *effect : flatten_effects(effects)) {
        if (string_field(*effect, "effect_type") == kind) return true;
    }
    return false;
}

bool condition_applies(
    const Value &state,
    std::int32_t actor,
    const Value &params,
    const Value &cards
){
    const std::string condition = string_field(params, "condition");
    const Value *opponent_active = active(state, 1 - actor);
    if (condition == "opponent_active_damaged") {
        return opponent_active != nullptr && integer_field(*opponent_active, "damage_counters") > 0;
    }
    if (condition == "field_energy_ge_5") {
        std::int64_t count = 0;
        for (const Value *pokemon : board(state, actor)) count += energy_unit_count(cards, pokemon);
        return count >= 5;
    }
    if (condition == "opponent_active_evolved") {
        return opponent_active != nullptr
            && !is_basic_pokemon(cards, string_field(*opponent_active, "card_id"));
    }
    if (condition == "ko_by_attack_last_turn" || condition == "ko_by_attack_damage_last_turn") {
        return had_knockout(state, actor, true);
    }
    if (condition == "ko_last_opponent_turn") return had_knockout(state, actor, false);
    return opponent_active != nullptr && integer_field(*opponent_active, "damage_counters") > 0;
}

std::int64_t branch_damage(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value *branch,
    const Value &cards
){
    if (branch == nullptr) return 0;
    Value::Array effects;
    if (branch->is_object()) effects.push_back(*branch);
    else if (branch->is_array()) effects = branch->as_array();
    std::int64_t best = 0;
    for (const Value *effect : flatten_effects(effects)) {
        best = std::max(best, effect_damage(position, state, actor, *effect, cards));
    }
    return best;
}

std::int64_t effect_damage(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &effect,
    const Value &cards
){
    const Value &own = player(state, actor);
    const Value &opponent = player(state, 1 - actor);
    const Value *own_active = active(state, actor);
    const Value *opponent_active = active(state, 1 - actor);
    const Value *params_value = field(effect, "params");
    static const Value empty = Value::make_object();
    const Value &params = params_value != nullptr && params_value->is_object()
        ? *params_value : empty;
    const std::string kind = string_field(effect, "effect_type");
    if (kind == "damage") return integer_field(params, "amount");
    if (kind == "conditional_damage_bonus") return condition_applies(
        state, actor, params, cards)
        ? integer_field(params, "bonus", integer_field(params, "amount")) : 0;
    if (kind == "damage_per_self_damage") return integer_field(params, "base")
        + (own_active == nullptr ? 0 : integer_field(*own_active, "damage_counters"))
            * integer_field(params, "per_counter");
    if (kind == "damage_per_self_energy" || kind == "damage_per_self_energy_type") {
        const std::string filter = lower_ascii(string_field(
            params, "energy_filter", string_field(params, "energy_type")));
        return integer_field(params, "base")
            + energy_type_count(cards, own_active, filter) * integer_field(params, "per_energy");
    }
    if (kind == "damage_per_energy") {
        std::int64_t count = 0;
        const std::string from = string_field(params, "count_from", "self");
        if (from == "opponent_active") count = energy_unit_count(cards, opponent_active);
        else if (from == "all_opponent") {
            for (const Value *pokemon : board(state, 1 - actor)) count += energy_unit_count(cards, pokemon);
        } else count = energy_unit_count(cards, own_active);
        return integer_field(params, "base") + count * integer_field(params, "per_energy");
    }
    if (kind == "damage_plus_bench") return integer_field(params, "base")
        + bench_count(own) * integer_field(params, "per_bench");
    if (kind == "attack_damage_formula") {
        std::int64_t total = integer_field(params, "base")
            + bench_count(own) * integer_field(params, "per_own_bench");
        const std::string energy_type = string_field(params, "per_self_energy_type");
        if (own_active != nullptr && !energy_type.empty()) {
            total += energy_type_count(cards, own_active, energy_type)
                * integer_field(params, "per_energy");
        }
        if (own_active != nullptr) total += integer_field(*own_active, "damage_counters")
            * integer_field(params, "per_self_damage_counter");
        const Value *bonus = field(params, "condition_bonus");
        if (bonus != nullptr && bonus->is_object()) {
            const std::string condition = string_field(*bonus, "condition");
            bool applies = false;
            if (condition == "ko_by_attack_last_turn" || condition == "ko_by_attack_damage_last_turn")
                applies = had_knockout(state, actor, true);
            else if (condition == "ko_last_opponent_turn") applies = had_knockout(state, actor, false);
            else if (condition == "own_bench_damaged") {
                applies = std::any_of(array_field(own, "bench").begin(), array_field(own, "bench").end(),
                    [](const Value &pokemon) {
                        return pokemon.is_object() && integer_field(pokemon, "damage_counters") > 0;
                    });
            } else if (condition == "opponent_active_evolved") {
                applies = opponent_active != nullptr
                    && !is_basic_pokemon(cards, string_field(*opponent_active, "card_id"));
            } else if (condition == "opponent_active_damaged") {
                applies = opponent_active != nullptr && integer_field(*opponent_active, "damage_counters") > 0;
            } else if (condition == "own_hand_empty") applies = array_field(own, "hand").empty();
            if (applies) total += integer_field(*bonus, "bonus");
        }
        return total;
    }
    if (kind == "damage_per_hand_size") return static_cast<std::int64_t>(array_field(own, "hand").size())
        * integer_field(params, "per");
    if (kind == "discard_hand_conditional_bonus") {
        const auto base = integer_field(params, "base_damage", integer_field(params, "base"));
        return base + (array_field(own, "hand").size()
            >= static_cast<std::size_t>(std::max<std::int64_t>(0, integer_field(params, "threshold", 5)))
                ? integer_field(params, "bonus") : 0);
    }
    if (kind == "damage_per_discard_psychic") {
        std::int64_t count = 0;
        for (const Value &entry : array_field(own, "discard")) {
            const Value *definition = card(cards, entry.string_or());
            if (definition != nullptr && is_pokemon(cards, entry.string_or())
                && array_contains(array_field(*definition, "energy_types"), "Psychic")) ++count;
        }
        return integer_field(params, "base") + count * integer_field(params, "per_card");
    }
    if (kind == "discard_fighting_energy_damage") {
        std::int64_t count = 0;
        if (own_active != nullptr) {
            const auto &attached = array_field(*own_active, "energy_card_ids");
            for (std::size_t index = 0; index < attached.size(); ++index) {
                Value one = *own_active;
                one["energy_card_ids"] = Value(Value::Array{attached[index]});
                const auto units = energy_units(cards, one);
                if (std::find(units.begin(), units.end(), "Fighting") != units.end()
                    || std::find(units.begin(), units.end(), "Rainbow") != units.end()) ++count;
            }
        }
        return integer_field(params, "base", 10) + count * integer_field(params, "per_energy", 60);
    }
    if (kind == "damage_per_evolved") {
        std::int64_t evolved = 0;
        for (const Value *pokemon : board(state, actor)) {
            if (!array_field(*pokemon, "evolution_stack_ids").empty()) ++evolved;
        }
        return evolved * integer_field(params, "per_evolved");
    }
    if (kind == "conditional_damage_heal") return integer_field(params, "base")
        + (own_active != nullptr && bool_field(*own_active, "healed_this_turn")
            ? integer_field(params, "bonus") : 0);
    if (kind == "damage_and_self_heal") return integer_field(
        params, "damage", integer_field(params, "amount"));
    if (kind == "any_pokemon_damage" || kind == "bench_damage") return integer_field(
        params, "amount", integer_field(params, "damage"));
    if (kind == "place_counters_and_self_discard") return integer_field(
        params, "amount", integer_field(params, "damage",
            integer_field(params, "counters") * 10));
    if (kind == "mill_and_damage_per_energy") {
        const auto &deck = array_field(own, "deck");
        const std::size_t count = static_cast<std::size_t>(std::max<std::int64_t>(
            0, integer_field(params, "mill_count", 5)));
        const std::size_t begin = deck.size() > count ? deck.size() - count : 0;
        std::int64_t energy_seen = 0;
        for (std::size_t index = begin; index < deck.size(); ++index) {
            if (is_energy(cards, deck[index].string_or())) ++energy_seen;
        }
        return energy_seen * integer_field(params, "damage_per");
    }
    if (kind == "damage_self_penalty") return std::max<std::int64_t>(0,
        integer_field(params, "base") - (own_active == nullptr ? 0
            : integer_field(*own_active, "damage_counters"))
            * integer_field(params, "per_counter"));
    if (kind == "coin_flip_triple") return static_cast<std::int64_t>(
        static_cast<double>(integer_field(params, "damage_per_head", 10)) * 1.5);
    if (kind == "coin_flip_until_tails") return integer_field(params, "per_head", 20);
    if (kind == "coin_flip_double_ko") return static_cast<std::int64_t>(
        static_cast<double>(opponent_active == nullptr ? 0
            : position.pokemon_current_hp(*opponent_active)) * 0.25);
    if (kind == "coin_flip") return static_cast<std::int64_t>(
        static_cast<double>(branch_damage(position, state, actor, field(params, "on_heads"), cards)
            + branch_damage(position, state, actor, field(params, "on_tails"), cards)) * 0.5);
    return 0;
}

std::int64_t reference_modified_attack_damage(
    const Value &state,
    std::int32_t actor,
    const Value &attacker,
    const Value &defender,
    std::int64_t base_damage,
    const Value &cards,
    bool ignore_defender_damage_effects
){
    if (base_damage <= 0) return std::max<std::int64_t>(0, base_damage);
    std::int64_t damage = base_damage;
    const Value *attacker_definition = card(
        cards, string_field(attacker, "card_id"));
    const Value *defender_definition = card(
        cards, string_field(defender, "card_id"));

    for (const Value *aura_source : board(state, actor)) {
        const Value *source_definition = card(
            cards, string_field(*aura_source, "card_id"));
        if (source_definition == nullptr) continue;
        for (const Value &ability : array_field(*source_definition, "abilities")) {
            for (const Value &effect : array_field(ability, "effects")) {
                if (string_field(effect, "effect_type") != "aura_damage_boost") {
                    continue;
                }
                const Value *params_value = field(effect, "params");
                static const Value empty = Value::make_object();
                const Value &params = params_value != nullptr
                    && params_value->is_object() ? *params_value : empty;
                const std::string attacker_subtype = string_field(
                    params, "attacker_subtype");
                const std::string defender_type = string_field(
                    params, "defender_type");
                if (
                    !attacker_subtype.empty()
                    && (
                        attacker_definition == nullptr
                        || !array_contains(
                            array_field(*attacker_definition, "subtypes"),
                            attacker_subtype)
                    )
                ) continue;
                if (
                    !defender_type.empty()
                    && (
                        defender_definition == nullptr
                        || !array_contains(
                            array_field(*defender_definition, "energy_types"),
                            defender_type)
                    )
                ) continue;
                damage += integer_field(params, "amount");
            }
        }
    }

    for (const Value &energy_id : array_field(attacker, "energy_card_ids")) {
        const Value *energy = card(cards, energy_id.string_or());
        if (energy == nullptr) continue;
        for (const Value &effect : array_field(*energy, "energy_effects")) {
            const Value *operation = field(effect, "effect");
            const Value *delta = operation != nullptr && operation->is_object()
                ? field(*operation, "delta") : nullptr;
            if (
                string_field(effect, "kind") == "modifier"
                && string_field(effect, "hook") == "MODIFY_DAMAGE"
                && string_field(effect, "scope") == "attached_attacker"
                && delta != nullptr && delta->is_integer()
            ) damage += delta->as_integer();
        }
    }
    for (const Value &modifier : array_field(attacker, "modifiers")) {
        const Value *operation = field(modifier, "operation");
        if (operation != nullptr && operation->is_object()
            && string_field(*operation, "kind") == "damage_delta") {
            damage += integer_field(*operation, "amount");
        }
    }

    bool tool_boost_materialized = false;
    for (const Value &modifier : array_field(attacker, "modifiers")) {
        const Value *operation = field(modifier, "operation");
        if (
            string_field(modifier, "hook") == "MODIFY_DAMAGE"
            && string_field(modifier, "scope") == "attached_attacker"
            && operation != nullptr && operation->is_object()
            && string_field(*operation, "kind") == "damage_delta"
            && integer_field(*operation, "amount") > 0
        ) {
            tool_boost_materialized = true;
            break;
        }
    }
    const std::string tool_id = string_field(attacker, "attached_tool_id");
    const Value *tool = tool_id.empty() ? nullptr : card(cards, tool_id);
    if (tool != nullptr && !tool_boost_materialized) {
        for (const Value &effect : array_field(*tool, "trainer_effects")) {
            if (string_field(effect, "effect_type") != "tool") continue;
            const Value *params_value = field(effect, "params");
            static const Value empty = Value::make_object();
            const Value &params = params_value != nullptr
                && params_value->is_object() ? *params_value : empty;
            const std::string name = string_field(params, "effect");
            if (name == "damage_boost_10") damage += 10;
            else if (name == "damage_boost_when_behind"
                && array_field(player(state, actor), "prizes").size()
                    > array_field(player(state, 1 - actor), "prizes").size()) {
                damage += 30;
            }
        }
    }
    if (damage <= 0) return 0;

    const auto aura_reduction = [&](bool before_weakness) {
        std::int64_t reduction = 0;
        if (defender_definition == nullptr) return reduction;
        for (const Value &ability : array_field(*defender_definition, "abilities")) {
            for (const Value &effect : array_field(ability, "effects")) {
                if (string_field(effect, "effect_type")
                    != "aura_damage_reduction") continue;
                const Value *params_value = field(effect, "params");
                static const Value empty = Value::make_object();
                const Value &params = params_value != nullptr
                    && params_value->is_object() ? *params_value : empty;
                if (bool_field(params, "before_weakness") != before_weakness) {
                    continue;
                }
                if (bool_field(params, "requires_attached_energy")
                    && array_field(defender, "energy_card_ids").empty()) {
                    continue;
                }
                reduction += integer_field(params, "reduction", 20);
            }
        }
        return reduction;
    };
    if (!ignore_defender_damage_effects) damage -= aura_reduction(true);
    if (damage <= 0) return 0;
    // Challenge/Deep normalize apply_type_matchups=false before trusted
    // evaluation, so Weakness and Resistance deliberately do not enter this
    // frozen projection.
    if (!ignore_defender_damage_effects) {
        damage -= aura_reduction(false);
        const std::string defender_tool_id = string_field(
            defender, "attached_tool_id");
        const Value *defender_tool = defender_tool_id.empty()
            ? nullptr : card(cards, defender_tool_id);
        if (defender_tool != nullptr) {
            for (const Value &effect : array_field(
                *defender_tool, "trainer_effects")) {
                if (string_field(effect, "effect_type") != "tool") continue;
                const Value *params_value = field(effect, "params");
                static const Value empty = Value::make_object();
                const Value &params = params_value != nullptr
                    && params_value->is_object() ? *params_value : empty;
                if (
                    string_field(params, "effect")
                        == "damage_reduction_stage1"
                    && is_stage1(cards, string_field(defender, "card_id"))
                ) damage -= integer_field(params, "amount", 30);
            }
        }
        if (modifier_kind(&defender, "prevent_damage")
            || modifier_kind(&defender, "prevent_effects")) return 0;
    }
    return std::max<std::int64_t>(0, damage);
}

std::int64_t estimated_attack_damage(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    std::size_t attack_index,
    const Value &cards
){
    const Value *attacker = active(state, actor);
    const Value *defender = active(state, 1 - actor);
    if (attacker == nullptr) return 0;
    const Value *definition = card(cards, string_field(*attacker, "card_id"));
    const auto &attacks = definition == nullptr
        ? Value::Array{} : array_field(*definition, "attacks");
    if (attack_index >= attacks.size()) return 0;
    const Value &attack = attacks[attack_index];
    const auto flattened = flatten_effects(array_field(attack, "effects"));
    bool full_damage = false;
    bool ignore_defender = false;
    static const std::set<std::string> full_kinds{
        "attack_damage_formula", "damage_per_self_damage", "damage_per_self_energy",
        "damage_per_self_energy_type", "damage_plus_bench", "damage_per_hand_size",
        "damage_per_energy", "damage_per_evolved", "damage_self_penalty",
        "damage_per_discard_psychic", "conditional_damage_heal",
        "discard_fighting_energy_damage", "discard_hand_conditional_bonus",
        "damage_and_self_heal", "any_pokemon_damage", "mill_and_damage_per_energy",
        "coin_flip_triple", "coin_flip_until_tails", "coin_flip_double_ko",
    };
    for (const Value *effect : flattened) {
        const std::string kind = string_field(*effect, "effect_type");
        if (full_kinds.count(kind)) full_damage = true;
        const Value *params = field(*effect, "params");
        if (params != nullptr && params->is_object()) {
            ignore_defender = ignore_defender
                || bool_field(*params, "ignore_defender_damage_effects")
                || bool_field(*params, "ignore_defender_effects")
                || bool_field(*params, "ignore_effects");
        }
    }
    std::int64_t damage = full_damage ? 0 : integer_field(attack, "damage");
    for (const Value *effect : flattened) {
        const std::string kind = string_field(*effect, "effect_type");
        if (kind == "coin_flip") {
            const Value *params = field(*effect, "params");
            if (params != nullptr && branch_has_effect(field(*params, "on_tails"), "attack_fail")) {
                damage = static_cast<std::int64_t>(std::llround(
                    static_cast<double>(damage + branch_damage(
                        position, state, actor, field(*params, "on_heads"), cards)) * 0.5));
                continue;
            }
        }
        const auto estimate = effect_damage(position, state, actor, *effect, cards);
        if (kind == "conditional_damage_bonus") damage += estimate;
        else damage = std::max(damage, estimate);
    }
    if (damage <= 0 || defender == nullptr) return std::max<std::int64_t>(0, damage);
    return reference_modified_attack_damage(
        state, actor, *attacker, *defender, damage, cards, ignore_defender);
}

std::int64_t best_available_damage(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &cards
){
    const Value *pokemon = active(state, actor);
    if (pokemon == nullptr) return 0;
    const Value *definition = card(cards, string_field(*pokemon, "card_id"));
    const auto &attacks = definition == nullptr ? Value::Array{} : array_field(*definition, "attacks");
    std::int64_t best = 0;
    for (std::size_t index = 0; index < attacks.size(); ++index) {
        if (missing_energy(cards, *pokemon, array_field(attacks[index], "cost")) <= 0) {
            best = std::max(best, estimated_attack_damage(position, state, actor, index, cards));
        }
    }
    return best;
}

std::int64_t best_ready_damage_for_pokemon(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &pokemon,
    const std::string &slot,
    const Value &cards
){
    Value simulation = state;
    Value *players = simulation.find("players");
    if (
        players == nullptr || !players->is_array() || actor < 0
        || static_cast<std::size_t>(actor) >= players->as_array().size()
    ) return 0;
    Value &owner = players->as_array()[static_cast<std::size_t>(actor)];
    Value original_active = field(owner, "active") == nullptr
        ? Value() : *field(owner, "active");
    if (slot.rfind("bench_", 0) == 0) {
        std::int64_t bench_index = -1;
        try {
            bench_index = std::stoll(slot.substr(6));
        } catch (const std::exception &) {
            return 0;
        }
        Value *bench = owner.find("bench");
        if (
            bench == nullptr || !bench->is_array() || bench_index < 0
            || static_cast<std::size_t>(bench_index) >= bench->as_array().size()
        ) return 0;
        bench->as_array()[static_cast<std::size_t>(bench_index)] =
            std::move(original_active);
    } else if (slot != "active") {
        return 0;
    }
    owner["active"] = pokemon;
    const Value *definition = card(cards, string_field(pokemon, "card_id"));
    if (definition == nullptr) return 0;
    std::int64_t best = 0;
    const auto &attacks = array_field(*definition, "attacks");
    for (std::size_t index = 0; index < attacks.size(); ++index) {
        if (missing_energy(cards, pokemon, array_field(attacks[index], "cost")) <= 0) {
            best = std::max(best, estimated_attack_damage(
                position, simulation, actor, index, cards));
        }
    }
    return best;
}

std::int64_t best_missing(const Value &cards, const Value *pokemon){
    if (pokemon == nullptr) return 99;
    const Value *definition = card(cards, string_field(*pokemon, "card_id"));
    const auto &attacks = definition == nullptr ? Value::Array{} : array_field(*definition, "attacks");
    if (attacks.empty()) return 99;
    std::int64_t result = 99;
    for (const Value &attack : attacks) {
        result = std::min(result, missing_energy(cards, *pokemon, array_field(attack, "cost")));
    }
    return result;
}

std::int64_t printed_best_damage(const Value &cards, const Value *pokemon){
    if (pokemon == nullptr) return 0;
    const Value *definition = card(cards, string_field(*pokemon, "card_id"));
    const auto &attacks = definition == nullptr ? Value::Array{} : array_field(*definition, "attacks");
    std::int64_t best = 0;
    for (const Value &attack : attacks) {
        std::int64_t damage = integer_field(attack, "damage");
        for (const Value *effect : flatten_effects(array_field(attack, "effects"))) {
            const Value *params_value = field(*effect, "params");
            static const Value empty = Value::make_object();
            const Value &params = params_value != nullptr && params_value->is_object()
                ? *params_value : empty;
            const std::string kind = string_field(*effect, "effect_type");
            if (kind == "damage_per_self_damage") damage = std::max(damage,
                integer_field(params, "base") + integer_field(*pokemon, "damage_counters")
                    * integer_field(params, "per_counter"));
            else if (kind == "damage_per_self_energy" || kind == "damage_per_self_energy_type") {
                const std::string type = string_field(params, "energy_filter",
                    string_field(params, "energy_type", "any"));
                damage = std::max(damage, integer_field(params, "base")
                    + energy_type_count(cards, pokemon, type) * integer_field(params, "per_energy"));
            } else if (kind == "damage_plus_bench") damage = std::max(damage,
                integer_field(params, "base") + integer_field(params, "per_bench") * 3);
            else if (kind == "discard_fighting_energy_damage") damage = std::max(damage,
                integer_field(params, "base") + energy_type_count(cards, pokemon, "Fighting")
                    * integer_field(params, "per_energy"));
            else if (kind == "damage_self_penalty") damage = std::max<std::int64_t>(0,
                integer_field(params, "base") - integer_field(*pokemon, "damage_counters")
                    * integer_field(params, "per_counter"));
            else if (kind == "conditional_damage_bonus") damage += integer_field(
                params, "bonus", integer_field(params, "amount"));
            else if (kind == "attack_damage_formula") {
                std::int64_t formula = integer_field(params, "base")
                    + integer_field(params, "per_own_bench") * 3;
                const std::string type = string_field(params, "per_self_energy_type");
                if (!type.empty()) formula += energy_type_count(cards, pokemon, type)
                    * integer_field(params, "per_energy");
                const Value *bonus = field(params, "condition_bonus");
                if (bonus != nullptr) formula += integer_field(*bonus, "bonus");
                damage = std::max(damage, formula);
            }
        }
        best = std::max(best, damage);
    }
    return best;
}

std::int64_t action_strength_damage(
    const Value &cards,
    const Value &definition,
    const Value *pokemon,
    std::int64_t energy_count
){
    std::int64_t best = 0;
    for (const Value &attack : array_field(definition, "attacks")) {
        std::int64_t damage = integer_field(attack, "damage");
        for (const Value *effect : flatten_effects(array_field(attack, "effects"))) {
            const Value *params_value = field(*effect, "params");
            static const Value empty = Value::make_object();
            const Value &params = params_value != nullptr && params_value->is_object()
                ? *params_value : empty;
            const std::string kind = string_field(*effect, "effect_type");
            if (kind == "damage_plus_bench") {
                damage = std::max(damage,
                    integer_field(params, "base")
                    + integer_field(params, "per_bench") * 3);
            } else if (
                kind == "damage_per_self_energy"
                || kind == "damage_per_self_energy_type"
            ) {
                const std::string type = string_field(
                    params, "energy_filter",
                    string_field(params, "energy_type", "any"));
                const std::int64_t units = pokemon == nullptr
                    ? energy_count : energy_type_count(cards, pokemon, type);
                damage = std::max(damage,
                    integer_field(params, "base")
                    + units * integer_field(params, "per_energy"));
            } else if (kind == "damage_self_penalty") {
                const std::int64_t counters = pokemon == nullptr
                    ? 0 : integer_field(*pokemon, "damage_counters");
                damage = std::max<std::int64_t>(0,
                    integer_field(params, "base")
                    - counters * integer_field(params, "per_counter"));
            } else if (kind == "conditional_damage_bonus") {
                damage += integer_field(
                    params, "bonus", integer_field(params, "amount"));
            } else if (kind == "attack_damage_formula") {
                std::int64_t formula = integer_field(params, "base")
                    + integer_field(params, "per_own_bench") * 3;
                const std::string type = string_field(
                    params, "per_self_energy_type");
                if (!type.empty()) {
                    const std::int64_t units = pokemon == nullptr
                        ? energy_count
                        : energy_type_count(cards, pokemon, type);
                    formula += units * integer_field(params, "per_energy");
                }
                const Value *bonus = field(params, "condition_bonus");
                if (bonus != nullptr) formula += integer_field(*bonus, "bonus");
                damage = std::max(damage, formula);
            }
        }
        best = std::max(best, damage);
    }
    return best;
}

const Value *pokemon_at(const Value &owner, const std::string &slot){
    if (slot == "active") {
        const Value *result = field(owner, "active");
        return result != nullptr && result->is_object() ? result : nullptr;
    }
    constexpr std::string_view prefix = "bench_";
    if (slot.rfind(prefix, 0) != 0) return nullptr;
    std::int64_t index = -1;
    try {
        index = std::stoll(slot.substr(prefix.size()));
    } catch (const std::exception &) {
        return nullptr;
    }
    const Value *bench = field(owner, "bench");
    return bench != nullptr && bench->is_array() && index >= 0
        && static_cast<std::size_t>(index) < bench->as_array().size()
        && bench->as_array()[static_cast<std::size_t>(index)].is_object()
        ? &bench->as_array()[static_cast<std::size_t>(index)] : nullptr;
}

bool modifier_kind(const Value *pokemon, const std::string &kind, const std::string &text){
    if (pokemon == nullptr) return false;
    for (const Value &modifier : array_field(*pokemon, "modifiers")) {
        const Value *operation = field(modifier, "operation");
        if (operation == nullptr || string_field(*operation, "kind") != kind) continue;
        if (text.empty()) return true;
        const std::string value = string_field(*operation, "attack_name",
            string_field(*operation, "reason"));
        if (value == text || value == "__all__") return true;
    }
    return false;
}

std::int64_t modifier_sum(const Value *pokemon, const std::string &kind){
    if (pokemon == nullptr) return 0;
    std::int64_t result = 0;
    for (const Value &modifier : array_field(*pokemon, "modifiers")) {
        const Value *operation = field(modifier, "operation");
        if (operation != nullptr && string_field(*operation, "kind") == kind) {
            result += integer_field(*operation, "amount");
        }
    }
    return result;
}

double deck_pressure(const Value &owner){
    const auto size = array_field(owner, "deck").size();
    if (size == 0) return 520.0;
    if (size <= 2) return 135.0 + static_cast<double>(3 - size) * 65.0;
    if (size <= 5) return 70.0 + static_cast<double>(6 - size) * 12.0;
    if (size <= 8) return 38.0 + static_cast<double>(9 - size) * 5.0;
    if (size <= 12) return 18.0;
    return 0.0;
}

std::string deck_key(const Value &state, std::int32_t actor){
    const auto &keys = array_field(state, "public_deck_keys");
    return actor >= 0 && static_cast<std::size_t>(actor) < keys.size()
        ? keys[static_cast<std::size_t>(actor)].string_or() : std::string{};
}

bool energy_matches_profile(
    const Value &cards,
    const std::string &card_id,
    const std::string &key
){
    const Value *definition = card(cards, card_id);
    if (definition == nullptr) return false;
    const auto &provided = array_field(*definition, "provides_energy");
    for (const Value &type_value : profile(cards, key).cards("energy")) {
        const std::string type = type_value.string_or();
        if (array_contains(provided, type) || array_contains(provided, "Rainbow")) return true;
    }
    return false;
}

std::int64_t energy_profile_match_count(
    const Value &cards,
    const std::string &card_id,
    const std::string &key
){
    const Value *definition = card(cards, card_id);
    if (definition == nullptr) return 0;
    const auto &provided = array_field(*definition, "provides_energy");
    std::int64_t count = 0;
    // Preserve the frozen GDScript loop exactly: Rainbow satisfies every
    // profile entry and therefore receives one +50 priority increment per
    // listed type (not merely one increment in total).
    for (const Value &type_value : profile(cards, key).cards("energy")) {
        const std::string type = type_value.string_or();
        if (array_contains(provided, type) || array_contains(provided, "Rainbow")) {
            ++count;
        }
    }
    return count;
}

double card_priority(const Value &cards, const std::string &card_id, const std::string &key){
    if (card_id.empty()) return 0.0;
    const DeckProfile p = profile(cards, key);
    double score = 0.0;
    if (p.contains("core", card_id)) score += 180.0;
    if (p.contains("engine", card_id)) score += 100.0;
    if (p.contains("evolution", card_id)) score += 120.0;
    if (p.contains("trainer", card_id)) score += 60.0;
    score += static_cast<double>(
        energy_profile_match_count(cards, card_id, key)) * 50.0;
    return score;
}

Value pokemon_with_extra_energy(
    const Value &pokemon,
    const std::string &energy_card_id
){
    Value result = pokemon;
    Value *attached = result.find("energy_card_ids");
    if (attached == nullptr || !attached->is_array()) {
        result["energy_card_ids"] = Value::make_array();
        attached = result.find("energy_card_ids");
    }
    attached->as_array().emplace_back(energy_card_id);
    return result;
}

std::int64_t best_missing_with_extra(
    const Value &cards,
    const Value *pokemon,
    const std::string &energy_card_id
){
    if (pokemon == nullptr) return 99;
    const Value probe = pokemon_with_extra_energy(*pokemon, energy_card_id);
    return best_missing(cards, &probe);
}

bool place_candidate_in_active(
    Value &simulation,
    std::int32_t actor,
    const Value &pokemon,
    const std::string &slot
){
    Value *players = simulation.find("players");
    if (
        players == nullptr || !players->is_array() || actor < 0
        || static_cast<std::size_t>(actor) >= players->as_array().size()
    ) return false;
    Value &owner = players->as_array()[static_cast<std::size_t>(actor)];
    Value original_active = field(owner, "active") == nullptr
        ? Value() : *field(owner, "active");
    if (slot.rfind("bench_", 0) == 0) {
        std::int64_t bench_index = -1;
        try {
            bench_index = std::stoll(slot.substr(6));
        } catch (const std::exception &) {
            return false;
        }
        Value *bench = owner.find("bench");
        if (
            bench == nullptr || !bench->is_array() || bench_index < 0
            || static_cast<std::size_t>(bench_index) >= bench->as_array().size()
        ) return false;
        bench->as_array()[static_cast<std::size_t>(bench_index)] =
            std::move(original_active);
    } else if (slot != "active") {
        return false;
    }
    owner["active"] = pokemon;
    return true;
}

std::int64_t estimated_damage_for_pokemon(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &pokemon,
    const std::string &slot,
    std::size_t attack_index,
    const Value &cards
){
    Value simulation = state;
    if (!place_candidate_in_active(simulation, actor, pokemon, slot)) return 0;
    return estimated_attack_damage(
        position, simulation, actor, attack_index, cards);
}

std::int64_t pokemon_attack_damage_ceiling(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &pokemon,
    const std::string &slot,
    std::size_t attack_index,
    const Value &cards
){
    const Value *definition = card(cards, string_field(pokemon, "card_id"));
    const auto &attacks = definition == nullptr
        ? Value::Array{} : array_field(*definition, "attacks");
    if (attack_index >= attacks.size()) return 0;
    const Value &attack = attacks[attack_index];
    std::int64_t potential = integer_field(attack, "damage");
    for (const Value *effect : flatten_effects(array_field(attack, "effects"))) {
        if (string_field(*effect, "effect_type") != "conditional_damage_bonus") {
            continue;
        }
        const Value *params = field(*effect, "params");
        if (params != nullptr && params->is_object()) {
            potential += integer_field(
                *params, "bonus", integer_field(*params, "amount"));
        }
    }
    return std::max(potential, estimated_damage_for_pokemon(
        position, state, actor, pokemon, slot, attack_index, cards));
}

std::int64_t best_pokemon_damage_for_state(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &pokemon,
    const std::string &slot,
    const Value &cards
){
    const Value *definition = card(cards, string_field(pokemon, "card_id"));
    const auto &attacks = definition == nullptr
        ? Value::Array{} : array_field(*definition, "attacks");
    std::int64_t best = 0;
    for (std::size_t index = 0; index < attacks.size(); ++index) {
        best = std::max(best, pokemon_attack_damage_ceiling(
            position, state, actor, pokemon, slot, index, cards));
    }
    return best;
}

HighImpactPlan high_impact_attack_plan(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &pokemon,
    const std::string &slot,
    const std::string &energy_card_id,
    const Value &cards
){
    const Value probe = !energy_card_id.empty() && is_energy(cards, energy_card_id)
        ? pokemon_with_extra_energy(pokemon, energy_card_id) : pokemon;
    const Value *definition = card(cards, string_field(probe, "card_id"));
    const auto &attacks = definition == nullptr
        ? Value::Array{} : array_field(*definition, "attacks");
    HighImpactPlan best;
    for (std::size_t index = 0; index < attacks.size(); ++index) {
        const std::int64_t missing = missing_energy(
            cards, probe, array_field(attacks[index], "cost"));
        const std::int64_t damage = pokemon_attack_damage_ceiling(
            position, state, actor, probe, slot, index, cards);
        const double impact = static_cast<double>(damage)
            - static_cast<double>(missing) * 50.0;
        if (
            impact > best.impact
            || (
                impact == best.impact
                && (missing < best.missing
                    || (missing == best.missing && damage > best.damage))
            )
        ) {
            best.damage = damage;
            best.missing = missing;
            best.impact = impact;
        }
    }
    return best;
}

std::int64_t high_impact_missing_energy(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &pokemon,
    const std::string &slot,
    const std::string &energy_card_id,
    const Value &cards
){
    return high_impact_attack_plan(
        position, state, actor, pokemon, slot, energy_card_id, cards).missing;
}

bool commands_require_belief_sampling(const Value &commands){
    if (!commands.is_array()) return false;
    static const std::set<std::string> belief_ops{
        "draw_and_attach_energy",
        "look_top_attach_energy",
        "look_top_deck",
        "mill_then_damage",
        "trekking_shoes",
    };
    for (const Value &command : commands.as_array()) {
        if (!command.is_object()) continue;
        const std::string op = string_field(command, "op");
        if (
            op.rfind("flip_coin", 0) == 0 || op == "flip_until_tails"
            || belief_ops.count(op)
        ) return true;
        const Value *branches = field(command, "branches");
        if (branches == nullptr || !branches->is_object()) continue;
        for (const auto &[branch_name, branch] : branches->as_object()) {
            (void)branch_name;
            if (commands_require_belief_sampling(branch)) return true;
        }
    }
    return false;
}

std::int64_t best_deterministic_available_damage(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &cards
){
    const Value *pokemon = active(state, actor);
    if (pokemon == nullptr || !array_field(*pokemon, "status_conditions").empty()) {
        return 0;
    }
    const Value *definition = card(cards, string_field(*pokemon, "card_id"));
    const auto &attacks = definition == nullptr
        ? Value::Array{} : array_field(*definition, "attacks");
    std::int64_t best = 0;
    for (std::size_t index = 0; index < attacks.size(); ++index) {
        if (
            missing_energy(cards, *pokemon, array_field(attacks[index], "cost")) <= 0
            && !commands_require_belief_sampling(
                field(attacks[index], "compiled_effects") == nullptr
                    ? Value::make_array() : *field(attacks[index], "compiled_effects"))
        ) {
            best = std::max(best, estimated_attack_damage(
                position, state, actor, index, cards));
        }
    }
    return best;
}

bool has_public_tatsugiri_acceleration_target(
    const Value &state,
    std::int32_t actor,
    const Value &cards
){
    for (const Value &pokemon : array_field(player(state, actor), "bench")) {
        if (
            pokemon.is_object()
            && is_basic_pokemon(cards, string_field(pokemon, "card_id"))
            && best_missing(cards, &pokemon) > 0
        ) return true;
    }
    return false;
}

double energy_plan_target_bonus(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &pokemon,
    const std::string &slot,
    const std::string &energy_card_id,
    const std::string &key,
    const Value &cards
){
    const Value *definition = card(cards, string_field(pokemon, "card_id"));
    if (definition == nullptr) return -std::numeric_limits<double>::infinity();
    const std::string pokemon_id = string_field(pokemon, "card_id");
    const DeckProfile deck = profile(cards, key);
    double bonus = 0.0;
    if (deck.contains("core", pokemon_id)) bonus += 95.0;
    if (
        deck.contains("evolution", pokemon_id)
        || !array_field(pokemon, "evolution_stack_ids").empty()
    ) bonus += 45.0;

    const std::int64_t damage_ceiling = best_pokemon_damage_for_state(
        position, state, actor, pokemon, slot, cards);
    if (deck.contains("engine", pokemon_id) && !deck.contains("core", pokemon_id)) {
        bonus += 22.0;
        const auto attached_cards = array_field(pokemon, "energy_card_ids").size();
        if (attached_cards > 0) {
            bonus -= 55.0 * static_cast<double>(attached_cards);
        }
        if (damage_ceiling < deck.high_impact_damage_floor()) bonus -= 25.0;
    }
    if (slot != "active" && deck.contains("bench", pokemon_id)) bonus += 34.0;
    if (has_subtype(*definition, "ex")) bonus += 45.0;
    bonus += std::min(120.0, static_cast<double>(damage_ceiling) * 0.35);

    const std::int64_t missing = best_missing(cards, &pokemon);
    const std::int64_t high_before = high_impact_missing_energy(
        position, state, actor, pokemon, slot, {}, cards);
    const std::int64_t high_after = !energy_card_id.empty()
        && is_energy(cards, energy_card_id)
        ? high_impact_missing_energy(
            position, state, actor, pokemon, slot, energy_card_id, cards)
        : high_before;
    const std::int64_t high_progress = std::max<std::int64_t>(
        0, high_before - high_after);
    if (damage_ceiling >= deck.high_impact_damage_floor() && high_progress > 0) {
        bonus += static_cast<double>(high_progress) * 110.0;
        if (high_after == 0) {
            bonus += 170.0 + static_cast<double>(damage_ceiling) * 0.25;
        } else if (high_after == 1) {
            bonus += 125.0;
        }
        if (slot != "active" && deck.contains("core", pokemon_id)) bonus += 75.0;
    }
    if (missing == 0) bonus += 35.0;
    else if (missing == 1) bonus += 25.0;
    else if (missing <= 3 && damage_ceiling >= deck.high_impact_damage_floor()) {
        bonus += 30.0;
    }
    const std::int64_t max_hp = integer_field(*definition, "hp");
    if (
        slot == "active"
        && static_cast<double>(position.pokemon_current_hp(pokemon))
            <= std::max(40.0, static_cast<double>(max_hp) * 0.35)
        && missing > 0
    ) bonus -= 65.0;
    if (!energy_card_id.empty()
        && energy_matches_profile(cards, energy_card_id, key)) bonus += 18.0;

    if (
        key == "water" && pokemon_id == "sv2-grex"
        && energy_type_count(cards, &pokemon, "Water") >= 2
        && missing == 0 && high_progress == 0
    ) bonus -= 480.0;

    if (
        key == "water" && pokemon_id == "sv2-keldeo"
        && bench_count(player(state, actor)) >= 3
    ) {
        const auto &attacks = array_field(*definition, "attacks");
        if (attacks.size() > 1) {
            const auto &cost = array_field(attacks[1], "cost");
            const std::int64_t before = missing_energy(cards, pokemon, cost);
            const Value probe = pokemon_with_extra_energy(pokemon, energy_card_id);
            const std::int64_t after = missing_energy(cards, probe, cost);
            if (before == 1 && after == 0) bonus += 190.0;
        }
    }

    if (
        key == "water" && slot == "active" && pokemon_id == "sv2-tatsu"
        && bench_count(player(state, actor)) > 0
    ) {
        const auto &attacks = array_field(*definition, "attacks");
        if (!attacks.empty()) {
            const auto &cost = array_field(attacks.front(), "cost");
            const std::int64_t before = missing_energy(cards, pokemon, cost);
            const Value probe = pokemon_with_extra_energy(pokemon, energy_card_id);
            const std::int64_t after = missing_energy(cards, probe, cost);
            if (
                before == 1 && after == 0
                && has_public_tatsugiri_acceleration_target(state, actor, cards)
            ) bonus += 280.0;
        }
    }
    return bonus;
}

bool has_better_bench_energy_plan(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const std::string &energy_card_id,
    const std::string &key,
    const Value &cards
){
    const Value &owner = player(state, actor);
    const Value *active_pokemon = active(state, actor);
    if (active_pokemon == nullptr) return false;
    const DeckProfile deck = profile(cards, key);
    const Value *active_definition = card(
        cards, string_field(*active_pokemon, "card_id"));
    const std::int64_t active_max_hp = active_definition == nullptr
        ? 0 : integer_field(*active_definition, "hp");
    const std::int64_t active_damage = best_pokemon_damage_for_state(
        position, state, actor, *active_pokemon, "active", cards);
    if (
        deck.contains("core", string_field(*active_pokemon, "card_id"))
        && static_cast<double>(position.pokemon_current_hp(*active_pokemon))
            > std::max(50.0, static_cast<double>(active_max_hp) * 0.35)
        && active_damage >= deck.high_impact_damage_floor()
    ) return false;

    const std::int64_t active_before = best_missing(cards, active_pokemon);
    const std::int64_t active_after = best_missing_with_extra(
        cards, active_pokemon, energy_card_id);
    const std::int64_t active_power_before = high_impact_missing_energy(
        position, state, actor, *active_pokemon, "active", {}, cards);
    const std::int64_t active_power_after = high_impact_missing_energy(
        position, state, actor, *active_pokemon,
        "active", energy_card_id, cards);
    const bool active_progresses = active_after < active_before
        || (
            active_damage >= deck.high_impact_damage_floor()
            && active_power_after < active_power_before
        );

    const auto &bench = array_field(owner, "bench");
    for (std::size_t index = 0; index < bench.size(); ++index) {
        if (!bench[index].is_object()) continue;
        const Value &pokemon = bench[index];
        const std::string slot = "bench_" + std::to_string(index);
        const std::int64_t before = best_missing(cards, &pokemon);
        const std::int64_t after = best_missing_with_extra(
            cards, &pokemon, energy_card_id);
        const std::int64_t damage = best_pokemon_damage_for_state(
            position, state, actor, pokemon, slot, cards);
        const std::int64_t power_before = high_impact_missing_energy(
            position, state, actor, pokemon, slot, {}, cards);
        const std::int64_t power_after = high_impact_missing_energy(
            position, state, actor, pokemon, slot, energy_card_id, cards);
        const bool progresses = after < before
            || (
                damage >= deck.high_impact_damage_floor()
                && power_after < power_before
            );
        if (
            progresses && deck.contains("core", string_field(pokemon, "card_id"))
            && (!active_progresses || active_damage < damage)
        ) return true;
        if (
            progresses && before > 0 && after == 0
            && damage >= std::max<std::int64_t>(
                deck.high_impact_damage_floor(), active_damage + 40)
        ) return true;
    }
    return false;
}

} // namespace ptcg::ai::traditional_trusted_detail
