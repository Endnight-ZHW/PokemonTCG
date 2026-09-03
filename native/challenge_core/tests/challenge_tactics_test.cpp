#include "ptcg_json_adapter.hpp"
#include "ptcg_traditional_infoset.hpp"
#include "ptcg_traditional_strategy.hpp"
#include "planner_v3/strategic_types.hpp"

#include <algorithm>
#include <cmath>
#include <iostream>
#include <stdexcept>
#include <string>

using nlohmann::json;
using ptcg::ai::TraditionalStrategyCatalog;
using ptcg::ai::TraditionalInformationSet;
using ptcg::ai::Value;
using namespace ptcg::ai::planner_v3;
using Array = Value::Array;
using Object = Value::Object;

namespace {

void require(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(message);
}

bool value_array_contains(
    const Value *object,
    const char *field,
    const std::string &expected
) {
    const Value *values = object != nullptr ? object->find(field) : nullptr;
    if (values == nullptr || !values->is_array()) return false;
    for (const Value &value : values->as_array()) {
        if (value.string_or() == expected) return true;
    }
    return false;
}

void check_normalized_deck_plans(
    const json &strategies_json,
    const json &cards_json,
    const TraditionalStrategyCatalog &catalog
) {
    const Value &plans = catalog.deck_plan_profiles();
    const Value *fire = plans.find("fire");
    if (
        fire == nullptr
        || !value_array_contains(fire, "core", "svi-infr")
        || !value_array_contains(fire, "setup", "svi-sqwk")
        || !value_array_contains(fire, "trainer", "sv1-152")
        || !value_array_contains(fire, "energy", "Fire")
    ) {
        throw std::runtime_error("normalized_fire_deck_plan_invalid");
    }
    json synthetic = strategies_json;
    synthetic["strategies"]["novel"] = {
        {"card_roles", {
            {"primary_attacker", json::array({"svi-infr"})},
            {"setup_basic", json::array({"svi-chim"})},
            {"bench_engine", json::array({"svi-chiy"})},
            {"secondary_attacker", json::array({"svi-ente"})},
            {"evolution", json::array({"svi-monf", "svi-infr"})},
            {"search", json::array({"sv1-152"})},
            {"energy", json::array({"sv1-ener-2"})},
        }},
    };
    TraditionalStrategyCatalog synthetic_catalog(
        ptcg::json_adapter::to_value(synthetic),
        ptcg::json_adapter::to_value(cards_json));
    const Value *novel = synthetic_catalog.deck_plan_profiles().find("novel");
    if (
        novel == nullptr
        || !value_array_contains(novel, "core", "svi-infr")
        || !value_array_contains(novel, "engine", "svi-chiy")
        || !value_array_contains(novel, "energy", "Fire")
    ) {
        throw std::runtime_error("data_only_deck_plan_generation_failed");
    }
}

Value hidden_player(std::size_t hand_count, std::size_t deck_count) {
    return Value(Object{
        {"name", Value("Player")},
        {"deck", Value(Array(deck_count, Value("__ai_hidden_card__")))},
        {"hand", Value(Array(hand_count, Value("__ai_hidden_card__")))},
        {"discard", Value::make_array()},
        {"prizes", Value::make_array()},
        {"active", Value()},
        {"bench", Value(Array(5, Value()))},
    });
}

Value known_hand_state(
    std::size_t hand_count,
    std::size_t deck_count,
    Array discard = {}
) {
    Value opponent = hidden_player(hand_count, deck_count);
    opponent["discard"] = Value(std::move(discard));
    return Value(Object{
        {"players", Value(Array{
            std::move(opponent), hidden_player(0, 0),
        })},
        {"public_deck_keys", Value(Array{
            Value("known-test"), Value(""),
        })},
        {"active_player_idx", Value(0)},
        {"first_player_idx", Value(0)},
        {"phase", Value("MAIN")},
        {"turn_number", Value(3)},
        {"revision", Value(9)},
    });
}

Value history_event(
    const std::string &event_type,
    const std::string &visibility,
    const std::string &source_zone,
    const std::string &target_zone,
    Array card_ids
) {
    return Value(Object{
        {"event_id", Value("history:" + event_type)},
        {"event_type", Value(event_type)},
        {"actor", Value(0)},
        {"visibility", Value(visibility)},
        {"amount", Value(static_cast<std::int64_t>(
            card_ids.empty() ? 1 : card_ids.size()))},
        {"source", Value(Object{
            {"player", Value(0)}, {"zone", Value(source_zone)},
        })},
        {"target", Value(Object{
            {"player", Value(0)}, {"zone", Value(target_zone)},
        })},
        {"data", Value(Object{
            {"player", Value(0)},
            {"visibility_owner", Value(0)},
            {"card_ids", Value(std::move(card_ids))},
            {"source_zone", Value(source_zone)},
            {"target_zone", Value(target_zone)},
        })},
    });
}

void check_known_hand_determinization(const json &cards_json) {
    const Value catalog = ptcg::json_adapter::to_value(cards_json);
    const Value decks(Object{
        {"known-test", Value(Object{
            {"cards", Value(Array{
                Value(Object{
                    {"card_id", Value("sv1-151")}, {"count", Value(1)},
                }),
                Value(Object{
                    {"card_id", Value("sv1-152")}, {"count", Value(1)},
                }),
                Value(Object{
                    {"card_id", Value("sv1-ener-1")}, {"count", Value(1)},
                }),
            })},
        })},
    });
    const Value public_entry = history_event(
        "cards_selected",
        "public",
        "deck",
        "hand",
        Array{Value("sv1-151")}
    );
    const Value private_draw = history_event(
        "cards_drawn", "owner", "deck", "hand", Array{});

    TraditionalInformationSet retained;
    std::string error;
    require(retained.capture(
            known_hand_state(2, 1),
            1,
            catalog,
            decks,
            Value::make_array(),
            Value(Array{public_entry, private_draw}),
            17,
            &error),
        "known opponent hand capture failed");
    require(retained.known_hand(0).size() == 1
            && retained.known_hand(0).front().string_or() == "sv1-151",
        "private draw forgot a still-known opponent card");
    require(retained.hand_count(0) == 2
            && retained.unknown_hand_count(0) == 1
            && retained.recommended_belief_samples(0, 3) == 2,
        "known hand did not reduce the redundant belief budget");
    const Value retained_sample = retained.sample_state(23U);
    const Array &retained_hand = retained_sample.find("players")
        ->as_array()[0].find("hand")->as_array();
    require(retained_hand.size() == 2
            && std::any_of(
                retained_hand.begin(),
                retained_hand.end(),
                [](const Value &card) {
                    return card.string_or() == "sv1-151";
                }),
        "determinization did not fix the revealed card in opponent hand");

    TraditionalInformationSet public_departure;
    const Value played = history_event(
        "trainer_played",
        "public",
        "hand",
        "discard",
        Array{Value("sv1-151")}
    );
    require(public_departure.capture(
            known_hand_state(1, 1, Array{Value("sv1-151")}),
            1,
            catalog,
            decks,
            Value::make_array(),
            Value(Array{public_entry, played}),
            29,
            &error)
            && public_departure.known_hand(0).empty(),
        "public hand departure retained stale known identity");
    require(public_departure.recommended_belief_samples(0, 3) == 3,
        "empty known hand unexpectedly reduced the belief budget");

    TraditionalInformationSet ambiguous_departure;
    const Value hidden_return = history_event(
        "cards_selected", "owner", "hand", "deck", Array{});
    require(ambiguous_departure.capture(
            known_hand_state(1, 2),
            1,
            catalog,
            decks,
            Value::make_array(),
            Value(Array{public_entry, hidden_return}),
            31,
            &error)
            && ambiguous_departure.known_hand(0).empty(),
        "identity-hidden hand change did not conservatively clear knowledge");

    TraditionalInformationSet leaked_history;
    const Value leaked_owner_entry = history_event(
        "cards_selected",
        "owner",
        "deck",
        "hand",
        Array{Value("sv1-151")}
    );
    require(!leaked_history.capture(
            known_hand_state(1, 2),
            1,
            catalog,
            decks,
            Value::make_array(),
            Value(Array{leaked_owner_entry}),
            37,
            &error)
            && error == "private_public_history",
        "information set accepted authoritative hidden identity history");
}

Value deck_browse_ref(
    std::int32_t player,
    std::int64_t index,
    const std::string &card_id,
    const std::string &zone = "deck"
) {
    return Value(Object{
        {"kind", Value("card")},
        {"player", Value(player)},
        {"zone", Value(zone)},
        {"index", Value(index)},
        {"card_id", Value(card_id)},
    });
}

std::size_t card_count(const Array &cards, const std::string &card_id) {
    return static_cast<std::size_t>(std::count_if(
        cards.begin(), cards.end(), [&card_id](const Value &card) {
            return card.string_or() == card_id;
        }));
}

void check_owner_deck_inspection_determinization(const json &cards_json) {
    const Value catalog = ptcg::json_adapter::to_value(cards_json);
    const Value decks(Object{
        {"inspection-test", Value(Object{
            {"cards", Value(Array{
                Value(Object{
                    {"card_id", Value("sv1-151")}, {"count", Value(1)},
                }),
                Value(Object{
                    {"card_id", Value("sv1-152")}, {"count", Value(1)},
                }),
                Value(Object{
                    {"card_id", Value("sv1-ener-1")}, {"count", Value(2)},
                }),
                Value(Object{
                    {"card_id", Value("sv1-ener-2")}, {"count", Value(1)},
                }),
            })},
        })},
    });
    Value owner = hidden_player(1, 2);
    owner["hand"] = Value(Array{Value("sv1-151")});
    owner["prizes"] = Value(Array{
        Value("__ai_hidden_prize__"), Value("__ai_hidden_prize__"),
    });
    const Value state(Object{
        {"players", Value(Array{owner, hidden_player(0, 0)})},
        {"public_deck_keys", Value(Array{
            Value("inspection-test"), Value(""),
        })},
        {"active_player_idx", Value(0)},
        {"first_player_idx", Value(0)},
        {"phase", Value("MAIN")},
        {"turn_number", Value(3)},
        {"revision", Value(11)},
    });
    const Value choice(Object{
        {"player", Value(0)},
        {"presentation", Value(Object{
            {"source_player", Value(0)},
            {"source_zone", Value("deck")},
            {"browse_card_refs", Value(Array{
                deck_browse_ref(0, 0, "sv1-152"),
                deck_browse_ref(0, 1, "sv1-ener-1"),
            })},
        })},
    });

    TraditionalInformationSet inspected;
    std::string error;
    require(inspected.capture(
            state, 0, catalog, decks, Value::make_array(),
            Value::make_array(), 41, &error),
        "owner inspection fixture capture failed");
    require(inspected.apply_deck_inspection(choice, &error)
            && inspected.has_exact_hidden_zones(0),
        "owner deck inspection was not accepted");
    require(inspected.known_prizes(0).size() == 2
            && card_count(inspected.known_prizes(0), "sv1-ener-1") == 1
            && card_count(inspected.known_prizes(0), "sv1-ener-2") == 1,
        "deck inspection did not infer the exact prize multiset");
    require(inspected.known_deck(0).size() == 2
            && card_count(inspected.known_deck(0), "sv1-152") == 1
            && card_count(inspected.known_deck(0), "sv1-ener-1") == 1,
        "deck inspection did not retain the exact searchable multiset");
    const Value sampled = inspected.sample_state(43U);
    const Value &sampled_owner = sampled.find("players")->as_array()[0];
    const Array &sampled_deck = sampled_owner.find("deck")->as_array();
    const Array &sampled_prizes = sampled_owner.find("prizes")->as_array();
    require(sampled_deck.size() == 2
            && card_count(sampled_deck, "sv1-152") == 1
            && card_count(sampled_deck, "sv1-ener-1") == 1,
        "determinization ignored the inspected deck multiset");
    require(sampled_prizes.size() == 2
            && card_count(sampled_prizes, "sv1-ener-1") == 1
            && card_count(sampled_prizes, "sv1-ener-2") == 1,
        "determinization ignored the inferred prize multiset");

    TraditionalInformationSet remembered;
    require(remembered.capture(
            state, 0, catalog, decks, Value::make_array(),
            Value::make_array(), 47, &error)
            && remembered.apply_known_prizes(
                inspected.known_prizes(0), &error)
            && remembered.has_exact_hidden_zones(0),
        "a later decision could not restore inspected prize knowledge");

    TraditionalInformationSet rejected;
    require(rejected.capture(
            state, 0, catalog, decks, Value::make_array(),
            Value::make_array(), 53, &error),
        "invalid inspection fixture capture failed");
    Value opponent_ref = choice.deep_clone();
    (*opponent_ref.find("presentation"))[
        "browse_card_refs"].as_array()[0]["player"] = Value(1);
    require(!rejected.apply_deck_inspection(opponent_ref, &error),
        "opponent deck browse identity was accepted");
    Value wrong_zone = choice.deep_clone();
    (*wrong_zone.find("presentation"))[
        "browse_card_refs"].as_array()[0]["zone"] = Value("hand");
    require(!rejected.apply_deck_inspection(wrong_zone, &error),
        "non-deck browse identity was accepted");
    Value duplicate_index = choice.deep_clone();
    (*duplicate_index.find("presentation"))[
        "browse_card_refs"].as_array()[1]["index"] = Value(0);
    require(!rejected.apply_deck_inspection(duplicate_index, &error),
        "duplicate deck browse index was accepted");
    Value wrong_cards = choice.deep_clone();
    (*wrong_cards.find("presentation"))[
        "browse_card_refs"].as_array()[0]["card_id"] = Value("sv1-151");
    require(!rejected.apply_deck_inspection(wrong_cards, &error),
        "browse cards outside the remaining hidden pool were accepted");
}

void check_strategic_planner_primitives() {
    require(std::abs(at_least_one_out_probability(10, 2, 1) - 0.2) < 1e-9,
        "analytic out probability is incorrect for one draw");
    require(std::abs(at_least_one_out_probability(10, 2, 2)
            - (1.0 - (8.0 / 10.0) * (7.0 / 9.0))) < 1e-9,
        "analytic out probability is incorrect for two draws");
    require(estimate_turns_to_win(5, 2, 1) == 4.0,
        "prize clock did not include readiness delay");
    require(match_loss_probability(1.0, false, false) == 0.0,
        "ordinary active knockout was classified as a match catastrophe");
    require(match_loss_probability(1.0, true, false) == 1.0,
        "last-Pokemon knockout was not classified as a match catastrophe");
    require(match_loss_probability(0.4, false, true) == 0.4,
        "final-prize loss probability was not preserved");

    PlanScore safe;
    safe.catastrophe_probability = 0.05;
    safe.prize_clock_margin = 0.5;
    PlanScore risky = safe;
    risky.catastrophe_probability = 0.55;
    risky.prize_clock_margin = 3.0;
    require(plan_score_better(safe, risky),
        "lexicographic score traded catastrophe safety for clock margin");
    PlanScore winning = risky;
    winning.terminal_rank = 3;
    require(plan_score_better(winning, safe),
        "terminal win was not the first comparison tier");

    ActionFootprint left;
    left.reads.insert("slot:bench_0");
    left.writes.insert("slot:bench_0");
    ActionFootprint right;
    right.reads.insert("slot:bench_1");
    right.writes.insert("slot:bench_1");
    require(footprints_commute(left, right),
        "independent board actions did not commute");
    left.consumes.insert("attachment_per_turn");
    right.consumes.insert("attachment_per_turn");
    require(!footprints_commute(left, right),
        "once-per-turn resource conflict was treated as commutative");
    right.consumes.clear();
    right.random = true;
    require(!footprints_commute(left, right),
        "random action was treated as commutative");
}

std::string slot_for_card(const json &state, const std::string &card_id) {
    const auto &own = state.at("players").at(0);
    if (own.value("active", json::object()).value("card_id", "") == card_id) {
        return "active";
    }
    const auto bench = own.value("bench", json::array());
    for (std::size_t index = 0; index < bench.size(); ++index) {
        if (bench[index].value("card_id", "") == card_id) {
            return "bench_" + std::to_string(index);
        }
    }
    return {};
}

json make_state(const json &context, const std::string &deck_key) {
    json state = context;
    json players = json::array({
        state.value("own", json::object()),
        state.value("opponent", json::object()),
    });
    for (auto &player : players) {
        if (!player.contains("active")) player["active"] = json::object();
        for (const char *key : {"bench", "discard", "hand"}) {
            if (!player.contains(key)) player[key] = json::array();
        }
        const int count = player.value("prizes_remaining", 6);
        player["prizes"] = json::array();
        for (int index = 0; index < count; ++index) {
            player["prizes"].push_back("__hidden_prize_" + std::to_string(index));
        }
    }
    state["players"] = std::move(players);
    state["public_deck_keys"] = json::array({deck_key, ""});
    state["active_player_idx"] = 0;
    state["first_player_idx"] = 1;
    state["phase"] = "MAIN";
    state["revision"] = 0;
    return state;
}

json make_action(const json &compact, const json &state) {
    json action = compact;
    json payload = action.value("payload", json::object());
    const std::string card_id = action.value("card_id", "");
    if (!card_id.empty()) {
        payload["card_id"] = card_id;
        action["source"] = {
            {"card_id", card_id},
            {"slot", slot_for_card(state, card_id)},
        };
    }
    if (action.contains("attack_index")) {
        payload["attack_index"] = action["attack_index"].get<std::int64_t>();
    }
    const std::string target_id = action.value("target_card_id", "");
    if (!target_id.empty()) {
        payload["target_card_id"] = target_id;
        action["target"] = {
            {"card_id", target_id},
            {"slot", slot_for_card(state, target_id)},
        };
    }
    action["payload"] = std::move(payload);
    return action;
}

} // namespace

int main(int argc, char **argv) {
    try {
        if (argc != 4) {
            throw std::runtime_error("usage: challenge_core_tests <strategies.json> <cards.json> <tactics.json>");
        }
        bool rejected_duplicate = false;
        try {
            (void)ptcg::json_adapter::parse_strict("{\"key\":1,\"key\":2}");
        } catch (const std::runtime_error &) {
            rejected_duplicate = true;
        }
        if (!rejected_duplicate) throw std::runtime_error("strict_json_duplicate_accepted");
        const json strategies_json = ptcg::json_adapter::read_strict_file(argv[1]);
        const json cards_json = ptcg::json_adapter::read_strict_file(argv[2]);
        const json fixture = ptcg::json_adapter::read_strict_file(argv[3]);
        TraditionalStrategyCatalog catalog(
            ptcg::json_adapter::to_value(strategies_json),
            ptcg::json_adapter::to_value(cards_json)
        );
        if (!catalog.valid()) throw std::runtime_error("strategy_catalog_invalid");
        check_normalized_deck_plans(strategies_json, cards_json, catalog);
        check_known_hand_determinization(cards_json);
        check_owner_deck_inspection_determinization(cards_json);
        check_strategic_planner_primitives();

        std::size_t count = 0;
        const auto &decks = fixture.at("decks");
        for (auto deck = decks.begin(); deck != decks.end(); ++deck) {
            for (const auto &scenario : deck.value()) {
                const json state_json = make_state(scenario.at("context"), deck.key());
                const std::string surface = scenario.value("surface", "action");
                json preferred_json = scenario.at("preferred");
                json over_json = scenario.at("over");
                if (surface == "action") {
                    preferred_json = make_action(preferred_json, state_json);
                    over_json = make_action(over_json, state_json);
                }
                const Value state = ptcg::json_adapter::to_value(state_json);
                const Value preferred = ptcg::json_adapter::to_value(preferred_json);
                const Value over = ptcg::json_adapter::to_value(over_json);
                const Value choice = ptcg::json_adapter::to_value(
                    scenario.value("choice_context", json::object())
                );
                const double preferred_score = surface == "choice"
                    ? catalog.choice_score(state, 0, choice, preferred)
                    : catalog.action_score(state, 0, preferred);
                const double over_score = surface == "choice"
                    ? catalog.choice_score(state, 0, choice, over)
                    : catalog.action_score(state, 0, over);
                if (!(preferred_score > over_score)) {
                    std::cerr << scenario.value("id", "<unknown>") << ": "
                              << preferred_score << " <= " << over_score << '\n';
                    return 3;
                }
                ++count;
            }
        }
        std::cout << "CHALLENGE_CORE_TACTICS_OK scenarios=" << count << '\n';
        return count == 109 ? 0 : 4;
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 2;
    }
}
