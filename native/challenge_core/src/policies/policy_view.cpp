#include "policies/policy_view.hpp"

namespace ptcg::ai::policy {
std::string action_kind(const Value &action) { return string_field(action, "kind"); }

const Value &action_payload(const Value &action) {
    static const Value empty = Value::make_object();
    const Value *payload = field(action, "payload");
    return payload != nullptr && payload->is_object() ? *payload : empty;
}

std::string action_card_id(const Value &action) {
    const Value *source = field(action, "source");
    if (source != nullptr && source->is_object()) {
        const std::string card_id = string_field(*source, "card_id");
        if (!card_id.empty())
            return card_id;
    }
    const Value &payload = action_payload(action);
    for (const char *key : {"card_id", "source_card_id", "hand_card_id"}) {
        const std::string card_id = string_field(payload, key);
        if (!card_id.empty())
            return card_id;
    }
    return {};
}

std::string action_target_card_id(const Value &action) {
    const Value *target = field(action, "target");
    if (target != nullptr && target->is_object()) {
        const std::string card_id = string_field(*target, "card_id");
        if (!card_id.empty())
            return card_id;
    }
    const Value &payload = action_payload(action);
    for (const char *key : {"target_card_id", "pokemon_card_id"}) {
        const std::string card_id = string_field(payload, key);
        if (!card_id.empty())
            return card_id;
    }
    return {};
}

std::string action_target_slot(const Value &action) {
    const Value *target = field(action, "target");
    if (target != nullptr && target->is_object()) {
        const std::string slot = string_field(*target, "slot");
        if (!slot.empty())
            return slot;
    }
    const Value &payload = action_payload(action);
    return string_field(payload, "target_slot", string_field(payload, "slot"));
}

std::string action_source_slot(const Value &action) {
    const Value *source = field(action, "source");
    if (source != nullptr && source->is_object()) {
        const std::string slot = string_field(*source, "slot");
        if (!slot.empty())
            return slot;
    }
    const Value &payload = action_payload(action);
    const std::string slot = string_field(payload, "source_slot", string_field(payload, "slot"));
    return slot.empty() ? action_target_slot(action) : slot;
}

std::int64_t attack_index(const Value &action) {
    const Value &payload = action_payload(action);
    return integer_field(payload, "attack_index", integer_field(payload, "attack_idx", -1));
}

std::string generic_plan_stage(const PolicyView &view) {
    const Value *goals = field(view.profile, "stage_goals");
    if (goals == nullptr || !goals->is_array() || goals->as_array().empty())
        return "develop";
    if (view.opponent_prizes() <= 2 || view.own_prizes() <= 2) {
        return string_field(goals->as_array().back(), "id", "closeout");
    }
    if (view.turn() <= 2 || view.own_board().size() <= 1) {
        return string_field(goals->as_array().front(), "id", "setup");
    }
    return string_field(goals->as_array()[std::min<std::size_t>(1, goals->as_array().size() - 1)],
                        "id", "develop");
}

const Value *stage_goal(const PolicyView &view, const std::string &stage) {
    const Value *goals = field(view.profile, "stage_goals");
    if (goals == nullptr || !goals->is_array())
        return nullptr;
    for (const Value &goal : goals->as_array()) {
        if (goal.is_object() && string_field(goal, "id") == stage)
            return &goal;
    }
    return nullptr;
}

std::int64_t role_progress(const PolicyView &view, const std::string &role) {
    if (role == "energy") {
        std::int64_t attached = 0;
        for (const Value *pokemon : view.own_board()) {
            for (const Value &energy : view.energy_ids(pokemon)) {
                if (view.has_role(energy.string_or(), role))
                    ++attached;
            }
        }
        return attached;
    }
    std::int64_t result = view.count_role_board(role);
    static const std::vector<std::string> hand_roles{
        "search",     "draw", "recovery", "switch",
        "disruption", "tool", "healing",  "energy_acceleration",
    };
    if (std::find(hand_roles.begin(), hand_roles.end(), role) != hand_roles.end()) {
        result += view.count_role_hand(role);
    }
    return result;
}

bool action_advances_role(const PolicyView &view, const Value &action, const std::string &role) {
    const std::string kind = action_kind(action);
    const std::string source = action_card_id(action);
    if (kind == "PLAY_BASIC" || kind == "EVOLVE")
        return view.has_role(source, role);
    if (kind == "ATTACH_ENERGY")
        return role == "energy" && view.has_role(source, "energy");
    if (kind == "PLAY_TRAINER" || kind == "USE_STADIUM" || kind == "USE_ABILITY") {
        static const std::vector<std::string> effect_roles{
            "search",     "draw", "recovery", "switch",
            "disruption", "tool", "healing",  "energy_acceleration",
        };
        return std::find(effect_roles.begin(), effect_roles.end(), role) != effect_roles.end() &&
               view.has_role(source, role);
    }
    return false;
}

double stage_action_score(const PolicyView &view, const Value &action) {
    const Value *goal = stage_goal(view, plan_stage(view));
    const Value *targets = goal == nullptr ? nullptr : field(*goal, "targets");
    if (targets == nullptr || !targets->is_object())
        return 0.0;
    double score = 0.0;
    for (const auto &[role, required_value] : targets->as_object()) {
        const auto required = std::max<std::int64_t>(0, required_value.as_integer());
        const auto deficit = std::max<std::int64_t>(0, required - role_progress(view, role));
        if (deficit > 0 && action_advances_role(view, action, role)) {
            score += view.weight("stage_action_bonus", 7.0) *
                     static_cast<double>(std::min<std::int64_t>(deficit, 2));
        }
    }
    return std::clamp(score, 0.0, 14.0);
}

double stage_state_score(const PolicyView &view) {
    const Value *goal = stage_goal(view, plan_stage(view));
    const Value *targets = goal == nullptr ? nullptr : field(*goal, "targets");
    if (targets == nullptr || !targets->is_object())
        return 0.0;
    std::int64_t progress = 0;
    for (const auto &[role, required_value] : targets->as_object()) {
        const auto required = std::max<std::int64_t>(0, required_value.as_integer());
        progress += std::min(required, role_progress(view, role));
    }
    return std::clamp(static_cast<double>(progress) * view.weight("stage_state_progress", 3.0), 0.0,
                      32.0);
}

double generic_state_adjustment(const PolicyView &view) {
    double score = static_cast<double>(view.count_role_board("primary_attacker")) *
                   view.weight("board_primary");
    score +=
        static_cast<double>(view.count_role_board("bench_engine")) * view.weight("board_engine");
    score += static_cast<double>(view.hand().size()) * view.weight("hand_size");
    score -= static_cast<double>(view.own_damage_total()) * view.weight("damage_pressure");
    if (view.own_prizes() <= 2)
        score += view.weight("closeout");
    if (view.opponent_prizes() <= 2)
        score -= view.weight("closeout");
    return score;
}

double generic_action_adjustment(const PolicyView &view, const Value &action) {
    const std::string kind = action_kind(action);
    const std::string card_id = action_card_id(action);
    const std::string target_id = action_target_card_id(action);
    double score = 0.0;
    if (kind == "PLAY_BASIC") {
        if (view.has_role(card_id, "setup_basic"))
            score += view.weight("play_setup");
        if (view.has_role(card_id, "bench_engine"))
            score += view.weight("play_engine");
    } else if (kind == "EVOLVE") {
        if (view.has_role(card_id, "evolution"))
            score += view.weight("evolve");
        if (view.has_role(card_id, "primary_attacker"))
            score += view.weight("evolve_core");
    } else if (kind == "ATTACH_ENERGY") {
        if (view.has_role(target_id, "primary_attacker"))
            score += view.weight("attach_primary");
        else if (view.has_role(target_id, "secondary_attacker"))
            score += view.weight("attach_secondary");
    } else if (kind == "PLAY_TRAINER" || kind == "USE_STADIUM") {
        for (const auto &[role, weight_name] : std::vector<std::pair<std::string, std::string>>{
                 {"search", "play_search"},
                 {"draw", "play_draw"},
                 {"energy_acceleration", "play_acceleration"},
                 {"recovery", "play_recovery"},
                 {"switch", "play_switch"},
                 {"disruption", "play_disruption"},
             })
            if (view.has_role(card_id, role))
                score += view.weight(weight_name);
    } else if (kind == "USE_ABILITY") {
        if (view.has_role(card_id, "bench_engine") || view.has_role(card_id, "energy_acceleration"))
            score += view.weight("use_engine_ability");
    } else if (kind == "DECLARE_ATTACK") {
        if (view.has_role(card_id, "primary_attacker"))
            score += view.weight("attack_primary");
        else if (view.has_role(card_id, "secondary_attacker"))
            score += view.weight("attack_secondary");
    }
    return score;
}

bool has_any_in_hand(const PolicyView &view, const std::vector<std::string> &ids) {
    return std::any_of(ids.begin(), ids.end(),
                       [&view](const std::string &id) { return view.count_card_hand(id) > 0; });
}

const Value &choice_presentation(const Value &choice) {
    static const Value empty = Value::make_object();
    const Value *presentation = field(choice, "presentation");
    if (presentation != nullptr && presentation->is_object())
        return *presentation;
    const Value *metadata = field(choice, "metadata");
    return metadata != nullptr && metadata->is_object() ? *metadata : empty;
}

std::string choice_purpose(const Value &choice) {
    const Value &presentation = choice_presentation(choice);
    return lower_ascii(string_field(presentation, "purpose", string_field(choice, "purpose")));
}

std::string choice_surface(const Value &choice) {
    const std::string request = lower_ascii(string_field(choice, "request_type"));
    const std::string purpose = choice_purpose(choice);
    if (request == "select_energy_target" || request == "distribute_energy" ||
        request == "look_top_attach_energy")
        return "energy_target";
    if (request == "select_heal_target" || purpose == "heal")
        return "heal_target";
    if (request == "select_bench" && purpose == "switch")
        return "switch_target";
    if (request == "select_opponent_bench" || request == "bench_damage_target" ||
        request == "damage_target" || request == "place_counters_self_discard") {
        return "opponent_target";
    }
    return "card";
}

std::string option_card_id(const Value &option) {
    for (const char *key : {"card_id", "source_card_id"}) {
        const std::string card_id = string_field(option, key);
        if (!card_id.empty())
            return card_id;
    }
    const Value *ref = field(option, "ref");
    return ref != nullptr && ref->is_object() ? string_field(*ref, "card_id") : std::string{};
}

std::string choice_mode(const PolicyView &view, const Value &choice) {
    const std::string request = lower_ascii(string_field(choice, "request_type"));
    const Value &presentation = choice_presentation(choice);
    const std::string purpose = choice_purpose(choice);
    if (request == "select_retreat_payment")
        return "payment";
    if (request == "select_attachment") {
        if (purpose.rfind("energy_relocate", 0) == 0 || purpose.rfind("relocate_energy", 0) == 0 ||
            purpose == "trigger_move_basic_energy")
            return "source";
        if (purpose == "discard_energy" || purpose == "discard_energy_attachments") {
            return integer_field(presentation, "source_player", view.actor) == view.actor
                       ? "payment"
                       : "benefit";
        }
        return "payment";
    }
    if (request == "select_energy_source" || purpose == "energy_relocate_source") {
        return "source";
    }
    if (purpose == "discard_then_draw" || purpose == "discard_hand_then_draw" ||
        purpose == "discard_cards" || purpose == "houb" || purpose == "zinnia" ||
        purpose == "discard" || purpose == "discard_cost")
        return "discard";
    if (purpose == "hand_bottom_draw" || purpose == "bottom_deck")
        return "payment";
    return "benefit";
}

std::int64_t remaining_hand_count_for_choice(const PolicyView &view, const Value &choice,
                                             const Value &option, const std::string &card_id) {
    std::int64_t count = view.count_card_hand(card_id);
    const Value *ref = field(option, "ref");
    bool removes_hand_card = true;
    if (ref != nullptr && ref->is_object()) {
        if (field(*ref, "zone") != nullptr) {
            removes_hand_card = string_field(*ref, "zone") == "hand";
        } else if (string_field(*ref, "kind") == "attachment") {
            removes_hand_card = false;
        }
    }
    const std::string mode = choice_mode(view, choice);
    if (removes_hand_card && (mode == "discard" || mode == "payment" || mode == "source"))
        --count;
    return std::max<std::int64_t>(0, count);
}

bool choice_offers_card(const Value &choice, const std::string &card_id) {
    const Value *options = field(choice, "options");
    return options != nullptr && options->is_array() &&
           std::any_of(options->as_array().begin(), options->as_array().end(),
                       [&card_id](const Value &option) {
                           return option.is_object() && option_card_id(option) == card_id;
                       });
}

double generic_choice_keep_value(const PolicyView &view, const Value &choice, const Value &option) {
    if (choice_surface(choice) != "card")
        return 0.0;
    const std::string card_id = option_card_id(option);
    double score = 0.0;
    if (view.has_role(card_id, "primary_attacker"))
        score += view.weight("choice_primary");
    if (view.has_role(card_id, "bench_engine") || view.has_role(card_id, "energy_acceleration"))
        score += view.weight("choice_engine");
    if (view.has_role(card_id, "setup_basic"))
        score += view.weight("choice_setup");
    if (view.has_role(card_id, "evolution"))
        score += view.weight("choice_evolution", 14.0);
    if (view.has_role(card_id, "search") || view.has_role(card_id, "recovery")) {
        score += view.weight("choice_resource", 4.0);
    }
    if (view.has_role(card_id, "energy"))
        score += view.weight("choice_energy");
    return score;
}

double matchup_adjustment(const PolicyView &view, const Value &action) {
    double threat = 0.0;
    const Value *tags = field(view.archetypes, view.opponent_deck_key());
    const Value *weights = field(view.profile, "matchup_weights");
    if (tags != nullptr && tags->is_array() && weights != nullptr && weights->is_object()) {
        for (const Value &tag : tags->as_array())
            threat += number_field(*weights, tag.string_or());
    }
    const std::string kind = action_kind(action);
    const std::string card = action_card_id(action);
    double score = 0.0;
    if (kind == "PLAY_BASIC" || kind == "EVOLVE" || kind == "ATTACH_ENERGY")
        score += threat * 0.08;
    else if (kind == "DECLARE_ATTACK") {
        score += threat * 0.25;
        if (view.opponent_prizes() < view.own_prizes())
            score += view.weight("closeout") * 0.2;
    } else if ((kind == "PLAY_TRAINER" || kind == "USE_STADIUM") &&
               view.has_role(card, "disruption")) {
        score += threat * 0.7;
        score += static_cast<double>(view.opponent_engine_count_for_action_semantics()) * 1.5;
    } else if (kind == "RETREAT") {
        const Value *active = view.active(view.actor);
        const Value *statuses = active == nullptr ? nullptr : field(*active, "status_conditions");
        score += static_cast<double>(statuses != nullptr && statuses->is_array()
                                         ? statuses->as_array().size()
                                         : 0U) *
                 view.weight("play_switch");
    }
    return score;
}

double candidate_score(const PolicyView &view, const Value &action) {
    const double top_scale = std::clamp(
        static_cast<double>(std::max<std::int64_t>(
            1, static_cast<std::int64_t>(std::round(view.weight("search_top_k", 6.0))))) /
            6.0,
        0.5, 1.5);
    const std::string source = action_card_id(action);
    const std::string target = action_target_card_id(action);
    double score = 0.0;
    if (view.has_role(source, "primary_attacker") || view.has_role(target, "primary_attacker"))
        score += view.weight("candidate_primary", 6.0) * top_scale;
    if (view.has_role(source, "bench_engine") || view.has_role(target, "bench_engine"))
        score += view.weight("candidate_engine", 4.0) * top_scale;
    return std::clamp(score, -24.0, 24.0);
}

std::string plan_stage(const PolicyView &view) {
    return view.policy ? view.policy->stage(view) : generic_plan_stage(view);
}

double evaluate_position(const DeckPolicy &selected, const PolicyView &view,
                         const PositionFeatures &facts, double development_weight) {
    // Preserve marginal gains when ahead: a saturated tactical score used to
    // make another usable attacker indistinguishable from an unpowered body.
    return facts.material + facts.tactical * 0.35 +
           selected.state_score(view) * development_weight +
           facts.readiness * view.weight("plan_readiness", 0.10) +
           facts.prize_clock_margin * view.weight("plan_prize_clock", 0.0);
}
} // namespace ptcg::ai::policy
