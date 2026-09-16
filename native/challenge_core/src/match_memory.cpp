#include "match_memory.hpp"
#include "challenge_search_support.hpp"
#include "ptcg_traditional_policy.hpp"
#include "ptcg_traditional_value.hpp"

namespace ptcg::ai {
using namespace challenge;
using namespace traditional_value;
Value MatchMemory::filter_root_actions(const Value &request, const Value &public_state,
                                       const Value &actions) {
    const std::int32_t actor = static_cast<std::int32_t>(integer_field(request, "actor", -1));
    Value filtered = filter_exhausted_repeatable_abilities(public_state, actor, actions, catalog_);
    if (!filtered.is_array()) {
        return filtered;
    }
    const std::string match_id = string_field(request, "match_instance_id");
    if (match_id.empty())
        return filtered;
    const std::string ledger_key =
        match_id + "|" + std::to_string(actor) + "|" +
        std::to_string(value_integer_field(public_state, "turn_number", 0));
    const auto found = action_cycle_ledger_.find(ledger_key);
    if (found == action_cycle_ledger_.end())
        return filtered;
    ActionCycleEntry &entry = found->second;
    const std::string fingerprint = action_cycle_state_fingerprint(public_state);
    const std::int64_t revision =
        integer_field(request, "revision", value_integer_field(public_state, "revision", 0));
    if (entry.last_state_fingerprint == fingerprint && revision > entry.last_revision &&
        !entry.last_action_signature.empty()) {
        entry.blocked_by_state[fingerprint].insert(entry.last_action_signature);
    }
    // Detect A -> B -> A as well as A -> A. Revision checks keep repeated
    // requests and cancelled generations from consuming a still-valid move.
    if (revision > entry.last_revision) {
        const auto previous_choices = entry.chosen_by_state.find(fingerprint);
        if (previous_choices != entry.chosen_by_state.end()) {
            entry.blocked_by_state[fingerprint].insert(previous_choices->second.begin(),
                                                       previous_choices->second.end());
        }
    }
    const auto blocked = entry.blocked_by_state.find(fingerprint);
    if (blocked == entry.blocked_by_state.end() || blocked->second.empty()) {
        return filtered;
    }
    Value::Array result;
    Value::Array terminal;
    for (const Value &action : filtered.as_array()) {
        if (traditional_action_is_terminal(action))
            terminal.push_back(action);
        if (blocked->second.count(value_action_signature(action)) == 0) {
            result.push_back(action);
        }
    }
    if (!result.empty())
        return Value(std::move(result));
    if (!terminal.empty())
        return Value(std::move(terminal));
    return filtered;
}

bool MatchMemory::apply_deck_inspection_memory(const Value &request,
                                               InformationSet &information_set) {
    if (!bool_field(request, "use_deck_inspection", true) || !information_set.valid()) {
        return false;
    }
    const std::int32_t actor = information_set.perspective();
    if (actor < 0 || actor > 1)
        return false;
    DeckInspectionMemory &memory = deck_inspection_memory_[static_cast<std::size_t>(actor)];
    const std::string match_id = string_field(request, "match_instance_id");
    if (match_id.empty() || !memory.valid || memory.match_instance_id != match_id)
        return false;
    std::string ignored;
    if (information_set.apply_known_prizes(memory.prize_cards, &ignored)) {
        return true;
    }
    // Prize count or hidden-zone composition changed.  Forget rather than
    // carrying an inference beyond the point where it is provably exact.
    memory = DeckInspectionMemory{};
    return false;
}

void MatchMemory::remember_deck_inspection(const Value &request,
                                           const InformationSet &information_set) {
    const std::int32_t actor = information_set.perspective();
    const std::string match_id = string_field(request, "match_instance_id");
    if (actor < 0 || actor > 1 || match_id.empty() ||
        !information_set.has_exact_hidden_zones(actor)) {
        return;
    }
    DeckInspectionMemory &memory = deck_inspection_memory_[static_cast<std::size_t>(actor)];
    memory.prize_cards = information_set.known_prizes(actor);
    memory.match_instance_id = match_id;
    memory.valid = true;
}

void MatchMemory::record_action_cycle_selection(const Value &request, const Value &public_state,
                                                const Value &action) {
    const std::string match_id = string_field(request, "match_instance_id");
    if (match_id.empty() || !action.is_object())
        return;
    const std::int32_t actor = static_cast<std::int32_t>(integer_field(request, "actor", -1));
    const std::string ledger_key =
        match_id + "|" + std::to_string(actor) + "|" +
        std::to_string(value_integer_field(public_state, "turn_number", 0));
    const bool inserted = action_cycle_ledger_.find(ledger_key) == action_cycle_ledger_.end();
    ActionCycleEntry &entry = action_cycle_ledger_[ledger_key];
    entry.last_state_fingerprint = action_cycle_state_fingerprint(public_state);
    entry.last_action_signature = value_action_signature(action);
    entry.chosen_by_state[entry.last_state_fingerprint].insert(entry.last_action_signature);
    entry.last_revision =
        integer_field(request, "revision", value_integer_field(public_state, "revision", 0));
    if (inserted)
        action_cycle_order_.push_back(ledger_key);
    while (action_cycle_order_.size() > 64) {
        action_cycle_ledger_.erase(action_cycle_order_.front());
        action_cycle_order_.erase(action_cycle_order_.begin());
    }
}

std::string MatchMemory::turn_plan_cache_key(const Value &request,
                                             const InformationSet &information_set) const {
    const std::string match_id = string_field(request, "match_instance_id");
    if (match_id.empty() || !information_set.valid())
        return {};
    const std::int32_t actor = information_set.perspective();
    const Value &state = information_set.public_snapshot();
    const Value *keys = state.find("public_deck_keys");
    const std::string deck_key = keys != nullptr && keys->is_array() && actor >= 0 &&
                                         static_cast<std::size_t>(actor) < keys->as_array().size()
                                     ? keys->as_array()[static_cast<std::size_t>(actor)].string_or()
                                     : std::string{};
    return match_id + "|" + string_field(request, "engine", "deck_planner_v1") + "|" +
           std::to_string(actor) + "|" +
           std::to_string(value_integer_field(state, "turn_number", 0)) + "|" + deck_key +
           "|policy=" + policies_->strategy_id(deck_key) +
           "|version=" + std::to_string(policies_->strategy_version(deck_key)) +
           "|hash=" + policies_->strategy_content_hash(deck_key) +
           "|inspection=" + (bool_field(request, "use_deck_inspection", true) ? "1" : "0");
}

Value MatchMemory::probe_cached_turn_action(const std::string &cache_key, std::int64_t revision,
                                            const Value &actions, const Value &precondition,
                                            std::int32_t actor, PlanCacheUpdate &update) const {
    const auto found = turn_plan_cache_.find(cache_key);
    if (cache_key.empty() || found == turn_plan_cache_.end())
        return {};
    update = {cache_key, std::nullopt};
    const CachedPlanEntry &entry = found->second;
    if (revision <= entry.last_revision || entry.steps.empty() || !actions.is_array() ||
        !precondition.is_object())
        return {};
    const CachedPlanStep &next = entry.steps.front();
    const auto same = [&next, &precondition](const char *key) {
        return value_string_field(next.precondition, key) == value_string_field(precondition, key);
    };
    if (!same("expected_public_fingerprint") || !same("expected_known_hand_fingerprint") ||
        !same("expected_known_prize_fingerprint") ||
        value_integer_field(next.precondition, "expected_actor", -1) !=
            value_integer_field(precondition, "expected_actor", -1) ||
        !same("expected_phase") || value_integer_field(next.action, "actor", -1) != actor)
        return {};
    const Value *matched = find_action_by_signature(actions, next.signature);
    if (matched == nullptr)
        return {};
    if (entry.steps.size() > 1) {
        update.entry = CachedPlanEntry{
            std::vector<CachedPlanStep>(entry.steps.begin() + 1, entry.steps.end()), revision};
    }
    return *matched;
}

MatchMemory::PlanCacheUpdate MatchMemory::prepare_turn_plan(const std::string &cache_key,
                                                            std::int64_t revision,
                                                            const SearchResult &result) const {
    if (cache_key.empty() || !result.success || !result.selected.is_object())
        return {};
    PlanCacheUpdate update{cache_key, std::nullopt};
    if (traditional_action_is_terminal(result.selected))
        return update;
    const std::string selected_signature = value_action_signature(result.selected);
    bool removed_selected = false;
    std::vector<CachedPlanStep> steps;
    const std::size_t count = std::min(result.sequence.size(), result.cache_preconditions.size());
    for (std::size_t index = 0; index < count; ++index) {
        const std::string signature = value_action_signature(result.sequence[index]);
        if (!removed_selected && signature == selected_signature) {
            removed_selected = true;
            continue;
        }
        steps.push_back({result.sequence[index], result.cache_preconditions[index], signature});
    }
    if (!steps.empty())
        update.entry = CachedPlanEntry{std::move(steps), revision};
    return update;
}

void MatchMemory::commit_plan_cache_update(PlanCacheUpdate update) {
    if (update.key.empty())
        return;
    if (!update.entry.has_value()) {
        turn_plan_cache_.erase(update.key);
        turn_plan_cache_order_.erase(
            std::remove(turn_plan_cache_order_.begin(), turn_plan_cache_order_.end(), update.key),
            turn_plan_cache_order_.end());
        return;
    }
    if (turn_plan_cache_.find(update.key) == turn_plan_cache_.end()) {
        turn_plan_cache_order_.push_back(update.key);
    }
    turn_plan_cache_[update.key] = std::move(*update.entry);
    while (turn_plan_cache_order_.size() > 8) {
        turn_plan_cache_.erase(turn_plan_cache_order_.front());
        turn_plan_cache_order_.erase(turn_plan_cache_order_.begin());
    }
}

void MatchMemory::reset() {
    action_cycle_ledger_.clear();
    action_cycle_order_.clear();
    turn_plan_cache_.clear();
    turn_plan_cache_order_.clear();
    deck_inspection_memory_ = {};
}
} // namespace ptcg::ai
