class_name AIInformationSet
extends RefCounted

## Immutable-by-contract information boundary for traditional AI.
##
## The captured public snapshot never retains identities from a hidden zone.
## Determinizations are rebuilt from the public deck list and public/owned
## observations, so callers cannot accidentally search the authoritative state.

const HIDDEN_CARD := "__ai_hidden_card__"
const HIDDEN_PRIZE := "__ai_hidden_prize__"
const EMPTY_RESOLUTION_STACK := {
	"schema_version": 3,
	"frames": [],
	"pending_request": null,
	"sequence": 0,
	"context": {},
}

var _perspective := -1
var _match_seed := 0
var _public_snapshot: Dictionary = {}
var _remaining_pools: Array = [[], []]
var _catalog: CardCatalog
var _validation_error := "not_captured"
var _fallback_card_id := "sv1-ener-1"
var _sampling_available := false


static func capture(
	state: GameState,
	perspective: int,
	catalog: CardCatalog = null,
	legal_actions: Array = [],
	public_history: Array = [],
	match_seed: int = 0,
) -> AIInformationSet:
	var result := AIInformationSet.new()
	result._capture_state(
		state, perspective, catalog, legal_actions, public_history, match_seed,
		true)
	return result


static func capture_view_only(
	state: GameState,
	perspective: int,
	catalog: CardCatalog = null,
	legal_actions: Array = [],
	public_history: Array = [],
	match_seed: int = 0,
) -> AIInformationSet:
	## Build the exact public projection used by capture(), without reconstructing
	## hidden-card pools that position/action strategy hooks cannot observe.
	var result := AIInformationSet.new()
	result._capture_state(
		state, perspective, catalog, legal_actions, public_history, match_seed,
		false)
	return result


static func from_snapshot(
	snapshot: Dictionary,
	perspective: int,
	catalog: CardCatalog = null,
	legal_actions: Array = [],
	public_history: Array = [],
	match_seed: int = 0,
) -> AIInformationSet:
	var result := AIInformationSet.new()
	if snapshot.is_empty():
		result._validation_error = "empty_snapshot"
		return result
	result._capture_state(
		GameState.from_dict(snapshot), perspective, catalog, legal_actions,
		public_history, match_seed, true)
	return result


func is_valid() -> bool:
	return _validation_error.is_empty()


func validation_error() -> String:
	return _validation_error


func perspective_player() -> int:
	return _perspective


func match_seed() -> int:
	return _match_seed


func read_only_view() -> Dictionary:
	## Return a new deeply frozen tree. No mutable branch aliases internal state.
	var result := _public_snapshot.duplicate(true)
	_deep_make_read_only(result)
	return result


func shared_read_only_view() -> Dictionary:
	## Internal hot-path view. The captured tree is already deeply immutable, so
	## strategy hooks can safely share it without another full snapshot copy.
	return _public_snapshot if is_valid() else {}


func read_only_view_for_legal_actions(legal_actions: Array) -> Dictionary:
	## Derive an action-specific strategy view from one sanitized state capture.
	## Every other field remains byte-for-byte equivalent to capture(...).
	if not is_valid():
		return {}
	# Nested branches are already deeply read-only and may be shared safely. Only
	# the top-level observation and the action list differ between candidates.
	var result := _public_snapshot.duplicate(false)
	var action_rows := _public_action_rows(legal_actions)
	_deep_make_read_only(action_rows)
	result["legal_actions"] = action_rows
	result.make_read_only()
	return result


func export_mutable() -> Dictionary:
	## Return an independent mutable public snapshot for feature builders.
	return _public_snapshot.duplicate(true)


func cache_precondition() -> Dictionary:
	## Stable public-state identity used to guard a cached semantic turn intent.
	if not is_valid():
		return {}
	# Nested branches are immutable and only top-level observation annotations
	# are removed, so a shallow container copy preserves the canonical wire.
	var payload := _public_snapshot.duplicate(false)
	# These are observation annotations, not game state. The legal set is checked
	# separately by the caller and history may be supplied at different lengths.
	payload.erase("legal_actions")
	payload.erase("public_history")
	payload.erase("perspective")
	payload.erase("match_seed")
	var wire := _stable_variant_signature(payload)
	return {
		"expected_public_fingerprint": "public:%s" % wire.sha256_text(),
		"expected_actor": int(_public_snapshot.get("actor", -1)),
		"expected_phase": str(_public_snapshot.get("phase", "")),
	}


func legal_action_summaries() -> Array:
	var result := Array(_public_snapshot.get("legal_actions", [])).duplicate(true)
	_deep_make_read_only(result)
	return result


func public_history() -> Array:
	var result := Array(_public_snapshot.get("public_history", [])).duplicate(true)
	_deep_make_read_only(result)
	return result


func inferred_hidden_pool_for_perspective() -> Array[String]:
	## Trusted rule-tactics may reason about the published deck list after
	## subtracting every visible/owned card.  This is a multiset for the unknown
	## deck+Prize partition, never the authoritative order or Prize identities;
	## strategy hooks receive only read_only_view() and cannot access it.
	return inferred_hidden_pool_for_player(_perspective)


func inferred_hidden_pool_for_player(player_idx: int) -> Array[String]:
	## Trusted tactics may also form probabilities about an opponent's hidden
	## hand/deck/Prize partition from the published release deck. This returns
	## only that public multiset: it never contains the authoritative allocation
	## or ordering, and strategy hooks are not given this AIInformationSet object.
	var result: Array[String] = []
	if is_valid() and player_idx in [0, 1]:
		for value in _remaining_pools[player_idx]:
			result.append(str(value))
	result.make_read_only()
	return result


func sample_state(seed: int) -> GameState:
	## Produce one legal-identity determinization without type matchups.
	if not is_valid() or not _sampling_available:
		return null
	var payload := export_mutable()
	var player_rows: Array = payload.get("players", [])
	if player_rows.size() != 2:
		return null
	var rng := PortableRandomSource.new(seed)
	for player_idx in [0, 1]:
		var row: Dictionary = player_rows[player_idx]
		var pool: Array = Array(_remaining_pools[player_idx]).duplicate()
		var hand_count := (
			Array(row.get("hand", [])).size() if player_idx != _perspective else 0
		)
		var deck_count := Array(row.get("deck", [])).size()
		var prize_count := Array(row.get("prizes", [])).size()
		var needed := hand_count + deck_count + prize_count
		while pool.size() < needed:
			pool.append(_fallback_card_id)
		rng.shuffle(pool)
		if pool.size() > needed:
			pool.resize(needed)
		var offset := 0
		if player_idx != _perspective:
			row["hand"] = _string_slice(pool, offset, offset + hand_count)
			offset += hand_count
		row["deck"] = _string_slice(pool, offset, offset + deck_count)
		offset += deck_count
		row["prizes"] = _string_slice(pool, offset, offset + prize_count)
		player_rows[player_idx] = row
	payload["players"] = player_rows
	_force_matchups_off(payload)
	payload["resolution_stack"] = EMPTY_RESOLUTION_STACK.duplicate(true)
	var state := GameState.from_dict(payload)
	state.set_type_matchups_enabled(false)
	return state


func hidden_zone_counts(player_idx: int) -> Dictionary:
	if not is_valid() or player_idx not in [0, 1]:
		return {}
	var players: Array = _public_snapshot.get("players", [])
	var row: Dictionary = players[player_idx]
	return {
		"hand": Array(row.get("hand", [])).size() if player_idx != _perspective else 0,
		"deck": Array(row.get("deck", [])).size(),
		"prizes": Array(row.get("prizes", [])).size(),
	}


func _capture_state(
	state: GameState,
	perspective: int,
	catalog: CardCatalog,
	legal_actions: Array,
	public_history: Array,
	match_seed: int,
	rebuild_hidden_pools: bool,
) -> void:
	_validation_error = ""
	_sampling_available = false
	if state == null:
		_validation_error = "null_state"
		return
	if perspective not in [0, 1]:
		_validation_error = "invalid_perspective"
		return
	if state.players.size() != 2:
		_validation_error = "invalid_player_count"
		return
	_perspective = perspective
	_match_seed = match_seed
	_catalog = catalog if catalog != null else CardCatalog.shared()
	if rebuild_hidden_pools:
		_fallback_card_id = _find_fallback_card(_catalog)
	if rebuild_hidden_pools:
		_public_snapshot = state.snapshot()
		_sanitize_public_snapshot()
	else:
		_public_snapshot = _build_public_snapshot(state)
	_public_snapshot["match_seed"] = _match_seed
	_install_public_context(legal_actions, public_history)
	if rebuild_hidden_pools:
		_rebuild_remaining_pools()
		_sampling_available = true
	_deep_make_read_only(_public_snapshot)
	for pool_value in _remaining_pools:
		if pool_value is Array:
			Array(pool_value).make_read_only()
	_remaining_pools.make_read_only()


func _build_public_snapshot(state: GameState) -> Dictionary:
	## Directly construct the same sanitized GameState snapshot used by capture().
	## Hidden-zone identities, action logs and resolution frames are never copied.
	var setup_board_hidden: bool = (
		state.phase == "SETUP"
		and state.setup_stage != GameState.SETUP_COMPLETE
	)
	var player_rows: Array[Dictionary] = []
	for player_idx in [0, 1]:
		var player: PlayerState = state.players[player_idx]
		var hide_board: bool = (
			setup_board_hidden and player_idx != _perspective)
		var bench_payload: Array = []
		if hide_board:
			bench_payload = [null, null, null, null, null]
		else:
			for pokemon_value in player.bench:
				bench_payload.append(
					pokemon_value.to_dict()
					if pokemon_value is PokemonState
					else null
				)
		player_rows.append({
			"name": player.name,
			"deck": _hidden_cards(player.deck.size(), HIDDEN_CARD),
			"hand": (
				player.hand.duplicate()
				if player_idx == _perspective
				else _hidden_cards(player.hand.size(), HIDDEN_CARD)
			),
			"discard": player.discard.duplicate(),
			"prizes": _hidden_cards(player.prizes.size(), HIDDEN_PRIZE),
			"active": (
				player.active.to_dict()
				if player.active != null and not hide_board
				else null
			),
			"bench": bench_payload,
			"supporter_played_this_turn": player.supporter_played_this_turn,
			"energy_attached_this_turn": player.energy_attached_this_turn,
			"retreated_this_turn": player.retreated_this_turn,
			"stadium_played_this_turn": player.stadium_played_this_turn,
			"stadium_used_this_turn": player.stadium_used_this_turn,
			"healed_this_turn": player.healed_this_turn,
			"vstar_power_used": player.vstar_power_used,
			"was_ko_by_attack": player.was_ko_by_attack,
		})
	var options := state.rules_options.duplicate(true)
	options["apply_type_matchups"] = false
	var bonus_ids := state.setup_bonus_card_ids.duplicate(true)
	while bonus_ids.size() < 2:
		bonus_ids.append([])
	bonus_ids[1 - _perspective] = []
	return {
		"players": player_rows,
		"active_player_idx": state.active_player_idx,
		"phase": state.phase,
		"turn_number": state.turn_number,
		"first_player_idx": state.first_player_idx,
		"stadium_card_id": state.stadium_card_id,
		"stadium_owner_idx": state.stadium_owner_idx,
		"winner": state.winner,
		"result_status": state.result_status,
		"result_reason": state.result_reason,
		"result_conditions": state.result_conditions.duplicate(true),
		"revision": state.revision,
		"choice_sequence": state.choice_sequence,
		"public_deck_keys": state.public_deck_keys.duplicate(),
		"apply_type_matchups": false,
		"rules_profile_id": state.rules_profile_id,
		"rules_options": options,
		"action_log": [],
		"mulligan_count": state.mulligan_count.duplicate(),
		"extra_draws": state.extra_draws.duplicate(),
		"setup_ready": state.setup_ready.duplicate(),
		"setup_stage": state.setup_stage,
		"setup_actor_idx": state.setup_actor_idx,
		"opening_coin_winner_idx": state.opening_coin_winner_idx,
		"mulligan_bonus_max": state.mulligan_bonus_max,
		"setup_bonus_card_ids": bonus_ids,
		"pending_promotions": state.pending_promotions.duplicate(),
		"processed_action_ids": [],
		"resolution_stack": EMPTY_RESOLUTION_STACK.duplicate(true),
		"turn_fact_book": state.turn_fact_book.duplicate(true),
		"snapshot_version": GameState.SNAPSHOT_SCHEMA_VERSION,
		"perspective": _perspective,
		"actor": _decision_actor_from_state(state),
	}


func _install_public_context(legal_actions: Array, public_history: Array) -> void:
	_public_snapshot["legal_actions"] = _public_action_rows(legal_actions)
	var history_rows: Array[Dictionary] = []
	for row_value in public_history.slice(maxi(0, public_history.size() - 24)):
		if row_value is Dictionary:
			var projected := _public_history_row(row_value)
			if not projected.is_empty():
				history_rows.append(projected)
	_public_snapshot["public_history"] = history_rows


func _public_action_rows(legal_actions: Array) -> Array[Dictionary]:
	var action_rows: Array[Dictionary] = []
	for action_value in legal_actions:
		if action_value is GameAction:
			action_rows.append(_public_action_summary(action_value))
	return action_rows


func _sanitize_public_snapshot() -> void:
	_force_matchups_off(_public_snapshot)
	_public_snapshot["perspective"] = _perspective
	_public_snapshot["actor"] = _decision_actor(_public_snapshot)
	# Resolution frames, transaction checkpoints and historical logs can carry
	# private selection values. They are never part of the planner observation.
	_public_snapshot["resolution_stack"] = EMPTY_RESOLUTION_STACK.duplicate(true)
	_public_snapshot["action_log"] = []
	_public_snapshot["processed_action_ids"] = []
	var player_rows: Array = _public_snapshot.get("players", [])
	if player_rows.size() != 2:
		_validation_error = "invalid_player_snapshot"
		return
	for player_idx in [0, 1]:
		var row: Dictionary = Dictionary(player_rows[player_idx]).duplicate(true)
		row["deck"] = _hidden_cards(Array(row.get("deck", [])).size(), HIDDEN_CARD)
		row["prizes"] = _hidden_cards(Array(row.get("prizes", [])).size(), HIDDEN_PRIZE)
		if player_idx != _perspective:
			row["hand"] = _hidden_cards(Array(row.get("hand", [])).size(), HIDDEN_CARD)
		player_rows[player_idx] = row
	var setup_board_hidden := (
		str(_public_snapshot.get("phase", "")) == "SETUP"
		and str(_public_snapshot.get("setup_stage", "")) != GameState.SETUP_COMPLETE
	)
	if setup_board_hidden:
		var opponent_idx := 1 - _perspective
		var opponent: Dictionary = player_rows[opponent_idx]
		opponent["active"] = null
		opponent["bench"] = [null, null, null, null, null]
		player_rows[opponent_idx] = opponent
	_public_snapshot["players"] = player_rows
	var bonus_ids: Array = Array(_public_snapshot.get(
		"setup_bonus_card_ids", [[], []])).duplicate(true)
	while bonus_ids.size() < 2:
		bonus_ids.append([])
	bonus_ids[1 - _perspective] = []
	_public_snapshot["setup_bonus_card_ids"] = bonus_ids


func _rebuild_remaining_pools() -> void:
	_remaining_pools = [[], []]
	if not _validation_error.is_empty():
		return
	var rows: Array = _public_snapshot.get("players", [])
	var deck_keys: Array = _public_snapshot.get("public_deck_keys", ["", ""])
	for player_idx in [0, 1]:
		var deck_key := str(deck_keys[player_idx]) if player_idx < deck_keys.size() else ""
		var pool: Array[String] = _catalog.expand_deck(deck_key)
		var row: Dictionary = rows[player_idx]
		for visible_id in _visible_cards(row, player_idx == _perspective):
			var found := pool.find(visible_id)
			if found >= 0:
				pool.remove_at(found)
		if (
			int(_public_snapshot.get("stadium_owner_idx", -1)) == player_idx
			and not str(_public_snapshot.get("stadium_card_id", "")).is_empty()
		):
			var stadium_index := pool.find(str(_public_snapshot["stadium_card_id"]))
			if stadium_index >= 0:
				pool.remove_at(stadium_index)
		var hidden_count := (
			(Array(row.get("hand", [])).size() if player_idx != _perspective else 0)
			+ Array(row.get("deck", [])).size()
			+ Array(row.get("prizes", [])).size()
		)
		if pool.is_empty() and hidden_count > 0:
			pool.resize(hidden_count)
			pool.fill(_fallback_card_id)
		_remaining_pools[player_idx] = pool


static func _visible_cards(row: Dictionary, include_hand: bool) -> Array[String]:
	var result: Array[String] = []
	if include_hand:
		for value in row.get("hand", []):
			if not _is_hidden_id(str(value)):
				result.append(str(value))
	for value in row.get("discard", []):
		if not _is_hidden_id(str(value)):
			result.append(str(value))
	_append_pokemon_cards(result, row.get("active"))
	for pokemon_value in row.get("bench", []):
		_append_pokemon_cards(result, pokemon_value)
	return result


static func _append_pokemon_cards(result: Array[String], value: Variant) -> void:
	if not value is Dictionary:
		return
	var pokemon: Dictionary = value
	for card_id_value in [pokemon.get("card_id", ""), pokemon.get("attached_tool_id", "")]:
		var card_id := str(card_id_value)
		if not card_id.is_empty() and not _is_hidden_id(card_id):
			result.append(card_id)
	for field in ["evolution_stack_ids", "energy_card_ids"]:
		for card_id_value in pokemon.get(field, []):
			var card_id := str(card_id_value)
			if not card_id.is_empty() and not _is_hidden_id(card_id):
				result.append(card_id)


static func _force_matchups_off(payload: Dictionary) -> void:
	payload["apply_type_matchups"] = false
	var options := Dictionary(payload.get("rules_options", {})).duplicate(true)
	options["apply_type_matchups"] = false
	payload["rules_options"] = options


static func _decision_actor(payload: Dictionary) -> int:
	var promotions: Array = payload.get("pending_promotions", [])
	if not promotions.is_empty() and int(promotions[0]) in [0, 1]:
		return int(promotions[0])
	if str(payload.get("phase", "")) == "SETUP":
		var setup_actor := int(payload.get("setup_actor_idx", -1))
		if setup_actor in [0, 1]:
			return setup_actor
	return int(payload.get("active_player_idx", -1))


static func _decision_actor_from_state(state: GameState) -> int:
	if (
		not state.pending_promotions.is_empty()
		and int(state.pending_promotions[0]) in [0, 1]
	):
		return int(state.pending_promotions[0])
	if state.phase == "SETUP" and state.setup_actor_idx in [0, 1]:
		return state.setup_actor_idx
	return state.active_player_idx


func _public_action_summary(action: GameAction) -> Dictionary:
	var payload: Dictionary = {}
	for key in ["attack_index", "ability_name", "trainer_type", "mode", "amount", "count"]:
		var value: Variant = action.payload.get(key)
		if action.payload.has(key) and (
			value is int or value is float or value is bool or value is String):
			payload[key] = action.payload[key]
	return {
		"kind": action.kind,
		"actor": action.actor,
		"source": _public_ref_summary(action.source),
		"target": _public_ref_summary(action.target),
		"payload": payload,
	}


func _public_ref_summary(ref: EntityRef) -> Dictionary:
	if ref == null:
		return {}
	var result := {
		"kind": ref.kind,
		"player": ref.player,
		"zone": ref.zone,
		"slot": ref.slot,
		"attachment_type": ref.attachment_type,
	}
	var identity_is_public := (
		ref.zone not in ["deck", "prizes"]
		and (ref.zone != "hand" or ref.player == _perspective)
	)
	if identity_is_public and not ref.card_id.is_empty():
		result["card_id"] = ref.card_id
	return result


static func _public_history_row(source: Dictionary) -> Dictionary:
	# History is an explicit structured public feed. Free-form messages, choices,
	# resolution frames and snapshots are intentionally impossible to project.
	var result: Dictionary = {}
	for key in [
		"turn_number", "revision", "actor", "kind", "card_id",
		"source_zone", "source_slot", "target_zone", "target_slot", "event_type",
	]:
		if not source.has(key):
			continue
		var value: Variant = source[key]
		if value is String or value is int or value is bool:
			result[key] = value
	# A card identity is only retained when the producer explicitly identifies a
	# public source zone. Missing or malformed zone metadata is treated as hidden
	# instead of trusting that the upstream history row was already sanitized.
	if (
		result.has("card_id")
		and str(result.get("source_zone", "")) not in [
			"field", "active", "bench", "discard", "stadium", "lost_zone",
		]
	):
		result.erase("card_id")
	return result


static func _hidden_cards(count: int, marker: String) -> Array[String]:
	var result: Array[String] = []
	result.resize(maxi(0, count))
	result.fill(marker)
	return result


static func _string_slice(values: Array, begin: int, end: int) -> Array[String]:
	var result: Array[String] = []
	for value in values.slice(begin, end):
		result.append(str(value))
	return result


static func _is_hidden_id(card_id: String) -> bool:
	return card_id in [HIDDEN_CARD, HIDDEN_PRIZE, "__hidden_card__", "__hidden_prize__"]


static func _find_fallback_card(catalog: CardCatalog) -> String:
	if catalog.cards.has("sv1-ener-1"):
		return "sv1-ener-1"
	for card_id_value in catalog.cards:
		var card_id := str(card_id_value)
		if catalog.is_basic_energy(card_id):
			return card_id
	return "sv1-ener-1"


static func _stable_variant_signature(value: Variant) -> String:
	if value is Dictionary:
		var dictionary: Dictionary = value
		var keys: Array[String] = []
		for key_value in dictionary:
			keys.append(str(key_value))
		keys.sort()
		var parts: Array[String] = []
		for key in keys:
			parts.append("%s:%s" % [
				JSON.stringify(key), _stable_variant_signature(dictionary[key]),
			])
		return "{%s}" % ",".join(parts)
	if value is Array:
		var parts: Array[String] = []
		for nested in value:
			parts.append(_stable_variant_signature(nested))
		return "[%s]" % ",".join(parts)
	return JSON.stringify(value)


static func _deep_make_read_only(value: Variant) -> void:
	if value is Dictionary:
		var dictionary: Dictionary = value
		for nested_value in dictionary.values():
			_deep_make_read_only(nested_value)
		dictionary.make_read_only()
	elif value is Array:
		var array: Array = value
		for nested_value in array:
			_deep_make_read_only(nested_value)
		array.make_read_only()
