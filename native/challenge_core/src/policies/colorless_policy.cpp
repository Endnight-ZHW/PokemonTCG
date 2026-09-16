#include "policies/policy_view.hpp"

namespace ptcg::ai {
namespace {
using namespace policy;
class ColorlessPolicy final : public DeckPolicy {
  public:
    const char *id() const noexcept override { return "colorless_policy_v1"; }
    std::string stage(const PolicyView &view) const override {
        if (view.count_card_board("svi-maus") <= 0)
            return "fill_bench";
        return view.hand().size() < 6 ? "grow_hand" : "family_pressure";
    }
    double action_score(const PolicyView &view, const Value &action) const override {

        double score = generic_action_adjustment(view, action) + matchup_adjustment(view, action) +
                       stage_action_score(view, action) + candidate_score(view, action);
        const std::string kind = action_kind(action);
        const std::string card = action_card_id(action);
        const std::string target = action_target_card_id(action);
        const std::string target_slot = action_target_slot(action);
        const auto attack = attack_index(action);
        if (kind == "EVOLVE" && card == "svi-maus")
            score += view.weight("family_board") *
                     static_cast<double>(view.count_role_board("family") + 1);
        else if (kind == "ATTACH_ENERGY" && view.has_role(card, "energy") && target == "svi-maus")
            score += view.weight("special_energy");
        else if (kind == "PLAY_TRAINER" && card == "sv1-189" && view.hand().size() >= 6)
            score -= view.weight("hand_preservation");
        else if (kind == "DECLARE_ATTACK" && card == "svi-maus")
            score +=
                view.weight("family_board") * static_cast<double>(view.count_role_board("family"));
        else if (kind == "DECLARE_ATTACK" && card == "svi-ambi") {
            if (attack == 0)
                score += view.weight("ambipom_call");
            else if (attack == 1)
                score += static_cast<double>(std::min<std::size_t>(view.hand().size(), 8)) *
                         view.weight("ambipom_hand_attack");
        } else if (kind == "DECLARE_ATTACK" && card == "svi-gree") {
            if (attack == 0)
                score += view.weight("greedent_call");
            else if (attack == 1)
                score += view.hand().size() >= 5 ? view.weight("greedent_dump")
                                                 : -view.weight("greedent_dump");
        }

        return std::clamp(score, -160.0, 160.0);
    }
    double keep_value(const PolicyView &view, const Value &choice,
                      const Value &option) const override {
        double score = generic_choice_keep_value(view, choice, option);
        const std::string card = option_card_id(option);
        const std::string surface = choice_surface(choice);
        if (card == "svi-tand" || card == "svi-maus")
            score += view.weight("family_board") * 2.0;
        else if (view.has_role(card, "energy"))
            score += view.weight("special_energy");

        return score;
    }
    double discard_value(const PolicyView &view, const Value &option) const override {
        return view.has_role(option_card_id(option), "discard_synergy")
                   ? view.weight("discard_synergy")
                   : 0.0;
    }
    double state_score(const PolicyView &view) const override {
        double score = generic_state_adjustment(view) + stage_state_score(view);
        score += static_cast<double>(view.count_role_board("family")) * view.weight("family_board");
        if (view.hand().size() >= 6)
            score += view.weight("hand_preservation");

        return std::clamp(score, -400.0, 400.0);
    }
    double position_value(const PolicyView &view, const PositionFeatures &facts) const override {
        return evaluate_position(*this, view, facts, 0.8);
    }
};
} // namespace
std::shared_ptr<const DeckPolicy> make_colorless_policy() {
    return std::make_shared<ColorlessPolicy>();
}
} // namespace ptcg::ai
