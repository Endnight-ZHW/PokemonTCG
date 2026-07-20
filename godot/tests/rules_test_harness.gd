class_name RulesTestHarness
extends RefCounted

# Test-only access to the private rules composition root. Shipping callers use
# GameEngine's query/submit API and never receive executor, validator or
# transaction services. Tests that need fault injection do so explicitly here.
var _engine: GameEngine

var runtime: RulesRuntime:
	get:
		return _engine._runtime
var validator: RulesValidator:
	get:
		return _engine._runtime._validator
var effect_engine: EffectEngine:
	get:
		return _engine._runtime._effect_engine
var knockout_settlement: VMKnockoutSettlement:
	get:
		return _engine._runtime._knockout_settlement
	set(value):
		_engine._runtime._knockout_settlement = value
var attack_settlement: VMAttackSettlement:
	get:
		return _engine._runtime._attack_settlement
	set(value):
		_engine._runtime._attack_settlement = value
var turn_settlement: VMTurnSettlement:
	get:
		return _engine._runtime._turn_settlement
	set(value):
		_engine._runtime._turn_settlement = value
var promotion_settlement: VMPromotionSettlement:
	get:
		return _engine._runtime._promotion_settlement
var availability: VMAvailability:
	get:
		return _engine._runtime._availability
var action_availability: VMActionAvailability:
	get:
		return _engine._runtime._action_availability
var action_executor: VMActionExecutor:
	get:
		return _engine._runtime._action_executor
var action_dispatcher: VMActionDispatcher:
	get:
		return _engine._runtime._action_dispatcher
var transaction_manager: VMTransactionManager:
	get:
		return _engine._runtime._transaction_manager
var action_settlement: VMActionSettlement:
	get:
		return _engine._runtime._action_settlement
var choice_settlement: VMChoiceSettlement:
	get:
		return _engine._runtime._choice_settlement
var action_registry: ActionDefinitionRegistry:
	get:
		return _engine._runtime._action_registry


func _init(engine: GameEngine) -> void:
	assert(engine != null)
	_engine = engine


static func runtime_for(engine: GameEngine) -> RulesRuntime:
	return engine._runtime


static func validator_for(engine: GameEngine) -> RulesValidator:
	return engine._runtime._validator


static func effect_engine_for(engine: GameEngine) -> EffectEngine:
	return engine._runtime._effect_engine


static func knockout_settlement_for(engine: GameEngine) -> VMKnockoutSettlement:
	return engine._runtime._knockout_settlement


static func set_knockout_settlement(
	engine: GameEngine,
	value: VMKnockoutSettlement,
) -> void:
	engine._runtime._knockout_settlement = value


static func attack_settlement_for(engine: GameEngine) -> VMAttackSettlement:
	return engine._runtime._attack_settlement


static func set_attack_settlement(
	engine: GameEngine,
	value: VMAttackSettlement,
) -> void:
	engine._runtime._attack_settlement = value


static func turn_settlement_for(engine: GameEngine) -> VMTurnSettlement:
	return engine._runtime._turn_settlement


static func set_turn_settlement(
	engine: GameEngine,
	value: VMTurnSettlement,
) -> void:
	engine._runtime._turn_settlement = value


static func promotion_settlement_for(engine: GameEngine) -> VMPromotionSettlement:
	return engine._runtime._promotion_settlement


static func availability_for(engine: GameEngine) -> VMAvailability:
	return engine._runtime._availability


static func action_availability_for(engine: GameEngine) -> VMActionAvailability:
	return engine._runtime._action_availability


static func action_executor_for(engine: GameEngine) -> VMActionExecutor:
	return engine._runtime._action_executor


static func action_dispatcher_for(engine: GameEngine) -> VMActionDispatcher:
	return engine._runtime._action_dispatcher


static func transaction_manager_for(engine: GameEngine) -> VMTransactionManager:
	return engine._runtime._transaction_manager


static func action_settlement_for(engine: GameEngine) -> VMActionSettlement:
	return engine._runtime._action_settlement


static func choice_settlement_for(engine: GameEngine) -> VMChoiceSettlement:
	return engine._runtime._choice_settlement


static func action_registry_for(engine: GameEngine) -> ActionDefinitionRegistry:
	return engine._runtime._action_registry


static func apply_choice(
	engine: GameEngine,
	state: GameState,
	_request: ChoiceRequest,
	response: ChoiceResponse,
	rng: PortableRandomSource,
) -> StepResult:
	return engine.apply_choice_response(state, response, rng)


static func legal_actions(
	engine: GameEngine,
	state: GameState,
	actor: int,
	_validate_effects: bool = true,
) -> Array[GameAction]:
	var result: Array[GameAction] = []
	var query := engine.query_legal_action_groups(state, actor)
	if not query.success:
		return result
	for group in query.groups:
		result.append_array(group.concrete_actions())
	return result
