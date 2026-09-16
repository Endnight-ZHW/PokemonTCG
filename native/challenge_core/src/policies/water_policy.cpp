#include "policies/policy_view.hpp"
#include "card_evaluation_detail.hpp"

namespace ptcg::ai {
namespace {
using namespace policy;
using namespace card_evaluation;
bool has_public_tatsugiri_acceleration_target(const Value &state, std::int32_t actor,
                                              const Value &cards) {
    for (const Value &pokemon : array_field(player(state, actor), "bench")) {
        if (pokemon.is_object() && is_basic_pokemon(cards, string_field(pokemon, "card_id")) &&
            best_missing(cards, &pokemon) > 0)
            return true;
    }
    return false;
}
double starmie_torrent_followup_value(const RulesSession &position, const Value &state,
                                      std::int32_t actor, const std::string &source_slot,
                                      const Value &cards) {
    const Value *target = active(state, 1 - actor);
    if (target == nullptr)
        return 0.0;
    const Value &owner = player(state, actor);
    const Value *attacker = active(state, actor);
    std::string attacker_slot = "active";
    if (attacker == nullptr || string_field(*attacker, "card_id") != "sv2-grex") {
        attacker = nullptr;
        if (source_slot != "active")
            return 0.0;
        const auto &bench = array_field(owner, "bench");
        for (std::size_t index = 0; index < bench.size(); ++index) {
            if (bench[index].is_object() && string_field(bench[index], "card_id") == "sv2-grex") {
                attacker = &bench[index];
                attacker_slot = "bench_" + std::to_string(index);
                break;
            }
        }
    }
    if (attacker == nullptr)
        return 0.0;
    const Value *definition = card(cards, "sv2-grex");
    const auto &attacks =
        definition == nullptr ? Value::Array{} : array_field(*definition, "attacks");
    if (attacks.size() <= 1 ||
        missing_energy(cards, *attacker, array_field(attacks[1], "cost")) > 0) {
        return 0.0;
    }
    const std::int64_t before_damage =
        estimated_damage_for_pokemon(position, state, actor, *attacker, attacker_slot, 1, cards);
    const std::int64_t before_hp = position.pokemon_current_hp(*target);
    constexpr std::int64_t added_counters = 2;
    Value simulation = state;
    Value *players = simulation.find("players");
    if (players == nullptr || !players->is_array() ||
        static_cast<std::size_t>(1 - actor) >= players->as_array().size()) {
        return 0.0;
    }
    Value &opponent = players->as_array()[static_cast<std::size_t>(1 - actor)];
    Value *simulated_target = opponent.find("active");
    if (simulated_target == nullptr || !simulated_target->is_object())
        return 0.0;
    (*simulated_target)["damage_counters"] =
        Value(integer_field(*simulated_target, "damage_counters") + added_counters);
    const Value *simulated_attacker = pokemon_at(player(simulation, actor), attacker_slot);
    if (simulated_attacker == nullptr)
        return 0.0;
    const std::int64_t after_damage = estimated_damage_for_pokemon(
        position, simulation, actor, *simulated_attacker, attacker_slot, 1, cards);
    const std::int64_t after_hp = position.pokemon_current_hp(*simulated_target);
    double bonus =
        static_cast<double>(std::max<std::int64_t>(0, after_damage - before_damage)) * 3.0;
    if (before_damage < before_hp && after_damage >= after_hp) {
        const Value *target_definition = card(cards, string_field(*target, "card_id"));
        bonus += 1050.0 +
                 static_cast<double>(target_definition == nullptr
                                         ? 1
                                         : integer_field(*target_definition, "prize_value", 1)) *
                     360.0;
    }
    return bonus;
}
double water_energy_bonus(const RulesSession &position, const Value &state, std::int32_t actor,
                          const Value &pokemon, const std::string &slot,
                          const std::string &energy_card_id, const Value &cards) {
    const std::string pokemon_id = string_field(pokemon, "card_id");
    const Value *definition = card(cards, pokemon_id);
    if (!definition)
        return 0;
    const auto &attacks = array_field(*definition, "attacks");
    std::int64_t missing = 100, high_progress = 0;
    for (const auto &attack : attacks) {
        const auto before = missing_energy(cards, pokemon, array_field(attack, "cost"));
        const auto after = missing_energy(cards, pokemon_with_extra_energy(pokemon, energy_card_id),
                                          array_field(attack, "cost"));
        missing = std::min(missing, before);
        if (before > after)
            high_progress = 1;
    }
    double bonus = 0;
    if (pokemon_id == "sv2-grex" && energy_type_count(cards, &pokemon, "Water") >= 2 &&
        missing == 0 && high_progress == 0)
        bonus -= 480.0;

    if (pokemon_id == "sv2-keldeo" && bench_count(player(state, actor)) >= 3) {
        const auto &attacks = array_field(*definition, "attacks");
        if (attacks.size() > 1) {
            const auto &cost = array_field(attacks[1], "cost");
            const std::int64_t before = missing_energy(cards, pokemon, cost);
            const Value probe = pokemon_with_extra_energy(pokemon, energy_card_id);
            const std::int64_t after = missing_energy(cards, probe, cost);
            if (before == 1 && after == 0)
                bonus += 190.0;
        }
    }

    if (slot == "active" && pokemon_id == "sv2-tatsu" && bench_count(player(state, actor)) > 0) {
        const auto &attacks = array_field(*definition, "attacks");
        if (!attacks.empty()) {
            const auto &cost = array_field(attacks.front(), "cost");
            const std::int64_t before = missing_energy(cards, pokemon, cost);
            const Value probe = pokemon_with_extra_energy(pokemon, energy_card_id);
            const std::int64_t after = missing_energy(cards, probe, cost);
            if (before == 1 && after == 0 &&
                has_public_tatsugiri_acceleration_target(state, actor, cards))
                bonus += 280.0;
        }
    }
    return bonus;
}

bool water_needs_froakie(const PolicyView &view) {
    return view.card_active("sv2-grex") && view.damage_on_card("sv2-grex") > 0 &&
           view.count_card_board("sv2-38") <= 0 && view.count_card_board("sv2-39") <= 0 &&
           view.count_card_board("sv2-grex") <= 1;
}
class WaterPolicy final : public DeckPolicy {
  public:
    bool preserve_best_action() const noexcept override { return false; }
    bool prefer_first() const noexcept override { return false; }
    double action_bonus(const RulesSession &position, std::int32_t actor, const Value &action,
                        const Value &cards) const override {
        const auto &state = position.search_state();
        const auto &owner = player(state, actor);
        const auto kind = string_field(action, "kind");
        const auto id = policy::action_card_id(action);
        const auto slot = action_target_slot(action);
        double bonus = 0;
        if (kind == "USE_ABILITY" && id == "sv2-starm")
            bonus += starmie_torrent_followup_value(position, state, actor,
                                                    action_source_slot(action), cards) *
                     0.75;
        if (kind == "PLAY_BASIC" && slot == "active" &&
            actor != integer_field(state, "first_player_idx")) {
            if (id == "sv2-tatsu")
                bonus += 240;
            else if (id == "sv2-staryu" && array_contains(array_field(owner, "hand"), "sv2-tatsu"))
                bonus -= 180;
        }
        if (kind == "ATTACH_ENERGY") {
            const auto *pokemon = pokemon_at(owner, slot);
            if (pokemon)
                bonus += water_energy_bonus(position, state, actor, *pokemon, slot, id, cards);
        }
        return bonus;
    }
    double choice_bonus(const RulesSession &position, std::int32_t actor, const Value &choice,
                        const Value &option, const Value &cards) const override {
        const auto &state = position.search_state();
        const auto *reference = field(option, "ref");
        if (!reference)
            return 0;
        const auto *presentation = field(choice, "presentation");
        if (!presentation)
            return 0;
        const auto slot = string_field(*reference, "slot");
        if (string_field(*presentation, "purpose") == "place_counters_self_discard" &&
            string_field(*presentation, "source_card_id") == "sv2-starm" &&
            integer_field(*reference, "player", -1) == 1 - actor && slot == "active")
            return starmie_torrent_followup_value(
                position, state, actor, string_field(*presentation, "source_slot"), cards);
        const auto surface = choice_surface(choice);
        if (surface == "energy_target" && integer_field(*reference, "player", -1) == actor) {
            const auto *pokemon = pokemon_at(player(state, actor), slot);
            if (pokemon)
                return water_energy_bonus(
                    position, state, actor, *pokemon, slot,
                    string_field(*presentation, "energy_card_id", "sv1-ener-3"), cards);
        }
        return 0;
    }
    const char *id() const noexcept override { return "water_policy_v1"; }
    std::string stage(const PolicyView &view) const override {
        if (view.count_card_board("sv2-grex") <= 0)
            return "establish_board";
        return view.own_prizes() <= 2 || view.opponent_active_damage() > 0 ? "take_multi_prize"
                                                                           : "enable_shuriken";
    }
    double action_score(const PolicyView &view, const Value &action) const override {

        double score = generic_action_adjustment(view, action) + matchup_adjustment(view, action) +
                       stage_action_score(view, action) + candidate_score(view, action);
        const std::string kind = action_kind(action);
        const std::string card = action_card_id(action);
        const std::string target = action_target_card_id(action);
        const std::string target_slot = action_target_slot(action);
        const auto attack = attack_index(action);
        if (kind == "PLAY_BASIC" && card == "sv2-tatsu" && target_slot == "active" &&
            view.going_second()) {
            score += view.weight("tatsugiri_opening");
        } else if (kind == "PLAY_BASIC" && card == "sv2-staryu" && target_slot == "active" &&
                   view.turn() <= 1 && view.count_card_hand("sv2-tatsu") > 0 &&
                   view.going_second()) {
            score -= view.weight("staryu_opening_penalty");
        } else if (kind == "PLAY_BASIC" && card == "sv2-staryu" &&
                   view.count_card_board("sv2-staryu") + view.count_card_board("sv2-starm") > 0) {
            score -= view.weight("staryu_duplicate_penalty");
        } else if (kind == "PLAY_BASIC" && card == "sv2-38" &&
                   target_slot.rfind("bench_", 0) == 0) {
            score += view.weight("froakie_bench");
            if (water_needs_froakie(view))
                score += view.weight("froakie_backup_search");
        } else if (kind == "ATTACH_ENERGY" && target == "sv2-tatsu" &&
                   view.card_active("sv2-tatsu") && view.energy_count("sv2-tatsu") <= 0 &&
                   view.bench_count() > 0) {
            score += view.weight("tatsugiri_prepare_attachment");
        } else if (kind == "EVOLVE" && card == "sv2-grex")
            score += view.weight("greninja_attack");
        else if (kind == "PLAY_TRAINER" && card == "sv1-152" &&
                 view.count_card_board("sv2-38") > 0 && view.count_card_hand("sv2-grex") > 0) {
            score += view.weight("rare_candy_greninja");
        } else if (kind == "PLAY_TRAINER" && card == "sv2-cand")
            score += view.weight("candice");
        else if (kind == "DECLARE_ATTACK" && card == "sv2-grex") {
            score += view.weight("greninja_attack");
            if (attack == 0) {
                score += view.weight("greninja_shuriken");
                score += static_cast<double>(std::max<std::int64_t>(
                             1, static_cast<std::int64_t>(view.opponent_board().size()) - 1)) *
                         view.weight("bench_target_pressure") * 0.35;
            } else if (attack == 1) {
                score += view.weight("greninja_torrent");
                if (view.opponent_active_damage() > 0)
                    score += view.weight("bench_target_pressure");
            }
        } else if (kind == "DECLARE_ATTACK" && card == "sv2-tatsu" && attack == 0) {
            score += view.weight("tatsugiri_prepare");
            if (view.turn() <= 2)
                score += view.weight("tatsugiri_opening");
        } else if (kind == "USE_ABILITY" && card == "sv2-starm") {
            const bool ready =
                view.count_card_board("sv2-grex") > 0 && view.energy_count("sv2-grex") >= 2;
            const bool torrent = ready &&
                                 (view.card_active("sv2-grex") ||
                                  (view.card_active("sv2-starm") && view.bench_count() > 0)) &&
                                 view.opponent_active_damage() <= 0;
            score += torrent ? view.weight("starmie_comet_combo")
                             : -view.weight("starmie_material_cost");
            score -= static_cast<double>(view.energy_count(card)) *
                     view.weight("starmie_attachment_cost");
            if (view.card_active(card) && view.bench_count() <= 0)
                score -= view.weight("starmie_no_backup_penalty");
        }

        return std::clamp(score, -160.0, 160.0);
    }
    double keep_value(const PolicyView &view, const Value &choice,
                      const Value &option) const override {
        double score = generic_choice_keep_value(view, choice, option);
        const std::string card = option_card_id(option);
        const std::string surface = choice_surface(choice);
        if (surface != "card")
            return score;
        if (card == "sv2-38" || card == "sv2-39" || card == "sv2-grex") {
            score += view.weight("greninja_attack");
            if (card == "sv2-38" && water_needs_froakie(view)) {
                score += view.weight("froakie_backup_search");
            }
        } else if (card == "sv2-staryu") {
            score += view.weight("choice_engine");
            if (view.count_card_board("sv2-staryu") + view.count_card_board("sv2-starm") > 0) {
                score -= view.weight("staryu_duplicate_penalty");
            }
        } else if (card == "sv2-starm") {
            const bool executable =
                view.count_card_board("sv2-staryu") > 0 || view.count_card_hand("sv2-staryu") > 0;
            score += executable ? view.weight("choice_engine")
                                : -view.weight("starmie_unexecutable_penalty");
            if (view.count_card_board("sv2-starm") > 0 &&
                view.count_card_board("sv2-staryu") <= 0) {
                score -= view.weight("staryu_duplicate_penalty");
            }
        }

        return score;
    }
    double discard_value(const PolicyView &view, const Value &option) const override {
        return view.has_role(option_card_id(option), "discard_synergy")
                   ? view.weight("discard_synergy")
                   : 0.0;
    }
    double state_score(const PolicyView &view) const override {
        double score = generic_state_adjustment(view) + stage_state_score(view);
        score +=
            static_cast<double>(view.count_card_board("sv2-grex")) * view.weight("greninja_attack");
        score += (view.opponent_active_damage() > 0 ? 1.0 : 0.0) * view.weight("torrent_setup");
        score += static_cast<double>(std::min<std::int64_t>(2, view.energy_count("sv2-grex"))) *
                 view.weight("greninja_energy");

        return std::clamp(score, -400.0, 400.0);
    }
    double position_value(const PolicyView &view, const PositionFeatures &facts) const override {
        return evaluate_position(*this, view, facts, 0.65);
    }
};
} // namespace
std::shared_ptr<const DeckPolicy> make_water_policy() {
    return std::make_shared<WaterPolicy>();
}
} // namespace ptcg::ai
