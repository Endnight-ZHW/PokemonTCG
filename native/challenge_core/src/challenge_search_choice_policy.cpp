#include "challenge_search_provider_internal.hpp"


#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <functional>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <string>
#include <utility>
#include <vector>
namespace ptcg::ai::challenge_detail {

using namespace challenge;

    bool ChallengeSearchProviderImpl::forced_choice_response(
        const ptcg::ai::Value &state,
        const ptcg::ai::Value &pending,
        const ptcg::ai::typed::ChoiceView &choice,
        ptcg::ai::Value &response
    ) const {
        if (!pending.is_object()) return false;
        const ptcg::ai::Value *options_value = pending.find("options");
        if (options_value == nullptr || !options_value->is_array()) {
            return false;
        }
        ptcg::ai::Value::Array selected_ids;
        bool cancelled = false;
        if (choice.options.empty()) {
            cancelled = choice.can_cancel && choice.min_select <= 0;
        } else if (
            choice.options.size() == 1
            && choice.min_select == 1 && choice.max_select == 1
            && !choice.allow_duplicates
        ) {
            selected_ids.emplace_back(choice.options.front().option_id);
        } else {
            using Kind = ptcg::ai::typed::ChoiceRequestKind;
            if (choice.request_kind == Kind::choose_turn_order) {
                selected_ids.emplace_back("turn:first");
            } else if (
                choice.request_kind == Kind::choose_mulligan_draw_count
            ) {
                std::int64_t largest_draw = -1;
                for (const ptcg::ai::typed::ChoiceOption &option
                    : choice.options) {
                    const std::string &option_id = option.option_id;
                    constexpr std::string_view prefix = "draw:";
                    if (option_id.rfind(prefix, 0) != 0) continue;
                    std::int64_t count = 0;
                    const char *begin = option_id.data() + prefix.size();
                    const char *end = option_id.data() + option_id.size();
                    const auto parsed = std::from_chars(begin, end, count);
                    if (parsed.ec == std::errc{} && parsed.ptr == end) {
                        largest_draw = std::max(largest_draw, count);
                    }
                }
                selected_ids.emplace_back(
                    "draw:" + std::to_string(std::max<std::int64_t>(
                        0, largest_draw)));
            } else if (choice.request_kind == Kind::select_prize) {
                std::int64_t lowest_prize = 999;
                for (const ptcg::ai::typed::ChoiceOption &option
                    : choice.options) {
                    const std::string &option_id = option.option_id;
                    constexpr std::string_view prefix = "prize:";
                    if (option_id.rfind(prefix, 0) != 0) continue;
                    std::int64_t index = 0;
                    const char *begin = option_id.data() + prefix.size();
                    const char *end = option_id.data() + option_id.size();
                    const auto parsed = std::from_chars(begin, end, index);
                    if (parsed.ec == std::errc{} && parsed.ptr == end) {
                        lowest_prize = std::min(lowest_prize, index);
                    }
                }
                selected_ids.emplace_back(
                    "prize:" + std::to_string(
                        lowest_prize == 999 ? 0 : lowest_prize));
            } else if (choice.request_kind == Kind::select_retreat_payment) {
                return retreat_payment_response(state, pending, response);
            } else if (choice.request_kind == Kind::confirm_trigger) {
                selected_ids.emplace_back(choice.options.front().option_id);
            } else if (choice.request_kind == Kind::confirm) {
                const ptcg::ai::Value *presentation = pending.find(
                    "presentation");
                static const ptcg::ai::Value empty =
                    ptcg::ai::Value::make_object();
                const ptcg::ai::Value &view = presentation != nullptr
                    && presentation->is_object() ? *presentation : empty;
                const std::string purpose = string_field(view, "purpose");
                if (
                    purpose == "trekking_shoes"
                    || !string_field(view, "top_card_id").empty()
                    || purpose == "confirm_switch"
                    || purpose == "search_any_switch_confirm"
                    || purpose == "switch"
                ) {
                    return false;
                }
                bool confirmed = true;
                if (purpose == "heal") {
                    confirmed = false;
                    const std::int32_t actor = choice.player;
                    const ptcg::ai::Value *players = state.find("players");
                    if (
                        players != nullptr && players->is_array()
                        && actor >= 0
                        && static_cast<std::size_t>(actor)
                            < players->as_array().size()
                    ) {
                        const ptcg::ai::Value &owner = players->as_array()[
                            static_cast<std::size_t>(actor)];
                        const ptcg::ai::Value *active = owner.find("active");
                        confirmed = active != nullptr && active->is_object()
                            && integer_field(*active, "damage_counters") > 0;
                        const ptcg::ai::Value *bench = owner.find("bench");
                        if (!confirmed && bench != nullptr && bench->is_array()) {
                            confirmed = std::any_of(
                                bench->as_array().begin(),
                                bench->as_array().end(),
                                [](const ptcg::ai::Value &pokemon) {
                                    return pokemon.is_object()
                                        && integer_field(
                                            pokemon, "damage_counters") > 0;
                                });
                        }
                    }
                }
                selected_ids.emplace_back(
                    confirmed ? "confirm:yes" : "confirm:no");
            } else {
                return false;
            }
        }
        response = ptcg::ai::Value(ptcg::ai::Value::Object{
            {"request_id", ptcg::ai::Value(choice.request_id)},
            {"option_ids", ptcg::ai::Value(std::move(selected_ids))},
            {"cancelled", ptcg::ai::Value(cancelled)},
        });
        return true;
    }


} // namespace ptcg::ai::challenge_detail
