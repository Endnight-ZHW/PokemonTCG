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

GameExecutionResult NativeGameKernel::resume_choice(
    Value state,
    const Value &continuation,
    const Value &selected_options,
    bool cancelled,
    std::uint32_t rng_state
) const {
    GameExecutionResult result;
    result.state = std::move(state);
    result.rng_state = rng_state;
    if (!continuation.is_object()) {
        result.error_code = "invalid_game_continuation";
        return result;
    }
    try {
        const std::string kind = string_arg(continuation, "kind");
        const std::int32_t actor = static_cast<std::int32_t>(
            integer_arg(continuation, "actor", -1)
        );
        if (kind == "vm") {
            const Value *cancel_rollback = continuation.find(
                "cancel_rollback"
            );
            if (cancelled && cancel_rollback != nullptr) {
                if (
                    actor != 0
                    && actor != 1
                ) {
                    throw std::invalid_argument(
                        "cancel_rollback_actor_invalid"
                    );
                }
                if (
                    !cancel_rollback->is_object()
                    || cancel_rollback->as_object().size() != 6
                    || cancel_rollback->find("hand_before") == nullptr
                    || cancel_rollback->find("discard_before") == nullptr
                    || cancel_rollback->find("deck_top_before") == nullptr
                    || cancel_rollback->find(
                        "expected_current_deck_count"
                    ) == nullptr
                    || cancel_rollback->find(
                        "supporter_played_before"
                    ) == nullptr
                    || cancel_rollback->find(
                        "choice_sequence_before"
                    ) == nullptr
                ) {
                    throw std::invalid_argument(
                        "cancel_rollback_shape_invalid"
                    );
                }
                const Value &hand_before = required(
                    *cancel_rollback,
                    "hand_before"
                );
                const Value &discard_before = required(
                    *cancel_rollback,
                    "discard_before"
                );
                const Value &deck_top_before = required(
                    *cancel_rollback,
                    "deck_top_before"
                );
                if (
                    !hand_before.is_array()
                    || !discard_before.is_array()
                    || !deck_top_before.is_array()
                    || deck_top_before.as_array().size() > 2
                ) {
                    throw std::invalid_argument(
                        "cancel_rollback_zone_invalid"
                    );
                }
                auto card_ids = [this](
                    const Value &zone,
                    const char *error
                ) {
                    std::vector<std::string> ids;
                    ids.reserve(zone.as_array().size());
                    for (const Value &entry : zone.as_array()) {
                        const std::string card_id = entry.string_or();
                        if (
                            card_id.empty()
                            || card_definition(cards_, card_id) == nullptr
                        ) {
                            throw std::invalid_argument(error);
                        }
                        ids.push_back(card_id);
                    }
                    return ids;
                };
                const std::vector<std::string> expected_hand = card_ids(
                    hand_before,
                    "cancel_rollback_hand_invalid"
                );
                const std::vector<std::string> expected_discard = card_ids(
                    discard_before,
                    "cancel_rollback_discard_invalid"
                );
                const std::vector<std::string> expected_top = card_ids(
                    deck_top_before,
                    "cancel_rollback_deck_top_invalid"
                );
                Value &owner = player(result.state, actor);
                Array &current_hand = required(
                    owner,
                    "hand"
                ).as_array();
                Array &current_discard = required(
                    owner,
                    "discard"
                ).as_array();
                Array &current_deck = required(
                    owner,
                    "deck"
                ).as_array();
                const std::int64_t expected_deck_count = integer_arg(
                    *cancel_rollback,
                    "expected_current_deck_count",
                    -1
                );
                const std::int64_t sequence_before = integer_arg(
                    *cancel_rollback,
                    "choice_sequence_before",
                    -1
                );
                if (
                    expected_deck_count < 0
                    || static_cast<std::size_t>(expected_deck_count)
                        != current_deck.size()
                    || sequence_before < 0
                    || integer_arg(
                        result.state,
                        "choice_sequence",
                        -1
                    ) != sequence_before + 1
                    || bool_arg(
                        owner,
                        "supporter_played_this_turn"
                    ) == bool_arg(
                        *cancel_rollback,
                        "supporter_played_before"
                    )
                ) {
                    throw std::invalid_argument(
                        "cancel_rollback_precondition_failed"
                    );
                }
                std::vector<std::string> current_visible;
                current_visible.reserve(
                    current_hand.size() + current_discard.size()
                );
                for (const Value &entry : current_hand) {
                    const std::string card_id = entry.string_or();
                    if (
                        card_id.empty()
                        || card_definition(cards_, card_id) == nullptr
                    ) {
                        throw std::invalid_argument(
                            "cancel_rollback_current_hand_invalid"
                        );
                    }
                    current_visible.push_back(card_id);
                }
                for (const Value &entry : current_discard) {
                    const std::string card_id = entry.string_or();
                    if (
                        card_id.empty()
                        || card_definition(cards_, card_id) == nullptr
                    ) {
                        throw std::invalid_argument(
                            "cancel_rollback_current_discard_invalid"
                        );
                    }
                    current_visible.push_back(card_id);
                }
                std::vector<std::string> expected_visible(
                    expected_hand.begin(),
                    expected_hand.end()
                );
                expected_visible.insert(
                    expected_visible.end(),
                    expected_discard.begin(),
                    expected_discard.end()
                );
                expected_visible.insert(
                    expected_visible.end(),
                    expected_top.begin(),
                    expected_top.end()
                );
                std::sort(
                    current_visible.begin(),
                    current_visible.end()
                );
                std::sort(
                    expected_visible.begin(),
                    expected_visible.end()
                );
                if (current_visible != expected_visible) {
                    throw std::invalid_argument(
                        "cancel_rollback_card_conservation_failed"
                    );
                }
                current_hand = hand_before.as_array();
                current_discard = discard_before.as_array();
                for (const Value &entry : deck_top_before.as_array()) {
                    current_deck.push_back(entry);
                }
                owner["supporter_played_this_turn"] = Value(
                    bool_arg(
                        *cancel_rollback,
                        "supporter_played_before"
                    )
                );
                result.state["choice_sequence"] = Value(sequence_before);
                increment(result.state, "revision");
                result.success = true;
                return result;
            }
            VmExecutionResult vm = rules_.resume(
                std::move(result.state),
                required(continuation, "context"),
                required(continuation, "vm"),
                selected_options,
                cancelled,
                result.rng_state
            );
            if (!vm.success) {
                throw std::invalid_argument(vm.error_code);
            }
            result.state = std::move(vm.state);
            result.rng_state = vm.rng_state;
            result.event_types = std::move(vm.event_types);
            result.events = std::move(vm.events);
            canonicalize_vm_modifiers(
                result.state,
                actor,
                string_arg(
                    continuation,
                    "source_slot",
                    "active"
                )
            );
            Value continued_context = vm.context;
            if (!vm.pending.as_object().empty()) {
                const bool direct_knockout_prize =
                    string_arg(vm.pending, "request_type") == "select_prize"
                    && string_arg(vm.continuation, "op")
                        == "flip_coin_then_ko"
                    && integer_arg(vm.continuation, "stage") == 1;
                if (direct_knockout_prize) {
                    const Value *remaining = continuation.find(
                        "remaining_effects");
                    if (
                        remaining != nullptr
                        && remaining->is_array()
                        && !remaining->as_array().empty()
                    ) {
                        throw std::invalid_argument(
                            "direct_knockout_must_be_final_effect");
                    }
                    const std::size_t available = required(
                        player(result.state, actor), "prizes").as_array().size();
                    const std::size_t requested = static_cast<std::size_t>(
                        std::max<std::int64_t>(
                            1,
                            integer_arg(
                                vm.continuation,
                                "remaining_prizes",
                                0
                            ) + 1
                        )
                    );
                    const std::size_t prize_count = std::min(
                        available, requested);
                    if (prize_count > 0) {
                        suspend_prize_queue(
                            result,
                            std::vector<std::int32_t>(prize_count, actor),
                            actor,
                            continued_context
                        );
                        result.continuation[
                            "finish_attack_after_prizes"
                        ] = Value(true);
                    } else {
                        finish_attack_resolution(
                            result, cards_, actor, continued_context);
                    }
                } else {
                    attach_game_continuation(
                        result,
                        vm,
                        actor,
                        bool_arg(continuation, "finish_attack"),
                        continuation.find("remaining_effects") != nullptr
                            ? *continuation.find("remaining_effects")
                            : Value::make_array(),
                        string_arg(
                            continuation,
                            "source_slot",
                            "active"
                        ),
                        string_arg(continuation, "context_mode")
                    );
                }
                const Value *post_vm_trigger_groups = continuation.find(
                    "post_vm_trigger_groups"
                );
                if (post_vm_trigger_groups != nullptr) {
                    result.continuation["post_vm_trigger_groups"] =
                        *post_vm_trigger_groups;
                }
            } else {
                const Value *remaining = continuation.find(
                    "remaining_effects"
                );
                if (remaining != nullptr && remaining->is_array()) {
                    const Array &rows = remaining->as_array();
                    for (
                        std::size_t effect_index = 0;
                        effect_index < rows.size();
                        ++effect_index
                    ) {
                        VmExecutionResult following = rules_.execute(
                            std::move(result.state),
                            rows[effect_index],
                            actor,
                            string_arg(
                                continuation,
                                "source_slot",
                                "active"
                            ),
                            result.rng_state,
                            string_arg(continuation, "context_mode"),
                            continued_context
                        );
                        if (!following.success) {
                            throw std::invalid_argument(
                                following.error_code
                            );
                        }
                        result.state = std::move(following.state);
                        result.rng_state = following.rng_state;
                        continued_context = following.context;
                        canonicalize_vm_modifiers(
                            result.state,
                            actor,
                            string_arg(
                                continuation,
                                "source_slot",
                                "active"
                            )
                        );
                        result.event_types.insert(
                            result.event_types.end(),
                            following.event_types.begin(),
                            following.event_types.end()
                        );
                        append_events(result.events, following.events);
                        if (!following.pending.as_object().empty()) {
                            attach_game_continuation(
                                result,
                                following,
                                actor,
                                bool_arg(
                                    continuation,
                                    "finish_attack"
                                ),
                                remaining_effects(
                                    rows,
                                    effect_index + 1
                                ),
                                string_arg(
                                    continuation,
                                    "source_slot",
                                    "active"
                                ),
                                string_arg(
                                    continuation,
                                    "context_mode"
                                )
                            );
                            const Value *post_vm_trigger_groups =
                                continuation.find(
                                    "post_vm_trigger_groups"
                                );
                            if (post_vm_trigger_groups != nullptr) {
                                result.continuation[
                                    "post_vm_trigger_groups"
                                ] = *post_vm_trigger_groups;
                            }
                            break;
                        }
                    }
                }
                if (
                    result.pending.as_object().empty()
                    && bool_arg(continuation, "finish_attack")
                ) {
                    const Value *deferred_value = continued_context.find(
                        "deferred_attack_effects"
                    );
                    if (
                        deferred_value != nullptr
                        && deferred_value->is_array()
                        && !deferred_value->as_array().empty()
                    ) {
                        if (
                            !bool_arg(continued_context, "attack_failed")
                            && !bool_arg(continued_context, "damage_applied")
                        ) {
                            apply_attack_damage_before_effect(
                                result,
                                cards_,
                                actor,
                                continued_context
                            );
                        }
                        const Array deferred = deferred_value->as_array();
                        continued_context.erase("deferred_attack_effects");
                        for (const Value &effect : deferred) {
                            VmExecutionResult following = rules_.execute(
                                std::move(result.state),
                                effect,
                                actor,
                                string_arg(
                                    continuation,
                                    "source_slot",
                                    "active"
                                ),
                                result.rng_state,
                                "attack",
                                continued_context
                            );
                            if (!following.success) {
                                throw std::invalid_argument(
                                    following.error_code
                                );
                            }
                            if (!following.pending.as_object().empty()) {
                                throw std::invalid_argument(
                                    "deferred_attack_effect_suspended"
                                );
                            }
                            result.state = std::move(following.state);
                            result.rng_state = following.rng_state;
                            continued_context = std::move(
                                following.context
                            );
                            canonicalize_vm_modifiers(
                                result.state,
                                actor,
                                string_arg(
                                    continuation,
                                    "source_slot",
                                    "active"
                                )
                            );
                            result.event_types.insert(
                                result.event_types.end(),
                                following.event_types.begin(),
                                following.event_types.end()
                            );
                            append_events(result.events, following.events);
                        }
                    }
                    const Value *post_vm_trigger_groups = continuation.find(
                        "post_vm_trigger_groups"
                    );
                    if (post_vm_trigger_groups != nullptr) {
                        if (!post_vm_trigger_groups->is_array()) {
                            throw std::invalid_argument(
                                "post_vm_trigger_queue_invalid"
                            );
                        }
                        if (consume_public_trigger_groups(
                            result,
                            cards_,
                            actor,
                            post_vm_trigger_groups->as_array(),
                            continued_context,
                            "post_vm_trigger_queue_invalid"
                        )) {
                            result.success = true;
                            return result;
                        }
                    }
                    finish_attack_resolution(
                        result,
                        cards_,
                        actor,
                        continued_context
                    );
                }
            }
            if (
                result.pending.as_object().empty()
                && !bool_arg(continuation, "finish_attack")
            ) {
                if (
                    string_arg(continuation, "context_mode") == "ability"
                    || string_arg(continuation, "context_mode") == "trainer"
                ) {
                    settle_ability_effect_knockouts(
                        result,
                        cards_,
                        actor
                    );
                }
                if (result.pending.as_object().empty()) {
                    finalize_terminal_if_needed(result);
                }
            }
        } else if (kind == "public_bench_damage_targets") {
            increment(result.state, "revision");
            const std::int32_t attack_actor =
                static_cast<std::int32_t>(integer_arg(
                    continuation,
                    "attack_actor",
                    -1
                ));
            const std::int32_t target_player =
                static_cast<std::int32_t>(integer_arg(
                    continuation,
                    "target_player",
                    -1
                ));
            const std::int64_t amount = integer_arg(
                continuation,
                "amount"
            );
            const std::int64_t count = integer_arg(
                continuation,
                "count"
            );
            const Value *allowed_value = continuation.find(
                "allowed_targets"
            );
            const Value *groups_value = continuation.find(
                "trigger_groups"
            );
            if (
                cancelled
                || actor != attack_actor
                || (attack_actor != 0 && attack_actor != 1)
                || target_player != 1 - attack_actor
                || amount <= 0
                || amount > 1000
                || count <= 0
                || count > 5
                || string_arg(result.state, "phase") != "ATTACK"
                || integer_arg(
                    result.state,
                    "active_player_idx",
                    -1
                ) != attack_actor
                || pokemon(
                    player(result.state, attack_actor),
                    "active"
                ) == nullptr
                || allowed_value == nullptr
                || !allowed_value->is_array()
                || allowed_value->as_array().size()
                    < static_cast<std::size_t>(count)
                || allowed_value->as_array().size() > 5
                || groups_value == nullptr
                || !groups_value->is_array()
                || !selected_options.is_array()
                || selected_options.as_array().size()
                    != static_cast<std::size_t>(count)
            ) {
                throw std::invalid_argument(
                    "public_bench_damage_selection_invalid"
                );
            }

            std::unordered_set<std::string> allowed_ids;
            std::unordered_set<std::string> allowed_slots;
            for (const Value &target : allowed_value->as_array()) {
                const std::string option_id = string_arg(
                    target,
                    "option_id"
                );
                const std::string slot = string_arg(
                    target,
                    "target_slot"
                );
                const std::string expected_card_id = string_arg(
                    target,
                    "target_card_id"
                );
                const bool valid_slot = (
                    slot.size() == 7
                    && slot.rfind("bench_", 0) == 0
                    && slot[6] >= '0'
                    && slot[6] <= '4'
                );
                const Value *current = valid_slot
                    ? pokemon(
                        player(result.state, target_player),
                        slot
                    )
                    : nullptr;
                if (
                    option_id.empty()
                    || expected_card_id.empty()
                    || !valid_slot
                    || !allowed_ids.insert(option_id).second
                    || !allowed_slots.insert(slot).second
                    || current == nullptr
                    || string_arg(*current, "card_id")
                        != expected_card_id
                ) {
                    throw std::invalid_argument(
                        "public_bench_damage_targets_invalid"
                    );
                }
            }

            Array damage_packets;
            std::unordered_set<std::string> selected_ids;
            for (const Value &selected : selected_options.as_array()) {
                const std::string option_id = string_arg(
                    selected,
                    "option_id"
                );
                const auto found = std::find_if(
                    allowed_value->as_array().begin(),
                    allowed_value->as_array().end(),
                    [&option_id](const Value &target) {
                        return string_arg(target, "option_id")
                            == option_id;
                    }
                );
                if (
                    option_id.empty()
                    || !selected_ids.insert(option_id).second
                    || found == allowed_value->as_array().end()
                ) {
                    throw std::invalid_argument(
                        "public_bench_damage_selection_invalid"
                    );
                }
                damage_packets.emplace_back(Object{
                    {"target_player", Value(target_player)},
                    {
                        "target_slot",
                        Value(string_arg(*found, "target_slot")),
                    },
                    {"amount", Value(amount)},
                });
            }

            Value attack_context(Object{
                {"base_damage", Value(0)},
                {"damage_packets", Value(std::move(damage_packets))},
                {"attack_failed", Value(false)},
            });
            apply_attack_damage_before_effect(
                result,
                cards_,
                attack_actor,
                attack_context
            );
            // The formal primary hit has already produced the exact public
            // reaction queue copied below.  Never synthesize it again from
            // this isolated bench packet.
            attack_context["after_damage_triggers_applied"] = Value(true);
            attack_context["reactive_thorns_applied"] = Value(true);

            Array groups = groups_value->as_array();
            std::int32_t previous_order = -1;
            std::size_t total_specs = 0;
            for (const Value &group : groups) {
                const std::int32_t owner =
                    static_cast<std::int32_t>(integer_arg(
                        group,
                        "owner",
                        -1
                    ));
                const Value *specs_value = group.find("specs");
                const std::int32_t order = owner == attack_actor
                    ? 0
                    : (owner == 1 - attack_actor ? 1 : -1);
                if (
                    order <= previous_order
                    || specs_value == nullptr
                    || !specs_value->is_array()
                    || specs_value->as_array().empty()
                ) {
                    throw std::invalid_argument(
                        "public_bench_damage_trigger_queue_invalid"
                    );
                }
                previous_order = order;
                total_specs += specs_value->as_array().size();
                if (total_specs > 64) {
                    throw std::invalid_argument(
                        "public_bench_damage_trigger_queue_invalid"
                    );
                }
                for (const Value &spec : specs_value->as_array()) {
                    validate_public_trigger_spec(result.state, spec);
                }
            }
            while (!groups.empty()) {
                Value group = std::move(groups.front());
                groups.erase(groups.begin());
                const std::int32_t owner =
                    static_cast<std::int32_t>(integer_arg(
                        group,
                        "owner",
                        -1
                    ));
                Array specs = required(group, "specs").as_array();
                if (specs.size() > 1) {
                    suspend_public_trigger_order(
                        result,
                        attack_actor,
                        owner,
                        std::move(specs),
                        std::move(groups),
                        attack_context
                    );
                    result.success = true;
                    return result;
                }
                apply_public_trigger_spec(result, cards_, specs.front());
            }
            finish_attack_resolution(
                result,
                cards_,
                attack_actor,
                attack_context
            );
        } else if (kind == "public_trigger_order") {
            increment(result.state, "revision");
            const Value *specs_value = continuation.find(
                "trigger_specs"
            );
            if (
                specs_value == nullptr
                || !specs_value->is_array()
                || specs_value->as_array().size() < 2
                || !selected_options.is_array()
                || selected_options.as_array().size() != 1
            ) {
                throw std::invalid_argument(
                    "public_trigger_order_selection_invalid"
                );
            }
            const std::string selected_id = string_arg(
                selected_options.as_array().front(),
                "option_id"
            );
            std::int64_t selected_index = -1;
            if (selected_id.rfind("trigger:", 0) == 0) {
                try {
                    std::size_t consumed = 0;
                    selected_index = std::stoll(
                        selected_id.substr(8),
                        &consumed
                    );
                    if (consumed != selected_id.size() - 8) {
                        selected_index = -1;
                    }
                } catch (const std::exception &) {
                    selected_index = -1;
                }
            }
            Array trigger_specs = specs_value->as_array();
            if (
                selected_index < 0
                || static_cast<std::size_t>(selected_index)
                    >= trigger_specs.size()
            ) {
                throw std::invalid_argument(
                    "public_trigger_order_selection_invalid"
                );
            }
            const std::int32_t attack_actor =
                static_cast<std::int32_t>(integer_arg(
                    continuation,
                    "attack_actor",
                    -1
                ));
            const std::int32_t trigger_owner =
                static_cast<std::int32_t>(integer_arg(
                    continuation,
                    "trigger_owner",
                    actor
                ));
            if (
                (attack_actor != 0 && attack_actor != 1)
                || (trigger_owner != 0 && trigger_owner != 1)
                || trigger_owner != actor
            ) {
                throw std::invalid_argument(
                    "public_trigger_order_actor_invalid"
                );
            }
            Value chosen = trigger_specs.at(
                static_cast<std::size_t>(selected_index)
            );
            trigger_specs.erase(
                trigger_specs.begin() + selected_index
            );
            apply_public_trigger_spec(result, cards_, chosen);

            const Value *remaining_value = continuation.find(
                "remaining_trigger_groups"
            );
            if (
                remaining_value == nullptr
                || !remaining_value->is_array()
            ) {
                throw std::invalid_argument(
                    "public_trigger_order_queue_invalid"
                );
            }
            Array remaining_groups = remaining_value->as_array();
            if (trigger_specs.size() > 1) {
                suspend_public_trigger_order(
                    result,
                    attack_actor,
                    trigger_owner,
                    std::move(trigger_specs),
                    std::move(remaining_groups),
                    required(continuation, "attack_context")
                );
                result.success = true;
                return result;
            }
            if (trigger_specs.size() == 1) {
                apply_public_trigger_spec(
                    result,
                    cards_,
                    trigger_specs.front()
                );
            }
            while (!remaining_groups.empty()) {
                Value group = std::move(remaining_groups.front());
                remaining_groups.erase(remaining_groups.begin());
                if (!group.is_object()) {
                    throw std::invalid_argument(
                        "public_trigger_order_queue_invalid"
                    );
                }
                const std::int32_t owner =
                    static_cast<std::int32_t>(integer_arg(
                        group,
                        "owner",
                        -1
                    ));
                const Value *group_specs_value = group.find("specs");
                if (
                    (owner != 0 && owner != 1)
                    || group_specs_value == nullptr
                    || !group_specs_value->is_array()
                    || group_specs_value->as_array().empty()
                ) {
                    throw std::invalid_argument(
                        "public_trigger_order_queue_invalid"
                    );
                }
                Array group_specs = group_specs_value->as_array();
                if (group_specs.size() > 1) {
                    suspend_public_trigger_order(
                        result,
                        attack_actor,
                        owner,
                        std::move(group_specs),
                        std::move(remaining_groups),
                        required(continuation, "attack_context")
                    );
                    result.success = true;
                    return result;
                }
                apply_public_trigger_spec(
                    result,
                    cards_,
                    group_specs.front()
                );
            }
            Value attack_context = required(
                continuation,
                "attack_context"
            );
            finish_attack_resolution(
                result,
                cards_,
                attack_actor,
                attack_context
            );
        } else if (kind == "after_damage_trigger_order") {
            increment(result.state, "revision");
            const std::int64_t trigger_count = std::max<std::int64_t>(
                0,
                integer_arg(continuation, "trigger_count")
            );
            if (
                !selected_options.is_array()
                || selected_options.as_array().size() != 1
                || string_arg(
                    selected_options.as_array().front(),
                    "option_id"
                ).rfind("trigger:", 0) != 0
            ) {
                throw std::invalid_argument(
                    "trigger_order_selection_invalid"
                );
            }
            const std::string selected_id = string_arg(
                selected_options.as_array().front(),
                "option_id"
            );
            std::int64_t selected_index = -1;
            try {
                std::size_t consumed = 0;
                selected_index = std::stoll(
                    selected_id.substr(8),
                    &consumed
                );
                if (consumed != selected_id.size() - 8) {
                    selected_index = -1;
                }
            } catch (const std::exception &) {
                selected_index = -1;
            }
            if (
                trigger_count < 2
                || selected_index < 0
                || selected_index >= trigger_count
            ) {
                throw std::invalid_argument(
                    "trigger_order_selection_invalid"
                );
            }
            const std::int32_t attack_actor =
                static_cast<std::int32_t>(integer_arg(
                    continuation,
                    "attack_actor",
                    -1
                ));
            const std::int32_t trigger_owner =
                static_cast<std::int32_t>(integer_arg(
                    continuation,
                    "trigger_owner",
                    actor
                ));
            const std::int64_t resolved_now = (
                trigger_count > 2 ? 1 : trigger_count
            );
            for (std::int64_t index = 0; index < resolved_now; ++index) {
                draw_one_with_payload(
                    result, trigger_owner, "after_damage_trigger");
            }
            if (trigger_count > 2) {
                suspend_after_damage_trigger_order(
                    result,
                    attack_actor,
                    trigger_owner,
                    trigger_count - 1,
                    (
                        continuation.find("remaining_trigger_groups")
                                != nullptr
                            ? continuation.find(
                                "remaining_trigger_groups"
                            )->as_array()
                            : Array{}
                    ),
                    required(continuation, "attack_context")
                );
                result.success = true;
                return result;
            }
            const Value *remaining = continuation.find(
                "remaining_trigger_groups"
            );
            Array remaining_groups = (
                remaining != nullptr && remaining->is_array()
            ) ? remaining->as_array() : Array{};
            while (!remaining_groups.empty()) {
                Value group = std::move(remaining_groups.front());
                remaining_groups.erase(remaining_groups.begin());
                const std::int32_t owner =
                    static_cast<std::int32_t>(integer_arg(
                        group,
                        "owner",
                        -1
                    ));
                const std::int64_t count = std::max<std::int64_t>(
                    0,
                    integer_arg(group, "count")
                );
                if (count > 1) {
                    suspend_after_damage_trigger_order(
                        result,
                        attack_actor,
                        owner,
                        count,
                        std::move(remaining_groups),
                        required(continuation, "attack_context")
                    );
                    result.success = true;
                    return result;
                }
                for (
                    std::int64_t index = 0;
                    index < count;
                    ++index
                ) {
                    draw_one_with_payload(
                        result, owner, "after_damage_trigger");
                }
            }
            Value attack_context = required(
                continuation,
                "attack_context"
            );
            finish_attack_resolution(
                result,
                cards_,
                attack_actor,
                attack_context
            );
        } else if (kind == "retreat_payment") {
            increment(result.state, "revision");
            if (!cancelled) {
                Value &self = player(result.state, actor);
                Value *active = pokemon(self, "active");
                if (active == nullptr) {
                    throw std::invalid_argument("retreat_active_missing");
                }
                Array &energy = required(
                    *active,
                    "energy_card_ids"
                ).as_array();
                std::vector<std::size_t> indices;
                for (const Value &entry : selected_options.as_array()) {
                    indices.push_back(static_cast<std::size_t>(
                        integer_arg(entry, "index", -1)
                    ));
                }
                std::sort(indices.begin(), indices.end());
                if (
                    std::adjacent_find(indices.begin(), indices.end())
                    != indices.end()
                ) {
                    throw std::invalid_argument(
                        "retreat_payment_duplicate"
                    );
                }
                const std::int64_t required_units = integer_arg(
                    continuation,
                    "required_units"
                );
                std::int64_t paid_units = 0;
                std::vector<std::int64_t> selected_unit_counts;
                selected_unit_counts.reserve(indices.size());
                for (const std::size_t index : indices) {
                    if (index >= energy.size()) {
                        throw std::invalid_argument(
                            "retreat_payment_stale"
                        );
                    }
                    const std::int64_t units = energy_card_unit_count(
                        cards_,
                        energy[index].string_or()
                    );
                    paid_units += units;
                    selected_unit_counts.push_back(units);
                }
                if (paid_units < required_units) {
                    throw std::invalid_argument(
                        "retreat_payment_insufficient"
                    );
                }
                if (std::any_of(
                    selected_unit_counts.begin(),
                    selected_unit_counts.end(),
                    [paid_units, required_units](std::int64_t units) {
                        return paid_units - units >= required_units;
                    }
                )) {
                    throw std::invalid_argument(
                        "retreat_payment_redundant"
                    );
                }
                Array &discard = required(self, "discard").as_array();
                for (
                    auto iterator = indices.rbegin();
                    iterator != indices.rend();
                    ++iterator
                ) {
                    if (*iterator >= energy.size()) {
                        throw std::invalid_argument(
                            "retreat_payment_stale"
                        );
                    }
                    discard.push_back(std::move(energy[*iterator]));
                    energy.erase(
                        energy.begin()
                            + static_cast<std::ptrdiff_t>(*iterator)
                    );
                }
                const std::size_t bench_index = static_cast<std::size_t>(
                    integer_arg(continuation, "bench_idx", -1)
                );
                Array &bench = required(self, "bench").as_array();
                if (
                    bench_index >= bench.size()
                    || !bench[bench_index].is_object()
                ) {
                    throw std::invalid_argument("retreat_target_stale");
                }
                if (!indices.empty()) {
                    result.event_types.emplace_back("cards_discarded");
                }
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
                settle_ability_effect_knockouts(
                    result,
                    cards_,
                    actor
                );
            }
        } else if (kind == "energy_attach_distribution") {
            increment(result.state, "revision");
            Value &self = player(result.state, actor);
            Array &deck = required(self, "deck").as_array();
            if (!cancelled) {
                for (const Value &selection : selected_options.as_array()) {
                    const auto energy = std::find_if(
                        deck.begin(),
                        deck.end(),
                        [this](const Value &entry) {
                            const Value *definition = card_definition(
                                cards_,
                                entry.string_or()
                            );
                            return definition != nullptr
                                && string_arg(*definition, "supertype")
                                    == "Energy"
                                && array_contains_string(
                                    definition->find("subtypes"),
                                    "Basic"
                                );
                        }
                    );
                    if (energy == deck.end()) {
                        break;
                    }
                    Value *target = pokemon(
                        self,
                        string_arg(selection, "slot")
                    );
                    if (target == nullptr) {
                        continue;
                    }
                    required(
                        *target,
                        "energy_card_ids"
                    ).as_array().push_back(std::move(*energy));
                    deck.erase(energy);
                    result.event_types.emplace_back("energy_attached");
                }
            }
            XorShift32 rng(result.rng_state);
            shuffle_array(deck, rng);
            result.rng_state = rng.state();
            result.event_types.emplace_back("deck_shuffled");
            finish_turn(result, cards_, actor);
        } else if (kind == "public_exp_share_spec_order") {
            increment(result.state, "revision");
            const Value *specs_value = continuation.find(
                "exp_share_trigger_specs"
            );
            if (
                specs_value == nullptr
                || !specs_value->is_array()
                || specs_value->as_array().size() < 2
                || specs_value->as_array().size() > 8
                || !selected_options.is_array()
                || selected_options.as_array().size() != 1
            ) {
                throw std::invalid_argument(
                    "public_exp_share_order_selection_invalid"
                );
            }
            const std::string option_id = string_arg(
                selected_options.as_array().front(),
                "option_id"
            );
            std::int64_t selected_index = -1;
            if (option_id.rfind("trigger:", 0) == 0) {
                try {
                    std::size_t consumed = 0;
                    selected_index = std::stoll(
                        option_id.substr(8),
                        &consumed
                    );
                    if (consumed != option_id.size() - 8) {
                        selected_index = -1;
                    }
                } catch (const std::exception &) {
                    selected_index = -1;
                }
            }
            Array trigger_specs = specs_value->as_array();
            if (
                selected_index < 0
                || static_cast<std::size_t>(selected_index)
                    >= trigger_specs.size()
            ) {
                throw std::invalid_argument(
                    "public_exp_share_order_selection_invalid"
                );
            }
            Value chosen = trigger_specs.at(
                static_cast<std::size_t>(selected_index)
            );
            trigger_specs.erase(
                trigger_specs.begin() + selected_index
            );
            const std::int32_t attack_actor =
                static_cast<std::int32_t>(integer_arg(
                    continuation,
                    "attack_actor",
                    1 - actor
                ));
            if (attack_actor != 0 && attack_actor != 1) {
                throw std::invalid_argument(
                    "public_exp_share_order_actor_invalid"
                );
            }
            suspend_public_exp_share_spec_confirmation(
                result,
                actor,
                attack_actor,
                continuation,
                std::move(chosen),
                std::move(trigger_specs)
            );
        } else if (kind == "public_exp_share_order") {
            increment(result.state, "revision");
            const std::int64_t count = integer_arg(
                continuation,
                "exp_share_order_count"
            );
            if (
                count < 2
                || count > 8
                || !selected_options.is_array()
                || selected_options.as_array().size() != 1
            ) {
                throw std::invalid_argument(
                    "exp_share_order_selection_invalid"
                );
            }
            const std::string option_id = string_arg(
                selected_options.as_array().front(),
                "option_id"
            );
            std::int64_t selected_index = -1;
            if (option_id.rfind("trigger:", 0) == 0) {
                try {
                    std::size_t consumed = 0;
                    selected_index = std::stoll(
                        option_id.substr(8),
                        &consumed
                    );
                    if (consumed != option_id.size() - 8) {
                        selected_index = -1;
                    }
                } catch (const std::exception &) {
                    selected_index = -1;
                }
            }
            if (selected_index < 0 || selected_index >= count) {
                throw std::invalid_argument(
                    "exp_share_order_selection_invalid"
                );
            }
            const std::int32_t attack_actor =
                static_cast<std::int32_t>(integer_arg(
                    continuation,
                    "attack_actor",
                    1 - actor
                ));
            suspend_exp_share_confirmation(
                result,
                actor,
                attack_actor,
                continuation,
                count - 1,
                count - 1 > 1
            );
        } else if (kind == "confirm_exp_share_trigger") {
            increment(result.state, "revision");
            const bool confirmed = selected_options.is_array()
                && !selected_options.as_array().empty()
                && string_arg(
                    selected_options.as_array().front(),
                    "option_id"
                ) == "confirm:yes";
            const std::int32_t attack_actor =
                static_cast<std::int32_t>(integer_arg(
                    continuation,
                    "attack_actor",
                    1 - actor
                ));
            if (!confirmed) {
                continue_after_exp_share_trigger(
                    result,
                    cards_,
                    actor,
                    attack_actor,
                    continuation
                );
            } else {
                Value *source = pokemon(
                    player(result.state, actor),
                    string_arg(continuation, "from_slot", "active")
                );
                Value *target = pokemon(
                    player(result.state, actor),
                    string_arg(continuation, "to_slot")
                );
                if (
                    source == nullptr
                    || target == nullptr
                    || string_arg(*source, "card_id")
                        != string_arg(continuation, "from_card_id")
                    || string_arg(*target, "card_id")
                        != string_arg(continuation, "to_card_id")
                    || string_arg(*target, "attached_tool_id")
                        != string_arg(continuation, "target_tool_id")
                ) {
                    throw std::invalid_argument(
                        "exp_share_entity_changed"
                    );
                }
                Array options;
                const Array &energy = required(
                    *source,
                    "energy_card_ids"
                ).as_array();
                for (std::size_t index = 0; index < energy.size(); ++index) {
                    if (!is_basic_energy_id(
                        cards_,
                        energy[index].string_or()
                    )) {
                        continue;
                    }
                    options.emplace_back(Object{
                        {"kind", Value("attachment")},
                        {"player", Value(actor)},
                        {
                            "slot",
                            Value(string_arg(
                                continuation,
                                "from_slot",
                                "active"
                            )),
                        },
                        {
                            "index",
                            Value(static_cast<std::int64_t>(index)),
                        },
                        {"attachment_type", Value("energy")},
                        {"card_id", Value(energy[index].string_or())},
                    });
                }
                if (options.empty()) {
                    continue_after_exp_share_trigger(
                        result,
                        cards_,
                        actor,
                        attack_actor,
                        continuation
                    );
                } else {
                    increment(result.state, "choice_sequence");
                    result.pending = action_pending(
                        "select_attachment",
                        actor,
                        1,
                        1,
                        false,
                        std::move(options),
                        "select_exp_share_energy",
                        true
                    );
                    Value continued = continuation;
                    continued["kind"] = Value(
                        "select_exp_share_energy"
                    );
                    result.continuation = std::move(continued);
                }
            }
        } else if (kind == "select_exp_share_energy") {
            increment(result.state, "revision");
            if (
                !selected_options.is_array()
                || selected_options.as_array().size() != 1
            ) {
                throw std::invalid_argument(
                    "exp_share_energy_selection_invalid"
                );
            }
            const Value &selection =
                selected_options.as_array().front();
            const std::int32_t attack_actor =
                static_cast<std::int32_t>(integer_arg(
                    continuation,
                    "attack_actor",
                    1 - actor
                ));
            Value *source = pokemon(
                player(result.state, actor),
                string_arg(continuation, "from_slot", "active")
            );
            Value *target = pokemon(
                player(result.state, actor),
                string_arg(continuation, "to_slot")
            );
            if (source == nullptr || target == nullptr) {
                throw std::invalid_argument(
                    "exp_share_entity_changed"
                );
            }
            Array &energy = required(
                *source,
                "energy_card_ids"
            ).as_array();
            const std::size_t index = static_cast<std::size_t>(
                integer_arg(selection, "index", -1)
            );
            if (
                index >= energy.size()
                || energy[index].string_or()
                    != string_arg(selection, "card_id")
                || !is_basic_energy_id(
                    cards_,
                    energy[index].string_or()
                )
            ) {
                throw std::invalid_argument(
                    "exp_share_energy_selection_changed"
                );
            }
            required(
                *target,
                "energy_card_ids"
            ).as_array().push_back(std::move(energy[index]));
            energy.erase(
                energy.begin() + static_cast<std::ptrdiff_t>(index)
            );
            result.event_types.emplace_back("energy_attached");
            continue_after_exp_share_trigger(
                result,
                cards_,
                actor,
                attack_actor,
                continuation
            );
        } else if (kind == "select_prize") {
            increment(result.state, "revision");
            if (
                selected_options.is_array()
                && !selected_options.as_array().empty()
            ) {
                const std::string option = string_arg(
                    selected_options.as_array().front(),
                    "option_id"
                );
                const std::size_t index = static_cast<std::size_t>(
                    std::stoul(option.substr(option.find(':') + 1))
                );
                Array &prizes = required(
                    player(result.state, actor),
                    "prizes"
                ).as_array();
                if (index >= prizes.size()) {
                    throw std::invalid_argument("prize_index_invalid");
                }
                const std::string prize_card_id =
                    prizes[index].string_or();
                Array targets = pokemon_options(
                    player(result.state, actor),
                    actor,
                    false,
                    true
                );
                if (
                    !targets.empty()
                    && prize_attaches_to_bench(
                        cards_,
                        prize_card_id
                    )
                ) {
                    increment(result.state, "choice_sequence");
                    result.pending = action_pending(
                        "select_prize_energy_target",
                        actor,
                        0,
                        1,
                        true,
                        std::move(targets),
                        "treasure_prize_target",
                        true
                    );
                    result.pending["prompt"] = Value(
                        "请选择宝藏能量的附着目标，或不发动效果。"
                    );
                    result.pending["presentation"] = Value(Object{
                        {"domain", Value("trigger")},
                        {"purpose", Value("treasure_energy_target")},
                        {"source_player", Value(actor)},
                        {"source_zone", Value("prizes")},
                        {"source_card_id", Value(prize_card_id)},
                        {"card_id", Value(prize_card_id)},
                        {
                            "revealed_card_ids",
                            Value(Array{Value(prize_card_id)}),
                        },
                    });
                    result.continuation = continuation;
                    result.continuation["kind"] = Value(
                        "treasure_prize_target"
                    );
                    result.continuation["actor"] = Value(actor);
                    result.continuation["prize_index"] = Value(
                        static_cast<std::int64_t>(index)
                    );
                    result.continuation["prize_card_id"] = Value(
                        prize_card_id
                    );
                    result.success = true;
                    return result;
                }
                required(
                    player(result.state, actor),
                    "hand"
                ).as_array().push_back(std::move(prizes[index]));
                prizes.erase(
                    prizes.begin() + static_cast<std::ptrdiff_t>(index)
                );
                append_event(result, "prize_taken", Object{
                    {"player", Value(actor)},
                    {"card_id", Value(prize_card_id)},
                    {"card_ids", Value(Array{Value(prize_card_id)})},
                    {"count", Value(1)},
                    {"source_zone", Value("prizes")},
                    {
                        "source_index",
                        Value(static_cast<std::int64_t>(index)),
                    },
                    {"target_zone", Value("hand")},
                    {"visibility", Value("owner")},
                });
                result.event_types.emplace_back("prize_taken");
            }
            continue_after_prize_selection(
                result,
                cards_,
                continuation
            );
        } else if (kind == "treasure_prize_target") {
            increment(result.state, "revision");
            Array &prizes = required(
                player(result.state, actor),
                "prizes"
            ).as_array();
            const std::size_t index = static_cast<std::size_t>(
                integer_arg(continuation, "prize_index", -1)
            );
            const std::string expected_id = string_arg(
                continuation,
                "prize_card_id"
            );
            if (
                index >= prizes.size()
                || prizes[index].string_or() != expected_id
                || !prize_attaches_to_bench(cards_, expected_id)
            ) {
                throw std::invalid_argument(
                    "treasure_prize_entity_changed"
                );
            }
            Value prize = std::move(prizes[index]);
            prizes.erase(
                prizes.begin() + static_cast<std::ptrdiff_t>(index)
            );
            if (
                !cancelled
                && selected_options.is_array()
                && !selected_options.as_array().empty()
            ) {
                if (selected_options.as_array().size() != 1) {
                    throw std::invalid_argument(
                        "treasure_prize_target_invalid"
                    );
                }
                const Value &selection =
                    selected_options.as_array().front();
                const std::string selected_slot = string_arg(
                    selection,
                    "slot"
                );
                if (
                    integer_arg(selection, "player", -1) != actor
                    || (
                        selected_slot != "active"
                        && selected_slot.rfind("bench_", 0) != 0
                    )
                ) {
                    throw std::invalid_argument(
                        "treasure_prize_target_invalid"
                    );
                }
                Value *target = pokemon(
                    player(result.state, actor),
                    selected_slot
                );
                if (
                    target == nullptr
                    || string_arg(*target, "card_id")
                        != string_arg(selection, "card_id")
                ) {
                    throw std::invalid_argument(
                        "treasure_prize_target_changed"
                    );
                }
                required(
                    *target,
                    "energy_card_ids"
                ).as_array().push_back(std::move(prize));
                result.event_types.emplace_back("energy_attached");
            } else {
                required(
                    player(result.state, actor),
                    "hand"
                ).as_array().push_back(std::move(prize));
                append_event(result, "prize_taken", Object{
                    {"player", Value(actor)},
                    {"card_id", Value(expected_id)},
                    {"card_ids", Value(Array{Value(expected_id)})},
                    {"count", Value(1)},
                    {"source_zone", Value("prizes")},
                    {
                        "source_index",
                        Value(static_cast<std::int64_t>(index)),
                    },
                    {"target_zone", Value("hand")},
                    {"visibility", Value("owner")},
                });
            }
            result.event_types.emplace_back("prize_taken");
            continue_after_prize_selection(
                result,
                cards_,
                continuation
            );
        } else {
            throw std::invalid_argument("unsupported_game_continuation");
        }
        result.success = true;
    } catch (const std::exception &error) {
        result.success = false;
        result.error_code = error.what();
    }
    return result;
}


} // namespace ptcg::ai
