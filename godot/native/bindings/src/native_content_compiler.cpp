#include "native_content_compiler.hpp"

#include "ptcg_content_compiler.hpp"
#include "ptcg_godot_value.hpp"

#include <godot_cpp/core/class_db.hpp>

namespace godot {
namespace {

Dictionary dictionary_from_value(const ptcg::ai::Value &value) {
    const Variant converted = ptcg::ai::value_to_godot(value);
    return converted.get_type() == Variant::DICTIONARY
        ? Dictionary(converted) : Dictionary();
}

} // namespace

void NativeContentCompiler::_bind_methods() {
    ClassDB::bind_method(
        D_METHOD("compile", "bundle"),
        &NativeContentCompiler::compile);
    ClassDB::bind_method(
        D_METHOD("get_contract"),
        &NativeContentCompiler::get_contract);
}

Dictionary NativeContentCompiler::compile(const Dictionary &bundle) const {
    return dictionary_from_value(ptcg::ai::compile_content_bundle(
        ptcg::ai::value_from_godot(bundle)));
}

Dictionary NativeContentCompiler::get_contract() const {
    return dictionary_from_value(ptcg::ai::content_compiler_contract());
}

} // namespace godot
