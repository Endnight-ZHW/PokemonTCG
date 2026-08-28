#include "ptcg_rules_session.hpp"
#include "ptcg_session_internal.hpp"

#include "ptcg_random.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <functional>
#include <iomanip>
#include <limits>
#include <mutex>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <unordered_set>
#include <unordered_map>
#include <utility>


namespace ptcg::ai {

using namespace session_detail;

RulesSessionResult RulesSession::create(
    const Value &catalog,
    const Value &decks,
    const Value &match_config,
    std::uint32_t seed
) {
    if (initialized_) {
        return result(
            false,
            "match_already_started",
            "match_already_started"
        );
    }
    if (!catalog.is_object() || catalog.as_object().empty()) {
        return result(false, "card_catalog_missing", "card_catalog_missing");
    }
    try {
        set_cards(catalog.deep_clone());
    } catch (const std::exception &error) {
        return result(false, error.what(), error.what());
    }
    return create(decks, match_config, seed);
}

RulesSessionResult RulesSession::create(
    const Value &decks,
    const Value &match_config,
    std::uint32_t seed
) {
    if (initialized_) {
        return result(
            false,
            "match_already_started",
            "match_already_started"
        );
    }
    if (!cards().is_object() || cards().as_object().empty()) {
        return result(false, "card_catalog_missing", "card_catalog_missing");
    }
    if (!decks.is_array() || decks.as_array().size() != 2) {
        return result(false, "invalid_decks", "invalid_decks");
    }
    Array prepared_decks;
    prepared_decks.reserve(2);
    for (const Value &deck_value : decks.as_array()) {
        if (!deck_value.is_array() || deck_value.as_array().size() != 60) {
            return result(false, "invalid_deck_size", "invalid_deck_size");
        }
        bool has_basic = false;
        for (const Value &card_value : deck_value.as_array()) {
            const std::string card_id = card_value.string_or();
            if (card_id.empty() || cards().find(card_id) == nullptr) {
                return result(false, "unknown_card", "unknown_card");
            }
            has_basic = has_basic || is_basic_pokemon(cards(), card_id);
        }
        if (!has_basic) {
            return result(false, "missing_basic_pokemon", "missing_basic_pokemon");
        }
        prepared_decks.push_back(deck_value.deep_clone());
    }

    XorShift32 rng(seed);
    shuffle(prepared_decks[0].as_array(), rng);
    shuffle(prepared_decks[1].as_array(), rng);
    const std::int32_t forced_first = static_cast<std::int32_t>(
        integer_field(match_config, "forced_first", -1));
    const std::int32_t coin_winner = forced_first == 0 || forced_first == 1
        ? forced_first
        : ((rng.next_u32() & 1U) == 0 ? 0 : 1);
    Array public_deck_keys{Value(""), Value("")};
    const Value *configured_keys = match_config.find("public_deck_keys");
    if (
        configured_keys != nullptr
        && configured_keys->is_array()
        && configured_keys->as_array().size() == 2
    ) {
        if (std::any_of(
            configured_keys->as_array().begin(),
            configured_keys->as_array().end(),
            [](const Value &entry) {
                return !entry.is_string() || entry.string_or().size() > 128;
            }
        )) {
            return result(
                false,
                "invalid_public_deck_keys",
                "invalid_public_deck_keys"
            );
        }
        public_deck_keys = configured_keys->as_array();
    }
    Value rules_options = Value(Object{{"apply_type_matchups", Value(false)}});
    const Value *configured_options = match_config.find("rules_options");
    if (configured_options != nullptr && configured_options->is_object()) {
        rules_options = configured_options->deep_clone();
    }
    const bool apply_type_matchups = bool_field(
        rules_options, "apply_type_matchups",
        bool_field(match_config, "apply_type_matchups"));
    rules_options["apply_type_matchups"] = Value(apply_type_matchups);
    Array player_names{Value("玩家1"), Value("玩家2")};
    const Value *configured_names = match_config.find("player_names");
    if (
        configured_names != nullptr
        && configured_names->is_array()
        && configured_names->as_array().size() == 2
    ) {
        if (std::any_of(
            configured_names->as_array().begin(),
            configured_names->as_array().end(),
            [](const Value &entry) {
                return !entry.is_string() || entry.string_or().size() > 128;
            }
        )) {
            return result(
                false,
                "invalid_player_names",
                "invalid_player_names"
            );
        }
        player_names = configured_names->as_array();
    }
    state_ = Value(Object{
        {"players", Value(Array{
            empty_player(player_names[0].string_or("玩家1"), prepared_decks[0].as_array()),
            empty_player(player_names[1].string_or("玩家2"), prepared_decks[1].as_array()),
        })},
        {"active_player_idx", Value(coin_winner)},
        {"phase", Value("SETUP")},
        {"turn_number", Value(0)},
        {"first_player_idx", Value(coin_winner)},
        {"stadium_card_id", Value("")},
        {"stadium_owner_idx", Value(-1)},
        {"winner", Value(-1)},
        {"result_status", Value("ONGOING")},
        {"result_reason", Value("")},
        {"result_conditions", Value(Array{Value::make_array(), Value::make_array()})},
        {"revision", Value(0)},
        {"choice_sequence", Value(0)},
        {"public_deck_keys", Value(public_deck_keys)},
        {"apply_type_matchups", Value(apply_type_matchups)},
        {"rules_profile_id", Value(string_field(
            match_config, "rules_profile_id", "CN_MAINLAND_3_1_0"))},
        {"rules_options", rules_options},
        {"action_log", Value::make_array()},
        {"mulligan_count", Value(Array{Value(0), Value(0)})},
        {"extra_draws", Value(Array{Value(0), Value(0)})},
        {"setup_ready", Value(Array{Value(false), Value(false)})},
        {"setup_stage", Value("TURN_ORDER")},
        {"setup_actor_idx", Value(coin_winner)},
        {"opening_coin_winner_idx", Value(coin_winner)},
        {"mulligan_bonus_max", Value(0)},
        {"setup_bonus_card_ids", Value(Array{Value::make_array(), Value::make_array()})},
        {"pending_promotions", Value::make_array()},
        {"processed_action_ids", Value::make_array()},
        {"resolution_stack", empty_resolution_stack()},
        {"turn_fact_book", Value(Object{
            {"current_turn", Value(Object{{"knockouts", Value::make_array()}})},
            {"previous_turn", Value(Object{{"knockouts", Value::make_array()}})},
        })},
    });
    match_config_ = match_config.is_object()
        ? match_config.deep_clone() : Value::make_object();
    if (!card_ir_content_fingerprint_.empty()) {
        match_config_["card_ir_content_fingerprint"] = Value(
            card_ir_content_fingerprint_);
        match_config_["card_ir_contract_fingerprint"] = Value(
            card_ir_contract_fingerprint_);
        match_config_["vm_descriptor_digest"] = Value(
            vm_descriptor_digest_);
    }
    match_config_["catalog_fingerprint"] = Value(
        canonical_value_hash(cards()));
    match_config_["decks_fingerprint"] = Value(
        canonical_value_hash(decks));
    match_config_["core_contract_fingerprint"] = Value(
        canonical_value_hash(contract()));
    initial_seed_ = seed == 0 ? 0x6D2B79F5U : seed;
    rng_state_ = rng.state();
    journal_entries_ = Value::make_array();
    pending_ = Value();
    pending_raw_ = Value();
    continuation_ = Value();
    initialized_ = true;
    std::vector<Value> events;
    if (forced_first != 0 && forced_first != 1) {
        events.push_back(event(
            "coin_flip", 0,
            Value(Object{
                {"purpose", Value("setup_turn_order")},
                {"results", Value(Array{Value(coin_winner == 0)})},
                {"coin_winner", Value(coin_winner)},
            }),
            "public"
        ));
        Array options{
            Value(Object{{"option_id", Value("turn:first")}, {"label", Value("先攻")}}),
            Value(Object{{"option_id", Value("turn:second")}, {"label", Value("后攻")}}),
        };
        pending_ = setup_choice(
            state_, coin_winner, "choose_turn_order", "请选择先攻或后攻。",
            options, "choose_turn_order");
        pending_raw_ = pending_;
        continuation_ = Value(Object{
            {"kind", Value("setup_turn_order")},
            {"actor", Value(coin_winner)},
        });
        materialize_resolution_stack();
    } else {
        state_["first_player_idx"] = Value(forced_first);
        state_["active_player_idx"] = Value(forced_first);
        const std::string opening_error = prepare_opening_hands(
            cards(), state_, rng, events);
        rng_state_ = rng.state();
        if (!opening_error.empty()) {
            initialized_ = false;
            return result(false, opening_error, opening_error);
        }
    }
    append_public_event_logs(state_, cards(), state_, events);
    std::string typed_error;
    if (!commit_authoritative_state(&typed_error)) {
        initialized_ = false;
        authoritative_state_.reset();
        return result(false, typed_error, typed_error);
    }
    append_journal_entry("create", match_config_, -1, events);
    return result(true, {}, "match_created", std::move(events));
}

RulesSessionResult RulesSession::load_scenario(
    const Value &snapshot_value,
    std::uint32_t rng_state,
    const Value &match_config
) {
    std::string error;
    if (!restore(snapshot_value, rng_state, &error)) {
        return result(false, error, error);
    }
    match_config_ = match_config.is_object()
        ? match_config.deep_clone() : Value::make_object();
    if (!card_ir_content_fingerprint_.empty()) {
        match_config_["card_ir_content_fingerprint"] = Value(
            card_ir_content_fingerprint_);
        match_config_["card_ir_contract_fingerprint"] = Value(
            card_ir_contract_fingerprint_);
        match_config_["vm_descriptor_digest"] = Value(
            vm_descriptor_digest_);
    }
    match_config_["catalog_fingerprint"] = Value(
        canonical_value_hash(cards()));
    match_config_["scenario_fingerprint"] = Value(
        canonical_value_hash(snapshot_value));
    match_config_["core_contract_fingerprint"] = Value(
        canonical_value_hash(contract()));
    initial_seed_ = rng_state_;
    journal_entries_ = Value::make_array();
    append_journal_entry("load_scenario", Value::make_object(), -1, {});
    return result(true, {}, "scenario_loaded");
}

} // namespace ptcg::ai
