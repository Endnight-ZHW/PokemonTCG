#include "policies/policy_view.hpp"

namespace ptcg::ai {
namespace {
using namespace policy;
class LightningPolicy final : public DeckPolicy {
  public:
    const char *id() const noexcept override { return "lightning_policy_v1"; }
    std::string stage(const PolicyView &view) const override {
        if (view.own_prizes() <= 2)
            return "burst_finish";
        return view.count_card_board("svl-flaa2") <= 0 ? "charge_bench" : "prepare_pikachu";
    }
    double action_score(const PolicyView &view, const Value &action) const override {

        double score = generic_action_adjustment(view, action) + matchup_adjustment(view, action) +
                       stage_action_score(view, action) + candidate_score(view, action);
        const std::string kind = action_kind(action);
        const std::string card = action_card_id(action);
        const std::string target = action_target_card_id(action);
        const std::string target_slot = action_target_slot(action);
        const auto attack = attack_index(action);
        static const std::vector<std::string> front{"svl-thun", "svl-emol", "svl-chat", "svl-zera"};
        static const std::vector<std::string> engines{"svl-mare2", "svl-chin"};
        if (kind == "PLAY_BASIC" && target_slot == "active" && view.turn() <= 1) {
            if (std::find(front.begin(), front.end(), card) != front.end())
                score += view.weight("frontline_opening");
            else if (std::find(engines.begin(), engines.end(), card) != engines.end() &&
                     has_any_in_hand(view, front))
                score -= view.weight("bench_engine_active_penalty");
        } else if (kind == "PLAY_TRAINER" && card == "sv1-170")
            score += view.weight("generator");
        else if (kind == "EVOLVE" && card == "svl-flaa2")
            score += view.weight("flaaffy_engine");
        else if (kind == "USE_ABILITY" && card == "svl-flaa2")
            score += view.weight("flaaffy_engine");
        else if (kind == "DECLARE_ATTACK" && card == "svl-pikaex") {
            if (attack == 0)
                score += view.weight("pikachu_jab");
            else if (attack == 1) {
                score += view.weight("pikachu_strong_volt");
                const double scale = view.count_card_board("svl-flaa2") > 0 ? 0.35 : 1.0;
                score -= static_cast<double>(view.energy_count(card)) *
                         view.weight("strong_volt_energy_risk") * scale;
            }
        }

        return std::clamp(score, -160.0, 160.0);
    }
    double keep_value(const PolicyView &view, const Value &choice,
                      const Value &option) const override {
        double score = generic_choice_keep_value(view, choice, option);
        const std::string card = option_card_id(option);
        const std::string surface = choice_surface(choice);
        if (card == "svl-mare2" || card == "svl-flaa2")
            score += view.weight("flaaffy_engine");
        else if (card == "svl-pikaex")
            score += view.weight("pikachu_burst");

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
            static_cast<double>(view.count_card_board("svl-flaa2")) * view.weight("flaaffy_engine");
        if (view.energy_count("svl-pikaex") >= 3)
            score += view.weight("pikachu_burst");

        return std::clamp(score, -400.0, 400.0);
    }
    double position_value(const PolicyView &view, const PositionFeatures &facts) const override {
        return evaluate_position(*this, view, facts, 0.65);
    }
};
} // namespace
std::shared_ptr<const DeckPolicy> make_lightning_policy() {
    return std::make_shared<LightningPolicy>();
}
} // namespace ptcg::ai
