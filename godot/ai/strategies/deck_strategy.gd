class_name DeckStrategy
extends RefCounted

## Pure, read-only scoring surface for one deck strategy.
##
## `info` is a public AI information-set dictionary, `action_row` is a serialized
## legal GameAction, and `semantic_catalog` contains static public card data.
## Strategies rank inputs supplied by the rules engine; they never create actions.

const MAX_ACTION_SCORE := 160.0
const MAX_CHOICE_SCORE := 120.0
const MAX_STATE_SCORE := 400.0
const MAX_STAGE_ACTION_SCORE := 14.0
const MAX_STAGE_STATE_SCORE := 32.0
const MAX_CANDIDATE_SCORE := 24.0

var _profile: Dictionary = {}
var _deck_archetypes: Dictionary = {}


func _init(profile: Dictionary = {}, deck_archetypes: Dictionary = {}) -> void:
	_profile = profile.duplicate(true)
	_deck_archetypes = deck_archetypes.duplicate(true)
	_deep_make_read_only(_profile)
	_deep_make_read_only(_deck_archetypes)


func strategy_id() -> String:
	return str(_profile.get("strategy_id", "generic_balanced_v1"))


func deck_key() -> String:
	return str(_profile.get("deck_key", "generic"))


func version() -> int:
	return int(_profile.get("version", 0))


func content_hash() -> String:
	return str(_profile.get("content_hash", ""))


func runtime_hook_hash() -> String:
	return str(_profile.get("runtime_hook_hash", ""))


func profile() -> Dictionary:
	return _profile


func action_score(
	info: Dictionary,
	action_row: Dictionary,
	semantic_catalog: Dictionary = {},
) -> float:
	var score := (
		action_score_adjustment(info, action_row, semantic_catalog)
		+ matchup_adjustment(info, action_row, semantic_catalog)
		+ stage_goal_action_adjustment(info, action_row)
		+ candidate_score(info, action_row, semantic_catalog)
	)
	return clampf(score, -MAX_ACTION_SCORE, MAX_ACTION_SCORE)


func choice_score(
	info: Dictionary,
	choice_view: Dictionary,
	option: Dictionary,
	semantic_catalog: Dictionary = {},
) -> float:
	var keep_value := choice_option_score(info, choice_view, option, semantic_catalog)
	var mode := choice_mode(info, choice_view)
	var score := keep_value
	if mode in ["discard", "payment", "source"]:
		score = -keep_value
		if mode == "discard":
			score += discard_synergy_score(
				info, choice_view, option, semantic_catalog)
	return clampf(score, -MAX_CHOICE_SCORE, MAX_CHOICE_SCORE)


func state_score(info: Dictionary, semantic_catalog: Dictionary = {}) -> float:
	return clampf(
		state_score_adjustment(info, semantic_catalog)
		+ stage_goal_state_adjustment(info),
		-MAX_STATE_SCORE,
		MAX_STATE_SCORE,
	)


func mandatory_action(
	_info: Dictionary,
	_action_rows: Array,
	_semantic_catalog: Dictionary = {},
) -> Dictionary:
	# Reserved for provably dominant public-information tactics. The default
	# deliberately leaves selection to the planner.
	return {}


func turn_goals(info: Dictionary) -> Dictionary:
	var stage := plan_stage(info)
	return {
		"strategy_id": strategy_id(),
		"strategy_version": version(),
		"content_hash": content_hash(),
		"runtime_hook_hash": runtime_hook_hash(),
		"deck_key": deck_key(),
		"stage": stage,
		"goal": stage_goal(stage),
		"opponent_deck_key": _opponent_deck_key(info),
		"search_hints": search_hints(info),
	}


func plan_stage(info: Dictionary) -> String:
	var goals := _stage_goals()
	if goals.is_empty():
		return "develop"
	if _opponent_prize_count(info) <= 2 or _own_prize_count(info) <= 2:
		return str(Dictionary(goals[goals.size() - 1]).get("id", "closeout"))
	if _turn_number(info) <= 2 or _own_board_rows(info).size() <= 1:
		return str(Dictionary(goals[0]).get("id", "setup"))
	return str(Dictionary(goals[mini(1, goals.size() - 1)]).get("id", "develop"))


func stage_goal(stage_id: String) -> Dictionary:
	for goal_value in _stage_goals():
		if goal_value is Dictionary:
			var goal: Dictionary = goal_value
			if str(goal.get("id", "")) == stage_id:
				return goal.duplicate(true)
	return {}


func stage_goal_action_adjustment(info: Dictionary, action_row: Dictionary) -> float:
	var goal := stage_goal(plan_stage(info))
	var targets: Variant = goal.get("targets", {})
	if not targets is Dictionary:
		return 0.0
	var score := 0.0
	for role_value in Dictionary(targets):
		var role := str(role_value)
		var required := maxi(0, int(Dictionary(targets)[role_value]))
		var deficit := maxi(0, required - _role_progress(info, role))
		if deficit > 0 and _action_advances_role(action_row, role):
			score += weight("stage_action_bonus", 7.0) * float(mini(deficit, 2))
	return clampf(score, 0.0, MAX_STAGE_ACTION_SCORE)


func stage_goal_state_adjustment(info: Dictionary) -> float:
	var goal := stage_goal(plan_stage(info))
	var targets: Variant = goal.get("targets", {})
	if not targets is Dictionary:
		return 0.0
	var progress := 0
	for role_value in Dictionary(targets):
		var role := str(role_value)
		var required := maxi(0, int(Dictionary(targets)[role_value]))
		progress += mini(required, _role_progress(info, role))
	return clampf(
		float(progress) * weight("stage_state_progress", 3.0),
		0.0,
		MAX_STAGE_STATE_SCORE,
	)


func candidate_score(
	_info: Dictionary,
	action_row: Dictionary,
	_semantic_catalog: Dictionary = {},
) -> float:
	var hints := search_hints(_info)
	var primary: Array = hints.get("primary_attackers", [])
	var engines: Array = hints.get("engine_cards", [])
	var top_k_scale := clampf(float(hints.get("top_k", 6)) / 6.0, 0.5, 1.5)
	var source_id := _action_card_id(action_row)
	var target_id := _action_target_card_id(action_row)
	var score := 0.0
	if source_id in primary or target_id in primary:
		score += weight("candidate_primary", 6.0) * top_k_scale
	if source_id in engines or target_id in engines:
		score += weight("candidate_engine", 4.0) * top_k_scale
	return clampf(score, -MAX_CANDIDATE_SCORE, MAX_CANDIDATE_SCORE)


func state_score_adjustment(
	info: Dictionary,
	_semantic_catalog: Dictionary = {},
) -> float:
	var score := 0.0
	score += float(_count_role_on_board(info, "primary_attacker")) * weight("board_primary")
	score += float(_count_role_on_board(info, "bench_engine")) * weight("board_engine")
	score += float(_own_hand(info).size()) * weight("hand_size")
	score -= float(_own_damage_total(info)) * weight("damage_pressure")
	if _own_prize_count(info) <= 2:
		score += weight("closeout")
	if _opponent_prize_count(info) <= 2:
		score -= weight("closeout")
	return score


func action_score_adjustment(
	_info: Dictionary,
	action_row: Dictionary,
	_semantic_catalog: Dictionary = {},
) -> float:
	var kind := _action_kind(action_row)
	var card_id := _action_card_id(action_row)
	var target_card_id := _action_target_card_id(action_row)
	var score := 0.0
	match kind:
		"PLAY_BASIC":
			if card_has_role(card_id, "setup_basic"):
				score += weight("play_setup")
			if card_has_role(card_id, "bench_engine"):
				score += weight("play_engine")
		"EVOLVE":
			if card_has_role(card_id, "evolution"):
				score += weight("evolve")
			if card_has_role(card_id, "primary_attacker"):
				score += weight("evolve_core")
		"ATTACH_ENERGY":
			if card_has_role(target_card_id, "primary_attacker"):
				score += weight("attach_primary")
			elif card_has_role(target_card_id, "secondary_attacker"):
				score += weight("attach_secondary")
		"PLAY_TRAINER", "USE_STADIUM":
			if card_has_role(card_id, "search"):
				score += weight("play_search")
			if card_has_role(card_id, "draw"):
				score += weight("play_draw")
			if card_has_role(card_id, "energy_acceleration"):
				score += weight("play_acceleration")
			if card_has_role(card_id, "recovery"):
				score += weight("play_recovery")
			if card_has_role(card_id, "switch"):
				score += weight("play_switch")
			if card_has_role(card_id, "disruption"):
				score += weight("play_disruption")
		"USE_ABILITY":
			if card_has_role(card_id, "bench_engine") or card_has_role(card_id, "energy_acceleration"):
				score += weight("use_engine_ability")
		"DECLARE_ATTACK":
			if card_has_role(card_id, "primary_attacker"):
				score += weight("attack_primary")
			elif card_has_role(card_id, "secondary_attacker"):
				score += weight("attack_secondary")
	return score


func choice_option_score(
	_info: Dictionary,
	_choice_view: Dictionary,
	option: Dictionary,
	_semantic_catalog: Dictionary = {},
) -> float:
	# Board-target choices are scored by the trusted rules layer using marginal
	# healing, Energy readiness, promotion, or prize value.  Search-card role
	# weights must not leak into those targets (for example, making an already
	# ready Stage 2 look like the best place for another Energy).
	if _choice_surface(_choice_view) != "card":
		return 0.0
	var card_id := _option_card_id(option)
	var score := 0.0
	if card_has_role(card_id, "primary_attacker"):
		score += weight("choice_primary")
	if card_has_role(card_id, "bench_engine") or card_has_role(card_id, "energy_acceleration"):
		score += weight("choice_engine")
	if card_has_role(card_id, "setup_basic"):
		score += weight("choice_setup")
	if card_has_role(card_id, "evolution"):
		score += weight("choice_evolution", 14.0)
	if card_has_role(card_id, "search") or card_has_role(card_id, "recovery"):
		score += weight("choice_resource", 4.0)
	if card_has_role(card_id, "energy"):
		score += weight("choice_energy")
	return score


func choice_mode(info: Dictionary, choice_view: Dictionary) -> String:
	var request_type := str(choice_view.get("request_type", "")).to_lower()
	var presentation: Dictionary = {}
	if choice_view.get("presentation") is Dictionary:
		presentation = choice_view["presentation"]
	elif choice_view.get("metadata") is Dictionary:
		presentation = choice_view["metadata"]
	var purpose := str(presentation.get("purpose", choice_view.get("purpose", ""))).to_lower()
	if request_type == "select_retreat_payment":
		return "payment"
	if request_type == "select_attachment":
		if purpose.begins_with("relocate_energy") or purpose == "trigger_move_basic_energy":
			return "source"
		if purpose == "discard_energy":
			var source_player := int(presentation.get("source_player", _perspective(info)))
			return "payment" if source_player == _perspective(info) else "benefit"
		return "payment"
	if request_type == "select_energy_source" or purpose == "energy_relocate_source":
		return "source"
	if purpose in ["discard_then_draw", "discard_cards", "houb", "zinnia"]:
		return "discard"
	if purpose in ["hand_bottom_draw", "bottom_deck"]:
		return "payment"
	if purpose in ["discard", "discard_cost"]:
		return "discard"
	return "benefit"


func _remaining_hand_count_for_choice(
	info: Dictionary,
	choice_view: Dictionary,
	option: Dictionary,
	card_id: String,
) -> int:
	var count := _count_card_in_hand(info, card_id)
	var ref: Variant = option.get("ref", {})
	var removes_hand_card := true
	if ref is Dictionary:
		if Dictionary(ref).has("zone"):
			removes_hand_card = str(Dictionary(ref).get("zone", "")) == "hand"
		elif str(Dictionary(ref).get("kind", "")) == "attachment":
			removes_hand_card = false
	if (
		removes_hand_card
		and choice_mode(info, choice_view) in ["discard", "payment", "source"]
	):
		count -= 1
	return maxi(0, count)


func discard_synergy_score(
	_info: Dictionary,
	_choice_view: Dictionary,
	option: Dictionary,
	_semantic_catalog: Dictionary = {},
) -> float:
	return (
		weight("discard_synergy", 16.0)
		if card_has_role(_option_card_id(option), "discard_synergy")
		else 0.0
	)


func matchup_adjustment(
	info: Dictionary,
	action_row: Dictionary,
	semantic_catalog: Dictionary = {},
) -> float:
	var opponent_key := _opponent_deck_key(info)
	var tags: Array = _deck_archetypes.get(opponent_key, []) if not opponent_key.is_empty() else []
	var matchup_weights: Dictionary = _profile.get("matchup_weights", {})
	var public_threat := 0.0
	for tag_value in tags:
		public_threat += float(matchup_weights.get(str(tag_value), 0.0))

	var kind := _action_kind(action_row)
	var card_id := _action_card_id(action_row)
	var score := 0.0
	if kind in ["PLAY_BASIC", "EVOLVE", "ATTACH_ENERGY"]:
		score += public_threat * 0.08
	elif kind == "DECLARE_ATTACK":
		score += public_threat * 0.25
		if _opponent_prize_count(info) < _own_prize_count(info):
			score += weight("closeout") * 0.2
	elif kind in ["PLAY_TRAINER", "USE_STADIUM"] and card_has_role(card_id, "disruption"):
		score += public_threat * 0.7
		score += float(_opponent_public_engine_count(info, semantic_catalog)) * 1.5
	elif kind == "RETREAT":
		score += float(_active_status_count(info)) * weight("play_switch")
	return score


func search_hints(_info: Dictionary) -> Dictionary:
	return {
		"top_k": maxi(1, int(round(weight("search_top_k", 6.0)))),
		"primary_attackers": role_cards("primary_attacker"),
		"engine_cards": role_cards("bench_engine"),
	}


func card_has_role(card_id: String, role: String) -> bool:
	if card_id.is_empty():
		return false
	return card_id in role_cards(role)


func role_cards(role: String) -> Array:
	var roles: Dictionary = _profile.get("card_roles", {})
	var values: Variant = roles.get(role, [])
	return Array(values) if values is Array else []


func weight(name: String, fallback: float = 0.0) -> float:
	var weights: Dictionary = _profile.get("weights", {})
	return float(weights.get(name, fallback))


func _role_progress(info: Dictionary, role: String) -> int:
	if role == "energy":
		var attached := 0
		for row_value in _own_board_rows(info):
			for energy_id_value in _row_energy_ids(row_value):
				if card_has_role(str(energy_id_value), role):
					attached += 1
		return attached
	var result := _count_role_on_board(info, role)
	if role in [
		"search", "draw", "recovery", "switch", "disruption", "tool",
		"healing", "energy_acceleration",
	]:
		result += _count_role_in_hand(info, role)
	return result


func _action_advances_role(action_row: Dictionary, role: String) -> bool:
	var kind := _action_kind(action_row)
	var source_id := _action_card_id(action_row)
	match kind:
		"PLAY_BASIC", "EVOLVE":
			return card_has_role(source_id, role)
		"ATTACH_ENERGY":
			return role == "energy" and card_has_role(source_id, "energy")
		"PLAY_TRAINER", "USE_STADIUM", "USE_ABILITY":
			return (
				role in [
					"search", "draw", "recovery", "switch", "disruption",
					"tool", "healing", "energy_acceleration",
				]
				and card_has_role(source_id, role)
			)
	return false


func _choice_surface(choice_view: Dictionary) -> String:
	var request_type := str(choice_view.get("request_type", "")).to_lower()
	var presentation: Dictionary = {}
	if choice_view.get("presentation") is Dictionary:
		presentation = choice_view["presentation"]
	elif choice_view.get("metadata") is Dictionary:
		presentation = choice_view["metadata"]
	var purpose := str(presentation.get(
		"purpose", choice_view.get("purpose", ""))).to_lower()
	if request_type in [
		"select_energy_target", "distribute_energy", "look_top_attach_energy",
	]:
		return "energy_target"
	if request_type == "select_heal_target" or purpose == "heal":
		return "heal_target"
	if request_type == "select_bench" and purpose == "switch":
		return "switch_target"
	if request_type in [
		"select_opponent_bench", "bench_damage_target", "damage_target",
		"place_counters_self_ko",
	]:
		return "opponent_target"
	return "card"


func _stage_goals() -> Array:
	var values: Variant = _profile.get("stage_goals", [])
	return Array(values) if values is Array else []


func _turn_number(info: Dictionary) -> int:
	return int(info.get("turn_number", info.get("turn", 0)))


func _perspective(info: Dictionary) -> int:
	var result := int(info.get("perspective", info.get("actor", -1)))
	if result in [0, 1]:
		return result
	return int(info.get("active_player_idx", info.get("active_player", 0)))


func _is_going_second(info: Dictionary) -> bool:
	# Production information sets always expose the public first-player index.
	# Older golden fixtures did not, so retain their historical neutral behavior
	# instead of silently treating the acting player as going first.
	var first_player := int(info.get("first_player_idx", -1))
	return first_player not in [0, 1] or first_player != _perspective(info)


func _player_view(info: Dictionary, player_idx: int) -> Dictionary:
	var players: Variant = info.get("players", [])
	if players is Array and player_idx >= 0 and player_idx < Array(players).size():
		var player_value: Variant = Array(players)[player_idx]
		if player_value is Dictionary:
			return player_value
	if player_idx == _perspective(info):
		var own_value: Variant = info.get("self", info.get("own", {}))
		if own_value is Dictionary:
			return own_value
	else:
		var opponent_value: Variant = info.get("opponent", {})
		if opponent_value is Dictionary:
			return opponent_value
	return {}


func _own_hand(info: Dictionary) -> Array:
	if info.get("own_hand") is Array:
		return Array(info["own_hand"])
	var own := _player_view(info, _perspective(info))
	for key in ["hand_card_ids", "hand"]:
		if own.get(key) is Array:
			return Array(own[key])
	return []


func _own_discard(info: Dictionary) -> Array:
	if info.get("own_discard") is Array:
		return Array(info["own_discard"])
	var own := _player_view(info, _perspective(info))
	var values: Variant = own.get("discard_card_ids", own.get("discard", []))
	return Array(values) if values is Array else []


func _own_board_rows(info: Dictionary) -> Array:
	return _board_rows_for_player(info, _perspective(info))


func _own_bench_count(info: Dictionary) -> int:
	var own := _player_view(info, _perspective(info))
	var result := 0
	if own.get("bench") is Array:
		for pokemon_value in own["bench"]:
			if pokemon_value is Dictionary and not _row_card_id(pokemon_value).is_empty():
				result += 1
		return result
	for row_value in _own_board_rows(info):
		if row_value is Array and Array(row_value).size() >= 2:
			if str(Array(row_value)[1]).begins_with("bench_"):
				result += 1
		elif row_value is Dictionary and str(Dictionary(row_value).get("slot", "")).begins_with("bench_"):
			result += 1
	return result


func _opponent_board_rows(info: Dictionary) -> Array:
	return _board_rows_for_player(info, 1 - _perspective(info))


func _board_rows_for_player(info: Dictionary, player_idx: int) -> Array:
	var result: Array = []
	var flat_board: Variant = info.get("board", [])
	if flat_board is Array and not Array(flat_board).is_empty():
		for row_value in flat_board:
			if row_value is Array and Array(row_value).size() >= 3 and int(Array(row_value)[0]) == player_idx:
				if not str(Array(row_value)[2]).is_empty():
					result.append(row_value)
			elif row_value is Dictionary and int(Dictionary(row_value).get("player", -1)) == player_idx:
				result.append(row_value)
		return result
	var player := _player_view(info, player_idx)
	if player.get("active") is Dictionary:
		result.append(player["active"])
	for pokemon_value in player.get("bench", []):
		if pokemon_value is Dictionary and not str(Dictionary(pokemon_value).get("card_id", "")).is_empty():
			result.append(pokemon_value)
	return result


func _active_row(info: Dictionary, player_idx: int) -> Variant:
	var player := _player_view(info, player_idx)
	if player.get("active") is Dictionary:
		return player["active"]
	for row_value in _board_rows_for_player(info, player_idx):
		if row_value is Array and Array(row_value).size() >= 2 and str(Array(row_value)[1]) == "active":
			return row_value
		if row_value is Dictionary and str(Dictionary(row_value).get("slot", "")) == "active":
			return row_value
	return null


func _own_row_for_slot(info: Dictionary, slot: String) -> Variant:
	if slot == "active":
		return _active_row(info, _perspective(info))
	var own := _player_view(info, _perspective(info))
	var normalized := slot.replace(":", "_")
	if normalized.begins_with("bench_"):
		var index_text := normalized.trim_prefix("bench_")
		var bench: Array = own.get("bench", [])
		if index_text.is_valid_int():
			var bench_index := int(index_text)
			if bench_index >= 0 and bench_index < bench.size():
				return bench[bench_index]
	for row_value in _own_board_rows(info):
		if row_value is Dictionary:
			var row_slot := str(Dictionary(row_value).get("slot", ""))
			if row_slot.replace(":", "_") == normalized:
				return row_value
		elif row_value is Array and Array(row_value).size() >= 2:
			if str(Array(row_value)[1]).replace(":", "_") == normalized:
				return row_value
	return null


func _action_target_slot(action_row: Dictionary) -> String:
	var target: Variant = action_row.get("target")
	if target is Dictionary and not str(Dictionary(target).get("slot", "")).is_empty():
		return str(Dictionary(target)["slot"])
	var payload := _action_payload(action_row)
	return str(payload.get("target_slot", payload.get("slot", "")))


func _option_slot(option: Dictionary) -> String:
	var ref: Variant = option.get("ref")
	if ref is Dictionary:
		return str(Dictionary(ref).get("slot", ""))
	return str(option.get("slot", ""))


func _choice_energy_card_id(choice_view: Dictionary) -> String:
	var presentation: Dictionary = {}
	if choice_view.get("presentation") is Dictionary:
		presentation = choice_view["presentation"]
	elif choice_view.get("metadata") is Dictionary:
		presentation = choice_view["metadata"]
	for card_id_value in presentation.get("card_ids", []):
		var card_id := str(card_id_value)
		if card_has_role(card_id, "energy"):
			return card_id
	var card_id := str(presentation.get("card_id", ""))
	return card_id if card_has_role(card_id, "energy") else ""


func _row_card_id(row_value: Variant) -> String:
	if row_value is Dictionary:
		return str(Dictionary(row_value).get("card_id", ""))
	if row_value is Array and Array(row_value).size() >= 3:
		return str(Array(row_value)[2])
	return ""


func _row_damage(row_value: Variant) -> int:
	if row_value is Dictionary:
		var row: Dictionary = row_value
		if row.has("damage_counters"):
			# GameState/Snapshot v3 stores ten-HP damage counters.  Strategy
			# thresholds and card HP are expressed in HP, so keep one unit at this
			# boundary instead of comparing counters directly with printed HP.
			return int(row.get("damage_counters", 0)) * 10
		return int(row.get("damage", 0))
	if row_value is Array and Array(row_value).size() >= 4:
		return int(Array(row_value)[3]) * 10
	return 0


func _row_energy_ids(row_value: Variant) -> Array:
	if row_value is Dictionary:
		var values: Variant = Dictionary(row_value).get("energy_card_ids", [])
		return Array(values) if values is Array else []
	if row_value is Array and Array(row_value).size() >= 5 and Array(row_value)[4] is Array:
		return Array(Array(row_value)[4])
	return []


func _row_statuses(row_value: Variant) -> Array:
	if row_value is Dictionary:
		var values: Variant = Dictionary(row_value).get("status_conditions", [])
		return Array(values) if values is Array else []
	if row_value is Array and Array(row_value).size() >= 6 and Array(row_value)[5] is Array:
		return Array(Array(row_value)[5])
	return []


func _row_healed_this_turn(row_value: Variant) -> bool:
	return (
		bool(Dictionary(row_value).get("healed_this_turn", false))
		if row_value is Dictionary
		else false
	)


func _count_role_on_board(info: Dictionary, role: String) -> int:
	var result := 0
	for row_value in _own_board_rows(info):
		if card_has_role(_row_card_id(row_value), role):
			result += 1
	return result


func _count_card_on_board(info: Dictionary, card_id: String) -> int:
	var result := 0
	for row_value in _own_board_rows(info):
		if _row_card_id(row_value) == card_id:
			result += 1
	return result


func _count_card_in_hand(info: Dictionary, card_id: String) -> int:
	return _own_hand(info).count(card_id)


func _count_role_in_hand(info: Dictionary, role: String) -> int:
	var result := 0
	for card_id_value in _own_hand(info):
		if card_has_role(str(card_id_value), role):
			result += 1
	return result


func _count_card_in_discard(info: Dictionary, card_id: String) -> int:
	return _own_discard(info).count(card_id)


func _count_role_in_discard(info: Dictionary, role: String) -> int:
	var result := 0
	for card_id_value in _own_discard(info):
		if card_has_role(str(card_id_value), role):
			result += 1
	return result


func _energy_count_for_card(info: Dictionary, card_id: String) -> int:
	var result := 0
	for row_value in _own_board_rows(info):
		if _row_card_id(row_value) == card_id:
			result = maxi(result, _row_energy_ids(row_value).size())
	return result


func _energy_id_count_for_card(info: Dictionary, card_id: String, energy_id: String) -> int:
	var result := 0
	for row_value in _own_board_rows(info):
		if _row_card_id(row_value) == card_id:
			result = maxi(result, _row_energy_ids(row_value).count(energy_id))
	return result


func _damage_on_card(info: Dictionary, card_id: String) -> int:
	var result := 0
	for row_value in _own_board_rows(info):
		if _row_card_id(row_value) == card_id:
			result = maxi(result, _row_damage(row_value))
	return result


func _card_healed_this_turn(info: Dictionary, card_id: String) -> bool:
	for row_value in _own_board_rows(info):
		if _row_card_id(row_value) == card_id and _row_healed_this_turn(row_value):
			return true
	return false


func _card_is_active(info: Dictionary, card_id: String) -> bool:
	return _row_card_id(_active_row(info, _perspective(info))) == card_id


func _own_bench_damaged(info: Dictionary) -> bool:
	var own := _player_view(info, _perspective(info))
	if own.get("bench") is Array:
		for pokemon_value in own["bench"]:
			if pokemon_value is Dictionary and _row_damage(pokemon_value) > 0:
				return true
		return false
	for row_value in _own_board_rows(info):
		if (
			row_value is Array
			and Array(row_value).size() >= 2
			and str(Array(row_value)[1]).begins_with("bench_")
			and _row_damage(row_value) > 0
		):
			return true
	return false


func _had_own_knockout_last_turn(info: Dictionary) -> bool:
	var fact_book: Variant = info.get("turn_fact_book", {})
	if not fact_book is Dictionary:
		return false
	var previous: Variant = Dictionary(fact_book).get("previous_turn", {})
	if not previous is Dictionary:
		return false
	for fact_value in Dictionary(previous).get("knockouts", []):
		if fact_value is Dictionary and int(Dictionary(fact_value).get(
			"defeated_player", -1)) == _perspective(info):
			return true
	return false


func _own_damage_total(info: Dictionary) -> int:
	var result := 0
	for row_value in _own_board_rows(info):
		result += _row_damage(row_value)
	return result


func _opponent_damage_total(info: Dictionary) -> int:
	var result := 0
	for row_value in _opponent_board_rows(info):
		result += _row_damage(row_value)
	return result


func _opponent_damaged_count(info: Dictionary) -> int:
	var result := 0
	for row_value in _opponent_board_rows(info):
		if _row_damage(row_value) > 0:
			result += 1
	return result


func _opponent_active_damage(info: Dictionary) -> int:
	return _row_damage(_active_row(info, 1 - _perspective(info)))


func _own_prize_count(info: Dictionary) -> int:
	if info.has("own_prize_count"):
		return int(info["own_prize_count"])
	var own := _player_view(info, _perspective(info))
	if own.get("prizes") is Array:
		return Array(own["prizes"]).size()
	return int(own.get("prizes_remaining", 6))


func _opponent_prize_count(info: Dictionary) -> int:
	if info.has("opponent_prize_count"):
		return int(info["opponent_prize_count"])
	var opponent := _player_view(info, 1 - _perspective(info))
	if opponent.get("prizes") is Array:
		return Array(opponent["prizes"]).size()
	return int(opponent.get("prizes_remaining", 6))


func _opponent_deck_key(info: Dictionary) -> String:
	if info.has("opponent_deck_key"):
		return str(info["opponent_deck_key"])
	var keys: Variant = info.get("public_deck_keys", [])
	var opponent_idx := 1 - _perspective(info)
	if keys is Array and opponent_idx >= 0 and opponent_idx < Array(keys).size():
		return str(Array(keys)[opponent_idx])
	return ""


func _active_status_count(info: Dictionary) -> int:
	return _row_statuses(_active_row(info, _perspective(info))).size()


func _opponent_public_engine_count(info: Dictionary, semantic_catalog: Dictionary) -> int:
	var result := 0
	for row_value in _opponent_board_rows(info):
		var card := _semantic_card(semantic_catalog, _row_card_id(row_value))
		if card.get("abilities") is Array and not Array(card["abilities"]).is_empty():
			result += 1
	return result


func _semantic_card(semantic_catalog: Dictionary, card_id: String) -> Dictionary:
	var cards: Variant = semantic_catalog.get("cards", semantic_catalog)
	if cards is Dictionary and Dictionary(cards).get(card_id) is Dictionary:
		return Dictionary(cards)[card_id]
	return {}


func _card_hp(semantic_catalog: Dictionary, card_id: String) -> int:
	return int(_semantic_card(semantic_catalog, card_id).get("hp", 0))


func _action_kind(action_row: Dictionary) -> String:
	return str(action_row.get("kind", action_row.get("action", "")))


func _action_payload(action_row: Dictionary) -> Dictionary:
	var payload: Variant = action_row.get("payload", action_row.get("params", {}))
	return payload if payload is Dictionary else {}


func _attack_index(action_row: Dictionary) -> int:
	var payload := _action_payload(action_row)
	return int(payload.get(
		"attack_index", payload.get("attack_idx", action_row.get("attack_index", -1))))


func _attack_params(
	action_row: Dictionary,
	semantic_catalog: Dictionary = {},
) -> Dictionary:
	var card := _semantic_card(semantic_catalog, _action_card_id(action_row))
	var attack_index := _attack_index(action_row)
	var attacks_value: Variant = card.get("attacks", [])
	var attacks: Array = (
		[attacks_value]
		if attacks_value is Dictionary
		else Array(attacks_value) if attacks_value is Array else []
	)
	for attack_value in attacks:
		if attack_value is Dictionary and int(Dictionary(attack_value).get(
			"index", -1)) == attack_index:
			return Dictionary(attack_value)
	return {}


func _attack_name(
	action_row: Dictionary,
	semantic_catalog: Dictionary = {},
) -> String:
	var payload := _action_payload(action_row)
	var explicit_name := str(payload.get("attack_name", action_row.get("attack_name", "")))
	return explicit_name if not explicit_name.is_empty() else str(
		_attack_params(action_row, semantic_catalog).get("name", ""))


func _action_card_id(action_row: Dictionary) -> String:
	for key in ["card_id", "source_card_id"]:
		if not str(action_row.get(key, "")).is_empty():
			return str(action_row[key])
	var source: Variant = action_row.get("source")
	if source is Dictionary and not str(Dictionary(source).get("card_id", "")).is_empty():
		return str(Dictionary(source)["card_id"])
	var payload: Variant = action_row.get("payload", action_row.get("params", {}))
	if payload is Dictionary:
		for key in ["card_id", "source_card_id", "hand_card_id"]:
			if not str(Dictionary(payload).get(key, "")).is_empty():
				return str(Dictionary(payload)[key])
	return ""


func _action_target_card_id(action_row: Dictionary) -> String:
	for key in ["target_card_id", "pokemon_card_id"]:
		if not str(action_row.get(key, "")).is_empty():
			return str(action_row[key])
	var target: Variant = action_row.get("target")
	if target is Dictionary:
		return str(Dictionary(target).get("card_id", ""))
	var payload: Variant = action_row.get("payload", action_row.get("params", {}))
	if payload is Dictionary:
		for key in ["target_card_id", "pokemon_card_id"]:
			if not str(Dictionary(payload).get(key, "")).is_empty():
				return str(Dictionary(payload)[key])
	return ""


func _option_card_id(option: Dictionary) -> String:
	for key in ["card_id", "source_card_id"]:
		if not str(option.get(key, "")).is_empty():
			return str(option[key])
	var ref: Variant = option.get("ref")
	if ref is Dictionary:
		return str(Dictionary(ref).get("card_id", ""))
	return ""


static func _deep_make_read_only(value: Variant) -> void:
	if value is Dictionary:
		var dictionary: Dictionary = value
		for nested_value in dictionary.values():
			_deep_make_read_only(nested_value)
		dictionary.make_read_only()
	elif value is Array:
		var array: Array = value
		for nested_value in array:
			_deep_make_read_only(nested_value)
		array.make_read_only()
