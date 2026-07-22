class_name DragonDeckStrategy
extends DeckStrategy


func _init(profile: Dictionary = {}, deck_archetypes: Dictionary = {}) -> void:
	super(profile, deck_archetypes)


func plan_stage(info: Dictionary) -> String:
	if _count_card_on_board(info, "svg-alt") <= 0:
		return "build_healing_core"
	if not _has_balanced_altaria(info):
		return "balance_energy"
	return "healing_lock"


func state_score_adjustment(info: Dictionary, semantic_catalog: Dictionary = {}) -> float:
	var score := super.state_score_adjustment(info, semantic_catalog)
	score += float(_count_card_on_board(info, "svg-alt")) * weight("altaria_lock")
	for row_value in _own_board_rows(info):
		if _row_card_id(row_value) != "svg-alt":
			continue
		var energy_ids := _row_energy_ids(row_value)
		if "sv1-ener-3" in energy_ids and "sv1-ener-8" in energy_ids:
			score += weight("dual_energy_balance") * 1.5
	return score


func action_score_adjustment(
	info: Dictionary,
	action_row: Dictionary,
	semantic_catalog: Dictionary = {},
) -> float:
	var score := super.action_score_adjustment(info, action_row, semantic_catalog)
	var kind := _action_kind(action_row)
	var card_id := _action_card_id(action_row)
	var target_card_id := _action_target_card_id(action_row)
	if kind == "EVOLVE" and card_id == "svg-alt":
		score += weight("altaria_lock")
	elif kind == "USE_ABILITY" and card_id == "svg-alt":
		score += float(_own_damage_total(info)) * weight("healing")
	elif kind == "PLAY_TRAINER" and card_id in ["svf-potion", "svg-chef"]:
		score += float(_own_damage_total(info)) * weight("healing")
	elif kind == "ATTACH_ENERGY" and target_card_id == "svg-alt":
		var target_energy_ids := _target_altaria_energy_ids(info, action_row)
		if card_id == "sv1-ener-3" and card_id not in target_energy_ids:
			score += weight("dual_energy_balance")
		elif card_id == "sv1-ener-8" and card_id not in target_energy_ids:
			score += weight("dual_energy_balance")
	elif kind == "DECLARE_ATTACK" and card_id == "svg-ceti":
		if _attack_index(action_row) == 0:
			score += weight("cetitan_headbutt")
		elif _attack_index(action_row) == 1:
			score += weight("cetitan_sweeping")
			score -= float(_damage_on_card(info, card_id)) * weight("cetitan_damage_penalty")
	elif (
		kind == "DECLARE_ATTACK"
		and card_id == "svg-milt"
		and _attack_index(action_row) == 0
		and _card_healed_this_turn(info, card_id)
	):
		score += weight("miltank_healed_attack")
	return score


func choice_option_score(
	info: Dictionary,
	choice_view: Dictionary,
	option: Dictionary,
	semantic_catalog: Dictionary = {},
) -> float:
	var score := super.choice_option_score(info, choice_view, option, semantic_catalog)
	if _choice_surface(choice_view) != "card":
		return score
	var card_id := _option_card_id(option)
	if card_id == "svg-swa":
		score += (
			weight("altaria_lock") * 0.45
			if _count_card_on_board(info, "svg-swa") <= 0
			else -weight("altaria_lock") * 0.25
		)
	elif card_id == "svg-alt":
		score += (
			weight("altaria_lock") * 0.65
			if _count_card_on_board(info, "svg-swa") > 0
			else -weight("altaria_lock") * 0.5
		)
	elif card_id in ["svf-potion", "svg-chef"] and _own_damage_total(info) > 0:
		score += float(_own_damage_total(info)) * weight("healing")
	if card_id in ["svg-swa", "svg-alt"]:
		score -= float(_remaining_hand_count_for_choice(
			info, choice_view, option, card_id)) * 35.0
	elif (
		card_id in ["sv1-ener-3", "sv1-ener-8"]
		and plan_stage(info) == "balance_energy"
		and _count_card_in_hand(info, card_id) <= 1
	):
		# Keep the last public copy of either required colour while the
		# same-row Water/Metal pair is incomplete.
		score += weight("dual_energy_balance") * 2.0
	return score


func _has_balanced_altaria(info: Dictionary) -> bool:
	for row_value in _own_board_rows(info):
		if _row_card_id(row_value) != "svg-alt":
			continue
		var energy_ids := _row_energy_ids(row_value)
		if "sv1-ener-3" in energy_ids and "sv1-ener-8" in energy_ids:
			return true
	return false


func _target_altaria_energy_ids(
	info: Dictionary,
	action_row: Dictionary,
) -> Array:
	var target_value: Variant = action_row.get("target")
	if target_value is Dictionary:
		var target: Dictionary = target_value
		var target_player := int(target.get("player", _perspective(info)))
		if target_player != _perspective(info):
			return []
		var own := _player_view(info, target_player)
		var target_slot := str(target.get("slot", ""))
		if target_slot == "active" and own.get("active") is Dictionary:
			var active: Dictionary = own["active"]
			if _row_card_id(active) == "svg-alt":
				return _row_energy_ids(active)
		elif target_slot.begins_with("bench_"):
			var index_text := target_slot.trim_prefix("bench_")
			var bench: Array = own.get("bench", [])
			if index_text.is_valid_int():
				var bench_index := int(index_text)
				if bench_index >= 0 and bench_index < bench.size():
					var pokemon_value: Variant = bench[bench_index]
					if (
						pokemon_value is Dictionary
						and _row_card_id(pokemon_value) == "svg-alt"
					):
						return _row_energy_ids(pokemon_value)

	# Static tactical fixtures may omit the target slot. Falling back is safe
	# only when the public board identifies exactly one possible Altaria.
	var matching_rows: Array = []
	for row_value in _own_board_rows(info):
		if _row_card_id(row_value) == "svg-alt":
			matching_rows.append(row_value)
	return _row_energy_ids(matching_rows[0]) if matching_rows.size() == 1 else []
