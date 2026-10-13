#include "ptcg_card_runtime.hpp"
#include "ptcg_game_internal.hpp"
#include "ptcg_rules_internal.hpp"
#include <algorithm>

namespace ptcg::ai::card_runtime {
using namespace game_detail;

const Value *rule(const Value &cards, const std::string &id, const std::string &effect) {
    const Value *definition = cards.find(id);
    if (!definition) return nullptr;
    auto find = [&](const Value *commands) -> const Value * {
        if (!commands || !commands->is_array()) return nullptr;
        for (const auto &command : commands->as_array()) {
            const auto *args = command.find("args");
            if (string_arg(command, "op") == "register_rule" && args && string_arg(*args, "effect") == effect) return args;
        }
        return nullptr;
    };
    if (const auto *found = find(definition->find("compiled_trainer_effects"))) return found;
    const auto *abilities = definition->find("abilities");
    if (abilities && abilities->is_array()) {
        for (const auto &ability : abilities->as_array()) {
            if (string_arg(ability, "trigger") == "passive")
                if (const auto *found = find(ability.find("compiled_effects"))) return found;
        }
    }
    return nullptr;
}

Value attacks(const Value &cards, const Value &pokemon_value) {
    // AI evaluation accepts both the card map and the complete rules catalog.
    // Preserve the same body/tool attack indices for either representation.
    const Value *wrapped_cards = cards.find("cards");
    const Value &definitions = wrapped_cards && wrapped_cards->is_object() ? *wrapped_cards : cards;
    Value::Array result;
    for (const char *key : {"card_id", "attached_tool_id"}) {
        const Value *definition = definitions.find(string_arg(pokemon_value, key));
        const Value *rows = definition ? definition->find("attacks") : nullptr;
        if (rows && rows->is_array()) result.insert(result.end(), rows->as_array().begin(), rows->as_array().end());
    }
    return Value(std::move(result));
}

bool board_rule(const Value &cards, const Value &state, int owner, const std::string &effect) {
    std::vector<std::pair<std::string, const Value *>> entries;
    append_pokemon_rows(player(state, owner), entries);
    for (const auto &[slot, pokemon_value] : entries) {
        const auto *args = rule(cards, string_arg(*pokemon_value, "card_id"), effect);
        if (!args || (bool_arg(*args, "requires_active") && slot != "active")) continue;
        const auto name = string_arg(*args, "filter_name");
        if (!name.empty()) {
            bool found = false;
            for (const auto &[ignored, ally] : entries) {
                const auto *definition = cards.find(string_arg(*ally, "card_id"));
                found = found || (definition && string_arg(*definition, "name") == name);
            }
            if (!found) continue;
        }
        return true;
    }
    return false;
}

std::int64_t bench_limit(const Value &cards, const Value &state, int owner) {
    const auto *active = pokemon(player(state, 1 - owner), "active");
    const auto *limit = active ? rule(cards, string_arg(*active, "card_id"), "opponent_bench_limit") : nullptr;
    return limit ? integer_arg(*limit, "amount", 5) : 5;
}

bool protects_effect(const Value &cards, const Value &state, int owner, const std::string &slot, bool counters_only) {
    const auto *target = pokemon(player(state, owner), slot);
    if (!target) return false;
    if (rule(cards, string_arg(*target, "card_id"), "protect_self_from_effects")) return true;
    if (!required(*target, "energy_card_ids").as_array().empty()
        && board_rule(cards, state, owner, "protect_energized_from_effects")) return true;
    if (counters_only && slot != "active" && board_rule(cards, state, owner, "protect_bench_counters_from_basic")) {
        const auto *attacker = pokemon(player(state, 1 - owner), "active");
        const auto *definition = attacker ? cards.find(string_arg(*attacker, "card_id")) : nullptr;
        return attacker && basic_in_play(cards,*attacker);
    }
    return false;
}

bool tera_protection(const Value &cards, const Value &pokemon_value, const std::string &slot) {
    const auto *definition = cards.find(string_arg(pokemon_value, "card_id"));
    return slot != "active" && definition && card_has_subtype(*definition, "Tera");
}

bool basic_in_play(const Value &cards,const Value &target) {
    const auto id=string_arg(target,"card_id");
    const auto *definition=cards.find(id);
    return definition && (is_basic_pokemon(*definition) || rule(cards,id,"setup_pokemon"));
}

bool knocked_out(const Value &cards, const Value &target) {
    return string_arg(target, "pending_ko_source_kind") == "direct_knockout"
        || (pokemon_hp(cards, target) > 0 && integer_arg(target, "damage_counters") * 10 >= pokemon_hp(cards, target));
}

std::int64_t attachment_units(const Value &cards,const Value &target,std::size_t index) {
    const auto &energy=required(target,"energy_card_ids").as_array();
    if (index>=energy.size()) return 0;
    Value probe=target.deep_clone();
    required(probe,"energy_card_ids").as_array()=Array{energy[index]};
    return static_cast<std::int64_t>(energy_units(cards,probe).size());
}

void on_hand_attachment(const Value &cards, VmExecutionResult &result, int owner,
    const std::string &attached_slot, const std::string &energy_id) {
    std::string slot=attached_slot;
    if (energy_switches_with_active_on_attach(cards,energy_id,slot)) {
        rules_detail::switch_active_with_event(result,player(result.state,owner),owner,owner,slot,"energy_switch_on_attach");
        slot="active";
    }
    Value *target = pokemon(player(result.state, owner), slot);
    if (!target) return;
    const Value *energy = cards.find(energy_id);
    const auto *effects = energy ? energy->find("energy_effects") : nullptr;
    if (effects && effects->is_array()) {
        for (const auto &entry : effects->as_array()) {
            const auto *condition = entry.find("condition");
            const auto *effect = entry.find("effect");
            if (string_arg(entry,"hook") != "ON_ATTACH" || !condition || !effect
                || string_arg(*condition,"from_zone") != "hand" || string_arg(*effect,"op") != "heal_damage") continue;
            const auto amount = std::min(integer_arg(*target,"damage_counters") * 10, integer_arg(*effect,"amount"));
            (*target)["damage_counters"] = Value(integer_arg(*target,"damage_counters") - amount / 10);
            if (amount > 0) {
                player(result.state,owner)["healed_this_turn"] = Value(true);
                rules_detail::append_healed_event(result, owner, owner, slot, amount);
            }
        }
    }
    const bool optional_switch=slot.rfind("bench_",0)==0 && rule(cards,string_arg(*target,"card_id"),"switch_on_hand_energy");
    const bool counters=board_rule(cards,result.state,1-owner,"opponent_hand_energy_counters");
    // The active player's attachment triggers resolve before the opponent's.
    if (counters && !optional_switch) {
        add_damage(*target,20);
        if (knocked_out(cards,*target)) (*target)["pending_ko_source_kind"] = Value("damage_counters");
        rules_detail::append_damage_feedback_event(result,"damage_counters_placed",1-owner,owner,slot,20);
    }
    if (optional_switch) {
        auto *queue = result.context.find("hand_energy_switches");
        if (!queue) { result.context["hand_energy_switches"] = Value::make_array(); queue=result.context.find("hand_energy_switches"); }
        queue->as_array().push_back(Value(Object{{"player",Value(owner)},{"bench_idx",Value(static_cast<std::int64_t>(std::stoll(slot.substr(6))))},{"counters",Value(counters?2:0)}}));
    }
}

Value take_hand_attachment_trigger(Value &context) {
    auto *queue = context.find("hand_energy_switches");
    if (!queue || !queue->is_array() || queue->as_array().empty()) return Value::make_object();
    Value args=queue->as_array().front();queue->as_array().erase(queue->as_array().begin());
    const auto counters=integer_arg(args,"counters");args.erase("counters");
    const int owner=static_cast<int>(integer_arg(args,"player"));
    Array accepted{Value(Object{{"op",Value("trigger_switch_with_active")},{"args",args},{"branches",Value::make_object()}})},declined;
    if (counters) {
        auto counter=[&](const std::string &slot){return Value(Object{{"op",Value("trigger_place_damage_counters")},
            {"args",Value(Object{{"player",Value(owner)},{"from_player",Value(1-owner)},{"slot",Value(slot)},{"count",Value(counters)}})},
            {"branches",Value::make_object()}});};
        accepted.push_back(counter("active"));declined.push_back(counter("bench_"+std::to_string(integer_arg(args,"bench_idx"))));
    }
    return Value(Object{{"op",Value("optional_effects")},{"args",Value::make_object()},
        {"branches",Value(Object{{"on_success",Value(std::move(accepted))},{"on_failure",Value(std::move(declined))}})}});
}

std::int64_t temporary_rule(const Value &pokemon_value, const std::string &effect,
    std::int64_t turn, const std::string &attack_name) {
    const Value *modifiers = pokemon_value.find("modifiers");
    if (!modifiers || !modifiers->is_array()) return 0;
    std::int64_t result = 0;
    for (const auto &modifier : modifiers->as_array()) {
        const auto *op = modifier.find("operation");
        const auto *condition = modifier.find("condition");
        if (!op || !condition || string_arg(*op, "kind") != "card_rule" || string_arg(*op, "effect") != effect) continue;
        if (integer_arg(*condition, "starts_on_turn") > turn || integer_arg(*condition, "expires_after_turn", turn) < turn) continue;
        const auto required_name = string_arg(*condition, "attack_name");
        if (!required_name.empty() && !attack_name.empty() && required_name != attack_name) continue;
        result += integer_arg(*op, "amount", 1);
    }
    return result;
}

void add_temporary_rule(Value &target, const std::string &effect, std::int64_t amount,
    int actor, const Value &source, const std::string &source_slot,
    std::int64_t expires, std::int64_t starts, const std::string &attack_name) {
    Value::Object condition{{"expires_after_turn", Value(expires)}};
    if (starts) condition["starts_on_turn"] = Value(starts);
    if (!attack_name.empty()) condition["attack_name"] = Value(attack_name);
    Value descriptor(Value::Object{
        {"hook",Value("CARD_RULE")},{"layer",Value("permission")},{"priority",Value(0)},
        {"controller",Value(actor)},{"scope",Value("self")},{"duration",Value("until_end_of_turn")},
        {"stacking",Value("replace_same_source")},{"conflict_policy",Value("commutative")},
        {"source_ref",Value(Value::Object{{"kind",Value("pokemon")},{"player",Value(actor)},
            {"slot",Value(source_slot)},{"card_id",Value(string_arg(source,"card_id"))}})},
        {"condition",Value(std::move(condition))},
        {"operation",Value(Value::Object{{"kind",Value("card_rule")},{"effect",Value(effect)},{"amount",Value(amount)}})}
    });
    if (!target.find("modifiers")) target["modifiers"]=Value::make_array();
    auto &modifiers = required(target, "modifiers").as_array();
    // Reapplying the same temporary rule refreshes it instead of stacking.
    modifiers.erase(std::remove_if(modifiers.begin(),modifiers.end(),[&](const Value &m) {
        const auto *op=m.find("operation");
        return op && string_arg(*op,"kind")=="card_rule" && string_arg(*op,"effect")==effect;
    }),modifiers.end());
    modifiers.push_back(std::move(descriptor));
}
}
