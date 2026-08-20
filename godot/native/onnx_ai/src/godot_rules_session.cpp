#include "godot_rules_session.hpp"

#include "ptcg_godot_value.hpp"

#include <godot_cpp/core/class_db.hpp>

#include <exception>
#include <string>

namespace godot {

namespace {

Dictionary result_dictionary(
    const ptcg::ai::RulesSessionResult &native_result
) {
    Dictionary result;
    result["success"] = native_result.success;
    result["error_code"] = String::utf8(native_result.error_code.c_str());
    result["message_key"] = String::utf8(native_result.message_key.c_str());
    result["state"] = ptcg::ai::value_to_godot(native_result.state);
    result["pending"] = ptcg::ai::value_to_godot(native_result.pending);
    result["events"] = ptcg::ai::value_to_godot(
        ptcg::ai::Value(native_result.events));
    result["rng_state"] = static_cast<int64_t>(native_result.rng_state);
    result["winner"] = static_cast<int64_t>(native_result.winner);
    result["terminal"] = native_result.terminal;
    return result;
}

Dictionary failure_dictionary(const std::string &error_code) {
    Dictionary result;
    result["success"] = false;
    result["error_code"] = String::utf8(error_code.c_str());
    result["message_key"] = String::utf8(error_code.c_str());
    result["state"] = Dictionary();
    result["pending"] = Variant();
    result["events"] = Array();
    result["rng_state"] = int64_t{0};
    result["winner"] = int64_t{-1};
    result["terminal"] = false;
    return result;
}

Dictionary dictionary_from_value(const ptcg::ai::Value &value) {
    const Variant converted = ptcg::ai::value_to_godot(value);
    return converted.get_type() == Variant::DICTIONARY
        ? Dictionary(converted) : Dictionary();
}

} // namespace

NativeRulesSession::NativeRulesSession()
    : session_(std::make_unique<ptcg::ai::RulesSession>()) {}

void NativeRulesSession::_bind_methods() {
    ClassDB::bind_method(
        D_METHOD("set_catalog", "catalog"),
        &NativeRulesSession::set_catalog
    );
    ClassDB::bind_method(
        D_METHOD("create", "catalog", "decks", "match_config", "seed"),
        &NativeRulesSession::create
    );
    ClassDB::bind_method(
        D_METHOD("load_scenario", "snapshot", "rng_state", "match_config"),
        &NativeRulesSession::load_scenario,
        DEFVAL(Dictionary())
    );
    ClassDB::bind_method(
        D_METHOD("legal_actions", "actor"),
        &NativeRulesSession::legal_actions
    );
    ClassDB::bind_method(
        D_METHOD("pokemon_max_hp", "pokemon"),
        &NativeRulesSession::pokemon_max_hp
    );
    ClassDB::bind_method(
        D_METHOD("pokemon_current_hp", "pokemon"),
        &NativeRulesSession::pokemon_current_hp
    );
    ClassDB::bind_method(
        D_METHOD(
            "estimate_public_damage",
            "actor",
            "attacker",
            "defender",
            "base_damage"
        ),
        &NativeRulesSession::estimate_public_damage
    );
    ClassDB::bind_method(
        D_METHOD("pending_choice", "viewer"),
        &NativeRulesSession::pending_choice
    );
    ClassDB::bind_method(
        D_METHOD("apply_action", "action"),
        &NativeRulesSession::apply_action
    );
    ClassDB::bind_method(
        D_METHOD("apply_choice", "response"),
        &NativeRulesSession::apply_choice
    );
    ClassDB::bind_method(
        D_METHOD("surrender", "actor"),
        &NativeRulesSession::surrender
    );
    ClassDB::bind_method(
        D_METHOD("view_for", "viewer"),
        &NativeRulesSession::view_for
    );
    ClassDB::bind_method(D_METHOD("snapshot"), &NativeRulesSession::snapshot);
    ClassDB::bind_method(
        D_METHOD("restore", "snapshot", "rng_state"),
        &NativeRulesSession::restore
    );
    ClassDB::bind_method(D_METHOD("fork"), &NativeRulesSession::fork);
    ClassDB::bind_method(D_METHOD("journal"), &NativeRulesSession::journal);
    ClassDB::bind_method(
        D_METHOD("get_contract"),
        &NativeRulesSession::get_contract
    );
    ClassDB::bind_method(
        D_METHOD("state_hash"),
        &NativeRulesSession::state_hash
    );
    ClassDB::bind_method(
        D_METHOD("rng_state"),
        &NativeRulesSession::rng_state
    );
    ClassDB::bind_method(D_METHOD("revision"), &NativeRulesSession::revision);
    ClassDB::bind_method(
        D_METHOD("is_initialized"),
        &NativeRulesSession::is_initialized
    );
}

bool NativeRulesSession::set_catalog(const Dictionary &catalog) {
    try {
        session_->set_cards(ptcg::ai::value_from_godot(catalog));
        return true;
    } catch (...) {
        return false;
    }
}

Dictionary NativeRulesSession::create(
    const Dictionary &catalog,
    const Array &decks,
    const Dictionary &match_config,
    int64_t seed
) {
    try {
        return result_dictionary(session_->create(
            ptcg::ai::value_from_godot(catalog),
            ptcg::ai::value_from_godot(decks),
            ptcg::ai::value_from_godot(match_config),
            static_cast<std::uint32_t>(seed)
        ));
    } catch (const std::exception &error) {
        return failure_dictionary(error.what());
    }
}

Dictionary NativeRulesSession::load_scenario(
    const Dictionary &snapshot_value,
    int64_t native_rng_state,
    const Dictionary &match_config
) {
    try {
        return result_dictionary(session_->load_scenario(
            ptcg::ai::value_from_godot(snapshot_value),
            static_cast<std::uint32_t>(native_rng_state),
            ptcg::ai::value_from_godot(match_config)
        ));
    } catch (const std::exception &error) {
        return failure_dictionary(error.what());
    }
}

Dictionary NativeRulesSession::legal_actions(int64_t actor) const {
    try {
        return dictionary_from_value(session_->legal_actions(
            static_cast<std::int32_t>(actor)));
    } catch (const std::exception &error) {
        Dictionary failed;
        failed["schema_version"] = int64_t{1};
        failed["success"] = false;
        failed["code"] = String::utf8(error.what());
        failed["message"] = String::utf8(error.what());
        failed["base_revision"] = revision();
        failed["groups"] = Array();
        return failed;
    }
}

int64_t NativeRulesSession::pokemon_max_hp(
    const Dictionary &pokemon
) const {
    try {
        return session_->pokemon_max_hp(
            ptcg::ai::value_from_godot(pokemon));
    } catch (...) {
        return 0;
    }
}

int64_t NativeRulesSession::pokemon_current_hp(
    const Dictionary &pokemon
) const {
    try {
        return session_->pokemon_current_hp(
            ptcg::ai::value_from_godot(pokemon));
    } catch (...) {
        return 0;
    }
}

int64_t NativeRulesSession::estimate_public_damage(
    int64_t actor,
    const Dictionary &attacker,
    const Dictionary &defender,
    int64_t base_damage
) const {
    try {
        return session_->estimate_public_damage(
            static_cast<std::int32_t>(actor),
            ptcg::ai::value_from_godot(attacker),
            ptcg::ai::value_from_godot(defender),
            base_damage
        );
    } catch (...) {
        return 0;
    }
}

Variant NativeRulesSession::pending_choice(int64_t viewer) const {
    try {
        return ptcg::ai::value_to_godot(session_->pending_choice(
            static_cast<std::int32_t>(viewer)));
    } catch (...) {
        return Variant();
    }
}

Dictionary NativeRulesSession::apply_action(const Dictionary &action) {
    try {
        return result_dictionary(session_->apply_action(
            ptcg::ai::value_from_godot(action)));
    } catch (const std::exception &error) {
        return failure_dictionary(error.what());
    }
}

Dictionary NativeRulesSession::apply_choice(const Dictionary &response) {
    try {
        return result_dictionary(session_->apply_choice(
            ptcg::ai::value_from_godot(response)));
    } catch (const std::exception &error) {
        return failure_dictionary(error.what());
    }
}

Dictionary NativeRulesSession::surrender(int64_t actor) {
    try {
        return result_dictionary(session_->concede(
            static_cast<std::int32_t>(actor)));
    } catch (const std::exception &error) {
        return failure_dictionary(error.what());
    }
}

Dictionary NativeRulesSession::view_for(int64_t viewer) const {
    try {
        return dictionary_from_value(session_->view_for(
            static_cast<std::int32_t>(viewer)));
    } catch (...) {
        return Dictionary();
    }
}

Dictionary NativeRulesSession::snapshot() const {
    return dictionary_from_value(session_->snapshot());
}

bool NativeRulesSession::restore(
    const Dictionary &snapshot_value,
    int64_t native_rng_state
) {
    try {
        return session_->restore(
            ptcg::ai::value_from_godot(snapshot_value),
            static_cast<std::uint32_t>(native_rng_state)
        );
    } catch (...) {
        return false;
    }
}

Ref<NativeRulesSession> NativeRulesSession::fork() const {
    Ref<NativeRulesSession> copy;
    copy.instantiate();
    copy->session_ = session_->fork();
    return copy;
}

Dictionary NativeRulesSession::journal() const {
    return dictionary_from_value(session_->journal());
}

Dictionary NativeRulesSession::get_contract() const {
    return dictionary_from_value(session_->contract());
}

String NativeRulesSession::state_hash() const {
    return String::utf8(session_->state_hash().c_str());
}

int64_t NativeRulesSession::rng_state() const {
    return static_cast<int64_t>(session_->rng_state());
}

int64_t NativeRulesSession::revision() const {
    return session_->revision();
}

bool NativeRulesSession::is_initialized() const {
    return session_->initialized();
}

} // namespace godot
