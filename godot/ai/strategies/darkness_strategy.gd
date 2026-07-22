class_name DarknessDeckStrategy
extends DeckStrategy


func _init(profile: Dictionary = {}, deck_archetypes: Dictionary = {}) -> void:
	super(profile, deck_archetypes)


func plan_stage(info: Dictionary) -> String:
	if _count_card_on_board(info, "svd-mabosstiff-ex") <= 0 or _count_card_on_board(info, "svd-dodrio") <= 0:
		return "build_dual_lines"
	if _damage_on_card(info, "svd-dodrio") < 20:
		return "prime_damage_engine"
	return "pride_finish"


func state_score_adjustment(info: Dictionary, semantic_catalog: Dictionary = {}) -> float:
	var score := super.state_score_adjustment(info, semantic_catalog)
	score += float(_damage_on_card(info, "svd-dodrio")) * weight("damage_engine")
	if _count_card_in_discard(info, "sv1-ener-7") > 0:
		score += weight("dark_patch")
	return score


func action_score_adjustment(
	info: Dictionary,
	action_row: Dictionary,
	semantic_catalog: Dictionary = {},
) -> float:
	var score := super.action_score_adjustment(info, action_row, semantic_catalog)
	var kind := _action_kind(action_row)
	var card_id := _action_card_id(action_row)
	if kind == "PLAY_TRAINER" and card_id == "svd-dark-patch":
		var discard_energy := _count_card_in_discard(info, "sv1-ener-7")
		if discard_energy <= 0:
			score -= weight("dark_patch") * 2.0
		else:
			score += float(mini(discard_energy, 2)) * weight("dark_patch") * 0.5
	elif kind == "USE_ABILITY" and card_id == "svd-dodrio":
		var hp := _card_hp(semantic_catalog, card_id)
		var damage_after := _damage_on_card(info, card_id) + 10
		if hp > 0 and damage_after >= hp:
			score -= weight("dodrio_safety_penalty") * 2.0
		elif hp > 0 and hp - damage_after <= 20:
			score -= weight("dodrio_safety_penalty")
		else:
			score += weight("damaged_dodrio")
	elif kind == "EVOLVE" and card_id == "svd-dodrio":
		score += weight("damaged_dodrio")
	elif kind == "EVOLVE" and card_id == "svd-mabosstiff-ex":
		score += weight("mabosstiff_evolution")
	elif kind == "DECLARE_ATTACK" and card_id == "svd-mabosstiff-ex":
		if _attack_index(action_row) == 0:
			score += weight("mabosstiff_intimidate")
		elif _attack_index(action_row) == 1:
			score += weight("mabosstiff_pride") if _own_bench_damaged(info) else 0.0
	return score


func choice_option_score(
	info: Dictionary,
	choice_view: Dictionary,
	option: Dictionary,
	semantic_catalog: Dictionary = {},
) -> float:
	var score := super.choice_option_score(info, choice_view, option, semantic_catalog)
	var card_id := _option_card_id(option)
	if card_id in ["svd-doduo", "svd-dodrio"]:
		score += weight("damaged_dodrio")
	elif card_id in ["svd-maschiff", "svd-mabosstiff-ex"]:
		score += weight("choice_primary")
	elif card_id == "svd-dark-patch" and _count_card_in_discard(info, "sv1-ener-7") > 0:
		score += weight("dark_patch")
	return score
