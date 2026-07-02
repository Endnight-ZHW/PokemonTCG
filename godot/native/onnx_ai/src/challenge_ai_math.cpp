#include "challenge_ai_math.hpp"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void ChallengeAIMath::_bind_methods() {
    ClassDB::bind_method(
        D_METHOD("pokemon_strength", "current_hp", "best_damage", "energy_count"),
        &ChallengeAIMath::pokemon_strength
    );
    ClassDB::bind_method(
        D_METHOD(
            "evaluate_board_features",
            "prize_delta",
            "hand_delta",
            "deck_delta",
            "own_features",
            "opponent_features"
        ),
        &ChallengeAIMath::evaluate_board_features
    );
}

double ChallengeAIMath::pokemon_strength(
    double current_hp,
    double best_damage,
    double energy_count
) const {
    return current_hp + best_damage * 2.0 + energy_count * 35.0;
}

double ChallengeAIMath::evaluate_board_features(
    double prize_delta,
    double hand_delta,
    double deck_delta,
    const PackedFloat64Array &own_features,
    const PackedFloat64Array &opponent_features
) const {
    double score = prize_delta * 220.0 + hand_delta * 4.0 + deck_delta * 0.5;
    for (int64_t index = 0; index + 2 < own_features.size(); index += 3) {
        score += pokemon_strength(
            own_features[index],
            own_features[index + 1],
            own_features[index + 2]
        );
    }
    for (int64_t index = 0; index + 2 < opponent_features.size(); index += 3) {
        score -= pokemon_strength(
            opponent_features[index],
            opponent_features[index + 1],
            opponent_features[index + 2]
        );
    }
    return score;
}

} // namespace godot
