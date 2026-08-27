#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace godot {

class NativeContentCompiler : public RefCounted {
    GDCLASS(NativeContentCompiler, RefCounted)

protected:
    static void _bind_methods();

public:
    Dictionary compile(const Dictionary &bundle) const;
    Dictionary get_contract() const;
};

} // namespace godot
