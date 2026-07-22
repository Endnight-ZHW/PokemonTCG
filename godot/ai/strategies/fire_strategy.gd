class_name FireDeckStrategy
extends DeckStrategy


func _init(profile: Dictionary = {}, deck_archetypes: Dictionary = {}) -> void:
	super(profile, deck_archetypes)


func plan_stage(info: Dictionary) -> String:
	if _opponent_prize_count(info) <= 2 or _own_prize_count(info) <= 2:
		return "closeout"
	if _count_card_on_board(info, "svi-infr") <= 0:
		return "establish_chain"
	return "ignite_engine"


func state_score_adjustment(info: Dictionary, semantic_catalog: Dictionary = {}) -> float:
	var score := super.state_score_adjustment(info, semantic_catalog)
	score += float(_count_card_on_board(info, "svi-infr")) * weight("fire_chain")
	score += float(_count_card_in_discard(info, "sv1-ener-2")) * weight("recycle_energy") * 0.15
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
		and _count_card_in_hand(info, "svi-chiy") > 0
		and _count_card_in_hand(info, "svi-ente") > 0
	):
		if card_id == "svi-chiy":
			score += weight("chiyu_opening")
		elif card_id == "svi-ente":
			score -= weight("chiyu_opening")
	elif kind == "PLAY_BASIC" and card_id == "svi-chim" and target_slot.begins_with("bench_"):
		score += weight("chimchar_bench")
	elif kind == "EVOLVE" and card_id == "svi-infr":
		score += weight("fire_chain")
	elif kind == "PLAY_TRAINER" and card_id == "sv1-152":
		score += weight("rare_candy")
	elif kind == "PLAY_TRAINER" and card_id in ["svi-erec", "svi-mela", "sv3-134"]:
		score += float(mini(_count_card_in_discard(info, "sv1-ener-2"), 3)) * weight("recycle_energy") * 0.25
	elif kind == "DECLARE_ATTACK" and card_id == "svi-infr":
		score += weight("infernape_attack")
		if _attack_index(action_row) == 0:
			score += weight("infernape_spiral")
		elif _attack_index(action_row) == 1:
			score += weight("infernape_burning_kick")
			score -= float(_energy_count_for_card(info, card_id)) * weight("burning_kick_energy_cost")
	elif kind == "DECLARE_ATTACK" and card_id == "svi-sqwk" and _attack_index(action_row) == 0:
		score += weight("squawk_call_family")
		if _turn_number(info) <= 2:
			score += weight("squawk_opening")
	elif kind == "DECLARE_ATTACK" and card_id == "svi-chiy" and _attack_index(action_row) == 0:
		score += float(mini(
			_count_card_in_discard(info, "sv1-ener-2"), 2
		)) * weight("chiyu_acceleration")
	elif (
		kind == "DECLARE_ATTACK"
		and card_id == "svi-chiy"
		and _attack_index(action_row) == 1
		and _had_own_knockout_last_turn(info)
	):
		score += weight("chiyu_revenge")
	return score


func choice_option_score(
	info: Dictionary,
	choice_view: Dictionary,
	option: Dictionary,
	semantic_catalog: Dictionary = {},
) -> float:
	var score := super.choice_option_score(info, choice_view, option, semantic_catalog)
	var card_id := _option_card_id(option)
	var chain_weight := weight("fire_chain")
	# With only an Active Pokemon, an Ultra Ball/other search must establish a
	# legal Basic backup before collecting a stranded evolution piece.  Clamp at
	# the strategy boundary gives this public survival rule precedence over the
	# generic Stage-1 keep value without exposing any hidden zone.
	if (
		_own_bench_count(info) == 0
		and _row_card_id(_active_row(info, _perspective(info))) == "svi-chim"
		and choice_mode(info, choice_view) == "benefit"
		and _choice_surface(choice_view) == "card"
	):
		if card_has_role(card_id, "setup_basic"):
			score += 240.0
		elif card_has_role(card_id, "evolution"):
			score -= 240.0
	var has_chimchar := _count_card_on_board(info, "svi-chim") > 0
	var has_monferno := (
		_count_card_on_board(info, "svi-monf") > 0
		or _count_card_in_hand(info, "svi-monf") > 0
	)
	var has_rare_candy := _count_card_in_hand(info, "sv1-152") > 0
	if card_id == "svi-chim":
		score += chain_weight
	elif card_id == "svi-monf":
		if has_chimchar and not has_monferno:
			score += chain_weight
	elif card_id == "svi-infr":
		if has_monferno or (has_chimchar and has_rare_candy):
			score += chain_weight
		else:
			# Keep the no-chain golden useful, but below an executable
			# Chimchar -> Monferno search route.
			score -= chain_weight
	if (
		card_id in ["svi-monf", "svi-infr"]
		and _remaining_hand_count_for_choice(
			info, choice_view, option, card_id) > 0
	):
		score -= chain_weight
	elif card_id in ["svi-erec", "svi-mela"] and _count_card_in_discard(info, "sv1-ener-2") > 0:
		score += weight("recycle_energy")
	return score
