#include "policies/policy_view.hpp"

namespace ptcg::ai {
namespace {
using namespace policy;

class Happy4Policy final : public DeckPolicy {
    std::string archetype_;
    std::string id_;
  public:
    explicit Happy4Policy(std::string archetype)
        : archetype_(std::move(archetype)), id_("happy4_" + archetype_ + "_policy_v1") {}
    const char *id() const noexcept override { return id_.c_str(); }
    std::string stage(const PolicyView &view) const override { return generic_plan_stage(view); }

    double action_score(const PolicyView &view, const Value &action) const override {
        double score = generic_action_adjustment(view, action) + matchup_adjustment(view, action)
            + stage_action_score(view, action) + candidate_score(view, action);
        const auto kind = action_kind(action);
        const auto card = action_card_id(action);
        const auto target = action_target_card_id(action);
        const auto attack = attack_index(action);
        if (archetype_ == "decidueye") {
            if (kind == "EVOLVE" && view.has_role(card, "evolution_core")) score += 45;
            // A second attachment must not consume the only Grass card needed
            // to pay Power Shot from the hand.
            if (kind == "ATTACH_ENERGY" && card == "sv1-ener-1"
                && view.count_card_hand(card) <= 1 && view.energy_count("csvh4-003") >= 1)
                score -= view.weight("energy_reserve", 100);
            if (kind == "DECLARE_ATTACK" && card == "csvh4-003") {
                if (attack == 1 && view.count_card_hand("sv1-ener-1") == 0) score -= 160;
                if (attack == 0 && view.hand().size() <= 2) score += 45;
            }
        } else if (archetype_ == "melmetal") {
            if ((kind == "EVOLVE" || kind == "USE_ABILITY") && card == "csvh4-017")
                score += view.weight("engine_setup", 55);
            if (kind == "ATTACH_ENERGY" && target == "csvh4-020") score += 24;
            if (kind == "DECLARE_ATTACK" && card == "csvh4-020" && attack == 0
                && view.energy_count(card) < 4) score += 45;
        } else if (archetype_ == "koraidon") {
            if (kind == "PLAY_BASIC" && view.has_role(card, "setup_basic"))
                score += view.weight("subtype_board", 28);
            if (kind == "PLAY_TRAINER" && card == "csvh4-046") score += 35;
        } else {
            if (kind == "PLAY_BASIC" && card == "csvh4-023"
                && action_target_slot(action) == "active" && view.turn() <= 1) score += 55;
            if (kind == "DECLARE_ATTACK" && card == "csvh4-023" && attack == 0
                && view.energy_count("csvh4-024") < 2) score += 40;
            if (kind == "DECLARE_ATTACK" && card == "csvh4-010" && attack == 0
                && view.opponent_active_damage() == 0) score += view.weight("spread_setup", 22);
        }
        return std::clamp(score, -160.0, 160.0);
    }

    double keep_value(const PolicyView &view, const Value &choice, const Value &option) const override {
        double score = generic_choice_keep_value(view, choice, option);
        const auto card = option_card_id(option);
        if (archetype_ == "decidueye" && card == "sv1-ener-1"
            && view.count_card_board("csvh4-003") > 0 && view.count_card_hand(card) <= 1)
            score += view.weight("energy_reserve", 100);
        if (archetype_ == "melmetal" && (card == "csvh4-016" || card == "csvh4-017")
            && view.count_card_board("csvh4-017") == 0) score += 55;
        if (archetype_ == "melmetal" && card == "csvh4-020") score += 24;
        if (archetype_ == "koraidon" && view.has_role(card, "setup_basic")) score += 20;
        if (archetype_ == "miraidon" && card == "csvh4-023"
            && view.count_card_board(card) == 0) score += 45;
        return score;
    }

    double discard_value(const PolicyView &view, const Value &option) const override {
        return view.has_role(option_card_id(option), "discard_synergy")
            ? view.weight("discard_synergy", 16) : 0;
    }
    double state_score(const PolicyView &view) const override {
        double score = generic_state_adjustment(view) + stage_state_score(view);
        if (archetype_ == "decidueye")
            score += 35 * view.count_card_board("csvh4-003")
                + (view.count_card_hand("sv1-ener-1") > 0 ? 25 : 0);
        else if (archetype_ == "melmetal") score += 55 * view.count_card_board("csvh4-017");
        else if (archetype_ == "koraidon") score += 28 * view.count_role_board("setup_basic");
        else score += 15 * view.count_card_board("csvh4-023") + 20 * view.count_card_board("csvh4-024");
        return std::clamp(score, -400.0, 400.0);
    }
    double position_value(const PolicyView &view, const PositionFeatures &facts) const override {
        return evaluate_position(*this, view, facts, 0.65);
    }
};
}
std::shared_ptr<const DeckPolicy> make_happy4_policy(const std::string &archetype) {
    return std::make_shared<Happy4Policy>(archetype);
}
}
