#include "ptcg_infoset.hpp"

#include <array>
#include <stdexcept>
#include <string_view>

namespace ptcg::ai {

namespace {

constexpr std::uint64_t FNV_OFFSET = 1469598103934665603ULL;
constexpr std::uint64_t FNV_PRIME = 1099511628211ULL;

bool is_hidden_id(std::string_view value) noexcept {
    return (
        value == "__hidden_card__"
        || value == "__hidden_prize__"
        || value == "__ai_hidden_card__"
        || value == "__ai_hidden_prize__"
    );
}

void hash_byte(std::uint64_t &hash, std::uint8_t value) noexcept {
    hash ^= value;
    hash *= FNV_PRIME;
}

void hash_bytes(
    std::uint64_t &hash,
    const void *source,
    std::size_t size
) noexcept {
    const auto *bytes = static_cast<const std::uint8_t *>(source);
    for (std::size_t index = 0; index < size; ++index) {
        hash_byte(hash, bytes[index]);
    }
}

void hash_string(
    std::uint64_t &hash,
    std::string_view value
) noexcept {
    const std::uint64_t size = value.size();
    hash_bytes(hash, &size, sizeof(size));
    hash_bytes(hash, value.data(), value.size());
}

void hash_value(std::uint64_t &hash, const Value &value) noexcept {
    hash_byte(hash, static_cast<std::uint8_t>(value.type()));
    switch (value.type()) {
        case Value::Type::null_value:
            return;
        case Value::Type::boolean: {
            hash_byte(hash, value.as_bool() ? 1 : 0);
            return;
        }
        case Value::Type::integer: {
            const std::int64_t number = value.as_integer();
            hash_bytes(hash, &number, sizeof(number));
            return;
        }
        case Value::Type::number: {
            const double number = value.as_number();
            hash_bytes(hash, &number, sizeof(number));
            return;
        }
        case Value::Type::string:
            hash_string(hash, value.as_string());
            return;
        case Value::Type::array: {
            const std::uint64_t size = value.as_array().size();
            hash_bytes(hash, &size, sizeof(size));
            for (const Value &entry : value.as_array()) {
                hash_value(hash, entry);
            }
            return;
        }
        case Value::Type::object: {
            const std::uint64_t size = value.as_object().size();
            hash_bytes(hash, &size, sizeof(size));
            for (const auto &[key, entry] : value.as_object()) {
                hash_string(hash, key);
                hash_value(hash, entry);
            }
            return;
        }
    }
}

const Value::Array *array_field(
    const Value &object,
    const std::string &field
) noexcept {
    const Value *value = object.find(field);
    return value != nullptr && value->is_array()
        ? &value->as_array()
        : nullptr;
}

std::string validate_hidden_zone(
    const Value &player,
    const std::string &zone,
    std::size_t player_index
) {
    const Value::Array *cards = array_field(player, zone);
    if (cards == nullptr) {
        return (
            "invalid_runtime_snapshot:players["
            + std::to_string(player_index)
            + "]."
            + zone
        );
    }
    for (const Value &card : *cards) {
        if (!card.is_string() || !is_hidden_id(card.as_string())) {
            return (
                "hidden_identity_exposed:players["
                + std::to_string(player_index)
                + "]."
                + zone
            );
        }
    }
    return {};
}

Value hidden_cards(std::size_t size, const char *marker) {
    Value::Array result(size, Value(marker));
    return Value(std::move(result));
}

Value public_projection(
    const Value &snapshot,
    std::int32_t actor,
    Value *actor_private
) {
    Value observation = snapshot;
    Value *players_value = observation.find("players");
    if (players_value == nullptr || !players_value->is_array()) {
        throw std::invalid_argument("invalid_infoset_players");
    }
    Value::Array &players = players_value->as_array();
    if (players.size() != 2) {
        throw std::invalid_argument("invalid_infoset_player_count");
    }

    for (std::size_t player_index = 0; player_index < 2; ++player_index) {
        Value &player = players[player_index];
        if (!player.is_object()) {
            throw std::invalid_argument("invalid_infoset_player");
        }
        Value *deck = player.find("deck");
        Value *hand = player.find("hand");
        Value *prizes = player.find("prizes");
        if (
            deck == nullptr || !deck->is_array()
            || hand == nullptr || !hand->is_array()
            || prizes == nullptr || !prizes->is_array()
        ) {
            throw std::invalid_argument("invalid_infoset_hidden_zone");
        }
        const std::size_t deck_size = deck->as_array().size();
        const std::size_t prize_size = prizes->as_array().size();
        player["deck"] = hidden_cards(deck_size, "__hidden_card__");
        player["prizes"] = hidden_cards(prize_size, "__hidden_prize__");
        if (static_cast<std::int32_t>(player_index) != actor) {
            player["hand"] = hidden_cards(
                hand->as_array().size(),
                "__hidden_card__"
            );
        } else if (actor_private != nullptr) {
            *actor_private = *hand;
        }
    }

    observation.erase("action_log");
    observation.erase("processed_action_ids");
    observation.erase("resolution_stack");
    observation["perspective"] = Value(actor);
    observation["actor"] = Value(actor);

    const std::string phase = observation.find("phase") != nullptr
        ? observation.find("phase")->string_or()
        : std::string{};
    const std::string setup_stage =
        observation.find("setup_stage") != nullptr
        ? observation.find("setup_stage")->string_or()
        : std::string{};
    if (phase == "SETUP" && setup_stage != "COMPLETE") {
        Value &opponent = players[static_cast<std::size_t>(1 - actor)];
        opponent["active"] = Value();
        opponent["bench"] = Value::make_array();
        Value *bonus = observation.find("setup_bonus_card_ids");
        if (bonus != nullptr && bonus->is_array()) {
            Value::Array &rows = bonus->as_array();
            if (rows.size() == 2) {
                rows[static_cast<std::size_t>(1 - actor)] =
                    Value::make_array();
            }
        }
    }
    return observation;
}

Value make_public_hash_view(
    const Value &observation,
    std::int32_t actor
) {
    Value result = observation;
    Value *players_value = result.find("players");
    if (
        players_value != nullptr
        && players_value->is_array()
        && players_value->as_array().size() == 2
    ) {
        Value &own = players_value->as_array()[
            static_cast<std::size_t>(actor)
        ];
        Value *hand = own.find("hand");
        if (hand != nullptr && hand->is_array()) {
            own["hand"] = hidden_cards(
                hand->as_array().size(),
                "__hidden_card__"
            );
        }
    }
    result.erase("perspective");
    result.erase("actor");
    return result;
}

std::uint64_t combine_hashes(
    std::uint64_t public_hash,
    std::uint64_t private_hash,
    std::int32_t actor
) noexcept {
    std::uint64_t hash = FNV_OFFSET;
    hash_byte(hash, 0xA7);
    hash_bytes(hash, &public_hash, sizeof(public_hash));
    hash_byte(hash, 0x5C);
    hash_bytes(hash, &private_hash, sizeof(private_hash));
    hash_byte(hash, static_cast<std::uint8_t>(actor));
    return hash;
}

} // namespace

std::string validate_runtime_snapshot(
    const Value &snapshot,
    std::int32_t actor
) {
    if (actor != 0 && actor != 1) {
        return "invalid_runtime_actor";
    }
    if (!snapshot.is_object()) {
        return "invalid_runtime_snapshot";
    }
    const Value::Array *players = array_field(snapshot, "players");
    if (players == nullptr || players->size() != 2) {
        return "invalid_runtime_players";
    }
    for (std::size_t player_index = 0; player_index < 2; ++player_index) {
        const Value &player = (*players)[player_index];
        if (!player.is_object()) {
            return "invalid_runtime_player";
        }
        std::string error = validate_hidden_zone(
            player,
            "deck",
            player_index
        );
        if (!error.empty()) {
            return error;
        }
        error = validate_hidden_zone(player, "prizes", player_index);
        if (!error.empty()) {
            return error;
        }
        if (static_cast<std::int32_t>(player_index) != actor) {
            error = validate_hidden_zone(player, "hand", player_index);
            if (!error.empty()) {
                return error;
            }
        } else {
            const Value::Array *hand = array_field(player, "hand");
            if (hand == nullptr) {
                return (
                    "invalid_runtime_snapshot:players["
                    + std::to_string(player_index)
                    + "].hand"
                );
            }
        }
    }

    const Value *resolution_stack = snapshot.find("resolution_stack");
    if (resolution_stack != nullptr && !resolution_stack->is_null()) {
        if (!resolution_stack->is_object()) {
            return "private_resolution_stack_exposed";
        }
        const Value *frames = resolution_stack->find("frames");
        const Value *pending = resolution_stack->find("pending_request");
        const Value *context = resolution_stack->find("context");
        if (
            (frames != nullptr
                && (!frames->is_array() || !frames->as_array().empty()))
            || (pending != nullptr && !pending->is_null())
            || (context != nullptr
                && (!context->is_object()
                    || !context->as_object().empty()))
        ) {
            return "private_resolution_stack_exposed";
        }
    }
    return {};
}

InformationSetProjection project_information_set(
    const Value &snapshot,
    std::int32_t actor
) {
    if (actor != 0 && actor != 1) {
        throw std::invalid_argument("invalid_infoset_actor");
    }
    Value private_hand = Value::make_array();
    InformationSetProjection result;
    result.observation = public_projection(
        snapshot,
        actor,
        &private_hand
    );
    const Value public_view = make_public_hash_view(
        result.observation,
        actor
    );
    result.public_hash = stable_value_hash(public_view);
    result.actor_private_hash = stable_value_hash(private_hand);
    result.tree_key = combine_hashes(
        result.public_hash,
        result.actor_private_hash,
        actor
    );
    return result;
}

std::uint64_t stable_value_hash(const Value &value) noexcept {
    std::uint64_t hash = FNV_OFFSET;
    hash_value(hash, value);
    return hash;
}

} // namespace ptcg::ai
