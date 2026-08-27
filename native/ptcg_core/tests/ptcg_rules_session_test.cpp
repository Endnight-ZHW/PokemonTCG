#include "ptcg_rules_session.hpp"
#include "ptcg_typed_ir.hpp"
#include "ptcg_typed_state.hpp"

#include <cstdint>
#include <algorithm>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>

namespace {

using ptcg::ai::RulesSession;
using ptcg::ai::Value;
using Array = Value::Array;
using Object = Value::Object;

void require(bool condition, const char *message) {
    if (!condition) {
        throw std::runtime_error(message);
    }
}

Value catalog() {
    return Value(Object{
        {"test-basic", Value(Object{
            {"name", Value("Test Basic")},
            {"supertype", Value("Pokémon")},
            {"subtypes", Value(Array{Value("Basic")})},
            {"energy_types", Value(Array{Value("Fire")})},
            {"hp", Value(60)},
            {"attacks", Value::make_array()},
            {"abilities", Value::make_array()},
            {"prize_value", Value(1)},
        })},
        {"test-weak", Value(Object{
            {"name", Value("Test Weak")},
            {"supertype", Value("Pokémon")},
            {"subtypes", Value(Array{Value("Basic")})},
            {"energy_types", Value(Array{Value("Grass")})},
            {"weaknesses", Value(Array{Value(Object{
                {"energy_type", Value("Fire")},
                {"value", Value("x2")},
            })})},
            {"resistances", Value::make_array()},
            {"hp", Value(120)},
            {"attacks", Value::make_array()},
            {"abilities", Value::make_array()},
            {"prize_value", Value(1)},
        })},
        {"test-resistant", Value(Object{
            {"name", Value("Test Resistant")},
            {"supertype", Value("Pokémon")},
            {"subtypes", Value(Array{Value("Basic")})},
            {"energy_types", Value(Array{Value("Grass")})},
            {"weaknesses", Value::make_array()},
            {"resistances", Value(Array{Value(Object{
                {"energy_type", Value("Fire")},
                {"value", Value("-30")},
            })})},
            {"hp", Value(120)},
            {"attacks", Value::make_array()},
            {"abilities", Value::make_array()},
            {"prize_value", Value(1)},
        })},
    });
}

Value decks() {
    Array deck(60, Value("test-basic"));
    return Value(Array{Value(deck), Value(deck)});
}

Value bind_action(
    const Value &query,
    const std::string &kind,
    const std::string &action_id
) {
    const Array &groups = query.find("groups")->as_array();
    for (const Value &group : groups) {
        if (group.find("kind")->string_or() != kind) {
            continue;
        }
        const Array &targets = group.find("targets")->as_array();
        return Value(Object{
            {"schema_version", Value(4)},
            {"action_id", Value(action_id)},
            {"base_revision", *query.find("base_revision")},
            {"actor", *group.find("actor")},
            {"kind", *group.find("kind")},
            {"source", *group.find("source")},
            {"target", targets.empty() ? Value() : targets.front()},
            {"payload", *group.find("payload")},
        });
    }
    throw std::runtime_error("requested legal action is missing");
}

std::int32_t setup_actor(const RulesSession &session) {
    return static_cast<std::int32_t>(
        session.snapshot().find("setup_actor_idx")->as_integer());
}

bool log_contains(const Value &state, const std::string &needle) {
    const Value *log = state.find("action_log");
    return log != nullptr && log->is_array() && std::any_of(
        log->as_array().begin(),
        log->as_array().end(),
        [&needle](const Value &entry) {
            return entry.string_or().find(needle) != std::string::npos;
        }
    );
}

std::string first_difference(
    const Value &left,
    const Value &right,
    const std::string &path = "$"
) {
    if (left == right) return {};
    if (left.type() != right.type()) return path + ":type";
    if (left.is_array()) {
        if (left.as_array().size() != right.as_array().size()) {
            return path + ":array_size";
        }
        for (std::size_t index = 0; index < left.as_array().size(); ++index) {
            const std::string nested = first_difference(
                left.as_array()[index], right.as_array()[index],
                path + "[" + std::to_string(index) + "]");
            if (!nested.empty()) return nested;
        }
    } else if (left.is_object()) {
        if (left.as_object().size() != right.as_object().size()) {
            for (const auto &[key, ignored] : left.as_object()) {
                (void)ignored;
                if (!right.contains(key)) return path + ":missing_right:" + key;
            }
            for (const auto &[key, ignored] : right.as_object()) {
                (void)ignored;
                if (!left.contains(key)) return path + ":missing_left:" + key;
            }
            return path + ":object_size";
        }
        for (const auto &[key, value] : left.as_object()) {
            const Value *other = right.find(key);
            if (other == nullptr) return path + ":missing_right:" + key;
            const std::string nested = first_difference(
                value, *other, path + "." + key);
            if (!nested.empty()) return nested;
        }
    }
    return path + ":value";
}

Value choose(const Value &pending, const std::string &option_id) {
    return Value(Object{
        {"request_id", *pending.find("request_id")},
        {"option_ids", Value(Array{Value(option_id)})},
        {"cancelled", Value(false)},
    });
}

const Value &active_of(const Value &state, std::size_t owner) {
    return *state.find("players")->as_array()[owner].find("active");
}

} // namespace

int main() {
    try {
        const Value cards = catalog();
        const Value match_decks = decks();
        const Value config(Object{
            {"forced_first", Value(0)},
            {"public_deck_keys", Value(Array{Value("a"), Value("b")})},
        });
        RulesSession session;
        const auto created = session.create(cards, match_decks, config, 12345U);
        require(created.success, "create failed");
        require(session.revision() == 0, "initial revision mismatch");
        const Value core_contract = session.contract();
        require(core_contract.find("typed_authoritative_state")->as_bool()
                && core_contract.find("typed_vm_ir")->as_bool(),
            "typed authoritative state/VM IR contract is disabled");
        ptcg::ai::typed::VmProgram typed_program;
        std::string typed_program_error;
        require(ptcg::ai::typed::compile_vm_program(Value(Array{Value(Object{
                {"op", Value("deal_damage")},
                {"args", Value(Object{{"formula_ast", Value(Object{
                    {"op", Value("add")},
                    {"terms", Value(Array{
                        Value(Object{{"const", Value(30)}}),
                        Value(Object{
                            {"op", Value("energy_count")},
                            {"scope", Value("self")},
                        }),
                    })},
                })}})},
                {"branches", Value::make_object()},
            })}), *std::make_shared<ptcg::ai::typed::CardStringTable>(cards),
            typed_program, &typed_program_error),
            "typed VM program compilation failed");
        require(typed_program.commands.size() == 1
                && typed_program.commands.front().op
                    == ptcg::ai::typed::VmOp::deal_damage
                && typed_program.commands.front().arguments.size() == 1
                && std::holds_alternative<ptcg::ai::typed::Formula>(
                    typed_program.commands.front().arguments.front().value),
            "typed VM command/formula fields diverged");
        require(session.contract().find("native_abi_version")->as_integer() == 2,
            "ABI mismatch");
        require(session.contract().find("framework_dependencies")->as_array().empty(),
            "core dependency contract mismatch");
        const std::string created_hash = session.state_hash();
        const auto recreated = session.create(match_decks, config, 999U);
        require(!recreated.success
                && recreated.error_code == "match_already_started",
            "an initialized core session accepted create twice");
        require(session.state_hash() == created_hash,
            "rejected recreate mutated state");

        RulesSession repeated;
        require(repeated.create(cards, match_decks, config, 12345U).success,
            "repeat create failed");
        require(repeated.state_hash() == session.state_hash(),
            "same seed did not reproduce state");
        require(repeated.rng_state() == session.rng_state(),
            "same seed did not reproduce RNG");

        Value query = session.legal_actions(0);
        require(query.find("success")->as_bool(), "legal query failed");
        require(query.find("schema_version")->as_integer() == 1,
            "legal query schema mismatch");
        Value play = bind_action(query, "PLAY_BASIC", "cpp:play:0");
        Value missing_id = play.deep_clone();
        missing_id["action_id"] = Value("");
        const auto malformed = session.apply_action(missing_id);
        require(!malformed.success && malformed.error_code == "invalid_schema",
            "empty Action v4 ID was accepted");
        require(session.state_hash() == created_hash,
            "malformed Action v4 mutated state");
        const auto played = session.apply_action(play);
        require(played.success, "play basic failed");
        require(played.events.size() == 1,
            "play basic presentation event count mismatch");
        const Value &played_event = played.events.front();
        require(played_event.find("event_type")->string_or()
                == "pokemon_played",
            "play basic presentation event type mismatch");
        require(played_event.find("card_id")->string_or() == "test-basic",
            "play basic presentation event lost card identity");
        require(played_event.find("visibility")->string_or() == "owner",
            "setup play presentation event leaked hidden identity");
        require(played_event.find("source")->find("zone")->string_or()
                == "hand",
            "play basic presentation event lost source endpoint");
        require(played_event.find("target")->find("slot")->string_or()
                == "active",
            "play basic presentation event lost target endpoint");
        const std::string stable_hash = session.state_hash();
        const std::uint32_t stable_rng = session.rng_state();
        const Value stable_journal = session.journal();
        const auto duplicate = session.apply_action(play);
        require(!duplicate.success && duplicate.error_code == "duplicate_action",
            "duplicate did not fail closed");
        require(session.state_hash() == stable_hash, "duplicate mutated state");
        require(session.rng_state() == stable_rng, "duplicate mutated RNG");
        require(session.journal() == stable_journal, "duplicate mutated journal");

        const Value owner_view = session.view_for(0);
        const Value opponent_view = session.view_for(1);
        require(owner_view.find("your")->find("hand") != nullptr,
            "owner hand missing");
        require(owner_view.find("opponent")->find("hand") == nullptr,
            "opponent hand exposed");
        require(opponent_view.find("opponent")->find("active")->is_object(),
            "setup identity was not hidden");
        require(log_contains(opponent_view, "暗置宝可梦"),
            "opponent setup log omitted the hidden placement action");
        require(!log_contains(opponent_view, "Test Basic"),
            "opponent setup log leaked the hidden Pokémon identity");

        const Value snapshot = session.snapshot();
        auto typed_cards = std::make_shared<ptcg::ai::typed::CardStringTable>(cards);
        ptcg::ai::typed::StateCodec typed_codec(typed_cards);
        ptcg::ai::typed::GameState typed_snapshot;
        std::string typed_error;
        require(typed_codec.decode_state(snapshot, typed_snapshot, &typed_error),
            "typed Snapshot 3 decode failed");

        Value legacy_reply_snapshot = snapshot.deep_clone();
        Value &legacy_active = legacy_reply_snapshot.find("players")
            ->as_array()[0]["active"];
        legacy_active["damage_prevented"] = Value(true);
        legacy_active["all_prevented"] = Value(true);
        legacy_active["outgoing_damage_reduction"] = Value(50);
        legacy_active["modifiers"] = Value(Array{Value(Object{
            {"condition", Value(Object{{"expires_after_turn", Value(12)}})},
            {"conflict_policy", Value("commutative")},
            {"controller", Value(0)},
            {"duration", Value("until_end_of_opponents_next_turn")},
            {"hook", Value("PREVENT_EFFECTS")},
            {"layer", Value("prevent")},
            {"operation", Value(Object{{"kind", Value("prevent_effects")}})},
            {"priority", Value(0)},
            {"scope", Value("self")},
            {"source_ref", Value(Object{
                {"card_id", Value("test-basic")},
                {"kind", Value("pokemon")},
                {"player", Value(0)},
                {"slot", Value("active")},
            })},
            {"stacking", Value("replace_same_source")},
        })});
        RulesSession legacy_reply(cards);
        std::string legacy_reply_error;
        require(legacy_reply.restore(
                legacy_reply_snapshot, 0xC10E0001U, &legacy_reply_error),
            "legacy reply projection fixture restore failed");
        auto projected_reply = legacy_reply.fork_for_reply_search();
        require(projected_reply != nullptr,
            "legacy reply projection fork failed");
        const Value &projected_active = active_of(
            projected_reply->search_state(), 0);
        require(projected_active.find("damage_prevented") == nullptr
                && projected_active.find("all_prevented") == nullptr
                && projected_active.find("outgoing_damage_reduction") == nullptr,
            "legacy reply projection retained DTO-excluded compatibility flags");
        require(projected_active.find("modifiers") != nullptr
                && projected_active.find("modifiers")->is_array()
                && projected_active.find("modifiers")->as_array().size() == 1,
            "legacy reply projection discarded canonical modifiers");
        require(active_of(legacy_reply.search_state(), 0).find(
                "all_prevented") != nullptr,
            "legacy reply projection mutated its parent state");
        Value snapshot_payload = snapshot.deep_clone();
        snapshot_payload.erase("snapshot_version");
        const Value typed_roundtrip = typed_codec.encode_state(typed_snapshot);
        if (!(typed_roundtrip == snapshot_payload)) {
            std::cerr << "TYPED_SNAPSHOT_DIFF "
                << first_difference(snapshot_payload, typed_roundtrip) << '\n';
        }
        require(typed_roundtrip == snapshot_payload,
            "typed Snapshot 3 roundtrip diverged");
        ptcg::ai::typed::Action typed_play;
        require(typed_codec.decode_action(play, typed_play, &typed_error),
            "typed Action v4 decode failed");
        require(typed_codec.encode_action(typed_play) == play,
            "typed Action v4 roundtrip diverged");
        auto forked = session.fork();
        require(forked->snapshot() == snapshot, "fork snapshot mismatch");
        const std::string parent_hash_before_search_fork = session.state_hash();
        const std::uint32_t parent_rng_before_search_fork = session.rng_state();
        auto search_fork = session.fork_for_search(424242U);
        require(search_fork->snapshot() == snapshot,
            "search fork snapshot mismatch");
        require(search_fork->rng_state() == 424242U,
            "search fork did not install branch RNG");
        Value search_query = search_fork->legal_actions(setup_actor(*search_fork));
        Value cached_setup_action = bind_action(
            search_query, "SETUP_DONE", "cpp:search-fork:setup-done");
        Value tampered_cached_action = cached_setup_action;
        tampered_cached_action["payload"]["unexpected"] = Value(true);
        const auto tampered_search_step =
            search_fork->apply_action_for_search(tampered_cached_action);
        require(
            !tampered_search_step.success
                && tampered_search_step.error_code == "illegal_action",
            "typed candidate cache accepted altered Action v4 payload");
        const auto search_step = search_fork->apply_action_for_search(
            cached_setup_action);
        require(search_step.success, "search fork action failed");
        const auto public_search_apply = session.apply_action_for_search(play);
        require(
            !public_search_apply.success
                && public_search_apply.error_code
                    == "search_action_requires_search_fork",
            "public session accepted the AI-only action cache path");
        require(session.state_hash() == parent_hash_before_search_fork,
            "search fork mutated parent state");
        require(session.rng_state() == parent_rng_before_search_fork,
            "search fork mutated parent RNG");
        RulesSession restored(cards);
        std::string restore_error;
        require(restored.restore(snapshot, session.rng_state(), &restore_error),
            "restore failed");
        require(restored.state_hash() == session.state_hash(),
            "restore hash mismatch");
        const std::string restored_hash = restored.state_hash();
        const std::uint32_t restored_rng = restored.rng_state();
        Value invalid_snapshot = snapshot.deep_clone();
        (*invalid_snapshot.find("resolution_stack"))["frames"] = Value(Array{
            Value(Object{{"kind", Value("legacy_effect")}}),
        });
        require(!restored.restore(invalid_snapshot, 999U, &restore_error),
            "invalid continuation snapshot was accepted");
        require(restored.state_hash() == restored_hash,
            "failed restore mutated state");
        require(restored.rng_state() == restored_rng,
            "failed restore mutated RNG");

        RulesSession choice_session;
        const auto choice_created = choice_session.create(
            cards, match_decks, Value::make_object(), 8080U);
        require(choice_created.success && !choice_created.pending.is_null(),
            "turn-order choice fixture failed");
        ptcg::ai::typed::ChoiceView typed_choice;
        require(typed_codec.decode_choice_view(
            choice_created.pending, typed_choice, &typed_error),
            "typed ChoiceView v2 decode failed");
        require(typed_choice.request_kind
                == ptcg::ai::typed::ChoiceRequestKind::choose_turn_order
                && typed_choice.player >= 0
                && typed_choice.options.size() == 2,
            "typed ChoiceView v2 fields diverged");
        require(typed_codec.encode_choice_view(typed_choice)
                == choice_created.pending,
            "typed ChoiceView v2 roundtrip diverged");
        const auto *cached_typed_choice =
            choice_session.typed_search_pending_choice(typed_choice.player);
        require(cached_typed_choice != nullptr
                && cached_typed_choice->request_id == typed_choice.request_id,
            "RulesSession typed pending Choice cache diverged");
        Value invalid_choice(Object{
            {"request_id", *choice_created.pending.find("request_id")},
            {"option_ids", Value::make_array()},
            {"cancelled", Value(false)},
            {"extra", Value(true)},
        });
        const std::string choice_hash = choice_session.state_hash();
        const auto malformed_choice = choice_session.apply_choice(
            invalid_choice);
        require(!malformed_choice.success
                && malformed_choice.error_code == "invalid_choice",
            "ChoiceResponse with an extra field was accepted");
        require(choice_session.state_hash() == choice_hash,
            "malformed ChoiceResponse mutated state");

        query = session.legal_actions(setup_actor(session));
        require(session.apply_action(bind_action(
            query, "SETUP_DONE", "cpp:done:0")).success,
            "first setup done failed");
        const std::int32_t second = setup_actor(session);
        query = session.legal_actions(second);
        require(session.apply_action(bind_action(
            query, "PLAY_BASIC", "cpp:play:1")).success,
            "second play basic failed");
        query = session.legal_actions(second);
        require(session.apply_action(bind_action(
            query, "SETUP_DONE", "cpp:done:1")).success,
            "second setup done failed");
        const Value completed = session.snapshot();
        require(completed.find("setup_stage")->string_or() == "COMPLETE",
            "setup did not complete");
        require(completed.find("phase")->string_or() == "MAIN",
            "first turn did not begin");
        require(log_contains(completed, "暗置宝可梦"),
            "setup action was absent from the public action log");
        require(log_contains(completed, "完成了开局宝可梦放置"),
            "setup completion was absent from the public action log");
        require(log_contains(completed, "的回合"),
            "turn start was absent from the public action log");
        require(log_contains(completed, "抽取了"),
            "draw event was absent from the public action log");
        for (const Value &player : completed.find("players")->as_array()) {
            require(player.find("prizes")->as_array().size() == 6,
                "prizes were not placed");
        }

        Value matchup_snapshot = completed.deep_clone();
        matchup_snapshot["apply_type_matchups"] = Value(true);
        (*matchup_snapshot.find("rules_options"))["apply_type_matchups"] =
            Value(true);
        Value &matchup_defender = matchup_snapshot.find("players")
            ->as_array()[1]["active"];
        matchup_defender["card_id"] = Value("test-weak");
        RulesSession matchup(cards);
        require(matchup.restore(
                matchup_snapshot, 0x54595045U, &restore_error),
            "type-matchup scenario restore failed");
        const Value matchup_state = matchup.snapshot();
        const Value &matchup_attacker = active_of(matchup_state, 0);
        const Value &weak_defender = active_of(matchup_state, 1);
        require(matchup.estimate_public_damage(
                0, matchup_attacker, weak_defender, 30) == 60,
            "enabled weakness did not apply after attacker modifiers");

        matchup_snapshot.find("players")->as_array()[1]["active"]
            ["card_id"] = Value("test-resistant");
        RulesSession resistance(cards);
        require(resistance.restore(
                matchup_snapshot, 0x52455349U, &restore_error),
            "resistance scenario restore failed");
        const Value resistance_state = resistance.snapshot();
        require(resistance.estimate_public_damage(
                0,
                active_of(resistance_state, 0),
                active_of(resistance_state, 1),
                50
            ) == 20,
            "enabled resistance did not apply before defender modifiers");

        matchup_snapshot["apply_type_matchups"] = Value(false);
        (*matchup_snapshot.find("rules_options"))["apply_type_matchups"] =
            Value(false);
        matchup_snapshot.find("players")->as_array()[1]["active"]
            ["card_id"] = Value("test-weak");
        RulesSession disabled_matchup(cards);
        require(disabled_matchup.restore(
                matchup_snapshot, 0x4E4F5459U, &restore_error),
            "disabled type-matchup scenario restore failed");
        const Value disabled_state = disabled_matchup.snapshot();
        require(disabled_matchup.estimate_public_damage(
                0,
                active_of(disabled_state, 0),
                active_of(disabled_state, 1),
                30
            ) == 30,
            "disabled type matchups changed damage");

        Value deck_out_snapshot = completed.deep_clone();
        deck_out_snapshot["snapshot_version"] = Value(3);
        deck_out_snapshot["active_player_idx"] = Value(0);
        deck_out_snapshot["phase"] = Value("MAIN");
        deck_out_snapshot.find("players")->as_array()[1]["deck"] =
            Value::make_array();
        RulesSession deck_out(cards);
        require(deck_out.restore(deck_out_snapshot, 9090U, &restore_error),
            "deck-out scenario restore failed");
        Value end_query = deck_out.legal_actions(0);
        const auto deck_out_step = deck_out.apply_action(bind_action(
            end_query, "END_TURN", "cpp:deck-out"));
        require(deck_out_step.success && deck_out_step.terminal
                && deck_out_step.winner == 0,
            "mandatory turn draw did not award a deck-out win");
        require(deck_out_step.state.find("result_reason")->string_or()
                == "deck_exhausted",
            "deck-out result reason mismatch");
        bool saw_deck_out = false;
        for (const Value &event : deck_out_step.events) {
            saw_deck_out = saw_deck_out || (
                event.find("event_type") != nullptr
                && event.find("event_type")->string_or()
                    == "deck_exhausted");
        }
        require(saw_deck_out, "deck-out event missing");

        Value checkup_snapshot = completed.deep_clone();
        checkup_snapshot["active_player_idx"] = Value(0);
        checkup_snapshot["phase"] = Value("MAIN");
        checkup_snapshot["turn_number"] = Value(3);
        Value &poisoned = checkup_snapshot.find("players")
            ->as_array()[0]["active"];
        poisoned["damage_counters"] = Value(5);
        poisoned["status_conditions"] = Value(Array{Value("POISONED")});
        RulesSession checkup(cards);
        require(checkup.restore(checkup_snapshot, 0x43484B50U, &restore_error),
            "checkup KO scenario restore failed");
        const auto checkup_step = checkup.apply_action(bind_action(
            checkup.legal_actions(0), "END_TURN", "cpp:checkup-ko"));
        if (!checkup_step.success) {
            std::cerr << "CHECKUP_TYPED_COMMIT_FAILED "
                << checkup_step.error_code << ' ' << checkup_step.message_key
                << '\n';
        }
        require(checkup_step.success && !checkup_step.terminal,
            "checkup KO did not suspend for its mandatory prize");
        require(checkup_step.state.find("phase")->string_or()
                == "POKEMON_CHECKUP",
            "checkup KO advanced the turn before settlement");
        require(checkup_step.state.find("players")->as_array()[0]
                .find("active")->is_null(),
            "lethally poisoned Active Pokémon remained in play");
        require(checkup_step.pending.find("request_type")->string_or()
                == "select_prize"
                && checkup_step.pending.find("player")->as_integer() == 1,
            "checkup KO did not give the opponent a prize choice");
        bool saw_checkup_damage = false;
        bool saw_checkup_ko = false;
        for (const Value &event : checkup_step.events) {
            const std::string type = event.find("event_type")->string_or();
            saw_checkup_damage = saw_checkup_damage || (
                type == "damage_counters_placed"
                && event.find("data")->find("target_player")->as_integer()
                    == 0
            );
            saw_checkup_ko = saw_checkup_ko || type == "pokemon_ko";
        }
        require(saw_checkup_damage && saw_checkup_ko,
            "checkup damage/KO presentation events were incomplete");
        const auto checkup_settled = checkup.apply_choice(choose(
            checkup_step.pending, "prize:0"));
        require(checkup_settled.success && checkup_settled.terminal
                && checkup_settled.winner == 1,
            "checkup KO did not evaluate victory after prize settlement");
        require(log_contains(checkup_settled.state, "昏厥了"),
            "checkup KO was absent from the action log");

        Value simultaneous_snapshot = completed.deep_clone();
        simultaneous_snapshot["active_player_idx"] = Value(0);
        simultaneous_snapshot["phase"] = Value("MAIN");
        simultaneous_snapshot["turn_number"] = Value(3);
        for (std::int32_t owner = 0; owner < 2; ++owner) {
            Value &owner_state = simultaneous_snapshot.find("players")
                ->as_array()[static_cast<std::size_t>(owner)];
            Value bench_pokemon = owner_state.find("active")->deep_clone();
            bench_pokemon["damage_counters"] = Value(0);
            bench_pokemon["status_conditions"] = Value::make_array();
            owner_state.find("bench")->as_array()[0] = std::move(bench_pokemon);
            (*owner_state.find("active"))["damage_counters"] = Value(5);
            (*owner_state.find("active"))["status_conditions"] = Value(
                Array{Value("POISONED")});
        }
        RulesSession simultaneous(cards);
        require(simultaneous.restore(
                simultaneous_snapshot, 0x53494D55U, &restore_error),
            "simultaneous checkup KO scenario restore failed");
        auto simultaneous_step = simultaneous.apply_action(bind_action(
            simultaneous.legal_actions(0),
            "END_TURN",
            "cpp:simultaneous-checkup"
        ));
        require(simultaneous_step.success
                && simultaneous_step.pending.find("player")->as_integer() == 0,
            "next-turn side's checkup KO was not settled first");
        simultaneous_step = simultaneous.apply_choice(choose(
            simultaneous_step.pending, "prize:0"));
        require(simultaneous_step.success
                && simultaneous_step.pending.find("player")->as_integer() == 1,
            "second simultaneous checkup prize choice was missing");
        simultaneous_step = simultaneous.apply_choice(choose(
            simultaneous_step.pending, "prize:0"));
        require(simultaneous_step.success && !simultaneous_step.terminal,
            "simultaneous checkup KO ended a match with available Bench Pokémon");
        const Array &promotions = simultaneous_step.state.find(
            "pending_promotions")->as_array();
        require(promotions.size() == 2
                && promotions[0].as_integer() == 1
                && promotions[1].as_integer() == 0,
            "simultaneous promotion order did not put next-turn player first");
        require(simultaneous.legal_actions(0).find("groups")->as_array().empty(),
            "outgoing player could promote before the next-turn player");
        require(simultaneous.apply_action(bind_action(
                simultaneous.legal_actions(1),
                "PROMOTE",
                "cpp:promote-next"
            )).success,
            "next-turn player promotion failed");
        const auto final_promotion = simultaneous.apply_action(bind_action(
            simultaneous.legal_actions(0),
            "PROMOTE",
            "cpp:promote-outgoing"
        ));
        require(final_promotion.success
                && final_promotion.state.find("active_player_idx")->as_integer()
                    == 1
                && final_promotion.state.find("phase")->string_or() == "MAIN",
            "checkup did not advance after both mandatory promotions");

        const auto conceded = session.concede(0);
        require(conceded.success && conceded.terminal && conceded.winner == 1,
            "surrender failed");
        const Value journal = session.journal();
        require(journal.find("schema")->string_or() == "ptcg_match_journal/1",
            "journal schema mismatch");
        require(journal.find("entries")->as_array().size() == 6,
            "journal entry count mismatch");
        require(log_contains(conceded.state, "放弃了对战"),
            "surrender was absent from the public action log");
        std::cout << "PTCG_CORE_TESTS_OK\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << "PTCG_CORE_TEST_FAILED: " << error.what() << '\n';
        return 1;
    }
}
