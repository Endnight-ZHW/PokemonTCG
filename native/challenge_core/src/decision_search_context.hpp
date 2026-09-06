#pragma once

#include "ptcg_rules_session.hpp"

#include <any>
#include <array>
#include <atomic>
#include <cstdint>
#include <mutex>
#include <optional>
#include <unordered_map>

namespace ptcg::ai {

enum class SearchMemo : std::uint8_t {
    Pipeline, Resources, Zones, StateScore, Fingerprint, Preconditions, Ranking,
    Count
};

// Request-scoped exact memoization. A retained COW Value owns each identity:
// mutations detach, and allocator address reuse cannot turn into a cache hit.
// Include the rules basis as well as the projected state (choice projections
// are evaluated against their original session), perspective and RNG state.
// No normalized public/cycle fingerprint is used as an equivalence proof.
class DecisionSearchContext {
public:
    bool memoization_enabled = true;

    template<class T, class Compute>
    T memoize(SearchMemo kind, const RulesSession &position, const Value &state,
        std::int32_t actor, std::uint64_t policy, Compute &&compute) {
        return memoize_values<T>(kind, position.search_state(), state,
            position.rng_state(), actor, policy, std::forward<Compute>(compute));
    }

    template<class T, class Compute>
    T memoize_values(SearchMemo kind, const Value &basis, const Value &state,
        std::uint32_t rng, std::int32_t actor, std::uint64_t policy, Compute &&compute) {
        const auto identity = [](const Value &value) -> const void * {
            if (value.is_object()) return &value.as_object();
            if (value.is_array()) return &value.as_array();
            return nullptr;
        };
        if (!memoization_enabled || !identity(state) || !identity(basis)) return compute();
        const Key key{identity(state), identity(basis), rng,
            actor, policy, kind};
        const auto index = static_cast<std::size_t>(kind);
        {
            std::lock_guard<std::mutex> lock(mutex_);
            const auto found = entries_.find(key);
            if (found != entries_.end()) {
                ++hits_[index];
                return std::any_cast<T>(found->second.result);
            }
        }
        ++misses_[index];
        T result = compute();
        {
            std::lock_guard<std::mutex> lock(mutex_);
            // Bounded per decision; returned values own their data and remain
            // valid across eviction. Cache races may duplicate work, not values.
            if (entries_.size() >= 4096) entries_.clear();
            entries_.emplace(key, Entry{state, basis, result});
        }
        return result;
    }

    Value counters() const {
        static constexpr const char *names[] = {
            "pipeline", "resources", "zones", "state_score", "fingerprint",
            "preconditions", "ranking"};
        Value result = Value::make_object();
        for (std::size_t index = 0; index < hits_.size(); ++index) {
            result[std::string("memo_") + names[index] + "_hits"] =
                Value(static_cast<std::int64_t>(hits_[index].load()));
            result[std::string("memo_") + names[index] + "_computations"] =
                Value(static_cast<std::int64_t>(misses_[index].load()));
        }
        return result;
    }

private:
    struct Key {
        const void *state;
        const void *basis;
        std::uint32_t rng;
        std::int32_t actor;
        std::uint64_t policy;
        SearchMemo kind;
        bool operator==(const Key &other) const noexcept {
            return state == other.state && basis == other.basis && rng == other.rng
                && actor == other.actor && policy == other.policy && kind == other.kind;
        }
    };
    struct Hash {
        std::size_t operator()(const Key &key) const noexcept {
            std::size_t hash = reinterpret_cast<std::uintptr_t>(key.state);
            const auto mix = [&](std::size_t value) {
                hash ^= value + 0x9e3779b9U + (hash << 6) + (hash >> 2);
            };
            mix(reinterpret_cast<std::uintptr_t>(key.basis));
            mix(key.rng); mix(static_cast<std::size_t>(key.actor));
            mix(static_cast<std::size_t>(key.policy));
            mix(static_cast<std::size_t>(key.kind));
            return hash;
        }
    };
    struct Entry { Value state; Value basis; std::any result; };
    std::mutex mutex_;
    std::unordered_map<Key, Entry, Hash> entries_;
    std::array<std::atomic<std::uint64_t>, static_cast<std::size_t>(SearchMemo::Count)> hits_{};
    std::array<std::atomic<std::uint64_t>, static_cast<std::size_t>(SearchMemo::Count)> misses_{};
};

} // namespace ptcg::ai
