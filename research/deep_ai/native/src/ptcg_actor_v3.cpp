#include "ptcg_actor_v3.hpp"

#include "ptcg_encoder_v3.hpp"
#include "ptcg_game.hpp"
#include "ptcg_infoset.hpp"
#include "ptcg_rules_session.hpp"

#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <utility>

namespace ptcg::ai {

namespace {

using Array = Value::Array;
using Object = Value::Object;

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

bool terminal_state(const Value &state) {
    const std::string status = string_field(state, "result_status");
    return status == "WIN" || status == "DRAW"
        || string_field(state, "phase") == "GAME_OVER";
}

std::int32_t state_actor(const Value &state) {
    const Value *promotions = state.find("pending_promotions");
    if (
        promotions != nullptr && promotions->is_array()
        && !promotions->as_array().empty()
    ) {
        const std::int32_t actor = static_cast<std::int32_t>(
            promotions->as_array().front().as_integer(-1)
        );
        if (actor == 0 || actor == 1) return actor;
    }
    if (string_field(state, "setup_stage") != "COMPLETE") {
        const std::int32_t setup = static_cast<std::int32_t>(
            integer_field(state, "setup_actor_idx", -1)
        );
        if (setup == 0 || setup == 1) return setup;
    }
    return static_cast<std::int32_t>(
        integer_field(state, "active_player_idx", -1)
    );
}

std::vector<std::string> expand_deck(
    const Value &decks,
    const std::string &deck_key
) {
    const Value *definition = decks.find(deck_key);
    if (definition == nullptr) {
        throw std::invalid_argument("v3_actor_unknown_deck:" + deck_key);
    }
    const Value *rows = definition;
    if (definition->is_object()) rows = definition->find("cards");
    if (rows == nullptr || !rows->is_array()) {
        throw std::invalid_argument("v3_actor_invalid_deck:" + deck_key);
    }
    std::vector<std::string> result;
    for (const Value &row : rows->as_array()) {
        if (row.is_string()) {
            result.push_back(row.string_or());
            continue;
        }
        if (!row.is_object()) {
            throw std::invalid_argument("v3_actor_invalid_deck_row");
        }
        const std::string card_id = string_field(row, "card_id");
        const std::int64_t count = integer_field(row, "count", 0);
        if (card_id.empty() || count <= 0 || count > 60) {
            throw std::invalid_argument("v3_actor_invalid_deck_entry");
        }
        result.insert(result.end(), static_cast<std::size_t>(count), card_id);
    }
    if (result.size() != 60) {
        throw std::invalid_argument(
            "v3_actor_deck_must_have_60_cards:" + deck_key
        );
    }
    return result;
}

Value deck_value(const std::vector<std::string> &cards) {
    Array result;
    result.reserve(cards.size());
    for (const std::string &card : cards) result.emplace_back(card);
    return Value(std::move(result));
}

float temperature_for_turn(std::int64_t turn) noexcept {
    if (turn <= 6) return 1.0F;
    if (turn <= 12) return 0.5F;
    return 0.1F;
}

Value choice_response(
    const Value &pending,
    const Value &candidate
) {
    const Value *selected = candidate.find("selected_options");
    return Value(Object{
        {"request_id", Value(string_field(pending, "request_id"))},
        {
            "option_ids",
            selected != nullptr && selected->is_array()
                ? selected->deep_clone() : Value::make_array(),
        },
        {"cancelled", Value(
            candidate.find("cancelled") != nullptr
                && candidate.find("cancelled")->as_bool(false)
        )},
    });
}

Value forced_turn_order_response(
    const Value &pending,
    std::int32_t first_player
) {
    const std::int32_t actor = static_cast<std::int32_t>(
        integer_field(pending, "player", -1)
    );
    Array selected;
    selected.emplace_back(actor == first_player ? "turn:first" : "turn:second");
    return Value(Object{
        {"request_id", Value(string_field(pending, "request_id"))},
        {"option_ids", Value(std::move(selected))},
        {"cancelled", Value(false)},
    });
}

std::uint64_t stable_game_hash(const RulesSession &session) {
    const std::string hash = session.state_hash();
    std::uint64_t result = 1469598103934665603ULL;
    for (const unsigned char value : hash) {
        result ^= value;
        result *= 1099511628211ULL;
    }
    return result;
}

ActorGameResultV3 task_result(const GameTaskV3 &task) {
    ActorGameResultV3 result;
    result.game_id = task.game_id;
    result.cycle = task.cycle;
    result.deck_a = task.deck_a;
    result.deck_b = task.deck_b;
    result.seed = task.seed;
    result.seat_a = task.seat_a;
    result.first_player = task.first_player;
    result.model_slots = task.model_slots;
    result.model_versions = task.model_versions;
    result.max_decisions = task.max_decisions;
    return result;
}

} // namespace

NativeActorPoolV3::NativeActorPoolV3(
    Value catalog,
    Value decks,
    std::shared_ptr<NativeSelfPlayBatch> batch,
    std::shared_ptr<NativeSearchLimiter> limiter,
    ActorPoolConfigV3 config
) :
    catalog_(std::move(catalog)),
    cards_(
        catalog_.find("cards") != nullptr
            ? *catalog_.find("cards") : catalog_
    ),
    decks_(std::move(decks)),
    batch_(std::move(batch)),
    limiter_(std::move(limiter)),
    config_(config) {
    if (!batch_ || !limiter_) {
        throw std::invalid_argument("v3_actor_pool_batch_or_limiter_missing");
    }
    if (
        config_.concurrent_games == 0 || config_.simulations == 0
        || config_.max_depth == 0 || config_.max_inflight_leaves == 0
        || config_.max_inflight_leaves > config_.simulations
        || !std::isfinite(config_.c_puct)
        || !std::isfinite(config_.dirichlet_epsilon)
        || (config_.direct_policy && config_.training)
    ) {
        throw std::invalid_argument("invalid_v3_actor_pool_config");
    }
}

NativeActorPoolV3::~NativeActorPoolV3() {
    cancel();
    wait();
}

void NativeActorPoolV3::start(std::vector<GameTaskV3> tasks) {
    if (running_.exchange(true) || !workers_.empty()) {
        running_ = true;
        throw std::logic_error("v3_actor_pool_already_started");
    }
    if (tasks.empty()) {
        running_ = false;
        throw std::invalid_argument("v3_actor_pool_tasks_empty");
    }
    for (const GameTaskV3 &task : tasks) {
        if (
            task.game_id.empty() || task.seat_a < 0 || task.seat_a > 1
            || task.first_player < 0 || task.first_player > 1
            || task.max_decisions == 0
        ) {
            running_ = false;
            throw std::invalid_argument("invalid_v3_game_task");
        }
    }
    tasks_ = std::move(tasks);
    next_task_ = 0;
    cancelled_ = false;
    paused_ = false;
    finished_ = false;
    const std::size_t count = std::min<std::size_t>(
        config_.concurrent_games,
        tasks_.size()
    );
    workers_.reserve(count);
    for (std::size_t index = 0; index < count; ++index) {
        workers_.emplace_back(&NativeActorPoolV3::worker, this);
    }
}

void NativeActorPoolV3::pause() noexcept {
    paused_ = true;
}

void NativeActorPoolV3::resume() noexcept {
    paused_ = false;
    pause_ready_.notify_all();
}

void NativeActorPoolV3::cancel() noexcept {
    cancelled_ = true;
    paused_ = false;
    pause_ready_.notify_all();
}

void NativeActorPoolV3::wait() {
    for (std::thread &worker_thread : workers_) {
        if (worker_thread.joinable()) worker_thread.join();
    }
    workers_.clear();
    running_ = false;
    finished_ = true;
}

bool NativeActorPoolV3::running() const noexcept {
    return running_;
}

bool NativeActorPoolV3::finished() const noexcept {
    return finished_;
}

std::vector<ActorGameResultV3> NativeActorPoolV3::drain_games() {
    std::lock_guard<std::mutex> lock(results_mutex_);
    std::vector<ActorGameResultV3> result;
    result.swap(results_);
    return result;
}

Value NativeActorPoolV3::metrics() const {
    return Value(Object{
        {"tasks", Value(static_cast<std::int64_t>(tasks_.size()))},
        {"completed_games", Value(static_cast<std::int64_t>(completed_games_.load()))},
        {"failed_games", Value(static_cast<std::int64_t>(failed_games_.load()))},
        {"decisions", Value(static_cast<std::int64_t>(decisions_.load()))},
        {"simulations", Value(static_cast<std::int64_t>(simulations_.load()))},
        {"samples", Value(static_cast<std::int64_t>(samples_.load()))},
        {"determinization_microseconds", Value(static_cast<std::int64_t>(
            determinization_microseconds_.load()))},
        {"projection_microseconds", Value(static_cast<std::int64_t>(
            projection_microseconds_.load()))},
        {"candidate_generation_microseconds", Value(static_cast<std::int64_t>(
            candidate_generation_microseconds_.load()))},
        {"apply_microseconds", Value(static_cast<std::int64_t>(
            apply_microseconds_.load()))},
        {"encoding_microseconds", Value(static_cast<std::int64_t>(
            encoding_microseconds_.load()))},
        {"inference_wait_microseconds", Value(static_cast<std::int64_t>(
            inference_wait_microseconds_.load()))},
        {"running", Value(running_.load())},
        {"finished", Value(finished_.load())},
        {"paused", Value(paused_.load())},
        {"cancelled", Value(cancelled_.load())},
    });
}

void NativeActorPoolV3::wait_if_paused() {
    if (!paused_) return;
    std::unique_lock<std::mutex> lock(pause_mutex_);
    pause_ready_.wait(lock, [this]() {
        return !paused_.load() || cancelled_.load();
    });
}

void NativeActorPoolV3::worker() {
    // These objects own the determinizer, tree/search scratch buffers and
    // encoder/card lookup context. A worker reuses them across every game it
    // drains while each game still receives an isolated RulesSession.
    NativeSearchJob search(cards_, decks_, batch_, limiter_);
    NativeInformationSetEncoderV3 encoder(cards_);
    NativeGameKernel game(cards_);
    while (!cancelled_) {
        wait_if_paused();
        const std::size_t index = next_task_.fetch_add(1);
        if (index >= tasks_.size()) break;
        ActorGameResultV3 result;
        try {
            result = run_game(tasks_[index], search, encoder, game);
        } catch (const std::exception &error) {
            result = task_result(tasks_[index]);
            result.error = error.what();
        } catch (...) {
            result = task_result(tasks_[index]);
            result.error = "unknown_v3_actor_error";
        }
        if (result.success) ++completed_games_;
        else ++failed_games_;
        decisions_ += result.decisions;
        simulations_ += result.simulations;
        samples_ += result.samples;
        determinization_microseconds_ += result.determinization_microseconds;
        projection_microseconds_ += result.projection_microseconds;
        candidate_generation_microseconds_ +=
            result.candidate_generation_microseconds;
        apply_microseconds_ += result.apply_microseconds;
        encoding_microseconds_ += result.encoding_microseconds;
        inference_wait_microseconds_ += result.inference_wait_microseconds;
        std::lock_guard<std::mutex> lock(results_mutex_);
        results_.push_back(std::move(result));
    }
}

ActorGameResultV3 NativeActorPoolV3::run_game(
    const GameTaskV3 &task,
    NativeSearchJob &search,
    NativeInformationSetEncoderV3 &encoder,
    NativeGameKernel &game
) {
    ActorGameResultV3 summary = task_result(task);
    const std::vector<std::string> deck_a = expand_deck(decks_, task.deck_a);
    const std::vector<std::string> deck_b = expand_deck(decks_, task.deck_b);
    Array seat_decks(2);
    Array deck_keys(2);
    seat_decks[static_cast<std::size_t>(task.seat_a)] = deck_value(deck_a);
    seat_decks[static_cast<std::size_t>(1 - task.seat_a)] = deck_value(deck_b);
    deck_keys[static_cast<std::size_t>(task.seat_a)] = Value(task.deck_a);
    deck_keys[static_cast<std::size_t>(1 - task.seat_a)] = Value(task.deck_b);
    RulesSession session;
    RulesSessionResult created = session.create(
        catalog_,
        Value(std::move(seat_decks)),
        Value(Object{
            {"public_deck_keys", Value(std::move(deck_keys))},
            {"player_names", Value(Array{Value("AI-0"), Value("AI-1")})},
            {"rules_profile_id", Value("CN_MAINLAND_3_1_0")},
            {"rules_options", Value(Object{{"apply_type_matchups", Value(false)}})},
        }),
        task.seed
    );
    if (!created.success) {
        summary.error = "v3_actor_create_failed:" + created.error_code;
        return summary;
    }

    std::vector<TrainingSample> pending_samples;
    pending_samples.reserve(task.max_decisions);

    for (std::uint32_t ply = 0; ply < task.max_decisions; ++ply) {
        if (cancelled_) {
            summary.error = "v3_actor_cancelled";
            return summary;
        }
        wait_if_paused();
        Value state = session.snapshot();
        if (terminal_state(state)) {
            summary.terminal = true;
            summary.winner = static_cast<std::int32_t>(
                integer_field(state, "winner", -1)
            );
            break;
        }
        Value pending;
        std::int32_t actor = -1;
        for (std::int32_t candidate_actor = 0; candidate_actor < 2; ++candidate_actor) {
            pending = session.pending_choice(candidate_actor);
            if (pending.is_object() && !pending.as_object().empty()) {
                actor = candidate_actor;
                break;
            }
        }
        if (actor < 0) actor = state_actor(state);
        if (actor < 0 || actor > 1) {
            summary.error = "v3_actor_invalid_decision_actor";
            return summary;
        }
        if (string_field(pending, "request_type") == "choose_turn_order") {
            RulesSessionResult applied = session.apply_choice(
                forced_turn_order_response(pending, task.first_player)
            );
            if (!applied.success) {
                summary.error = "v3_actor_turn_order_failed:" + applied.error_code;
                return summary;
            }
            continue;
        }
        // Setup settlement has session-level transitions (notably
        // SETUP_DONE) that deliberately do not exist in NativeGameKernel.
        // Resolve the complete setup through the persistent authoritative
        // session before starting PUCT; training begins at the first normal
        // turn decision.
        if (string_field(state, "setup_stage") != "COMPLETE") {
            RulesSessionResult setup_result;
            if (pending.is_object() && !pending.as_object().empty()) {
                Value candidates = NativeGameKernel::choice_candidates(pending);
                if (!candidates.is_array() || candidates.as_array().empty()) {
                    summary.error = "v3_actor_setup_choice_empty";
                    return summary;
                }
                setup_result = session.apply_choice(choice_response(
                    pending,
                    candidates.as_array().front()
                ));
            } else {
                Value actions = game.legal_actions(state, actor);
                if (!actions.is_array() || actions.as_array().empty()) {
                    summary.error = "v3_actor_setup_action_empty";
                    return summary;
                }
                Value action = actions.as_array().front();
                action["action_id"] = Value(
                    "v3-setup:" + task.game_id + ":"
                    + std::to_string(session.revision())
                );
                action["base_revision"] = Value(session.revision());
                setup_result = session.apply_action(action);
            }
            if (!setup_result.success) {
                summary.error = "v3_actor_setup_failed:"
                    + setup_result.error_code;
                return summary;
            }
            continue;
        }
        Value root_candidates = pending.is_object() && !pending.as_object().empty()
            ? NativeGameKernel::choice_candidates(pending)
            : game.legal_actions(state, actor);
        if (!root_candidates.is_array() || root_candidates.as_array().empty()) {
            summary.error = "v3_actor_candidate_set_empty";
            return summary;
        }
        NativeSearchConfig search_config;
        search_config.simulations = config_.simulations;
        search_config.max_depth = config_.max_depth;
        search_config.max_inflight_leaves = config_.max_inflight_leaves;
        search_config.inference_wait_milliseconds = config_.inference_wait_milliseconds;
        search_config.c_puct = config_.c_puct;
        search_config.dirichlet_epsilon = config_.training
            ? config_.dirichlet_epsilon : 0.0F;
        search_config.temperature = config_.training
            ? temperature_for_turn(integer_field(state, "turn_number")) : 0.0F;
        search_config.training = config_.training;
        search_config.model_slot = task.model_slots[static_cast<std::size_t>(actor)];
        const std::uint32_t decision_seed = static_cast<std::uint32_t>(
            task.seed + ply * 104729U
        );
        Value selected_candidate;
        NativeSearchResult searched;
        if (config_.direct_policy) {
            selected_candidate = root_candidates.as_array().front();
            ++summary.decisions;
        } else {
            if (pending.is_object() && !pending.as_object().empty()) {
                search.start_choice(
                    state,
                    actor,
                    pending,
                    session.search_continuation(),
                    decision_seed,
                    search_config
                );
            } else {
                search.start(state, actor, decision_seed, search_config);
            }
            searched = search.wait();
            if (!searched.success) {
                summary.error = "v3_actor_search_failed:" + searched.error;
                return summary;
            }
            selected_candidate = searched.selected;
            ++summary.decisions;
            summary.simulations += searched.simulations;
            summary.determinization_microseconds +=
                searched.determinization_microseconds;
            summary.projection_microseconds +=
                searched.projection_microseconds;
            summary.candidate_generation_microseconds +=
                searched.candidate_generation_microseconds;
            summary.apply_microseconds += searched.apply_microseconds;
            summary.encoding_microseconds += searched.encoding_microseconds;
            summary.inference_wait_microseconds +=
                searched.inference_wait_microseconds;
        }
        if (config_.training && !config_.direct_policy) {
            const InformationSetProjection projection = project_information_set(
                state, actor
            );
            TrainingSample sample;
            sample.input = pending.is_object() && !pending.as_object().empty()
                ? encoder.encode_choices(
                    projection.observation,
                    pending,
                    searched.candidates
                )
                : encoder.encode_actions(
                    projection.observation,
                    searched.candidates
                );
            sample.input.model_slot = search_config.model_slot;
            for (const Value &probability : searched.probabilities.as_array()) {
                sample.policy_target.push_back(
                    static_cast<float>(probability.as_number())
                );
            }
            sample.actor = actor;
            sample.game_id = task.game_id;
            sample.game_seed = task.seed;
            sample.ply = static_cast<std::int32_t>(ply);
            sample.model_version = task.model_versions[static_cast<std::size_t>(actor)];
            sample.cycle = task.cycle;
            sample.phase_bucket = std::min<std::int32_t>(
                3,
                static_cast<std::int32_t>(integer_field(state, "turn_number") / 6)
            );
            pending_samples.push_back(std::move(sample));
        }
        RulesSessionResult applied;
        if (pending.is_object() && !pending.as_object().empty()) {
            applied = session.apply_choice(choice_response(
                pending, selected_candidate
            ));
        } else {
            Value action = std::move(selected_candidate);
            action["action_id"] = Value(
                "v3:" + task.game_id + ":" + std::to_string(session.revision())
            );
            action["base_revision"] = Value(session.revision());
            applied = session.apply_action(action);
        }
        if (!applied.success) {
            summary.error = "v3_actor_apply_failed:" + applied.error_code;
            return summary;
        }
    }

    Value final_state = session.snapshot();
    summary.terminal = terminal_state(final_state);
    summary.truncated = !summary.terminal;
    summary.winner = static_cast<std::int32_t>(
        integer_field(final_state, "winner", -1)
    );
    if (summary.truncated) {
        summary.error = "v3_actor_decision_cap";
        return summary;
    }
    for (TrainingSample &sample : pending_samples) {
        if (summary.winner < 0) {
            sample.wdl_target = {0.0F, 1.0F, 0.0F};
        } else if (summary.winner == sample.actor) {
            sample.wdl_target = {1.0F, 0.0F, 0.0F};
        } else {
            sample.wdl_target = {0.0F, 0.0F, 1.0F};
        }
        batch_->append_sample(std::move(sample));
        ++summary.samples;
    }
    summary.state_hash = stable_game_hash(session);
    summary.success = true;
    return summary;
}

} // namespace ptcg::ai
