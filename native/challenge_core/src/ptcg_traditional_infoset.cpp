#include "ptcg_traditional_infoset.hpp"
#include "ptcg_traditional_value.hpp"

#include "ptcg_random.hpp"

#include <algorithm>
#include <stdexcept>
#include <string_view>
#include <utility>

namespace ptcg::ai {

namespace {

using Array = Value::Array;
using Object = Value::Object;

using traditional_value::bool_field;
using traditional_value::field;
using traditional_value::integer_field;
using traditional_value::string_field;

Value array_field_or(const Value &value, const char *key, Value fallback) {
    const Value *entry = field(value, key);
    return entry != nullptr && entry->is_array() ? *entry : std::move(fallback);
}

Value object_field_or(const Value &value, const char *key, Value fallback) {
    const Value *entry = field(value, key);
    return entry != nullptr && entry->is_object() ? *entry : std::move(fallback);
}

Value pair_array(Value source, Value first, Value second) {
    if (!source.is_array()) source = Value::make_array();
    Array &values = source.as_array();
    while (values.size() < 2) {
        values.push_back(values.empty() ? first : second);
    }
    values.resize(2);
    return source;
}

bool is_hidden_id(std::string_view card_id) noexcept {
    return card_id == "__ai_hidden_card__"
        || card_id == "__ai_hidden_prize__"
        || card_id == "__hidden_card__"
        || card_id == "__hidden_prize__";
}

constexpr std::size_t max_public_history = 4096;

Array history_card_ids(const Value &event, const Value &data) {
    const Value *entries = field(data, "card_ids");
    if (entries == nullptr || !entries->is_array()) {
        entries = field(data, "cards");
    }
    if (entries == nullptr || !entries->is_array()) {
        entries = field(data, "selected_card_ids");
    }
    Array result;
    if (entries != nullptr && entries->is_array()) {
        result.reserve(entries->as_array().size());
        for (const Value &entry : entries->as_array()) {
            const std::string card_id = entry.is_object()
                ? string_field(entry, "card_id") : entry.string_or();
            if (!card_id.empty() && !is_hidden_id(card_id)) {
                result.emplace_back(card_id);
            }
        }
    }
    if (result.empty()) {
        const std::string card_id = string_field(
            event, "card_id", string_field(data, "card_id"));
        if (!card_id.empty() && !is_hidden_id(card_id)) {
            result.emplace_back(card_id);
        }
    }
    return result;
}

const Value &history_data(const Value &event) {
    static const Value empty = Value::make_object();
    const Value *data = field(event, "data");
    return data != nullptr && data->is_object() ? *data : empty;
}

std::int32_t history_endpoint_player(
    const Value &event,
    const Value &data,
    const char *endpoint_key
) {
    const Value *endpoint = field(event, endpoint_key);
    if (endpoint != nullptr && endpoint->is_object()) {
        const std::int64_t player = integer_field(*endpoint, "player", -1);
        if (player == 0 || player == 1) {
            return static_cast<std::int32_t>(player);
        }
    }
    return static_cast<std::int32_t>(integer_field(
        data, "player", integer_field(event, "actor", -1)));
}

std::string history_endpoint_zone(
    const Value &event,
    const Value &data,
    const char *endpoint_key,
    const char *data_key
) {
    const Value *endpoint = field(event, endpoint_key);
    if (endpoint != nullptr && endpoint->is_object()) {
        const std::string zone = string_field(*endpoint, "zone");
        if (!zone.empty()) {
            return zone;
        }
    }
    return string_field(data, data_key);
}

bool is_hand_movement_event(const std::string &event_type) {
    return event_type == "card_moved"
        || event_type == "cards_discarded"
        || event_type == "cards_selected"
        || event_type == "energy_attached"
        || event_type == "pokemon_evolved"
        || event_type == "pokemon_played"
        || event_type == "stadium_changed"
        || event_type == "tool_attached"
        || event_type == "trainer_played";
}

void remove_known_cards(Array &known, const Array &departed) {
    for (const Value &card : departed) {
        const std::string card_id = card.string_or();
        const auto found = std::find_if(
            known.begin(),
            known.end(),
            [&card_id](const Value &entry) {
                return entry.string_or() == card_id;
            }
        );
        if (found != known.end()) {
            known.erase(found);
        }
    }
}

bool replay_known_opponent_hand(
    const Value &public_history,
    std::int32_t perspective,
    Array &known,
    std::string *error
) {
    known.clear();
    if (
        !public_history.is_array()
        || public_history.as_array().size() > max_public_history
    ) {
        if (error != nullptr) *error = "invalid_public_history";
        return false;
    }
    const std::int32_t opponent = 1 - perspective;
    for (const Value &event : public_history.as_array()) {
        if (!event.is_object()) {
            if (error != nullptr) *error = "invalid_public_history";
            return false;
        }
        const Value *data_value = field(event, "data");
        const Value *source_value = field(event, "source");
        const Value *target_value = field(event, "target");
        if (
            data_value == nullptr || !data_value->is_object()
            || source_value == nullptr || !source_value->is_object()
            || target_value == nullptr || !target_value->is_object()
        ) {
            if (error != nullptr) *error = "invalid_public_history";
            return false;
        }
        const std::string event_type = string_field(event, "event_type");
        const std::string visibility = string_field(
            event, "visibility", "public");
        if (
            event_type.empty()
            || (visibility != "public"
                && visibility != "owner"
                && visibility != "private")
        ) {
            if (error != nullptr) *error = "invalid_public_history";
            return false;
        }
        const Value &data = history_data(event);
        const std::int32_t visibility_owner = static_cast<std::int32_t>(
            integer_field(
                data,
                "visibility_owner",
                integer_field(data, "player", integer_field(event, "actor", -1))
            ));
        const Array card_ids = history_card_ids(event, data);
        if (
            (visibility != "public"
                && visibility_owner != 0
                && visibility_owner != 1)
        ) {
            if (error != nullptr) *error = "invalid_public_history";
            return false;
        }
        if (
            (visibility == "private" && visibility_owner != perspective)
            || (visibility != "public"
                && visibility_owner != perspective
                && !card_ids.empty())
        ) {
            if (error != nullptr) *error = "private_public_history";
            return false;
        }
        const std::int32_t source_player = history_endpoint_player(
            event, data, "source");
        const std::int32_t target_player = history_endpoint_player(
            event, data, "target");
        const std::string source_zone = history_endpoint_zone(
            event, data, "source", "source_zone");
        const std::string target_zone = history_endpoint_zone(
            event, data, "target", "target_zone");

        if (
            source_player == opponent
            && source_zone == "hand"
            && is_hand_movement_event(event_type)
        ) {
            if (visibility == "public" && !card_ids.empty()) {
                remove_known_cards(known, card_ids);
            } else {
                // An identity-hidden or otherwise ambiguous hand departure can
                // include any previously revealed copy.  Forget conservatively.
                known.clear();
            }
        }
        if (
            target_player == opponent
            && target_zone == "hand"
            && visibility == "public"
        ) {
            known.insert(known.end(), card_ids.begin(), card_ids.end());
        }
    }
    return true;
}

Value hidden_cards(std::size_t count, const char *marker) {
    return Value(Array(count, Value(marker)));
}

Value empty_resolution_stack() {
    return Value(Object{
        {"schema_version", Value(3)},
        {"frames", Value::make_array()},
        {"pending_request", Value()},
        {"sequence", Value(0)},
        {"context", Value::make_object()},
    });
}

Value empty_turn_fact_book() {
    return Value(Object{
        {"current_turn", Value(Object{{"knockouts", Value::make_array()}})},
        {"previous_turn", Value(Object{{"knockouts", Value::make_array()}})},
    });
}

Value normalize_pokemon(const Value *source) {
    if (source == nullptr || !source->is_object()) return Value();
    Value result(Object{
        {"card_id", Value(string_field(*source, "card_id"))},
        {"damage_counters", Value(integer_field(*source, "damage_counters"))},
        {"energy_card_ids", array_field_or(
            *source, "energy_card_ids", Value::make_array())},
        {"attached_tool_id", Value(string_field(*source, "attached_tool_id"))},
        {"status_conditions", array_field_or(
            *source, "status_conditions", Value::make_array())},
        {"evolution_stack_ids", array_field_or(
            *source, "evolution_stack_ids", Value::make_array())},
        {"can_evolve_this_turn", Value(bool_field(
            *source, "can_evolve_this_turn", true))},
        {"placed_this_turn", Value(bool_field(
            *source, "placed_this_turn", true))},
        {"used_abilities", array_field_or(
            *source, "used_abilities", Value::make_array())},
        {"healed_this_turn", Value(bool_field(
            *source, "healed_this_turn"))},
        {"paralyzed_since_turn", Value(integer_field(
            *source, "paralyzed_since_turn"))},
    });
    const Value *modifiers = field(*source, "modifiers");
    if (modifiers != nullptr && modifiers->is_array()
        && !modifiers->as_array().empty()) {
        result["modifiers"] = *modifiers;
    }
    return result;
}

Value normalize_player(const Value &source) {
    Value bench = array_field_or(source, "bench", Value::make_array());
    Array normalized_bench;
    normalized_bench.reserve(5);
    for (std::size_t index = 0; index < 5; ++index) {
        const Value *pokemon = index < bench.as_array().size()
            ? &bench.as_array()[index] : nullptr;
        normalized_bench.push_back(normalize_pokemon(pokemon));
    }
    Value result(Object{
        {"name", Value(string_field(source, "name", "玩家"))},
        {"deck", array_field_or(source, "deck", Value::make_array())},
        {"hand", array_field_or(source, "hand", Value::make_array())},
        {"discard", array_field_or(source, "discard", Value::make_array())},
        {"prizes", array_field_or(source, "prizes", Value::make_array())},
        {"active", normalize_pokemon(field(source, "active"))},
        {"bench", Value(std::move(normalized_bench))},
        {"supporter_played_this_turn", Value(bool_field(
            source, "supporter_played_this_turn"))},
        {"energy_attached_this_turn", Value(bool_field(
            source, "energy_attached_this_turn"))},
        {"retreated_this_turn", Value(bool_field(
            source, "retreated_this_turn"))},
        {"stadium_played_this_turn", Value(bool_field(
            source, "stadium_played_this_turn"))},
        {"stadium_used_this_turn", Value(bool_field(
            source, "stadium_used_this_turn"))},
        {"healed_this_turn", Value(bool_field(
            source, "healed_this_turn"))},
        {"vstar_power_used", Value(bool_field(source, "vstar_power_used"))},
        {"was_ko_by_attack", Value(bool_field(source, "was_ko_by_attack"))},
    });
    const Value *locks = field(source, "attack_locked_names");
    if (locks != nullptr && locks->is_object() && !locks->as_object().empty()) {
        result["attack_locked_names"] = *locks;
    }
    return result;
}

Value normalize_public_snapshot(
    const Value &source,
    std::int32_t perspective,
    const Value &legal_actions,
    std::int64_t match_seed
) {
    const Value *source_players = field(source, "players");
    if (source_players == nullptr || !source_players->is_array()
        || source_players->as_array().size() != 2) {
        throw std::invalid_argument("invalid_player_snapshot");
    }
    Array players;
    players.reserve(2);
    for (const Value &player : source_players->as_array()) {
        if (!player.is_object()) {
            throw std::invalid_argument("invalid_player_snapshot");
        }
        players.push_back(normalize_player(player));
    }

    const std::int64_t first_player = integer_field(source, "first_player_idx");
    const std::int64_t winner = integer_field(source, "winner", -1);
    const std::string setup_stage = string_field(
        source, "setup_stage", "INITIAL_PLACEMENT");
    Value rules_options = object_field_or(
        source, "rules_options", Value::make_object());
    rules_options["apply_type_matchups"] = Value(false);
    Value result(Object{
        {"players", Value(std::move(players))},
        {"active_player_idx", Value(integer_field(source, "active_player_idx"))},
        {"phase", Value(string_field(source, "phase", "SETUP"))},
        {"turn_number", Value(integer_field(source, "turn_number"))},
        {"first_player_idx", Value(first_player)},
        {"stadium_card_id", Value(string_field(source, "stadium_card_id"))},
        {"stadium_owner_idx", Value(integer_field(
            source, "stadium_owner_idx", -1))},
        {"winner", Value(winner)},
        {"result_status", Value(string_field(
            source, "result_status", winner >= 0 ? "WIN" : "ONGOING"))},
        {"result_reason", Value(string_field(source, "result_reason"))},
        {"result_conditions", pair_array(array_field_or(
            source, "result_conditions", Value::make_array()),
            Value::make_array(), Value::make_array())},
        {"revision", Value(integer_field(source, "revision"))},
        {"choice_sequence", Value(integer_field(source, "choice_sequence"))},
        {"public_deck_keys", pair_array(array_field_or(
            source, "public_deck_keys", Value::make_array()), Value(""), Value(""))},
        {"apply_type_matchups", Value(false)},
        {"rules_profile_id", Value(string_field(
            source, "rules_profile_id", "CN_MAINLAND_3_1_0"))},
        {"rules_options", std::move(rules_options)},
        {"action_log", Value::make_array()},
        {"mulligan_count", pair_array(array_field_or(
            source, "mulligan_count", Value::make_array()), Value(0), Value(0))},
        {"extra_draws", pair_array(array_field_or(
            source, "extra_draws", Value::make_array()), Value(0), Value(0))},
        {"setup_ready", pair_array(array_field_or(
            source, "setup_ready", Value::make_array()), Value(false), Value(false))},
        {"setup_stage", Value(setup_stage)},
        {"setup_actor_idx", Value(integer_field(
            source, "setup_actor_idx", first_player))},
        {"opening_coin_winner_idx", Value(integer_field(
            source, "opening_coin_winner_idx", first_player))},
        {"mulligan_bonus_max", Value(integer_field(
            source, "mulligan_bonus_max"))},
        {"setup_bonus_card_ids", pair_array(array_field_or(
            source, "setup_bonus_card_ids", Value::make_array()),
            Value::make_array(), Value::make_array())},
        {"pending_promotions", array_field_or(
            source, "pending_promotions", Value::make_array())},
        {"processed_action_ids", Value::make_array()},
        {"resolution_stack", empty_resolution_stack()},
        {"turn_fact_book", object_field_or(
            source, "turn_fact_book", empty_turn_fact_book())},
        {"snapshot_version", Value(3)},
        {"perspective", Value(perspective)},
        {"actor", Value(perspective)},
        {"match_seed", Value(match_seed)},
        {"legal_actions", legal_actions.is_array()
            ? legal_actions : Value::make_array()},
    });

    Array &rows = result["players"].as_array();
    for (std::int32_t player = 0; player < 2; ++player) {
        Value &row = rows[static_cast<std::size_t>(player)];
        const std::size_t deck_count = row["deck"].as_array().size();
        const std::size_t prize_count = row["prizes"].as_array().size();
        row["deck"] = hidden_cards(deck_count, "__ai_hidden_card__");
        row["prizes"] = hidden_cards(prize_count, "__ai_hidden_prize__");
        if (player != perspective) {
            row["hand"] = hidden_cards(
                row["hand"].as_array().size(), "__ai_hidden_card__");
        }
    }
    if (string_field(result, "phase") == "SETUP" && setup_stage != "COMPLETE") {
        Value &opponent = rows[static_cast<std::size_t>(1 - perspective)];
        opponent["active"] = Value();
        opponent["bench"] = Value(Array(5, Value()));
    }
    Array &bonus = result["setup_bonus_card_ids"].as_array();
    bonus[static_cast<std::size_t>(1 - perspective)] = Value::make_array();
    const Value *promotions = result.find("pending_promotions");
    if (promotions != nullptr && promotions->is_array()
        && !promotions->as_array().empty()) {
        const std::int64_t pending_actor = promotions->as_array().front().as_integer(-1);
        if (pending_actor == 0 || pending_actor == 1) result["actor"] = Value(pending_actor);
    } else if (string_field(result, "phase") == "SETUP") {
        const std::int64_t setup_actor = integer_field(result, "setup_actor_idx", -1);
        if (setup_actor == 0 || setup_actor == 1) result["actor"] = Value(setup_actor);
    } else {
        result["actor"] = Value(integer_field(result, "active_player_idx", -1));
    }
    return result;
}

const Value &catalog_cards(const Value &catalog) {
    const Value *cards = field(catalog, "cards");
    return cards != nullptr && cards->is_object() ? *cards : catalog;
}

Array expand_deck(const Value &decks, const std::string &deck_key) {
    const Value *definition = field(decks, deck_key);
    if (definition == nullptr) return {};
    if (definition->is_array()) return definition->as_array();
    const Value *rows = field(*definition, "cards");
    if (rows == nullptr || !rows->is_array()) return {};
    Array result;
    result.reserve(60);
    for (const Value &row : rows->as_array()) {
        if (!row.is_object()) continue;
        const std::string card_id = string_field(row, "card_id");
        const std::int64_t count = integer_field(row, "count");
        if (card_id.empty() || count <= 0) continue;
        for (std::int64_t copy = 0; copy < count; ++copy) {
            result.emplace_back(card_id);
        }
    }
    return result;
}

void append_visible_pokemon(Array &result, const Value *pokemon) {
    if (pokemon == nullptr || !pokemon->is_object()) return;
    for (const char *key : {"card_id", "attached_tool_id"}) {
        const std::string card_id = string_field(*pokemon, key);
        if (!card_id.empty() && !is_hidden_id(card_id)) result.emplace_back(card_id);
    }
    for (const char *key : {"evolution_stack_ids", "energy_card_ids"}) {
        const Value *cards = field(*pokemon, key);
        if (cards == nullptr || !cards->is_array()) continue;
        for (const Value &card : cards->as_array()) {
            const std::string card_id = card.string_or();
            if (!card_id.empty() && !is_hidden_id(card_id)) result.emplace_back(card_id);
        }
    }
}

Array visible_cards(const Value &player, bool include_hand) {
    Array result;
    if (include_hand) {
        const Value *hand = field(player, "hand");
        if (hand != nullptr && hand->is_array()) {
            for (const Value &card : hand->as_array()) {
                const std::string card_id = card.string_or();
                if (!card_id.empty() && !is_hidden_id(card_id)) result.emplace_back(card_id);
            }
        }
    }
    const Value *discard = field(player, "discard");
    if (discard != nullptr && discard->is_array()) {
        for (const Value &card : discard->as_array()) {
            const std::string card_id = card.string_or();
            if (!card_id.empty() && !is_hidden_id(card_id)) result.emplace_back(card_id);
        }
    }
    append_visible_pokemon(result, field(player, "active"));
    const Value *bench = field(player, "bench");
    if (bench != nullptr && bench->is_array()) {
        for (const Value &pokemon : bench->as_array()) append_visible_pokemon(result, &pokemon);
    }
    return result;
}

void remove_visible(Array &pool, const Array &visible) {
    for (const Value &card : visible) {
        const std::string card_id = card.string_or();
        const auto found = std::find_if(pool.begin(), pool.end(), [&card_id](const Value &entry) {
            return entry.string_or() == card_id;
        });
        // AIInformationSet intentionally tolerates synthetic/public fixture
        // mismatches: only identities that exist in the published list are
        // removed.
        if (found != pool.end()) pool.erase(found);
    }
}

void shuffle(Array &values, XorShift32 &rng) {
    for (std::size_t index = values.size(); index > 1; --index) {
        const std::size_t selected = rng.next_u32() % index;
        std::swap(values[index - 1], values[selected]);
    }
}

Array slice(const Array &source, std::size_t begin, std::size_t end) {
    return Array(source.begin() + static_cast<std::ptrdiff_t>(begin),
                 source.begin() + static_cast<std::ptrdiff_t>(end));
}

} // namespace

bool TraditionalInformationSet::capture(
    const Value &public_state,
    std::int32_t perspective,
    const Value &catalog,
    const Value &decks,
    const Value &legal_actions,
    const Value &public_history,
    std::int64_t match_seed,
    std::string *error
) {
    valid_ = false;
    remaining_pools_ = {};
    known_hands_ = {};
    published_deck_valid_ = {};
    if (perspective != 0 && perspective != 1) {
        if (error != nullptr) *error = "invalid_perspective";
        return false;
    }
    if (!public_state.is_object() || !decks.is_object()) {
        if (error != nullptr) *error = "invalid_public_state";
        return false;
    }
    if (!replay_known_opponent_hand(
        public_history,
        perspective,
        known_hands_[static_cast<std::size_t>(1 - perspective)],
        error
    )) {
        return false;
    }
    try {
        public_snapshot_ = normalize_public_snapshot(
            public_state, perspective, legal_actions, match_seed);
        perspective_ = perspective;
        match_seed_ = match_seed;
        const Value &cards = catalog_cards(catalog);
        if (cards.find("sv1-ener-1") != nullptr) {
            fallback_card_id_ = "sv1-ener-1";
        } else {
            fallback_card_id_ = "sv1-ener-1";
            for (const auto &[card_id, card] : cards.as_object()) {
                if (string_field(card, "supertype") != "Energy") continue;
                const Value *subtypes = field(card, "subtypes");
                if (subtypes == nullptr || !subtypes->is_array()) continue;
                if (std::any_of(subtypes->as_array().begin(), subtypes->as_array().end(),
                        [](const Value &entry) { return entry.string_or() == "Basic"; })) {
                    fallback_card_id_ = card_id;
                    break;
                }
            }
        }
        const Array &players = public_snapshot_.find("players")->as_array();
        const Array &deck_keys = public_snapshot_.find("public_deck_keys")->as_array();
        for (std::int32_t player = 0; player < 2; ++player) {
            const Value &row = players[static_cast<std::size_t>(player)];
            Array pool = expand_deck(decks, deck_keys[static_cast<std::size_t>(player)].string_or());
            published_deck_valid_[static_cast<std::size_t>(player)] = !pool.empty();
            remove_visible(pool, visible_cards(row, player == perspective));
            if (integer_field(public_snapshot_, "stadium_owner_idx", -1) == player) {
                const std::string stadium = string_field(public_snapshot_, "stadium_card_id");
                if (!stadium.empty()) {
                    remove_visible(pool, Array{Value(stadium)});
                }
            }
            const std::size_t hand_count = player == perspective
                ? 0U : row.find("hand")->as_array().size();
            Array &known_hand = known_hands_[static_cast<std::size_t>(player)];
            if (known_hand.size() > hand_count) {
                if (error != nullptr) *error = "invalid_known_hand";
                return false;
            }
            if (!known_hand.empty()) {
                if (!published_deck_valid_[static_cast<std::size_t>(player)]) {
                    if (error != nullptr) *error = "invalid_known_hand";
                    return false;
                }
                for (const Value &known_card : known_hand) {
                    const std::string card_id = known_card.string_or();
                    const auto found = std::find_if(
                        pool.begin(),
                        pool.end(),
                        [&card_id](const Value &entry) {
                            return entry.string_or() == card_id;
                        }
                    );
                    if (found == pool.end()) {
                        if (error != nullptr) *error = "invalid_known_hand";
                        return false;
                    }
                    pool.erase(found);
                }
            }
            const std::size_t hidden_count =
                hand_count - known_hand.size()
                + row.find("deck")->as_array().size()
                + row.find("prizes")->as_array().size();
            if (pool.empty() && hidden_count > 0) {
                pool.assign(hidden_count, Value(fallback_card_id_));
            }
            remaining_pools_[static_cast<std::size_t>(player)] = std::move(pool);
        }
        valid_ = true;
        if (error != nullptr) error->clear();
        return true;
    } catch (const std::exception &exception) {
        if (error != nullptr) *error = exception.what();
        return false;
    }
}

bool TraditionalInformationSet::valid() const noexcept { return valid_; }
std::int32_t TraditionalInformationSet::perspective() const noexcept { return perspective_; }
std::int64_t TraditionalInformationSet::match_seed() const noexcept { return match_seed_; }
const Value &TraditionalInformationSet::public_snapshot() const noexcept { return public_snapshot_; }

const Value::Array &TraditionalInformationSet::remaining_pool(std::int32_t player) const {
    if (player != 0 && player != 1) throw std::out_of_range("invalid_player");
    return remaining_pools_[static_cast<std::size_t>(player)];
}

const Value::Array &TraditionalInformationSet::known_hand(
    std::int32_t player
) const {
    if (player != 0 && player != 1) throw std::out_of_range("invalid_player");
    return known_hands_[static_cast<std::size_t>(player)];
}

std::size_t TraditionalInformationSet::hand_count(std::int32_t player) const {
    if (player != 0 && player != 1) throw std::out_of_range("invalid_player");
    const Value *players = public_snapshot_.find("players");
    if (
        players == nullptr || !players->is_array()
        || static_cast<std::size_t>(player) >= players->as_array().size()
    ) {
        return 0;
    }
    const Value *hand = players->as_array()[static_cast<std::size_t>(player)]
        .find("hand");
    return hand != nullptr && hand->is_array() ? hand->as_array().size() : 0;
}

std::size_t TraditionalInformationSet::unknown_hand_count(
    std::int32_t player
) const {
    const std::size_t total = hand_count(player);
    const std::size_t known = known_hand(player).size();
    return total > known ? total - known : 0;
}

std::size_t TraditionalInformationSet::recommended_belief_samples(
    std::int32_t player,
    std::size_t requested
) const {
    if (requested <= 1) return requested;
    const std::size_t known = known_hand(player).size();
    if (known == 0) return requested;
    const std::size_t unknown = unknown_hand_count(player);
    const Value *players = public_snapshot_.find("players");
    std::size_t deck_count = 0;
    if (
        players != nullptr && players->is_array()
        && static_cast<std::size_t>(player) < players->as_array().size()
    ) {
        const Value *deck = players->as_array()[static_cast<std::size_t>(player)]
            .find("deck");
        if (deck != nullptr && deck->is_array()) {
            deck_count = deck->as_array().size();
        }
    }
    // A fully known hand with no possible next draw has only one reply belief.
    // Otherwise retain two samples for the hidden remainder and next draw.
    // Once at least one identity is exact, the third sample mostly repeats the
    // same known-card reply branch; spend that budget only on fully hidden
    // hands, where all three opponent-hand realizations remain distinct.
    if (unknown == 0 && deck_count == 0) return 1;
    return std::min<std::size_t>(requested, 2);
}

bool TraditionalInformationSet::has_published_deck(
    std::int32_t player
) const noexcept {
    return (player == 0 || player == 1)
        && published_deck_valid_[static_cast<std::size_t>(player)];
}

Value TraditionalInformationSet::sample_state(std::uint32_t seed) const {
    if (!valid_) return Value();
    Value result = public_snapshot_;
    Array &players = result["players"].as_array();
    XorShift32 rng(seed);
    for (std::int32_t player = 0; player < 2; ++player) {
        Value &row = players[static_cast<std::size_t>(player)];
        Array pool = remaining_pools_[static_cast<std::size_t>(player)];
        const std::size_t total_hand_count = player == perspective_
            ? 0U : row["hand"].as_array().size();
        const Array &known_hand = known_hands_[static_cast<std::size_t>(player)];
        const std::size_t hand_count = total_hand_count - known_hand.size();
        const std::size_t deck_count = row["deck"].as_array().size();
        const std::size_t prize_count = row["prizes"].as_array().size();
        const std::size_t needed = hand_count + deck_count + prize_count;
        while (pool.size() < needed) pool.emplace_back(fallback_card_id_);
        shuffle(pool, rng);
        if (pool.size() > needed) pool.resize(needed);
        std::size_t cursor = 0;
        if (player != perspective_) {
            Array sampled_hand = known_hand;
            const Array unknown_hand = slice(
                pool, cursor, cursor + hand_count);
            sampled_hand.insert(
                sampled_hand.end(), unknown_hand.begin(), unknown_hand.end());
            if (!known_hand.empty()) {
                shuffle(sampled_hand, rng);
            }
            row["hand"] = Value(std::move(sampled_hand));
            cursor += hand_count;
        }
        row["deck"] = Value(slice(pool, cursor, cursor + deck_count));
        cursor += deck_count;
        row["prizes"] = Value(slice(pool, cursor, cursor + prize_count));
    }
    result["apply_type_matchups"] = Value(false);
    result["rules_options"]["apply_type_matchups"] = Value(false);
    result["resolution_stack"] = empty_resolution_stack();
    result["snapshot_version"] = Value(3);
    for (const char *annotation : {
        "perspective", "actor", "match_seed", "legal_actions",
        "public_history", "ai_runtime_projection",
    }) {
        result.erase(annotation);
    }
    return result;
}

} // namespace ptcg::ai
