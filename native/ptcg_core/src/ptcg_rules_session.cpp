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

RulesSession::RulesSession(Value cards) {
    if (cards.is_object() && !cards.as_object().empty()) {
        set_cards(std::move(cards));
    }
}

const Value &RulesSession::cards() const noexcept {
    static const Value empty_cards = Value::make_object();
    return catalog_ ? catalog_->cards : empty_cards;
}

const NativeGameKernel &RulesSession::game() const noexcept {
    static const NativeGameKernel empty_game;
    return catalog_ ? catalog_->game : empty_game;
}

void RulesSession::set_cards(Value cards) {
    if (initialized_) {
        throw std::logic_error("cannot_replace_cards_during_match");
    }
    CatalogPayload catalog = normalize_catalog(cards);
    const std::string catalog_key = canonical_value_hash(catalog.cards);
    static std::mutex cache_mutex;
    static std::unordered_map<
        std::string,
        std::weak_ptr<const CatalogContext>
    > cache;
    std::shared_ptr<const CatalogContext> context;
    {
        const std::lock_guard<std::mutex> guard(cache_mutex);
        const auto found = cache.find(catalog_key);
        if (found != cache.end()) context = found->second.lock();
        if (context && !(context->cards == catalog.cards)) context.reset();
    }
    if (!context) {
        auto compiled = std::make_shared<const CatalogContext>(
            std::move(catalog.cards));
        if (!compiled->vm_catalog.valid()) {
            throw std::invalid_argument(compiled->vm_catalog.error());
        }
        const std::lock_guard<std::mutex> guard(cache_mutex);
        const auto found = cache.find(catalog_key);
        context = found == cache.end() ? nullptr : found->second.lock();
        if (context && !(context->cards == compiled->cards)) context.reset();
        if (!context) {
            context = std::move(compiled);
            cache[catalog_key] = context;
        }
    }
    catalog_ = std::move(context);
    card_ir_content_fingerprint_ = std::move(catalog.content_fingerprint);
    card_ir_contract_fingerprint_ = std::move(catalog.contract_fingerprint);
    vm_descriptor_digest_ = std::move(catalog.descriptor_digest);
}

bool RulesSession::initialized() const noexcept {
    return initialized_;
}


} // namespace ptcg::ai
