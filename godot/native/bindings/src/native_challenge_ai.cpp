#include "native_challenge_ai.hpp"

#include "ptcg_godot_value.hpp"

#include <godot_cpp/core/class_db.hpp>

namespace godot {
namespace {

Dictionary dictionary_from_value(const ptcg::ai::Value &value) {
    const Variant converted = ptcg::ai::value_to_godot(value);
    return converted.get_type() == Variant::DICTIONARY
        ? Dictionary(converted) : Dictionary();
}

std::string utf8(const String &value) {
    const CharString bytes = value.utf8();
    return std::string(bytes.get_data(), bytes.length());
}

} // namespace

void NativeChallengeAI::_bind_methods() {
    ClassDB::bind_method(
        D_METHOD("configure", "catalog", "decks", "strategies"),
        &NativeChallengeAI::configure);
    ClassDB::bind_method(
        D_METHOD("decide", "request", "generation"),
        &NativeChallengeAI::decide,
        DEFVAL(1));
    ClassDB::bind_method(
        D_METHOD("cancel", "generation"),
        &NativeChallengeAI::cancel);
    ClassDB::bind_method(
        D_METHOD("reset_match", "match_instance_id"),
        &NativeChallengeAI::reset_match);
    ClassDB::bind_method(
        D_METHOD("get_contract"),
        &NativeChallengeAI::get_contract);
}

Dictionary NativeChallengeAI::configure(
    const Dictionary &catalog,
    const Dictionary &decks,
    const Dictionary &strategies
) {
    return dictionary_from_value(controller_.configure(
        ptcg::ai::value_from_godot(catalog),
        ptcg::ai::value_from_godot(decks),
        ptcg::ai::value_from_godot(strategies)));
}

Dictionary NativeChallengeAI::decide(
    const Dictionary &request,
    int64_t generation
) {
    return dictionary_from_value(controller_.decide(
        ptcg::ai::value_from_godot(request), generation));
}

void NativeChallengeAI::cancel(int64_t generation) noexcept {
    controller_.cancel(generation);
}

void NativeChallengeAI::reset_match(const String &match_instance_id) {
    controller_.reset_match(utf8(match_instance_id));
}

Dictionary NativeChallengeAI::get_contract() const {
    return dictionary_from_value(controller_.get_contract());
}

} // namespace godot
