class_name AIPositionEvaluator
extends RefCounted

## Canonical deterministic scoring shared by candidate ordering, leaf
## evaluation, tactical fallbacks and opponent-response search.

const SCORE_SCALE := 1000
const WIN_SCORE_MILLI := 1000000000
const STRATEGY_ACTION_LIMIT_MILLI := 250000
const STRATEGY_STATE_LIMIT_MILLI := 300000
const TRUSTED_STATE_LIMIT_MILLI := 210000
const RETREAT_TEMPO_COST := 42.0
const EVOLUTION_ASSET_VALUE := 18.0


static func action_score_milli(
	state: GameState,
	actor: int,
	action: GameAction,
	strategy: Variant,
	semantic_catalog: CardSemanticCatalog,
	catalog: CardCatalog,
	match_seed: int,
	trusted_action_evaluator: Callable = Callable(),
) -> int:
	if state == null or action == null:
		return -WIN_SCORE_MILLI
	var score_milli := _quantize(_default_action_priority(action, semantic_catalog))
	if trusted_action_evaluator.is_valid():
		var trusted_value: Variant = trusted_action_evaluator.call(state, actor, action)
		if _is_finite_number(trusted_value):
			score_milli = _quantize(float(trusted_value))
	var information := AIInformationSet.capture(
		state, actor, catalog, [action], [], match_seed)
	if information.is_valid():
		var strategy_value: Variant = _strategy_call(
			strategy,
			"action_score",
			[
				information.read_only_view(),
				_read_only_copy(action.to_dict()),
				semantic_context_for_action(action, semantic_catalog),
			],
			0.0,
		)
		if _is_finite_number(strategy_value):
			score_milli += clampi(
				_quantize(float(strategy_value)),
				-STRATEGY_ACTION_LIMIT_MILLI,
				STRATEGY_ACTION_LIMIT_MILLI,
			)
	return score_milli


static func state_score_milli(
	state: GameState,
	actor: int,
	strategy: Variant,
	semantic_catalog: CardSemanticCatalog,
	catalog: CardCatalog,
	match_seed: int,
	trusted_leaf_evaluator: Callable = Callable(),
) -> int:
	if state == null:
		return -WIN_SCORE_MILLI
	if state.is_terminal():
		if state.result_status == GameState.RESULT_DRAW:
			return 0
		return WIN_SCORE_MILLI if state.winner == actor else -WIN_SCORE_MILLI
	var own := state.get_player(actor)
	var opponent := state.get_player(1 - actor)
	var score := float(opponent.prizes.size() - own.prizes.size()) * 150.0
	score += float(own.hand.size() - opponent.hand.size()) * 2.0
	score += float(own.deck.size() - opponent.deck.size()) * 0.05
	score += board_score(own, catalog) - board_score(opponent, catalog)
	score += turn_commitment_score(own) - turn_commitment_score(opponent)
	var score_milli := _quantize(score)
	if trusted_leaf_evaluator.is_valid():
		var trusted_value: Variant = trusted_leaf_evaluator.call(state, actor, catalog)
		if _is_finite_number(trusted_value):
			score_milli += clampi(
				_quantize(float(trusted_value) * 0.35),
				-TRUSTED_STATE_LIMIT_MILLI,
				TRUSTED_STATE_LIMIT_MILLI,
			)
	var information := AIInformationSet.capture(
		state, actor, catalog, [], [], match_seed)
	if information.is_valid():
		var public_view := information.read_only_view()
		var strategy_value: Variant = _strategy_call(
			strategy,
			"state_score",
			[public_view, semantic_context_for_view(public_view, semantic_catalog)],
			0.0,
		)
		if _is_finite_number(strategy_value):
			score_milli += clampi(
				_quantize(float(strategy_value)),
				-STRATEGY_STATE_LIMIT_MILLI,
				STRATEGY_STATE_LIMIT_MILLI,
			)
	return score_milli


static func ranked_actions(
	state: GameState,
	actor: int,
	actions: Array[GameAction],
	strategy: Variant,
	semantic_catalog: CardSemanticCatalog,
	catalog: CardCatalog,
	match_seed: int,
	cancel_check: Callable = Callable(),
	trusted_action_evaluator: Callable = Callable(),
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for index in range(actions.size()):
		if _is_cancelled(cancel_check):
			break
		var action := actions[index]
		result.append({
			"action": action,
			"score_milli": action_score_milli(
				state,
				actor,
				action,
				strategy,
				semantic_catalog,
				catalog,
				match_seed,
				trusted_action_evaluator,
			),
			"signature": action_signature(action),
			"bucket": semantic_bucket(action),
			"purpose_bucket": action_purpose_bucket(action),
			"index": index,
		})
	result.sort_custom(action_row_descending)
	return result


static func action_row_descending(left: Dictionary, right: Dictionary) -> bool:
	var left_score := int(left.get("score_milli", -WIN_SCORE_MILLI))
	var right_score := int(right.get("score_milli", -WIN_SCORE_MILLI))
	if left_score != right_score:
		return left_score > right_score
	var left_signature := str(left.get("signature", ""))
	var right_signature := str(right.get("signature", ""))
	if left_signature != right_signature:
		return left_signature < right_signature
	return int(left.get("index", 0)) < int(right.get("index", 0))


static func diverse_top_actions(
	ranked: Array[Dictionary],
	count: int,
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var limit := mini(maxi(0, count), ranked.size())
	if limit <= 0:
		return result
	var used_buckets: Dictionary = {}
	var used_purposes: Dictionary = {}
	var used_signatures: Dictionary = {}
	# Reserve one slot per action purpose before considering alternate cards,
	# attacks or targets.  A high-scoring family of attacks must not crowd all
	# evolution and resource-building continuations out of a fixed-width node.
	for row_value in ranked:
		var row: Dictionary = row_value
		var action: GameAction = row.get("action")
		var purpose := str(row.get(
			"purpose_bucket", action_purpose_bucket(action)))
		var signature := str(row.get("signature", ""))
		if purpose.is_empty() or used_purposes.has(purpose) or used_signatures.has(signature):
			continue
		result.append(row)
		used_purposes[purpose] = true
		used_signatures[signature] = true
		used_buckets[str(row.get("bucket", semantic_bucket(action)))] = true
		if result.size() >= limit:
			break
	# Then admit semantically different source/card/attack/target/fee variants.
	for row_value in ranked:
		if result.size() >= limit:
			break
		var row: Dictionary = row_value
		var action: GameAction = row.get("action")
		var bucket := str(row.get("bucket", semantic_bucket(action)))
		var signature := str(row.get("signature", ""))
		if bucket.is_empty() or used_buckets.has(bucket) or used_signatures.has(signature):
			continue
		result.append(row)
		used_buckets[bucket] = true
		used_signatures[signature] = true
		used_purposes[str(row.get(
			"purpose_bucket", action_purpose_bucket(action)))] = true
	for row_value in ranked:
		if result.size() >= limit:
			break
		var row: Dictionary = row_value
		var signature := str(row.get("signature", ""))
		if used_signatures.has(signature):
			continue
		result.append(row)
		used_signatures[signature] = true
	# END_TURN/SETUP_DONE is a real strategic alternative, not merely a
	# low-scored fallback.  Keep one available even when every higher-ranked
	# semantic bucket is a development action.
	var end_row: Dictionary = {}
	for row_value in ranked:
		var row: Dictionary = row_value
		var action: GameAction = row.get("action")
		if action != null and action.kind in ["END_TURN", "SETUP_DONE"]:
			end_row = row
			break
	if not end_row.is_empty():
		var end_signature := str(end_row.get("signature", ""))
		if not used_signatures.has(end_signature):
			if result.size() >= limit:
				result[_protected_replacement_index(result)] = end_row
			else:
				result.append(end_row)
			used_signatures[end_signature] = true
	# Always compare at least one genuinely completed turn.
	var has_terminal := false
	for row_value in result:
		var action: GameAction = Dictionary(row_value).get("action")
		if action != null and action.terminal:
			has_terminal = true
			break
	if not has_terminal:
		for row_value in ranked:
			var row: Dictionary = row_value
			var action: GameAction = row.get("action")
			if action == null or not action.terminal:
				continue
			if result.size() >= limit:
				result[result.size() - 1] = row
			else:
				result.append(row)
			break
	# When every purpose consumes a slot, the old one-per-purpose reservation
	# silently removed all alternate evolution/attachment/bench targets.  Keep
	# the best unrepresented target-sensitive variant and replace only the
	# lowest-scored nonterminal purpose; winning/attack and END alternatives
	# remain protected.
	var target_variant := _best_unrepresented_target_variant(ranked, result)
	if not target_variant.is_empty():
		if result.size() < limit:
			result.append(target_variant)
		else:
			var replacement_index := _target_variant_replacement_index(
				result,
				str(target_variant.get("purpose_bucket", "")),
			)
			if replacement_index >= 0:
				result[replacement_index] = target_variant
	return result


static func action_signature(action: GameAction) -> String:
	if action == null:
		return ""
	var stable := {
		"kind": action.kind,
		"actor": action.actor,
		"source": _stable_ref(action.source),
		"target": _stable_ref(action.target),
		"payload": action.payload.duplicate(true),
	}
	var wire := stable_variant_signature(stable)
	return "action:%s" % wire.sha256_text()


static func semantic_bucket(action: GameAction) -> String:
	if action == null:
		return ""
	var payload := action.payload
	var stable := {
		"purpose": action_purpose_bucket(action),
		"kind": action.kind,
		"source": _stable_ref(action.source),
		"target": _stable_ref(action.target),
		"card_id": str(payload.get("card_id", "")),
		"attack_index": int(payload.get(
			"attack_index", payload.get("attack_idx", -1))),
		"ability_name": str(payload.get("ability_name", "")),
		"target_index": int(payload.get(
			"target_index", payload.get("bench_index", -1))),
		"payload": payload.duplicate(true),
	}
	return stable_variant_signature(stable)


static func action_purpose_bucket(action: GameAction) -> String:
	if action == null:
		return ""
	match action.kind:
		"DECLARE_ATTACK":
			return "terminal:attack"
		"END_TURN", "SETUP_DONE":
			return "terminal:end"
		"EVOLVE":
			return "development:evolve"
		"ATTACH_ENERGY":
			return "development:energy"
		"PLAY_BASIC":
			return "development:bench"
		"RETREAT", "PROMOTE":
			return "position:switch"
		"USE_ABILITY":
			return "effect:ability"
		"PLAY_TRAINER":
			return "effect:trainer"
		"USE_STADIUM":
			return "effect:stadium"
		_:
			return "other:%s" % action.kind


static func sequence_signature(sequence_value: Variant) -> String:
	var parts: Array[String] = []
	for action_value in sequence_value:
		if action_value is GameAction:
			parts.append(action_signature(action_value))
	return "|".join(parts)


static func board_score(player: PlayerState, catalog: CardCatalog) -> float:
	var score := 0.0
	if player == null or catalog == null:
		return score
	for row in player.get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon == null:
			continue
		var remaining_hp := pokemon.current_hp(catalog)
		var is_active := str(row["slot"]) == "active"
		var slot_weight := 1.2 if is_active else 1.0
		var profile := public_attack_profile(pokemon, catalog)
		score += float(remaining_hp) * 0.35 * slot_weight
		score += float(profile["useful_units"]) * 12.0
		score -= float(profile["stranded_units"]) * 7.0
		score += float(pokemon.evolution_stack_ids.size()) * EVOLUTION_ASSET_VALUE
		var missing := int(profile["minimum_missing"])
		var preparation_factor := 0.0
		if missing == 0:
			preparation_factor = 1.0
		elif missing == 1:
			preparation_factor = 0.55
		elif missing == 2:
			preparation_factor = 0.20
		score += preparation_factor * (26.0 if is_active else 14.0)
		if is_active:
			score += (
				45.0
				* float(profile["ready_ratio"])
				* float(profile["gate_probability"])
			)
		score += float(catalog.prize_value(pokemon.card_id)) * 2.0
	return score


static func turn_commitment_score(player: PlayerState) -> float:
	if player == null:
		return 0.0
	# A retreat spends attached Energy and the only manual retreat for the turn.
	# The board score already observes the discarded Energy; this term captures
	# the additional tempo/option cost so a cosmetic active-slot improvement
	# cannot beat an otherwise equivalent development line.
	return -RETREAT_TEMPO_COST if player.retreated_this_turn else 0.0


static func public_attack_profile(
	pokemon: PokemonState,
	catalog: CardCatalog,
) -> Dictionary:
	var result := {
		"available_units": 0,
		"useful_units": 0,
		"stranded_units": 0,
		"eligible_attacks": 0,
		"ready_attacks": 0,
		"ready_ratio": 0.0,
		"minimum_missing": 99,
		"gate_probability": 1.0,
	}
	if pokemon == null or catalog == null:
		return result
	var available: Array[String] = []
	available.assign(pokemon.available_energy(catalog))
	result["available_units"] = available.size()
	var attacks: Array = catalog.get_card(pokemon.card_id).get("attacks", [])
	var useful_units := 0
	var eligible_attacks := 0
	var ready_attacks := 0
	var minimum_missing := 99
	for attack_value in attacks:
		if not attack_value is Dictionary:
			continue
		var attack: Dictionary = attack_value
		var cost: Array = attack.get("cost", [])
		var missing := _missing_energy_units(available, cost)
		useful_units = maxi(useful_units, maxi(0, cost.size() - missing))
		var attack_name := str(attack.get("name", ""))
		if pokemon.attack_is_locked(attack_name):
			continue
		eligible_attacks += 1
		minimum_missing = mini(minimum_missing, missing)
		if missing == 0:
			ready_attacks += 1
	result["useful_units"] = useful_units
	result["stranded_units"] = maxi(0, available.size() - useful_units)
	result["eligible_attacks"] = eligible_attacks
	result["ready_attacks"] = ready_attacks
	result["minimum_missing"] = minimum_missing
	result["ready_ratio"] = (
		float(ready_attacks) / float(eligible_attacks)
		if eligible_attacks > 0
		else 0.0
	)
	var gate_probability := 1.0
	if "ASLEEP" in pokemon.status_conditions or "PARALYZED" in pokemon.status_conditions:
		gate_probability = 0.0
	else:
		if "CONFUSED" in pokemon.status_conditions:
			gate_probability *= 0.5
		if pokemon.has_attack_gate("dazzled"):
			gate_probability *= 0.5
	result["gate_probability"] = gate_probability
	return result


static func semantic_context_for_action(
	action: GameAction,
	semantic_catalog: CardSemanticCatalog,
) -> Dictionary:
	var ids: Array[String] = []
	for ref_value in [action.source, action.target]:
		var ref: EntityRef = ref_value
		if ref != null and not ref.card_id.is_empty() and ref.card_id not in ids:
			ids.append(ref.card_id)
	return _semantic_context(ids, semantic_catalog)


static func semantic_context_for_choice(
	request: ChoiceView,
	semantic_catalog: CardSemanticCatalog,
) -> Dictionary:
	var ids: Array[String] = []
	for option_value in request.options:
		if not option_value is Dictionary:
			continue
		var ref_value: Variant = Dictionary(option_value).get("ref")
		if not ref_value is Dictionary:
			continue
		var card_id := str(Dictionary(ref_value).get("card_id", ""))
		if not card_id.is_empty() and card_id not in ids:
			ids.append(card_id)
	return _semantic_context(ids, semantic_catalog)


static func semantic_context_for_view(
	view: Dictionary,
	semantic_catalog: CardSemanticCatalog,
) -> Dictionary:
	var ids: Array[String] = []
	var stadium_id := str(view.get("stadium_card_id", ""))
	if not stadium_id.is_empty():
		ids.append(stadium_id)
	for player_value in view.get("players", []):
		if not player_value is Dictionary:
			continue
		var player: Dictionary = player_value
		for zone in ["hand", "discard"]:
			for card_id_value in player.get(zone, []):
				var card_id := str(card_id_value)
				if not card_id.begins_with("__ai_hidden_") and card_id not in ids:
					ids.append(card_id)
		_append_visible_pokemon_ids(ids, player.get("active"))
		for pokemon_value in player.get("bench", []):
			_append_visible_pokemon_ids(ids, pokemon_value)
	return _semantic_context(ids, semantic_catalog)


static func stable_variant_signature(value: Variant) -> String:
	if value is Dictionary:
		var dictionary: Dictionary = value
		var keys: Array[String] = []
		for key_value in dictionary:
			keys.append(str(key_value))
		keys.sort()
		var parts: Array[String] = []
		for key in keys:
			parts.append("%s=%s" % [key, stable_variant_signature(dictionary[key])])
		return "{%s}" % ",".join(parts)
	if value is Array:
		var parts: Array[String] = []
		for item in value:
			parts.append(stable_variant_signature(item))
		return "[%s]" % ",".join(parts)
	return JSON.stringify(value)


static func _default_action_priority(
	action: GameAction,
	semantic_catalog: CardSemanticCatalog,
) -> float:
	match action.kind:
		"DECLARE_ATTACK":
			var card_id := action.source.card_id if action.source != null else ""
			var attack_index := int(action.payload.get("attack_index", -1))
			var attack := semantic_catalog.attack_semantics(card_id, attack_index)
			return 500.0 + float(attack.get("expected_damage", 0.0))
		"USE_ABILITY":
			return 420.0
		"PLAY_TRAINER":
			return 360.0
		"EVOLVE":
			return 320.0
		"ATTACH_ENERGY":
			return 280.0
		"PLAY_BASIC":
			return 220.0
		"USE_STADIUM":
			return 180.0
		"RETREAT", "PROMOTE":
			return 140.0
		"SETUP_DONE":
			return 40.0
		"END_TURN":
			return -100.0
		_:
			return 0.0


static func _missing_energy_units(
	available_input: Array[String],
	cost: Array,
) -> int:
	var available: Array[String] = []
	available.assign(available_input)
	var missing := 0
	var colorless := 0
	for required_value in cost:
		var required := str(required_value)
		if required == "Colorless":
			colorless += 1
			continue
		var index := available.find(required)
		if index < 0:
			index = available.find("Rainbow")
		if index >= 0:
			available.remove_at(index)
		else:
			missing += 1
	return missing + maxi(0, colorless - available.size())


static func _stable_ref(ref: EntityRef) -> Dictionary:
	if ref == null:
		return {}
	var result := {"kind": ref.kind, "player": ref.player}
	for field in ["zone", "slot", "attachment_type", "card_id"]:
		var value := str(ref.get(field))
		if not value.is_empty():
			result[field] = value
	return result


static func _protected_replacement_index(rows: Array[Dictionary]) -> int:
	if rows.is_empty():
		return 0
	var purpose_counts: Dictionary = {}
	for row in rows:
		var action: GameAction = row.get("action")
		var purpose := str(row.get(
			"purpose_bucket", action_purpose_bucket(action)))
		purpose_counts[purpose] = int(purpose_counts.get(purpose, 0)) + 1
	for index in range(rows.size() - 1, -1, -1):
		var row: Dictionary = rows[index]
		var action: GameAction = row.get("action")
		var purpose := str(row.get(
			"purpose_bucket", action_purpose_bucket(action)))
		if int(purpose_counts.get(purpose, 0)) > 1:
			return index
	for index in range(rows.size() - 1, -1, -1):
		var action: GameAction = rows[index].get("action")
		if action == null or not action.terminal:
			return index
	return rows.size() - 1


static func _best_unrepresented_target_variant(
	ranked: Array[Dictionary],
	selected: Array[Dictionary],
) -> Dictionary:
	var target_sensitive_purposes := {
		"development:evolve": true,
		"development:energy": true,
		"development:bench": true,
		"position:switch": true,
		"effect:ability": true,
		"effect:trainer": true,
	}
	var selected_signatures: Dictionary = {}
	var selected_buckets_by_purpose: Dictionary = {}
	for row in selected:
		var action: GameAction = row.get("action")
		var signature := str(row.get("signature", action_signature(action)))
		var purpose := str(row.get(
			"purpose_bucket", action_purpose_bucket(action)))
		var bucket := str(row.get("bucket", semantic_bucket(action)))
		selected_signatures[signature] = true
		var buckets: Dictionary = selected_buckets_by_purpose.get(purpose, {})
		buckets[bucket] = true
		selected_buckets_by_purpose[purpose] = buckets
	for row_value in ranked:
		var row: Dictionary = row_value
		var action: GameAction = row.get("action")
		var purpose := str(row.get(
			"purpose_bucket", action_purpose_bucket(action)))
		if not target_sensitive_purposes.has(purpose):
			continue
		var signature := str(row.get("signature", action_signature(action)))
		if selected_signatures.has(signature):
			continue
		var bucket := str(row.get("bucket", semantic_bucket(action)))
		var represented: Dictionary = selected_buckets_by_purpose.get(
			purpose, {})
		if not represented.is_empty() and not represented.has(bucket):
			return row
	return {}


static func _target_variant_replacement_index(
	rows: Array[Dictionary],
	protected_purpose: String,
) -> int:
	var result := -1
	var lowest_score := WIN_SCORE_MILLI
	var lowest_signature := ""
	for index in range(rows.size()):
		var row: Dictionary = rows[index]
		var action: GameAction = row.get("action")
		if (
			action == null
			or action.terminal
			or str(row.get(
				"purpose_bucket", action_purpose_bucket(action)))
			== protected_purpose
		):
			continue
		var score := int(row.get("score_milli", -WIN_SCORE_MILLI))
		var signature := str(row.get("signature", action_signature(action)))
		if (
			result < 0
			or score < lowest_score
			or (score == lowest_score and signature > lowest_signature)
		):
			result = index
			lowest_score = score
			lowest_signature = signature
	return result


static func _semantic_context(
	card_ids: Array[String],
	semantic_catalog: CardSemanticCatalog,
) -> Dictionary:
	var cards: Dictionary = {}
	for card_id in card_ids:
		cards[card_id] = semantic_catalog.semantics_for(card_id)
	var result := {"cards": cards}
	_deep_make_read_only(result)
	return result


static func _append_visible_pokemon_ids(ids: Array[String], value: Variant) -> void:
	if not value is Dictionary:
		return
	var pokemon: Dictionary = value
	for field in ["card_id", "attached_tool_id"]:
		var card_id := str(pokemon.get(field, ""))
		if not card_id.is_empty() and card_id not in ids:
			ids.append(card_id)
	for field in ["evolution_stack_ids", "energy_card_ids"]:
		for card_id_value in pokemon.get(field, []):
			var card_id := str(card_id_value)
			if not card_id.is_empty() and card_id not in ids:
				ids.append(card_id)


static func _strategy_call(
	strategy: Variant,
	method: String,
	args: Array,
	fallback: Variant,
) -> Variant:
	if strategy is Dictionary:
		var callable_value: Variant = Dictionary(strategy).get(method)
		if callable_value is Callable and Callable(callable_value).is_valid():
			return Callable(callable_value).callv(args)
	elif typeof(strategy) == TYPE_OBJECT and strategy != null and strategy.has_method(method):
		return strategy.callv(method, args)
	return fallback


static func _read_only_copy(value: Variant) -> Variant:
	var result: Variant = value.duplicate(true) if value is Dictionary or value is Array else value
	_deep_make_read_only(result)
	return result


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


static func _quantize(value: float) -> int:
	return roundi(value * float(SCORE_SCALE))


static func _is_finite_number(value: Variant) -> bool:
	return (
		(value is float or value is int)
		and is_finite(float(value))
	)


static func _is_cancelled(cancel_check: Callable) -> bool:
	return cancel_check.is_valid() and bool(cancel_check.call())
