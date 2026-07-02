#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>

namespace godot {

class ChallengeAIMath : public RefCounted {
    GDCLASS(ChallengeAIMath, RefCounted)

protected:
    static void _bind_methods();

public:
    double pokemon_strength(double current_hp, double best_damage, double energy_count) const;
    double evaluate_board_features(
        double prize_delta,
        double hand_delta,
        double deck_delta,
        const PackedFloat64Array &own_features,
        const PackedFloat64Array &opponent_features
    ) const;
};

} // namespace godot
