class_name AuthoritativeSession
extends RefCounted

var catalog: CardCatalog
var state: GameState
var rng := PortableRandomSource.new(1)
var room_id := ""
var deck_keys: Array[String] = ["", ""]
var native_rules: NativeRulesSessionAdapter


func _init(p_room_id: String = "", p_catalog: CardCatalog = null) -> void:
	room_id = p_room_id
	catalog = p_catalog if p_catalog != null else CardCatalog.shared()
	native_rules = NativeRulesSessionAdapter.new(catalog)


func set_native_rules_enabled(enabled: bool) -> bool:
	if state != null:
		return false
	return enabled and native_rules.is_available()


func match_journal() -> Dictionary:
	return native_rules.journal()


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
	if not native_rules.is_available():
		return StepResult.new(
			false,
			"原生规则会话不可用。",
			null,
			[],
			-1,
			false,
			"native_rules_unavailable",
		)
	deck_keys = [host_deck, client_deck]
	var result := native_rules.start_match(
		host_deck,
		client_deck,
		seed,
		forced_first,
		rules_options,
	)
	state = native_rules.state
	if state != null:
		rng = PortableRandomSource.new(native_rules.rng_state)
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
	var native_result := native_rules.apply_action(action_data)
	state = native_rules.state
	if state != null:
		rng.set_state(native_rules.rng_state)
	return native_result


func submit_choice(player_idx: int, response_data: Dictionary) -> StepResult:
	if state == null:
		return StepResult.new(false, "对局尚未开始。", null, [], -1, false, "not_started")
	var request := native_rules.pending_choice(player_idx)
	if request == null:
		var other_request := native_rules.pending_choice(1 - player_idx)
		if other_request != null:
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
	var native_result := native_rules.apply_choice(response.to_dict())
	state = native_rules.state
	if state != null:
		rng.set_state(native_rules.rng_state)
	return native_result


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
	var native_result := native_rules.surrender(player_idx)
	state = native_rules.state
	if state != null:
		rng.set_state(native_rules.rng_state)
	return native_result


func view_for(
	player_idx: int,
	presentation_events: Array = [],
) -> Dictionary:
	if state == null:
		return {}
	var native_state_view := native_rules.view_for(player_idx)
	var native_pending := native_rules.pending_choice(player_idx)
	var waiting := native_rules.pending_choice(1 - player_idx)
	var native_query := LegalActionQueryResult.ok(state.revision, [])
	if native_pending == null and waiting == null and _current_actor() == player_idx:
		native_query = native_rules.legal_actions(player_idx)
	var visible_events: Array[Dictionary] = []
	for event in PresentationEvent.normalize_all(
		presentation_events, state.revision, state.active_player_idx):
		var visible := PresentationEvent.for_player(event, player_idx)
		if not visible.is_empty():
			visible_events.append(visible)
	var group_rows: Array = []
	if native_query.success:
		for group in native_query.groups:
			group_rows.append(group.to_dict())
	return {
		"state": native_state_view,
		"legal_action_groups": group_rows,
		"legal_action_error": native_query.code,
		"presentation_events": visible_events,
		"choice_request": native_pending.to_dict() if native_pending != null else null,
		"wait_context": (
			{
				"waiting_for_player": 1 - player_idx,
				"choice_kind": _coarse_native_choice_kind(waiting),
			}
			if waiting != null else null
		),
	}


func _current_actor() -> int:
	if state == null:
		return -1
	if not state.pending_promotions.is_empty():
		return int(state.pending_promotions[0])
	if state.phase == "SETUP":
		return state.setup_actor_idx
	return state.active_player_idx


static func _coarse_native_choice_kind(request: ChoiceView) -> String:
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
	if "trigger" in request.request_type:
		return "trigger"
	if request.request_type == "select_prize":
		return "prize"
	if request.request_type in ["choose_turn_order", "choose_mulligan_draw_count"]:
		return "setup"
	return "choice"
