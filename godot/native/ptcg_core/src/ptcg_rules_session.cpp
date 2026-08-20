#include "ptcg_rules_session.hpp"

#include "ptcg_random.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <functional>
#include <iomanip>
#include <limits>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <unordered_set>
#include <utility>

namespace ptcg::ai {

namespace {

using Array = Value::Array;
using Object = Value::Object;

const Value *field(const Value &value, const std::string &key) {
    return value.is_object() ? value.find(key) : nullptr;
}

std::string string_field(
    const Value &value,
    const std::string &key,
    std::string fallback = {}
) {
    const Value *entry = field(value, key);
    return entry == nullptr ? std::move(fallback) : entry->string_or(
        std::move(fallback));
}

std::int64_t integer_field(
    const Value &value,
    const std::string &key,
    std::int64_t fallback = 0
) {
    const Value *entry = field(value, key);
    return entry == nullptr ? fallback : entry->as_integer(fallback);
}

bool bool_field(
    const Value &value,
    const std::string &key,
    bool fallback = false
) {
    const Value *entry = field(value, key);
    return entry == nullptr ? fallback : entry->as_bool(fallback);
}

Value &required(Value &value, const std::string &key) {
    Value *entry = value.find(key);
    if (entry == nullptr) {
        throw std::invalid_argument("missing_field:" + key);
    }
    return *entry;
}

const Value &required(const Value &value, const std::string &key) {
    const Value *entry = value.find(key);
    if (entry == nullptr) {
        throw std::invalid_argument("missing_field:" + key);
    }
    return *entry;
}

Value &player(Value &state, std::int32_t actor) {
    if (actor < 0 || actor > 1) {
        throw std::invalid_argument("invalid_actor");
    }
    return required(state, "players").as_array().at(
        static_cast<std::size_t>(actor));
}

const Value &player(const Value &state, std::int32_t actor) {
    if (actor < 0 || actor > 1) {
        throw std::invalid_argument("invalid_actor");
    }
    return required(state, "players").as_array().at(
        static_cast<std::size_t>(actor));
}

bool array_contains_string(const Value *value, const std::string &needle) {
    if (value == nullptr || !value->is_array()) {
        return false;
    }
    return std::any_of(
        value->as_array().begin(),
        value->as_array().end(),
        [&needle](const Value &entry) {
            return entry.string_or() == needle;
        }
    );
}

bool is_basic_pokemon(const Value &cards, const std::string &card_id) {
    const Value *card = cards.find(card_id);
    if (card == nullptr || !card->is_object()) {
        return false;
    }
    const bool pokemon = integer_field(*card, "hp") > 0
        && string_field(*card, "supertype") != "Energy"
        && string_field(*card, "supertype") != "Trainer";
    return pokemon && array_contains_string(card->find("subtypes"), "Basic");
}

bool hand_has_basic(const Value &cards, const Value &owner) {
    const Value *hand = owner.find("hand");
    if (hand == nullptr || !hand->is_array()) {
        return false;
    }
    return std::any_of(
        hand->as_array().begin(),
        hand->as_array().end(),
        [&cards](const Value &entry) {
            return is_basic_pokemon(cards, entry.string_or());
        }
    );
}

bool is_hex_digest(const std::string &value) {
    return value.size() == 64 && std::all_of(
        value.begin(), value.end(), [](const unsigned char character) {
            return std::isdigit(character)
                || (character >= 'a' && character <= 'f');
        });
}

struct CatalogPayload {
    Value cards = Value::make_object();
    std::string content_fingerprint;
    std::string contract_fingerprint;
    std::string descriptor_digest;
};

Value *named_card_block(Value &card, const char *field_name,
                        const std::string &name) {
    Value *blocks = card.find(field_name);
    if (blocks == nullptr || !blocks->is_array()) {
        return nullptr;
    }
    for (Value &block : blocks->as_array()) {
        if (block.is_object() && string_field(block, "name") == name) {
            return &block;
        }
    }
    return nullptr;
}

void apply_ir_blocks(
    Value &card,
    const Value &ir_card,
    const char *field_name,
    const char *ir_field_name
) {
    Value *blocks = card.find(field_name);
    const Value *ir_blocks = ir_card.find(ir_field_name);
    if (
        blocks == nullptr || !blocks->is_array()
        || ir_blocks == nullptr || !ir_blocks->is_object()
    ) {
        throw std::invalid_argument("invalid_card_ir_blocks");
    }
    for (Value &block : blocks->as_array()) {
        if (!block.is_object() || string_field(block, "name").empty()) {
            throw std::invalid_argument("invalid_card_definition_block");
        }
        block["compiled_effects"] = Value::make_array();
    }
    for (const auto &[name, ir_block] : ir_blocks->as_object()) {
        const Value *commands = ir_block.is_object()
            ? ir_block.find("commands") : nullptr;
        Value *target = named_card_block(card, field_name, name);
        if (commands == nullptr || !commands->is_array() || target == nullptr) {
            throw std::invalid_argument("card_ir_block_not_found");
        }
        (*target)["compiled_effects"] = commands->deep_clone();
    }
}

CatalogPayload normalize_catalog(const Value &catalog) {
    if (!catalog.is_object() || catalog.as_object().empty()) {
        throw std::invalid_argument("card_catalog_missing");
    }
    const Value *envelope_cards = catalog.find("cards");
    const Value *card_ir = catalog.find("card_ir");
    if (envelope_cards == nullptr && card_ir == nullptr) {
        return CatalogPayload{catalog.deep_clone(), {}, {}, {}};
    }
    if (
        catalog.as_object().size() != 2
        || envelope_cards == nullptr || !envelope_cards->is_object()
        || envelope_cards->as_object().empty()
        || card_ir == nullptr || !card_ir->is_object()
        || string_field(*card_ir, "format") != "ptcg_card_ir/3"
    ) {
        throw std::invalid_argument("invalid_card_ir_envelope");
    }
    const Value *vm_version = card_ir->find("vm_ir_version");
    const Value *card_count = card_ir->find("card_count");
    const Value *ir_cards = card_ir->find("cards");
    const std::string content_fingerprint = string_field(
        *card_ir, "content_fingerprint");
    const std::string contract_fingerprint = string_field(
        *card_ir, "contract_fingerprint");
    const std::string descriptor_digest = string_field(
        *card_ir, "descriptor_digest");
    if (
        vm_version == nullptr || !vm_version->is_number()
        || vm_version->as_number() != 3.0
        || card_count == nullptr || !card_count->is_number()
        || card_count->as_number()
            != static_cast<double>(card_count->as_integer())
        || card_count->as_integer() != static_cast<std::int64_t>(
            envelope_cards->as_object().size())
        || ir_cards == nullptr || !ir_cards->is_object()
        || ir_cards->as_object().size() != envelope_cards->as_object().size()
        || !is_hex_digest(content_fingerprint)
        || !is_hex_digest(contract_fingerprint)
        || !is_hex_digest(descriptor_digest)
    ) {
        throw std::invalid_argument("invalid_card_ir_contract");
    }

    Value normalized_cards = envelope_cards->deep_clone();
    for (auto &[card_id, card] : normalized_cards.as_object()) {
        const Value *ir_card = ir_cards->find(card_id);
        if (!card.is_object() || ir_card == nullptr || !ir_card->is_object()) {
            throw std::invalid_argument("card_ir_catalog_mismatch");
        }
        apply_ir_blocks(card, *ir_card, "attacks", "attacks");
        apply_ir_blocks(card, *ir_card, "abilities", "abilities");
        const Value *trainer_commands = ir_card->find("trainer_commands");
        const Value *energy_effects = ir_card->find("energy_effects");
        if (
            trainer_commands == nullptr || !trainer_commands->is_array()
            || energy_effects == nullptr || !energy_effects->is_array()
        ) {
            throw std::invalid_argument("invalid_card_ir_card");
        }
        card["compiled_trainer_effects"] = trainer_commands->deep_clone();
        card["energy_effects"] = energy_effects->deep_clone();
    }
    return CatalogPayload{
        std::move(normalized_cards),
        content_fingerprint,
        contract_fingerprint,
        descriptor_digest,
    };
}

void shuffle(Array &values, XorShift32 &rng) {
    if (values.size() < 2) {
        return;
    }
    for (std::size_t index = values.size() - 1; index > 0; --index) {
        const std::size_t selected = static_cast<std::size_t>(
            rng.next_u32() % static_cast<std::uint32_t>(index + 1));
        std::swap(values[index], values[selected]);
    }
}

Array draw_cards(Value &owner, std::size_t count) {
    Array drawn;
    Array &deck = required(owner, "deck").as_array();
    Array &hand = required(owner, "hand").as_array();
    drawn.reserve(std::min(count, deck.size()));
    for (std::size_t index = 0; index < count && !deck.empty(); ++index) {
        drawn.push_back(deck.back());
        hand.push_back(deck.back());
        deck.pop_back();
    }
    return drawn;
}

Value empty_player(std::string name, Array deck) {
    return Value(Object{
        {"name", Value(std::move(name))},
        {"deck", Value(std::move(deck))},
        {"hand", Value::make_array()},
        {"discard", Value::make_array()},
        {"prizes", Value::make_array()},
        {"active", Value()},
        {"bench", Value(Array{Value(), Value(), Value(), Value(), Value()})},
        {"supporter_played_this_turn", Value(false)},
        {"energy_attached_this_turn", Value(false)},
        {"retreated_this_turn", Value(false)},
        {"stadium_played_this_turn", Value(false)},
        {"stadium_used_this_turn", Value(false)},
        {"healed_this_turn", Value(false)},
        {"vstar_power_used", Value(false)},
        {"was_ko_by_attack", Value(false)},
    });
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

Value event(
    std::string type,
    std::int32_t actor = -1,
    Value data = Value::make_object(),
    std::string visibility = {}
) {
    Object result{
        {"event_type", Value(std::move(type))},
        {"data", std::move(data)},
    };
    if (actor >= 0) {
        result["actor"] = Value(actor);
    }
    if (!visibility.empty()) {
        result["visibility"] = Value(std::move(visibility));
    }
    return Value(std::move(result));
}

const Value *state_pokemon(
    const Value &state,
    std::int32_t owner,
    const std::string &slot
) {
    if (owner < 0 || owner > 1 || slot.empty()) {
        return nullptr;
    }
    const Value &owner_value = player(state, owner);
    if (slot == "active") {
        const Value *active = owner_value.find("active");
        return active != nullptr && active->is_object() ? active : nullptr;
    }
    if (slot.rfind("bench_", 0) != 0) {
        return nullptr;
    }
    std::int64_t index = -1;
    try {
        index = std::stoll(slot.substr(6));
    } catch (const std::exception &) {
        return nullptr;
    }
    const Value *bench = owner_value.find("bench");
    if (
        bench == nullptr
        || !bench->is_array()
        || index < 0
        || static_cast<std::size_t>(index) >= bench->as_array().size()
    ) {
        return nullptr;
    }
    const Value &pokemon_value = bench->as_array()[
        static_cast<std::size_t>(index)];
    return pokemon_value.is_object() ? &pokemon_value : nullptr;
}

std::string public_card_name(
    const Value &cards,
    const std::string &card_id
) {
    if (card_id.empty()) {
        return "卡牌";
    }
    const Value *definition = cards.find(card_id);
    return definition != nullptr && definition->is_object()
        ? string_field(*definition, "name", card_id) : card_id;
}

std::string public_player_name(
    const Value &state,
    std::int32_t actor
) {
    if (actor < 0 || actor > 1) {
        return "玩家";
    }
    return string_field(
        player(state, actor),
        "name",
        "玩家" + std::to_string(actor + 1)
    );
}

std::string public_slot_name(const std::string &slot) {
    if (slot == "active") {
        return "战斗场";
    }
    if (slot.rfind("bench_", 0) == 0) {
        return "备战区";
    }
    return "场上";
}

std::string public_pokemon_name(
    const Value &cards,
    const Value &before_state,
    const Value &after_state,
    std::int32_t owner,
    const std::string &slot,
    const std::string &fallback_card_id = {}
) {
    const Value *pokemon_value = state_pokemon(before_state, owner, slot);
    if (pokemon_value == nullptr) {
        pokemon_value = state_pokemon(after_state, owner, slot);
    }
    const std::string card_id = pokemon_value != nullptr
        ? string_field(*pokemon_value, "card_id") : fallback_card_id;
    return public_card_name(cards, card_id);
}

void append_action_log_line(Value &state, std::string line) {
    if (line.empty()) {
        return;
    }
    Value *log = state.find("action_log");
    if (log == nullptr || !log->is_array()) {
        state["action_log"] = Value::make_array();
        log = state.find("action_log");
    }
    Array &lines = log->as_array();
    lines.emplace_back(std::move(line));
    // Protocol v6 accepts up to 256 entries.  Keeping the same bound in the
    // authoritative core prevents otherwise-valid late-match actions from
    // disappearing before projection/network serialization.
    while (lines.size() > 256) {
        lines.erase(lines.begin());
    }
}

std::string attack_name_for_action(
    const Value &cards,
    const Value &action
) {
    const Value *source = action.find("source");
    const Value *payload = action.find("payload");
    const std::string card_id = source != nullptr && source->is_object()
        ? string_field(*source, "card_id") : std::string{};
    const Value *definition = cards.find(card_id);
    const Value *attacks = definition != nullptr && definition->is_object()
        ? definition->find("attacks") : nullptr;
    const std::int64_t attack_index = payload != nullptr
        && payload->is_object()
        ? integer_field(*payload, "attack_index", -1) : -1;
    if (
        attacks == nullptr
        || !attacks->is_array()
        || attack_index < 0
        || static_cast<std::size_t>(attack_index)
            >= attacks->as_array().size()
    ) {
        return "招式";
    }
    return string_field(
        attacks->as_array()[static_cast<std::size_t>(attack_index)],
        "name",
        "招式"
    );
}

std::string ability_name_for_action(
    const Value &cards,
    const Value &action
) {
    const Value *source = action.find("source");
    const Value *payload = action.find("payload");
    if (payload != nullptr && payload->is_object()) {
        const std::string supplied = string_field(*payload, "ability_name");
        if (!supplied.empty()) {
            return supplied;
        }
    }
    const std::string card_id = source != nullptr && source->is_object()
        ? string_field(*source, "card_id") : std::string{};
    const Value *definition = cards.find(card_id);
    const Value *abilities = definition != nullptr && definition->is_object()
        ? definition->find("abilities") : nullptr;
    const std::int64_t ability_index = payload != nullptr
        && payload->is_object()
        ? integer_field(*payload, "ability_index", -1) : -1;
    if (
        abilities == nullptr
        || !abilities->is_array()
        || ability_index < 0
        || static_cast<std::size_t>(ability_index)
            >= abilities->as_array().size()
    ) {
        return "特性";
    }
    return string_field(
        abilities->as_array()[static_cast<std::size_t>(ability_index)],
        "name",
        "特性"
    );
}

void append_submitted_action_log(
    Value &state,
    const Value &cards,
    const Value &before_state,
    const Value &action
) {
    const std::int32_t actor = static_cast<std::int32_t>(
        integer_field(action, "actor", -1));
    if (actor < 0 || actor > 1) {
        return;
    }
    const std::string player_name = public_player_name(before_state, actor);
    const std::string kind = string_field(action, "kind");
    const Value *source = action.find("source");
    const Value *target = action.find("target");
    const std::string source_card_id = source != nullptr && source->is_object()
        ? string_field(*source, "card_id") : std::string{};
    const std::string card_name = public_card_name(cards, source_card_id);
    const std::string target_slot = target != nullptr && target->is_object()
        ? string_field(*target, "slot") : std::string{};
    std::string line;
    if (kind == "PLAY_BASIC") {
        // Setup identities remain hidden until setup_revealed. The setup path
        // already records a generic "暗置宝可梦" line.
        if (string_field(before_state, "setup_stage") != "COMPLETE") {
            return;
        }
        line = player_name + " 将 " + card_name + " 放到了"
            + public_slot_name(target_slot) + "。";
    } else if (kind == "EVOLVE") {
        line = player_name + " 使用 " + card_name + " 进行了进化。";
    } else if (kind == "ATTACH_ENERGY") {
        line = player_name + " 将 " + card_name + " 附加给了"
            + public_slot_name(target_slot) + "的宝可梦。";
    } else if (kind == "PLAY_TRAINER") {
        line = player_name + " 使用了训练家卡 " + card_name + "。";
    } else if (kind == "USE_ABILITY") {
        line = player_name + " 使用了特性「"
            + ability_name_for_action(cards, action) + "」。";
    } else if (kind == "USE_STADIUM") {
        line = player_name + " 使用了 " + card_name + " 的竞技场效果。";
    } else if (kind == "DECLARE_ATTACK") {
        line = player_name + " 的 " + card_name + " 使用了「"
            + attack_name_for_action(cards, action) + "」。";
    } else if (kind == "RETREAT") {
        const std::string retreat_target = target != nullptr
            && target->is_object()
            ? string_field(*target, "card_id") : std::string{};
        line = player_name + " 宣告撤退，并选择 "
            + public_card_name(cards, retreat_target) + " 进入战斗场。";
    } else if (kind == "PROMOTE") {
        const std::string promoted_id = target != nullptr && target->is_object()
            ? string_field(*target, "card_id") : std::string{};
        line = player_name + " 将 " + public_card_name(cards, promoted_id)
            + " 放到了战斗场。";
    } else if (kind == "END_TURN") {
        line = player_name + " 结束了回合。";
    } else if (kind == "SETUP_DONE") {
        line = player_name + " 完成了开局宝可梦放置。";
    }
    append_action_log_line(state, std::move(line));
}

void append_choice_action_log(
    Value &state,
    const Value &before_state,
    const Value &pending,
    const Value &response
) {
    if (!pending.is_object() || pending.as_object().empty()) {
        return;
    }
    const std::int32_t actor = static_cast<std::int32_t>(
        integer_field(pending, "player", -1));
    const std::string player_name = public_player_name(before_state, actor);
    if (bool_field(response, "cancelled")) {
        append_action_log_line(state, player_name + " 取消了此次操作。");
        return;
    }
    const Value *option_ids = response.find("option_ids");
    const std::int64_t count = option_ids != nullptr && option_ids->is_array()
        ? static_cast<std::int64_t>(option_ids->as_array().size()) : 0;
    const std::string request_type = string_field(pending, "request_type");
    const Value *presentation = pending.find("presentation");
    const std::string purpose = presentation != nullptr
        && presentation->is_object()
        ? string_field(*presentation, "purpose", request_type)
        : request_type;
    if (request_type == "coin_flip") {
        return;
    }
    std::string line;
    if (request_type == "choose_turn_order" && count == 1) {
        const std::string selected = option_ids->as_array().front().string_or();
        line = player_name + (selected == "turn:first"
            ? " 选择了先攻。" : " 选择了后攻。");
    } else if (request_type == "choose_mulligan_draw_count" && count == 1) {
        const std::string selected = option_ids->as_array().front().string_or();
        const std::string amount = selected.rfind("draw:", 0) == 0
            ? selected.substr(5) : std::string("0");
        line = player_name + " 选择抽取 " + amount + " 张再战奖励牌。";
    } else if (request_type == "select_prize") {
        line = player_name + " 选择了 " + std::to_string(count)
            + " 张奖赏卡。";
    } else if (request_type == "select_retreat_payment") {
        line = player_name + " 选择了撤退所需的能量。";
    } else if (request_type == "confirm_trigger" && count == 1) {
        const std::string selected = option_ids->as_array().front().string_or();
        line = player_name + (selected == "confirm:yes"
            ? " 选择发动触发效果。" : " 选择不发动触发效果。");
    } else if (request_type == "choose_trigger_order") {
        line = player_name + " 选择了触发效果的结算顺序。";
    } else if (purpose == "shuffle_from_discard") {
        // "discard" describes the source zone here.  It must never be
        // presented as if the player discarded another card.
        line = player_name + " 选择将 " + std::to_string(count)
            + " 张卡牌从弃牌区放回牌库。";
    } else if (purpose == "clara") {
        line = player_name + " 选择从弃牌区回收了 "
            + std::to_string(count) + " 张卡牌。";
    } else if (purpose == "attach_discard_energy_distribution") {
        line = player_name + " 选择将弃牌区中的 "
            + std::to_string(count) + " 张能量附着到场上。";
    } else if (
        purpose == "discard_cards"
        || purpose == "discard_hand"
        || purpose == "discard_hand_then_draw"
        || purpose == "zinnia"
    ) {
        line = player_name + " 选择弃置了 " + std::to_string(count)
            + " 张手牌。";
    } else if (
        purpose == "discard_energy_attachments"
        || purpose == "discard_attachment"
    ) {
        line = player_name + " 选择弃置了 " + std::to_string(count)
            + " 张附着能量。";
    } else if (purpose == "place_counters_self_discard") {
        // The selected option is the opponent's damage-counter target.  The
        // source Pokemon discards itself automatically after that selection.
        line = player_name + " 选择了伤害指示物的放置目标。";
    } else if (
        purpose == "energy_relocate_attachments"
        || purpose == "relocate_energy_attachments"
    ) {
        line = player_name + " 选择了 " + std::to_string(count)
            + " 张要转附的能量。";
    } else if (
        purpose == "energy_relocate_target"
        || purpose == "relocate_energy_target"
    ) {
        line = player_name + " 选择了能量转附目标。";
    } else if (
        request_type.find("search") != std::string::npos
        || request_type.find("select") != std::string::npos
        || request_type.find("choose") != std::string::npos
    ) {
        line = player_name + " 完成了卡牌选择。";
    } else if (!request_type.empty()) {
        line = player_name + " 完成了一项效果选择。";
    }
    append_action_log_line(state, std::move(line));
}

void append_public_event_logs(
    Value &state,
    const Value &cards,
    const Value &before_state,
    const std::vector<Value> &events
) {
    for (const Value &event_value : events) {
        if (!event_value.is_object()) {
            continue;
        }
        const std::string event_type = string_field(
            event_value, "event_type");
        const Value *data_value = event_value.find("data");
        const Value empty_data = Value::make_object();
        const Value &data = data_value != nullptr && data_value->is_object()
            ? *data_value : empty_data;
        const std::int32_t actor = static_cast<std::int32_t>(integer_field(
            event_value, "actor", integer_field(data, "player", -1)));
        const std::int32_t target_player = static_cast<std::int32_t>(
            integer_field(data, "target_player", integer_field(
                data, "player", actor)));
        const std::string target_slot = string_field(
            data, "target_slot", string_field(data, "slot", "active"));
        const std::int64_t amount = integer_field(
            event_value,
            "amount",
            integer_field(data, "amount", integer_field(data, "count", 0))
        );
        std::string line;
        if (event_type == "cards_drawn" && amount > 0) {
            line = public_player_name(state, target_player) + " 抽取了 "
                + std::to_string(amount) + " 张卡牌。";
        } else if (event_type == "cards_discarded" && amount > 0) {
            line = public_player_name(state, target_player) + " 弃置了 "
                + std::to_string(amount) + " 张卡牌。";
        } else if (event_type == "energy_attached" && amount > 0) {
            const std::string energy_id = string_field(
                event_value,
                "card_id",
                string_field(data, "card_id")
            );
            const std::string energy_name = energy_id.empty()
                ? std::to_string(amount) + " 张能量"
                : public_card_name(cards, energy_id);
            line = public_player_name(state, target_player) + " 将 "
                + energy_name + " 附着到了 " + public_pokemon_name(
                    cards,
                    before_state,
                    state,
                    target_player,
                    target_slot
                ) + "。";
        } else if (
            event_type == "card_moved"
            && amount > 0
            && string_field(data, "source_zone") == "hand"
            && string_field(data, "target_zone") == "deck"
        ) {
            line = public_player_name(state, target_player) + " 将 "
                + std::to_string(amount) + " 张手牌放回了牌库。";
        } else if (event_type == "deck_shuffled") {
            line = public_player_name(state, target_player) + " 重洗了牌库。";
        } else if (
            event_type == "switched"
            || event_type == "promoted"
        ) {
            line = public_player_name(state, target_player) + " 将 "
                + public_pokemon_name(
                    cards,
                    before_state,
                    state,
                    target_player,
                    "active"
                ) + " 换入了战斗场。";
        } else if (event_type == "damage_prevented") {
            line = public_pokemon_name(
                cards,
                before_state,
                state,
                target_player,
                target_slot
            ) + " 防止了招式伤害。";
        } else if (event_type == "dazzled_failed") {
            line = public_player_name(state, actor)
                + " 的招式因炫目效果而失败。";
        } else if (
            (event_type == "damage_dealt"
                || event_type == "damage_counters_placed"
                || event_type == "confusion_failed")
            && amount > 0
        ) {
            const std::string pokemon_name = public_pokemon_name(
                cards, before_state, state, target_player, target_slot);
            if (
                event_type == "damage_counters_placed"
                || event_type == "confusion_failed"
                || string_field(data, "damage_kind") == "damage_counters"
            ) {
                line = "在 " + pokemon_name + " 身上放置了 "
                    + std::to_string((amount + 9) / 10)
                    + " 个伤害指示物。";
            } else {
                line = pokemon_name + " 受到了 " + std::to_string(amount)
                    + " 点伤害。";
            }
        } else if (event_type == "healed" && amount > 0) {
            line = public_pokemon_name(
                cards, before_state, state, target_player, target_slot)
                + " 恢复了 " + std::to_string(amount) + " 点HP。";
        } else if (event_type == "status_applied") {
            line = public_pokemon_name(
                cards, before_state, state, target_player, target_slot)
                + " 陷入了 " + string_field(data, "status", "特殊状态")
                + "。";
        } else if (event_type == "status_removed") {
            line = public_pokemon_name(
                cards, before_state, state, target_player, target_slot)
                + " 解除了 " + string_field(data, "status", "特殊状态")
                + "。";
        } else if (event_type == "pokemon_ko") {
            const std::string card_id = string_field(
                event_value, "card_id", string_field(data, "card_id"));
            line = public_card_name(cards, card_id) + " 昏厥了。";
        } else if (event_type == "prize_taken" && amount > 0) {
            line = public_player_name(state, target_player) + " 拿取了 "
                + std::to_string(amount) + " 张奖赏卡。";
        } else if (event_type == "coin_flip") {
            const Value *results = data.find("results");
            if (results != nullptr && results->is_array()) {
                std::int64_t heads = 0;
                for (const Value &result : results->as_array()) {
                    heads += result.as_bool() ? 1 : 0;
                }
                line = public_player_name(state, actor) + " 抛掷硬币："
                    + std::to_string(heads) + " 次正面，"
                    + std::to_string(
                        static_cast<std::int64_t>(results->as_array().size())
                            - heads)
                    + " 次反面。";
            }
        } else if (event_type == "turn_start") {
            line = "—— " + public_player_name(state, actor) + " 的回合 ——";
        } else if (event_type == "deck_exhausted") {
            line = public_player_name(state, actor) + " 无法从牌库抽牌。";
        } else if (event_type == "game_over") {
            const std::int32_t winner = static_cast<std::int32_t>(
                integer_field(data, "winner", actor));
            line = winner >= 0
                ? "对战结束，胜者：" + public_player_name(state, winner) + "。"
                : "对战结束，本局为平局。";
        }
        append_action_log_line(state, std::move(line));
    }
}

void append_canonical_json(std::string &output, const Value &value) {
    switch (value.type()) {
        case Value::Type::null_value:
            output += "null";
            return;
        case Value::Type::boolean:
            output += value.as_bool() ? "true" : "false";
            return;
        case Value::Type::integer:
            output += std::to_string(value.as_integer());
            return;
        case Value::Type::number: {
            std::ostringstream stream;
            stream << std::setprecision(17) << value.as_number();
            output += stream.str();
            return;
        }
        case Value::Type::string: {
            output += '"';
            for (const unsigned char character : value.as_string()) {
                switch (character) {
                    case '\\': output += "\\\\"; break;
                    case '"': output += "\\\""; break;
                    case '\b': output += "\\b"; break;
                    case '\f': output += "\\f"; break;
                    case '\n': output += "\\n"; break;
                    case '\r': output += "\\r"; break;
                    case '\t': output += "\\t"; break;
                    default:
                        if (character < 0x20) {
                            std::ostringstream escaped;
                            escaped << "\\u" << std::hex << std::setw(4)
                                << std::setfill('0')
                                << static_cast<int>(character);
                            output += escaped.str();
                        } else {
                            output += static_cast<char>(character);
                        }
                }
            }
            output += '"';
            return;
        }
        case Value::Type::array: {
            output += '[';
            bool first = true;
            for (const Value &entry : value.as_array()) {
                if (!first) {
                    output += ',';
                }
                first = false;
                append_canonical_json(output, entry);
            }
            output += ']';
            return;
        }
        case Value::Type::object: {
            output += '{';
            bool first = true;
            for (const auto &[key, entry] : value.as_object()) {
                if (!first) {
                    output += ',';
                }
                first = false;
                append_canonical_json(output, Value(key));
                output += ':';
                append_canonical_json(output, entry);
            }
            output += '}';
            return;
        }
    }
}

std::string fnv1a64_hex(const std::string &input) {
    std::uint64_t hash = 14695981039346656037ULL;
    for (const unsigned char byte : input) {
        hash ^= static_cast<std::uint64_t>(byte);
        hash *= 1099511628211ULL;
    }
    std::ostringstream stream;
    stream << std::hex << std::setw(16) << std::setfill('0') << hash;
    return stream.str();
}

std::int32_t winner_from_state(const Value &state) {
    return static_cast<std::int32_t>(integer_field(state, "winner", -1));
}

bool terminal_from_state(const Value &state) {
    return string_field(state, "result_status", "ONGOING") != "ONGOING"
        || winner_from_state(state) >= 0;
}

Value public_option_ref(
    const Value &source,
    std::int32_t request_player,
    const std::string &request_type
) {
    const Value *nested = source.find("ref");
    const Value &raw = nested != nullptr && nested->is_object()
        ? *nested : source;
    if (!raw.is_object() || request_type == "select_prize") {
        return Value();
    }
    const std::string kind = string_field(raw, "kind");
    const std::int32_t owner = static_cast<std::int32_t>(
        integer_field(raw, "player", -1));
    if (owner < 0 || owner > 1) {
        return Value();
    }
    Object reference{{"kind", Value(kind)}, {"player", Value(owner)}};
    if (kind == "card") {
        const std::string zone = string_field(raw, "zone");
        if (
            zone.empty()
            || zone == "prize" || zone == "prizes"
            || ((zone == "hand" || zone == "deck")
                && owner != request_player)
        ) {
            return Value();
        }
        reference["zone"] = Value(zone);
        reference["index"] = Value(integer_field(raw, "index", -1));
        reference["card_id"] = Value(string_field(raw, "card_id"));
    } else if (kind == "pokemon" || kind == "slot") {
        reference["slot"] = Value(string_field(raw, "slot"));
        if (kind == "pokemon") {
            reference["card_id"] = Value(string_field(raw, "card_id"));
        }
    } else if (kind == "attachment") {
        reference["slot"] = Value(string_field(raw, "slot"));
        reference["attachment_type"] = Value(string_field(
            raw, "attachment_type"));
        reference["index"] = Value(integer_field(raw, "index", -1));
        reference["card_id"] = Value(string_field(raw, "card_id"));
    } else {
        return Value();
    }
    return Value(std::move(reference));
}

Value public_choice(
    Value &state,
    const Value &raw,
    const std::string &request_id_override = {}
) {
    if (!raw.is_object()) {
        return Value();
    }
    const bool already_versioned = (
        integer_field(raw, "schema_version") == 2
        && !string_field(raw, "request_id").empty()
    );
    const std::int32_t actor = static_cast<std::int32_t>(
        integer_field(raw, "player", -1));
    const std::string request_type = string_field(
        raw, "request_type", "select");
    const Value *raw_presentation = raw.find("presentation");
    const Value *raw_metadata = raw.find("metadata");
    const std::string presentation_domain = (
        raw_presentation != nullptr && raw_presentation->is_object()
    ) ? string_field(*raw_presentation, "domain", "effect") : (
        raw_metadata != nullptr && raw_metadata->is_object()
            ? string_field(*raw_metadata, "domain", "effect")
            : "effect"
    );
    const std::string presentation_purpose = (
        raw_presentation != nullptr && raw_presentation->is_object()
    ) ? string_field(*raw_presentation, "purpose", request_type) : (
        raw_metadata != nullptr && raw_metadata->is_object()
            ? string_field(
                *raw_metadata,
                "continuation_kind",
                string_field(raw, "continuation_kind", request_type)
            )
            : string_field(raw, "continuation_kind", request_type)
    );
    const bool cancels_action = (
        raw_presentation != nullptr && raw_presentation->is_object()
            && bool_field(*raw_presentation, "cancels_action")
    ) || (
        raw_metadata != nullptr && raw_metadata->is_object()
            && bool_field(*raw_metadata, "cancels_action")
    );
    std::int64_t sequence = integer_field(state, "choice_sequence");
    std::string request_id = request_id_override;
    if (request_id.empty()) {
        request_id = already_versioned
            ? string_field(raw, "request_id")
            : "choice:" + std::to_string(integer_field(
                state, "revision")) + ":" + std::to_string(actor) + ":"
                + request_type + ":" + std::to_string(sequence);
    }
    if (!already_versioned) {
        state["choice_sequence"] = Value(sequence + 1);
    }
    Array options;
    const Value *raw_options = raw.find("options");
    if (raw_options != nullptr && raw_options->is_array()) {
        options.reserve(raw_options->as_array().size());
        for (
            std::size_t index = 0;
            index < raw_options->as_array().size();
            ++index
        ) {
            const Value &source = raw_options->as_array()[index];
            std::string option_id = request_type == "select_prize"
                ? "prize:" + std::to_string(index)
                : string_field(source, "option_id");
            if (option_id.empty()) {
                option_id = "option:" + std::to_string(index);
            }
            std::string label = request_type == "select_prize"
                ? "奖励牌 " + std::to_string(index + 1)
                : string_field(source, "label");
            if (label.empty()) {
                label = string_field(source, "card_id");
            }
            if (label.empty()) {
                label = string_field(source, "slot");
            }
            if (label.empty()) {
                label = "option " + std::to_string(index + 1);
            }
            const Value reference = public_option_ref(
                source, actor, request_type);
            const Value *nested_reference = source.find("ref");
            const Value &raw_reference = (
                nested_reference != nullptr && nested_reference->is_object()
            ) ? *nested_reference : source;
            const bool source_is_hidden_reference = (
                string_field(raw_reference, "kind") == "card"
                && reference.is_null()
            );
            if (source_is_hidden_reference && request_type != "select_prize") {
                option_id = "option:" + std::to_string(index);
                label = "卡牌 " + std::to_string(index + 1);
            }
            Object option{
                {"option_id", Value(std::move(option_id))},
                {"label", Value(std::move(label))},
            };
            if (!reference.is_null()) {
                option["ref"] = reference;
            }
            options.emplace_back(std::move(option));
        }
    }
    Object presentation{
        {"domain", Value(presentation_domain)},
        {"purpose", Value(presentation_purpose)},
    };
    // ChoiceView v2 deliberately exposes only this allowlist.  Copying these
    // author-provided hints is part of the public choice contract; omitting
    // them makes otherwise valid selectors (for example retreat payment)
    // unable to construct a legal response.
    static constexpr std::array<const char *, 34> presentation_fields{
        "decision_mode", "cancel_mode", "card_ids", "revealed_card_ids",
        "top_card_id", "attachment_refs", "source_player", "source_slot",
        "source_zone", "source_card_id", "card_id", "target_player",
        "target_slot", "target_slots", "required_units", "max_per_target",
        "same_target", "same_source", "pokemon_count", "energy_count",
        "energy_type", "predetermined_flips", "category_limits",
        "selection_mode", "amount", "count", "owner", "trigger_id",
        "trigger_ids", "hook", "labels", "domain", "purpose",
        "cancels_action",
    };
    static const std::unordered_set<std::string> prize_private_fields{
        "card_ids", "revealed_card_ids", "top_card_id", "attachment_refs",
        "source_card_id", "card_id", "labels",
    };
    for (const char *field_name : presentation_fields) {
        const std::string key(field_name);
        if ((request_type == "select_prize"
                && prize_private_fields.find(key)
                    != prize_private_fields.end())) {
            continue;
        }
        const Value *source = nullptr;
        if (raw_presentation != nullptr && raw_presentation->is_object()) {
            source = raw_presentation->find(key);
        }
        if (source == nullptr && raw_metadata != nullptr
            && raw_metadata->is_object()) {
            source = raw_metadata->find(key);
        }
        if (source != nullptr) {
            presentation[key] = source->deep_clone();
        }
    }
    if (cancels_action) {
        presentation["cancels_action"] = Value(true);
    }
    return Value(Object{
        {"schema_version", Value(2)},
        {"request_id", Value(std::move(request_id))},
        {
            "base_revision",
            Value(already_versioned
                ? integer_field(raw, "base_revision", -1)
                : integer_field(state, "revision", -1)),
        },
        {"player", Value(actor)},
        {"request_type", Value(request_type)},
        {
            "prompt",
            Value(request_type == "select_prize"
                ? "请选择奖励牌。"
                : string_field(raw, "prompt", "请选择。")),
        },
        {"options", Value(std::move(options))},
        {"min_select", Value(integer_field(raw, "min_select", 1))},
        {"max_select", Value(integer_field(raw, "max_select", 1))},
        {"allow_duplicates", Value(bool_field(raw, "allow_duplicates"))},
        {"can_cancel", Value(bool_field(raw, "can_cancel"))},
        {"presentation", Value(std::move(presentation))},
    });
}

Value setup_choice(
    Value &state,
    std::int32_t player_index,
    std::string request_type,
    std::string prompt,
    Array options,
    std::string purpose
) {
    const std::int64_t revision = integer_field(state, "revision");
    const std::int64_t sequence = integer_field(state, "choice_sequence");
    const std::string request_id = "choice:" + std::to_string(revision)
        + ":" + std::to_string(player_index) + ":" + request_type + ":"
        + std::to_string(sequence);
    state["choice_sequence"] = Value(sequence + 1);
    return Value(Object{
        {"schema_version", Value(2)},
        {"request_id", Value(request_id)},
        {"base_revision", Value(revision)},
        {"player", Value(player_index)},
        {"request_type", Value(std::move(request_type))},
        {"prompt", Value(std::move(prompt))},
        {"options", Value(std::move(options))},
        {"min_select", Value(1)},
        {"max_select", Value(1)},
        {"allow_duplicates", Value(false)},
        {"can_cancel", Value(false)},
        {"presentation", Value(Object{
            {"domain", Value("setup")},
            {"purpose", Value(std::move(purpose))},
        })},
    });
}

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
        }
        if (declared_identity) {
            selected = select_declared(
                event_value, event_type, previous_type);
        } else if (
            !action_card_id.empty()
            && action_event_matches(action_kind, event_type)
        ) {
            selected = select_direct(event_type, action_card_id);
        }
        if (
            selected.empty()
            && !declared_identity
            && !explicit_zero_selection
        ) {
            selected = select_for_event(event_type, previous_type);
        }
        if (!selected.empty()) {
            apply_moves(event_value, event_type, selected, previous_type);
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
        const std::string &previous_type
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
        if (first.source.index >= 0) {
            set_if_empty(data, "source_index", Value(first.source.index));
        }
        if (first.target.index >= 0) {
            set_if_empty(data, "target_index", Value(first.target.index));
        }
        if (selected.size() > 1) {
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
    const Value *before_state = nullptr,
    const Value *after_state = nullptr,
    const Value *input = nullptr,
    std::int32_t actor_hint = -1
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

bool action_equivalent(const Value &submitted, const Value &candidate) {
    static const std::array<const char *, 6> keys = {
        "schema_version", "base_revision", "actor", "kind", "source", "target",
    };
    for (const char *key : keys) {
        const Value *left = submitted.find(key);
        const Value *right = candidate.find(key);
        if (left == nullptr || right == nullptr || !(*left == *right)) {
            return false;
        }
    }
    const Value *left_payload = submitted.find("payload");
    const Value *right_payload = candidate.find("payload");
    return left_payload != nullptr && right_payload != nullptr
        && *left_payload == *right_payload;
}

std::string validate_action_shape(const Value &action) {
    if (!action.is_object()) {
        return "invalid_schema";
    }
    static const std::unordered_set<std::string> allowed = {
        "schema_version", "action_id", "base_revision", "actor",
        "kind", "source", "target", "payload",
    };
    if (action.as_object().size() != allowed.size()) {
        return "invalid_schema";
    }
    for (const auto &[key, value] : action.as_object()) {
        (void)value;
        if (allowed.find(key) == allowed.end()) {
            return "invalid_schema";
        }
    }
    const Value *schema_version = action.find("schema_version");
    const Value *action_id = action.find("action_id");
    const Value *base_revision = action.find("base_revision");
    const Value *actor = action.find("actor");
    const Value *kind = action.find("kind");
    const Value *payload = action.find("payload");
    const auto wire_integer = [](const Value *value) {
        if (value == nullptr || !value->is_number()) {
            return false;
        }
        const double number = value->as_number();
        return number >= static_cast<double>(
                std::numeric_limits<std::int32_t>::min())
            && number <= static_cast<double>(
                std::numeric_limits<std::int32_t>::max())
            && number == static_cast<double>(value->as_integer());
    };
    if (
        !wire_integer(schema_version)
        || schema_version->as_integer() != 4
        || action_id == nullptr || !action_id->is_string()
        || action_id->as_string().empty() || action_id->as_string().size() > 128
        || !wire_integer(base_revision)
        || base_revision->as_integer() < 0
        || !wire_integer(actor)
        || actor->as_integer() < 0 || actor->as_integer() > 1
        || kind == nullptr || !kind->is_string()
        || kind->as_string().empty() || kind->as_string().size() > 64
        || payload == nullptr || !payload->is_object()
    ) {
        return "invalid_schema";
    }
    const Value *source = action.find("source");
    const Value *target = action.find("target");
    if (
        source == nullptr || target == nullptr
        || (!source->is_null() && !source->is_object())
        || (!target->is_null() && !target->is_object())
    ) {
        return "invalid_schema";
    }
    return {};
}

std::string validate_choice_response_shape(const Value &response) {
    if (!response.is_object() || response.as_object().size() != 3) {
        return "invalid_choice";
    }
    static const std::array<const char *, 3> required_fields = {
        "request_id", "option_ids", "cancelled",
    };
    for (const char *key : required_fields) {
        if (response.find(key) == nullptr) {
            return "invalid_choice";
        }
    }
    const Value *request_id = response.find("request_id");
    const Value *option_ids = response.find("option_ids");
    const Value *cancelled = response.find("cancelled");
    if (
        !request_id->is_string() || request_id->as_string().empty()
        || request_id->as_string().size() > 128
        || !option_ids->is_array() || option_ids->as_array().size() > 60
        || !cancelled->is_bool()
    ) {
        return "invalid_choice";
    }
    for (const Value &option_id : option_ids->as_array()) {
        if (
            !option_id.is_string() || option_id.as_string().empty()
            || option_id.as_string().size() > 128
        ) {
            return "invalid_choice";
        }
    }
    return {};
}

Value hidden_cards(std::size_t count) {
    return Value(Array(count, Value("")));
}

void strip_internal_pokemon_fields(Value &pokemon_value) {
    if (!pokemon_value.is_object()) {
        return;
    }
    static const std::unordered_set<std::string> public_fields = {
        "card_id", "damage_counters", "energy_card_ids", "attached_tool_id",
        "status_conditions", "evolution_stack_ids", "can_evolve_this_turn",
        "placed_this_turn", "used_abilities", "healed_this_turn",
        "paralyzed_since_turn", "modifiers",
    };
    Object &row = pokemon_value.as_object();
    for (auto iterator = row.begin(); iterator != row.end();) {
        if (public_fields.find(iterator->first) == public_fields.end()) {
            iterator = row.erase(iterator);
        } else {
            ++iterator;
        }
    }
}

Value player_view(
    const Value &owner,
    bool show_hand,
    bool hide_setup_board
) {
    Value result = owner.deep_clone();
    Object &row = result.as_object();
    const auto count = [&owner](const std::string &key) {
        const Value *value = owner.find(key);
        return static_cast<std::int64_t>(
            value != nullptr && value->is_array() ? value->as_array().size() : 0);
    };
    row["hand_count"] = Value(count("hand"));
    row["deck_count"] = Value(count("deck"));
    row["prize_count"] = Value(count("prizes"));
    row.erase("deck");
    row.erase("prizes");
    if (!show_hand) {
        row.erase("hand");
    }
    Value *public_active = result.find("active");
    if (public_active != nullptr) {
        strip_internal_pokemon_fields(*public_active);
    }
    Value *public_bench = result.find("bench");
    if (public_bench != nullptr && public_bench->is_array()) {
        for (Value &pokemon_value : public_bench->as_array()) {
            strip_internal_pokemon_fields(pokemon_value);
        }
    }
    if (hide_setup_board) {
        const Value *active = owner.find("active");
        row["active"] = active != nullptr && active->is_object()
            ? Value(Object{{"hidden", Value(true)}})
            : Value();
        Array bench;
        const Value *source_bench = owner.find("bench");
        if (source_bench != nullptr && source_bench->is_array()) {
            for (const Value &entry : source_bench->as_array()) {
                bench.push_back(entry.is_object()
                    ? Value(Object{{"hidden", Value(true)}})
                    : Value());
            }
        }
        row["bench"] = Value(std::move(bench));
    }
    return result;
}

void set_prizes(Value &state) {
    for (std::int32_t actor = 0; actor < 2; ++actor) {
        Value &owner = player(state, actor);
        Array &deck = required(owner, "deck").as_array();
        Array &prizes = required(owner, "prizes").as_array();
        for (std::size_t count = 0; count < 6 && !deck.empty(); ++count) {
            prizes.push_back(deck.back());
            deck.pop_back();
        }
    }
}

void finish_setup(Value &state, std::vector<Value> &events) {
    state["setup_stage"] = Value("COMPLETE");
    state["setup_actor_idx"] = Value(-1);
    state["setup_bonus_card_ids"] = Value(Array{Value::make_array(), Value::make_array()});
    const std::int32_t first = static_cast<std::int32_t>(
        integer_field(state, "first_player_idx"));
    state["active_player_idx"] = Value(first);
    state["phase"] = Value("DRAW");
    Array revealed_players;
    for (std::int32_t actor = 0; actor < 2; ++actor) {
        const Value &owner = player(state, actor);
        Array bench_ids;
        const Value *bench = owner.find("bench");
        if (bench != nullptr && bench->is_array()) {
            for (const Value &entry : bench->as_array()) {
                if (entry.is_object()) {
                    bench_ids.emplace_back(string_field(entry, "card_id"));
                }
            }
        }
        const Value *active = owner.find("active");
        revealed_players.emplace_back(Object{
            {
                "active",
                Value(active != nullptr && active->is_object()
                    ? string_field(*active, "card_id") : ""),
            },
            {"bench", Value(std::move(bench_ids))},
        });
    }
    events.push_back(event(
        "setup_revealed",
        -1,
        Value(Object{
            {"first_player", Value(first)},
            {"players", Value(std::move(revealed_players))},
        }),
        "public"
    ));
    events.push_back(event(
        "turn_start",
        first,
        Value(Object{
            {"player", Value(first)},
            {"turn", Value(integer_field(state, "turn_number"))},
        })
    ));
    Value &owner = player(state, first);
    Array drawn = draw_cards(owner, 1);
    if (drawn.empty()) {
        const std::int32_t winner = 1 - first;
        state["winner"] = Value(winner);
        state["result_status"] = Value("WIN");
        state["result_reason"] = Value("deck_exhausted");
        state["result_conditions"] = Value(Array{
            Value(first == 1 ? Array{Value("opponent_deck_exhausted")} : Array{}),
            Value(first == 0 ? Array{Value("opponent_deck_exhausted")} : Array{}),
        });
        events.push_back(event(
            "deck_exhausted", first,
            Value(Object{{"player", Value(first)}, {"reason", Value("draw_failed")}})));
        events.push_back(event(
            "game_over", winner,
            Value(Object{{"winner", Value(winner)}, {"reason", Value("deck_exhausted")}})));
        return;
    }
    events.push_back(event(
        "cards_drawn",
        first,
        Value(Object{
            {"player", Value(first)},
            {"count", Value(1)},
            {"card_ids", Value(drawn)},
            {"purpose", Value("turn_draw")},
            {"turn", Value(integer_field(state, "turn_number"))},
        }),
        "owner"
    ));
    state["phase"] = Value("MAIN");
}

std::string prepare_opening_hands(
    const Value &cards,
    Value &state,
    XorShift32 &rng,
    std::vector<Value> &events
) {
    state["turn_number"] = Value(1);
    state["mulligan_count"] = Value(Array{Value(0), Value(0)});
    for (std::int32_t actor = 0; actor < 2; ++actor) {
        Array drawn = draw_cards(player(state, actor), 7);
        events.push_back(event(
            "cards_drawn",
            actor,
            Value(Object{
                {"player", Value(actor)},
                {"purpose", Value("opening_hand")},
                {"round", Value(0)},
                {"count", Value(static_cast<std::int64_t>(drawn.size()))},
                {"card_ids", Value(drawn)},
                {"final_opening_hand", Value(hand_has_basic(cards, player(state, actor)))},
            }),
            "owner"
        ));
    }
    std::int64_t guard = 0;
    while (
        !hand_has_basic(cards, player(state, 0))
        || !hand_has_basic(cards, player(state, 1))
    ) {
        ++guard;
        if (guard > 64) {
            return "mulligan_guard";
        }
        std::array<bool, 2> redraw = {
            !hand_has_basic(cards, player(state, 0)),
            !hand_has_basic(cards, player(state, 1)),
        };
        for (std::int32_t actor = 0; actor < 2; ++actor) {
            if (!redraw[static_cast<std::size_t>(actor)]) {
                continue;
            }
            Value &owner = player(state, actor);
            const Array revealed = required(owner, "hand").as_array();
            events.push_back(event(
                "cards_revealed", actor,
                Value(Object{
                    {"player", Value(actor)},
                    {"purpose", Value("mulligan")},
                    {"round", Value(guard)},
                    {"card_ids", Value(revealed)},
                    {"cards", Value(revealed)},
                }),
                "public"
            ));
            Array &deck = required(owner, "deck").as_array();
            Array &hand = required(owner, "hand").as_array();
            events.push_back(event(
                "card_moved", actor,
                Value(Object{
                    {"player", Value(actor)},
                    {"purpose", Value("mulligan_return")},
                    {"round", Value(guard)},
                    {"card_ids", Value(revealed)},
                    {"count", Value(static_cast<std::int64_t>(revealed.size()))},
                    {"source_zone", Value("hand")},
                    {"target_zone", Value("deck")},
                }),
                "public"
            ));
            deck.insert(deck.end(), hand.begin(), hand.end());
            hand.clear();
            shuffle(deck, rng);
            Array &counts = required(state, "mulligan_count").as_array();
            counts[static_cast<std::size_t>(actor)] = Value(
                counts[static_cast<std::size_t>(actor)].as_integer() + 1);
            events.push_back(event(
                "deck_shuffled", actor,
                Value(Object{
                    {"player", Value(actor)},
                    {"purpose", Value("mulligan")},
                    {"round", Value(guard)},
                }),
                "public"
            ));
            Array drawn = draw_cards(owner, 7);
            events.push_back(event(
                "cards_drawn", actor,
                Value(Object{
                    {"player", Value(actor)},
                    {"purpose", Value("mulligan_redraw")},
                    {"round", Value(guard)},
                    {"count", Value(static_cast<std::int64_t>(drawn.size()))},
                    {"card_ids", Value(drawn)},
                    {"final_opening_hand", Value(hand_has_basic(cards, owner))},
                }),
                "owner"
            ));
        }
    }
    const Array &counts = required(state, "mulligan_count").as_array();
    const std::int64_t bonus_zero = std::max<std::int64_t>(
        0, counts[1].as_integer() - counts[0].as_integer());
    const std::int64_t bonus_one = std::max<std::int64_t>(
        0, counts[0].as_integer() - counts[1].as_integer());
    state["mulligan_bonus_max"] = Value(std::max(bonus_zero, bonus_one));
    state["setup_stage"] = Value("INITIAL_PLACEMENT");
    state["setup_actor_idx"] = state["first_player_idx"];
    state["setup_ready"] = Value(Array{Value(false), Value(false)});
    return {};
}

std::string validate_snapshot_payload(
    const Value &snapshot,
    const Value &cards
) {
    std::string encoded;
    append_canonical_json(encoded, snapshot);
    if (encoded.size() > 1024U * 1024U) {
        return "snapshot_too_large";
    }
    static const std::array<const char *, 30> required_fields = {
        "players", "active_player_idx", "phase", "turn_number",
        "first_player_idx", "stadium_card_id", "stadium_owner_idx",
        "winner", "result_status", "result_reason", "result_conditions",
        "revision", "choice_sequence", "public_deck_keys",
        "apply_type_matchups", "rules_profile_id", "rules_options",
        "action_log", "mulligan_count", "extra_draws", "setup_ready",
        "setup_stage", "setup_actor_idx", "opening_coin_winner_idx",
        "mulligan_bonus_max", "setup_bonus_card_ids", "pending_promotions",
        "processed_action_ids", "resolution_stack", "turn_fact_book",
    };
    for (const char *key : required_fields) {
        if (snapshot.find(key) == nullptr) {
            return std::string("missing_snapshot_field:") + key;
        }
    }
    if (
        !required(snapshot, "players").is_array()
        || required(snapshot, "players").as_array().size() != 2
        || !required(snapshot, "phase").is_string()
        || string_field(snapshot, "phase").empty()
        || integer_field(snapshot, "active_player_idx", -1) < 0
        || integer_field(snapshot, "active_player_idx", -1) > 1
        || integer_field(snapshot, "first_player_idx", -1) < 0
        || integer_field(snapshot, "first_player_idx", -1) > 1
        || integer_field(snapshot, "winner", -2) < -1
        || integer_field(snapshot, "winner", -2) > 1
        || integer_field(snapshot, "turn_number", -1) < 0
        || integer_field(snapshot, "revision", -1) < 0
        || integer_field(snapshot, "choice_sequence", -1) < 0
        || !required(snapshot, "rules_options").is_object()
        || !required(snapshot, "turn_fact_book").is_object()
        || !required(snapshot, "resolution_stack").is_object()
    ) {
        return "invalid_snapshot_shape";
    }
    for (const char *key : {
        "public_deck_keys", "mulligan_count", "extra_draws", "setup_ready",
        "setup_bonus_card_ids", "result_conditions",
    }) {
        const Value *rows = snapshot.find(key);
        if (rows == nullptr || !rows->is_array() || rows->as_array().size() != 2) {
            return std::string("invalid_snapshot_pair:") + key;
        }
    }
    for (const char *key : {"action_log", "pending_promotions", "processed_action_ids"}) {
        const Value *rows = snapshot.find(key);
        if (rows == nullptr || !rows->is_array() || rows->as_array().size() > 4096) {
            return std::string("invalid_snapshot_array:") + key;
        }
    }
    const auto validate_card_array = [&cards](const Value *values) {
        if (values == nullptr || !values->is_array() || values->as_array().size() > 256) {
            return false;
        }
        return std::all_of(
            values->as_array().begin(), values->as_array().end(),
            [&cards](const Value &entry) {
                return entry.is_string()
                    && !entry.string_or().empty()
                    && cards.find(entry.string_or()) != nullptr;
            }
        );
    };
    const auto validate_pokemon = [&cards, &validate_card_array](
        const Value &pokemon_value
    ) {
        if (pokemon_value.is_null()) {
            return true;
        }
        if (!pokemon_value.is_object()) {
            return false;
        }
        const std::string card_id = string_field(pokemon_value, "card_id");
        const std::string tool_id = string_field(
            pokemon_value, "attached_tool_id");
        return !card_id.empty()
            && cards.find(card_id) != nullptr
            && (tool_id.empty() || cards.find(tool_id) != nullptr)
            && validate_card_array(pokemon_value.find("energy_card_ids"))
            && validate_card_array(pokemon_value.find("evolution_stack_ids"));
    };
    for (const Value &owner : required(snapshot, "players").as_array()) {
        if (!owner.is_object() || !string_field(owner, "name").size()) {
            return "invalid_snapshot_player";
        }
        for (const char *zone : {"deck", "hand", "discard", "prizes"}) {
            if (!validate_card_array(owner.find(zone))) {
                return std::string("invalid_snapshot_zone:") + zone;
            }
        }
        const Value *active = owner.find("active");
        const Value *bench = owner.find("bench");
        if (
            active == nullptr || !validate_pokemon(*active)
            || bench == nullptr || !bench->is_array()
            || bench->as_array().size() != 5
            || !std::all_of(
                bench->as_array().begin(), bench->as_array().end(),
                validate_pokemon)
        ) {
            return "invalid_snapshot_board";
        }
    }
    const Value &stack = required(snapshot, "resolution_stack");
    const Value *frames = stack.find("frames");
    const Value *context = stack.find("context");
    const Value *pending = stack.find("pending_request");
    if (
        integer_field(stack, "schema_version", -1) != 3
        || integer_field(stack, "sequence", -1) < 0
        || frames == nullptr || !frames->is_array()
        || frames->as_array().size() > 64
        || context == nullptr || !context->is_object()
        || pending == nullptr
        || (!pending->is_null() && !pending->is_object())
    ) {
        return "invalid_resolution_stack";
    }
    return {};
}

} // namespace

std::string canonical_value_hash(const Value &value) {
    std::string canonical;
    append_canonical_json(canonical, value);
    return fnv1a64_hex(canonical);
}

RulesSession::RulesSession(Value cards)
    : game_() {
    if (cards.is_object() && !cards.as_object().empty()) {
        set_cards(std::move(cards));
    }
}

void RulesSession::set_cards(Value cards) {
    if (initialized_) {
        throw std::logic_error("cannot_replace_cards_during_match");
    }
    CatalogPayload catalog = normalize_catalog(cards);
    cards_ = std::move(catalog.cards);
    card_ir_content_fingerprint_ = std::move(catalog.content_fingerprint);
    card_ir_contract_fingerprint_ = std::move(catalog.contract_fingerprint);
    vm_descriptor_digest_ = std::move(catalog.descriptor_digest);
    game_.set_cards(cards_);
}

bool RulesSession::initialized() const noexcept {
    return initialized_;
}

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
    if (!cards_.is_object() || cards_.as_object().empty()) {
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
            if (card_id.empty() || cards_.find(card_id) == nullptr) {
                return result(false, "unknown_card", "unknown_card");
            }
            has_basic = has_basic || is_basic_pokemon(cards_, card_id);
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
        canonical_value_hash(cards_));
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
            cards_, state_, rng, events);
        rng_state_ = rng.state();
        if (!opening_error.empty()) {
            initialized_ = false;
            return result(false, opening_error, opening_error);
        }
    }
    append_public_event_logs(state_, cards_, state_, events);
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
        canonical_value_hash(cards_));
    match_config_["scenario_fingerprint"] = Value(
        canonical_value_hash(snapshot_value));
    match_config_["core_contract_fingerprint"] = Value(
        canonical_value_hash(contract()));
    initial_seed_ = rng_state_;
    journal_entries_ = Value::make_array();
    append_journal_entry("load_scenario", Value::make_object(), -1, {});
    return result(true, {}, "scenario_loaded");
}

Value RulesSession::legal_actions(std::int32_t actor) const {
    const auto failure = [this](const std::string &code) {
        return Value(Object{
            {"schema_version", Value(1)},
            {"success", Value(false)},
            {"code", Value(code)},
            {"message", Value(code)},
            {"base_revision", Value(revision())},
            {"groups", Value::make_array()},
        });
    };
    if (!initialized_) {
        return failure("not_started");
    }
    if (actor < 0 || actor > 1) {
        return failure("invalid_actor");
    }
    Array groups;
    if (pending_.is_null()) {
        const Value candidates = game_.legal_actions(state_, actor);
        if (!candidates.is_array()) {
            return failure("native_legal_action_error");
        }
        std::vector<std::string> signatures;
        for (const Value &candidate : candidates.as_array()) {
            if (!candidate.is_object()) {
                return failure("invalid_native_action");
            }
            Value signature(Object{
                {"base_revision", Value(integer_field(
                    candidate, "base_revision", revision()))},
                {"actor", Value(integer_field(candidate, "actor", actor))},
                {"kind", Value(string_field(candidate, "kind"))},
                {
                    "source",
                    candidate.find("source") == nullptr
                        ? Value() : candidate.find("source")->deep_clone(),
                },
                {
                    "payload",
                    candidate.find("payload") == nullptr
                        ? Value::make_object()
                        : candidate.find("payload")->deep_clone(),
                },
            });
            const std::string signature_hash = canonical_value_hash(signature);
            auto found = std::find(
                signatures.begin(), signatures.end(), signature_hash);
            if (found == signatures.end()) {
                signatures.push_back(signature_hash);
                Array targets;
                const Value *target = candidate.find("target");
                if (target != nullptr && !target->is_null()) {
                    targets.push_back(target->deep_clone());
                }
                groups.emplace_back(Object{
                    {"group_id", Value("native:" + signature_hash)},
                    {"base_revision", signature["base_revision"]},
                    {"actor", signature["actor"]},
                    {"kind", signature["kind"]},
                    {"source", signature["source"]},
                    {"payload", signature["payload"]},
                    {"targets", Value(std::move(targets))},
                });
                continue;
            }
            const std::size_t group_index = static_cast<std::size_t>(
                std::distance(signatures.begin(), found));
            const Value *target = candidate.find("target");
            if (target != nullptr && !target->is_null()) {
                Array &targets = required(groups[group_index], "targets").as_array();
                if (std::find(targets.begin(), targets.end(), *target)
                    == targets.end()) {
                    targets.push_back(target->deep_clone());
                }
            }
        }
    }
    return Value(Object{
        {"schema_version", Value(1)},
        {"success", Value(true)},
        {"code", Value("")},
        {"message", Value("")},
        {"base_revision", Value(revision())},
        {"groups", Value(std::move(groups))},
    });
}

std::int64_t RulesSession::pokemon_max_hp(const Value &pokemon) const {
    return game_.pokemon_max_hp(pokemon);
}

std::int64_t RulesSession::pokemon_current_hp(const Value &pokemon) const {
    return game_.pokemon_current_hp(pokemon);
}

std::int64_t RulesSession::estimate_public_damage(
    std::int32_t actor,
    const Value &attacker,
    const Value &defender,
    std::int64_t base_damage
) const {
    return initialized_ ? game_.estimate_public_damage(
        state_, actor, attacker, defender, base_damage) : 0;
}

Value RulesSession::pending_choice(std::int32_t viewer) const {
    if (
        !initialized_ || viewer < 0 || viewer > 1 || pending_.is_null()
        || integer_field(pending_, "player", -1) != viewer
    ) {
        return Value();
    }
    return pending_.deep_clone();
}

RulesSessionResult RulesSession::apply_action(const Value &submitted_action) {
    if (!initialized_) {
        return result(false, "not_started", "not_started");
    }
    if (!pending_.is_null()) {
        return result(false, "pending_choice", "pending_choice");
    }
    const std::string shape_error = validate_action_shape(submitted_action);
    if (!shape_error.empty()) {
        return result(false, shape_error, shape_error);
    }
    const std::int64_t revision_before = revision();
    Value action = submitted_action.deep_clone();
    const std::string action_id = string_field(action, "action_id");
    const Value *processed = state_.find("processed_action_ids");
    if (
        processed != nullptr && processed->is_array()
        && std::any_of(
            processed->as_array().begin(), processed->as_array().end(),
            [&action_id](const Value &entry) {
                return entry.string_or() == action_id;
            })
    ) {
        return result(false, "duplicate_action", "duplicate_action");
    }
    if (integer_field(submitted_action, "base_revision", -1) != revision_before) {
        return result(false, "stale_revision", "stale_revision");
    }
    const Value candidates = game_.legal_actions(
        state_, static_cast<std::int32_t>(integer_field(action, "actor", -1)));
    if (
        !candidates.is_array()
        || std::none_of(
            candidates.as_array().begin(), candidates.as_array().end(),
            [&action](const Value &candidate) {
                return action_equivalent(action, candidate);
            })
    ) {
        return result(false, "illegal_action", "illegal_action");
    }

    if (string_field(action, "kind") == "SETUP_DONE") {
        const Value previous_state = state_.deep_clone();
        Value next = state_.deep_clone();
        next["revision"] = Value(revision_before + 1);
        const std::int32_t actor = static_cast<std::int32_t>(
            integer_field(action, "actor", -1));
        std::vector<Value> events;
        const std::string stage = string_field(next, "setup_stage");
        if (stage == "BONUS_PLACEMENT") {
            finish_setup(next, events);
        } else if (stage == "INITIAL_PLACEMENT") {
            Value &ready = required(next, "setup_ready");
            ready.as_array()[static_cast<std::size_t>(actor)] = Value(true);
            if (
                !ready.as_array()[0].as_bool()
                || !ready.as_array()[1].as_bool()
            ) {
                next["setup_actor_idx"] = Value(1 - actor);
            } else {
                set_prizes(next);
                const Array &mulligans = required(next, "mulligan_count").as_array();
                std::int32_t bonus_player = -1;
                if (mulligans[1].as_integer() > mulligans[0].as_integer()) {
                    bonus_player = 0;
                } else if (mulligans[0].as_integer() > mulligans[1].as_integer()) {
                    bonus_player = 1;
                }
                if (
                    bonus_player >= 0
                    && integer_field(next, "mulligan_bonus_max") > 0
                ) {
                    next["setup_stage"] = Value("BONUS_DRAW");
                    next["setup_actor_idx"] = Value(bonus_player);
                } else {
                    finish_setup(next, events);
                }
            }
        } else {
            return result(false, "invalid_setup_stage", "invalid_setup_stage");
        }
        state_ = std::move(next);
        Array &ids = required(state_, "processed_action_ids").as_array();
        ids.emplace_back(action_id);
        if (ids.size() > 256) {
            ids.erase(ids.begin());
        }
        if (string_field(state_, "setup_stage") == "BONUS_DRAW") {
            const std::int32_t bonus_player = static_cast<std::int32_t>(
                integer_field(state_, "setup_actor_idx"));
            Array options;
            for (
                std::int64_t count = 0;
                count <= integer_field(state_, "mulligan_bonus_max");
                ++count
            ) {
                options.emplace_back(Object{
                    {"option_id", Value("draw:" + std::to_string(count))},
                    {"label", Value("抽" + std::to_string(count) + "张")},
                });
            }
            pending_ = setup_choice(
                state_, bonus_player, "choose_mulligan_draw_count",
                "请选择再战奖励抽牌数。", options,
                "choose_mulligan_draw_count");
            pending_raw_ = pending_;
            continuation_ = Value(Object{
                {"kind", Value("setup_mulligan_draw")},
                {"actor", Value(bonus_player)},
                {"max_draw", Value(integer_field(state_, "mulligan_bonus_max"))},
            });
            materialize_resolution_stack();
        } else {
            clear_resolution_stack();
        }
        append_submitted_action_log(
            state_, cards_, previous_state, action);
        append_public_event_logs(
            state_, cards_, previous_state, events);
        append_journal_entry("action", action, revision_before, events);
        return result(true, {}, "action_applied", std::move(events));
    }

    GameExecutionResult native_result = game_.apply_action(
        state_.deep_clone(), action, rng_state_);
    if (native_result.success) {
        Value &ids = required(native_result.state, "processed_action_ids");
        ids.as_array().emplace_back(action_id);
        if (ids.as_array().size() > 256) {
            ids.as_array().erase(ids.as_array().begin());
        }
        if (
            string_field(state_, "setup_stage") == "BONUS_PLACEMENT"
            && string_field(action, "kind") == "PLAY_BASIC"
        ) {
            const std::int32_t actor = static_cast<std::int32_t>(
                integer_field(action, "actor"));
            const Value *source = action.find("source");
            const std::string card_id = source == nullptr
                ? std::string{} : string_field(*source, "card_id");
            Value &bonus_rows = required(native_result.state, "setup_bonus_card_ids");
            Array &bonus = bonus_rows.as_array()[static_cast<std::size_t>(actor)].as_array();
            const auto found = std::find_if(
                bonus.begin(), bonus.end(),
                [&card_id](const Value &entry) {
                    return entry.string_or() == card_id;
                });
            if (found != bonus.end()) {
                bonus.erase(found);
            }
        }
        if (
            string_field(state_, "setup_stage") != "COMPLETE"
            && string_field(action, "kind") == "PLAY_BASIC"
        ) {
            const std::int32_t actor = static_cast<std::int32_t>(
                integer_field(action, "actor", -1));
            const std::string name = actor >= 0 && actor <= 1
                ? string_field(player(native_result.state, actor), "name")
                : std::string("玩家");
            required(native_result.state, "action_log").as_array().emplace_back(
                name + " 暗置宝可梦。"
            );
        }
        if (
            (string_field(action, "kind") == "PLAY_TRAINER"
                || string_field(action, "kind") == "RETREAT")
            && native_result.pending.is_object()
            && !native_result.pending.as_object().empty()
            && bool_field(native_result.pending, "can_cancel")
        ) {
            if (
                !native_result.continuation.is_object()
                || native_result.continuation.as_object().empty()
            ) {
                native_result.success = false;
                native_result.error_code = "missing_cancel_continuation";
            } else {
                Value *metadata = native_result.pending.find("metadata");
                if (metadata == nullptr || !metadata->is_object()) {
                    native_result.pending["metadata"] = Value::make_object();
                    metadata = native_result.pending.find("metadata");
                }
                (*metadata)["cancels_action"] = Value(true);
                const std::vector<Value> deferred_events = canonical_events(
                    native_result,
                    &state_,
                    &native_result.state,
                    &action,
                    static_cast<std::int32_t>(integer_field(
                        action, "actor", -1))
                );
                native_result.continuation["session_transaction"] = Value(Object{
                    {"state", state_.deep_clone()},
                    {"rng_state", Value(static_cast<std::int64_t>(rng_state_))},
                    {"deferred_events", Value(deferred_events)},
                    {"action", action.deep_clone()},
                });
                native_result.events.clear();
                native_result.event_types.clear();
            }
        }
    }
    return commit_game_result(
        native_result, "action", action, revision_before);
}

RulesSessionResult RulesSession::apply_choice(const Value &response) {
    if (!initialized_) {
        return result(false, "not_started", "not_started");
    }
    if (pending_.is_null()) {
        return result(false, "stale_choice", "stale_choice");
    }
    const std::string response_shape_error = validate_choice_response_shape(
        response);
    if (!response_shape_error.empty()) {
        return result(false, response_shape_error, response_shape_error);
    }
    if (
        string_field(response, "request_id")
            != string_field(pending_, "request_id")
        || integer_field(pending_, "base_revision", -1) != revision()
    ) {
        return result(false, "stale_choice", "stale_choice");
    }
    const bool cancelled = bool_field(response, "cancelled");
    const Value *selected_value = response.find("option_ids");
    if (selected_value == nullptr || !selected_value->is_array()) {
        return result(false, "invalid_choice", "invalid_choice");
    }
    const Array &selected_ids = selected_value->as_array();
    if (cancelled && !bool_field(pending_, "can_cancel")) {
        return result(
            false,
            "choice_not_cancellable",
            "choice_not_cancellable"
        );
    }
    if (!bool_field(pending_, "allow_duplicates")) {
        std::unordered_set<std::string> unique;
        for (const Value &selected_id : selected_ids) {
            if (!unique.insert(selected_id.string_or()).second) {
                return result(false, "duplicate_choice", "duplicate_choice");
            }
        }
    }
    if (
        !cancelled && (
            selected_ids.size() < static_cast<std::size_t>(
                std::max<std::int64_t>(0, integer_field(pending_, "min_select")))
            || selected_ids.size() > static_cast<std::size_t>(
                std::max<std::int64_t>(0, integer_field(pending_, "max_select")))
        )
    ) {
        return result(false, "choice_count", "choice_count");
    }
    Array raw_selected;
    if (!cancelled) {
        const Array &public_options = required(pending_, "options").as_array();
        const Array &raw_options = required(pending_raw_, "options").as_array();
        for (const Value &selected_id_value : selected_ids) {
            const std::string selected_id = selected_id_value.string_or();
            std::size_t matched = public_options.size();
            for (std::size_t index = 0; index < public_options.size(); ++index) {
                if (string_field(public_options[index], "option_id") == selected_id) {
                    matched = index;
                    break;
                }
            }
            if (matched >= public_options.size() || matched >= raw_options.size()) {
                return result(false, "invalid_choice", "invalid_choice");
            }
            raw_selected.push_back(raw_options[matched]);
        }
    }
    const std::int64_t revision_before = revision();
    const std::string continuation_kind = string_field(continuation_, "kind");
    if (continuation_kind == "setup_turn_order") {
        const Value previous_state = state_.deep_clone();
        const Value previous_pending = pending_.deep_clone();
        if (cancelled || selected_ids.size() != 1) {
            return result(false, "choice_count", "choice_count");
        }
        const std::string selected = selected_ids.front().string_or();
        if (selected != "turn:first" && selected != "turn:second") {
            return result(false, "invalid_choice", "invalid_choice");
        }
        Value next = state_.deep_clone();
        const std::int32_t coin_winner = static_cast<std::int32_t>(
            integer_field(next, "opening_coin_winner_idx"));
        const std::int32_t first = selected == "turn:first"
            ? coin_winner : 1 - coin_winner;
        next["revision"] = Value(revision_before + 1);
        next["first_player_idx"] = Value(first);
        next["active_player_idx"] = Value(first);
        std::vector<Value> events{
            event("turn_order_chosen", coin_winner, Value(Object{
                {"coin_winner", Value(coin_winner)},
                {"first_player", Value(first)},
            }))
        };
        XorShift32 rng(rng_state_);
        const std::string opening_error = prepare_opening_hands(
            cards_, next, rng, events);
        if (!opening_error.empty()) {
            return result(false, opening_error, opening_error);
        }
        state_ = std::move(next);
        rng_state_ = rng.state();
        pending_ = Value();
        pending_raw_ = Value();
        continuation_ = Value();
        clear_resolution_stack();
        append_choice_action_log(
            state_, previous_state, previous_pending, response);
        append_public_event_logs(
            state_, cards_, previous_state, events);
        append_journal_entry("choice", response, revision_before, events);
        return result(true, {}, "choice_applied", std::move(events));
    }
    if (continuation_kind == "setup_mulligan_draw") {
        const Value previous_state = state_.deep_clone();
        const Value previous_pending = pending_.deep_clone();
        if (cancelled || selected_ids.size() != 1) {
            return result(false, "choice_count", "choice_count");
        }
        const std::string selected = selected_ids.front().string_or();
        if (selected.rfind("draw:", 0) != 0) {
            return result(false, "invalid_choice", "invalid_choice");
        }
        const std::string amount_text = selected.substr(5);
        if (
            amount_text.empty()
            || std::any_of(amount_text.begin(), amount_text.end(), [](char value) {
                return !std::isdigit(static_cast<unsigned char>(value));
            })
        ) {
            return result(false, "invalid_choice", "invalid_choice");
        }
        const std::int64_t amount = std::stoll(amount_text);
        const std::int32_t actor = static_cast<std::int32_t>(
            integer_field(continuation_, "actor", -1));
        if (
            actor < 0 || actor > 1 || amount < 0
            || amount > integer_field(continuation_, "max_draw")
        ) {
            return result(false, "invalid_choice", "invalid_choice");
        }
        Value next = state_.deep_clone();
        next["revision"] = Value(revision_before + 1);
        Array drawn = draw_cards(player(next, actor), static_cast<std::size_t>(amount));
        required(next, "extra_draws").as_array()[static_cast<std::size_t>(actor)] =
            Value(static_cast<std::int64_t>(drawn.size()));
        required(next, "setup_bonus_card_ids").as_array()[
            static_cast<std::size_t>(actor)] = Value(drawn);
        std::vector<Value> events;
        if (!drawn.empty()) {
            events.push_back(event(
                "cards_drawn", actor,
                Value(Object{
                    {"player", Value(actor)},
                    {"count", Value(static_cast<std::int64_t>(drawn.size()))},
                    {"card_ids", Value(drawn)},
                    {"purpose", Value("mulligan_bonus")},
                }),
                "owner"
            ));
        }
        bool placeable = false;
        const Array &bench = required(player(next, actor), "bench").as_array();
        const bool bench_space = std::any_of(
            bench.begin(), bench.end(), [](const Value &entry) {
                return entry.is_null();
            });
        if (bench_space) {
            placeable = std::any_of(
                drawn.begin(), drawn.end(),
                [this](const Value &entry) {
                    return is_basic_pokemon(cards_, entry.string_or());
                });
        }
        if (placeable) {
            next["setup_stage"] = Value("BONUS_PLACEMENT");
            next["setup_actor_idx"] = Value(actor);
        } else {
            finish_setup(next, events);
        }
        state_ = std::move(next);
        pending_ = Value();
        pending_raw_ = Value();
        continuation_ = Value();
        clear_resolution_stack();
        append_choice_action_log(
            state_, previous_state, previous_pending, response);
        append_public_event_logs(
            state_, cards_, previous_state, events);
        append_journal_entry("choice", response, revision_before, events);
        return result(true, {}, "choice_applied", std::move(events));
    }

    const Value *session_transaction = continuation_.find(
        "session_transaction");
    if (cancelled && session_transaction != nullptr) {
        const Value previous_state = state_.deep_clone();
        const Value previous_pending = pending_.deep_clone();
        const Value *checkpoint_state = session_transaction->find("state");
        const Value *checkpoint_rng = session_transaction->find("rng_state");
        if (
            !session_transaction->is_object()
            || checkpoint_state == nullptr || !checkpoint_state->is_object()
            || checkpoint_rng == nullptr || !checkpoint_rng->is_number()
        ) {
            return result(
                false,
                "invalid_cancel_checkpoint",
                "invalid_cancel_checkpoint"
            );
        }
        const Value *stored_action = session_transaction->find("action");
        const Value transaction_action = stored_action != nullptr
            ? stored_action->deep_clone() : Value();
        Value restored = checkpoint_state->deep_clone();
        restored["revision"] = Value(revision_before + 1);
        state_ = std::move(restored);
        rng_state_ = static_cast<std::uint32_t>(checkpoint_rng->as_integer());
        pending_ = Value();
        pending_raw_ = Value();
        continuation_ = Value();
        clear_resolution_stack();
        std::vector<Value> events;
        if (
            transaction_action.is_object()
            && string_field(transaction_action, "kind") == "PLAY_TRAINER"
        ) {
            const Value *source = transaction_action.find("source");
            const std::int32_t actor = static_cast<std::int32_t>(
                integer_field(transaction_action, "actor", -1));
            const std::string card_id = source != nullptr && source->is_object()
                ? string_field(*source, "card_id") : std::string{};
            events.push_back(event(
                "card_moved",
                actor,
                Value(Object{
                    {"player", Value(actor)},
                    {"card_id", Value(card_id)},
                    {"card_ids", Value(Array{Value(card_id)})},
                    {"source_zone", Value("discard")},
                    {"target_zone", Value("hand")},
                    {"target_index", Value(source != nullptr
                        ? integer_field(*source, "index", -1) : -1)},
                    {"cause", Value("cancelled_trainer")},
                }),
                "private"
            ));
        }
        append_public_event_logs(
            state_, cards_, previous_state, events);
        append_journal_entry("choice", response, revision_before, events);
        return result(true, {}, "action_cancelled", events);
    }

    Value kernel_state = state_.deep_clone();
    kernel_state["resolution_stack"] = empty_resolution_stack();
    GameExecutionResult native_result = game_.resume_choice(
        std::move(kernel_state), continuation_, Value(raw_selected),
        cancelled, rng_state_);
    if (native_result.success && session_transaction != nullptr) {
        const Value *deferred_value = session_transaction->find(
            "deferred_events");
        if (deferred_value == nullptr || !deferred_value->is_array()) {
            return result(
                false,
                "invalid_cancel_checkpoint",
                "invalid_cancel_checkpoint"
            );
        }
        std::vector<Value> combined = deferred_value->as_array();
        const std::vector<Value> choice_events = canonical_events(
            native_result,
            &state_,
            &native_result.state,
            &response,
            static_cast<std::int32_t>(integer_field(
                pending_, "player", -1))
        );
        combined.insert(
            combined.end(), choice_events.begin(), choice_events.end());
        if (
            native_result.pending.is_object()
            && !native_result.pending.as_object().empty()
        ) {
            if (
                !native_result.continuation.is_object()
                || native_result.continuation.as_object().empty()
            ) {
                return result(
                    false,
                    "missing_cancel_continuation",
                    "missing_cancel_continuation"
                );
            }
            Value transaction = session_transaction->deep_clone();
            transaction["deferred_events"] = Value(combined);
            native_result.continuation["session_transaction"] = std::move(
                transaction);
            Value *metadata = native_result.pending.find("metadata");
            if (metadata == nullptr || !metadata->is_object()) {
                native_result.pending["metadata"] = Value::make_object();
                metadata = native_result.pending.find("metadata");
            }
            (*metadata)["cancels_action"] = Value(true);
            native_result.events.clear();
            native_result.event_types.clear();
        } else {
            native_result.events = std::move(combined);
            native_result.event_types.clear();
        }
    }
    return commit_game_result(
        native_result, "choice", response, revision_before);
}

RulesSessionResult RulesSession::concede(std::int32_t actor) {
    if (!initialized_) {
        return result(false, "not_started", "not_started");
    }
    if (actor < 0 || actor > 1) {
        return result(false, "invalid_actor", "invalid_actor");
    }
    if (terminal_from_state(state_)) {
        return result(false, "game_over", "game_over");
    }
    const std::int64_t revision_before = revision();
    const Value previous_state = state_.deep_clone();
    const std::int32_t winner = 1 - actor;
    state_["revision"] = Value(revision_before + 1);
    state_["winner"] = Value(winner);
    state_["result_status"] = Value("WIN");
    state_["result_reason"] = Value("surrender");
    state_["result_conditions"] = Value(Array{
        Value(winner == 0 ? Array{Value("opponent_surrendered")} : Array{}),
        Value(winner == 1 ? Array{Value("opponent_surrendered")} : Array{}),
    });
    state_["phase"] = Value("GAME_OVER");
    pending_ = Value();
    pending_raw_ = Value();
    continuation_ = Value();
    clear_resolution_stack();
    std::vector<Value> events{event(
        "game_over",
        winner,
        Value(Object{
            {"winner", Value(winner)},
            {"reason", Value("surrender")},
            {"surrendered_player", Value(actor)},
        }),
        "public"
    )};
    const Value input(Object{
        {"command", Value("surrender")},
        {"actor", Value(actor)},
    });
    append_action_log_line(
        state_, public_player_name(previous_state, actor) + " 放弃了对战。");
    append_public_event_logs(
        state_, cards_, previous_state, events);
    append_journal_entry("command", input, revision_before, events);
    return result(true, {}, "player_surrendered", std::move(events));
}

Value RulesSession::view_for(std::int32_t viewer) const {
    if (!initialized_ || viewer < 0 || viewer > 1) {
        return Value::make_object();
    }
    Value checkpoint_view;
    const Value *view_state = &state_;
    if (
        !pending_.is_null()
        && integer_field(pending_, "player", -1) != viewer
        && continuation_.is_object()
    ) {
        const Value *transaction = continuation_.find("session_transaction");
        const Value *checkpoint = transaction != nullptr && transaction->is_object()
            ? transaction->find("state") : nullptr;
        if (checkpoint != nullptr && checkpoint->is_object()) {
            checkpoint_view = checkpoint->deep_clone();
            checkpoint_view["revision"] = Value(revision());
            checkpoint_view["choice_sequence"] = Value(integer_field(
                state_, "choice_sequence"));
            view_state = &checkpoint_view;
        }
    }
    const bool hide_setup = string_field(
        *view_state, "setup_stage") != "COMPLETE";
    static const std::array<const char *, 27> public_fields = {
        "phase", "turn_number", "active_player_idx", "first_player_idx",
        "revision", "stadium_card_id", "stadium_owner_idx", "winner",
        "result_status", "result_reason", "result_conditions", "public_deck_keys",
        "apply_type_matchups", "rules_profile_id", "rules_options", "action_log",
        "mulligan_count", "extra_draws", "setup_ready", "setup_stage",
        "setup_actor_idx", "opening_coin_winner_idx", "mulligan_bonus_max",
        "pending_promotions", "turn_fact_book", "choice_sequence", "setup_bonus_card_ids",
    };
    Object view;
    for (const char *key : public_fields) {
        const Value *value = view_state->find(key);
        if (value != nullptr) {
            view[key] = value->deep_clone();
        }
    }
    // Private setup bookkeeping is never emitted even though it remains in the
    // authoritative Snapshot 3 state.
    view.erase("choice_sequence");
    view.erase("setup_bonus_card_ids");
    view["your"] = player_view(player(*view_state, viewer), true, false);
    view["opponent"] = player_view(
        player(*view_state, 1 - viewer), false, hide_setup);
    return Value(std::move(view));
}

Value RulesSession::snapshot() const {
    if (!initialized_) {
        return Value::make_object();
    }
    Value result = state_.deep_clone();
    result["snapshot_version"] = Value(SNAPSHOT_SCHEMA_VERSION);
    return result;
}

bool RulesSession::restore(
    const Value &snapshot_value,
    std::uint32_t rng_state,
    std::string *error
) {
    const auto fail = [error](const std::string &message) {
        if (error != nullptr) {
            *error = message;
        }
        return false;
    };
    if (!cards_.is_object() || cards_.as_object().empty()) {
        return fail("card_catalog_missing");
    }
    if (!snapshot_value.is_object()) {
        return fail("invalid_snapshot");
    }
    if (integer_field(snapshot_value, "snapshot_version", -1)
        != SNAPSHOT_SCHEMA_VERSION) {
        return fail("incompatible_snapshot");
    }
    const std::string payload_error = validate_snapshot_payload(
        snapshot_value, cards_);
    if (!payload_error.empty()) {
        return fail(payload_error);
    }
    const Value *players = snapshot_value.find("players");
    if (players == nullptr || !players->is_array() || players->as_array().size() != 2) {
        return fail("invalid_snapshot_players");
    }
    Value next_state = snapshot_value.deep_clone();
    next_state.erase("snapshot_version");
    Value next_pending;
    Value next_pending_raw;
    Value next_continuation;
    const Value *stack = next_state.find("resolution_stack");
    if (stack != nullptr && stack->is_object()) {
        const Value *pending = stack->find("pending_request");
        const Value *frames = stack->find("frames");
        const Value *context = stack->find("context");
        const bool has_pending_request = pending != nullptr && pending->is_object();
        if (
            frames == nullptr || !frames->is_array()
            || frames->as_array().size() != (has_pending_request ? 1U : 0U)
            || context == nullptr || !context->is_object()
            || !context->as_object().empty()
        ) {
            return fail("unsupported_legacy_continuation");
        }
        if (pending != nullptr && pending->is_object()) {
            next_pending_raw = pending->deep_clone();
            next_pending = public_choice(
                next_state,
                *pending,
                string_field(*pending, "request_id")
            );
        }
        if (frames != nullptr && frames->is_array() && !frames->as_array().empty()) {
            const Value &frame = frames->as_array().back();
            if (
                string_field(frame, "kind") != "continuation"
                || string_field(frame, "operation") != "native_rules_session"
            ) {
                return fail("unsupported_legacy_continuation");
            }
            const Value *data = frame.find("data");
            if (data == nullptr || !data->is_object()) {
                return fail("invalid_native_continuation");
            }
            const Value *raw = data->find("raw_pending");
            const Value *continuation = data->find("continuation");
            if (raw != nullptr) {
                next_pending_raw = raw->deep_clone();
            }
            if (continuation != nullptr) {
                next_continuation = continuation->deep_clone();
            }
        }
    }
    if (
        !next_pending.is_null()
        && (
            !next_pending_raw.is_object()
            || !next_continuation.is_object()
            || next_pending_raw.as_object().empty()
            || next_continuation.as_object().empty()
            || next_pending_raw.find("options") == nullptr
            || !next_pending_raw.find("options")->is_array()
            || next_pending_raw.find("options")->as_array().size()
                != next_pending.find("options")->as_array().size()
        )
    ) {
        return fail("invalid_native_continuation");
    }
    if (
        !next_pending.is_null()
        && (
            integer_field(next_pending, "schema_version", -1) != 2
            || string_field(next_pending, "request_id").empty()
            || integer_field(next_pending, "player", -1) < 0
            || integer_field(next_pending, "player", -1) > 1
            || integer_field(next_pending, "base_revision", -1)
                != integer_field(next_state, "revision", -2)
            || next_pending.find("options") == nullptr
            || !next_pending.find("options")->is_array()
        )
    ) {
        return fail("invalid_choice_view");
    }
    const Value *session_transaction = next_continuation.is_object()
        ? next_continuation.find("session_transaction") : nullptr;
    if (session_transaction != nullptr) {
        const Value *checkpoint = session_transaction->find("state");
        const Value *checkpoint_rng = session_transaction->find("rng_state");
        const Value *deferred = session_transaction->find("deferred_events");
        const Value *checkpoint_action = session_transaction->find("action");
        if (
            next_pending.is_null()
            || !session_transaction->is_object()
            || session_transaction->as_object().size() != 4
            || checkpoint == nullptr || !checkpoint->is_object()
            || checkpoint_rng == nullptr || !checkpoint_rng->is_number()
            || checkpoint_rng->as_integer() <= 0
            || checkpoint_rng->as_integer()
                > static_cast<std::int64_t>(std::numeric_limits<std::uint32_t>::max())
            || deferred == nullptr || !deferred->is_array()
            || deferred->as_array().size() > 4096
            || checkpoint_action == nullptr
            || !validate_action_shape(*checkpoint_action).empty()
        ) {
            return fail("invalid_cancel_checkpoint");
        }
        Value checkpoint_snapshot = checkpoint->deep_clone();
        checkpoint_snapshot["snapshot_version"] = Value(SNAPSHOT_SCHEMA_VERSION);
        const std::string checkpoint_error = validate_snapshot_payload(
            checkpoint_snapshot, cards_);
        if (!checkpoint_error.empty()) {
            return fail("invalid_cancel_checkpoint");
        }
        for (const Value &deferred_event : deferred->as_array()) {
            if (!deferred_event.is_object()) {
                return fail("invalid_cancel_checkpoint");
            }
        }
    }
    state_ = std::move(next_state);
    pending_ = std::move(next_pending);
    pending_raw_ = std::move(next_pending_raw);
    continuation_ = std::move(next_continuation);
    rng_state_ = rng_state == 0 ? 0x6D2B79F5U : rng_state;
    initialized_ = true;
    return true;
}

std::unique_ptr<RulesSession> RulesSession::fork() const {
    return std::make_unique<RulesSession>(*this);
}

Value RulesSession::contract() const {
    return Value(Object{
        {"native_abi_version", Value(NATIVE_RULES_SESSION_ABI_VERSION)},
        {"protocol_version", Value(6)},
        {"action_schema_version", Value(4)},
        {"choice_view_schema_version", Value(2)},
        {"snapshot_schema_version", Value(SNAPSHOT_SCHEMA_VERSION)},
        {"vm_ir_version", Value(3)},
        {"journal_format_version", Value(MATCH_JOURNAL_FORMAT_VERSION)},
        {"hash_algorithm", Value("fnv1a64-canonical-json")},
        {"card_ir_content_fingerprint", Value(
            card_ir_content_fingerprint_)},
        {"card_ir_contract_fingerprint", Value(
            card_ir_contract_fingerprint_)},
        {"vm_descriptor_digest", Value(vm_descriptor_digest_)},
        {"state_owner", Value("ptcg_core")},
        {"framework_dependencies", Value::make_array()},
        {"card_count", Value(static_cast<std::int64_t>(
            cards_.is_object() ? cards_.as_object().size() : 0))},
        {"implemented_op_count", Value(static_cast<std::int64_t>(
            game_.implemented_op_count()))},
        {"required_op_count", Value(static_cast<std::int64_t>(
            NativeGameKernel::required_op_count()))},
    });
}

Value RulesSession::journal() const {
    return Value(Object{
        {"schema", Value("ptcg_match_journal/1")},
        {"format_version", Value(MATCH_JOURNAL_FORMAT_VERSION)},
        {"native_abi_version", Value(NATIVE_RULES_SESSION_ABI_VERSION)},
        {"hash_algorithm", Value("fnv1a64-canonical-json")},
        {"initial_seed", Value(static_cast<std::int64_t>(initial_seed_))},
        {"catalog_fingerprint", Value(string_field(
            match_config_, "catalog_fingerprint"))},
        {"content_fingerprint", Value(card_ir_content_fingerprint_)},
        {"contract_fingerprint", Value(card_ir_contract_fingerprint_)},
        {"vm_descriptor_digest", Value(vm_descriptor_digest_)},
        {"match_config", match_config_.deep_clone()},
        {"entries", journal_entries_.deep_clone()},
    });
}

std::string RulesSession::state_hash() const {
    return initialized_ ? canonical_value_hash(state_) : std::string{};
}

std::uint32_t RulesSession::rng_state() const noexcept {
    return rng_state_;
}

std::int64_t RulesSession::revision() const noexcept {
    return initialized_ ? integer_field(state_, "revision", -1) : -1;
}

RulesSessionResult RulesSession::commit_game_result(
    const GameExecutionResult &native_result,
    const std::string &entry_kind,
    const Value &input,
    std::int64_t revision_before
) {
    if (!native_result.success) {
        return result(
            false,
            native_result.error_code.empty()
                ? "native_rule_error" : native_result.error_code,
            native_result.error_code.empty()
                ? "native_rule_error" : native_result.error_code
        );
    }
    const Value previous_state = state_;
    const Value previous_pending = pending_;
    const Value previous_pending_raw = pending_raw_;
    const Value previous_continuation = continuation_;
    const Value previous_journal = journal_entries_;
    const std::uint32_t previous_rng = rng_state_;
    try {
        const std::int32_t actor_hint = entry_kind == "action"
            ? static_cast<std::int32_t>(integer_field(input, "actor", -1))
            : static_cast<std::int32_t>(integer_field(
                pending_, "player", -1));
        std::vector<Value> events = canonical_events(
            native_result,
            &state_,
            &native_result.state,
            &input,
            actor_hint
        );
        state_ = native_result.state;
        rng_state_ = native_result.rng_state;
        set_pending(native_result.pending, native_result.continuation);
        if (entry_kind == "action") {
            append_submitted_action_log(
                state_, cards_, previous_state, input);
        } else if (entry_kind == "choice") {
            append_choice_action_log(
                state_, previous_state, previous_pending, input);
        }
        append_public_event_logs(
            state_, cards_, previous_state, events);
        append_journal_entry(entry_kind, input, revision_before, events);
        return result(true, {}, entry_kind + "_applied", std::move(events));
    } catch (const std::exception &) {
        state_ = previous_state;
        pending_ = previous_pending;
        pending_raw_ = previous_pending_raw;
        continuation_ = previous_continuation;
        journal_entries_ = previous_journal;
        rng_state_ = previous_rng;
        return result(
            false,
            "invalid_native_continuation",
            "invalid_native_continuation"
        );
    }
}

RulesSessionResult RulesSession::result(
    bool success,
    std::string error_code,
    std::string message_key,
    std::vector<Value> events
) const {
    RulesSessionResult output;
    output.success = success;
    output.error_code = std::move(error_code);
    output.message_key = std::move(message_key);
    output.state = initialized_ ? state_.deep_clone() : Value::make_object();
    output.pending = success ? pending_.deep_clone() : Value();
    output.events = std::move(events);
    output.rng_state = rng_state_;
    output.winner = initialized_ ? winner_from_state(state_) : -1;
    output.terminal = initialized_ && terminal_from_state(state_);
    return output;
}

void RulesSession::materialize_resolution_stack() {
    if (!initialized_) {
        return;
    }
    Array frames;
    if (!continuation_.is_null()) {
        frames.emplace_back(Object{
            {"kind", Value("continuation")},
            {"operation", Value("native_rules_session")},
            {"data", Value(Object{
                {"continuation", continuation_.deep_clone()},
                {"raw_pending", pending_raw_.deep_clone()},
            })},
        });
    }
    state_["resolution_stack"] = Value(Object{
        {"schema_version", Value(3)},
        {"frames", Value(std::move(frames))},
        {"pending_request", pending_.deep_clone()},
        {"sequence", Value(integer_field(state_, "choice_sequence"))},
        {"context", Value::make_object()},
    });
}

void RulesSession::clear_resolution_stack() {
    if (initialized_) {
        state_["resolution_stack"] = empty_resolution_stack();
    }
}

void RulesSession::set_pending(Value pending, Value continuation) {
    pending_ = Value();
    pending_raw_ = Value();
    continuation_ = Value();
    const bool has_pending = (
        pending.is_object() && !pending.as_object().empty()
    );
    const bool has_continuation = (
        continuation.is_object() && !continuation.as_object().empty()
    );
    if (has_pending != has_continuation) {
        throw std::invalid_argument("pending_continuation_mismatch");
    }
    if (has_pending) {
        pending_raw_ = pending.deep_clone();
        pending_ = public_choice(state_, pending_raw_);
        const Value *options = pending_.find("options");
        const std::int64_t minimum = integer_field(pending_, "min_select", -1);
        const std::int64_t maximum = integer_field(pending_, "max_select", -1);
        if (
            integer_field(pending_, "schema_version", -1) != 2
            || string_field(pending_, "request_id").empty()
            || integer_field(pending_, "base_revision", -1) != revision()
            || integer_field(pending_, "player", -1) < 0
            || integer_field(pending_, "player", -1) > 1
            || string_field(pending_, "request_type").empty()
            || options == nullptr || !options->is_array()
            || options->as_array().size() > 256
            || minimum < 0 || maximum < minimum || maximum > 256
        ) {
            throw std::invalid_argument("invalid_pending_choice");
        }
        std::unordered_set<std::string> option_ids;
        for (const Value &option : options->as_array()) {
            const std::string option_id = string_field(option, "option_id");
            if (option_id.empty() || !option_ids.insert(option_id).second) {
                throw std::invalid_argument("invalid_pending_options");
            }
        }
        continuation_ = std::move(continuation);
        if (string_field(pending_, "request_type") == "coin_flip") {
            const Value *vm = continuation_.find("vm");
            const Value *flips = vm != nullptr && vm->is_object()
                ? vm->find("flips") : nullptr;
            Value *presentation = pending_.find("presentation");
            if (
                flips != nullptr && flips->is_array()
                && presentation != nullptr && presentation->is_object()
            ) {
                (*presentation)["predetermined_flips"] = flips->deep_clone();
            }
        }
        materialize_resolution_stack();
    } else {
        clear_resolution_stack();
    }
}

void RulesSession::append_journal_entry(
    const std::string &kind,
    const Value &input,
    std::int64_t revision_before,
    const std::vector<Value> &events
) {
    if (!journal_entries_.is_array()) {
        journal_entries_ = Value::make_array();
    }
    Value events_value(events);
    journal_entries_.as_array().emplace_back(Object{
        {"index", Value(static_cast<std::int64_t>(journal_entries_.as_array().size()))},
        {"kind", Value(kind)},
        {"revision_before", Value(revision_before)},
        {"revision_after", Value(revision())},
        {"input", input.deep_clone()},
        {"state_hash", Value(state_hash())},
        {"event_hash", Value(canonical_value_hash(events_value))},
        {"rng_state", Value(static_cast<std::int64_t>(rng_state_))},
    });
}

} // namespace ptcg::ai
