class_name FightingDeckStrategy
extends DeckStrategy


func _init(profile: Dictionary = {}, deck_archetypes: Dictionary = {}) -> void:
	super(profile, deck_archetypes)


func plan_stage(info: Dictionary) -> String:
	if _count_card_on_board(info, "svf-luca") <= 0:
		return "build_lucario"
	if _energy_count_for_card(info, "svf-luca") < 2:
		return "stack_fighting_energy"
	return "aura_burst"


func state_score_adjustment(info: Dictionary, semantic_catalog: Dictionary = {}) -> float:
	var score := super.state_score_adjustment(info, semantic_catalog)
	score += float(_count_card_on_board(info, "svf-luca")) * weight("lucario_engine")
	score += float(_energy_count_for_card(info, "svf-luca")) * weight("fighting_stack")
	return score


func action_score_adjustment(
	info: Dictionary,
	action_row: Dictionary,
	semantic_catalog: Dictionary = {},
) -> float:
	var score := super.action_score_adjustment(info, action_row, semantic_catalog)
	var kind := _action_kind(action_row)
	var card_id := _action_card_id(action_row)
	if kind == "EVOLVE" and card_id == "svf-luca":
		score += weight("lucario_engine")
	elif kind == "USE_ABILITY" and card_id == "svf-luca":
		var source_row: Variant = _own_row_for_slot(
			info, _action_source_slot(action_row))
		var hp := _card_hp(semantic_catalog, card_id)
		var damage_after := _row_damage(source_row) + 20
		if hp > 0 and damage_after >= hp:
			score -= weight("lucario_self_ko_penalty")
		elif hp > 0 and hp - damage_after <= 40:
			score -= weight("lucario_low_hp_penalty")
		else:
			score += weight("lucario_engine")
	elif kind == "DECLARE_ATTACK" and card_id == "svf-luca":
		var active_row: Variant = _active_row(info, _perspective(info))
		score += float(_row_energy_ids(active_row).size()) * weight("fighting_stack")
	elif kind == "DECLARE_ATTACK" and card_id == "svf-klea":
		score += weight("kleavor")
		if _attack_index(action_row) == 0:
			score += weight("kleavor_guillotine")
		elif _attack_index(action_row) == 1:
			score += weight("kleavor_rampage")
	return score


func _action_source_slot(action_row: Dictionary) -> String:
	var source: Variant = action_row.get("source")
	if source is Dictionary:
		var source_slot := str(Dictionary(source).get("slot", ""))
		if not source_slot.is_empty():
			return source_slot
	var payload := _action_payload(action_row)
	var payload_slot := str(payload.get("source_slot", payload.get("slot", "")))
	return payload_slot if not payload_slot.is_empty() else _action_target_slot(action_row)


func choice_option_score(
	info: Dictionary,
	choice_view: Dictionary,
	option: Dictionary,
	semantic_catalog: Dictionary = {},
) -> float:
	var score := super.choice_option_score(info, choice_view, option, semantic_catalog)
	var card_id := _option_card_id(option)
	if card_id in ["svf-rio", "svf-luca"]:
		score += weight("lucario_engine")
	elif card_id in ["svf-scyt", "svf-klea"]:
		score += weight("kleavor")
	return score
