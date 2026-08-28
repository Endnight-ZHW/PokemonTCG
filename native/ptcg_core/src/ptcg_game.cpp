#include "ptcg_game.hpp"
#include "ptcg_game_internal.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <limits>
#include <stdexcept>
#include <string>
#include <string_view>
#include <unordered_set>
#include <utility>

namespace ptcg::ai {

using namespace game_detail;

NativeGameKernel::NativeGameKernel(Value cards)
    : cards_(cards),
      rules_(std::move(cards)) {}

void NativeGameKernel::set_cards(Value cards) {
    cards_ = cards;
    rules_.set_cards(std::move(cards));
}

std::size_t NativeGameKernel::card_count() const noexcept {
    return cards_.is_object() ? cards_.as_object().size() : 0;
}

std::size_t NativeGameKernel::implemented_op_count() const noexcept {
    return rules_.implemented_op_count();
}

std::size_t NativeGameKernel::required_op_count() noexcept {
    return NativeRulesKernel::required_op_count();
}

std::int64_t NativeGameKernel::pokemon_max_hp(
    const Value &pokemon_value
) const {
    return pokemon_hp(cards_, pokemon_value);
}

std::int64_t NativeGameKernel::pokemon_current_hp(
    const Value &pokemon_value
) const {
    return std::max<std::int64_t>(
        0,
        pokemon_hp(cards_, pokemon_value)
            - integer_arg(pokemon_value, "damage_counters") * 10
    );
}

std::int64_t NativeGameKernel::estimate_public_damage(
    const Value &state,
    std::int32_t actor,
    const Value &attacker,
    const Value &defender,
    std::int64_t base_damage
) const {
    if (!state.is_object() || !attacker.is_object() || !defender.is_object()
        || actor < 0 || actor > 1 || base_damage <= 0) {
        return 0;
    }
    std::int64_t damage = std::max<std::int64_t>(
        0,
        base_damage + attached_attack_damage_delta(
            cards_, state, actor, attacker, true)
            + field_aura_attack_damage_delta(
                cards_, state, actor, attacker, defender, true)
            + aura_damage_reduction_delta(
                cards_, defender, true, true)
            + opponent_active_aura_attack_damage_delta(
                cards_, state, actor, true)
    );
    damage = apply_active_type_matchups(
        cards_, state, attacker, defender, damage, false, false);
    damage = std::max<std::int64_t>(
        0,
        damage + attached_defender_damage_delta(cards_, defender, true)
    );
    return defender_prevents_attack_damage(defender) ? 0 : damage;
}


} // namespace ptcg::ai
