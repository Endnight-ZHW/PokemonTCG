#include "policies/policy_view.hpp"
namespace ptcg::ai {
using namespace policy;
double DeckPolicy::resource_bundle_value(const PolicyView &view,
                                         const ResourceBundle &bundle) const {
    // Card utility already contains this policy's keep/discard preferences.
    // Policies may override the combination value with the same goal and
    // retained resources in both live choices and simulated choices.
    double reserves = 0.0;
    if (bundle.requirements.is_object() && bundle.retained_hand.is_array()) {
        for (const auto &[role, target] : bundle.requirements.as_object()) {
            const auto needed =
                std::max<std::int64_t>(0, target.as_integer() - view.count_role_board(role));
            const auto count = [&](const Value::Array &hand) {
                return static_cast<std::int64_t>(
                    std::count_if(hand.begin(), hand.end(), [&](const Value &card) {
                        return view.has_role(card.string_or(), role);
                    }));
            };
            // The last card satisfying a missing role matters; extra copies do
            // not each earn the same reservation bonus.
            reserves += std::min(needed, count(bundle.retained_hand.as_array())) -
                        std::min(needed, count(view.hand()));
        }
    }
    return bundle.card_utility + bundle.resource_delta * view.weight("bundle_resource", 1.0) +
           reserves * view.weight("bundle_reserve", 0.0);
}
double DeckPolicy::discard_value(const PolicyView &view, const Value &option) const {
    return view.has_role(option_card_id(option), "discard_synergy") ? view.weight("discard_synergy")
                                                                    : 0.0;
}
namespace {
class GenericPolicy final : public DeckPolicy {
  public:
    const char *id() const noexcept override { return "generic_policy_v1"; }
    bool specialized() const noexcept override { return false; }
    std::string stage(const PolicyView &view) const override { return generic_plan_stage(view); }
    double action_score(const PolicyView &view, const Value &action) const override {
        return generic_action_adjustment(view, action);
    }
    double keep_value(const PolicyView &view, const Value &choice,
                      const Value &option) const override {
        return generic_choice_keep_value(view, choice, option);
    }
    double state_score(const PolicyView &view) const override {
        return generic_state_adjustment(view);
    }
    double position_value(const PolicyView &view, const PositionFeatures &facts) const override {
        return evaluate_position(*this, view, facts, 0.5);
    }
};
} // namespace
std::shared_ptr<const DeckPolicy> make_generic_policy() {
    return std::make_shared<GenericPolicy>();
}
} // namespace ptcg::ai
