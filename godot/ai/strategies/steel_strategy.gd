class_name SteelDeckStrategy
extends DeckStrategy


func _init(profile: Dictionary = {}, deck_archetypes: Dictionary = {}) -> void:
	super(profile, deck_archetypes)


func plan_stage(info: Dictionary) -> String:
	if _count_card_on_board(info, "svm-bronzor") <= 0 and _count_card_on_board(info, "svm-bronzong") <= 0:
		return "build_metal_board"
	if _count_card_on_board(info, "svm-bronzong") <= 0:
		return "enable_transfer"
	return "fortress_pressure"


func state_score_adjustment(info: Dictionary, semantic_catalog: Dictionary = {}) -> float:
	var score := super.state_score_adjustment(info, semantic_catalog)
	score += float(_count_card_on_board(info, "svm-bronzong")) * weight("metal_transfer")
	score += float(_own_board_rows(info).size()) * weight("metal_board")
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
	if kind == "EVOLVE" and card_id == "svm-bronzong":
		score += weight("metal_transfer")
	elif kind == "USE_ABILITY" and card_id == "svm-bronzong":
		score += weight("metal_transfer")
	elif kind == "DECLARE_ATTACK" and card_id == "svm-zamazenta":
		if _had_own_knockout_last_turn(info):
			score += weight("revenge")
	elif kind == "DECLARE_ATTACK" and card_id == "svm-zacian":
		if _attack_index(action_row) == 0:
			score += float(_own_bench_count(info)) * weight("zacian_battle_legion")
		elif _attack_index(action_row) == 1:
			score += weight("zacian_blade")
	elif (
		kind == "ATTACH_ENERGY"
		and target_card_id == "svm-orthworm"
		and card_id == "sv1-ener-8"
		and _energy_id_count_for_card(info, target_card_id, card_id) == 2
	):
		score += weight("orthworm_threshold")
	elif kind == "PLAY_BASIC" and card_has_role(card_id, "primary_attacker"):
		score += weight("metal_board") * float(_own_board_rows(info).size() + 1)
	return score


func choice_option_score(
	info: Dictionary,
	choice_view: Dictionary,
	option: Dictionary,
	semantic_catalog: Dictionary = {},
) -> float:
	var score := super.choice_option_score(info, choice_view, option, semantic_catalog)
	var card_id := _option_card_id(option)
	if card_id in ["svm-bronzor", "svm-bronzong"]:
		score += weight("metal_transfer")
	elif card_id in ["svm-zacian", "svm-zamazenta", "svm-orthworm"]:
		score += weight("metal_board")
	return score
