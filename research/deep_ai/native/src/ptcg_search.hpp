#pragma once

#include "ptcg_ai_core.hpp"
#include "ptcg_determinizer.hpp"
#include "ptcg_encoder_v3.hpp"
#include "ptcg_game.hpp"
#include "ptcg_value.hpp"

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

namespace ptcg::ai {

struct NativeSearchConfig {
    std::uint32_t simulations = 128;
    std::uint32_t max_depth = 128;
    float c_puct = 1.4F;
    float dirichlet_epsilon = 0.25F;
    float temperature = 1.0F;
    bool training = true;
    // Test/audit switch. Production reuses candidates by information-set key;
    // this mode regenerates them and fails if an infoset is not invariant.
    bool verify_candidate_cache = false;
    std::uint32_t inference_wait_milliseconds = 100;
    // Number of leaf evaluations one search may have outstanding.  A value
    // of one preserves strictly sequential PUCT; production training and
    // clients use a small wave with virtual visits to fill shared batches.
    std::uint32_t max_inflight_leaves = 1;
    // Routes actor/champion/history requests through one shared GPU broker.
    std::int32_t model_slot = 0;
};

struct NativeSearchResult {
    bool success = false;
    bool cancelled = false;
    std::string error;
    Value selected = Value::make_object();
    Value next_pending = Value::make_object();
    Value next_continuation = Value::make_object();
    std::int64_t next_state_revision = -1;
    // Root candidates in exactly the same order as visits, value_sums and
    // probabilities.  Bindings must not infer this order from a fresh legal
    // action query because tree edges are keyed by the determinized root.
    Value candidates = Value::make_array();
    Value visits = Value::make_array();
    Value value_sums = Value::make_array();
    Value probabilities = Value::make_array();
    float root_value = 0.0F;
    std::uint32_t simulations = 0;
    std::uint64_t tree_nodes = 0;
    std::uint64_t chance_nodes = 0;
    std::uint64_t chance_edges = 0;
    std::uint64_t determinization_microseconds = 0;
    std::uint64_t projection_microseconds = 0;
    std::uint64_t candidate_generation_microseconds = 0;
    std::uint64_t apply_microseconds = 0;
    std::uint64_t encoding_microseconds = 0;
    std::uint64_t inference_wait_microseconds = 0;
    std::uint64_t max_pending_leaves = 0;
    std::uint64_t candidate_cache_hits = 0;
    std::uint64_t candidate_cache_misses = 0;
    std::uint64_t apply_undo_journal_entries = 0;
    std::uint64_t apply_undo_operations = 0;
};

class NativeSearchLimiter {
public:
    explicit NativeSearchLimiter(std::size_t capacity);

    bool acquire(
        const std::atomic<bool> &cancel_requested,
        const std::atomic<bool> &stop_requested
    );
    void release() noexcept;
    std::size_t capacity() const noexcept;
    std::size_t active() const noexcept;
    std::size_t max_active() const noexcept;

private:
    const std::size_t capacity_;
    mutable std::mutex mutex_;
    std::condition_variable available_;
    std::size_t active_ = 0;
    std::size_t max_active_ = 0;
};

class NativeSearchJob {
public:
    NativeSearchJob(
        Value cards,
        Value decks,
        std::shared_ptr<NativeSelfPlayBatch> batch,
        std::shared_ptr<NativeSearchLimiter> limiter = nullptr
    );
    ~NativeSearchJob();

    NativeSearchJob(const NativeSearchJob &) = delete;
    NativeSearchJob &operator=(const NativeSearchJob &) = delete;

    void start(
        Value root_state,
        std::int32_t root_actor,
        std::uint32_t seed,
        NativeSearchConfig config = {}
    );
    void start_choice(
        Value root_state,
        std::int32_t root_actor,
        Value root_pending,
        Value root_continuation,
        std::uint32_t seed,
        NativeSearchConfig config = {}
    );
    void cancel() noexcept;
    void stop() noexcept;
    bool running() const noexcept;
    bool finished() const noexcept;
    NativeSearchResult wait();

private:
    void start_impl(
        Value root_state,
        std::int32_t root_actor,
        Value root_pending,
        Value root_continuation,
        std::uint32_t seed,
        NativeSearchConfig config
    );
    void run(
        Value root_state,
        std::int32_t root_actor,
        Value root_pending,
        Value root_continuation,
        std::uint32_t seed,
        NativeSearchConfig config
    ) noexcept;

    NativeGameKernel game_;
    NativeDeterminizer determinizer_;
    NativeInformationSetEncoderV3 encoder_;
    std::shared_ptr<NativeSelfPlayBatch> batch_;
    std::shared_ptr<NativeSearchLimiter> limiter_;
    std::thread worker_;
    std::atomic<bool> cancel_requested_{false};
    std::atomic<bool> stop_requested_{false};
    std::atomic<bool> running_{false};
    std::atomic<bool> finished_{false};
    mutable std::mutex result_mutex_;
    std::condition_variable finished_ready_;
    NativeSearchResult result_;
};

} // namespace ptcg::ai
