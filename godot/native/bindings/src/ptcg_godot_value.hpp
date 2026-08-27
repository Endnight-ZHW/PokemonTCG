#pragma once

#include "ptcg_value.hpp"

#include <godot_cpp/variant/variant.hpp>

namespace ptcg::ai {

Value value_from_godot(const godot::Variant &source);
godot::Variant value_to_godot(const Value &source);

} // namespace ptcg::ai
