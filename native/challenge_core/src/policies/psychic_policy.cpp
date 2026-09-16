#include "card_evaluation_detail.hpp"
#include "policies/policy_view.hpp"
#include "ptcg_rules_session.hpp"

namespace ptcg::ai {
namespace {
using namespace policy;
bool houndstone_available(const PolicyView &view) {
    return view.count_card_board("sv1-104") > 0 || view.count_card_board("sv1-106") > 0 ||
           view.count_card_hand("sv1-104") > 0 || view.count_card_hand("sv1-106") > 0;
}
bool xatu_energy_finishes(const RulesSession &position, std::int32_t actor, const Value &option,
                          const Value &cards) {
    const auto *reference = field(option, "ref");
    if (!reference || string_field(*reference, "card_id") != "sv1-108")
        return false;
    const auto &state = position.search_state();
    if (integer_field(state, "turn_number") <= 1 &&
        integer_field(state, "first_player_idx") == actor)
        return false;
    static const Value empty = Value::make_object();
    const PolicyView view{state, empty, empty, cards, actor};
    const auto slot = string_field(*reference, "slot");
    const auto *pokemon = view.row_for_slot(slot);
    const auto *defender = view.active(1 - actor);
    if (!pokemon || !defender)
        return false;
    const auto &statuses = view.array(*pokemon, "status_conditions");
    for (const auto &status : statuses)
        if (status.string_or() == "ASLEEP" || status.string_or() == "PARALYZED" ||
            status.string_or() == "CONFUSED")
            return false;
    if (card_evaluation::modifier_kind(pokemon, "attack_lock") ||
        card_evaluation::modifier_kind(pokemon, "attack_gate_coin"))
        return false;
    const auto *target_card = card(cards, string_field(*defender, "card_id"));
    if (view.board(1 - actor).size() > 1 &&
        view.own_prizes() > (target_card ? integer_field(*target_card, "prize_value", 1) : 1))
        return false;
    const auto *definition = card(cards, "sv1-108");
    const auto probe = card_evaluation::pokemon_with_extra_energy(*pokemon, "sv1-ener-5");
    if (!definition || array_field(*definition, "attacks").empty() ||
        card_evaluation::missing_energy(
            cards, probe, array_field(array_field(*definition, "attacks")[0], "cost")) > 0 ||
        card_evaluation::estimated_damage_for_pokemon(
            position, state, actor, probe, slot, 0, cards) < position.pokemon_current_hp(*defender))
        return false;
    const auto legal = position.search_legal_action_candidates(actor);
    if (legal.is_array())
        for (const auto &action : legal.as_array())
            if ((action_kind(action) == "RETREAT" && action_target_slot(action) == slot) ||
                (action_kind(action) == "PLAY_TRAINER" && action_card_id(action) == "sv1-150"))
                return true;
    return false;
}
class PsychicPolicy final : public DeckPolicy {
  public:
    bool prefer_first() const noexcept override { return false; }
    double choice_bonus(const RulesSession &position, std::int32_t actor, const Value &choice,
                        const Value &option, const Value &cards) const override {
        if (string_field(choice, "request_type") == "distribute_energy" &&
            integer_field(choice, "max_select") == 3 &&
            bool_field(choice_presentation(choice), "same_target")) {
            static const Value empty = Value::make_object();
            const PolicyView view{position.search_state(), empty, empty, cards, actor};
            const auto id = option_card_id(option);
            const auto *reference = field(option, "ref");
            const auto slot = reference ? string_field(*reference, "slot") : std::string{};
            const auto *target = view.row_for_slot(slot);
            // Growth's three energies must share one target. Prepare a full
            // backup attack and keep the held manual energy for Cresselia.
            if (view.turn() == 2 && view.going_second() && view.card_active("sv1-113") &&
                view.energy_count("sv1-113") == 1 && view.count_card_hand("sv1-ener-5") > 0 &&
                slot.rfind("bench_", 0) == 0 && target && view.energy_ids(target).empty() &&
                (id == "sv1-111" || id == "sv1-112" || id == "sv1-109"))
                return 600.0;
        }
        if (string_field(choice, "request_type") == "select_own_bench_energy" &&
            xatu_energy_finishes(position, actor, option, cards))
            return 3000.0;
        if (string_field(choice, "request_type") != "arven")
            return 0;
        const auto &state = position.search_state();
        static const Value no_profile = Value::make_object();
        const PolicyView engine_view{state, no_profile, no_profile, cards, actor};
        // With a seed already in play, search the missing evolution instead of
        // adding another basic. Two payment cards must leave an energy for Xatu.
        if (option_card_id(option) == "sv1-153" && engine_view.count_card_board("sv1-107") > 0 &&
            engine_view.count_card_board("sv1-108") == 0 &&
            engine_view.count_card_hand("sv1-108") == 0 &&
            engine_view.count_card_hand("sv1-153") == 0 &&
            engine_view.count_card_hand("sv1-ener-5") > 0 && engine_view.hand().size() >= 3)
            return 900.0;
        if (option_card_id(option) != "sv1-150")
            return 0;
        if (string_field(state, "phase") != "MAIN" || integer_field(state, "turn_number") != 2 ||
            integer_field(state, "first_player_idx", -1) == actor)
            return 0;
        static const Value empty = Value::make_object();
        const PolicyView view{state, empty, empty, cards, actor};
        if (view.card_active("sv1-113") || !view.card_benched("sv1-113") ||
            view.count_card_hand("sv1-150") > 0)
            return 0;
        if (view.energy_count("sv1-113") == 0 &&
            (bool_field(view.own(), "energy_attached_this_turn") ||
             view.count_card_hand("sv1-ener-5") == 0))
            return 0;
        const Value legal = position.search_legal_action_candidates(actor);
        if (legal.is_array())
            for (const auto &action : legal.as_array()) {
                if (action_kind(action) == "RETREAT" && action_target_card_id(action) == "sv1-113")
                    return 0;
            }
        return 1500;
    }
    const char *id() const noexcept override { return "psychic_policy_v1"; }
    std::string stage(const PolicyView &view) const override {
        const auto xatu = view.count_card_board("sv1-108");
        const bool natu =
            view.count_card_board("sv1-107") > 0 || view.count_card_hand("sv1-107") > 0;
        if (xatu <= 0 || (xatu < 2 && natu))
            return "build_xatu_engine";
        return view.count_card_hand("sv1-ener-5") >= 2 ? "accelerate_energy" : "scale_attackers";
    }
    double action_score(const PolicyView &view, const Value &action) const override {

        double score = generic_action_adjustment(view, action) + matchup_adjustment(view, action) +
                       stage_action_score(view, action) + candidate_score(view, action);
        const std::string kind = action_kind(action);
        const std::string card = action_card_id(action);
        const std::string target = action_target_card_id(action);
        const std::string target_slot = action_target_slot(action);
        const auto attack = attack_index(action);
        const bool exact = string_field(view.state, "phase") == "MAIN" && view.turn() == 2 &&
                           view.going_second() &&
                           integer_field(view.state, "active_player_idx", -1) == view.actor;
        const bool cresselia_bench = view.card_benched("sv1-113");
        const bool cresselia_ready = view.energy_count("sv1-113") >= 1;
        if (exact && cresselia_bench) {
            if (kind == "ATTACH_ENERGY" && target == "sv1-113" &&
                target_slot.rfind("bench_", 0) == 0)
                score += view.weight("cresselia_opening_route");
            else if (kind == "PLAY_TRAINER" && card == "sv1-150" && cresselia_ready)
                score += view.weight("cresselia_opening_route");
            else if (kind == "PLAY_TRAINER" && card == "sv1-204" &&
                     (cresselia_ready || (!bool_field(view.own(), "energy_attached_this_turn") &&
                                          view.count_card_hand("sv1-ener-5") > 0)) &&
                     view.count_card_hand("sv1-150") <= 0 &&
                     !(action_kind(action) == "RETREAT" && target == "sv1-113"))
                score += view.weight("cresselia_opening_route");
            else if (kind == "RETREAT" && target == "sv1-113" && cresselia_ready)
                score += view.weight("cresselia_opening_route");
        }
        if (kind == "PLAY_BASIC" && card == "sv1-113" && target_slot == "active" &&
            view.going_second())
            score += view.weight("cresselia_active_opening");
        else if (kind == "PLAY_BASIC" && card == "sv1-107" && target_slot.rfind("bench_", 0) == 0)
            score += view.weight("natu_bench");
        else if (kind == "EVOLVE" && card == "sv1-108") {
            score += view.weight("xatu_engine");
            if (view.count_card_board("sv1-108") <= 0)
                score += view.weight("first_xatu_priority");
        } else if (kind == "EVOLVE" && card == "sv1-106" && view.count_card_board("sv1-108") <= 0 &&
                   view.count_card_board("sv1-107") > 0)
            score -= view.weight("houndstone_before_xatu_penalty");
        else if (kind == "USE_ABILITY" && card == "sv1-108") {
            score += view.weight("xatu_engine");
            score += static_cast<double>(view.count_card_hand("sv1-ener-5")) *
                     view.weight("psychic_energy_hand");
        } else if (kind == "DECLARE_ATTACK" && card == "sv1-106")
            score += static_cast<double>(view.count_role_discard("psychic_pokemon")) *
                     view.weight("graveyard_scaling");
        else if (kind == "DECLARE_ATTACK" && card == "sv1-113" && attack == 0) {
            score += view.weight("cresselia_growth");
            if (exact)
                score += view.weight("cresselia_first_turn_growth");
        } else if (kind == "DECLARE_ATTACK" && card == "sv1-111") {
            if (attack == 0)
                score += view.weight("latios_glide");
            else if (attack == 1)
                score += view.weight("latios_clean_light");
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
        const std::string mode = choice_mode(view, choice);
        if (mode == "discard" || mode == "payment" || mode == "source")
            return score;
        const auto natu_board = view.count_card_board("sv1-107");
        const auto xatu_board = view.count_card_board("sv1-108");
        const auto natu_hand = view.count_card_hand("sv1-107");
        const bool must_start = xatu_board <= 0 && natu_board + natu_hand <= 0 &&
                                view.bench_count() < 5 && choice_offers_card(choice, "sv1-107");
        // Outside Cresselia's available opening attack, complete the engine
        // already in hand before collecting another unpowered basic attacker.
        const bool opening_funded = view.turn() == 2 && view.going_second() &&
                                    !bool_field(view.own(), "energy_attached_this_turn") &&
                                    view.count_card_hand("sv1-ener-5") > 0;
        if (must_start && card == "sv1-107" && view.count_card_hand("sv1-108") > 0 &&
            !opening_funded && view.own_prizes() > 2 && view.opponent_board().size() > 1)
            score += view.weight("ready_xatu_seed", 400.0);
        if (must_start && card != "sv1-107" && card != "sv1-108") {
            score -= view.weight("attacker_before_xatu_search_penalty");
        }
        if (card == "sv1-108") {
            if (natu_board > 0 && xatu_board == 0 && view.count_card_hand("sv1-108") == 0)
                score += view.weight("complete_xatu_line", 240.0);
            if (natu_board > 0)
                score += view.weight("xatu_engine") * 2.5;
            else if (natu_hand > 0)
                score += view.weight("xatu_engine") * 1.25;
            else
                score -= view.weight("xatu_engine") * 2.0;
        } else if (card == "sv1-107") {
            score +=
                view.weight("xatu_engine") * (natu_board + natu_hand <= xatu_board ? 2.0 : 0.5);
        } else if ((card == "sv1-104" || card == "sv1-106") && natu_board > 0 && xatu_board <= 0) {
            score -= view.weight("xatu_engine");
        } else if (card == "sv1-ener-5" && xatu_board > 0) {
            score += view.weight("psychic_energy_hand") * 2.0;
        }

        return score;
    }
    double discard_value(const PolicyView &view, const Value &option) const override {
        double score = DeckPolicy::discard_value(view, option);
        if (houndstone_available(view) && view.has_role(option_card_id(option), "psychic_pokemon"))
            score += view.weight("graveyard_scaling");
        return score;
    }
    double state_score(const PolicyView &view) const override {
        double score = generic_state_adjustment(view) + stage_state_score(view);
        const auto xatu = view.count_card_board("sv1-108");
        score += static_cast<double>(xatu) * view.weight("xatu_engine");
        score += static_cast<double>(std::min(view.count_card_hand("sv1-ener-5"), xatu)) *
                 view.weight("psychic_energy_hand");
        if (houndstone_available(view)) {
            score += static_cast<double>(
                         std::min<std::int64_t>(view.count_role_discard("psychic_pokemon"), 6)) *
                     view.weight("graveyard_scaling");
        }

        return std::clamp(score, -400.0, 400.0);
    }
    double position_value(const PolicyView &view, const PositionFeatures &facts) const override {
        return evaluate_position(*this, view, facts, 0.8);
    }
};
} // namespace
std::shared_ptr<const DeckPolicy> make_psychic_policy() {
    return std::make_shared<PsychicPolicy>();
}
} // namespace ptcg::ai
