#include "ptcg_json_adapter.hpp"
#include "ptcg_traditional_strategy.hpp"

#include <iostream>
#include <stdexcept>
#include <string>

using nlohmann::json;
using ptcg::ai::TraditionalStrategyCatalog;
using ptcg::ai::Value;

namespace {

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
