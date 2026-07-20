class_name VMModifierContinuations
extends RefCounted


func register(interpreter: VMInterpreter) -> void:
	interpreter.register_continuation(
		"modifier_controller_choice",
		Callable(VMModifierManager, "continue_controller_choice"),
	)
