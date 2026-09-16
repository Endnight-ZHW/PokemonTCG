#include "planning/strategic_facts.hpp"

#include "ptcg_traditional_card.hpp"
#include "card_evaluation_detail.hpp"
#include "ptcg_traditional_value.hpp"

#include <algorithm>
#include <cmath>
#include <functional>
#include <limits>
#include <set>
#include <string>
#include <utility>
#include <vector>

namespace ptcg::ai::planning {
namespace {

using namespace traditional_value;
using traditional_card::active;
using traditional_card::bench_count;
using traditional_card::card;
using traditional_card::is_energy;
using traditional_card::player;
using namespace card_evaluation;

bool contains_token(const std::string &value, const std::string &token) {
    return value.find(token) != std::string::npos;
}

void inspect_semantic_token(const std::string &raw, CardSemanticProfile &profile) {
    const std::string token = lower_ascii(raw);
    profile.search = profile.search || contains_token(token, "search");
    profile.draw =
        profile.draw || contains_token(token, "draw") || contains_token(token, "look_top");
    profile.gust = profile.gust || contains_token(token, "gust") ||
                   contains_token(token, "switch_opponent") ||
                   contains_token(token, "opponent_bench");
    profile.self_switch = profile.self_switch ||
                          (contains_token(token, "switch") && !contains_token(token, "opponent"));
    profile.heal = profile.heal || contains_token(token, "heal");
    profile.prevent_damage = profile.prevent_damage || contains_token(token, "prevent_damage") ||
                             contains_token(token, "protection");
    profile.hand_disruption = profile.hand_disruption || contains_token(token, "hand_disruption") ||
                              contains_token(token, "shuffle_opponent_hand") ||
                              contains_token(token, "discard_opponent_hand");
    profile.energy_denial = profile.energy_denial ||
                            contains_token(token, "discard_opponent_energy") ||
                            contains_token(token, "energy_denial");
    profile.bench_damage = profile.bench_damage || contains_token(token, "bench_damage") ||
                           contains_token(token, "damage_bench");
    profile.recovery = profile.recovery || contains_token(token, "recover") ||
                       contains_token(token, "from_discard") ||
                       contains_token(token, "discard_to_hand");
    profile.acceleration = profile.acceleration || contains_token(token, "attach_energy") ||
                           contains_token(token, "energy_accel");
    profile.random = profile.random || contains_token(token, "coin") ||
                     contains_token(token, "random") || contains_token(token, "shuffle") ||
                     contains_token(token, "mill") || contains_token(token, "look_top");
    profile.reveals_information = profile.reveals_information || profile.search || profile.draw ||
                                  contains_token(token, "reveal") ||
                                  contains_token(token, "look_top");
    profile.irreversible = profile.irreversible || contains_token(token, "discard") ||
                           contains_token(token, "shuffle") || contains_token(token, "attach") ||
                           contains_token(token, "evolve");
}

void inspect_semantics(const Value &value, CardSemanticProfile &profile) {
    if (value.is_array()) {
        for (const Value &entry : value.as_array()) {
            inspect_semantics(entry, profile);
        }
        return;
    }
    if (!value.is_object())
        return;
    const std::string op = string_field(value, "op", string_field(value, "effect_type"));
    const Value *arguments = field(value, "args");
    if (arguments == nullptr)
        arguments = field(value, "params");
    static const Value empty = Value::make_object();
    const Value &args = arguments == nullptr ? empty : *arguments;
    if (op == "judge") {
        profile.hand_disruption = true;
        profile.draw = true;
        profile.random = true;
        profile.reveals_information = true;
    }
    if (op == "switch_pokemon") {
        const bool opponent = string_field(args, "target") == "opponent";
        profile.gust = profile.gust || opponent;
        profile.self_switch = profile.self_switch || !opponent;
    }
    const std::string filter = lower_ascii(string_field(args, "filter", "any"));
    if (op == "search_cards" || op == "search" || op == "look_top_deck") {
        const bool energy_filter = filter == "any" || filter.find("energy") != std::string::npos;
        profile.energy_search = profile.energy_search || energy_filter;
        profile.recovery = profile.recovery || string_field(args, "from_zone", "deck") == "discard";
    }
    if (op == "attach_energy_from_discard" || op == "attach_from_discard" ||
        op == "recover_clara" || op == "clara") {
        profile.discard_energy_source = true;
        profile.recovery = true;
    }
    for (const auto &[key, entry] : value.as_object()) {
        if ((key == "op" || key == "effect_type" || key == "kind") && entry.is_string()) {
            inspect_semantic_token(entry.string_or(), profile);
        }
        inspect_semantics(entry, profile);
    }
}

std::string action_card_id(const Value &action) {
    for (const char *container : {"source", "target", "payload"}) {
        const Value *value = field(action, container);
        if (value == nullptr || !value->is_object())
            continue;
        const std::string card_id = string_field(*value, "card_id");
        if (!card_id.empty())
            return card_id;
    }
    return {};
}

std::string reference_slot(const Value &action) {
    for (const char *container : {"target", "source"}) {
        const Value *value = field(action, container);
        if (value == nullptr || !value->is_object())
            continue;
        const std::string slot = string_field(*value, "slot");
        if (!slot.empty())
            return slot;
    }
    const Value *payload = field(action, "payload");
    return payload == nullptr ? std::string{} : string_field(*payload, "slot");
}

std::size_t prize_value(const Value &cards, const Value *pokemon) {
    const Value *definition =
        pokemon == nullptr ? nullptr : card(cards, string_field(*pokemon, "card_id"));
    return static_cast<std::size_t>(std::max<std::int64_t>(
        1, definition == nullptr ? 1 : integer_field(*definition, "prize_value", 1)));
}

std::size_t zone_size(const Value &owner, const char *key) {
    return array_field(owner, key).size();
}

std::string deck_key(const Value &state, std::int32_t actor) {
    const Value *keys = field(state, "public_deck_keys");
    return keys != nullptr && keys->is_array() && actor >= 0 &&
                   static_cast<std::size_t>(actor) < keys->as_array().size()
               ? keys->as_array()[static_cast<std::size_t>(actor)].string_or()
               : std::string{};
}

double attacker_selection_value(const AttackerClock &clock) {
    double value = clock.readiness_probability * 100.0 +
                   static_cast<double>(clock.max_relevant_damage) * 0.16 -
                   static_cast<double>(clock.prizes_exposed) * 7.0 -
                   static_cast<double>(clock.missing_evolution_steps) * 10.0;
    if (clock.primary_role)
        value += 45.0;
    if (clock.secondary_role)
        value += 22.0;
    if (clock.engine_role && !clock.primary_role && !clock.secondary_role) {
        value -= 28.0;
    }
    return value;
}

bool known_has(const Value::Array &known,
               const std::function<bool(const std::string &)> &predicate) {
    return std::any_of(known.begin(), known.end(),
                       [&](const Value &entry) { return predicate(entry.string_or()); });
}

std::size_t count_pool(const Value::Array &pool,
                       const std::function<bool(const std::string &)> &predicate) {
    return static_cast<std::size_t>(
        std::count_if(pool.begin(), pool.end(),
                      [&](const Value &entry) { return predicate(entry.string_or()); }));
}

double probability_for_role(const Value::Array &known, const Value::Array &pool, std::size_t looks,
                            const std::function<bool(const std::string &)> &predicate) {
    if (known_has(known, predicate))
        return 1.0;
    const std::size_t outs = count_pool(pool, predicate);
    // Current unknown hand plus the normal next-turn draw. The pool also
    // includes hidden prizes, which intentionally makes this conservative.
    return at_least_one_out_probability(pool.size(), outs, looks);
}

Value attacker_clock_value(const AttackerClock &clock) {
    return Value(Value::Object{
        {"slot", Value(clock.slot)},
        {"card_id", Value(clock.card_id)},
        {"earliest_ready_turn", Value(static_cast<std::int64_t>(clock.earliest_ready_turn))},
        {"expected_damage", Value(clock.expected_damage)},
        {"max_relevant_damage", Value(clock.max_relevant_damage)},
        {"prizes_exposed", Value(static_cast<std::int64_t>(clock.prizes_exposed))},
        {"missing_energy", Value(static_cast<std::int64_t>(clock.missing_energy))},
        {"missing_evolution_steps",
         Value(static_cast<std::int64_t>(clock.missing_evolution_steps))},
        {"readiness_probability", Value(clock.readiness_probability)},
        {"planned_card_id", Value(clock.planned_card_id)},
        {"attack_index", Value(static_cast<std::int64_t>(clock.attack_index))},
        {"reload_turns", Value(clock.reload_turns)},
        {"access_probability", Value(clock.access_probability)},
        {"ready_ko_probability", Value(clock.ready_ko_probability)},
        {"planned_ko_probability", Value(clock.planned_ko_probability)},
        {"promotion_delay", Value(static_cast<std::int64_t>(clock.promotion_delay))},
        {"primary_role", Value(clock.primary_role)},
        {"secondary_role", Value(clock.secondary_role)},
        {"engine_role", Value(clock.engine_role)},
    });
}

Value attacker_pipeline_value(const AttackerPipeline &pipeline) {
    Value::Array attackers;
    attackers.reserve(pipeline.attackers.size());
    for (const AttackerClock &clock : pipeline.attackers) {
        attackers.push_back(attacker_clock_value(clock));
    }
    return Value(Value::Object{
        {"attackers", Value(std::move(attackers))},
        {"current_slot", Value(pipeline.current_slot)},
        {"next_slot", Value(pipeline.next_slot)},
        {"backup_slot", Value(pipeline.backup_slot)},
        {"current_readiness", Value(pipeline.current_readiness)},
        {"next_readiness", Value(pipeline.next_readiness)},
        {"backup_readiness", Value(pipeline.backup_readiness)},
    });
}

} // namespace

CardSemanticModel::CardSemanticModel(Value catalog, std::shared_ptr<const Profiles> profiles)
    : profiles_(std::move(profiles)) {
    if (profiles_)
        return;
    const Value *rows = std::as_const(catalog).find("cards");
    const Value &cards = rows != nullptr && rows->is_object() ? *rows : catalog;
    auto computed = std::make_shared<Profiles>();
    for (const auto &[id, definition] : cards.as_object()) {
        auto &profile = (*computed)[id];
        profile.supporter = string_field(definition, "trainer_type") == "Supporter";
        inspect_semantics(definition, profile);
    }
    profiles_ = std::move(computed);
}

CardSemanticProfile CardSemanticModel::profile(const std::string &card_id) const {
    const auto cached = profiles_->find(card_id);
    return cached != profiles_->end() ? cached->second : CardSemanticProfile{};
}

BeliefTracker::BeliefTracker(Value catalog, const DeckPolicyRegistry &strategies)
    : strategies_(strategies), semantics_(catalog) {
    const Value *cards = catalog.find("cards");
    cards_ = cards != nullptr && cards->is_object() ? *cards : std::move(catalog);
}

BeliefSummary BeliefTracker::summarize(const InformationSet &information, const Value &public_state,
                                       std::int32_t actor) const {
    BeliefSummary result;
    if (!information.valid() || actor < 0 || actor > 1)
        return result;
    const std::int32_t opponent = 1 - actor;
    const Value::Array &known = information.known_hand(opponent);
    const Value::Array &pool = information.remaining_pool(opponent);
    result.known_hand_count = known.size();
    result.unknown_hand_count = information.unknown_hand_count(opponent);
    result.remaining_pool_count = pool.size();
    const auto has_role = [&](const std::string &card_id, const char *role) {
        return strategies_.card_has_role(public_state, opponent, card_id, role);
    };
    const auto gust = [&](const std::string &card_id) {
        return is_trainer(cards_, card_id) && semantics_.profile(card_id).gust;
    };
    const auto energy_out = [&](const std::string &card_id) {
        const CardSemanticProfile semantic = semantics_.profile(card_id);
        if (is_energy(cards_, card_id)) {
            return energy_improves_attack_readiness(public_state, opponent, card_id, cards_);
        }
        if (!is_trainer(cards_, card_id))
            return false;
        if (semantic.discard_energy_source) {
            const auto &discard = array_field(player(public_state, opponent), "discard");
            return std::any_of(discard.begin(), discard.end(), [&](const Value &entry) {
                return is_energy(cards_, entry.string_or()) &&
                       energy_improves_attack_readiness(public_state, opponent, entry.string_or(),
                                                        cards_);
            });
        }
        return semantic.energy_search &&
               !array_field(player(public_state, opponent), "deck").empty();
    };
    const auto switch_out = [&](const std::string &card_id) {
        return semantics_.profile(card_id).self_switch || has_role(card_id, "switch");
    };
    const auto hand_disruption = [&](const std::string &card_id) {
        return semantics_.profile(card_id).hand_disruption;
    };
    const std::size_t looks =
        result.unknown_hand_count +
        static_cast<std::size_t>(!array_field(player(public_state, opponent), "deck").empty());
    result.p_has_gust = probability_for_role(known, pool, looks, gust);
    result.p_has_energy_out = probability_for_role(known, pool, looks, energy_out);
    result.p_has_switch = probability_for_role(known, pool, looks, switch_out);
    result.p_has_hand_disruption = probability_for_role(known, pool, looks, hand_disruption);
    return result;
}

StrategicAnalyzer::Knowledge::Knowledge(const Value &catalog) {
    semantic_profiles = CardSemanticModel(catalog).profiles();
    const Value *rows = catalog.find("cards");
    const Value &cards = rows != nullptr && rows->is_object() ? *rows : catalog;
    for (const auto &[id, definition] : cards.as_object()) {
        if (!definition.is_object())
            continue;
        const std::string name = string_field(definition, "name");
        cards_by_name[name].push_back(id);
        if (!name.empty())
            evolves_from_by_name[name] = string_field(definition, "evolves_from");
    }
    for (const auto &[name, ids] : cards_by_name) {
        auto &options = evolutions[name];
        for (const auto &[id, definition] : cards.as_object()) {
            if (!definition.is_object())
                continue;
            const auto previous = string_field(definition, "evolves_from");
            const auto middle = evolves_from_by_name.find(previous);
            if (previous == name || (!previous.empty() && middle != evolves_from_by_name.end() &&
                                     middle->second == name)) {
                options.push_back({id, previous, previous == name});
            }
        }
    }
}

StrategicAnalyzer::StrategicAnalyzer(Value catalog, Value decks,
                                     const DeckPolicyRegistry &strategies,
                                     std::shared_ptr<const Knowledge> knowledge)
    : catalog_(std::move(catalog)), decks_(std::move(decks)), strategies_(strategies),
      knowledge_(knowledge ? std::move(knowledge) : std::make_shared<Knowledge>(catalog_)),
      semantics_(catalog_, knowledge_->semantic_profiles) {
    const Value *cards = catalog_.find("cards");
    cards_ = cards != nullptr && cards->is_object() ? *cards : catalog_;
}

std::size_t StrategicAnalyzer::missing_evolution_steps(const Value &state, std::int32_t actor,
                                                       const std::string &card_id) const {
    if (strategies_.card_has_role(state, actor, card_id, "primary_attacker") ||
        strategies_.card_has_role(state, actor, card_id, "secondary_attacker")) {
        return 0;
    }
    const Value *source = card(cards_, card_id);
    if (source == nullptr)
        return 0;
    const std::string source_name = string_field(*source, "name");
    if (source_name.empty())
        return 0;
    std::size_t best = 3;
    for (const auto &[candidate_id, definition] : cards_.as_object()) {
        if (!definition.is_object() ||
            (!strategies_.card_has_role(state, actor, candidate_id, "primary_attacker") &&
             !strategies_.card_has_role(state, actor, candidate_id, "secondary_attacker"))) {
            continue;
        }
        const std::string evolves_from = string_field(definition, "evolves_from");
        if (evolves_from == source_name)
            best = std::min<std::size_t>(best, 1);
        if (evolves_from.empty())
            continue;
        const auto middle = knowledge_->evolves_from_by_name.find(evolves_from);
        if (middle != knowledge_->evolves_from_by_name.end() && middle->second == source_name) {
            best = std::min<std::size_t>(best, 2);
        }
    }
    return best == 3 ? 0 : best;
}

AttackerClock StrategicAnalyzer::attacker_clock(const RulesSession &position, const Value &state,
                                                std::int32_t actor, const Value &pokemon,
                                                const std::string &slot) const {
    return combat_clock(position, state, actor, pokemon, slot);
}

AttackerPipeline StrategicAnalyzer::attacker_pipeline(const RulesSession &position,
                                                      const Value &state,
                                                      std::int32_t actor) const {
    const auto compute = [&] { return compute_attacker_pipeline(position, state, actor); };
    const auto context = context_.lock();
    return context ? context->memoize<AttackerPipeline>(SearchMemo::Pipeline, position, state,
                                                        actor, 1, compute)
                   : compute();
}

AttackerPipeline StrategicAnalyzer::compute_attacker_pipeline(const RulesSession &position,
                                                              const Value &state,
                                                              std::int32_t actor) const {
    AttackerPipeline result;
    const Value &owner = player(state, actor);
    const Value *active_pokemon = active(state, actor);
    if (active_pokemon != nullptr) {
        result.attackers.push_back(
            attacker_clock(position, state, actor, *active_pokemon, "active"));
        result.current_slot = "active";
        result.current_readiness = result.attackers.back().readiness_probability;
    }
    const Value::Array &bench = array_field(owner, "bench");
    for (std::size_t index = 0; index < bench.size(); ++index) {
        if (!bench[index].is_object())
            continue;
        result.attackers.push_back(
            attacker_clock(position, state, actor, bench[index], "bench_" + std::to_string(index)));
    }
    std::vector<const AttackerClock *> bench_candidates;
    for (const AttackerClock &clock : result.attackers) {
        if (clock.slot == "active")
            continue;
        // Bench engines are vital support pieces, but an engine-only line with
        // no attacker evolution must not become the planned energy target or
        // promotion merely because it is the only Pokemon on the Bench.
        const bool pure_engine =
            clock.engine_role && !clock.primary_role && !clock.secondary_role &&
            !strategies_.card_has_role(state, actor, clock.planned_card_id, "primary_attacker") &&
            !strategies_.card_has_role(state, actor, clock.planned_card_id, "secondary_attacker");
        if (!pure_engine) {
            bench_candidates.push_back(&clock);
        }
    }
    std::stable_sort(bench_candidates.begin(), bench_candidates.end(),
                     [](const AttackerClock *left, const AttackerClock *right) {
                         const double left_value = attacker_selection_value(*left);
                         const double right_value = attacker_selection_value(*right);
                         return left_value != right_value ? left_value > right_value
                                                          : left->slot < right->slot;
                     });
    if (!bench_candidates.empty()) {
        result.next_slot = bench_candidates[0]->slot;
        result.next_readiness = bench_candidates[0]->readiness_probability;
    }
    if (bench_candidates.size() > 1) {
        result.backup_slot = bench_candidates[1]->slot;
        result.backup_readiness = bench_candidates[1]->readiness_probability;
    }
    return result;
}

StrategicFacts StrategicAnalyzer::analyze(const RulesSession &position, const BeliefSummary &belief,
                                          std::int32_t actor) const {
    StrategicFacts result;
    result.actor = actor;
    result.belief = belief;
    if (actor < 0 || actor > 1)
        return result;
    const Value &state = position.search_state();
    const std::int32_t opponent = 1 - actor;
    result.turn_number = integer_field(state, "turn_number", 0);
    result.winner = integer_field(state, "winner", -1);
    result.terminal = string_field(state, "phase") == "GAME_OVER" ||
                      string_field(state, "result_status", "ONGOING") != "ONGOING";
    result.own_attackers = attacker_pipeline(position, state, actor);
    result.opponent_attackers = attacker_pipeline(position, state, opponent);

    const Value &own = player(state, actor);
    const Value &other = player(state, opponent);
    // A support Pokemon still prevents an immediate board-out even though it
    // is intentionally absent from the combat attacker pipeline.
    result.has_backup = bench_count(own) > 0;
    const Value *own_active = active(state, actor);
    const Value *opponent_active = active(state, opponent);
    result.prize_race.own_prizes_remaining = static_cast<std::int64_t>(zone_size(own, "prizes"));
    result.prize_race.opponent_prizes_remaining =
        static_cast<std::int64_t>(zone_size(other, "prizes"));
    result.opponent_deck_size = zone_size(other, "deck");
    result.prize_race.active_target_prizes =
        static_cast<std::int64_t>(prize_value(cards_, opponent_active));
    result.prize_race.own_active_prizes_exposed =
        static_cast<std::int64_t>(prize_value(cards_, own_active));
    result.active_can_attack = !result.own_attackers.attackers.empty() &&
                               result.own_attackers.attackers.front().expected_damage > 0;
    const std::int64_t opponent_hp = opponent_active == nullptr
                                         ? std::numeric_limits<std::int64_t>::max()
                                         : position.pokemon_current_hp(*opponent_active);
    result.active_can_take_prize =
        result.active_can_attack &&
        result.own_attackers.attackers.front().expected_damage >= opponent_hp;
    const std::size_t own_delay = result.own_attackers.attackers.empty()
                                      ? 3
                                      : result.own_attackers.attackers.front().earliest_ready_turn;
    const std::size_t opponent_delay =
        result.opponent_attackers.attackers.empty()
            ? 3
            : result.opponent_attackers.attackers.front().earliest_ready_turn;
    result.prize_race.own_turns_to_win = estimate_turns_to_win(
        result.prize_race.own_prizes_remaining, result.prize_race.active_target_prizes, own_delay);
    result.prize_race.opponent_turns_to_win =
        estimate_turns_to_win(result.prize_race.opponent_prizes_remaining,
                              result.prize_race.own_active_prizes_exposed, opponent_delay);
    {
        const auto &hand = array_field(own, "hand");
        const bool gust_in_hand = std::any_of(hand.begin(), hand.end(), [&](const Value &entry) {
            return semantics_.profile(entry.string_or()).gust;
        });
        result.prize_race.own_turns_to_win =
            prize_route(position, state, actor, result.own_attackers, gust_in_hand ? 0.5 : 0.0);
        result.prize_race.opponent_turns_to_win =
            prize_route(position, state, opponent, result.opponent_attackers, belief.p_has_gust);
    }
    result.prize_race.clock_margin =
        result.prize_race.opponent_turns_to_win - result.prize_race.own_turns_to_win;

    result.energy_schedule.attachment_available = !bool_field(own, "energy_attached_this_turn");
    result.energy_schedule.priority_slot = result.own_attackers.next_slot;
    for (const AttackerClock &clock : result.own_attackers.attackers) {
        result.energy_schedule.total_missing_energy += clock.missing_energy;
        if (clock.missing_energy == 0 && clock.max_relevant_damage > 0) {
            ++result.energy_schedule.ready_attackers;
        }
        if (clock.slot == result.energy_schedule.priority_slot) {
            result.energy_schedule.priority_missing_energy = clock.missing_energy;
        }
    }
    if (!result.active_can_attack && !result.own_attackers.attackers.empty()) {
        result.energy_schedule.priority_slot = "active";
        result.energy_schedule.priority_missing_energy =
            result.own_attackers.attackers.front().missing_energy;
    }

    result.resources.hand_size = zone_size(own, "hand");
    result.resources.deck_size = zone_size(own, "deck");
    result.resources.bench_count =
        static_cast<std::size_t>(std::max<std::int64_t>(0, bench_count(own)));
    result.resources.bench_slots_free =
        result.resources.bench_count >= 5 ? 0 : 5 - result.resources.bench_count;
    for (const Value &entry : array_field(own, "hand")) {
        const std::string card_id = entry.string_or();
        if (is_energy(cards_, card_id))
            ++result.resources.energy_in_hand;
        if (strategies_.card_has_role(state, actor, card_id, "switch")) {
            ++result.resources.switch_outs_visible;
        }
        if (strategies_.card_has_role(state, actor, card_id, "recovery")) {
            ++result.resources.recovery_outs_visible;
        }
        if (strategies_.card_has_role(state, actor, card_id, "disruption")) {
            ++result.resources.disruption_outs_visible;
        }
    }
    result.resources.flexibility =
        std::min(10.0, static_cast<double>(result.resources.hand_size) * 0.55 +
                           static_cast<double>(result.resources.bench_slots_free) * 0.45 +
                           static_cast<double>(result.resources.switch_outs_visible) * 1.2 +
                           static_cast<double>(result.resources.recovery_outs_visible) * 0.8);

    result.threats.own_active_hp =
        own_active == nullptr ? 0 : position.pokemon_current_hp(*own_active);
    result.threats.active_retaliation_damage =
        best_potential_retaliation_damage(position, state, opponent, cards_);
    const AttackerClock *opponent_clock = result.opponent_attackers.attackers.empty()
                                              ? nullptr
                                              : &result.opponent_attackers.attackers.front();
    double ko_probability = 0.0;
    if (opponent_clock != nullptr && result.threats.own_active_hp > 0) {
        {
            ko_probability = opponent_clock->ready_ko_probability;
            if (opponent_clock->missing_energy == 1)
                ko_probability =
                    std::max(ko_probability, result.belief.p_has_energy_out *
                                                 opponent_clock->planned_ko_probability);
        }
    }
    result.belief.p_can_ko_active = ko_probability;
    result.belief.p_can_ko_bench_target = std::min(result.belief.p_has_gust, ko_probability);
    result.threats.active_ko_threat = ko_probability >= 0.5;
    result.threats.board_loss_threat = !result.has_backup && ko_probability > 0.0;
    const bool prize_loss =
        result.prize_race.opponent_prizes_remaining <= result.prize_race.own_active_prizes_exposed;
    // Losing an ordinary active Pokemon is a prize-exchange/tempo event, not a
    // catastrophe.  Catastrophe is reserved for losing the match before the
    // next useful action (last Pokemon or enough prizes for the opponent).
    result.threats.catastrophe_probability =
        match_loss_probability(ko_probability, result.threats.board_loss_threat, prize_loss);

    result.risk_mode =
        result.prize_race.clock_margin > 0.75
            ? RiskMode::LowVariance
            : (result.prize_race.clock_margin < -0.75 ? RiskMode::SeekUpside : RiskMode::Balanced);
    return result;
}

Value belief_summary_value(const BeliefSummary &belief) {
    return Value(Value::Object{
        {"p_has_gust", Value(belief.p_has_gust)},
        {"p_has_energy_out", Value(belief.p_has_energy_out)},
        {"p_has_switch", Value(belief.p_has_switch)},
        {"p_has_hand_disruption", Value(belief.p_has_hand_disruption)},
        {"p_can_ko_active", Value(belief.p_can_ko_active)},
        {"p_can_ko_bench_target", Value(belief.p_can_ko_bench_target)},
        {"known_hand_count", Value(static_cast<std::int64_t>(belief.known_hand_count))},
        {"unknown_hand_count", Value(static_cast<std::int64_t>(belief.unknown_hand_count))},
        {"remaining_pool_count", Value(static_cast<std::int64_t>(belief.remaining_pool_count))},
    });
}

Value strategic_facts_value(const StrategicFacts &facts) {
    return Value(Value::Object{
        {"actor", Value(facts.actor)},
        {"turn_number", Value(facts.turn_number)},
        {"opponent_deck_size", Value(static_cast<std::int64_t>(facts.opponent_deck_size))},
        {"terminal", Value(facts.terminal)},
        {"winner", Value(facts.winner)},
        {"risk_mode", Value(risk_mode_name(facts.risk_mode))},
        {"active_can_attack", Value(facts.active_can_attack)},
        {"active_can_take_prize", Value(facts.active_can_take_prize)},
        {"has_backup", Value(facts.has_backup)},
        {"prize_race",
         Value(Value::Object{
             {"own_prizes_remaining", Value(facts.prize_race.own_prizes_remaining)},
             {"opponent_prizes_remaining", Value(facts.prize_race.opponent_prizes_remaining)},
             {"own_turns_to_win", Value(facts.prize_race.own_turns_to_win)},
             {"opponent_turns_to_win", Value(facts.prize_race.opponent_turns_to_win)},
             {"clock_margin", Value(facts.prize_race.clock_margin)},
             {"active_target_prizes", Value(facts.prize_race.active_target_prizes)},
             {"own_active_prizes_exposed", Value(facts.prize_race.own_active_prizes_exposed)},
         })},
        {"own_attackers", attacker_pipeline_value(facts.own_attackers)},
        {"opponent_attackers", attacker_pipeline_value(facts.opponent_attackers)},
        {"energy_schedule",
         Value(Value::Object{
             {"attachment_available", Value(facts.energy_schedule.attachment_available)},
             {"priority_slot", Value(facts.energy_schedule.priority_slot)},
             {"priority_missing_energy",
              Value(static_cast<std::int64_t>(facts.energy_schedule.priority_missing_energy))},
             {"total_missing_energy",
              Value(static_cast<std::int64_t>(facts.energy_schedule.total_missing_energy))},
             {"ready_attackers",
              Value(static_cast<std::int64_t>(facts.energy_schedule.ready_attackers))},
         })},
        {"resources",
         Value(Value::Object{
             {"hand_size", Value(static_cast<std::int64_t>(facts.resources.hand_size))},
             {"deck_size", Value(static_cast<std::int64_t>(facts.resources.deck_size))},
             {"bench_count", Value(static_cast<std::int64_t>(facts.resources.bench_count))},
             {"bench_slots_free",
              Value(static_cast<std::int64_t>(facts.resources.bench_slots_free))},
             {"energy_in_hand", Value(static_cast<std::int64_t>(facts.resources.energy_in_hand))},
             {"switch_outs_visible",
              Value(static_cast<std::int64_t>(facts.resources.switch_outs_visible))},
             {"recovery_outs_visible",
              Value(static_cast<std::int64_t>(facts.resources.recovery_outs_visible))},
             {"flexibility", Value(facts.resources.flexibility)},
         })},
        {"threats",
         Value(Value::Object{
             {"active_retaliation_damage", Value(facts.threats.active_retaliation_damage)},
             {"own_active_hp", Value(facts.threats.own_active_hp)},
             {"active_ko_threat", Value(facts.threats.active_ko_threat)},
             {"board_loss_threat", Value(facts.threats.board_loss_threat)},
             {"catastrophe_probability", Value(facts.threats.catastrophe_probability)},
         })},
        {"belief", belief_summary_value(facts.belief)},
    });
}

} // namespace ptcg::ai::planning
