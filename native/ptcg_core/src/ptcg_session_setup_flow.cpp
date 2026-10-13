#include "ptcg_rules_session.hpp"
#include "ptcg_session_internal.hpp"

#include "ptcg_random.hpp"
#include "ptcg_card_runtime.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <functional>
#include <iomanip>
#include <limits>
#include <mutex>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <unordered_set>
#include <unordered_map>
#include <utility>


namespace ptcg::ai::session_detail {

using Array = Value::Array;
using Object = Value::Object;

void set_prizes(Value &state) {
    for (std::int32_t actor = 0; actor < 2; ++actor) {
        Value &owner = player(state, actor);
        Array &deck = required(owner, "deck").as_array();
        Array &prizes = required(owner, "prizes").as_array();
        for (std::size_t count = 0; count < 6 && !deck.empty(); ++count) {
            prizes.push_back(deck.back());
            deck.pop_back();
        }
    }
}

void finish_setup(Value &state, std::vector<Value> &events) {
    state["setup_stage"] = Value("COMPLETE");
    state["setup_actor_idx"] = Value(-1);
    state["setup_bonus_card_ids"] = Value(Array{Value::make_array(), Value::make_array()});
    const std::int32_t first = static_cast<std::int32_t>(
        integer_field(state, "first_player_idx"));
    state["active_player_idx"] = Value(first);
    state["phase"] = Value("DRAW");
    Array revealed_players;
    for (std::int32_t actor = 0; actor < 2; ++actor) {
        const Value &owner = player(state, actor);
        Array bench_ids;
        const Value *bench = owner.find("bench");
        if (bench != nullptr && bench->is_array()) {
            for (const Value &entry : bench->as_array()) {
                if (entry.is_object()) {
                    bench_ids.emplace_back(string_field(entry, "card_id"));
                }
            }
        }
        const Value *active = owner.find("active");
        revealed_players.emplace_back(Object{
            {
                "active",
                Value(active != nullptr && active->is_object()
                    ? string_field(*active, "card_id") : ""),
            },
            {"bench", Value(std::move(bench_ids))},
        });
    }
    events.push_back(event(
        "setup_revealed",
        -1,
        Value(Object{
            {"first_player", Value(first)},
            {"players", Value(std::move(revealed_players))},
        }),
        "public"
    ));
    events.push_back(event(
        "turn_start",
        first,
        Value(Object{
            {"player", Value(first)},
            {"turn", Value(integer_field(state, "turn_number"))},
        })
    ));
    Value &owner = player(state, first);
    Array drawn = draw_cards(owner, 1);
    if (drawn.empty()) {
        const std::int32_t winner = 1 - first;
        state["winner"] = Value(winner);
        state["result_status"] = Value("WIN");
        state["result_reason"] = Value("deck_exhausted");
        state["result_conditions"] = Value(Array{
            Value(first == 1 ? Array{Value("opponent_deck_exhausted")} : Array{}),
            Value(first == 0 ? Array{Value("opponent_deck_exhausted")} : Array{}),
        });
        events.push_back(event(
            "deck_exhausted", first,
            Value(Object{{"player", Value(first)}, {"reason", Value("draw_failed")}})));
        events.push_back(event(
            "game_over", winner,
            Value(Object{{"winner", Value(winner)}, {"reason", Value("deck_exhausted")}})));
        return;
    }
    events.push_back(event(
        "cards_drawn",
        first,
        Value(Object{
            {"player", Value(first)},
            {"count", Value(1)},
            {"card_ids", Value(drawn)},
            {"purpose", Value("turn_draw")},
            {"turn", Value(integer_field(state, "turn_number"))},
        }),
        "owner"
    ));
    state["phase"] = Value("MAIN");
}

std::string prepare_opening_hands(
    const Value &cards,
    Value &state,
    XorShift32 &rng,
    std::vector<Value> &events,
    bool initial,
    int force_redraw
) {
    const auto may_keep = [&](int owner) {
        if (owner == force_redraw) return false;
        if (hand_has_basic(cards,player(state,owner))) return true;
        for (const auto &id : required(player(state,owner),"hand").as_array())
            if (card_runtime::rule(cards,id.string_or(),"setup_pokemon")) return true;
        return false;
    };
    if (initial) {
    state["turn_number"] = Value(1);
    state["mulligan_count"] = Value(Array{Value(0), Value(0)});
    for (std::int32_t actor = 0; actor < 2; ++actor) {
        Array drawn = draw_cards(player(state, actor), 7);
        events.push_back(event(
            "cards_drawn",
            actor,
            Value(Object{
                {"player", Value(actor)},
                {"purpose", Value("opening_hand")},
                {"round", Value(0)},
                {"count", Value(static_cast<std::int64_t>(drawn.size()))},
                {"card_ids", Value(drawn)},
                {"final_opening_hand", Value(hand_has_basic(cards, player(state, actor)))},
            }),
            "owner"
        ));
    }
    }
    std::int64_t guard = 0;
    while (
        !may_keep(0) || !may_keep(1)
    ) {
        ++guard;
        if (guard > 64) {
            return "mulligan_guard";
        }
        std::array<bool, 2> redraw = {
            !may_keep(0), !may_keep(1),
        };
        force_redraw = -1;
        for (std::int32_t actor = 0; actor < 2; ++actor) {
            if (!redraw[static_cast<std::size_t>(actor)]) {
                continue;
            }
            Value &owner = player(state, actor);
            const Array revealed = required(owner, "hand").as_array();
            events.push_back(event(
                "cards_revealed", actor,
                Value(Object{
                    {"player", Value(actor)},
                    {"purpose", Value("mulligan")},
                    {"round", Value(guard)},
                    {"card_ids", Value(revealed)},
                    {"cards", Value(revealed)},
                }),
                "public"
            ));
            Array &deck = required(owner, "deck").as_array();
            Array &hand = required(owner, "hand").as_array();
            events.push_back(event(
                "card_moved", actor,
                Value(Object{
                    {"player", Value(actor)},
                    {"purpose", Value("mulligan_return")},
                    {"round", Value(guard)},
                    {"card_ids", Value(revealed)},
                    {"count", Value(static_cast<std::int64_t>(revealed.size()))},
                    {"source_zone", Value("hand")},
                    {"target_zone", Value("deck")},
                }),
                "public"
            ));
            deck.insert(deck.end(), hand.begin(), hand.end());
            hand.clear();
            shuffle(deck, rng);
            Array &counts = required(state, "mulligan_count").as_array();
            counts[static_cast<std::size_t>(actor)] = Value(
                counts[static_cast<std::size_t>(actor)].as_integer() + 1);
            events.push_back(event(
                "deck_shuffled", actor,
                Value(Object{
                    {"player", Value(actor)},
                    {"purpose", Value("mulligan")},
                    {"round", Value(guard)},
                }),
                "public"
            ));
            Array drawn = draw_cards(owner, 7);
            events.push_back(event(
                "cards_drawn", actor,
                Value(Object{
                    {"player", Value(actor)},
                    {"purpose", Value("mulligan_redraw")},
                    {"round", Value(guard)},
                    {"count", Value(static_cast<std::int64_t>(drawn.size()))},
                    {"card_ids", Value(drawn)},
                    {"final_opening_hand", Value(hand_has_basic(cards, owner))},
                }),
                "owner"
            ));
        }
    }
    const Array &counts = required(state, "mulligan_count").as_array();
    const std::int64_t bonus_zero = std::max<std::int64_t>(
        0, counts[1].as_integer() - counts[0].as_integer());
    const std::int64_t bonus_one = std::max<std::int64_t>(
        0, counts[0].as_integer() - counts[1].as_integer());
    state["mulligan_bonus_max"] = Value(std::max(bonus_zero, bonus_one));
    state["setup_stage"] = Value("INITIAL_PLACEMENT");
    state["setup_actor_idx"] = state["first_player_idx"];
    state["setup_ready"] = Value(Array{Value(false), Value(false)});
    return {};
}

bool opening_doll_choice(const Value &cards, Value &state, const Array &accepted,
    Value &pending, Value &continuation) {
    for (int owner : {static_cast<int>(integer_field(state,"first_player_idx")),
            1-static_cast<int>(integer_field(state,"first_player_idx"))}) {
        if (hand_has_basic(cards,player(state,owner)) || std::any_of(accepted.begin(),accepted.end(),
            [&](const Value &entry){return entry.as_integer(-1)==owner;})) continue;
        pending=setup_choice(state,owner,"confirm","手牌没有基础宝可梦。是否使用卡比兽娃娃开始对战？",
            Array{Value(Object{{"option_id",Value("confirm:yes")},{"label",Value("使用卡比兽娃娃")}}),
                Value(Object{{"option_id",Value("confirm:no")},{"label",Value("重新抽取起始手牌")}})},"setup_doll");
        continuation=Value(Object{{"kind",Value("setup_doll")},{"actor",Value(owner)},{"accepted",Value(accepted)}});
        return true;
    }
    pending=Value();continuation=Value();return false;
}


} // namespace ptcg::ai::session_detail
