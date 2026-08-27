#include "ptcg_rules_session.hpp"

#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace ptcg::ai {
namespace {

std::int64_t integer_field(
    const Value &value,
    const char *key,
    std::int64_t fallback = 0
) {
    const Value *entry = value.find(key);
    return entry == nullptr ? fallback : entry->as_integer(fallback);
}

std::string string_field(
    const Value &value,
    const char *key,
    std::string fallback = {}
) {
    const Value *entry = value.find(key);
    return entry == nullptr ? std::move(fallback)
                            : entry->string_or(std::move(fallback));
}

} // namespace

bool RulesSession::populate_legal_cache(std::int32_t actor) const {
    if (!initialized_ || actor < 0 || actor > 1 || !pending_.is_null()) {
        return false;
    }
    if (legal_cache_revision_ == revision()
        && legal_cache_actor_ == actor
        && legal_cache_candidates_.is_array()) {
        return true;
    }
    Value candidates = game().legal_actions(state_, actor);
    if (!candidates.is_array()) return false;
    std::vector<typed::Action> typed_candidates;
    typed_candidates.reserve(candidates.as_array().size());
    for (const Value &candidate : candidates.as_array()) {
        typed::Action typed_candidate;
        std::string error;
        if (!catalog_->state_codec.decode_action(
                candidate, typed_candidate, &error)) {
            legal_cache_revision_ = -1;
            legal_cache_actor_ = -1;
            legal_cache_candidates_ = Value::make_array();
            typed_legal_cache_.reset();
            return false;
        }
        typed_candidates.push_back(std::move(typed_candidate));
    }
    legal_cache_revision_ = revision();
    legal_cache_actor_ = actor;
    legal_cache_candidates_ = std::move(candidates);
    typed_legal_cache_ = std::make_shared<const std::vector<typed::Action>>(
        std::move(typed_candidates));
    return true;
}

const Value &RulesSession::search_legal_action_candidates(
    std::int32_t actor
) const {
    static const Value empty = Value::make_array();
    return populate_legal_cache(actor) ? legal_cache_candidates_ : empty;
}

std::int64_t RulesSession::pokemon_max_hp(const Value &pokemon) const {
    return game().pokemon_max_hp(pokemon);
}

std::int64_t RulesSession::pokemon_current_hp(const Value &pokemon) const {
    return game().pokemon_current_hp(pokemon);
}

std::int64_t RulesSession::estimate_public_damage(
    std::int32_t actor,
    const Value &attacker,
    const Value &defender,
    std::int64_t base_damage
) const {
    return initialized_ ? game().estimate_public_damage(
        state_, actor, attacker, defender, base_damage) : 0;
}

Value RulesSession::pending_choice(std::int32_t viewer) const {
    if (!initialized_ || viewer < 0 || viewer > 1 || pending_.is_null()
        || integer_field(pending_, "player", -1) != viewer) {
        return Value();
    }
    return pending_.deep_clone();
}

const Value &RulesSession::search_pending_choice(
    std::int32_t viewer
) const noexcept {
    static const Value none;
    if (!initialized_ || viewer < 0 || viewer > 1 || pending_.is_null()
        || integer_field(pending_, "player", -1) != viewer) {
        return none;
    }
    return pending_;
}

const typed::ChoiceView *RulesSession::typed_search_pending_choice(
    std::int32_t viewer
) const {
    const Value &pending = search_pending_choice(viewer);
    if (pending.is_null()) return nullptr;
    const std::int64_t current_revision = revision();
    const std::string request_id = string_field(pending, "request_id");
    if (typed_pending_cache_.has_value()
        && typed_pending_cache_revision_ == current_revision
        && typed_pending_cache_request_id_ == request_id) {
        return &*typed_pending_cache_;
    }
    typed::ChoiceView decoded;
    std::string error;
    if (!catalog_ || !catalog_->state_codec.decode_choice_view(
            pending, decoded, &error)) {
        throw std::runtime_error(error.empty()
            ? "typed_choice_decode_failed" : error);
    }
    typed_pending_cache_ = std::move(decoded);
    typed_pending_cache_revision_ = current_revision;
    typed_pending_cache_request_id_ = request_id;
    return &*typed_pending_cache_;
}

Value RulesSession::search_continuation() const {
    return continuation_.deep_clone();
}

} // namespace ptcg::ai
