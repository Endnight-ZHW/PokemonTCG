#include "ptcg_ai_core.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <limits>
#include <numeric>
#include <stdexcept>

namespace ptcg::ai {

namespace {

constexpr std::uint64_t FNV_OFFSET = 1469598103934665603ULL;
constexpr std::uint64_t FNV_PRIME = 1099511628211ULL;

void hash_word(std::uint64_t &hash, std::uint32_t word) noexcept {
    for (int shift = 0; shift < 32; shift += 8) {
        hash ^= static_cast<std::uint8_t>(word >> shift);
        hash *= FNV_PRIME;
    }
}

bool finite_probability(float value) noexcept {
    return std::isfinite(value) && value >= 0.0F;
}

} // namespace

XorShift32::XorShift32(std::uint32_t seed)
    : state_(seed == 0 ? 0x6D2B79F5u : seed) {}

std::uint32_t XorShift32::state() const noexcept {
    return state_;
}

void XorShift32::set_state(std::uint32_t state) noexcept {
    state_ = state == 0 ? 0x6D2B79F5u : state;
}

std::uint32_t XorShift32::next_u32() noexcept {
    std::uint32_t value = state_;
    value ^= value << 13;
    value ^= value >> 17;
    value ^= value << 5;
    state_ = value;
    return value;
}

float XorShift32::next_unit() noexcept {
    return static_cast<float>(next_u32()) / 4294967296.0F;
}

CompactState::CompactState(std::size_t word_count)
    : words_(word_count, 0) {}

std::size_t CompactState::size() const noexcept {
    return words_.size();
}

std::int32_t CompactState::get(std::size_t index) const {
    return words_.at(index);
}

void CompactState::set(std::size_t index, std::int32_t value) {
    const std::int32_t previous = words_.at(index);
    if (previous == value) {
        return;
    }
    if (index > std::numeric_limits<std::uint32_t>::max()) {
        throw std::overflow_error("compact_state_index_overflow");
    }
    journal_.push_back({
        static_cast<std::uint32_t>(index),
        previous,
    });
    words_[index] = value;
}

UndoMark CompactState::mark() const noexcept {
    return {journal_.size()};
}

void CompactState::undo(UndoMark mark) {
    if (mark.journal_size > journal_.size()) {
        throw std::invalid_argument("invalid_undo_mark");
    }
    while (journal_.size() > mark.journal_size) {
        const JournalEntry entry = journal_.back();
        journal_.pop_back();
        words_[entry.index] = entry.previous;
    }
}

void CompactState::clear_journal() noexcept {
    journal_.clear();
}

const std::vector<std::int32_t> &CompactState::words() const noexcept {
    return words_;
}

std::uint64_t information_set_hash(
    const std::vector<std::int32_t> &public_words,
    const std::vector<std::int32_t> &actor_private_words,
    std::int32_t actor
) noexcept {
    std::uint64_t hash = FNV_OFFSET;
    hash_word(hash, 0x50544347u);
    hash_word(hash, static_cast<std::uint32_t>(actor));
    hash_word(hash, static_cast<std::uint32_t>(public_words.size()));
    for (const std::int32_t word : public_words) {
        hash_word(hash, static_cast<std::uint32_t>(word));
    }
    hash_word(hash, 0x49534554u);
    hash_word(hash, static_cast<std::uint32_t>(actor_private_words.size()));
    for (const std::int32_t word : actor_private_words) {
        hash_word(hash, static_cast<std::uint32_t>(word));
    }
    return hash;
}

float PuctCandidate::q() const noexcept {
    return visits == 0
        ? 0.0F
        : value_sum / static_cast<float>(visits);
}

std::uint64_t PuctCandidate::selection_visits() const noexcept {
    return static_cast<std::uint64_t>(visits) + in_flight;
}

float PuctCandidate::selection_q(float virtual_loss) const noexcept {
    const std::uint64_t selected_visits = selection_visits();
    return selected_visits == 0
        ? 0.0F
        : (
            value_sum
            - virtual_loss * static_cast<float>(in_flight)
        ) / static_cast<float>(selected_visits);
}

PuctNode::PuctNode(std::int32_t actor)
    : actor_(actor) {}

void PuctNode::expand(
    const std::vector<std::uint64_t> &signatures,
    const std::vector<float> &priors
) {
    if (expanded_) {
        throw std::logic_error("puct_node_already_expanded");
    }
    if (signatures.empty() || signatures.size() != priors.size()) {
        throw std::invalid_argument("invalid_puct_expansion");
    }
    float total = 0.0F;
    for (const float prior : priors) {
        if (!finite_probability(prior)) {
            throw std::invalid_argument("invalid_puct_prior");
        }
        total += prior;
    }
    if (!std::isfinite(total) || total <= 0.0F) {
        throw std::invalid_argument("empty_puct_prior");
    }
    edges_.reserve(signatures.size());
    for (std::size_t index = 0; index < signatures.size(); ++index) {
        edges_.push_back({
            signatures[index],
            priors[index] / total,
            0,
            0.0F,
            0,
        });
    }
    expanded_ = true;
}

std::size_t PuctNode::ensure_edge(
    std::uint64_t signature,
    float probability
) {
    if (!finite_probability(probability) || probability <= 0.0F) {
        throw std::invalid_argument("invalid_chance_probability");
    }
    const auto existing = std::find_if(
        edges_.begin(),
        edges_.end(),
        [signature](const PuctCandidate &edge) {
            return edge.signature == signature;
        }
    );
    if (existing != edges_.end()) {
        return static_cast<std::size_t>(
            existing - edges_.begin()
        );
    }
    edges_.push_back({
        signature,
        probability,
        0,
        0.0F,
        0,
    });
    expanded_ = true;
    return edges_.size() - 1;
}

bool PuctNode::expanded() const noexcept {
    return expanded_;
}

std::size_t PuctNode::size() const noexcept {
    return edges_.size();
}

std::size_t PuctNode::select(float c_puct) const {
    if (!expanded_ || edges_.empty() || !std::isfinite(c_puct)) {
        throw std::logic_error("cannot_select_unexpanded_puct_node");
    }
    const std::uint64_t visits = std::accumulate(
        edges_.begin(),
        edges_.end(),
        std::uint64_t{0},
        [](std::uint64_t total, const PuctCandidate &edge) {
            return total + edge.selection_visits();
        }
    );
    const float scale = std::sqrt(
        static_cast<float>(std::max<std::uint64_t>(1, visits))
    );
    std::size_t selected = 0;
    float selected_score = -std::numeric_limits<float>::infinity();
    for (std::size_t index = 0; index < edges_.size(); ++index) {
        const PuctCandidate &edge = edges_[index];
        const float score = edge.selection_q()
            + c_puct * edge.prior * scale
                / static_cast<float>(1 + edge.selection_visits());
        if (
            score > selected_score
            || (
                score == selected_score
                && edge.signature < edges_[selected].signature
            )
        ) {
            selected = index;
            selected_score = score;
        }
    }
    return selected;
}

void PuctNode::reserve(std::size_t edge_index) {
    PuctCandidate &selected = edges_.at(edge_index);
    if (selected.in_flight == std::numeric_limits<std::uint32_t>::max()) {
        throw std::overflow_error("puct_virtual_visit_overflow");
    }
    ++selected.in_flight;
}

void PuctNode::release(std::size_t edge_index) {
    PuctCandidate &selected = edges_.at(edge_index);
    if (selected.in_flight == 0) {
        throw std::logic_error("puct_virtual_visit_underflow");
    }
    --selected.in_flight;
}

void PuctNode::backup(std::size_t edge_index, float actor_value) {
    if (!std::isfinite(actor_value) || actor_value < -1.0F || actor_value > 1.0F) {
        throw std::invalid_argument("invalid_backup_value");
    }
    PuctCandidate &selected = edges_.at(edge_index);
    ++selected.visits;
    selected.value_sum += actor_value;
}

const PuctCandidate &PuctNode::edge(std::size_t index) const {
    return edges_.at(index);
}

PuctCandidate &PuctNode::edge(std::size_t index) {
    return edges_.at(index);
}

std::int32_t PuctNode::actor() const noexcept {
    return actor_;
}

PuctNode &PuctTree::node(std::uint64_t key, std::int32_t actor) {
    const auto [iterator, inserted] = nodes_.try_emplace(key, actor);
    if (!inserted && iterator->second.actor() != actor) {
        throw std::logic_error("infoset_actor_collision");
    }
    return iterator->second;
}

const PuctNode *PuctTree::find(std::uint64_t key) const noexcept {
    const auto iterator = nodes_.find(key);
    return iterator == nodes_.end() ? nullptr : &iterator->second;
}

void PuctTree::clear() noexcept {
    nodes_.clear();
}

std::size_t PuctTree::size() const noexcept {
    return nodes_.size();
}

std::size_t InferenceRequest::candidate_count() const noexcept {
    return candidate_card_ids.size();
}

void InferenceRequest::validate() const {
    const std::size_t count = candidate_count();
    if (count == 0) {
        throw std::invalid_argument("candidate_set_empty");
    }
    if (
        candidate_numeric.size() != count * CANDIDATE_NUMERIC_SIZE
        || candidate_type_ids.size() != count
        || candidate_refs.size() != count * CANDIDATE_REF_FIELDS
    ) {
        throw std::invalid_argument("candidate_tensor_shape_mismatch");
    }
    if (
        !std::all_of(
            state_global.begin(),
            state_global.end(),
            [](float value) { return std::isfinite(value); }
        )
        || !std::all_of(
            entity_numeric.begin(),
            entity_numeric.end(),
            [](float value) { return std::isfinite(value); }
        )
        || !std::all_of(
            candidate_numeric.begin(),
            candidate_numeric.end(),
            [](float value) { return std::isfinite(value); }
        )
    ) {
        throw std::invalid_argument("non_finite_inference_input");
    }
}

void InferenceResponse::validate(std::size_t candidate_count) const {
    if (policy.size() != candidate_count) {
        throw std::invalid_argument("policy_size_mismatch");
    }
    float policy_total = 0.0F;
    for (const float probability : policy) {
        if (!finite_probability(probability)) {
            throw std::invalid_argument("invalid_policy_probability");
        }
        policy_total += probability;
    }
    float wdl_total = 0.0F;
    for (const float probability : wdl) {
        if (!finite_probability(probability)) {
            throw std::invalid_argument("invalid_wdl_probability");
        }
        wdl_total += probability;
    }
    if (
        std::abs(policy_total - 1.0F) > 1e-4F
        || std::abs(wdl_total - 1.0F) > 1e-4F
    ) {
        throw std::invalid_argument("inference_output_not_normalized");
    }
}

std::uint64_t NativeSelfPlayBatch::enqueue(InferenceRequest request) {
    request.validate();
    std::lock_guard<std::mutex> lock(mutex_);
    if (closed_) {
        throw std::logic_error("native_batch_closed");
    }
    request.request_id = next_request_id_++;
    expected_candidates_[request.request_id] = request.candidate_count();
    pending_.push_back(std::move(request));
    ready_.notify_one();
    return pending_.back().request_id;
}

std::vector<InferenceRequest> NativeSelfPlayBatch::poll_inference(
    std::size_t max_requests,
    std::uint32_t wait_milliseconds,
    std::size_t target_requests,
    std::uint32_t coalesce_milliseconds
) {
    if (
        max_requests == 0
        || target_requests == 0
        || target_requests > max_requests
    ) {
        throw std::invalid_argument("invalid_poll_batch_config");
    }
    std::unique_lock<std::mutex> lock(mutex_);
    if (pending_.empty() && !closed_ && wait_milliseconds > 0) {
        ready_.wait_for(
            lock,
            std::chrono::milliseconds(wait_milliseconds),
            [this]() { return !pending_.empty() || closed_; }
        );
    }
    if (
        !pending_.empty()
        && !closed_
        && pending_.size() < target_requests
        && coalesce_milliseconds > 0
    ) {
        ready_.wait_for(
            lock,
            std::chrono::milliseconds(coalesce_milliseconds),
            [this, target_requests]() {
                return pending_.size() >= target_requests || closed_;
            }
        );
    }
    std::vector<InferenceRequest> result;
    result.reserve(std::min(max_requests, pending_.size()));
    while (!pending_.empty() && result.size() < max_requests) {
        result.push_back(std::move(pending_.front()));
        pending_.pop_front();
    }
    return result;
}

void NativeSelfPlayBatch::submit_inference(
    const std::vector<InferenceResponse> &responses
) {
    std::lock_guard<std::mutex> lock(mutex_);
    for (const InferenceResponse &response : responses) {
        const auto discarded = discarded_requests_.find(
            response.request_id
        );
        if (discarded != discarded_requests_.end()) {
            discarded_requests_.erase(discarded);
            continue;
        }
        const auto expected = expected_candidates_.find(response.request_id);
        if (expected == expected_candidates_.end()) {
            throw std::invalid_argument("unknown_inference_request");
        }
        response.validate(expected->second);
        if (!responses_.emplace(response.request_id, response).second) {
            throw std::invalid_argument("duplicate_inference_response");
        }
    }
    ready_.notify_all();
}

std::optional<InferenceResponse> NativeSelfPlayBatch::take_response(
    std::uint64_t request_id
) {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto response = responses_.find(request_id);
    if (response == responses_.end()) {
        return std::nullopt;
    }
    InferenceResponse result = std::move(response->second);
    responses_.erase(response);
    expected_candidates_.erase(request_id);
    return result;
}

std::optional<InferenceResponse> NativeSelfPlayBatch::wait_response(
    std::uint64_t request_id,
    std::uint32_t wait_milliseconds
) {
    std::unique_lock<std::mutex> lock(mutex_);
    if (responses_.find(request_id) == responses_.end() && !closed_) {
        ready_.wait_for(
            lock,
            std::chrono::milliseconds(wait_milliseconds),
            [this, request_id]() {
                return responses_.find(request_id) != responses_.end()
                    || closed_;
            }
        );
    }
    const auto response = responses_.find(request_id);
    if (response == responses_.end()) {
        return std::nullopt;
    }
    InferenceResponse result = std::move(response->second);
    responses_.erase(response);
    expected_candidates_.erase(request_id);
    return result;
}

bool NativeSelfPlayBatch::discard_request(
    std::uint64_t request_id
) noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto expected = expected_candidates_.find(request_id);
    if (expected == expected_candidates_.end()) {
        return false;
    }
    const auto pending = std::find_if(
        pending_.begin(),
        pending_.end(),
        [request_id](const InferenceRequest &request) {
            return request.request_id == request_id;
        }
    );
    const bool was_pending = pending != pending_.end();
    if (was_pending) {
        pending_.erase(pending);
    } else {
        // A poller may already own this request. Remember it so a late
        // response can be ignored without turning cancellation into a batch
        // protocol failure.
        discarded_requests_.insert(request_id);
    }
    responses_.erase(request_id);
    expected_candidates_.erase(expected);
    ready_.notify_all();
    return true;
}

void NativeSelfPlayBatch::append_sample(TrainingSample sample) {
    sample.input.validate();
    if (sample.policy_target.size() != sample.input.candidate_count()) {
        throw std::invalid_argument("sample_policy_size_mismatch");
    }
    InferenceResponse validation{
        0,
        sample.policy_target,
        sample.wdl_target,
    };
    validation.validate(sample.input.candidate_count());
    std::lock_guard<std::mutex> lock(mutex_);
    samples_.push_back(std::move(sample));
}

std::vector<TrainingSample> NativeSelfPlayBatch::drain_samples() {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<TrainingSample> result;
    result.swap(samples_);
    return result;
}

std::size_t NativeSelfPlayBatch::pending_requests() const noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    return pending_.size();
}

void NativeSelfPlayBatch::close() noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    closed_ = true;
    ready_.notify_all();
}

bool NativeSelfPlayBatch::closed() const noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    return closed_;
}

} // namespace ptcg::ai
