#pragma once

#include "ptcg_value.hpp"

namespace ptcg::ai {

// Compiles the Godot-owned JSON authoring bundle into the immutable runtime
// card/deck/strategy payloads. Godot owns JSON/image file I/O; canonical
// semantic/source/contract SHA-256 fingerprints are produced here.
Value compile_content_bundle(const Value &bundle);
Value content_compiler_contract();

} // namespace ptcg::ai
