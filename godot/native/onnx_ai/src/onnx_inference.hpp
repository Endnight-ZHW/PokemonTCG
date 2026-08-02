#pragma once

#include <memory>
#include <mutex>
#include <string>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <onnxruntime_cxx_api.h>

namespace godot {

class OnnxInference : public RefCounted {
    GDCLASS(OnnxInference, RefCounted)

private:
    static constexpr int64_t STATE_GLOBAL_SIZE = 128;
    static constexpr int64_t ENTITY_SLOTS = 128;
    static constexpr int64_t ENTITY_NUMERIC_SIZE = 16;
    static constexpr int64_t ENTITY_TYPE_FIELDS = 4;
    static constexpr int64_t CANDIDATE_NUMERIC_SIZE = 32;
    static constexpr int64_t CANDIDATE_REF_FIELDS = 4;
    static constexpr int64_t WDL_SIZE = 3;
    static constexpr int64_t MAX_BATCH_SIZE = 256;
    static constexpr int64_t MAX_CANDIDATES = 512;

    mutable std::mutex mutex_;
    Ort::Env environment_;
    Ort::SessionOptions session_options_;
    std::unique_ptr<Ort::Session> session_;
    PackedByteArray model_bytes_;
    String loaded_path_;
    String last_error_;
    double last_duration_ms_ = 0.0;

    Dictionary fail(const String &message);
    static String validate_output_tensor(
        const Ort::Value &value,
        size_t expected_count,
        const char *output_name
    );
    static PackedFloat32Array tensor_to_array(const Ort::Value &value);
    static bool checked_product(
        int64_t left,
        int64_t right,
        int64_t &result
    );

protected:
    static void _bind_methods();

public:
    OnnxInference();
    ~OnnxInference() override = default;

    bool load_model(const String &path, const Dictionary &manifest);
    void unload_model();
    bool is_loaded() const;
    Dictionary infer_v2(
        const PackedFloat32Array &state_global,
        const PackedFloat32Array &entity_numeric,
        const PackedInt64Array &entity_card_ids,
        const PackedInt64Array &entity_type_ids,
        const PackedFloat32Array &candidate_numeric,
        const PackedInt64Array &candidate_card_ids,
        const PackedInt64Array &candidate_type_ids,
        const PackedInt64Array &candidate_refs,
        const PackedByteArray &candidate_mask,
        const PackedInt64Array &actor_deck_ids,
        const PackedInt64Array &opponent_deck_ids,
        int64_t batch_size,
        int64_t candidate_count
    );
    String get_last_error() const;
    double get_last_duration_ms() const;
    String get_execution_provider() const;
    String get_runtime_version() const;
    Dictionary get_contract() const;
};

} // namespace godot
