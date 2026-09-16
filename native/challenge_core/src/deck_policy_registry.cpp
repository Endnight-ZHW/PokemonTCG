#include "deck_policy_registry.hpp"
#include "policies/policy_view.hpp"

namespace ptcg::ai {
using namespace policy;
namespace {
enum class PlanCardKind { Any, Pokemon, Trainer };
const Value *strategy_profile(const Value &strategies, const std::string &deck_key) {
    const Value *profile = strategies.find(deck_key);
    return profile != nullptr && profile->is_object() ? profile : nullptr;
}

bool plan_card_matches(const Value &cards, const std::string &card_id, PlanCardKind kind) {
    if (kind == PlanCardKind::Pokemon)
        return is_pokemon(cards, card_id);
    if (kind == PlanCardKind::Trainer)
        return is_trainer(cards, card_id);
    return card(cards, card_id) != nullptr;
}

void append_role_cards(const Value &profile, const Value &cards,
                       const std::vector<std::string> &role_names, PlanCardKind kind,
                       std::set<std::string> &result) {
    const Value *roles = field(profile, "card_roles");
    if (roles == nullptr || !roles->is_object())
        return;
    for (const std::string &role_name : role_names) {
        const Value *values = field(*roles, role_name);
        if (values == nullptr || !values->is_array())
            continue;
        for (const Value &value : values->as_array()) {
            const std::string card_id = value.string_or();
            if (!card_id.empty() && plan_card_matches(cards, card_id, kind)) {
                result.insert(card_id);
            }
        }
    }
}

Value string_set_value(const std::set<std::string> &values) {
    Value::Array result;
    result.reserve(values.size());
    for (const std::string &value : values)
        result.emplace_back(value);
    return Value(std::move(result));
}

Value normalized_deck_plan(const Value &profile, const Value &cards) {
    const auto role_set = [&](std::initializer_list<const char *> role_names, PlanCardKind kind) {
        std::vector<std::string> names;
        names.reserve(role_names.size());
        for (const char *name : role_names)
            names.emplace_back(name);
        std::set<std::string> values;
        append_role_cards(profile, cards, names, kind, values);
        return values;
    };
    std::set<std::string> trainer_cards;
    const Value *roles = field(profile, "card_roles");
    if (roles != nullptr && roles->is_object()) {
        std::vector<std::string> all_roles;
        all_roles.reserve(roles->as_object().size());
        for (const auto &[role_name, ignored] : roles->as_object()) {
            (void)ignored;
            all_roles.push_back(role_name);
        }
        append_role_cards(profile, cards, all_roles, PlanCardKind::Trainer, trainer_cards);
    }
    std::set<std::string> energy_types;
    for (const std::string &energy_id : role_set({"energy"}, PlanCardKind::Any)) {
        const Value *definition = card(cards, energy_id);
        if (definition == nullptr)
            continue;
        for (const Value &provided : array_field(*definition, "provides_energy")) {
            const std::string energy_type = provided.string_or();
            if (!energy_type.empty())
                energy_types.insert(energy_type);
        }
    }
    const Value *card_roles = field(profile, "card_roles");
    return Value(Value::Object{
        {"core", string_set_value(role_set({"primary_attacker"}, PlanCardKind::Pokemon))},
        {"engine", string_set_value(
                       role_set({"bench_engine", "energy_acceleration"}, PlanCardKind::Pokemon))},
        {"setup", string_set_value(role_set({"setup_basic"}, PlanCardKind::Pokemon))},
        {"bench", string_set_value(role_set({"bench_engine", "secondary_attacker", "setup_basic"},
                                            PlanCardKind::Pokemon))},
        {"evolution", string_set_value(role_set({"evolution"}, PlanCardKind::Pokemon))},
        {"trainer", string_set_value(trainer_cards)},
        {"energy", string_set_value(energy_types)},
        {"card_roles", card_roles != nullptr && card_roles->is_object() ? card_roles->deep_clone()
                                                                        : Value::make_object()},
        // This is a global tactical heuristic, not deck knowledge. Individual
        // deck card IDs and energy types are entirely data-derived above.
        {"high_impact_damage_floor", Value(std::int64_t{110})},
    });
}

Value normalized_deck_plans(const Value &source, const Value &strategies, const Value &cards) {
    Value::Object result;
    const Value *fallback = field(source, "fallback");
    result["fallback"] = normalized_deck_plan(
        fallback != nullptr && fallback->is_object() ? *fallback : Value::make_object(), cards);
    for (const auto &[deck_key, profile] : strategies.as_object()) {
        if (profile.is_object()) {
            result[deck_key] = normalized_deck_plan(profile, cards);
        }
    }
    return Value(std::move(result));
}
} // namespace
DeckPolicyRegistry::DeckPolicyRegistry(Value strategies, Value catalog) {
    generic_ = make_generic_policy();
    policies_.emplace("fire", make_fire_policy());
    policies_.emplace("water", make_water_policy());
    policies_.emplace("psychic", make_psychic_policy());
    policies_.emplace("lightning", make_lightning_policy());
    policies_.emplace("fighting", make_fighting_policy());
    policies_.emplace("colorless", make_colorless_policy());
    policies_.emplace("dragon", make_dragon_policy());
    policies_.emplace("grass", make_grass_policy());
    policies_.emplace("steel", make_steel_policy());
    policies_.emplace("darkness", make_darkness_policy());
    const Value *strategy_rows = strategies.find("strategies");
    const Value *archetypes = strategies.find("deck_archetypes");
    strategies_ = strategy_rows != nullptr && strategy_rows->is_object() ? *strategy_rows
                                                                         : std::move(strategies);
    archetypes_ =
        archetypes != nullptr && archetypes->is_object() ? *archetypes : Value::make_object();
    const Value *cards = catalog.find("cards");
    cards_ = cards != nullptr && cards->is_object() ? *cards : std::move(catalog);
    deck_plan_profiles_ = normalized_deck_plans(strategies, strategies_, cards_);
    valid_ = strategies_.is_object() && !strategies_.as_object().empty();
}

bool DeckPolicyRegistry::valid() const noexcept { return valid_; }

const Value &DeckPolicyRegistry::deck_plan_profiles() const noexcept { return deck_plan_profiles_; }

std::string DeckPolicyRegistry::strategy_id(const std::string &deck_key) const {
    return policy_for(deck_key).id();
}

std::int64_t DeckPolicyRegistry::strategy_version(const std::string &deck_key) const {
    const Value *profile = strategy_profile(strategies_, deck_key);
    return profile == nullptr ? 0 : integer_field(*profile, "version", 0);
}

std::string DeckPolicyRegistry::strategy_content_hash(const std::string &deck_key) const {
    const Value *profile = strategy_profile(strategies_, deck_key);
    return profile == nullptr ? std::string{} : string_field(*profile, "content_hash");
}

double DeckPolicyRegistry::action_score(const Value &state, std::int32_t actor,
                                        const Value &action) const {
    if (!valid_ || actor < 0 || actor > 1)
        return 0.0;
    const Value *keys = field(state, "public_deck_keys");
    const std::string deck_key = keys != nullptr && keys->is_array() &&
                                         static_cast<std::size_t>(actor) < keys->as_array().size()
                                     ? keys->as_array()[static_cast<std::size_t>(actor)].string_or()
                                     : std::string{};
    const Value *profile = strategy_profile(strategies_, deck_key);
    static const Value empty_profile = Value::make_object();
    if (profile == nullptr)
        profile = &empty_profile;
    const PolicyView view{state, *profile, archetypes_,          cards_,
                          actor, &action,  &policy_for(deck_key)};
    const double score = view.policy->action_score(view, action);
    return score;
}

double DeckPolicyRegistry::choice_score(const Value &state, std::int32_t actor,
                                        const Value &choice_view, const Value &option) const {
    if (!valid_ || actor < 0 || actor > 1 || !choice_view.is_object() || !option.is_object())
        return 0.0;
    const Value *keys = field(state, "public_deck_keys");
    const std::string deck_key = keys != nullptr && keys->is_array() &&
                                         static_cast<std::size_t>(actor) < keys->as_array().size()
                                     ? keys->as_array()[static_cast<std::size_t>(actor)].string_or()
                                     : std::string{};
    const Value *profile = strategy_profile(strategies_, deck_key);
    static const Value empty_profile = Value::make_object();
    if (profile == nullptr)
        profile = &empty_profile;
    const PolicyView view{state, *profile, archetypes_,          cards_,
                          actor, nullptr,  &policy_for(deck_key)};
    const double keep = view.policy->keep_value(view, choice_view, option);
    const std::string mode = choice_mode(view, choice_view);
    double score = keep;
    if (mode == "discard" || mode == "payment" || mode == "source") {
        score = -keep;
        if (mode == "discard")
            score += view.policy->discard_value(view, option);
    }
    return score;
}

double DeckPolicyRegistry::resource_bundle_value(const Value &state, std::int32_t actor,
                                                 const Value &retained_hand, double card_utility,
                                                 double resource_delta) const {
    const auto &keys = array_field(state, "public_deck_keys");
    if (actor < 0 || static_cast<std::size_t>(actor) >= keys.size())
        return card_utility;
    const auto key = keys[static_cast<std::size_t>(actor)].string_or();
    const Value *profile = strategy_profile(strategies_, key);
    static const Value empty = Value::make_object();
    const PolicyView view{
        state, profile ? *profile : empty, archetypes_, cards_, actor, nullptr, &policy_for(key)};
    ResourceBundle bundle;
    bundle.goal = plan_stage(view);
    const auto *goal = stage_goal(view, bundle.goal);
    const auto *targets = goal ? field(*goal, "targets") : nullptr;
    bundle.requirements = targets ? *targets : empty;
    bundle.retained_hand = retained_hand;
    bundle.card_utility = card_utility;
    bundle.resource_delta = resource_delta;
    return view.policy->resource_bundle_value(view, bundle);
}

double DeckPolicyRegistry::state_score(const Value &state, std::int32_t actor) const {
    if (!valid_ || actor < 0 || actor > 1)
        return 0.0;
    const Value *keys = field(state, "public_deck_keys");
    const std::string deck_key = keys != nullptr && keys->is_array() &&
                                         static_cast<std::size_t>(actor) < keys->as_array().size()
                                     ? keys->as_array()[static_cast<std::size_t>(actor)].string_or()
                                     : std::string{};
    const Value *profile = strategy_profile(strategies_, deck_key);
    static const Value empty_profile = Value::make_object();
    if (profile == nullptr)
        profile = &empty_profile;
    const PolicyView view{state, *profile, archetypes_,          cards_,
                          actor, nullptr,  &policy_for(deck_key)};
    return std::clamp(view.policy->state_score(view), -400.0, 400.0);
}

Value DeckPolicyRegistry::turn_goals(const Value &state, std::int32_t actor) const {
    if (!valid_ || actor < 0 || actor > 1)
        return Value::make_object();
    const Value *keys = field(state, "public_deck_keys");
    const std::string deck_key = keys != nullptr && keys->is_array() &&
                                         static_cast<std::size_t>(actor) < keys->as_array().size()
                                     ? keys->as_array()[static_cast<std::size_t>(actor)].string_or()
                                     : std::string{};
    const Value *profile = strategy_profile(strategies_, deck_key);
    if (profile == nullptr)
        return Value::make_object();
    const PolicyView view{state, *profile, archetypes_,          cards_,
                          actor, nullptr,  &policy_for(deck_key)};
    const std::string stage = plan_stage(view);
    const Value *goal = stage_goal(view, stage);
    const Value *roles = field(*profile, "card_roles");
    const auto role_cards = [&roles](const char *role) {
        const Value *values =
            roles != nullptr && roles->is_object() ? field(*roles, role) : nullptr;
        return values != nullptr && values->is_array() ? *values : Value::make_array();
    };
    Value search_hints(Value::Object{
        {"top_k", Value(std::max<std::int64_t>(
                      1, static_cast<std::int64_t>(std::round(view.weight("search_top_k", 6.0)))))},
        {"primary_attackers", role_cards("primary_attacker")},
        {"engine_cards", role_cards("bench_engine")},
    });
    return Value(Value::Object{
        {"strategy_id", Value(string_field(*profile, "strategy_id", "generic_balanced_v1"))},
        {"strategy_version", Value(integer_field(*profile, "version", 0))},
        {"content_hash", Value(string_field(*profile, "content_hash"))},
        {"runtime_hook_hash", Value(string_field(*profile, "runtime_hook_hash"))},
        {"deck_key", Value(deck_key)},
        {"stage", Value(stage)},
        {"goal", goal == nullptr ? Value::make_object() : *goal},
        {"opponent_deck_key", Value(view.opponent_deck_key())},
        {"search_hints", std::move(search_hints)},
    });
}

bool DeckPolicyRegistry::card_has_role(const Value &state, std::int32_t actor,
                                       const std::string &card_id, const std::string &role) const {
    if (!valid_ || actor < 0 || actor > 1 || card_id.empty() || role.empty()) {
        return false;
    }
    const Value *keys = field(state, "public_deck_keys");
    const std::string deck_key = keys != nullptr && keys->is_array() &&
                                         static_cast<std::size_t>(actor) < keys->as_array().size()
                                     ? keys->as_array()[static_cast<std::size_t>(actor)].string_or()
                                     : std::string{};
    const Value *profile = strategy_profile(strategies_, deck_key);
    if (profile == nullptr)
        return false;
    const PolicyView view{state, *profile, archetypes_,          cards_,
                          actor, nullptr,  &policy_for(deck_key)};
    return view.has_role(card_id, role);
}

const DeckPolicy &DeckPolicyRegistry::policy_for(const std::string &deck_key) const {
    const auto found = policies_.find(deck_key);
    return found == policies_.end() ? *generic_ : *found->second;
}

double DeckPolicyRegistry::position_value(const Value &state, std::int32_t actor,
                                          const PositionFeatures &facts) const {
    if (actor < 0 || actor > 1)
        return facts.material;
    const auto &keys = array_field(state, "public_deck_keys");
    const std::string key =
        static_cast<std::size_t>(actor) < keys.size() ? keys[actor].string_or() : "";
    const Value *profile = strategy_profile(strategies_, key);
    static const Value empty = Value::make_object();
    const auto &selected = policy_for(key);
    const PolicyView view{state,    profile ? *profile : empty, archetypes_, cards_, actor, nullptr,
                          &selected};
    return selected.position_value(view, facts);
}
} // namespace ptcg::ai
