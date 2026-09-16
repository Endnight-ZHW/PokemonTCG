#include "policies/policy_view.hpp"

namespace ptcg::ai {
namespace {
using namespace policy;
class DarknessPolicy final : public DeckPolicy {
  public:
    const char *id() const noexcept override { return "darkness_policy_v1"; }
    std::string stage(const PolicyView &view) const override {
        if (view.count_card_board("svd-mabosstiff-ex") <= 0 ||
            view.count_card_board("svd-dodrio") <= 0)
            return "build_dual_lines";
        return view.damage_on_card("svd-dodrio") < 20 ? "prime_damage_engine" : "pride_finish";
    }
    double action_score(const PolicyView &view, const Value &action) const override {

        double score = generic_action_adjustment(view, action) + matchup_adjustment(view, action) +
                       stage_action_score(view, action) + candidate_score(view, action);
        const std::string kind = action_kind(action);
        const std::string card = action_card_id(action);
        const std::string target = action_target_card_id(action);
        const std::string target_slot = action_target_slot(action);
        const auto attack = attack_index(action);
        if (kind == "PLAY_TRAINER" && card == "svd-dark-patch") {
            const auto count = view.count_card_discard("sv1-ener-7");
            score += count <= 0 ? -view.weight("dark_patch") * 2.0
                                : static_cast<double>(std::min<std::int64_t>(count, 2)) *
                                      view.weight("dark_patch") * 0.5;
        } else if (kind == "USE_ABILITY" && card == "svd-dodrio") {
            const auto hp = view.card_hp(card);
            const auto after = view.damage_on_card(card) + 10;
            if (hp > 0 && after >= hp)
                score -= view.weight("dodrio_safety_penalty") * 2.0;
            else if (hp > 0 && hp - after <= 20)
                score -= view.weight("dodrio_safety_penalty");
            else
                score += view.weight("damaged_dodrio");
        } else if (kind == "EVOLVE" && card == "svd-dodrio")
            score += view.weight("damaged_dodrio");
        else if (kind == "EVOLVE" && card == "svd-mabosstiff-ex")
            score += view.weight("mabosstiff_evolution");
        else if (kind == "DECLARE_ATTACK" && card == "svd-mabosstiff-ex") {
            if (attack == 0)
                score += view.weight("mabosstiff_intimidate");
            else if (attack == 1 && view.own_bench_damaged())
                score += view.weight("mabosstiff_pride");
        }

        return std::clamp(score, -160.0, 160.0);
    }
    double keep_value(const PolicyView &view, const Value &choice,
                      const Value &option) const override {
        double score = generic_choice_keep_value(view, choice, option);
        const std::string card = option_card_id(option);
        const std::string surface = choice_surface(choice);
        if (card == "svd-doduo" || card == "svd-dodrio")
            score += view.weight("damaged_dodrio");
        else if (card == "svd-maschiff" || card == "svd-mabosstiff-ex")
            score += view.weight("choice_primary");
        else if (card == "svd-dark-patch" && view.count_card_discard("sv1-ener-7") > 0)
            score += view.weight("dark_patch");

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
            static_cast<double>(view.damage_on_card("svd-dodrio")) * view.weight("damage_engine");
        if (view.count_card_discard("sv1-ener-7") > 0)
            score += view.weight("dark_patch");

        return std::clamp(score, -400.0, 400.0);
    }
    double position_value(const PolicyView &view, const PositionFeatures &facts) const override {
        return evaluate_position(*this, view, facts, 0.65);
    }
};
} // namespace
std::shared_ptr<const DeckPolicy> make_darkness_policy() {
    return std::make_shared<DarknessPolicy>();
}
} // namespace ptcg::ai
