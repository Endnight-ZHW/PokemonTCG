#include "policies/policy_view.hpp"

namespace ptcg::ai {
namespace {
using namespace policy;
class GrassPolicy final : public DeckPolicy {
  public:
    const char *id() const noexcept override { return "grass_policy_v1"; }
    std::string stage(const PolicyView &view) const override {
        const auto evolved = view.count_role_board("evolution");
        if (view.own_prizes() <= 2 || view.opponent_prizes() <= 2)
            return "evolution_pressure";
        if (view.own_board().size() < 3)
            return "fill_evolution_board";
        return evolved < 3 ? "evolve_swarm" : "evolution_pressure";
    }
    double action_score(const PolicyView &view, const Value &action) const override {

        double score = generic_action_adjustment(view, action) + matchup_adjustment(view, action) +
                       stage_action_score(view, action) + candidate_score(view, action);
        const std::string kind = action_kind(action);
        const std::string card = action_card_id(action);
        const std::string target = action_target_card_id(action);
        const std::string target_slot = action_target_slot(action);
        const auto attack = attack_index(action);
        if (kind == "PLAY_BASIC" && card == "svg2-turt")
            score += view.weight("turtwig_setup");
        else if (kind == "EVOLVE")
            score += view.weight("evolved_board") * 0.65;
        else if (kind == "ATTACH_ENERGY" && target == "svg2-tort") {
            const Value *row = view.row_for_slot(target_slot);
            if (row != nullptr && view.energy_ids(row).size() >= 2 &&
                view.count_role_board("evolution") >= 3)
                score -= 150.0;
        } else if (kind == "PLAY_TRAINER" && card == "sv1-152")
            score += view.weight("rare_candy");
        else if (kind == "PLAY_TRAINER" && card == "svg2-gard")
            score += view.weight("gardenia");
        else if (kind == "USE_ABILITY" && card == "svg2-grot" &&
                 has_any_in_hand(view, {"sv2-young", "sv1-176", "sv1-180", "sv1-189"}))
            score -= 30.0;
        else if (kind == "DECLARE_ATTACK" && card == "svg2-tort") {
            if (attack == 0) {
                score += view.weight("torterra_evolution_pressure");
                score += view.weight("evolved_board") *
                         static_cast<double>(view.count_role_board("evolution"));
            } else if (attack == 1)
                score += view.weight("torterra_headbutt");
        } else if (kind == "USE_ABILITY" && card == "svg2-empo" && view.hand().empty() &&
                   view.count_card_discard(card) > 0)
            score += view.weight("empoleon_revival");
        else if (kind == "DECLARE_ATTACK" && card == "svg2-zaru" && attack == 0 && view.turn() <= 2)
            score += view.weight("zarude_opening_search");

        return std::clamp(score, -160.0, 160.0);
    }
    double keep_value(const PolicyView &view, const Value &choice,
                      const Value &option) const override {
        double score = generic_choice_keep_value(view, choice, option);
        const std::string card = option_card_id(option);
        const std::string surface = choice_surface(choice);
        if (surface != "card")
            return score;
        const bool turtwig = view.count_card_board("svg2-turt") > 0;
        const bool grotle = view.count_card_board("svg2-grot") > 0;
        const bool torterra = view.count_card_board("svg2-tort") > 0;
        const bool candy = view.count_card_hand("sv1-152") > 0;
        if (choice_mode(view, choice) == "benefit") {
            const auto turtwig_receivers =
                view.count_card_board("svg2-turt") + view.count_card_hand("svg2-turt");
            const auto grotle_receivers =
                view.count_card_board("svg2-grot") + view.count_card_hand("svg2-grot");
            const auto shroomish_receivers =
                view.count_card_board("svg2-shro") + view.count_card_hand("svg2-shro");
            // Search the missing base of a line instead of accumulating unusable evolutions.
            if ((card == "svg2-grot" && turtwig_receivers == 0) ||
                (card == "svg2-tort" && grotle_receivers == 0 &&
                 !(turtwig_receivers > 0 && candy)) ||
                (card == "svg2-brel" && shroomish_receivers == 0))
                score -= view.weight("unpaired_evolution", 180.0);
            if (view.bench_count() < 5 && ((card == "svg2-turt" && turtwig_receivers == 0 &&
                                            view.count_card_hand("svg2-grot") > 0) ||
                                           (card == "svg2-shro" && shroomish_receivers == 0 &&
                                            view.count_card_hand("svg2-brel") > 0)))
                score += view.weight("evolution_seed", 180.0);
            const auto held = remaining_hand_count_for_choice(view, choice, option, card);
            const auto live_receivers = card == "svg2-grot" ? turtwig_receivers
                                        : card == "svg2-tort"
                                            ? grotle_receivers + (candy ? turtwig_receivers : 0)
                                        : card == "svg2-brel" ? shroomish_receivers
                                                              : -1;
            if (live_receivers >= 0 && held > 0 && held >= live_receivers)
                score -= view.weight("unpaired_evolution", 180.0);
            if (view.bench_count() == 0 && view.count_role_hand("setup_basic") == 0 &&
                (card == "svg2-turt" || card == "svg2-shro"))
                score += view.weight("bootstrap_basic", 200.0);
        }
        if (card == "svg2-turt") {
            score += !(turtwig || grotle || torterra)
                         ? view.weight("evolved_board") + (view.bench_count() <= 0 ? 24.0 : 0.0)
                         : -8.0;
        } else if (card == "svg2-grot") {
            const auto receivers = view.count_card_board("svg2-turt");
            const auto supply = remaining_hand_count_for_choice(view, choice, option, card);
            score += receivers > supply ? view.weight("evolved_board") * 1.25
                                        : -view.weight("evolve_core");
        } else if (card == "svg2-tort") {
            auto receivers = view.count_card_board("svg2-grot");
            if (candy)
                receivers += view.count_card_board("svg2-turt");
            const auto supply = remaining_hand_count_for_choice(view, choice, option, card);
            if (supply >= receivers)
                score -= view.weight("evolve_core") * 1.25;
            else if (grotle)
                score += view.weight("evolve_core") * 0.75;
            else if (turtwig && candy)
                score += view.weight("evolve_core") * 0.55;
            else
                score -= view.weight("evolve_core");
        } else if (card == "svg2-gard")
            score += view.weight("gardenia");
        if (card == "svg2-turt" || card == "svg2-grot" || card == "svg2-tort") {
            score -=
                static_cast<double>(remaining_hand_count_for_choice(view, choice, option, card)) *
                35.0;
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
            static_cast<double>(view.count_role_board("evolution")) * view.weight("evolved_board");
        // The first live line opens repeatable search and next-turn Torterra.
        // Retain that value after evolving the engine into its attacker.
        if (view.count_card_board("svg2-grot") + view.count_card_board("svg2-tort") > 0)
            score += view.weight("first_evolution_line", 120.0);

        return std::clamp(score, -400.0, 400.0);
    }
    double position_value(const PolicyView &view, const PositionFeatures &facts) const override {
        return evaluate_position(*this, view, facts, 0.65);
    }
};
} // namespace
std::shared_ptr<const DeckPolicy> make_grass_policy() { return std::make_shared<GrassPolicy>(); }
} // namespace ptcg::ai
