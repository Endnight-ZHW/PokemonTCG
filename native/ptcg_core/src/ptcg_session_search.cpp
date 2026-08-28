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

Value RulesSession::legal_actions(std::int32_t actor) const {
    const auto failure = [this](const std::string &code) {
        return Value(Object{
            {"schema_version", Value(1)},
            {"success", Value(false)},
            {"code", Value(code)},
            {"message", Value(code)},
            {"base_revision", Value(revision())},
            {"groups", Value::make_array()},
        });
    };
    if (!initialized_) {
        return failure("not_started");
    }
    if (actor < 0 || actor > 1) {
        return failure("invalid_actor");
    }
    Array groups;
    if (pending_.is_null()) {
        if (!populate_legal_cache(actor)) {
            return failure("native_legal_action_error");
        }
        const Value &candidates = legal_cache_candidates_;
        std::vector<std::string> signatures;
        for (const Value &candidate : candidates.as_array()) {
            if (!candidate.is_object()) {
                return failure("invalid_native_action");
            }
            Value signature(Object{
                {"base_revision", Value(integer_field(
                    candidate, "base_revision", revision()))},
                {"actor", Value(integer_field(candidate, "actor", actor))},
                {"kind", Value(string_field(candidate, "kind"))},
                {
                    "source",
                    candidate.find("source") == nullptr
                        ? Value() : candidate.find("source")->deep_clone(),
                },
                {
                    "payload",
                    candidate.find("payload") == nullptr
                        ? Value::make_object()
                        : candidate.find("payload")->deep_clone(),
                },
            });
            const std::string signature_hash = canonical_value_hash(signature);
            auto found = std::find(
                signatures.begin(), signatures.end(), signature_hash);
            if (found == signatures.end()) {
                signatures.push_back(signature_hash);
                Array targets;
                const Value *target = candidate.find("target");
                if (target != nullptr && !target->is_null()) {
                    targets.push_back(target->deep_clone());
                }
                groups.emplace_back(Object{
                    {"group_id", Value("native:" + signature_hash)},
                    {"base_revision", signature["base_revision"]},
                    {"actor", signature["actor"]},
                    {"kind", signature["kind"]},
                    {"source", signature["source"]},
                    {"payload", signature["payload"]},
                    {"targets", Value(std::move(targets))},
                });
                continue;
            }
            const std::size_t group_index = static_cast<std::size_t>(
                std::distance(signatures.begin(), found));
            const Value *target = candidate.find("target");
            if (target != nullptr && !target->is_null()) {
                Array &targets = required(groups[group_index], "targets").as_array();
                if (std::find(targets.begin(), targets.end(), *target)
                    == targets.end()) {
                    targets.push_back(target->deep_clone());
                }
            }
        }
    }
    return Value(Object{
        {"schema_version", Value(1)},
        {"success", Value(true)},
        {"code", Value("")},
        {"message", Value("")},
        {"base_revision", Value(revision())},
        {"groups", Value(std::move(groups))},
    });
}


} // namespace ptcg::ai

namespace ptcg::ai::session_detail {

bool typed_action_equivalent(
    const typed::Action &submitted,
    const typed::Action &candidate
) {
    return submitted.kind == candidate.kind
        && submitted.actor == candidate.actor
        && submitted.base_revision == candidate.base_revision
        && submitted.source == candidate.source
        && submitted.target == candidate.target
        && submitted.attack_index == candidate.attack_index
        && submitted.ability_name == candidate.ability_name;
}

Value clone_wire_field(
    const Value &source,
    const char *key,
    Value fallback
) {
    const Value *entry = source.find(key);
    return entry == nullptr ? std::move(fallback) : *entry;
}

Value reply_search_pokemon_projection(const Value &source) {
    if (!source.is_object()) return Value();
    Value result(Object{
        {"card_id", clone_wire_field(source, "card_id", Value(""))},
        {"damage_counters", clone_wire_field(
            source, "damage_counters", Value(0))},
        {"energy_card_ids", clone_wire_field(
            source, "energy_card_ids", Value::make_array())},
        {"attached_tool_id", clone_wire_field(
            source, "attached_tool_id", Value(""))},
        {"status_conditions", clone_wire_field(
            source, "status_conditions", Value::make_array())},
        {"evolution_stack_ids", clone_wire_field(
            source, "evolution_stack_ids", Value::make_array())},
        {"can_evolve_this_turn", clone_wire_field(
            source, "can_evolve_this_turn", Value(true))},
        {"placed_this_turn", clone_wire_field(
            source, "placed_this_turn", Value(true))},
        {"used_abilities", clone_wire_field(
            source, "used_abilities", Value::make_array())},
        {"healed_this_turn", clone_wire_field(
            source, "healed_this_turn", Value(false))},
        {"paralyzed_since_turn", clone_wire_field(
            source, "paralyzed_since_turn", Value(0))},
    });
    const Value *modifiers = source.find("modifiers");
    if (modifiers != nullptr && modifiers->is_array()
        && !modifiers->as_array().empty()) {
        result["modifiers"] = *modifiers;
    }
    return result;
}

Value reply_search_player_projection(
    const Value &source,
    std::int32_t actor
) {
    Value bench = clone_wire_field(source, "bench", Value::make_array());
    if (!bench.is_array()) bench = Value::make_array();
    for (Value &entry : bench.as_array()) {
        entry = reply_search_pokemon_projection(entry);
    }
    while (bench.as_array().size() < 5) bench.as_array().emplace_back();
    if (bench.as_array().size() > 5) bench.as_array().resize(5);
    Value result(Object{
        {"name", clone_wire_field(
            source, "name", Value("玩家" + std::to_string(actor + 1)))},
        {"deck", clone_wire_field(source, "deck", Value::make_array())},
        {"hand", clone_wire_field(source, "hand", Value::make_array())},
        {"discard", clone_wire_field(
            source, "discard", Value::make_array())},
        {"prizes", clone_wire_field(source, "prizes", Value::make_array())},
        {"active", reply_search_pokemon_projection(
            clone_wire_field(source, "active", Value()))},
        {"bench", std::move(bench)},
        {"supporter_played_this_turn", clone_wire_field(
            source, "supporter_played_this_turn", Value(false))},
        {"energy_attached_this_turn", clone_wire_field(
            source, "energy_attached_this_turn", Value(false))},
        {"retreated_this_turn", clone_wire_field(
            source, "retreated_this_turn", Value(false))},
        {"stadium_played_this_turn", clone_wire_field(
            source, "stadium_played_this_turn", Value(false))},
        {"stadium_used_this_turn", clone_wire_field(
            source, "stadium_used_this_turn", Value(false))},
        {"healed_this_turn", clone_wire_field(
            source, "healed_this_turn", Value(false))},
        {"vstar_power_used", clone_wire_field(
            source, "vstar_power_used", Value(false))},
        {"was_ko_by_attack", clone_wire_field(
            source, "was_ko_by_attack", Value(false))},
    });
    const Value *locked_names = source.find("attack_locked_names");
    if (locked_names != nullptr && locked_names->is_object()
        && !locked_names->as_object().empty()) {
        result["attack_locked_names"] = *locked_names;
    }
    return result;
}

Value reply_search_state_projection(const Value &source) {
    Value players = clone_wire_field(source, "players", Value::make_array());
    if (!players.is_array()) players = Value::make_array();
    while (players.as_array().size() < 2) players.as_array().emplace_back(
        Value::make_object());
    if (players.as_array().size() > 2) players.as_array().resize(2);
    for (std::size_t index = 0; index < players.as_array().size(); ++index) {
        players.as_array()[index] = reply_search_player_projection(
            players.as_array()[index], static_cast<std::int32_t>(index));
    }
    Value public_deck_keys = clone_wire_field(
        source, "public_deck_keys", Value::make_array());
    if (!public_deck_keys.is_array()) public_deck_keys = Value::make_array();
    while (public_deck_keys.as_array().size() < 2) {
        public_deck_keys.as_array().emplace_back("");
    }
    if (public_deck_keys.as_array().size() > 2) {
        public_deck_keys.as_array().resize(2);
    }
    const bool apply_type_matchups = clone_wire_field(
        source, "apply_type_matchups", Value(false)).as_bool(false);
    Value rules_options = clone_wire_field(
        source, "rules_options", Value::make_object());
    if (!rules_options.is_object()) rules_options = Value::make_object();
    rules_options["apply_type_matchups"] = Value(apply_type_matchups);
    return Value(Object{
        {"players", std::move(players)},
        {"active_player_idx", clone_wire_field(
            source, "active_player_idx", Value(0))},
        {"phase", clone_wire_field(source, "phase", Value("SETUP"))},
        {"turn_number", clone_wire_field(source, "turn_number", Value(0))},
        {"first_player_idx", clone_wire_field(
            source, "first_player_idx", Value(0))},
        {"stadium_card_id", clone_wire_field(
            source, "stadium_card_id", Value(""))},
        {"stadium_owner_idx", clone_wire_field(
            source, "stadium_owner_idx", Value(-1))},
        {"winner", clone_wire_field(source, "winner", Value(-1))},
        {"result_status", clone_wire_field(
            source, "result_status", Value("ONGOING"))},
        {"result_reason", clone_wire_field(
            source, "result_reason", Value(""))},
        {"result_conditions", clone_wire_field(
            source, "result_conditions", Value(Array{
                Value::make_array(), Value::make_array()}))},
        {"revision", clone_wire_field(source, "revision", Value(0))},
        {"choice_sequence", clone_wire_field(
            source, "choice_sequence", Value(0))},
        {"public_deck_keys", std::move(public_deck_keys)},
        {"apply_type_matchups", Value(apply_type_matchups)},
        {"rules_profile_id", clone_wire_field(
            source, "rules_profile_id", Value("CN_MAINLAND_3_1_0"))},
        {"rules_options", std::move(rules_options)},
        {"action_log", clone_wire_field(
            source, "action_log", Value::make_array())},
        {"mulligan_count", clone_wire_field(
            source, "mulligan_count", Value(Array{Value(0), Value(0)}))},
        {"extra_draws", clone_wire_field(
            source, "extra_draws", Value(Array{Value(0), Value(0)}))},
        {"setup_ready", clone_wire_field(
            source, "setup_ready", Value(Array{Value(false), Value(false)}))},
        {"setup_stage", clone_wire_field(
            source, "setup_stage", Value("INITIAL_PLACEMENT"))},
        {"setup_actor_idx", clone_wire_field(
            source, "setup_actor_idx", Value(0))},
        {"opening_coin_winner_idx", clone_wire_field(
            source, "opening_coin_winner_idx", Value(0))},
        {"mulligan_bonus_max", clone_wire_field(
            source, "mulligan_bonus_max", Value(0))},
        {"setup_bonus_card_ids", clone_wire_field(
            source, "setup_bonus_card_ids", Value(Array{
                Value::make_array(), Value::make_array()}))},
        {"pending_promotions", clone_wire_field(
            source, "pending_promotions", Value::make_array())},
        {"processed_action_ids", clone_wire_field(
            source, "processed_action_ids", Value::make_array())},
        {"resolution_stack", clone_wire_field(
            source, "resolution_stack", Value(Object{
                {"schema_version", Value(3)},
                {"frames", Value::make_array()},
                {"context", Value::make_object()},
                {"pending_request", Value()},
                {"sequence", Value(0)},
            }))},
        {"turn_fact_book", clone_wire_field(
            source, "turn_fact_book", Value(Object{
                {"current_turn", Value(Object{{"knockouts", Value::make_array()}})},
                {"previous_turn", Value(Object{{"knockouts", Value::make_array()}})},
            }))},
    });
}

} // namespace ptcg::ai::session_detail

namespace ptcg::ai {

using namespace session_detail;

std::unique_ptr<RulesSession> RulesSession::fork() const {
    return std::make_unique<RulesSession>(*this);
}

std::unique_ptr<RulesSession> RulesSession::fork_for_search(
    std::uint32_t rng_state
) const {
    auto copy = std::make_unique<RulesSession>();
    copy->catalog_ = catalog_;
    copy->state_ = state_;
    copy->pending_ = pending_;
    copy->pending_raw_ = pending_raw_;
    copy->continuation_ = continuation_;
    copy->match_config_ = match_config_;
    copy->card_ir_content_fingerprint_ = card_ir_content_fingerprint_;
    copy->card_ir_contract_fingerprint_ = card_ir_contract_fingerprint_;
    copy->vm_descriptor_digest_ = vm_descriptor_digest_;
    copy->initial_seed_ = initial_seed_;
    copy->rng_state_ = rng_state == 0 ? 0x6D2B79F5U : rng_state;
    copy->initialized_ = initialized_;
    copy->search_mode_ = true;
    copy->legal_cache_revision_ = legal_cache_revision_;
    copy->legal_cache_actor_ = legal_cache_actor_;
    copy->legal_cache_candidates_ = legal_cache_candidates_;
    copy->typed_legal_cache_ = typed_legal_cache_;
    copy->authoritative_state_ = authoritative_state_;
    copy->typed_pending_cache_ = typed_pending_cache_;
    copy->typed_pending_cache_revision_ = typed_pending_cache_revision_;
    copy->typed_pending_cache_request_id_ = typed_pending_cache_request_id_;
    return copy;
}

std::unique_ptr<RulesSession> RulesSession::fork_for_reply_search() const {
    auto copy = fork_for_search(rng_state_);
    copy->state_ = reply_search_state_projection(state_);
    copy->legal_cache_revision_ = -1;
    copy->legal_cache_actor_ = -1;
    copy->legal_cache_candidates_ = Value::make_array();
    copy->typed_legal_cache_.reset();
    std::string typed_error;
    if (!copy->commit_authoritative_state(&typed_error)) {
        throw std::runtime_error(typed_error.empty()
            ? "typed_reply_projection_failed" : typed_error);
    }
    copy->typed_pending_cache_.reset();
    copy->typed_pending_cache_revision_ = -1;
    copy->typed_pending_cache_request_id_.clear();
    return copy;
}

} // namespace ptcg::ai
