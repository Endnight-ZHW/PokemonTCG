#include "challenge_search_provider_internal.hpp"
#include "planner_v3/strategic_facts.hpp"
#include "ptcg_traditional_card.hpp"

namespace ptcg::ai::challenge_detail {
using namespace traditional_value;

void ChallengeSearchProviderImpl::improve_choice_bundle(const RulesSession &position,
    const Value &pending, const typed::ChoiceView &choice, Value &response) {
    const std::string type = choice.request_type;
    const bool discard = type == "discard_cards" || type == "zinnia";
    if (!discard && type != "arven" && type != "clara" && type != "search_any_switch") return;
    if (choice.allow_duplicates || choice.max_select < 2 || choice.max_select > 4
        || choice.options.size() < 3 || choice.player < 0 || choice.player > 1) return;
    const auto &options = array_field(pending, "options");
    if (options.size() != choice.options.size()) return;
    const Value *presentation_value = field(pending, "presentation");
    const Value presentation = presentation_value == nullptr ? Value::make_object() : *presentation_value;
    Value key_state = position.search_state();
    for (Value &owner : key_state["players"].as_array()) {
        for (const char *zone : {"deck", "prizes"}) {
            auto &cards = owner[zone].as_array();
            std::sort(cards.begin(), cards.end(), [](const Value &a, const Value &b) { return a.string_or() < b.string_or(); });
        }
    }
    Value key_choice = pending;
    key_choice.erase("request_id");
    key_choice.erase("base_revision");
    const std::string cache_key = action_cycle_state_fingerprint(std::move(key_state))
        + stable_value_signature(key_choice);
    {
        std::lock_guard<std::mutex> lock(choice_bundle_cache_mutex_);
        const auto cached = choice_bundle_cache_.find(cache_key);
        if (cached != choice_bundle_cache_.end()) {
            response["option_ids"] = Value(cached->second);
            response["cancelled"] = Value(cached->second.empty() && choice.can_cancel && choice.min_select == 0);
            ++choice_bundle_cache_hits_;
            return;
        }
    }
    struct Candidate { std::size_t index; double prior; std::string id; std::string category; };
    std::vector<Candidate> candidates;
    for (std::size_t index = 0; index < options.size(); ++index) {
        const Value *reference = field(options[index], "ref");
        if (reference == nullptr || string_field(*reference, "kind") != "card"
            || integer_field(*reference, "player", -1) != choice.player) return;
        const std::string id = resolved_option_card_id(options[index]);
        const Value *definition = cards_.find(id);
        if (definition == nullptr) return;
        std::string category = string_field(*definition, "supertype");
        if (type == "arven") category = string_field(*definition, "trainer_type");
        const double prior = trusted_evaluator_.choice_option_score(position, choice.player,
            pending, options[index]).value_or(0.0)
            + strategy_catalog_.choice_score(position.search_state(), choice.player, pending, options[index])
            + prize_aware_search_choice_score(position, choice.player, pending, options[index]);
        candidates.push_back({index, prior, id, category});
    }
    std::stable_sort(candidates.begin(), candidates.end(), [](const auto &a, const auto &b) {
        return a.prior != b.prior ? a.prior > b.prior : a.index < b.index;
    });
    // Protect both Arven categories and both halves of a Candy/evolution pair.
    std::vector<Candidate> shortlist;
    std::set<std::string> protected_categories;
    for (const Candidate &candidate : candidates) {
        if (shortlist.size() < 8 || candidate.id == "sv1-152"
            || (type == "arven" && !protected_categories.count(candidate.category))) {
            shortlist.push_back(candidate);
            protected_categories.insert(candidate.category);
        }
    }
    if (shortlist.size() > 10) shortlist.resize(10);
    const auto &analyzer = resource_analyzer_;
    const double initial_resources = analyzer.resource_value(position, position.search_state(), choice.player);
    const auto evaluate = [&](const std::vector<std::size_t> &indices) {
        Value virtual_state = position.snapshot();
        auto &owner = virtual_state["players"].as_array()[static_cast<std::size_t>(choice.player)];
        double prior = 0.0;
        for (const std::size_t index : indices) {
            const auto found = std::find_if(candidates.begin(), candidates.end(), [&](const Candidate &row) { return row.index == index; });
            if (found == candidates.end()) return -std::numeric_limits<double>::infinity();
            prior += found->prior;
            const Value &reference = *field(options[index], "ref");
            const std::string source = discard ? "hand" : string_field(reference, "zone", "deck");
            auto &zone = owner[source].as_array();
            const auto card = std::find_if(zone.begin(), zone.end(), [&](const Value &entry) { return entry.string_or() == found->id; });
            if (card != zone.end()) zone.erase(card);
            owner[discard ? "discard" : "hand"].as_array().emplace_back(found->id);
        }
        ++choice_bundle_evaluations_;
        // Keep/discard priors include each deck's engine and discard synergies;
        // combat progress supplies the non-additive value of a complete combo.
        return prior + analyzer.resource_value(position, virtual_state, choice.player) - initial_resources;
    };
    std::vector<std::size_t> baseline;
    for (const Value &id : array_field(response, "option_ids")) {
        for (std::size_t index = 0; index < options.size(); ++index) {
            if (string_field(options[index], "option_id") == id.string_or()) baseline.push_back(index);
        }
    }
    struct Bundle { std::vector<std::size_t> indices; std::map<std::string, int> categories; double score; };
    Bundle best{baseline, {}, evaluate(baseline)};
    std::vector<Bundle> frontier{{{}, {}, 0.0}};
    bool completed = true;
    for (std::int64_t depth = 1; depth <= choice.max_select && completed; ++depth) {
        std::vector<Bundle> next;
        for (const Bundle &parent : frontier) {
            if (!completed) break;
            for (const Candidate &candidate : shortlist) {
                if (time_budget_exhausted()) { completed = false; break; }
                if (!parent.indices.empty() && candidate.index <= parent.indices.back()) continue;
                auto categories = parent.categories;
                const int limit = type == "arven" ? 1
                    : (type == "clara" ? static_cast<int>(integer_field(presentation,
                        candidate.category == "Energy" ? "energy_count" : "pokemon_count", 2)) : 4);
                if (++categories[candidate.category] > limit) continue;
                auto indices = parent.indices;
                indices.push_back(candidate.index);
                const double score = evaluate(indices);
                Bundle child{std::move(indices), std::move(categories), score};
                if (depth >= choice.min_select && child.score > best.score + 0.001) best = child;
                next.push_back(std::move(child));
            }
        }
        std::stable_sort(next.begin(), next.end(), [](const Bundle &a, const Bundle &b) {
            return a.score != b.score ? a.score > b.score : a.indices < b.indices;
        });
        if (next.size() > 4) next.resize(4);
        frontier = std::move(next);
    }
    Value::Array ids;
    for (const auto index : best.indices) ids.emplace_back(string_field(options[index], "option_id"));
    {
        std::lock_guard<std::mutex> lock(choice_bundle_cache_mutex_);
        if (completed && choice_bundle_cache_.size() < 256) choice_bundle_cache_.emplace(cache_key, ids);
    }
    if (best.indices == baseline) return;
    response["option_ids"] = Value(std::move(ids));
    response["cancelled"] = Value(false);
    ++choice_bundle_changes_;
}
} // namespace ptcg::ai::challenge_detail
