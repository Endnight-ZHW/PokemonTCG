#pragma once
#include "ptcg_value.hpp"
#include <memory>
#include <optional>
#include <string>

namespace ptcg::ai {
class RulesSession;
namespace policy {
struct PolicyView;
}

// Facts have no deck preferences. The selected policy owns their valuation.
struct PositionFeatures {
    double material = 0;
    double tactical = 0;
    double readiness = 0;
    double prize_clock_margin = 0;
};

struct ResourceBundle {
    std::string goal;
    Value requirements;
    Value retained_hand;
    double card_utility = 0;
    double resource_delta = 0;
};

class DeckPolicy {
  public:
    virtual ~DeckPolicy() = default;
    virtual double action_bonus(const RulesSession &, std::int32_t, const Value &,
                                const Value &) const {
        return 0;
    }
    virtual double choice_bonus(const RulesSession &, std::int32_t, const Value &, const Value &,
                                const Value &) const {
        return 0;
    }
    virtual const char *id() const noexcept = 0;
    virtual bool specialized() const noexcept { return true; }
    virtual bool prefer_first() const noexcept { return true; }
    // A narrow search can reserve its preferred action or explore another target.
    // The actor's policy makes this tradeoff for own, reply and recovery turns.
    virtual bool preserve_best_action() const noexcept { return true; }
    virtual std::optional<bool> confirm_choice(const RulesSession &, std::int32_t, const Value &,
                                               const Value &) const {
        return std::nullopt;
    }
    virtual std::string stage(const policy::PolicyView &view) const = 0;
    virtual double action_score(const policy::PolicyView &view, const Value &action) const = 0;
    virtual double keep_value(const policy::PolicyView &view, const Value &choice,
                              const Value &option) const = 0;
    virtual double discard_value(const policy::PolicyView &view, const Value &option) const;
    virtual double state_score(const policy::PolicyView &view) const = 0;
    virtual double position_value(const policy::PolicyView &view,
                                  const PositionFeatures &facts) const = 0;
    virtual double resource_bundle_value(const policy::PolicyView &view,
                                         const ResourceBundle &bundle) const;
};

std::shared_ptr<const DeckPolicy> make_generic_policy();
std::shared_ptr<const DeckPolicy> make_fire_policy();
std::shared_ptr<const DeckPolicy> make_water_policy();
std::shared_ptr<const DeckPolicy> make_psychic_policy();
std::shared_ptr<const DeckPolicy> make_lightning_policy();
std::shared_ptr<const DeckPolicy> make_fighting_policy();
std::shared_ptr<const DeckPolicy> make_colorless_policy();
std::shared_ptr<const DeckPolicy> make_dragon_policy();
std::shared_ptr<const DeckPolicy> make_grass_policy();
std::shared_ptr<const DeckPolicy> make_steel_policy();
std::shared_ptr<const DeckPolicy> make_darkness_policy();

} // namespace ptcg::ai
