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
	rules_options: Dictionary = {"apply_type_matchups": false},
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
	state.set_type_matchups_enabled(bool(rules_options.get(
		"apply_type_matchups", false)))
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
	# Authenticate the connection identity before interpreting refs or payload.
	# This keeps actor forgery distinguishable from an otherwise malformed action.
	if action_data.get("actor") is int and int(action_data["actor"]) != player_idx:
		return StepResult.new(false, "动作玩家与连接身份不匹配。", null, [], state.winner, false, "unauthorized_actor")
	var schema := GameAction.validate_wire_dict(action_data, true)
	if not bool(schema.get("ok", false)):
		return StepResult.new(
			false,
			str(schema.get("message", "动作结构无效。")),
			null,
			[],
			state.winner,
			false,
			str(schema.get("code", "invalid_schema")),
		)
	var action := GameAction.from_dict(action_data)
	if action.actor != player_idx:
		return StepResult.new(false, "动作玩家与连接身份不匹配。", null, [], state.winner, false, "unauthorized_actor")
	if action.action_id.is_empty():
		return StepResult.new(false, "动作缺少唯一 ID。", null, [], state.winner, false, "missing_action_id")
	return engine.apply_action(state, action, rng)


func submit_choice(player_idx: int, response_data: Dictionary) -> StepResult:
	if state == null:
		return StepResult.new(false, "对局尚未开始。", null, [], -1, false, "not_started")
	var request := engine.query_pending_choice(state, player_idx)
	if request == null:
		if engine.query_pending_choice(state, 1 - player_idx) != null:
			return StepResult.new(false, "该选择不属于当前玩家。", null, [], state.winner, false, "wrong_actor")
		return StepResult.new(false, "当前没有待处理选择。", null, [], state.winner, false, "stale_choice")
	var schema := ProtocolV6.validate_payload(
		ProtocolV6.CHOICE_SUBMIT, {"response": response_data})
	if not bool(schema.get("ok", false)):
		return StepResult.new(
			false,
			str(schema.get("message", "选择响应结构无效。")),
			null,
			[],
			state.winner,
			false,
			"invalid_choice",
		)
	var response := ChoiceResponse.from_dict(response_data)
	return engine.apply_choice_response(state, response, rng)


func surrender(player_idx: int) -> StepResult:
	if state == null or player_idx not in [0, 1]:
		return StepResult.new(false, "无法投降。", null, [], -1, false, "invalid_actor")
	if state.is_terminal():
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
	state.set_win(1 - player_idx, "surrender")
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
	var public_view := engine.query_state_view(state, player_idx)
	var pending := engine.query_pending_choice(state, player_idx)
	var hide_cancellable_transaction := bool(public_view.get(
		"hides_provisional_action", false))
	var legal_groups: Array = []
	var legal_query := LegalActionQueryResult.ok(state.revision, [])
	if (
		public_view.get("choice_request") == null
		and public_view.get("wait_context") == null
		and _current_actor() == player_idx
	):
		legal_query = engine.query_legal_action_groups(state, player_idx)
		if legal_query.success:
			for group in legal_query.groups:
				legal_groups.append(group.to_dict())
	var visible_events: Array[Dictionary] = []
	if not hide_cancellable_transaction:
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
		"state": public_view.get("state", {}),
		"legal_action_groups": legal_groups,
		"legal_action_error": legal_query.code,
		"presentation_events": visible_events,
		"choice_request": public_view.get("choice_request"),
		"wait_context": public_view.get("wait_context"),
	}


func _current_actor() -> int:
	if state == null:
		return -1
	if not state.pending_promotions.is_empty():
		return int(state.pending_promotions[0])
	if state.phase == "SETUP":
		return state.setup_actor_idx
	return state.active_player_idx
