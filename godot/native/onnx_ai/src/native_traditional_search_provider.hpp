#pragma once

#include "ptcg_traditional_infoset.hpp"
#include "ptcg_traditional_search.hpp"

#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace godot {

// Extended provider surface used by the Godot request boundary. The concrete
// implementation stays private to its translation unit so search semantics do
// not leak into NativeTraditionalAI's binding/controller class.
class NativeTraditionalSearchProvider
    : public ptcg::ai::TraditionalSearchProvider {
public:
    virtual bool trusted_leaf_enabled() const noexcept = 0;
    virtual const std::vector<std::string> &debug_trajectory_events()
        const noexcept = 0;
    virtual const Dictionary &first_rank_mismatch() const noexcept = 0;
    virtual const Dictionary &first_state_score_mismatch() const noexcept = 0;
    virtual const Dictionary &first_choice_mismatch() const noexcept = 0;
    virtual const Dictionary &debug_actions_by_signature() const noexcept = 0;
    virtual Dictionary debug_states_by_fingerprint() const = 0;
    virtual Dictionary performance_counters() const = 0;
    virtual bool select_external_choice(
        const ptcg::ai::RulesSession &position,
        const ptcg::ai::Value &pending,
        ptcg::ai::Value &response
    ) = 0;
    virtual ptcg::ai::Value post_plan_tactical_guard(
        const ptcg::ai::RulesSession &position,
        std::int32_t actor,
        const ptcg::ai::Value &preferred,
        const ptcg::ai::Value &actions,
        std::uint32_t seed,
        bool &changed
    ) = 0;
};

std::unique_ptr<NativeTraditionalSearchProvider>
make_native_traditional_search_provider(
    Callable provider,
    ptcg::ai::Value catalog,
    ptcg::ai::Value decks,
    ptcg::ai::Value strategies,
    std::int32_t root_actor,
    const ptcg::ai::TraditionalInformationSet *information_set = nullptr,
    bool debug_trajectory = false,
    bool strict_native_choices = false
);

} // namespace godot
