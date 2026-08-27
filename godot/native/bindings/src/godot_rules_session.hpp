#pragma once

#include "ptcg_rules_session.hpp"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include <memory>

namespace godot {

// Thin GDExtension boundary for the dependency-free ptcg_core session.  This
// type converts immutable DTOs only; authoritative state and RNG never leave
// the C++ session for mutation by GDScript.
class NativeRulesSession : public RefCounted {
    GDCLASS(NativeRulesSession, RefCounted)

protected:
    static void _bind_methods();

public:
    NativeRulesSession();

    bool set_catalog(const Dictionary &catalog);
    Dictionary create(
        const Dictionary &catalog,
        const Array &decks,
        const Dictionary &match_config,
        int64_t seed
    );
    Dictionary load_scenario(
        const Dictionary &snapshot,
        int64_t rng_state,
        const Dictionary &match_config
    );
    Dictionary legal_actions(int64_t actor) const;
    int64_t pokemon_max_hp(const Dictionary &pokemon) const;
    int64_t pokemon_current_hp(const Dictionary &pokemon) const;
    int64_t estimate_public_damage(
        int64_t actor,
        const Dictionary &attacker,
        const Dictionary &defender,
        int64_t base_damage
    ) const;
    Variant pending_choice(int64_t viewer) const;
    Dictionary apply_action(const Dictionary &action);
    Dictionary apply_choice(const Dictionary &response);
    Dictionary surrender(int64_t actor);
    Dictionary view_for(int64_t viewer) const;
    Dictionary snapshot() const;
    bool restore(const Dictionary &snapshot, int64_t rng_state);
    Ref<NativeRulesSession> fork() const;
    Ref<NativeRulesSession> fork_for_search(int64_t rng_state) const;
    Dictionary fork_apply_action_for_search(
        const Dictionary &action,
        int64_t rng_state
    ) const;
    Dictionary journal() const;
    Dictionary get_contract() const;
    String state_hash() const;
    int64_t rng_state() const;
    int64_t revision() const;
    bool is_initialized() const;

private:
    std::unique_ptr<ptcg::ai::RulesSession> session_;
};

} // namespace godot
