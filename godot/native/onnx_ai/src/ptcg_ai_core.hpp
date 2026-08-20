#pragma once

#include "ptcg_random.hpp"

#include <array>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <mutex>
#include <optional>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace ptcg::ai {

inline constexpr int NATIVE_ABI_VERSION = 2;
inline constexpr std::size_t STATE_GLOBAL_SIZE = 128;
inline constexpr std::size_t ENTITY_SLOTS = 128;
inline constexpr std::size_t ENTITY_NUMERIC_SIZE = 16;
inline constexpr std::size_t ENTITY_TYPE_FIELDS = 4;
inline constexpr std::size_t CANDIDATE_NUMERIC_SIZE = 32;
inline constexpr std::size_t CANDIDATE_REF_FIELDS = 4;

struct UndoMark {
    std::size_t journal_size = 0;
};

class CompactState {
public:
    explicit CompactState(std::size_t word_count = 0);

    std::size_t size() const noexcept;
    std::int32_t get(std::size_t index) const;
    void set(std::size_t index, std::int32_t value);
    UndoMark mark() const noexcept;
    void undo(UndoMark mark);
    void clear_journal() noexcept;
    const std::vector<std::int32_t> &words() const noexcept;

private:
    struct JournalEntry {
        std::uint32_t index = 0;
        std::int32_t previous = 0;
    };

    std::vector<std::int32_t> words_;
    std::vector<JournalEntry> journal_;
};

std::uint64_t information_set_hash(
    const std::vector<std::int32_t> &public_words,
    const std::vector<std::int32_t> &actor_private_words,
    std::int32_t actor
) noexcept;

struct PuctCandidate {
    std::uint64_t signature = 0;
    float prior = 0.0F;
    std::uint32_t visits = 0;
    float value_sum = 0.0F;
    std::uint32_t in_flight = 0;

    float q() const noexcept;
    std::uint64_t selection_visits() const noexcept;
    float selection_q(float virtual_loss = 1.0F) const noexcept;
};

class PuctNode {
public:
    explicit PuctNode(std::int32_t actor = 0);

    void expand(
        const std::vector<std::uint64_t> &signatures,
        const std::vector<float> &priors
    );
    std::size_t ensure_edge(
        std::uint64_t signature,
        float probability
    );
    bool expanded() const noexcept;
    std::size_t size() const noexcept;
    std::size_t select(float c_puct) const;
    void reserve(std::size_t edge_index);
    void release(std::size_t edge_index);
    void backup(std::size_t edge_index, float actor_value);
    const PuctCandidate &edge(std::size_t index) const;
    PuctCandidate &edge(std::size_t index);
    std::int32_t actor() const noexcept;

private:
    std::int32_t actor_;
    bool expanded_ = false;
    std::vector<PuctCandidate> edges_;
};

class PuctTree {
public:
    PuctNode &node(std::uint64_t key, std::int32_t actor);
    const PuctNode *find(std::uint64_t key) const noexcept;
    void clear() noexcept;
    std::size_t size() const noexcept;

private:
    std::unordered_map<std::uint64_t, PuctNode> nodes_;
};

struct InferenceRequest {
    std::uint64_t request_id = 0;
    std::array<float, STATE_GLOBAL_SIZE> state_global{};
    std::array<float, ENTITY_SLOTS * ENTITY_NUMERIC_SIZE> entity_numeric{};
    std::array<std::int64_t, ENTITY_SLOTS> entity_card_ids{};
    std::array<
        std::int64_t,
        ENTITY_SLOTS * ENTITY_TYPE_FIELDS
    > entity_type_ids{};
    std::vector<float> candidate_numeric;
    std::vector<std::int64_t> candidate_card_ids;
    std::vector<std::int64_t> candidate_type_ids;
    std::vector<std::int64_t> candidate_refs;
    std::int64_t actor_deck_id = 0;
    std::int64_t opponent_deck_id = 0;

    std::size_t candidate_count() const noexcept;
    void validate() const;
};

struct InferenceResponse {
    std::uint64_t request_id = 0;
    std::vector<float> policy;
    std::array<float, 3> wdl{};

    void validate(std::size_t candidate_count) const;
};

struct TrainingSample {
    InferenceRequest input;
    std::vector<float> policy_target;
    std::array<float, 3> wdl_target{};
    std::int32_t generation = 0;
    std::int32_t actor = 0;
};

class NativeSelfPlayBatch {
public:
    NativeSelfPlayBatch() = default;

    std::uint64_t enqueue(InferenceRequest request);
    std::vector<InferenceRequest> poll_inference(
        std::size_t max_requests,
        std::uint32_t wait_milliseconds = 0,
        std::size_t target_requests = 1,
        std::uint32_t coalesce_milliseconds = 0
    );
    void submit_inference(const std::vector<InferenceResponse> &responses);
    std::optional<InferenceResponse> take_response(std::uint64_t request_id);
    std::optional<InferenceResponse> wait_response(
        std::uint64_t request_id,
        std::uint32_t wait_milliseconds
    );
    bool discard_request(std::uint64_t request_id) noexcept;
    void append_sample(TrainingSample sample);
    std::vector<TrainingSample> drain_samples();
    std::size_t pending_requests() const noexcept;
    void close() noexcept;
    bool closed() const noexcept;

private:
    mutable std::mutex mutex_;
    std::condition_variable ready_;
    std::deque<InferenceRequest> pending_;
    std::unordered_map<std::uint64_t, std::size_t> expected_candidates_;
    std::unordered_map<std::uint64_t, InferenceResponse> responses_;
    std::unordered_set<std::uint64_t> discarded_requests_;
    std::vector<TrainingSample> samples_;
    std::uint64_t next_request_id_ = 1;
    bool closed_ = false;
};

} // namespace ptcg::ai
