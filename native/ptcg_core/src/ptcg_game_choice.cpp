#include "ptcg_game.hpp"
#include "ptcg_game_internal.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <limits>
#include <stdexcept>
#include <string>
#include <string_view>
#include <unordered_set>
#include <utility>

namespace ptcg::ai {

using namespace game_detail;

Value NativeGameKernel::choice_candidates(const Value &request) {
    Array result;
    if (!request.is_object()) {
        return Value(std::move(result));
    }
    const Value *allowed = request.find("allowed_candidates");
    if (allowed != nullptr) {
        if (!allowed->is_array()) {
            throw std::invalid_argument(
                "allowed_choice_candidates_must_be_array"
            );
        }
        for (const Value &candidate : allowed->as_array()) {
            if (
                !candidate.is_object()
                || string_arg(candidate, "kind") != "choice"
                || !candidate.find("selected_options")
                || !candidate.find("selected_options")->is_array()
            ) {
                throw std::invalid_argument(
                    "invalid_allowed_choice_candidate"
                );
            }
            result.push_back(candidate);
        }
        return Value(std::move(result));
    }
    const Value *options = request.find("options");
    if (options == nullptr || !options->is_array()) {
        return Value(std::move(result));
    }
    constexpr std::size_t MAX_CANDIDATES = 256;
    const std::int64_t minimum = std::max<std::int64_t>(
        0,
        integer_arg(request, "min_select")
    );
    const std::int64_t maximum = std::max<std::int64_t>(
        minimum,
        integer_arg(request, "max_select")
    );
    const bool allow_duplicates = bool_arg(
        request,
        "allow_duplicates"
    );
    const std::string request_id = string_arg(request, "request_id");
    const std::string request_type = string_arg(
        request,
        "request_type",
        "select"
    );
    const Value *constraints = request.find("metadata");
    if (constraints == nullptr || !constraints->is_object()) {
        constraints = request.find("presentation");
    }
    const bool same_target = constraints != nullptr
        && constraints->is_object()
        && bool_arg(*constraints, "same_target");
    const std::int64_t max_per_target = constraints != nullptr
        && constraints->is_object()
        ? std::max<std::int64_t>(
            0,
            integer_arg(
                *constraints,
                "max_per_target",
                std::numeric_limits<std::int64_t>::max()
            )
        )
        : std::numeric_limits<std::int64_t>::max();
    const bool retreat_payment = request_type == "select_retreat_payment";
    const std::int64_t required_retreat_units = (
        retreat_payment && constraints != nullptr
    ) ? integer_arg(*constraints, "required_units", -1) : -1;
    std::unordered_map<std::string, std::int64_t> retreat_units;
    if (retreat_payment) {
        const Value *references = constraints != nullptr
            ? constraints->find("attachment_refs") : nullptr;
        if (
            required_retreat_units <= 0
            || references == nullptr || !references->is_array()
        ) {
            return Value(std::move(result));
        }
        for (const Value &reference : references->as_array()) {
            const std::string option_id = string_arg(reference, "option_id");
            const std::int64_t units = integer_arg(reference, "units", 0);
            if (
                option_id.empty() || units <= 0
                || !retreat_units.emplace(option_id, units).second
            ) {
                return Value(std::move(result));
            }
        }
    }
    const auto target_key = [&request_type](const Value &option) {
        const Value *reference = option.find("ref");
        const Value &target = (
            reference != nullptr && reference->is_object()
        ) ? *reference : option;
        const std::string slot = string_arg(target, "slot");
        if (!slot.empty()) {
            return std::to_string(integer_arg(target, "player", -1))
                + ":" + slot;
        }
        return stable_choice_option_id(option, request_type);
    };
    const auto energy_source_index = [](const Value &option) {
        const std::string option_id = string_arg(option, "option_id");
        constexpr std::string_view prefix = "energy:";
        if (option_id.rfind(prefix, 0) != 0) {
            return std::int64_t{-1};
        }
        const std::size_t end = option_id.find(':', prefix.size());
        if (end == std::string::npos) {
            return std::int64_t{-2};
        }
        try {
            return static_cast<std::int64_t>(std::stoll(
                option_id.substr(prefix.size(), end - prefix.size())
            ));
        } catch (const std::exception &) {
            return std::int64_t{-2};
        }
    };
    const auto selection_respects_constraints = [
        &target_key,
        &energy_source_index,
        same_target,
        max_per_target
    ](const std::vector<const Value *> &rows) {
        std::string selected_target;
        std::map<std::string, std::int64_t, std::less<>> per_target;
        std::unordered_set<std::int64_t> energy_sources;
        for (const Value *option : rows) {
            if (option == nullptr || !option->is_object()) {
                return false;
            }
            const std::string key = target_key(*option);
            if (key.empty()) {
                return false;
            }
            if (selected_target.empty()) {
                selected_target = key;
            } else if (same_target && key != selected_target) {
                return false;
            }
            if (++per_target[key] > max_per_target) {
                return false;
            }
            const std::int64_t source_index = energy_source_index(*option);
            if (source_index == -2) {
                return false;
            }
            if (
                source_index >= 0
                && !energy_sources.insert(source_index).second
            ) {
                return false;
            }
        }
        return true;
    };
    const auto selection_completes_constraints = [
        &selection_respects_constraints,
        &retreat_units,
        request_type,
        retreat_payment,
        required_retreat_units
    ](const std::vector<const Value *> &rows) {
        if (!selection_respects_constraints(rows)) return false;
        if (!retreat_payment) return true;
        std::int64_t paid = 0;
        std::vector<std::int64_t> units;
        units.reserve(rows.size());
        for (const Value *option : rows) {
            const auto found = retreat_units.find(
                stable_choice_option_id(*option, request_type)
            );
            if (found == retreat_units.end()) return false;
            paid += found->second;
            units.push_back(found->second);
        }
        return paid >= required_retreat_units
            && std::none_of(
                units.begin(),
                units.end(),
                [paid, required_retreat_units](std::int64_t value) {
                    return paid - value >= required_retreat_units;
                }
            );
    };
    std::vector<const Value *> selected;
    std::function<void(std::size_t, std::size_t)> enumerate =
        [&](std::size_t begin, std::size_t remaining) {
            if (result.size() >= MAX_CANDIDATES) {
                return;
            }
            if (remaining == 0) {
                if (!selection_completes_constraints(selected)) {
                    return;
                }
                append_choice_candidate(
                    result,
                    request_id,
                    request_type,
                    selected,
                    false
                );
                return;
            }
            for (
                std::size_t index = begin;
                index < options->as_array().size();
                ++index
            ) {
                selected.push_back(&options->as_array()[index]);
                if (selection_respects_constraints(selected)) {
                    enumerate(
                        allow_duplicates ? index : index + 1,
                        remaining - 1
                    );
                }
                selected.pop_back();
                if (result.size() >= MAX_CANDIDATES) {
                    return;
                }
            }
        };
    for (
        std::int64_t size = minimum;
        size <= maximum && result.size() < MAX_CANDIDATES;
        ++size
    ) {
        enumerate(0, static_cast<std::size_t>(size));
    }
    if (
        bool_arg(request, "can_cancel")
        && result.size() < MAX_CANDIDATES
    ) {
        append_choice_candidate(
            result,
            request_id,
            request_type,
            {},
            true
        );
    }
    // Multiple identical physical cards can legitimately produce the same
    // semantic selection (especially for allow_duplicates distribution
    // requests). The tree is keyed by stable signatures, so collapse those
    // aliases before expansion instead of letting a determinization create
    // duplicate edges.
    Array unique;
    unique.reserve(result.size());
    std::unordered_set<std::string> signatures;
    for (Value &candidate : result) {
        const std::string signature = string_arg(
            candidate,
            "signature"
        );
        if (
            !signature.empty()
            && signatures.insert(signature).second
        ) {
            unique.push_back(std::move(candidate));
        }
    }
    return Value(std::move(unique));
}


} // namespace ptcg::ai
