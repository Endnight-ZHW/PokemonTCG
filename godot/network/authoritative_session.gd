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
	var stack := ResolutionStack.from_dict(state.resolution_stack)
	var pending := stack.pending_request
	var render_state := state
	var hide_cancellable_transaction := false
	if pending != null and pending.player != player_idx:
		var checkpoint: Variant = stack.context.get("cancel_action_checkpoint")
		if checkpoint is Dictionary and Dictionary(checkpoint).get("state") is Dictionary:
			# A cancellable Trainer is provisional until its final choice commits.
			# The chooser must see the working state, while the opponent keeps the
			# pre-action board and only learns that a generic choice is pending.
			render_state = GameState.from_dict(Dictionary(checkpoint)["state"])
			render_state.revision = state.revision
			render_state.choice_sequence = state.choice_sequence
			hide_cancellable_transaction = true
	var legal: Array = []
	if pending == null and _current_actor() == player_idx:
		for action in engine.legal_actions(state, player_idx, true):
			legal.append(action.to_dict())
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
		"state": StateSerializer.for_player(render_state, player_idx),
		"legal_actions": legal,
		"presentation_events": visible_events,
		"choice_request": (
			_choice_payload(pending, state.revision)
			if pending != null and pending.player == player_idx
			else null
		),
		"wait_context": (
			{
				"waiting_for_player": pending.player,
				"choice_kind": _coarse_choice_kind(pending),
			}
			if pending != null and pending.player != player_idx
			else null
		),
	}


static func _choice_payload(request: ChoiceRequest, revision: int) -> Dictionary:
	var payload := request.to_dict()
	var metadata: Dictionary = Dictionary(payload.get("metadata", {})).duplicate(true)
	if str(metadata.get("domain", "")).is_empty():
		metadata["domain"] = "rules"
	metadata["revision"] = revision
	if str(metadata.get("continuation_frame_id", "")).is_empty():
		metadata["continuation_frame_id"] = request.request_id
	payload["metadata"] = metadata
	return payload


static func _coarse_choice_kind(request: ChoiceRequest) -> String:
	if request == null:
		return ""
	if request.request_type == "select_attachment":
		return "attachment"
	if request.request_type in [
		"distribute_energy", "select_energy_source", "select_energy_target",
		"select_own_bench_energy",
	]:
		return "energy"
	if request.request_type == "coin_flip":
		return "coin"
	return "choice"


func _current_actor() -> int:
	if state == null:
		return -1
	if not state.pending_promotions.is_empty():
		return int(state.pending_promotions[0])
	if state.phase == "SETUP":
		return state.setup_actor_idx
	return state.active_player_idx
