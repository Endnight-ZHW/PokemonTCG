class_name LightningDeckStrategy
extends DeckStrategy

const FRONTLINE_OPENERS := ["svl-thun", "svl-emol", "svl-chat", "svl-zera"]
const BENCH_ENGINE_BASICS := ["svl-mare2", "svl-chin"]


func _init(profile: Dictionary = {}, deck_archetypes: Dictionary = {}) -> void:
	super(profile, deck_archetypes)


func plan_stage(info: Dictionary) -> String:
	if _own_prize_count(info) <= 2:
		return "burst_finish"
	if _count_card_on_board(info, "svl-flaa2") <= 0:
		return "charge_bench"
	return "prepare_pikachu"


func state_score_adjustment(info: Dictionary, semantic_catalog: Dictionary = {}) -> float:
	var score := super.state_score_adjustment(info, semantic_catalog)
	score += float(_count_card_on_board(info, "svl-flaa2")) * weight("flaaffy_engine")
	if _energy_count_for_card(info, "svl-pikaex") >= 3:
		score += weight("pikachu_burst")
	return score


func action_score_adjustment(
	info: Dictionary,
	action_row: Dictionary,
	semantic_catalog: Dictionary = {},
) -> float:
	var score := super.action_score_adjustment(info, action_row, semantic_catalog)
	var kind := _action_kind(action_row)
	var card_id := _action_card_id(action_row)
	var target_slot := _action_target_slot(action_row)
	if (
		kind == "PLAY_BASIC"
		and target_slot == "active"
		and _turn_number(info) <= 1
	):
		if card_id in FRONTLINE_OPENERS:
			# Thundurus accelerates, Emolga/Chatot pivot for free, and Zeraora
			# supplies 120 HP plus a real two-Energy attack. Mareep and Chinchou
			# are the two evolution engines and should remain on the Bench whenever
			# one of those public opening pivots is also legal.
			score += weight("frontline_opening")
		elif card_id in BENCH_ENGINE_BASICS and _has_frontline_opener_in_hand(info):
			score -= weight("bench_engine_active_penalty")
	elif kind == "PLAY_TRAINER" and card_id == "sv1-170":
		score += weight("generator")
	elif kind == "EVOLVE" and card_id == "svl-flaa2":
		score += weight("flaaffy_engine")
	elif kind == "USE_ABILITY" and card_id == "svl-flaa2":
		score += weight("flaaffy_engine")
	elif kind == "DECLARE_ATTACK" and card_id == "svl-pikaex":
		if _attack_index(action_row) == 0:
			score += weight("pikachu_jab")
		elif _attack_index(action_row) == 1:
			score += weight("pikachu_strong_volt")
			var recovery_scale := 0.35 if _count_card_on_board(info, "svl-flaa2") > 0 else 1.0
			score -= float(_energy_count_for_card(info, card_id)) * weight("strong_volt_energy_risk") * recovery_scale
	return score


func _has_frontline_opener_in_hand(info: Dictionary) -> bool:
	for card_id_value in _own_hand(info):
		if str(card_id_value) in FRONTLINE_OPENERS:
			return true
	return false


func choice_option_score(
	info: Dictionary,
	choice_view: Dictionary,
	option: Dictionary,
	semantic_catalog: Dictionary = {},
) -> float:
	var score := super.choice_option_score(info, choice_view, option, semantic_catalog)
	var card_id := _option_card_id(option)
	if card_id in ["svl-mare2", "svl-flaa2"]:
		score += weight("flaaffy_engine")
	elif card_id == "svl-pikaex":
		score += weight("pikachu_burst")
	return score
