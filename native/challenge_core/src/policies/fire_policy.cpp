#include "policies/policy_view.hpp"

namespace ptcg::ai {
namespace {
using namespace policy;
class FirePolicy final : public DeckPolicy {
  public:
    bool preserve_best_action() const noexcept override { return false; }
    const char *id() const noexcept override { return "fire_policy_v1"; }
    std::string stage(const PolicyView &view) const override {
        if (view.opponent_prizes() <= 2 || view.own_prizes() <= 2)
            return "closeout";
        return view.count_card_board("svi-infr") <= 0 ? "establish_chain" : "ignite_engine";
    }
    double action_score(const PolicyView &view, const Value &action) const override {

        double score = generic_action_adjustment(view, action) + matchup_adjustment(view, action) +
                       stage_action_score(view, action) + candidate_score(view, action);
        const std::string kind = action_kind(action);
        const std::string card = action_card_id(action);
        const std::string target = action_target_card_id(action);
        const std::string target_slot = action_target_slot(action);
        const auto attack = attack_index(action);
        if (kind == "PLAY_BASIC" && target_slot == "active" && view.turn() <= 1 &&
            view.count_card_hand("svi-chiy") > 0 && view.count_card_hand("svi-ente") > 0) {
            if (card == "svi-chiy")
                score += view.weight("chiyu_opening");
            else if (card == "svi-ente")
                score -= view.weight("chiyu_opening");
        } else if (kind == "PLAY_BASIC" && card == "svi-chim" &&
                   target_slot.rfind("bench_", 0) == 0)
            score += view.weight("chimchar_bench");
        else if (kind == "EVOLVE" && card == "svi-infr")
            score += view.weight("fire_chain");
        else if (kind == "PLAY_TRAINER" && card == "sv1-152")
            score += view.weight("rare_candy");
        else if (kind == "PLAY_TRAINER" &&
                 (card == "svi-erec" || card == "svi-mela" || card == "sv3-134")) {
            score += static_cast<double>(
                         std::min<std::int64_t>(view.count_card_discard("sv1-ener-2"), 3)) *
                     view.weight("recycle_energy") * 0.25;
        } else if (kind == "DECLARE_ATTACK" && card == "svi-infr") {
            score += view.weight("infernape_attack");
            if (attack == 0)
                score += view.weight("infernape_spiral");
            else if (attack == 1) {
                score += view.weight("infernape_burning_kick");
                score -= static_cast<double>(view.energy_count(card)) *
                         view.weight("burning_kick_energy_cost");
            }
        } else if (kind == "DECLARE_ATTACK" && card == "svi-sqwk" && attack == 0) {
            score += view.weight("squawk_call_family");
            if (view.turn() <= 2)
                score += view.weight("squawk_opening");
        } else if (kind == "DECLARE_ATTACK" && card == "svi-chiy" && attack == 0) {
            score += static_cast<double>(
                         std::min<std::int64_t>(view.count_card_discard("sv1-ener-2"), 2)) *
                     view.weight("chiyu_acceleration");
        } else if (kind == "DECLARE_ATTACK" && card == "svi-chiy" && attack == 1 &&
                   view.own_knockout_last_turn())
            score += view.weight("chiyu_revenge");

        return std::clamp(score, -160.0, 160.0);
    }
    double keep_value(const PolicyView &view, const Value &choice,
                      const Value &option) const override {
        double score = generic_choice_keep_value(view, choice, option);
        const std::string card = option_card_id(option);
        const std::string surface = choice_surface(choice);
        const double chain = view.weight("fire_chain");
        if (view.bench_count() == 0 && view.card_active("svi-chim") &&
            choice_mode(view, choice) == "benefit" && surface == "card") {
            if (view.has_role(card, "setup_basic"))
                score += 240.0;
            else if (view.has_role(card, "evolution"))
                score -= 240.0;
        }
        const bool has_chimchar = view.count_card_board("svi-chim") > 0;
        const bool has_monferno =
            view.count_card_board("svi-monf") > 0 || view.count_card_hand("svi-monf") > 0;
        const bool has_candy = view.count_card_hand("sv1-152") > 0;
        if (card == "svi-chim")
            score += chain;
        else if (card == "svi-monf" && has_chimchar && !has_monferno)
            score += chain;
        else if (card == "svi-infr") {
            score += has_monferno || (has_chimchar && has_candy) ? chain : -chain;
        }
        if ((card == "svi-monf" || card == "svi-infr") &&
            remaining_hand_count_for_choice(view, choice, option, card) > 0) {
            score -= chain;
        } else if ((card == "svi-erec" || card == "svi-mela") &&
                   view.count_card_discard("sv1-ener-2") > 0) {
            score += view.weight("recycle_energy");
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
        score += static_cast<double>(view.count_card_board("svi-infr")) * view.weight("fire_chain");
        score += static_cast<double>(view.count_card_discard("sv1-ener-2")) *
                 view.weight("recycle_energy") * 0.15;

        return std::clamp(score, -400.0, 400.0);
    }
    double position_value(const PolicyView &view, const PositionFeatures &facts) const override {
        return evaluate_position(*this, view, facts, 0.65);
    }
};
} // namespace
std::shared_ptr<const DeckPolicy> make_fire_policy() {
    return std::make_shared<FirePolicy>();
}
} // namespace ptcg::ai
