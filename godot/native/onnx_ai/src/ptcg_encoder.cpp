#include "ptcg_encoder.hpp"

#include <algorithm>
#include <array>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace ptcg::ai {

namespace {

using Array = Value::Array;
using Object = Value::Object;

constexpr std::array<std::string_view, 6> PHASES{
    "SETUP", "DRAW", "MAIN", "ATTACK", "POKEMON_CHECKUP", "GAME_OVER",
};
constexpr std::array<std::string_view, 10> DECK_KEYS{
    "fire", "water", "psychic", "lightning", "fighting",
    "colorless", "dragon", "grass", "steel", "darkness",
};
constexpr std::array<std::string_view, 11> ACTION_TYPES{
    "PLAY_BASIC", "EVOLVE", "ATTACH_ENERGY", "PLAY_TRAINER",
    "USE_ABILITY", "USE_STADIUM", "RETREAT", "DECLARE_ATTACK",
    "PROMOTE", "SETUP_DONE", "END_TURN",
};
constexpr std::array<std::string_view, 9> CHOICE_TYPES{
    "select_card", "select_pokemon", "select_attachment",
    "distribute_energy", "confirm", "select_prize", "setup",
    "coin_flip", "order",
};
constexpr std::array<std::string_view, 6> TARGET_SLOTS{
    "active", "bench_0", "bench_1", "bench_2", "bench_3", "bench_4",
};

const Value &required(const Value &value, const std::string &key) {
    const Value *found = value.find(key);
    if (found == nullptr) {
        throw std::invalid_argument("encoder_missing_field:" + key);
    }
    return *found;
}

std::string string_field(
    const Value &value,
    const std::string &key,
    const std::string &fallback = {}
) {
    const Value *found = value.find(key);
    return found == nullptr ? fallback : found->string_or(fallback);
}

std::int64_t integer_field(
    const Value &value,
    const std::string &key,
    std::int64_t fallback = 0
) {
    const Value *found = value.find(key);
    return found == nullptr ? fallback : found->as_integer(fallback);
}

bool boolean_field(
    const Value &value,
    const std::string &key,
    bool fallback = false
) {
    const Value *found = value.find(key);
    return found == nullptr ? fallback : found->as_bool(fallback);
}

float normalized(double value, double scale) noexcept {
    return static_cast<float>(std::clamp(
        value / std::max(1.0e-6, scale),
        -1.0,
        1.0
    ));
}

template <std::size_t Size>
std::size_t enum_index(
    const std::array<std::string_view, Size> &values,
    std::string_view needle,
    std::size_t fallback = Size
) noexcept {
    const auto found = std::find(values.begin(), values.end(), needle);
    return found == values.end()
        ? fallback
        : static_cast<std::size_t>(found - values.begin());
}

std::size_t deck_index(const std::string &key) noexcept {
    return enum_index(DECK_KEYS, key, 0);
}

std::int64_t zone_id(const std::string &zone) noexcept {
    if (zone == "active") return 1;
    if (zone == "bench") return 2;
    if (zone == "hand") return 3;
    if (zone == "discard") return 4;
    if (zone == "stadium") return 5;
    if (zone == "energy") return 6;
    if (zone == "tool") return 7;
    if (zone == "deck") return 8;
    if (zone == "prizes") return 9;
    if (zone == "field") return 10;
    return 0;
}

std::int64_t slot_id(const std::string &slot) noexcept {
    if (slot == "active") {
        return 1;
    }
    if (slot.rfind("bench_", 0) == 0 && slot.size() == 7) {
        const char digit = slot[6];
        if (digit >= '0' && digit <= '4') {
            return static_cast<std::int64_t>(digit - '0' + 2);
        }
    }
    return 0;
}

const Value *card_definition(
    const Value &cards,
    const std::string &card_id
) noexcept {
    return cards.find(card_id);
}

std::int64_t card_index(
    const Value &cards,
    const std::string &card_id
) noexcept {
    if (card_id.empty()) {
        return 0;
    }
    const Value *card = card_definition(cards, card_id);
    return card == nullptr
        ? 1
        : integer_field(*card, "ai_card_index", 1);
}

void write_semantics(
    const Value &cards,
    const std::string &card_id,
    float *destination,
    std::size_t available
) noexcept {
    const Value *card = card_definition(cards, card_id);
    const Value *features = card != nullptr
        ? card->find("ai_semantic_features")
        : nullptr;
    if (features == nullptr || !features->is_array()) {
        return;
    }
    const std::size_t count = std::min(
        available,
        features->as_array().size()
    );
    for (std::size_t index = 0; index < count; ++index) {
        destination[index] = static_cast<float>(
            features->as_array()[index].as_number()
        );
    }
}

const Value *pokemon_at(
    const Value &player,
    const std::string &slot
) {
    if (slot == "active") {
        const Value *active = player.find("active");
        return active != nullptr && active->is_object() ? active : nullptr;
    }
    if (slot.rfind("bench_", 0) != 0 || slot.size() != 7) {
        return nullptr;
    }
    const std::size_t index = static_cast<std::size_t>(slot[6] - '0');
    const Value *bench = player.find("bench");
    if (
        bench == nullptr
        || !bench->is_array()
        || index >= bench->as_array().size()
        || !bench->as_array()[index].is_object()
    ) {
        return nullptr;
    }
    return &bench->as_array()[index];
}

void set_entity(
    InferenceRequest &result,
    const Value &cards,
    std::size_t index,
    const std::string &card_id,
    std::int64_t token_type,
    std::int64_t owner,
    const std::string &zone,
    const std::string &slot,
    const std::vector<float> &values
) {
    if (index >= ENTITY_SLOTS) {
        throw std::invalid_argument("entity_layout_overflow");
    }
    result.entity_card_ids[index] = card_index(cards, card_id);
    const std::size_t type_base = index * ENTITY_TYPE_FIELDS;
    result.entity_type_ids[type_base] = token_type;
    result.entity_type_ids[type_base + 1] = owner;
    result.entity_type_ids[type_base + 2] = zone_id(zone);
    result.entity_type_ids[type_base + 3] = slot_id(slot);
    const std::size_t numeric_base = index * ENTITY_NUMERIC_SIZE;
    const std::size_t count = std::min(
        values.size(),
        ENTITY_NUMERIC_SIZE
    );
    std::copy_n(
        values.begin(),
        count,
        result.entity_numeric.begin()
            + static_cast<std::ptrdiff_t>(numeric_base)
    );
}

const Value &observation_player(
    const Value &observation,
    std::int32_t player_index
) {
    return required(observation, "players").as_array().at(
        static_cast<std::size_t>(player_index)
    );
}

void encode_information_set(
    InferenceRequest &result,
    const Value &cards,
    const Value &observation
) {
    const std::int32_t perspective = static_cast<std::int32_t>(
        integer_field(observation, "perspective", -1)
    );
    if (perspective != 0 && perspective != 1) {
        throw std::invalid_argument("invalid_encoder_perspective");
    }
    const std::string phase = string_field(observation, "phase");
    const std::size_t phase_index = enum_index(PHASES, phase);
    if (phase_index < 16) {
        result.state_global[phase_index] = 1.0F;
    }
    const Value &own = observation_player(observation, perspective);
    const Value &opponent = observation_player(
        observation,
        1 - perspective
    );
    const Array &own_hand = required(own, "hand").as_array();
    const Array &own_discard = required(own, "discard").as_array();
    const Array &own_deck = required(own, "deck").as_array();
    const Array &own_prizes = required(own, "prizes").as_array();
    const Array &opponent_hand = required(opponent, "hand").as_array();
    const Array &opponent_discard = required(
        opponent,
        "discard"
    ).as_array();
    const Array &opponent_deck = required(opponent, "deck").as_array();
    const Array &opponent_prizes = required(
        opponent,
        "prizes"
    ).as_array();
    const std::int64_t winner = integer_field(
        observation,
        "winner",
        -1
    );
    const std::array<float, 13> scalars{
        integer_field(observation, "active_player_idx", -1)
            == perspective ? 1.0F : 0.0F,
        normalized(integer_field(observation, "turn_number"), 30.0),
        boolean_field(observation, "apply_type_matchups") ? 1.0F : 0.0F,
        winner == perspective ? 1.0F : 0.0F,
        winner == 1 - perspective ? 1.0F : 0.0F,
        normalized(own_hand.size(), 20.0),
        normalized(own_discard.size(), 60.0),
        normalized(own_deck.size(), 60.0),
        normalized(own_prizes.size(), 6.0),
        normalized(opponent_hand.size(), 20.0),
        normalized(opponent_discard.size(), 60.0),
        normalized(opponent_deck.size(), 60.0),
        normalized(opponent_prizes.size(), 6.0),
    };
    std::copy(
        scalars.begin(),
        scalars.end(),
        result.state_global.begin() + 16
    );
    const Value *keys_value = observation.find("public_deck_keys");
    std::string own_key;
    std::string opponent_key;
    if (
        keys_value != nullptr
        && keys_value->is_array()
        && keys_value->as_array().size() == 2
    ) {
        own_key = keys_value->as_array()[
            static_cast<std::size_t>(perspective)
        ].string_or();
        opponent_key = keys_value->as_array()[
            static_cast<std::size_t>(1 - perspective)
        ].string_or();
    }
    result.actor_deck_id = static_cast<std::int64_t>(
        deck_index(own_key)
    );
    result.opponent_deck_id = static_cast<std::int64_t>(
        deck_index(opponent_key)
    );
    result.state_global[
        29 + static_cast<std::size_t>(result.actor_deck_id)
    ] = 1.0F;
    result.state_global[
        39 + static_cast<std::size_t>(result.opponent_deck_id)
    ] = 1.0F;

    std::size_t entity_index = 0;
    for (const std::int32_t player_index :
         {perspective, 1 - perspective}) {
        const Value &owner = observation_player(
            observation,
            player_index
        );
        for (const std::string_view slot_value : TARGET_SLOTS) {
            const std::string slot(slot_value);
            const Value *pokemon = pokemon_at(owner, slot);
            const std::string pokemon_id = pokemon != nullptr
                ? string_field(*pokemon, "card_id")
                : std::string{};
            const Value *energies = pokemon != nullptr
                ? pokemon->find("energy_card_ids")
                : nullptr;
            const Value *statuses = pokemon != nullptr
                ? pokemon->find("status_conditions")
                : nullptr;
            const std::string tool = pokemon != nullptr
                ? string_field(*pokemon, "attached_tool_id")
                : std::string{};
            const std::size_t energy_count = (
                energies != nullptr && energies->is_array()
            ) ? energies->as_array().size() : 0;
            const std::size_t status_count = (
                statuses != nullptr && statuses->is_array()
            ) ? statuses->as_array().size() : 0;
            const std::int64_t owner_id =
                player_index == perspective ? 1 : 2;
            const std::size_t base = entity_index;
            set_entity(
                result,
                cards,
                base,
                pokemon_id,
                1,
                owner_id,
                slot == "active" ? "active" : "bench",
                slot,
                {
                    pokemon_id.empty() ? 0.0F : 1.0F,
                    slot == "active" ? 1.0F : 0.0F,
                    normalized(
                        pokemon != nullptr
                            ? integer_field(*pokemon, "damage_counters")
                            : 0,
                        30.0
                    ),
                    normalized(energy_count, 6.0),
                    normalized(status_count, 5.0),
                    tool.empty() ? 0.0F : 1.0F,
                }
            );
            for (std::size_t offset = 0; offset < 4; ++offset) {
                const std::string energy_id = (
                    energies != nullptr
                    && energies->is_array()
                    && offset < energies->as_array().size()
                ) ? energies->as_array()[offset].string_or() : "";
                set_entity(
                    result,
                    cards,
                    base + 1 + offset,
                    energy_id,
                    2,
                    owner_id,
                    "energy",
                    slot,
                    {
                        energy_id.empty() ? 0.0F : 1.0F,
                        normalized(offset + 1, 4.0),
                        normalized(base + 1, ENTITY_SLOTS),
                    }
                );
            }
            set_entity(
                result,
                cards,
                base + 5,
                tool,
                3,
                owner_id,
                "tool",
                slot,
                {
                    tool.empty() ? 0.0F : 1.0F,
                    normalized(base + 1, ENTITY_SLOTS),
                }
            );
            entity_index += 6;
        }
    }

    auto encode_zone = [&result, &cards, &entity_index](
        const Array &values,
        std::size_t width,
        bool take_last,
        std::int64_t token_type,
        std::int64_t owner_id,
        const std::string &zone
    ) {
        const std::size_t start = take_last && values.size() > width
            ? values.size() - width
            : 0;
        for (std::size_t offset = 0; offset < width; ++offset) {
            const std::string card_id = start + offset < values.size()
                ? values[start + offset].string_or()
                : std::string{};
            set_entity(
                result,
                cards,
                entity_index + offset,
                card_id,
                token_type,
                owner_id,
                zone,
                "",
                {
                    card_id.empty() ? 0.0F : 1.0F,
                    normalized(offset + 1, width),
                }
            );
        }
        entity_index += width;
    };
    encode_zone(own_hand, 16, false, 4, 1, "hand");
    encode_zone(own_discard, 12, true, 5, 1, "discard");
    encode_zone(opponent_discard, 12, true, 6, 2, "discard");
    const std::string stadium = string_field(
        observation,
        "stadium_card_id"
    );
    set_entity(
        result,
        cards,
        entity_index,
        stadium,
        7,
        0,
        "stadium",
        "",
        {stadium.empty() ? 0.0F : 1.0F}
    );
}

std::int64_t ref_owner(const Value *ref) noexcept {
    return ref != nullptr && ref->is_object()
        ? integer_field(*ref, "player", -1)
        : -1;
}

void encode_candidate_ref(
    const Value *source,
    const Value *target,
    std::vector<std::int64_t> &refs
) {
    const Value *ref = target != nullptr && target->is_object()
        ? target
        : source != nullptr && source->is_object() ? source : nullptr;
    const std::int64_t owner = ref_owner(ref);
    refs.push_back(
        owner >= -1 && owner <= 1 ? owner + 2 : 0
    );
    refs.push_back(
        ref != nullptr
            ? zone_id(string_field(*ref, "zone"))
            : 0
    );
    refs.push_back(
        ref != nullptr
            ? slot_id(string_field(*ref, "slot"))
            : 0
    );
    refs.push_back(
        std::max<std::int64_t>(
            0,
            (ref != nullptr ? integer_field(*ref, "index", -1) : -1)
                + 1
        )
    );
}

std::string normalized_choice_type(const std::string &request_type) {
    if (
        request_type == "arven"
        || request_type == "clara"
        || request_type == "discard_cards"
        || request_type == "discard_then_draw"
        || request_type == "evolve_skip_stage"
        || request_type == "hand_bottom_draw"
        || request_type == "houb"
        || request_type == "look_top"
        || request_type == "look_top_attach_energy"
        || request_type == "resolve_empty"
        || request_type == "search"
        || request_type == "search_any_switch"
        || request_type == "search_deck"
        || request_type == "search_move"
        || request_type == "select"
        || request_type == "select_card"
        || request_type == "select_hand_to_discard"
        || request_type == "shuffle_from_discard"
        || request_type == "zinnia"
    ) return "select_card";
    if (
        request_type == "bench_damage_target"
        || request_type == "damage_target"
        || request_type == "place_counters_self_discard"
        || request_type == "select_bench"
        || request_type == "select_bench_targets"
        || request_type == "select_energy_source"
        || request_type == "select_energy_target"
        || request_type == "select_heal_target"
        || request_type == "select_opponent_bench"
        || request_type == "select_own_bench_energy"
        || request_type == "select_prize_energy_target"
    ) return "select_pokemon";
    if (
        request_type == "select_attachment"
        || request_type == "select_retreat_payment"
    ) return "select_attachment";
    if (
        request_type == "confirm"
        || request_type == "confirm_trigger"
    ) return "confirm";
    if (
        request_type == "choose_mulligan_draw_count"
        || request_type == "choose_turn_order"
    ) return "setup";
    if (request_type == "choose_trigger_order") return "order";
    return request_type;
}

std::string ref_card_id(
    const Value &cards,
    const Value *ref,
    const std::string &option_id = {}
) {
    if (ref != nullptr && ref->is_object()) {
        const std::string direct = string_field(*ref, "card_id");
        if (!direct.empty()) {
            return direct;
        }
    }
    const std::size_t separator = option_id.rfind(':');
    if (separator == std::string::npos) {
        return {};
    }
    const std::string candidate = option_id.substr(separator + 1);
    return cards.find(candidate) != nullptr ? candidate : std::string{};
}

} // namespace

NativeInformationSetEncoder::NativeInformationSetEncoder(Value cards)
    : cards_(std::move(cards)) {
    if (!cards_.is_object()) {
        throw std::invalid_argument("encoder_cards_must_be_object");
    }
}

void NativeInformationSetEncoder::set_cards(Value cards) {
    if (!cards.is_object()) {
        throw std::invalid_argument("encoder_cards_must_be_object");
    }
    cards_ = std::move(cards);
}

Value NativeInformationSetEncoder::build_observation(
    const Value &snapshot,
    std::int32_t actor
) const {
    // The normalized information-set snapshot already has the exact fields
    // required by the encoder; this method makes the accepted boundary explicit.
    Value observation = snapshot;
    observation["perspective"] = Value(actor);
    return observation;
}

InferenceRequest NativeInformationSetEncoder::encode_actions(
    const Value &observation,
    const Value &actions
) const {
    if (!actions.is_array() || actions.as_array().empty()) {
        throw std::invalid_argument("candidate_set_empty");
    }
    InferenceRequest result;
    encode_information_set(result, cards_, observation);
    const std::int32_t perspective = static_cast<std::int32_t>(
        integer_field(observation, "perspective", -1)
    );
    const Value &own = observation_player(observation, perspective);
    const Array &own_hand = required(own, "hand").as_array();
    std::size_t occupied = 0;
    std::size_t opponent_occupied = 0;
    for (std::int32_t player_index : {0, 1}) {
        const Value &owner = observation_player(
            observation,
            player_index
        );
        for (const std::string_view slot : TARGET_SLOTS) {
            if (pokemon_at(owner, std::string(slot)) != nullptr) {
                ++occupied;
                if (player_index != perspective) {
                    ++opponent_occupied;
                }
            }
        }
    }
    for (const Value &action : actions.as_array()) {
        if (!action.is_object()) {
            throw std::invalid_argument("invalid_action_candidate");
        }
        const std::string kind = string_field(
            action,
            "kind",
            string_field(action, "action")
        );
        const std::size_t action_index = enum_index(ACTION_TYPES, kind);
        if (action_index >= ACTION_TYPES.size()) {
            throw std::invalid_argument("unknown_action_type:" + kind);
        }
        const Value *payload = action.find("payload");
        if (payload == nullptr || !payload->is_object()) {
            payload = action.find("params");
        }
        static const Value empty_object = Value::make_object();
        if (payload == nullptr || !payload->is_object()) {
            payload = &empty_object;
        }
        const Value *source = action.find("source");
        const Value *target = action.find("target");
        const std::size_t base = result.candidate_numeric.size();
        result.candidate_numeric.resize(
            base + CANDIDATE_NUMERIC_SIZE,
            0.0F
        );
        result.candidate_numeric[base + action_index] = 1.0F;
        result.candidate_numeric[base + 11] = (
            kind == "DECLARE_ATTACK"
            || kind == "SETUP_DONE"
            || kind == "END_TURN"
        ) ? 1.0F : 0.0F;
        const std::int64_t action_actor = integer_field(
            action,
            "actor",
            -1
        );
        result.candidate_numeric[base + 12] = (
            action_actor < 0 || action_actor == perspective
        ) ? 1.0F : 0.0F;
        std::string slot = target != nullptr && target->is_object()
            ? string_field(*target, "slot")
            : std::string{};
        if (slot.empty()) {
            slot = string_field(
                *payload,
                "target_slot",
                string_field(
                    *payload,
                    "target",
                    string_field(*payload, "slot")
                )
            );
        }
        const std::size_t target_index = enum_index(
            TARGET_SLOTS,
            slot
        );
        if (target_index < TARGET_SLOTS.size()) {
            result.candidate_numeric[
                base + 13 + target_index
            ] = 1.0F;
        }
        std::int64_t hand_index = integer_field(
            *payload,
            "hand_idx",
            -1
        );
        if (
            hand_index < 0
            && source != nullptr
            && source->is_object()
            && string_field(*source, "zone") == "hand"
        ) {
            hand_index = integer_field(*source, "index", -1);
        }
        const std::int64_t attack_index = integer_field(
            *payload,
            "attack_index",
            integer_field(*payload, "attack_idx", -1)
        );
        std::int64_t bench_index = integer_field(
            *payload,
            "bench_idx",
            -1
        );
        if (
            bench_index < 0
            && slot.rfind("bench_", 0) == 0
            && slot.size() == 7
        ) {
            bench_index = slot[6] - '0';
        }
        const Value *energy_indices = payload->find("energy_indices");
        const std::size_t energy_count = (
            energy_indices != nullptr && energy_indices->is_array()
        ) ? energy_indices->as_array().size() : 0;
        result.candidate_numeric[base + 19] = normalized(
            hand_index >= 0 ? hand_index + 1 : 0,
            12.0
        );
        result.candidate_numeric[base + 20] = normalized(
            attack_index >= 0 ? attack_index + 1 : 0,
            4.0
        );
        result.candidate_numeric[base + 21] = normalized(
            bench_index >= 0 ? bench_index + 1 : 0,
            5.0
        );
        result.candidate_numeric[base + 22] = normalized(
            energy_count,
            6.0
        );
        result.candidate_numeric[base + 23] = normalized(
            occupied,
            12.0
        );
        result.candidate_numeric[base + 24] = normalized(
            opponent_occupied,
            6.0
        );
        std::string card_id = source != nullptr && source->is_object()
            ? string_field(*source, "card_id")
            : std::string{};
        if (
            card_id.empty()
            && hand_index >= 0
            && static_cast<std::size_t>(hand_index) < own_hand.size()
        ) {
            card_id = own_hand[
                static_cast<std::size_t>(hand_index)
            ].string_or();
        }
        write_semantics(
            cards_,
            card_id,
            result.candidate_numeric.data() + base + 25,
            CANDIDATE_NUMERIC_SIZE - 25
        );
        result.candidate_card_ids.push_back(
            card_index(cards_, card_id)
        );
        result.candidate_type_ids.push_back(
            static_cast<std::int64_t>(action_index + 1)
        );
        encode_candidate_ref(
            source,
            target,
            result.candidate_refs
        );
    }
    result.validate();
    return result;
}

InferenceRequest NativeInformationSetEncoder::encode_choices(
    const Value &observation,
    const Value &request,
    const Value &candidates
) const {
    if (!candidates.is_array() || candidates.as_array().empty()) {
        throw std::invalid_argument("candidate_set_empty");
    }
    InferenceRequest result;
    encode_information_set(result, cards_, observation);
    const std::int32_t perspective = static_cast<std::int32_t>(
        integer_field(observation, "perspective", -1)
    );
    const std::string request_type = normalized_choice_type(
        string_field(request, "request_type", "select")
    );
    const std::size_t choice_index = enum_index(
        CHOICE_TYPES,
        request_type
    );
    if (choice_index >= CHOICE_TYPES.size()) {
        throw std::invalid_argument(
            "unknown_choice_type:" + request_type
        );
    }
    for (
        std::size_t candidate_index = 0;
        candidate_index < candidates.as_array().size();
        ++candidate_index
    ) {
        const Value &candidate = candidates.as_array()[candidate_index];
        const Value *ref = candidate.find("ref");
        const std::string option_id = string_field(
            candidate,
            "signature"
        );
        const std::size_t base = result.candidate_numeric.size();
        result.candidate_numeric.resize(
            base + CANDIDATE_NUMERIC_SIZE,
            0.0F
        );
        result.candidate_numeric[base + choice_index] = 1.0F;
        result.candidate_numeric[base + 9] = normalized(
            candidate_index + 1,
            64.0
        );
        const std::string kind = ref != nullptr && ref->is_object()
            ? string_field(*ref, "kind")
            : std::string{};
        result.candidate_numeric[base + 10] =
            kind == "card" ? 1.0F : 0.0F;
        result.candidate_numeric[base + 11] =
            kind == "pokemon" ? 1.0F : 0.0F;
        result.candidate_numeric[base + 12] =
            kind == "attachment" ? 1.0F : 0.0F;
        result.candidate_numeric[base + 13] = (
            ref == nullptr
            || !ref->is_object()
            || integer_field(*ref, "player", perspective) == perspective
        ) ? 1.0F : 0.0F;
        const std::string slot = ref != nullptr && ref->is_object()
            ? string_field(*ref, "slot")
            : std::string{};
        const std::size_t target_index = enum_index(
            TARGET_SLOTS,
            slot
        );
        if (target_index < TARGET_SLOTS.size()) {
            result.candidate_numeric[
                base + 14 + target_index
            ] = 1.0F;
        }
        const std::string card_id = ref_card_id(
            cards_,
            ref,
            option_id
        );
        write_semantics(
            cards_,
            card_id,
            result.candidate_numeric.data() + base + 20,
            CANDIDATE_NUMERIC_SIZE - 20
        );
        result.candidate_card_ids.push_back(
            card_index(cards_, card_id)
        );
        result.candidate_type_ids.push_back(
            static_cast<std::int64_t>(
                ACTION_TYPES.size() + choice_index + 1
            )
        );
        encode_candidate_ref(ref, nullptr, result.candidate_refs);
    }
    result.validate();
    return result;
}

} // namespace ptcg::ai
