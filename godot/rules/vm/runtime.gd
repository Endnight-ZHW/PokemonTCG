class_name VMRuntime
extends RefCounted

var catalog: CardCatalog
var vm_interpreter: VMInterpreter
var trainer_continuations: VMTrainerContinuations
var board_continuations: VMBoardContinuations
var energy_continuations: VMEnergyContinuations
var look_top_continuations: VMLookTopContinuations
var modifier_continuations: VMModifierContinuations
var draw_commands: VMDrawCommands
var trainer_commands: VMTrainerCommands
var modifier_commands: VMModifierCommands
var energy_commands: VMEnergyCommands
var status_commands: VMStatusCommands
var coin_commands: VMCoinCommands
var board_commands: VMBoardCommands
var look_top_commands: VMLookTopCommands
var combat_commands: VMCombatCommands
var trigger_commands: VMTriggerCommands


func _init(p_catalog: CardCatalog) -> void:
	catalog = p_catalog
	vm_interpreter = VMInterpreter.new()
	trigger_commands = VMTriggerCommands.new(catalog)
	draw_commands = VMDrawCommands.new()
	trainer_commands = VMTrainerCommands.new(catalog)
	modifier_commands = VMModifierCommands.new()
	energy_commands = VMEnergyCommands.new(catalog, trigger_commands)
	status_commands = VMStatusCommands.new(catalog)
	board_commands = VMBoardCommands.new(catalog)
	look_top_commands = VMLookTopCommands.new(catalog, energy_commands)
	combat_commands = VMCombatCommands.new(catalog, trainer_commands, board_commands)
	coin_commands = VMCoinCommands.new(catalog, combat_commands.damage)
	trainer_continuations = VMTrainerContinuations.new(catalog)
	board_continuations = VMBoardContinuations.new(
		catalog, board_commands, coin_commands, combat_commands.damage)
	energy_continuations = VMEnergyContinuations.new(energy_commands, trigger_commands)
	look_top_continuations = VMLookTopContinuations.new(catalog)
	modifier_continuations = VMModifierContinuations.new()
	vm_interpreter.register_command_descriptors(VMContract.native_command_descriptors())
	_register_command_handlers()
	_register_continuations()
	var registry_errors := vm_interpreter.freeze(VMContract.native_command_ops())
	if not registry_errors.is_empty():
		push_error("VM runtime registry is incomplete: %s" % "; ".join(registry_errors))


func supports_effect_type(effect_type: String) -> bool:
	return VMContract.supports_effect_type(effect_type)


func supports_command_spec(spec: Dictionary) -> bool:
	return vm_interpreter.supports_command_spec(spec)


func supports_command_handler(op: String) -> bool:
	return vm_interpreter.supports_command_handler(op)


func native_command_ops() -> Array[String]:
	return VMContract.native_command_ops()


func supports_continuation(operation: String) -> bool:
	return vm_interpreter.supports_continuation(operation)


func is_ready() -> bool:
	return vm_interpreter.is_ready()


func resolve(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
) -> StepResult:
	return vm_interpreter.resolve(state, stack, rng)


func apply_choice(
	state: GameState,
	stack: ResolutionStack,
	response: ChoiceResponse,
	rng: PortableRandomSource,
) -> StepResult:
	return vm_interpreter.apply_choice(state, stack, response, rng)


func _register_command_handlers() -> void:
	draw_commands.register(vm_interpreter)
	trainer_commands.register(vm_interpreter)
	modifier_commands.register(vm_interpreter)
	energy_commands.register(vm_interpreter)
	status_commands.register(vm_interpreter)
	coin_commands.register(vm_interpreter)
	board_commands.register(vm_interpreter)
	look_top_commands.register(vm_interpreter)
	combat_commands.register(vm_interpreter)
	trigger_commands.register(vm_interpreter)


func _register_continuations() -> void:
	trainer_continuations.register(vm_interpreter)
	board_continuations.register(vm_interpreter)
	energy_continuations.register(vm_interpreter)
	look_top_continuations.register(vm_interpreter)
	modifier_continuations.register(vm_interpreter)
