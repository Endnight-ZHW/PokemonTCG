class_name GameEngine
extends RefCounted

var catalog: CardCatalog
var validator: RulesValidator
var effect_engine: EffectEngine
var knockout_settlement: VMKnockoutSettlement
var attack_settlement: VMAttackSettlement
var turn_settlement: VMTurnSettlement
var promotion_settlement: VMPromotionSettlement
var availability: VMAvailability
var action_availability: VMActionAvailability
var action_executor: VMActionExecutor
var action_dispatcher: VMActionDispatcher
var transaction_manager: VMTransactionManager
var action_settlement: VMActionSettlement
var choice_settlement: VMChoiceSettlement


func _init(p_catalog: CardCatalog = null) -> void:
	catalog = p_catalog if p_catalog else CardCatalog.shared()
	validator = RulesValidator.new(catalog)
	effect_engine = EffectEngine.new(catalog)
	knockout_settlement = VMKnockoutSettlement.new(
		catalog, validator, effect_engine.runtime.trigger_commands)
	attack_settlement = VMAttackSettlement.new(
		catalog, validator, knockout_settlement, effect_engine)
	attack_settlement.set_trigger_command_runner(effect_engine.runtime.trigger_commands)
	turn_settlement = VMTurnSettlement.new(knockout_settlement)
	attack_settlement.turn_settlement = turn_settlement
	promotion_settlement = VMPromotionSettlement.new(attack_settlement, turn_settlement)
	availability = VMAvailability.new(catalog)
	action_availability = VMActionAvailability.new(
		catalog, validator, availability, attack_settlement)
	action_executor = VMActionExecutor.new(
		catalog, validator, availability, effect_engine, turn_settlement)
	action_dispatcher = VMActionDispatcher.new(
		action_executor, promotion_settlement, attack_settlement, turn_settlement)
	transaction_manager = VMTransactionManager.new()
	action_settlement = VMActionSettlement.new(knockout_settlement, transaction_manager)
	choice_settlement = VMChoiceSettlement.new(
		effect_engine, attack_settlement, knockout_settlement, transaction_manager)


func setup_game(
	state: GameState,
	deck_one: Array[String],
	deck_two: Array[String],
	rng: PortableRandomSource,
	forced_first: int = -1,
) -> StepResult:
	if deck_one.size() != 60 or deck_two.size() != 60:
		return _error("双方牌组都必须正好包含60张卡。", "invalid_deck_size", state)
	for deck in [deck_one, deck_two]:
		var has_basic := false
		for card_id in deck:
			if catalog.is_basic_pokemon(card_id):
				has_basic = true
				break
		if not has_basic:
			return _error("牌组至少需要1张基础宝可梦。", "deck_without_basic", state)

	state.mulligan_count = [0, 0]
	state.extra_draws = [0, 0]
	state.setup_ready = [false, false]
	state.action_log.clear()
	state.setup_game(deck_one, deck_two, rng, forced_first)
	for player_idx in [0, 1]:
		var player := state.get_player(player_idx)
		var guard := 0
		while not _hand_has_basic(player) and guard < 32:
			guard += 1
			state.mulligan_count[player_idx] += 1
			player.deck.append_array(player.hand)
			player.hand.clear()
			rng.shuffle(player.deck)
			player.draw_cards(7)
		if not _hand_has_basic(player):
			return _error("连续再战仍未抽到基础宝可梦。", "mulligan_guard", state)

	for player_idx in [0, 1]:
		if state.mulligan_count[player_idx] > 0:
			var opponent_idx: int = 1 - int(player_idx)
			state.extra_draws[opponent_idx] += 1
			state.get_player(opponent_idx).draw_cards(1)
	state.log_action("起始手牌已准备。")
	return StepResult.new(true, "游戏准备完成。", null, [], state.winner, false)


func legal_actions(
	state: GameState,
	actor: int,
	validate_effects: bool = true,
) -> Array[GameAction]:
	return action_availability.legal_actions(
		state, actor, validate_effects, Callable(self, "apply_action"))


func apply_action(
	state: GameState,
	action: GameAction,
	rng: PortableRandomSource,
) -> StepResult:
	var actor := state.active_player_idx if action.actor < 0 else action.actor
	if actor not in [0, 1]:
		return _error("动作玩家无效。", "invalid_actor", state)
	if not action.action_id.is_empty() and action.action_id in state.processed_action_ids:
		return _error("动作已处理。", "duplicate_action", state)
	var pending_stack := ResolutionStack.from_dict(state.resolution_stack)
	if pending_stack.pending_request != null:
		return _error("必须先完成当前选择。", "pending_choice", state)
	var reference_error := action_availability.validate_action_references(state, action)
	if not reference_error.is_empty():
		return _error(reference_error, "stale_action_reference", state)
	var cost_error := action_availability.action_cost_error(state, action, actor)
	if not cost_error.is_empty():
		return _error(cost_error, "cost_not_payable", state)
	var target_error := action_availability.action_target_availability_error(state, action, actor)
	if not target_error.is_empty():
		return _error(target_error, "no_legal_target", state)
	return action_settlement.apply_action(
		state, action, actor, rng, Callable(action_dispatcher, "dispatch"))


func apply_choice(
	state: GameState,
	request: ChoiceRequest,
	response: ChoiceResponse,
	rng: PortableRandomSource,
) -> StepResult:
	return choice_settlement.apply_choice(state, request, response, rng)


func _hand_has_basic(player: PlayerState) -> bool:
	for card_id in player.hand:
		if catalog.is_basic_pokemon(card_id):
			return true
	return false


func _error(
	message: String,
	code: String,
	state: GameState,
) -> StepResult:
	return StepResult.new(false, message, null, [], state.winner, false, code)
