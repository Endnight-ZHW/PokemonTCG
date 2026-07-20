class_name VMActionDispatcher
extends RefCounted

var action_executor: VMActionExecutor
var promotion_settlement: VMPromotionSettlement
var attack_settlement: VMAttackSettlement
var turn_settlement: VMTurnSettlement
var _handlers: Dictionary = {}
var _frozen := false


func _init(
	p_action_executor: VMActionExecutor,
	p_promotion_settlement: VMPromotionSettlement,
	p_attack_settlement: VMAttackSettlement,
	p_turn_settlement: VMTurnSettlement,
	action_registry: ActionDefinitionRegistry,
) -> void:
	action_executor = p_action_executor
	promotion_settlement = p_promotion_settlement
	attack_settlement = p_attack_settlement
	turn_settlement = p_turn_settlement
	_frozen = _register_from_registry(action_registry)


func register_action(action_name: String, handler: Callable) -> bool:
	if _frozen:
		push_error("VM action dispatcher is frozen: %s" % action_name)
		return false
	if action_name.is_empty() or _handlers.has(action_name):
		push_error("VM action name must be non-empty")
		return false
	if not handler.is_valid():
		push_error("VM action handler must be valid: %s" % action_name)
		return false
	_handlers[action_name] = handler
	return true


func is_frozen() -> bool:
	return _frozen


func supports_action(action_name: String) -> bool:
	return _handlers.has(action_name)


func supported_actions() -> Dictionary:
	return _handlers.duplicate()


func dispatch(
	state: GameState,
	action: GameAction,
	actor: int,
	rng: PortableRandomSource,
) -> StepResult:
	if state.phase != "SETUP" and action.action != "PROMOTE" and actor != state.active_player_idx:
		return _error("不是你的回合。", "wrong_actor", state)
	var handler: Callable = _handlers.get(action.action, Callable())
	if not handler.is_valid():
		return _error("未知动作: %s" % action.action, "unknown_action", state)
	return handler.call(state, action, actor, rng)


func _register_from_registry(action_registry: ActionDefinitionRegistry) -> bool:
	if action_registry == null:
		return false
	for action_name in action_registry.all_kinds():
		var definition := action_registry.definition(action_name)
		var method_name := str(definition.get("executor_method", ""))
		var handler := Callable(self, method_name)
		if method_name.is_empty() or not handler.is_valid():
			return false
		if not register_action(action_name, handler):
			return false
	return true


func _dispatch_noop(
	state: GameState,
	_action: GameAction,
	_actor: int,
	_rng: PortableRandomSource,
) -> StepResult:
	return StepResult.new(true, "", null, [], state.winner, false)


func _dispatch_setup_done(
	state: GameState,
	_action: GameAction,
	actor: int,
	rng: PortableRandomSource,
) -> StepResult:
	return action_executor.setup_done(state, actor, rng)


func _dispatch_promote(
	state: GameState,
	action: GameAction,
	actor: int,
	rng: PortableRandomSource,
) -> StepResult:
	return promotion_settlement.apply_promotion(
		state, actor, int(action.params.get("bench_idx", -1)), rng)


func _dispatch_play_basic(
	state: GameState,
	action: GameAction,
	actor: int,
	rng: PortableRandomSource,
) -> StepResult:
	return action_executor.play_basic(
		state, actor, int(action.params.get("hand_idx", -1)),
		str(action.params.get("target", "")), rng)


func _dispatch_evolve(
	state: GameState,
	action: GameAction,
	actor: int,
	rng: PortableRandomSource,
) -> StepResult:
	return action_executor.evolve(
		state, actor, int(action.params.get("hand_idx", -1)),
		str(action.params.get("slot", "")), rng)


func _dispatch_attach_energy(
	state: GameState,
	action: GameAction,
	actor: int,
	rng: PortableRandomSource,
) -> StepResult:
	return action_executor.attach_energy(
		state, actor, int(action.params.get("hand_idx", -1)),
		str(action.params.get("target_slot", "")), rng)


func _dispatch_play_trainer(
	state: GameState,
	action: GameAction,
	actor: int,
	rng: PortableRandomSource,
) -> StepResult:
	return action_executor.play_trainer(
		state, actor, int(action.params.get("hand_idx", -1)),
		str(action.params.get("target_slot", "")), rng)


func _dispatch_use_ability(
	state: GameState,
	action: GameAction,
	actor: int,
	rng: PortableRandomSource,
) -> StepResult:
	return action_executor.use_ability(
		state, actor, str(action.params.get("slot", "")),
		str(action.params.get("ability_name", "")), rng)


func _dispatch_use_stadium(
	state: GameState,
	_action: GameAction,
	actor: int,
	rng: PortableRandomSource,
) -> StepResult:
	return action_executor.use_stadium(state, actor, rng)


func _dispatch_retreat(
	state: GameState,
	action: GameAction,
	actor: int,
	_rng: PortableRandomSource,
) -> StepResult:
	var bench_idx := int(action.params.get("bench_idx", -1))
	var player := state.get_player(actor)
	if (
		player.active != null
		and action_executor.validator.effective_retreat_cost(state, player) > 0
	):
		return action_executor.request_retreat_payment(state, actor, bench_idx)
	return action_executor.retreat(state, actor, bench_idx, [])


func _dispatch_declare_attack(
	state: GameState,
	action: GameAction,
	actor: int,
	rng: PortableRandomSource,
) -> StepResult:
	return attack_settlement.declare_attack(
		state, actor, int(action.params.get("attack_idx", -1)), rng)


func _dispatch_end_turn(
	state: GameState,
	_action: GameAction,
	actor: int,
	rng: PortableRandomSource,
) -> StepResult:
	return turn_settlement.end_turn(state, actor, rng)


func _error(
	message: String,
	code: String,
	state: GameState,
) -> StepResult:
	return StepResult.new(false, message, null, [], state.winner, false, code)
