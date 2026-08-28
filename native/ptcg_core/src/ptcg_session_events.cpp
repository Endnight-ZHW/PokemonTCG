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


namespace ptcg::ai::session_detail {

using Array = Value::Array;
using Object = Value::Object;

struct CardPlace {
    std::int32_t player = -1;
    std::string zone;
    std::string slot;
    std::string role;
    std::int64_t index = -1;
};

struct CardLocation {
    std::string card_id;
    CardPlace place;
};

struct CardMoveFact {
    std::string card_id;
    CardPlace source;
    CardPlace target;
    bool consumed = false;
};

bool same_place_bucket(const CardPlace &left, const CardPlace &right) {
    // Array indices are deliberately excluded. Removing one of two identical
    // cards reindexes the survivor, but that is not a second physical move.
    return left.player == right.player
        && left.zone == right.zone
        && left.slot == right.slot
        && left.role == right.role;
}

bool is_board_place(const CardPlace &place) {
    return !place.slot.empty();
}

bool is_hidden_zone(const std::string &zone) {
    return zone == "deck" || zone == "hand" || zone == "prizes";
}

void append_card_location(
    std::vector<CardLocation> &locations,
    const Value &card_id,
    CardPlace place
) {
    const std::string id = card_id.string_or();
    if (!id.empty()) {
        locations.push_back(CardLocation{id, std::move(place)});
    }
}

void append_pokemon_locations(
    std::vector<CardLocation> &locations,
    const Value &pokemon_value,
    std::int32_t owner,
    const std::string &slot
) {
    if (!pokemon_value.is_object()) {
        return;
    }
    const Value *card_id = pokemon_value.find("card_id");
    if (card_id != nullptr) {
        append_card_location(
            locations,
            *card_id,
            CardPlace{owner, {}, slot, "pokemon", -1}
        );
    }
    const Value *evolutions = pokemon_value.find("evolution_stack_ids");
    if (evolutions != nullptr && evolutions->is_array()) {
        for (std::size_t index = 0; index < evolutions->as_array().size(); ++index) {
            append_card_location(
                locations,
                evolutions->as_array()[index],
                CardPlace{
                    owner, {}, slot, "evolution",
                    static_cast<std::int64_t>(index),
                }
            );
        }
    }
    const Value *energy = pokemon_value.find("energy_card_ids");
    if (energy != nullptr && energy->is_array()) {
        for (std::size_t index = 0; index < energy->as_array().size(); ++index) {
            append_card_location(
                locations,
                energy->as_array()[index],
                CardPlace{
                    owner, {}, slot, "energy",
                    static_cast<std::int64_t>(index),
                }
            );
        }
    }
    const std::string tool_id = string_field(
        pokemon_value, "attached_tool_id");
    if (!tool_id.empty()) {
        append_card_location(
            locations,
            Value(tool_id),
            CardPlace{owner, {}, slot, "tool", 0}
        );
    }
}

std::vector<CardLocation> card_locations(const Value &state) {
    std::vector<CardLocation> locations;
    const Value *players = state.find("players");
    if (players == nullptr || !players->is_array()) {
        return locations;
    }
    static constexpr std::array<const char *, 4> zones{
        "deck", "hand", "discard", "prizes",
    };
    for (
        std::size_t player_index = 0;
        player_index < players->as_array().size() && player_index < 2;
        ++player_index
    ) {
        const Value &owner = players->as_array()[player_index];
        if (!owner.is_object()) {
            continue;
        }
        for (const char *zone_name : zones) {
            const Value *cards = owner.find(zone_name);
            if (cards == nullptr || !cards->is_array()) {
                continue;
            }
            for (std::size_t index = 0; index < cards->as_array().size(); ++index) {
                append_card_location(
                    locations,
                    cards->as_array()[index],
                    CardPlace{
                        static_cast<std::int32_t>(player_index),
                        zone_name,
                        {},
                        "card",
                        static_cast<std::int64_t>(index),
                    }
                );
            }
        }
        const Value *active = owner.find("active");
        if (active != nullptr) {
            append_pokemon_locations(
                locations,
                *active,
                static_cast<std::int32_t>(player_index),
                "active"
            );
        }
        const Value *bench = owner.find("bench");
        if (bench != nullptr && bench->is_array()) {
            for (std::size_t index = 0; index < bench->as_array().size(); ++index) {
                append_pokemon_locations(
                    locations,
                    bench->as_array()[index],
                    static_cast<std::int32_t>(player_index),
                    "bench_" + std::to_string(index)
                );
            }
        }
    }
    const std::string stadium_id = string_field(state, "stadium_card_id");
    if (!stadium_id.empty()) {
        append_card_location(
            locations,
            Value(stadium_id),
            CardPlace{
                static_cast<std::int32_t>(integer_field(
                    state, "stadium_owner_idx", -1)),
                "stadium", {}, "card", 0,
            }
        );
    }
    return locations;
}

std::vector<CardMoveFact> card_move_facts(
    const Value *before_state,
    const Value *after_state
) {
    if (before_state == nullptr || after_state == nullptr) {
        return {};
    }
    const std::vector<CardLocation> before = card_locations(*before_state);
    const std::vector<CardLocation> after = card_locations(*after_state);
    std::vector<bool> before_matched(before.size(), false);
    std::vector<bool> after_matched(after.size(), false);

    // Cancel cards that stayed in the same logical container first. This also
    // makes a pure deck shuffle produce no fake card movements.
    for (std::size_t left = 0; left < before.size(); ++left) {
        for (std::size_t right = 0; right < after.size(); ++right) {
            if (
                !after_matched[right]
                && before[left].card_id == after[right].card_id
                && same_place_bucket(before[left].place, after[right].place)
            ) {
                before_matched[left] = true;
                after_matched[right] = true;
                break;
            }
        }
    }

    std::vector<CardMoveFact> moves;
    for (std::size_t left = 0; left < before.size(); ++left) {
        if (before_matched[left]) {
            continue;
        }
        for (std::size_t right = 0; right < after.size(); ++right) {
            if (
                !after_matched[right]
                && before[left].card_id == after[right].card_id
            ) {
                moves.push_back(CardMoveFact{
                    before[left].card_id,
                    before[left].place,
                    after[right].place,
                    false,
                });
                before_matched[left] = true;
                after_matched[right] = true;
                break;
            }
        }
    }
    return moves;
}

bool empty_contract_value(const Value *value) {
    return value == nullptr || value->is_null()
        || (value->is_string() && value->as_string().empty())
        || (value->is_array() && value->as_array().empty())
        || (value->is_object() && value->as_object().empty());
}

void set_if_empty(Value &object, const std::string &key, Value value) {
    if (empty_contract_value(object.find(key))) {
        object[key] = std::move(value);
    }
}

Value endpoint_from_place(const CardPlace &place) {
    Object endpoint{{"player", Value(place.player)}};
    if (!place.zone.empty()) {
        endpoint["zone"] = Value(place.zone);
    }
    if (!place.slot.empty()) {
        endpoint["slot"] = Value(place.slot);
    }
    if (place.index >= 0) {
        endpoint["index"] = Value(place.index);
    }
    if (place.role == "energy" || place.role == "tool") {
        endpoint["attachment_type"] = Value(place.role);
    }
    return Value(std::move(endpoint));
}

std::int64_t bench_index(const std::string &slot) {
    if (slot.rfind("bench_", 0) != 0) {
        return -1;
    }
    try {
        return std::stoll(slot.substr(6));
    } catch (const std::exception &) {
        return -1;
    }
}

bool action_event_matches(
    const std::string &action_kind,
    const std::string &event_type
) {
    if (action_kind == "PLAY_BASIC") {
        return event_type == "pokemon_played";
    }
    if (action_kind == "EVOLVE") {
        return event_type == "pokemon_evolved";
    }
    if (action_kind == "ATTACH_ENERGY") {
        return event_type == "energy_attached";
    }
    if (action_kind == "PLAY_TRAINER") {
        return event_type == "trainer_played"
            || event_type == "tool_attached"
            || event_type == "stadium_changed";
    }
    if (action_kind == "PROMOTE") {
        return event_type == "promoted";
    }
    if (action_kind == "RETREAT") {
        return event_type == "retreat";
    }
    if (action_kind == "DECLARE_ATTACK") {
        return event_type == "attack_declared";
    }
    return false;
}

class EventTransitionHydrator {
public:
    EventTransitionHydrator(
        const Value *before_state,
        const Value *after_state,
        const Value *input,
        std::int32_t actor_hint
    ) : before_state_(before_state),
        after_state_(after_state),
        input_(input),
        actor_hint_(actor_hint),
        moves_(card_move_facts(before_state, after_state)) {}

    void hydrate(
        Value &event_value,
        const std::string &event_type,
        const std::string &previous_type
    ) {
        if (!event_value.is_object()) {
            return;
        }
        if (
            event_value.find("data") == nullptr
            || !event_value.find("data")->is_object()
        ) {
            event_value["data"] = Value::make_object();
        }

        const std::string action_kind = input_ != nullptr
            ? string_field(*input_, "kind") : std::string{};
        const Value *action_source = input_ != nullptr
            ? input_->find("source") : nullptr;
        const std::string action_card_id = action_source != nullptr
            && action_source->is_object()
            ? string_field(*action_source, "card_id") : std::string{};

        std::vector<std::size_t> selected;
        const bool explicit_zero_selection = is_explicit_zero_selection(
            event_type);
        if (explicit_zero_selection) {
            Value &data = required(event_value, "data");
            data["card_ids"] = Value::make_array();
            data["count"] = Value(0);
            event_value["amount"] = Value(0);
        }
        const bool declared_identity = has_declared_card_identity(event_value);
        const bool declared_card_batch = declared_identity && (
            event_type == "card_moved"
            || event_type == "cards_discarded"
            || event_type == "cards_drawn"
            || event_type == "cards_selected"
            || event_type == "prize_taken"
        );
        if (declared_card_batch) {
            // A command event records the physical operation, while the
            // before/after diff only records the net multiset change.  When a
            // card with the same id leaves and re-enters a zone in one
            // resolution (Youngster and discard-then-draw are common cases),
            // the net diff deliberately cancels those two copies.  Preserve
            // the command's declared identity/count before hydrating endpoint
            // hints so presentation never drops the cancelled motion.
            Value &data = required(event_value, "data");
            const Value *declared_ids = data.find("card_ids");
            if (
                empty_contract_value(event_value.find("card_id"))
                && declared_ids != nullptr
                && declared_ids->is_array()
                && !declared_ids->as_array().empty()
            ) {
                event_value["card_id"] = Value(
                    declared_ids->as_array().front().string_or()
                );
            }
            if (event_value.find("amount") == nullptr) {
                const std::int64_t declared_count = integer_field(
                    data,
                    "count",
                    declared_ids != nullptr && declared_ids->is_array()
                        ? static_cast<std::int64_t>(
                            declared_ids->as_array().size())
                        : 1
                );
                if (declared_count >= 0) {
                    event_value["amount"] = Value(declared_count);
                }
            }
            seed_declared_batch_endpoints(event_value);
        }
        const bool direct_action_event = !declared_identity
            && !action_card_id.empty()
            && action_event_matches(action_kind, event_type);
        if (declared_identity) {
            selected = select_declared(
                event_value, event_type, previous_type);
        } else if (direct_action_event) {
            selected = select_direct(event_type, action_card_id);
        }
        if (
            selected.empty()
            && !declared_identity
            && !explicit_zero_selection
            && !direct_action_event
        ) {
            selected = select_for_event(event_type, previous_type);
        }
        if (!selected.empty()) {
            const bool preserve_declared_contract = declared_card_batch
                && selected.size() < declared_card_count(event_value);
            apply_moves(
                event_value,
                event_type,
                selected,
                previous_type,
                preserve_declared_contract
            );
        } else if (action_event_matches(action_kind, event_type)) {
            apply_action_fallback(event_value, event_type);
        }

        hydrate_turn_boundary(event_value, event_type);
        hydrate_feedback_defaults(event_value, event_type);
        Value &data = required(event_value, "data");
        if (empty_contract_value(event_value.find("card_id"))) {
            const std::string data_card_id = string_field(data, "card_id");
            const Value *data_card_ids = data.find("card_ids");
            if (!data_card_id.empty()) {
                event_value["card_id"] = Value(data_card_id);
            } else if (
                data_card_ids != nullptr
                && data_card_ids->is_array()
                && !data_card_ids->as_array().empty()
            ) {
                event_value["card_id"] = Value(
                    data_card_ids->as_array().front().string_or());
            }
        }
        if (empty_contract_value(event_value.find("amount"))) {
            const std::int64_t amount = integer_field(
                data, "amount", integer_field(data, "count", 0));
            if (amount > 0) {
                event_value["amount"] = Value(amount);
            }
        }
        if (event_value.find("actor") == nullptr) {
            const std::int32_t data_actor = static_cast<std::int32_t>(
                integer_field(
                    data,
                    "actor",
                    integer_field(data, "player", actor_hint_)
                ));
            if (data_actor >= 0) {
                event_value["actor"] = Value(data_actor);
            }
        }
        if (empty_contract_value(event_value.find("visibility"))) {
            const std::string data_visibility = string_field(
                data, "visibility");
            if (!data_visibility.empty()) {
                event_value["visibility"] = Value(data_visibility);
            } else if (
                event_type == "cards_drawn"
                || event_type == "prize_taken"
                || event_type == "cards_selected"
            ) {
                event_value["visibility"] = Value("owner");
            }
        }
        const std::string visibility = string_field(
            event_value, "visibility", string_field(data, "visibility"));
        if (
            (visibility == "owner" || visibility == "private")
            && data.find("visibility_owner") == nullptr
        ) {
            // The causal actor can differ from the owner of a hidden movement
            // (Judge is the canonical example). Privacy follows the explicit
            // payload/physical endpoint, never the player who caused the event.
            std::int32_t visibility_owner = static_cast<std::int32_t>(
                integer_field(data, "player", -1));
            if (visibility_owner < 0 || visibility_owner > 1) {
                const Value *source = event_value.find("source");
                if (source != nullptr && source->is_object()) {
                    visibility_owner = static_cast<std::int32_t>(
                        integer_field(*source, "player", -1));
                }
            }
            if (visibility_owner < 0 || visibility_owner > 1) {
                const Value *target = event_value.find("target");
                if (target != nullptr && target->is_object()) {
                    visibility_owner = static_cast<std::int32_t>(
                        integer_field(*target, "player", -1));
                }
            }
            if (visibility_owner < 0 || visibility_owner > 1) {
                visibility_owner = static_cast<std::int32_t>(
                    integer_field(event_value, "actor", actor_hint_));
            }
            if (visibility_owner >= 0 && visibility_owner <= 1) {
                data["visibility_owner"] = Value(visibility_owner);
            }
        }
    }

private:
    const Value *before_state_ = nullptr;
    const Value *after_state_ = nullptr;
    const Value *input_ = nullptr;
    std::int32_t actor_hint_ = -1;
    std::vector<CardMoveFact> moves_;

    bool is_explicit_zero_selection(const std::string &event_type) const {
        if (
            event_type != "cards_selected"
            || input_ == nullptr
            || !input_->is_object()
            || bool_field(*input_, "cancelled")
        ) {
            return false;
        }
        const Value *option_ids = input_->find("option_ids");
        return option_ids != nullptr
            && option_ids->is_array()
            && option_ids->as_array().empty();
    }

    bool has_declared_card_identity(const Value &event_value) const {
        const Value *data = event_value.find("data");
        if (data == nullptr || !data->is_object()) {
            return !string_field(event_value, "card_id").empty();
        }
        if (
            !string_field(event_value, "card_id").empty()
            || !string_field(*data, "card_id").empty()
        ) {
            return true;
        }
        const Value *card_ids = data->find("card_ids");
        return card_ids != nullptr
            && card_ids->is_array()
            && !card_ids->as_array().empty();
    }

    void seed_declared_batch_endpoints(Value &event_value) const {
        Value &data = required(event_value, "data");
        const std::int32_t owner = static_cast<std::int32_t>(
            integer_field(data, "player", actor_hint_));
        const auto seed_endpoint = [&event_value, &data, owner](
            const std::string &endpoint_key,
            const std::string &field_prefix
        ) {
            const std::string zone = string_field(
                data, field_prefix + "_zone");
            const std::string slot = string_field(
                data, field_prefix + "_slot");
            if (zone.empty() && slot.empty()) {
                return;
            }
            const std::int32_t player = static_cast<std::int32_t>(
                integer_field(data, field_prefix + "_player", owner));
            Object endpoint{{"player", Value(player)}};
            if (!zone.empty()) {
                endpoint["zone"] = Value(zone);
            }
            if (!slot.empty()) {
                endpoint["slot"] = Value(slot);
            }
            const std::int64_t index = integer_field(
                data, field_prefix + "_index", -1);
            if (index >= 0) {
                endpoint["index"] = Value(index);
            }
            set_if_empty(
                event_value,
                endpoint_key,
                Value(std::move(endpoint))
            );
        };
        seed_endpoint("source", "source");
        seed_endpoint("target", "target");
    }

    std::size_t declared_card_count(const Value &event_value) const {
        const Value *data = event_value.find("data");
        if (data == nullptr || !data->is_object()) {
            return string_field(event_value, "card_id").empty() ? 0 : 1;
        }
        const Value *card_ids = data->find("card_ids");
        if (card_ids != nullptr && card_ids->is_array()) {
            return card_ids->as_array().size();
        }
        return string_field(event_value, "card_id").empty()
            && string_field(*data, "card_id").empty() ? 0 : 1;
    }

    bool matches_declared_endpoints(
        const CardMoveFact &move,
        const Value *data
    ) const {
        if (data == nullptr || !data->is_object()) {
            return true;
        }
        const std::string source_zone = string_field(*data, "source_zone");
        const std::string target_zone = string_field(*data, "target_zone");
        const std::string source_slot = string_field(*data, "source_slot");
        const std::string target_slot = string_field(*data, "target_slot");
        if (!source_zone.empty() && move.source.zone != source_zone) {
            return false;
        }
        if (!target_zone.empty() && move.target.zone != target_zone) {
            return false;
        }
        if (!source_slot.empty() && move.source.slot != source_slot) {
            return false;
        }
        if (!target_slot.empty() && move.target.slot != target_slot) {
            return false;
        }
        const std::int32_t source_player = static_cast<std::int32_t>(
            integer_field(*data, "source_player", -1));
        const std::int32_t target_player = static_cast<std::int32_t>(
            integer_field(*data, "target_player", -1));
        return (source_player < 0 || move.source.player == source_player)
            && (target_player < 0 || move.target.player == target_player);
    }

    std::vector<std::size_t> select_declared(
        const Value &event_value,
        const std::string &event_type,
        const std::string &previous_type
    ) {
        std::vector<std::string> declared_ids;
        const Value *data = event_value.find("data");
        const Value *card_ids = data != nullptr && data->is_object()
            ? data->find("card_ids") : nullptr;
        if (card_ids != nullptr && card_ids->is_array()) {
            for (const Value &entry : card_ids->as_array()) {
                if (!entry.string_or().empty()) {
                    declared_ids.push_back(entry.string_or());
                }
            }
        }
        if (declared_ids.empty()) {
            std::string card_id = string_field(event_value, "card_id");
            if (card_id.empty() && data != nullptr && data->is_object()) {
                card_id = string_field(*data, "card_id");
            }
            if (!card_id.empty()) {
                declared_ids.push_back(std::move(card_id));
            }
        }
        const std::int32_t declared_owner = data != nullptr
            && data->is_object()
            ? static_cast<std::int32_t>(integer_field(*data, "player", -1))
            : -1;
        std::vector<std::size_t> selected;
        for (const std::string &card_id : declared_ids) {
            std::optional<std::size_t> matched;
            for (std::size_t index = 0; index < moves_.size(); ++index) {
                if (
                    !moves_[index].consumed
                    && moves_[index].card_id == card_id
                    && matches_event(moves_[index], event_type, previous_type)
                    && matches_declared_endpoints(moves_[index], data)
                    && (
                        declared_owner < 0
                        || owner_for_event(moves_[index], event_type)
                            == declared_owner
                    )
                ) {
                    matched = index;
                    break;
                }
            }
            if (matched.has_value()) {
                moves_[*matched].consumed = true;
                selected.push_back(*matched);
            }
        }
        return selected;
    }

    bool matches_event(
        const CardMoveFact &move,
        const std::string &event_type,
        const std::string &previous_type
    ) const {
        if (event_type == "cards_drawn") {
            return move.source.zone == "deck"
                && move.target.zone == "hand";
        }
        if (event_type == "prize_taken") {
            return move.source.zone == "prizes"
                && move.target.zone == "hand";
        }
        if (event_type == "cards_selected") {
            return !same_place_bucket(move.source, move.target)
                && !move.source.zone.empty()
                && move.target.zone != "discard";
        }
        if (event_type == "cards_discarded") {
            return move.target.zone == "discard";
        }
        if (event_type == "pokemon_played") {
            return move.source.zone == "hand"
                && move.target.role == "pokemon";
        }
        if (event_type == "pokemon_evolved") {
            return move.source.zone == "hand"
                && move.target.role == "pokemon";
        }
        if (event_type == "energy_attached") {
            return move.target.role == "energy";
        }
        if (event_type == "tool_attached") {
            return move.target.role == "tool";
        }
        if (event_type == "trainer_played") {
            return move.source.zone == "hand"
                && (move.target.zone == "discard"
                    || move.target.zone == "stadium");
        }
        if (event_type == "stadium_changed") {
            return move.target.zone == "stadium";
        }
        if (event_type == "pokemon_ko") {
            return move.source.role == "pokemon"
                && is_board_place(move.source)
                && move.target.zone == "discard";
        }
        if (
            event_type == "card_moved"
            && previous_type == "pokemon_ko"
        ) {
            return move.source.role == "pokemon"
                && is_board_place(move.source)
                && move.target.zone == "discard";
        }
        if (event_type == "card_moved") {
            // Dedicated draw/search/prize events own hidden-pile arrivals.
            // Leaving these facts available prevents an earlier generic move
            // (for example hand -> deck before a redraw) from stealing the
            // identities needed by the later flying-card event.
            return move.source.role != "evolution"
                && !(move.source.zone == "deck"
                    && move.target.zone == "hand")
                && !(move.source.zone == "prizes"
                    && move.target.zone == "hand");
        }
        if (
            event_type == "promoted"
            || event_type == "retreat"
            || event_type == "switched"
        ) {
            return is_board_place(move.source)
                && is_board_place(move.target)
                && (
                    move.target.slot == "active"
                    || move.source.slot == "active"
                );
        }
        return false;
    }

    std::int32_t owner_for_event(
        const CardMoveFact &move,
        const std::string &event_type
    ) const {
        if (
            event_type == "cards_drawn"
            || event_type == "prize_taken"
            || event_type == "cards_selected"
        ) {
            return move.target.player;
        }
        return move.source.player >= 0
            ? move.source.player : move.target.player;
    }

    bool same_event_group(
        const CardMoveFact &left,
        const CardMoveFact &right,
        const std::string &event_type,
        const std::string &previous_type
    ) const {
        if (
            event_type == "pokemon_ko"
            || event_type == "pokemon_played"
            || event_type == "pokemon_evolved"
            || event_type == "tool_attached"
            || event_type == "trainer_played"
            || event_type == "stadium_changed"
            || event_type == "prize_taken"
        ) {
            return false;
        }
        if (
            event_type == "card_moved"
            && previous_type == "pokemon_ko"
        ) {
            return left.source.player == right.source.player
                && left.source.slot == right.source.slot
                && left.target.player == right.target.player
                && left.target.zone == right.target.zone;
        }
        if (
            event_type == "promoted"
            || event_type == "retreat"
            || event_type == "switched"
        ) {
            return left.source.player == right.source.player
                && left.source.slot == right.source.slot
                && left.target.player == right.target.player
                && left.target.slot == right.target.slot;
        }
        return same_place_bucket(left.source, right.source)
            && same_place_bucket(left.target, right.target);
    }

    std::vector<std::size_t> select_direct(
        const std::string &event_type,
        const std::string &card_id
    ) {
        for (std::size_t index = 0; index < moves_.size(); ++index) {
            if (
                !moves_[index].consumed
                && moves_[index].card_id == card_id
                && matches_event(moves_[index], event_type, {})
            ) {
                moves_[index].consumed = true;
                return {index};
            }
        }
        return {};
    }

    std::vector<std::size_t> select_for_event(
        const std::string &event_type,
        const std::string &previous_type
    ) {
        std::optional<std::size_t> seed;
        for (std::size_t index = 0; index < moves_.size(); ++index) {
            if (
                !moves_[index].consumed
                && matches_event(moves_[index], event_type, previous_type)
                && owner_for_event(moves_[index], event_type) == actor_hint_
            ) {
                seed = index;
                break;
            }
        }
        if (!seed.has_value()) {
            for (std::size_t index = 0; index < moves_.size(); ++index) {
                if (
                    !moves_[index].consumed
                    && matches_event(moves_[index], event_type, previous_type)
                ) {
                    seed = index;
                    break;
                }
            }
        }
        if (!seed.has_value()) {
            return {};
        }
        std::vector<std::size_t> selected{*seed};
        for (std::size_t index = 0; index < moves_.size(); ++index) {
            if (
                index != *seed
                && !moves_[index].consumed
                && matches_event(moves_[index], event_type, previous_type)
                && same_event_group(
                    moves_[*seed], moves_[index], event_type, previous_type)
            ) {
                selected.push_back(index);
            }
        }
        // pokemon_ko is a declaration. The following card_moved event owns and
        // consumes the physical stack departure.
        if (event_type != "pokemon_ko") {
            for (const std::size_t index : selected) {
                moves_[index].consumed = true;
            }
        }
        return selected;
    }

    void apply_moves(
        Value &event_value,
        const std::string &event_type,
        const std::vector<std::size_t> &selected,
        const std::string &previous_type,
        bool preserve_declared_contract = false
    ) {
        if (selected.empty()) {
            return;
        }
        const CardMoveFact &first = moves_[selected.front()];
        Array card_ids;
        Array source_indices;
        Array target_indices;
        for (const std::size_t index : selected) {
            card_ids.emplace_back(moves_[index].card_id);
            source_indices.emplace_back(moves_[index].source.index);
            target_indices.emplace_back(moves_[index].target.index);
        }
        Value &data = required(event_value, "data");
        set_if_empty(data, "card_id", Value(first.card_id));
        set_if_empty(data, "card_ids", Value(card_ids));
        set_if_empty(
            data, "count",
            Value(static_cast<std::int64_t>(selected.size()))
        );
        set_if_empty(data, "source_player", Value(first.source.player));
        set_if_empty(data, "target_player", Value(first.target.player));
        set_if_empty(data, "source_zone", Value(first.source.zone));
        set_if_empty(data, "target_zone", Value(first.target.zone));
        set_if_empty(data, "source_slot", Value(first.source.slot));
        set_if_empty(data, "target_slot", Value(first.target.slot));
        if (!preserve_declared_contract && first.source.index >= 0) {
            set_if_empty(data, "source_index", Value(first.source.index));
        }
        if (!preserve_declared_contract && first.target.index >= 0) {
            set_if_empty(data, "target_index", Value(first.target.index));
        }
        if (!preserve_declared_contract && selected.size() > 1) {
            set_if_empty(data, "source_indices", Value(source_indices));
            set_if_empty(data, "target_indices", Value(target_indices));
        }
        const std::int32_t owner = owner_for_event(first, event_type);
        set_if_empty(data, "player", Value(owner));
        set_if_empty(event_value, "card_id", Value(first.card_id));
        set_if_empty(
            event_value, "amount",
            Value(static_cast<std::int64_t>(selected.size()))
        );
        set_if_empty(
            event_value, "source", endpoint_from_place(first.source));
        set_if_empty(
            event_value, "target", endpoint_from_place(first.target));
        // A choice payload can identify an exact physical slot that a multiset
        // before/after diff cannot recover (notably duplicate face-down Prize
        // cards). Preserve that authoritative index in the canonical endpoint.
        if (!preserve_declared_contract) {
            const std::int64_t declared_source_index = integer_field(
                data, "source_index", -1);
            if (declared_source_index >= 0) {
                Value *source_endpoint = event_value.find("source");
                if (source_endpoint != nullptr && source_endpoint->is_object()) {
                    (*source_endpoint)["index"] = Value(declared_source_index);
                }
            }
            const std::int64_t declared_target_index = integer_field(
                data, "target_index", -1);
            if (declared_target_index >= 0) {
                Value *target_endpoint = event_value.find("target");
                if (target_endpoint != nullptr && target_endpoint->is_object()) {
                    (*target_endpoint)["index"] = Value(declared_target_index);
                }
            }
        }

        std::int32_t actor = (
            event_type == "cards_drawn"
            || event_type == "prize_taken"
            || event_type == "cards_selected"
        ) ? owner : actor_hint_;
        if (actor < 0) {
            actor = owner;
        }
        if (event_value.find("actor") == nullptr && actor >= 0) {
            event_value["actor"] = Value(actor);
        }
        if (
            event_type == "cards_drawn"
            || event_type == "prize_taken"
            || event_type == "cards_selected"
        ) {
            set_if_empty(event_value, "visibility", Value("owner"));
        } else if (
            event_type == "pokemon_played"
            && before_state_ != nullptr
            && string_field(*before_state_, "setup_stage") != "COMPLETE"
        ) {
            set_if_empty(event_value, "visibility", Value("owner"));
        } else if (
            (is_hidden_zone(first.source.zone)
                || is_hidden_zone(first.target.zone))
            && first.target.zone != "discard"
            && !is_board_place(first.target)
            && first.target.zone != "stadium"
        ) {
            set_if_empty(event_value, "visibility", Value("owner"));
        } else {
            set_if_empty(event_value, "visibility", Value("public"));
        }

        if (event_type == "pokemon_ko") {
            set_if_empty(data, "slot", Value(first.source.slot));
            set_if_empty(data, "stage", Value("declared"));
            set_if_empty(data, "defer_leave_play", Value(true));
            set_if_empty(
                data, "presentation_phase", Value("knockout"));
            // KO feedback targets the still-visible in-play stack.
            event_value["target"] = endpoint_from_place(first.source);
            event_value["amount"] = Value(1);
        }
        if (
            event_type == "card_moved"
            && previous_type == "pokemon_ko"
        ) {
            set_if_empty(data, "cause", Value("pokemon_ko"));
            set_if_empty(data, "ko_leave_play", Value(true));
            set_if_empty(
                data, "presentation_phase", Value("knockout"));
        }
        if (
            event_type == "energy_attached"
            || event_type == "tool_attached"
            || event_type == "pokemon_played"
            || event_type == "pokemon_evolved"
        ) {
            set_if_empty(data, "slot", Value(first.target.slot));
        }
        if (
            event_type == "promoted"
            || event_type == "retreat"
            || event_type == "switched"
        ) {
            const std::string bench_slot =
                first.source.slot.rfind("bench_", 0) == 0
                ? first.source.slot : first.target.slot;
            set_if_empty(data, "slot", Value(bench_slot));
            const std::int64_t index = bench_index(bench_slot);
            if (index >= 0) {
                set_if_empty(data, "bench_idx", Value(index));
            }
        }
    }

    void apply_action_fallback(
        Value &event_value,
        const std::string &event_type
    ) const {
        if (input_ == nullptr || !input_->is_object()) {
            return;
        }
        Value &data = required(event_value, "data");
        const std::int32_t actor = static_cast<std::int32_t>(
            integer_field(*input_, "actor", actor_hint_));
        const Value *source = input_->find("source");
        const Value *target = input_->find("target");
        std::string card_id;
        if (source != nullptr && source->is_object()) {
            card_id = string_field(*source, "card_id");
            set_if_empty(event_value, "source", source->deep_clone());
            set_if_empty(data, "source_zone", Value(string_field(*source, "zone")));
            set_if_empty(data, "source_slot", Value(string_field(*source, "slot")));
            const std::int64_t index = integer_field(*source, "index", -1);
            if (index >= 0) {
                set_if_empty(data, "source_index", Value(index));
            }
        }
        if (target != nullptr && target->is_object()) {
            if (card_id.empty()) {
                card_id = string_field(*target, "card_id");
            }
            set_if_empty(event_value, "target", target->deep_clone());
            set_if_empty(data, "target_zone", Value(string_field(*target, "zone")));
            set_if_empty(data, "target_slot", Value(string_field(*target, "slot")));
        }
        if (event_type == "trainer_played") {
            set_if_empty(event_value, "target", Value(Object{
                {"player", Value(actor)}, {"zone", Value("discard")},
            }));
            set_if_empty(data, "target_zone", Value("discard"));
        } else if (event_type == "stadium_changed") {
            set_if_empty(event_value, "target", Value(Object{
                {"player", Value(actor)}, {"zone", Value("stadium")},
            }));
            set_if_empty(data, "target_zone", Value("stadium"));
        } else if (event_type == "promoted") {
            if (target != nullptr && target->is_object()) {
                event_value["source"] = target->deep_clone();
                event_value["target"] = Value(Object{
                    {"player", Value(actor)}, {"slot", Value("active")},
                });
                const std::string slot = string_field(*target, "slot");
                set_if_empty(data, "slot", Value(slot));
                const std::int64_t index = bench_index(slot);
                if (index >= 0) {
                    set_if_empty(data, "bench_idx", Value(index));
                }
            }
        }
        if (!card_id.empty()) {
            set_if_empty(event_value, "card_id", Value(card_id));
            set_if_empty(data, "card_id", Value(card_id));
            set_if_empty(data, "card_ids", Value(Array{Value(card_id)}));
            set_if_empty(data, "count", Value(1));
            set_if_empty(event_value, "amount", Value(1));
        }
        set_if_empty(data, "player", Value(actor));
        if (event_value.find("actor") == nullptr && actor >= 0) {
            event_value["actor"] = Value(actor);
        }
        if (
            event_type == "pokemon_played"
            && before_state_ != nullptr
            && string_field(*before_state_, "setup_stage") != "COMPLETE"
        ) {
            set_if_empty(event_value, "visibility", Value("owner"));
        } else {
            set_if_empty(event_value, "visibility", Value("public"));
        }
    }

    void hydrate_turn_boundary(
        Value &event_value,
        const std::string &event_type
    ) const {
        if (
            event_type != "turn_start"
            && event_type != "turn_end"
            && event_type != "checkup"
            && event_type != "deck_shuffled"
        ) {
            return;
        }
        Value &data = required(event_value, "data");
        std::int32_t actor = actor_hint_;
        const Value *state = before_state_;
        if (event_type == "turn_start" && after_state_ != nullptr) {
            state = after_state_;
            actor = static_cast<std::int32_t>(integer_field(
                *after_state_, "active_player_idx", actor));
        } else if (
            (event_type == "turn_end" || event_type == "checkup")
            && before_state_ != nullptr
        ) {
            actor = static_cast<std::int32_t>(integer_field(
                *before_state_, "active_player_idx", actor));
        } else if (event_type == "deck_shuffled") {
            actor = static_cast<std::int32_t>(integer_field(
                data, "player", actor));
        }
        if (actor >= 0) {
            set_if_empty(data, "player", Value(actor));
            if (event_value.find("actor") == nullptr) {
                event_value["actor"] = Value(actor);
            }
        }
        if (state != nullptr && (event_type == "turn_start" || event_type == "turn_end")) {
            set_if_empty(data, "turn", Value(integer_field(*state, "turn_number")));
        }
    }

    void hydrate_feedback_defaults(
        Value &event_value,
        const std::string &event_type
    ) const {
        Value &data = required(event_value, "data");
        std::int32_t actor = static_cast<std::int32_t>(integer_field(
            data,
            "actor",
            event_value.find("actor") != nullptr
                ? integer_field(event_value, "actor", actor_hint_)
                : actor_hint_
        ));
        if (event_type == "attack_declared") {
            const std::int32_t attacker = actor >= 0
                ? actor : static_cast<std::int32_t>(integer_field(
                    data, "player", -1));
            if (attacker >= 0 && attacker <= 1) {
                set_if_empty(event_value, "source", Value(Object{
                    {"player", Value(attacker)},
                    {"slot", Value("active")},
                }));
                set_if_empty(event_value, "target", Value(Object{
                    {"player", Value(1 - attacker)},
                    {"slot", Value("active")},
                }));
                set_if_empty(data, "source_player", Value(attacker));
                set_if_empty(data, "source_slot", Value("active"));
                set_if_empty(data, "target_player", Value(1 - attacker));
                set_if_empty(data, "target_slot", Value("active"));
            }
            return;
        }
        static const std::unordered_set<std::string> targeted_feedback{
            "confusion_failed",
            "damage_counters_placed",
            "damage_dealt",
            "damage_prevented",
            "dazzled_failed",
            "direct_knockout_applied",
            "healed",
            "status_applied",
            "status_removed",
        };
        if (targeted_feedback.find(event_type) != targeted_feedback.end()) {
            const std::int32_t target_player = static_cast<std::int32_t>(
                integer_field(
                    data,
                    "target_player",
                    integer_field(data, "player", actor)
                ));
            const std::string target_slot = string_field(
                data, "target_slot", string_field(data, "slot", "active"));
            if (target_player >= 0 && target_player <= 1) {
                set_if_empty(event_value, "target", Value(Object{
                    {"player", Value(target_player)},
                    {"slot", Value(target_slot)},
                }));
                if (actor >= 0 && actor <= 1) {
                    set_if_empty(event_value, "source", Value(Object{
                        {"player", Value(actor)},
                        {"slot", Value("active")},
                    }));
                }
            }
            return;
        }
        if (event_type == "deck_exhausted") {
            const std::int32_t exhausted = static_cast<std::int32_t>(
                integer_field(data, "player", actor));
            if (exhausted >= 0 && exhausted <= 1) {
                set_if_empty(data, "player", Value(exhausted));
                set_if_empty(data, "reason", Value("draw_failed"));
                set_if_empty(event_value, "source", Value(Object{
                    {"player", Value(exhausted)},
                    {"zone", Value("deck")},
                }));
                set_if_empty(event_value, "target", Value(Object{
                    {"player", Value(exhausted)},
                    {"zone", Value("deck")},
                }));
            }
            return;
        }
        if (event_type == "game_over" && after_state_ != nullptr) {
            const std::int32_t winner = static_cast<std::int32_t>(
                integer_field(*after_state_, "winner", actor));
            set_if_empty(data, "winner", Value(winner));
            set_if_empty(data, "result_status", Value(string_field(
                *after_state_, "result_status")));
            set_if_empty(data, "reason", Value(string_field(
                *after_state_, "result_reason")));
            const Value *conditions = after_state_->find("result_conditions");
            if (conditions != nullptr) {
                set_if_empty(data, "conditions", conditions->deep_clone());
            }
            if (event_value.find("actor") == nullptr && winner >= 0) {
                event_value["actor"] = Value(winner);
            }
        }
    }
};

std::vector<Value> canonical_events(
    const GameExecutionResult &result,
    const Value *before_state,
    const Value *after_state,
    const Value *input,
    std::int32_t actor_hint
) {
    // Payload-bearing events are intentionally sparse.  Align them by their
    // explicit type instead of by vector index, otherwise a trailing payload
    // (for example game_over) can overwrite an earlier type-only event such as
    // prize_taken.
    std::vector<Value> events;
    events.reserve(result.event_types.size() + result.events.size());
    std::size_t payload_index = 0;
    EventTransitionHydrator hydrator(
        before_state, after_state, input, actor_hint);
    for (std::size_t index = 0; index < result.event_types.size(); ++index) {
        const std::string &type = result.event_types[index];
        Value canonical;
        if (
            payload_index < result.events.size()
            && result.events[payload_index].is_object()
            && string_field(
                result.events[payload_index], "event_type") == type
        ) {
            canonical = result.events[payload_index].deep_clone();
            ++payload_index;
        } else {
            canonical = event(type);
        }
        const std::string previous_type = index > 0
            ? result.event_types[index - 1] : std::string{};
        hydrator.hydrate(canonical, type, previous_type);
        events.push_back(std::move(canonical));
    }
    while (payload_index < result.events.size()) {
        Value payload = result.events[payload_index++].deep_clone();
        if (!payload.is_object() || payload.find("event_type") == nullptr) {
            payload = event("event");
        }
        const std::string type = string_field(payload, "event_type", "event");
        hydrator.hydrate(payload, type, {});
        events.push_back(std::move(payload));
    }
    return events;
}


} // namespace ptcg::ai::session_detail
