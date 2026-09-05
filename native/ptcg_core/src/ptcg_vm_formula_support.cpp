#include "ptcg_rules.hpp"
#include "ptcg_rules_internal.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <cmath>
#include <iterator>
#include <limits>
#include <stdexcept>
#include <string_view>
#include <unordered_set>


namespace ptcg::ai::rules_detail {

using Array = Value::Array;
using Object = Value::Object;

bool condition_applies(
    const Value &cards,
    const Value &state,
    std::int32_t actor,
    const std::string &condition
) {
    const Value &self = player(state, actor);
    const Value &opponent = player(state, 1 - actor);
    const Value *opponent_active = pokemon(opponent, "active");
    if (condition == "own_bench_damaged") {
        const Array &bench = required(self, "bench").as_array();
        return std::any_of(
            bench.begin(),
            bench.end(),
            [](const Value &entry) {
                return entry.is_object()
                    && get_integer(entry, "damage_counters") > 0;
            }
        );
    }
    if (condition == "opponent_active_damaged") {
        return opponent_active != nullptr
            && get_integer(*opponent_active, "damage_counters") > 0;
    }
    if (condition == "opponent_active_evolved") {
        return opponent_active != nullptr
            && !card_has_subtype(
                cards,
                card_id(*opponent_active),
                "Basic"
            );
    }
    if (condition == "own_hand_empty") {
        return required(self, "hand").as_array().empty();
    }
    if (condition == "field_energy_ge_5") {
        std::int64_t total = 0;
        for (const Value *entry : all_pokemon(self)) {
            total += energy_units(cards, entry);
        }
        return total >= 5;
    }
    if (
        condition == "ko_by_attack_last_turn"
        || condition == "ko_by_attack_damage_last_turn"
    ) {
        const Value *fact_book = state.find("turn_fact_book");
        const Value *previous = fact_book != nullptr
            && fact_book->is_object()
            ? fact_book->find("previous_turn")
            : nullptr;
        const Value *knockouts = previous != nullptr
            && previous->is_object()
            ? previous->find("knockouts")
            : nullptr;
        if (
            knockouts != nullptr
            && knockouts->is_array()
            && !knockouts->as_array().empty()
        ) {
            return std::any_of(
                knockouts->as_array().begin(),
                knockouts->as_array().end(),
                [actor](const Value &fact) {
                    return integer_arg(fact, "defeated_player", -1) == actor
                        && string_arg(fact, "source_kind")
                            == "attack_damage";
                }
            );
        }
        const Value *flag = self.find("was_ko_by_attack");
        return flag != nullptr && flag->as_bool();
    }
    if (condition == "ko_last_opponent_turn") {
        const Value *fact_book = state.find("turn_fact_book");
        const Value *previous = fact_book != nullptr
            && fact_book->is_object()
            ? fact_book->find("previous_turn")
            : nullptr;
        const Value *knockouts = previous != nullptr
            && previous->is_object()
            ? previous->find("knockouts")
            : nullptr;
        if (
            knockouts != nullptr
            && knockouts->is_array()
            && !knockouts->as_array().empty()
        ) {
            return std::any_of(
                knockouts->as_array().begin(),
                knockouts->as_array().end(),
                [actor](const Value &fact) {
                    return integer_arg(fact, "defeated_player", -1) == actor
                        && integer_arg(fact, "source_player", -1) >= 0;
                }
            );
        }
        const Value *flag = self.find("was_ko_by_attack");
        return flag != nullptr && flag->as_bool();
    }
    return false;
}

std::int64_t evaluate_formula_ast(
    const Value &formula,
    const Value &cards,
    const Value &state,
    std::int32_t actor
) {
    if (!formula.is_object()) {
        return formula.as_integer();
    }
    const std::string op = string_arg(formula, "op");
    if (op == "const") {
        return integer_arg(formula, "value");
    }
    if (op == "damage_counters") {
        const std::int32_t owner = string_arg(
            formula,
            "target",
            "self"
        ) == "opponent" ? 1 - actor : actor;
        const Value *target = pokemon(player(state, owner), "active");
        return target == nullptr
            ? 0
            : integer_arg(*target, "damage_counters");
    }
    if (op == "bench_count") {
        const std::int32_t owner = string_arg(
            formula,
            "player",
            "self"
        ) == "opponent" ? 1 - actor : actor;
        return bench_count(player(state, owner));
    }
    if (op == "hand_size") {
        const std::int32_t owner = string_arg(
            formula,
            "player",
            "self"
        ) == "opponent" ? 1 - actor : actor;
        return static_cast<std::int64_t>(
            required(player(state, owner), "hand").as_array().size()
        );
    }
    if (op == "discard_count") {
        const std::int32_t owner = string_arg(
            formula,
            "player",
            "self"
        ) == "opponent" ? 1 - actor : actor;
        const Value *filter = formula.find("filter");
        const std::string card_type = (
            filter != nullptr && filter->is_object()
        ) ? lower_ascii(string_arg(*filter, "card_type"))
          : std::string{};
        const std::string energy_type = (
            filter != nullptr && filter->is_object()
        ) ? string_arg(*filter, "energy_type")
          : std::string{};
        std::int64_t total = 0;
        for (
            const Value &entry
            : required(player(state, owner), "discard").as_array()
        ) {
            const Value *definition = card_definition(
                cards,
                entry.string_or()
            );
            if (definition == nullptr) {
                continue;
            }
            const std::string supertype = lower_ascii(
                string_arg(*definition, "supertype")
            );
            if (
                card_type == "pokemon"
                && supertype != "pokémon"
                && supertype != "pokemon"
            ) {
                continue;
            }
            if (card_type == "energy" && supertype != "energy") {
                continue;
            }
            if (
                !energy_type.empty()
                && !string_array_contains_ci(
                    definition->find("energy_types"),
                    energy_type
                )
            ) {
                continue;
            }
            ++total;
        }
        return total;
    }
    if (op == "energy_count") {
        const std::string scope = string_arg(
            formula,
            "scope",
            string_arg(formula, "target", "self")
        );
        const std::string filter = string_arg(
            formula,
            "energy_type",
            string_arg(formula, "filter", "any")
        );
        const Value &self = player(state, actor);
        const Value &opponent = player(state, 1 - actor);
        if (
            scope == "self"
            || scope == "self_active"
            || scope == "source"
        ) {
            return energy_units(cards, pokemon(self, "active"), filter);
        }
        if (scope == "opponent" || scope == "opponent_active") {
            return energy_units(
                cards,
                pokemon(opponent, "active"),
                filter
            );
        }
        const Value &owner = (
            scope == "all_opponent" || scope == "opponent_all"
        ) ? opponent : self;
        if (
            scope != "all_self"
            && scope != "self_all"
            && scope != "all_opponent"
            && scope != "opponent_all"
        ) {
            throw std::invalid_argument(
                "unsupported_formula_energy_scope:" + scope
            );
        }
        std::int64_t total = energy_units(
            cards,
            pokemon(owner, "active"),
            filter
        );
        const Array &bench = required(owner, "bench").as_array();
        for (const Value &entry : bench) {
            total += energy_units(
                cards,
                entry.is_object() ? &entry : nullptr,
                filter
            );
        }
        return total;
    }
    if (op == "evolved_count") {
        const std::int32_t owner = string_arg(
            formula,
            "player",
            "self"
        ) == "opponent" ? 1 - actor : actor;
        const Value &owner_state = player(state, owner);
        std::int64_t total = 0;
        const Value *active = pokemon(owner_state, "active");
        if (
            active != nullptr
            && !card_has_subtype(cards, card_id(*active), "Basic")
        ) {
            ++total;
        }
        const Array &bench = required(owner_state, "bench").as_array();
        for (const Value &entry : bench) {
            if (
                entry.is_object()
                && !card_has_subtype(cards, card_id(entry), "Basic")
            ) {
                ++total;
            }
        }
        return total;
    }
    if (const Value *constant = formula.find("const")) {
        return constant->as_integer();
    }
    if (op == "sub") {
        const Value *left = formula.find("lhs");
        if (left == nullptr) {
            left = formula.find("left");
        }
        const Value *right = formula.find("rhs");
        if (right == nullptr) {
            right = formula.find("right");
        }
        if (left == nullptr || right == nullptr) {
            throw std::invalid_argument(
                "formula_ast_binary_operands_missing"
            );
        }
        return evaluate_formula_ast(*left, cards, state, actor)
            - evaluate_formula_ast(*right, cards, state, actor);
    }
    if (op == "add") {
        std::int64_t result = 0;
        const Value *terms = formula.find("terms");
        if (terms != nullptr && terms->is_array()) {
            for (const Value &term : terms->as_array()) {
                result += evaluate_formula_ast(
                    term,
                    cards,
                    state,
                    actor
                );
            }
        }
        return result;
    }
    if (op == "mul" || op == "multiply") {
        const Value *terms = formula.find("terms");
        if (terms == nullptr) {
            terms = formula.find("factors");
        }
        std::int64_t result = 1;
        if (terms != nullptr && terms->is_array()) {
            for (const Value &term : terms->as_array()) {
                result *= evaluate_formula_ast(
                    term,
                    cards,
                    state,
                    actor
                );
            }
        }
        return result;
    }
    if (op == "if") {
        const bool applies = condition_applies(
            cards,
            state,
            actor,
            string_arg(formula, "condition")
        );
        const Value *branch = formula.find(applies ? "then" : "else");
        return branch == nullptr
            ? 0
            : evaluate_formula_ast(*branch, cards, state, actor);
    }
    throw std::invalid_argument("unsupported_formula_ast:" + op);
}

void append_modifier(
    Value &pokemon_value,
    const std::string &op,
    const Value &args
) {
    Value *modifiers = pokemon_value.find("modifiers");
    if (modifiers == nullptr || !modifiers->is_array()) {
        pokemon_value["modifiers"] = Value::make_array();
        modifiers = pokemon_value.find("modifiers");
    }
    Object descriptor;
    descriptor["native_op"] = Value(op);
    descriptor["args"] = args;
    modifiers->as_array().emplace_back(std::move(descriptor));
}

Value modifier_probe(
    const std::string &op,
    const Value &args,
    const Value *source,
    std::int32_t actor,
    const std::string &source_slot
) {
    if (
        op == "register_reactive_thorns"
        || op == "register_tool_exp_share"
    ) {
        return Value(Object{{"registered", Value(false)}});
    }
    static const std::map<std::string, std::string, std::less<>> kinds = {
        {"register_aura_damage_boost", "aura_damage_boost"},
        {"register_aura_damage_reduction", "aura_damage_reduction"},
        {"register_conditional_hp_boost", "conditional_hp_boost"},
        {"register_conditional_zero_retreat", "conditional_zero_retreat"},
        {"register_tool_modifier", "tool"},
    };
    const auto found = kinds.find(op);
    if (found == kinds.end()) {
        return Value::make_object();
    }
    if (source == nullptr) {
        return Value(Object{{"registered", Value(false)}});
    }
    Object result;
    result["registered"] = Value(true);
    result["modifier_kind"] = Value(found->second);
    result["player"] = Value(actor);
    result["slot"] = Value(source_slot);
    result["card_id"] = Value(card_id(*source));
    result["params"] = args;
    return Value(std::move(result));
}

std::int64_t bench_count(const Value &player_value) {
    const Array &bench = required(player_value, "bench").as_array();
    return static_cast<std::int64_t>(std::count_if(
        bench.begin(),
        bench.end(),
        [](const Value &entry) { return entry.is_object(); }
    ));
}

} // namespace ptcg::ai::rules_detail
