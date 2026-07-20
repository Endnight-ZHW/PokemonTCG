class_name RulesRuntime
extends RefCounted

# Narrow composition root for the shipping rules chain. GameEngine remains the
# public API; this object owns wiring and exposes only the services that the
# action/choice settlement pipeline needs.
var _catalog: CardCatalog
var _validator: RulesValidator
var _effect_engine: EffectEngine
var _knockout_settlement: VMKnockoutSettlement
var _attack_settlement: VMAttackSettlement
var _turn_settlement: VMTurnSettlement
var _promotion_settlement: VMPromotionSettlement
var _availability: VMAvailability
var _action_availability: VMActionAvailability
var _action_executor: VMActionExecutor
var _action_dispatcher: VMActionDispatcher
var _transaction_manager: VMTransactionManager
var _action_settlement: VMActionSettlement
var _choice_settlement: VMChoiceSettlement
var _action_registry: ActionDefinitionRegistry


func _init(
	p_catalog: CardCatalog,
	action_preflight: Callable,
) -> void:
	_catalog = p_catalog
	_validator = RulesValidator.new(_catalog)
	_effect_engine = EffectEngine.new(_catalog)
	_knockout_settlement = VMKnockoutSettlement.new(
		_catalog, _validator, _effect_engine.trigger_commands())
	_attack_settlement = VMAttackSettlement.new(
		_catalog, _validator, _knockout_settlement, _effect_engine)
	_attack_settlement.set_trigger_command_runner(_effect_engine.trigger_commands())
	_turn_settlement = VMTurnSettlement.new(_knockout_settlement)
	_attack_settlement.turn_settlement = _turn_settlement
	_promotion_settlement = VMPromotionSettlement.new(
		_attack_settlement, _turn_settlement)
	_availability = VMAvailability.new(_catalog)
	_action_availability = VMActionAvailability.new(
		_catalog, _validator, _availability, _attack_settlement)
	_action_executor = VMActionExecutor.new(
		_catalog, _validator, _availability, _effect_engine, _turn_settlement)
	_action_registry = ActionDefinitionRegistry.new(true)
	_action_dispatcher = VMActionDispatcher.new(
		_action_executor, _promotion_settlement, _attack_settlement, _turn_settlement,
		_action_registry)
	var bindings_ok := _action_dispatcher.is_frozen()
	bindings_ok = _action_registry.bind_candidate_generator(
		Callable(_action_availability, "legal_actions")) and bindings_ok
	for kind in _action_registry.all_kinds():
		bindings_ok = _action_registry.bind_runtime(
			kind, action_preflight, Callable(_action_dispatcher, "dispatch")) and bindings_ok
	bindings_ok = _action_registry.freeze() and bindings_ok
	_transaction_manager = VMTransactionManager.new()
	_action_settlement = VMActionSettlement.new(
		_knockout_settlement, _transaction_manager)
	_choice_settlement = VMChoiceSettlement.new(
		_effect_engine,
		_attack_settlement,
		_knockout_settlement,
		_transaction_manager,
	)
	if not bindings_ok:
		push_error("RulesRuntime action registry failed to initialize")


func is_ready() -> bool:
	if not (
		_action_registry != null
		and _action_registry.is_frozen()
		and _action_dispatcher != null
		and _action_dispatcher.is_frozen()
		and _effect_engine != null
		and _effect_engine.is_ready()
		and VMModifierDescriptorRegistry.shared().is_frozen()
	):
		return false
	var evaluator_names := _availability.preflight_evaluator_names()
	var descriptors := VMContract.native_command_descriptors()
	if descriptors.is_empty() or not VMContract.descriptor_load_error().is_empty():
		return false
	for descriptor_value in descriptors.values():
		if str(Dictionary(descriptor_value).get(
			"preflight_evaluator", "")) not in evaluator_names:
			return false
	var descriptor_ops: Array[String] = []
	for op_value in descriptors:
		descriptor_ops.append(str(op_value))
	descriptor_ops.sort()
	if VMContract.golden_command_ops() != descriptor_ops:
		return false
	var registry_kinds := _action_registry.all_kinds()
	var dispatcher_kinds: Array = _action_dispatcher.supported_actions().keys()
	registry_kinds.sort()
	dispatcher_kinds.sort()
	return registry_kinds == dispatcher_kinds
