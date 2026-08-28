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

bool execute_vm_trigger_pipeline(
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
        op == "return_to_hand"
        || op == "search_any_and_switch"
        || op == "search_cards"
        || op == "search_item_and_tool"
        || op == "set_attack_damage_formula"
        || op == "set_attack_flags"
        || op == "shuffle_from_discard_to_deck"
        || op == "shuffle_then_draw_cards"
        || op == "switch_pokemon"
        || op == "trekking_shoes"
        || op == "trigger_place_damage_counters"
        || op == "trigger_move_basic_energy"
        || op == "trigger_switch_with_active"
        || op == "zinnia_resolve"
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

        if (op == "return_to_hand") {
            return_pokemon_to_hand(self, source_slot);
            result.event_types.emplace_back("card_moved");
        } else if (
            op == "search_any_and_switch"
            || op == "search_cards"
            || op == "search_item_and_tool"
        ) {
            std::string request_type;
            std::string continuation_kind;
            std::string filter;
            std::int64_t minimum = 0;
            std::int64_t maximum = 1;
            bool can_cancel = false;
            if (op == "search_any_and_switch") {
                request_type = "search_any_switch";
                continuation_kind = "search_any_switch";
                filter = "any";
                minimum = integer_arg(args, "min_select");
                maximum = integer_arg(args, "count", 2);
                can_cancel = true;
            } else if (op == "search_cards") {
                request_type = "search_move";
                continuation_kind = "search_move";
                filter = string_arg(args, "filter", "any");
                minimum = integer_arg(args, "min_select", 1);
                maximum = integer_arg(args, "count", 1);
                can_cancel = minimum == 0;
            } else {
                request_type = "arven";
                continuation_kind = "arven";
                filter = "item_or_tool";
                minimum = 1;
                maximum = 2;
            }
            const std::string source_zone = op == "search_cards"
                ? string_arg(args, "from_zone", "deck")
                : "deck";
            if (source_zone == "deck") {
                if (op == "search_item_and_tool") {
                    minimum = 0;
                    can_cancel = false;
                } else if (op == "search_cards") {
                    if (filter != "any") {
                        minimum = 0;
                    }
                    // A zero-card hidden search resolves the effect. It must
                    // not roll back a Trainer or a cost that was already paid.
                    can_cancel = minimum == 0 && context_mode != "trainer";
                }
            }
            Array options = zone_options(
                cards,
                self,
                actor,
                source_zone,
                filter,
                0,
                std::numeric_limits<std::int64_t>::max(),
                false,
                op == "search_cards"
                    ? string_arg(args, "filter_name")
                    : std::string{}
            );
            if (
                op == "search_cards"
                && string_arg(args, "destination", "hand") == "bench"
            ) {
                maximum = std::min<std::int64_t>(
                    maximum,
                    std::max<std::int64_t>(
                        0,
                        5 - static_cast<std::int64_t>(
                            bench_count(self)
                        )
                    )
                );
            }
            if (options.empty()) {
                if (source_zone == "deck") {
                    shuffle_array(
                        required(self, "deck").as_array(),
                        rng
                    );
                    result.event_types.emplace_back("deck_shuffled");
                }
                result.success = true;
                result.rng_state = rng.state();
                early_return = true; return true;
            }
            if (maximum <= 0) {
                if (source_zone == "deck") {
                    shuffle_array(
                        required(self, "deck").as_array(),
                        rng
                    );
                    result.event_types.emplace_back("deck_shuffled");
                }
                result.success = true;
                result.rng_state = rng.state();
                early_return = true; return true;
            }
            maximum = std::min<std::int64_t>(
                maximum,
                static_cast<std::int64_t>(options.size())
            );
            minimum = std::min(minimum, maximum);
            Value request = pending_request(
                request_type,
                actor,
                minimum,
                maximum,
                false,
                can_cancel,
                std::move(options),
                continuation_kind
            );
            if (op == "search_item_and_tool") {
                request["metadata"] = Value(Object{
                    {"category_limits", Value(Object{
                        {"item", Value(1)},
                        {"tool", Value(1)},
                    })},
                    {"domain", Value("search")},
                    {"purpose", Value("arven")},
                });
            }
            suspend(
                std::move(request),
                make_continuation(
                    op,
                    command_spec,
                    actor,
                    source_slot
                )
            );
        } else if (op == "set_attack_damage_formula") {
            std::int64_t total = integer_arg(args, "base");
            const Value *condition_bonus = args.find("condition_bonus");
            if (
                condition_bonus != nullptr
                && condition_bonus->is_object()
                && condition_applies(
                    cards,
                    result.state,
                    actor,
                    string_arg(*condition_bonus, "condition")
                )
            ) {
                total += integer_arg(*condition_bonus, "bonus");
            }
            total += bench_count(self)
                * integer_arg(args, "per_own_bench");
            if (source != nullptr) {
                total += get_integer(*source, "damage_counters")
                    * integer_arg(args, "per_self_damage_counter");
                const std::string energy_type = string_arg(
                    args,
                    "per_self_energy_type"
                );
                if (!energy_type.empty()) {
                    total += energy_units(cards, source, energy_type)
                        * integer_arg(args, "per_energy");
                }
            }
            set_attack_damage(result.context, total, false);
        } else if (op == "set_attack_flags") {
            for (const std::string &key : {
                "ignore_weakness",
                "ignore_resistance",
                "ignore_defender_damage_effects",
            }) {
                if (bool_arg(args, key)) {
                    result.context[key] = Value(true);
                }
            }
        } else if (op == "shuffle_from_discard_to_deck") {
            const Array options = zone_options(
                cards,
                self,
                actor,
                "discard",
                string_arg(args, "filter", "any")
            );
            suspend(
                pending_request(
                    "shuffle_from_discard",
                    actor,
                    std::min<std::int64_t>(
                        1,
                        static_cast<std::int64_t>(options.size())
                    ),
                    std::min<std::int64_t>(
                        integer_arg(args, "count", 1),
                        static_cast<std::int64_t>(options.size())
                    ),
                    false,
                    true,
                    options,
                    "shuffle_from_discard"
                ),
                make_continuation(
                    op,
                    command_spec,
                    actor,
                    source_slot
                )
            );
        } else if (op == "shuffle_then_draw_cards") {
            Array &hand = required(self, "hand").as_array();
            Array &deck = required(self, "deck").as_array();
            if (bool_arg(args, "shuffle_hand")) {
                const Array returned = hand;
                for (Value &entry : hand) {
                    deck.push_back(std::move(entry));
                }
                hand.clear();
                if (!returned.empty()) {
                    append_event(result, "card_moved", Object{
                        {"player", Value(actor)},
                        {"card_ids", Value(returned)},
                        {"count", Value(static_cast<std::int64_t>(returned.size()))},
                        {"source_zone", Value("hand")},
                        {"target_zone", Value("deck")},
                        {"visibility", Value("owner")},
                    });
                    result.event_types.emplace_back("card_moved");
                }
                shuffle_array(deck, rng);
                result.event_types.emplace_back("deck_shuffled");
            }
            const auto drawn = draw_cards(
                self,
                integer_arg(args, "draw", 5)
            );
            if (!drawn.empty()) {
                append_event(result, "cards_drawn", Object{
                    {"player", Value(actor)},
                    {"card_ids", Value(card_id_values(drawn))},
                    {"count", Value(static_cast<std::int64_t>(drawn.size()))},
                    {"purpose", Value("shuffle_then_draw")},
                    {"visibility", Value("owner")},
                });
                result.event_types.emplace_back("cards_drawn");
            }
        } else if (op == "switch_pokemon") {
            const bool opponent_target = string_arg(
                args,
                "target",
                "self"
            ) == "opponent";
            const bool optional = bool_arg(args, "optional");
            const bool controller_chooses = bool_arg(args, "you_choose");
            Value &target = opponent_target ? opponent : self;
            Array options = pokemon_options(
                target,
                opponent_target ? 1 - actor : actor,
                false,
                true
            );
            if (options.empty()) {
                result.success = true;
                result.rng_state = rng.state();
                early_return = true; return true;
            }
            if (optional) {
                Value request = pending_request(
                    "confirm",
                    actor,
                    1,
                    1,
                    false,
                    false,
                    {
                        id_option("confirm:yes", "进行换位"),
                        id_option("confirm:no", "不进行换位"),
                    },
                    "switch_confirm"
                );
                request["prompt"] = Value(
                    opponent_target
                        ? "是否让对手的战斗宝可梦与备战宝可梦互换？"
                        : "是否将这只宝可梦与备战宝可梦互换？"
                );
                Object presentation{
                    {"domain", Value("effect")},
                    {"purpose", Value("switch_confirm")},
                    {"source_player", Value(actor)},
                    {"source_slot", Value(source_slot)},
                    {
                        "target_player",
                        Value(opponent_target ? 1 - actor : actor),
                    },
                };
                if (source != nullptr) {
                    presentation["source_card_id"] = Value(
                        string_arg(*source, "card_id")
                    );
                }
                request["presentation"] = Value(
                    std::move(presentation)
                );
                suspend(
                    std::move(request),
                    make_continuation(
                        op,
                        command_spec,
                        actor,
                        source_slot
                    )
                );
            } else if (
                options.size() == 1
                && !(opponent_target && controller_chooses)
            ) {
                switch_active_with_event(
                    result,
                    target,
                    actor,
                    opponent_target ? 1 - actor : actor,
                    string_arg(options.front(), "slot"),
                    "switch_pokemon"
                );
            } else {
                const std::int32_t chooser = (
                    opponent_target && !controller_chooses
                ) ? 1 - actor : actor;
                suspend(
                    pending_request(
                        opponent_target && controller_chooses
                            ? "select_opponent_bench"
                            : "select_bench",
                        chooser,
                        1,
                        1,
                        false,
                        false,
                        std::move(options),
                        "switch"
                    ),
                    make_continuation(
                        op,
                        command_spec,
                        actor,
                        source_slot,
                        1
                    )
                );
            }
        } else if (op == "trekking_shoes") {
            Value keep_option = id_option("confirm:yes");
            keep_option["label"] = Value("将这张卡牌加入手牌");
            Value discard_option = id_option("confirm:no");
            discard_option["label"] = Value("丢弃这张卡牌，再抽1张卡牌");
            Value request = pending_request(
                "confirm",
                actor,
                1,
                1,
                false,
                false,
                {
                    std::move(keep_option),
                    std::move(discard_option),
                },
                "trekking_shoes"
            );
            request["prompt"] = Value(
                "查看了牌库顶的卡牌。请选择处理方式。"
            );
            const Array &deck = required(self, "deck").as_array();
            if (!deck.empty()) {
                const std::string top_card_id = deck.back().string_or();
                request["presentation"] = Value(Object{
                    {"domain", Value("effect")},
                    {"purpose", Value("trekking_shoes")},
                    {"top_card_id", Value(top_card_id)},
                    {
                        "revealed_card_ids",
                        Value(Array{Value(top_card_id)}),
                    },
                });
            }
            suspend(
                std::move(request),
                make_continuation(
                    op,
                    command_spec,
                    actor,
                    source_slot
                )
            );
        } else if (op == "trigger_place_damage_counters") {
            const std::int32_t target_owner = static_cast<std::int32_t>(
                integer_arg(args, "player", actor));
            const std::string target_slot = string_arg(
                args, "slot", "active");
            Value &target_player = player(
                result.state,
                target_owner
            );
            if (
                Value *target = pokemon(
                    target_player,
                    target_slot
                )
            ) {
                const std::int64_t amount = integer_arg(args, "count") * 10;
                add_damage(*target, amount);
                append_damage_feedback_event(
                    result,
                    "damage_counters_placed",
                    actor,
                    target_owner,
                    target_slot,
                    amount
                );
            }
        } else if (op == "trigger_move_basic_energy") {
            Value &from_player = player(
                result.state,
                static_cast<std::int32_t>(
                    integer_arg(args, "from_player", actor)
                )
            );
            Value &to_player = player(
                result.state,
                static_cast<std::int32_t>(
                    integer_arg(args, "to_player", actor)
                )
            );
            Value *from = pokemon(
                from_player,
                string_arg(args, "from_slot", "active")
            );
            Value *to = pokemon(
                to_player,
                string_arg(args, "to_slot", "active")
            );
            if (from != nullptr && to != nullptr) {
                Array &source_energy = required(
                    *from,
                    "energy_card_ids"
                ).as_array();
                Array &target_energy = required(
                    *to,
                    "energy_card_ids"
                ).as_array();
                const auto found = std::find_if(
                    source_energy.begin(),
                    source_energy.end(),
                    [&cards](const Value &entry) {
                        return card_matches_energy(
                            cards,
                            entry.string_or(),
                            "basic"
                        );
                    }
                );
                if (found != source_energy.end()) {
                    target_energy.push_back(std::move(*found));
                    source_energy.erase(found);
                    result.event_types.emplace_back("energy_attached");
                }
            }
        } else if (op == "trigger_switch_with_active") {
            Value &target_player = player(
                result.state,
                static_cast<std::int32_t>(
                    integer_arg(args, "player", actor)
                )
            );
            Array &bench = required(target_player, "bench").as_array();
            const std::size_t index = static_cast<std::size_t>(
                integer_arg(args, "bench_idx")
            );
            Value &active = required(target_player, "active");
            if (
                index < bench.size()
                && active.is_object()
                && bench[index].is_object()
            ) {
                const std::int32_t target_owner = static_cast<std::int32_t>(
                    integer_arg(args, "player", actor)
                );
                switch_active_with_event(
                    result,
                    target_player,
                    actor,
                    target_owner,
                    "bench_" + std::to_string(index),
                    "trigger_switch_with_active"
                );
            }
        } else if (op == "zinnia_resolve") {
            Array &hand = required(self, "hand").as_array();
            const std::int64_t draw_amount = (
                pokemon(opponent, "active") == nullptr ? 0 : 1
            ) + static_cast<std::int64_t>(
                pokemon_options(
                    opponent,
                    1 - actor,
                    false,
                    true
                ).size()
            );
            if (hand.size() == 2) {
                Array &discard = required(self, "discard").as_array();
                Array discarded_ids;
                discarded_ids.reserve(hand.size());
                for (Value &entry : hand) {
                    discarded_ids.emplace_back(entry.string_or());
                    discard.push_back(std::move(entry));
                }
                hand.clear();
                const auto drawn = draw_cards(self, draw_amount);
                append_card_zone_event(
                    result,
                    "cards_discarded",
                    actor,
                    std::move(discarded_ids),
                    "hand",
                    "discard",
                    "public"
                );
                append_cards_drawn_event(
                    result, actor, drawn, "zinnia");
                result.success = true;
                result.rng_state = rng.state();
                early_return = true; return true;
            }
            Value continued = make_continuation(
                op,
                command_spec,
                actor,
                source_slot
            );
            continued["draw_amount"] = Value(draw_amount);
            suspend(
                pending_request(
                    "zinnia",
                    actor,
                    2,
                    2,
                    false,
                    false,
                    zone_options(
                        cards,
                        self,
                        actor,
                        "hand",
                        "any"
                    ),
                    "zinnia"
                ),
                std::move(continued)
            );
        }

    return true;
}

} // namespace ptcg::ai::rules_detail
