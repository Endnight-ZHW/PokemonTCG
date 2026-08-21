#include "../src/ptcg_ai_core.hpp"
#include "../src/ptcg_actor_v3.hpp"
#include "../src/ptcg_determinizer.hpp"
#include "../src/ptcg_encoder_v3.hpp"
#include "ptcg_game.hpp"
#include "../src/ptcg_infoset.hpp"
#include "ptcg_rules.hpp"
#include "ptcg_rules_session.hpp"
#include "../src/ptcg_search.hpp"
#include "ptcg_value.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>
#include <stdexcept>

#include <pybind11/numpy.h>
#include <pybind11/pybind11.h>
#include <pybind11/stl.h>

namespace py = pybind11;
using namespace pybind11::literals;
using ptcg::ai::CompactState;
using ptcg::ai::ActorGameResultV3;
using ptcg::ai::ActorPoolConfigV3;
using ptcg::ai::GameTaskV3;
using ptcg::ai::InferenceRequest;
using ptcg::ai::InferenceResponse;
using ptcg::ai::InferenceTensorSpec;
using ptcg::ai::NativeSelfPlayBatch;
using ptcg::ai::NativeActorPoolV3;
using ptcg::ai::NativeGameKernel;
using ptcg::ai::NativeDeterminizer;
using ptcg::ai::NativeInformationSetEncoderV3;
using ptcg::ai::NativeRulesKernel;
using ptcg::ai::RulesSession;
using ptcg::ai::RulesSessionResult;
using ptcg::ai::NativeSearchConfig;
using ptcg::ai::NativeSearchJob;
using ptcg::ai::NativeSearchLimiter;
using ptcg::ai::NativeSearchResult;
using ptcg::ai::PuctNode;
using ptcg::ai::PuctTree;
using ptcg::ai::TrainingSample;
using ptcg::ai::UndoMark;
using ptcg::ai::XorShift32;
using ptcg::ai::Value;

namespace {

Value value_from_python(const py::handle &source) {
    if (source.is_none()) {
        return Value();
    }
    if (py::isinstance<py::bool_>(source)) {
        return Value(py::cast<bool>(source));
    }
    if (py::isinstance<py::int_>(source)) {
        return Value(py::cast<std::int64_t>(source));
    }
    if (py::isinstance<py::float_>(source)) {
        return Value(py::cast<double>(source));
    }
    if (py::isinstance<py::str>(source)) {
        return Value(py::cast<std::string>(source));
    }
    if (
        py::isinstance<py::list>(source)
        || py::isinstance<py::tuple>(source)
    ) {
        Value::Array result;
        const py::sequence sequence = py::reinterpret_borrow<py::sequence>(
            source
        );
        result.reserve(static_cast<std::size_t>(sequence.size()));
        for (const py::handle entry : sequence) {
            result.push_back(value_from_python(entry));
        }
        return Value(std::move(result));
    }
    if (py::isinstance<py::dict>(source)) {
        Value::Object result;
        const py::dict dictionary = py::reinterpret_borrow<py::dict>(source);
        for (const auto &entry : dictionary) {
            if (!py::isinstance<py::str>(entry.first)) {
                throw py::type_error("native_value_object_key_not_string");
            }
            result.emplace(
                py::cast<std::string>(entry.first),
                value_from_python(entry.second)
            );
        }
        return Value(std::move(result));
    }
    throw py::type_error("unsupported_native_value_type");
}

py::object value_to_python(const Value &source) {
    switch (source.type()) {
        case Value::Type::null_value:
            return py::none();
        case Value::Type::boolean:
            return py::bool_(source.as_bool());
        case Value::Type::integer:
            return py::int_(source.as_integer());
        case Value::Type::number:
            return py::float_(source.as_number());
        case Value::Type::string:
            return py::str(source.as_string());
        case Value::Type::array: {
            py::list result;
            for (const Value &entry : source.as_array()) {
                result.append(value_to_python(entry));
            }
            return std::move(result);
        }
        case Value::Type::object: {
            py::dict result;
            for (const auto &[key, value] : source.as_object()) {
                result[py::str(key)] = value_to_python(value);
            }
            return std::move(result);
        }
    }
    throw py::type_error("invalid_native_value_type");
}

py::dict rules_session_result_to_python(
    const RulesSessionResult &native_result
) {
    py::dict result;
    result["success"] = native_result.success;
    result["error_code"] = native_result.error_code;
    result["message_key"] = native_result.message_key;
    result["state"] = value_to_python(native_result.state);
    result["pending"] = value_to_python(native_result.pending);
    result["events"] = value_to_python(Value(native_result.events));
    result["rng_state"] = native_result.rng_state;
    result["winner"] = native_result.winner;
    result["terminal"] = native_result.terminal;
    return result;
}

template <typename T>
void copy_sized(
    const py::array_t<T, py::array::c_style | py::array::forcecast> &source,
    std::vector<T> &destination,
    const char *name
) {
    if (source.size() != static_cast<py::ssize_t>(destination.size())) {
        throw py::value_error(std::string(name) + "_shape_mismatch");
    }
    std::memcpy(
        destination.data(),
        source.data(),
        destination.size() * sizeof(T)
    );
}

template <typename T>
std::vector<T> copy_vector(
    const py::array_t<T, py::array::c_style | py::array::forcecast> &source
) {
    return std::vector<T>(source.data(), source.data() + source.size());
}

InferenceRequest request_from_arrays(
    const py::array_t<float, py::array::c_style | py::array::forcecast>
        &state_global,
    const py::array_t<float, py::array::c_style | py::array::forcecast>
        &entity_numeric,
    const py::array_t<std::int64_t, py::array::c_style | py::array::forcecast>
        &entity_card_ids,
    const py::array_t<std::int64_t, py::array::c_style | py::array::forcecast>
        &entity_type_ids,
    const py::array_t<bool, py::array::c_style | py::array::forcecast>
        &entity_mask,
    const py::array_t<float, py::array::c_style | py::array::forcecast>
        &candidate_numeric,
    const py::array_t<std::int64_t, py::array::c_style | py::array::forcecast>
        &candidate_card_ids,
    const py::array_t<std::int64_t, py::array::c_style | py::array::forcecast>
        &candidate_type_ids,
    const py::array_t<std::int64_t, py::array::c_style | py::array::forcecast>
        &candidate_refs,
    std::int64_t actor_deck_id,
    std::int64_t opponent_deck_id
) {
    if (
        state_global.ndim() != 1
        || entity_numeric.ndim() != 2
        || entity_card_ids.ndim() != 1
        || entity_type_ids.ndim() != 2
        || entity_mask.ndim() != 1
        || candidate_numeric.ndim() != 2
        || candidate_card_ids.ndim() != 1
        || candidate_type_ids.ndim() != 1
        || candidate_refs.ndim() != 2
        || entity_numeric.shape(0) != entity_card_ids.shape(0)
        || entity_type_ids.shape(0) != entity_card_ids.shape(0)
        || entity_mask.shape(0) != entity_card_ids.shape(0)
        || candidate_numeric.shape(0) != candidate_card_ids.shape(0)
        || candidate_type_ids.shape(0) != candidate_card_ids.shape(0)
        || candidate_refs.shape(0) != candidate_card_ids.shape(0)
    ) {
        throw py::value_error("inference_request_rank_mismatch");
    }
    InferenceRequest request(InferenceTensorSpec::v3());
    copy_sized(state_global, request.state_global, "state_global");
    copy_sized(entity_numeric, request.entity_numeric, "entity_numeric");
    copy_sized(entity_card_ids, request.entity_card_ids, "entity_card_ids");
    copy_sized(entity_type_ids, request.entity_type_ids, "entity_type_ids");
    for (std::size_t index = 0; index < request.entity_mask.size(); ++index) {
        request.entity_mask[index] = entity_mask.at(
            static_cast<py::ssize_t>(index)
        ) ? 1 : 0;
    }
    request.candidate_numeric = copy_vector(candidate_numeric);
    request.candidate_card_ids = copy_vector(candidate_card_ids);
    request.candidate_type_ids = copy_vector(candidate_type_ids);
    request.candidate_refs = copy_vector(candidate_refs);
    request.actor_deck_id = actor_deck_id;
    request.opponent_deck_id = opponent_deck_id;
    request.validate();
    return request;
}

py::dict requests_as_numpy(std::vector<InferenceRequest> requests) {
    py::dict result;
    const py::ssize_t count = static_cast<py::ssize_t>(requests.size());
    if (requests.empty()) {
        result["request_ids"] = py::array_t<std::uint64_t>({0});
        return result;
    }
    const InferenceTensorSpec spec = requests.front().spec;
    std::size_t max_candidates = 0;
    for (const InferenceRequest &request : requests) {
        if (!(request.spec == spec)) {
            throw py::value_error("mixed_inference_tensor_specs");
        }
        max_candidates = std::max(
            max_candidates,
            request.candidate_count()
        );
    }

    py::array_t<std::uint64_t> request_ids({count});
    py::array_t<float> state_global({
        count,
        static_cast<py::ssize_t>(spec.state_global_size),
    });
    py::array_t<float> entity_numeric({
        count,
        static_cast<py::ssize_t>(spec.entity_slots),
        static_cast<py::ssize_t>(spec.entity_numeric_size),
    });
    py::array_t<std::int64_t> entity_card_ids({
        count,
        static_cast<py::ssize_t>(spec.entity_slots),
    });
    py::array_t<std::int64_t> entity_type_ids({
        count,
        static_cast<py::ssize_t>(spec.entity_slots),
        static_cast<py::ssize_t>(spec.entity_type_fields),
    });
    py::array_t<bool> entity_mask({
        count,
        static_cast<py::ssize_t>(spec.entity_slots),
    });
    py::array_t<float> candidate_numeric({
        count,
        static_cast<py::ssize_t>(max_candidates),
        static_cast<py::ssize_t>(spec.candidate_numeric_size),
    });
    py::array_t<std::int64_t> candidate_card_ids({
        count,
        static_cast<py::ssize_t>(max_candidates),
    });
    py::array_t<std::int64_t> candidate_type_ids({
        count,
        static_cast<py::ssize_t>(max_candidates),
    });
    py::array_t<std::int64_t> candidate_refs({
        count,
        static_cast<py::ssize_t>(max_candidates),
        static_cast<py::ssize_t>(spec.candidate_ref_fields),
    });
    py::array_t<bool> candidate_mask({
        count,
        static_cast<py::ssize_t>(max_candidates),
    });
    py::array_t<std::int64_t> actor_deck_id({count});
    py::array_t<std::int64_t> opponent_deck_id({count});
    py::array_t<std::int32_t> model_slots({count});
    py::array_t<std::int32_t> encoder_versions({count});

    std::fill_n(
        candidate_numeric.mutable_data(),
        candidate_numeric.size(),
        0.0F
    );
    std::fill_n(
        candidate_card_ids.mutable_data(),
        candidate_card_ids.size(),
        std::int64_t{0}
    );
    std::fill_n(
        candidate_type_ids.mutable_data(),
        candidate_type_ids.size(),
        std::int64_t{0}
    );
    std::fill_n(
        candidate_refs.mutable_data(),
        candidate_refs.size(),
        std::int64_t{0}
    );
    std::fill_n(
        candidate_mask.mutable_data(),
        candidate_mask.size(),
        false
    );

    for (py::ssize_t index = 0; index < count; ++index) {
        const InferenceRequest &request = requests[static_cast<std::size_t>(index)];
        request_ids.mutable_at(index) = request.request_id;
        std::memcpy(
            state_global.mutable_data(index, 0),
            request.state_global.data(),
            request.state_global.size() * sizeof(float)
        );
        std::memcpy(
            entity_numeric.mutable_data(index, 0, 0),
            request.entity_numeric.data(),
            request.entity_numeric.size() * sizeof(float)
        );
        std::memcpy(
            entity_card_ids.mutable_data(index, 0),
            request.entity_card_ids.data(),
            request.entity_card_ids.size() * sizeof(std::int64_t)
        );
        std::memcpy(
            entity_type_ids.mutable_data(index, 0, 0),
            request.entity_type_ids.data(),
            request.entity_type_ids.size() * sizeof(std::int64_t)
        );
        for (std::size_t entity = 0; entity < spec.entity_slots; ++entity) {
            entity_mask.mutable_at(
                index,
                static_cast<py::ssize_t>(entity)
            ) = request.entity_mask[entity] != 0;
        }
        const py::ssize_t candidate_count = static_cast<py::ssize_t>(
            request.candidate_count()
        );
        std::memcpy(
            candidate_numeric.mutable_data(index, 0, 0),
            request.candidate_numeric.data(),
            request.candidate_numeric.size() * sizeof(float)
        );
        std::memcpy(
            candidate_card_ids.mutable_data(index, 0),
            request.candidate_card_ids.data(),
            request.candidate_card_ids.size() * sizeof(std::int64_t)
        );
        std::memcpy(
            candidate_type_ids.mutable_data(index, 0),
            request.candidate_type_ids.data(),
            request.candidate_type_ids.size() * sizeof(std::int64_t)
        );
        std::memcpy(
            candidate_refs.mutable_data(index, 0, 0),
            request.candidate_refs.data(),
            request.candidate_refs.size() * sizeof(std::int64_t)
        );
        std::fill_n(
            candidate_mask.mutable_data(index, 0),
            candidate_count,
            true
        );
        actor_deck_id.mutable_at(index) = request.actor_deck_id;
        opponent_deck_id.mutable_at(index) = request.opponent_deck_id;
        model_slots.mutable_at(index) = request.model_slot;
        encoder_versions.mutable_at(index) = spec.encoder_version;
    }

    result["request_ids"] = std::move(request_ids);
    result["state_global"] = std::move(state_global);
    result["entity_numeric"] = std::move(entity_numeric);
    result["entity_card_ids"] = std::move(entity_card_ids);
    result["entity_type_ids"] = std::move(entity_type_ids);
    result["entity_mask"] = std::move(entity_mask);
    result["candidate_numeric"] = std::move(candidate_numeric);
    result["candidate_card_ids"] = std::move(candidate_card_ids);
    result["candidate_type_ids"] = std::move(candidate_type_ids);
    result["candidate_refs"] = std::move(candidate_refs);
    result["candidate_mask"] = std::move(candidate_mask);
    result["actor_deck_id"] = std::move(actor_deck_id);
    result["opponent_deck_id"] = std::move(opponent_deck_id);
    result["model_slots"] = std::move(model_slots);
    result["encoder_version"] = std::move(encoder_versions);
    return result;
}

py::dict poll_as_numpy(
    NativeSelfPlayBatch &batch,
    std::size_t max_requests,
    std::uint32_t wait_milliseconds,
    std::size_t target_requests,
    std::uint32_t coalesce_milliseconds
) {
    std::vector<InferenceRequest> requests;
    {
        py::gil_scoped_release release;
        requests = batch.poll_inference(
            max_requests,
            wait_milliseconds,
            target_requests,
            coalesce_milliseconds
        );
    }
    return requests_as_numpy(std::move(requests));
}

py::dict drain_samples_as_numpy(NativeSelfPlayBatch &batch) {
    std::vector<TrainingSample> samples;
    {
        py::gil_scoped_release release;
        samples = batch.drain_samples();
    }
    std::size_t max_candidates = 0;
    std::vector<InferenceRequest> requests;
    requests.reserve(samples.size());
    for (const TrainingSample &sample : samples) {
        max_candidates = std::max(
            max_candidates,
            sample.input.candidate_count()
        );
        requests.push_back(sample.input);
    }
    py::dict result = requests_as_numpy(std::move(requests));
    const py::ssize_t count = static_cast<py::ssize_t>(samples.size());
    py::array_t<float> policy_target({
        count,
        static_cast<py::ssize_t>(max_candidates),
    });
    py::array_t<float> wdl_target({count, py::ssize_t{3}});
    py::array_t<std::int32_t> generation({count});
    py::array_t<std::int32_t> actor({count});
    py::array_t<std::uint64_t> game_seed({count});
    py::array_t<std::int32_t> ply({count});
    py::array_t<std::int32_t> model_version({count});
    py::array_t<std::int32_t> cycle({count});
    py::array_t<std::int32_t> phase_bucket({count});
    py::array_t<std::int32_t> source({count});
    py::list game_ids;
    std::fill_n(
        policy_target.mutable_data(),
        policy_target.size(),
        0.0F
    );
    for (py::ssize_t row = 0; row < count; ++row) {
        const TrainingSample &sample = samples[
            static_cast<std::size_t>(row)
        ];
        std::memcpy(
            policy_target.mutable_data(row, 0),
            sample.policy_target.data(),
            sample.policy_target.size() * sizeof(float)
        );
        std::memcpy(
            wdl_target.mutable_data(row, 0),
            sample.wdl_target.data(),
            sample.wdl_target.size() * sizeof(float)
        );
        generation.mutable_at(row) = sample.generation;
        actor.mutable_at(row) = sample.actor;
        game_seed.mutable_at(row) = sample.game_seed;
        ply.mutable_at(row) = sample.ply;
        model_version.mutable_at(row) = sample.model_version;
        cycle.mutable_at(row) = sample.cycle;
        phase_bucket.mutable_at(row) = sample.phase_bucket;
        source.mutable_at(row) = sample.source;
        game_ids.append(py::str(sample.game_id));
    }
    result["policy_target"] = std::move(policy_target);
    result["wdl_target"] = std::move(wdl_target);
    result["generation"] = std::move(generation);
    result["actor"] = std::move(actor);
    result["game_ids"] = py::module_::import("numpy").attr("asarray")(
        std::move(game_ids)
    );
    result["game_seed"] = std::move(game_seed);
    result["ply"] = std::move(ply);
    result["model_version"] = std::move(model_version);
    result["cycle"] = std::move(cycle);
    result["phase_bucket"] = std::move(phase_bucket);
    result["source"] = std::move(source);
    return result;
}

std::vector<float> softmax_row(
    const float *logits,
    std::size_t count
) {
    if (count == 0) {
        throw py::value_error("softmax_row_empty");
    }
    const float maximum = *std::max_element(logits, logits + count);
    if (!std::isfinite(maximum)) {
        throw py::value_error("non_finite_policy_logits");
    }
    std::vector<float> result(count);
    float total = 0.0F;
    for (std::size_t index = 0; index < count; ++index) {
        if (!std::isfinite(logits[index])) {
            throw py::value_error("non_finite_policy_logits");
        }
        result[index] = std::exp(logits[index] - maximum);
        total += result[index];
    }
    for (float &value : result) {
        value /= total;
    }
    return result;
}

GameTaskV3 game_task_v3_from_python(const py::dict &source) {
    GameTaskV3 result;
    result.game_id = py::cast<std::string>(source["game_id"]);
    result.cycle = source.contains("cycle")
        ? py::cast<std::int32_t>(source["cycle"]) : 0;
    result.deck_a = py::cast<std::string>(source["deck_a"]);
    result.deck_b = py::cast<std::string>(source["deck_b"]);
    result.seed = py::cast<std::uint32_t>(source["seed"]);
    result.seat_a = py::cast<std::int32_t>(source["seat_a"]);
    result.first_player = py::cast<std::int32_t>(source["first_player"]);
    result.max_decisions = source.contains("max_decisions")
        ? py::cast<std::uint32_t>(source["max_decisions"]) : 512;
    if (source.contains("model_slots")) {
        const std::vector<std::int32_t> values = py::cast<
            std::vector<std::int32_t>
        >(source["model_slots"]);
        if (values.size() != 2) {
            throw py::value_error("v3_task_model_slots_shape");
        }
        std::copy(values.begin(), values.end(), result.model_slots.begin());
    }
    if (source.contains("model_versions")) {
        const std::vector<std::int32_t> values = py::cast<
            std::vector<std::int32_t>
        >(source["model_versions"]);
        if (values.size() != 2) {
            throw py::value_error("v3_task_model_versions_shape");
        }
        std::copy(values.begin(), values.end(), result.model_versions.begin());
    }
    return result;
}

ActorPoolConfigV3 actor_config_v3_from_python(const py::dict &source) {
    ActorPoolConfigV3 result;
    auto set_uint = [&source](const char *key, std::uint32_t &destination) {
        if (source.contains(key)) {
            destination = py::cast<std::uint32_t>(source[key]);
        }
    };
    auto set_float = [&source](const char *key, float &destination) {
        if (source.contains(key)) {
            destination = py::cast<float>(source[key]);
        }
    };
    set_uint("concurrent_games", result.concurrent_games);
    set_uint("simulations", result.simulations);
    set_uint("max_depth", result.max_depth);
    set_uint("max_inflight_leaves", result.max_inflight_leaves);
    set_uint(
        "inference_wait_milliseconds",
        result.inference_wait_milliseconds
    );
    set_float("c_puct", result.c_puct);
    set_float("dirichlet_epsilon", result.dirichlet_epsilon);
    if (source.contains("training")) {
        result.training = py::cast<bool>(source["training"]);
    }
    if (source.contains("direct_policy")) {
        result.direct_policy = py::cast<bool>(source["direct_policy"]);
    }
    return result;
}

py::dict actor_game_v3_to_python(const ActorGameResultV3 &source) {
    return py::dict(
        "game_id"_a=source.game_id,
        "cycle"_a=source.cycle,
        "deck_a"_a=source.deck_a,
        "deck_b"_a=source.deck_b,
        "seed"_a=source.seed,
        "seat_a"_a=source.seat_a,
        "first_player"_a=source.first_player,
        "model_slots"_a=source.model_slots,
        "model_versions"_a=source.model_versions,
        "max_decisions"_a=source.max_decisions,
        "success"_a=source.success,
        "terminal"_a=source.terminal,
        "truncated"_a=source.truncated,
        "error"_a=source.error,
        "winner"_a=source.winner,
        "decisions"_a=source.decisions,
        "simulations"_a=source.simulations,
        "samples"_a=source.samples,
        "state_hash"_a=source.state_hash,
        "determinization_microseconds"_a=source.determinization_microseconds,
        "projection_microseconds"_a=source.projection_microseconds,
        "candidate_generation_microseconds"_a=
            source.candidate_generation_microseconds,
        "apply_microseconds"_a=source.apply_microseconds,
        "encoding_microseconds"_a=source.encoding_microseconds,
        "inference_wait_microseconds"_a=source.inference_wait_microseconds
    );
}

} // namespace

PYBIND11_MODULE(ptcg_ai_core, module) {
    module.doc() = "PTCG Deep AI v3 native actor/search core";
    module.def("abi_version", []() {
        return ptcg::ai::NATIVE_ABI_VERSION;
    });
    module.def("production_ready", []() {
        // This is the technical native-kernel gate. External parity,
        // performance, device and strength evidence is validated by the
        // fail-closed Python release-evidence aggregator.
        return true;
    });
    module.def("production_blockers", []() {
        return std::vector<std::string>{};
    });
    module.def(
        "information_set_hash",
        &ptcg::ai::information_set_hash,
        py::arg("public_words"),
        py::arg("actor_private_words"),
        py::arg("actor")
    );
    module.def(
        "validate_runtime_snapshot",
        [](const py::dict &snapshot, std::int32_t actor) {
            return ptcg::ai::validate_runtime_snapshot(
                value_from_python(snapshot),
                actor
            );
        },
        py::arg("snapshot"),
        py::arg("actor")
    );
    module.def(
        "project_information_set",
        [](const py::dict &snapshot, std::int32_t actor) {
            Value native_snapshot = value_from_python(snapshot);
            ptcg::ai::InformationSetProjection projection;
            {
                py::gil_scoped_release release;
                projection = ptcg::ai::project_information_set(
                    native_snapshot,
                    actor
                );
            }
            py::dict result;
            result["observation"] = value_to_python(
                projection.observation
            );
            result["public_hash"] = projection.public_hash;
            result["actor_private_hash"] =
                projection.actor_private_hash;
            result["tree_key"] = projection.tree_key;
            return result;
        },
        py::arg("snapshot"),
        py::arg("actor")
    );

    py::class_<XorShift32>(module, "XorShift32")
        .def(py::init<std::uint32_t>(), py::arg("seed") = 0x6D2B79F5u)
        .def_property("state", &XorShift32::state, &XorShift32::set_state)
        .def("next_u32", &XorShift32::next_u32)
        .def("next_unit", &XorShift32::next_unit);

    py::class_<UndoMark>(module, "UndoMark")
        .def_readonly("journal_size", &UndoMark::journal_size);

    py::class_<CompactState>(module, "CompactState")
        .def(py::init<std::size_t>(), py::arg("word_count"))
        .def("__len__", &CompactState::size)
        .def("get", &CompactState::get)
        .def("set", &CompactState::set)
        .def("mark", &CompactState::mark)
        .def("undo", &CompactState::undo)
        .def("clear_journal", &CompactState::clear_journal)
        .def("words", [](const CompactState &state) {
            return state.words();
        });

    py::class_<PuctNode>(module, "PuctNode")
        .def("expand", &PuctNode::expand)
        .def("select", &PuctNode::select)
        .def("reserve", &PuctNode::reserve)
        .def("release", &PuctNode::release)
        .def("backup", &PuctNode::backup)
        .def_property_readonly("expanded", &PuctNode::expanded)
        .def_property_readonly("actor", &PuctNode::actor)
        .def("__len__", &PuctNode::size)
        .def("edge", [](const PuctNode &node, std::size_t index) {
            const auto &edge = node.edge(index);
            return py::dict(
                "signature"_a=edge.signature,
                "prior"_a=edge.prior,
                "visits"_a=edge.visits,
                "value_sum"_a=edge.value_sum,
                "in_flight"_a=edge.in_flight,
                "q"_a=edge.q()
            );
        });

    py::class_<PuctTree>(module, "PuctTree")
        .def(py::init<>())
        .def(
            "node",
            &PuctTree::node,
            py::return_value_policy::reference_internal
        )
        .def("clear", &PuctTree::clear)
        .def("__len__", &PuctTree::size);

    py::class_<
        NativeSelfPlayBatch,
        std::shared_ptr<NativeSelfPlayBatch>
    >(module, "NativeSelfPlayBatch")
        .def(py::init<>())
        .def(
            "enqueue",
            [](NativeSelfPlayBatch &batch,
               const py::array_t<float, py::array::c_style | py::array::forcecast>
                   &state_global,
               const py::array_t<float, py::array::c_style | py::array::forcecast>
                   &entity_numeric,
               const py::array_t<std::int64_t, py::array::c_style | py::array::forcecast>
                   &entity_card_ids,
               const py::array_t<std::int64_t, py::array::c_style | py::array::forcecast>
                   &entity_type_ids,
               const py::array_t<bool, py::array::c_style | py::array::forcecast>
                   &entity_mask,
               const py::array_t<float, py::array::c_style | py::array::forcecast>
                   &candidate_numeric,
               const py::array_t<std::int64_t, py::array::c_style | py::array::forcecast>
                   &candidate_card_ids,
               const py::array_t<std::int64_t, py::array::c_style | py::array::forcecast>
                   &candidate_type_ids,
               const py::array_t<std::int64_t, py::array::c_style | py::array::forcecast>
                   &candidate_refs,
               std::int64_t actor_deck_id,
               std::int64_t opponent_deck_id) {
                return batch.enqueue(request_from_arrays(
                    state_global,
                    entity_numeric,
                    entity_card_ids,
                    entity_type_ids,
                    entity_mask,
                    candidate_numeric,
                    candidate_card_ids,
                    candidate_type_ids,
                    candidate_refs,
                    actor_deck_id,
                    opponent_deck_id
                ));
            }
        )
        .def(
            "poll_inference",
            &poll_as_numpy,
            py::arg("max_requests"),
            py::arg("wait_milliseconds") = 0,
            py::arg("target_requests") = 1,
            py::arg("coalesce_milliseconds") = 0
        )
        .def(
            "submit_inference",
            [](NativeSelfPlayBatch &batch,
               const py::array_t<std::uint64_t, py::array::c_style | py::array::forcecast>
                   &request_ids,
               const py::array_t<float, py::array::c_style | py::array::forcecast>
                   &policy_logits,
               const py::array_t<float, py::array::c_style | py::array::forcecast>
                   &wdl_logits,
               const py::array_t<bool, py::array::c_style | py::array::forcecast>
                   &candidate_mask) {
                if (
                    policy_logits.ndim() != 2
                    || wdl_logits.ndim() != 2
                    || candidate_mask.ndim() != 2
                    || request_ids.ndim() != 1
                    || policy_logits.shape(0) != request_ids.shape(0)
                    || wdl_logits.shape(0) != request_ids.shape(0)
                    || wdl_logits.shape(1) != 3
                    || candidate_mask.shape(0) != request_ids.shape(0)
                    || candidate_mask.shape(1) != policy_logits.shape(1)
                ) {
                    throw py::value_error("submit_inference_shape_mismatch");
                }
                std::vector<InferenceResponse> responses;
                for (py::ssize_t row = 0; row < request_ids.shape(0); ++row) {
                    std::size_t candidates = 0;
                    while (
                        candidates < static_cast<std::size_t>(candidate_mask.shape(1))
                        && candidate_mask.at(
                            row,
                            static_cast<py::ssize_t>(candidates)
                        )
                    ) {
                        ++candidates;
                    }
                    InferenceResponse response;
                    response.request_id = request_ids.at(row);
                    response.policy = softmax_row(
                        policy_logits.data(row, 0),
                        candidates
                    );
                    const std::vector<float> wdl = softmax_row(
                        wdl_logits.data(row, 0),
                        3
                    );
                    std::copy(wdl.begin(), wdl.end(), response.wdl.begin());
                    responses.push_back(std::move(response));
                }
                batch.submit_inference(responses);
            }
        )
        .def(
            "take_response",
            [](NativeSelfPlayBatch &batch, std::uint64_t request_id) -> py::object {
                const auto response = batch.take_response(request_id);
                if (!response.has_value()) {
                    return py::none();
                }
                return py::make_tuple(
                    response->policy,
                    response->wdl
                );
            }
        )
        .def(
            "append_sample",
            [](NativeSelfPlayBatch &batch,
               const py::array_t<float, py::array::c_style | py::array::forcecast>
                   &state_global,
               const py::array_t<float, py::array::c_style | py::array::forcecast>
                   &entity_numeric,
               const py::array_t<std::int64_t, py::array::c_style | py::array::forcecast>
                   &entity_card_ids,
               const py::array_t<std::int64_t, py::array::c_style | py::array::forcecast>
                   &entity_type_ids,
               const py::array_t<bool, py::array::c_style | py::array::forcecast>
                   &entity_mask,
               const py::array_t<float, py::array::c_style | py::array::forcecast>
                   &candidate_numeric,
               const py::array_t<std::int64_t, py::array::c_style | py::array::forcecast>
                   &candidate_card_ids,
               const py::array_t<std::int64_t, py::array::c_style | py::array::forcecast>
                   &candidate_type_ids,
               const py::array_t<std::int64_t, py::array::c_style | py::array::forcecast>
                   &candidate_refs,
               std::int64_t actor_deck_id,
               std::int64_t opponent_deck_id,
               const py::array_t<float, py::array::c_style | py::array::forcecast>
                   &policy_target,
               const py::array_t<float, py::array::c_style | py::array::forcecast>
                   &wdl_target,
               std::int32_t generation,
               std::int32_t actor) {
                TrainingSample sample;
                sample.input = request_from_arrays(
                    state_global,
                    entity_numeric,
                    entity_card_ids,
                    entity_type_ids,
                    entity_mask,
                    candidate_numeric,
                    candidate_card_ids,
                    candidate_type_ids,
                    candidate_refs,
                    actor_deck_id,
                    opponent_deck_id
                );
                sample.policy_target = copy_vector(policy_target);
                if (wdl_target.size() != 3) {
                    throw py::value_error("wdl_target_shape_mismatch");
                }
                std::copy_n(
                    wdl_target.data(),
                    3,
                    sample.wdl_target.begin()
                );
                sample.generation = generation;
                sample.actor = actor;
                py::gil_scoped_release release;
                batch.append_sample(std::move(sample));
            }
        )
        .def("drain_samples", &drain_samples_as_numpy)
        .def_property_readonly(
            "pending_requests",
            &NativeSelfPlayBatch::pending_requests
        )
        .def("close", &NativeSelfPlayBatch::close)
        .def_property_readonly("closed", &NativeSelfPlayBatch::closed);

    py::class_<NativeActorPoolV3>(module, "NativeActorPoolV3")
        .def(
            py::init([](
                const py::dict &catalog,
                const py::dict &decks,
                std::shared_ptr<NativeSelfPlayBatch> batch,
                std::shared_ptr<NativeSearchLimiter> limiter,
                const py::dict &config
            ) {
                return std::make_unique<NativeActorPoolV3>(
                    value_from_python(catalog),
                    value_from_python(decks),
                    std::move(batch),
                    std::move(limiter),
                    actor_config_v3_from_python(config)
                );
            }),
            py::arg("catalog"),
            py::arg("decks"),
            py::arg("batch"),
            py::arg("limiter"),
            py::arg("config") = py::dict()
        )
        .def(
            "start",
            [](NativeActorPoolV3 &pool, const py::list &tasks) {
                std::vector<GameTaskV3> native_tasks;
                native_tasks.reserve(tasks.size());
                for (const py::handle &task : tasks) {
                    native_tasks.push_back(game_task_v3_from_python(
                        py::cast<py::dict>(task)
                    ));
                }
                py::gil_scoped_release release;
                pool.start(std::move(native_tasks));
            },
            py::arg("tasks")
        )
        .def("pause", &NativeActorPoolV3::pause)
        .def("resume", &NativeActorPoolV3::resume)
        .def("cancel", &NativeActorPoolV3::cancel)
        .def("wait", [](NativeActorPoolV3 &pool) {
            py::gil_scoped_release release;
            pool.wait();
        })
        .def("drain_games", [](NativeActorPoolV3 &pool) {
            py::list result;
            for (const ActorGameResultV3 &game : pool.drain_games()) {
                result.append(actor_game_v3_to_python(game));
            }
            return result;
        })
        .def("metrics", [](const NativeActorPoolV3 &pool) {
            return value_to_python(pool.metrics());
        })
        .def_property_readonly("running", &NativeActorPoolV3::running)
        .def_property_readonly("finished", &NativeActorPoolV3::finished);

    py::class_<
        NativeSearchLimiter,
        std::shared_ptr<NativeSearchLimiter>
    >(module, "NativeSearchLimiter")
        .def(py::init<std::size_t>(), py::arg("capacity"))
        .def_property_readonly(
            "capacity",
            &NativeSearchLimiter::capacity
        )
        .def_property_readonly("active", &NativeSearchLimiter::active)
        .def_property_readonly(
            "max_active",
            &NativeSearchLimiter::max_active
        );

    py::class_<NativeSearchJob>(module, "NativeSearchJob")
        .def(
            py::init([](
                const py::dict &cards,
                const py::dict &decks,
                std::shared_ptr<NativeSelfPlayBatch> batch,
                std::shared_ptr<NativeSearchLimiter> limiter
            ) {
                return std::make_unique<NativeSearchJob>(
                    value_from_python(cards),
                    value_from_python(decks),
                    std::move(batch),
                    std::move(limiter)
                );
            }),
            py::arg("cards"),
            py::arg("decks"),
            py::arg("batch"),
            py::arg("limiter") = nullptr
        )
        .def(
            "start",
            [](NativeSearchJob &job,
               const py::dict &root_state,
               std::int32_t root_actor,
               std::uint32_t seed,
               const py::dict &config) {
                NativeSearchConfig native_config;
                auto set_uint = [&config](
                    const char *key,
                    std::uint32_t &destination
                ) {
                    if (config.contains(key)) {
                        destination = py::cast<std::uint32_t>(
                            config[key]
                        );
                    }
                };
                auto set_float = [&config](
                    const char *key,
                    float &destination
                ) {
                    if (config.contains(key)) {
                        destination = py::cast<float>(config[key]);
                    }
                };
                set_uint("simulations", native_config.simulations);
                set_uint("max_depth", native_config.max_depth);
                set_uint(
                    "inference_wait_milliseconds",
                    native_config.inference_wait_milliseconds
                );
                set_uint(
                    "max_inflight_leaves",
                    native_config.max_inflight_leaves
                );
                set_float("c_puct", native_config.c_puct);
                set_float(
                    "dirichlet_epsilon",
                    native_config.dirichlet_epsilon
                );
                set_float("temperature", native_config.temperature);
                if (config.contains("training")) {
                    native_config.training = py::cast<bool>(
                        config["training"]
                    );
                }
                if (config.contains("model_slot")) {
                    native_config.model_slot = py::cast<std::int32_t>(
                        config["model_slot"]
                    );
                }
                if (config.contains("verify_candidate_cache")) {
                    native_config.verify_candidate_cache = py::cast<bool>(
                        config["verify_candidate_cache"]
                    );
                }
                Value native_state = value_from_python(root_state);
                py::gil_scoped_release release;
                job.start(
                    std::move(native_state),
                    root_actor,
                    seed,
                    native_config
                );
            },
            py::arg("root_state"),
            py::arg("root_actor"),
            py::arg("seed"),
            py::arg("config") = py::dict()
        )
        .def(
            "start_choice",
            [](NativeSearchJob &job,
               const py::dict &root_state,
               std::int32_t root_actor,
               const py::dict &root_pending,
               const py::dict &root_continuation,
               std::uint32_t seed,
               const py::dict &config) {
                NativeSearchConfig native_config;
                auto set_uint = [&config](
                    const char *key,
                    std::uint32_t &destination
                ) {
                    if (config.contains(key)) {
                        destination = py::cast<std::uint32_t>(
                            config[key]
                        );
                    }
                };
                auto set_float = [&config](
                    const char *key,
                    float &destination
                ) {
                    if (config.contains(key)) {
                        destination = py::cast<float>(config[key]);
                    }
                };
                set_uint("simulations", native_config.simulations);
                set_uint("max_depth", native_config.max_depth);
                set_uint(
                    "inference_wait_milliseconds",
                    native_config.inference_wait_milliseconds
                );
                set_uint(
                    "max_inflight_leaves",
                    native_config.max_inflight_leaves
                );
                set_float("c_puct", native_config.c_puct);
                set_float(
                    "dirichlet_epsilon",
                    native_config.dirichlet_epsilon
                );
                set_float("temperature", native_config.temperature);
                if (config.contains("training")) {
                    native_config.training = py::cast<bool>(
                        config["training"]
                    );
                }
                if (config.contains("model_slot")) {
                    native_config.model_slot = py::cast<std::int32_t>(
                        config["model_slot"]
                    );
                }
                if (config.contains("verify_candidate_cache")) {
                    native_config.verify_candidate_cache = py::cast<bool>(
                        config["verify_candidate_cache"]
                    );
                }
                Value native_state = value_from_python(root_state);
                Value native_pending = value_from_python(root_pending);
                Value native_continuation = value_from_python(
                    root_continuation
                );
                py::gil_scoped_release release;
                job.start_choice(
                    std::move(native_state),
                    root_actor,
                    std::move(native_pending),
                    std::move(native_continuation),
                    seed,
                    native_config
                );
            },
            py::arg("root_state"),
            py::arg("root_actor"),
            py::arg("root_pending"),
            py::arg("root_continuation"),
            py::arg("seed"),
            py::arg("config") = py::dict()
        )
        .def("cancel", &NativeSearchJob::cancel)
        .def("stop", &NativeSearchJob::stop)
        .def_property_readonly("running", &NativeSearchJob::running)
        .def_property_readonly("finished", &NativeSearchJob::finished)
        .def(
            "wait",
            [](NativeSearchJob &job) {
                NativeSearchResult result;
                {
                    py::gil_scoped_release release;
                    result = job.wait();
                }
                py::dict payload;
                payload["success"] = result.success;
                payload["cancelled"] = result.cancelled;
                payload["error"] = result.error;
                payload["selected"] = value_to_python(result.selected);
                payload["next_pending"] = value_to_python(
                    result.next_pending
                );
                payload["next_continuation"] = value_to_python(
                    result.next_continuation
                );
                payload["next_state_revision"] =
                    result.next_state_revision;
                payload["candidates"] = value_to_python(
                    result.candidates
                );
                payload["visits"] = value_to_python(result.visits);
                payload["value_sums"] = value_to_python(
                    result.value_sums
                );
                payload["probabilities"] = value_to_python(
                    result.probabilities
                );
                payload["root_value"] = result.root_value;
                payload["simulations"] = result.simulations;
                payload["tree_nodes"] = result.tree_nodes;
                payload["chance_nodes"] = result.chance_nodes;
                payload["chance_edges"] = result.chance_edges;
                payload["determinization_microseconds"] =
                    result.determinization_microseconds;
                payload["projection_microseconds"] =
                    result.projection_microseconds;
                payload["candidate_generation_microseconds"] =
                    result.candidate_generation_microseconds;
                payload["apply_microseconds"] = result.apply_microseconds;
                payload["encoding_microseconds"] =
                    result.encoding_microseconds;
                payload["inference_wait_microseconds"] =
                    result.inference_wait_microseconds;
                payload["max_pending_leaves"] =
                    result.max_pending_leaves;
                payload["candidate_cache_hits"] =
                    result.candidate_cache_hits;
                payload["candidate_cache_misses"] =
                    result.candidate_cache_misses;
                payload["apply_undo_journal_entries"] =
                    result.apply_undo_journal_entries;
                payload["apply_undo_operations"] =
                    result.apply_undo_operations;
                return payload;
            }
        );

    py::class_<NativeRulesKernel>(module, "NativeRulesKernel")
        .def(
            py::init([](const py::dict &cards) {
                return NativeRulesKernel(value_from_python(cards));
            }),
            py::arg("cards")
        )
        .def(
            "set_cards",
            [](NativeRulesKernel &kernel, const py::dict &cards) {
                kernel.set_cards(value_from_python(cards));
            }
        )
        .def_property_readonly(
            "card_count",
            &NativeRulesKernel::card_count
        )
        .def(
            "supports",
            &NativeRulesKernel::supports,
            py::arg("op")
        )
        .def_property_readonly(
            "implemented_op_count",
            &NativeRulesKernel::implemented_op_count
        )
        .def_property_readonly_static(
            "required_op_count",
            [](py::object) {
                return NativeRulesKernel::required_op_count();
            }
        )
        .def_property_readonly_static(
            "implemented_ops",
            [](py::object) {
                return NativeRulesKernel::implemented_ops();
            }
        )
        .def(
            "execute",
            [](const NativeRulesKernel &kernel,
               const py::dict &state,
               const py::dict &command_spec,
               std::int32_t actor,
               const std::string &source_slot,
               std::uint32_t seed,
               const std::string &context_mode) {
                Value native_state = value_from_python(state);
                Value native_command = value_from_python(command_spec);
                ptcg::ai::VmExecutionResult result;
                {
                    py::gil_scoped_release release;
                    result = kernel.execute(
                        std::move(native_state),
                        native_command,
                        actor,
                        source_slot,
                        seed,
                        context_mode
                    );
                }
                py::dict payload;
                payload["success"] = result.success;
                payload["error_code"] = result.error_code;
                payload["state"] = value_to_python(result.state);
                payload["context"] = value_to_python(result.context);
                payload["modifier"] = value_to_python(result.modifier);
                payload["pending"] = value_to_python(result.pending);
                payload["continuation"] = value_to_python(
                    result.continuation
                );
                payload["event_types"] = result.event_types;
                payload["events"] = value_to_python(
                    Value(result.events)
                );
                payload["rng_state"] = result.rng_state;
                return payload;
            },
            py::arg("state"),
            py::arg("command_spec"),
            py::arg("actor"),
            py::arg("source_slot"),
            py::arg("seed"),
            py::arg("context_mode")
        )
        .def(
            "resume",
            [](const NativeRulesKernel &kernel,
               const py::dict &state,
               const py::dict &context,
               const py::dict &continuation,
               const py::list &selected_options,
               bool cancelled,
               std::uint32_t rng_state) {
                Value native_state = value_from_python(state);
                Value native_context = value_from_python(context);
                Value native_continuation = value_from_python(
                    continuation
                );
                Value native_selected = value_from_python(selected_options);
                ptcg::ai::VmExecutionResult result;
                {
                    py::gil_scoped_release release;
                    result = kernel.resume(
                        std::move(native_state),
                        std::move(native_context),
                        native_continuation,
                        native_selected,
                        cancelled,
                        rng_state
                    );
                }
                py::dict payload;
                payload["success"] = result.success;
                payload["error_code"] = result.error_code;
                payload["state"] = value_to_python(result.state);
                payload["context"] = value_to_python(result.context);
                payload["modifier"] = value_to_python(result.modifier);
                payload["pending"] = value_to_python(result.pending);
                payload["continuation"] = value_to_python(
                    result.continuation
                );
                payload["event_types"] = result.event_types;
                payload["events"] = value_to_python(
                    Value(result.events)
                );
                payload["rng_state"] = result.rng_state;
                return payload;
            },
            py::arg("state"),
            py::arg("context"),
            py::arg("continuation"),
            py::arg("selected_options"),
            py::arg("cancelled"),
            py::arg("rng_state")
        );

    py::class_<RulesSession>(module, "NativeRulesSession")
        .def(py::init<>())
        .def(
            "set_catalog",
            [](RulesSession &session, const py::dict &catalog) {
                session.set_cards(value_from_python(catalog));
            },
            py::arg("catalog")
        )
        .def(
            "create",
            [](RulesSession &session,
               const py::dict &catalog,
               const py::object &decks,
               const py::dict &match_config,
               std::uint32_t seed) {
                Value native_catalog = value_from_python(catalog);
                Value native_decks = value_from_python(decks);
                Value native_config = value_from_python(match_config);
                RulesSessionResult result;
                {
                    py::gil_scoped_release release;
                    result = session.create(
                        native_catalog,
                        native_decks,
                        native_config,
                        seed
                    );
                }
                return rules_session_result_to_python(result);
            },
            py::arg("catalog"),
            py::arg("decks"),
            py::arg("match_config") = py::dict(),
            py::arg("seed") = 0x6D2B79F5u
        )
        .def(
            "load_scenario",
            [](RulesSession &session,
               const py::dict &snapshot,
               std::uint32_t rng_state,
               const py::dict &match_config) {
                Value native_snapshot = value_from_python(snapshot);
                Value native_config = value_from_python(match_config);
                RulesSessionResult result;
                {
                    py::gil_scoped_release release;
                    result = session.load_scenario(
                        native_snapshot,
                        rng_state,
                        native_config
                    );
                }
                return rules_session_result_to_python(result);
            },
            py::arg("snapshot"),
            py::arg("rng_state"),
            py::arg("match_config") = py::dict()
        )
        .def(
            "legal_actions",
            [](const RulesSession &session, std::int32_t actor) {
                return value_to_python(session.legal_actions(actor));
            },
            py::arg("actor")
        )
        .def(
            "pokemon_max_hp",
            [](const RulesSession &session, const py::dict &pokemon) {
                return session.pokemon_max_hp(value_from_python(pokemon));
            },
            py::arg("pokemon")
        )
        .def(
            "pokemon_current_hp",
            [](const RulesSession &session, const py::dict &pokemon) {
                return session.pokemon_current_hp(
                    value_from_python(pokemon)
                );
            },
            py::arg("pokemon")
        )
        .def(
            "pending_choice",
            [](const RulesSession &session, std::int32_t viewer) {
                return value_to_python(session.pending_choice(viewer));
            },
            py::arg("viewer")
        )
        .def(
            "apply_action",
            [](RulesSession &session, const py::dict &action) {
                Value native_action = value_from_python(action);
                RulesSessionResult result;
                {
                    py::gil_scoped_release release;
                    result = session.apply_action(native_action);
                }
                return rules_session_result_to_python(result);
            },
            py::arg("action")
        )
        .def(
            "apply_choice",
            [](RulesSession &session, const py::dict &response) {
                Value native_response = value_from_python(response);
                RulesSessionResult result;
                {
                    py::gil_scoped_release release;
                    result = session.apply_choice(native_response);
                }
                return rules_session_result_to_python(result);
            },
            py::arg("response")
        )
        .def(
            "surrender",
            [](RulesSession &session, std::int32_t actor) {
                return rules_session_result_to_python(session.concede(actor));
            },
            py::arg("actor")
        )
        .def(
            "view_for",
            [](const RulesSession &session, std::int32_t viewer) {
                return value_to_python(session.view_for(viewer));
            },
            py::arg("viewer")
        )
        .def(
            "snapshot",
            [](const RulesSession &session) {
                return value_to_python(session.snapshot());
            }
        )
        .def(
            "restore",
            [](RulesSession &session,
               const py::dict &snapshot,
               std::uint32_t rng_state) {
                std::string error;
                const bool success = session.restore(
                    value_from_python(snapshot), rng_state, &error);
                return py::dict(
                    "success"_a = success,
                    "error_code"_a = error
                );
            },
            py::arg("snapshot"),
            py::arg("rng_state")
        )
        .def("fork", &RulesSession::fork)
        .def(
            "journal",
            [](const RulesSession &session) {
                return value_to_python(session.journal());
            }
        )
        .def(
            "get_contract",
            [](const RulesSession &session) {
                return value_to_python(session.contract());
            }
        )
        .def_property_readonly("state_hash", &RulesSession::state_hash)
        .def_property_readonly("rng_state", &RulesSession::rng_state)
        .def_property_readonly("revision", &RulesSession::revision)
        .def_property_readonly("initialized", &RulesSession::initialized);

    py::class_<NativeInformationSetEncoderV3>(
        module,
        "NativeInformationSetEncoderV3"
    )
        .def(
            py::init([](const py::dict &cards) {
                return NativeInformationSetEncoderV3(
                    value_from_python(cards)
                );
            }),
            py::arg("cards")
        )
        .def(
            "build_observation",
            [](const NativeInformationSetEncoderV3 &encoder,
               const py::dict &snapshot,
               std::int32_t actor) {
                return value_to_python(encoder.build_observation(
                    value_from_python(snapshot), actor
                ));
            },
            py::arg("snapshot"),
            py::arg("actor")
        )
        .def(
            "encode_actions",
            [](const NativeInformationSetEncoderV3 &encoder,
               const py::dict &observation,
               const py::list &actions) {
                InferenceRequest request;
                Value native_observation = value_from_python(observation);
                Value native_actions = value_from_python(actions);
                {
                    py::gil_scoped_release release;
                    request = encoder.encode_actions(
                        native_observation, native_actions
                    );
                }
                std::vector<InferenceRequest> rows;
                rows.push_back(std::move(request));
                return requests_as_numpy(std::move(rows));
            },
            py::arg("observation"),
            py::arg("actions")
        )
        .def(
            "encode_choices",
            [](const NativeInformationSetEncoderV3 &encoder,
               const py::dict &observation,
               const py::dict &request,
               const py::list &candidates) {
                InferenceRequest encoded;
                Value native_observation = value_from_python(observation);
                Value native_request = value_from_python(request);
                Value native_candidates = value_from_python(candidates);
                {
                    py::gil_scoped_release release;
                    encoded = encoder.encode_choices(
                        native_observation,
                        native_request,
                        native_candidates
                    );
                }
                std::vector<InferenceRequest> rows;
                rows.push_back(std::move(encoded));
                return requests_as_numpy(std::move(rows));
            },
            py::arg("observation"),
            py::arg("request"),
            py::arg("candidates")
        );

    py::class_<NativeDeterminizer>(module, "NativeDeterminizer")
        .def(
            py::init([](const py::dict &decks) {
                return NativeDeterminizer(value_from_python(decks));
            }),
            py::arg("decks")
        )
        .def(
            "set_decks",
            [](NativeDeterminizer &determinizer,
               const py::dict &decks) {
                determinizer.set_decks(value_from_python(decks));
            }
        )
        .def(
            "determinize",
            [](const NativeDeterminizer &determinizer,
               const py::dict &snapshot,
               std::int32_t actor,
               std::uint32_t seed) {
                Value native_snapshot = value_from_python(snapshot);
                Value result;
                {
                    py::gil_scoped_release release;
                    result = determinizer.determinize(
                        native_snapshot,
                        actor,
                        seed
                    );
                }
                return value_to_python(result);
            },
            py::arg("snapshot"),
            py::arg("actor"),
            py::arg("seed")
        );

    py::class_<NativeGameKernel>(module, "NativeGameKernel")
        .def(
            py::init([](const py::dict &cards) {
                return NativeGameKernel(value_from_python(cards));
            }),
            py::arg("cards")
        )
        .def(
            "set_cards",
            [](NativeGameKernel &kernel, const py::dict &cards) {
                kernel.set_cards(value_from_python(cards));
            }
        )
        .def_property_readonly(
            "card_count",
            &NativeGameKernel::card_count
        )
        .def(
            "pokemon_max_hp",
            [](const NativeGameKernel &kernel, const py::dict &pokemon) {
                return kernel.pokemon_max_hp(value_from_python(pokemon));
            },
            py::arg("pokemon")
        )
        .def(
            "pokemon_current_hp",
            [](const NativeGameKernel &kernel, const py::dict &pokemon) {
                return kernel.pokemon_current_hp(
                    value_from_python(pokemon)
                );
            },
            py::arg("pokemon")
        )
        .def(
            "legal_actions",
            [](const NativeGameKernel &kernel,
               const py::dict &state,
               std::int32_t actor) {
                Value native_state = value_from_python(state);
                Value result;
                {
                    py::gil_scoped_release release;
                    result = kernel.legal_actions(native_state, actor);
                }
                return value_to_python(result);
            },
            py::arg("state"),
            py::arg("actor")
        )
        .def_static(
            "choice_candidates",
            [](const py::dict &request) {
                return value_to_python(
                    NativeGameKernel::choice_candidates(
                        value_from_python(request)
                    )
                );
            },
            py::arg("request")
        )
        .def(
            "apply_action",
            [](const NativeGameKernel &kernel,
               const py::dict &state,
               const py::dict &action,
               std::uint32_t rng_state) {
                Value native_state = value_from_python(state);
                Value native_action = value_from_python(action);
                ptcg::ai::GameExecutionResult result;
                {
                    py::gil_scoped_release release;
                    result = kernel.apply_action(
                        std::move(native_state),
                        native_action,
                        rng_state
                    );
                }
                py::dict payload;
                payload["success"] = result.success;
                payload["error_code"] = result.error_code;
                payload["state"] = value_to_python(result.state);
                payload["pending"] = value_to_python(result.pending);
                payload["continuation"] = value_to_python(
                    result.continuation
                );
                payload["event_types"] = result.event_types;
                payload["events"] = value_to_python(
                    Value(result.events)
                );
                payload["rng_state"] = result.rng_state;
                return payload;
            },
            py::arg("state"),
            py::arg("action"),
            py::arg("rng_state")
        )
        .def(
            "resume_choice",
            [](const NativeGameKernel &kernel,
               const py::dict &state,
               const py::dict &continuation,
               const py::list &selected_options,
               bool cancelled,
               std::uint32_t rng_state) {
                Value native_state = value_from_python(state);
                Value native_continuation = value_from_python(
                    continuation
                );
                Value native_selected = value_from_python(selected_options);
                ptcg::ai::GameExecutionResult result;
                {
                    py::gil_scoped_release release;
                    result = kernel.resume_choice(
                        std::move(native_state),
                        native_continuation,
                        native_selected,
                        cancelled,
                        rng_state
                    );
                }
                py::dict payload;
                payload["success"] = result.success;
                payload["error_code"] = result.error_code;
                payload["state"] = value_to_python(result.state);
                payload["pending"] = value_to_python(result.pending);
                payload["continuation"] = value_to_python(
                    result.continuation
                );
                payload["event_types"] = result.event_types;
                payload["events"] = value_to_python(
                    Value(result.events)
                );
                payload["rng_state"] = result.rng_state;
                return payload;
            },
            py::arg("state"),
            py::arg("continuation"),
            py::arg("selected_options"),
            py::arg("cancelled"),
            py::arg("rng_state")
        );
}
