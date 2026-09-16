#include "policies/policy_view.hpp"

namespace ptcg::ai {
namespace {
using namespace policy;
class SteelPolicy final : public DeckPolicy {
  public:
    const char *id() const noexcept override { return "steel_policy_v1"; }
    std::string stage(const PolicyView &view) const override {
        if (view.count_card_board("svm-bronzor") <= 0 && view.count_card_board("svm-bronzong") <= 0)
            return "build_metal_board";
        return view.count_card_board("svm-bronzong") <= 0 ? "enable_transfer" : "fortress_pressure";
    }
    double action_score(const PolicyView &view, const Value &action) const override {

        double score = generic_action_adjustment(view, action) + matchup_adjustment(view, action) +
                       stage_action_score(view, action) + candidate_score(view, action);
        const std::string kind = action_kind(action);
        const std::string card = action_card_id(action);
        const std::string target = action_target_card_id(action);
        const std::string target_slot = action_target_slot(action);
        const auto attack = attack_index(action);
        if (kind == "EVOLVE" && card == "svm-bronzong")
            score += view.weight("metal_transfer");
        else if (kind == "USE_ABILITY" && card == "svm-bronzong")
            score += view.weight("metal_transfer");
        else if (kind == "DECLARE_ATTACK" && card == "svm-zamazenta" &&
                 view.own_knockout_last_turn())
            score += view.weight("revenge");
        else if (kind == "DECLARE_ATTACK" && card == "svm-zacian") {
            if (attack == 0)
                score +=
                    static_cast<double>(view.bench_count()) * view.weight("zacian_battle_legion");
            else if (attack == 1)
                score += view.weight("zacian_blade");
        } else if (kind == "ATTACH_ENERGY" && target == "svm-orthworm" && card == "sv1-ener-8" &&
                   view.energy_id_count(target, card) == 2)
            score += view.weight("orthworm_threshold");
        else if (kind == "PLAY_BASIC" && view.has_role(card, "primary_attacker"))
            score += view.weight("metal_board") * static_cast<double>(view.own_board().size() + 1);

        return std::clamp(score, -160.0, 160.0);
    }
    double keep_value(const PolicyView &view, const Value &choice,
                      const Value &option) const override {
        double score = generic_choice_keep_value(view, choice, option);
        const std::string card = option_card_id(option);
        const std::string surface = choice_surface(choice);
        if (card == "svm-bronzor" || card == "svm-bronzong")
            score += view.weight("metal_transfer");
        else if (card == "svm-zacian" || card == "svm-zamazenta" || card == "svm-orthworm")
            score += view.weight("metal_board");

        return score;
    }
    double discard_value(const PolicyView &view, const Value &option) const override {
        return view.has_role(option_card_id(option), "discard_synergy")
                   ? view.weight("discard_synergy")
                   : 0.0;
    }
    double state_score(const PolicyView &view) const override {
        double score = generic_state_adjustment(view) + stage_state_score(view);
        score += static_cast<double>(view.count_card_board("svm-bronzong")) *
                 view.weight("metal_transfer");
        score += static_cast<double>(view.own_board().size()) * view.weight("metal_board");

        return std::clamp(score, -400.0, 400.0);
    }
    double position_value(const PolicyView &view, const PositionFeatures &facts) const override {
        return evaluate_position(*this, view, facts, 0.65);
    }
};
} // namespace
std::shared_ptr<const DeckPolicy> make_steel_policy() {
    return std::make_shared<SteelPolicy>();
}
} // namespace ptcg::ai
