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

    bool ChallengeSearchProviderImpl::confirm_choice_response(
        const ptcg::ai::RulesSession &position,
        const ptcg::ai::Value &pending,
        const ptcg::ai::typed::ChoiceView &choice,
        ptcg::ai::Value &response
    ) const {
        if (choice.request_kind != ptcg::ai::typed::ChoiceRequestKind::confirm) {
            return false;
        }
        const std::optional<bool> confirmed = trusted_evaluator_.confirm_choice(
            position, choice.player, pending);
        if (!confirmed.has_value()) return false;
        const std::string expected = *confirmed ? "confirm:yes" : "confirm:no";
        if (std::none_of(choice.options.begin(), choice.options.end(),
            [&expected](const ptcg::ai::typed::ChoiceOption &option) {
                return option.option_id == expected;
            })) return false;
        response = ptcg::ai::Value(ptcg::ai::Value::Object{
            {"request_id", ptcg::ai::Value(choice.request_id)},
            {"option_ids", ptcg::ai::Value(ptcg::ai::Value::Array{
                ptcg::ai::Value(expected),
            })},
            {"cancelled", ptcg::ai::Value(false)},
        });
        return true;
    }


    std::string ChallengeSearchProviderImpl::resolved_option_card_id(
        const ptcg::ai::Value &option
    ) const {
        const ptcg::ai::Value *reference = option.find("ref");
        if (reference != nullptr && reference->is_object()) {
            const std::string id = string_field(*reference, "card_id");
            if (!id.empty()) return id;
        }
        const std::string option_id = string_field(option, "option_id");
        const std::size_t separator = option_id.rfind(':');
        if (separator == std::string::npos || separator + 1 >= option_id.size()) {
            return {};
        }
        const std::string candidate = option_id.substr(separator + 1);
        return cards_.find(candidate) != nullptr ? candidate : std::string{};
    }


    double ChallengeSearchProviderImpl::prize_aware_search_choice_score(
        const ptcg::ai::RulesSession &position,
        std::int32_t actor,
        const ptcg::ai::Value &pending,
        const ptcg::ai::Value &option
    ) const {
        if (!strategy_optimization_ || actor != root_actor_
            || information_set_ == nullptr
            || !information_set_->valid()
            || information_set_->perspective() != actor
            || !information_set_->has_exact_hidden_zones(actor)) {
            return 0.0;
        }
        const ptcg::ai::Value *presentation = pending.find("presentation");
        const ptcg::ai::Value *reference = option.find("ref");
        if (presentation == nullptr || !presentation->is_object()
            || string_field(*presentation, "domain") != "search"
            || string_field(*presentation, "source_zone") != "deck"
            || reference == nullptr || !reference->is_object()
            || string_field(*reference, "kind") != "card"
            || integer_field(*reference, "player", -1) != actor
            || string_field(*reference, "zone") != "deck") {
            return 0.0;
        }
        const std::string card_id = string_field(*reference, "card_id");
        if (card_id.empty()) return 0.0;
        const ptcg::ai::Value &state = position.search_state();
        const ptcg::ai::Value *players = state.find("players");
        if (players == nullptr || !players->is_array()
            || actor < 0
            || static_cast<std::size_t>(actor) >= players->as_array().size()) {
            return 0.0;
        }
        const ptcg::ai::Value &owner = players->as_array()[
            static_cast<std::size_t>(actor)];
        const auto count_zone = [&card_id](const ptcg::ai::Value *zone) {
            if (zone == nullptr || !zone->is_array()) return std::int64_t{0};
            return static_cast<std::int64_t>(std::count_if(
                zone->as_array().begin(), zone->as_array().end(),
                [&card_id](const ptcg::ai::Value &entry) {
                    return entry.string_or() == card_id;
                }));
        };
        const std::int64_t deck_copies = count_zone(owner.find("deck"));
        if (deck_copies <= 0) return 0.0;
        const std::int64_t prize_copies = static_cast<std::int64_t>(
            std::count_if(
                information_set_->known_prizes(actor).begin(),
                information_set_->known_prizes(actor).end(),
                [&card_id](const ptcg::ai::Value &entry) {
                    return entry.string_or() == card_id;
                }));

        double dead_evolution_line_penalty = 0.0;
        const ptcg::ai::Value *definition = cards_.find(card_id);
        const auto has_role = [&](const std::string &candidate_id,
                                  const char *name) {
            return strategy_catalog_.card_has_role(
                state, actor, candidate_id, name);
        };
        const bool candidate_is_attacker = has_role(
                card_id, "primary_attacker")
            || has_role(card_id, "secondary_attacker");
        if (definition != nullptr && definition->is_object()
            && string_field(*definition, "supertype") == "Pokémon"
            && !candidate_is_attacker) {
            const std::string candidate_name = string_field(
                *definition, "name");
            std::set<std::string> direct_names;
            std::set<std::string> evolution_ids;
            for (const auto &[evolution_id, evolution] : cards_.as_object()) {
                if (!evolution.is_object()
                    || string_field(evolution, "evolves_from")
                        != candidate_name) continue;
                direct_names.insert(string_field(evolution, "name"));
                if (has_role(evolution_id, "primary_attacker")
                    || has_role(evolution_id, "secondary_attacker")
                    || has_role(evolution_id, "bench_engine")
                    || has_role(evolution_id, "energy_acceleration")
                    || has_role(evolution_id, "evolution")) {
                    evolution_ids.insert(evolution_id);
                }
            }
            if (!direct_names.empty()) {
                for (const auto &[evolution_id, evolution] :
                    cards_.as_object()) {
                    if (!evolution.is_object()
                        || direct_names.count(string_field(
                            evolution, "evolves_from")) == 0) continue;
                    if (has_role(evolution_id, "primary_attacker")
                        || has_role(evolution_id, "secondary_attacker")
                        || has_role(evolution_id, "bench_engine")
                        || has_role(evolution_id, "energy_acceleration")
                        || has_role(evolution_id, "evolution")) {
                        evolution_ids.insert(evolution_id);
                    }
                }
            }
            if (!evolution_ids.empty()) {
                const auto count_ids = [&evolution_ids](
                    const ptcg::ai::Value *zone
                ) {
                    if (zone == nullptr || !zone->is_array()) {
                        return std::int64_t{0};
                    }
                    return static_cast<std::int64_t>(std::count_if(
                        zone->as_array().begin(), zone->as_array().end(),
                        [&evolution_ids](const ptcg::ai::Value &entry) {
                            return evolution_ids.count(entry.string_or()) != 0;
                        }));
                };
                const auto count_known = [&evolution_ids](
                    const std::vector<ptcg::ai::Value> &zone
                ) {
                    return static_cast<std::int64_t>(std::count_if(
                        zone.begin(), zone.end(),
                        [&evolution_ids](const ptcg::ai::Value &entry) {
                            return evolution_ids.count(entry.string_or()) != 0;
                        }));
                };
                std::int64_t accessible = count_known(
                    information_set_->known_deck(actor));
                accessible += count_ids(owner.find("hand"));
                const auto count_pokemon_id = [&](const ptcg::ai::Value *pokemon) {
                    if (pokemon != nullptr && pokemon->is_object()
                        && evolution_ids.count(string_field(
                            *pokemon, "card_id")) != 0) ++accessible;
                };
                count_pokemon_id(owner.find("active"));
                const ptcg::ai::Value *bench = owner.find("bench");
                if (bench != nullptr && bench->is_array()) {
                    for (const ptcg::ai::Value &pokemon : bench->as_array()) {
                        count_pokemon_id(&pokemon);
                    }
                }
                const std::int64_t prized = count_known(
                    information_set_->known_prizes(actor));
                const std::int64_t discarded = count_ids(owner.find("discard"));
                if (accessible == 0 && prized > 0 && discarded == 0) {
                    dead_evolution_line_penalty = -180.0;
                }
            }
        }

        double role_value = 0.0;
        const auto role = [&](const char *name) {
            return strategy_catalog_.card_has_role(
                state, actor, card_id, name);
        };
        if (role("primary_attacker")) role_value = std::max(role_value, 22.0);
        if (role("bench_engine") || role("energy_acceleration")) {
            role_value = std::max(role_value, 19.0);
        }
        if (role("setup_basic")) role_value = std::max(role_value, 15.0);
        if (role("evolution")) role_value = std::max(role_value, 14.0);
        if (role("secondary_attacker")) role_value = std::max(role_value, 11.0);
        if (role("recovery")) role_value = std::max(role_value, 8.0);
        if (role("search")) role_value = std::max(role_value, 6.0);
        if (role("energy")) role_value = std::max(role_value, 5.0);
        double scarcity_bonus = 0.0;
        if (role_value > 0.0 && prize_copies > 0) {
            double scarcity = deck_copies == 1 ? 1.0
                : (deck_copies == 2 ? 0.35 : 0.0);
            if (scarcity > 0.0) {
                scarcity += std::min(
                    0.5, static_cast<double>(prize_copies) * 0.2);

                std::int64_t visible_copies = count_zone(owner.find("hand"));
                const auto count_pokemon = [&](const ptcg::ai::Value *pokemon) {
                    if (pokemon == nullptr || !pokemon->is_object()) return;
                    if (string_field(*pokemon, "card_id") == card_id) {
                        ++visible_copies;
                    }
                    const ptcg::ai::Value *stack = pokemon->find(
                        "evolution_stack_ids");
                    visible_copies += count_zone(stack);
                };
                count_pokemon(owner.find("active"));
                const ptcg::ai::Value *bench = owner.find("bench");
                if (bench != nullptr && bench->is_array()) {
                    for (const ptcg::ai::Value &pokemon : bench->as_array()) {
                        count_pokemon(&pokemon);
                    }
                }
                if (visible_copies > 0) scarcity *= 0.35;
                scarcity_bonus = std::clamp(
                    role_value * scarcity, 0.0, 30.0);
            }
        }
        const double result = std::clamp(
            dead_evolution_line_penalty + scarcity_bonus, -180.0, 30.0);
        if (std::abs(result) > 0.000001) {
            prize_aware_choice_adjustments_.fetch_add(
                1, std::memory_order_relaxed);
        }
        return result;
    }


    bool ChallengeSearchProviderImpl::arven_choice_response(
        const ptcg::ai::RulesSession &position,
        const ptcg::ai::Value &pending,
        const ptcg::ai::typed::ChoiceView &choice,
        ptcg::ai::Value &response
    ) const {
        if (choice.request_type != "arven") return false;
        const ptcg::ai::Value *options_value = pending.find("options");
        if (options_value == nullptr || !options_value->is_array()
            || options_value->as_array().empty()) return false;
        const auto &options = options_value->as_array();
        const auto has_subtype = [this](const std::string &card_id,
                                        const std::string &subtype) {
            const ptcg::ai::Value *definition = cards_.find(card_id);
            const ptcg::ai::Value *subtypes = definition != nullptr
                && definition->is_object() ? definition->find("subtypes") : nullptr;
            return subtypes != nullptr && subtypes->is_array()
                && std::any_of(subtypes->as_array().begin(), subtypes->as_array().end(),
                    [&subtype](const ptcg::ai::Value &entry) {
                        return entry.string_or() == subtype;
                    });
        };
        std::int64_t best_item = -1;
        std::int64_t best_tool = -1;
        double best_item_score = -std::numeric_limits<double>::infinity();
        double best_tool_score = -std::numeric_limits<double>::infinity();
        for (std::size_t index = 0; index < options.size(); ++index) {
            // Arven has category limits that the generic fallback cannot infer.
            // Keep this specialized path authoritative even when the trusted
            // evaluator has no opinion about an otherwise legal card.
            const double score = trusted_evaluator_.choice_option_score(
                position, choice.player, pending, options[index]).value_or(0.0)
                + strategy_catalog_.choice_score(
                    position.search_state(), choice.player, pending, options[index])
                + prize_aware_search_choice_score(
                    position, choice.player, pending, options[index]);
            const std::string card_id = resolved_option_card_id(options[index]);
            if (has_subtype(card_id, "Item") && score > best_item_score) {
                best_item = static_cast<std::int64_t>(index);
                best_item_score = score;
            } else if (has_subtype(card_id, "Tool") && score > best_tool_score) {
                best_tool = static_cast<std::int64_t>(index);
                best_tool_score = score;
            }
        }

        const ptcg::ai::Value &state = position.search_state();
        const ptcg::ai::Value *keys = state.find("public_deck_keys");
        const std::string key = keys != nullptr && keys->is_array()
            && choice.player >= 0
            && static_cast<std::size_t>(choice.player) < keys->as_array().size()
            ? keys->as_array()[static_cast<std::size_t>(choice.player)].string_or()
            : std::string{};
        if (
            key == "psychic" && string_field(state, "phase") == "MAIN"
            && integer_field(state, "active_player_idx", -1) == choice.player
            && integer_field(state, "first_player_idx", -1) != choice.player
            && integer_field(state, "turn_number") == 2
        ) {
            const ptcg::ai::Value *players = state.find("players");
            if (players != nullptr && players->is_array()
                && choice.player >= 0
                && static_cast<std::size_t>(choice.player) < players->as_array().size()) {
                const ptcg::ai::Value &owner = players->as_array()[
                    static_cast<std::size_t>(choice.player)];
                const ptcg::ai::Value *active = owner.find("active");
                const auto &hand = owner.find("hand") != nullptr
                    && owner.find("hand")->is_array()
                    ? owner.find("hand")->as_array()
                    : ptcg::ai::Value::Array{};
                bool has_switch = std::any_of(hand.begin(), hand.end(),
                    [](const ptcg::ai::Value &entry) {
                        return entry.string_or() == "sv1-150";
                    });
                std::int64_t cresselia_index = -1;
                const ptcg::ai::Value *bench = owner.find("bench");
                if (bench != nullptr && bench->is_array()) {
                    for (std::size_t index = 0; index < bench->as_array().size(); ++index) {
                        if (bench->as_array()[index].is_object()
                            && string_field(bench->as_array()[index], "card_id")
                                == "sv1-113") {
                            cresselia_index = static_cast<std::int64_t>(index);
                            break;
                        }
                    }
                }
                bool can_pay = false;
                if (cresselia_index >= 0 && bench != nullptr) {
                    const ptcg::ai::Value &cresselia = bench->as_array()[
                        static_cast<std::size_t>(cresselia_index)];
                    const ptcg::ai::Value *energy = cresselia.find("energy_card_ids");
                    can_pay = energy != nullptr && energy->is_array()
                        && std::any_of(energy->as_array().begin(), energy->as_array().end(),
                            [](const ptcg::ai::Value &entry) {
                                return entry.string_or() == "sv1-ener-5";
                            });
                    can_pay = can_pay || (!bool_field(owner,
                        "energy_attached_this_turn")
                        && std::any_of(hand.begin(), hand.end(),
                            [](const ptcg::ai::Value &entry) {
                                return entry.string_or() == "sv1-ener-5";
                            }));
                }
                bool direct_retreat = false;
                if (cresselia_index >= 0) {
                    const ptcg::ai::Value &actions =
                        position.search_legal_action_candidates(choice.player);
                    if (actions.is_array()) {
                        for (const ptcg::ai::Value &action : actions.as_array()) {
                            const ptcg::ai::Value *target = action.find("target");
                            if (string_field(action, "kind") == "RETREAT"
                                && target != nullptr && target->is_object()
                                && string_field(*target, "slot")
                                    == "bench_" + std::to_string(cresselia_index)) {
                                direct_retreat = true;
                                break;
                            }
                        }
                    }
                }
                if (active != nullptr && active->is_object()
                    && string_field(*active, "card_id") != "sv1-113"
                    && !has_switch && cresselia_index >= 0 && can_pay
                    && !direct_retreat) {
                    for (std::size_t index = 0; index < options.size(); ++index) {
                        if (resolved_option_card_id(options[index]) == "sv1-150") {
                            best_item = static_cast<std::int64_t>(index);
                            break;
                        }
                    }
                }
            }
        }

        ptcg::ai::Value::Array selected;
        if (best_item >= 0) selected.emplace_back(string_field(
            options[static_cast<std::size_t>(best_item)], "option_id"));
        if (best_tool >= 0
            && selected.size() < static_cast<std::size_t>(
                std::max<std::int64_t>(0, choice.max_select))) {
            selected.emplace_back(string_field(
                options[static_cast<std::size_t>(best_tool)], "option_id"));
        }
        if (selected.empty() && choice.min_select > 0) {
            std::size_t fallback = 0;
            double fallback_score = trusted_evaluator_.choice_option_score(
                position, choice.player, pending, options[0]).value_or(0.0);
            for (std::size_t index = 1; index < options.size(); ++index) {
                const double score = trusted_evaluator_.choice_option_score(
                    position, choice.player, pending, options[index]).value_or(0.0);
                if (score > fallback_score) {
                    fallback = index;
                    fallback_score = score;
                }
            }
            selected.emplace_back(string_field(options[fallback], "option_id"));
        }
        response = ptcg::ai::Value(ptcg::ai::Value::Object{
            {"request_id", ptcg::ai::Value(choice.request_id)},
            {"option_ids", ptcg::ai::Value(std::move(selected))},
            {"cancelled", ptcg::ai::Value(false)},
        });
        return true;
    }


    bool ChallengeSearchProviderImpl::sequential_discard_response(
        const ptcg::ai::RulesSession &position,
        const ptcg::ai::Value &pending,
        const ptcg::ai::typed::ChoiceView &choice,
        ptcg::ai::Value &response
    ) const {
        const ptcg::ai::Value *options_value = pending.find("options");
        if (options_value == nullptr || !options_value->is_array()) return false;
        const auto &options = options_value->as_array();
        const std::size_t maximum = static_cast<std::size_t>(
            std::max<std::int64_t>(0, std::min<std::int64_t>(
                choice.max_select, static_cast<std::int64_t>(options.size()))));
        if (maximum <= 1 || choice.allow_duplicates) return false;
        ptcg::ai::Value virtual_state = position.snapshot();
        virtual_state["apply_type_matchups"] = ptcg::ai::Value(false);
        std::vector<std::size_t> selected_indices;
        ptcg::ai::Value::Array selected_ids;
        selected_indices.reserve(maximum);
        selected_ids.reserve(maximum);
        const auto is_hand_card = [](const ptcg::ai::Value &option) {
            const ptcg::ai::Value *reference = option.find("ref");
            if (reference != nullptr && reference->is_object()) {
                if (reference->find("zone") != nullptr) {
                    return string_field(*reference, "zone") == "hand";
                }
                if (string_field(*reference, "kind") == "attachment") return false;
            }
            return true;
        };
        const auto approximately_equal = [](double left, double right) {
            const double tolerance = 0.00001
                * std::max(1.0, std::max(std::abs(left), std::abs(right)));
            return std::abs(left - right) <= tolerance;
        };
        for (std::size_t selection_index = 0;
            selection_index < maximum; ++selection_index) {
            std::unique_ptr<ptcg::ai::RulesSession> virtual_position =
                position.fork_for_search(position.rng_state());
            std::string restore_error;
            if (!virtual_position || !virtual_position->restore(
                virtual_state, position.rng_state(), &restore_error)) return false;
            std::int64_t best_index = -1;
            double best_score = -std::numeric_limits<double>::infinity();
            std::string best_tiebreak;
            for (std::size_t option_index = 0;
                option_index < options.size(); ++option_index) {
                if (std::find(selected_indices.begin(), selected_indices.end(),
                    option_index) != selected_indices.end()) continue;
                const ptcg::ai::Value &option = options[option_index];
                const std::optional<double> base =
                    trusted_evaluator_.choice_option_score(
                        *virtual_position, choice.player, pending, option);
                if (!base.has_value()) return false;
                const double score = *base + strategy_catalog_.choice_score(
                    virtual_state, choice.player, pending, option);
                const std::string card_id = resolved_option_card_id(option);
                const std::string tiebreak = card_id + "|"
                    + string_field(option, "option_id");
                if (
                    best_index < 0 || score > best_score + 0.001
                    || (approximately_equal(score, best_score)
                        && tiebreak < best_tiebreak)
                ) {
                    best_index = static_cast<std::int64_t>(option_index);
                    best_score = score;
                    best_tiebreak = tiebreak;
                }
            }
            if (best_index < 0) return false;
            if (selection_index >= static_cast<std::size_t>(
                std::max<std::int64_t>(0, choice.min_select))
                && best_score <= 0.0) break;
            const std::size_t chosen = static_cast<std::size_t>(best_index);
            const ptcg::ai::Value &option = options[chosen];
            const std::string option_id = string_field(option, "option_id");
            if (option_id.empty()) return false;
            selected_indices.push_back(chosen);
            selected_ids.emplace_back(option_id);
            if (is_hand_card(option)) {
                const std::string card_id = resolved_option_card_id(option);
                ptcg::ai::Value *players = virtual_state.find("players");
                if (players == nullptr || !players->is_array()
                    || choice.player < 0
                    || static_cast<std::size_t>(choice.player)
                        >= players->as_array().size()) return false;
                ptcg::ai::Value &owner = players->as_array()[
                    static_cast<std::size_t>(choice.player)];
                ptcg::ai::Value *hand = owner.find("hand");
                if (hand != nullptr && hand->is_array()) {
                    auto &cards = hand->as_array();
                    const auto found = std::find_if(
                        cards.begin(), cards.end(), [&card_id](const ptcg::ai::Value &entry) {
                            return entry.string_or() == card_id;
                        });
                    if (found != cards.end()) cards.erase(found);
                }
            }
        }
        if (selected_ids.size() < static_cast<std::size_t>(
            std::max<std::int64_t>(0, choice.min_select))) return false;
        response = ptcg::ai::Value(ptcg::ai::Value::Object{
            {"request_id", ptcg::ai::Value(choice.request_id)},
            {"option_ids", ptcg::ai::Value(std::move(selected_ids))},
            {"cancelled", ptcg::ai::Value(false)},
        });
        return true;
    }


    bool ChallengeSearchProviderImpl::single_choice_response(
        const ptcg::ai::RulesSession &position,
        const ptcg::ai::Value &pending,
        const ptcg::ai::typed::ChoiceView &choice,
        ptcg::ai::Value &response
    ) const {
        using Kind = ptcg::ai::typed::ChoiceRequestKind;
        if (
            choice.options.empty() || choice.allow_duplicates
            || choice.request_kind == Kind::confirm
            || choice.request_kind == Kind::confirm_trigger
            || choice.request_kind == Kind::choose_turn_order
            || choice.request_kind == Kind::choose_mulligan_draw_count
            || choice.request_kind == Kind::select_prize
            || choice.request_kind == Kind::select_retreat_payment
            || choice.request_type == "arven"
        ) return false;
        const ptcg::ai::Value *options_value = pending.find("options");
        if (options_value == nullptr || !options_value->is_array()
            || options_value->as_array().size() != choice.options.size()) {
            return false;
        }
        const ptcg::ai::Value *presentation_probe = pending.find("presentation");
        static const ptcg::ai::Value empty_presentation =
            ptcg::ai::Value::make_object();
        const ptcg::ai::Value &presentation_for_mode =
            presentation_probe != nullptr && presentation_probe->is_object()
            ? *presentation_probe : empty_presentation;
        const std::string request_type = string_field(pending, "request_type");
        const std::string purpose = string_field(
            presentation_for_mode, "purpose");
        const bool attachment_discard = request_type == "select_attachment"
            && purpose != "discard_energy"
            && purpose != "discard_energy_attachments"
            && purpose.rfind("energy_relocate", 0) != 0
            && purpose.rfind("relocate_energy", 0) != 0;
        const bool discard_purpose = purpose == "discard_then_draw"
            || purpose == "discard_hand_then_draw"
            || purpose == "discard_cards" || purpose == "hand_bottom_draw"
            || purpose == "houb" || purpose == "zinnia"
            || purpose == "discard" || purpose == "discard_cost"
            || purpose == "bottom_deck";
        if (choice.max_select > 1 && (attachment_discard || discard_purpose)) {
            return sequential_discard_response(
                position, pending, choice, response);
        }
        const std::int32_t actor = choice.player;
        struct ScoredOption {
            std::size_t index = 0;
            double score = 0.0;
        };
        std::vector<ScoredOption> ranked;
        ranked.reserve(choice.options.size());
        for (std::size_t index = 0; index < choice.options.size(); ++index) {
            const ptcg::ai::Value &option = options_value->as_array()[index];
            const std::optional<double> base = trusted_evaluator_.choice_option_score(
                position, actor, pending, option);
            if (!base.has_value()) return false;
            ranked.push_back({
                index,
                *base + strategy_catalog_.choice_score(
                    position.search_state(), actor, pending, option)
                    + prize_aware_search_choice_score(
                        position, actor, pending, option),
            });
        }
        const auto approximately_equal = [](double left, double right) {
            const double tolerance = 0.00001
                * std::max(1.0, std::max(std::abs(left), std::abs(right)));
            return std::abs(left - right) <= tolerance;
        };
        std::stable_sort(ranked.begin(), ranked.end(),
            [&approximately_equal](const ScoredOption &left,
                                    const ScoredOption &right) {
                if (approximately_equal(left.score, right.score)) {
                    return left.index < right.index;
                }
                return left.score > right.score;
            });

        const ptcg::ai::Value *presentation_value = pending.find("presentation");
        static const ptcg::ai::Value empty = ptcg::ai::Value::make_object();
        const ptcg::ai::Value &presentation = presentation_value != nullptr
            && presentation_value->is_object() ? *presentation_value : empty;
        const std::int64_t max_per_target = std::max<std::int64_t>(
            0, integer_field(presentation, "max_per_target", 2147483647));
        const ptcg::ai::Value *category_limits = presentation.find(
            "category_limits");
        const auto category_for = [this](const ptcg::ai::Value &option) {
            const ptcg::ai::Value *reference = option.find("ref");
            const std::string card_id = reference != nullptr
                && reference->is_object()
                ? string_field(*reference, "card_id") : std::string{};
            if (card_id.empty()) return std::string{};
            const ptcg::ai::Value *definition = cards_.find(card_id);
            if (definition == nullptr || !definition->is_object()) return std::string{};
            const std::string supertype = string_field(*definition, "supertype");
            const ptcg::ai::Value *subtypes = definition->find("subtypes");
            const auto has_subtype = [&subtypes](const std::string &needle) {
                if (subtypes == nullptr || !subtypes->is_array()) return false;
                return std::any_of(
                    subtypes->as_array().begin(), subtypes->as_array().end(),
                    [&needle](const ptcg::ai::Value &entry) {
                        return entry.string_or() == needle;
                    });
            };
            if (supertype == "Pokémon") return std::string("pokemon");
            if (supertype == "Energy") return std::string("energy");
            if (supertype == "Trainer" && has_subtype("Item")) {
                return std::string("item");
            }
            if (supertype == "Trainer" && has_subtype("Tool")) {
                return std::string("tool");
            }
            if (supertype == "Trainer") return std::string("trainer");
            return std::string{};
        };
        const auto category_limit = [&](const std::string &category) {
            if (category.empty()) return std::int64_t{2147483647};
            if (category_limits != nullptr && category_limits->is_object()) {
                const ptcg::ai::Value *explicit_limit = category_limits->find(category);
                if (explicit_limit != nullptr) {
                    return std::max<std::int64_t>(0, explicit_limit->as_integer());
                }
            }
            const ptcg::ai::Value *count_field = presentation.find(
                category + "_count");
            return count_field != nullptr && count_field->is_integer()
                ? std::max<std::int64_t>(0, count_field->as_integer())
                : std::int64_t{2147483647};
        };

        const bool same_target = bool_field(presentation, "same_target");
        const auto target_key_for = [](const ptcg::ai::Value &option) {
            const ptcg::ai::Value *reference = option.find("ref");
            if (reference != nullptr && reference->is_object()) {
                const std::string slot = string_field(*reference, "slot");
                if (!slot.empty()) {
                    return std::to_string(integer_field(*reference, "player", -1))
                        + ":" + slot;
                }
            }
            return "option:" + string_field(option, "option_id");
        };
        const std::size_t maximum = static_cast<std::size_t>(
            std::max<std::int64_t>(0, std::min<std::int64_t>(
                choice.max_select,
                static_cast<std::int64_t>(choice.options.size()))));
        std::size_t desired_count = maximum;
        if (choice.min_select <= 0) {
            desired_count = std::min(maximum, static_cast<std::size_t>(
                std::count_if(ranked.begin(), ranked.end(),
                    [](const ScoredOption &row) { return row.score > 0.0; })));
        }
        ptcg::ai::Value::Array selected_ids;
        std::map<std::string, std::int64_t> per_target;
        std::map<std::string, std::int64_t> per_category;
        std::set<std::string> used_option_ids;
        std::string selected_target;
        if (desired_count > 0 && max_per_target > 0) {
            std::size_t optional_candidates_seen = 0;
            for (const ScoredOption &row : ranked) {
                if (choice.min_select <= 0) {
                    if (row.score <= 0.0 || optional_candidates_seen >= maximum) {
                        break;
                    }
                    ++optional_candidates_seen;
                }
                const ptcg::ai::Value &option = options_value->as_array()[row.index];
                const std::string option_id = string_field(option, "option_id");
                if (option_id.empty() || used_option_ids.count(option_id)) continue;
                const std::string target_key = target_key_for(option);
                if (same_target && !selected_target.empty()
                    && target_key != selected_target) continue;
                if (per_target[target_key] >= max_per_target) continue;
                const std::string category = category_for(option);
                if (per_category[category] >= category_limit(category)) continue;
                selected_ids.emplace_back(option_id);
                used_option_ids.insert(option_id);
                if (selected_target.empty()) selected_target = target_key;
                ++per_target[target_key];
                if (!category.empty()) ++per_category[category];
                if (selected_ids.size() >= desired_count) break;
            }
        }
        const bool cancelled = selected_ids.empty()
            && choice.min_select <= 0 && choice.can_cancel;
        response = ptcg::ai::Value(ptcg::ai::Value::Object{
            {"request_id", ptcg::ai::Value(choice.request_id)},
            {"option_ids", ptcg::ai::Value(std::move(selected_ids))},
            {"cancelled", ptcg::ai::Value(cancelled)},
        });
        return choice.min_select <= 0 || !response.find("option_ids")
            ->as_array().empty();
    }


} // namespace ptcg::ai::challenge_detail
