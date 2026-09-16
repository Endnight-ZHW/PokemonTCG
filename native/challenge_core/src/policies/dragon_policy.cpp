#include "policies/policy_view.hpp"

namespace ptcg::ai {
namespace {
using namespace policy;
bool balanced_altaria(const PolicyView &view) {
    for (const Value *pokemon : view.own_board()) {
        if (string_field(*pokemon, "card_id") != "svg-alt")
            continue;
        const auto &energy = view.energy_ids(pokemon);
        if (std::any_of(energy.begin(), energy.end(),
                        [](const Value &v) { return v.string_or() == "sv1-ener-3"; }) &&
            std::any_of(energy.begin(), energy.end(),
                        [](const Value &v) { return v.string_or() == "sv1-ener-8"; }))
            return true;
    }
    return false;
}
class DragonPolicy final : public DeckPolicy {
  public:
    const char *id() const noexcept override { return "dragon_policy_v1"; }
    std::string stage(const PolicyView &view) const override {
        if (view.count_card_board("svg-alt") <= 0)
            return "build_healing_core";
        return balanced_altaria(view) ? "healing_lock" : "balance_energy";
    }
    double action_score(const PolicyView &view, const Value &action) const override {

        double score = generic_action_adjustment(view, action) + matchup_adjustment(view, action) +
                       stage_action_score(view, action) + candidate_score(view, action);
        const std::string kind = action_kind(action);
        const std::string card = action_card_id(action);
        const std::string target = action_target_card_id(action);
        const std::string target_slot = action_target_slot(action);
        const auto attack = attack_index(action);
        if (kind == "EVOLVE" && card == "svg-alt")
            score += view.weight("altaria_lock");
        else if (kind == "USE_ABILITY" && card == "svg-alt")
            score += static_cast<double>(view.own_damage_total()) * view.weight("healing");
        else if (kind == "PLAY_TRAINER" && (card == "svf-potion" || card == "svg-chef"))
            score += static_cast<double>(view.own_damage_total()) * view.weight("healing");
        else if (kind == "ATTACH_ENERGY" && target == "svg-alt") {
            const Value *row = view.row_for_slot(target_slot);
            const auto &ids = view.energy_ids(row);
            const bool present = std::any_of(
                ids.begin(), ids.end(), [&card](const Value &v) { return v.string_or() == card; });
            if ((card == "sv1-ener-3" || card == "sv1-ener-8") && !present)
                score += view.weight("dual_energy_balance");
        } else if (kind == "DECLARE_ATTACK" && card == "svg-ceti") {
            if (attack == 0)
                score += view.weight("cetitan_headbutt");
            else if (attack == 1) {
                score += view.weight("cetitan_sweeping");
                score -= static_cast<double>(view.damage_on_card(card)) *
                         view.weight("cetitan_damage_penalty");
            }
        } else if (kind == "DECLARE_ATTACK" && card == "svg-milt" && attack == 0 &&
                   view.card_healed(card))
            score += view.weight("miltank_healed_attack");

        return std::clamp(score, -160.0, 160.0);
    }
    double keep_value(const PolicyView &view, const Value &choice,
                      const Value &option) const override {
        double score = generic_choice_keep_value(view, choice, option);
        const std::string card = option_card_id(option);
        const std::string surface = choice_surface(choice);
        if (surface != "card")
            return score;
        if (card == "svg-swa") {
            score += view.weight("altaria_lock") *
                     (view.count_card_board("svg-swa") <= 0 ? 0.45 : -0.25);
        } else if (card == "svg-alt") {
            score +=
                view.weight("altaria_lock") * (view.count_card_board("svg-swa") > 0 ? 0.65 : -0.5);
        } else if ((card == "svf-potion" || card == "svg-chef") && view.own_damage_total() > 0) {
            score += static_cast<double>(view.own_damage_total()) * view.weight("healing");
        }
        if (card == "svg-swa" || card == "svg-alt") {
            score -=
                static_cast<double>(remaining_hand_count_for_choice(view, choice, option, card)) *
                35.0;
        } else if ((card == "sv1-ener-3" || card == "sv1-ener-8") &&
                   plan_stage(view) == "balance_energy" && view.count_card_hand(card) <= 1) {
            score += view.weight("dual_energy_balance") * 2.0;
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
            static_cast<double>(view.count_card_board("svg-alt")) * view.weight("altaria_lock");
        for (const Value *pokemon : view.own_board()) {
            if (string_field(*pokemon, "card_id") != "svg-alt")
                continue;
            const auto &energy = view.energy_ids(pokemon);
            if (std::any_of(energy.begin(), energy.end(),
                            [](const Value &v) { return v.string_or() == "sv1-ener-3"; }) &&
                std::any_of(energy.begin(), energy.end(),
                            [](const Value &v) { return v.string_or() == "sv1-ener-8"; })) {
                score += view.weight("dual_energy_balance") * 1.5;
            }
        }

        return std::clamp(score, -400.0, 400.0);
    }
    double position_value(const PolicyView &view, const PositionFeatures &facts) const override {
        return evaluate_position(*this, view, facts, 0.65);
    }
};
} // namespace
std::shared_ptr<const DeckPolicy> make_dragon_policy() {
    return std::make_shared<DragonPolicy>();
}
} // namespace ptcg::ai
