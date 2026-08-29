#pragma once

#include "challenge_controller.hpp"
#include "ptcg_value.hpp"

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace ptcg::ai {

struct ChallengeArenaAgentSpec {
    std::string agent_id;
    std::string build_id;
    Value strategies = Value::make_object();
    Value evaluation_options = Value::make_object();
};

struct ChallengeArenaTask {
    std::string task_id;
    std::string candidate_deck;
    std::string baseline_deck;
    std::uint32_t game_seed = 17;
    std::int32_t candidate_seat = 0;
    std::int32_t first_player = 0;
    std::uint32_t max_decisions = 512;
};

struct ChallengeArenaPoolConfig {
    std::uint32_t concurrent_games = 8;
    bool deterministic = true;
    bool capture_failure_trace = true;
    bool capture_all_decisions = false;
    std::uint32_t inner_search_workers = 1;
};

struct ChallengeArenaGameResult {
    std::string task_id;
    std::string candidate_deck;
    std::string baseline_deck;
    std::uint32_t game_seed = 0;
    std::int32_t candidate_seat = 0;
    std::int32_t first_player = 0;
    std::uint32_t max_decisions = 0;

    bool success = false;
    bool terminal = false;
    bool truncated = false;
    bool strength_eligible = true;

    std::int32_t winner_seat = -1;
    std::int32_t winner_agent = -1;
    std::int32_t candidate_score_x2 = 1;
    std::int32_t offending_agent = -1;

    std::uint32_t decisions = 0;
    std::uint32_t turns = 0;
    std::uint64_t candidate_decision_us = 0;
    std::uint64_t baseline_decision_us = 0;
    std::uint64_t candidate_nodes = 0;
    std::uint64_t baseline_nodes = 0;
    std::uint64_t projection_us = 0;
    std::uint64_t legal_actions_us = 0;
    std::uint64_t apply_us = 0;

    std::vector<std::uint64_t> candidate_decision_samples_us;
    std::vector<std::uint64_t> baseline_decision_samples_us;
    std::vector<std::uint64_t> candidate_planner_samples_us;
    std::vector<std::uint64_t> baseline_planner_samples_us;

    std::uint32_t candidate_forced_tactics = 0;
    std::uint32_t baseline_forced_tactics = 0;
    std::uint32_t candidate_plan_cache_hits = 0;
    std::uint32_t baseline_plan_cache_hits = 0;
    std::uint64_t candidate_completed_depth = 0;
    std::uint64_t baseline_completed_depth = 0;
    std::uint64_t candidate_reply_depth = 0;
    std::uint64_t baseline_reply_depth = 0;
    std::uint64_t candidate_belief_samples = 0;
    std::uint64_t baseline_belief_samples = 0;

    std::uint32_t invalid_actions = 0;
    std::uint32_t illegal_choices = 0;
    std::uint32_t controller_failures = 0;
    std::uint32_t rule_exceptions = 0;
    std::string failure_kind;
    std::string error;

    std::string final_state_hash;
    std::string semantic_result_hash;
    Value decision_trace = Value::make_array();
    Value failure_trace = Value::make_object();
};

class NativeChallengeArenaPool {
public:
    NativeChallengeArenaPool(
        Value catalog,
        Value decks,
        ChallengeArenaAgentSpec candidate,
        ChallengeArenaAgentSpec baseline,
        ChallengeArenaPoolConfig config = {}
    );
    ~NativeChallengeArenaPool();

    NativeChallengeArenaPool(const NativeChallengeArenaPool &) = delete;
    NativeChallengeArenaPool &operator=(const NativeChallengeArenaPool &) = delete;

    void start(std::vector<ChallengeArenaTask> tasks);
    void pause() noexcept;
    void resume() noexcept;
    void cancel() noexcept;
    void wait();
    bool running() const noexcept;
    bool finished() const noexcept;
    std::vector<ChallengeArenaGameResult> drain_games();
    Value metrics() const;

private:
    void worker();
    ChallengeArenaGameResult run_game(
        const ChallengeArenaTask &task,
        ChallengeController &candidate,
        ChallengeController &baseline
    );
    void wait_if_paused();

    Value catalog_;
    Value decks_;
    ChallengeArenaAgentSpec candidate_;
    ChallengeArenaAgentSpec baseline_;
    ChallengeArenaPoolConfig config_;
    std::vector<ChallengeArenaTask> tasks_;
    std::vector<std::thread> workers_;
    std::atomic<std::size_t> next_task_{0};
    std::atomic<bool> running_{false};
    std::atomic<bool> finished_{false};
    std::atomic<bool> paused_{false};
    std::atomic<bool> cancelled_{false};
    mutable std::mutex pause_mutex_;
    std::condition_variable pause_ready_;
    mutable std::mutex results_mutex_;
    std::vector<ChallengeArenaGameResult> results_;
    mutable std::mutex controllers_mutex_;
    std::vector<ChallengeController *> active_controllers_;

    std::atomic<std::uint64_t> completed_games_{0};
    std::atomic<std::uint64_t> failed_games_{0};
    std::atomic<std::uint64_t> decisions_{0};
    std::atomic<std::uint64_t> invalid_actions_{0};
    std::atomic<std::uint64_t> illegal_choices_{0};
    std::atomic<std::uint64_t> controller_failures_{0};
    std::atomic<std::uint64_t> rule_exceptions_{0};
    std::atomic<std::uint64_t> truncated_games_{0};
    std::atomic<std::uint64_t> candidate_decision_us_{0};
    std::atomic<std::uint64_t> baseline_decision_us_{0};
    std::atomic<std::uint64_t> candidate_nodes_{0};
    std::atomic<std::uint64_t> baseline_nodes_{0};
    std::atomic<std::uint64_t> projection_us_{0};
    std::atomic<std::uint64_t> legal_actions_us_{0};
    std::atomic<std::uint64_t> apply_us_{0};
};

} // namespace ptcg::ai
