class_name AuthoritativeSession
extends RefCounted

var catalog: CardCatalog
var engine: GameEngine
var state: GameState
var rng := PortableRandomSource.new(1)
var room_id := ""
var deck_keys: Array[String] = ["", ""]


func _init(p_room_id: String = "", p_catalog: CardCatalog = null) -> void:
	room_id = p_room_id
	catalog = p_catalog if p_catalog != null else CardCatalog.shared()
	engine = GameEngine.new(catalog)


func start_match(
	host_deck: String,
	client_deck: String,
	seed: int,
	forced_first: int = -1,
) -> StepResult:
	if not catalog.decks.has(host_deck) or not catalog.decks.has(client_deck):
		return StepResult.new(
			false,
			"未知牌组。",
			null,
			[],
			-1,
			false,
			"invalid_deck",
		)
	deck_keys = [host_deck, client_deck]
	state = GameState.new()
	state.public_deck_keys = deck_keys.duplicate()
	rng = PortableRandomSource.new(seed)
	var result := engine.setup_game(
		state,
		catalog.expand_deck(host_deck),
		catalog.expand_deck(client_deck),
		rng,
		forced_first,
	)
	if result.success:
		state.players[0].name = "房主"
		state.players[1].name = "挑战者"
	return result


func submit_action(player_idx: int, action_data: Dictionary) -> StepResult:
	if state == null:
		return StepResult.new(false, "对局尚未开始。", null, [], -1, false, "not_started")
	var action := GameAction.from_dict(action_data)
	if action.actor != player_idx:
		return StepResult.new(false, "动作玩家与连接身份不匹配。", null, [], state.winner, false, "wrong_actor")
	if action.action_id.is_empty():
		return StepResult.new(false, "动作缺少唯一 ID。", null, [], state.winner, false, "missing_action_id")
	return engine.apply_action(state, action, rng)


func submit_choice(player_idx: int, response_data: Dictionary) -> StepResult:
	if state == null:
		return StepResult.new(false, "对局尚未开始。", null, [], -1, false, "not_started")
	var request := ResolutionStack.from_dict(state.resolution_stack).pending_request
	if request == null:
		return StepResult.new(false, "当前没有待处理选择。", null, [], state.winner, false, "stale_choice")
	if request.player != player_idx:
		return StepResult.new(false, "该选择不属于当前玩家。", null, [], state.winner, false, "wrong_actor")
	var response := ChoiceResponse.from_dict(response_data)
	return engine.apply_choice(state, request, response, rng)


func surrender(player_idx: int) -> StepResult:
	if state == null or player_idx not in [0, 1]:
		return StepResult.new(false, "无法投降。", null, [], -1, false, "invalid_actor")
	if state.phase == "GAME_OVER" or state.winner >= 0:
		return StepResult.new(
			false,
			"对局已经结束。",
			null,
			[],
			state.winner,
			true,
			"game_over",
		)
	state.revision += 1
	state.winner = 1 - player_idx
	state.phase = "GAME_OVER"
	state.log_action("%s 投降。" % state.players[player_idx].name)
	return StepResult.new(true, "玩家投降。", null, [{
		"event_type": "game_over",
		"actor": state.winner,
		"data": {
			"winner": state.winner,
			"reason": "surrender",
		},
	}], state.winner, true)


func view_for(
	player_idx: int,
	presentation_events: Array = [],
) -> Dictionary:
	if state == null:
		return {}
	var pending := ResolutionStack.from_dict(state.resolution_stack).pending_request
	var legal: Array = []
	if pending == null and _current_actor() == player_idx:
		for action in engine.legal_actions(state, player_idx, true):
			legal.append(action.to_dict())
	var visible_events: Array[Dictionary] = []
	var normalized := PresentationEvent.normalize_all(
		presentation_events,
		state.revision,
		state.active_player_idx,
	)
	for event in normalized:
		var visible := PresentationEvent.for_player(event, player_idx)
		if not visible.is_empty():
			visible_events.append(visible)
	return {
		"state": StateSerializer.for_player(state, player_idx),
		"legal_actions": legal,
		"presentation_events": visible_events,
		"choice_request": (
			pending.to_dict()
			if pending != null and pending.player == player_idx
			else null
		),
	}


func _current_actor() -> int:
	if state == null:
		return -1
	if not state.pending_promotions.is_empty():
		return int(state.pending_promotions[0])
	if state.phase == "SETUP":
		return 0 if not state.setup_ready[0] else 1
	return state.active_player_idx
