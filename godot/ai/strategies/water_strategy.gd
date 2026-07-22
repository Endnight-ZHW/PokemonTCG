class_name WaterDeckStrategy
extends DeckStrategy


func _init(profile: Dictionary = {}, deck_archetypes: Dictionary = {}) -> void:
	super(profile, deck_archetypes)


func plan_stage(info: Dictionary) -> String:
	if _count_card_on_board(info, "sv2-grex") <= 0:
		return "establish_board"
	# Torrent only converts damage on the opponent's Active Pokemon.  Spreading
	# counters over two arbitrary targets is not, by itself, a prize route.
	if _own_prize_count(info) <= 2 or _opponent_active_damage(info) > 0:
		return "take_multi_prize"
	return "enable_shuriken"


func state_score_adjustment(info: Dictionary, semantic_catalog: Dictionary = {}) -> float:
	var score := super.state_score_adjustment(info, semantic_catalog)
	score += float(_count_card_on_board(info, "sv2-grex")) * weight("greninja_attack")
	score += float(_opponent_active_damage(info) > 0) * weight("torrent_setup")
	# Torrent is fully supplied at two Water Energy; do not make a third
	# attachment look like continuing strategic progress.
	score += float(mini(
		2, _energy_count_for_card(info, "sv2-grex")
	)) * weight("greninja_energy")
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
		and card_id == "sv2-tatsu"
		and target_slot == "active"
		and _is_going_second(info)
	):
		# Tatsugiri is the deck's best opening pivot: its first attack converts one
		# attachment into two more while Froakie develops safely on the Bench.
		score += weight("tatsugiri_opening")
	elif (
		kind == "PLAY_BASIC"
		and card_id == "sv2-staryu"
		and target_slot == "active"
		and _turn_number(info) <= 1
		and "sv2-tatsu" in _own_hand(info)
		and _is_going_second(info)
	):
		# Do not let the generic engine/setup bonuses erase Tatsugiri's explicit
		# opening role when both Basics are legal opening choices.
		score -= weight("staryu_opening_penalty")
	elif kind == "PLAY_BASIC" and card_id == "sv2-staryu":
		if _staryu_line_count(info) > 0:
			# One Staryu line supplies Mystic Comet.  Further copies should not
			# consume Bench space needed for a Greninja replacement attacker.
			score -= weight("staryu_duplicate_penalty")
	elif kind == "PLAY_BASIC" and card_id == "sv2-38" and target_slot.begins_with("bench_"):
		score += weight("froakie_bench")
		if _needs_froakie_backup(info):
			score += weight("froakie_backup_search")
	elif (
		kind == "ATTACH_ENERGY"
		and _action_target_card_id(action_row) == "sv2-tatsu"
		and _card_is_active(info, "sv2-tatsu")
		and _energy_count_for_card(info, "sv2-tatsu") <= 0
		and _own_bench_count(info) > 0
	):
		# One Water Energy immediately unlocks Prepare.  Without this explicit
		# bridge the generic damage heuristic feeds a Bench attacker and leaves the
		# active Tatsugiri unable to accelerate two Energy this turn.
		score += weight("tatsugiri_prepare_attachment")
	elif kind == "EVOLVE" and card_id == "sv2-grex":
		score += weight("greninja_attack")
	elif (
		kind == "PLAY_TRAINER"
		and card_id == "sv1-152"
		and _count_card_on_board(info, "sv2-38") > 0
		and _count_card_in_hand(info, "sv2-grex") > 0
	):
		# Rare Candy turns the public Basic + Stage 2 pair into the deck's main
		# attacker before a hand refresh can discard either half.
		score += weight("rare_candy_greninja")
	elif kind == "PLAY_TRAINER" and card_id == "sv2-cand":
		score += weight("candice")
	elif kind == "DECLARE_ATTACK" and card_id == "sv2-grex":
		score += weight("greninja_attack")
		if _attack_index(action_row) == 0:
			score += weight("greninja_shuriken")
			score += float(maxi(1, _opponent_board_rows(info).size() - 1)) * weight("bench_target_pressure") * 0.35
		elif _attack_index(action_row) == 1:
			score += weight("greninja_torrent")
			if _opponent_active_damage(info) > 0:
				score += weight("bench_target_pressure")
	elif kind == "DECLARE_ATTACK" and card_id == "sv2-tatsu":
		if _attack_index(action_row) == 0:
			score += weight("tatsugiri_prepare")
			if _turn_number(info) <= 2:
				score += weight("tatsugiri_opening")
	elif kind == "USE_ABILITY" and card_id == "sv2-starm":
		# Mystic Comet discards Starmie and its attached cards; it does not award
		# the opponent a Prize.  Spend that public material when a ready Active
		# Greninja can convert the new damage marker into Torrent damage this turn.
		var ready_greninja_on_board := (
			_count_card_on_board(info, "sv2-grex") > 0
			and _energy_count_for_card(info, "sv2-grex") >= 2)
		var torrent_ready := (
			ready_greninja_on_board
			and (
				_card_is_active(info, "sv2-grex")
				or (_card_is_active(info, "sv2-starm") and _own_bench_count(info) > 0)
			)
			and _opponent_active_damage(info) <= 0
		)
		if torrent_ready:
			score += weight("starmie_comet_combo")
		else:
			score -= weight("starmie_material_cost")
		score -= float(_energy_count_for_card(info, card_id)) * weight("starmie_attachment_cost")
		if _card_is_active(info, card_id) and _own_bench_count(info) <= 0:
			score -= weight("starmie_no_backup_penalty")
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
	if card_id in ["sv2-38", "sv2-39", "sv2-grex"]:
		score += weight("greninja_attack")
		if card_id == "sv2-38" and _needs_froakie_backup(info):
			# Search effects should rebuild the main line before adding a second
			# Staryu engine when the damaged Active Greninja is exposed.
			score += weight("froakie_backup_search")
	elif card_id == "sv2-staryu":
		score += weight("choice_engine")
		if _staryu_line_count(info) > 0:
			score -= weight("staryu_duplicate_penalty")
	elif card_id == "sv2-starm":
		var executable_line := (
			_count_card_on_board(info, "sv2-staryu") > 0
			or _count_card_in_hand(info, "sv2-staryu") > 0
		)
		if executable_line:
			score += weight("choice_engine")
		else:
			# A Stage 1 with no publicly available Basic is dead material.  Do not
			# let its generic evolution role beat an executable Greninja line.
			score -= weight("starmie_unexecutable_penalty")
		# A Starmie can complete a Staryu already in play.  It is redundant only
		# when the established line has no unevolved Staryu waiting for it.
		if (
			_count_card_on_board(info, "sv2-starm") > 0
			and _count_card_on_board(info, "sv2-staryu") <= 0
		):
			score -= weight("staryu_duplicate_penalty")
	return score


func _staryu_line_count(info: Dictionary) -> int:
	return (
		_count_card_on_board(info, "sv2-staryu")
		+ _count_card_on_board(info, "sv2-starm")
	)


func _needs_froakie_backup(info: Dictionary) -> bool:
	if not _card_is_active(info, "sv2-grex") or _damage_on_card(info, "sv2-grex") <= 0:
		return false
	# Frogadier or a second Greninja already represents a live replacement
	# line, so do not over-search another Basic in those states.
	return (
		_count_card_on_board(info, "sv2-38") <= 0
		and _count_card_on_board(info, "sv2-39") <= 0
		and _count_card_on_board(info, "sv2-grex") <= 1
	)
