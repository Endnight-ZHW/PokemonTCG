#include "ptcg_rules_session.hpp"

#include <stdexcept>
#include <string>

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

Value RulesSession::contract() const {
    return Value(Value::Object{
        {"native_abi_version", Value(NATIVE_RULES_SESSION_ABI_VERSION)},
        {"protocol_version", Value(6)},
        {"action_schema_version", Value(4)},
        {"choice_view_schema_version", Value(2)},
        {"snapshot_schema_version", Value(SNAPSHOT_SCHEMA_VERSION)},
        {"vm_ir_version", Value(3)},
        {"journal_format_version", Value(MATCH_JOURNAL_FORMAT_VERSION)},
        {"hash_algorithm", Value("fnv1a64-canonical-json")},
        {"typed_state_codec", Value(true)},
        {"typed_authoritative_state", Value(true)},
        {"typed_vm_ir", Value(true)},
        {"typed_vm_program_count", Value(static_cast<std::int64_t>(
            catalog_ ? catalog_->vm_catalog.program_count() : 0))},
        {"typed_vm_command_count", Value(static_cast<std::int64_t>(
            catalog_ ? catalog_->vm_catalog.command_count() : 0))},
        {"typed_action_cache", Value(true)},
        {"typed_choice_cache", Value(true)},
        {"search_candidate_cache", Value(true)},
        {"card_ir_content_fingerprint", Value(card_ir_content_fingerprint_)},
        {"card_ir_contract_fingerprint", Value(card_ir_contract_fingerprint_)},
        {"vm_descriptor_digest", Value(vm_descriptor_digest_)},
        {"state_owner", Value("ptcg_core")},
        {"ai_observation_boundary", Value("ai_public_state_v1")},
        {"framework_dependencies", Value::make_array()},
        {"card_count", Value(static_cast<std::int64_t>(
            cards().is_object() ? cards().as_object().size() : 0))},
        {"implemented_op_count", Value(static_cast<std::int64_t>(
            game().implemented_op_count()))},
        {"required_op_count", Value(static_cast<std::int64_t>(
            NativeGameKernel::required_op_count()))},
    });
}

Value RulesSession::journal() const {
    return Value(Value::Object{
        {"schema", Value("ptcg_match_journal/1")},
        {"format_version", Value(MATCH_JOURNAL_FORMAT_VERSION)},
        {"native_abi_version", Value(NATIVE_RULES_SESSION_ABI_VERSION)},
        {"hash_algorithm", Value("fnv1a64-canonical-json")},
        {"initial_seed", Value(static_cast<std::int64_t>(initial_seed_))},
        {"catalog_fingerprint", Value(string_field(
            match_config_, "catalog_fingerprint"))},
        {"content_fingerprint", Value(card_ir_content_fingerprint_)},
        {"contract_fingerprint", Value(card_ir_contract_fingerprint_)},
        {"vm_descriptor_digest", Value(vm_descriptor_digest_)},
        {"match_config", match_config_.deep_clone()},
        {"entries", journal_entries_.deep_clone()},
    });
}

std::string RulesSession::state_hash() const {
    if (!initialized_ || authoritative_state_ == nullptr || !catalog_) return {};
    return canonical_value_hash(
        catalog_->state_codec.encode_state(*authoritative_state_));
}

std::uint32_t RulesSession::rng_state() const noexcept {
    return rng_state_;
}

std::int64_t RulesSession::revision() const noexcept {
    return initialized_ ? integer_field(state_, "revision", -1) : -1;
}

const Value &RulesSession::search_state() const noexcept {
    return state_;
}

const typed::GameState &RulesSession::typed_search_state() const {
    return typed_state();
}

const typed::GameState &RulesSession::typed_state() const {
    if (!initialized_ || authoritative_state_ == nullptr) {
        throw std::runtime_error("typed_authoritative_state_unavailable");
    }
    return *authoritative_state_;
}

bool RulesSession::commit_authoritative_state(std::string *error) {
    if (!catalog_) {
        if (error != nullptr) *error = "typed_state_catalog_missing";
        return false;
    }
    auto decoded = std::make_shared<typed::GameState>();
    std::string decode_error;
    if (!catalog_->state_codec.decode_state(state_, *decoded, &decode_error)) {
        if (error != nullptr) {
            *error = decode_error.empty()
                ? "typed_state_decode_failed" : decode_error;
        }
        return false;
    }
    authoritative_state_ = std::move(decoded);
    if (error != nullptr) error->clear();
    return true;
}

} // namespace ptcg::ai
