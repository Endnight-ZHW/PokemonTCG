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

namespace ptcg::ai::game_detail {

using Array = Value::Array;
using Object = Value::Object;

bool ability_is_discard_revive(const Value &ability) {
    const Value *effects = ability.find("compiled_effects");
    if (effects == nullptr || !effects->is_array()) {
        return false;
    }
    for (const Value &effect : effects->as_array()) {
        if (effect.is_object() && string_arg(effect, "op")
            == "discard_then_revive") {
            return true;
        }
    }
    return false;
}

bool rare_candy_has_target(
    const Value &cards,
    const Value &owner,
    std::size_t source_index
) {
    const Array &hand = required(owner, "hand").as_array();
    std::vector<std::string> basic_names;
    std::vector<std::pair<std::string, const Value *>> pokemon_rows;
    append_pokemon_rows(owner, pokemon_rows);
    for (const auto &[slot, pokemon_value] : pokemon_rows) {
        (void)slot;
        if (
            bool_arg(*pokemon_value, "placed_this_turn")
            || !bool_arg(
                *pokemon_value,
                "can_evolve_this_turn",
                true
            )
        ) {
            continue;
        }
        const Value *definition = card_definition(
            cards,
            string_arg(*pokemon_value, "card_id")
        );
        if (definition != nullptr && is_basic_pokemon(*definition)) {
            basic_names.push_back(string_arg(*definition, "name"));
        }
    }
    if (basic_names.empty()) {
        return false;
    }
    for (std::size_t index = 0; index < hand.size(); ++index) {
        if (index == source_index) {
            continue;
        }
        const Value *stage_two = card_definition(
            cards,
            hand[index].string_or()
        );
        if (
            stage_two == nullptr
            || !card_has_subtype(*stage_two, "Stage 2")
        ) {
            continue;
        }
        const std::string stage_one_name = string_arg(
            *stage_two,
            "evolves_from"
        );
        for (const auto &[card_id, candidate] : cards.as_object()) {
            (void)card_id;
            if (
                !candidate.is_object()
                || string_arg(candidate, "name") != stage_one_name
            ) {
                continue;
            }
            const std::string basic_name = string_arg(
                candidate,
                "evolves_from"
            );
            if (
                std::find(
                    basic_names.begin(),
                    basic_names.end(),
                    basic_name
                ) != basic_names.end()
            ) {
                return true;
            }
        }
    }
    return false;
}

bool card_matches_filter(
    const Value &cards,
    const Value &card_id,
    const std::string &filter,
    const std::string &filter_name
) {
    const Value *card = card_definition(cards, card_id.string_or());
    if (card == nullptr) {
        return false;
    }
    if (!filter_name.empty()) {
        return string_arg(*card, "name") == filter_name;
    }
    std::string normalized = filter;
    std::transform(
        normalized.begin(),
        normalized.end(),
        normalized.begin(),
        [](unsigned char value) {
            return static_cast<char>(std::tolower(value));
        }
    );
    bool basic_typed_energy = false;
    if (
        normalized.rfind("basic_", 0) == 0
        && normalized != "basic_energy"
    ) {
        basic_typed_energy = true;
        normalized = normalized.substr(6);
    }
    if (normalized.empty() || normalized == "any") {
        return true;
    }
    const bool pokemon_card = is_pokemon_card(*card);
    const bool energy_card = is_energy_card(*card);
    const bool basic_energy = (
        energy_card && card_has_subtype(*card, "Basic")
    );
    if (normalized == "basic_pokemon") {
        return is_basic_pokemon(*card);
    }
    if (normalized == "pokemon") {
        return pokemon_card;
    }
    if (
        normalized == "basic"
        || normalized == "basic_energy"
        || normalized == "basic_energy_card"
    ) {
        return basic_energy;
    }
    if (
        normalized == "energy"
        || normalized == "energy_card"
    ) {
        return energy_card;
    }
    if (normalized == "supporter") {
        return is_supporter_card(*card);
    }
    if (normalized == "item") {
        return (
            is_trainer_card(*card)
            && string_arg(*card, "trainer_type") == "Item"
        );
    }
    if (normalized == "item_or_tool") {
        return (
            is_tool_card(*card)
            || (
                is_trainer_card(*card)
                && string_arg(*card, "trainer_type") == "Item"
            )
        );
    }
    if (normalized == "pokemon_and_energy") {
        return pokemon_card || basic_energy;
    }
    if (normalized == "grass_pokemon") {
        return (
            pokemon_card
            && array_contains_string(card->find("energy_types"), "Grass")
        );
    }
    if (normalized == "water_pokemon_and_energy") {
        return (
            (
                pokemon_card
                && array_contains_string(
                    card->find("energy_types"),
                    "Water"
                )
            )
            || (
                energy_card
                && array_contains_string(
                    card->find("provides_energy"),
                    "Water"
                )
            )
        );
    }
    constexpr std::string_view suffix = "_energy";
    if (
        normalized.size() > suffix.size()
        && normalized.compare(
            normalized.size() - suffix.size(),
            suffix.size(),
            suffix
        ) == 0
    ) {
        normalized.resize(normalized.size() - suffix.size());
        if (normalized == "basic") {
            return basic_energy;
        }
        const Value *provided = card->find("provides_energy");
        if (provided == nullptr || !provided->is_array()) {
            return false;
        }
        return std::any_of(
            provided->as_array().begin(),
            provided->as_array().end(),
            [&normalized](const Value &unit) {
                std::string available = unit.string_or();
                std::transform(
                    available.begin(),
                    available.end(),
                    available.begin(),
                    [](unsigned char value) {
                        return static_cast<char>(std::tolower(value));
                    }
                );
                return available == normalized;
            }
        );
    }
    const bool named_energy_type = (
        normalized == "grass"
        || normalized == "fire"
        || normalized == "water"
        || normalized == "lightning"
        || normalized == "psychic"
        || normalized == "fighting"
        || normalized == "darkness"
        || normalized == "metal"
        || normalized == "dragon"
        || normalized == "colorless"
    );
    if (
        named_energy_type
        && (!energy_card || (basic_typed_energy && !basic_energy))
    ) {
        return false;
    }
    if (energy_card) {
        const Value *provided = card->find("provides_energy");
        if (provided != nullptr && provided->is_array()) {
            return std::any_of(
                provided->as_array().begin(),
                provided->as_array().end(),
                [&normalized](const Value &unit) {
                    std::string available = unit.string_or();
                    std::transform(
                        available.begin(),
                        available.end(),
                        available.begin(),
                        [](unsigned char value) {
                            return static_cast<char>(
                                std::tolower(value)
                            );
                        }
                    );
                    return available == normalized;
                }
            );
        }
    }
    return true;
}

bool zone_has_matching_card(
    const Value &cards,
    const Value &owner,
    const std::string &zone,
    const Value &args
) {
    const Value *rows = owner.find(zone);
    if (rows == nullptr || !rows->is_array()) {
        return false;
    }
    const std::string filter = string_arg(args, "filter", "any");
    const std::string filter_name = string_arg(args, "filter_name");
    return std::any_of(
        rows->as_array().begin(),
        rows->as_array().end(),
        [&cards, &filter, &filter_name](const Value &card_id) {
            return card_matches_filter(
                cards,
                card_id,
                filter,
                filter_name
            );
        }
    );
}

std::size_t occupied_bench_count(const Value &owner) {
    const Value *bench = owner.find("bench");
    if (bench == nullptr || !bench->is_array()) {
        return 0;
    }
    return static_cast<std::size_t>(std::count_if(
        bench->as_array().begin(),
        bench->as_array().end(),
        [](const Value &row) {
            return row.is_object();
        }
    ));
}

bool pokemon_matches_type(
    const Value &cards,
    const Value &pokemon_value,
    const std::string &required_type
) {
    if (required_type.empty()) {
        return true;
    }
    const Value *card = card_definition(
        cards,
        string_arg(pokemon_value, "card_id")
    );
    return (
        card != nullptr
        && array_contains_string(
            card->find("energy_types"),
            required_type
        )
    );
}

bool has_energy_target(
    const Value &cards,
    const Value &owner,
    const Value &args,
    const std::string &source_slot
) {
    const std::string target = string_arg(
        args,
        "target",
        string_arg(args, "to", "self")
    );
    const std::string effective_target = (
        string_arg(args, "destination") == "bench_energy"
    ) ? "bench" : target;
    const std::string required_type = string_arg(
        args,
        "target_pokemon_type"
    );
    std::vector<std::pair<std::string, const Value *>> rows;
    append_pokemon_rows(owner, rows);
    return std::any_of(
        rows.begin(),
        rows.end(),
        [
            &cards,
            &effective_target,
            &required_type,
            &source_slot
        ](const auto &row) {
            if (
                effective_target == "self"
                && row.first != (
                    source_slot.empty() ? "active" : source_slot
                )
            ) {
                return false;
            }
            if (
                effective_target == "bench"
                && row.first.rfind("bench_", 0) != 0
            ) {
                return false;
            }
            if (
                effective_target == "self_basic"
                && (
                    card_definition(
                        cards,
                        string_arg(*row.second, "card_id")
                    ) == nullptr
                    || !is_basic_pokemon(*card_definition(
                        cards,
                        string_arg(*row.second, "card_id")
                    ))
                )
            ) {
                return false;
            }
            return pokemon_matches_type(
                cards,
                *row.second,
                required_type
            );
        }
    );
}

bool previous_turn_had_knockout(
    const Value &state,
    std::int32_t actor
) {
    const Value *book = state.find("turn_fact_book");
    const Value *previous = (
        book != nullptr && book->is_object()
    ) ? book->find("previous_turn") : nullptr;
    const Value *knockouts = (
        previous != nullptr && previous->is_object()
    ) ? previous->find("knockouts") : nullptr;
    if (knockouts == nullptr || !knockouts->is_array()) {
        return false;
    }
    return std::any_of(
        knockouts->as_array().begin(),
        knockouts->as_array().end(),
        [actor](const Value &fact) {
            return (
                fact.is_object()
                && integer_arg(fact, "defeated_player", -1) == actor
                && integer_arg(fact, "source_player", -1) >= 0
            );
        }
    );
}

bool effect_list_has_visible_target(
    const Value &cards,
    const Value &state,
    std::int32_t actor,
    const Value &effects,
    std::size_t source_hand_index,
    const std::string &source_slot
);

bool effect_has_visible_target(
    const Value &cards,
    const Value &state,
    std::int32_t actor,
    const Value &effect,
    std::size_t source_hand_index,
    const std::string &source_slot
) {
    if (!effect.is_object()) {
        return false;
    }
    const std::string op = string_arg(effect, "op");
    const Value empty_args = Value::make_object();
    const Value *args_value = effect.find("args");
    const Value &args = (
        args_value != nullptr && args_value->is_object()
    ) ? *args_value : empty_args;
    const Value &owner = player(state, actor);
    const Value &opponent = player(state, 1 - actor);
    const std::int64_t visible_hand_size = static_cast<std::int64_t>(
        required(owner, "hand").as_array().size());
    const bool source_is_hand_card = source_hand_index
        < required(owner, "hand").as_array().size();
    const std::int64_t post_play_hand_size = std::max<std::int64_t>(
        0,
        visible_hand_size - (source_is_hand_card ? 1 : 0)
    );
    const bool own_deck_has_card = !required(
        owner, "deck").as_array().empty();
    if (op == "draw_cards") {
        return own_deck_has_card;
    }
    if (op == "draw_until") {
        return own_deck_has_card
            && post_play_hand_size
                < integer_arg(args, "target_hand_size");
    }
    if (op == "draw_until_more_than_opponent") {
        return own_deck_has_card
            && post_play_hand_size
                < static_cast<std::int64_t>(
                    required(opponent, "hand").as_array().size() + 1);
    }
    if (op == "trekking_shoes") {
        return own_deck_has_card;
    }
    if (op == "discard_then_draw_cards") {
        return own_deck_has_card
            || (bool_arg(args, "discard_hand") && post_play_hand_size > 0)
            || (!bool_arg(args, "discard_hand") && post_play_hand_size > 0);
    }
    if (op == "shuffle_then_draw_cards") {
        return own_deck_has_card || post_play_hand_size > 0;
    }
    if (op == "judge") {
        return own_deck_has_card
            || !required(opponent, "deck").as_array().empty()
            || post_play_hand_size > 0
            || !required(opponent, "hand").as_array().empty();
    }
    if (
        op == "register_tool_modifier"
        || op == "register_tool_exp_share"
    ) {
        return true;
    }
    if (op == "look_top_deck") {
        if (
            string_arg(args, "destination", "hand")
                == "bench_energy"
            && !has_energy_target(cards, owner, args, source_slot)
        ) {
            return false;
        }
        return (
            integer_arg(args, "count", 1) > 0
            && !required(owner, "deck").as_array().empty()
        );
    }
    if (op == "search_item_and_tool") {
        return !required(owner, "deck").as_array().empty();
    }
    if (op == "search_cards") {
        const std::string destination = string_arg(
            args,
            "destination",
            "hand"
        );
        if (
            destination == "bench"
            && occupied_bench_count(owner) >= 5
        ) {
            return false;
        }
        const std::string from_zone = string_arg(
            args,
            "from_zone",
            "deck"
        );
        if (from_zone == "deck") {
            return (
                integer_arg(args, "count", 1) > 0
                && !required(owner, "deck").as_array().empty()
            );
        }
        return zone_has_matching_card(
            cards,
            owner,
            from_zone,
            args
        );
    }
    if (op == "shuffle_from_discard_to_deck") {
        return zone_has_matching_card(
            cards,
            owner,
            "discard",
            args
        );
    }
    if (op == "switch_pokemon") {
        const Value &target_owner = string_arg(args, "target", "self")
            == "opponent" ? opponent : owner;
        return (
            target_owner.find("active") != nullptr
            && target_owner.find("active")->is_object()
            && occupied_bench_count(target_owner) > 0
        );
    }
    if (op == "choose_heal_damage" || op == "heal_all") {
        std::vector<std::pair<std::string, const Value *>> rows;
        append_pokemon_rows(owner, rows);
        return std::any_of(
            rows.begin(),
            rows.end(),
            [](const auto &row) {
                return integer_arg(*row.second, "damage_counters") > 0;
            }
        );
    }
    if (op == "heal_damage") {
        const std::string target = string_arg(args, "target", "self");
        std::vector<std::pair<std::string, const Value *>> rows;
        append_pokemon_rows(owner, rows);
        return std::any_of(
            rows.begin(),
            rows.end(),
            [&target, &source_slot](const auto &row) {
                if (
                    target == "self"
                    && row.first != (
                        source_slot.empty() ? "active" : source_slot
                    )
                ) {
                    return false;
                }
                return integer_arg(*row.second, "damage_counters") > 0;
            }
        );
    }
    if (op == "attach_energy") {
        const std::string from_zone = string_arg(
            args,
            "from_zone",
            "hand"
        );
        if (!zone_has_matching_card(
                cards,
                owner,
                from_zone,
                args
            )) {
            // A deck search may legally fail because its contents are hidden.
            // A required attachment from the public hand (Xatu's Clairvoyant
            // Sense) cannot be activated without the specified Energy.
            return from_zone == "deck"
                || bool_arg(args, "optional")
                || args.find("min_select") != nullptr;
        }
        return has_energy_target(cards, owner, args, source_slot);
    }
    if (op == "attach_energy_from_discard") {
        return (
            has_energy_target(cards, owner, args, source_slot)
            && zone_has_matching_card(
                cards,
                owner,
                "discard",
                Value(Value::Object{
                    {
                        "filter",
                        Value(string_arg(
                            args,
                            "energy_type",
                            "any"
                        ))
                    },
                })
            )
        );
    }
    if (op == "relocate_energy") {
        std::vector<std::pair<std::string, const Value *>> rows;
        append_pokemon_rows(owner, rows);
        if (rows.size() < 2) {
            return false;
        }
        const std::string energy_type = string_arg(
            args,
            "energy_type",
            "any"
        );
        return std::any_of(
            rows.begin(),
            rows.end(),
            [&cards, &energy_type](const auto &row) {
                return pokemon_has_matching_attached_energy(
                    cards,
                    *row.second,
                    energy_type
                );
            }
        );
    }
    if (op == "evolve_skip_stage") {
        if (is_player_first_turn(state, actor)) {
            return false;
        }
        return rare_candy_has_target(
            cards,
            owner,
            source_hand_index
        );
    }
    if (op == "hand_to_bottom_then_draw") {
        return required(owner, "hand").as_array().size() > 1;
    }
    if (op == "hand_to_bottom_draw_until") {
        // The legality probe runs before the Supporter itself leaves the hand.
        // Houb only requires one *other* card to put on the bottom.
        return required(owner, "hand").as_array().size() > 1;
    }
    if (op == "zinnia_resolve") {
        return required(owner, "hand").as_array().size() > 2;
    }
    if (op == "recover_clara") {
        const Value &discard = required(owner, "discard");
        return std::any_of(
            discard.as_array().begin(),
            discard.as_array().end(),
            [&cards](const Value &card_id) {
                const Value *card = card_definition(
                    cards,
                    card_id.string_or()
                );
                return (
                    card != nullptr
                    && (
                        is_pokemon_card(*card)
                        || (
                            is_energy_card(*card)
                            && card_has_subtype(*card, "Basic")
                        )
                    )
                );
            }
        );
    }
    if (op == "draw_and_attach_energy") {
        // Gardenia's Vigor can always be used for its leading draw while the
        // deck has a card. The optional attachment is conditional on actually
        // drawing and does not require a Bench target at play time.
        return !required(owner, "deck").as_array().empty();
    }
    if (op == "flip_coin") {
        const Value *branches = effect.find("branches");
        if (branches == nullptr || !branches->is_object()) {
            return true;
        }
        for (const auto &[name, branch] : branches->as_object()) {
            (void)name;
            if (
                branch.is_array()
                && effect_list_has_visible_target(
                    cards,
                    state,
                    actor,
                    branch,
                    source_hand_index,
                    source_slot
                )
            ) {
                return true;
            }
        }
        return false;
    }
    if (op == "flip_coin_then_discard_energy") {
        std::vector<std::pair<std::string, const Value *>> rows;
        append_pokemon_rows(opponent, rows);
        return std::any_of(
            rows.begin(),
            rows.end(),
            [](const auto &row) {
                const Value *energy = row.second->find("energy_card_ids");
                return (
                    energy != nullptr
                    && energy->is_array()
                    && !energy->as_array().empty()
                );
            }
        );
    }
    if (op == "conditional") {
        const std::string condition = string_arg(args, "condition");
        if (
            condition == "ko_last_opponent_turn"
            && !previous_turn_had_knockout(state, actor)
        ) {
            return false;
        }
        const Value *branches = effect.find("branches");
        if (branches == nullptr || !branches->is_object()) {
            return true;
        }
        const Value *cost = branches->find("cost");
        if (cost != nullptr && cost->is_array()) {
            for (const Value &cost_effect : cost->as_array()) {
                if (
                    string_arg(cost_effect, "op") == "discard_cards"
                ) {
                    const Value *cost_args = cost_effect.find("args");
                    const std::int64_t amount = (
                        cost_args != nullptr && cost_args->is_object()
                    ) ? integer_arg(*cost_args, "amount") : 0;
                    if (
                        static_cast<std::int64_t>(
                            required(owner, "hand").as_array().size()
                        ) - 1 < amount
                    ) {
                        return false;
                    }
                }
            }
        }
        const Value *on_pay = branches->find("on_pay");
        if (on_pay != nullptr && on_pay->is_array()) {
            for (const Value &paid_effect : on_pay->as_array()) {
                if (
                    string_arg(paid_effect, "op")
                        != "attach_energy_from_discard"
                ) {
                    continue;
                }
                const Value *paid_args = paid_effect.find("args");
                const bool optional_attach = paid_args != nullptr
                    && paid_args->is_object()
                    && (
                        bool_arg(*paid_args, "optional")
                        || paid_args->find("min_select") != nullptr
                    );
                if (
                    !optional_attach
                    && !effect_has_visible_target(
                        cards,
                        state,
                        actor,
                        paid_effect,
                        source_hand_index,
                        source_slot
                    )
                ) {
                    return false;
                }
            }
        }
        return (
            on_pay == nullptr
            || !on_pay->is_array()
            || effect_list_has_visible_target(
                cards,
                state,
                actor,
                *on_pay,
                source_hand_index,
                source_slot
            )
        );
    }
    return true;
}

bool effect_list_has_visible_target(
    const Value &cards,
    const Value &state,
    std::int32_t actor,
    const Value &effects,
    std::size_t source_hand_index,
    const std::string &source_slot
) {
    if (!effects.is_array() || effects.as_array().empty()) {
        return true;
    }
    bool has_visible_effect = false;
    for (const Value &effect : effects.as_array()) {
        has_visible_effect = has_visible_effect
            || effect_has_visible_target(
                cards,
                state,
                actor,
                effect,
                source_hand_index,
                source_slot
            );
    }
    return has_visible_effect;
}

bool ability_effect_list_has_visible_target(
    const Value &cards,
    const Value &state,
    std::int32_t actor,
    const Value &effects,
    const std::string &source_slot
) {
    if (!effects.is_array() || effects.as_array().empty()) {
        return true;
    }
    // Required attachment abilities need both their public source and target;
    // later effects do not make an unpayable attachment legal.
    for (const Value &effect : effects.as_array()) {
        if (
            string_arg(effect, "op") == "attach_energy"
            && !effect_has_visible_target(
                cards,
                state,
                actor,
                effect,
                std::numeric_limits<std::size_t>::max(),
                source_slot
            )
        ) {
            return false;
        }
    }
    return effect_list_has_visible_target(
        cards,
        state,
        actor,
        effects,
        std::numeric_limits<std::size_t>::max(),
        source_slot
    );
}

bool stadium_has_activation(const Value &card) {
    const Value *effects = card.find("compiled_trainer_effects");
    if (effects == nullptr || !effects->is_array()) {
        return false;
    }
    for (const Value &effect : effects->as_array()) {
        if (!effect.is_object()) {
            continue;
        }
        const std::string op = string_arg(effect, "op");
        if (op != "stadium" && op != "set_stadium") {
            return true;
        }
    }
    return false;
}

std::string stable_choice_option_id(
    const Value &option,
    const std::string &request_type
) {
    std::string result = string_arg(option, "option_id");
    if (!result.empty()) {
        return result;
    }
    const Value *nested_ref = option.find("ref");
    const Value &ref = (
        nested_ref != nullptr && nested_ref->is_object()
    ) ? *nested_ref : option;
    const std::string kind = string_arg(ref, "kind");
    const std::int64_t owner = integer_arg(ref, "player", -1);
    if (request_type == "select_retreat_payment") {
        return "retreat:energy:" + std::to_string(
            integer_arg(ref, "index", -1)
        );
    }
    if (kind == "card") {
        return "card:" + std::to_string(owner)
            + ":" + string_arg(ref, "zone")
            + ":" + std::to_string(integer_arg(ref, "index", -1))
            + ":" + string_arg(ref, "card_id");
    }
    if (kind == "pokemon") {
        return "pokemon:" + std::to_string(owner)
            + ":" + string_arg(ref, "slot")
            + ":" + string_arg(ref, "card_id");
    }
    if (kind == "slot") {
        return "slot:" + std::to_string(owner)
            + ":" + string_arg(ref, "slot");
    }
    if (kind == "attachment") {
        return "attachment:" + std::to_string(owner)
            + ":" + string_arg(ref, "slot")
            + ":" + string_arg(ref, "attachment_type")
            + ":" + std::to_string(integer_arg(ref, "index", -1))
            + ":" + string_arg(ref, "card_id");
    }
    return {};
}

void append_choice_candidate(
    Array &result,
    const std::string &request_id,
    const std::string &request_type,
    const std::vector<const Value *> &selected,
    bool cancelled
) {
    Array option_ids;
    std::string signature = "choice:" + request_id + ":";
    for (std::size_t index = 0; index < selected.size(); ++index) {
        const std::string option_id = stable_choice_option_id(
            *selected[index],
            request_type
        );
        if (option_id.empty()) {
            throw std::invalid_argument(
                "choice_option_signature_unavailable"
            );
        }
        option_ids.emplace_back(option_id);
        if (index > 0) {
            signature += "|";
        }
        signature += option_id;
    }
    if (cancelled) {
        signature += "cancel";
    }
    Object candidate{
        {"kind", Value("choice")},
        {"signature", Value(signature)},
        {"request_id", Value(request_id)},
        {"request_type", Value(request_type)},
        {"selected_options", Value(std::move(option_ids))},
        {"cancelled", Value(cancelled)},
    };
    if (!selected.empty()) {
        const Value *ref = selected.front()->find("ref");
        candidate["ref"] = ref != nullptr ? *ref : Value();
    } else {
        candidate["ref"] = Value();
    }
    result.emplace_back(std::move(candidate));
}


} // namespace ptcg::ai::game_detail
