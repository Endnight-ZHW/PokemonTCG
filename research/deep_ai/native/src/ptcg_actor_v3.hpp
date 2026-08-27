#pragma once

#include "ptcg_ai_core.hpp"
#include "ptcg_search.hpp"
#include "ptcg_value.hpp"

#include <array>
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace ptcg::ai {

class NativeGameKernel;
class NativeInformationSetEncoderV3;

struct GameTaskV3 {
    std::string game_id;
    std::int32_t cycle = 0;
    std::string deck_a;
    std::string deck_b;
    std::uint32_t seed = 17;
    std::int32_t seat_a = 0;
    std::int32_t first_player = 0;
    std::array<std::int32_t, 2> model_slots{0, 0};
    std::array<std::int32_t, 2> model_versions{0, 0};
    std::uint32_t max_decisions = 512;
};

struct ActorPoolConfigV3 {
    std::uint32_t concurrent_games = 64;
    std::uint32_t simulations = 128;
    std::uint32_t max_depth = 128;
    std::uint32_t max_inflight_leaves = 8;
    std::uint32_t inference_wait_milliseconds = 25;
    float c_puct = 1.4F;
    float dirichlet_epsilon = 0.25F;
    bool training = true;
    bool direct_policy = false;
};

struct ActorGameResultV3 {
    std::string game_id;
    std::int32_t cycle = 0;
    std::string deck_a;
    std::string deck_b;
    std::uint32_t seed = 0;
    std::int32_t seat_a = 0;
    std::int32_t first_player = 0;
    std::array<std::int32_t, 2> model_slots{0, 0};
    std::array<std::int32_t, 2> model_versions{0, 0};
    std::uint32_t max_decisions = 0;
    bool success = false;
    bool terminal = false;
    bool truncated = false;
    std::string error;
    std::int32_t winner = -1;
    std::uint32_t decisions = 0;
    std::uint64_t simulations = 0;
    std::uint64_t samples = 0;
    std::uint64_t state_hash = 0;
    std::uint64_t determinization_microseconds = 0;
    std::uint64_t projection_microseconds = 0;
    std::uint64_t candidate_generation_microseconds = 0;
    std::uint64_t apply_microseconds = 0;
    std::uint64_t encoding_microseconds = 0;
    std::uint64_t inference_wait_microseconds = 0;
};

class NativeActorPoolV3 {
public:
    NativeActorPoolV3(
        Value catalog,
        Value decks,
        std::shared_ptr<NativeSelfPlayBatch> batch,
        std::shared_ptr<NativeSearchLimiter> limiter,
        ActorPoolConfigV3 config = {}
    );
    ~NativeActorPoolV3();

    NativeActorPoolV3(const NativeActorPoolV3 &) = delete;
    NativeActorPoolV3 &operator=(const NativeActorPoolV3 &) = delete;

    void start(std::vector<GameTaskV3> tasks);
    void pause() noexcept;
    void resume() noexcept;
    void cancel() noexcept;
    void wait();
    bool running() const noexcept;
    bool finished() const noexcept;
    std::vector<ActorGameResultV3> drain_games();
    Value metrics() const;

private:
    void worker();
    ActorGameResultV3 run_game(
        const GameTaskV3 &task,
        NativeSearchJob &search,
        NativeInformationSetEncoderV3 &encoder,
        NativeGameKernel &game
    );
    void wait_if_paused();

    Value catalog_;
    Value cards_;
    Value decks_;
    std::shared_ptr<NativeSelfPlayBatch> batch_;
    std::shared_ptr<NativeSearchLimiter> limiter_;
    ActorPoolConfigV3 config_;
    std::vector<GameTaskV3> tasks_;
    std::vector<std::thread> workers_;
    std::atomic<std::size_t> next_task_{0};
    std::atomic<bool> running_{false};
    std::atomic<bool> finished_{false};
    std::atomic<bool> paused_{false};
    std::atomic<bool> cancelled_{false};
    mutable std::mutex pause_mutex_;
    std::condition_variable pause_ready_;
    mutable std::mutex results_mutex_;
    std::vector<ActorGameResultV3> results_;
    std::atomic<std::uint64_t> completed_games_{0};
    std::atomic<std::uint64_t> failed_games_{0};
    std::atomic<std::uint64_t> decisions_{0};
    std::atomic<std::uint64_t> simulations_{0};
    std::atomic<std::uint64_t> samples_{0};
    std::atomic<std::uint64_t> determinization_microseconds_{0};
    std::atomic<std::uint64_t> projection_microseconds_{0};
    std::atomic<std::uint64_t> candidate_generation_microseconds_{0};
    std::atomic<std::uint64_t> apply_microseconds_{0};
    std::atomic<std::uint64_t> encoding_microseconds_{0};
    std::atomic<std::uint64_t> inference_wait_microseconds_{0};
};

} // namespace ptcg::ai
