#include "onnx_inference.hpp"

#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <limits>
#include <memory>

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/core/class_db.hpp>

namespace godot {

namespace {

constexpr std::array<const char *, 12> INPUT_NAMES{
    "state_global",
    "entity_numeric",
    "entity_card_ids",
    "entity_type_ids",
    "entity_mask",
    "candidate_numeric",
    "candidate_card_ids",
    "candidate_type_ids",
    "candidate_refs",
    "candidate_mask",
    "actor_deck_id",
    "opponent_deck_id",
};
constexpr std::array<const char *, 2> OUTPUT_NAMES{
    "policy_logits",
    "wdl_logits",
};

} // namespace

OnnxInference::OnnxInference()
    : environment_(ORT_LOGGING_LEVEL_WARNING, "PokemonTCGAlphaZeroV3") {
    session_options_.SetIntraOpNumThreads(1);
    session_options_.SetInterOpNumThreads(1);
    session_options_.SetGraphOptimizationLevel(
        GraphOptimizationLevel::ORT_ENABLE_ALL
    );
}

void OnnxInference::_bind_methods() {
    ClassDB::bind_method(
        D_METHOD("load_model", "path", "manifest"),
        &OnnxInference::load_model
    );
    ClassDB::bind_method(
        D_METHOD("unload_model"),
        &OnnxInference::unload_model
    );
    ClassDB::bind_method(
        D_METHOD("is_loaded"),
        &OnnxInference::is_loaded
    );
    ClassDB::bind_method(
        D_METHOD(
            "infer_v3",
            "state_global",
            "entity_numeric",
            "entity_card_ids",
            "entity_type_ids",
            "entity_mask",
            "candidate_numeric",
            "candidate_card_ids",
            "candidate_type_ids",
            "candidate_refs",
            "candidate_mask",
            "actor_deck_ids",
            "opponent_deck_ids",
            "batch_size",
            "candidate_count"
        ),
        &OnnxInference::infer_v3
    );
    ClassDB::bind_method(
        D_METHOD("get_last_error"),
        &OnnxInference::get_last_error
    );
    ClassDB::bind_method(
        D_METHOD("get_last_duration_ms"),
        &OnnxInference::get_last_duration_ms
    );
    ClassDB::bind_method(
        D_METHOD("get_execution_provider"),
        &OnnxInference::get_execution_provider
    );
    ClassDB::bind_method(
        D_METHOD("get_runtime_version"),
        &OnnxInference::get_runtime_version
    );
    ClassDB::bind_method(
        D_METHOD("get_contract"),
        &OnnxInference::get_contract
    );
}

Dictionary OnnxInference::fail(const String &message) {
    last_error_ = message;
    Dictionary result;
    result["success"] = false;
    result["error"] = message;
    result["duration_ms"] = last_duration_ms_;
    return result;
}

bool OnnxInference::load_model(
    const String &path,
    const Dictionary &manifest
) {
    std::lock_guard<std::mutex> lock(mutex_);
    session_.reset();
    model_bytes_.clear();
    loaded_path_ = "";
    last_error_ = "";
    last_duration_ms_ = 0.0;
    try {
        if (int64_t(manifest.get("format_version", 0)) != 4) {
            last_error_ = "unsupported_runtime_manifest_format";
            return false;
        }
        if (int64_t(manifest.get("opset", 0)) != 17) {
            last_error_ = "unsupported_opset";
            return false;
        }
        if (
            String(manifest.get("model_variant", ""))
            != "universal_infoset_transformer_v3"
        ) {
            last_error_ = "unsupported_model_variant";
            return false;
        }
        if (
            int64_t(manifest.get("state_global_size", 0))
                != STATE_GLOBAL_SIZE
            || int64_t(manifest.get("entity_slots", 0))
                != ENTITY_SLOTS
            || int64_t(manifest.get("entity_numeric_size", 0))
                != ENTITY_NUMERIC_SIZE
            || int64_t(manifest.get("entity_type_fields", 0))
                != ENTITY_TYPE_FIELDS
            || int64_t(manifest.get("candidate_numeric_size", 0))
                != CANDIDATE_NUMERIC_SIZE
            || int64_t(manifest.get("candidate_ref_fields", 0))
                != CANDIDATE_REF_FIELDS
        ) {
            last_error_ = "model_shape_mismatch";
            return false;
        }
        const String expected_sha = String(
            manifest.get("onnx_sha256", "")
        ).to_lower();
        const String actual_sha = FileAccess::get_sha256(path).to_lower();
        if (expected_sha.is_empty() || expected_sha != actual_sha) {
            last_error_ = "model_sha256_mismatch";
            return false;
        }
        Ref<FileAccess> file = FileAccess::open(path, FileAccess::READ);
        if (file.is_null()) {
            last_error_ = "model_open_failed";
            return false;
        }
        model_bytes_ = file->get_buffer(file->get_length());
        if (model_bytes_.is_empty()) {
            last_error_ = "model_empty";
            return false;
        }
        session_ = std::make_unique<Ort::Session>(
            environment_,
            model_bytes_.ptr(),
            static_cast<size_t>(model_bytes_.size()),
            session_options_
        );
        loaded_path_ = path;
        return true;
    } catch (const Ort::Exception &error) {
        session_.reset();
        model_bytes_.clear();
        last_error_ = String("onnx_load_failed:") + error.what();
        return false;
    } catch (const std::exception &error) {
        session_.reset();
        model_bytes_.clear();
        last_error_ = String("model_load_failed:") + error.what();
        return false;
    }
}

void OnnxInference::unload_model() {
    std::lock_guard<std::mutex> lock(mutex_);
    session_.reset();
    model_bytes_.clear();
    loaded_path_ = "";
    last_error_ = "";
    last_duration_ms_ = 0.0;
}

bool OnnxInference::is_loaded() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return session_ != nullptr;
}

bool OnnxInference::checked_product(
    int64_t left,
    int64_t right,
    int64_t &result
) {
    if (
        left < 0
        || right < 0
        || (
            left != 0
            && right > std::numeric_limits<int64_t>::max() / left
        )
    ) {
        return false;
    }
    result = left * right;
    return true;
}

Dictionary OnnxInference::infer_v3(
    const PackedFloat32Array &state_global,
    const PackedFloat32Array &entity_numeric,
    const PackedInt64Array &entity_card_ids,
    const PackedInt64Array &entity_type_ids,
    const PackedByteArray &entity_mask,
    const PackedFloat32Array &candidate_numeric,
    const PackedInt64Array &candidate_card_ids,
    const PackedInt64Array &candidate_type_ids,
    const PackedInt64Array &candidate_refs,
    const PackedByteArray &candidate_mask,
    const PackedInt64Array &actor_deck_ids,
    const PackedInt64Array &opponent_deck_ids,
    int64_t batch_size,
    int64_t candidate_count
) {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto started = std::chrono::steady_clock::now();
    last_error_ = "";
    if (!session_) {
        return fail("model_not_loaded");
    }
    if (
        batch_size <= 0
        || batch_size > MAX_BATCH_SIZE
        || candidate_count <= 0
        || candidate_count > MAX_CANDIDATES
    ) {
        return fail("invalid_batch_shape");
    }
    int64_t batch_candidates = 0;
    int64_t expected_state_global = 0;
    int64_t expected_entity_numeric = 0;
    int64_t expected_entity_cards = 0;
    int64_t expected_entity_types = 0;
    int64_t expected_candidate_numeric = 0;
    int64_t expected_candidate_refs = 0;
    if (
        !checked_product(batch_size, candidate_count, batch_candidates)
        || !checked_product(
            batch_size,
            STATE_GLOBAL_SIZE,
            expected_state_global
        )
        || !checked_product(
            batch_size,
            ENTITY_SLOTS * ENTITY_NUMERIC_SIZE,
            expected_entity_numeric
        )
        || !checked_product(
            batch_size,
            ENTITY_SLOTS,
            expected_entity_cards
        )
        || !checked_product(
            batch_size,
            ENTITY_SLOTS * ENTITY_TYPE_FIELDS,
            expected_entity_types
        )
        || !checked_product(
            batch_candidates,
            CANDIDATE_NUMERIC_SIZE,
            expected_candidate_numeric
        )
        || !checked_product(
            batch_candidates,
            CANDIDATE_REF_FIELDS,
            expected_candidate_refs
        )
    ) {
        return fail("input_shape_overflow");
    }
    if (
        state_global.size() != expected_state_global
        || entity_numeric.size() != expected_entity_numeric
        || entity_card_ids.size() != expected_entity_cards
        || entity_type_ids.size() != expected_entity_types
        || entity_mask.size() != expected_entity_cards
        || candidate_numeric.size() != expected_candidate_numeric
        || candidate_card_ids.size() != batch_candidates
        || candidate_type_ids.size() != batch_candidates
        || candidate_refs.size() != expected_candidate_refs
        || candidate_mask.size() != batch_candidates
        || actor_deck_ids.size() != batch_size
        || opponent_deck_ids.size() != batch_size
    ) {
        return fail("invalid_input_shape");
    }
    for (const float value : state_global) {
        if (!std::isfinite(value)) {
            return fail("non_finite_input");
        }
    }
    for (const float value : entity_numeric) {
        if (!std::isfinite(value)) {
            return fail("non_finite_input");
        }
    }
    for (const float value : candidate_numeric) {
        if (!std::isfinite(value)) {
            return fail("non_finite_input");
        }
    }

    try {
        Ort::MemoryInfo memory = Ort::MemoryInfo::CreateCpu(
            OrtArenaAllocator,
            OrtMemTypeDefault
        );
        std::array<int64_t, 2> state_global_shape{
            batch_size,
            STATE_GLOBAL_SIZE,
        };
        std::array<int64_t, 3> entity_numeric_shape{
            batch_size,
            ENTITY_SLOTS,
            ENTITY_NUMERIC_SIZE,
        };
        std::array<int64_t, 2> entity_card_shape{
            batch_size,
            ENTITY_SLOTS,
        };
        std::array<int64_t, 3> entity_type_shape{
            batch_size,
            ENTITY_SLOTS,
            ENTITY_TYPE_FIELDS,
        };
        std::array<int64_t, 2> entity_mask_shape{
            batch_size,
            ENTITY_SLOTS,
        };
        std::array<int64_t, 3> candidate_numeric_shape{
            batch_size,
            candidate_count,
            CANDIDATE_NUMERIC_SIZE,
        };
        std::array<int64_t, 2> candidate_shape{
            batch_size,
            candidate_count,
        };
        std::array<int64_t, 3> candidate_ref_shape{
            batch_size,
            candidate_count,
            CANDIDATE_REF_FIELDS,
        };
        std::array<int64_t, 1> deck_shape{batch_size};

        std::unique_ptr<bool[]> bool_entity_mask = std::make_unique<bool[]>(
            static_cast<std::size_t>(expected_entity_cards)
        );
        for (int64_t index = 0; index < expected_entity_cards; ++index) {
            bool_entity_mask[static_cast<std::size_t>(index)]
                = entity_mask[index] != 0;
        }
        std::unique_ptr<bool[]> bool_mask = std::make_unique<bool[]>(
            static_cast<std::size_t>(batch_candidates)
        );
        for (int64_t index = 0; index < batch_candidates; ++index) {
            bool_mask[static_cast<std::size_t>(index)]
                = candidate_mask[index] != 0;
        }

        std::array<Ort::Value, 12> inputs{
            Ort::Value::CreateTensor<float>(
                memory,
                const_cast<float *>(state_global.ptr()),
                state_global.size(),
                state_global_shape.data(),
                state_global_shape.size()
            ),
            Ort::Value::CreateTensor<float>(
                memory,
                const_cast<float *>(entity_numeric.ptr()),
                entity_numeric.size(),
                entity_numeric_shape.data(),
                entity_numeric_shape.size()
            ),
            Ort::Value::CreateTensor<int64_t>(
                memory,
                const_cast<int64_t *>(entity_card_ids.ptr()),
                entity_card_ids.size(),
                entity_card_shape.data(),
                entity_card_shape.size()
            ),
            Ort::Value::CreateTensor<int64_t>(
                memory,
                const_cast<int64_t *>(entity_type_ids.ptr()),
                entity_type_ids.size(),
                entity_type_shape.data(),
                entity_type_shape.size()
            ),
            Ort::Value::CreateTensor<bool>(
                memory,
                bool_entity_mask.get(),
                static_cast<std::size_t>(expected_entity_cards),
                entity_mask_shape.data(),
                entity_mask_shape.size()
            ),
            Ort::Value::CreateTensor<float>(
                memory,
                const_cast<float *>(candidate_numeric.ptr()),
                candidate_numeric.size(),
                candidate_numeric_shape.data(),
                candidate_numeric_shape.size()
            ),
            Ort::Value::CreateTensor<int64_t>(
                memory,
                const_cast<int64_t *>(candidate_card_ids.ptr()),
                candidate_card_ids.size(),
                candidate_shape.data(),
                candidate_shape.size()
            ),
            Ort::Value::CreateTensor<int64_t>(
                memory,
                const_cast<int64_t *>(candidate_type_ids.ptr()),
                candidate_type_ids.size(),
                candidate_shape.data(),
                candidate_shape.size()
            ),
            Ort::Value::CreateTensor<int64_t>(
                memory,
                const_cast<int64_t *>(candidate_refs.ptr()),
                candidate_refs.size(),
                candidate_ref_shape.data(),
                candidate_ref_shape.size()
            ),
            Ort::Value::CreateTensor<bool>(
                memory,
                bool_mask.get(),
                static_cast<std::size_t>(batch_candidates),
                candidate_shape.data(),
                candidate_shape.size()
            ),
            Ort::Value::CreateTensor<int64_t>(
                memory,
                const_cast<int64_t *>(actor_deck_ids.ptr()),
                actor_deck_ids.size(),
                deck_shape.data(),
                deck_shape.size()
            ),
            Ort::Value::CreateTensor<int64_t>(
                memory,
                const_cast<int64_t *>(opponent_deck_ids.ptr()),
                opponent_deck_ids.size(),
                deck_shape.data(),
                deck_shape.size()
            ),
        };
        auto outputs = session_->Run(
            Ort::RunOptions{nullptr},
            INPUT_NAMES.data(),
            inputs.data(),
            inputs.size(),
            OUTPUT_NAMES.data(),
            OUTPUT_NAMES.size()
        );
        if (outputs.size() != OUTPUT_NAMES.size()) {
            return fail("model_output_count_mismatch");
        }
        String policy_error = validate_output_tensor(
            outputs[0],
            static_cast<std::size_t>(batch_candidates),
            OUTPUT_NAMES[0]
        );
        if (!policy_error.is_empty()) {
            return fail(policy_error);
        }
        String wdl_error = validate_output_tensor(
            outputs[1],
            static_cast<std::size_t>(batch_size * WDL_SIZE),
            OUTPUT_NAMES[1]
        );
        if (!wdl_error.is_empty()) {
            return fail(wdl_error);
        }
        const auto finished = std::chrono::steady_clock::now();
        last_duration_ms_ = std::chrono::duration<double, std::milli>(
            finished - started
        ).count();
        Dictionary result;
        result["success"] = true;
        result["policy_logits"] = tensor_to_array(outputs[0]);
        result["wdl_logits"] = tensor_to_array(outputs[1]);
        result["batch_size"] = batch_size;
        result["candidate_count"] = candidate_count;
        result["duration_ms"] = last_duration_ms_;
        return result;
    } catch (const Ort::Exception &error) {
        return fail(String("onnx_inference_failed:") + error.what());
    } catch (const std::exception &error) {
        return fail(String("inference_failed:") + error.what());
    }
}

String OnnxInference::validate_output_tensor(
    const Ort::Value &value,
    size_t expected_count,
    const char *output_name
) {
    const String name(output_name);
    if (!value.IsTensor()) {
        return String("model_output_not_tensor:") + name;
    }
    const auto info = value.GetTensorTypeAndShapeInfo();
    if (info.GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
        return String("model_output_type_mismatch:") + name;
    }
    if (info.GetElementCount() != expected_count) {
        return String("model_output_size_mismatch:") + name;
    }
    const float *data = value.GetTensorData<float>();
    for (size_t index = 0; index < expected_count; ++index) {
        if (!std::isfinite(data[index])) {
            return String("non_finite_model_output:") + name;
        }
    }
    return "";
}

PackedFloat32Array OnnxInference::tensor_to_array(
    const Ort::Value &value
) {
    const auto info = value.GetTensorTypeAndShapeInfo();
    const size_t count = info.GetElementCount();
    const float *source = value.GetTensorData<float>();
    PackedFloat32Array result;
    result.resize(static_cast<int64_t>(count));
    float *target = result.ptrw();
    for (size_t index = 0; index < count; ++index) {
        target[index] = source[index];
    }
    return result;
}

String OnnxInference::get_last_error() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return last_error_;
}

double OnnxInference::get_last_duration_ms() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return last_duration_ms_;
}

String OnnxInference::get_execution_provider() const {
    return "CPUExecutionProvider";
}

String OnnxInference::get_runtime_version() const {
    return String(Ort::GetVersionString().c_str());
}

Dictionary OnnxInference::get_contract() const {
    Dictionary result;
    result["format_version"] = 4;
    result["encoder_version"] = 8;
    result["model_variant"] = "universal_infoset_transformer_v3";
    result["state_global_size"] = STATE_GLOBAL_SIZE;
    result["entity_slots"] = ENTITY_SLOTS;
    result["entity_numeric_size"] = ENTITY_NUMERIC_SIZE;
    result["entity_type_fields"] = ENTITY_TYPE_FIELDS;
    result["candidate_numeric_size"] = CANDIDATE_NUMERIC_SIZE;
    result["candidate_ref_fields"] = CANDIDATE_REF_FIELDS;
    result["wdl_size"] = WDL_SIZE;
    return result;
}

} // namespace godot
