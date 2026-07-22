class_name ColorlessDeckStrategy
extends DeckStrategy


func _init(profile: Dictionary = {}, deck_archetypes: Dictionary = {}) -> void:
	super(profile, deck_archetypes)


func plan_stage(info: Dictionary) -> String:
	if _count_card_on_board(info, "svi-maus") <= 0:
		return "fill_bench"
	if _own_hand(info).size() < 6:
		return "grow_hand"
	return "family_pressure"


func state_score_adjustment(info: Dictionary, semantic_catalog: Dictionary = {}) -> float:
	var score := super.state_score_adjustment(info, semantic_catalog)
	score += float(_count_role_on_board(info, "family")) * weight("family_board")
	if _own_hand(info).size() >= 6:
		score += weight("hand_preservation")
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
	if kind == "EVOLVE" and card_id == "svi-maus":
		score += weight("family_board") * float(_count_role_on_board(info, "family") + 1)
	elif kind == "ATTACH_ENERGY" and card_has_role(card_id, "energy") and target_card_id == "svi-maus":
		score += weight("special_energy")
	elif kind == "PLAY_TRAINER" and card_id == "sv1-189" and _own_hand(info).size() >= 6:
		score -= weight("hand_preservation")
	elif kind == "DECLARE_ATTACK" and card_id == "svi-maus":
		score += weight("family_board") * float(_count_role_on_board(info, "family"))
	elif kind == "DECLARE_ATTACK" and card_id == "svi-ambi":
		if _attack_index(action_row) == 0:
			score += weight("ambipom_call")
		elif _attack_index(action_row) == 1:
			score += float(mini(_own_hand(info).size(), 8)) * weight("ambipom_hand_attack")
	elif kind == "DECLARE_ATTACK" and card_id == "svi-gree":
		if _attack_index(action_row) == 0:
			score += weight("greedent_call")
		elif _attack_index(action_row) == 1:
			score += weight("greedent_dump") if _own_hand(info).size() >= 5 else -weight("greedent_dump")
	return score


func choice_option_score(
	info: Dictionary,
	choice_view: Dictionary,
	option: Dictionary,
	semantic_catalog: Dictionary = {},
) -> float:
	var score := super.choice_option_score(info, choice_view, option, semantic_catalog)
	var card_id := _option_card_id(option)
	if card_id in ["svi-tand", "svi-maus"]:
		score += weight("family_board") * 2.0
	elif card_has_role(card_id, "energy"):
		score += weight("special_energy")
	return score
