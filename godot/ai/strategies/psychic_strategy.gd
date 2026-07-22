class_name PsychicDeckStrategy
extends DeckStrategy


func _init(profile: Dictionary = {}, deck_archetypes: Dictionary = {}) -> void:
	super(profile, deck_archetypes)


func plan_stage(info: Dictionary) -> String:
	# The deck has two Xatu and needs both acceleration activations to keep pace
	# with the release decks' high-damage attackers.
	var xatu_count := _count_card_on_board(info, "sv1-108")
	# A Xatu in hand is not an executable second line by itself.  Treating it as
	# one made the planner leave the only Natu out of play and then search an
	# attacker it could not power up.
	var natu_line_available := (
		_count_card_on_board(info, "sv1-107") > 0
		or _count_card_in_hand(info, "sv1-107") > 0
	)
	if xatu_count <= 0 or (xatu_count < 2 and natu_line_available):
		return "build_xatu_engine"
	if _count_card_in_hand(info, "sv1-ener-5") >= 2:
		return "accelerate_energy"
	return "scale_attackers"


func state_score_adjustment(info: Dictionary, semantic_catalog: Dictionary = {}) -> float:
	var score := super.state_score_adjustment(info, semantic_catalog)
	var xatu_count := _count_card_on_board(info, "sv1-108")
	score += float(xatu_count) * weight("xatu_engine")
	# Energy in hand is valuable only to the extent that the public Xatu engine
	# can turn it into tempo; otherwise unconditional hoarding suppresses attacks.
	score += float(mini(
		_count_card_in_hand(info, "sv1-ener-5"), xatu_count
	)) * weight("psychic_energy_hand")
	if _houndstone_line_publicly_available(info):
		score += float(mini(
			_count_role_in_discard(info, "psychic_pokemon"), 6
		)) * weight("graveyard_scaling")
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
	var exact_opening := _is_exact_cresselia_opening_turn(info)
	var cresselia_benched := _card_is_benched(info, "sv1-113")
	var cresselia_ready := _energy_count_for_card(info, "sv1-113") >= 1
	if exact_opening and cresselia_benched:
		if (
			kind == "ATTACH_ENERGY"
			and _action_target_card_id(action_row) == "sv1-113"
			and target_slot.begins_with("bench_")
		):
			score += weight("cresselia_opening_route")
		elif (
			kind == "PLAY_TRAINER"
			and card_id == "sv1-150"
			and cresselia_ready
		):
			score += weight("cresselia_opening_route")
		elif (
			kind == "PLAY_TRAINER"
			and card_id == "sv1-204"
			and _cresselia_opening_energy_available(info)
			and _count_card_in_hand(info, "sv1-150") <= 0
			and not _has_legal_cresselia_retreat(info)
		):
			# Arven's category resolver has the matching strict Switch override.
			# This score only makes the public route enter the six-action beam.
			score += weight("cresselia_opening_route")
		elif (
			kind == "RETREAT"
			and _action_target_card_id(action_row) == "sv1-113"
			and cresselia_ready
		):
			score += weight("cresselia_opening_route")
	if (
		kind == "PLAY_BASIC"
		and card_id == "sv1-113"
		and target_slot == "active"
		and _is_going_second(info)
	):
		# Cresselia's opening attack is the only route to three accelerated Energy
		# on the first going-second turn.  Natu should develop on the Bench instead.
		score += weight("cresselia_active_opening")
	elif kind == "PLAY_BASIC" and card_id == "sv1-107" and target_slot.begins_with("bench_"):
		score += weight("natu_bench")
	elif kind == "EVOLVE" and card_id == "sv1-108":
		score += weight("xatu_engine")
		if _count_card_on_board(info, "sv1-108") <= 0:
			score += weight("first_xatu_priority")
	elif (
		kind == "EVOLVE"
		and card_id == "sv1-106"
		and _count_card_on_board(info, "sv1-108") <= 0
		and _count_card_on_board(info, "sv1-107") > 0
	):
		# Houndstone is valuable only after the acceleration engine can support
		# attackers.  The former broad "evolution" goal completed on Houndstone
		# and delayed the first Xatu by several turns.
		score -= weight("houndstone_before_xatu_penalty")
	elif kind == "USE_ABILITY" and card_id == "sv1-108":
		score += weight("xatu_engine")
		score += float(_count_card_in_hand(info, "sv1-ener-5")) * weight("psychic_energy_hand")
	elif kind == "DECLARE_ATTACK" and card_id == "sv1-106":
		score += float(_count_role_in_discard(info, "psychic_pokemon")) * weight("graveyard_scaling")
	elif kind == "DECLARE_ATTACK" and card_id == "sv1-113":
		if _attack_index(action_row) == 0:
			score += weight("cresselia_growth")
			if exact_opening:
				score += weight("cresselia_first_turn_growth")
	elif kind == "DECLARE_ATTACK" and card_id == "sv1-111":
		if _attack_index(action_row) == 0:
			score += weight("latios_glide")
		elif _attack_index(action_row) == 1:
			score += weight("latios_clean_light")
	return score


func choice_option_score(
	info: Dictionary,
	choice_view: Dictionary,
	option: Dictionary,
	semantic_catalog: Dictionary = {},
) -> float:
	var score := super.choice_option_score(info, choice_view, option, semantic_catalog)
	if _choice_surface(choice_view) != "card":
		# Search-card priorities must never leak into board target choices.  This
		# previously made Xatu attach Energy to Natu over readyable attackers.
		return score
	var card_id := _option_card_id(option)
	# Executability changes what to fetch, not what to throw away.  Applying the
	# no-Natu penalty to a discard choice inverted it and made Xatu the cheapest
	# card to lose.
	if choice_mode(info, choice_view) in ["discard", "payment", "source"]:
		return score
	var natu_on_board := _count_card_on_board(info, "sv1-107")
	var xatu_on_board := _count_card_on_board(info, "sv1-108")
	var natu_in_hand := _count_card_in_hand(info, "sv1-107")
	var must_start_xatu_line := (
		xatu_on_board <= 0
		and natu_on_board + natu_in_hand <= 0
		and _own_bench_count(info) < 5
		and _choice_offers_card(choice_view, "sv1-107")
	)
	if must_start_xatu_line and card_id not in ["sv1-107", "sv1-108"]:
		# The generic search value gives every 120-HP core attacker +210 or more,
		# so a per-card Natu bonus alone hits the strategy cap and still loses.
		# When the same lawful search explicitly offers Natu and a bench slot is
		# open, defer another attacker until the first acceleration line exists.
		score -= weight("attacker_before_xatu_search_penalty")
	if card_id == "sv1-108":
		if natu_on_board > 0:
			# Complete a currently executable engine before collecting a second
			# attacker.  This also wins the otherwise near-tie with Houndstone.
			score += weight("xatu_engine") * 2.5
		elif natu_in_hand > 0:
			score += weight("xatu_engine") * 1.25
		else:
			# An evolution with no public Basic is dead material for this turn.
			score -= weight("xatu_engine") * 2.0
	elif card_id == "sv1-107":
		if natu_on_board + natu_in_hand <= xatu_on_board:
			score += weight("xatu_engine") * 2.0
		else:
			score += weight("xatu_engine") * 0.5
	elif card_id in ["sv1-104", "sv1-106"] and natu_on_board > 0 and xatu_on_board <= 0:
		# Do not abandon the first Xatu engine for a slower graveyard line unless
		# the trusted tactical layer has already found an immediate knockout.
		score -= weight("xatu_engine")
	elif card_id == "sv1-ener-5" and _count_card_on_board(info, "sv1-108") > 0:
		score += weight("psychic_energy_hand") * 2.0
	return score


func discard_synergy_score(
	info: Dictionary,
	choice_view: Dictionary,
	option: Dictionary,
	semantic_catalog: Dictionary = {},
) -> float:
	if not _houndstone_line_publicly_available(info):
		return 0.0
	return super.discard_synergy_score(
		info, choice_view, option, semantic_catalog)


func _houndstone_line_publicly_available(info: Dictionary) -> bool:
	return (
		_count_card_on_board(info, "sv1-104") > 0
		or _count_card_on_board(info, "sv1-106") > 0
		or _count_card_in_hand(info, "sv1-104") > 0
		or _count_card_in_hand(info, "sv1-106") > 0
	)


func _is_exact_cresselia_opening_turn(info: Dictionary) -> bool:
	return (
		str(info.get("phase", "")) == "MAIN"
		and _turn_number(info) == 2
		and _is_going_second(info)
		and int(info.get("active_player_idx", -1)) == _perspective(info)
	)


func _card_is_benched(info: Dictionary, card_id: String) -> bool:
	var own := _player_view(info, _perspective(info))
	var bench: Variant = own.get("bench", [])
	if not bench is Array:
		return false
	for pokemon_value in Array(bench):
		if pokemon_value is Dictionary and _row_card_id(pokemon_value) == card_id:
			return true
	return false


func _cresselia_opening_energy_available(info: Dictionary) -> bool:
	if _energy_count_for_card(info, "sv1-113") >= 1:
		return true
	var own := _player_view(info, _perspective(info))
	return (
		not bool(own.get("energy_attached_this_turn", false))
		and _count_card_in_hand(info, "sv1-ener-5") > 0
	)


func _has_legal_cresselia_retreat(info: Dictionary) -> bool:
	for action_value in info.get("legal_actions", []):
		if not action_value is Dictionary:
			continue
		var action_row: Dictionary = action_value
		if (
			_action_kind(action_row) == "RETREAT"
			and _action_target_card_id(action_row) == "sv1-113"
		):
			return true
	return false


func _choice_offers_card(choice_view: Dictionary, card_id: String) -> bool:
	var values: Variant = choice_view.get("options", [])
	if not values is Array:
		return false
	for option_value in Array(values):
		if option_value is Dictionary and _option_card_id(option_value) == card_id:
			return true
	return false
