class_name AIRuntimeStateProjection
extends RefCounted

## Canonical in-process AI observation boundary.
##
## The returned payload deliberately keeps the GameState wire shape so both
## traditional and native Deep planners can consume it, but it is not a
## restorable Snapshot 3: hidden identities and private continuation state have
## been removed. Rules simulation must start from an information-set
## determinization, never by restoring this observation directly.

const BOUNDARY_ID := "ai_public_state_v1"
const HIDDEN_CARD := "__hidden_card__"
const HIDDEN_PRIZE := "__hidden_prize__"


static func project(state: GameState, perspective: int) -> Dictionary:
	if state == null or perspective not in [0, 1] or state.players.size() != 2:
		return {}
	var snapshot := state.snapshot()
	snapshot["ai_runtime_projection"] = BOUNDARY_ID
	# Resolution frames, idempotency records and setup bonus identities are
	# authoritative implementation details. The public action log is retained for
	# deterministic repeatable-ability guards, then scrubbed by AIInformationSet
	# before deck strategy hooks receive their view.
	snapshot.erase("resolution_stack")
	snapshot.erase("processed_action_ids")
	snapshot.erase("choice_sequence")
	snapshot.erase("setup_bonus_card_ids")
	var player_rows: Array = snapshot.get("players", [])
	if player_rows.size() != 2:
		return {}
	for player_index in [0, 1]:
		var row: Dictionary = Dictionary(player_rows[player_index]).duplicate(true)
		row["deck"] = _hidden_cards(
			Array(row.get("deck", [])).size(), HIDDEN_CARD)
		row["prizes"] = _hidden_cards(
			Array(row.get("prizes", [])).size(), HIDDEN_PRIZE)
		if player_index != perspective:
			row["hand"] = _hidden_cards(
				Array(row.get("hand", [])).size(), HIDDEN_CARD)
		player_rows[player_index] = row
	if (
		str(snapshot.get("phase", "")) == "SETUP"
		and str(snapshot.get("setup_stage", GameState.SETUP_COMPLETE))
		!= GameState.SETUP_COMPLETE
	):
		var opponent_index := 1 - perspective
		var opponent: Dictionary = player_rows[opponent_index]
		opponent["active"] = null
		var hidden_bench: Array = []
		hidden_bench.resize(Array(opponent.get("bench", [])).size())
		hidden_bench.fill(null)
		opponent["bench"] = hidden_bench
		player_rows[opponent_index] = opponent
	snapshot["players"] = player_rows
	return snapshot


static func validate(snapshot: Dictionary, perspective: int) -> String:
	if perspective not in [0, 1]:
		return "invalid_perspective"
	if str(snapshot.get("ai_runtime_projection", "")) != BOUNDARY_ID:
		return "missing_runtime_projection"
	if not snapshot.get("revision") is int or int(snapshot["revision"]) < 0:
		return "invalid_revision"
	if snapshot.has("resolution_stack"):
		return "private_field_exposed:resolution_stack"
	if snapshot.has("processed_action_ids"):
		return "private_field_exposed:processed_action_ids"
	if snapshot.has("choice_sequence"):
		return "private_field_exposed:choice_sequence"
	if snapshot.has("setup_bonus_card_ids"):
		return "private_field_exposed:setup_bonus_card_ids"
	var players: Variant = snapshot.get("players")
	if not players is Array or Array(players).size() != 2:
		return "invalid_player_snapshot"
	for player_index in [0, 1]:
		var row_value: Variant = Array(players)[player_index]
		if not row_value is Dictionary:
			return "invalid_player_snapshot"
		var row: Dictionary = row_value
		var deck_error := _validate_hidden_zone(
			row.get("deck"), HIDDEN_CARD,
			"players[%d].deck" % player_index)
		if not deck_error.is_empty():
			return deck_error
		var prize_error := _validate_hidden_zone(
			row.get("prizes"), HIDDEN_PRIZE,
			"players[%d].prizes" % player_index)
		if not prize_error.is_empty():
			return prize_error
		if player_index != perspective:
			var hand_error := _validate_hidden_zone(
				row.get("hand"), HIDDEN_CARD,
				"players[%d].hand" % player_index)
			if not hand_error.is_empty():
				return hand_error
	if (
		str(snapshot.get("phase", "")) == "SETUP"
		and str(snapshot.get("setup_stage", GameState.SETUP_COMPLETE))
		!= GameState.SETUP_COMPLETE
	):
		var opponent_index := 1 - perspective
		var opponent: Dictionary = Array(players)[opponent_index]
		if opponent.get("active") != null:
			return "hidden_identity_exposed:setup_active"
		for bench_value in opponent.get("bench", []):
			if bench_value != null:
				return "hidden_identity_exposed:setup_bench"
	return ""


static func is_projected(snapshot: Dictionary) -> bool:
	return str(snapshot.get("ai_runtime_projection", "")) == BOUNDARY_ID


static func _hidden_cards(count: int, marker: String) -> Array[String]:
	var result: Array[String] = []
	result.resize(maxi(0, count))
	result.fill(marker)
	return result


static func _validate_hidden_zone(
	value: Variant,
	marker: String,
	path: String,
) -> String:
	if not value is Array:
		return "invalid_hidden_zone:%s" % path
	for card_id_value in Array(value):
		if not card_id_value is String or str(card_id_value) != marker:
			return "hidden_identity_exposed:%s" % path
	return ""
