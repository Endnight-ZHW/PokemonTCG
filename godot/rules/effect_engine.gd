class_name EffectEngine
extends RefCounted

var runtime: VMRuntime


func _init(p_catalog: CardCatalog) -> void:
	runtime = VMRuntime.new(p_catalog)


func supports_effect_type(effect_type: String) -> bool:
	return runtime.supports_effect_type(effect_type)


func supports_command_spec(spec: Dictionary) -> bool:
	return runtime.supports_command_spec(spec)


func supports_command_handler(op: String) -> bool:
	return runtime.supports_command_handler(op)


func native_command_ops() -> Array[String]:
	return runtime.native_command_ops()


func supports_continuation(operation: String) -> bool:
	return runtime.supports_continuation(operation)


func is_ready() -> bool:
	return runtime != null and runtime.is_ready()


func trigger_commands() -> VMTriggerCommands:
	return runtime.trigger_commands


func resolve(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
) -> StepResult:
	return runtime.resolve(state, stack, rng)


func apply_choice(
	state: GameState,
	stack: ResolutionStack,
	response: ChoiceResponse,
	rng: PortableRandomSource,
) -> StepResult:
	return runtime.apply_choice(state, stack, response, rng)
