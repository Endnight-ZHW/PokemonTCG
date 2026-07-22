class_name GrassDeckStrategy
extends DeckStrategy


func _init(profile: Dictionary = {}, deck_archetypes: Dictionary = {}) -> void:
	super(profile, deck_archetypes)


func plan_stage(info: Dictionary) -> String:
	var evolved_count := _count_role_on_board(info, "evolution")
	if _own_prize_count(info) <= 2 or _opponent_prize_count(info) <= 2:
		return "evolution_pressure"
	if _own_board_rows(info).size() < 3:
		return "fill_evolution_board"
	if evolved_count < 3:
		return "evolve_swarm"
	return "evolution_pressure"


func state_score_adjustment(info: Dictionary, semantic_catalog: Dictionary = {}) -> float:
	var score := super.state_score_adjustment(info, semantic_catalog)
	score += float(_count_role_on_board(info, "evolution")) * weight("evolved_board")
	return score


func action_score_adjustment(
	info: Dictionary,
	action_row: Dictionary,
	semantic_catalog: Dictionary = {},
) -> float:
	var score := super.action_score_adjustment(info, action_row, semantic_catalog)
	var kind := _action_kind(action_row)
	var card_id := _action_card_id(action_row)
	if kind == "PLAY_BASIC" and card_id == "svg2-turt":
		score += weight("turtwig_setup")
	elif kind == "EVOLVE":
		# Evolution is already rewarded by the shared scorer.  A fixed marginal
		# board gain preserves context instead of saturating the strategy clamp.
		score += weight("evolved_board") * 0.65
	elif kind == "ATTACH_ENERGY" and _action_target_card_id(action_row) == "svg2-tort":
		var target_row: Variant = _own_row_for_slot(
			info, _action_target_slot(action_row))
		if (
			target_row != null
			and _row_energy_ids(target_row).size() >= 2
			and _count_role_on_board(info, "evolution") >= 3
		):
			# Evolution Pressure is already live; do not chase the printed
			# four-Energy Headbutt unless the trusted KO tactic overrides this.
			score -= 150.0
	elif kind == "PLAY_TRAINER" and card_id == "sv1-152":
		score += weight("rare_candy")
	elif kind == "PLAY_TRAINER" and card_id == "svg2-gard":
		score += weight("gardenia")
	elif (
		kind == "USE_ABILITY"
		and card_id == "svg2-grot"
		and _hand_contains_any(info, ["sv2-young", "sv1-176", "sv1-180", "sv1-189"])
	):
		# Do not search a card immediately before a known public hand reset.
		score -= 30.0
	elif kind == "DECLARE_ATTACK" and card_id == "svg2-tort":
		if _attack_index(action_row) == 0:
			score += weight("torterra_evolution_pressure")
			score += weight("evolved_board") * float(_count_role_on_board(info, "evolution"))
		elif _attack_index(action_row) == 1:
			score += weight("torterra_headbutt")
	elif (
		kind == "USE_ABILITY"
		and card_id == "svg2-empo"
		and _own_hand(info).is_empty()
		and _count_card_in_discard(info, card_id) > 0
	):
		score += weight("empoleon_revival")
	elif (
		kind == "DECLARE_ATTACK"
		and card_id == "svg2-zaru"
		and _attack_index(action_row) == 0
		and _turn_number(info) <= 2
	):
		score += weight("zarude_opening_search")
	return score


func _hand_contains_any(info: Dictionary, card_ids: Array) -> bool:
	for card_id_value in card_ids:
		if _count_card_in_hand(info, str(card_id_value)) > 0:
			return true
	return false


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
	var has_turtwig := _count_card_on_board(info, "svg2-turt") > 0
	var has_grotle := _count_card_on_board(info, "svg2-grot") > 0
	var has_torterra := _count_card_on_board(info, "svg2-tort") > 0
	var has_rare_candy := _count_card_in_hand(info, "sv1-152") > 0
	if card_id == "svg2-turt":
		score += (
			weight("evolved_board") + (24.0 if _own_bench_count(info) <= 0 else 0.0)
			if not (has_turtwig or has_grotle or has_torterra)
			else -8.0
		)
	elif card_id == "svg2-grot":
		var middle_receivers := _count_card_on_board(info, "svg2-turt")
		var middle_supply := _remaining_hand_count_for_choice(
			info, choice_view, option, "svg2-grot")
		score += (
			weight("evolved_board") * 1.25
			if middle_receivers > middle_supply
			else -weight("evolve_core")
		)
	elif card_id == "svg2-tort":
		var final_receivers := _count_card_on_board(info, "svg2-grot")
		if has_rare_candy:
			final_receivers += _count_card_on_board(info, "svg2-turt")
		var final_supply := _remaining_hand_count_for_choice(
			info, choice_view, option, "svg2-tort")
		if final_supply >= final_receivers:
			score -= weight("evolve_core") * 1.25
		elif has_grotle:
			score += weight("evolve_core") * 0.75
		elif has_turtwig and has_rare_candy:
			score += weight("evolve_core") * 0.55
		else:
			score -= weight("evolve_core")
	elif card_id == "svg2-gard":
		score += weight("gardenia")
	if card_id in ["svg2-turt", "svg2-grot", "svg2-tort"]:
		score -= float(_remaining_hand_count_for_choice(
			info, choice_view, option, card_id)) * 35.0
	return score
