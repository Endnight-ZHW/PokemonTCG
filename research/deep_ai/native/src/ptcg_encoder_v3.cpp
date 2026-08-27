#include "ptcg_encoder_v3.hpp"

#include "ptcg_infoset.hpp"

#include <algorithm>
#include <array>
#include <initializer_list>
#include <map>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <tuple>
#include <vector>

namespace ptcg::ai {

namespace {

using Array = Value::Array;

constexpr std::array<std::string_view, 6> PHASES{
    "SETUP", "DRAW", "MAIN", "ATTACK", "POKEMON_CHECKUP", "GAME_OVER",
};
constexpr std::array<std::string_view, 5> SETUP_STAGES{
    "TURN_ORDER", "INITIAL_PLACEMENT", "BONUS_DRAW",
    "BONUS_PLACEMENT", "COMPLETE",
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
constexpr std::array<std::string_view, 5> STATUS_NAMES{
    "POISONED", "BURNED", "ASLEEP", "PARALYZED", "CONFUSED",
};

const Value &required(const Value &value, const std::string &key) {
    const Value *found = value.find(key);
    if (found == nullptr) {
        throw std::invalid_argument("v3_encoder_missing_field:" + key);
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

std::int64_t deck_index(const std::string &key) noexcept {
    return static_cast<std::int64_t>(enum_index(DECK_KEYS, key, 0));
}

std::int64_t zone_id(const std::string &zone) noexcept {
    if (zone == "active") return 1;
    if (zone == "bench") return 2;
    if (zone == "hand") return 3;
    if (zone == "discard") return 4;
    if (zone == "stadium") return 5;
    if (zone == "energy") return 6;
    if (zone == "tool") return 7;
    if (zone == "evolution") return 8;
    return 0;
}

std::int64_t slot_id(const std::string &slot) noexcept {
    if (slot == "active") return 1;
    if (slot.rfind("bench_", 0) == 0 && slot.size() == 7) {
        const char value = slot[6];
        if (value >= '0' && value <= '4') {
            return static_cast<std::int64_t>(value - '0' + 2);
        }
    }
    return 0;
}

std::int64_t card_index(
    const Value &cards,
    const std::string &card_id
) noexcept {
    if (card_id.empty() || card_id.rfind("__hidden_", 0) == 0) {
        return 0;
    }
    const Value *card = cards.find(card_id);
    return card == nullptr ? 1 : integer_field(*card, "ai_card_index", 1);
}

const Value &player(const Value &observation, std::int32_t index) {
    const Value &players = required(observation, "players");
    if (!players.is_array() || players.as_array().size() != 2) {
        throw std::invalid_argument("v3_encoder_invalid_players");
    }
    return players.as_array().at(static_cast<std::size_t>(index));
}

const Value *pokemon_at(const Value &owner, const std::string &slot) {
    if (slot == "active") {
        const Value *active = owner.find("active");
        return active != nullptr && active->is_object() ? active : nullptr;
    }
    if (slot.rfind("bench_", 0) != 0 || slot.size() != 7) {
        return nullptr;
    }
    const Value *bench = owner.find("bench");
    const std::size_t index = static_cast<std::size_t>(slot[6] - '0');
    if (
        bench == nullptr || !bench->is_array()
        || index >= bench->as_array().size()
        || !bench->as_array()[index].is_object()
    ) {
        return nullptr;
    }
    return &bench->as_array()[index];
}

std::size_t array_size(const Value &value, const std::string &key) noexcept {
    const Value *found = value.find(key);
    return found != nullptr && found->is_array()
        ? found->as_array().size() : 0;
}

bool array_contains(const Value *values, const std::string &needle) {
    return values != nullptr && values->is_array()
        && std::any_of(
            values->as_array().begin(),
            values->as_array().end(),
            [&needle](const Value &value) {
                return value.string_or() == needle;
            }
        );
}

void reject_hidden_identity_leaks(
    const Value &owner,
    const std::initializer_list<const char *> zones
) {
    for (const char *zone : zones) {
        const Value *values = owner.find(zone);
        if (values == nullptr || !values->is_array()) continue;
        for (const Value &value : values->as_array()) {
            const std::string card_id = value.string_or();
            if (
                !card_id.empty()
                && card_id != "__hidden_card__"
                && card_id != "__hidden_prize__"
            ) {
                throw std::invalid_argument(
                    "v3_hidden_identity_exposed:" + std::string(zone)
                );
            }
        }
    }
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
    if (index >= result.spec.entity_slots) {
        throw std::invalid_argument("v3_entity_overflow");
    }
    result.entity_mask[index] = 1;
    result.entity_card_ids[index] = card_index(cards, card_id);
    const std::size_t type_base = index * result.spec.entity_type_fields;
    result.entity_type_ids[type_base] = token_type;
    result.entity_type_ids[type_base + 1] = owner;
    result.entity_type_ids[type_base + 2] = zone_id(zone);
    result.entity_type_ids[type_base + 3] = slot_id(slot);
    const std::size_t numeric_base = index * result.spec.entity_numeric_size;
    std::copy_n(
        values.begin(),
        std::min(values.size(), result.spec.entity_numeric_size),
        result.entity_numeric.begin()
            + static_cast<std::ptrdiff_t>(numeric_base)
    );
}

using GroupKey = std::tuple<
    std::int64_t,
    std::string,
    std::string,
    std::int64_t,
    std::string
>;

void add_group(
    std::map<GroupKey, std::size_t> &groups,
    std::int64_t owner,
    const std::string &zone,
    const std::string &slot,
    std::int64_t token_type,
    const std::string &card_id
) {
    if (!card_id.empty() && card_id.rfind("__hidden_", 0) != 0) {
        ++groups[{owner, zone, slot, token_type, card_id}];
    }
}

void add_array_groups(
    std::map<GroupKey, std::size_t> &groups,
    const Value *values,
    std::int64_t owner,
    const std::string &zone,
    const std::string &slot,
    std::int64_t token_type
) {
    if (values == nullptr || !values->is_array()) return;
    for (const Value &value : values->as_array()) {
        add_group(
            groups, owner, zone, slot, token_type, value.string_or()
        );
    }
}

void encode_information_set(
    InferenceRequest &result,
    const Value &cards,
    const Value &observation,
    const Value *request
) {
    const std::int32_t perspective = static_cast<std::int32_t>(
        integer_field(observation, "perspective", -1)
    );
    if (perspective != 0 && perspective != 1) {
        throw std::invalid_argument("v3_encoder_invalid_perspective");
    }
    const std::size_t phase = enum_index(
        PHASES,
        string_field(observation, "phase")
    );
    if (phase < PHASES.size()) result.state_global[phase] = 1.0F;
    const Value &own = player(observation, perspective);
    const Value &opponent = player(observation, 1 - perspective);
    reject_hidden_identity_leaks(own, {"deck", "prizes"});
    reject_hidden_identity_leaks(
        opponent, {"deck", "hand", "prizes"}
    );
    const std::array<float, 15> scalars{
        integer_field(observation, "active_player_idx", -1) == perspective ? 1.0F : 0.0F,
        integer_field(observation, "first_player_idx", -1) == perspective ? 1.0F : 0.0F,
        normalized(integer_field(observation, "turn_number"), 30.0),
        boolean_field(observation, "apply_type_matchups") ? 1.0F : 0.0F,
        integer_field(observation, "winner", -1) == perspective ? 1.0F : 0.0F,
        integer_field(observation, "winner", -1) == 1 - perspective ? 1.0F : 0.0F,
        normalized(array_size(own, "hand"), 20.0),
        normalized(array_size(own, "discard"), 60.0),
        normalized(array_size(own, "deck"), 60.0),
        normalized(array_size(own, "prizes"), 6.0),
        normalized(array_size(opponent, "hand"), 20.0),
        normalized(array_size(opponent, "discard"), 60.0),
        normalized(array_size(opponent, "deck"), 60.0),
        normalized(array_size(opponent, "prizes"), 6.0),
        static_cast<float>(integer_field(observation, "revision") % 2),
    };
    std::copy(scalars.begin(), scalars.end(), result.state_global.begin() + 16);
    const Value *keys = observation.find("public_deck_keys");
    std::string own_key;
    std::string opponent_key;
    if (keys != nullptr && keys->is_array() && keys->as_array().size() == 2) {
        own_key = keys->as_array()[static_cast<std::size_t>(perspective)].string_or();
        opponent_key = keys->as_array()[static_cast<std::size_t>(1 - perspective)].string_or();
    }
    result.actor_deck_id = deck_index(own_key);
    result.opponent_deck_id = deck_index(opponent_key);
    result.state_global[32 + static_cast<std::size_t>(result.actor_deck_id)] = 1.0F;
    result.state_global[42 + static_cast<std::size_t>(result.opponent_deck_id)] = 1.0F;
    const std::size_t setup = enum_index(
        SETUP_STAGES,
        string_field(observation, "setup_stage")
    );
    if (setup < SETUP_STAGES.size()) result.state_global[52 + setup] = 1.0F;
    std::size_t cursor = 64;
    for (const Value *owner : {&own, &opponent}) {
        for (const char *flag : {
            "supporter_played_this_turn", "energy_attached_this_turn",
            "retreated_this_turn", "stadium_played_this_turn",
            "stadium_used_this_turn", "healed_this_turn",
            "vstar_power_used", "was_ko_by_attack",
        }) {
            result.state_global[cursor++] = boolean_field(*owner, flag) ? 1.0F : 0.0F;
        }
    }
    result.state_global[80] = normalized(
        array_size(observation, "pending_promotions"), 2.0
    );
    const Value *facts = observation.find("turn_fact_book");
    if (facts != nullptr && facts->is_object()) {
        for (std::size_t offset = 0; offset < 2; ++offset) {
            const Value *window = facts->find(
                offset == 0 ? "previous_turn" : "current_turn"
            );
            result.state_global[81 + offset] = window != nullptr
                ? normalized(array_size(*window, "knockouts"), 6.0) : 0.0F;
        }
    }
    if (request != nullptr && request->is_object()) {
        std::string request_type = string_field(*request, "request_type");
        if (request_type == "choose_mulligan_draw_count" || request_type == "choose_turn_order") request_type = "setup";
        else if (request_type == "confirm_trigger") request_type = "confirm";
        else if (request_type == "select_retreat_payment") request_type = "select_attachment";
        else if (request_type == "choose_trigger_order") request_type = "order";
        else if (request_type == "select_prize_energy_target") request_type = "select_pokemon";
        const std::size_t type = enum_index(CHOICE_TYPES, request_type);
        if (type < CHOICE_TYPES.size()) result.state_global[96 + type] = 1.0F;
        result.state_global[112] = normalized(integer_field(*request, "min_select"), 60.0);
        result.state_global[113] = normalized(integer_field(*request, "max_select"), 60.0);
        result.state_global[114] = boolean_field(*request, "allow_duplicates") ? 1.0F : 0.0F;
        result.state_global[115] = boolean_field(*request, "can_cancel") ? 1.0F : 0.0F;
        result.state_global[116] = normalized(array_size(*request, "options"), 256.0);
    }

    std::size_t entity = 0;
    std::map<GroupKey, std::size_t> groups;
    for (const std::int32_t player_index : {perspective, 1 - perspective}) {
        const Value &owner = player(observation, player_index);
        const std::int64_t owner_id = player_index == perspective ? 1 : 2;
        for (const std::string_view slot_view : TARGET_SLOTS) {
            const std::string slot(slot_view);
            const Value *pokemon = pokemon_at(owner, slot);
            const std::string card_id = pokemon != nullptr
                ? string_field(*pokemon, "card_id") : std::string{};
            const Value *energies = pokemon != nullptr
                ? pokemon->find("energy_card_ids") : nullptr;
            const Value *statuses = pokemon != nullptr
                ? pokemon->find("status_conditions") : nullptr;
            const std::vector<float> values{
                card_id.empty() ? 0.0F : 1.0F,
                1.0F,
                slot == "active" ? 1.0F : 0.0F,
                normalized(pokemon != nullptr ? integer_field(*pokemon, "damage_counters") : 0, 30.0),
                normalized(energies != nullptr && energies->is_array() ? energies->as_array().size() : 0, 12.0),
                pokemon != nullptr && !string_field(*pokemon, "attached_tool_id").empty() ? 1.0F : 0.0F,
                array_contains(statuses, "POISONED") ? 1.0F : 0.0F,
                array_contains(statuses, "BURNED") ? 1.0F : 0.0F,
                array_contains(statuses, "ASLEEP") ? 1.0F : 0.0F,
                array_contains(statuses, "PARALYZED") ? 1.0F : 0.0F,
                array_contains(statuses, "CONFUSED") ? 1.0F : 0.0F,
                pokemon != nullptr && boolean_field(*pokemon, "can_evolve_this_turn") ? 1.0F : 0.0F,
                pokemon != nullptr && boolean_field(*pokemon, "placed_this_turn") ? 1.0F : 0.0F,
                normalized(pokemon != nullptr ? array_size(*pokemon, "used_abilities") : 0, 4.0),
                pokemon != nullptr && boolean_field(*pokemon, "damage_prevented") ? 1.0F : 0.0F,
                pokemon != nullptr && boolean_field(*pokemon, "all_prevented") ? 1.0F : 0.0F,
                normalized(pokemon != nullptr ? integer_field(*pokemon, "outgoing_damage_reduction") : 0, 300.0),
                pokemon != nullptr && boolean_field(*pokemon, "attack_locked") ? 1.0F : 0.0F,
                pokemon != nullptr && boolean_field(*pokemon, "dazzled") ? 1.0F : 0.0F,
                pokemon != nullptr && boolean_field(*pokemon, "healed_this_turn") ? 1.0F : 0.0F,
                normalized(pokemon != nullptr ? integer_field(*pokemon, "paralyzed_since_turn") : 0, 30.0),
                normalized(pokemon != nullptr ? array_size(*pokemon, "modifiers") : 0, 8.0),
                normalized(pokemon != nullptr ? array_size(*pokemon, "max_hp_modifiers") : 0, 8.0),
            };
            set_entity(
                result, cards, entity++, card_id, 1, owner_id,
                slot == "active" ? "active" : "bench", slot, values
            );
            if (pokemon != nullptr) {
                add_array_groups(groups, energies, owner_id, "energy", slot, 2);
                add_array_groups(groups, pokemon->find("evolution_stack_ids"), owner_id, "evolution", slot, 8);
                add_group(groups, owner_id, "tool", slot, 3, string_field(*pokemon, "attached_tool_id"));
            }
        }
        if (player_index == perspective) {
            add_array_groups(groups, owner.find("hand"), owner_id, "hand", "", 4);
        }
        add_array_groups(
            groups, owner.find("discard"), owner_id, "discard", "",
            owner_id == 1 ? 5 : 6
        );
    }
    add_group(
        groups, 0, "stadium", "", 7,
        string_field(observation, "stadium_card_id")
    );
    if (entity + groups.size() > result.spec.entity_slots) {
        throw std::invalid_argument(
            "v3_entity_overflow:required="
            + std::to_string(entity + groups.size())
            + ":limit=" + std::to_string(result.spec.entity_slots)
        );
    }
    for (const auto &[key, count] : groups) {
        const auto &[owner, zone, slot, token_type, card_id] = key;
        set_entity(
            result, cards, entity++, card_id, token_type, owner,
            zone, slot,
            {1.0F, normalized(count, 60.0), normalized(count, 4.0)}
        );
    }
}

void encode_ref(
    const Value *ref,
    std::vector<std::int64_t> &target,
    std::size_t offset
) {
    if (ref == nullptr || !ref->is_object()) return;
    const std::int64_t owner = integer_field(*ref, "player", -1);
    target[offset] = owner >= -1 && owner <= 1 ? owner + 2 : 0;
    target[offset + 1] = zone_id(string_field(*ref, "zone"));
    target[offset + 2] = slot_id(string_field(*ref, "slot"));
    target[offset + 3] = std::max<std::int64_t>(
        0,
        integer_field(*ref, "index", -1) + 1
    );
}

std::string normalized_choice_type(std::string value) {
    if (value == "choose_mulligan_draw_count" || value == "choose_turn_order") return "setup";
    if (value == "confirm_trigger") return "confirm";
    if (value == "select_retreat_payment") return "select_attachment";
    if (value == "choose_trigger_order") return "order";
    if (value == "select_prize_energy_target") return "select_pokemon";
    const std::size_t index = enum_index(CHOICE_TYPES, value);
    return index < CHOICE_TYPES.size() ? value : "select_card";
}

const Value *option_by_id(const Value &request, const std::string &id) {
    const Value *options = request.find("options");
    if (options == nullptr || !options->is_array()) return nullptr;
    const auto found = std::find_if(
        options->as_array().begin(),
        options->as_array().end(),
        [&id](const Value &row) {
            return string_field(row, "option_id") == id;
        }
    );
    return found == options->as_array().end() ? nullptr : &*found;
}

std::optional<std::pair<std::int64_t, std::string>>
energy_option_identity(const std::string &option_id) {
    constexpr std::string_view prefix{"energy:"};
    if (option_id.rfind(prefix.data(), 0) != 0) return std::nullopt;
    const std::size_t index_end = option_id.find(':', prefix.size());
    const std::size_t identity_end = option_id.find("->", index_end);
    if (
        index_end == std::string::npos
        || identity_end == std::string::npos
        || identity_end <= index_end + 1
    ) {
        return std::nullopt;
    }
    try {
        std::size_t consumed = 0;
        const std::string raw = option_id.substr(
            prefix.size(), index_end - prefix.size()
        );
        const std::int64_t index = std::stoll(raw, &consumed);
        const std::string card_id = option_id.substr(
            index_end + 1, identity_end - index_end - 1
        );
        if (consumed != raw.size() || index < 0 || card_id.empty()) {
            return std::nullopt;
        }
        return std::pair{index, card_id};
    } catch (const std::exception &) {
        return std::nullopt;
    }
}

} // namespace

NativeInformationSetEncoderV3::NativeInformationSetEncoderV3(Value cards) :
    cards_(std::move(cards)) {}

void NativeInformationSetEncoderV3::set_cards(Value cards) {
    cards_ = std::move(cards);
}

Value NativeInformationSetEncoderV3::build_observation(
    const Value &snapshot,
    std::int32_t actor
) const {
    return project_information_set(snapshot, actor).observation;
}

InferenceRequest NativeInformationSetEncoderV3::encode_actions(
    const Value &observation,
    const Value &actions
) const {
    if (!actions.is_array() || actions.as_array().empty()) {
        throw std::invalid_argument("candidate_set_empty");
    }
    InferenceRequest result(InferenceTensorSpec::v3());
    encode_information_set(result, cards_, observation, nullptr);
    const std::int32_t perspective = static_cast<std::int32_t>(
        integer_field(observation, "perspective", -1)
    );
    for (std::size_t index = 0; index < actions.as_array().size(); ++index) {
        const Value &action = actions.as_array()[index];
        const std::string kind = string_field(action, "kind");
        const std::size_t type = enum_index(ACTION_TYPES, kind);
        if (type >= ACTION_TYPES.size()) {
            throw std::invalid_argument("unknown_v3_action_type:" + kind);
        }
        const Value *source = action.find("source");
        const Value *target = action.find("target");
        const Value *payload = action.find("payload");
        static const Value empty = Value::make_object();
        if (payload == nullptr || !payload->is_object()) payload = &empty;
        const std::size_t base = result.candidate_numeric.size();
        result.candidate_numeric.resize(
            base + result.spec.candidate_numeric_size,
            0.0F
        );
        result.candidate_numeric[base + 2] = (
            kind == "DECLARE_ATTACK" || kind == "SETUP_DONE" || kind == "END_TURN"
        ) ? 1.0F : 0.0F;
        result.candidate_numeric[base + 3] = (
            integer_field(action, "actor", perspective) == perspective
        ) ? 1.0F : 0.0F;
        const std::int64_t source_index = source != nullptr && source->is_object()
            ? integer_field(*source, "index", -1) : -1;
        result.candidate_numeric[base + 4] = normalized(
            integer_field(*payload, "hand_idx", source_index) + 1, 60.0
        );
        result.candidate_numeric[base + 5] = normalized(
            integer_field(*payload, "attack_index", integer_field(*payload, "attack_idx", -1)) + 1,
            4.0
        );
        result.candidate_numeric[base + 6] = normalized(
            integer_field(*payload, "ability_index", -1) + 1,
            8.0
        );
        result.candidate_numeric[base + 8] = normalized(
            array_size(*payload, "energy_indices"), 12.0
        );
        result.candidate_numeric[base + 9] = normalized(
            integer_field(*payload, "amount", integer_field(*payload, "count")), 60.0
        );
        result.candidate_numeric[base + 10] = normalized(index + 1, 256.0);
        result.candidate_numeric[base + 11] = source != nullptr && source->is_object() ? 1.0F : 0.0F;
        result.candidate_numeric[base + 12] = target != nullptr && target->is_object() ? 1.0F : 0.0F;
        result.candidate_numeric[base + 13] = source != nullptr && source->is_object()
            && integer_field(*source, "player", -1) == perspective ? 1.0F : 0.0F;
        result.candidate_numeric[base + 14] = target != nullptr && target->is_object()
            && integer_field(*target, "player", -1) == perspective ? 1.0F : 0.0F;
        const std::string card_id = source != nullptr && source->is_object()
            ? string_field(*source, "card_id")
            : target != nullptr && target->is_object()
                ? string_field(*target, "card_id") : std::string{};
        result.candidate_card_ids.push_back(card_index(cards_, card_id));
        result.candidate_type_ids.push_back(static_cast<std::int64_t>(type + 1));
        const std::size_t ref_base = result.candidate_refs.size();
        result.candidate_refs.resize(
            ref_base + result.spec.candidate_ref_fields,
            0
        );
        encode_ref(source, result.candidate_refs, ref_base);
        encode_ref(target, result.candidate_refs, ref_base + 4);
    }
    result.validate();
    return result;
}

InferenceRequest NativeInformationSetEncoderV3::encode_choices(
    const Value &observation,
    const Value &request,
    const Value &candidates
) const {
    if (!candidates.is_array() || candidates.as_array().empty()) {
        throw std::invalid_argument("candidate_set_empty");
    }
    InferenceRequest result(InferenceTensorSpec::v3());
    encode_information_set(result, cards_, observation, &request);
    const std::int32_t perspective = static_cast<std::int32_t>(
        integer_field(observation, "perspective", -1)
    );
    const std::string request_type = normalized_choice_type(
        string_field(request, "request_type")
    );
    const std::size_t type = enum_index(CHOICE_TYPES, request_type);
    for (std::size_t index = 0; index < candidates.as_array().size(); ++index) {
        const Value &candidate = candidates.as_array()[index];
        const Value *selected = candidate.find("selected_options");
        const Value *source = nullptr;
        const Value *target = nullptr;
        Value energy_source;
        if (selected != nullptr && selected->is_array() && !selected->as_array().empty()) {
            source = option_by_id(request, selected->as_array()[0].string_or());
            if (source != nullptr && source->find("ref") != nullptr) source = source->find("ref");
            if (selected->as_array().size() > 1) {
                target = option_by_id(request, selected->as_array()[1].string_or());
                if (target != nullptr && target->find("ref") != nullptr) target = target->find("ref");
            }
            if (request_type == "distribute_energy") {
                const Value *first = option_by_id(
                    request, selected->as_array()[0].string_or()
                );
                const auto identity = energy_option_identity(
                    selected->as_array()[0].string_or()
                );
                if (first != nullptr && identity.has_value()) {
                    target = first->find("ref") != nullptr
                        ? first->find("ref") : first;
                    const Value *presentation = request.find("presentation");
                    if (presentation == nullptr || !presentation->is_object()) {
                        presentation = request.find("metadata");
                    }
                    energy_source = Value(Value::Object{
                        {"kind", Value("card")},
                        {"player", Value(integer_field(
                            request, "player", perspective
                        ))},
                        {"zone", Value(
                            presentation != nullptr
                                ? string_field(*presentation, "source_zone")
                                : std::string{}
                        )},
                        {"index", Value(identity->first)},
                        {"card_id", Value(identity->second)},
                    });
                    source = &energy_source;
                }
            }
        }
        const std::size_t base = result.candidate_numeric.size();
        result.candidate_numeric.resize(
            base + result.spec.candidate_numeric_size,
            0.0F
        );
        result.candidate_numeric[base] = 1.0F;
        result.candidate_numeric[base + 1] = boolean_field(candidate, "cancelled") ? 1.0F : 0.0F;
        result.candidate_numeric[base + 3] = 1.0F;
        result.candidate_numeric[base + 7] = normalized(
            selected != nullptr && selected->is_array() ? selected->as_array().size() : 0,
            60.0
        );
        result.candidate_numeric[base + 10] = normalized(index + 1, 256.0);
        result.candidate_numeric[base + 11] = source != nullptr && source->is_object() ? 1.0F : 0.0F;
        result.candidate_numeric[base + 12] = target != nullptr && target->is_object() ? 1.0F : 0.0F;
        result.candidate_numeric[base + 13] = source != nullptr && source->is_object()
            && integer_field(*source, "player", -1) == perspective ? 1.0F : 0.0F;
        result.candidate_numeric[base + 14] = target != nullptr && target->is_object()
            && integer_field(*target, "player", -1) == perspective ? 1.0F : 0.0F;
        result.candidate_numeric[base + 15] = normalized(integer_field(request, "min_select"), 60.0);
        result.candidate_numeric[base + 16] = normalized(integer_field(request, "max_select"), 60.0);
        result.candidate_numeric[base + 17] = boolean_field(request, "allow_duplicates") ? 1.0F : 0.0F;
        const std::string card_id = source != nullptr && source->is_object()
            ? string_field(*source, "card_id")
            : target != nullptr && target->is_object()
                ? string_field(*target, "card_id") : std::string{};
        result.candidate_card_ids.push_back(card_index(cards_, card_id));
        result.candidate_type_ids.push_back(static_cast<std::int64_t>(
            ACTION_TYPES.size() + type + 1
        ));
        const std::size_t ref_base = result.candidate_refs.size();
        result.candidate_refs.resize(
            ref_base + result.spec.candidate_ref_fields,
            0
        );
        encode_ref(source, result.candidate_refs, ref_base);
        encode_ref(target, result.candidate_refs, ref_base + 4);
    }
    result.validate();
    return result;
}

} // namespace ptcg::ai
