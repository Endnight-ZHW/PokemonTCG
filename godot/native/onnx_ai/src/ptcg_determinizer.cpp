#include "ptcg_determinizer.hpp"

#include "ptcg_ai_core.hpp"
#include "ptcg_infoset.hpp"

#include <algorithm>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace ptcg::ai {

namespace {

using Array = Value::Array;

const Value &required(const Value &value, const std::string &key) {
    const Value *found = value.find(key);
    if (found == nullptr) {
        throw std::invalid_argument("determinizer_missing_field:" + key);
    }
    return *found;
}

std::string string_field(
    const Value &value,
    const std::string &key
) {
    const Value *found = value.find(key);
    return found == nullptr ? std::string{} : found->string_or();
}

std::int64_t integer_field(
    const Value &value,
    const std::string &key,
    std::int64_t fallback = 0
) {
    const Value *found = value.find(key);
    return found == nullptr ? fallback : found->as_integer(fallback);
}

Array expand_deck(
    const Value &deck_specs,
    const std::string &deck_key
) {
    const Value *definition = deck_specs.find(deck_key);
    if (definition == nullptr) {
        throw std::invalid_argument("missing_deck_prior:" + deck_key);
    }
    if (definition->is_array()) {
        return definition->as_array();
    }
    const Value *rows = definition->find("cards");
    if (rows == nullptr || !rows->is_array()) {
        throw std::invalid_argument("invalid_deck_prior:" + deck_key);
    }
    Array result;
    for (const Value &row : rows->as_array()) {
        if (!row.is_object()) {
            throw std::invalid_argument(
                "invalid_deck_prior_row:" + deck_key
            );
        }
        const std::string card_id = string_field(row, "card_id");
        const std::int64_t count = integer_field(row, "count", -1);
        if (card_id.empty() || count < 0 || count > 60) {
            throw std::invalid_argument(
                "invalid_deck_prior_row:" + deck_key
            );
        }
        for (std::int64_t copy = 0; copy < count; ++copy) {
            result.emplace_back(card_id);
        }
    }
    return result;
}

void append_visible_pokemon(
    std::vector<std::string> &result,
    const Value *pokemon
) {
    if (pokemon == nullptr || !pokemon->is_object()) {
        return;
    }
    const std::string card_id = string_field(*pokemon, "card_id");
    if (!card_id.empty()) {
        result.push_back(card_id);
    }
    for (const char *field : {
        "evolution_stack_ids",
        "energy_card_ids",
    }) {
        const Value *cards = pokemon->find(field);
        if (cards == nullptr || !cards->is_array()) {
            continue;
        }
        for (const Value &entry : cards->as_array()) {
            if (!entry.string_or().empty()) {
                result.push_back(entry.string_or());
            }
        }
    }
    const std::string tool = string_field(
        *pokemon,
        "attached_tool_id"
    );
    if (!tool.empty()) {
        result.push_back(tool);
    }
}

std::vector<std::string> visible_cards(
    const Value &state,
    std::int32_t player_index,
    std::int32_t actor
) {
    const Value &player = required(state, "players").as_array().at(
        static_cast<std::size_t>(player_index)
    );
    std::vector<std::string> result;
    for (const char *zone : {"discard"}) {
        const Value *cards = player.find(zone);
        if (cards == nullptr || !cards->is_array()) {
            continue;
        }
        for (const Value &entry : cards->as_array()) {
            if (!entry.string_or().empty()) {
                result.push_back(entry.string_or());
            }
        }
    }
    if (player_index == actor) {
        const Value *hand = player.find("hand");
        if (hand != nullptr && hand->is_array()) {
            for (const Value &entry : hand->as_array()) {
                if (!entry.string_or().empty()) {
                    result.push_back(entry.string_or());
                }
            }
        }
    }
    append_visible_pokemon(result, player.find("active"));
    const Value *bench = player.find("bench");
    if (bench != nullptr && bench->is_array()) {
        for (const Value &pokemon : bench->as_array()) {
            append_visible_pokemon(result, &pokemon);
        }
    }
    if (
        integer_field(state, "stadium_owner_idx", -1) == player_index
    ) {
        const std::string stadium = string_field(
            state,
            "stadium_card_id"
        );
        if (!stadium.empty()) {
            result.push_back(stadium);
        }
    }
    return result;
}

void remove_visible(
    Array &pool,
    const std::vector<std::string> &visible,
    const std::string &deck_key
) {
    for (const std::string &card_id : visible) {
        const auto found = std::find_if(
            pool.begin(),
            pool.end(),
            [&card_id](const Value &entry) {
                return entry.string_or() == card_id;
            }
        );
        if (found == pool.end()) {
            throw std::invalid_argument(
                "deck_prior_visible_card_mismatch:"
                + deck_key
                + ":"
                + card_id
            );
        }
        pool.erase(found);
    }
}

void shuffle(Array &values, XorShift32 &rng) {
    for (std::size_t index = values.size(); index > 1; --index) {
        const std::size_t selected = rng.next_u32() % index;
        std::swap(values[index - 1], values[selected]);
    }
}

Array slice(
    const Array &source,
    std::size_t begin,
    std::size_t end
) {
    return Array(
        source.begin() + static_cast<std::ptrdiff_t>(begin),
        source.begin() + static_cast<std::ptrdiff_t>(end)
    );
}

} // namespace

NativeDeterminizer::NativeDeterminizer(Value deck_specs)
    : deck_specs_(std::move(deck_specs)) {
    if (!deck_specs_.is_object()) {
        throw std::invalid_argument("deck_specs_must_be_object");
    }
}

void NativeDeterminizer::set_decks(Value deck_specs) {
    if (!deck_specs.is_object()) {
        throw std::invalid_argument("deck_specs_must_be_object");
    }
    deck_specs_ = std::move(deck_specs);
}

Value NativeDeterminizer::determinize(
    const Value &snapshot,
    std::int32_t actor,
    std::uint32_t seed
) const {
    InformationSetProjection projection = project_information_set(
        snapshot,
        actor
    );
    Value state = std::move(projection.observation);
    Value &players_value = state["players"];
    Array &players = players_value.as_array();
    const Value &keys = required(state, "public_deck_keys");
    if (!keys.is_array() || keys.as_array().size() != 2) {
        throw std::invalid_argument("invalid_public_deck_keys");
    }
    XorShift32 rng(seed);
    for (std::int32_t player_index = 0; player_index < 2; ++player_index) {
        const std::string deck_key = keys.as_array()[
            static_cast<std::size_t>(player_index)
        ].string_or();
        Array pool = expand_deck(deck_specs_, deck_key);
        remove_visible(
            pool,
            visible_cards(state, player_index, actor),
            deck_key
        );
        Value &owner = players[static_cast<std::size_t>(player_index)];
        const std::size_t hand_count = player_index == actor
            ? 0
            : required(owner, "hand").as_array().size();
        const std::size_t deck_count = required(
            owner,
            "deck"
        ).as_array().size();
        const std::size_t prize_count = required(
            owner,
            "prizes"
        ).as_array().size();
        const std::size_t hidden_count =
            hand_count + deck_count + prize_count;
        if (pool.size() != hidden_count) {
            throw std::invalid_argument(
                "deck_prior_hidden_count_mismatch:"
                + deck_key
                + ":"
                + std::to_string(pool.size())
                + "!="
                + std::to_string(hidden_count)
            );
        }
        shuffle(pool, rng);
        std::size_t cursor = 0;
        if (player_index != actor) {
            owner["hand"] = Value(slice(
                pool,
                cursor,
                cursor + hand_count
            ));
            cursor += hand_count;
        }
        owner["deck"] = Value(slice(
            pool,
            cursor,
            cursor + deck_count
        ));
        cursor += deck_count;
        owner["prizes"] = Value(slice(
            pool,
            cursor,
            cursor + prize_count
        ));
    }
    state.erase("perspective");
    state.erase("actor");
    return state;
}

} // namespace ptcg::ai
