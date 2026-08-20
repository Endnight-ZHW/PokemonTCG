#pragma once

#include "ptcg_determinizer.hpp"
#include "ptcg_encoder.hpp"
#include "ptcg_game.hpp"
#include "ptcg_infoset.hpp"
#include "ptcg_search.hpp"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>

#include <string>

namespace godot {

class NativeDeepSearch : public RefCounted {
    GDCLASS(NativeDeepSearch, RefCounted)

protected:
    static void _bind_methods();

public:
    static constexpr int64_t SCHEMA_VERSION = 2;
    static constexpr double C_PUCT = 1.4;
    static constexpr int64_t WATCHDOG_USEC = 2'000'000;
    static constexpr int64_t STOP_MARGIN_USEC = 50'000;

    Dictionary decide(
        const Dictionary &request,
        const Callable &cancel_check,
        const Variant &inference
    );
    int64_t information_set_hash_v2(
        const PackedInt32Array &public_words,
        const PackedInt32Array &actor_private_words,
        int64_t actor
    ) const;
    int64_t puct_select(
        const PackedFloat32Array &priors,
        const PackedInt32Array &visits,
        const PackedFloat32Array &value_sums,
        double c_puct = C_PUCT
    ) const;
    Dictionary get_contract() const;
    void set_catalog(const Dictionary &cards);
    void set_decks(const Dictionary &decks);
    String validate_runtime_snapshot(
        const Dictionary &state,
        int64_t actor
    ) const;
    Dictionary project_information_set(
        const Dictionary &state,
        int64_t actor
    ) const;
    Dictionary encode_actions_v7(
        const Dictionary &state,
        int64_t actor,
        const Array &actions
    ) const;
    Dictionary encode_choices_v7(
        const Dictionary &state,
        int64_t actor,
        const Dictionary &request,
        const Array &candidates
    ) const;
    Dictionary determinize_information_set(
        const Dictionary &state,
        int64_t actor,
        int64_t seed
    ) const;
    String action_signature_v2(const Dictionary &action) const;

private:
    ptcg::ai::NativeGameKernel game_kernel_;
    ptcg::ai::NativeInformationSetEncoder encoder_;
    ptcg::ai::NativeDeterminizer determinizer_;
    ptcg::ai::Value cards_ = ptcg::ai::Value::make_object();
    ptcg::ai::Value decks_ = ptcg::ai::Value::make_object();
    ptcg::ai::Value choice_context_pending_ =
        ptcg::ai::Value::make_object();
    ptcg::ai::Value choice_context_continuation_ =
        ptcg::ai::Value::make_object();
    std::string choice_context_match_id_;
    int64_t choice_context_revision_ = -1;
    int64_t choice_context_actor_ = -1;
    bool choice_context_valid_ = false;
};

} // namespace godot
