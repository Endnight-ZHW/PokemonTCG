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

GameExecutionResult NativeGameKernel::apply_action(
    Value state,
    const Value &action,
    std::uint32_t rng_state
) const {
    GameExecutionResult result;
    result.state = std::move(state);
    result.rng_state = rng_state;
    if (!action.is_object()) {
        result.error_code = "invalid_action";
        return result;
    }
    const std::string kind = string_arg(
        action,
        "action",
        string_arg(action, "kind")
    );
    const Value action_params = canonical_params(action, kind);
    const std::int32_t actor = static_cast<std::int32_t>(
        integer_arg(
            action,
            "actor",
            integer_arg(result.state, "active_player_idx", -1)
        )
    );
    if (actor < 0 || actor > 1) {
        result.error_code = "invalid_actor";
        return result;
    }

    try {
        Value &self = player(result.state, actor);
        Value &opponent = player(result.state, 1 - actor);
        increment(result.state, "revision");

        if (kind == "PLAY_BASIC") {
            Array &hand = required(self, "hand").as_array();
            const std::size_t hand_index = static_cast<std::size_t>(
                integer_arg(action_params, "hand_idx", -1)
            );
            if (hand_index >= hand.size()) {
                throw std::invalid_argument("invalid_hand_index");
            }
            const std::string id = hand[hand_index].string_or();
            hand.erase(
                hand.begin() + static_cast<std::ptrdiff_t>(hand_index)
            );
            const std::string target = string_arg(
                action_params,
                "target",
                "active"
            );
            if (target == "active") {
                self["active"] = make_pokemon(id, true);
            } else {
                if (target.rfind("bench_", 0) != 0) {
                    throw std::invalid_argument(
                        "basic_target_slot_invalid"
                    );
                }
                const std::size_t bench_index = static_cast<std::size_t>(
                    std::stoul(target.substr(6))
                );
                required(self, "bench").as_array().at(bench_index) =
                    make_pokemon(id, true);
            }
            result.event_types.emplace_back("pokemon_played");
        } else if (kind == "EVOLVE") {
            Array &hand = required(self, "hand").as_array();
            const std::size_t hand_index = static_cast<std::size_t>(
                integer_arg(action_params, "hand_idx", -1)
            );
            if (hand_index >= hand.size()) {
                throw std::invalid_argument("invalid_hand_index");
            }
            const std::string next_id = hand[hand_index].string_or();
            Value *target = pokemon(
                self,
                string_arg(action_params, "slot", "active")
            );
            if (target == nullptr) {
                throw std::invalid_argument("evolution_target_missing");
            }
            required(
                *target,
                "evolution_stack_ids"
            ).as_array().emplace_back(string_arg(*target, "card_id"));
            (*target)["card_id"] = Value(next_id);
            (*target)["can_evolve_this_turn"] = Value(false);
            (*target)["status_conditions"] = Value::make_array();
            (*target)["paralyzed_since_turn"] = Value(0);
            (*target)["used_abilities"] = Value::make_array();
            clear_attack_effects_on_leave(*target);
            hand.erase(
                hand.begin() + static_cast<std::ptrdiff_t>(hand_index)
            );
            result.event_types.emplace_back("pokemon_evolved");
            settle_ability_effect_knockouts(result, cards_, actor);
        } else if (kind == "ATTACH_ENERGY") {
            Array &hand = required(self, "hand").as_array();
            const std::size_t hand_index = static_cast<std::size_t>(
                integer_arg(action_params, "hand_idx", -1)
            );
            const std::string target_slot = string_arg(
                action_params,
                "target_slot",
                "active"
            );
            Value *target = pokemon(
                self,
                target_slot
            );
            if (hand_index >= hand.size() || target == nullptr) {
                throw std::invalid_argument("energy_attachment_invalid");
            }
            const std::string energy_id = hand[hand_index].string_or();
            required(
                *target,
                "energy_card_ids"
            ).as_array().push_back(std::move(hand[hand_index]));
            hand.erase(
                hand.begin() + static_cast<std::ptrdiff_t>(hand_index)
            );
            self["energy_attached_this_turn"] = Value(true);
            result.event_types.emplace_back("energy_attached");
            if (energy_switches_with_active_on_attach(
                cards_,
                energy_id,
                target_slot
            )) {
                switch_active_with_event(
                    result,
                    self,
                    actor,
                    actor,
                    target_slot,
                    "switched",
                    "energy_switch_on_attach"
                );
            }
        } else if (kind == "RETREAT") {
            Value *active = pokemon(self, "active");
            if (active == nullptr) {
                throw std::invalid_argument("retreat_active_missing");
            }
            const std::int64_t retreat_cost = effective_retreat_cost(
                cards_,
                result.state,
                *active,
                card_definition(cards_, string_arg(*active, "card_id"))
            );
            const std::size_t bench_index = static_cast<std::size_t>(
                integer_arg(action_params, "bench_idx", -1)
            );
            Array &bench = required(self, "bench").as_array();
            if (
                bench_index >= bench.size()
                || !bench[bench_index].is_object()
            ) {
                throw std::invalid_argument("retreat_target_missing");
            }
            if (retreat_cost <= 0) {
                switch_active_with_event(
                    result,
                    self,
                    actor,
                    actor,
                    "bench_" + std::to_string(bench_index),
                    "retreat",
                    "retreat"
                );
                self["retreated_this_turn"] = Value(true);
                result.success = true;
                return result;
            }
            const Array &energy = required(
                *active,
                "energy_card_ids"
            ).as_array();
            if (
                energy_units(cards_, *active).size()
                < static_cast<std::size_t>(retreat_cost)
            ) {
                throw std::invalid_argument("retreat_energy_missing");
            }
            Array options;
            Array attachment_refs;
            for (std::size_t index = 0; index < energy.size(); ++index) {
                Value option(Object{
                    {"kind", Value("attachment")},
                    {"player", Value(actor)},
                    {"card_id", Value(energy[index].string_or())},
                    {"slot", Value("active")},
                    {"attachment_type", Value("energy")},
                    {"index", Value(static_cast<std::int64_t>(index))},
                });
                attachment_refs.emplace_back(Object{
                    {
                        "option_id",
                        Value(stable_choice_option_id(
                            option, "select_retreat_payment"
                        )),
                    },
                    {
                        "units",
                        Value(energy_card_unit_count(
                            cards_, energy[index].string_or()
                        )),
                    },
                });
                options.push_back(std::move(option));
            }
            increment(result.state, "choice_sequence");
            result.pending = action_pending(
                "select_retreat_payment",
                actor,
                1,
                static_cast<std::int64_t>(energy.size()),
                true,
                std::move(options),
                "retreat_payment",
                false
            );
            // ChoiceView v2 exposes the amount the chooser must cover.  This
            // is presentation-safe public information and is required by AI
            // and UI payment selectors; the authoritative continuation still
            // owns the value used for settlement.
            result.pending["metadata"]["required_units"] = Value(
                retreat_cost);
            result.pending["metadata"]["attachment_refs"] = Value(
                std::move(attachment_refs));
            result.continuation = Value(Object{
                {"kind", Value("retreat_payment")},
                {"actor", Value(actor)},
                {
                    "bench_idx",
                    Value(integer_arg(action_params, "bench_idx", -1)),
                },
                {"required_units", Value(retreat_cost)},
            });
        } else if (kind == "PROMOTE") {
            const std::size_t bench_index = static_cast<std::size_t>(
                integer_arg(action_params, "bench_idx", -1)
            );
            Array &bench = required(self, "bench").as_array();
            if (
                bench_index >= bench.size()
                || !bench[bench_index].is_object()
            ) {
                throw std::invalid_argument("promotion_target_missing");
            }
            self["active"] = std::move(bench[bench_index]);
            bench[bench_index] = Value();
            Array &pending = required(
                result.state,
                "pending_promotions"
            ).as_array();
            pending.erase(
                std::remove_if(
                    pending.begin(),
                    pending.end(),
                    [actor](const Value &entry) {
                        return entry.as_integer(-1) == actor;
                    }
                ),
                pending.end()
            );
            append_slot_transition_event(
                result,
                "promoted",
                actor,
                actor,
                "bench_" + std::to_string(bench_index),
                "",
                string_arg(required(self, "active"), "card_id"),
                "promotion"
            );
            if (
                string_arg(result.state, "phase") == "ATTACK"
                && pending.empty()
            ) {
                finish_turn(
                    result,
                    cards_,
                    static_cast<std::int32_t>(
                        integer_arg(result.state, "active_player_idx")
                    )
                );
            } else if (
                string_arg(result.state, "phase")
                    == "POKEMON_CHECKUP"
                && pending.empty()
            ) {
                complete_checkup_transition(
                    result.state,
                    static_cast<std::int32_t>(
                        integer_arg(
                            result.state,
                            "active_player_idx"
                        )
                    ),
                    result.event_types
                );
            }
        } else if (kind == "END_TURN") {
            finish_turn(result, cards_, actor);
        } else if (kind == "USE_STADIUM") {
            const std::string id = string_arg(
                result.state,
                "stadium_card_id"
            );
            const Value *definition = card_definition(cards_, id);
            if (definition == nullptr) {
                throw std::invalid_argument("stadium_missing");
            }
            const Value *effects = definition->find(
                "compiled_trainer_effects"
            );
            if (effects != nullptr && effects->is_array()) {
                for (const Value &effect : effects->as_array()) {
                    VmExecutionResult vm = rules_.execute(
                        std::move(result.state),
                        effect,
                        actor,
                        "active",
                        result.rng_state,
                        "trainer"
                    );
                    if (!vm.success) {
                        throw std::invalid_argument(vm.error_code);
                    }
                    result.state = std::move(vm.state);
                    result.rng_state = vm.rng_state;
                    result.event_types.insert(
                        result.event_types.end(),
                        vm.event_types.begin(),
                        vm.event_types.end()
                    );
                    append_events(result.events, vm.events);
                }
            }
            player(result.state, actor)["stadium_used_this_turn"] =
                Value(true);
            if (result.pending.as_object().empty()) {
                settle_ability_effect_knockouts(result, cards_, actor);
                if (result.pending.as_object().empty()) {
                    finalize_terminal_if_needed(result);
                }
            }
        } else if (kind == "PLAY_TRAINER") {
            Array &hand = required(self, "hand").as_array();
            const std::size_t hand_index = static_cast<std::size_t>(
                integer_arg(action_params, "hand_idx", -1)
            );
            if (hand_index >= hand.size()) {
                throw std::invalid_argument("invalid_hand_index");
            }
            const std::string id = hand[hand_index].string_or();
            const Value *definition = card_definition(cards_, id);
            if (definition == nullptr) {
                throw std::invalid_argument("trainer_definition_missing");
            }
            const std::string trainer_type = string_arg(
                *definition,
                "trainer_type"
            );
            hand.erase(
                hand.begin() + static_cast<std::ptrdiff_t>(hand_index)
            );
            if (trainer_type == "Tool") {
                const std::string target_slot = string_arg(
                    action_params,
                    "target_slot",
                    "active"
                );
                Value *target = pokemon(
                    self,
                    target_slot
                );
                if (target == nullptr) {
                    throw std::invalid_argument("tool_target_missing");
                }
                (*target)["attached_tool_id"] = Value(id);
                append_tool_modifiers(
                    *target,
                    *definition,
                    actor,
                    target_slot
                );
                result.event_types.emplace_back("tool_attached");
            } else {
                result.event_types.emplace_back("trainer_played");
                const Value *effects = definition->find(
                    "compiled_trainer_effects"
                );
                if (effects != nullptr && effects->is_array()) {
                    Array rows = effects->as_array();
                    if (
                        rows.size() == 1
                        && string_arg(rows.front(), "op") == "conditional"
                    ) {
                        const Value *branches = rows.front().find("branches");
                        const Value *cost = (
                            branches != nullptr && branches->is_object()
                        ) ? branches->find("cost") : nullptr;
                        const Value *on_pay = (
                            branches != nullptr && branches->is_object()
                        ) ? branches->find("on_pay") : nullptr;
                        const bool has_cost = cost != nullptr
                            && cost->is_array()
                            && !cost->as_array().empty();
                        if (
                            !has_cost
                            && on_pay != nullptr
                            && on_pay->is_array()
                        ) {
                            const Value *conditional_args =
                                rows.front().find("args");
                            const std::string condition = (
                                conditional_args != nullptr
                                && conditional_args->is_object()
                            ) ? string_arg(
                                *conditional_args,
                                "condition"
                            ) : std::string{};
                            if (
                                condition == "ko_last_opponent_turn"
                                && !previous_turn_had_knockout(
                                    result.state,
                                    actor
                                )
                            ) {
                                throw std::invalid_argument(
                                    "conditional_condition_not_met"
                                );
                            }
                            rows = on_pay->as_array();
                        }
                    }
                    for (
                        std::size_t effect_index = 0;
                        effect_index < rows.size();
                        ++effect_index
                    ) {
                        const Value &effect = rows[effect_index];
                        VmExecutionResult vm = rules_.execute(
                            std::move(result.state),
                            effect,
                            actor,
                            "active",
                            result.rng_state,
                            "trainer"
                        );
                        if (!vm.success) {
                            throw std::invalid_argument(vm.error_code);
                        }
                        result.state = std::move(vm.state);
                        result.rng_state = vm.rng_state;
                        result.event_types.insert(
                            result.event_types.end(),
                            vm.event_types.begin(),
                            vm.event_types.end()
                        );
                        append_events(result.events, vm.events);
                        if (!vm.pending.as_object().empty()) {
                            attach_game_continuation(
                                result,
                                vm,
                                actor,
                                false,
                                remaining_effects(
                                    rows,
                                    effect_index + 1
                                ),
                                "active",
                                "trainer"
                            );
                            break;
                        }
                    }
                }
                Value &current_self = player(result.state, actor);
                if (trainer_type == "Supporter") {
                    current_self["supporter_played_this_turn"] = Value(true);
                }
                if (
                    trainer_type == "Supporter"
                    || trainer_type == "Item"
                ) {
                    required(
                        current_self,
                        "discard"
                    ).as_array().emplace_back(id);
                }
            }
            if (result.pending.as_object().empty()) {
                settle_ability_effect_knockouts(result, cards_, actor);
                if (result.pending.as_object().empty()) {
                    finalize_terminal_if_needed(result);
                }
            }
        } else if (kind == "USE_ABILITY") {
            std::string slot = string_arg(
                action_params,
                "slot",
                "active"
            );
            const bool discard_source = slot == "discard"
                || slot.rfind("discard_", 0) == 0;
            std::string source_card_id;
            std::string effect_source_slot = slot;
            Value *source = nullptr;
            if (discard_source) {
                std::int64_t discard_index = integer_arg(
                    action_params,
                    "discard_idx",
                    -1
                );
                if (discard_index < 0 && slot.rfind("discard_", 0) == 0) {
                    discard_index = std::stoll(slot.substr(8));
                }
                const Array &discard = required(self, "discard").as_array();
                if (
                    discard_index < 0
                    || static_cast<std::size_t>(discard_index)
                        >= discard.size()
                ) {
                    throw std::invalid_argument("ability_source_missing");
                }
                source_card_id = discard[
                    static_cast<std::size_t>(discard_index)
                ].string_or();
                const std::string requested_id = string_arg(
                    action_params,
                    "card_id"
                );
                if (
                    !requested_id.empty()
                    && requested_id != source_card_id
                ) {
                    throw std::invalid_argument(
                        "ability_source_identity_mismatch"
                    );
                }
                const Array &bench = required(self, "bench").as_array();
                const auto empty = std::find_if(
                    bench.begin(),
                    bench.end(),
                    [](const Value &entry) { return entry.is_null(); }
                );
                if (empty == bench.end()) {
                    throw std::invalid_argument(
                        "ability_revive_target_missing"
                    );
                }
                effect_source_slot = "bench_"
                    + std::to_string(std::distance(bench.begin(), empty));
            } else {
                source = pokemon(self, slot);
                if (source == nullptr) {
                    throw std::invalid_argument("ability_source_missing");
                }
                source_card_id = string_arg(*source, "card_id");
            }
            const Value *definition = card_definition(
                cards_,
                source_card_id
            );
            const std::string ability_name = string_arg(
                action_params,
                "ability_name"
            );
            const Value *ability = definition == nullptr
                ? nullptr
                : find_named_ability(*definition, ability_name);
            if (ability == nullptr) {
                throw std::invalid_argument("ability_missing");
            }
            const Value *effects = ability->find("compiled_effects");
            if (effects != nullptr && effects->is_array()) {
                const Array &rows = effects->as_array();
                for (
                    std::size_t effect_index = 0;
                    effect_index < rows.size();
                    ++effect_index
                ) {
                    const Value &effect = rows[effect_index];
                    VmExecutionResult vm = rules_.execute(
                        std::move(result.state),
                        effect,
                        actor,
                        effect_source_slot,
                        result.rng_state,
                        "ability"
                    );
                    if (!vm.success) {
                        throw std::invalid_argument(vm.error_code);
                    }
                    result.state = std::move(vm.state);
                    result.rng_state = vm.rng_state;
                    result.event_types.insert(
                        result.event_types.end(),
                        vm.event_types.begin(),
                        vm.event_types.end()
                    );
                    append_events(result.events, vm.events);
                    if (!vm.pending.as_object().empty()) {
                        attach_game_continuation(
                            result,
                            vm,
                            actor,
                            false,
                            remaining_effects(
                                rows,
                                effect_index + 1
                            ),
                            effect_source_slot,
                            "ability"
                        );
                        break;
                    }
                }
            }
            source = pokemon(
                player(result.state, actor),
                effect_source_slot
            );
            if (
                source != nullptr
                && string_arg(*ability, "trigger") != "repeatable"
                && !array_contains_string(
                    source->find("used_abilities"),
                    ability_name
                )
            ) {
                required(
                    *source,
                    "used_abilities"
                ).as_array().emplace_back(ability_name);
            }
            if (result.pending.as_object().empty()) {
                settle_ability_effect_knockouts(
                    result,
                    cards_,
                    actor
                );
                if (result.pending.as_object().empty()) {
                    finalize_terminal_if_needed(result);
                }
            }
        } else if (kind == "DECLARE_ATTACK") {
            result.state["phase"] = Value("ATTACK");
            result.event_types.emplace_back("attack_declared");
            Value *attacker = pokemon(self, "active");
            Value *defender = pokemon(opponent, "active");
            if (attacker == nullptr || defender == nullptr) {
                throw std::invalid_argument("attack_board_invalid");
            }
            const Value *definition = card_definition(
                cards_,
                string_arg(*attacker, "card_id")
            );
            const Value *attacks = definition == nullptr
                ? nullptr
                : definition->find("attacks");
            const std::size_t attack_index = static_cast<std::size_t>(
                integer_arg(action_params, "attack_idx")
            );
            if (
                attacks == nullptr
                || !attacks->is_array()
                || attack_index >= attacks->as_array().size()
            ) {
                throw std::invalid_argument("attack_missing");
            }
            const Value &attack = attacks->as_array()[attack_index];
            append_event(
                result,
                "attack_declared",
                Object{
                    {"player", Value(actor)},
                    {
                        "card_id",
                        Value(string_arg(*attacker, "card_id")),
                    },
                    {
                        "attack_idx",
                        Value(static_cast<std::int64_t>(attack_index)),
                    },
                    {
                        "attack_name",
                        Value(string_arg(attack, "name")),
                    },
                }
            );
            if (
                array_contains_string(
                    attacker->find("status_conditions"),
                    "CONFUSED"
                )
            ) {
                XorShift32 rng(result.rng_state);
                const bool heads = (rng.next_u32() & 1U) == 0;
                result.rng_state = rng.state();
                result.event_types.emplace_back("coin_flip");
                append_event(
                    result,
                    "coin_flip",
                    Object{
                        {"player", Value(actor)},
                        {"results", Value(Array{Value(heads)})},
                        {"purpose", Value("confusion")},
                    }
                );
                if (!heads) {
                    add_damage(*attacker, 30);
                    result.event_types.emplace_back("confusion_failed");
                    append_event(
                        result,
                        "confusion_failed",
                        Object{
                            {"actor", Value(actor)},
                            {"player", Value(actor)},
                            {"target_player", Value(actor)},
                            {"target_slot", Value("active")},
                            {"slot", Value("active")},
                            {"amount", Value(30)},
                            {"self_damage", Value(30)},
                            {"counter_count", Value(3)},
                            {"damage_kind", Value("damage_counters")},
                            {"source_kind", Value("confusion")},
                            {"visibility", Value("public")},
                        }
                    );
                    Value failed_context(Object{
                        {"attack_failed", Value(true)},
                        {"damage_applied", Value(true)},
                        {"after_damage_triggers_applied", Value(true)},
                        {"final_damage", Value(0)},
                    });
                    if (
                        pokemon_hp(cards_, *attacker) > 0
                        && integer_arg(*attacker, "damage_counters") * 10
                            >= pokemon_hp(cards_, *attacker)
                    ) {
                        (*attacker)["pending_ko_source_kind"] = Value(
                            "damage_counters");
                    }
                    finish_attack_resolution(
                        result, cards_, actor, failed_context);
                    result.success = true;
                    return result;
                }
            }
            bool dazzled = false;
            Value *modifiers = attacker->find("modifiers");
            if (modifiers != nullptr && modifiers->is_array()) {
                const auto gate = std::find_if(
                    modifiers->as_array().begin(),
                    modifiers->as_array().end(),
                    [](const Value &descriptor) {
                        const Value *operation = descriptor.find(
                            "operation"
                        );
                        return operation != nullptr
                            && operation->is_object()
                            && string_arg(*operation, "kind")
                                == "attack_gate_coin"
                            && string_arg(*operation, "reason")
                                == "dazzled";
                    }
                );
                if (gate != modifiers->as_array().end()) {
                    modifiers->as_array().erase(gate);
                    dazzled = true;
                }
            }
            if (dazzled) {
                XorShift32 rng(result.rng_state);
                const bool heads = (rng.next_u32() & 1U) == 0;
                result.rng_state = rng.state();
                result.event_types.emplace_back("coin_flip");
                append_event(
                    result,
                    "coin_flip",
                    Object{
                        {"player", Value(actor)},
                        {"results", Value(Array{Value(heads)})},
                        {"purpose", Value("dazzled")},
                    }
                );
                if (!heads) {
                    result.event_types.emplace_back("dazzled_failed");
                    append_event(
                        result,
                        "dazzled_failed",
                        Object{
                            {"player", Value(actor)},
                            {"slot", Value("active")},
                        }
                    );
                    finish_turn(result, cards_, actor);
                    result.success = true;
                    return result;
                }
            }
            const Value *effects = attack.find("compiled_effects");
            bool replace_damage = false;
            if (effects != nullptr && effects->is_array()) {
                for (const Value &effect : effects->as_array()) {
                    replace_damage = replace_damage
                        || replaces_attack_damage(
                            string_arg(effect, "op")
                        );
                }
            }
            Value context = Value(Object{
                {
                    "base_damage",
                    Value(
                        replace_damage
                        ? 0
                        : integer_arg(attack, "damage")
                    ),
                },
                {"defer_coin_post_damage", Value(true)},
            });
            std::vector<std::string> effect_events;
            std::vector<Value> effect_payloads;
            if (effects != nullptr && effects->is_array()) {
                const Array &rows = effects->as_array();
                for (
                    std::size_t effect_index = 0;
                    effect_index < rows.size();
                    ++effect_index
                ) {
                    const Value &effect = rows[effect_index];
                    const std::string op = string_arg(effect, "op");
                    const Value *args_ptr = effect.find("args");
                    const Value empty_args = Value::make_object();
                    const Value &effect_args = (
                        args_ptr != nullptr && args_ptr->is_object()
                    ) ? *args_ptr : empty_args;
                    if (
                        op == "deal_damage_then_heal"
                        && !bool_arg(context, "damage_applied")
                    ) {
                        context["base_damage"] = Value(integer_arg(
                            effect_args,
                            "damage"
                        ));
                        apply_attack_damage_before_effect(
                            result,
                            cards_,
                            actor,
                            context
                        );
                    } else if (
                        !attack_effect_runs_before_damage(op, effect_args)
                        && !bool_arg(context, "damage_applied")
                    ) {
                        apply_attack_damage_before_effect(
                            result,
                            cards_,
                            actor,
                            context
                        );
                    }
                    VmExecutionResult vm = rules_.execute(
                        std::move(result.state),
                        effect,
                        actor,
                        "active",
                        result.rng_state,
                        "attack",
                        context
                    );
                    if (!vm.success) {
                        throw std::invalid_argument(vm.error_code);
                    }
                    result.state = std::move(vm.state);
                    result.rng_state = vm.rng_state;
                    context = std::move(vm.context);
                    effect_events.insert(
                        effect_events.end(),
                        vm.event_types.begin(),
                        vm.event_types.end()
                    );
                    append_events(effect_payloads, vm.events);
                    if (!vm.pending.as_object().empty()) {
                        vm.context = context;
                        result.event_types.insert(
                            result.event_types.end(),
                            effect_events.begin(),
                            effect_events.end()
                        );
                        append_events(result.events, effect_payloads);
                        attach_game_continuation(
                            result,
                            vm,
                            actor,
                            true,
                            remaining_effects(
                                rows,
                                effect_index + 1
                            ),
                            "active",
                            "attack"
                        );
                        result.success = true;
                        return result;
                    }
                    if (
                        op == "prevent_all"
                        || op == "prevent_damage"
                        || op == "prevent_effects"
                        || (
                            op == "apply_self_attack_lock"
                            && string_arg(effect_args, "scope") != "player"
                        )
                    ) {
                        Value *current_source = pokemon(
                            player(result.state, actor),
                            "active"
                        );
                        if (current_source == nullptr) {
                            continue;
                        }
                        append_canonical_modifier(
                            *current_source,
                            *current_source,
                            op,
                            required(effect, "args"),
                            actor,
                            "active",
                            actor,
                            integer_arg(result.state, "turn_number")
                        );
                    } else if (
                        op == "apply_attack_lock_basic"
                        || op == "apply_dazzling_beam"
                        || op == "apply_outgoing_damage_reduction"
                    ) {
                        Value *current_source = pokemon(
                            player(result.state, actor),
                            "active"
                        );
                        Value *target = pokemon(
                            player(result.state, 1 - actor),
                            "active"
                        );
                        if (current_source == nullptr || target == nullptr) {
                            continue;
                        }
                        const Value *target_card = card_definition(
                            cards_,
                            string_arg(*target, "card_id")
                        );
                        const bool should_register = (
                            !bool_arg(*target, "all_prevented")
                            && (
                                op != "apply_attack_lock_basic"
                                || (
                                    target_card != nullptr
                                    && is_basic_pokemon(*target_card)
                                )
                            )
                        );
                        append_canonical_modifier(
                            *target,
                            *current_source,
                            should_register ? op : std::string{},
                            required(effect, "args"),
                            actor,
                            "active",
                            1 - actor,
                            integer_arg(result.state, "turn_number")
                        );
                    }
                }
            }
            result.event_types.insert(
                result.event_types.end(),
                effect_events.begin(),
                effect_events.end()
            );
            append_events(result.events, effect_payloads);
            finish_attack_resolution(result, cards_, actor, context);
        } else {
            throw std::invalid_argument("unsupported_native_action:" + kind);
        }
        result.success = true;
    } catch (const std::exception &error) {
        result.success = false;
        result.error_code = error.what();
    }
    return result;
}


} // namespace ptcg::ai
