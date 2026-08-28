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
    const std::string &request_id_override
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

} // namespace ptcg::ai::session_detail
