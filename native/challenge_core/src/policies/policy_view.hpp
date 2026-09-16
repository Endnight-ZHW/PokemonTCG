#pragma once
#include "deck_policy.hpp"
#include "ptcg_traditional_card.hpp"
#include "ptcg_traditional_value.hpp"
#include <algorithm>
#include <cmath>
#include <set>
#include <vector>

namespace ptcg::ai::policy {
using namespace traditional_value;
using traditional_card::card;
using traditional_card::is_pokemon;
using traditional_card::is_trainer;
std::string action_card_id(const Value &action);
std::string action_target_card_id(const Value &action);
struct PolicyView {
    const Value &state;
    const Value &profile;
    const Value &archetypes;
    const Value &cards;
    std::int32_t actor;
    const Value *current_action = nullptr;
    const DeckPolicy *policy = nullptr;

    const Value &player(std::int32_t index) const {
        static const Value empty = Value::make_object();
        const Value *players = field(state, "players");
        return players != nullptr && players->is_array() && index >= 0 &&
                       static_cast<std::size_t>(index) < players->as_array().size()
                   ? players->as_array()[static_cast<std::size_t>(index)]
                   : empty;
    }

    const Value &own() const { return player(actor); }
    const Value &opponent() const { return player(1 - actor); }

    const Value::Array &array(const Value &object, const char *key) const {
        static const Value::Array empty;
        const Value *value = field(object, key);
        return value != nullptr && value->is_array() ? value->as_array() : empty;
    }

    const Value::Array &hand() const { return array(own(), "hand"); }
    const Value::Array &discard() const { return array(own(), "discard"); }

    std::vector<const Value *> board(std::int32_t index) const {
        std::vector<const Value *> result;
        const Value &owner = player(index);
        const Value *active = field(owner, "active");
        if (active != nullptr && active->is_object())
            result.push_back(active);
        const Value *bench = field(owner, "bench");
        if (bench != nullptr && bench->is_array()) {
            for (const Value &pokemon : bench->as_array()) {
                if (pokemon.is_object() && !string_field(pokemon, "card_id").empty()) {
                    result.push_back(&pokemon);
                }
            }
        }
        return result;
    }

    std::vector<const Value *> own_board() const { return board(actor); }
    std::vector<const Value *> opponent_board() const { return board(1 - actor); }

    const Value *active(std::int32_t index) const {
        const Value *value = field(player(index), "active");
        return value != nullptr && value->is_object() ? value : nullptr;
    }

    std::string deck_key() const {
        const Value *keys = field(state, "public_deck_keys");
        return keys != nullptr && keys->is_array() &&
                       static_cast<std::size_t>(actor) < keys->as_array().size()
                   ? keys->as_array()[static_cast<std::size_t>(actor)].string_or()
                   : std::string{};
    }

    std::string opponent_deck_key() const {
        const Value *keys = field(state, "public_deck_keys");
        return keys != nullptr && keys->is_array() &&
                       static_cast<std::size_t>(1 - actor) < keys->as_array().size()
                   ? keys->as_array()[static_cast<std::size_t>(1 - actor)].string_or()
                   : std::string{};
    }

    std::int64_t turn() const { return integer_field(state, "turn_number"); }
    std::int64_t own_prizes() const {
        return static_cast<std::int64_t>(array(own(), "prizes").size());
    }
    std::int64_t opponent_prizes() const {
        return static_cast<std::int64_t>(array(opponent(), "prizes").size());
    }
    bool going_second() const {
        const std::int64_t first = integer_field(state, "first_player_idx", -1);
        return first < 0 || first > 1 || first != actor;
    }

    const Value *roles() const {
        const Value *value = field(profile, "card_roles");
        return value != nullptr && value->is_object() ? value : nullptr;
    }

    bool has_role(const std::string &card_id, const std::string &role) const {
        if (card_id.empty())
            return false;
        const Value *role_map = roles();
        return role_map != nullptr && array_contains(field(*role_map, role), card_id);
    }

    double weight(const std::string &name, double fallback = 0.0) const {
        const Value *weights = field(profile, "weights");
        return weights != nullptr && weights->is_object() ? number_field(*weights, name, fallback)
                                                          : fallback;
    }

    std::int64_t count_card_board(const std::string &card_id) const {
        std::int64_t count = 0;
        for (const Value *pokemon : own_board()) {
            if (string_field(*pokemon, "card_id") == card_id)
                ++count;
        }
        return count;
    }

    std::int64_t count_role_board(const std::string &role) const {
        std::int64_t count = 0;
        for (const Value *pokemon : own_board()) {
            if (has_role(string_field(*pokemon, "card_id"), role))
                ++count;
        }
        return count;
    }

    std::int64_t count_card_hand(const std::string &card_id) const {
        return static_cast<std::int64_t>(
            std::count_if(hand().begin(), hand().end(),
                          [&card_id](const Value &entry) { return entry.string_or() == card_id; }));
    }

    std::int64_t count_role_hand(const std::string &role) const {
        std::int64_t count = 0;
        for (const Value &card : hand())
            if (has_role(card.string_or(), role))
                ++count;
        return count;
    }

    std::int64_t count_card_discard(const std::string &card_id) const {
        return static_cast<std::int64_t>(
            std::count_if(discard().begin(), discard().end(),
                          [&card_id](const Value &entry) { return entry.string_or() == card_id; }));
    }

    std::int64_t count_role_discard(const std::string &role) const {
        std::int64_t count = 0;
        for (const Value &card : discard())
            if (has_role(card.string_or(), role))
                ++count;
        return count;
    }

    const Value::Array &energy_ids(const Value *pokemon) const {
        static const Value::Array empty;
        const Value *value = pokemon == nullptr ? nullptr : field(*pokemon, "energy_card_ids");
        return value != nullptr && value->is_array() ? value->as_array() : empty;
    }

    std::int64_t energy_count(const std::string &card_id) const {
        std::int64_t result = 0;
        for (const Value *pokemon : own_board()) {
            if (string_field(*pokemon, "card_id") == card_id) {
                result = std::max(result, static_cast<std::int64_t>(energy_ids(pokemon).size()));
            }
        }
        return result;
    }

    std::int64_t energy_id_count(const std::string &card_id, const std::string &energy_id) const {
        std::int64_t result = 0;
        for (const Value *pokemon : own_board()) {
            if (string_field(*pokemon, "card_id") != card_id)
                continue;
            result = std::max(result, static_cast<std::int64_t>(std::count_if(
                                          energy_ids(pokemon).begin(), energy_ids(pokemon).end(),
                                          [&energy_id](const Value &entry) {
                                              return entry.string_or() == energy_id;
                                          })));
        }
        return result;
    }

    static std::int64_t damage(const Value *pokemon) {
        return pokemon == nullptr ? 0 : integer_field(*pokemon, "damage_counters") * 10;
    }

    std::int64_t damage_on_card(const std::string &card_id) const {
        std::int64_t result = 0;
        for (const Value *pokemon : own_board()) {
            if (string_field(*pokemon, "card_id") == card_id) {
                result = std::max(result, damage(pokemon));
            }
        }
        return result;
    }

    std::int64_t own_damage_total() const {
        std::int64_t result = 0;
        for (const Value *pokemon : own_board())
            result += damage(pokemon);
        return result;
    }

    std::int64_t opponent_active_damage() const { return damage(active(1 - actor)); }

    bool card_active(const std::string &card_id) const {
        const Value *pokemon = active(actor);
        return pokemon != nullptr && string_field(*pokemon, "card_id") == card_id;
    }

    bool card_benched(const std::string &card_id) const {
        const Value *bench = field(own(), "bench");
        if (bench == nullptr || !bench->is_array())
            return false;
        return std::any_of(
            bench->as_array().begin(), bench->as_array().end(), [&card_id](const Value &pokemon) {
                return pokemon.is_object() && string_field(pokemon, "card_id") == card_id;
            });
    }

    std::int64_t bench_count() const {
        const Value *bench = field(own(), "bench");
        if (bench == nullptr || !bench->is_array())
            return 0;
        return static_cast<std::int64_t>(std::count_if(
            bench->as_array().begin(), bench->as_array().end(), [](const Value &pokemon) {
                return pokemon.is_object() && !string_field(pokemon, "card_id").empty();
            }));
    }

    bool own_bench_damaged() const {
        const Value *bench = field(own(), "bench");
        return bench != nullptr && bench->is_array() &&
               std::any_of(bench->as_array().begin(), bench->as_array().end(),
                           [](const Value &pokemon) {
                               return pokemon.is_object() && damage(&pokemon) > 0;
                           });
    }

    bool card_healed(const std::string &card_id) const {
        for (const Value *pokemon : own_board()) {
            if (string_field(*pokemon, "card_id") == card_id &&
                bool_field(*pokemon, "healed_this_turn"))
                return true;
        }
        return false;
    }

    bool own_knockout_last_turn() const {
        const Value *book = field(state, "turn_fact_book");
        const Value *previous = book == nullptr ? nullptr : field(*book, "previous_turn");
        const Value *facts = previous == nullptr ? nullptr : field(*previous, "knockouts");
        return facts != nullptr && facts->is_array() &&
               std::any_of(facts->as_array().begin(), facts->as_array().end(),
                           [this](const Value &fact) {
                               return integer_field(fact, "defeated_player", -1) == actor;
                           });
    }

    const Value *card(const std::string &card_id) const {
        const Value *value = cards.find(card_id);
        return value != nullptr && value->is_object() ? value : nullptr;
    }

    std::int64_t card_hp(const std::string &card_id) const {
        const Value *definition = card(card_id);
        return definition == nullptr ? 0 : integer_field(*definition, "hp");
    }

    std::int64_t opponent_engine_count_for_action_semantics() const {
        // AIPositionEvaluator supplies action_score() with the deliberately
        // narrow semantic_context_for_action(): only source/target card IDs
        // are published.  Preserve that boundary instead of consulting the
        // full immutable catalog for every visible opposing Pokemon.
        if (current_action == nullptr)
            return 0;
        const std::string source_id = action_card_id(*current_action);
        const std::string target_id = action_target_card_id(*current_action);
        std::int64_t result = 0;
        for (const Value *pokemon : opponent_board()) {
            const std::string card_id = string_field(*pokemon, "card_id");
            if (card_id != source_id && card_id != target_id)
                continue;
            const Value *definition = card(card_id);
            const Value *abilities =
                definition == nullptr ? nullptr : field(*definition, "abilities");
            if (abilities != nullptr && abilities->is_array() && !abilities->as_array().empty())
                ++result;
        }
        return result;
    }

    const Value *row_for_slot(const std::string &slot) const {
        if (slot == "active")
            return active(actor);
        if (slot.rfind("bench_", 0) != 0)
            return nullptr;
        try {
            const std::size_t index = static_cast<std::size_t>(std::stoll(slot.substr(6)));
            const Value *bench = field(own(), "bench");
            return bench != nullptr && bench->is_array() && index < bench->as_array().size() &&
                           bench->as_array()[index].is_object()
                       ? &bench->as_array()[index]
                       : nullptr;
        } catch (...) {
            return nullptr;
        }
    }
};

std::string action_kind(const Value &action);
const Value &action_payload(const Value &action);
std::string action_card_id(const Value &action);
std::string action_target_card_id(const Value &action);
std::string action_target_slot(const Value &action);
std::string action_source_slot(const Value &action);
std::int64_t attack_index(const Value &action);
std::string generic_plan_stage(const PolicyView &view);
const Value *stage_goal(const PolicyView &view, const std::string &stage);
std::int64_t role_progress(const PolicyView &view, const std::string &role);
bool action_advances_role(const PolicyView &view, const Value &action, const std::string &role);
double stage_action_score(const PolicyView &view, const Value &action);
double stage_state_score(const PolicyView &view);
double generic_state_adjustment(const PolicyView &view);
double generic_action_adjustment(const PolicyView &view, const Value &action);
bool has_any_in_hand(const PolicyView &view, const std::vector<std::string> &ids);
const Value &choice_presentation(const Value &choice);
std::string choice_purpose(const Value &choice);
std::string choice_surface(const Value &choice);
std::string option_card_id(const Value &option);
std::string choice_mode(const PolicyView &view, const Value &choice);
std::int64_t remaining_hand_count_for_choice(const PolicyView &view, const Value &choice,
                                             const Value &option, const std::string &card_id);
bool choice_offers_card(const Value &choice, const std::string &card_id);
double generic_choice_keep_value(const PolicyView &view, const Value &choice, const Value &option);
double matchup_adjustment(const PolicyView &view, const Value &action);
double candidate_score(const PolicyView &view, const Value &action);
std::string plan_stage(const PolicyView &view);
double evaluate_position(const DeckPolicy &policy, const PolicyView &view,
                         const PositionFeatures &facts, double development_weight);
} // namespace ptcg::ai::policy
