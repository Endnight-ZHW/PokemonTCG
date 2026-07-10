#pragma once

#include <memory>
#include <mutex>
#include <string>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <onnxruntime_cxx_api.h>

namespace godot {

class OnnxInference : public RefCounted {
    GDCLASS(OnnxInference, RefCounted)

private:
    static constexpr int64_t STATE_NUMERIC_SIZE = 960;
    static constexpr int64_t STATE_CARD_SLOTS = 96;
    static constexpr int64_t ACTION_NUMERIC_SIZE = 178;

    mutable std::mutex mutex_;
    Ort::Env environment_;
    Ort::SessionOptions session_options_;
    std::unique_ptr<Ort::Session> session_;
    PackedByteArray model_bytes_;
    String loaded_path_;
    String last_error_;
    double last_duration_ms_ = 0.0;
    bool choice_head_enabled_ = false;

    Dictionary fail(const String &message);
    static String validate_output_tensor(
        const Ort::Value &value,
        size_t expected_count,
        const char *output_name
    );
    static PackedFloat32Array tensor_to_array(const Ort::Value &value);

protected:
    static void _bind_methods();

public:
    OnnxInference();
    ~OnnxInference() override = default;

    bool load_model(const String &path, const Dictionary &manifest);
    void unload_model();
    bool is_loaded() const;
    bool supports_choice_head() const;
    Dictionary infer(
        const PackedFloat32Array &state_numeric,
        const PackedInt64Array &state_cards,
        const PackedFloat32Array &action_numeric,
        const PackedInt64Array &action_cards,
        const PackedFloat32Array &choice_numeric,
        const PackedInt64Array &choice_cards
    );
    String get_last_error() const;
    double get_last_duration_ms() const;
    String get_execution_provider() const;
    String get_runtime_version() const;
};

} // namespace godot
