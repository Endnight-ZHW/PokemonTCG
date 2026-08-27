#include "register_types.hpp"

#include "challenge_ai_math.hpp"
#include "godot_rules_session.hpp"
#include "native_traditional_ai.hpp"
#if defined(PTCG_ENABLE_DEEP_RUNTIME)
#include "native_deep_search.hpp"
#include "onnx_inference.hpp"
#endif

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

void initialize_onnx_ai_module(ModuleInitializationLevel level) {
    if (level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
    GDREGISTER_CLASS(ChallengeAIMath);
    GDREGISTER_CLASS(NativeTraditionalAI);
#if defined(PTCG_ENABLE_DEEP_RUNTIME)
    GDREGISTER_CLASS(OnnxInference);
    GDREGISTER_CLASS(NativeDeepSearch);
#endif
    GDREGISTER_CLASS(NativeRulesSession);
}

void uninitialize_onnx_ai_module(ModuleInitializationLevel level) {
    if (level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
}

extern "C" {

GDExtensionBool GDE_EXPORT pokemon_ai_library_init(
    GDExtensionInterfaceGetProcAddress get_proc_address,
    const GDExtensionClassLibraryPtr library,
    GDExtensionInitialization *initialization
) {
    GDExtensionBinding::InitObject init_object(
        get_proc_address,
        library,
        initialization
    );
    init_object.register_initializer(initialize_onnx_ai_module);
    init_object.register_terminator(uninitialize_onnx_ai_module);
    init_object.set_minimum_library_initialization_level(
        MODULE_INITIALIZATION_LEVEL_SCENE
    );
    return init_object.init();
}

}
