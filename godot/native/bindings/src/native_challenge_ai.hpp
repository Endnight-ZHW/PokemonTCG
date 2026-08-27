#pragma once

#include "challenge_controller.hpp"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace godot {

// Godot type conversion only; Challenge behavior lives in challenge_core.
class NativeChallengeAI : public RefCounted {
    GDCLASS(NativeChallengeAI, RefCounted)

protected:
    static void _bind_methods();

public:
    Dictionary configure(
        const Dictionary &catalog,
        const Dictionary &decks,
        const Dictionary &strategies
    );
    Dictionary decide(const Dictionary &request, int64_t generation = 1);
    void cancel(int64_t generation) noexcept;
    void reset_match(const String &match_instance_id);
    Dictionary get_contract() const;

private:
    ptcg::ai::ChallengeController controller_;
};

} // namespace godot
