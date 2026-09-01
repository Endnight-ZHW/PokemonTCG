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

using Array = Value::Array;
using Object = Value::Object;

const Value *field(const Value &value, const std::string &key) {
    return value.is_object() ? value.find(key) : nullptr;
}

std::string string_field(
    const Value &value,
    const std::string &key,
    std::string fallback
) {
    const Value *entry = field(value, key);
    return entry == nullptr ? std::move(fallback) : entry->string_or(
        std::move(fallback));
}

std::int64_t integer_field(
    const Value &value,
    const std::string &key,
    std::int64_t fallback
) {
    const Value *entry = field(value, key);
    return entry == nullptr ? fallback : entry->as_integer(fallback);
}

bool bool_field(
    const Value &value,
    const std::string &key,
    bool fallback
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
        || string_field(*card_ir, "format") != "ptcg_card_ir/4"
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
    std::int32_t actor,
    Value data,
    std::string visibility
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
    if (!cards.is_object()) return card_id;
    struct PublicNameCache {
        const Value::Object *identity = nullptr;
        std::size_t size = 0;
        std::string first_id;
        std::string last_id;
        std::unordered_map<std::string, std::string> labels;
    };
    thread_local PublicNameCache cache;
    const Value::Object &definitions = cards.as_object();
    const std::string first_id = definitions.empty()
        ? std::string{} : definitions.begin()->first;
    const std::string last_id = definitions.empty()
        ? std::string{} : definitions.rbegin()->first;
    if (
        cache.identity != &definitions || cache.size != definitions.size()
        || cache.first_id != first_id || cache.last_id != last_id
    ) {
        cache = PublicNameCache{};
        cache.identity = &definitions;
        cache.size = definitions.size();
        cache.first_id = first_id;
        cache.last_id = last_id;
        std::unordered_map<std::string, std::size_t> name_counts;
        for (const auto &[candidate_id, candidate] : definitions) {
            const std::string name = candidate.is_object()
                ? string_field(candidate, "name", candidate_id) : candidate_id;
            ++name_counts[name];
        }
        cache.labels.reserve(definitions.size());
        for (const auto &[candidate_id, candidate] : definitions) {
            const std::string name = candidate.is_object()
                ? string_field(candidate, "name", candidate_id) : candidate_id;
            cache.labels.emplace(
                candidate_id,
                name_counts[name] > 1
                    ? name + "（" + candidate_id + "）" : name
            );
        }
    }
    const auto found = cache.labels.find(card_id);
    return found == cache.labels.end() ? card_id : found->second;
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
    const std::string &fallback_card_id
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

namespace {

std::string public_disambiguated_card_name(
    const Value &cards,
    const std::string &card_id
) {
    return public_card_name(cards, card_id);
}

std::vector<std::string> public_event_card_ids(
    const Value &event_value,
    const Value &data
) {
    const Value *values = data.find("card_ids");
    if (values == nullptr || !values->is_array()) {
        values = data.find("cards");
    }
    if (values == nullptr || !values->is_array()) {
        values = data.find("selected_card_ids");
    }
    std::vector<std::string> result;
    if (values != nullptr && values->is_array()) {
        result.reserve(values->as_array().size());
        for (const Value &entry : values->as_array()) {
            const std::string card_id = entry.is_object()
                ? string_field(entry, "card_id") : entry.string_or();
            if (!card_id.empty()) {
                result.push_back(card_id);
            }
        }
    }
    if (result.empty()) {
        const std::string card_id = string_field(
            event_value, "card_id", string_field(data, "card_id"));
        if (!card_id.empty()) {
            result.push_back(card_id);
        }
    }
    return result;
}

std::string public_card_list(
    const Value &cards,
    const std::vector<std::string> &card_ids
) {
    std::vector<std::pair<std::string, std::int64_t>> counts;
    for (const std::string &card_id : card_ids) {
        const std::string label = public_disambiguated_card_name(
            cards, card_id);
        const auto found = std::find_if(
            counts.begin(),
            counts.end(),
            [&label](const auto &entry) { return entry.first == label; }
        );
        if (found == counts.end()) {
            counts.emplace_back(label, 1);
        } else {
            ++found->second;
        }
    }
    std::string result;
    for (const auto &[label, count] : counts) {
        if (!result.empty()) {
            result += "、";
        }
        result += label;
        if (count > 1) {
            result += "×" + std::to_string(count);
        }
    }
    return result;
}

bool has_selection_result_event(const std::vector<Value> &events) {
    return std::any_of(
        events.begin(),
        events.end(),
        [](const Value &event_value) {
            if (!event_value.is_object()) {
                return false;
            }
            const std::string event_type = string_field(
                event_value, "event_type");
            if (event_type == "cards_selected") {
                return true;
            }
            const Value *data = event_value.find("data");
            if (data == nullptr || !data->is_object()) {
                return false;
            }
            const bool public_identity = string_field(
                    event_value,
                    "visibility",
                    string_field(*data, "visibility", "public")
                ) == "public"
                && !public_event_card_ids(event_value, *data).empty();
            return public_identity && (
                event_type == "cards_discarded"
                || event_type == "energy_attached"
                || event_type == "tool_attached"
                || (event_type == "card_moved" && (
                    string_field(*data, "source_zone") == "discard"
                    || string_field(*data, "target_zone") == "bench"
                ))
            );
        }
    );
}

} // namespace

void append_choice_action_log(
    Value &state,
    const Value &before_state,
    const Value &pending,
    const Value &response,
    const std::vector<Value> &events
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
    // cards_selected carries the authoritative visibility and, when public,
    // the exact identities.  Let the event logger produce the one canonical
    // line instead of retaining the old generic "completed selection" entry.
    if (has_selection_result_event(events)) {
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
    } else if (request_type.find("search") != std::string::npos) {
        // Search results are logged only when their final visibility is known.
        // A deck-to-Bench search can suspend again for a slot before that
        // public movement occurs, so never commit a premature generic line.
        return;
    } else if (
        request_type.find("select") != std::string::npos
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
        const std::string visibility = string_field(
            event_value,
            "visibility",
            string_field(data, "visibility", "public")
        );
        std::optional<std::string> cached_card_list;
        const auto event_card_list = [&]() -> const std::string & {
            if (!cached_card_list.has_value()) {
                cached_card_list = visibility == "public"
                    ? public_card_list(
                        cards, public_event_card_ids(event_value, data))
                    : std::string{};
            }
            return *cached_card_list;
        };
        std::string line;
        if (event_type == "cards_drawn" && amount > 0) {
            line = public_player_name(state, target_player) + " 抽取了 "
                + std::to_string(amount) + " 张卡牌。";
        } else if (event_type == "cards_discarded" && amount > 0) {
            const std::string &card_list = event_card_list();
            line = public_player_name(state, target_player) + " 弃置了 "
                + (card_list.empty()
                    ? std::to_string(amount) + " 张卡牌" : card_list)
                + "。";
        } else if (event_type == "cards_selected" && amount > 0) {
            const std::string &card_list = event_card_list();
            if (card_list.empty()) {
                line = public_player_name(state, target_player) + " 选择了 "
                    + std::to_string(amount) + " 张卡牌（身份未公开）。";
            } else {
                const std::string source_zone = string_field(
                    data, "source_zone");
                const std::string target_zone = string_field(
                    data, "target_zone");
                line = public_player_name(state, target_player)
                    + (source_zone == "deck" ? " 展示了 " : " 公开选择了 ")
                    + card_list;
                if (target_zone == "hand") {
                    line += "，并加入手牌";
                }
                line += "。";
            }
        } else if (
            event_type == "cards_revealed"
            && visibility == "public"
            && !event_card_list().empty()
        ) {
            line = public_player_name(state, target_player) + " 公开了 "
                + event_card_list() + "。";
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
        } else if (event_type == "tool_attached" && amount > 0) {
            const std::string tool_id = string_field(
                event_value,
                "card_id",
                string_field(data, "card_id")
            );
            line = public_player_name(state, target_player) + " 将 "
                + (tool_id.empty()
                    ? std::to_string(amount) + " 张宝可梦道具"
                    : public_card_name(cards, tool_id))
                + " 附着到了 " + public_pokemon_name(
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
            const std::string &card_list = event_card_list();
            line = public_player_name(state, target_player) + " 将 "
                + (card_list.empty()
                    ? std::to_string(amount) + " 张手牌" : card_list)
                + " 放回了牌库。";
        } else if (
            event_type == "card_moved"
            && amount > 0
            && string_field(data, "source_zone") == "discard"
            && string_field(data, "target_zone") == "deck"
        ) {
            const std::string &card_list = event_card_list();
            line = public_player_name(state, target_player) + " 将 "
                + (card_list.empty()
                    ? std::to_string(amount) + " 张卡牌" : card_list)
                + " 从弃牌区放回了牌库。";
        } else if (
            event_type == "card_moved"
            && amount > 0
            && string_field(data, "target_zone") == "bench"
        ) {
            const std::string &card_list = event_card_list();
            line = public_player_name(state, target_player) + " 将 "
                + (card_list.empty()
                    ? std::to_string(amount) + " 张宝可梦" : card_list)
                + " 放到了备战区。";
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

} // namespace ptcg::ai::session_detail
