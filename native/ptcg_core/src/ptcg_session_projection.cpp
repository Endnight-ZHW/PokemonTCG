#include "ptcg_rules_session.hpp"
#include "ptcg_session_internal.hpp"

#include "ptcg_random.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <functional>
#include <iomanip>
#include <limits>
#include <mutex>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <unordered_set>
#include <unordered_map>
#include <utility>


namespace ptcg::ai {

using namespace session_detail;

Value RulesSession::view_for(std::int32_t viewer) const {
    if (!initialized_ || viewer < 0 || viewer > 1) {
        return Value::make_object();
    }
    Value checkpoint_view;
    const Value *view_state = &state_;
    if (
        !pending_.is_null()
        && integer_field(pending_, "player", -1) != viewer
        && continuation_.is_object()
    ) {
        const Value *transaction = continuation_.find("session_transaction");
        const Value *checkpoint = transaction != nullptr && transaction->is_object()
            ? transaction->find("state") : nullptr;
        if (checkpoint != nullptr && checkpoint->is_object()) {
            checkpoint_view = checkpoint->deep_clone();
            checkpoint_view["revision"] = Value(revision());
            checkpoint_view["choice_sequence"] = Value(integer_field(
                state_, "choice_sequence"));
            view_state = &checkpoint_view;
        }
    }
    const bool hide_setup = string_field(
        *view_state, "setup_stage") != "COMPLETE";
    static const std::array<const char *, 27> public_fields = {
        "phase", "turn_number", "active_player_idx", "first_player_idx",
        "revision", "stadium_card_id", "stadium_owner_idx", "winner",
        "result_status", "result_reason", "result_conditions", "public_deck_keys",
        "apply_type_matchups", "rules_profile_id", "rules_options", "action_log",
        "mulligan_count", "extra_draws", "setup_ready", "setup_stage",
        "setup_actor_idx", "opening_coin_winner_idx", "mulligan_bonus_max",
        "pending_promotions", "turn_fact_book", "choice_sequence", "setup_bonus_card_ids",
    };
    Object view;
    for (const char *key : public_fields) {
        const Value *value = view_state->find(key);
        if (value != nullptr) {
            view[key] = value->deep_clone();
        }
    }
    // Private setup bookkeeping is never emitted even though it remains in the
    // authoritative Snapshot 3 state.
    view.erase("choice_sequence");
    view.erase("setup_bonus_card_ids");
    view["your"] = player_view(player(*view_state, viewer), true, false);
    view["opponent"] = player_view(
        player(*view_state, 1 - viewer), false, hide_setup);
    return Value(std::move(view));
}


} // namespace ptcg::ai
