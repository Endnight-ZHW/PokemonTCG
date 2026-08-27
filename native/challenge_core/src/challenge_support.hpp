#pragma once

#include "ptcg_rules_session.hpp"
#include "ptcg_traditional_policy.hpp"

#include <charconv>
#include <cstdint>
#include <functional>
#include <string>
#include <utility>

namespace ptcg::ai::challenge {

std::string json_scalar_text(const Value &value);
std::string sha256_text(const std::string &value);
std::uint32_t string_hash32(const std::string &value) noexcept;

inline std::string value_string_field(
    const ptcg::ai::Value &value,
    const char *key,
    std::string fallback = {}
) {
    const ptcg::ai::Value *entry = value.find(key);
    return entry == nullptr ? std::move(fallback)
                            : entry->string_or(std::move(fallback));
}

inline std::string stable_value_signature(const ptcg::ai::Value &value) {
    using Type = ptcg::ai::Value::Type;
    switch (value.type()) {
        case Type::object: {
            std::string result = "{";
            bool first = true;
            for (const auto &[key, nested] : value.as_object()) {
                if (!first) result += ',';
                first = false;
                result += key + "=" + stable_value_signature(nested);
            }
            return result + "}";
        }
        case Type::array: {
            std::string result = "[";
            bool first = true;
            for (const ptcg::ai::Value &nested : value.as_array()) {
                if (!first) result += ',';
                first = false;
                result += stable_value_signature(nested);
            }
            return result + "]";
        }
        default:
            return json_scalar_text(value);
    }
}

inline std::string information_value_signature(const ptcg::ai::Value &value) {
    using Type = ptcg::ai::Value::Type;
    if (value.type() == Type::object) {
        std::string result = "{";
        bool first = true;
        for (const auto &[key, nested] : value.as_object()) {
            if (!first) result += ',';
            first = false;
            result += json_scalar_text(Value(key)) + ":"
                + information_value_signature(nested);
        }
        return result + "}";
    }
    if (value.type() == Type::array) {
        std::string result = "[";
        bool first = true;
        for (const ptcg::ai::Value &nested : value.as_array()) {
            if (!first) result += ',';
            first = false;
            result += information_value_signature(nested);
        }
        return result + "]";
    }
    return json_scalar_text(value);
}

inline ptcg::ai::Value normalized_fingerprint_pokemon(const ptcg::ai::Value &source) {
    if (!source.is_object()) return ptcg::ai::Value();
    using ptcg::ai::Value;
    const auto copy_or = [&source](const char *key, Value fallback) {
        const Value *value = source.find(key);
        return value == nullptr ? std::move(fallback) : *value;
    };
    Value result(Value::Object{
        {"card_id", copy_or("card_id", Value(""))},
        {"damage_counters", copy_or("damage_counters", Value(0))},
        {"energy_card_ids", copy_or("energy_card_ids", Value::make_array())},
        {"attached_tool_id", copy_or("attached_tool_id", Value(""))},
        {"status_conditions", copy_or("status_conditions", Value::make_array())},
        {"evolution_stack_ids", copy_or("evolution_stack_ids", Value::make_array())},
        {"can_evolve_this_turn", copy_or("can_evolve_this_turn", Value(true))},
        {"placed_this_turn", copy_or("placed_this_turn", Value(true))},
        {"used_abilities", copy_or("used_abilities", Value::make_array())},
        {"healed_this_turn", copy_or("healed_this_turn", Value(false))},
        {"paralyzed_since_turn", copy_or("paralyzed_since_turn", Value(0))},
    });
    const Value *modifiers = source.find("modifiers");
    if (modifiers != nullptr && modifiers->is_array()
        && !modifiers->as_array().empty()) result["modifiers"] = *modifiers;
    return result;
}

inline ptcg::ai::Value normalized_fingerprint_player(const ptcg::ai::Value &source) {
    using ptcg::ai::Value;
    if (!source.is_object()) return Value::make_object();
    const auto copy_or = [&source](const char *key, Value fallback) {
        const Value *value = source.find(key);
        return value == nullptr ? std::move(fallback) : *value;
    };
    Value bench = copy_or("bench", Value::make_array());
    if (bench.is_array()) {
        for (Value &pokemon : bench.as_array()) {
            pokemon = normalized_fingerprint_pokemon(pokemon);
        }
        while (bench.as_array().size() < 5) bench.as_array().emplace_back();
        if (bench.as_array().size() > 5) bench.as_array().resize(5);
    }
    Value result(Value::Object{
        {"name", copy_or("name", Value("玩家"))},
        {"deck", copy_or("deck", Value::make_array())},
        {"hand", copy_or("hand", Value::make_array())},
        {"discard", copy_or("discard", Value::make_array())},
        {"prizes", copy_or("prizes", Value::make_array())},
        {"active", normalized_fingerprint_pokemon(copy_or("active", Value()))},
        {"bench", std::move(bench)},
        {"supporter_played_this_turn", copy_or(
            "supporter_played_this_turn", Value(false))},
        {"energy_attached_this_turn", copy_or(
            "energy_attached_this_turn", Value(false))},
        {"retreated_this_turn", copy_or("retreated_this_turn", Value(false))},
        {"stadium_played_this_turn", copy_or(
            "stadium_played_this_turn", Value(false))},
        {"stadium_used_this_turn", copy_or(
            "stadium_used_this_turn", Value(false))},
        {"healed_this_turn", copy_or("healed_this_turn", Value(false))},
        {"vstar_power_used", copy_or("vstar_power_used", Value(false))},
        {"was_ko_by_attack", copy_or("was_ko_by_attack", Value(false))},
    });
    const Value *locks = source.find("attack_locked_names");
    if (locks != nullptr && locks->is_object()
        && !locks->as_object().empty()) result["attack_locked_names"] = *locks;
    return result;
}

inline std::string traditional_state_fingerprint(const ptcg::ai::RulesSession &position) {
    const ptcg::ai::Value &state = position.search_state();
    ptcg::ai::Value players = state.find("players") == nullptr
        ? ptcg::ai::Value::make_array() : *state.find("players");
    if (players.is_array()) {
        for (ptcg::ai::Value &player : players.as_array()) {
            player = normalized_fingerprint_player(player);
        }
    }
    ptcg::ai::Value rules_options = state.find("rules_options") != nullptr
        && state.find("rules_options")->is_object()
        ? *state.find("rules_options") : ptcg::ai::Value::make_object();
    const ptcg::ai::Value *matchups = state.find("apply_type_matchups");
    rules_options["apply_type_matchups"] = ptcg::ai::Value(
        matchups != nullptr && matchups->as_bool(false));
    ptcg::ai::Value payload = ptcg::ai::Value::make_object();
    payload["players"] = std::move(players);
    constexpr const char *keys[] = {
        "active_player_idx",
        "phase",
        "turn_number",
        "first_player_idx",
        "stadium_card_id",
        "stadium_owner_idx",
        "winner",
        "result_status",
        "result_reason",
        "result_conditions",
        "public_deck_keys",
        "apply_type_matchups",
        "rules_profile_id",
        "mulligan_count",
        "extra_draws",
        "setup_ready",
        "setup_stage",
        "setup_actor_idx",
        "opening_coin_winner_idx",
        "mulligan_bonus_max",
        "setup_bonus_card_ids",
        "pending_promotions",
        "turn_fact_book",
    };
    for (const char *key : keys) {
        const ptcg::ai::Value *value = state.find(key);
        payload[key] = value == nullptr ? ptcg::ai::Value() : *value;
    }
    payload["rules_options"] = std::move(rules_options);
    payload["resolution_stack"] = ptcg::ai::Value::make_object();
    return sha256_text(stable_value_signature(payload));
}

inline std::int64_t value_integer_field(
    const ptcg::ai::Value &value,
    const char *key,
    std::int64_t fallback = 0
) {
    const ptcg::ai::Value *entry = value.find(key);
    return entry == nullptr ? fallback : entry->as_integer(fallback);
}

inline const ptcg::ai::Value &value_player(
    const ptcg::ai::Value &state,
    std::int32_t actor
) {
    static const ptcg::ai::Value empty = ptcg::ai::Value::make_object();
    const ptcg::ai::Value *players = state.find("players");
    return players != nullptr && players->is_array() && actor >= 0
        && static_cast<std::size_t>(actor) < players->as_array().size()
        ? players->as_array()[static_cast<std::size_t>(actor)] : empty;
}

inline const ptcg::ai::Value *value_pokemon_at(
    const ptcg::ai::Value &state,
    std::int32_t actor,
    const std::string &slot
) {
    const ptcg::ai::Value &owner = value_player(state, actor);
    if (slot == "active") {
        const ptcg::ai::Value *pokemon = owner.find("active");
        return pokemon != nullptr && pokemon->is_object() ? pokemon : nullptr;
    }
    if (slot.rfind("bench_", 0) != 0) return nullptr;
    std::size_t index = 0;
    const std::string suffix = slot.substr(6);
    const auto parsed = std::from_chars(
        suffix.data(), suffix.data() + suffix.size(), index);
    const ptcg::ai::Value *bench = owner.find("bench");
    if (parsed.ec != std::errc{} || parsed.ptr != suffix.data() + suffix.size()
        || bench == nullptr || !bench->is_array()
        || index >= bench->as_array().size()) return nullptr;
    const ptcg::ai::Value &pokemon = bench->as_array()[index];
    return pokemon.is_object() ? &pokemon : nullptr;
}

inline const ptcg::ai::Value &value_catalog_cards(
    const ptcg::ai::Value &catalog
) {
    const ptcg::ai::Value *cards = catalog.find("cards");
    return cards != nullptr && cards->is_object() ? *cards : catalog;
}

inline const ptcg::ai::Value *value_card(
    const ptcg::ai::Value &catalog,
    const std::string &card_id
) {
    const ptcg::ai::Value &cards = value_catalog_cards(catalog);
    const ptcg::ai::Value *definition = cards.find(card_id);
    return definition != nullptr && definition->is_object() ? definition : nullptr;
}

inline std::string value_action_signature(const ptcg::ai::Value &action) {
    const ptcg::ai::TraditionalStableSignature stable = [](
        const ptcg::ai::Value &value
    ) {
        return stable_value_signature(value);
    };
    const std::function<std::string(const std::string &)> sha = [](
        const std::string &value
    ) {
        return sha256_text(value);
    };
    return ptcg::ai::traditional_action_signature(action, stable, sha);
}

inline ptcg::ai::Value stable_entity_ref(const ptcg::ai::Value *reference) {
    using ptcg::ai::Value;
    if (reference == nullptr || !reference->is_object()) return Value::make_object();
    Value result(Value::Object{
        {"kind", Value(value_string_field(*reference, "kind"))},
        {"player", Value(value_integer_field(*reference, "player", -1))},
    });
    for (const char *key : {"zone", "slot", "attachment_type", "card_id"}) {
        const std::string value = value_string_field(*reference, key);
        if (!value.empty()) result[key] = Value(value);
    }
    return result;
}

inline std::string semantic_intent(const std::string &kind) {
    if (kind == "PLAY_BASIC") return "develop_board";
    if (kind == "EVOLVE") return "evolve";
    if (kind == "ATTACH_ENERGY") return "attach_energy";
    if (kind == "PLAY_TRAINER") return "play_trainer";
    if (kind == "USE_ABILITY") return "use_ability";
    if (kind == "USE_STADIUM") return "use_stadium";
    if (kind == "RETREAT") return "retreat";
    if (kind == "DECLARE_ATTACK") return "attack";
    if (kind == "PROMOTE") return "promote";
    if (kind == "SETUP_DONE") return "finish_setup";
    if (kind == "END_TURN") return "end_turn";
    return "action";
}

inline ptcg::ai::Value action_intent(
    const ptcg::ai::Value &action,
    const ptcg::ai::Value *precondition = nullptr
) {
    using ptcg::ai::Value;
    const std::string kind = value_string_field(action, "kind");
    const Value *payload = action.find("payload");
    Value result(Value::Object{
        {"kind", Value(kind)},
        {"intent", Value(semantic_intent(kind))},
        {"actor", Value(value_integer_field(action, "actor", -1))},
        {"source", stable_entity_ref(action.find("source"))},
        {"target", stable_entity_ref(action.find("target"))},
        {"payload", payload != nullptr && payload->is_object()
            ? *payload : Value::make_object()},
    });
    Value stable(Value::Object{
        {"kind", result["kind"]},
        {"actor", result["actor"]},
        {"source", result["source"]},
        {"target", result["target"]},
        {"payload", result["payload"]},
    });
    result["signature"] = Value("intent:" + sha256_text(
        stable_value_signature(stable)));
    if (precondition != nullptr && precondition->is_object()) {
        for (const char *key : {
            "expected_public_fingerprint", "expected_actor", "expected_phase",
        }) {
            const Value *value = precondition->find(key);
            if (value != nullptr) result[key] = *value;
        }
    }
    return result;
}

inline std::string traditional_decision_semantic_hash(
    const ptcg::ai::Value &selected,
    const ptcg::ai::Value &planner,
    const ptcg::ai::Value &turn_plan,
    ptcg::ai::Value *debug_payload = nullptr
) {
    using ptcg::ai::Value;
    const auto copy_or = [&planner](const char *key, Value fallback) {
        const Value *value = planner.find(key);
        return value == nullptr ? std::move(fallback) : *value;
    };
    Value root_signatures = copy_or("root_signatures_attempted", Value::make_array());
    const Value root_counts = copy_or("root_sample_counts", Value::make_object());
    if (root_signatures.is_array() && root_signatures.as_array().empty()
        && root_counts.is_object() && !root_counts.as_object().empty()) {
        for (const auto &[signature, count] : root_counts.as_object()) {
            (void)count;
            root_signatures.as_array().emplace_back(signature);
        }
    }
    Value preconditions = copy_or("cache_preconditions", Value::make_array());
    if (preconditions.is_array() && preconditions.as_array().empty()
        && turn_plan.is_array()) {
        for (const Value &step : turn_plan.as_array()) {
            Value precondition = Value::make_object();
            for (const char *key : {
                "expected_public_fingerprint", "expected_actor", "expected_phase",
            }) {
                const Value *value = step.find(key);
                if (value != nullptr) precondition[key] = *value;
            }
            preconditions.as_array().push_back(std::move(precondition));
        }
    }
    Value payload(Value::Object{
        {"contract", Value("traditional_ai_decision_semantics_v1")},
        {"engine_id", copy_or("engine_id", Value("turn_beam_v2"))},
        {"selected_action", selected},
        {"selected_action_signature", Value(value_action_signature(selected))},
        {"turn_plan", turn_plan},
        {"plan_steps", turn_plan},
        {"root_signatures_attempted", root_signatures},
        {"root_order", root_signatures},
        {"root_sample_counts", root_counts},
        {"belief_seed_hash", copy_or("belief_seed_hash", Value(""))},
        {"cache_preconditions", preconditions},
        {"trajectory_hash", copy_or("trajectory_hash", Value(""))},
        {"nodes_expanded", copy_or("nodes_expanded", Value(0))},
        {"score_milli", copy_or("score_milli", Value(0))},
        {"requested_depth", copy_or("requested_depth", Value(8))},
        {"completed_depth", copy_or("completed_depth", Value(0))},
        {"max_path_depth", copy_or("max_path_depth", Value(0))},
        {"reply_requested_depth", copy_or("reply_requested_depth", Value(3))},
        {"reply_completed_depth", copy_or("reply_completed_depth", Value(0))},
        {"layers_completed", copy_or("layers_completed", Value(0))},
        {"completion_reason", copy_or("completion_reason", Value(""))},
        {"opponent_strategy_id", copy_or("opponent_strategy_id", Value(""))},
    });
    if (debug_payload != nullptr) *debug_payload = payload;
    return sha256_text(stable_value_signature(payload));
}

inline std::string action_cycle_state_fingerprint(ptcg::ai::Value state) {
    for (const char *key : {
        "action_log", "processed_action_ids", "revision", "choice_sequence",
    }) state.erase(key);
    state["resolution_stack"] = ptcg::ai::Value::make_object();
    return sha256_text(stable_value_signature(state));
}

inline std::string action_primary_slot(const ptcg::ai::Value &action) {
    for (const char *key : {"source", "target"}) {
        const ptcg::ai::Value *reference = action.find(key);
        if (reference == nullptr || !reference->is_object()) continue;
        const std::string kind = value_string_field(*reference, "kind");
        if (kind == "pokemon" || kind == "slot" || kind == "attachment") {
            const std::string slot = value_string_field(*reference, "slot");
            if (!slot.empty()) return slot;
        }
    }
    return "active";
}

inline bool value_ability_is_repeatable(
    const ptcg::ai::Value &state,
    std::int32_t actor,
    const ptcg::ai::Value &action,
    const std::string &ability_name,
    const ptcg::ai::Value &catalog
) {
    const ptcg::ai::Value *pokemon = value_pokemon_at(
        state, actor, action_primary_slot(action));
    if (pokemon == nullptr) return false;
    const ptcg::ai::Value *definition = value_card(
        catalog, value_string_field(*pokemon, "card_id"));
    const ptcg::ai::Value *abilities = definition == nullptr
        ? nullptr : definition->find("abilities");
    if (abilities == nullptr || !abilities->is_array()) return false;
    for (const ptcg::ai::Value &ability : abilities->as_array()) {
        if (value_string_field(ability, "name") == ability_name
            && value_string_field(ability, "trigger") == "repeatable") return true;
    }
    return false;
}

inline bool string_ends_with(const std::string &value, const std::string &suffix) {
    return value.size() >= suffix.size()
        && value.compare(value.size() - suffix.size(), suffix.size(), suffix) == 0;
}

inline std::size_t repeatable_ability_uses_this_turn(
    const ptcg::ai::Value &state,
    std::int32_t actor,
    const ptcg::ai::Value &action,
    const std::string &ability_name,
    const ptcg::ai::Value &catalog
) {
    std::string source_card_id;
    const ptcg::ai::Value *source = action.find("source");
    if (source != nullptr && source->is_object()) {
        source_card_id = value_string_field(*source, "card_id");
    }
    if (source_card_id.empty()) {
        const ptcg::ai::Value *pokemon = value_pokemon_at(
            state, actor, action_primary_slot(action));
        if (pokemon != nullptr) source_card_id = value_string_field(
            *pokemon, "card_id");
    }
    const ptcg::ai::Value *definition = value_card(catalog, source_card_id);
    const std::string card_name = definition == nullptr
        ? source_card_id : value_string_field(*definition, "name", source_card_id);
    const std::string player_name = value_string_field(
        value_player(state, actor), "name");
    const std::string canonical = player_name + " 使用了特性「"
        + ability_name + "」。";
    const std::string legacy = card_name + "使用特性" + ability_name + "。";
    const std::string loose_suffix = "使用特性" + ability_name + "。";
    const ptcg::ai::Value *log = state.find("action_log");
    if (log == nullptr || !log->is_array()) return 0;
    std::size_t count = 0;
    for (std::size_t cursor = log->as_array().size(); cursor > 0; --cursor) {
        const std::string entry = log->as_array()[cursor - 1].string_or();
        if (entry.rfind("—— ", 0) == 0) break;
        if (entry == canonical || (!card_name.empty() && entry == legacy)
            || string_ends_with(entry, loose_suffix)) ++count;
    }
    return count;
}

inline ptcg::ai::Value filter_exhausted_repeatable_abilities(
    const ptcg::ai::Value &state,
    std::int32_t actor,
    const ptcg::ai::Value &actions,
    const ptcg::ai::Value &catalog
) {
    if (!actions.is_array()) return ptcg::ai::Value::make_array();
    ptcg::ai::Value::Array kept;
    ptcg::ai::Value::Array terminal;
    for (const ptcg::ai::Value &action : actions.as_array()) {
        if (ptcg::ai::traditional_action_is_terminal(action)) terminal.push_back(action);
        if (value_string_field(action, "kind") != "USE_ABILITY") {
            kept.push_back(action);
            continue;
        }
        const ptcg::ai::Value *payload = action.find("payload");
        const std::string ability_name = payload == nullptr
            ? std::string{} : value_string_field(*payload, "ability_name");
        if (ability_name.empty()
            || !value_ability_is_repeatable(
                state, actor, action, ability_name, catalog)
            || repeatable_ability_uses_this_turn(
                state, actor, action, ability_name, catalog) < 6) {
            kept.push_back(action);
        }
    }
    if (!kept.empty()) return ptcg::ai::Value(std::move(kept));
    if (!terminal.empty()) return ptcg::ai::Value(std::move(terminal));
    return actions;
}

} // namespace ptcg::ai::challenge
