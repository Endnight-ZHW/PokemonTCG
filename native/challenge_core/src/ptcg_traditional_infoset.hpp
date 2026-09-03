#pragma once

#include "ptcg_value.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>

namespace ptcg::ai {

// Exact native counterpart of AIInformationSet for the production
// turn_beam_v2 path.  It accepts only a public observation (either the
// ai_public_state_v1 worker boundary or an already-sanitized test view),
// rebuilds hidden multisets from published deck lists, and emits restorable
// Snapshot 3 determinizations.  No authoritative hidden identity is retained.
class TraditionalInformationSet {
public:
    TraditionalInformationSet() = default;

    bool capture(
        const Value &public_state,
        std::int32_t perspective,
        const Value &catalog,
        const Value &decks,
        const Value &legal_actions,
        const Value &public_history,
        std::int64_t match_seed,
        std::string *error = nullptr
    );

    bool valid() const noexcept;
    std::int32_t perspective() const noexcept;
    std::int64_t match_seed() const noexcept;
    const Value &public_snapshot() const noexcept;
    const Value::Array &remaining_pool(std::int32_t player) const;
    const Value::Array &known_hand(std::int32_t player) const;
    std::size_t hand_count(std::int32_t player) const;
    std::size_t unknown_hand_count(std::int32_t player) const;
    std::size_t recommended_belief_samples(
        std::int32_t player,
        std::size_t requested
    ) const;
    bool has_published_deck(std::int32_t player) const noexcept;

    // Owner-only deck inspection is additional private information supplied by
    // ChoiceView v2.  It constrains only the acting player's hidden deck/prize
    // split; legal choices continue to come exclusively from ChoiceView.options.
    bool apply_deck_inspection(
        const Value &choice_view,
        std::string *error = nullptr
    );
    bool apply_known_prizes(
        const Value::Array &prize_cards,
        std::string *error = nullptr
    );
    bool has_exact_hidden_zones(std::int32_t player) const noexcept;
    const Value::Array &known_deck(std::int32_t player) const;
    const Value::Array &known_prizes(std::int32_t player) const;

    Value sample_state(std::uint32_t seed) const;

private:
    Value public_snapshot_ = Value::make_object();
    std::array<Value::Array, 2> remaining_pools_{};
    std::array<Value::Array, 2> known_hands_{};
    std::array<Value::Array, 2> exact_decks_{};
    std::array<Value::Array, 2> exact_prizes_{};
    std::array<bool, 2> published_deck_valid_{};
    std::array<bool, 2> exact_hidden_zones_valid_{};
    std::string fallback_card_id_ = "sv1-ener-1";
    std::int32_t perspective_ = -1;
    std::int64_t match_seed_ = 0;
    bool valid_ = false;
};

} // namespace ptcg::ai
