#include "policies/policy_view.hpp"

namespace ptcg::ai {
namespace {
using namespace policy;
class FightingPolicy final : public DeckPolicy {
  public:
    const char *id() const noexcept override { return "fighting_policy_v1"; }
    std::string stage(const PolicyView &view) const override {
        if (view.count_card_board("svf-luca") <= 0)
            return "build_lucario";
        return view.energy_count("svf-luca") < 2 ? "stack_fighting_energy" : "aura_burst";
    }
    double action_score(const PolicyView &view, const Value &action) const override {

        double score = generic_action_adjustment(view, action) + matchup_adjustment(view, action) +
                       stage_action_score(view, action) + candidate_score(view, action);
        const std::string kind = action_kind(action);
        const std::string card = action_card_id(action);
        const std::string target = action_target_card_id(action);
        const std::string target_slot = action_target_slot(action);
        const auto attack = attack_index(action);
        if (kind == "EVOLVE" && card == "svf-luca")
            score += view.weight("lucario_engine");
        else if (kind == "USE_ABILITY" && card == "svf-luca") {
            const Value *source = view.row_for_slot(action_source_slot(action));
            const auto hp = view.card_hp(card);
            const auto after = PolicyView::damage(source) + 20;
            if (hp > 0 && after >= hp)
                score -= view.weight("lucario_self_ko_penalty");
            else if (hp > 0 && hp - after <= 40)
                score -= view.weight("lucario_low_hp_penalty");
            else
                score += view.weight("lucario_engine");
        } else if (kind == "DECLARE_ATTACK" && card == "svf-luca")
            score += static_cast<double>(view.energy_ids(view.active(view.actor)).size()) *
                     view.weight("fighting_stack");
        else if (kind == "DECLARE_ATTACK" && card == "svf-klea") {
            score += view.weight("kleavor");
            if (attack == 0)
                score += view.weight("kleavor_guillotine");
            else if (attack == 1)
                score += view.weight("kleavor_rampage");
        }

        return std::clamp(score, -160.0, 160.0);
    }
    double keep_value(const PolicyView &view, const Value &choice,
                      const Value &option) const override {
        double score = generic_choice_keep_value(view, choice, option);
        const std::string card = option_card_id(option);
        const std::string surface = choice_surface(choice);
        if (card == "svf-rio" || card == "svf-luca")
            score += view.weight("lucario_engine");
        else if (card == "svf-scyt" || card == "svf-klea")
            score += view.weight("kleavor");

        if (card == "svf-ensw2")
            score += view.weight("energy_switch_reserve");
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
            static_cast<double>(view.count_card_board("svf-luca")) * view.weight("lucario_engine");
        // Each Lucario is a separate charge-and-discard engine. A second
        // powered attacker must not disappear behind the fullest one's count.
        for (const Value *pokemon : view.own_board()) {
            if (string_field(*pokemon, "card_id") != "svf-luca")
                continue;
            const auto energy = view.energy_ids(pokemon).size();
            score += static_cast<double>(energy) * view.weight("fighting_stack");
        }
        score += static_cast<double>(view.count_card_hand("svf-ensw2")) *
                 view.weight("energy_switch_reserve");

        return std::clamp(score, -400.0, 400.0);
    }
    double position_value(const PolicyView &view, const PositionFeatures &facts) const override {
        return evaluate_position(*this, view, facts, 0.65);
    }
};
} // namespace
std::shared_ptr<const DeckPolicy> make_fighting_policy() {
    return std::make_shared<FightingPolicy>();
}
} // namespace ptcg::ai
