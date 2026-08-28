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

bool resume_vm_triggers(
    const NativeRulesKernel &kernel,
    const Value &cards,
    const Value &continuation,
    const Value &selected_options,
    bool cancelled,
    const std::string &op,
    const Value &args,
    std::int32_t actor,
    const std::string &source_slot,
    std::int64_t stage,
    XorShift32 &rng,
    VmExecutionResult &result,
    bool &early_return
) {
    (void)kernel;
    if (!(
        op == "relocate_energy"
        || op == "search_any_and_switch"
        || op == "shuffle_from_discard_to_deck"
        || op == "switch_pokemon"
        || op == "trekking_shoes"
        || op == "zinnia_resolve"
    )) return false;
    Value &self = player(result.state, actor);
    Value &opponent = player(result.state, 1 - actor);
    auto next = [&result](Value request, Value next_continuation) {
        increment_integer(result.state, "choice_sequence");
        result.pending = std::move(request);
        result.continuation = std::move(next_continuation);
    };

        if (op == "relocate_energy") {
            auto relocation_targets = [
                &self,
                actor
            ](const std::string &excluded_slot) {
                Array options = pokemon_options(
                    self,
                    actor,
                    true,
                    true
                );
                options.erase(
                    std::remove_if(
                        options.begin(),
                        options.end(),
                        [&excluded_slot](const Value &entry) {
                            return string_arg(entry, "slot")
                                == excluded_slot;
                        }
                    ),
                    options.end()
                );
                return options;
            };
            auto request_relocation_targets = [
                &next,
                &relocation_targets,
                &args,
                actor
            ](
                Value continued,
                const std::string &selected_source_slot,
                Value attachments
            ) {
                const std::int64_t count =
                    static_cast<std::int64_t>(
                        attachments.as_array().size()
                    );
                continued["source_slot"] = Value(
                    selected_source_slot
                );
                continued["stage"] = Value(1);
                continued["selected_attachments"] = std::move(
                    attachments
                );
                const bool same_target = bool_arg(args, "same_target");
                const std::int64_t target_count = same_target ? 1 : count;
                next(
                    pending_request(
                        !same_target && count > 1
                            ? "distribute_energy"
                            : "select_energy_target",
                        actor,
                        target_count,
                        target_count,
                        !same_target && count > 1,
                        false,
                        relocation_targets(selected_source_slot),
                        !same_target && count > 1
                            ? "energy_relocate_distribution"
                            : "energy_relocate_target"
                    ),
                    std::move(continued)
                );
            };
            if (stage == -1) {
                const std::string selected_source_slot = selected_slot(
                    selected_options
                );
                Value *selected_source = pokemon(
                    self,
                    selected_source_slot
                );
                if (selected_source == nullptr) {
                    throw std::invalid_argument(
                        "energy_relocate_source_missing"
                    );
                }
                const Value &source_option =
                    selected_options.as_array().front();
                if (
                    integer_arg(source_option, "player", -1) != actor
                    || string_arg(source_option, "card_id")
                        != string_arg(*selected_source, "card_id")
                ) {
                    throw std::invalid_argument(
                        "energy_relocate_source_stale"
                    );
                }
                const std::string filter = string_arg(
                    args,
                    "energy_type",
                    string_arg(args, "filter", "any")
                );
                Array attachments;
                const Array &energy = required(
                    *selected_source,
                    "energy_card_ids"
                ).as_array();
                for (
                    std::size_t index = 0;
                    index < energy.size();
                    ++index
                ) {
                    if (attached_energy_card_matches(
                        cards,
                        *selected_source,
                        index,
                        filter
                    )) {
                        attachments.push_back(attachment_option(
                            energy[index].string_or(),
                            actor,
                            selected_source_slot,
                            static_cast<std::int64_t>(index)
                        ));
                    }
                }
                const std::int64_t amount = std::min<std::int64_t>(
                    integer_arg(args, "amount", 1),
                    static_cast<std::int64_t>(attachments.size())
                );
                const bool optional_count =
                    args.find("min_select") != nullptr
                    || bool_arg(args, "optional");
                const std::int64_t minimum = optional_count
                    ? std::min(
                        amount,
                        integer_arg(args, "min_select")
                    )
                    : amount;
                const bool exact_choice = minimum < amount
                    || static_cast<std::int64_t>(attachments.size())
                        > amount;
                Value continued = continuation;
                continued["source_slot"] = Value(
                    selected_source_slot
                );
                if (exact_choice) {
                    continued["stage"] = Value(0);
                    next(
                        pending_request(
                            "select_attachment",
                            actor,
                            minimum,
                            amount,
                            false,
                            minimum == 0,
                            std::move(attachments),
                            "energy_relocate_attachments"
                        ),
                        std::move(continued)
                    );
                } else {
                    attachments.resize(
                        static_cast<std::size_t>(amount)
                    );
                    request_relocation_targets(
                        std::move(continued),
                        selected_source_slot,
                        std::move(attachments)
                    );
                }
            } else if (stage == 0) {
                if (selected_options.as_array().empty()) {
                    result.success = true;
                    result.rng_state = rng.state();
                    early_return = true; return true;
                }
                Value *selected_source = pokemon(self, source_slot);
                if (selected_source == nullptr) {
                    throw std::invalid_argument(
                        "energy_relocate_source_missing"
                    );
                }
                const Array &source_energy = required(
                    *selected_source,
                    "energy_card_ids"
                ).as_array();
                const std::string filter = string_arg(
                    args,
                    "energy_type",
                    string_arg(args, "filter", "any")
                );
                std::unordered_set<std::size_t> selected_indices;
                for (const Value &attachment : selected_options.as_array()) {
                    const std::int64_t raw_index = integer_arg(
                        attachment, "index", -1);
                    if (
                        !attachment.is_object()
                        || string_arg(attachment, "kind") != "attachment"
                        || string_arg(attachment, "attachment_type")
                            != "energy"
                        || integer_arg(attachment, "player", -1) != actor
                        || string_arg(attachment, "slot") != source_slot
                        || raw_index < 0
                        || static_cast<std::size_t>(raw_index)
                            >= source_energy.size()
                        || !selected_indices.insert(
                            static_cast<std::size_t>(raw_index)).second
                        || source_energy[
                            static_cast<std::size_t>(raw_index)].string_or()
                            != string_arg(attachment, "card_id")
                        || !attached_energy_card_matches(
                            cards,
                            *selected_source,
                            static_cast<std::size_t>(raw_index),
                            filter
                        )
                    ) {
                        throw std::invalid_argument(
                            "energy_relocate_attachment_invalid"
                        );
                    }
                }
                Value continued = continuation;
                request_relocation_targets(
                    std::move(continued),
                    source_slot,
                    selected_options
                );
            } else {
                Value *source = pokemon(self, source_slot);
                if (source == nullptr) {
                    throw std::invalid_argument(
                        "energy_relocate_source_missing"
                    );
                }
                const Value &attachments = required(
                    continuation,
                    "selected_attachments"
                );
                const bool same_target = bool_arg(args, "same_target");
                const std::size_t expected_targets = same_target
                    ? 1
                    : attachments.as_array().size();
                if (
                    selected_options.as_array().size()
                    != expected_targets
                ) {
                    throw std::invalid_argument(
                        "energy_relocate_target_count"
                    );
                }
                std::vector<std::size_t> indices;
                std::unordered_set<std::size_t> unique_indices;
                for (const Value &entry : attachments.as_array()) {
                    const std::int64_t raw_index = integer_arg(
                        entry, "index", -1);
                    if (
                        !entry.is_object()
                        || string_arg(entry, "kind") != "attachment"
                        || string_arg(entry, "attachment_type") != "energy"
                        || integer_arg(entry, "player", -1) != actor
                        || string_arg(entry, "slot") != source_slot
                        || raw_index < 0
                        || !unique_indices.insert(
                            static_cast<std::size_t>(raw_index)).second
                    ) {
                        throw std::invalid_argument(
                            "energy_relocate_attachment_invalid"
                        );
                    }
                    indices.push_back(static_cast<std::size_t>(raw_index));
                }
                Array &source_energy = required(
                    *source,
                    "energy_card_ids"
                ).as_array();
                for (std::size_t index = 0; index < indices.size(); ++index) {
                    if (
                        indices[index] >= source_energy.size()
                        || source_energy[indices[index]].string_or()
                            != string_arg(
                                attachments.as_array()[index], "card_id")
                    ) {
                        throw std::invalid_argument(
                            "energy_relocate_attachment_stale"
                        );
                    }
                }
                std::vector<Value *> targets;
                targets.reserve(selected_options.as_array().size());
                for (const Value &target_option
                    : selected_options.as_array()) {
                    const std::string target_slot = string_arg(
                        target_option, "slot");
                    Value *target = pokemon(self, target_slot);
                    if (
                        target == nullptr
                        || target_slot == source_slot
                        || integer_arg(target_option, "player", -1) != actor
                        || string_arg(target_option, "card_id")
                            != string_arg(*target, "card_id")
                    ) {
                        throw std::invalid_argument(
                            "energy_relocate_target_missing"
                        );
                    }
                    targets.push_back(target);
                }
                Array moved;
                for (const std::size_t index : indices) {
                    moved.push_back(source_energy.at(index));
                }
                std::vector<std::size_t> removal_indices = indices;
                std::sort(
                    removal_indices.begin(),
                    removal_indices.end()
                );
                for (
                    auto index = removal_indices.rbegin();
                    index != removal_indices.rend();
                    ++index
                ) {
                    source_energy.erase(
                        source_energy.begin()
                            + static_cast<std::ptrdiff_t>(*index)
                    );
                }
                for (std::size_t index = 0; index < moved.size(); ++index) {
                    Value *target = targets[
                        same_target ? 0 : index];
                    required(
                        *target,
                        "energy_card_ids"
                    ).as_array().push_back(std::move(moved[index]));
                    result.event_types.emplace_back("energy_attached");
                }
            }
        } else if (op == "search_any_and_switch") {
            if (stage == 0) {
                if (selected_options.as_array().size() > 2) {
                    throw std::invalid_argument(
                        "search_selection_count_exceeded"
                    );
                }
                selected_zone_card_ids(
                    self,
                    selected_options,
                    "deck",
                    actor
                );
                std::vector<Value> removed = remove_selected(
                    self,
                    "deck",
                    selected_options
                );
                Array selected_ids = card_id_values(removed);
                Array &hand = required(self, "hand").as_array();
                for (Value &entry : removed) {
                    hand.push_back(std::move(entry));
                }
                append_card_zone_event(
                    result,
                    "cards_selected",
                    actor,
                    std::move(selected_ids),
                    "deck",
                    "hand",
                    "owner"
                );
                shuffle_array(required(self, "deck").as_array(), rng);
                result.event_types.emplace_back("deck_shuffled");
                if (pokemon_options(self, actor, false, true).empty()) {
                    result.success = true;
                    result.rng_state = rng.state();
                    early_return = true; return true;
                }
                Value continued = continuation;
                continued["stage"] = Value(1);
                next(
                    pending_request(
                        "confirm",
                        actor,
                        1,
                        1,
                        false,
                        false,
                        {id_option("confirm:yes"), id_option("confirm:no")},
                        "search_any_switch_confirm"
                    ),
                    std::move(continued)
                );
            } else if (stage == 1) {
                if (selected_confirmation(selected_options)) {
                    Array options = pokemon_options(
                        self,
                        actor,
                        false,
                        true
                    );
                    if (options.size() == 1) {
                        switch_active_with_event(
                            result,
                            self,
                            actor,
                            actor,
                            string_arg(options.front(), "slot"),
                            "search_any_and_switch"
                        );
                    } else if (!options.empty()) {
                        Value continued = continuation;
                        continued["stage"] = Value(2);
                        next(
                            pending_request(
                                "select_bench",
                                actor,
                                1,
                                1,
                                false,
                                false,
                                std::move(options),
                                "search_any_switch_bench"
                            ),
                            std::move(continued)
                        );
                    }
                }
            } else {
                switch_active_with_event(
                    result,
                    self,
                    actor,
                    actor,
                    selected_slot(selected_options),
                    "search_any_and_switch"
                );
            }
        } else if (op == "shuffle_from_discard_to_deck") {
            const std::string filter = string_arg(args, "filter", "any");
            const std::vector<std::string> selected_ids =
                selected_zone_card_ids(
                    self,
                    selected_options,
                    "discard",
                    actor
                );
            if (
                selected_ids.empty()
                || selected_ids.size()
                    > static_cast<std::size_t>(std::max<std::int64_t>(
                        0,
                        integer_arg(args, "count", 1)
                    ))
            ) {
                throw std::invalid_argument(
                    "shuffle_recovery_selection_count_invalid"
                );
            }
            for (const std::string &selected_id : selected_ids) {
                if (!card_matches_filter(cards, selected_id, filter)) {
                    throw std::invalid_argument(
                        "shuffle_recovery_filter_mismatch"
                    );
                }
            }
            std::vector<Value> removed = remove_selected(
                self,
                "discard",
                selected_options
            );
            Array returned_ids = card_id_values(removed);
            Array &deck = required(self, "deck").as_array();
            for (Value &entry : removed) {
                deck.push_back(std::move(entry));
            }
            if (!removed.empty()) {
                append_card_zone_event(
                    result,
                    "card_moved",
                    actor,
                    std::move(returned_ids),
                    "discard",
                    "deck",
                    "public"
                );
            }
            shuffle_array(deck, rng);
            result.event_types.emplace_back("deck_shuffled");
        } else if (op == "switch_pokemon") {
            const bool opponent_target = string_arg(
                args,
                "target",
                "self"
            ) == "opponent";
            Value &target = opponent_target ? opponent : self;
            if (bool_arg(args, "optional") && stage == 0) {
                if (selected_confirmation(selected_options)) {
                    Array options = pokemon_options(
                        target,
                        opponent_target ? 1 - actor : actor,
                        false,
                        true
                    );
                    if (options.size() == 1) {
                        switch_active_with_event(
                            result,
                            target,
                            actor,
                            opponent_target ? 1 - actor : actor,
                            string_arg(options.front(), "slot"),
                            "switch_pokemon"
                        );
                    } else if (!options.empty()) {
                        Value continued = continuation;
                        continued["stage"] = Value(1);
                        next(
                            pending_request(
                                "select_bench",
                                actor,
                                1,
                                1,
                                false,
                                false,
                                std::move(options),
                                "switch"
                            ),
                            std::move(continued)
                        );
                    }
                }
            } else {
                switch_active_with_event(
                    result,
                    target,
                    actor,
                    opponent_target ? 1 - actor : actor,
                    selected_slot(selected_options),
                    "switch_pokemon"
                );
            }
        } else if (op == "trekking_shoes") {
            Array &deck = required(self, "deck").as_array();
            if (!deck.empty()) {
                const std::int64_t source_index =
                    static_cast<std::int64_t>(deck.size() - 1);
                const std::string moved_card_id =
                    deck.back().string_or();
                if (selected_confirmation(selected_options)) {
                    Array &hand = required(self, "hand").as_array();
                    const std::int64_t target_index =
                        static_cast<std::int64_t>(hand.size());
                    hand.push_back(std::move(deck.back()));
                    append_event(
                        result,
                        "card_moved",
                        Object{
                            {"actor", Value(actor)},
                            {"visibility", Value("owner")},
                            {"card_id", Value(moved_card_id)},
                            {
                                "source",
                                Value(Object{
                                    {"player", Value(actor)},
                                    {"zone", Value("deck")},
                                    {"index", Value(source_index)},
                                }),
                            },
                            {
                                "target",
                                Value(Object{
                                    {"player", Value(actor)},
                                    {"zone", Value("hand")},
                                    {"index", Value(target_index)},
                                }),
                            },
                            {"amount", Value(1)},
                            {"player", Value(actor)},
                            {
                                "card_ids",
                                Value(Array{Value(moved_card_id)}),
                            },
                            {"count", Value(1)},
                            {"source_zone", Value("deck")},
                            {"source_index", Value(source_index)},
                            {"target_zone", Value("hand")},
                            {"target_index", Value(target_index)},
                        }
                    );
                } else {
                    Array &discard = required(self, "discard").as_array();
                    const std::int64_t target_index =
                        static_cast<std::int64_t>(discard.size());
                    discard.push_back(std::move(deck.back()));
                    deck.pop_back();
                    result.event_types.emplace_back("cards_discarded");
                    append_event(
                        result,
                        "cards_discarded",
                        Object{
                            {"actor", Value(actor)},
                            {"visibility", Value("public")},
                            {"card_id", Value(moved_card_id)},
                            {
                                "source",
                                Value(Object{
                                    {"player", Value(actor)},
                                    {"zone", Value("deck")},
                                    {"index", Value(source_index)},
                                }),
                            },
                            {
                                "target",
                                Value(Object{
                                    {"player", Value(actor)},
                                    {"zone", Value("discard")},
                                    {"index", Value(target_index)},
                                }),
                            },
                            {"amount", Value(1)},
                            {"player", Value(actor)},
                            {
                                "card_ids",
                                Value(Array{Value(moved_card_id)}),
                            },
                            {"count", Value(1)},
                            {"source_zone", Value("deck")},
                            {"source_index", Value(source_index)},
                            {"target_zone", Value("discard")},
                            {"target_index", Value(target_index)},
                        }
                    );
                    const auto drawn = draw_cards(self, 1);
                    if (!drawn.empty()) {
                        result.event_types.emplace_back("cards_drawn");
                        Array drawn_ids;
                        drawn_ids.reserve(drawn.size());
                        for (const std::string &card_id : drawn) {
                            drawn_ids.emplace_back(card_id);
                        }
                        append_event(
                            result,
                            "cards_drawn",
                            Object{
                                {"actor", Value(actor)},
                                {"visibility", Value("owner")},
                                {
                                    "source",
                                    Value(Object{
                                        {"player", Value(actor)},
                                        {"zone", Value("deck")},
                                    }),
                                },
                                {
                                    "target",
                                    Value(Object{
                                        {"player", Value(actor)},
                                        {"zone", Value("hand")},
                                    }),
                                },
                                {
                                    "amount",
                                    Value(static_cast<std::int64_t>(
                                        drawn.size()
                                    )),
                                },
                                {"player", Value(actor)},
                                {"card_ids", Value(std::move(drawn_ids))},
                                {
                                    "count",
                                    Value(static_cast<std::int64_t>(
                                        drawn.size()
                                    )),
                                },
                                {"source_zone", Value("deck")},
                                {"target_zone", Value("hand")},
                            }
                        );
                    }
                    result.success = true;
                    result.rng_state = rng.state();
                    early_return = true; return true;
                }
                deck.pop_back();
                result.event_types.emplace_back("card_moved");
            }
        } else if (op == "zinnia_resolve") {
            if (selected_options.as_array().size() != 2) {
                throw std::invalid_argument(
                    "zinnia_selection_count_invalid"
                );
            }
            selected_zone_card_ids(
                self,
                selected_options,
                "hand",
                actor
            );
            std::vector<Value> removed = remove_selected(
                self,
                "hand",
                selected_options
            );
            Array discarded_ids = card_id_values(removed);
            Array &discard = required(self, "discard").as_array();
            for (Value &entry : removed) {
                discard.push_back(std::move(entry));
            }
            if (!removed.empty()) {
                append_card_zone_event(
                    result,
                    "cards_discarded",
                    actor,
                    std::move(discarded_ids),
                    "hand",
                    "discard",
                    "public"
                );
            }
            const auto drawn = draw_cards(
                self,
                integer_arg(continuation, "draw_amount")
            );
            append_cards_drawn_event(result, actor, drawn, "zinnia");
        } else {
            throw std::invalid_argument("unsupported_native_resume_op");
        }

    return true;
}

} // namespace ptcg::ai::rules_detail
