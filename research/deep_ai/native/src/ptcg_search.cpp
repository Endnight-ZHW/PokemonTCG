#include "ptcg_search.hpp"

#include "ptcg_infoset.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <limits>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace ptcg::ai {

namespace {

using Array = Value::Array;
using Object = Value::Object;
using SearchClock = std::chrono::steady_clock;

std::uint64_t elapsed_microseconds(
    SearchClock::time_point started
) noexcept {
    return static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::microseconds>(
            SearchClock::now() - started
        ).count()
    );
}

struct SearchWorldMark {
    std::size_t journal_size = 0;
    UndoMark compact_mark{};
};

struct SearchWorld {
    Value state;
    Value pending = Value::make_object();
    Value continuation = Value::make_object();
    std::uint32_t rng_state = 0;
    bool pending_chance_recorded = false;

    SearchWorld(
        Value initial_state,
        Value initial_pending = Value::make_object(),
        Value initial_continuation = Value::make_object(),
        std::uint32_t initial_rng_state = 0,
        bool initial_pending_chance_recorded = false
    ) :
        state(std::move(initial_state)),
        pending(std::move(initial_pending)),
        continuation(std::move(initial_continuation)),
        rng_state(initial_rng_state),
        pending_chance_recorded(initial_pending_chance_recorded),
        compact_metadata_(4) {
        sync_compact_metadata();
        compact_metadata_.clear_journal();
    }

    SearchWorldMark mark() const noexcept {
        return SearchWorldMark{
            journal_.size(),
            compact_metadata_.mark(),
        };
    }

    void begin_transition() {
        journal_.push_back(JournalEntry{
            state,
            pending,
            continuation,
            rng_state,
            pending_chance_recorded,
        });
        ++journal_entry_count_;
    }

    void finish_transition() {
        sync_compact_metadata();
    }

    void undo(SearchWorldMark mark) {
        if (mark.journal_size > journal_.size()) {
            throw std::out_of_range("search_world_undo_mark_out_of_range");
        }
        while (journal_.size() > mark.journal_size) {
            JournalEntry &entry = journal_.back();
            state = std::move(entry.state);
            pending = std::move(entry.pending);
            continuation = std::move(entry.continuation);
            rng_state = entry.rng_state;
            pending_chance_recorded =
                entry.pending_chance_recorded;
            journal_.pop_back();
            ++undo_operation_count_;
        }
        compact_metadata_.undo(mark.compact_mark);
        verify_compact_metadata();
    }

    std::uint64_t journal_entry_count() const noexcept {
        return journal_entry_count_;
    }

    std::uint64_t undo_operation_count() const noexcept {
        return undo_operation_count_;
    }

private:
    struct JournalEntry {
        Value state;
        Value pending;
        Value continuation;
        std::uint32_t rng_state = 0;
        bool pending_chance_recorded = false;
    };

    static std::int64_t state_integer(
        const Value &source,
        const char *field,
        std::int64_t fallback
    ) noexcept {
        const Value *value = source.find(field);
        return value == nullptr
            ? fallback
            : value->as_integer(fallback);
    }

    void sync_compact_metadata() {
        compact_metadata_.set(
            0,
            static_cast<std::int32_t>(
                state_integer(state, "revision", 0)
            )
        );
        compact_metadata_.set(
            1,
            static_cast<std::int32_t>(
                state_integer(state, "active_player_idx", -1)
            )
        );
        compact_metadata_.set(
            2,
            static_cast<std::int32_t>(rng_state)
        );
        compact_metadata_.set(
            3,
            pending_chance_recorded ? 1 : 0
        );
    }

    void verify_compact_metadata() const {
        if (
            compact_metadata_.get(0)
                != static_cast<std::int32_t>(
                    state_integer(state, "revision", 0)
                )
            || compact_metadata_.get(1)
                != static_cast<std::int32_t>(
                    state_integer(state, "active_player_idx", -1)
                )
            || static_cast<std::uint32_t>(
                compact_metadata_.get(2)
            ) != rng_state
            || compact_metadata_.get(3)
                != (pending_chance_recorded ? 1 : 0)
        ) {
            throw std::runtime_error(
                "search_world_compact_metadata_diverged"
            );
        }
    }

    CompactState compact_metadata_;
    std::vector<JournalEntry> journal_;
    std::uint64_t journal_entry_count_ = 0;
    std::uint64_t undo_operation_count_ = 0;
};

struct PathEntry {
    std::uint64_t node_key = 0;
    std::size_t edge_index = 0;
    std::int32_t actor = 0;
};

struct ObservedChanceTransition {
    Value descriptor = Value::make_object();
    float probability = 1.0F;
    bool resolves_pending_coin = false;
};

class SimulationLease {
public:
    SimulationLease(
        std::shared_ptr<NativeSearchLimiter> limiter,
        const std::atomic<bool> &cancel_requested,
        const std::atomic<bool> &stop_requested
    ) :
        limiter_(std::move(limiter)),
        cancel_requested_(cancel_requested),
        stop_requested_(stop_requested) {}

    ~SimulationLease() {
        release();
    }

    bool acquire() {
        if (held_ || !limiter_) {
            return true;
        }
        held_ = limiter_->acquire(
            cancel_requested_,
            stop_requested_
        );
        return held_;
    }

    void release() noexcept {
        if (held_ && limiter_) {
            limiter_->release();
            held_ = false;
        }
    }

private:
    std::shared_ptr<NativeSearchLimiter> limiter_;
    const std::atomic<bool> &cancel_requested_;
    const std::atomic<bool> &stop_requested_;
    bool held_ = false;
};

std::uint64_t search_tree_key(
    const InformationSetProjection &projection,
    const SearchWorld &world
) {
    const bool choice = (
        world.pending.is_object()
        && !world.pending.as_object().empty()
    );
    const std::uint64_t decision_hash = choice
        ? stable_value_hash(world.pending)
        : 0xA37C10A5D18F43E9ULL;
    std::uint64_t key = projection.tree_key;
    key ^= decision_hash
        + 0x9E3779B97F4A7C15ULL
        + (key << 6U)
        + (key >> 2U);
    key ^= choice
        ? 0xC401CE5E7D2A91B3ULL
        : 0xAC710A5E48B326D1ULL;
    return key;
}

const Value &required(const Value &value, const std::string &key) {
    const Value *found = value.find(key);
    if (found == nullptr) {
        throw std::invalid_argument("search_missing_field:" + key);
    }
    return *found;
}

std::string string_field(
    const Value &value,
    const std::string &key,
    const std::string &fallback = {}
) {
    const Value *found = value.find(key);
    return found == nullptr ? fallback : found->string_or(fallback);
}

std::int64_t integer_field(
    const Value &value,
    const std::string &key,
    std::int64_t fallback = 0
) {
    const Value *found = value.find(key);
    return found == nullptr ? fallback : found->as_integer(fallback);
}

bool boolean_field(
    const Value &value,
    const std::string &key,
    bool fallback = false
) {
    const Value *found = value.find(key);
    return found == nullptr ? fallback : found->as_bool(fallback);
}

std::int32_t world_actor(const SearchWorld &world) {
    if (world.pending.is_object() && !world.pending.as_object().empty()) {
        return static_cast<std::int32_t>(
            integer_field(world.pending, "player", -1)
        );
    }
    const Value *promotions = world.state.find("pending_promotions");
    if (
        promotions != nullptr
        && promotions->is_array()
        && !promotions->as_array().empty()
    ) {
        return static_cast<std::int32_t>(
            promotions->as_array().front().as_integer(-1)
        );
    }
    if (string_field(world.state, "phase") == "SETUP") {
        return static_cast<std::int32_t>(
            integer_field(world.state, "setup_actor_idx", -1)
        );
    }
    return static_cast<std::int32_t>(
        integer_field(world.state, "active_player_idx", -1)
    );
}

bool terminal(const SearchWorld &world) {
    const std::string status = string_field(
        world.state,
        "result_status",
        "ONGOING"
    );
    return status != "ONGOING"
        || string_field(world.state, "phase") == "GAME_OVER";
}

float terminal_value(
    const SearchWorld &world,
    std::int32_t actor
) {
    const std::int64_t winner = integer_field(
        world.state,
        "winner",
        -1
    );
    if (winner < 0) {
        return 0.0F;
    }
    return winner == actor ? 1.0F : -1.0F;
}

Value selected_choice_values(
    const Value &request,
    const Value &candidate
);

const Value *choice_option_reference(const Value &option) {
    const Value *ref = option.find("ref");
    return ref != nullptr && ref->is_object() ? ref : &option;
}

std::optional<std::pair<std::int64_t, std::string>>
public_energy_option_identity(const Value &option) {
    const std::string option_id = string_field(option, "option_id");
    constexpr std::string_view prefix{"energy:"};
    if (option_id.rfind(prefix.data(), 0) != 0) {
        return std::nullopt;
    }
    const std::size_t index_end = option_id.find(':', prefix.size());
    const std::size_t identity_end = option_id.find("->", index_end);
    if (
        index_end == std::string::npos
        || identity_end == std::string::npos
        || identity_end <= index_end + 1
    ) {
        return std::nullopt;
    }
    try {
        std::size_t consumed = 0;
        const std::string raw_index = option_id.substr(
            prefix.size(), index_end - prefix.size()
        );
        const std::int64_t index = std::stoll(raw_index, &consumed);
        if (consumed != raw_index.size() || index < 0) {
            return std::nullopt;
        }
        return std::pair{
            index,
            option_id.substr(
                index_end + 1,
                identity_end - index_end - 1
            ),
        };
    } catch (const std::exception &) {
        return std::nullopt;
    }
}

void condition_on_revealed_choice(
    Value &state,
    const Value &pending,
    std::int32_t actor,
    const Value &continuation
) {
    if (!pending.is_object() || pending.as_object().empty()) {
        return;
    }
    if (integer_field(pending, "player", -1) != actor) {
        throw std::runtime_error("root_choice_actor_mismatch");
    }
    Value *players = state.find("players");
    if (
        players == nullptr
        || !players->is_array()
        || players->as_array().size() != 2
    ) {
        throw std::runtime_error("invalid_choice_condition_players");
    }
    Value &owner = players->as_array().at(
        static_cast<std::size_t>(actor)
    );
    Value *deck_value = owner.find("deck");
    Value *prizes_value = owner.find("prizes");
    if (
        deck_value == nullptr || !deck_value->is_array()
        || prizes_value == nullptr || !prizes_value->is_array()
    ) {
        throw std::runtime_error("invalid_choice_condition_zones");
    }
    Array &deck = deck_value->as_array();
    Array &prizes = prizes_value->as_array();
    struct Pin {
        bool prize = false;
        std::size_t index = 0;
        std::string card_id;
    };
    std::vector<Pin> pins;
    auto add_pin = [&pins, &deck, &prizes](
        const std::string &zone,
        std::int64_t raw_index,
        const std::string &card_id
    ) {
        const bool prize = zone == "prize" || zone == "prizes";
        if (zone != "deck" && !prize) {
            return;
        }
        const std::size_t size = prize ? prizes.size() : deck.size();
        if (
            raw_index < 0
            || static_cast<std::size_t>(raw_index) >= size
            || card_id.empty()
        ) {
            throw std::runtime_error("invalid_revealed_choice_pin");
        }
        const std::size_t index = static_cast<std::size_t>(raw_index);
        const auto existing = std::find_if(
            pins.begin(),
            pins.end(),
            [prize, index](const Pin &pin) {
                return pin.prize == prize && pin.index == index;
            }
        );
        if (existing != pins.end()) {
            if (existing->card_id != card_id) {
                throw std::runtime_error(
                    "conflicting_revealed_choice_pin"
                );
            }
            return;
        }
        pins.push_back({prize, index, card_id});
    };

    const Value *options = pending.find("options");
    if (options == nullptr || !options->is_array()) {
        throw std::runtime_error("invalid_root_choice_options");
    }
    for (const Value &option : options->as_array()) {
        if (!option.is_object()) {
            throw std::runtime_error("invalid_root_choice_option");
        }
        const Value *ref = choice_option_reference(option);
        if (
            ref == nullptr
            || !ref->is_object()
            || string_field(*ref, "kind") != "card"
        ) {
            continue;
        }
        if (integer_field(*ref, "player", actor) != actor) {
            throw std::runtime_error(
                "opponent_hidden_choice_reference_rejected"
            );
        }
        add_pin(
            string_field(*ref, "zone"),
            integer_field(*ref, "index", -1),
            string_field(*ref, "card_id")
        );
    }

    // Multi-stage look-top operations retain stage-one card selections inside
    // the VM continuation. Those identities are public to the actor (and are
    // mirrored in ChoiceView presentation/energy option ids), so a later
    // re-determinization must keep their referenced deck positions stable.
    const Value *vm = string_field(continuation, "kind") == "vm"
        ? continuation.find("vm") : nullptr;
    const std::string vm_op = vm != nullptr && vm->is_object()
        ? string_field(*vm, "op") : std::string{};
    const std::string request_type = string_field(pending, "request_type");
    const bool look_top_distribution = (
        vm_op == "look_top_deck" && request_type == "distribute_energy"
    );
    const bool look_top_target = (
        vm_op == "look_top_attach_energy"
        && request_type == "select_energy_target"
    );
    if (
        (look_top_distribution || look_top_target)
        && vm != nullptr && vm->is_object()
        && integer_field(*vm, "stage", -1) == 1
    ) {
        const Value *selected_cards = vm->find("selected_cards");
        if (
            selected_cards == nullptr || !selected_cards->is_array()
            || selected_cards->as_array().empty()
            || selected_cards->as_array().size() > 64
        ) {
            throw std::runtime_error(
                "invalid_look_top_continuation"
            );
        }
        std::unordered_map<std::int64_t, std::string> exposed_sources;
        if (look_top_distribution) {
            for (const Value &option : options->as_array()) {
                const auto identity = public_energy_option_identity(option);
                if (!identity.has_value() || identity->second.empty()) {
                    throw std::runtime_error(
                        "invalid_look_top_distribution_option"
                    );
                }
                const auto [existing, inserted] = exposed_sources.emplace(
                    identity->first,
                    identity->second
                );
                if (!inserted && existing->second != identity->second) {
                    throw std::runtime_error(
                        "conflicting_look_top_distribution_option"
                    );
                }
            }
        } else {
            const Value *presentation = pending.find("presentation");
            if (presentation == nullptr || !presentation->is_object()) {
                presentation = pending.find("metadata");
            }
            const Value *revealed = presentation != nullptr
                ? presentation->find("revealed_card_ids") : nullptr;
            if (
                revealed == nullptr || !revealed->is_array()
                || revealed->as_array().size()
                    != selected_cards->as_array().size()
            ) {
                throw std::runtime_error(
                    "invalid_look_top_target_presentation"
                );
            }
            for (std::size_t index = 0; index < revealed->as_array().size(); ++index) {
                exposed_sources.emplace(
                    static_cast<std::int64_t>(index),
                    revealed->as_array()[index].string_or()
                );
            }
        }
        if (exposed_sources.size() != selected_cards->as_array().size()) {
            throw std::runtime_error(
                    "look_top_source_count_mismatch"
            );
        }
        for (
            std::size_t ordinal = 0;
            ordinal < selected_cards->as_array().size();
            ++ordinal
        ) {
            const Value &selected = selected_cards->as_array()[ordinal];
            const std::string card_id = string_field(selected, "card_id");
            const auto exposed = exposed_sources.find(
                static_cast<std::int64_t>(ordinal)
            );
            if (
                !selected.is_object()
                || string_field(selected, "kind") != "card"
                || integer_field(selected, "player", -1) != actor
                || string_field(selected, "zone") != "deck"
                || exposed == exposed_sources.end()
                || exposed->second != card_id
            ) {
                throw std::runtime_error(
                    "look_top_source_mismatch"
                );
            }
            add_pin(
                "deck",
                integer_field(selected, "index", -1),
                card_id
            );
        }
    }

    const Value *metadata = pending.find("metadata");
    const Value *visible_continuation = (
        metadata != nullptr && metadata->is_object()
    ) ? metadata->find("continuation") : nullptr;
    const Value *top_ids = (
        visible_continuation != nullptr
        && visible_continuation->is_object()
    ) ? visible_continuation->find("top_card_ids") : nullptr;
    if (top_ids != nullptr) {
        if (
            !top_ids->is_array()
            || top_ids->as_array().size() > deck.size()
        ) {
            throw std::runtime_error("invalid_revealed_top_window");
        }
        for (
            std::size_t position = 0;
            position < top_ids->as_array().size();
            ++position
        ) {
            add_pin(
                "deck",
                static_cast<std::int64_t>(
                    deck.size() - 1 - position
                ),
                top_ids->as_array()[position].string_or()
            );
        }
    }
    std::vector<std::string> revealed_source_card_ids;
    const Value *revealed_source_zone = (
        visible_continuation != nullptr
        && visible_continuation->is_object()
    ) ? visible_continuation->find("revealed_source_zone") : nullptr;
    const Value *revealed_source_ids = (
        visible_continuation != nullptr
        && visible_continuation->is_object()
    ) ? visible_continuation->find(
        "revealed_source_card_ids"
    ) : nullptr;
    if (
        (revealed_source_zone == nullptr)
        != (revealed_source_ids == nullptr)
    ) {
        throw std::runtime_error(
            "incomplete_revealed_source_context"
        );
    }
    if (revealed_source_zone != nullptr) {
        if (
            revealed_source_zone->string_or() != "deck"
            || revealed_source_ids == nullptr
            || !revealed_source_ids->is_array()
            || revealed_source_ids->as_array().empty()
            || revealed_source_ids->as_array().size() > 64
            || string_field(pending, "request_type")
                != "distribute_energy"
        ) {
            throw std::runtime_error(
                "invalid_revealed_source_context"
            );
        }
        std::unordered_map<std::int64_t, std::string>
            option_energy_by_index;
        for (const Value &option : options->as_array()) {
            const Value *value = option.find("value");
            if (value == nullptr || !value->is_object()) {
                throw std::runtime_error(
                    "invalid_revealed_source_option"
                );
            }
            const std::int64_t energy_index = integer_field(
                *value,
                "energy_index",
                -1
            );
            const std::string energy_card_id = string_field(
                *value,
                "energy_card_id"
            );
            if (
                energy_index < 0
                || energy_card_id.empty()
            ) {
                throw std::runtime_error(
                    "invalid_revealed_source_option"
                );
            }
            const auto [existing, inserted] =
                option_energy_by_index.emplace(
                    energy_index,
                    energy_card_id
                );
            if (
                !inserted
                && existing->second != energy_card_id
            ) {
                throw std::runtime_error(
                    "conflicting_revealed_source_option"
                );
            }
        }
        revealed_source_card_ids.reserve(
            revealed_source_ids->as_array().size()
        );
        for (
            std::size_t index = 0;
            index < revealed_source_ids->as_array().size();
            ++index
        ) {
            const std::string card_id =
                revealed_source_ids->as_array()[index].string_or();
            const auto option = option_energy_by_index.find(
                static_cast<std::int64_t>(index)
            );
            if (
                card_id.empty()
                || option == option_energy_by_index.end()
                || option->second != card_id
            ) {
                throw std::runtime_error(
                    "revealed_source_option_mismatch"
                );
            }
            revealed_source_card_ids.push_back(card_id);
        }
        if (
            option_energy_by_index.size()
                != revealed_source_card_ids.size()
        ) {
            throw std::runtime_error(
                "revealed_source_option_index_gap"
            );
        }
    }
    // Native VM attach_energy requests publish the selected deck-energy
    // multiset directly in pending metadata (or ChoiceView presentation),
    // rather than in the compatibility continuation wrapper above.  Once the
    // decision actor changes, re-determinization may otherwise move one of
    // those now-public sources into prizes and make a legal choice fail.
    const Value *distribution_context = (
        metadata != nullptr && metadata->is_object()
    ) ? metadata : pending.find("presentation");
    if (
        revealed_source_card_ids.empty()
        && request_type == "distribute_energy"
        && distribution_context != nullptr
        && distribution_context->is_object()
        && string_field(*distribution_context, "source_zone") == "deck"
    ) {
        if (
            integer_field(*distribution_context, "source_player", actor)
                != actor
        ) {
            throw std::runtime_error(
                "revealed_distribution_source_actor_mismatch"
            );
        }
        const Value *source_ids = distribution_context->find("card_ids");
        if (source_ids == nullptr) {
            source_ids = distribution_context->find("revealed_card_ids");
        }
        if (
            source_ids == nullptr || !source_ids->is_array()
            || source_ids->as_array().empty()
            || source_ids->as_array().size() > 64
        ) {
            throw std::runtime_error(
                "invalid_revealed_distribution_sources"
            );
        }
        std::unordered_map<std::int64_t, std::string>
            option_energy_by_index;
        for (const Value &option : options->as_array()) {
            const auto identity = public_energy_option_identity(option);
            if (!identity.has_value() || identity->second.empty()) {
                throw std::runtime_error(
                    "invalid_revealed_distribution_option"
                );
            }
            const auto [existing, inserted] =
                option_energy_by_index.emplace(
                    identity->first,
                    identity->second
                );
            if (!inserted && existing->second != identity->second) {
                throw std::runtime_error(
                    "conflicting_revealed_distribution_option"
                );
            }
        }
        for (
            std::size_t index = 0;
            index < source_ids->as_array().size();
            ++index
        ) {
            const std::string card_id =
                source_ids->as_array()[index].string_or();
            const auto option = option_energy_by_index.find(
                static_cast<std::int64_t>(index)
            );
            if (
                card_id.empty()
                || option == option_energy_by_index.end()
                || option->second != card_id
            ) {
                throw std::runtime_error(
                    "revealed_distribution_option_mismatch"
                );
            }
            revealed_source_card_ids.push_back(card_id);
        }
        if (
            option_energy_by_index.size()
                != revealed_source_card_ids.size()
        ) {
            throw std::runtime_error(
                "revealed_distribution_option_index_gap"
            );
        }
    }
    if (
        string_field(pending, "request_type")
            == "select_prize_energy_target"
    ) {
        if (
            !continuation.is_object()
            || string_field(continuation, "kind")
                != "treasure_prize_target"
            || integer_field(continuation, "actor", -1) != actor
        ) {
            throw std::runtime_error(
                "invalid_revealed_prize_context"
            );
        }
        add_pin(
            "prizes",
            integer_field(continuation, "prize_index", -1),
            string_field(continuation, "prize_card_id")
        );
    }

    std::vector<Value *> slots;
    slots.reserve(deck.size() + prizes.size());
    for (Value &entry : deck) {
        slots.push_back(&entry);
    }
    for (Value &entry : prizes) {
        slots.push_back(&entry);
    }
    std::vector<bool> fixed(slots.size(), false);
    for (const Pin &pin : pins) {
        const std::size_t target = pin.prize
            ? deck.size() + pin.index
            : pin.index;
        if (slots[target]->string_or() == pin.card_id) {
            fixed[target] = true;
            continue;
        }
        std::size_t source = slots.size();
        for (std::size_t index = 0; index < slots.size(); ++index) {
            if (
                !fixed[index]
                && slots[index]->string_or() == pin.card_id
            ) {
                source = index;
                break;
            }
        }
        if (source >= slots.size()) {
            throw std::runtime_error(
                "revealed_choice_card_missing_from_determinization"
            );
        }
        std::swap(*slots[target], *slots[source]);
        fixed[target] = true;
    }

    // Energy distribution choices expose matching source identities but use
    // Pokemon references as their selectable options.  Preserve only the
    // revealed multiset (not original deck positions) in every compatible
    // determinization so a selected source cannot disappear into prizes.
    std::unordered_map<std::string, std::size_t> required_counts;
    for (const std::string &card_id : revealed_source_card_ids) {
        ++required_counts[card_id];
    }
    for (const auto &[card_id, required_count] : required_counts) {
        auto deck_count = [&deck, &card_id]() {
            return static_cast<std::size_t>(std::count_if(
                deck.begin(),
                deck.end(),
                [&card_id](const Value &entry) {
                    return entry.string_or() == card_id;
                }
            ));
        };
        while (deck_count() < required_count) {
            std::size_t source = slots.size();
            for (
                std::size_t index = deck.size();
                index < slots.size();
                ++index
            ) {
                if (
                    !fixed[index]
                    && slots[index]->string_or() == card_id
                ) {
                    source = index;
                    break;
                }
            }
            if (source >= slots.size()) {
                throw std::runtime_error(
                    "revealed_source_card_missing_from_determinization"
                );
            }
            std::size_t target = deck.size();
            for (
                std::size_t index = 0;
                index < deck.size();
                ++index
            ) {
                if (fixed[index]) {
                    continue;
                }
                const std::string current = slots[index]->string_or();
                const auto required = required_counts.find(current);
                const std::size_t current_required = (
                    required == required_counts.end()
                ) ? 0 : required->second;
                const std::size_t current_count =
                    static_cast<std::size_t>(std::count_if(
                        deck.begin(),
                        deck.end(),
                        [&current](const Value &entry) {
                            return entry.string_or() == current;
                        }
                    ));
                if (current_count > current_required) {
                    target = index;
                    break;
                }
            }
            if (target >= deck.size()) {
                throw std::runtime_error(
                    "revealed_source_deck_capacity_exhausted"
                );
            }
            std::swap(*slots[target], *slots[source]);
            fixed[target] = true;
        }
    }
}

Value candidates(
    const NativeGameKernel &game,
    const SearchWorld &world,
    std::int32_t actor
) {
    if (
        !world.pending.is_object()
        || world.pending.as_object().empty()
    ) {
        return game.legal_actions(world.state, actor);
    }
    const Value rows = NativeGameKernel::choice_candidates(world.pending);
    Array valid;
    valid.reserve(rows.as_array().size());
    const bool authoritative_root_candidates = (
        world.pending.find("allowed_candidates") != nullptr
    );
    for (const Value &candidate : rows.as_array()) {
        const GameExecutionResult transition = game.resume_choice(
            world.state,
            world.continuation,
            selected_choice_values(world.pending, candidate),
            boolean_field(candidate, "cancelled"),
            world.rng_state
        );
        if (transition.success) {
            valid.push_back(candidate);
        } else if (authoritative_root_candidates) {
            throw std::runtime_error(
                "authoritative_choice_transition_failed:"
                + string_field(candidate, "signature")
                + ":" + transition.error_code
            );
        }
    }
    return Value(std::move(valid));
}

const Value *pending_coin_flips(const SearchWorld &world) {
    if (
        string_field(world.pending, "request_type")
            != "coin_flip"
        || !world.continuation.is_object()
        || string_field(world.continuation, "kind") != "vm"
    ) {
        return nullptr;
    }
    const Value *vm = world.continuation.find("vm");
    const Value *flips = (
        vm != nullptr && vm->is_object()
    ) ? vm->find("flips") : nullptr;
    return (
        flips != nullptr
        && flips->is_array()
        && !flips->as_array().empty()
    ) ? flips : nullptr;
}

const Value *chance_flips(const SearchWorld &world) {
    return world.pending_chance_recorded
        ? nullptr
        : pending_coin_flips(world);
}

Value chance_candidates(
    const SearchWorld &world,
    Value candidate_rows
) {
    const Value *flips = chance_flips(world);
    if (
        flips == nullptr
        || !candidate_rows.is_array()
        || candidate_rows.as_array().size() != 1
    ) {
        throw std::runtime_error("invalid_coin_chance_node");
    }
    Value &candidate = candidate_rows.as_array().front();
    candidate["chance_outcome"] = *flips;
    candidate["chance_probability"] = Value(std::ldexp(
        1.0,
        -static_cast<int>(flips->as_array().size())
    ));
    return candidate_rows;
}

bool contains_event(
    const std::vector<std::string> &events,
    const std::string &event_type
) {
    return std::find(
        events.begin(),
        events.end(),
        event_type
    ) != events.end();
}

std::optional<std::size_t> rng_advance_count(
    std::uint32_t previous_rng_state,
    std::uint32_t current_rng_state,
    std::size_t maximum
) {
    XorShift32 replay(previous_rng_state);
    for (std::size_t count = 1; count <= maximum; ++count) {
        replay.next_u32();
        if (replay.state() == current_rng_state) {
            return count;
        }
    }
    return std::nullopt;
}

std::optional<ObservedChanceTransition> observe_random_transition(
    const GameExecutionResult &result,
    std::uint32_t previous_rng_state,
    std::int32_t actor
) {
    if (result.rng_state == previous_rng_state) {
        return std::nullopt;
    }
    SearchWorld projected_world{
        result.state,
        result.pending,
        result.continuation,
        result.rng_state,
        false,
    };
    const Value *flips = pending_coin_flips(projected_world);
    const bool coin_event = contains_event(
        result.event_types,
        "coin_flip"
    );
    const bool shuffle_event = contains_event(
        result.event_types,
        "deck_shuffled"
    );
    const bool checkup_event = contains_event(
        result.event_types,
        "checkup"
    );
    if (
        flips == nullptr
        && !coin_event
        && !shuffle_event
        && !checkup_event
    ) {
        std::ostringstream details;
        details << "unclassified_random_transition:events=";
        for (std::size_t index = 0;
             index < result.event_types.size();
             ++index) {
            if (index > 0) {
                details << ",";
            }
            details << result.event_types[index];
        }
        details
            << ":pending="
            << string_field(result.pending, "request_type")
            << ":continuation="
            << string_field(result.continuation, "kind")
            << ":phase="
            << string_field(result.state, "phase");
        throw std::runtime_error(details.str());
    }

    ObservedChanceTransition observed;
    Object descriptor;
    if (flips != nullptr) {
        descriptor["kind"] = Value("coin_sequence");
        descriptor["chance_outcome"] = *flips;
        observed.probability = static_cast<float>(std::ldexp(
            1.0,
            -static_cast<int>(flips->as_array().size())
        ));
        observed.resolves_pending_coin = true;
    } else if (coin_event && !shuffle_event) {
        descriptor["kind"] = Value("confusion_coin");
        descriptor["chance_outcome"] = Value(
            contains_event(result.event_types, "confusion_failed")
                ? "tails"
                : "heads"
        );
        observed.probability = 0.5F;
    } else if (checkup_event && !coin_event && !shuffle_event) {
        const std::optional<std::size_t> flip_count =
            rng_advance_count(
                previous_rng_state,
                result.rng_state,
                4
            );
        if (!flip_count.has_value()) {
            throw std::runtime_error(
                "invalid_status_check_random_transition"
            );
        }
        descriptor["kind"] = Value("status_check");
        const InformationSetProjection projection =
            project_information_set(result.state, actor);
        descriptor["observable_outcome_hash"] = Value(
            static_cast<std::int64_t>(projection.tree_key)
        );
        descriptor["flip_count"] = Value(
            static_cast<std::int64_t>(*flip_count)
        );
        observed.probability = static_cast<float>(std::ldexp(
            1.0,
            -static_cast<int>(*flip_count)
        ));
    } else {
        descriptor["kind"] = Value(
            coin_event ? "compound_random_transition" : "hidden_shuffle"
        );
        const InformationSetProjection projection =
            project_information_set(result.state, actor);
        descriptor["observable_outcome_hash"] = Value(
            static_cast<std::int64_t>(projection.tree_key)
        );
        // Hidden permutations that produce the same actor information set are
        // one sampled observation-equivalence outcome. Search never selects
        // this edge; its visits are driven by the RNG samples themselves.
        observed.probability = 1.0F;
    }
    descriptor["chance_probability"] = Value(
        static_cast<double>(observed.probability)
    );
    observed.descriptor = Value(std::move(descriptor));
    return observed;
}

std::uint64_t chance_tree_key(
    std::uint64_t parent_key,
    std::uint64_t candidate_signature
) noexcept {
    std::uint64_t key = parent_key ^ 0xC84A71CE91D50B7FULL;
    key ^= candidate_signature
        + 0x9E3779B97F4A7C15ULL
        + (key << 6U)
        + (key >> 2U);
    return key;
}

void append_observed_chance(
    PuctTree &tree,
    std::unordered_set<std::uint64_t> &chance_node_keys,
    std::vector<PathEntry> &path,
    std::uint64_t parent_key,
    std::uint64_t candidate_signature,
    std::int32_t actor,
    const ObservedChanceTransition &observed
) {
    const std::uint64_t key = chance_tree_key(
        parent_key,
        candidate_signature
    );
    PuctNode &node = tree.node(key, actor);
    const std::size_t edge_index = node.ensure_edge(
        stable_value_hash(observed.descriptor),
        observed.probability
    );
    chance_node_keys.insert(key);
    path.push_back({key, edge_index, actor});
}

std::string choice_option_id(
    const Value &request,
    const Value &option
) {
    std::string result = string_field(option, "option_id");
    if (!result.empty()) {
        return result;
    }
    const Value *ref = choice_option_reference(option);
    const std::string kind = string_field(*ref, "kind");
    const std::int64_t player_index = integer_field(
        *ref,
        "player",
        integer_field(request, "player", -1)
    );
    if (
        string_field(request, "request_type")
            == "select_retreat_payment"
    ) {
        return "retreat:energy:" + std::to_string(
            integer_field(*ref, "index", -1)
        );
    }
    if (kind == "card") {
        return "card:" + std::to_string(player_index)
            + ":" + string_field(*ref, "zone")
            + ":" + std::to_string(integer_field(*ref, "index", -1))
            + ":" + string_field(*ref, "card_id");
    }
    if (kind == "pokemon") {
        return "pokemon:" + std::to_string(player_index)
            + ":" + string_field(*ref, "slot")
            + ":" + string_field(*ref, "card_id");
    }
    if (kind == "slot") {
        return "slot:" + std::to_string(player_index)
            + ":" + string_field(*ref, "slot");
    }
    if (kind == "attachment") {
        return "attachment:" + std::to_string(player_index)
            + ":" + string_field(*ref, "slot")
            + ":" + string_field(*ref, "attachment_type")
            + ":" + std::to_string(integer_field(*ref, "index", -1))
            + ":" + string_field(*ref, "card_id");
    }
    return {};
}

Value selected_choice_values(
    const Value &request,
    const Value &candidate
) {
    const Value &selected_ids = required(
        candidate,
        "selected_options"
    );
    const Value &options = required(request, "options");
    if (!selected_ids.is_array() || !options.is_array()) {
        throw std::runtime_error("invalid_search_choice_payload");
    }
    Array selected;
    selected.reserve(selected_ids.as_array().size());
    for (const Value &selected_id : selected_ids.as_array()) {
        const std::string id = selected_id.string_or();
        const auto found = std::find_if(
            options.as_array().begin(),
            options.as_array().end(),
            [&request, &id](const Value &option) {
                return (
                    option.is_object()
                    && choice_option_id(request, option) == id
                );
            }
        );
        if (found == options.as_array().end()) {
            throw std::runtime_error("search_choice_option_stale");
        }
        Value resolved = *found;
        const Value *ref = found->find("ref");
        const Value *option_value = found->find("value");
        if (ref != nullptr && ref->is_object()) {
            Value::Object flattened;
            if (option_value != nullptr && option_value->is_object()) {
                flattened = option_value->as_object();
            }
            for (const auto &[key, value] : ref->as_object()) {
                flattened[key] = value;
            }
            flattened["option_id"] = Value(id);
            resolved = Value(std::move(flattened));
        }
        selected.push_back(std::move(resolved));
    }
    return Value(std::move(selected));
}

void condition_on_selected_candidate(
    Value &state,
    const Value &pending,
    const Value &candidate
) {
    const Value selected = selected_choice_values(pending, candidate);
    if (!selected.is_array()) return;
    Value *players = state.find("players");
    if (
        players == nullptr || !players->is_array()
        || players->as_array().size() != 2
    ) {
        throw std::runtime_error("invalid_candidate_condition_players");
    }
    for (const Value &option : selected.as_array()) {
        if (!option.is_object() || string_field(option, "kind") != "card") {
            continue;
        }
        const std::int64_t owner = integer_field(option, "player", -1);
        std::string zone = string_field(option, "zone");
        if (zone == "prize") zone = "prizes";
        const std::int64_t raw_index = integer_field(option, "index", -1);
        const std::string card_id = string_field(option, "card_id");
        if (
            owner < 0 || owner > 1 || raw_index < 0 || card_id.empty()
            || (
                zone != "hand" && zone != "deck"
                && zone != "discard" && zone != "prizes"
            )
        ) {
            throw std::runtime_error("invalid_selected_card_condition");
        }
        Value &owner_row = players->as_array().at(
            static_cast<std::size_t>(owner)
        );
        Value *zone_value = owner_row.find(zone);
        if (zone_value == nullptr || !zone_value->is_array()) {
            throw std::runtime_error("invalid_selected_card_zone");
        }
        Array &cards = zone_value->as_array();
        const std::size_t index = static_cast<std::size_t>(raw_index);
        if (index >= cards.size()) {
            throw std::runtime_error("selected_card_condition_out_of_range");
        }
        if (cards[index].string_or() == card_id) continue;
        const auto found = std::find_if(
            cards.begin(),
            cards.end(),
            [&card_id](const Value &value) {
                return value.string_or() == card_id;
            }
        );
        if (found == cards.end()) {
            throw std::runtime_error(
                "selected_card_condition_identity_unavailable"
            );
        }
        std::swap(cards[index], *found);
    }
}

void condition_on_action_candidate(
    Value &state,
    const Value &candidate
) {
    Value *players = state.find("players");
    if (
        players == nullptr || !players->is_array()
        || players->as_array().size() != 2
    ) {
        throw std::runtime_error("invalid_action_condition_players");
    }
    for (const char *field : {"source", "target"}) {
        const Value *reference = candidate.find(field);
        if (
            reference == nullptr || !reference->is_object()
            || string_field(*reference, "kind") != "card"
        ) {
            continue;
        }
        const std::int64_t owner = integer_field(*reference, "player", -1);
        std::string zone = string_field(*reference, "zone");
        if (zone == "prize") zone = "prizes";
        const std::int64_t raw_index = integer_field(*reference, "index", -1);
        const std::string card_id = string_field(*reference, "card_id");
        if (
            owner < 0 || owner > 1 || raw_index < 0 || card_id.empty()
            || (
                zone != "hand" && zone != "deck"
                && zone != "discard" && zone != "prizes"
            )
        ) {
            continue;
        }
        Value &owner_row = players->as_array().at(
            static_cast<std::size_t>(owner)
        );
        Value *zone_value = owner_row.find(zone);
        if (zone_value == nullptr || !zone_value->is_array()) {
            throw std::runtime_error("invalid_action_card_zone");
        }
        Array &cards = zone_value->as_array();
        const std::size_t index = static_cast<std::size_t>(raw_index);
        if (index >= cards.size()) {
            throw std::runtime_error("action_card_condition_out_of_range");
        }
        if (cards[index].string_or() == card_id) continue;
        const auto found = std::find_if(
            cards.begin(),
            cards.end(),
            [&card_id](const Value &value) {
                return value.string_or() == card_id;
            }
        );
        if (found == cards.end()) {
            throw std::runtime_error(
                "action_card_condition_identity_unavailable"
            );
        }
        std::swap(cards[index], *found);
    }
}

std::optional<ObservedChanceTransition> apply_candidate(
    const NativeGameKernel &game,
    SearchWorld &world,
    const Value &candidate,
    std::int32_t actor,
    std::uint64_t *elapsed = nullptr
) {
    const SearchClock::time_point started = SearchClock::now();
    world.begin_transition();
    const std::uint32_t previous_rng_state = world.rng_state;
    GameExecutionResult result;
    if (string_field(candidate, "kind") == "choice") {
        condition_on_selected_candidate(
            world.state,
            world.pending,
            candidate
        );
        result = game.resume_choice(
            std::move(world.state),
            world.continuation,
            selected_choice_values(world.pending, candidate),
            boolean_field(candidate, "cancelled"),
            world.rng_state
        );
    } else {
        condition_on_action_candidate(world.state, candidate);
        result = game.apply_action(
            std::move(world.state),
            candidate,
            world.rng_state
        );
    }
    if (!result.success) {
        const Value *vm = world.continuation.find("vm");
        throw std::runtime_error(
            "search_transition_failed:" + result.error_code
            + ":candidate_kind=" + string_field(candidate, "kind")
            + ":request_type=" + string_field(
                world.pending,
                "request_type",
                "action"
            )
            + ":continuation_kind=" + string_field(
                world.continuation,
                "kind",
                "none"
            )
            + ":source_zone=" + string_field(
                world.continuation,
                "source_zone",
                "none"
            )
            + ":vm_op=" + (
                vm != nullptr && vm->is_object()
                    ? string_field(*vm, "op", "none") : "none"
            )
            + ":vm_stage=" + std::to_string(
                vm != nullptr && vm->is_object()
                    ? integer_field(*vm, "stage", -1) : -1
            )
        );
    }
    std::optional<ObservedChanceTransition> observed =
        observe_random_transition(
            result,
            previous_rng_state,
            actor
        );
    world.state = std::move(result.state);
    world.pending = std::move(result.pending);
    world.continuation = std::move(result.continuation);
    world.rng_state = result.rng_state;
    world.pending_chance_recorded = (
        observed.has_value()
        && observed->resolves_pending_coin
    );
    world.finish_transition();
    if (elapsed != nullptr) {
        *elapsed += elapsed_microseconds(started);
    }
    return observed;
}

std::vector<std::uint64_t> candidate_signatures(
    const Value &candidate_rows
) {
    std::vector<std::uint64_t> result;
    result.reserve(candidate_rows.as_array().size());
    for (const Value &candidate : candidate_rows.as_array()) {
        result.push_back(stable_value_hash(candidate));
    }
    return result;
}

std::string describe_candidates(const Value &candidate_rows) {
    if (!candidate_rows.is_array()) {
        return "not_array";
    }
    std::ostringstream output;
    for (std::size_t index = 0;
         index < candidate_rows.as_array().size();
         ++index) {
        if (index > 0) {
            output << ",";
        }
        const Value &row = candidate_rows.as_array()[index];
        output << string_field(row, "kind");
        const Value *source = row.find("source");
        if (source != nullptr && source->is_object()) {
            output
                << "@"
                << string_field(*source, "zone")
                << ":"
                << integer_field(*source, "index", -1)
                << ":"
                << string_field(*source, "card_id");
        }
        const Value *target = row.find("target");
        if (target != nullptr && target->is_object()) {
            output << ">" << string_field(*target, "slot");
        }
        output << "#" << stable_value_hash(row);
    }
    return output.str();
}

double normal_sample(XorShift32 &rng) {
    const double first = std::max<double>(
        rng.next_unit(),
        1.0e-12
    );
    const double second = rng.next_unit();
    return std::sqrt(-2.0 * std::log(first))
        * std::cos(6.28318530717958647692 * second);
}

double gamma_sample(double shape, XorShift32 &rng) {
    if (!(shape > 0.0) || !std::isfinite(shape)) {
        throw std::invalid_argument("invalid_dirichlet_alpha");
    }
    if (shape < 1.0) {
        const double uniform = std::max<double>(
            rng.next_unit(),
            1.0e-12
        );
        return gamma_sample(shape + 1.0, rng)
            * std::pow(uniform, 1.0 / shape);
    }
    const double d = shape - 1.0 / 3.0;
    const double c = 1.0 / std::sqrt(9.0 * d);
    while (true) {
        const double x = normal_sample(rng);
        const double factor = 1.0 + c * x;
        if (factor <= 0.0) {
            continue;
        }
        const double v = factor * factor * factor;
        const double uniform = rng.next_unit();
        if (
            uniform < 1.0 - 0.0331 * x * x * x * x
            || std::log(std::max(uniform, 1.0e-12))
                < 0.5 * x * x
                    + d * (1.0 - v + std::log(v))
        ) {
            return d * v;
        }
    }
}

void add_root_noise(
    std::vector<float> &priors,
    float epsilon,
    XorShift32 &rng
) {
    if (priors.empty() || epsilon <= 0.0F) {
        return;
    }
    const double alpha = std::clamp(
        10.0 / static_cast<double>(priors.size()),
        0.03,
        0.30
    );
    std::vector<double> noise(priors.size());
    double total = 0.0;
    for (double &value : noise) {
        value = gamma_sample(alpha, rng);
        total += value;
    }
    if (!(total > 0.0) || !std::isfinite(total)) {
        throw std::runtime_error("invalid_dirichlet_sample");
    }
    for (std::size_t index = 0; index < priors.size(); ++index) {
        priors[index] = (1.0F - epsilon) * priors[index]
            + epsilon * static_cast<float>(noise[index] / total);
    }
}

std::size_t select_legal_edge(
    const PuctNode &node,
    const std::unordered_map<std::uint64_t, std::size_t> &current,
    float c_puct
) {
    std::uint64_t total_visits = 0;
    for (std::size_t index = 0; index < node.size(); ++index) {
        const PuctCandidate &edge = node.edge(index);
        if (current.find(edge.signature) != current.end()) {
            total_visits += edge.selection_visits();
        }
    }
    const float scale = std::sqrt(
        static_cast<float>(std::max<std::uint64_t>(1, total_visits))
    );
    std::size_t selected = node.size();
    float best = -std::numeric_limits<float>::infinity();
    for (std::size_t index = 0; index < node.size(); ++index) {
        const PuctCandidate &edge = node.edge(index);
        if (current.find(edge.signature) == current.end()) {
            continue;
        }
        const float score = edge.selection_q()
            + c_puct * edge.prior * scale
                / static_cast<float>(1 + edge.selection_visits());
        if (
            selected == node.size()
            || score > best
            || (
                score == best
                && edge.signature < node.edge(selected).signature
            )
        ) {
            selected = index;
            best = score;
        }
    }
    if (selected == node.size()) {
        throw std::runtime_error("tree_legal_set_diverged");
    }
    return selected;
}

void reserve_path(
    PuctTree &tree,
    const std::vector<PathEntry> &path
) {
    for (const PathEntry &entry : path) {
        tree.node(entry.node_key, entry.actor).reserve(entry.edge_index);
    }
}

void release_path(
    PuctTree &tree,
    const std::vector<PathEntry> &path
) {
    for (auto entry = path.rbegin(); entry != path.rend(); ++entry) {
        tree.node(entry->node_key, entry->actor).release(
            entry->edge_index
        );
    }
}

void backup(
    PuctTree &tree,
    const std::vector<PathEntry> &path,
    float value,
    std::int32_t value_actor
) {
    if (!std::isfinite(value)) {
        throw std::invalid_argument("non_finite_leaf_value");
    }
    for (auto entry = path.rbegin(); entry != path.rend(); ++entry) {
        PuctNode &node = tree.node(entry->node_key, entry->actor);
        node.backup(
            entry->edge_index,
            entry->actor == value_actor ? value : -value
        );
    }
}

std::vector<float> visit_distribution(
    const PuctNode &node,
    float temperature
) {
    std::vector<float> result(node.size(), 0.0F);
    if (temperature <= 1.0e-6F) {
        std::size_t selected = 0;
        for (std::size_t index = 1; index < node.size(); ++index) {
            if (
                node.edge(index).visits > node.edge(selected).visits
                || (
                    node.edge(index).visits
                        == node.edge(selected).visits
                    && node.edge(index).signature
                        < node.edge(selected).signature
                )
            ) {
                selected = index;
            }
        }
        result[selected] = 1.0F;
        return result;
    }
    const double inverse = 1.0 / temperature;
    double total = 0.0;
    for (std::size_t index = 0; index < node.size(); ++index) {
        result[index] = static_cast<float>(std::pow(
            static_cast<double>(node.edge(index).visits),
            inverse
        ));
        total += result[index];
    }
    if (!(total > 0.0)) {
        const float uniform = 1.0F / static_cast<float>(node.size());
        std::fill(result.begin(), result.end(), uniform);
        return result;
    }
    for (float &probability : result) {
        probability = static_cast<float>(probability / total);
    }
    return result;
}

std::size_t sample_distribution(
    const std::vector<float> &probabilities,
    XorShift32 &rng
) {
    const float target = rng.next_unit();
    float cumulative = 0.0F;
    for (std::size_t index = 0; index < probabilities.size(); ++index) {
        cumulative += probabilities[index];
        if (target < cumulative) {
            return index;
        }
    }
    return probabilities.size() - 1;
}

} // namespace

NativeSearchLimiter::NativeSearchLimiter(std::size_t capacity)
    : capacity_(capacity) {
    if (capacity == 0) {
        throw std::invalid_argument("native_search_limiter_empty");
    }
}

bool NativeSearchLimiter::acquire(
    const std::atomic<bool> &cancel_requested,
    const std::atomic<bool> &stop_requested
) {
    std::unique_lock<std::mutex> lock(mutex_);
    while (
        active_ >= capacity_
        && !cancel_requested.load()
        && !stop_requested.load()
    ) {
        available_.wait_for(lock, std::chrono::milliseconds(2));
    }
    if (cancel_requested.load() || stop_requested.load()) {
        return false;
    }
    ++active_;
    max_active_ = std::max(max_active_, active_);
    return true;
}

void NativeSearchLimiter::release() noexcept {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (active_ == 0) {
            std::terminate();
        }
        --active_;
    }
    available_.notify_one();
}

std::size_t NativeSearchLimiter::capacity() const noexcept {
    return capacity_;
}

std::size_t NativeSearchLimiter::active() const noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    return active_;
}

std::size_t NativeSearchLimiter::max_active() const noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    return max_active_;
}

NativeSearchJob::NativeSearchJob(
    Value cards,
    Value decks,
    std::shared_ptr<NativeSelfPlayBatch> batch,
    std::shared_ptr<NativeSearchLimiter> limiter
) :
    game_(cards),
    determinizer_(std::move(decks)),
    encoder_(std::move(cards)),
    batch_(std::move(batch)),
    limiter_(std::move(limiter)) {
    if (!batch_) {
        throw std::invalid_argument("native_search_batch_is_null");
    }
}

NativeSearchJob::~NativeSearchJob() {
    cancel();
    if (worker_.joinable()) {
        worker_.join();
    }
}

void NativeSearchJob::start(
    Value root_state,
    std::int32_t root_actor,
    std::uint32_t seed,
    NativeSearchConfig config
) {
    start_impl(
        std::move(root_state),
        root_actor,
        Value::make_object(),
        Value::make_object(),
        seed,
        config
    );
}

void NativeSearchJob::start_choice(
    Value root_state,
    std::int32_t root_actor,
    Value root_pending,
    Value root_continuation,
    std::uint32_t seed,
    NativeSearchConfig config
) {
    if (
        !root_pending.is_object()
        || root_pending.as_object().empty()
        || !root_continuation.is_object()
        || root_continuation.as_object().empty()
    ) {
        throw std::invalid_argument("invalid_root_choice_context");
    }
    if (
        integer_field(root_pending, "player", -1)
        != root_actor
    ) {
        throw std::invalid_argument("root_choice_actor_mismatch");
    }
    start_impl(
        std::move(root_state),
        root_actor,
        std::move(root_pending),
        std::move(root_continuation),
        seed,
        config
    );
}

void NativeSearchJob::start_impl(
    Value root_state,
    std::int32_t root_actor,
    Value root_pending,
    Value root_continuation,
    std::uint32_t seed,
    NativeSearchConfig config
) {
    if (running_.exchange(true) || worker_.joinable()) {
        running_ = true;
        throw std::logic_error("native_search_already_started");
    }
    if (
        root_actor != 0 && root_actor != 1
    ) {
        running_ = false;
        throw std::invalid_argument("invalid_search_actor");
    }
    if (
        config.simulations == 0
        || config.max_depth == 0
        || config.max_inflight_leaves == 0
        || config.max_inflight_leaves > config.simulations
        || !std::isfinite(config.c_puct)
        || config.c_puct < 0.0F
        || !std::isfinite(config.temperature)
        || config.temperature < 0.0F
        || !std::isfinite(config.dirichlet_epsilon)
        || config.dirichlet_epsilon < 0.0F
        || config.dirichlet_epsilon > 1.0F
    ) {
        running_ = false;
        throw std::invalid_argument("invalid_search_config");
    }
    cancel_requested_ = false;
    stop_requested_ = false;
    finished_ = false;
    {
        std::lock_guard<std::mutex> lock(result_mutex_);
        result_ = NativeSearchResult{};
    }
    worker_ = std::thread(
        &NativeSearchJob::run,
        this,
        std::move(root_state),
        root_actor,
        std::move(root_pending),
        std::move(root_continuation),
        seed,
        config
    );
}

void NativeSearchJob::cancel() noexcept {
    cancel_requested_ = true;
}

void NativeSearchJob::stop() noexcept {
    stop_requested_ = true;
}

bool NativeSearchJob::running() const noexcept {
    return running_;
}

bool NativeSearchJob::finished() const noexcept {
    return finished_;
}

NativeSearchResult NativeSearchJob::wait() {
    if (worker_.joinable()) {
        worker_.join();
    }
    std::lock_guard<std::mutex> lock(result_mutex_);
    return result_;
}

void NativeSearchJob::run(
    Value root_state,
    std::int32_t root_actor,
    Value root_pending,
    Value root_continuation,
    std::uint32_t seed,
    NativeSearchConfig config
) noexcept {
    NativeSearchResult completed;
    try {
        Value root_allowed_actions = Value::make_array();
        if (
            const Value *allowed = root_state.find(
                "_native_root_allowed_actions"
            )
        ) {
            if (
                !allowed->is_array()
                || allowed->as_array().empty()
            ) {
                throw std::runtime_error(
                    "invalid_root_action_allowlist"
                );
            }
            root_allowed_actions = *allowed;
            root_state.erase("_native_root_allowed_actions");
        }
        const SearchClock::time_point root_projection_started =
            SearchClock::now();
        const InformationSetProjection root_projection =
            project_information_set(root_state, root_actor);
        completed.projection_microseconds += elapsed_microseconds(
            root_projection_started
        );
        const SearchWorld root_world{
            root_state,
            root_pending,
            root_continuation,
            seed,
        };
        const std::uint64_t root_key = search_tree_key(
            root_projection,
            root_world
        );
        PuctTree tree;
        std::unordered_map<std::uint64_t, Value> expanded_candidates;
        std::unordered_map<
            std::uint64_t,
            std::vector<std::uint64_t>
        > expanded_signatures;
        std::unordered_set<std::uint64_t> chance_node_keys;
        XorShift32 selection_rng(seed ^ 0xA17E5EEDU);
        float root_value = 0.0F;
        Value root_candidate_rows = Value::make_array();
        enum class PreparedStatus {
            completed,
            inference,
            blocked,
            stopped,
        };
        struct PreparedSimulation {
            PreparedStatus status = PreparedStatus::stopped;
            std::uint32_t simulation = 0;
            std::uint32_t depth = 0;
            std::uint64_t key = 0;
            std::int32_t actor = 0;
            InferenceRequest request;
            Value candidate_rows = Value::make_array();
            std::vector<std::uint64_t> signatures;
            std::vector<PathEntry> path;
        };
        struct PendingLeaf {
            std::uint32_t simulation = 0;
            std::uint32_t depth = 0;
            std::uint64_t key = 0;
            std::uint64_t request_id = 0;
            std::int32_t actor = 0;
            Value candidate_rows = Value::make_array();
            std::vector<std::uint64_t> signatures;
            std::vector<PathEntry> path;
            SearchClock::time_point wait_started{};
        };
        std::vector<PendingLeaf> pending_leaves;
        pending_leaves.reserve(config.max_inflight_leaves);
        std::unordered_set<std::uint64_t> pending_leaf_keys;

        auto prepare_simulation = [&](std::uint32_t simulation) {
            PreparedSimulation prepared;
            prepared.simulation = simulation;
            if (cancel_requested_) {
                completed.cancelled = true;
                return prepared;
            }
            if (stop_requested_) {
                return prepared;
            }
            SimulationLease simulation_lease(
                limiter_,
                cancel_requested_,
                stop_requested_
            );
            if (!simulation_lease.acquire()) {
                completed.cancelled = cancel_requested_;
                return prepared;
            }
            const SearchClock::time_point determinization_started =
                SearchClock::now();
            Value determined = determinizer_.determinize(
                root_state,
                root_actor,
                seed ^ (0x9E3779B9U * (simulation + 1))
            );
            condition_on_revealed_choice(
                determined,
                root_pending,
                root_actor,
                root_continuation
            );
            completed.determinization_microseconds += elapsed_microseconds(
                determinization_started
            );
            SearchWorld world{
                std::move(determined),
                root_pending,
                root_continuation,
                seed ^ (0x85EBCA6BU * (simulation + 1)),
            };
            const Value simulation_root_state = world.state;
            const Value simulation_root_pending = world.pending;
            const Value simulation_root_continuation =
                world.continuation;
            const std::uint32_t simulation_root_rng = world.rng_state;
            const bool simulation_root_pending_chance =
                world.pending_chance_recorded;
            const SearchWorldMark simulation_root_mark = world.mark();
            std::vector<PathEntry> path;
            std::int32_t previous_actor = root_actor;
            bool simulation_resolved = false;
            bool simulation_blocked = false;
            for (
                std::uint32_t depth = 0;
                depth < config.max_depth;
                ++depth
            ) {
                if (cancel_requested_) {
                    completed.cancelled = true;
                    break;
                }
                if (stop_requested_) {
                    break;
                }
                const std::int32_t actor = world_actor(world);
                if (actor != 0 && actor != 1) {
                    throw std::runtime_error("invalid_world_actor");
                }
                if (depth > 0 && actor != previous_actor) {
                    const SearchClock::time_point redeterminization_started =
                        SearchClock::now();
                    world.begin_transition();
                    world.state = determinizer_.determinize(
                        world.state,
                        actor,
                        seed
                            ^ (simulation + 1) * 0xC2B2AE35U
                            ^ (depth + 1) * 0x27D4EB2FU
                    );
                    condition_on_revealed_choice(
                        world.state,
                        world.pending,
                        actor,
                        world.continuation
                    );
                    world.finish_transition();
                    completed.determinization_microseconds +=
                        elapsed_microseconds(redeterminization_started);
                }
                previous_actor = actor;
                if (terminal(world)) {
                    const float value = terminal_value(world, actor);
                    backup(tree, path, value, actor);
                    simulation_resolved = true;
                    break;
                }
                const SearchClock::time_point projection_started =
                    SearchClock::now();
                const InformationSetProjection projection =
                    project_information_set(world.state, actor);
                completed.projection_microseconds += elapsed_microseconds(
                    projection_started
                );
                const std::uint64_t key = depth == 0
                    ? root_key
                    : search_tree_key(projection, world);
                const bool cached_candidate_allowed = (
                    !world.pending_chance_recorded
                    && chance_flips(world) == nullptr
                );
                const auto cached_candidates = cached_candidate_allowed
                    ? expanded_candidates.find(key)
                    : expanded_candidates.end();
                const auto cached_signatures = cached_candidate_allowed
                    ? expanded_signatures.find(key)
                    : expanded_signatures.end();
                Value candidate_rows;
                if (cached_candidates != expanded_candidates.end()) {
                    if (cached_signatures == expanded_signatures.end()) {
                        throw std::runtime_error(
                            "candidate_signature_cache_missing"
                        );
                    }
                    ++completed.candidate_cache_hits;
                    candidate_rows = cached_candidates->second;
                    if (config.verify_candidate_cache) {
                        const SearchClock::time_point verification_started =
                            SearchClock::now();
                        const Value regenerated = (
                            depth == 0
                            && root_allowed_actions.is_array()
                            && !root_allowed_actions.as_array().empty()
                        ) ? root_allowed_actions
                          : candidates(game_, world, actor);
                        completed.candidate_generation_microseconds +=
                            elapsed_microseconds(verification_started);
                        if (candidate_signatures(regenerated)
                            != cached_signatures->second) {
                            throw std::runtime_error(
                                "infoset_candidate_cache_diverged:actor="
                                + std::to_string(actor)
                                + ":depth=" + std::to_string(depth)
                            );
                        }
                    }
                } else {
                    ++completed.candidate_cache_misses;
                    const SearchClock::time_point candidates_started =
                        SearchClock::now();
                    candidate_rows = (
                        depth == 0
                        && root_allowed_actions.is_array()
                        && !root_allowed_actions.as_array().empty()
                    ) ? root_allowed_actions
                      : candidates(game_, world, actor);
                    completed.candidate_generation_microseconds +=
                        elapsed_microseconds(candidates_started);
                }
                if (
                    !candidate_rows.is_array()
                    || candidate_rows.as_array().empty()
                ) {
                    backup(tree, path, 0.0F, actor);
                    simulation_resolved = true;
                    break;
                }
                if (
                    world.pending_chance_recorded
                    && pending_coin_flips(world) != nullptr
                ) {
                    if (candidate_rows.as_array().size() != 1) {
                        throw std::runtime_error(
                            "recorded_coin_resolution_not_forced"
                        );
                    }
                    const Value &candidate =
                        candidate_rows.as_array().front();
                    const std::uint64_t signature =
                        stable_value_hash(candidate);
                    const std::optional<ObservedChanceTransition> observed =
                        apply_candidate(
                            game_,
                            world,
                            candidate,
                            actor,
                            &completed.apply_microseconds
                        );
                    if (observed.has_value()) {
                        append_observed_chance(
                            tree,
                            chance_node_keys,
                            path,
                            key,
                            signature,
                            actor,
                            *observed
                        );
                    }
                    continue;
                }
                const bool chance_node = chance_flips(world) != nullptr;
                if (chance_node) {
                    candidate_rows = chance_candidates(
                        world,
                        std::move(candidate_rows)
                    );
                }
                if (depth == 0 && root_candidate_rows.as_array().empty()) {
                    root_candidate_rows = candidate_rows;
                }
                const std::vector<std::uint64_t> signatures = (
                    cached_signatures != expanded_signatures.end()
                ) ? cached_signatures->second
                  : candidate_signatures(candidate_rows);
                PuctNode &node = tree.node(key, actor);
                if (chance_node) {
                    const Value &candidate =
                        candidate_rows.as_array().front();
                    const Value *probability = candidate.find(
                        "chance_probability"
                    );
                    const std::size_t edge_index = node.ensure_edge(
                        signatures.front(),
                        static_cast<float>(
                            probability == nullptr
                                ? 0.0
                                : probability->as_number()
                        )
                    );
                    chance_node_keys.insert(key);
                    path.push_back({key, edge_index, actor});
                    const std::optional<ObservedChanceTransition> observed =
                        apply_candidate(
                            game_,
                            world,
                            candidate,
                            actor,
                            &completed.apply_microseconds
                        );
                    if (observed.has_value()) {
                        append_observed_chance(
                            tree,
                            chance_node_keys,
                            path,
                            key,
                            signatures.front(),
                            actor,
                            *observed
                        );
                    }
                    continue;
                }
                if (!node.expanded()) {
                    if (pending_leaf_keys.find(key)
                        != pending_leaf_keys.end()) {
                        simulation_blocked = true;
                        break;
                    }
                    const SearchClock::time_point encoding_started =
                        SearchClock::now();
                    if (
                        world.pending.is_object()
                        && !world.pending.as_object().empty()
                    ) {
                        prepared.request = encoder_.encode_choices(
                            projection.observation,
                            world.pending,
                            candidate_rows
                        );
                    } else {
                        prepared.request = encoder_.encode_actions(
                            projection.observation,
                            candidate_rows
                        );
                    }
                    prepared.request.model_slot = config.model_slot;
                    completed.encoding_microseconds +=
                        elapsed_microseconds(encoding_started);
                    prepared.status = PreparedStatus::inference;
                    prepared.depth = depth;
                    prepared.key = key;
                    prepared.actor = actor;
                    prepared.candidate_rows = std::move(candidate_rows);
                    prepared.signatures = signatures;
                    prepared.path = path;
                    break;
                }
                std::unordered_map<std::uint64_t, std::size_t> current;
                for (
                    std::size_t index = 0;
                    index < signatures.size();
                    ++index
                ) {
                    if (!current.emplace(signatures[index], index).second) {
                        throw std::runtime_error(
                            "duplicate_candidate_signature:actor="
                            + std::to_string(actor)
                            + ":depth=" + std::to_string(depth)
                            + ":candidates="
                            + describe_candidates(candidate_rows)
                        );
                    }
                }
                bool any_legal_edge = false;
                for (
                    std::size_t index = 0;
                    index < node.size();
                    ++index
                ) {
                    if (
                        current.find(node.edge(index).signature)
                        != current.end()
                    ) {
                        any_legal_edge = true;
                        break;
                    }
                }
                if (!any_legal_edge) {
                    const auto previous = expanded_candidates.find(key);
                    throw std::runtime_error(
                        "tree_legal_set_diverged:actor="
                        + std::to_string(actor)
                        + ":previous="
                        + (
                            previous == expanded_candidates.end()
                            ? std::string("missing")
                            : describe_candidates(previous->second)
                        )
                        + ":current="
                        + describe_candidates(candidate_rows)
                    );
                }
                const std::size_t edge_index = select_legal_edge(
                    node,
                    current,
                    config.c_puct
                );
                const auto current_candidate = current.find(
                    node.edge(edge_index).signature
                );
                path.push_back({key, edge_index, actor});
                const Value &selected_candidate =
                    candidate_rows.as_array().at(
                        current_candidate->second
                    );
                const std::optional<ObservedChanceTransition> observed =
                    apply_candidate(
                    game_,
                    world,
                    selected_candidate,
                    actor,
                    &completed.apply_microseconds
                );
                if (observed.has_value()) {
                    append_observed_chance(
                        tree,
                        chance_node_keys,
                        path,
                        key,
                        node.edge(edge_index).signature,
                        actor,
                        *observed
                    );
                }
            }
            world.undo(simulation_root_mark);
            completed.apply_undo_journal_entries +=
                world.journal_entry_count();
            completed.apply_undo_operations +=
                world.undo_operation_count();
            if (
                !(world.state == simulation_root_state)
                || !(world.pending == simulation_root_pending)
                || !(
                    world.continuation
                    == simulation_root_continuation
                )
                || world.rng_state != simulation_root_rng
                || world.pending_chance_recorded
                    != simulation_root_pending_chance
            ) {
                throw std::runtime_error(
                    "search_world_apply_undo_roundtrip_failed"
                );
            }
            if (completed.cancelled || stop_requested_) {
                prepared.status = PreparedStatus::stopped;
                return prepared;
            }
            if (prepared.status == PreparedStatus::inference) {
                return prepared;
            }
            if (simulation_blocked) {
                prepared.status = PreparedStatus::blocked;
                return prepared;
            }
            if (!simulation_resolved) {
                // A depth-limited simulation is a censored leaf. Back it up
                // as a draw so every completed simulation that selected root
                // edges contributes exactly one visit.
                backup(tree, path, 0.0F, root_actor);
            }
            prepared.status = PreparedStatus::completed;
            return prepared;
        };

        auto discard_pending = [&]() noexcept {
            for (PendingLeaf &leaf : pending_leaves) {
                batch_->discard_request(leaf.request_id);
                try {
                    release_path(tree, leaf.path);
                } catch (...) {
                    // Search is already failing or stopping.  The tree is
                    // private to this job and will be discarded immediately.
                }
            }
            pending_leaves.clear();
            pending_leaf_keys.clear();
        };

        std::uint32_t next_simulation = 0;
        try {
            while (
                next_simulation < config.simulations
                || !pending_leaves.empty()
            ) {
                if (cancel_requested_ || stop_requested_) {
                    completed.cancelled = cancel_requested_;
                    discard_pending();
                    break;
                }
                bool blocked = false;
                while (
                    next_simulation < config.simulations
                    && pending_leaves.size()
                        < config.max_inflight_leaves
                ) {
                    PreparedSimulation prepared = prepare_simulation(
                        next_simulation
                    );
                    if (prepared.status == PreparedStatus::stopped) {
                        completed.cancelled = cancel_requested_;
                        break;
                    }
                    if (prepared.status == PreparedStatus::blocked) {
                        blocked = true;
                        break;
                    }
                    if (prepared.status == PreparedStatus::completed) {
                        ++completed.simulations;
                        ++next_simulation;
                        continue;
                    }
                    const std::uint64_t request_id = batch_->enqueue(
                        std::move(prepared.request)
                    );
                    reserve_path(tree, prepared.path);
                    if (!pending_leaf_keys.insert(prepared.key).second) {
                        release_path(tree, prepared.path);
                        batch_->discard_request(request_id);
                        throw std::logic_error(
                            "duplicate_pending_leaf_key"
                        );
                    }
                    pending_leaves.push_back({
                        prepared.simulation,
                        prepared.depth,
                        prepared.key,
                        request_id,
                        prepared.actor,
                        std::move(prepared.candidate_rows),
                        std::move(prepared.signatures),
                        std::move(prepared.path),
                        SearchClock::now(),
                    });
                    completed.max_pending_leaves = std::max<std::uint64_t>(
                        completed.max_pending_leaves,
                        pending_leaves.size()
                    );
                    ++next_simulation;
                }
                if (completed.cancelled || stop_requested_) {
                    discard_pending();
                    break;
                }
                if (pending_leaves.empty()) {
                    if (blocked) {
                        throw std::logic_error(
                            "pending_leaf_blocked_without_request"
                        );
                    }
                    continue;
                }

                std::size_t ready_index = pending_leaves.size();
                std::optional<InferenceResponse> response;
                for (
                    std::size_t index = 0;
                    index < pending_leaves.size();
                    ++index
                ) {
                    response = batch_->take_response(
                        pending_leaves[index].request_id
                    );
                    if (response.has_value()) {
                        ready_index = index;
                        break;
                    }
                }
                if (!response.has_value()) {
                    ready_index = 0;
                    response = batch_->wait_response(
                        pending_leaves.front().request_id,
                        config.inference_wait_milliseconds
                    );
                    if (batch_->closed() && !response.has_value()) {
                        throw std::runtime_error(
                            "inference_batch_closed"
                        );
                    }
                    if (!response.has_value()) {
                        continue;
                    }
                }

                PendingLeaf leaf = std::move(
                    pending_leaves[ready_index]
                );
                pending_leaves.erase(
                    pending_leaves.begin()
                        + static_cast<std::ptrdiff_t>(ready_index)
                );
                if (pending_leaf_keys.erase(leaf.key) != 1) {
                    throw std::logic_error(
                        "pending_leaf_key_missing"
                    );
                }
                completed.inference_wait_microseconds +=
                    elapsed_microseconds(leaf.wait_started);
                release_path(tree, leaf.path);
                PuctNode &node = tree.node(leaf.key, leaf.actor);
                if (node.expanded()) {
                    throw std::logic_error(
                        "pending_leaf_already_expanded"
                    );
                }
                std::vector<float> priors = response->policy;
                if (config.training && leaf.depth == 0) {
                    add_root_noise(
                        priors,
                        config.dirichlet_epsilon,
                        selection_rng
                    );
                }
                node.expand(leaf.signatures, priors);
                expanded_candidates[leaf.key] = leaf.candidate_rows;
                expanded_signatures[leaf.key] = leaf.signatures;
                const float value = response->wdl[0] - response->wdl[2];
                if (leaf.simulation == 0) {
                    root_value = value;
                }
                backup(tree, leaf.path, value, leaf.actor);
                ++completed.simulations;
            }
        } catch (...) {
            discard_pending();
            throw;
        }
        const PuctNode *root = tree.find(root_key);
        if (root == nullptr || !root->expanded() || root->size() == 0) {
            if (!completed.cancelled) {
                throw std::runtime_error("puct_root_not_expanded");
            }
        } else {
            const std::vector<float> probabilities =
                visit_distribution(*root, config.temperature);
            const std::size_t selected = config.training
                ? sample_distribution(probabilities, selection_rng)
                : static_cast<std::size_t>(
                    std::max_element(
                        probabilities.begin(),
                        probabilities.end()
                    ) - probabilities.begin()
                );
            Value root_candidates = std::move(root_candidate_rows);
            if (
                !root_candidates.is_array()
                || root_candidates.as_array().empty()
            ) {
                throw std::runtime_error(
                    "root_candidate_rows_missing"
                );
            }
            const std::vector<std::uint64_t> root_signatures =
                candidate_signatures(root_candidates);
            const std::uint64_t selected_signature =
                root->edge(selected).signature;
            const auto selected_row = std::find(
                root_signatures.begin(),
                root_signatures.end(),
                selected_signature
            );
            if (selected_row == root_signatures.end()) {
                throw std::runtime_error(
                    "root_candidate_signature_missing"
                );
            }
            completed.selected = root_candidates.as_array().at(
                static_cast<std::size_t>(
                    selected_row - root_signatures.begin()
                )
            );
            Value selected_state = determinizer_.determinize(
                root_state,
                root_actor,
                seed ^ 0x51ED270BU
            );
            condition_on_revealed_choice(
                selected_state,
                root_pending,
                root_actor,
                root_continuation
            );
            SearchWorld selected_world{
                std::move(selected_state),
                root_pending,
                root_continuation,
                seed,
            };
            (void)apply_candidate(
                game_,
                selected_world,
                completed.selected,
                root_actor,
                &completed.apply_microseconds
            );
            completed.next_state_revision = integer_field(
                selected_world.state,
                "revision",
                -1
            );
            completed.next_pending = std::move(
                selected_world.pending
            );
            completed.next_continuation = std::move(
                selected_world.continuation
            );
            Array visits;
            Array value_sums;
            Array probability_rows;
            Array ordered_candidates;
            for (std::size_t index = 0; index < root->size(); ++index) {
                const auto candidate_row = std::find(
                    root_signatures.begin(),
                    root_signatures.end(),
                    root->edge(index).signature
                );
                if (candidate_row == root_signatures.end()) {
                    throw std::runtime_error(
                        "root_candidate_signature_missing"
                    );
                }
                ordered_candidates.push_back(
                    root_candidates.as_array().at(
                        static_cast<std::size_t>(
                            candidate_row - root_signatures.begin()
                        )
                    )
                );
                visits.emplace_back(static_cast<std::int64_t>(
                    root->edge(index).visits
                ));
                value_sums.emplace_back(static_cast<double>(
                    root->edge(index).value_sum
                ));
                probability_rows.emplace_back(
                    static_cast<double>(probabilities[index])
                );
            }
            completed.candidates = Value(std::move(ordered_candidates));
            completed.visits = Value(std::move(visits));
            completed.value_sums = Value(std::move(value_sums));
            completed.probabilities = Value(
                std::move(probability_rows)
            );
            completed.root_value = root_value;
            completed.tree_nodes = tree.size();
            completed.chance_nodes = chance_node_keys.size();
            for (const std::uint64_t key : chance_node_keys) {
                const PuctNode *chance = tree.find(key);
                if (chance != nullptr) {
                    completed.chance_edges += chance->size();
                }
            }
            completed.success = !completed.cancelled;
        }
    } catch (const std::exception &error) {
        completed.error = error.what();
    } catch (...) {
        completed.error = "unknown_native_search_error";
    }
    {
        std::lock_guard<std::mutex> lock(result_mutex_);
        result_ = std::move(completed);
    }
    running_ = false;
    finished_ = true;
    finished_ready_.notify_all();
}

} // namespace ptcg::ai
