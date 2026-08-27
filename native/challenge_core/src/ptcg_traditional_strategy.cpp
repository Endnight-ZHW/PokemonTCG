#include "ptcg_traditional_strategy.hpp"
#include "ptcg_traditional_value.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <string_view>
#include <vector>

namespace ptcg::ai {

namespace {

using traditional_value::array_contains;
using traditional_value::bool_field;
using traditional_value::field;
using traditional_value::integer_field;
using traditional_value::lower_ascii;
using traditional_value::number_field;
using traditional_value::string_field;

std::string action_card_id(const Value &action);
std::string action_target_card_id(const Value &action);

struct StrategyView {
    const Value &state;
    const Value &profile;
    const Value &archetypes;
    const Value &cards;
    std::int32_t actor;
    const Value *current_action = nullptr;

    const Value &player(std::int32_t index) const {
        static const Value empty = Value::make_object();
        const Value *players = field(state, "players");
        return players != nullptr && players->is_array()
            && index >= 0
            && static_cast<std::size_t>(index) < players->as_array().size()
            ? players->as_array()[static_cast<std::size_t>(index)] : empty;
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
        if (active != nullptr && active->is_object()) result.push_back(active);
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
        return keys != nullptr && keys->is_array()
            && static_cast<std::size_t>(actor) < keys->as_array().size()
            ? keys->as_array()[static_cast<std::size_t>(actor)].string_or() : std::string{};
    }

    std::string opponent_deck_key() const {
        const Value *keys = field(state, "public_deck_keys");
        return keys != nullptr && keys->is_array()
            && static_cast<std::size_t>(1 - actor) < keys->as_array().size()
            ? keys->as_array()[static_cast<std::size_t>(1 - actor)].string_or() : std::string{};
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
        if (card_id.empty()) return false;
        const Value *role_map = roles();
        return role_map != nullptr && array_contains(field(*role_map, role), card_id);
    }

    double weight(const std::string &name, double fallback = 0.0) const {
        const Value *weights = field(profile, "weights");
        return weights != nullptr && weights->is_object()
            ? number_field(*weights, name, fallback) : fallback;
    }

    std::int64_t count_card_board(const std::string &card_id) const {
        std::int64_t count = 0;
        for (const Value *pokemon : own_board()) {
            if (string_field(*pokemon, "card_id") == card_id) ++count;
        }
        return count;
    }

    std::int64_t count_role_board(const std::string &role) const {
        std::int64_t count = 0;
        for (const Value *pokemon : own_board()) {
            if (has_role(string_field(*pokemon, "card_id"), role)) ++count;
        }
        return count;
    }

    std::int64_t count_card_hand(const std::string &card_id) const {
        return static_cast<std::int64_t>(std::count_if(
            hand().begin(), hand().end(), [&card_id](const Value &entry) {
                return entry.string_or() == card_id;
            }));
    }

    std::int64_t count_role_hand(const std::string &role) const {
        std::int64_t count = 0;
        for (const Value &card : hand()) if (has_role(card.string_or(), role)) ++count;
        return count;
    }

    std::int64_t count_card_discard(const std::string &card_id) const {
        return static_cast<std::int64_t>(std::count_if(
            discard().begin(), discard().end(), [&card_id](const Value &entry) {
                return entry.string_or() == card_id;
            }));
    }

    std::int64_t count_role_discard(const std::string &role) const {
        std::int64_t count = 0;
        for (const Value &card : discard()) if (has_role(card.string_or(), role)) ++count;
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

    std::int64_t energy_id_count(
        const std::string &card_id,
        const std::string &energy_id
    ) const {
        std::int64_t result = 0;
        for (const Value *pokemon : own_board()) {
            if (string_field(*pokemon, "card_id") != card_id) continue;
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
        for (const Value *pokemon : own_board()) result += damage(pokemon);
        return result;
    }

    std::int64_t opponent_active_damage() const { return damage(active(1 - actor)); }

    bool card_active(const std::string &card_id) const {
        const Value *pokemon = active(actor);
        return pokemon != nullptr && string_field(*pokemon, "card_id") == card_id;
    }

    bool card_benched(const std::string &card_id) const {
        const Value *bench = field(own(), "bench");
        if (bench == nullptr || !bench->is_array()) return false;
        return std::any_of(bench->as_array().begin(), bench->as_array().end(),
            [&card_id](const Value &pokemon) {
                return pokemon.is_object() && string_field(pokemon, "card_id") == card_id;
            });
    }

    std::int64_t bench_count() const {
        const Value *bench = field(own(), "bench");
        if (bench == nullptr || !bench->is_array()) return 0;
        return static_cast<std::int64_t>(std::count_if(
            bench->as_array().begin(), bench->as_array().end(),
            [](const Value &pokemon) {
                return pokemon.is_object() && !string_field(pokemon, "card_id").empty();
            }));
    }

    bool own_bench_damaged() const {
        const Value *bench = field(own(), "bench");
        return bench != nullptr && bench->is_array()
            && std::any_of(bench->as_array().begin(), bench->as_array().end(),
                [](const Value &pokemon) {
                    return pokemon.is_object() && damage(&pokemon) > 0;
                });
    }

    bool card_healed(const std::string &card_id) const {
        for (const Value *pokemon : own_board()) {
            if (string_field(*pokemon, "card_id") == card_id
                && bool_field(*pokemon, "healed_this_turn")) return true;
        }
        return false;
    }

    bool own_knockout_last_turn() const {
        const Value *book = field(state, "turn_fact_book");
        const Value *previous = book == nullptr ? nullptr : field(*book, "previous_turn");
        const Value *facts = previous == nullptr ? nullptr : field(*previous, "knockouts");
        return facts != nullptr && facts->is_array()
            && std::any_of(facts->as_array().begin(), facts->as_array().end(),
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
        if (current_action == nullptr) return 0;
        const std::string source_id = action_card_id(*current_action);
        const std::string target_id = action_target_card_id(*current_action);
        std::int64_t result = 0;
        for (const Value *pokemon : opponent_board()) {
            const std::string card_id = string_field(*pokemon, "card_id");
            if (card_id != source_id && card_id != target_id) continue;
            const Value *definition = card(card_id);
            const Value *abilities = definition == nullptr ? nullptr : field(*definition, "abilities");
            if (abilities != nullptr && abilities->is_array()
                && !abilities->as_array().empty()) ++result;
        }
        return result;
    }

    const Value *row_for_slot(const std::string &slot) const {
        if (slot == "active") return active(actor);
        if (slot.rfind("bench_", 0) != 0) return nullptr;
        try {
            const std::size_t index = static_cast<std::size_t>(std::stoll(slot.substr(6)));
            const Value *bench = field(own(), "bench");
            return bench != nullptr && bench->is_array() && index < bench->as_array().size()
                && bench->as_array()[index].is_object() ? &bench->as_array()[index] : nullptr;
        } catch (...) { return nullptr; }
    }
};

std::string action_kind(const Value &action) { return string_field(action, "kind"); }

const Value &action_payload(const Value &action) {
    static const Value empty = Value::make_object();
    const Value *payload = field(action, "payload");
    return payload != nullptr && payload->is_object() ? *payload : empty;
}

std::string action_card_id(const Value &action) {
    const Value *source = field(action, "source");
    if (source != nullptr && source->is_object()) {
        const std::string card_id = string_field(*source, "card_id");
        if (!card_id.empty()) return card_id;
    }
    const Value &payload = action_payload(action);
    for (const char *key : {"card_id", "source_card_id", "hand_card_id"}) {
        const std::string card_id = string_field(payload, key);
        if (!card_id.empty()) return card_id;
    }
    return {};
}

std::string action_target_card_id(const Value &action) {
    const Value *target = field(action, "target");
    if (target != nullptr && target->is_object()) {
        const std::string card_id = string_field(*target, "card_id");
        if (!card_id.empty()) return card_id;
    }
    const Value &payload = action_payload(action);
    for (const char *key : {"target_card_id", "pokemon_card_id"}) {
        const std::string card_id = string_field(payload, key);
        if (!card_id.empty()) return card_id;
    }
    return {};
}

std::string action_target_slot(const Value &action) {
    const Value *target = field(action, "target");
    if (target != nullptr && target->is_object()) {
        const std::string slot = string_field(*target, "slot");
        if (!slot.empty()) return slot;
    }
    const Value &payload = action_payload(action);
    return string_field(payload, "target_slot", string_field(payload, "slot"));
}

std::string action_source_slot(const Value &action) {
    const Value *source = field(action, "source");
    if (source != nullptr && source->is_object()) {
        const std::string slot = string_field(*source, "slot");
        if (!slot.empty()) return slot;
    }
    const Value &payload = action_payload(action);
    const std::string slot = string_field(
        payload, "source_slot", string_field(payload, "slot"));
    return slot.empty() ? action_target_slot(action) : slot;
}

std::int64_t attack_index(const Value &action) {
    const Value &payload = action_payload(action);
    return integer_field(payload, "attack_index", integer_field(payload, "attack_idx", -1));
}

const Value *strategy_profile(const Value &strategies, const std::string &deck_key) {
    const Value *profile = strategies.find(deck_key);
    return profile != nullptr && profile->is_object() ? profile : nullptr;
}

std::string generic_plan_stage(const StrategyView &view) {
    const Value *goals = field(view.profile, "stage_goals");
    if (goals == nullptr || !goals->is_array() || goals->as_array().empty()) return "develop";
    if (view.opponent_prizes() <= 2 || view.own_prizes() <= 2) {
        return string_field(goals->as_array().back(), "id", "closeout");
    }
    if (view.turn() <= 2 || view.own_board().size() <= 1) {
        return string_field(goals->as_array().front(), "id", "setup");
    }
    return string_field(goals->as_array()[std::min<std::size_t>(1, goals->as_array().size() - 1)],
                        "id", "develop");
}

bool balanced_altaria(const StrategyView &view) {
    for (const Value *pokemon : view.own_board()) {
        if (string_field(*pokemon, "card_id") != "svg-alt") continue;
        const auto &energy = view.energy_ids(pokemon);
        if (std::any_of(energy.begin(), energy.end(), [](const Value &v) { return v.string_or() == "sv1-ener-3"; })
            && std::any_of(energy.begin(), energy.end(), [](const Value &v) { return v.string_or() == "sv1-ener-8"; })) return true;
    }
    return false;
}

bool houndstone_available(const StrategyView &view) {
    return view.count_card_board("sv1-104") > 0
        || view.count_card_board("sv1-106") > 0
        || view.count_card_hand("sv1-104") > 0
        || view.count_card_hand("sv1-106") > 0;
}

std::string plan_stage(const StrategyView &view) {
    const std::string key = view.deck_key();
    if (key == "fire") {
        if (view.opponent_prizes() <= 2 || view.own_prizes() <= 2) return "closeout";
        return view.count_card_board("svi-infr") <= 0 ? "establish_chain" : "ignite_engine";
    }
    if (key == "water") {
        if (view.count_card_board("sv2-grex") <= 0) return "establish_board";
        return view.own_prizes() <= 2 || view.opponent_active_damage() > 0
            ? "take_multi_prize" : "enable_shuriken";
    }
    if (key == "psychic") {
        const auto xatu = view.count_card_board("sv1-108");
        const bool natu = view.count_card_board("sv1-107") > 0
            || view.count_card_hand("sv1-107") > 0;
        if (xatu <= 0 || (xatu < 2 && natu)) return "build_xatu_engine";
        return view.count_card_hand("sv1-ener-5") >= 2
            ? "accelerate_energy" : "scale_attackers";
    }
    if (key == "lightning") {
        if (view.own_prizes() <= 2) return "burst_finish";
        return view.count_card_board("svl-flaa2") <= 0
            ? "charge_bench" : "prepare_pikachu";
    }
    if (key == "fighting") {
        if (view.count_card_board("svf-luca") <= 0) return "build_lucario";
        return view.energy_count("svf-luca") < 2 ? "stack_fighting_energy" : "aura_burst";
    }
    if (key == "colorless") {
        if (view.count_card_board("svi-maus") <= 0) return "fill_bench";
        return view.hand().size() < 6 ? "grow_hand" : "family_pressure";
    }
    if (key == "darkness") {
        if (view.count_card_board("svd-mabosstiff-ex") <= 0
            || view.count_card_board("svd-dodrio") <= 0) return "build_dual_lines";
        return view.damage_on_card("svd-dodrio") < 20
            ? "prime_damage_engine" : "pride_finish";
    }
    if (key == "dragon") {
        if (view.count_card_board("svg-alt") <= 0) return "build_healing_core";
        return balanced_altaria(view) ? "healing_lock" : "balance_energy";
    }
    if (key == "grass") {
        const auto evolved = view.count_role_board("evolution");
        if (view.own_prizes() <= 2 || view.opponent_prizes() <= 2) return "evolution_pressure";
        if (view.own_board().size() < 3) return "fill_evolution_board";
        return evolved < 3 ? "evolve_swarm" : "evolution_pressure";
    }
    if (key == "steel") {
        if (view.count_card_board("svm-bronzor") <= 0
            && view.count_card_board("svm-bronzong") <= 0) return "build_metal_board";
        return view.count_card_board("svm-bronzong") <= 0
            ? "enable_transfer" : "fortress_pressure";
    }
    return generic_plan_stage(view);
}

const Value *stage_goal(const StrategyView &view, const std::string &stage) {
    const Value *goals = field(view.profile, "stage_goals");
    if (goals == nullptr || !goals->is_array()) return nullptr;
    for (const Value &goal : goals->as_array()) {
        if (goal.is_object() && string_field(goal, "id") == stage) return &goal;
    }
    return nullptr;
}

std::int64_t role_progress(const StrategyView &view, const std::string &role) {
    if (role == "energy") {
        std::int64_t attached = 0;
        for (const Value *pokemon : view.own_board()) {
            for (const Value &energy : view.energy_ids(pokemon)) {
                if (view.has_role(energy.string_or(), role)) ++attached;
            }
        }
        return attached;
    }
    std::int64_t result = view.count_role_board(role);
    static const std::vector<std::string> hand_roles{
        "search", "draw", "recovery", "switch", "disruption", "tool",
        "healing", "energy_acceleration",
    };
    if (std::find(hand_roles.begin(), hand_roles.end(), role) != hand_roles.end()) {
        result += view.count_role_hand(role);
    }
    return result;
}

bool action_advances_role(
    const StrategyView &view,
    const Value &action,
    const std::string &role
) {
    const std::string kind = action_kind(action);
    const std::string source = action_card_id(action);
    if (kind == "PLAY_BASIC" || kind == "EVOLVE") return view.has_role(source, role);
    if (kind == "ATTACH_ENERGY") return role == "energy" && view.has_role(source, "energy");
    if (kind == "PLAY_TRAINER" || kind == "USE_STADIUM" || kind == "USE_ABILITY") {
        static const std::vector<std::string> effect_roles{
            "search", "draw", "recovery", "switch", "disruption", "tool",
            "healing", "energy_acceleration",
        };
        return std::find(effect_roles.begin(), effect_roles.end(), role) != effect_roles.end()
            && view.has_role(source, role);
    }
    return false;
}

double stage_action_score(const StrategyView &view, const Value &action) {
    const Value *goal = stage_goal(view, plan_stage(view));
    const Value *targets = goal == nullptr ? nullptr : field(*goal, "targets");
    if (targets == nullptr || !targets->is_object()) return 0.0;
    double score = 0.0;
    for (const auto &[role, required_value] : targets->as_object()) {
        const auto required = std::max<std::int64_t>(0, required_value.as_integer());
        const auto deficit = std::max<std::int64_t>(0, required - role_progress(view, role));
        if (deficit > 0 && action_advances_role(view, action, role)) {
            score += view.weight("stage_action_bonus", 7.0)
                * static_cast<double>(std::min<std::int64_t>(deficit, 2));
        }
    }
    return std::clamp(score, 0.0, 14.0);
}

double stage_state_score(const StrategyView &view) {
    const Value *goal = stage_goal(view, plan_stage(view));
    const Value *targets = goal == nullptr ? nullptr : field(*goal, "targets");
    if (targets == nullptr || !targets->is_object()) return 0.0;
    std::int64_t progress = 0;
    for (const auto &[role, required_value] : targets->as_object()) {
        const auto required = std::max<std::int64_t>(0, required_value.as_integer());
        progress += std::min(required, role_progress(view, role));
    }
    return std::clamp(
        static_cast<double>(progress) * view.weight("stage_state_progress", 3.0),
        0.0, 32.0);
}

double generic_state_adjustment(const StrategyView &view) {
    double score = static_cast<double>(view.count_role_board("primary_attacker"))
        * view.weight("board_primary");
    score += static_cast<double>(view.count_role_board("bench_engine"))
        * view.weight("board_engine");
    score += static_cast<double>(view.hand().size()) * view.weight("hand_size");
    score -= static_cast<double>(view.own_damage_total()) * view.weight("damage_pressure");
    if (view.own_prizes() <= 2) score += view.weight("closeout");
    if (view.opponent_prizes() <= 2) score -= view.weight("closeout");
    return score;
}

double custom_state_adjustment(const StrategyView &view) {
    const std::string key = view.deck_key();
    double score = generic_state_adjustment(view);
    if (key == "fire") {
        score += static_cast<double>(view.count_card_board("svi-infr")) * view.weight("fire_chain");
        score += static_cast<double>(view.count_card_discard("sv1-ener-2"))
            * view.weight("recycle_energy") * 0.15;
    } else if (key == "water") {
        score += static_cast<double>(view.count_card_board("sv2-grex")) * view.weight("greninja_attack");
        score += (view.opponent_active_damage() > 0 ? 1.0 : 0.0) * view.weight("torrent_setup");
        score += static_cast<double>(std::min<std::int64_t>(2, view.energy_count("sv2-grex")))
            * view.weight("greninja_energy");
    } else if (key == "psychic") {
        const auto xatu = view.count_card_board("sv1-108");
        score += static_cast<double>(xatu) * view.weight("xatu_engine");
        score += static_cast<double>(std::min(view.count_card_hand("sv1-ener-5"), xatu))
            * view.weight("psychic_energy_hand");
        if (houndstone_available(view)) {
            score += static_cast<double>(std::min<std::int64_t>(
                view.count_role_discard("psychic_pokemon"), 6))
                * view.weight("graveyard_scaling");
        }
    } else if (key == "lightning") {
        score += static_cast<double>(view.count_card_board("svl-flaa2")) * view.weight("flaaffy_engine");
        if (view.energy_count("svl-pikaex") >= 3) score += view.weight("pikachu_burst");
    } else if (key == "fighting") {
        score += static_cast<double>(view.count_card_board("svf-luca")) * view.weight("lucario_engine");
        score += static_cast<double>(view.energy_count("svf-luca")) * view.weight("fighting_stack");
    } else if (key == "colorless") {
        score += static_cast<double>(view.count_role_board("family")) * view.weight("family_board");
        if (view.hand().size() >= 6) score += view.weight("hand_preservation");
    } else if (key == "darkness") {
        score += static_cast<double>(view.damage_on_card("svd-dodrio")) * view.weight("damage_engine");
        if (view.count_card_discard("sv1-ener-7") > 0) score += view.weight("dark_patch");
    } else if (key == "dragon") {
        score += static_cast<double>(view.count_card_board("svg-alt")) * view.weight("altaria_lock");
        for (const Value *pokemon : view.own_board()) {
            if (string_field(*pokemon, "card_id") != "svg-alt") continue;
            const auto &energy = view.energy_ids(pokemon);
            if (std::any_of(energy.begin(), energy.end(), [](const Value &v) { return v.string_or() == "sv1-ener-3"; })
                && std::any_of(energy.begin(), energy.end(), [](const Value &v) { return v.string_or() == "sv1-ener-8"; })) {
                score += view.weight("dual_energy_balance") * 1.5;
            }
        }
    } else if (key == "grass") {
        score += static_cast<double>(view.count_role_board("evolution")) * view.weight("evolved_board");
    } else if (key == "steel") {
        score += static_cast<double>(view.count_card_board("svm-bronzong")) * view.weight("metal_transfer");
        score += static_cast<double>(view.own_board().size()) * view.weight("metal_board");
    }
    return score;
}

double generic_action_adjustment(const StrategyView &view, const Value &action) {
    const std::string kind = action_kind(action);
    const std::string card_id = action_card_id(action);
    const std::string target_id = action_target_card_id(action);
    double score = 0.0;
    if (kind == "PLAY_BASIC") {
        if (view.has_role(card_id, "setup_basic")) score += view.weight("play_setup");
        if (view.has_role(card_id, "bench_engine")) score += view.weight("play_engine");
    } else if (kind == "EVOLVE") {
        if (view.has_role(card_id, "evolution")) score += view.weight("evolve");
        if (view.has_role(card_id, "primary_attacker")) score += view.weight("evolve_core");
    } else if (kind == "ATTACH_ENERGY") {
        if (view.has_role(target_id, "primary_attacker")) score += view.weight("attach_primary");
        else if (view.has_role(target_id, "secondary_attacker")) score += view.weight("attach_secondary");
    } else if (kind == "PLAY_TRAINER" || kind == "USE_STADIUM") {
        for (const auto &[role, weight_name] : std::vector<std::pair<std::string, std::string>>{
            {"search", "play_search"}, {"draw", "play_draw"},
            {"energy_acceleration", "play_acceleration"}, {"recovery", "play_recovery"},
            {"switch", "play_switch"}, {"disruption", "play_disruption"},
        }) if (view.has_role(card_id, role)) score += view.weight(weight_name);
    } else if (kind == "USE_ABILITY") {
        if (view.has_role(card_id, "bench_engine")
            || view.has_role(card_id, "energy_acceleration")) score += view.weight("use_engine_ability");
    } else if (kind == "DECLARE_ATTACK") {
        if (view.has_role(card_id, "primary_attacker")) score += view.weight("attack_primary");
        else if (view.has_role(card_id, "secondary_attacker")) score += view.weight("attack_secondary");
    }
    return score;
}

bool has_any_in_hand(const StrategyView &view, const std::vector<std::string> &ids) {
    return std::any_of(ids.begin(), ids.end(), [&view](const std::string &id) {
        return view.count_card_hand(id) > 0;
    });
}

bool water_needs_froakie(const StrategyView &view) {
    return view.card_active("sv2-grex") && view.damage_on_card("sv2-grex") > 0
        && view.count_card_board("sv2-38") <= 0
        && view.count_card_board("sv2-39") <= 0
        && view.count_card_board("sv2-grex") <= 1;
}

const Value &choice_presentation(const Value &choice) {
    static const Value empty = Value::make_object();
    const Value *presentation = field(choice, "presentation");
    if (presentation != nullptr && presentation->is_object()) return *presentation;
    const Value *metadata = field(choice, "metadata");
    return metadata != nullptr && metadata->is_object() ? *metadata : empty;
}

std::string choice_purpose(const Value &choice) {
    const Value &presentation = choice_presentation(choice);
    return lower_ascii(string_field(
        presentation, "purpose", string_field(choice, "purpose")));
}

std::string choice_surface(const Value &choice) {
    const std::string request = lower_ascii(string_field(choice, "request_type"));
    const std::string purpose = choice_purpose(choice);
    if (request == "select_energy_target" || request == "distribute_energy"
        || request == "look_top_attach_energy") return "energy_target";
    if (request == "select_heal_target" || purpose == "heal") return "heal_target";
    if (request == "select_bench" && purpose == "switch") return "switch_target";
    if (request == "select_opponent_bench" || request == "bench_damage_target"
        || request == "damage_target" || request == "place_counters_self_discard") {
        return "opponent_target";
    }
    return "card";
}

std::string option_card_id(const Value &option) {
    for (const char *key : {"card_id", "source_card_id"}) {
        const std::string card_id = string_field(option, key);
        if (!card_id.empty()) return card_id;
    }
    const Value *ref = field(option, "ref");
    return ref != nullptr && ref->is_object()
        ? string_field(*ref, "card_id") : std::string{};
}

std::string choice_mode(
    const StrategyView &view,
    const Value &choice
) {
    const std::string request = lower_ascii(string_field(choice, "request_type"));
    const Value &presentation = choice_presentation(choice);
    const std::string purpose = choice_purpose(choice);
    if (request == "select_retreat_payment") return "payment";
    if (request == "select_attachment") {
        if (purpose.rfind("energy_relocate", 0) == 0
            || purpose.rfind("relocate_energy", 0) == 0
            || purpose == "trigger_move_basic_energy") return "source";
        if (purpose == "discard_energy" || purpose == "discard_energy_attachments") {
            return integer_field(presentation, "source_player", view.actor) == view.actor
                ? "payment" : "benefit";
        }
        return "payment";
    }
    if (request == "select_energy_source" || purpose == "energy_relocate_source") {
        return "source";
    }
    if (purpose == "discard_then_draw" || purpose == "discard_hand_then_draw"
        || purpose == "discard_cards" || purpose == "houb" || purpose == "zinnia"
        || purpose == "discard" || purpose == "discard_cost") return "discard";
    if (purpose == "hand_bottom_draw" || purpose == "bottom_deck") return "payment";
    return "benefit";
}

std::int64_t remaining_hand_count_for_choice(
    const StrategyView &view,
    const Value &choice,
    const Value &option,
    const std::string &card_id
) {
    std::int64_t count = view.count_card_hand(card_id);
    const Value *ref = field(option, "ref");
    bool removes_hand_card = true;
    if (ref != nullptr && ref->is_object()) {
        if (field(*ref, "zone") != nullptr) {
            removes_hand_card = string_field(*ref, "zone") == "hand";
        } else if (string_field(*ref, "kind") == "attachment") {
            removes_hand_card = false;
        }
    }
    const std::string mode = choice_mode(view, choice);
    if (removes_hand_card
        && (mode == "discard" || mode == "payment" || mode == "source")) --count;
    return std::max<std::int64_t>(0, count);
}

bool choice_offers_card(const Value &choice, const std::string &card_id) {
    const Value *options = field(choice, "options");
    return options != nullptr && options->is_array()
        && std::any_of(options->as_array().begin(), options->as_array().end(),
            [&card_id](const Value &option) {
                return option.is_object() && option_card_id(option) == card_id;
            });
}

double generic_choice_keep_value(
    const StrategyView &view,
    const Value &choice,
    const Value &option
) {
    if (choice_surface(choice) != "card") return 0.0;
    const std::string card_id = option_card_id(option);
    double score = 0.0;
    if (view.has_role(card_id, "primary_attacker")) score += view.weight("choice_primary");
    if (view.has_role(card_id, "bench_engine")
        || view.has_role(card_id, "energy_acceleration")) score += view.weight("choice_engine");
    if (view.has_role(card_id, "setup_basic")) score += view.weight("choice_setup");
    if (view.has_role(card_id, "evolution")) score += view.weight("choice_evolution", 14.0);
    if (view.has_role(card_id, "search") || view.has_role(card_id, "recovery")) {
        score += view.weight("choice_resource", 4.0);
    }
    if (view.has_role(card_id, "energy")) score += view.weight("choice_energy");
    return score;
}

double custom_choice_keep_value(
    const StrategyView &view,
    const Value &choice,
    const Value &option
) {
    double score = generic_choice_keep_value(view, choice, option);
    const std::string key = view.deck_key();
    const std::string card = option_card_id(option);
    const std::string surface = choice_surface(choice);
    if (key == "fire") {
        const double chain = view.weight("fire_chain");
        if (view.bench_count() == 0 && view.card_active("svi-chim")
            && choice_mode(view, choice) == "benefit" && surface == "card") {
            if (view.has_role(card, "setup_basic")) score += 240.0;
            else if (view.has_role(card, "evolution")) score -= 240.0;
        }
        const bool has_chimchar = view.count_card_board("svi-chim") > 0;
        const bool has_monferno = view.count_card_board("svi-monf") > 0
            || view.count_card_hand("svi-monf") > 0;
        const bool has_candy = view.count_card_hand("sv1-152") > 0;
        if (card == "svi-chim") score += chain;
        else if (card == "svi-monf" && has_chimchar && !has_monferno) score += chain;
        else if (card == "svi-infr") {
            score += has_monferno || (has_chimchar && has_candy) ? chain : -chain;
        }
        if ((card == "svi-monf" || card == "svi-infr")
            && remaining_hand_count_for_choice(view, choice, option, card) > 0) {
            score -= chain;
        } else if ((card == "svi-erec" || card == "svi-mela")
            && view.count_card_discard("sv1-ener-2") > 0) {
            score += view.weight("recycle_energy");
        }
    } else if (key == "water") {
        if (surface != "card") return score;
        if (card == "sv2-38" || card == "sv2-39" || card == "sv2-grex") {
            score += view.weight("greninja_attack");
            if (card == "sv2-38" && water_needs_froakie(view)) {
                score += view.weight("froakie_backup_search");
            }
        } else if (card == "sv2-staryu") {
            score += view.weight("choice_engine");
            if (view.count_card_board("sv2-staryu")
                + view.count_card_board("sv2-starm") > 0) {
                score -= view.weight("staryu_duplicate_penalty");
            }
        } else if (card == "sv2-starm") {
            const bool executable = view.count_card_board("sv2-staryu") > 0
                || view.count_card_hand("sv2-staryu") > 0;
            score += executable ? view.weight("choice_engine")
                : -view.weight("starmie_unexecutable_penalty");
            if (view.count_card_board("sv2-starm") > 0
                && view.count_card_board("sv2-staryu") <= 0) {
                score -= view.weight("staryu_duplicate_penalty");
            }
        }
    } else if (key == "psychic") {
        if (surface != "card") return score;
        const std::string mode = choice_mode(view, choice);
        if (mode == "discard" || mode == "payment" || mode == "source") return score;
        const auto natu_board = view.count_card_board("sv1-107");
        const auto xatu_board = view.count_card_board("sv1-108");
        const auto natu_hand = view.count_card_hand("sv1-107");
        const bool must_start = xatu_board <= 0 && natu_board + natu_hand <= 0
            && view.bench_count() < 5 && choice_offers_card(choice, "sv1-107");
        if (must_start && card != "sv1-107" && card != "sv1-108") {
            score -= view.weight("attacker_before_xatu_search_penalty");
        }
        if (card == "sv1-108") {
            if (natu_board > 0) score += view.weight("xatu_engine") * 2.5;
            else if (natu_hand > 0) score += view.weight("xatu_engine") * 1.25;
            else score -= view.weight("xatu_engine") * 2.0;
        } else if (card == "sv1-107") {
            score += view.weight("xatu_engine")
                * (natu_board + natu_hand <= xatu_board ? 2.0 : 0.5);
        } else if ((card == "sv1-104" || card == "sv1-106")
            && natu_board > 0 && xatu_board <= 0) {
            score -= view.weight("xatu_engine");
        } else if (card == "sv1-ener-5" && xatu_board > 0) {
            score += view.weight("psychic_energy_hand") * 2.0;
        }
    } else if (key == "lightning") {
        if (card == "svl-mare2" || card == "svl-flaa2") score += view.weight("flaaffy_engine");
        else if (card == "svl-pikaex") score += view.weight("pikachu_burst");
    } else if (key == "fighting") {
        if (card == "svf-rio" || card == "svf-luca") score += view.weight("lucario_engine");
        else if (card == "svf-scyt" || card == "svf-klea") score += view.weight("kleavor");
    } else if (key == "colorless") {
        if (card == "svi-tand" || card == "svi-maus") score += view.weight("family_board") * 2.0;
        else if (view.has_role(card, "energy")) score += view.weight("special_energy");
    } else if (key == "darkness") {
        if (card == "svd-doduo" || card == "svd-dodrio") score += view.weight("damaged_dodrio");
        else if (card == "svd-maschiff" || card == "svd-mabosstiff-ex") score += view.weight("choice_primary");
        else if (card == "svd-dark-patch" && view.count_card_discard("sv1-ener-7") > 0)
            score += view.weight("dark_patch");
    } else if (key == "dragon") {
        if (surface != "card") return score;
        if (card == "svg-swa") {
            score += view.weight("altaria_lock")
                * (view.count_card_board("svg-swa") <= 0 ? 0.45 : -0.25);
        } else if (card == "svg-alt") {
            score += view.weight("altaria_lock")
                * (view.count_card_board("svg-swa") > 0 ? 0.65 : -0.5);
        } else if ((card == "svf-potion" || card == "svg-chef")
            && view.own_damage_total() > 0) {
            score += static_cast<double>(view.own_damage_total()) * view.weight("healing");
        }
        if (card == "svg-swa" || card == "svg-alt") {
            score -= static_cast<double>(remaining_hand_count_for_choice(
                view, choice, option, card)) * 35.0;
        } else if ((card == "sv1-ener-3" || card == "sv1-ener-8")
            && plan_stage(view) == "balance_energy"
            && view.count_card_hand(card) <= 1) {
            score += view.weight("dual_energy_balance") * 2.0;
        }
    } else if (key == "grass") {
        if (surface != "card") return score;
        const bool turtwig = view.count_card_board("svg2-turt") > 0;
        const bool grotle = view.count_card_board("svg2-grot") > 0;
        const bool torterra = view.count_card_board("svg2-tort") > 0;
        const bool candy = view.count_card_hand("sv1-152") > 0;
        if (card == "svg2-turt") {
            score += !(turtwig || grotle || torterra)
                ? view.weight("evolved_board") + (view.bench_count() <= 0 ? 24.0 : 0.0)
                : -8.0;
        } else if (card == "svg2-grot") {
            const auto receivers = view.count_card_board("svg2-turt");
            const auto supply = remaining_hand_count_for_choice(view, choice, option, card);
            score += receivers > supply
                ? view.weight("evolved_board") * 1.25 : -view.weight("evolve_core");
        } else if (card == "svg2-tort") {
            auto receivers = view.count_card_board("svg2-grot");
            if (candy) receivers += view.count_card_board("svg2-turt");
            const auto supply = remaining_hand_count_for_choice(view, choice, option, card);
            if (supply >= receivers) score -= view.weight("evolve_core") * 1.25;
            else if (grotle) score += view.weight("evolve_core") * 0.75;
            else if (turtwig && candy) score += view.weight("evolve_core") * 0.55;
            else score -= view.weight("evolve_core");
        } else if (card == "svg2-gard") score += view.weight("gardenia");
        if (card == "svg2-turt" || card == "svg2-grot" || card == "svg2-tort") {
            score -= static_cast<double>(remaining_hand_count_for_choice(
                view, choice, option, card)) * 35.0;
        }
    } else if (key == "steel") {
        if (card == "svm-bronzor" || card == "svm-bronzong") score += view.weight("metal_transfer");
        else if (card == "svm-zacian" || card == "svm-zamazenta" || card == "svm-orthworm")
            score += view.weight("metal_board");
    }
    return score;
}

double discard_synergy(
    const StrategyView &view,
    const Value &option
) {
    if (view.deck_key() == "psychic") {
        const bool houndstone = view.count_card_board("sv1-104") > 0
            || view.count_card_board("sv1-106") > 0
            || view.count_card_hand("sv1-104") > 0
            || view.count_card_hand("sv1-106") > 0;
        if (!houndstone) return 0.0;
    }
    return view.has_role(option_card_id(option), "discard_synergy")
        ? view.weight("discard_synergy", 16.0) : 0.0;
}

double custom_action_adjustment(const StrategyView &view, const Value &action) {
    double score = generic_action_adjustment(view, action);
    const std::string key = view.deck_key();
    const std::string kind = action_kind(action);
    const std::string card = action_card_id(action);
    const std::string target = action_target_card_id(action);
    const std::string target_slot = action_target_slot(action);
    const auto attack = attack_index(action);
    if (key == "fire") {
        if (kind == "PLAY_BASIC" && target_slot == "active" && view.turn() <= 1
            && view.count_card_hand("svi-chiy") > 0 && view.count_card_hand("svi-ente") > 0) {
            if (card == "svi-chiy") score += view.weight("chiyu_opening");
            else if (card == "svi-ente") score -= view.weight("chiyu_opening");
        } else if (kind == "PLAY_BASIC" && card == "svi-chim"
            && target_slot.rfind("bench_", 0) == 0) score += view.weight("chimchar_bench");
        else if (kind == "EVOLVE" && card == "svi-infr") score += view.weight("fire_chain");
        else if (kind == "PLAY_TRAINER" && card == "sv1-152") score += view.weight("rare_candy");
        else if (kind == "PLAY_TRAINER" && (card == "svi-erec" || card == "svi-mela" || card == "sv3-134")) {
            score += static_cast<double>(std::min<std::int64_t>(view.count_card_discard("sv1-ener-2"), 3))
                * view.weight("recycle_energy") * 0.25;
        } else if (kind == "DECLARE_ATTACK" && card == "svi-infr") {
            score += view.weight("infernape_attack");
            if (attack == 0) score += view.weight("infernape_spiral");
            else if (attack == 1) {
                score += view.weight("infernape_burning_kick");
                score -= static_cast<double>(view.energy_count(card)) * view.weight("burning_kick_energy_cost");
            }
        } else if (kind == "DECLARE_ATTACK" && card == "svi-sqwk" && attack == 0) {
            score += view.weight("squawk_call_family");
            if (view.turn() <= 2) score += view.weight("squawk_opening");
        } else if (kind == "DECLARE_ATTACK" && card == "svi-chiy" && attack == 0) {
            score += static_cast<double>(std::min<std::int64_t>(view.count_card_discard("sv1-ener-2"), 2))
                * view.weight("chiyu_acceleration");
        } else if (kind == "DECLARE_ATTACK" && card == "svi-chiy" && attack == 1
            && view.own_knockout_last_turn()) score += view.weight("chiyu_revenge");
    } else if (key == "water") {
        if (kind == "PLAY_BASIC" && card == "sv2-tatsu" && target_slot == "active" && view.going_second()) {
            score += view.weight("tatsugiri_opening");
        } else if (kind == "PLAY_BASIC" && card == "sv2-staryu" && target_slot == "active"
            && view.turn() <= 1 && view.count_card_hand("sv2-tatsu") > 0 && view.going_second()) {
            score -= view.weight("staryu_opening_penalty");
        } else if (kind == "PLAY_BASIC" && card == "sv2-staryu"
            && view.count_card_board("sv2-staryu") + view.count_card_board("sv2-starm") > 0) {
            score -= view.weight("staryu_duplicate_penalty");
        } else if (kind == "PLAY_BASIC" && card == "sv2-38" && target_slot.rfind("bench_", 0) == 0) {
            score += view.weight("froakie_bench");
            if (water_needs_froakie(view)) score += view.weight("froakie_backup_search");
        } else if (kind == "ATTACH_ENERGY" && target == "sv2-tatsu" && view.card_active("sv2-tatsu")
            && view.energy_count("sv2-tatsu") <= 0 && view.bench_count() > 0) {
            score += view.weight("tatsugiri_prepare_attachment");
        } else if (kind == "EVOLVE" && card == "sv2-grex") score += view.weight("greninja_attack");
        else if (kind == "PLAY_TRAINER" && card == "sv1-152"
            && view.count_card_board("sv2-38") > 0 && view.count_card_hand("sv2-grex") > 0) {
            score += view.weight("rare_candy_greninja");
        } else if (kind == "PLAY_TRAINER" && card == "sv2-cand") score += view.weight("candice");
        else if (kind == "DECLARE_ATTACK" && card == "sv2-grex") {
            score += view.weight("greninja_attack");
            if (attack == 0) {
                score += view.weight("greninja_shuriken");
                score += static_cast<double>(std::max<std::int64_t>(1,
                    static_cast<std::int64_t>(view.opponent_board().size()) - 1))
                    * view.weight("bench_target_pressure") * 0.35;
            } else if (attack == 1) {
                score += view.weight("greninja_torrent");
                if (view.opponent_active_damage() > 0) score += view.weight("bench_target_pressure");
            }
        } else if (kind == "DECLARE_ATTACK" && card == "sv2-tatsu" && attack == 0) {
            score += view.weight("tatsugiri_prepare");
            if (view.turn() <= 2) score += view.weight("tatsugiri_opening");
        } else if (kind == "USE_ABILITY" && card == "sv2-starm") {
            const bool ready = view.count_card_board("sv2-grex") > 0 && view.energy_count("sv2-grex") >= 2;
            const bool torrent = ready && (view.card_active("sv2-grex")
                || (view.card_active("sv2-starm") && view.bench_count() > 0))
                && view.opponent_active_damage() <= 0;
            score += torrent ? view.weight("starmie_comet_combo") : -view.weight("starmie_material_cost");
            score -= static_cast<double>(view.energy_count(card)) * view.weight("starmie_attachment_cost");
            if (view.card_active(card) && view.bench_count() <= 0) score -= view.weight("starmie_no_backup_penalty");
        }
    } else if (key == "psychic") {
        const bool exact = string_field(view.state, "phase") == "MAIN" && view.turn() == 2
            && view.going_second() && integer_field(view.state, "active_player_idx", -1) == view.actor;
        const bool cresselia_bench = view.card_benched("sv1-113");
        const bool cresselia_ready = view.energy_count("sv1-113") >= 1;
        if (exact && cresselia_bench) {
            if (kind == "ATTACH_ENERGY" && target == "sv1-113"
                && target_slot.rfind("bench_", 0) == 0) score += view.weight("cresselia_opening_route");
            else if (kind == "PLAY_TRAINER" && card == "sv1-150" && cresselia_ready)
                score += view.weight("cresselia_opening_route");
            else if (kind == "PLAY_TRAINER" && card == "sv1-204"
                && (cresselia_ready || (!bool_field(view.own(), "energy_attached_this_turn")
                    && view.count_card_hand("sv1-ener-5") > 0))
                && view.count_card_hand("sv1-150") <= 0
                && !(action_kind(action) == "RETREAT" && target == "sv1-113"))
                score += view.weight("cresselia_opening_route");
            else if (kind == "RETREAT" && target == "sv1-113" && cresselia_ready)
                score += view.weight("cresselia_opening_route");
        }
        if (kind == "PLAY_BASIC" && card == "sv1-113" && target_slot == "active" && view.going_second())
            score += view.weight("cresselia_active_opening");
        else if (kind == "PLAY_BASIC" && card == "sv1-107" && target_slot.rfind("bench_", 0) == 0)
            score += view.weight("natu_bench");
        else if (kind == "EVOLVE" && card == "sv1-108") {
            score += view.weight("xatu_engine");
            if (view.count_card_board("sv1-108") <= 0) score += view.weight("first_xatu_priority");
        } else if (kind == "EVOLVE" && card == "sv1-106"
            && view.count_card_board("sv1-108") <= 0 && view.count_card_board("sv1-107") > 0)
            score -= view.weight("houndstone_before_xatu_penalty");
        else if (kind == "USE_ABILITY" && card == "sv1-108") {
            score += view.weight("xatu_engine");
            score += static_cast<double>(view.count_card_hand("sv1-ener-5")) * view.weight("psychic_energy_hand");
        } else if (kind == "DECLARE_ATTACK" && card == "sv1-106")
            score += static_cast<double>(view.count_role_discard("psychic_pokemon")) * view.weight("graveyard_scaling");
        else if (kind == "DECLARE_ATTACK" && card == "sv1-113" && attack == 0) {
            score += view.weight("cresselia_growth");
            if (exact) score += view.weight("cresselia_first_turn_growth");
        } else if (kind == "DECLARE_ATTACK" && card == "sv1-111") {
            if (attack == 0) score += view.weight("latios_glide");
            else if (attack == 1) score += view.weight("latios_clean_light");
        }
    } else if (key == "lightning") {
        static const std::vector<std::string> front{"svl-thun", "svl-emol", "svl-chat", "svl-zera"};
        static const std::vector<std::string> engines{"svl-mare2", "svl-chin"};
        if (kind == "PLAY_BASIC" && target_slot == "active" && view.turn() <= 1) {
            if (std::find(front.begin(), front.end(), card) != front.end()) score += view.weight("frontline_opening");
            else if (std::find(engines.begin(), engines.end(), card) != engines.end()
                && has_any_in_hand(view, front)) score -= view.weight("bench_engine_active_penalty");
        } else if (kind == "PLAY_TRAINER" && card == "sv1-170") score += view.weight("generator");
        else if (kind == "EVOLVE" && card == "svl-flaa2") score += view.weight("flaaffy_engine");
        else if (kind == "USE_ABILITY" && card == "svl-flaa2") score += view.weight("flaaffy_engine");
        else if (kind == "DECLARE_ATTACK" && card == "svl-pikaex") {
            if (attack == 0) score += view.weight("pikachu_jab");
            else if (attack == 1) {
                score += view.weight("pikachu_strong_volt");
                const double scale = view.count_card_board("svl-flaa2") > 0 ? 0.35 : 1.0;
                score -= static_cast<double>(view.energy_count(card)) * view.weight("strong_volt_energy_risk") * scale;
            }
        }
    } else if (key == "fighting") {
        if (kind == "EVOLVE" && card == "svf-luca") score += view.weight("lucario_engine");
        else if (kind == "USE_ABILITY" && card == "svf-luca") {
            const Value *source = view.row_for_slot(action_source_slot(action));
            const auto hp = view.card_hp(card);
            const auto after = StrategyView::damage(source) + 20;
            if (hp > 0 && after >= hp) score -= view.weight("lucario_self_ko_penalty");
            else if (hp > 0 && hp - after <= 40) score -= view.weight("lucario_low_hp_penalty");
            else score += view.weight("lucario_engine");
        } else if (kind == "DECLARE_ATTACK" && card == "svf-luca")
            score += static_cast<double>(view.energy_ids(view.active(view.actor)).size()) * view.weight("fighting_stack");
        else if (kind == "DECLARE_ATTACK" && card == "svf-klea") {
            score += view.weight("kleavor");
            if (attack == 0) score += view.weight("kleavor_guillotine");
            else if (attack == 1) score += view.weight("kleavor_rampage");
        }
    } else if (key == "colorless") {
        if (kind == "EVOLVE" && card == "svi-maus")
            score += view.weight("family_board") * static_cast<double>(view.count_role_board("family") + 1);
        else if (kind == "ATTACH_ENERGY" && view.has_role(card, "energy") && target == "svi-maus")
            score += view.weight("special_energy");
        else if (kind == "PLAY_TRAINER" && card == "sv1-189" && view.hand().size() >= 6)
            score -= view.weight("hand_preservation");
        else if (kind == "DECLARE_ATTACK" && card == "svi-maus")
            score += view.weight("family_board") * static_cast<double>(view.count_role_board("family"));
        else if (kind == "DECLARE_ATTACK" && card == "svi-ambi") {
            if (attack == 0) score += view.weight("ambipom_call");
            else if (attack == 1) score += static_cast<double>(std::min<std::size_t>(view.hand().size(), 8)) * view.weight("ambipom_hand_attack");
        } else if (kind == "DECLARE_ATTACK" && card == "svi-gree") {
            if (attack == 0) score += view.weight("greedent_call");
            else if (attack == 1) score += view.hand().size() >= 5 ? view.weight("greedent_dump") : -view.weight("greedent_dump");
        }
    } else if (key == "darkness") {
        if (kind == "PLAY_TRAINER" && card == "svd-dark-patch") {
            const auto count = view.count_card_discard("sv1-ener-7");
            score += count <= 0 ? -view.weight("dark_patch") * 2.0
                : static_cast<double>(std::min<std::int64_t>(count, 2)) * view.weight("dark_patch") * 0.5;
        } else if (kind == "USE_ABILITY" && card == "svd-dodrio") {
            const auto hp = view.card_hp(card);
            const auto after = view.damage_on_card(card) + 10;
            if (hp > 0 && after >= hp) score -= view.weight("dodrio_safety_penalty") * 2.0;
            else if (hp > 0 && hp - after <= 20) score -= view.weight("dodrio_safety_penalty");
            else score += view.weight("damaged_dodrio");
        } else if (kind == "EVOLVE" && card == "svd-dodrio") score += view.weight("damaged_dodrio");
        else if (kind == "EVOLVE" && card == "svd-mabosstiff-ex") score += view.weight("mabosstiff_evolution");
        else if (kind == "DECLARE_ATTACK" && card == "svd-mabosstiff-ex") {
            if (attack == 0) score += view.weight("mabosstiff_intimidate");
            else if (attack == 1 && view.own_bench_damaged()) score += view.weight("mabosstiff_pride");
        }
    } else if (key == "dragon") {
        if (kind == "EVOLVE" && card == "svg-alt") score += view.weight("altaria_lock");
        else if (kind == "USE_ABILITY" && card == "svg-alt")
            score += static_cast<double>(view.own_damage_total()) * view.weight("healing");
        else if (kind == "PLAY_TRAINER" && (card == "svf-potion" || card == "svg-chef"))
            score += static_cast<double>(view.own_damage_total()) * view.weight("healing");
        else if (kind == "ATTACH_ENERGY" && target == "svg-alt") {
            const Value *row = view.row_for_slot(target_slot);
            const auto &ids = view.energy_ids(row);
            const bool present = std::any_of(ids.begin(), ids.end(), [&card](const Value &v) { return v.string_or() == card; });
            if ((card == "sv1-ener-3" || card == "sv1-ener-8") && !present)
                score += view.weight("dual_energy_balance");
        } else if (kind == "DECLARE_ATTACK" && card == "svg-ceti") {
            if (attack == 0) score += view.weight("cetitan_headbutt");
            else if (attack == 1) {
                score += view.weight("cetitan_sweeping");
                score -= static_cast<double>(view.damage_on_card(card)) * view.weight("cetitan_damage_penalty");
            }
        } else if (kind == "DECLARE_ATTACK" && card == "svg-milt" && attack == 0 && view.card_healed(card))
            score += view.weight("miltank_healed_attack");
    } else if (key == "grass") {
        if (kind == "PLAY_BASIC" && card == "svg2-turt") score += view.weight("turtwig_setup");
        else if (kind == "EVOLVE") score += view.weight("evolved_board") * 0.65;
        else if (kind == "ATTACH_ENERGY" && target == "svg2-tort") {
            const Value *row = view.row_for_slot(target_slot);
            if (row != nullptr && view.energy_ids(row).size() >= 2
                && view.count_role_board("evolution") >= 3) score -= 150.0;
        } else if (kind == "PLAY_TRAINER" && card == "sv1-152") score += view.weight("rare_candy");
        else if (kind == "PLAY_TRAINER" && card == "svg2-gard") score += view.weight("gardenia");
        else if (kind == "USE_ABILITY" && card == "svg2-grot"
            && has_any_in_hand(view, {"sv2-young", "sv1-176", "sv1-180", "sv1-189"})) score -= 30.0;
        else if (kind == "DECLARE_ATTACK" && card == "svg2-tort") {
            if (attack == 0) {
                score += view.weight("torterra_evolution_pressure");
                score += view.weight("evolved_board") * static_cast<double>(view.count_role_board("evolution"));
            } else if (attack == 1) score += view.weight("torterra_headbutt");
        } else if (kind == "USE_ABILITY" && card == "svg2-empo" && view.hand().empty()
            && view.count_card_discard(card) > 0) score += view.weight("empoleon_revival");
        else if (kind == "DECLARE_ATTACK" && card == "svg2-zaru" && attack == 0 && view.turn() <= 2)
            score += view.weight("zarude_opening_search");
    } else if (key == "steel") {
        if (kind == "EVOLVE" && card == "svm-bronzong") score += view.weight("metal_transfer");
        else if (kind == "USE_ABILITY" && card == "svm-bronzong") score += view.weight("metal_transfer");
        else if (kind == "DECLARE_ATTACK" && card == "svm-zamazenta" && view.own_knockout_last_turn())
            score += view.weight("revenge");
        else if (kind == "DECLARE_ATTACK" && card == "svm-zacian") {
            if (attack == 0) score += static_cast<double>(view.bench_count()) * view.weight("zacian_battle_legion");
            else if (attack == 1) score += view.weight("zacian_blade");
        } else if (kind == "ATTACH_ENERGY" && target == "svm-orthworm" && card == "sv1-ener-8"
            && view.energy_id_count(target, card) == 2) score += view.weight("orthworm_threshold");
        else if (kind == "PLAY_BASIC" && view.has_role(card, "primary_attacker"))
            score += view.weight("metal_board") * static_cast<double>(view.own_board().size() + 1);
    }
    return score;
}

double matchup_adjustment(const StrategyView &view, const Value &action) {
    double threat = 0.0;
    const Value *tags = field(view.archetypes, view.opponent_deck_key());
    const Value *weights = field(view.profile, "matchup_weights");
    if (tags != nullptr && tags->is_array() && weights != nullptr && weights->is_object()) {
        for (const Value &tag : tags->as_array()) threat += number_field(*weights, tag.string_or());
    }
    const std::string kind = action_kind(action);
    const std::string card = action_card_id(action);
    double score = 0.0;
    if (kind == "PLAY_BASIC" || kind == "EVOLVE" || kind == "ATTACH_ENERGY") score += threat * 0.08;
    else if (kind == "DECLARE_ATTACK") {
        score += threat * 0.25;
        if (view.opponent_prizes() < view.own_prizes()) score += view.weight("closeout") * 0.2;
    } else if ((kind == "PLAY_TRAINER" || kind == "USE_STADIUM")
        && view.has_role(card, "disruption")) {
        score += threat * 0.7;
        score += static_cast<double>(
            view.opponent_engine_count_for_action_semantics()) * 1.5;
    } else if (kind == "RETREAT") {
        const Value *active = view.active(view.actor);
        const Value *statuses = active == nullptr ? nullptr : field(*active, "status_conditions");
        score += static_cast<double>(statuses != nullptr && statuses->is_array()
            ? statuses->as_array().size() : 0U) * view.weight("play_switch");
    }
    return score;
}

double candidate_score(const StrategyView &view, const Value &action) {
    const double top_scale = std::clamp(
        static_cast<double>(std::max<std::int64_t>(1,
            static_cast<std::int64_t>(std::round(view.weight("search_top_k", 6.0))))) / 6.0,
        0.5, 1.5);
    const std::string source = action_card_id(action);
    const std::string target = action_target_card_id(action);
    double score = 0.0;
    if (view.has_role(source, "primary_attacker") || view.has_role(target, "primary_attacker"))
        score += view.weight("candidate_primary", 6.0) * top_scale;
    if (view.has_role(source, "bench_engine") || view.has_role(target, "bench_engine"))
        score += view.weight("candidate_engine", 4.0) * top_scale;
    return std::clamp(score, -24.0, 24.0);
}

} // namespace

TraditionalStrategyCatalog::TraditionalStrategyCatalog(Value strategies, Value catalog) {
    const Value *strategy_rows = strategies.find("strategies");
    const Value *archetypes = strategies.find("deck_archetypes");
    strategies_ = strategy_rows != nullptr && strategy_rows->is_object()
        ? *strategy_rows : std::move(strategies);
    archetypes_ = archetypes != nullptr && archetypes->is_object()
        ? *archetypes : Value::make_object();
    const Value *cards = catalog.find("cards");
    cards_ = cards != nullptr && cards->is_object() ? *cards : std::move(catalog);
    valid_ = strategies_.is_object() && !strategies_.as_object().empty();
}

bool TraditionalStrategyCatalog::valid() const noexcept { return valid_; }

std::string TraditionalStrategyCatalog::strategy_id(const std::string &deck_key) const {
    const Value *profile = strategy_profile(strategies_, deck_key);
    return profile == nullptr ? "generic_balanced_v1"
        : string_field(*profile, "strategy_id", "generic_balanced_v1");
}

std::int64_t TraditionalStrategyCatalog::strategy_version(
    const std::string &deck_key
) const {
    const Value *profile = strategy_profile(strategies_, deck_key);
    return profile == nullptr ? 0 : integer_field(*profile, "version", 0);
}

std::string TraditionalStrategyCatalog::strategy_content_hash(
    const std::string &deck_key
) const {
    const Value *profile = strategy_profile(strategies_, deck_key);
    return profile == nullptr ? std::string{}
        : string_field(*profile, "content_hash");
}

double TraditionalStrategyCatalog::action_score(
    const Value &state,
    std::int32_t actor,
    const Value &action
) const {
    if (!valid_ || actor < 0 || actor > 1) return 0.0;
    const Value *keys = field(state, "public_deck_keys");
    const std::string deck_key = keys != nullptr && keys->is_array()
        && static_cast<std::size_t>(actor) < keys->as_array().size()
        ? keys->as_array()[static_cast<std::size_t>(actor)].string_or() : std::string{};
    const Value *profile = strategy_profile(strategies_, deck_key);
    if (profile == nullptr) return 0.0;
    const StrategyView view{state, *profile, archetypes_, cards_, actor, &action};
    const double score = custom_action_adjustment(view, action)
        + matchup_adjustment(view, action)
        + stage_action_score(view, action)
        + candidate_score(view, action);
    return std::clamp(score, -160.0, 160.0);
}

double TraditionalStrategyCatalog::choice_score(
    const Value &state,
    std::int32_t actor,
    const Value &choice_view,
    const Value &option
) const {
    if (!valid_ || actor < 0 || actor > 1
        || !choice_view.is_object() || !option.is_object()) return 0.0;
    const Value *keys = field(state, "public_deck_keys");
    const std::string deck_key = keys != nullptr && keys->is_array()
        && static_cast<std::size_t>(actor) < keys->as_array().size()
        ? keys->as_array()[static_cast<std::size_t>(actor)].string_or()
        : std::string{};
    const Value *profile = strategy_profile(strategies_, deck_key);
    if (profile == nullptr) return 0.0;
    const StrategyView view{state, *profile, archetypes_, cards_, actor, nullptr};
    const double keep = custom_choice_keep_value(view, choice_view, option);
    const std::string mode = choice_mode(view, choice_view);
    double score = keep;
    if (mode == "discard" || mode == "payment" || mode == "source") {
        score = -keep;
        if (mode == "discard") score += discard_synergy(view, option);
    }
    return std::clamp(score, -120.0, 120.0);
}

double TraditionalStrategyCatalog::state_score(
    const Value &state,
    std::int32_t actor
) const {
    if (!valid_ || actor < 0 || actor > 1) return 0.0;
    const Value *keys = field(state, "public_deck_keys");
    const std::string deck_key = keys != nullptr && keys->is_array()
        && static_cast<std::size_t>(actor) < keys->as_array().size()
        ? keys->as_array()[static_cast<std::size_t>(actor)].string_or() : std::string{};
    const Value *profile = strategy_profile(strategies_, deck_key);
    if (profile == nullptr) return 0.0;
    const StrategyView view{state, *profile, archetypes_, cards_, actor, nullptr};
    return std::clamp(
        custom_state_adjustment(view) + stage_state_score(view), -400.0, 400.0);
}

Value TraditionalStrategyCatalog::turn_goals(
    const Value &state,
    std::int32_t actor
) const {
    if (!valid_ || actor < 0 || actor > 1) return Value::make_object();
    const Value *keys = field(state, "public_deck_keys");
    const std::string deck_key = keys != nullptr && keys->is_array()
        && static_cast<std::size_t>(actor) < keys->as_array().size()
        ? keys->as_array()[static_cast<std::size_t>(actor)].string_or()
        : std::string{};
    const Value *profile = strategy_profile(strategies_, deck_key);
    if (profile == nullptr) return Value::make_object();
    const StrategyView view{state, *profile, archetypes_, cards_, actor, nullptr};
    const std::string stage = plan_stage(view);
    const Value *goal = stage_goal(view, stage);
    const Value *roles = field(*profile, "card_roles");
    const auto role_cards = [&roles](const char *role) {
        const Value *values = roles != nullptr && roles->is_object()
            ? field(*roles, role) : nullptr;
        return values != nullptr && values->is_array()
            ? *values : Value::make_array();
    };
    Value search_hints(Value::Object{
        {"top_k", Value(std::max<std::int64_t>(1, static_cast<std::int64_t>(
            std::round(view.weight("search_top_k", 6.0)))))},
        {"primary_attackers", role_cards("primary_attacker")},
        {"engine_cards", role_cards("bench_engine")},
    });
    return Value(Value::Object{
        {"strategy_id", Value(string_field(
            *profile, "strategy_id", "generic_balanced_v1"))},
        {"strategy_version", Value(integer_field(*profile, "version", 0))},
        {"content_hash", Value(string_field(*profile, "content_hash"))},
        {"runtime_hook_hash", Value(string_field(*profile, "runtime_hook_hash"))},
        {"deck_key", Value(deck_key)},
        {"stage", Value(stage)},
        {"goal", goal == nullptr ? Value::make_object() : *goal},
        {"opponent_deck_key", Value(view.opponent_deck_key())},
        {"search_hints", std::move(search_hints)},
    });
}

bool TraditionalStrategyCatalog::card_has_role(
    const Value &state,
    std::int32_t actor,
    const std::string &card_id,
    const std::string &role
) const {
    if (!valid_ || actor < 0 || actor > 1 || card_id.empty() || role.empty()) {
        return false;
    }
    const Value *keys = field(state, "public_deck_keys");
    const std::string deck_key = keys != nullptr && keys->is_array()
        && static_cast<std::size_t>(actor) < keys->as_array().size()
        ? keys->as_array()[static_cast<std::size_t>(actor)].string_or()
        : std::string{};
    const Value *profile = strategy_profile(strategies_, deck_key);
    if (profile == nullptr) return false;
    const StrategyView view{state, *profile, archetypes_, cards_, actor, nullptr};
    return view.has_role(card_id, role);
}

} // namespace ptcg::ai
