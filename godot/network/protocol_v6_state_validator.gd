extends "res://network/protocol_v6_presentation_validator.gd"

static func _validate_state_update_payload(payload: Dictionary) -> Dictionary:
	if not payload.get("state") is Dictionary:
		return _invalid("invalid_payload", "状态同步消息缺少局面对象。")
	if payload.has("legal_actions"):
		return _invalid("invalid_payload", "Protocol v6 不接受展开式合法动作。")
	if not payload.get("legal_action_groups", []) is Array:
		return _invalid("invalid_payload", "合法动作分组类型错误。")
	if not _bounded_string(
		payload.get("legal_action_error", ""), MAX_IDENTIFIER_BYTES
	):
		return _invalid("invalid_payload", "合法动作错误码无效。")
	if payload.has("presentation_events") and not payload["presentation_events"] is Array:
		return _invalid("invalid_payload", "表现事件列表类型错误。")
	if payload.has("choice_request") and payload["choice_request"] != null:
		if not payload["choice_request"] is Dictionary:
			return _invalid("invalid_payload", "选择请求类型错误。")
	if payload.has("wait_context") and payload["wait_context"] != null:
		if not _validate_wait_context(payload["wait_context"]):
			return _invalid("invalid_payload", "等待上下文格式无效。")
	var state: Dictionary = payload["state"]
	if not _bounded_int(state, "revision", 0, 2147483647):
		return _invalid("invalid_payload", "状态同步消息缺少版本号。")
	if not state.get("your") is Dictionary or not state.get("opponent") is Dictionary:
		return _invalid("invalid_payload", "状态同步消息缺少玩家视图。")
	var state_validation := _validate_state_payload(state)
	if not bool(state_validation.get("ok", false)):
		return state_validation
	var legal_groups: Array = payload.get("legal_action_groups", [])
	if legal_groups.size() > MAX_LEGAL_ACTIONS:
		return _invalid("invalid_payload", "合法动作数量超过限制。")
	for group_value in legal_groups:
		var group_validation := _validate_legal_action_group(group_value)
		if not bool(group_validation.get("ok", false)):
			return group_validation
		if int(Dictionary(group_value).get("base_revision", -1)) != int(state["revision"]):
			return _invalid("invalid_payload", "合法动作分组版本与局面不一致。")
	var presentation_events: Array = payload.get("presentation_events", [])
	if presentation_events.size() > MAX_PRESENTATION_EVENTS:
		return _invalid("invalid_payload", "表现事件数量超过限制。")
	for event_value in presentation_events:
		if not _validate_presentation_event(event_value):
			return _invalid("invalid_payload", "表现事件格式无效。")
	if payload.get("choice_request") != null:
		var choice_validation := _validate_choice_view(payload["choice_request"])
		if not bool(choice_validation.get("ok", false)):
			return choice_validation
		if int(Dictionary(payload["choice_request"]).get(
			"base_revision", -1)) != int(state["revision"]):
			return _invalid("invalid_payload", "选择视图版本与局面不一致。")
	return {"ok": true}


static func _validate_wait_context(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var context: Dictionary = value
	return (
		context.size() == 2
		and _bounded_int(context, "waiting_for_player", 0, 1)
		and _bounded_string(context.get("choice_kind", ""), 32)
		and str(context.get("choice_kind", "")) in [
			"attachment", "energy", "coin", "choice", "setup", "prize", "trigger",
		]
	)


static func _validate_state_payload(state: Dictionary) -> Dictionary:
	if (
		not _bounded_string(state.get("phase"), 32)
		or str(state.get("phase", "")) not in GAME_PHASES
		or not _bounded_int(state, "turn_number", 0, 2147483647)
		or not _bounded_int(state, "active_player_idx", 0, 1)
		or not _bounded_int(state, "first_player_idx", 0, 1)
		or not _bounded_int(state, "winner", -1, 1)
		or not _bounded_string(state.get("rules_profile_id", ""), 64)
		or str(state.get("rules_profile_id", "")) != RULES_PROFILE_ID
		or not _validate_rules_options(state.get("rules_options", {}))
		or not _bounded_string(state.get("setup_stage", ""), 32)
		or str(state.get("setup_stage", "")) not in SETUP_STAGES
		or not _bounded_int(state, "setup_actor_idx", -1, 1)
		or not _bounded_int(state, "opening_coin_winner_idx", -1, 1)
		or not _bounded_int(state, "mulligan_bonus_max", 0, MAX_DECK_CARDS)
		or not _bounded_string(state.get("result_status", ""), 16)
		or str(state.get("result_status", "")) not in RESULT_STATUSES
		or not _bounded_string(state.get("result_reason", ""), MAX_TEXT_BYTES)
		or not _bounded_int(state, "stadium_owner_idx", -1, 1)
	):
		return _invalid("invalid_payload", "局面基础字段无效。")
	var terminal_phase := str(state["phase"]) == "GAME_OVER"
	var result_status := str(state["result_status"])
	if terminal_phase != (result_status != "ONGOING"):
		return _invalid("invalid_payload", "终局阶段与结果状态不一致。")
	if (
		(result_status == "ONGOING" and int(state["winner"]) != -1)
		or (result_status == "WIN" and int(state["winner"]) not in [0, 1])
		or (result_status == "DRAW" and int(state["winner"]) != -1)
	):
		return _invalid("invalid_payload", "结果状态与胜者字段不一致。")
	if not _validate_result_conditions(state.get("result_conditions", [])):
		return _invalid("invalid_payload", "胜负条件记录无效。")
	if (
		not _bounded_string(state.get("stadium_card_id", ""), MAX_IDENTIFIER_BYTES)
		or not state.get("apply_type_matchups", false) is bool
		or bool(state.get("apply_type_matchups", false)) != bool(
			Dictionary(state["rules_options"]).get("apply_type_matchups", false)
		)
	):
		return _invalid("invalid_payload", "局面字段类型无效。")
	if not _fixed_string_array(state.get("public_deck_keys"), 2, MAX_IDENTIFIER_BYTES):
		return _invalid("invalid_payload", "公开牌组列表无效。")
	if not _bounded_string_array(
		state.get("action_log"), MAX_ACTION_LOG_ENTRIES, MAX_TEXT_BYTES
	):
		return _invalid("invalid_payload", "动作日志无效或超过限制。")
	if (
		not _fixed_int_array(state.get("mulligan_count"), 2, 0, MAX_DECK_CARDS)
		or not _fixed_int_array(state.get("extra_draws"), 2, 0, MAX_DECK_CARDS)
		or not _fixed_bool_array(state.get("setup_ready"), 2)
		or not _bounded_player_index_array(state.get("pending_promotions"), 2)
	):
		return _invalid("invalid_payload", "局面玩家数组无效。")
	var setup_board_hidden := str(state["setup_stage"]) != "COMPLETE"
	var own_validation := _validate_player_payload(state["your"], true, false)
	if not bool(own_validation.get("ok", false)):
		return own_validation
	return _validate_player_payload(
		state["opponent"],
		false,
		setup_board_hidden,
	)


static func _validate_player_payload(
	payload: Dictionary,
	show_hand: bool,
	require_hidden_board: bool,
) -> Dictionary:
	if payload.has("deck") or payload.has("prizes") or (not show_hand and payload.has("hand")):
		return _invalid("invalid_payload", "局面泄露了隐藏牌身份。")
	if not _bounded_string(payload.get("name", ""), MAX_IDENTIFIER_BYTES):
		return _invalid("invalid_payload", "玩家名称无效。")
	if (
		not _bounded_int(payload, "deck_count", 0, MAX_DECK_CARDS)
		or not _bounded_int(payload, "hand_count", 0, MAX_DECK_CARDS)
		or not _bounded_int(payload, "prize_count", 0, MAX_PRIZES)
	):
		return _invalid("invalid_payload", "牌区数量无效或超过限制。")
	if show_hand:
		if not _bounded_string_array(payload.get("hand"), MAX_DECK_CARDS, MAX_IDENTIFIER_BYTES):
			return _invalid("invalid_payload", "手牌列表无效或超过限制。")
		if int(payload["hand_count"]) != Array(payload["hand"]).size():
			return _invalid("invalid_payload", "手牌数量与列表不一致。")
	if not _bounded_string_array(
		payload.get("discard"), MAX_DECK_CARDS, MAX_IDENTIFIER_BYTES
	):
		return _invalid("invalid_payload", "弃牌区无效或超过限制。")
	if not payload.get("bench") is Array or Array(payload["bench"]).size() > MAX_BENCH_SIZE:
		return _invalid("invalid_payload", "备战区无效或超过限制。")
	if payload.get("active") != null and not (
		_validate_hidden_pokemon(payload["active"])
		if require_hidden_board
		else _validate_pokemon(payload["active"])
	):
		return _invalid("invalid_payload", "战斗宝可梦数据无效。")
	for pokemon_value in payload["bench"]:
		if pokemon_value != null and not (
			_validate_hidden_pokemon(pokemon_value)
			if require_hidden_board
			else _validate_pokemon(pokemon_value)
		):
			return _invalid("invalid_payload", "备战宝可梦数据无效。")
	for flag in [
		"supporter_played_this_turn", "energy_attached_this_turn",
		"retreated_this_turn", "stadium_played_this_turn",
		"stadium_used_this_turn", "healed_this_turn", "vstar_power_used",
		"was_ko_by_attack",
	]:
		if payload.has(flag) and not payload[flag] is bool:
			return _invalid("invalid_payload", "玩家状态标记类型无效。")
	if payload.has("attack_locked_names"):
		var locks_value: Variant = payload["attack_locked_names"]
		if not locks_value is Dictionary or Dictionary(locks_value).size() > 32:
			return _invalid("invalid_payload", "玩家招式限制数据无效。")
		for attack_name_value in Dictionary(locks_value).keys():
			var attack_name := str(attack_name_value)
			var expires_value: Variant = Dictionary(locks_value)[attack_name_value]
			if (
				not attack_name_value is String
				or not _bounded_string(attack_name, MAX_IDENTIFIER_BYTES)
				or attack_name.is_empty()
				or not expires_value is int
				or int(expires_value) < 0
				or int(expires_value) > 2147483647
			):
				return _invalid("invalid_payload", "玩家招式限制数据无效。")
	return {"ok": true}


static func _validate_pokemon(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var pokemon: Dictionary = value
	var allowed_fields := [
		"card_id", "damage_counters", "energy_card_ids", "attached_tool_id",
		"status_conditions", "evolution_stack_ids", "can_evolve_this_turn",
		"placed_this_turn", "used_abilities", "healed_this_turn",
		"paralyzed_since_turn", "modifiers",
	]
	for key_value in pokemon.keys():
		if str(key_value) not in allowed_fields:
			return false
	if (
		not _bounded_string(pokemon.get("card_id"), MAX_IDENTIFIER_BYTES)
		or str(pokemon.get("card_id", "")).is_empty()
		or not _bounded_int(pokemon, "damage_counters", 0, 10000)
		or not _bounded_string(pokemon.get("attached_tool_id", ""), MAX_IDENTIFIER_BYTES)
	):
		return false
	if (
		not _bounded_string_array(
			pokemon.get("energy_card_ids", []), MAX_DECK_CARDS, MAX_IDENTIFIER_BYTES)
		or not _bounded_string_array(
			pokemon.get("evolution_stack_ids", []), MAX_DECK_CARDS, MAX_IDENTIFIER_BYTES)
		or not _bounded_string_array(
			pokemon.get("used_abilities", []), 32, MAX_IDENTIFIER_BYTES)
	):
		return false
	var statuses: Variant = pokemon.get("status_conditions", [])
	if not statuses is Array or Array(statuses).size() > STATUS_CONDITIONS.size():
		return false
	for status_value in statuses:
		if not status_value is String or str(status_value) not in STATUS_CONDITIONS:
			return false
	if not pokemon.get("modifiers", []) is Array or Array(pokemon.get("modifiers", [])).size() > 32:
		return false
	for modifier_value in pokemon.get("modifiers", []):
		if (
			not modifier_value is Dictionary
			or not _json_tree_is_bounded(modifier_value)
			or not PokemonState.modifier_wire_validation_error(
				modifier_value).is_empty()
		):
			return false
	for flag in [
		"can_evolve_this_turn", "placed_this_turn", "healed_this_turn",
	]:
		if pokemon.has(flag) and not pokemon[flag] is bool:
			return false
	for integer_field in ["paralyzed_since_turn"]:
		if pokemon.has(integer_field) and not _is_integer_number(pokemon[integer_field]):
			return false
	return true


static func _validate_action(value: Variant, require_action_id: bool) -> Dictionary:
	if value is Dictionary:
		var action: Dictionary = value
		if (
			not _bounded_string(action.get("action_id", ""), MAX_IDENTIFIER_BYTES)
			or not _bounded_string(action.get("kind", ""), 64)
		):
			return _invalid("invalid_payload", "动作标识字段无效。")
	var validation := GameAction.validate_wire_dict(value, require_action_id)
	if not bool(validation.get("ok", false)):
		return _invalid(
			str(validation.get("code", "invalid_payload")),
			str(validation.get("message", "动作字段无效。")),
		)
	return {"ok": true}


static func _validate_legal_action_group(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return _invalid("invalid_payload", "合法动作分组必须是对象。")
	var group: Dictionary = value
	var fields := [
		"group_id", "base_revision", "actor", "kind", "source", "payload", "targets",
	]
	if group.size() != fields.size():
		return _invalid("invalid_payload", "合法动作分组包含缺失或多余字段。")
	for field in fields:
		if not group.has(field):
			return _invalid("invalid_payload", "合法动作分组缺少字段。")
	if (
		not _bounded_string(group.get("group_id", ""), MAX_IDENTIFIER_BYTES)
		or str(group.get("group_id", "")).is_empty()
		or not _bounded_int(group, "base_revision", 0, 2147483647)
		or not _bounded_int(group, "actor", 0, 1)
		or not _bounded_string(group.get("kind", ""), 64)
		or not group.get("payload") is Dictionary
		or not group.get("targets") is Array
		or Array(group["targets"]).size() > MAX_CHOICE_OPTIONS
	):
		return _invalid("invalid_payload", "合法动作分组字段无效。")
	if group["source"] != null and not _validate_entity_ref(group["source"]):
		return _invalid("invalid_payload", "合法动作来源引用无效。")
	var targets: Array = group["targets"]
	var probe_targets: Array = targets if not targets.is_empty() else [null]
	var seen_targets: Dictionary = {}
	for target_value in probe_targets:
		if target_value != null:
			if not _validate_entity_ref(target_value):
				return _invalid("invalid_payload", "合法动作目标引用无效。")
			var signature := JSON.stringify(target_value)
			if seen_targets.has(signature):
				return _invalid("invalid_payload", "合法动作目标重复。")
			seen_targets[signature] = true
		var action := GameAction.create(
			str(group["kind"]),
			Dictionary(group["payload"]),
			int(group["actor"]),
			EntityRef.from_dict(group["source"]) if group["source"] is Dictionary else null,
			EntityRef.from_dict(target_value) if target_value is Dictionary else null,
			"",
			int(group["base_revision"]),
		)
		var action_validation := GameAction.validate_instance(action, true)
		if not bool(action_validation.get("ok", false)):
			return _invalid(
				str(action_validation.get("code", "invalid_payload")),
				str(action_validation.get("message", "合法动作分组无效。")),
			)
	return {"ok": true}
