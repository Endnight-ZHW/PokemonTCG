#include "ptcg_rules.hpp"
#include "ptcg_rules_internal.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <cmath>
#include <iterator>
#include <limits>
#include <stdexcept>
#include <string_view>
#include <unordered_set>


namespace ptcg::ai::rules_detail {

using Array = Value::Array;
using Object = Value::Object;

bool execute_vm_card_pipeline(
    const Value &cards,
    const Value &command_spec,
    const std::string &op,
    const Value &args,
    std::int32_t actor,
    const std::string &source_slot,
    const std::string &context_mode,
    XorShift32 &rng,
    VmExecutionResult &result,
    bool &early_return
) {
    if (!(
        op == "draw_cards"
        || op == "trigger_draw_cards"
        || op == "draw_until"
        || op == "draw_until_more_than_opponent"
        || op == "evolve_skip_stage"
        || op == "fail_attack"
        || op == "flip_coin"
        || op == "flip_coin_repeat_damage"
        || op == "flip_coin_then_discard_energy"
        || op == "flip_coin_then_ko"
        || op == "flip_until_tails"
        || op == "hand_to_bottom_draw_until"
        || op == "hand_to_bottom_then_draw"
        || op == "heal_all"
        || op == "heal_damage"
        || op == "judge"
        || op == "look_top_attach_energy"
        || op == "look_top_deck"
        || op == "mill_then_damage"
        || op == "place_counters_then_self_discard"
        || op == "place_damage_counters"
        || op == "register_aura_damage_boost"
        || op == "register_aura_damage_reduction"
        || op == "register_conditional_hp_boost"
        || op == "register_conditional_zero_retreat"
        || op == "register_reactive_thorns"
        || op == "register_tool_exp_share"
        || op == "register_tool_modifier"
        || op == "recover_clara"
        || op == "relocate_energy"
    )) return false;
    Value &self = player(result.state, actor);
    Value &opponent = player(result.state, 1 - actor);
    Value *source = pokemon(self, source_slot);
    Value *opponent_active = pokemon(opponent, "active");
    auto suspend = [&result](Value request, Value continuation) {
        increment_integer(result.state, "choice_sequence");
        result.pending = std::move(request);
        result.continuation = std::move(continuation);
    };

        if (
            op == "draw_cards"
            || op == "trigger_draw_cards"
        ) {
            const std::int32_t target = op == "trigger_draw_cards"
                ? static_cast<std::int32_t>(
                    integer_arg(args, "player", actor)
                )
                : (
                    string_arg(args, "player", "self") == "opponent"
                    ? 1 - actor
                    : actor
                );
            const auto drawn = draw_cards(
                player(result.state, target),
                integer_arg(args, "amount", 1)
            );
            append_cards_drawn_event(result, target, drawn, op);
        } else if (
            op == "draw_until"
            || op == "draw_until_more_than_opponent"
        ) {
            const std::int64_t target = op == "draw_until"
                ? integer_arg(args, "target_hand_size")
                : static_cast<std::int64_t>(
                    required(opponent, "hand").as_array().size() + 1
                );
            const std::int64_t current = static_cast<std::int64_t>(
                required(self, "hand").as_array().size()
            );
            const auto drawn = draw_cards(self, std::max<std::int64_t>(
                0,
                target - current
            ));
            append_cards_drawn_event(result, actor, drawn, op);
        } else if (op == "evolve_skip_stage") {
            Array options = rare_candy_options(
                cards,
                self,
                actor
            );
            suspend(
                pending_request(
                    "evolve_skip_stage",
                    actor,
                    1,
                    1,
                    false,
                    false,
                    std::move(options),
                    "evolve_skip_stage"
                ),
                make_continuation(
                    op,
                    command_spec,
                    actor,
                    source_slot
                )
            );
        } else if (op == "fail_attack") {
            result.context["attack_failed"] = Value(true);
        } else if (
            op == "flip_coin"
            || op == "flip_coin_repeat_damage"
            || op == "flip_coin_then_discard_energy"
            || op == "flip_coin_then_ko"
            || op == "flip_until_tails"
        ) {
            Array flips;
            if (op == "flip_coin_repeat_damage") {
                const std::int64_t count = std::min<std::int64_t>(
                    32,
                    integer_arg(args, "flips", 3)
                );
                for (std::int64_t index = 0; index < count; ++index) {
                    flips.emplace_back((rng.next_u32() & 1U) == 0U);
                }
            } else if (op == "flip_coin_then_ko") {
                flips.emplace_back((rng.next_u32() & 1U) == 0U);
                flips.emplace_back((rng.next_u32() & 1U) == 0U);
            } else if (op == "flip_until_tails") {
                for (std::int64_t index = 0; index < 32; ++index) {
                    const bool heads = (rng.next_u32() & 1U) == 0U;
                    flips.emplace_back(heads);
                    if (!heads) {
                        break;
                    }
                }
            } else {
                flips.emplace_back((rng.next_u32() & 1U) == 0U);
            }
            Value continuation = make_continuation(
                op,
                command_spec,
                actor,
                source_slot
            );
            continuation["flips"] = Value(std::move(flips));
            continuation["context_mode"] = Value(context_mode);
            suspend(
                pending_request(
                    "coin_flip",
                    actor,
                    0,
                    0,
                    false,
                    false,
                    {},
                    "coin"
                ),
                std::move(continuation)
            );
        } else if (
            op == "hand_to_bottom_draw_until"
            || op == "hand_to_bottom_then_draw"
        ) {
            const std::int64_t size = static_cast<std::int64_t>(
                required(self, "hand").as_array().size()
            );
            const bool until = op == "hand_to_bottom_draw_until";
            if (until && size == 1) {
                Array &hand = required(self, "hand").as_array();
                Array &deck = required(self, "deck").as_array();
                Array returned_ids{Value(hand.front().string_or())};
                deck.insert(deck.begin(), std::move(hand.front()));
                hand.erase(hand.begin());
                append_card_zone_event(
                    result,
                    "card_moved",
                    actor,
                    std::move(returned_ids),
                    "hand",
                    "deck",
                    "owner"
                );
                const std::int64_t draw_count = std::max<std::int64_t>(
                    0,
                    integer_arg(args, "target_hand_size", 5)
                        - static_cast<std::int64_t>(hand.size())
                );
                const auto drawn = draw_cards(self, draw_count);
                append_cards_drawn_event(
                    result, actor, drawn, "hand_to_bottom");
                result.success = true;
                result.rng_state = rng.state();
                early_return = true; return true;
            }
            suspend(
                pending_request(
                    until ? "houb" : "hand_bottom_draw",
                    actor,
                    until ? 1 : 0,
                    until ? 1 : size,
                    false,
                    !until,
                    zone_options(
                        cards,
                        self,
                        actor,
                        "hand",
                        "any"
                    ),
                    until ? "houb" : "hand_bottom_draw"
                ),
                make_continuation(
                    op,
                    command_spec,
                    actor,
                    source_slot
                )
            );
        } else if (op == "heal_all") {
            static constexpr std::array<const char *, 6> slots{
                "active", "bench_0", "bench_1", "bench_2", "bench_3",
                "bench_4",
            };
            for (const char *slot : slots) {
                Value *entry = pokemon(self, slot);
                const std::int64_t healed = entry == nullptr
                    ? 0 : heal_damage(
                        *entry, integer_arg(args, "amount", 20));
                if (healed > 0) {
                    append_healed_event(
                        result, actor, actor, slot, healed);
                    self["healed_this_turn"] = Value(true);
                }
            }
        } else if (op == "heal_damage") {
            Value *target = source;
            const std::string target_name = string_arg(
                args,
                "target",
                "self"
            );
            if (target_name == "opponent_active") {
                target = opponent_active;
            }
            const std::int64_t healed = target == nullptr
                ? 0 : heal_damage(*target, integer_arg(args, "amount"));
            if (healed > 0) {
                if (target_name != "opponent_active") {
                    self["healed_this_turn"] = Value(true);
                }
                append_healed_event(
                    result,
                    actor,
                    target_name == "opponent_active" ? 1 - actor : actor,
                    target_name == "opponent_active" ? "active" : source_slot,
                    healed
                );
            }
        } else if (op == "judge") {
            for (std::int32_t index : {0, 1}) {
                Value &target = player(result.state, index);
                Array &hand = required(target, "hand").as_array();
                Array &deck = required(target, "deck").as_array();
                const Array returned = hand;
                for (Value &entry : hand) {
                    deck.push_back(std::move(entry));
                }
                hand.clear();
                if (!returned.empty()) {
                    append_event(result, "card_moved", Object{
                        {"player", Value(index)},
                        {"card_ids", Value(returned)},
                        {"count", Value(static_cast<std::int64_t>(returned.size()))},
                        {"source_zone", Value("hand")},
                        {"target_zone", Value("deck")},
                        {"visibility", Value("owner")},
                    });
                    result.event_types.emplace_back("card_moved");
                }
                shuffle_array(deck, rng);
                append_event(result, "deck_shuffled", Object{
                    {"player", Value(index)},
                });
                result.event_types.emplace_back("deck_shuffled");
                const auto drawn = draw_cards(
                    target,
                    integer_arg(args, "draw", 4)
                );
                if (!drawn.empty()) {
                    append_event(result, "cards_drawn", Object{
                        {"player", Value(index)},
                        {"card_ids", Value(card_id_values(drawn))},
                        {"count", Value(static_cast<std::int64_t>(drawn.size()))},
                        {"purpose", Value("judge")},
                        {"visibility", Value("owner")},
                    });
                    result.event_types.emplace_back("cards_drawn");
                }
            }
        } else if (
            op == "look_top_attach_energy"
            || op == "look_top_deck"
        ) {
            Array &deck = required(self, "deck").as_array();
            const std::int64_t count = std::min<std::int64_t>(
                integer_arg(args, "count"),
                static_cast<std::int64_t>(deck.size())
            );
            const std::int64_t first = static_cast<std::int64_t>(
                deck.size()
            ) - count;
            Array options = zone_options(
                cards,
                self,
                actor,
                "deck",
                string_arg(args, "filter", "any"),
                first,
                static_cast<std::int64_t>(deck.size()) - 1,
                true
            );
            const std::int64_t take = std::min<std::int64_t>(
                integer_arg(args, "take", 1),
                static_cast<std::int64_t>(options.size())
            );
            const std::int64_t minimum = std::min<std::int64_t>(
                take,
                args.find("min_select") == nullptr
                    ? (
                        integer_arg(args, "take", 1) >= 99
                        ? 0
                        : 1
                    )
                    : integer_arg(args, "min_select")
            );
            const bool attach = op == "look_top_attach_energy";
            if (options.empty()) {
                Array returned;
                returned.reserve(static_cast<std::size_t>(count));
                for (
                    std::int64_t index = 0;
                    index < count && !deck.empty();
                    ++index
                ) {
                    returned.push_back(std::move(deck.back()));
                    deck.pop_back();
                }
                if (bool_arg(args, "shuffle_rest")) {
                    for (Value &entry : returned) {
                        deck.push_back(std::move(entry));
                    }
                    shuffle_array(deck, rng);
                    result.event_types.emplace_back("deck_shuffled");
                } else if (bool_arg(args, "rest_bottom", true)) {
                    for (Value &entry : returned) {
                        deck.insert(deck.begin(), std::move(entry));
                    }
                } else {
                    for (auto iterator = returned.rbegin();
                         iterator != returned.rend();
                         ++iterator) {
                        deck.push_back(std::move(*iterator));
                    }
                }
                result.success = true;
                result.rng_state = rng.state();
                early_return = true; return true;
            }
            suspend(
                pending_request(
                    attach ? "look_top_attach_energy" : "look_top",
                    actor,
                    minimum,
                    take,
                    false,
                    minimum <= 0,
                    std::move(options),
                    attach ? "look_top_attach_energy" : "look_top"
                ),
                make_continuation(
                    op,
                    command_spec,
                    actor,
                    source_slot
                )
            );
        } else if (op == "mill_then_damage") {
            Array &deck = required(self, "deck").as_array();
            Array &discard = required(self, "discard").as_array();
            Array non_energy;
            Array revealed_cards;
            std::int64_t energy_count = 0;
            std::int64_t remaining = std::min<std::int64_t>(
                integer_arg(args, "mill_count", 5),
                static_cast<std::int64_t>(deck.size())
            );
            while (remaining-- > 0) {
                Value entry = std::move(deck.back());
                deck.pop_back();
                const std::string card_id = entry.string_or();
                const bool matched = card_is_energy(cards, card_id);
                revealed_cards.emplace_back(Object{
                    {"card_id", Value(card_id)},
                    {"matched", Value(matched)},
                    {"destination", Value(Object{
                        {"player", Value(actor)},
                        {"zone", Value(matched ? "discard" : "deck")},
                    })},
                });
                if (matched) {
                    discard.push_back(std::move(entry));
                    ++energy_count;
                } else {
                    non_energy.push_back(std::move(entry));
                }
            }
            for (Value &entry : non_energy) {
                deck.push_back(std::move(entry));
            }
            shuffle_array(deck, rng);
            result.rng_state = rng.state();
            set_attack_damage(
                result.context,
                energy_count * integer_arg(args, "damage_per", 80),
                true
            );
            append_event(result, "cards_revealed", Object{
                {"player", Value(actor)},
                {"cards", Value(std::move(revealed_cards))},
                {"summary", Value(Object{
                    {"kind", Value("energy_damage")},
                    {"matched_count", Value(energy_count)},
                    {
                        "amount",
                        Value(energy_count * integer_arg(args, "damage_per", 80)),
                    },
                })},
            });
            result.event_types.emplace_back("cards_revealed");
            result.event_types.emplace_back("deck_shuffled");
        } else if (op == "place_counters_then_self_discard") {
            Array options = pokemon_options(
                opponent,
                1 - actor,
                true,
                true
            );
            if (options.size() == 1) {
                const std::string target_slot = string_arg(
                    options.front(), "slot");
                Value *target = pokemon(
                    opponent,
                    target_slot
                );
                if (
                    target != nullptr
                    && !(
                        context_mode == "attack"
                        && prevents_attack_effects(*target)
                    )
                ) {
                    const std::int64_t amount = integer_arg(
                        args, "counters", 2) * 10;
                    add_damage(
                        *target,
                        amount
                    );
                    const std::int64_t maximum_hp = pokemon_hp(
                        cards,
                        *target
                    );
                    if (
                        maximum_hp > 0
                        && integer_arg(
                            *target,
                            "damage_counters"
                        ) * 10 >= maximum_hp
                        && target->find("pending_ko_source_kind") == nullptr
                    ) {
                        (*target)["pending_ko_source_kind"] = Value(
                            "damage_counters"
                        );
                    }
                    append_damage_feedback_event(
                        result,
                        "damage_counters_placed",
                        actor,
                        1 - actor,
                        target_slot,
                        amount
                    );
                }
                discard_pokemon(self, source_slot);
                if (
                    source_slot == "active"
                    && !pokemon_options(
                        self,
                        actor,
                        false,
                        true
                    ).empty()
                ) {
                    required(
                        result.state,
                        "pending_promotions"
                    ).as_array().emplace_back(actor);
                }
                result.event_types.emplace_back("cards_discarded");
            } else {
                suspend(
                    pending_request(
                        "place_counters_self_discard",
                        actor,
                        1,
                        1,
                        false,
                        false,
                        std::move(options),
                        "place_counters_self_discard"
                    ),
                    make_continuation(
                        op,
                        command_spec,
                        actor,
                        source_slot
                    )
                );
            }
        } else if (op == "place_damage_counters") {
            if (source != nullptr) {
                const std::int64_t amount = integer_arg(args, "amount");
                const bool self_damage = string_arg(
                    args,
                    "damage_kind",
                    "damage_counters"
                ) == "self_damage";
                add_damage(*source, amount);
                const std::int64_t maximum_hp = pokemon_hp(cards, *source);
                if (
                    maximum_hp > 0
                    && integer_arg(*source, "damage_counters") * 10
                        >= maximum_hp
                    && source->find("pending_ko_source_kind") == nullptr
                ) {
                    (*source)["pending_ko_source_kind"] = Value(
                        self_damage ? "attack_effect" : "damage_counters"
                    );
                }
                append_damage_feedback_event(
                    result,
                    self_damage ? "damage_dealt" : "damage_counters_placed",
                    actor,
                    actor,
                    source_slot,
                    amount
                );
            }
        } else if (
            op.rfind("register_", 0) == 0
        ) {
            if (source != nullptr) {
                append_modifier(*source, op, args);
            }
            result.modifier = modifier_probe(
                op,
                args,
                source,
                actor,
                source_slot
            );
        } else if (op == "recover_clara") {
            const std::int64_t pokemon_count = std::max<std::int64_t>(
                0,
                integer_arg(args, "pokemon_count", 2)
            );
            const std::int64_t energy_count = std::max<std::int64_t>(
                0,
                integer_arg(args, "energy_count", 2)
            );
            Value request = pending_request(
                    "clara",
                    actor,
                    0,
                    energy_count + pokemon_count,
                    false,
                    true,
                    zone_options(
                        cards,
                        self,
                        actor,
                        "discard",
                        "pokemon_and_energy"
                    ),
                    "clara"
                );
            request["metadata"] = Value(Object{
                {"category_limits", Value(Object{
                    {"energy", Value(energy_count)},
                    {"pokemon", Value(pokemon_count)},
                })},
                {"domain", Value("recover")},
                {"energy_count", Value(energy_count)},
                {"pokemon_count", Value(pokemon_count)},
                {"purpose", Value("clara")},
            });
            suspend(
                std::move(request),
                make_continuation(
                    op,
                    command_spec,
                    actor,
                    source_slot
                )
            );
        } else if (op == "relocate_energy") {
            const std::string filter = string_arg(
                args,
                "energy_type",
                string_arg(args, "filter", "any")
            );
            Array board = pokemon_options(self, actor, true, true);
            struct RelocateSource {
                std::string slot;
                Value option;
                Array attachments;
            };
            std::vector<RelocateSource> sources;
            for (const Value &option : board) {
                const std::string slot = string_arg(option, "slot");
                Value *candidate = pokemon(self, slot);
                if (
                    candidate == nullptr
                    || (
                        bool_arg(args, "from_self")
                        && slot != source_slot
                    )
                ) {
                    continue;
                }
                Array attachments;
                const Array &energy = required(
                    *candidate,
                    "energy_card_ids"
                ).as_array();
                for (
                    std::size_t index = 0;
                    index < energy.size();
                    ++index
                ) {
                    if (attached_energy_card_matches(
                        cards,
                        *candidate,
                        index,
                        filter
                    )) {
                        attachments.push_back(attachment_option(
                            energy[index].string_or(),
                            actor,
                            slot,
                            static_cast<std::int64_t>(index)
                        ));
                    }
                }
                if (!attachments.empty()) {
                    sources.push_back(RelocateSource{
                        slot,
                        option,
                        std::move(attachments),
                    });
                }
            }
            if (sources.empty() || board.size() <= 1) {
                result.success = true;
                result.rng_state = rng.state();
                early_return = true; return true;
            }
            if (sources.size() > 1) {
                Array options;
                for (const RelocateSource &entry : sources) {
                    options.push_back(entry.option);
                }
                Value continued = make_continuation(
                    op,
                    command_spec,
                    actor,
                    source_slot,
                    -1
                );
                suspend(
                    pending_request(
                        "distribute_energy",
                        actor,
                        1,
                        1,
                        false,
                        false,
                        std::move(options),
                        "energy_relocate_source"
                    ),
                    std::move(continued)
                );
                result.success = true;
                result.rng_state = rng.state();
                early_return = true; return true;
            }
            const RelocateSource &only = sources.front();
            const std::int64_t amount = std::min<std::int64_t>(
                integer_arg(args, "amount", 1),
                static_cast<std::int64_t>(only.attachments.size())
            );
            const bool optional_count = args.find("min_select") != nullptr
                || bool_arg(args, "optional");
            const std::int64_t minimum = optional_count
                ? std::min(
                    amount,
                    integer_arg(args, "min_select")
                )
                : amount;
            const bool exact_choice = minimum < amount
                || static_cast<std::int64_t>(only.attachments.size())
                    > amount;
            Value continued = make_continuation(
                op,
                command_spec,
                actor,
                only.slot,
                0
            );
            Array options;
            std::string request_type;
            std::string continuation_kind;
            if (exact_choice) {
                options = only.attachments;
                request_type = "select_attachment";
                continuation_kind = "energy_relocate_attachments";
            } else {
                for (const Value &target : board) {
                    if (string_arg(target, "slot") == only.slot) {
                        continue;
                    }
                    options.push_back(target);
                }
                request_type = "distribute_energy";
                continuation_kind = "energy_relocate_distribution";
                continued["stage"] = Value(1);
                continued["selected_attachments"] = Value(
                    only.attachments
                );
            }
            suspend(
                pending_request(
                    request_type,
                    actor,
                    minimum,
                    amount,
                    request_type == "distribute_energy" && amount > 1,
                    minimum == 0,
                    std::move(options),
                    continuation_kind
                ),
                std::move(continued)
            );
        }

    return true;
}

} // namespace ptcg::ai::rules_detail
