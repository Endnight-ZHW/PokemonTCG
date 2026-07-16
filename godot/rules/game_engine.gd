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
	for deck in [deck_one, deck_two]:
		var deck_error := _deck_validation_error(deck)
		if not deck_error.is_empty():
			return _error(
				str(deck_error.get("message", "牌组不合法。")),
				str(deck_error.get("code", "invalid_deck")),
				state,
			)

	state.mulligan_count = [0, 0]
	state.extra_draws = [0, 0]
	state.setup_ready = [false, false]
	state.action_log.clear()
	state.setup_game(deck_one, deck_two, rng, forced_first)
	var setup_events: Array[Dictionary] = []
	if forced_first not in [0, 1]:
		# The setup coin is authoritative: every peer consumes the same result,
		# while forced-first debug/test matches do not pretend a toss occurred.
		setup_events.append({
			"event_id": "setup:first-player",
			"event_type": "coin_flip",
			"actor": 0,
			"visibility": "public",
			"source": {"player": 0},
			"target": {"player": state.first_player_idx},
			"data": {
				"purpose": "setup_turn_order",
				"results": [state.first_player_idx == 0],
				"coin_winner": state.opening_coin_winner_idx,
			},
		})
	if forced_first not in [0, 1]:
		var request := _request_turn_order_choice(state)
		return StepResult.new(
			true,
			"硬币胜者请选择先后攻。",
			request,
			setup_events,
			state.winner,
			false,
		)
	state.first_player_idx = forced_first
	state.active_player_idx = forced_first
	var opening := _prepare_opening_hands(state, rng)
	if not str(opening.get("error", "")).is_empty():
		return _error(str(opening["error"]), "mulligan_guard", state)
	setup_events.append_array(opening.get("events", []))
	return StepResult.new(
		true,
		"游戏准备完成。",
		null,
		setup_events,
		state.winner,
		false,
	)


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
	var stored_stack := ResolutionStack.from_dict(state.resolution_stack)
	if (
		stored_stack.pending_request != null
		and str(stored_stack.pending_request.metadata.get("domain", "")) == "setup"
	):
		return _apply_setup_choice(state, request, response, rng, stored_stack)
	if (
		stored_stack.pending_request != null
		and str(stored_stack.pending_request.metadata.get("domain", "")) == "knockout"
	):
		return _apply_knockout_choice(state, request, response, rng, stored_stack)
	return choice_settlement.apply_choice(state, request, response, rng)


func _hand_has_basic(player: PlayerState) -> bool:
	for card_id in player.hand:
		if catalog.is_basic_pokemon(card_id):
			return true
	return false


func _request_turn_order_choice(state: GameState) -> ChoiceRequest:
	var chooser := state.opening_coin_winner_idx
	var stack := ResolutionStack.new()
	var frame_id := "setup:turn_order:%d" % state.choice_sequence
	stack.push_continuation("setup_turn_order", {
		"kind": "setup_turn_order",
		"frame_id": frame_id,
		"chooser": chooser,
	})
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, chooser, "choose_turn_order"),
		"choose_turn_order",
		chooser,
		"请选择先攻或后攻。",
		[
			{"option_id": "turn:first", "label": "先攻", "value": {"goes_first": true}},
			{"option_id": "turn:second", "label": "后攻", "value": {"goes_first": false}},
		],
		1,
		1,
		false,
		false,
		{
			"domain": "setup",
			"purpose": "choose_turn_order",
			"revision": state.revision,
			"continuation_frame_id": frame_id,
		},
	)
	state.resolution_stack = stack.to_dict()
	return stack.pending_request


func _apply_setup_choice(
	state: GameState,
	request: ChoiceRequest,
	response: ChoiceResponse,
	rng: PortableRandomSource,
	stack: ResolutionStack,
) -> StepResult:
	var pending := stack.pending_request
	if pending == null or request.request_id != pending.request_id or response.request_id != pending.request_id:
		return _error("选择请求已过期。", "stale_choice", state)
	if int(pending.metadata.get("revision", state.revision)) != state.revision:
		return _error("局面已变化，选择请求已过期。", "stale_choice", state)
	if response.cancelled or response.option_ids.size() != 1:
		return _error("必须选择一个选项。", "choice_count", state)
	var selected_id := response.option_ids[0]
	var valid_ids: Array[String] = []
	for option in pending.options:
		valid_ids.append(str(option.get("option_id", "")))
	if selected_id not in valid_ids:
		return _error("包含无效选择项。", "invalid_choice", state)
	state.revision += 1
	stack.pending_request = null
	stack.frames.clear()
	state.resolution_stack = stack.to_dict()
	match str(pending.metadata.get("purpose", "")):
		"choose_turn_order":
			if selected_id not in ["turn:first", "turn:second"]:
				return _error("先后攻选择无效。", "invalid_choice", state)
			state.first_player_idx = (
				state.opening_coin_winner_idx
				if selected_id == "turn:first"
				else 1 - state.opening_coin_winner_idx
			)
			state.active_player_idx = state.first_player_idx
			var opening := _prepare_opening_hands(state, rng)
			if not str(opening.get("error", "")).is_empty():
				return _error(str(opening["error"]), "mulligan_guard", state)
			var events: Array[Dictionary] = [{
				"event_type": "turn_order_chosen",
				"actor": state.opening_coin_winner_idx,
				"target": {"player": state.first_player_idx},
				"data": {
					"coin_winner": state.opening_coin_winner_idx,
					"first_player": state.first_player_idx,
				},
			}]
			events.append_array(opening.get("events", []))
			return StepResult.new(true, "先后攻已确定。", null, events)
		"choose_mulligan_draw_count":
			return _apply_mulligan_bonus_choice(state, pending.player, selected_id, rng)
	return _error("未知准备阶段选择。", "unknown_setup_choice", state)


func _prepare_opening_hands(state: GameState, rng: PortableRandomSource) -> Dictionary:
	var events: Array[Dictionary] = []
	state.turn_number = 1
	state.mulligan_count = [0, 0]
	for player_idx in [0, 1]:
		var player := state.get_player(player_idx)
		var drawn := player.draw_cards(7)
		events.append(_opening_hand_draw_event(
			player_idx,
			drawn,
			"opening_hand",
			0,
			_hand_has_basic(player),
		))
	var guard := 0
	while (
		not _hand_has_basic(state.get_player(0))
		or not _hand_has_basic(state.get_player(1))
	):
		guard += 1
		if guard > 64:
			return {"error": "连续再战仍未抽到基础宝可梦。", "events": events}
		var needs_redraw := [
			not _hand_has_basic(state.get_player(0)),
			not _hand_has_basic(state.get_player(1)),
		]
		for player_idx in [0, 1]:
			if not needs_redraw[player_idx]:
				continue
			var revealed: Array[String] = state.get_player(player_idx).hand.duplicate()
			events.append({
				"event_type": "cards_revealed",
				"actor": player_idx,
				"visibility": "public",
				"source": {"player": player_idx, "zone": "hand"},
				"data": {
					"player": player_idx,
					"purpose": "mulligan",
					"round": guard,
					"card_ids": revealed,
					"cards": revealed,
				},
			})
		for player_idx in [0, 1]:
			if not needs_redraw[player_idx]:
				continue
			var player := state.get_player(player_idx)
			var returned: Array[String] = player.hand.duplicate()
			state.mulligan_count[player_idx] += 1
			events.append({
				"event_type": "card_moved",
				"actor": player_idx,
				"visibility": "public",
				"source": {"player": player_idx, "zone": "hand"},
				"target": {"player": player_idx, "zone": "deck"},
				"amount": returned.size(),
				"data": {
					"player": player_idx,
					"purpose": "mulligan_return",
					"round": guard,
					"count": returned.size(),
					"card_ids": returned,
				},
			})
			player.deck.append_array(player.hand)
			player.hand.clear()
			rng.shuffle(player.deck)
			events.append({
				"event_type": "deck_shuffled",
				"actor": player_idx,
				"visibility": "public",
				"source": {"player": player_idx, "zone": "deck"},
				"target": {"player": player_idx, "zone": "deck"},
				"data": {
					"player": player_idx,
					"purpose": "mulligan",
					"round": guard,
				},
			})
		for player_idx in [0, 1]:
			if not needs_redraw[player_idx]:
				continue
			var player := state.get_player(player_idx)
			var redrawn := player.draw_cards(7)
			events.append(_opening_hand_draw_event(
				player_idx,
				redrawn,
				"mulligan_redraw",
				guard,
				_hand_has_basic(player),
			))
	var bonus_for_zero := maxi(0, state.mulligan_count[1] - state.mulligan_count[0])
	var bonus_for_one := maxi(0, state.mulligan_count[0] - state.mulligan_count[1])
	state.mulligan_bonus_max = maxi(bonus_for_zero, bonus_for_one)
	state.setup_stage = GameState.SETUP_INITIAL_PLACEMENT
	state.setup_actor_idx = state.first_player_idx
	state.setup_ready = [false, false]
	state.log_action("起始手牌已准备。")
	return {"error": "", "events": events}


func _opening_hand_draw_event(
	player_idx: int,
	cards: Array[String],
	purpose: String,
	round_number: int,
	final_opening_hand: bool,
) -> Dictionary:
	return {
		"event_type": "cards_drawn",
		"actor": player_idx,
		"visibility": "owner",
		"source": {"player": player_idx, "zone": "deck"},
		"target": {"player": player_idx, "zone": "hand"},
		"amount": cards.size(),
		"data": {
			"player": player_idx,
			"purpose": purpose,
			"round": round_number,
			"count": cards.size(),
			"card_ids": cards.duplicate(),
			"final_opening_hand": final_opening_hand,
		},
	}


func _apply_mulligan_bonus_choice(
	state: GameState,
	player_idx: int,
	option_id: String,
	rng: PortableRandomSource,
) -> StepResult:
	if not option_id.begins_with("draw:"):
		return _error("再战奖励选择无效。", "invalid_choice", state)
	var amount := option_id.trim_prefix("draw:").to_int()
	if amount < 0 or amount > state.mulligan_bonus_max:
		return _error("再战奖励抽牌数无效。", "invalid_choice", state)
	var player := state.get_player(player_idx)
	var drawn := player.draw_cards(amount)
	state.extra_draws[player_idx] = drawn.size()
	state.setup_bonus_card_ids[player_idx] = drawn.duplicate()
	var has_placeable_basic := false
	if player.find_empty_bench_slot() >= 0:
		for card_id in drawn:
			if catalog.is_basic_pokemon(card_id):
				has_placeable_basic = true
				break
	var events: Array[Dictionary] = []
	if not drawn.is_empty():
		events.append({
			"event_type": "cards_drawn",
			"actor": player_idx,
			"visibility": "owner",
			"source": {"player": player_idx, "zone": "deck"},
			"target": {"player": player_idx, "zone": "hand"},
			"data": {
				"player": player_idx,
				"count": drawn.size(),
				"card_ids": drawn.duplicate(),
				"purpose": "mulligan_bonus",
			},
		})
	if has_placeable_basic:
		state.setup_stage = GameState.SETUP_BONUS_PLACEMENT
		state.setup_actor_idx = player_idx
		return StepResult.new(true, "可以将奖励抽到的基础宝可梦放入备战区。", null, events)
	var completed := action_executor.complete_setup(state, rng)
	completed.events = events + completed.events
	return completed


func _apply_knockout_choice(
	state: GameState,
	request: ChoiceRequest,
	response: ChoiceResponse,
	rng: PortableRandomSource,
	stack: ResolutionStack,
) -> StepResult:
	var pending := stack.pending_request
	if pending == null or pending.request_id != request.request_id or pending.request_id != response.request_id:
		return _error("选择请求已过期。", "stale_choice", state)
	if int(pending.metadata.get("revision", state.revision)) != state.revision:
		return _error("局面已变化，选择请求已过期。", "stale_choice", state)
	var checkpoint := transaction_manager.capture_choice_transaction(state, rng)
	state.revision += 1
	var purpose := str(pending.metadata.get("purpose", ""))
	var outcome: Dictionary
	if purpose == "treasure_energy_attach":
		outcome = knockout_settlement.apply_treasure_energy_choice(state, response, stack)
	elif purpose == "select_prize":
		outcome = knockout_settlement.apply_prize_choice(state, pending, response, stack)
	else:
		outcome = knockout_settlement.apply_ko_trigger_choice(state, response, stack)
	if not bool(outcome.get("success", false)):
		return transaction_manager.rollback_choice_failure(
			state,
			rng,
			checkpoint,
			str(outcome.get("message", "奖赏卡选择失败。")),
			str(outcome.get("error_code", "invalid_choice")),
		)
	var events: Array[Dictionary] = []
	events.append_array(outcome.get("events", []))
	var next_request: Variant = outcome.get("pending_choice", null)
	if next_request is ChoiceRequest:
		return StepResult.new(
			true, str(outcome.get("message", "")), next_request, events, state.winner, false)
	stack.context.erase("prize_awards")
	stack.context.erase("ko_batch")
	if bool(stack.context.get("finish_end_turn_after_knockouts", false)):
		var end_turn_actor := int(stack.context.get("end_turn_actor", state.active_player_idx))
		stack.context.erase("finish_end_turn_after_knockouts")
		stack.context.erase("end_turn_actor")
		state.resolution_stack = stack.to_dict()
		return turn_settlement.finish_end_turn_after_knockouts(
			state, end_turn_actor, rng, events)
	stack.pending_request = null
	if bool(stack.context.get("finish_attack_after_prizes", false)):
		var actor := int(stack.context.get("actor", state.active_player_idx))
		# The KO/prize pipeline owns this serialized finalization frame. Popping is
		# deliberately idempotent so GameEngine does not duplicate the generic
		# choice-settlement frame inspection policy.
		stack.pop_finalize_attack()
		return attack_settlement.finish_attack_after_prizes(
			state, stack, actor, rng, events)
	state.resolution_stack = stack.to_dict()
	knockout_settlement.resolve_empty_boards_and_promotions(state)
	if state.is_terminal():
		knockout_settlement.append_game_over_event(events, state)
		state.resolution_stack = ResolutionStack.new().to_dict()
	return StepResult.new(
		true,
		str(outcome.get("message", "")),
		null,
		events,
		state.winner,
		state.is_terminal(),
	)


func _deck_validation_error(deck: Array[String]) -> Dictionary:
	if deck.size() != 60:
		return {"message": "双方牌组都必须正好包含60张卡。", "code": "invalid_deck_size"}
	var has_basic := false
	var counts_by_name: Dictionary = {}
	var ace_spec_count := 0
	var radiant_count := 0
	for card_id in deck:
		if not catalog.cards.has(card_id):
			return {"message": "牌组包含未知卡牌：%s。" % card_id, "code": "unknown_card"}
		has_basic = has_basic or catalog.is_basic_pokemon(card_id)
		var card := catalog.get_card(card_id)
		var card_name := catalog.card_name(card_id)
		if not catalog.is_basic_energy(card_id):
			counts_by_name[card_name] = int(counts_by_name.get(card_name, 0)) + 1
			if int(counts_by_name[card_name]) > 4:
				return {"message": "同名卡牌最多放入4张：%s。" % card_name, "code": "too_many_copies"}
		var rules_text := " ".join(card.get("rules", []))
		var subtypes_text := " ".join(card.get("subtypes", []))
		if "ACE SPEC" in rules_text or "ACE SPEC" in subtypes_text:
			ace_spec_count += 1
		if "Radiant" in subtypes_text or card_name.begins_with("光辉"):
			radiant_count += 1
	if not has_basic:
		return {"message": "牌组至少需要1张基础宝可梦。", "code": "deck_without_basic"}
	if ace_spec_count > 1:
		return {"message": "牌组最多放入1张ACE SPEC卡。", "code": "too_many_ace_spec"}
	if radiant_count > 1:
		return {"message": "牌组最多放入1张光辉宝可梦。", "code": "too_many_radiant"}
	return {}


func _error(
	message: String,
	code: String,
	state: GameState,
) -> StepResult:
	return StepResult.new(false, message, null, [], state.winner, false, code)
