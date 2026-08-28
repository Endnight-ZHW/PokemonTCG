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

bool execute_vm_modifier_pipeline(
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
        op == "apply_attack_lock_basic"
        || op == "apply_dazzling_beam"
        || op == "apply_outgoing_damage_reduction"
        || op == "apply_self_attack_lock"
        || op == "prevent_all"
        || op == "prevent_damage"
        || op == "prevent_effects"
        || op == "apply_status"
        || op == "conditional_status"
        || op == "attach_energy"
        || op == "attach_energy_from_discard"
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
            op == "apply_attack_lock_basic"
            || op == "apply_dazzling_beam"
            || op == "apply_outgoing_damage_reduction"
            || op == "apply_self_attack_lock"
            || op == "prevent_all"
            || op == "prevent_damage"
            || op == "prevent_effects"
        ) {
            const bool player_attack_name_lock = (
                op == "apply_self_attack_lock"
                && string_arg(args, "scope") == "player"
            );
            if (player_attack_name_lock) {
                Value *locks = self.find("attack_locked_names");
                if (locks == nullptr || !locks->is_object()) {
                    self["attack_locked_names"] = Value::make_object();
                    locks = self.find("attack_locked_names");
                }
                const std::string attack_name = string_arg(
                    args,
                    "attack_name"
                );
                if (!attack_name.empty()) {
                    (*locks)[attack_name] = Value(
                        integer_arg(result.state, "turn_number") + 2
                    );
                }
            }
            Value *target = (
                op == "apply_self_attack_lock"
                || op == "prevent_all"
                || op == "prevent_damage"
                || op == "prevent_effects"
            ) ? source : opponent_active;
            if (target != nullptr && !player_attack_name_lock) {
                bool effect_applies = true;
                if (
                    target == opponent_active
                    && context_mode == "attack"
                    && prevents_attack_effects(*target)
                ) {
                    effect_applies = false;
                }
                if (effect_applies && op == "apply_attack_lock_basic") {
                    effect_applies = card_has_subtype(
                        cards,
                        card_id(*target),
                        "Basic"
                    );
                }
                if (effect_applies) {
                    append_modifier(*target, op, args);
                    if (op == "prevent_all" || op == "prevent_damage") {
                        (*target)["damage_prevented"] = Value(true);
                    }
                    if (op == "prevent_all" || op == "prevent_effects") {
                        (*target)["all_prevented"] = Value(true);
                    }
                    if (op == "apply_outgoing_damage_reduction") {
                        (*target)["outgoing_damage_reduction"] = Value(
                            std::max<std::int64_t>(
                                integer_arg(
                                    *target,
                                    "outgoing_damage_reduction"
                                ),
                                std::abs(integer_arg(args, "amount"))
                            )
                        );
                    }
                }
            }
        } else if (op == "apply_status" || op == "conditional_status") {
            bool applies = true;
            if (op == "conditional_status") {
                applies = condition_applies(
                    cards,
                    result.state,
                    actor,
                    string_arg(args, "condition")
                );
            }
            if (
                applies
                && opponent_active != nullptr
                && !(
                    context_mode == "attack"
                    && prevents_attack_effects(*opponent_active)
                )
            ) {
                Value *conditions = opponent_active->find(
                    "status_conditions"
                );
                if (conditions == nullptr || !conditions->is_array()) {
                    (*opponent_active)["status_conditions"] =
                        Value::make_array();
                    conditions = opponent_active->find(
                        "status_conditions"
                    );
                }
                const std::string status = upper_ascii(
                    string_arg(args, "status")
                );
                std::vector<std::string> replaced_statuses;
                if (
                    status == "ASLEEP"
                    || status == "PARALYZED"
                    || status == "CONFUSED"
                ) {
                    for (const Value &entry : conditions->as_array()) {
                        const std::string current = entry.string_or();
                        if (
                            current != status
                            && (
                                current == "ASLEEP"
                                || current == "PARALYZED"
                                || current == "CONFUSED"
                            )
                        ) {
                            replaced_statuses.push_back(current);
                        }
                    }
                    conditions->as_array().erase(
                        std::remove_if(
                            conditions->as_array().begin(),
                            conditions->as_array().end(),
                            [](const Value &entry) {
                                const std::string current =
                                    entry.string_or();
                                return current == "ASLEEP"
                                    || current == "PARALYZED"
                                    || current == "CONFUSED";
                            }
                        ),
                        conditions->as_array().end()
                    );
                }
                for (const std::string &replaced : replaced_statuses) {
                    append_status_event(
                        result,
                        "status_removed",
                        actor,
                        1 - actor,
                        "active",
                        replaced
                    );
                }
                if (
                    std::find(
                        replaced_statuses.begin(),
                        replaced_statuses.end(),
                        "PARALYZED"
                    ) != replaced_statuses.end()
                ) {
                    set_integer(*opponent_active, "paralyzed_since_turn", 0);
                }
                const auto already = std::find_if(
                    conditions->as_array().begin(),
                    conditions->as_array().end(),
                    [&status](const Value &entry) {
                        return entry.string_or() == status;
                    }
                );
                if (already == conditions->as_array().end()) {
                    conditions->as_array().emplace_back(status);
                }
                if (status == "PARALYZED") {
                    set_integer(
                        *opponent_active,
                        "paralyzed_since_turn",
                        get_integer(result.state, "turn_number")
                    );
                }
                append_status_event(
                    result,
                    "status_applied",
                    actor,
                    1 - actor,
                    "active",
                    status
                );
            }
        } else if (op == "attach_energy") {
            const std::string from_zone = string_arg(
                args,
                "from_zone",
                "hand"
            );
            Value &source_zone = required(self, from_zone);
            Array &source_cards = source_zone.as_array();
            const std::string filter = string_arg(
                args,
                "filter",
                "any"
            );
            const std::string target_kind = string_arg(
                args,
                "to",
                source_slot
            );
            std::int64_t amount = integer_arg(args, "amount", 1);
            const std::int64_t going_second_bonus = integer_arg(
                args,
                "going_second_bonus"
            );
            const bool bonus_applied = going_second_bonus > amount
                && actor != integer_arg(result.state, "first_player_idx", -1)
                && integer_arg(result.state, "turn_number") == 2;
            if (bonus_applied) {
                amount = going_second_bonus;
            }
            const bool optional = bool_arg(args, "optional")
                || bonus_applied
                || args.find("min_select") != nullptr;
            const bool select_source = bool_arg(args, "select_source");
            const bool single_optional_bench = (
                target_kind == "bench"
                && optional
                && std::count_if(
                    required(self, "bench").as_array().begin(),
                    required(self, "bench").as_array().end(),
                    [](const Value &entry) {
                        return entry.is_object();
                    }
                ) == 1
            );
            if (
                target_kind == "any"
                || target_kind == "self_basic"
                || (
                    target_kind == "bench"
                    && (
                        amount > 1
                        || select_source
                        || single_optional_bench
                    )
                )
            ) {
                const bool bench_only = target_kind == "bench";
                Array targets = pokemon_options(
                    self,
                    actor,
                    !bench_only,
                    true
                );
                if (target_kind == "self_basic") {
                    targets.erase(
                        std::remove_if(
                            targets.begin(),
                            targets.end(),
                            [&cards](const Value &entry) {
                                return !card_has_subtype(
                                    cards,
                                    string_arg(entry, "card_id"),
                                    "Basic"
                                );
                            }
                        ),
                        targets.end()
                    );
                }
                std::vector<std::string> matching_energy_ids;
                for (const Value &entry : source_cards) {
                    if (card_matches_energy(
                        cards,
                        entry.string_or(),
                        filter
                    )) {
                        matching_energy_ids.push_back(entry.string_or());
                    }
                }
                const std::int64_t matching_energy =
                    static_cast<std::int64_t>(
                        matching_energy_ids.size()
                    );
                if (matching_energy == 0 || targets.empty()) {
                    if (
                        context_mode == "ability"
                        && from_zone == "hand"
                        && !optional
                    ) {
                        throw std::invalid_argument(
                            matching_energy == 0
                                ? "required_energy_source_missing"
                                : "required_energy_target_missing"
                        );
                    }
                    // Hidden deck searches and optional attack effects may
                    // still resolve without finding a card.
                    result.success = true;
                    result.rng_state = rng.state();
                    early_return = true; return true;
                }
                const std::int64_t max_per_target = bench_only
                    ? integer_arg(args, "max_per_target", 99)
                    : amount;
                const bool same_target = bool_arg(args, "same_target")
                    || target_kind == "any"
                    || target_kind == "self_basic";
                const std::int64_t target_capacity = std::max<
                    std::int64_t
                >(
                    0,
                    static_cast<std::int64_t>(targets.size())
                        * max_per_target
                );
                const std::int64_t maximum = std::min({
                    amount,
                    matching_energy,
                    target_capacity,
                });
                if (
                    targets.size() == 1
                    && !optional
                    && !select_source
                ) {
                    Value *target = pokemon(
                        self,
                        string_arg(targets.front(), "slot")
                    );
                    std::int64_t remaining = maximum;
                    for (
                        std::size_t index = 0;
                        index < source_cards.size() && remaining > 0;
                    ) {
                        if (!card_matches_energy(
                            cards,
                            source_cards[index].string_or(),
                            filter
                        )) {
                            ++index;
                            continue;
                        }
                        required(
                            *target,
                            "energy_card_ids"
                        ).as_array().push_back(
                            std::move(source_cards[index])
                        );
                        source_cards.erase(
                            source_cards.begin()
                                + static_cast<std::ptrdiff_t>(index)
                        );
                        --remaining;
                        result.event_types.emplace_back(
                            "energy_attached"
                        );
                    }
                    if (from_zone == "deck") {
                        shuffle_array(source_cards, rng);
                        result.event_types.emplace_back("deck_shuffled");
                    }
                    result.success = true;
                    result.rng_state = rng.state();
                    early_return = true; return true;
                }
                Array options;
                Array presented_energy_ids;
                const bool distribution = optional
                    || select_source
                    || bench_only;
                if (distribution) {
                    std::vector<std::int64_t> exposed_energy_indices;
                    std::map<std::string, std::int64_t, std::less<>>
                        exposed_by_id;
                    for (
                        std::int64_t index = 0;
                        index < matching_energy;
                        ++index
                    ) {
                        const std::string &card_id = matching_energy_ids[
                            static_cast<std::size_t>(index)
                        ];
                        if (
                            select_source
                            && exposed_by_id[card_id] >= maximum
                        ) {
                            continue;
                        }
                        exposed_energy_indices.push_back(index);
                        ++exposed_by_id[card_id];
                        if (
                            !select_source
                            && exposed_energy_indices.size()
                                >= static_cast<std::size_t>(maximum)
                        ) {
                            break;
                        }
                    }
                    for (const std::int64_t index : exposed_energy_indices) {
                        presented_energy_ids.emplace_back(
                            matching_energy_ids[
                                static_cast<std::size_t>(index)
                            ]
                        );
                    }
                    for (const Value &target : targets) {
                        for (const std::int64_t index : exposed_energy_indices) {
                            Value option = target;
                            decorate_energy_distribution_option(
                                option,
                                actor,
                                index,
                                matching_energy_ids[
                                    static_cast<std::size_t>(index)
                                ]
                            );
                            options.push_back(std::move(option));
                        }
                    }
                } else {
                    options = std::move(targets);
                }
                Value continued = make_continuation(
                    op,
                    command_spec,
                    actor,
                    source_slot
                );
                continued["effective_amount"] = Value(maximum);
                continued["distribution"] = Value(distribution);
                const std::int64_t minimum = distribution
                    ? std::min(
                        maximum,
                        integer_arg(args, "min_select")
                    )
                    : 1;
                Value request = pending_request(
                        distribution
                            ? "distribute_energy"
                            : "select_energy_target",
                        actor,
                        minimum,
                        distribution ? maximum : 1,
                        false,
                        distribution && minimum == 0,
                        std::move(options),
                        distribution
                            ? "energy_attach_distribution"
                            : "attach_energy_to_board"
                    );
                if (distribution) {
                    request["metadata"] = Value(Object{
                        {"card_ids", Value(std::move(presented_energy_ids))},
                        {"domain", Value("distribute_energy")},
                        {"energy_type", Value(filter)},
                        {"max_per_target", Value(max_per_target)},
                        {"purpose", Value("energy_attach_distribution")},
                        {"same_target", Value(same_target)},
                        {"source_player", Value(actor)},
                        {"source_zone", Value(from_zone)},
                    });
                }
                suspend(
                    std::move(request),
                    std::move(continued)
                );
                result.success = true;
                result.rng_state = rng.state();
                early_return = true; return true;
            }
            if (target_kind == "bench" && amount <= 1 && !select_source) {
                Array targets = pokemon_options(
                    self,
                    actor,
                    false,
                    true
                );
                const bool has_matching_energy = std::any_of(
                    source_cards.begin(),
                    source_cards.end(),
                    [&cards, &filter](const Value &entry) {
                        return card_matches_energy(
                            cards,
                            entry.string_or(),
                            filter
                        );
                    }
                );
                if (!has_matching_energy || targets.empty()) {
                    // The formal engine does not shuffle for this no-op.
                    result.success = true;
                    result.rng_state = rng.state();
                    early_return = true; return true;
                }
                if (targets.size() == 1 && !optional) {
                    Value *target = pokemon(
                        self,
                        string_arg(targets.front(), "slot")
                    );
                    const auto energy = std::find_if(
                        source_cards.begin(),
                        source_cards.end(),
                        [&cards, &filter](const Value &entry) {
                            return card_matches_energy(
                                cards,
                                entry.string_or(),
                                filter
                            );
                        }
                    );
                    required(
                        *target,
                        "energy_card_ids"
                    ).as_array().push_back(std::move(*energy));
                    source_cards.erase(energy);
                    result.event_types.emplace_back("energy_attached");
                    if (from_zone == "deck") {
                        shuffle_array(source_cards, rng);
                        result.event_types.emplace_back("deck_shuffled");
                    }
                    result.success = true;
                    result.rng_state = rng.state();
                    early_return = true; return true;
                }
                suspend(
                    pending_request(
                        "select_own_bench_energy",
                        actor,
                        optional ? 0 : 1,
                        1,
                        false,
                        optional,
                        std::move(targets),
                        "attach_energy_to_bench"
                    ),
                    make_continuation(
                        op,
                        command_spec,
                        actor,
                        source_slot
                    )
                );
                result.success = true;
                result.rng_state = rng.state();
                early_return = true; return true;
            }
            Value *target = pokemon(
                self,
                target_kind == "self"
                    ? source_slot
                    : target_kind
            );
            std::int64_t remaining = amount;
            if (target != nullptr) {
                Array &attachments = required(
                    *target,
                    "energy_card_ids"
                ).as_array();
                for (
                    std::size_t index = 0;
                    index < source_cards.size() && remaining > 0;
                ) {
                    if (!card_matches_energy(
                        cards,
                        source_cards[index].string_or(),
                        filter
                    )) {
                        ++index;
                        continue;
                    }
                    attachments.push_back(std::move(source_cards[index]));
                    source_cards.erase(
                        source_cards.begin()
                            + static_cast<std::ptrdiff_t>(index)
                    );
                    --remaining;
                    result.event_types.emplace_back("energy_attached");
                }
            }
            if (from_zone == "deck") {
                shuffle_array(source_cards, rng);
                result.event_types.emplace_back("deck_shuffled");
            }
        } else if (op == "attach_energy_from_discard") {
            const std::string filter = string_arg(
                args,
                "energy_type",
                string_arg(args, "filter", "basic")
            );
            const Array sources = zone_options(
                cards,
                self,
                actor,
                "discard",
                filter
            );
            Array targets = pokemon_options(
                self,
                actor,
                string_arg(args, "target", "self") != "bench",
                string_arg(args, "target", "self") != "self"
            );
            const std::string target_type = string_arg(
                args,
                "target_pokemon_type"
            );
            if (!target_type.empty()) {
                targets.erase(
                    std::remove_if(
                        targets.begin(),
                        targets.end(),
                        [&cards, &target_type](const Value &entry) {
                            const Value *definition = card_definition(
                                cards,
                                string_arg(entry, "card_id")
                            );
                            return definition == nullptr
                                || !string_array_contains_ci(
                                    definition->find("energy_types"),
                                    target_type
                                );
                        }
                    ),
                    targets.end()
                );
            }
            if (sources.empty() || targets.empty()) {
                const bool required_public_attach = (
                    context_mode == "trainer"
                    || context_mode == "ability"
                ) && args.find("min_select") == nullptr
                    && !bool_arg(args, "optional");
                if (required_public_attach) {
                    throw std::invalid_argument(
                        sources.empty()
                            ? "required_energy_source_missing"
                            : "required_energy_target_missing"
                    );
                }
                result.success = true;
                result.rng_state = rng.state();
                early_return = true; return true;
            }
            const bool select_source = bool_arg(args, "select_source");
            const std::int64_t maximum = std::min<std::int64_t>(
                integer_arg(args, "amount", 1),
                static_cast<std::int64_t>(sources.size())
            );
            std::vector<std::size_t> exposed_source_indices;
            std::map<std::string, std::int64_t, std::less<>> exposed_by_id;
            for (std::size_t index = 0; index < sources.size(); ++index) {
                const std::string card_id = string_arg(
                    sources[index],
                    "card_id"
                );
                if (select_source && exposed_by_id[card_id] >= maximum) {
                    continue;
                }
                exposed_source_indices.push_back(index);
                ++exposed_by_id[card_id];
                if (
                    !select_source
                    && exposed_source_indices.size()
                        >= static_cast<std::size_t>(maximum)
                ) {
                    break;
                }
            }
            Array options;
            Array presented_energy_ids;
            for (const std::size_t index : exposed_source_indices) {
                presented_energy_ids.emplace_back(
                    string_arg(sources[index], "card_id")
                );
            }
            for (const Value &target : targets) {
                for (const std::size_t index : exposed_source_indices) {
                    Value option = target;
                    decorate_energy_distribution_option(
                        option,
                        actor,
                        static_cast<std::int64_t>(index),
                        string_arg(sources[index], "card_id")
                    );
                    options.push_back(std::move(option));
                }
            }
            const bool optional_count = args.find("min_select") != nullptr
                || bool_arg(args, "optional");
            const std::string target_kind = string_arg(
                args,
                "target",
                "self"
            );
            const bool same_target = bool_arg(args, "same_target")
                || target_kind == "self"
                || target_kind == "self_or_bench";
            if (
                targets.size() == 1
                && static_cast<std::int64_t>(sources.size()) == maximum
                && !optional_count
                && !select_source
            ) {
                Array &discard = required(self, "discard").as_array();
                Value *target = pokemon(
                    self,
                    string_arg(targets.front(), "slot")
                );
                std::int64_t remaining = maximum;
                for (
                    std::size_t index = 0;
                    index < discard.size() && remaining > 0;
                ) {
                    if (!card_matches_energy(
                            cards,
                            discard[index].string_or(),
                            filter
                        )) {
                        ++index;
                        continue;
                    }
                    required(
                        *target,
                        "energy_card_ids"
                    ).as_array().push_back(std::move(discard[index]));
                    discard.erase(
                        discard.begin()
                            + static_cast<std::ptrdiff_t>(index)
                    );
                    --remaining;
                    result.event_types.emplace_back("energy_attached");
                }
                result.success = true;
                result.rng_state = rng.state();
                early_return = true; return true;
            }
            const std::int64_t minimum = optional_count
                ? std::min(
                    maximum,
                    integer_arg(args, "min_select")
                )
                : maximum;
            Value request = pending_request(
                    "distribute_energy",
                    actor,
                    minimum,
                    maximum,
                    false,
                    minimum == 0,
                    std::move(options),
                    "attach_discard_energy_distribution"
                );
            request["metadata"] = Value(Object{
                {"card_ids", Value(std::move(presented_energy_ids))},
                {"domain", Value("distribute_energy")},
                {"energy_type", Value(filter)},
                {"max_per_target", Value(same_target ? maximum : 99)},
                {
                    "purpose",
                    Value("attach_discard_energy_distribution")
                },
                {"same_target", Value(same_target)},
                {"source_player", Value(actor)},
                {"source_zone", Value("discard")},
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
        }

    return true;
}

} // namespace ptcg::ai::rules_detail
