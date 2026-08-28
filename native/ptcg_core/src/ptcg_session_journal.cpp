#include "ptcg_rules_session.hpp"
#include "ptcg_session_internal.hpp"

#include "ptcg_random.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <functional>
#include <iomanip>
#include <limits>
#include <mutex>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <unordered_set>
#include <unordered_map>
#include <utility>


namespace ptcg::ai {

using namespace session_detail;

std::string canonical_value_hash(const Value &value) {
    std::string canonical;
    append_canonical_json(canonical, value);
    return fnv1a64_hex(canonical);
}
void RulesSession::append_journal_entry(
    const std::string &kind,
    const Value &input,
    std::int64_t revision_before,
    const std::vector<Value> &events
) {
    if (search_mode_) {
        return;
    }
    if (!journal_entries_.is_array()) {
        journal_entries_ = Value::make_array();
    }
    Value events_value(events);
    journal_entries_.as_array().emplace_back(Object{
        {"index", Value(static_cast<std::int64_t>(journal_entries_.as_array().size()))},
        {"kind", Value(kind)},
        {"revision_before", Value(revision_before)},
        {"revision_after", Value(revision())},
        {"input", input.deep_clone()},
        {"state_hash", Value(state_hash())},
        {"event_hash", Value(canonical_value_hash(events_value))},
        {"rng_state", Value(static_cast<std::int64_t>(rng_state_))},
    });
}

} // namespace ptcg::ai
