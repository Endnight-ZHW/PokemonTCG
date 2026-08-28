#include "challenge_search_provider_internal.hpp"


#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <functional>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <string>
#include <utility>
#include <vector>
namespace ptcg::ai::challenge_detail {

using namespace challenge;

    bool ChallengeSearchProviderImpl::duplicate_energy_choice_response(
        const ptcg::ai::RulesSession &position,
        const ptcg::ai::Value &pending,
        const ptcg::ai::typed::ChoiceView &choice,
        ptcg::ai::Value &response
    ) const {
        if (!choice.allow_duplicates || choice.request_type != "distribute_energy") {
            return false;
        }
        const ptcg::ai::Value *options_value = pending.find("options");
        const ptcg::ai::Value *presentation_value = pending.find("presentation");
        if (options_value == nullptr || !options_value->is_array()
            || presentation_value == nullptr || !presentation_value->is_object()) {
            return false;
        }
        const auto &options = options_value->as_array();
        const ptcg::ai::Value &presentation = *presentation_value;
        const std::int64_t maximum = std::max<std::int64_t>(0, choice.max_select);
        const std::int64_t minimum = std::max<std::int64_t>(0, choice.min_select);
        const std::int64_t max_per_target = std::max<std::int64_t>(
            0, integer_field(presentation, "max_per_target", 2147483647));
        const bool same_target = bool_field(presentation, "same_target");
        if (same_target) {
            struct Row {
                std::size_t index = 0;
                double score = 0.0;
                std::int64_t useful_count = 0;
            };
            std::vector<Row> ranked;
            ranked.reserve(options.size());
            for (std::size_t index = 0; index < options.size(); ++index) {
                const std::optional<double> base =
                    trusted_evaluator_.choice_option_score(
                        position, choice.player, pending, options[index]);
                const ptcg::ai::Value plan =
                    trusted_evaluator_.energy_target_prefix_plan(
                        position, choice.player, pending,
                        options[index], maximum);
                const std::int64_t count = integer_field(plan, "count");
                // Public ChoiceView options can be shape-valid even when a
                // synthetic/minimal projected state cannot resolve the target
                // for semantic scoring. Cardinality is still authoritative:
                // use deterministic public order as the fallback score.
                const double base_score = base.value_or(0.0);
                double score = count <= 0 ? -10000.0 : base_score
                    + std::max(0.0, std::min(180.0,
                        (plan.find("gain") == nullptr ? 0.0
                            : plan.find("gain")->as_number()) * 0.35));
                score += strategy_catalog_.choice_score(
                    position.search_state(), choice.player,
                    pending, options[index]);
                ranked.push_back({index, score, count});
            }
            const auto approximately_equal = [](double left, double right) {
                const double tolerance = 0.00001
                    * std::max(1.0, std::max(std::abs(left), std::abs(right)));
                return std::abs(left - right) <= tolerance;
            };
            std::stable_sort(ranked.begin(), ranked.end(),
                [&approximately_equal](const Row &left, const Row &right) {
                    if (approximately_equal(left.score, right.score)) {
                        return left.index < right.index;
                    }
                    return left.score > right.score;
                });
            if (ranked.empty()) return false;
            const Row *selected_row = nullptr;
            for (const Row &row : ranked) {
                if (minimum <= 0 && row.score <= 0.0) break;
                if (!string_field(options[row.index], "option_id").empty()) {
                    selected_row = &row;
                    break;
                }
            }
            ptcg::ai::Value::Array selected;
            if (selected_row != nullptr) {
                std::int64_t count = maximum;
                if (selected_row->useful_count >= 0) {
                    count = std::max(minimum,
                        std::min(maximum, selected_row->useful_count));
                }
                count = std::min(count, max_per_target);
                const std::string option_id = string_field(
                    options[selected_row->index], "option_id");
                for (std::int64_t index = 0; index < count; ++index) {
                    selected.emplace_back(option_id);
                }
            }
            if (selected.size() < static_cast<std::size_t>(minimum)) return false;
            const bool cancelled = selected.empty() && choice.can_cancel;
            response = ptcg::ai::Value(ptcg::ai::Value::Object{
                {"request_id", ptcg::ai::Value(choice.request_id)},
                {"option_ids", ptcg::ai::Value(std::move(selected))},
                {"cancelled", ptcg::ai::Value(cancelled)},
            });
            return true;
        }

        if (maximum < 2 || maximum > 3) return false;
        const auto generic_public_distribution = [&] () {
            struct RankedOption {
                std::size_t index = 0;
                double score = 0.0;
            };
            std::vector<RankedOption> ranked;
            ranked.reserve(options.size());
            for (std::size_t index = 0; index < options.size(); ++index) {
                const std::optional<double> base =
                    trusted_evaluator_.choice_option_score(
                        position, choice.player, pending, options[index]);
                if (!base.has_value()) return false;
                ranked.push_back({
                    index,
                    *base + strategy_catalog_.choice_score(
                        position.search_state(), choice.player,
                        pending, options[index]),
                });
            }
            std::stable_sort(
                ranked.begin(), ranked.end(),
                [](const RankedOption &left, const RankedOption &right) {
                    const double tolerance = 0.00001 * std::max(
                        1.0, std::max(std::abs(left.score), std::abs(right.score)));
                    if (std::abs(left.score - right.score) <= tolerance) {
                        return left.index < right.index;
                    }
                    return left.score > right.score;
                });
            std::vector<std::size_t> allowed;
            for (const RankedOption &row : ranked) {
                if (minimum <= 0 && row.score <= 0.0) continue;
                allowed.push_back(row.index);
            }
            if (allowed.empty() && minimum > 0) {
                for (const RankedOption &row : ranked) allowed.push_back(row.index);
            }
            const std::int64_t target_count = minimum <= 0
                ? (allowed.empty() ? 0 : maximum)
                : std::max(minimum, maximum);
            ptcg::ai::Value::Array selected;
            std::map<std::string, std::int64_t> per_target;
            std::string selected_target;
            while (selected.size() < static_cast<std::size_t>(target_count)) {
                bool appended = false;
                for (const std::size_t option_index : allowed) {
                    const std::string option_id = string_field(
                        options[option_index], "option_id");
                    const ptcg::ai::Value *reference = options[option_index].find("ref");
                    const std::string target_key = reference != nullptr
                        && reference->is_object()
                        ? std::to_string(integer_field(
                            *reference, "player", choice.player)) + ":"
                            + string_field(*reference, "slot")
                        : option_id;
                    if (option_id.empty()
                        || (same_target && !selected_target.empty()
                            && target_key != selected_target)
                        || per_target[target_key] >= max_per_target) continue;
                    selected.emplace_back(option_id);
                    if (selected_target.empty()) selected_target = target_key;
                    ++per_target[target_key];
                    appended = true;
                    break;
                }
                if (!appended) break;
            }
            if (selected.size() < static_cast<std::size_t>(minimum)) return false;
            const bool cancelled = selected.empty() && choice.can_cancel;
            response = ptcg::ai::Value(ptcg::ai::Value::Object{
                {"request_id", ptcg::ai::Value(choice.request_id)},
                {"option_ids", ptcg::ai::Value(std::move(selected))},
                {"cancelled", ptcg::ai::Value(cancelled)},
            });
            return true;
        };
        const ptcg::ai::Value *card_ids_value = presentation.find("card_ids");
        if (card_ids_value == nullptr || !card_ids_value->is_array()
            || card_ids_value->as_array().size()
                < static_cast<std::size_t>(maximum)) {
            return generic_public_distribution();
        }
        std::vector<std::string> energy_ids;
        energy_ids.reserve(static_cast<std::size_t>(maximum));
        for (std::int64_t index = 0; index < maximum; ++index) {
            const std::string id = card_ids_value->as_array()[
                static_cast<std::size_t>(index)].string_or();
            const ptcg::ai::Value *definition = cards_.find(id);
            if (definition == nullptr || string_field(*definition, "supertype")
                != "Energy") return false;
            energy_ids.push_back(id);
        }
        struct Target {
            std::size_t option_index = 0;
            std::string option_id;
            std::string slot;
        };
        std::vector<Target> targets;
        std::set<std::string> seen_slots;
        std::set<std::string> seen_ids;
        const ptcg::ai::Value &state = position.search_state();
        const ptcg::ai::Value *players = state.find("players");
        if (players == nullptr || !players->is_array() || choice.player < 0
            || static_cast<std::size_t>(choice.player)
                >= players->as_array().size()) return false;
        const ptcg::ai::Value &owner = players->as_array()[
            static_cast<std::size_t>(choice.player)];
        for (std::size_t index = 0; index < options.size(); ++index) {
            const ptcg::ai::Value &option = options[index];
            const std::string option_id = string_field(option, "option_id");
            const ptcg::ai::Value *reference = option.find("ref");
            const std::string slot = reference != nullptr && reference->is_object()
                ? string_field(*reference, "slot") : std::string{};
            const std::int64_t target_player = reference != nullptr
                && reference->is_object()
                ? integer_field(*reference, "player", choice.player)
                : choice.player;
            if (option_id.empty() || slot.empty() || target_player != choice.player
                || seen_slots.count(slot) || seen_ids.count(option_id)) continue;
            const ptcg::ai::Value *pokemon = nullptr;
            if (slot == "active") pokemon = owner.find("active");
            else if (slot.rfind("bench_", 0) == 0) {
                try {
                    const std::size_t bench_index = static_cast<std::size_t>(
                        std::stoll(slot.substr(6)));
                    const ptcg::ai::Value *bench = owner.find("bench");
                    if (bench != nullptr && bench->is_array()
                        && bench_index < bench->as_array().size()) {
                        pokemon = &bench->as_array()[bench_index];
                    }
                } catch (const std::exception &) {}
            }
            if (pokemon == nullptr || !pokemon->is_object()) continue;
            const std::string public_card = reference != nullptr
                && reference->is_object()
                ? string_field(*reference, "card_id") : std::string{};
            if (!public_card.empty()
                && public_card != string_field(*pokemon, "card_id")) continue;
            seen_slots.insert(slot);
            seen_ids.insert(option_id);
            targets.push_back({index, option_id, slot});
        }
        if (targets.empty()) return false;
        const std::string purpose = string_field(presentation, "purpose");
        const bool relocation = purpose.rfind("energy_relocate", 0) == 0
            || purpose.rfind("relocate_energy", 0) == 0;
        if (relocation && minimum != maximum) return false;
        std::unique_ptr<ptcg::ai::RulesSession> simulation =
            position.fork_for_search(position.rng_state());
        if (!simulation) return false;
        bool found = false;
        double best_score = -std::numeric_limits<double>::infinity();
        ptcg::ai::Value::Array best_ids;
        for (std::int64_t count = minimum; count <= maximum; ++count) {
            std::uint64_t assignment_count = 1;
            for (std::int64_t index = 0; index < count; ++index) {
                assignment_count *= static_cast<std::uint64_t>(targets.size());
            }
            for (std::uint64_t ordinal = 0; ordinal < assignment_count; ++ordinal) {
                std::uint64_t encoded = ordinal;
                std::vector<std::size_t> assignment(static_cast<std::size_t>(count));
                // GDScript expands the leftmost position first. Decode in base N
                // with the last position changing fastest to preserve that order.
                for (std::size_t reverse = assignment.size(); reverse > 0; --reverse) {
                    assignment[reverse - 1] = static_cast<std::size_t>(
                        encoded % targets.size());
                    encoded /= targets.size();
                }
                std::map<std::string, std::int64_t> target_counts;
                bool shape_ok = true;
                for (std::size_t target_index : assignment) {
                    if (++target_counts[targets[target_index].slot] > max_per_target) {
                        shape_ok = false;
                        break;
                    }
                }
                if (!shape_ok) continue;
                ptcg::ai::Value snapshot = position.snapshot();
                ptcg::ai::Value *snapshot_players = snapshot.find("players");
                if (snapshot_players == nullptr || !snapshot_players->is_array()) {
                    return false;
                }
                ptcg::ai::Value &mutable_owner = snapshot_players->as_array()[
                    static_cast<std::size_t>(choice.player)];
                if (relocation) {
                    const std::int32_t source_player = static_cast<std::int32_t>(
                        integer_field(
                            presentation,
                            "source_player",
                            choice.player));
                    const std::string source_slot = string_field(
                        presentation, "source_slot");
                    const ptcg::ai::Value *refs = presentation.find("attachment_refs");
                    if (source_player != choice.player || source_slot.empty()
                        || refs == nullptr || !refs->is_array()
                        || refs->as_array().size() < static_cast<std::size_t>(maximum)) {
                        return false;
                    }
                    ptcg::ai::Value *source = source_slot == "active"
                        ? mutable_owner.find("active") : nullptr;
                    if (source == nullptr && source_slot.rfind("bench_", 0) == 0) {
                        try {
                            const std::size_t index = static_cast<std::size_t>(
                                std::stoll(source_slot.substr(6)));
                            ptcg::ai::Value *bench = mutable_owner.find("bench");
                            if (bench != nullptr && bench->is_array()
                                && index < bench->as_array().size()) {
                                source = &bench->as_array()[index];
                            }
                        } catch (const std::exception &) {}
                    }
                    if (source == nullptr || !source->is_object()) return false;
                    ptcg::ai::Value *attached = source->find("energy_card_ids");
                    if (attached == nullptr || !attached->is_array()) return false;
                    std::vector<std::size_t> indices;
                    std::set<std::size_t> seen;
                    for (std::int64_t index = 0; index < maximum; ++index) {
                        const ptcg::ai::Value &reference = refs->as_array()[
                            static_cast<std::size_t>(index)];
                        const std::int64_t attachment_index = integer_field(
                            reference, "index", -1);
                        if (!reference.is_object() || attachment_index < 0
                            || static_cast<std::size_t>(attachment_index)
                                >= attached->as_array().size()
                            || seen.count(static_cast<std::size_t>(attachment_index))
                            || string_field(reference, "kind") != "attachment"
                            || integer_field(reference, "player", -1) != source_player
                            || string_field(reference, "slot") != source_slot
                            || string_field(reference, "attachment_type") != "energy"
                            || string_field(reference, "card_id") != energy_ids[
                                static_cast<std::size_t>(index)]
                            || attached->as_array()[static_cast<std::size_t>(
                                attachment_index)].string_or() != energy_ids[
                                    static_cast<std::size_t>(index)]) return false;
                        seen.insert(static_cast<std::size_t>(attachment_index));
                        indices.push_back(static_cast<std::size_t>(attachment_index));
                    }
                    std::sort(indices.rbegin(), indices.rend());
                    for (std::size_t index : indices) {
                        attached->as_array().erase(attached->as_array().begin()
                            + static_cast<std::ptrdiff_t>(index));
                    }
                }
                ptcg::ai::Value::Array candidate_ids;
                for (std::size_t position_index = 0;
                    position_index < assignment.size(); ++position_index) {
                    const Target &target = targets[assignment[position_index]];
                    candidate_ids.emplace_back(target.option_id);
                    ptcg::ai::Value *pokemon = target.slot == "active"
                        ? mutable_owner.find("active") : nullptr;
                    if (pokemon == nullptr && target.slot.rfind("bench_", 0) == 0) {
                        const std::size_t index = static_cast<std::size_t>(
                            std::stoll(target.slot.substr(6)));
                        ptcg::ai::Value *bench = mutable_owner.find("bench");
                        if (bench != nullptr && bench->is_array()
                            && index < bench->as_array().size()) {
                            pokemon = &bench->as_array()[index];
                        }
                    }
                    if (pokemon != nullptr && pokemon->is_object()) {
                        ptcg::ai::Value *attached = pokemon->find("energy_card_ids");
                        if (attached == nullptr || !attached->is_array()) {
                            (*pokemon)["energy_card_ids"] =
                                ptcg::ai::Value::make_array();
                            attached = pokemon->find("energy_card_ids");
                        }
                        attached->as_array().emplace_back(
                            energy_ids[position_index]);
                    }
                }
                std::string restore_error;
                if (!simulation->restore(
                    snapshot, position.rng_state(), &restore_error)) return false;
                const double score = trusted_evaluator_
                    .energy_distribution_board_utility(*simulation, choice.player);
                if (!found || score > best_score + 0.001) {
                    found = true;
                    best_score = score;
                    best_ids = std::move(candidate_ids);
                }
            }
        }
        if (!found) return false;
        const bool cancelled = best_ids.empty() && choice.can_cancel;
        response = ptcg::ai::Value(ptcg::ai::Value::Object{
            {"request_id", ptcg::ai::Value(choice.request_id)},
            {"option_ids", ptcg::ai::Value(std::move(best_ids))},
            {"cancelled", ptcg::ai::Value(cancelled)},
        });
        return true;
    }


    bool ChallengeSearchProviderImpl::retreat_payment_response(
        const ptcg::ai::Value &state,
        const ptcg::ai::Value &pending,
        ptcg::ai::Value &response
    ) const {
        const ptcg::ai::Value *presentation = pending.find("presentation");
        const std::int64_t required_units = std::max<std::int64_t>(
            0,
            presentation != nullptr && presentation->is_object()
                ? integer_field(*presentation, "required_units") : 0);
        ptcg::ai::Value::Array selected_ids;
        bool cancelled = false;
        const auto finish = [&]() {
            response = ptcg::ai::Value(ptcg::ai::Value::Object{
                {"request_id", ptcg::ai::Value(string_field(
                    pending, "request_id"))},
                {"option_ids", ptcg::ai::Value(std::move(selected_ids))},
                {"cancelled", ptcg::ai::Value(cancelled)},
            });
            return true;
        };
        if (required_units <= 0) return finish();
        const std::int32_t actor = static_cast<std::int32_t>(integer_field(
            pending, "player", -1));
        const ptcg::ai::Value *players = state.find("players");
        if (
            actor < 0 || actor > 1 || players == nullptr
            || !players->is_array()
            || static_cast<std::size_t>(actor) >= players->as_array().size()
        ) {
            cancelled = bool_field(pending, "can_cancel");
            return finish();
        }
        const ptcg::ai::Value &owner = players->as_array()[
            static_cast<std::size_t>(actor)];
        const ptcg::ai::Value *active = owner.find("active");
        const ptcg::ai::Value *energy_value = active != nullptr
            && active->is_object() ? active->find("energy_card_ids") : nullptr;
        if (energy_value == nullptr || !energy_value->is_array()) {
            cancelled = bool_field(pending, "can_cancel");
            return finish();
        }
        const ptcg::ai::Value::Array &energy_ids = energy_value->as_array();
        const ptcg::ai::Value *options_value = pending.find("options");
        if (options_value == nullptr || !options_value->is_array()) {
            cancelled = bool_field(pending, "can_cancel");
            return finish();
        }
        struct Candidate {
            std::string option_id;
            std::int64_t units = 0;
            std::int64_t attachment_index = -1;
            std::size_t option_order = 0;
        };
        std::vector<Candidate> candidates;
        const auto &options = options_value->as_array();
        candidates.reserve(options.size());
        for (std::size_t order = 0; order < options.size(); ++order) {
            const ptcg::ai::Value *ref = options[order].find("ref");
            if (ref == nullptr || !ref->is_object()) continue;
            const std::int64_t index = integer_field(*ref, "index", -1);
            if (
                string_field(*ref, "kind") != "attachment"
                || string_field(*ref, "attachment_type") != "energy"
                || integer_field(*ref, "player", -1) != actor
                || string_field(*ref, "slot") != "active"
                || index < 0
                || static_cast<std::size_t>(index) >= energy_ids.size()
                || string_field(*ref, "card_id")
                    != energy_ids[static_cast<std::size_t>(index)].string_or()
            ) continue;
            const std::int64_t units = energy_units_provided_by_card(
                energy_ids, static_cast<std::size_t>(index));
            if (units <= 0) continue;
            candidates.push_back(Candidate{
                string_field(options[order], "option_id"),
                units,
                index,
                order,
            });
        }
        std::stable_sort(
            candidates.begin(), candidates.end(),
            [](const Candidate &left, const Candidate &right) {
                if (left.units != right.units) return left.units > right.units;
                if (left.attachment_index != right.attachment_index) {
                    return left.attachment_index < right.attachment_index;
                }
                return left.option_order < right.option_order;
            });
        std::vector<Candidate> selected;
        std::int64_t paid_units = 0;
        for (const Candidate &candidate : candidates) {
            selected.push_back(candidate);
            paid_units += candidate.units;
            if (paid_units >= required_units) break;
        }
        if (paid_units < required_units) {
            cancelled = bool_field(pending, "can_cancel");
            return finish();
        }
        for (std::size_t cursor = selected.size(); cursor > 0; --cursor) {
            const std::size_t index = cursor - 1;
            if (paid_units - selected[index].units >= required_units) {
                paid_units -= selected[index].units;
                selected.erase(selected.begin() + static_cast<std::ptrdiff_t>(
                    index));
            }
        }
        selected_ids.reserve(selected.size());
        for (const Candidate &candidate : selected) {
            selected_ids.emplace_back(candidate.option_id);
        }
        return finish();
    }


    std::int64_t ChallengeSearchProviderImpl::energy_units_provided_by_card(
        const ptcg::ai::Value::Array &attached,
        std::size_t index
    ) const {
        if (index >= attached.size()) return 0;
        const ptcg::ai::Value *definition = cards_.find(
            attached[index].string_or());
        if (definition == nullptr || !definition->is_object()) return 0;
        const ptcg::ai::Value *provided = definition->find("provides_energy");
        if (provided == nullptr || !provided->is_array()) return 0;
        // Downgrading a Rainbow unit to Colorless does not change how many
        // retreat units the physical Energy card provides.
        return static_cast<std::int64_t>(provided->as_array().size());
    }


} // namespace ptcg::ai::challenge_detail
