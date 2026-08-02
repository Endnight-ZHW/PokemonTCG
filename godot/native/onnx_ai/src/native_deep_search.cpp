#include "native_deep_search.hpp"

#include "onnx_inference.hpp"
#include "ptcg_ai_core.hpp"
#include "ptcg_godot_value.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <limits>
#include <memory>
#include <stdexcept>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <godot_cpp/classes/json.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

namespace godot {

namespace {

std::string utf8_string(const String &source) {
    const CharString encoded = source.utf8();
    return std::string(encoded.get_data(), encoded.length());
}

Dictionary vm_result_dictionary(
    const ptcg::ai::VmExecutionResult &native_result
) {
    Dictionary result;
    result["success"] = native_result.success;
    result["error_code"] = String::utf8(
        native_result.error_code.c_str()
    );
    result["state"] = ptcg::ai::value_to_godot(native_result.state);
    result["context"] = ptcg::ai::value_to_godot(native_result.context);
    result["modifier"] = ptcg::ai::value_to_godot(native_result.modifier);
    result["pending"] = ptcg::ai::value_to_godot(native_result.pending);
    result["continuation"] = ptcg::ai::value_to_godot(
        native_result.continuation
    );
    Array events;
    for (const std::string &event : native_result.event_types) {
        events.push_back(String::utf8(event.c_str()));
    }
    result["event_types"] = events;
    result["events"] = ptcg::ai::value_to_godot(
        ptcg::ai::Value(native_result.events)
    );
    result["rng_state"] = static_cast<int64_t>(native_result.rng_state);
    return result;
}

Dictionary game_result_dictionary(
    const ptcg::ai::GameExecutionResult &native_result
) {
    Dictionary result;
    result["success"] = native_result.success;
    result["error_code"] = String::utf8(
        native_result.error_code.c_str()
    );
    result["state"] = ptcg::ai::value_to_godot(native_result.state);
    result["pending"] = ptcg::ai::value_to_godot(native_result.pending);
    result["continuation"] = ptcg::ai::value_to_godot(
        native_result.continuation
    );
    Array events;
    for (const std::string &event : native_result.event_types) {
        events.push_back(String::utf8(event.c_str()));
    }
    result["event_types"] = events;
    result["events"] = ptcg::ai::value_to_godot(
        ptcg::ai::Value(native_result.events)
    );
    result["rng_state"] = static_cast<int64_t>(native_result.rng_state);
    return result;
}

Dictionary vm_wrapper_error(const std::string &message) {
    Dictionary result;
    result["success"] = false;
    result["error_code"] = String::utf8(message.c_str());
    result["state"] = Dictionary();
    result["context"] = Dictionary();
    result["modifier"] = Dictionary();
    result["pending"] = Dictionary();
    result["continuation"] = Dictionary();
    result["event_types"] = Array();
    result["events"] = Array();
    result["rng_state"] = int64_t{0};
    return result;
}

Dictionary encoded_request_dictionary(
    const ptcg::ai::InferenceRequest &request
) {
    Dictionary result;
    result["success"] = true;
    PackedFloat32Array state_global;
    state_global.resize(request.state_global.size());
    std::copy(
        request.state_global.begin(),
        request.state_global.end(),
        state_global.ptrw()
    );
    PackedFloat32Array entity_numeric;
    entity_numeric.resize(request.entity_numeric.size());
    std::copy(
        request.entity_numeric.begin(),
        request.entity_numeric.end(),
        entity_numeric.ptrw()
    );
    PackedInt64Array entity_card_ids;
    entity_card_ids.resize(request.entity_card_ids.size());
    std::copy(
        request.entity_card_ids.begin(),
        request.entity_card_ids.end(),
        entity_card_ids.ptrw()
    );
    PackedInt64Array entity_type_ids;
    entity_type_ids.resize(request.entity_type_ids.size());
    std::copy(
        request.entity_type_ids.begin(),
        request.entity_type_ids.end(),
        entity_type_ids.ptrw()
    );
    PackedFloat32Array candidate_numeric;
    candidate_numeric.resize(request.candidate_numeric.size());
    std::copy(
        request.candidate_numeric.begin(),
        request.candidate_numeric.end(),
        candidate_numeric.ptrw()
    );
    PackedInt64Array candidate_card_ids;
    candidate_card_ids.resize(request.candidate_card_ids.size());
    std::copy(
        request.candidate_card_ids.begin(),
        request.candidate_card_ids.end(),
        candidate_card_ids.ptrw()
    );
    PackedInt64Array candidate_type_ids;
    candidate_type_ids.resize(request.candidate_type_ids.size());
    std::copy(
        request.candidate_type_ids.begin(),
        request.candidate_type_ids.end(),
        candidate_type_ids.ptrw()
    );
    PackedInt64Array candidate_refs;
    candidate_refs.resize(request.candidate_refs.size());
    std::copy(
        request.candidate_refs.begin(),
        request.candidate_refs.end(),
        candidate_refs.ptrw()
    );
    result["state_global"] = state_global;
    result["entity_numeric"] = entity_numeric;
    result["entity_card_ids"] = entity_card_ids;
    result["entity_type_ids"] = entity_type_ids;
    result["candidate_numeric"] = candidate_numeric;
    result["candidate_card_ids"] = candidate_card_ids;
    result["candidate_type_ids"] = candidate_type_ids;
    result["candidate_refs"] = candidate_refs;
    result["candidate_count"] = static_cast<int64_t>(
        request.candidate_count()
    );
    result["actor_deck_id"] = request.actor_deck_id;
    result["opponent_deck_id"] = request.opponent_deck_id;
    return result;
}

String stable_variant_signature(const Variant &value) {
    if (value.get_type() == Variant::DICTIONARY) {
        const Dictionary dictionary = value;
        PackedStringArray keys;
        const Array raw_keys = dictionary.keys();
        keys.resize(raw_keys.size());
        for (int64_t index = 0; index < raw_keys.size(); ++index) {
            keys.set(index, String(raw_keys[index]));
        }
        keys.sort();
        PackedStringArray parts;
        for (int64_t index = 0; index < keys.size(); ++index) {
            const String key = keys[index];
            parts.append(
                key
                    + String("=")
                    + stable_variant_signature(dictionary[key])
            );
        }
        return String("{") + String(",").join(parts) + String("}");
    }
    if (value.get_type() == Variant::ARRAY) {
        const Array values = value;
        PackedStringArray parts;
        for (int64_t index = 0; index < values.size(); ++index) {
            parts.append(stable_variant_signature(values[index]));
        }
        return String("[") + String(",").join(parts) + String("]");
    }
    return JSON::stringify(value);
}

Dictionary stable_entity_ref(const Variant &value) {
    Dictionary result;
    if (value.get_type() != Variant::DICTIONARY) {
        return result;
    }
    const Dictionary reference = value;
    result["kind"] = String(reference.get("kind", ""));
    result["player"] = int64_t(reference.get("player", -1));
    constexpr const char *fields[] = {
        "zone",
        "slot",
        "attachment_type",
        "card_id",
    };
    for (const char *field : fields) {
        const String field_value = String(reference.get(field, ""));
        if (!field_value.is_empty()) {
            result[field] = field_value;
        }
    }
    return result;
}

struct PackedInferenceBatch {
    PackedFloat32Array state_global;
    PackedFloat32Array entity_numeric;
    PackedInt64Array entity_card_ids;
    PackedInt64Array entity_type_ids;
    PackedFloat32Array candidate_numeric;
    PackedInt64Array candidate_card_ids;
    PackedInt64Array candidate_type_ids;
    PackedInt64Array candidate_refs;
    PackedByteArray candidate_mask;
    PackedInt64Array actor_deck_ids;
    PackedInt64Array opponent_deck_ids;
    std::size_t candidate_count = 0;
};

PackedInferenceBatch pack_inference_requests(
    const std::vector<ptcg::ai::InferenceRequest> &requests
) {
    if (requests.empty()) {
        throw std::invalid_argument("empty_runtime_inference_batch");
    }
    PackedInferenceBatch result;
    for (const auto &request : requests) {
        request.validate();
        result.candidate_count = std::max(
            result.candidate_count,
            request.candidate_count()
        );
    }
    const std::size_t batch_size = requests.size();
    const std::size_t candidate_rows =
        batch_size * result.candidate_count;
    result.state_global.resize(
        batch_size * ptcg::ai::STATE_GLOBAL_SIZE
    );
    result.entity_numeric.resize(
        batch_size
            * ptcg::ai::ENTITY_SLOTS
            * ptcg::ai::ENTITY_NUMERIC_SIZE
    );
    result.entity_card_ids.resize(
        batch_size * ptcg::ai::ENTITY_SLOTS
    );
    result.entity_type_ids.resize(
        batch_size
            * ptcg::ai::ENTITY_SLOTS
            * ptcg::ai::ENTITY_TYPE_FIELDS
    );
    result.candidate_numeric.resize(
        candidate_rows * ptcg::ai::CANDIDATE_NUMERIC_SIZE
    );
    result.candidate_card_ids.resize(candidate_rows);
    result.candidate_type_ids.resize(candidate_rows);
    result.candidate_refs.resize(
        candidate_rows * ptcg::ai::CANDIDATE_REF_FIELDS
    );
    result.candidate_mask.resize(candidate_rows);
    result.actor_deck_ids.resize(batch_size);
    result.opponent_deck_ids.resize(batch_size);
    std::fill_n(
        result.candidate_numeric.ptrw(),
        result.candidate_numeric.size(),
        0.0F
    );
    std::fill_n(
        result.candidate_card_ids.ptrw(),
        result.candidate_card_ids.size(),
        std::int64_t{0}
    );
    std::fill_n(
        result.candidate_type_ids.ptrw(),
        result.candidate_type_ids.size(),
        std::int64_t{0}
    );
    std::fill_n(
        result.candidate_refs.ptrw(),
        result.candidate_refs.size(),
        std::int64_t{0}
    );
    std::fill_n(
        result.candidate_mask.ptrw(),
        result.candidate_mask.size(),
        std::uint8_t{0}
    );
    for (std::size_t row = 0; row < batch_size; ++row) {
        const auto &request = requests[row];
        std::copy(
            request.state_global.begin(),
            request.state_global.end(),
            result.state_global.ptrw()
                + row * ptcg::ai::STATE_GLOBAL_SIZE
        );
        std::copy(
            request.entity_numeric.begin(),
            request.entity_numeric.end(),
            result.entity_numeric.ptrw()
                + row
                    * ptcg::ai::ENTITY_SLOTS
                    * ptcg::ai::ENTITY_NUMERIC_SIZE
        );
        std::copy(
            request.entity_card_ids.begin(),
            request.entity_card_ids.end(),
            result.entity_card_ids.ptrw()
                + row * ptcg::ai::ENTITY_SLOTS
        );
        std::copy(
            request.entity_type_ids.begin(),
            request.entity_type_ids.end(),
            result.entity_type_ids.ptrw()
                + row
                    * ptcg::ai::ENTITY_SLOTS
                    * ptcg::ai::ENTITY_TYPE_FIELDS
        );
        const std::size_t candidate_offset =
            row * result.candidate_count;
        std::copy(
            request.candidate_numeric.begin(),
            request.candidate_numeric.end(),
            result.candidate_numeric.ptrw()
                + candidate_offset
                    * ptcg::ai::CANDIDATE_NUMERIC_SIZE
        );
        std::copy(
            request.candidate_card_ids.begin(),
            request.candidate_card_ids.end(),
            result.candidate_card_ids.ptrw() + candidate_offset
        );
        std::copy(
            request.candidate_type_ids.begin(),
            request.candidate_type_ids.end(),
            result.candidate_type_ids.ptrw() + candidate_offset
        );
        std::copy(
            request.candidate_refs.begin(),
            request.candidate_refs.end(),
            result.candidate_refs.ptrw()
                + candidate_offset
                    * ptcg::ai::CANDIDATE_REF_FIELDS
        );
        std::fill_n(
            result.candidate_mask.ptrw() + candidate_offset,
            request.candidate_count(),
            std::uint8_t{1}
        );
        result.actor_deck_ids.set(row, request.actor_deck_id);
        result.opponent_deck_ids.set(
            row,
            request.opponent_deck_id
        );
    }
    return result;
}

std::vector<float> softmax_logits(
    const PackedFloat32Array &logits,
    std::size_t offset,
    std::size_t count
) {
    if (count == 0 || offset + count > static_cast<std::size_t>(
        logits.size()
    )) {
        throw std::invalid_argument("runtime_output_shape_mismatch");
    }
    float maximum = -std::numeric_limits<float>::infinity();
    for (std::size_t index = 0; index < count; ++index) {
        const float value = logits[
            static_cast<int64_t>(offset + index)
        ];
        if (!std::isfinite(value)) {
            throw std::invalid_argument("non_finite_model_output");
        }
        maximum = std::max(maximum, value);
    }
    std::vector<float> result(count);
    double total = 0.0;
    for (std::size_t index = 0; index < count; ++index) {
        result[index] = std::exp(
            logits[static_cast<int64_t>(offset + index)] - maximum
        );
        total += result[index];
    }
    if (!(total > 0.0) || !std::isfinite(total)) {
        throw std::invalid_argument("invalid_model_softmax");
    }
    for (float &value : result) {
        value = static_cast<float>(value / total);
    }
    return result;
}

std::string string_field(
    const ptcg::ai::Value &value,
    const std::string &key,
    std::string fallback = {}
) {
    const ptcg::ai::Value *field = value.find(key);
    return field == nullptr
        ? std::move(fallback)
        : field->string_or(std::move(fallback));
}

std::int64_t integer_field(
    const ptcg::ai::Value &value,
    const std::string &key,
    std::int64_t fallback = 0
) {
    const ptcg::ai::Value *field = value.find(key);
    return field == nullptr ? fallback : field->as_integer(fallback);
}

bool boolean_field(
    const ptcg::ai::Value &value,
    const std::string &key,
    bool fallback = false
) {
    const ptcg::ai::Value *field = value.find(key);
    return field == nullptr ? fallback : field->as_bool(fallback);
}

bool is_hidden_choice_zone(const std::string &zone) {
    return zone == "deck"
        || zone == "hand"
        || zone == "prize"
        || zone == "prizes";
}

void validate_public_choice_ref(
    const ptcg::ai::Value &reference,
    std::int32_t actor
) {
    if (!reference.is_object()) {
        throw std::invalid_argument("invalid_public_choice_reference");
    }
    static const std::unordered_set<std::string> allowed_fields = {
        "kind",
        "player",
        "zone",
        "slot",
        "index",
        "attachment_type",
        "card_id",
    };
    for (const auto &[field, _value] : reference.as_object()) {
        if (allowed_fields.find(field) == allowed_fields.end()) {
            throw std::invalid_argument(
                "invalid_public_choice_reference"
            );
        }
    }
    const std::string kind = string_field(reference, "kind");
    if (
        kind != "card"
        && kind != "pokemon"
        && kind != "slot"
        && kind != "attachment"
    ) {
        throw std::invalid_argument("invalid_public_choice_reference");
    }
    const std::int64_t player = integer_field(
        reference,
        "player",
        -1
    );
    if (player != 0 && player != 1) {
        throw std::invalid_argument("invalid_public_choice_reference");
    }
    const std::string zone = string_field(reference, "zone");
    if (
        kind == "card"
        && (
            (is_hidden_choice_zone(zone) && player != actor)
            || zone == "prize"
            || zone == "prizes"
        )
    ) {
        throw std::invalid_argument(
            "opponent_hidden_choice_reference_rejected"
        );
    }
}

void merge_reference_value(ptcg::ai::Value &option) {
    ptcg::ai::Value *reference = option.find("ref");
    if (reference == nullptr || !reference->is_object()) {
        return;
    }
    ptcg::ai::Value *value = option.find("value");
    if (value == nullptr || !value->is_object()) {
        option["value"] = ptcg::ai::Value::make_object();
        value = option.find("value");
    }
    constexpr const char *fields[] = {
        "player",
        "zone",
        "slot",
        "index",
        "attachment_type",
        "card_id",
    };
    for (const char *field : fields) {
        const ptcg::ai::Value *source = reference->find(field);
        if (source != nullptr) {
            (*value)[field] = *source;
        }
    }
}

ptcg::ai::Value public_choice_pending(
    const ptcg::ai::Value &choice,
    const ptcg::ai::Value &cached_pending,
    std::int32_t actor
) {
    using ptcg::ai::Value;
    if (!choice.is_object()) {
        throw std::invalid_argument("invalid_public_choice_view");
    }
    const std::string request_id = string_field(choice, "request_id");
    const std::string request_type = string_field(
        choice,
        "request_type"
    );
    const std::int64_t player = integer_field(choice, "player", -1);
    const std::int64_t minimum = integer_field(
        choice,
        "min_select",
        -1
    );
    const std::int64_t maximum = integer_field(
        choice,
        "max_select",
        -1
    );
    const Value *public_options = choice.find("options");
    if (
        request_id.empty()
        || request_type.empty()
        || player != actor
        || minimum < 0
        || maximum < minimum
        || maximum > 64
        || public_options == nullptr
        || !public_options->is_array()
        || public_options->as_array().size() > 256
    ) {
        throw std::invalid_argument("invalid_public_choice_view");
    }
    if (
        !cached_pending.is_object()
        || cached_pending.as_object().empty()
        || (
            !string_field(cached_pending, "request_type").empty()
            && string_field(cached_pending, "request_type")
                != request_type
        )
    ) {
        throw std::invalid_argument(
            "native_choice_context_mismatch"
        );
    }

    std::unordered_map<std::string, Value> cached_by_id;
    const Value *cached_options = cached_pending.find("options");
    if (cached_options != nullptr && cached_options->is_array()) {
        for (const Value &option : cached_options->as_array()) {
            const std::string option_id = string_field(
                option,
                "option_id"
            );
            if (!option_id.empty()) {
                cached_by_id.emplace(option_id, option);
            }
        }
    }

    Value::Array merged_options;
    merged_options.reserve(public_options->as_array().size());
    std::unordered_set<std::string> option_ids;
    for (const Value &public_option : public_options->as_array()) {
        if (!public_option.is_object()) {
            throw std::invalid_argument(
                "invalid_public_choice_option"
            );
        }
        constexpr const char *private_fields[] = {
            "value",
            "continuation",
            "guard",
            "command",
            "commands",
            "checkpoint",
            "snapshot",
        };
        for (const char *field : private_fields) {
            if (public_option.find(field) != nullptr) {
                throw std::invalid_argument(
                    "private_choice_payload_rejected"
                );
            }
        }
        const std::string option_id = string_field(
            public_option,
            "option_id"
        );
        if (
            option_id.empty()
            || !option_ids.insert(option_id).second
        ) {
            throw std::invalid_argument(
                "duplicate_public_choice_option"
            );
        }
        Value merged = public_option;
        const auto cached = cached_by_id.find(option_id);
        if (cached != cached_by_id.end()) {
            merged = cached->second;
            merged["option_id"] = Value(option_id);
            const Value *label = public_option.find("label");
            if (label != nullptr) {
                merged["label"] = *label;
            }
        }
        const Value *reference = public_option.find("ref");
        if (reference != nullptr) {
            validate_public_choice_ref(*reference, actor);
            merged["ref"] = *reference;
            merge_reference_value(merged);
        } else {
            merged.erase("ref");
            if (cached == cached_by_id.end()) {
                merged.erase("value");
            }
        }
        merged_options.push_back(std::move(merged));
    }

    Value::Object metadata;
    const Value *cached_metadata = cached_pending.find("metadata");
    if (cached_metadata != nullptr && cached_metadata->is_object()) {
        metadata = cached_metadata->as_object();
    }
    const Value *presentation = choice.find("presentation");
    if (presentation != nullptr) {
        if (!presentation->is_object()) {
            throw std::invalid_argument(
                "invalid_public_choice_presentation"
            );
        }
        if (
            presentation->find("continuation") != nullptr
            || presentation->find("_resume") != nullptr
        ) {
            throw std::invalid_argument(
                "private_choice_payload_rejected"
            );
        }
        const Value *revealed = presentation->find(
            "revealed_card_ids"
        );
        if (revealed != nullptr) {
            if (!revealed->is_array()) {
                throw std::invalid_argument(
                    "invalid_revealed_choice_cards"
                );
            }
            for (const Value &card_id : revealed->as_array()) {
                if (!card_id.is_string() || card_id.string_or().empty()) {
                    throw std::invalid_argument(
                        "invalid_revealed_choice_cards"
                    );
                }
            }
            metadata["continuation"] = Value(Value::Object{
                {"top_card_ids", *revealed},
            });
        }
    }

    return Value(Value::Object{
        {"request_id", Value(request_id)},
        {"request_type", Value(request_type)},
        {"player", Value(actor)},
        {"min_select", Value(minimum)},
        {"max_select", Value(maximum)},
        {
            "allow_duplicates",
            Value(boolean_field(choice, "allow_duplicates"))
        },
        {"can_cancel", Value(boolean_field(choice, "can_cancel"))},
        {"options", Value(std::move(merged_options))},
        {"metadata", Value(std::move(metadata))},
    });
}

std::string choice_signature(const ptcg::ai::Value &candidate) {
    return string_field(candidate, "signature");
}

} // namespace

void NativeDeepSearch::_bind_methods() {
    ClassDB::bind_method(
        D_METHOD("decide", "request", "cancel_check", "inference"),
        &NativeDeepSearch::decide
    );
    ClassDB::bind_method(
        D_METHOD(
            "information_set_hash_v2",
            "public_words",
            "actor_private_words",
            "actor"
        ),
        &NativeDeepSearch::information_set_hash_v2
    );
    ClassDB::bind_method(
        D_METHOD(
            "puct_select",
            "priors",
            "visits",
            "value_sums",
            "c_puct"
        ),
        &NativeDeepSearch::puct_select,
        DEFVAL(C_PUCT)
    );
    ClassDB::bind_method(
        D_METHOD("get_contract"),
        &NativeDeepSearch::get_contract
    );
    ClassDB::bind_method(
        D_METHOD("vm_set_cards", "cards"),
        &NativeDeepSearch::vm_set_cards
    );
    ClassDB::bind_method(
        D_METHOD("simulation_set_decks", "decks"),
        &NativeDeepSearch::simulation_set_decks
    );
    ClassDB::bind_method(
        D_METHOD(
            "vm_execute",
            "state",
            "command_spec",
            "actor",
            "source_slot",
            "seed",
            "context_mode"
        ),
        &NativeDeepSearch::vm_execute
    );
    ClassDB::bind_method(
        D_METHOD(
            "vm_resume",
            "state",
            "context",
            "continuation",
            "selected_options",
            "cancelled",
            "rng_state"
        ),
        &NativeDeepSearch::vm_resume
    );
    ClassDB::bind_method(
        D_METHOD("vm_contract"),
        &NativeDeepSearch::vm_contract
    );
    ClassDB::bind_method(
        D_METHOD("game_apply_action", "state", "action", "rng_state"),
        &NativeDeepSearch::game_apply_action
    );
    ClassDB::bind_method(
        D_METHOD("game_legal_actions", "state", "actor"),
        &NativeDeepSearch::game_legal_actions
    );
    ClassDB::bind_method(
        D_METHOD("game_choice_candidates", "request"),
        &NativeDeepSearch::game_choice_candidates
    );
    ClassDB::bind_method(
        D_METHOD(
            "game_resume_choice",
            "state",
            "continuation",
            "selected_options",
            "cancelled",
            "rng_state"
        ),
        &NativeDeepSearch::game_resume_choice
    );
    ClassDB::bind_method(
        D_METHOD("validate_runtime_snapshot", "state", "actor"),
        &NativeDeepSearch::validate_runtime_snapshot
    );
    ClassDB::bind_method(
        D_METHOD("project_information_set", "state", "actor"),
        &NativeDeepSearch::project_information_set
    );
    ClassDB::bind_method(
        D_METHOD("encode_actions_v7", "state", "actor", "actions"),
        &NativeDeepSearch::encode_actions_v7
    );
    ClassDB::bind_method(
        D_METHOD(
            "encode_choices_v7",
            "state",
            "actor",
            "request",
            "candidates"
        ),
        &NativeDeepSearch::encode_choices_v7
    );
    ClassDB::bind_method(
        D_METHOD(
            "determinize_information_set",
            "state",
            "actor",
            "seed"
        ),
        &NativeDeepSearch::determinize_information_set
    );
    ClassDB::bind_method(
        D_METHOD("action_signature_v2", "action"),
        &NativeDeepSearch::action_signature_v2
    );
}

Dictionary NativeDeepSearch::decide(
    const Dictionary &request,
    const Callable &cancel_check,
    const Variant &inference
) {
    const auto started = std::chrono::steady_clock::now();
    Dictionary result;
    result["success"] = false;
    result["cancelled"] = false;
    result["planner"] = "infoset_puct_v2";
    result["request_id"] = String(request.get("request_id", ""));
    result["revision"] = int64_t(request.get("revision", -1));
    result["simulations"] = 0;
    result["degraded_deadline"] = false;
    try {
        if (
            cancel_check.is_valid()
            && bool(cancel_check.call())
        ) {
            result["cancelled"] = true;
            result["error"] = "cancelled";
            throw std::runtime_error("runtime_result_ready");
        }
        const Variant state_value = request.get("state", Variant());
        const int64_t actor = int64_t(request.get("actor", -1));
        if (state_value.get_type() != Variant::DICTIONARY) {
            result["error"] = "invalid_runtime_snapshot";
            throw std::runtime_error("runtime_result_ready");
        }
        if (actor != 0 && actor != 1) {
            result["error"] = "invalid_runtime_actor";
            throw std::runtime_error("runtime_result_ready");
        }
        const ptcg::ai::Value native_state =
            ptcg::ai::value_from_godot(state_value);
        const std::string boundary_error =
            ptcg::ai::validate_runtime_snapshot(
                native_state,
                static_cast<std::int32_t>(actor)
            );
        if (!boundary_error.empty()) {
            // Do not continue into inference/search after any private ID
            // crosses the public client boundary.
            result["error"] = "hidden_information_violation";
            result["hidden_information_error"] = String::utf8(
                boundary_error.c_str()
            );
            throw std::runtime_error("runtime_result_ready");
        }
        const std::string request_kind = utf8_string(
            String(request.get("kind", "action"))
        );
        if (request_kind != "action" && request_kind != "choice") {
            choice_context_valid_ = false;
            result["error"] = "invalid_runtime_request_kind";
            throw std::runtime_error("runtime_result_ready");
        }
        if (inference.get_type() == Variant::NIL) {
            result["error"] = "runtime_unavailable";
            throw std::runtime_error("runtime_result_ready");
        }
        OnnxInference *backend = Object::cast_to<OnnxInference>(
            inference.get_validated_object()
        );
        if (backend == nullptr || !backend->is_loaded()) {
            result["error"] = "runtime_unavailable";
            throw std::runtime_error("runtime_result_ready");
        }
        if (
            !cards_.is_object()
            || cards_.as_object().empty()
            || !decks_.is_object()
            || decks_.as_object().empty()
        ) {
            result["error"] = "native_catalog_not_configured";
            throw std::runtime_error("runtime_result_ready");
        }

        std::unordered_set<std::string> authoritative_signatures;
        std::unordered_set<std::string> root_choice_signatures;
        ptcg::ai::Value root_pending =
            ptcg::ai::Value::make_object();
        ptcg::ai::Value root_continuation =
            ptcg::ai::Value::make_object();
        if (request_kind == "action") {
            // Every action request consumes any prior one-shot choice
            // continuation, including a continuation left behind by a
            // cancelled/fallback request.
            choice_context_valid_ = false;
            choice_context_pending_ = ptcg::ai::Value::make_object();
            choice_context_continuation_ =
                ptcg::ai::Value::make_object();
            choice_context_match_id_.clear();
            choice_context_revision_ = -1;
            choice_context_actor_ = -1;
            const Variant action_rows_value = request.get(
                "actions",
                Variant()
            );
            if (action_rows_value.get_type() != Variant::ARRAY) {
                result["error"] =
                    "authoritative_legal_actions_missing";
                throw std::runtime_error("runtime_result_ready");
            }
            const Array authoritative_rows = action_rows_value;
            const ptcg::ai::Value native_rows =
                game_kernel_.legal_actions(
                    native_state,
                    static_cast<std::int32_t>(actor)
                );
            const Array generated_rows = Array(
                ptcg::ai::value_to_godot(native_rows)
            );
            std::unordered_set<std::string> generated_signatures;
            for (
                int64_t index = 0;
                index < authoritative_rows.size();
                ++index
            ) {
                if (
                    authoritative_rows[index].get_type()
                    != Variant::DICTIONARY
                ) {
                    result["error"] = "invalid_authoritative_action";
                    throw std::runtime_error(
                        "runtime_result_ready"
                    );
                }
                authoritative_signatures.insert(utf8_string(
                    action_signature_v2(
                        Dictionary(authoritative_rows[index])
                    )
                ));
            }
            for (
                int64_t index = 0;
                index < generated_rows.size();
                ++index
            ) {
                generated_signatures.insert(utf8_string(
                    action_signature_v2(
                        Dictionary(generated_rows[index])
                    )
                ));
            }
            if (
                authoritative_signatures.size()
                    != static_cast<std::size_t>(
                        authoritative_rows.size()
                    )
                || generated_signatures.size()
                    != static_cast<std::size_t>(
                        generated_rows.size()
                    )
                || authoritative_signatures
                    != generated_signatures
            ) {
                result["error"] =
                    "native_legal_action_set_mismatch";
                result["authoritative_action_count"] =
                    authoritative_rows.size();
                result["native_action_count"] =
                    generated_rows.size();
                throw std::runtime_error("runtime_result_ready");
            }
        } else {
            const bool context_matches = (
                choice_context_valid_
                && choice_context_actor_ == actor
                && choice_context_revision_
                    == int64_t(request.get("revision", -1))
                && choice_context_match_id_
                    == utf8_string(String(request.get(
                        "match_instance_id",
                        ""
                    )))
            );
            ptcg::ai::Value cached_pending =
                choice_context_pending_;
            root_continuation = choice_context_continuation_;
            // The continuation is deliberately one-shot. A failed or
            // cancelled choice falls back to the formal engine and must not
            // make a later request reuse stale transaction state.
            choice_context_valid_ = false;
            choice_context_pending_ = ptcg::ai::Value::make_object();
            choice_context_continuation_ =
                ptcg::ai::Value::make_object();
            choice_context_match_id_.clear();
            choice_context_revision_ = -1;
            choice_context_actor_ = -1;
            if (!context_matches) {
                result["error"] =
                    "native_choice_continuation_unavailable";
                throw std::runtime_error("runtime_result_ready");
            }
            const Variant choice_value = request.get(
                "choice",
                Variant()
            );
            if (choice_value.get_type() != Variant::DICTIONARY) {
                result["error"] = "invalid_public_choice_view";
                throw std::runtime_error("runtime_result_ready");
            }
            root_pending = public_choice_pending(
                ptcg::ai::value_from_godot(choice_value),
                cached_pending,
                static_cast<std::int32_t>(actor)
            );
            const ptcg::ai::Value root_candidates =
                game_kernel_.choice_candidates(root_pending);
            if (
                !root_candidates.is_array()
                || root_candidates.as_array().empty()
            ) {
                result["error"] =
                    "authoritative_legal_choices_missing";
                throw std::runtime_error("runtime_result_ready");
            }
            for (
                const ptcg::ai::Value &candidate
                : root_candidates.as_array()
            ) {
                const std::string signature =
                    choice_signature(candidate);
                if (
                    signature.empty()
                    || !root_choice_signatures.insert(
                        signature
                    ).second
                ) {
                    result["error"] =
                        "invalid_authoritative_choice";
                    throw std::runtime_error(
                        "runtime_result_ready"
                    );
                }
            }
        }

        const bool android = OS::get_singleton()->get_name() == "Android";
        const std::uint32_t minimum_simulations = android ? 16U : 32U;
        const std::uint32_t maximum_simulations = android ? 128U : 256U;
        const std::size_t leaf_batch_size = android ? 4U : 8U;
        auto batch = std::make_shared<ptcg::ai::NativeSelfPlayBatch>();
        ptcg::ai::NativeSearchJob job(cards_, decks_, batch);
        ptcg::ai::NativeSearchConfig config;
        config.simulations = maximum_simulations;
        config.max_depth = 128;
        config.c_puct = static_cast<float>(C_PUCT);
        config.dirichlet_epsilon = 0.0F;
        config.temperature = 0.0F;
        config.training = false;
        config.inference_wait_milliseconds = 2;
        config.max_inflight_leaves = static_cast<std::uint32_t>(
            leaf_batch_size
        );
        if (request_kind == "choice") {
            job.start_choice(
                native_state,
                static_cast<std::int32_t>(actor),
                root_pending,
                root_continuation,
                static_cast<std::uint32_t>(int64_t(
                    request.get("seed", 0)
                )),
                config
            );
        } else {
            job.start(
                native_state,
                static_cast<std::int32_t>(actor),
                static_cast<std::uint32_t>(int64_t(
                    request.get("seed", 0)
                )),
                config
            );
        }
        const auto stop_at = started + std::chrono::microseconds(
            WATCHDOG_USEC - STOP_MARGIN_USEC
        );
        bool deadline_stop = false;
        while (!job.finished()) {
            if (
                cancel_check.is_valid()
                && bool(cancel_check.call())
            ) {
                job.cancel();
                continue;
            }
            if (std::chrono::steady_clock::now() >= stop_at) {
                job.stop();
                deadline_stop = true;
                continue;
            }
            std::vector<ptcg::ai::InferenceRequest> requests =
                batch->poll_inference(leaf_batch_size, 2);
            if (requests.empty()) {
                continue;
            }
            PackedInferenceBatch packed = pack_inference_requests(
                requests
            );
            Dictionary inferred = backend->infer_v2(
                packed.state_global,
                packed.entity_numeric,
                packed.entity_card_ids,
                packed.entity_type_ids,
                packed.candidate_numeric,
                packed.candidate_card_ids,
                packed.candidate_type_ids,
                packed.candidate_refs,
                packed.candidate_mask,
                packed.actor_deck_ids,
                packed.opponent_deck_ids,
                static_cast<int64_t>(requests.size()),
                static_cast<int64_t>(packed.candidate_count)
            );
            if (!bool(inferred.get("success", false))) {
                job.cancel();
                result["error"] = String("runtime_inference_failed:")
                    + String(inferred.get("error", "unknown"));
                job.wait();
                throw std::runtime_error("runtime_result_ready");
            }
            const Variant policy_value = inferred.get(
                "policy_logits",
                Variant()
            );
            const Variant wdl_value = inferred.get(
                "wdl_logits",
                Variant()
            );
            if (
                policy_value.get_type()
                    != Variant::PACKED_FLOAT32_ARRAY
                || wdl_value.get_type()
                    != Variant::PACKED_FLOAT32_ARRAY
            ) {
                job.cancel();
                job.wait();
                result["error"] = "runtime_output_type_mismatch";
                throw std::runtime_error("runtime_result_ready");
            }
            const PackedFloat32Array policy_logits = policy_value;
            const PackedFloat32Array wdl_logits = wdl_value;
            if (
                policy_logits.size()
                    != static_cast<int64_t>(
                        requests.size() * packed.candidate_count
                    )
                || wdl_logits.size()
                    != static_cast<int64_t>(requests.size() * 3)
            ) {
                job.cancel();
                job.wait();
                result["error"] = "runtime_output_shape_mismatch";
                throw std::runtime_error("runtime_result_ready");
            }
            std::vector<ptcg::ai::InferenceResponse> responses;
            responses.reserve(requests.size());
            for (std::size_t row = 0; row < requests.size(); ++row) {
                ptcg::ai::InferenceResponse response;
                response.request_id = requests[row].request_id;
                response.policy = softmax_logits(
                    policy_logits,
                    row * packed.candidate_count,
                    requests[row].candidate_count()
                );
                const std::vector<float> wdl = softmax_logits(
                    wdl_logits,
                    row * 3,
                    3
                );
                std::copy(
                    wdl.begin(),
                    wdl.end(),
                    response.wdl.begin()
                );
                responses.push_back(std::move(response));
            }
            batch->submit_inference(responses);
            if (std::chrono::steady_clock::now() >= stop_at) {
                job.stop();
                deadline_stop = true;
            }
        }
        const ptcg::ai::NativeSearchResult searched = job.wait();
        result["simulations"] = static_cast<int64_t>(
            searched.simulations
        );
        result["tree_nodes"] = static_cast<int64_t>(
            searched.tree_nodes
        );
        result["chance_nodes"] = static_cast<int64_t>(
            searched.chance_nodes
        );
        result["chance_edges"] = static_cast<int64_t>(
            searched.chance_edges
        );
        result["determinization_microseconds"] = static_cast<int64_t>(
            searched.determinization_microseconds
        );
        result["projection_microseconds"] = static_cast<int64_t>(
            searched.projection_microseconds
        );
        result["candidate_generation_microseconds"] = static_cast<int64_t>(
            searched.candidate_generation_microseconds
        );
        result["apply_microseconds"] = static_cast<int64_t>(
            searched.apply_microseconds
        );
        result["encoding_microseconds"] = static_cast<int64_t>(
            searched.encoding_microseconds
        );
        result["inference_wait_microseconds"] = static_cast<int64_t>(
            searched.inference_wait_microseconds
        );
        result["max_pending_leaves"] = static_cast<int64_t>(
            searched.max_pending_leaves
        );
        result["candidate_cache_hits"] = static_cast<int64_t>(
            searched.candidate_cache_hits
        );
        result["candidate_cache_misses"] = static_cast<int64_t>(
            searched.candidate_cache_misses
        );
        result["apply_undo_journal_entries"] = static_cast<int64_t>(
            searched.apply_undo_journal_entries
        );
        result["apply_undo_operations"] = static_cast<int64_t>(
            searched.apply_undo_operations
        );
        result["root_value"] = searched.root_value;
        result["degraded_deadline"] =
            searched.simulations < minimum_simulations;
        result["deadline_stop"] = deadline_stop;
        result["leaf_batch_size"] = static_cast<int64_t>(
            leaf_batch_size
        );
        if (searched.cancelled) {
            result["cancelled"] = true;
            result["error"] = "cancelled";
            throw std::runtime_error("runtime_result_ready");
        }
        if (!searched.success) {
            result["error"] = String("native_search_failed:")
                + String::utf8(searched.error.c_str());
            throw std::runtime_error("runtime_result_ready");
        }
        const Dictionary selected = Dictionary(
            ptcg::ai::value_to_godot(searched.selected)
        );
        if (request_kind == "choice") {
            const std::string selected_signature = choice_signature(
                searched.selected
            );
            if (
                selected_signature.empty()
                || root_choice_signatures.find(selected_signature)
                    == root_choice_signatures.end()
            ) {
                result["error"] =
                    "native_choice_not_in_authoritative_set";
                throw std::runtime_error("runtime_result_ready");
            }
            const Variant selected_options = selected.get(
                "selected_options",
                Variant()
            );
            if (selected_options.get_type() != Variant::ARRAY) {
                result["error"] =
                    "native_choice_selection_missing";
                throw std::runtime_error("runtime_result_ready");
            }
            result["kind"] = "choice";
            result["choice_signature"] = String::utf8(
                selected_signature.c_str()
            );
            result["choice_request_id"] = String(
                selected.get("request_id", "")
            );
            result["selected_options"] = Array(
                selected_options
            ).duplicate(true);
            result["choice_cancelled"] = bool(
                selected.get("cancelled", false)
            );
        } else {
            const String selected_signature =
                action_signature_v2(selected);
            if (
                authoritative_signatures.find(
                    utf8_string(selected_signature)
                ) == authoritative_signatures.end()
            ) {
                result["error"] =
                    "native_action_not_in_authoritative_legal_set";
                throw std::runtime_error("runtime_result_ready");
            }
            result["kind"] = "action";
            result["action_signature"] = selected_signature;
        }

        if (
            searched.next_pending.is_object()
            && !searched.next_pending.as_object().empty()
            && searched.next_continuation.is_object()
            && !searched.next_continuation.as_object().empty()
        ) {
            choice_context_pending_ = searched.next_pending;
            choice_context_continuation_ =
                searched.next_continuation;
            choice_context_match_id_ = utf8_string(String(
                request.get("match_instance_id", "")
            ));
            choice_context_revision_ =
                searched.next_state_revision;
            choice_context_actor_ = integer_field(
                searched.next_pending,
                "player",
                actor
            );
            choice_context_valid_ = (
                choice_context_revision_ >= 0
                && (
                    choice_context_actor_ == 0
                    || choice_context_actor_ == 1
                )
            );
        } else {
            choice_context_valid_ = false;
            choice_context_pending_ =
                ptcg::ai::Value::make_object();
            choice_context_continuation_ =
                ptcg::ai::Value::make_object();
            choice_context_match_id_.clear();
            choice_context_revision_ = -1;
            choice_context_actor_ = -1;
        }
        result["success"] = true;
        result["root_visits"] = ptcg::ai::value_to_godot(
            searched.visits
        );
        result["root_probabilities"] = ptcg::ai::value_to_godot(
            searched.probabilities
        );
    } catch (const std::runtime_error &error) {
        if (std::string(error.what()) != "runtime_result_ready") {
            result["error"] = String("native_search_exception:")
                + String::utf8(error.what());
        }
    } catch (const std::exception &error) {
        result["error"] = String("native_search_exception:")
            + String::utf8(error.what());
    } catch (...) {
        result["error"] = "native_search_exception:unknown";
    }
    if (!bool(result.get("success", false))) {
        result["deep_failure_reason"] = result.get(
            "error",
            "native_search_failed"
        );
    }
    const auto finished = std::chrono::steady_clock::now();
    result["elapsed_ms"] = std::chrono::duration<double, std::milli>(
        finished - started
    ).count();
    return result;
}

int64_t NativeDeepSearch::information_set_hash_v2(
    const PackedInt32Array &public_words,
    const PackedInt32Array &actor_private_words,
    int64_t actor
) const {
    if (actor != 0 && actor != 1) {
        return 0;
    }
    std::vector<std::int32_t> public_values;
    public_values.reserve(public_words.size());
    for (int64_t index = 0; index < public_words.size(); ++index) {
        public_values.push_back(public_words[index]);
    }
    std::vector<std::int32_t> private_values;
    private_values.reserve(actor_private_words.size());
    for (int64_t index = 0; index < actor_private_words.size(); ++index) {
        private_values.push_back(actor_private_words[index]);
    }
    return static_cast<int64_t>(ptcg::ai::information_set_hash(
        public_values,
        private_values,
        static_cast<std::int32_t>(actor)
    ));
}

int64_t NativeDeepSearch::puct_select(
    const PackedFloat32Array &priors,
    const PackedInt32Array &visits,
    const PackedFloat32Array &value_sums,
    double c_puct
) const {
    if (
        priors.is_empty()
        || priors.size() != visits.size()
        || priors.size() != value_sums.size()
        || !std::isfinite(c_puct)
    ) {
        return -1;
    }
    ptcg::ai::PuctNode node(0);
    std::vector<std::uint64_t> signatures;
    std::vector<float> prior_values;
    signatures.reserve(priors.size());
    prior_values.reserve(priors.size());
    for (int64_t index = 0; index < priors.size(); ++index) {
        signatures.push_back(static_cast<std::uint64_t>(index + 1));
        prior_values.push_back(priors[index]);
    }
    try {
        node.expand(signatures, prior_values);
        for (int64_t index = 0; index < visits.size(); ++index) {
            const int32_t count = visits[index];
            if (count < 0 || !std::isfinite(value_sums[index])) {
                return -1;
            }
            for (int32_t ordinal = 0; ordinal < count; ++ordinal) {
                node.backup(
                    static_cast<std::size_t>(index),
                    value_sums[index] / static_cast<float>(
                        std::max<int32_t>(1, count)
                    )
                );
            }
        }
        return static_cast<int64_t>(
            node.select(static_cast<float>(c_puct))
        );
    } catch (...) {
        return -1;
    }
}

Dictionary NativeDeepSearch::get_contract() const {
    Dictionary result;
    result["planner_id"] = "infoset_puct_v2";
    result["schema_version"] = SCHEMA_VERSION;
    result["c_puct"] = C_PUCT;
    result["watchdog_seconds"] = 2.0;
    result["stop_margin_seconds"] = 0.05;
    result["windows_min_simulations"] = 32;
    result["windows_target_simulations"] = 128;
    result["windows_max_simulations"] = 256;
    result["windows_leaf_batch_size"] = 8;
    result["android_min_simulations"] = 16;
    result["android_target_simulations"] = 64;
    result["android_max_simulations"] = 128;
    result["android_leaf_batch_size"] = 4;
    result["leaf_evaluator"] = "neural_wdl";
    result["challenge_prior_weight"] = 0.0;
    result["full_turn_rollout"] = false;
    result["native_rules"] = vm_contract();
    result["infoset_abi_version"] =
        ptcg::ai::NATIVE_INFOSET_ABI_VERSION;
    result["runtime_hidden_identity_policy"] = "reject";
    result["root_choice_search"] = "one_shot_native_continuation";
    result["root_choice_public_intersection"] = true;
    result["explicit_chance_nodes"] =
        "vm_coin_sequences,confusion_coin,infoset_shuffle_outcomes";
    result["chance_node_gate_complete"] = true;
    result["unclassified_rng_policy"] = "fail_closed";
    result["state_storage"] =
        "compact_metadata_cow_apply_undo_journal_v2";
    result["infoset_candidate_cache"] = true;
    result["candidate_cache_audit_available"] = true;
    result["compact_apply_undo_gate_complete"] = true;
    result["native_effect_legality_gate_complete"] = true;
    return result;
}

void NativeDeepSearch::vm_set_cards(const Dictionary &cards) {
    ptcg::ai::Value native_cards = ptcg::ai::value_from_godot(cards);
    cards_ = native_cards;
    rules_kernel_.set_cards(native_cards);
    game_kernel_.set_cards(native_cards);
    encoder_.set_cards(std::move(native_cards));
}

void NativeDeepSearch::simulation_set_decks(const Dictionary &decks) {
    decks_ = ptcg::ai::value_from_godot(decks);
    determinizer_.set_decks(decks_);
}

Dictionary NativeDeepSearch::vm_execute(
    const Dictionary &state,
    const Dictionary &command_spec,
    int64_t actor,
    const String &source_slot,
    int64_t seed,
    const String &context_mode
) const {
    try {
        return vm_result_dictionary(rules_kernel_.execute(
            ptcg::ai::value_from_godot(state),
            ptcg::ai::value_from_godot(command_spec),
            static_cast<std::int32_t>(actor),
            utf8_string(source_slot),
            static_cast<std::uint32_t>(seed),
            utf8_string(context_mode)
        ));
    } catch (const std::exception &error) {
        return vm_wrapper_error(error.what());
    }
}

Dictionary NativeDeepSearch::vm_resume(
    const Dictionary &state,
    const Dictionary &context,
    const Dictionary &continuation,
    const Array &selected_options,
    bool cancelled,
    int64_t rng_state
) const {
    try {
        return vm_result_dictionary(rules_kernel_.resume(
            ptcg::ai::value_from_godot(state),
            ptcg::ai::value_from_godot(context),
            ptcg::ai::value_from_godot(continuation),
            ptcg::ai::value_from_godot(selected_options),
            cancelled,
            static_cast<std::uint32_t>(rng_state)
        ));
    } catch (const std::exception &error) {
        return vm_wrapper_error(error.what());
    }
}

Dictionary NativeDeepSearch::vm_contract() const {
    Dictionary result;
    result["abi_version"] = ptcg::ai::NATIVE_RULES_ABI_VERSION;
    result["card_count"] = static_cast<int64_t>(rules_kernel_.card_count());
    result["implemented_op_count"] = static_cast<int64_t>(
        rules_kernel_.implemented_op_count()
    );
    result["required_op_count"] = static_cast<int64_t>(
        ptcg::ai::NativeRulesKernel::required_op_count()
    );
    result["complete"] = (
        rules_kernel_.implemented_op_count()
        == ptcg::ai::NativeRulesKernel::required_op_count()
    );
    result["game_abi_version"] = ptcg::ai::NATIVE_GAME_ABI_VERSION;
    result["game_card_count"] = static_cast<int64_t>(
        game_kernel_.card_count()
    );
    return result;
}

Dictionary NativeDeepSearch::game_apply_action(
    const Dictionary &state,
    const Dictionary &action,
    int64_t rng_state
) const {
    try {
        return game_result_dictionary(game_kernel_.apply_action(
            ptcg::ai::value_from_godot(state),
            ptcg::ai::value_from_godot(action),
            static_cast<std::uint32_t>(rng_state)
        ));
    } catch (const std::exception &error) {
        return vm_wrapper_error(error.what());
    }
}

Array NativeDeepSearch::game_legal_actions(
    const Dictionary &state,
    int64_t actor
) const {
    try {
        return Array(ptcg::ai::value_to_godot(
            game_kernel_.legal_actions(
                ptcg::ai::value_from_godot(state),
                static_cast<std::int32_t>(actor)
            )
        ));
    } catch (...) {
        return Array();
    }
}

Array NativeDeepSearch::game_choice_candidates(
    const Dictionary &request
) const {
    try {
        return Array(ptcg::ai::value_to_godot(
            ptcg::ai::NativeGameKernel::choice_candidates(
                ptcg::ai::value_from_godot(request)
            )
        ));
    } catch (...) {
        return Array();
    }
}

Dictionary NativeDeepSearch::game_resume_choice(
    const Dictionary &state,
    const Dictionary &continuation,
    const Array &selected_options,
    bool cancelled,
    int64_t rng_state
) const {
    try {
        return game_result_dictionary(game_kernel_.resume_choice(
            ptcg::ai::value_from_godot(state),
            ptcg::ai::value_from_godot(continuation),
            ptcg::ai::value_from_godot(selected_options),
            cancelled,
            static_cast<std::uint32_t>(rng_state)
        ));
    } catch (const std::exception &error) {
        return vm_wrapper_error(error.what());
    }
}

String NativeDeepSearch::validate_runtime_snapshot(
    const Dictionary &state,
    int64_t actor
) const {
    try {
        const std::string error = ptcg::ai::validate_runtime_snapshot(
            ptcg::ai::value_from_godot(state),
            static_cast<std::int32_t>(actor)
        );
        return String::utf8(error.c_str());
    } catch (const std::exception &error) {
        return String::utf8(error.what());
    }
}

Dictionary NativeDeepSearch::project_information_set(
    const Dictionary &state,
    int64_t actor
) const {
    Dictionary result;
    try {
        const ptcg::ai::InformationSetProjection projection =
            ptcg::ai::project_information_set(
                ptcg::ai::value_from_godot(state),
                static_cast<std::int32_t>(actor)
            );
        result["success"] = true;
        result["observation"] = ptcg::ai::value_to_godot(
            projection.observation
        );
        result["public_hash"] = static_cast<int64_t>(
            projection.public_hash
        );
        result["actor_private_hash"] = static_cast<int64_t>(
            projection.actor_private_hash
        );
        result["tree_key"] = static_cast<int64_t>(
            projection.tree_key
        );
    } catch (const std::exception &error) {
        result["success"] = false;
        result["error"] = String::utf8(error.what());
    }
    return result;
}

Dictionary NativeDeepSearch::encode_actions_v7(
    const Dictionary &state,
    int64_t actor,
    const Array &actions
) const {
    try {
        const ptcg::ai::InformationSetProjection projection =
            ptcg::ai::project_information_set(
                ptcg::ai::value_from_godot(state),
                static_cast<std::int32_t>(actor)
            );
        return encoded_request_dictionary(encoder_.encode_actions(
            projection.observation,
            ptcg::ai::value_from_godot(actions)
        ));
    } catch (const std::exception &error) {
        Dictionary result;
        result["success"] = false;
        result["error"] = String::utf8(error.what());
        return result;
    }
}

Dictionary NativeDeepSearch::encode_choices_v7(
    const Dictionary &state,
    int64_t actor,
    const Dictionary &request,
    const Array &candidates
) const {
    try {
        const ptcg::ai::InformationSetProjection projection =
            ptcg::ai::project_information_set(
                ptcg::ai::value_from_godot(state),
                static_cast<std::int32_t>(actor)
            );
        return encoded_request_dictionary(encoder_.encode_choices(
            projection.observation,
            ptcg::ai::value_from_godot(request),
            ptcg::ai::value_from_godot(candidates)
        ));
    } catch (const std::exception &error) {
        Dictionary result;
        result["success"] = false;
        result["error"] = String::utf8(error.what());
        return result;
    }
}

Dictionary NativeDeepSearch::determinize_information_set(
    const Dictionary &state,
    int64_t actor,
    int64_t seed
) const {
    Dictionary result;
    try {
        result["success"] = true;
        result["state"] = ptcg::ai::value_to_godot(
            determinizer_.determinize(
                ptcg::ai::value_from_godot(state),
                static_cast<std::int32_t>(actor),
                static_cast<std::uint32_t>(seed)
            )
        );
    } catch (const std::exception &error) {
        result["success"] = false;
        result["error"] = String::utf8(error.what());
    }
    return result;
}

String NativeDeepSearch::action_signature_v2(
    const Dictionary &action
) const {
    try {
        Dictionary stable;
        stable["kind"] = String(action.get("kind", ""));
        stable["actor"] = int64_t(action.get("actor", -1));
        stable["source"] = stable_entity_ref(
            action.get("source", Variant())
        );
        stable["target"] = stable_entity_ref(
            action.get("target", Variant())
        );
        stable["payload"] = action.get("payload", Dictionary());
        const String wire = stable_variant_signature(stable);
        return String("action:") + wire.sha256_text();
    } catch (const std::exception &error) {
        return String("native_action_signature_error:")
            + String::utf8(error.what());
    } catch (...) {
        return "native_action_signature_error:unknown";
    }
}

} // namespace godot
