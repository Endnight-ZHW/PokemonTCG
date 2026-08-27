#include "ptcg_traditional_policy.hpp"
#include "ptcg_traditional_value.hpp"

#include <algorithm>
#include <limits>
#include <map>
#include <set>
#include <string_view>

namespace ptcg::ai {

namespace {

using traditional_value::field;
using traditional_value::integer_field;
using traditional_value::string_field;

Value stable_ref(const Value *ref) {
    if (ref == nullptr || !ref->is_object()) return Value::make_object();
    Value result(Value::Object{
        {"kind", Value(string_field(*ref, "kind"))},
        {"player", Value(integer_field(*ref, "player", -1))},
    });
    for (const char *key : {"zone", "slot", "attachment_type", "card_id"}) {
        const std::string value = string_field(*ref, key);
        if (!value.empty()) result[key] = Value(value);
    }
    return result;
}

std::string action_kind(const Value &action) {
    return string_field(action, "kind");
}

std::string row_signature(const TraditionalRankedAction &row) {
    return row.signature;
}

std::string row_bucket(const TraditionalRankedAction &row) {
    return row.semantic_bucket;
}

std::string row_purpose(const TraditionalRankedAction &row) {
    return row.purpose_bucket;
}

std::size_t protected_replacement_index(
    const std::vector<TraditionalRankedAction> &rows
) {
    if (rows.empty()) return 0;
    std::map<std::string, std::size_t> purpose_counts;
    for (const auto &row : rows) ++purpose_counts[row_purpose(row)];
    for (std::size_t offset = 0; offset < rows.size(); ++offset) {
        const std::size_t index = rows.size() - 1 - offset;
        if (purpose_counts[row_purpose(rows[index])] > 1) return index;
    }
    for (std::size_t offset = 0; offset < rows.size(); ++offset) {
        const std::size_t index = rows.size() - 1 - offset;
        if (!traditional_action_is_terminal(rows[index].action)) return index;
    }
    return rows.size() - 1;
}

const TraditionalRankedAction *best_unrepresented_target_variant(
    const std::vector<TraditionalRankedAction> &ranked,
    const std::vector<TraditionalRankedAction> &selected
) {
    static const std::set<std::string> target_sensitive{
        "development:evolve", "development:energy", "development:bench",
        "position:switch", "effect:ability", "effect:trainer",
    };
    std::set<std::string> selected_signatures;
    std::map<std::string, std::set<std::string>> buckets_by_purpose;
    for (const auto &row : selected) {
        selected_signatures.insert(row_signature(row));
        buckets_by_purpose[row_purpose(row)].insert(row_bucket(row));
    }
    for (const auto &row : ranked) {
        const std::string purpose = row_purpose(row);
        if (target_sensitive.find(purpose) == target_sensitive.end()
            || selected_signatures.find(row_signature(row))
                != selected_signatures.end()) {
            continue;
        }
        const auto found = buckets_by_purpose.find(purpose);
        if (found != buckets_by_purpose.end() && !found->second.empty()
            && found->second.find(row_bucket(row)) == found->second.end()) {
            return &row;
        }
    }
    return nullptr;
}

std::ptrdiff_t target_variant_replacement_index(
    const std::vector<TraditionalRankedAction> &rows,
    const std::string &protected_purpose
) {
    std::ptrdiff_t result = -1;
    std::int64_t lowest_score = 1000000000LL;
    std::string lowest_signature;
    for (std::size_t index = 0; index < rows.size(); ++index) {
        const auto &row = rows[index];
        if (traditional_action_is_terminal(row.action)
            || row_purpose(row) == protected_purpose) {
            continue;
        }
        if (result < 0 || row.score_milli < lowest_score
            || (row.score_milli == lowest_score
                && row_signature(row) > lowest_signature)) {
            result = static_cast<std::ptrdiff_t>(index);
            lowest_score = row.score_milli;
            lowest_signature = row_signature(row);
        }
    }
    return result;
}

} // namespace

std::string traditional_action_purpose(const Value &action) {
    const std::string kind = action_kind(action);
    if (kind == "DECLARE_ATTACK") return "terminal:attack";
    if (kind == "END_TURN" || kind == "SETUP_DONE") return "terminal:end";
    if (kind == "EVOLVE") return "development:evolve";
    if (kind == "ATTACH_ENERGY") return "development:energy";
    if (kind == "PLAY_BASIC") return "development:bench";
    if (kind == "RETREAT" || kind == "PROMOTE") return "position:switch";
    if (kind == "USE_ABILITY") return "effect:ability";
    if (kind == "PLAY_TRAINER") return "effect:trainer";
    if (kind == "USE_STADIUM") return "effect:stadium";
    return "other:" + kind;
}

std::string traditional_action_signature(
    const Value &action,
    const TraditionalStableSignature &stable_signature,
    const std::function<std::string(const std::string &)> &sha256_text
) {
    if (!action.is_object()) return {};
    const Value *payload = field(action, "payload");
    Value stable(Value::Object{
        {"kind", Value(action_kind(action))},
        {"actor", Value(integer_field(action, "actor", -1))},
        {"source", stable_ref(field(action, "source"))},
        {"target", stable_ref(field(action, "target"))},
        {"payload", payload != nullptr && payload->is_object()
            ? *payload : Value::make_object()},
    });
    return "action:" + sha256_text(stable_signature(stable));
}

std::string traditional_semantic_bucket(
    const Value &action,
    const TraditionalStableSignature &stable_signature
) {
    if (!action.is_object()) return {};
    const Value *payload_value = field(action, "payload");
    const Value payload = payload_value != nullptr && payload_value->is_object()
        ? *payload_value : Value::make_object();
    const std::int64_t attack_index = integer_field(
        payload, "attack_index", integer_field(payload, "attack_idx", -1));
    const std::int64_t target_index = integer_field(
        payload, "target_index", integer_field(payload, "bench_index", -1));
    Value stable(Value::Object{
        {"purpose", Value(traditional_action_purpose(action))},
        {"kind", Value(action_kind(action))},
        {"source", stable_ref(field(action, "source"))},
        {"target", stable_ref(field(action, "target"))},
        {"card_id", Value(string_field(payload, "card_id"))},
        {"attack_index", Value(attack_index)},
        {"ability_name", Value(string_field(payload, "ability_name"))},
        {"target_index", Value(target_index)},
        {"payload", payload},
    });
    return stable_signature(stable);
}

bool traditional_action_is_terminal(const Value &action) noexcept {
    const Value *kind_value = action.find("kind");
    const std::string kind = kind_value == nullptr
        ? std::string{} : kind_value->string_or();
    return kind == "DECLARE_ATTACK" || kind == "END_TURN"
        || kind == "SETUP_DONE";
}

void traditional_sort_ranked_actions(
    std::vector<TraditionalRankedAction> &ranked
) {
    std::stable_sort(ranked.begin(), ranked.end(),
        [](const TraditionalRankedAction &left,
           const TraditionalRankedAction &right) {
            if (left.score_milli != right.score_milli) {
                return left.score_milli > right.score_milli;
            }
            if (left.signature != right.signature) {
                return left.signature < right.signature;
            }
            return left.source_index < right.source_index;
        });
}

std::vector<TraditionalRankedAction> traditional_diverse_top_actions(
    const std::vector<TraditionalRankedAction> &ranked,
    std::size_t count
) {
    const std::size_t limit = std::min(count, ranked.size());
    std::vector<TraditionalRankedAction> result;
    result.reserve(limit);
    if (limit == 0) return result;
    std::set<std::string> used_buckets;
    std::set<std::string> used_purposes;
    std::set<std::string> used_signatures;
    for (const auto &row : ranked) {
        const std::string purpose = row_purpose(row);
        const std::string signature = row_signature(row);
        if (purpose.empty() || used_purposes.count(purpose)
            || used_signatures.count(signature)) continue;
        result.push_back(row);
        used_purposes.insert(purpose);
        used_signatures.insert(signature);
        used_buckets.insert(row_bucket(row));
        if (result.size() >= limit) break;
    }
    for (const auto &row : ranked) {
        if (result.size() >= limit) break;
        const std::string bucket = row_bucket(row);
        const std::string signature = row_signature(row);
        if (bucket.empty() || used_buckets.count(bucket)
            || used_signatures.count(signature)) continue;
        result.push_back(row);
        used_buckets.insert(bucket);
        used_signatures.insert(signature);
        used_purposes.insert(row_purpose(row));
    }
    for (const auto &row : ranked) {
        if (result.size() >= limit) break;
        if (used_signatures.count(row_signature(row))) continue;
        result.push_back(row);
        used_signatures.insert(row_signature(row));
    }
    const TraditionalRankedAction *end_row = nullptr;
    for (const auto &row : ranked) {
        const std::string kind = action_kind(row.action);
        if (kind == "END_TURN" || kind == "SETUP_DONE") {
            end_row = &row;
            break;
        }
    }
    if (end_row != nullptr && !used_signatures.count(row_signature(*end_row))) {
        if (result.size() >= limit) {
            result[protected_replacement_index(result)] = *end_row;
        } else {
            result.push_back(*end_row);
        }
        used_signatures.insert(row_signature(*end_row));
    }
    const bool has_terminal = std::any_of(result.begin(), result.end(),
        [](const TraditionalRankedAction &row) {
            return traditional_action_is_terminal(row.action);
        });
    if (!has_terminal) {
        const auto terminal = std::find_if(ranked.begin(), ranked.end(),
            [](const TraditionalRankedAction &row) {
                return traditional_action_is_terminal(row.action);
            });
        if (terminal != ranked.end()) {
            if (result.size() >= limit) result.back() = *terminal;
            else result.push_back(*terminal);
        }
    }
    const TraditionalRankedAction *target_variant =
        best_unrepresented_target_variant(ranked, result);
    if (target_variant != nullptr) {
        if (result.size() < limit) {
            result.push_back(*target_variant);
        } else {
            const std::ptrdiff_t index = target_variant_replacement_index(
                result, target_variant->purpose_bucket);
            if (index >= 0) result[static_cast<std::size_t>(index)] = *target_variant;
        }
    }
    return result;
}

} // namespace ptcg::ai
