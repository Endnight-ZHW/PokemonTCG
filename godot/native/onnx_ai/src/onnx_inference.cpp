#include "onnx_inference.hpp"

#include <array>
#include <chrono>
#include <vector>

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

namespace godot {

OnnxInference::OnnxInference()
    : environment_(ORT_LOGGING_LEVEL_WARNING, "PokemonTCG") {
    session_options_.SetIntraOpNumThreads(1);
    session_options_.SetInterOpNumThreads(1);
    session_options_.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
}

void OnnxInference::_bind_methods() {
    ClassDB::bind_method(D_METHOD("load_model", "path", "manifest"), &OnnxInference::load_model);
    ClassDB::bind_method(D_METHOD("unload_model"), &OnnxInference::unload_model);
    ClassDB::bind_method(D_METHOD("is_loaded"), &OnnxInference::is_loaded);
    ClassDB::bind_method(D_METHOD("supports_choice_head"), &OnnxInference::supports_choice_head);
    ClassDB::bind_method(
        D_METHOD(
            "infer",
            "state_numeric",
            "state_cards",
            "action_numeric",
            "action_cards",
            "choice_numeric",
            "choice_cards"
        ),
        &OnnxInference::infer
    );
    ClassDB::bind_method(D_METHOD("get_last_error"), &OnnxInference::get_last_error);
    ClassDB::bind_method(D_METHOD("get_last_duration_ms"), &OnnxInference::get_last_duration_ms);
    ClassDB::bind_method(D_METHOD("get_execution_provider"), &OnnxInference::get_execution_provider);
    ClassDB::bind_method(D_METHOD("get_runtime_version"), &OnnxInference::get_runtime_version);
}

Dictionary OnnxInference::fail(const String &message) {
    last_error_ = message;
    Dictionary result;
    result["success"] = false;
    result["error"] = message;
    result["duration_ms"] = last_duration_ms_;
    return result;
}

bool OnnxInference::load_model(const String &path, const Dictionary &manifest) {
    std::lock_guard<std::mutex> lock(mutex_);
    last_error_ = "";
    last_duration_ms_ = 0.0;
    choice_head_enabled_ = false;
    try {
        if (int64_t(manifest.get("opset", 0)) != 17) {
            last_error_ = "unsupported_opset";
            return false;
        }
        if (
            int64_t(manifest.get("state_numeric_size", 0)) != STATE_NUMERIC_SIZE ||
            int64_t(manifest.get("state_card_slots", 0)) != STATE_CARD_SLOTS ||
            int64_t(manifest.get("action_numeric_size", 0)) != ACTION_NUMERIC_SIZE
        ) {
            last_error_ = "model_shape_mismatch";
            return false;
        }
        const String expected_sha = String(manifest.get("onnx_sha256", "")).to_lower();
        const String actual_sha = FileAccess::get_sha256(path).to_lower();
        if (expected_sha.is_empty() || actual_sha != expected_sha) {
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
        choice_head_enabled_ = bool(manifest.get("choice_head_enabled", false));
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
    choice_head_enabled_ = false;
}

bool OnnxInference::is_loaded() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return session_ != nullptr;
}

bool OnnxInference::supports_choice_head() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return session_ != nullptr && choice_head_enabled_;
}

PackedFloat32Array OnnxInference::tensor_to_array(const Ort::Value &value) {
    const auto info = value.GetTensorTypeAndShapeInfo();
    const size_t count = info.GetElementCount();
    const float *data = value.GetTensorData<float>();
    PackedFloat32Array result;
    result.resize(static_cast<int64_t>(count));
    float *target = result.ptrw();
    for (size_t index = 0; index < count; ++index) {
        target[index] = data[index];
    }
    return result;
}

Dictionary OnnxInference::infer(
    const PackedFloat32Array &state_numeric,
    const PackedInt64Array &state_cards,
    const PackedFloat32Array &action_numeric,
    const PackedInt64Array &action_cards,
    const PackedFloat32Array &choice_numeric,
    const PackedInt64Array &choice_cards
) {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto started = std::chrono::steady_clock::now();
    last_error_ = "";
    if (!session_) {
        return fail("model_not_loaded");
    }
    if (
        state_numeric.size() != STATE_NUMERIC_SIZE ||
        state_cards.size() != STATE_CARD_SLOTS ||
        action_cards.is_empty() ||
        choice_cards.is_empty() ||
        action_numeric.size() != action_cards.size() * ACTION_NUMERIC_SIZE ||
        choice_numeric.size() != choice_cards.size() * ACTION_NUMERIC_SIZE
    ) {
        return fail("invalid_input_shape");
    }

    try {
        Ort::MemoryInfo memory = Ort::MemoryInfo::CreateCpu(
            OrtArenaAllocator,
            OrtMemTypeDefault
        );
        const int64_t action_count = action_cards.size();
        const int64_t choice_count = choice_cards.size();
        std::array<int64_t, 2> state_numeric_shape{1, STATE_NUMERIC_SIZE};
        std::array<int64_t, 2> state_cards_shape{1, STATE_CARD_SLOTS};
        std::array<int64_t, 3> action_numeric_shape{1, action_count, ACTION_NUMERIC_SIZE};
        std::array<int64_t, 2> action_cards_shape{1, action_count};
        std::array<int64_t, 3> choice_numeric_shape{1, choice_count, ACTION_NUMERIC_SIZE};
        std::array<int64_t, 2> choice_cards_shape{1, choice_count};

        std::array<Ort::Value, 6> inputs{
            Ort::Value::CreateTensor<float>(
                memory,
                const_cast<float *>(state_numeric.ptr()),
                state_numeric.size(),
                state_numeric_shape.data(),
                state_numeric_shape.size()
            ),
            Ort::Value::CreateTensor<int64_t>(
                memory,
                const_cast<int64_t *>(state_cards.ptr()),
                state_cards.size(),
                state_cards_shape.data(),
                state_cards_shape.size()
            ),
            Ort::Value::CreateTensor<float>(
                memory,
                const_cast<float *>(action_numeric.ptr()),
                action_numeric.size(),
                action_numeric_shape.data(),
                action_numeric_shape.size()
            ),
            Ort::Value::CreateTensor<int64_t>(
                memory,
                const_cast<int64_t *>(action_cards.ptr()),
                action_cards.size(),
                action_cards_shape.data(),
                action_cards_shape.size()
            ),
            Ort::Value::CreateTensor<float>(
                memory,
                const_cast<float *>(choice_numeric.ptr()),
                choice_numeric.size(),
                choice_numeric_shape.data(),
                choice_numeric_shape.size()
            ),
            Ort::Value::CreateTensor<int64_t>(
                memory,
                const_cast<int64_t *>(choice_cards.ptr()),
                choice_cards.size(),
                choice_cards_shape.data(),
                choice_cards_shape.size()
            ),
        };
        static constexpr std::array<const char *, 6> input_names{
            "state_numeric",
            "state_cards",
            "action_numeric",
            "action_cards",
            "choice_numeric",
            "choice_cards",
        };
        static constexpr std::array<const char *, 3> output_names{
            "action_logits",
            "state_value",
            "choice_logits",
        };
        auto outputs = session_->Run(
            Ort::RunOptions{nullptr},
            input_names.data(),
            inputs.data(),
            inputs.size(),
            output_names.data(),
            output_names.size()
        );
        last_duration_ms_ = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - started
        ).count();
        Dictionary result;
        result["success"] = true;
        result["action_logits"] = tensor_to_array(outputs[0]);
        const PackedFloat32Array values = tensor_to_array(outputs[1]);
        result["value"] = values.is_empty() ? 0.0f : values[0];
        result["choice_logits"] = tensor_to_array(outputs[2]);
        result["duration_ms"] = last_duration_ms_;
        result["provider"] = "CPUExecutionProvider";
        return result;
    } catch (const Ort::Exception &error) {
        last_duration_ms_ = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - started
        ).count();
        return fail(String("onnx_inference_failed:") + error.what());
    } catch (const std::exception &error) {
        last_duration_ms_ = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - started
        ).count();
        return fail(String("inference_failed:") + error.what());
    }
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
    return OrtGetApiBase()->GetVersionString();
}

} // namespace godot
