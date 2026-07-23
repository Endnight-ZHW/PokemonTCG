class_name AIMandatoryTactics
extends RefCounted

## Sound, bounded decisions that should bypass general search.
##
## Deck strategies may nominate a mandatory action, but it is accepted only if
## it is one of the supplied legal actions. Built-in match wins and survival
## development take precedence over deck-specific nominations.

const IMMINENT_LETHAL_MIN_PROBABILITY := 0.65
const MIN_TACTICAL_ATTACK_SCAN := 3
const SURVIVAL_BACKUP_SCORE_EPSILON := 0.001


func resolve(
	information_set: AIInformationSet,
	state: GameState,
	actor: int,
	actions: Array[GameAction],
	engine: GameEngine,
	strategy: Variant = null,
	seed: int = 1,
	cancel_check: Callable = Callable(),
	deadline_usec: int = 0,
	node_budget: int = 192,
	trusted_choice_resolver: Callable = Callable(),
	trusted_action_evaluator: Callable = Callable(),
) -> Dictionary:
	if (
		information_set == null
		or not information_set.is_valid()
		or state == null
		or engine == null
		or actor not in [0, 1]
	):
		return _unresolved("invalid_input", 0)
	if _is_cancelled(cancel_check):
		return _unresolved("cancelled", 0)
	if _deadline_reached(deadline_usec):
		return _unresolved("deadline", 0)
	if actions.is_empty():
		return _unresolved("no_legal_actions", 0)
	if actions.size() == 1:
		return _resolved(actions[0], "only_legal_action", 0)
	var backup_action := survival_backup_action(
		state,
		actor,
		actions,
		information_set,
		strategy,
		engine.catalog,
		trusted_action_evaluator,
	)
	var expanded := 0
	var forced_knockout: GameAction = null
	var semantic_catalog := CardSemanticCatalog.new(engine.catalog)
	var deterministic_attack_count := 0
	for candidate in actions:
		if candidate == null or candidate.kind != "DECLARE_ATTACK":
			continue
		var candidate_card_id := (
			candidate.source.card_id if candidate.source != null else "")
		var candidate_attack_index := int(candidate.payload.get(
			"attack_index", candidate.payload.get("attack_idx", -1)))
		if not bool(semantic_catalog.attack_semantics(
			candidate_card_id, candidate_attack_index).get(
				"has_random_effect", false)):
			deterministic_attack_count += 1
	# The search node budget may fall to one on a local/exhausted replan.  A
	# normal Pokemon can still expose two attacks, so reserve a tiny tactical
	# scan floor: otherwise legal-action order could hide a deterministic KO in
	# the second slot.  The caller continues to clamp reported search nodes, and
	# the hard deadline remains authoritative.
	var tactical_attack_scan_budget := maxi(0, node_budget)
	if tactical_attack_scan_budget > 0:
		tactical_attack_scan_budget = maxi(
			tactical_attack_scan_budget,
			mini(MIN_TACTICAL_ATTACK_SCAN, deterministic_attack_count),
		)
	for index in range(actions.size()):
		if _is_cancelled(cancel_check):
			return _unresolved("cancelled", expanded)
		if _deadline_reached(deadline_usec):
			return (
				_resolved(backup_action, "establish_only_backup", expanded)
				if backup_action != null
				else _resolved(forced_knockout, "immediate_knockout", expanded)
				if forced_knockout != null
				else _unresolved("deadline", expanded)
			)
		var action := actions[index]
		if action.kind != "DECLARE_ATTACK":
			continue
		# A sampled favourable coin result is not a provable forced win. Random
		# attacks stay in the bounded belief search instead of bypassing it.
		var card_id := action.source.card_id if action.source != null else ""
		var attack_index := int(action.payload.get("attack_index", -1))
		if bool(semantic_catalog.attack_semantics(
			card_id, attack_index).get("has_random_effect", false)):
			continue
		if expanded >= tactical_attack_scan_budget:
			return (
				_resolved(backup_action, "establish_only_backup", expanded)
				if backup_action != null
				else _resolved(forced_knockout, "immediate_knockout", expanded)
				if forced_knockout != null
				else _unresolved("node_budget", expanded)
			)
		expanded += 1
		var simulation := state.clone_state()
		simulation.set_type_matchups_enabled(false)
		var rng := PortableRandomSource.new(seed + index * 104729)
		var step := engine.apply_action(simulation, action, rng)
		if not step.success:
			continue
		if not _resolve_choices(
			simulation, actor, engine, strategy, rng, cancel_check, deadline_usec,
			information_set.match_seed(), trusted_choice_resolver):
			continue
		if simulation.is_terminal():
			if simulation.winner == actor:
				return _resolved(action, "immediate_match_win", expanded)
			# A simultaneous knockout can be a draw or even a loss. It must never
			# be promoted to the ordinary active-KO shortcut below.
			continue
		# Prize change remains observable after the defeated Active has already
		# been replaced from the Bench. Checking the Active slot here would miss
		# that settled knockout because choice resolution also promotes it.
		if (
			simulation.get_player(actor).prizes.size()
			< state.get_player(actor).prizes.size()
		):
			forced_knockout = action
	# With exactly one Pokemon in play, adding any legal Basic to the Bench is
	# a non-terminal action and leaves the attack available for the subsequent
	# replan. Immediate wins above retain priority; ordinary KOs do not bypass
	# this survival development step.
	if backup_action != null:
		return _resolved(backup_action, "establish_only_backup", expanded)
	if forced_knockout != null:
		var safe_development := safe_pre_knockout_development_action(
			information_set,
			state,
			actor,
			actions,
			forced_knockout,
			engine,
			strategy,
			seed + 600013,
			cancel_check,
			deadline_usec,
			maxi(0, node_budget - expanded),
			trusted_choice_resolver,
			trusted_action_evaluator,
		)
		expanded += mini(
			maxi(0, node_budget - expanded),
			maxi(0, int(safe_development.get("nodes_expanded", 0))),
		)
		var development_action: GameAction = safe_development.get("action")
		if development_action != null:
			return _resolved(
				development_action,
				"safe_development_before_knockout",
				expanded,
			)
		return _resolved(forced_knockout, "immediate_knockout", expanded)
	var backup_draw := seek_only_backup_out_action(
		information_set, state, actor, actions, engine)
	if backup_draw != null:
		return _resolved(backup_draw, "seek_only_backup_out", expanded)
	var nominated: Variant = _strategy_call(
		strategy,
		"mandatory_action",
		[
			information_set.read_only_view(),
			information_set.legal_action_summaries(),
			_semantic_context_for_actions(actions, engine.catalog),
		],
		null,
	)
	if _is_cancelled(cancel_check):
		return _unresolved("cancelled", expanded)
	var nominated_action := _coerce_action(nominated)
	if nominated_action != null:
		var legal_nomination := _find_legal_equivalent(nominated_action, actions)
		if legal_nomination != null:
			return _resolved(legal_nomination, "strategy_mandatory", expanded)
	return _unresolved("search_required", expanded)


static func survival_backup_action(
	state: GameState,
	actor: int,
	actions: Array[GameAction],
	information_set: AIInformationSet = null,
	strategy: Variant = null,
	catalog: CardCatalog = null,
	trusted_action_evaluator: Callable = Callable(),
) -> GameAction:
	if state == null or actor not in [0, 1]:
		return null
	var player := state.get_player(actor)
	if player.active == null or player.bench_count() != 0:
		return null
	var selected: GameAction = null
	var selected_score := -INF
	var selected_key := ""
	for action in actions:
		if not is_survival_backup_action(state, actor, action):
			continue
		var score := _survival_backup_action_score(
			state,
			actor,
			action,
			information_set,
			strategy,
			catalog,
			trusted_action_evaluator,
		)
		var key := _survival_backup_semantic_key(action)
		var score_delta := score - selected_score
		if (
			selected == null
			or score_delta > SURVIVAL_BACKUP_SCORE_EPSILON
			or (
				absf(score_delta) <= SURVIVAL_BACKUP_SCORE_EPSILON
				and key < selected_key
			)
		):
			selected = action
			selected_score = score
			selected_key = key
	return selected


static func is_survival_backup_action(
	state: GameState,
	actor: int,
	action: GameAction,
) -> bool:
	if state == null or action == null or actor not in [0, 1]:
		return false
	var player := state.get_player(actor)
	return (
		player.active != null
		and player.bench_count() == 0
		and action.actor == actor
		and action.kind == "PLAY_BASIC"
		and action.target != null
		and action.target.slot.begins_with("bench_")
	)


static func _survival_backup_action_score(
	state: GameState,
	actor: int,
	action: GameAction,
	information_set: AIInformationSet,
	strategy: Variant,
	catalog: CardCatalog,
	trusted_action_evaluator: Callable,
) -> float:
	var score := 0.0
	if trusted_action_evaluator.is_valid():
		var trusted_value: Variant = trusted_action_evaluator.call(
			state, actor, action)
		if trusted_value is int or trusted_value is float:
			var trusted_score := float(trusted_value)
			if not is_nan(trusted_score) and not is_inf(trusted_score):
				score += trusted_score
	if (
		information_set != null
		and information_set.is_valid()
		and strategy != null
		and catalog != null
	):
		var action_row: Dictionary = action.to_dict()
		_deep_make_read_only(action_row)
		var semantic_actions: Array[GameAction] = [action]
		var strategy_value: Variant = _strategy_call(
			strategy,
			"action_score",
			[
				information_set.read_only_view(),
				action_row,
				_semantic_context_for_actions(semantic_actions, catalog),
			],
			0.0,
		)
		if strategy_value is int or strategy_value is float:
			var strategy_score := float(strategy_value)
			if not is_nan(strategy_score) and not is_inf(strategy_score):
				score += strategy_score
	return score


static func _survival_backup_semantic_key(action: GameAction) -> String:
	if action == null:
		return ""
	var card_id := action.source.card_id if action.source != null else ""
	var target_slot := action.target.slot if action.target != null else ""
	var stable_payload := action.payload.duplicate(true)
	# Hand position is presentation state, not a deck-strategy preference. Two
	# otherwise identical opening hands must choose the same backup card even if
	# the authoritative hand indices are permuted.
	stable_payload.erase("hand_idx")
	stable_payload.erase("hand_index")
	return "%s|%s|%s" % [
		card_id,
		target_slot,
		JSON.stringify(stable_payload),
	]


static func safe_pre_knockout_development_action(
	information_set: AIInformationSet,
	state: GameState,
	actor: int,
	actions: Array[GameAction],
	forced_knockout: GameAction,
	engine: GameEngine,
	strategy: Variant = null,
	seed: int = 1,
	cancel_check: Callable = Callable(),
	deadline_usec: int = 0,
	node_budget: int = 0,
	trusted_choice_resolver: Callable = Callable(),
	trusted_action_evaluator: Callable = Callable(),
) -> Dictionary:
	# Only a Bench evolution is treated as monotonic pre-attack development. It
	# spends no Energy/supporter/retreat resource, and the simulation below must
	# prove that the exact same deterministic Active knockout remains legal. Any
	# evolution that opens a Choice is left to the beam so hidden/card-order
	# outcomes can never be smuggled into this mandatory rule.
	if (
		information_set == null
		or not information_set.is_valid()
		or state == null
		or engine == null
		or forced_knockout == null
		or forced_knockout.kind != "DECLARE_ATTACK"
		or node_budget < 2
	):
		return {"action": null, "nodes_expanded": 0}
	var candidates: Array[Dictionary] = []
	var public_view := information_set.read_only_view()
	for action in actions:
		if (
			action == null
			or action.actor != actor
			or action.kind != "EVOLVE"
			or action.source == null
			or action.target == null
			or not action.target.slot.begins_with("bench_")
		):
			continue
		if _card_has_on_enter_play_effect(action.source.card_id, engine.catalog):
			continue
		var action_row: Dictionary = action.to_dict()
		_deep_make_read_only(action_row)
		var semantic_actions: Array[GameAction] = [action]
		var strategy_score_value: Variant = _strategy_call(
			strategy,
			"action_score",
			[
				public_view,
				action_row,
				_semantic_context_for_actions(semantic_actions, engine.catalog),
			],
			0.0,
		)
		var strategy_score := (
			float(strategy_score_value)
			if strategy_score_value is int or strategy_score_value is float
			else 0.0
		)
		var trusted_score := 0.0
		if trusted_action_evaluator.is_valid():
			var trusted_value: Variant = trusted_action_evaluator.call(
				state, actor, action)
			if trusted_value is int or trusted_value is float:
				trusted_score = float(trusted_value)
				if is_nan(trusted_score) or is_inf(trusted_score):
					trusted_score = 0.0
		candidates.append({
			"action": action,
			"score": strategy_score + trusted_score,
			"key": _action_signature(action),
		})
	candidates.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		if is_equal_approx(float(left["score"]), float(right["score"])):
			return str(left["key"]) < str(right["key"])
		return float(left["score"]) > float(right["score"])
	)
	var expanded := 0
	for candidate_index in range(candidates.size()):
		if (
			_is_cancelled(cancel_check)
			or _deadline_reached(deadline_usec)
			or expanded + 2 > node_budget
		):
			break
		var candidate: GameAction = candidates[candidate_index]["action"]
		var simulation := state.clone_state()
		simulation.set_type_matchups_enabled(false)
		var rng := PortableRandomSource.new(seed + candidate_index * 104729)
		expanded += 1
		var development_step := engine.apply_action(simulation, candidate, rng)
		if not development_step.success or simulation.is_terminal():
			continue
		if _step_has_hidden_or_random_event(development_step):
			continue
		# A pending on-evolve decision is not a free deterministic action and may
		# depend on information that the strategy is not allowed to inspect.
		if (
			engine.query_pending_choice(simulation, 0) != null
			or engine.query_pending_choice(simulation, 1) != null
		):
			continue
		var followup_query := engine.query_legal_action_groups(simulation, actor)
		if not followup_query.success:
			continue
		var followup_actions: Array[GameAction] = []
		followup_actions.assign(followup_query.concrete_actions())
		var followup_attack := _find_legal_equivalent(
			forced_knockout, followup_actions)
		if followup_attack == null:
			continue
		var prizes_before := simulation.get_player(actor).prizes.size()
		expanded += 1
		var attack_step := engine.apply_action(simulation, followup_attack, rng)
		if not attack_step.success:
			continue
		if not _resolve_choices(
			simulation,
			actor,
			engine,
			strategy,
			rng,
			cancel_check,
			deadline_usec,
			information_set.match_seed(),
			trusted_choice_resolver,
		):
			continue
		if (
			(simulation.is_terminal() and simulation.winner == actor)
			or (
				not simulation.is_terminal()
				and simulation.get_player(actor).prizes.size() < prizes_before
			)
		):
			return {"action": candidate, "nodes_expanded": expanded}
	return {"action": null, "nodes_expanded": expanded}


static func seek_only_backup_out_action(
	information_set: AIInformationSet,
	state: GameState,
	actor: int,
	actions: Array[GameAction],
	engine: GameEngine,
) -> GameAction:
	# This emergency route uses only the published deck multiset and public board
	# threat. It deliberately never samples the real/derived deck order: the
	# probability is the exact hypergeometric chance that a legal draw action
	# finds at least one Basic from the unknown deck+Prize partition.
	if (
		information_set == null
		or not information_set.is_valid()
		or state == null
		or engine == null
		or actor not in [0, 1]
	):
		return null
	var player := state.get_player(actor)
	if player.active == null or player.bench_count() != 0:
		return null
	if survival_backup_action(state, actor, actions) != null:
		return null
	var semantic_catalog := CardSemanticCatalog.new(engine.catalog)
	var lethal_probability := _public_imminent_lethal_attack_probability(
		information_set, state, actor, engine.catalog, semantic_catalog)
	if lethal_probability < IMMINENT_LETHAL_MIN_PROBABILITY:
		return null
	if _has_deterministic_defense_action(
		state, actor, actions, engine.catalog, semantic_catalog):
		return null
	var hidden_counts := information_set.hidden_zone_counts(actor)
	var deck_count := int(hidden_counts.get("deck", 0))
	var prize_count := int(hidden_counts.get("prizes", 0))
	if deck_count <= 0:
		return null
	var pool := information_set.inferred_hidden_pool_for_perspective()
	# A malformed/partial custom list must fail closed rather than silently use a
	# probability from cards that are not actually represented by hidden zones.
	if pool.size() != deck_count + prize_count:
		return null
	var basic_count := 0
	for card_id in pool:
		if engine.catalog.is_basic_pokemon(card_id):
			basic_count += 1
	if basic_count <= 0:
		return null
	var best: GameAction = null
	var best_probability := 0.0
	var best_discards_hand := true
	var best_key := ""
	for action in actions:
		if (
			action == null
			or action.actor != actor
			or action.kind != "PLAY_TRAINER"
			or action.source == null
			or action.source.zone != "hand"
		):
			continue
		var draw_profile := _deterministic_draw_profile(
			action.source.card_id, semantic_catalog)
		if draw_profile.is_empty():
			continue
		var draw_count := mini(
			deck_count, maxi(0, int(draw_profile.get("draw_count", 0))))
		if draw_count <= 0 or deck_count < int(draw_profile.get("draw_count", 0)):
			continue
		var probability := _at_least_one_success_probability(
			pool.size(), basic_count, draw_count)
		if probability <= 0.0:
			continue
		var discards_hand := bool(draw_profile.get("discards_hand", false))
		var key := _action_signature(action)
		if (
			best == null
			or probability > best_probability + 0.000001
			or (
				is_equal_approx(probability, best_probability)
				and best_discards_hand
				and not discards_hand
			)
			or (
				is_equal_approx(probability, best_probability)
				and discards_hand == best_discards_hand
				and key < best_key
			)
		):
			best = action
			best_probability = probability
			best_discards_hand = discards_hand
			best_key = key
	return best


static func _public_imminent_lethal_attack_probability(
	information_set: AIInformationSet,
	state: GameState,
	actor: int,
	catalog: CardCatalog,
	semantic_catalog: CardSemanticCatalog,
) -> float:
	var defender := state.get_player(actor).active
	var attacker := state.get_player(1 - actor).active
	if defender == null or attacker == null or defender.prevents_damage():
		return 0.0
	if (
		"ASLEEP" in attacker.status_conditions
		or "PARALYZED" in attacker.status_conditions
		or "CONFUSED" in attacker.status_conditions
		or attacker.has_modifier_operation("attack_gate_coin")
	):
		return 0.0
	var attacks: Array = catalog.get_card(attacker.card_id).get("attacks", [])
	var deterministic_attacks: Array[Dictionary] = []
	for attack_index in range(attacks.size()):
		var attack: Dictionary = attacks[attack_index]
		var attack_name := str(attack.get("name", ""))
		if attacker.attack_is_locked(attack_name):
			continue
		var semantics := semantic_catalog.attack_semantics(
			attacker.card_id, attack_index)
		if (
			semantics.is_empty()
			or bool(semantics.get("has_random_effect", false))
			or _attack_commands_can_invalidate_base_damage(
				semantics.get("commands", []))
		):
			continue
		var damage := int(semantics.get("base_damage", attack.get("damage", 0)))
		if damage <= 0:
			continue
		deterministic_attacks.append({"attack": attack, "base_damage": damage})
		if (
			attacker.has_enough_energy(attack.get("cost", []), catalog)
			and _damage_after_public_modifiers(
				state, actor, attacker, defender, damage, catalog)
			>= defender.current_hp(catalog)
		):
			return 1.0
	if deterministic_attacks.is_empty():
		return 0.0

	# If the attack is one ordinary attachment away, estimate that attachment
	# from the opponent's published deck multiset. Opponent hand identities and
	# the real top card remain hidden: hand plus next draw is a hypergeometric
	# sample from the public unknown hand/deck/Prize partition.
	var opponent_idx := 1 - actor
	var deck_key := (
		str(state.public_deck_keys[opponent_idx])
		if opponent_idx < state.public_deck_keys.size()
		else ""
	)
	if catalog.expand_deck(deck_key).is_empty():
		return 0.0
	var hidden_counts := information_set.hidden_zone_counts(opponent_idx)
	var hand_count := int(hidden_counts.get("hand", 0))
	var deck_count := int(hidden_counts.get("deck", 0))
	var prize_count := int(hidden_counts.get("prizes", 0))
	if deck_count <= 0:
		return 0.0
	var pool := information_set.inferred_hidden_pool_for_player(opponent_idx)
	if pool.size() != hand_count + deck_count + prize_count:
		return 0.0
	var lethal_energy_count := 0
	for card_id_value in pool:
		var energy_card_id := str(card_id_value)
		if not catalog.is_energy(energy_card_id):
			continue
		var future_attacker := attacker.clone_state()
		future_attacker.energy_card_ids.append(energy_card_id)
		var enables_lethal := false
		for attack_row in deterministic_attacks:
			var attack: Dictionary = attack_row["attack"]
			if not future_attacker.has_enough_energy(
				attack.get("cost", []), catalog):
				continue
			if (
				_damage_after_public_modifiers(
					state,
					actor,
					future_attacker,
					defender,
					int(attack_row["base_damage"]),
					catalog,
				)
				>= defender.current_hp(catalog)
			):
				enables_lethal = true
				break
		if enables_lethal:
			lethal_energy_count += 1
	var observed_by_next_turn := mini(pool.size(), hand_count + 1)
	return _at_least_one_success_probability(
		pool.size(), lethal_energy_count, observed_by_next_turn)


static func _damage_after_public_modifiers(
	state: GameState,
	defending_actor: int,
	attacker: PokemonState,
	defender: PokemonState,
	base_damage: int,
	catalog: CardCatalog,
) -> int:
	var context := {
		"actor": 1 - defending_actor,
		"attacker_slot": "active",
		"attacker": attacker,
		"defender": defender,
		"target_player": defending_actor,
		"target_slot": "active",
		"damage": base_damage,
		"ignore_weakness": true,
		"ignore_resistance": true,
		"modifier_phase": "attacker",
	}
	var damage := VMDamageModifierHooks.apply_modify_damage(
		state, catalog, context)
	context["damage"] = damage
	context["modifier_phase"] = "defender"
	return VMDamageModifierHooks.apply_modify_damage(state, catalog, context)


static func _attack_commands_can_invalidate_base_damage(commands: Array) -> bool:
	for command_value in commands:
		if not command_value is Dictionary:
			continue
		var command: Dictionary = command_value
		var op := str(command.get("op", ""))
		var semantic_kind := str(command.get("semantic_kind", ""))
		if (
			bool(command.get("replaces_base_damage", false))
			or op in ["mill_then_damage", "place_counters_then_self_discard"]
			or semantic_kind in [
				"mill_and_damage_per_energy", "place_counters_and_self_discard",
			]
		):
			return true
		for branch_value in Dictionary(command.get("branches", {})).values():
			if branch_value is Array and _attack_commands_can_invalidate_base_damage(
				branch_value):
				return true
	return false


static func _has_deterministic_defense_action(
	_state: GameState,
	actor: int,
	actions: Array[GameAction],
	catalog: CardCatalog,
	semantic_catalog: CardSemanticCatalog,
) -> bool:
	for action in actions:
		if action == null or action.actor != actor:
			continue
		if (
			action.kind == "EVOLVE"
			and action.target != null
			and action.target.slot == "active"
		):
			return true
		var commands: Array = []
		if action.kind == "DECLARE_ATTACK":
			var attack_semantics := semantic_catalog.attack_semantics(
				action.source.card_id if action.source != null else "",
				int(action.payload.get("attack_index", -1)),
			)
			if bool(attack_semantics.get("has_random_effect", false)):
				continue
			commands = attack_semantics.get("commands", [])
		elif action.kind == "PLAY_TRAINER" and action.source != null:
			commands = semantic_catalog.semantics_for(
				action.source.card_id).get("trainer_commands", [])
		elif action.kind == "USE_ABILITY" and action.source != null:
			commands = semantic_catalog.ability_semantics(
				action.source.card_id,
				str(action.payload.get("ability_name", "")),
			).get("commands", [])
		if commands.is_empty() or _semantic_commands_have_random_effect(commands):
			continue
		if _semantic_commands_have_defensive_effect(commands):
			return true
	return false


static func _semantic_commands_have_defensive_effect(commands: Array) -> bool:
	const DEFENSIVE_KINDS := [
		"attack_lock_basic",
		"conditional_damage_heal",
		"conditional_status",
		"damage_and_self_heal",
		"heal",
		"heal_all",
		"potion_heal",
		"prevent_all",
		"prevent_damage",
		"prevent_effects",
		"search_any_and_switch",
		"status",
		"switch",
	]
	for command_value in commands:
		if not command_value is Dictionary:
			continue
		var command: Dictionary = command_value
		if str(command.get("semantic_kind", "")) in DEFENSIVE_KINDS:
			return true
		for branch_value in Dictionary(command.get("branches", {})).values():
			if branch_value is Array and _semantic_commands_have_defensive_effect(
				branch_value):
				return true
	return false


static func _semantic_commands_have_random_effect(commands: Array) -> bool:
	for command_value in commands:
		if not command_value is Dictionary:
			continue
		var command: Dictionary = command_value
		var op := str(command.get("op", ""))
		if op.begins_with("flip_coin") or op == "flip_until_tails":
			return true
		for branch_value in Dictionary(command.get("branches", {})).values():
			if branch_value is Array and _semantic_commands_have_random_effect(
				branch_value):
				return true
	return false


static func _deterministic_draw_profile(
	card_id: String,
	semantic_catalog: CardSemanticCatalog,
) -> Dictionary:
	var commands: Array = semantic_catalog.semantics_for(
		card_id).get("trainer_commands", [])
	if commands.size() != 1 or _semantic_commands_have_random_effect(commands):
		return {}
	var command: Dictionary = commands[0]
	if not Dictionary(command.get("branches", {})).is_empty():
		return {}
	var args: Dictionary = command.get("args", {})
	match str(command.get("op", "")):
		"draw_cards":
			return {
				"draw_count": int(args.get("amount", 0)),
				"discards_hand": false,
			}
		"discard_then_draw_cards":
			if not bool(args.get("discard_hand", false)):
				return {}
			return {
				"draw_count": int(args.get("draw", 0)),
				"discards_hand": true,
			}
	return {}


static func _at_least_one_success_probability(
	population_size: int,
	success_count: int,
	draw_count: int,
) -> float:
	if population_size <= 0 or success_count <= 0 or draw_count <= 0:
		return 0.0
	var failure_probability := 1.0
	for index in range(mini(draw_count, population_size)):
		var remaining_population := population_size - index
		var remaining_failures := population_size - success_count - index
		if remaining_failures <= 0:
			return 1.0
		failure_probability *= (
			float(remaining_failures) / float(remaining_population))
	return clampf(1.0 - failure_probability, 0.0, 1.0)


static func _card_has_on_enter_play_effect(
	card_id: String,
	catalog: CardCatalog,
) -> bool:
	if card_id.is_empty() or catalog == null:
		return true
	for ability_value in catalog.get_card(card_id).get("abilities", []):
		var ability: Dictionary = ability_value
		if str(ability.get("trigger", "")) == "on_enter_play":
			return true
	return false


static func _step_has_hidden_or_random_event(step: StepResult) -> bool:
	if step == null:
		return true
	for event_value in step.events:
		var event: Dictionary = event_value
		if str(event.get("event_type", "")) in [
			"cards_drawn",
			"cards_revealed",
			"deck_shuffled",
			"coin_flip",
		]:
			return true
	return false


static func _resolve_choices(
	state: GameState,
	actor: int,
	engine: GameEngine,
	strategy: Variant,
	rng: PortableRandomSource,
	cancel_check: Callable,
	deadline_usec: int,
	match_seed: int,
	trusted_choice_resolver: Callable = Callable(),
) -> bool:
	for _guard in range(24):
		if _is_cancelled(cancel_check):
			return false
		if _deadline_reached(deadline_usec):
			return false
		var request := engine.query_pending_choice(state, 0)
		if request == null:
			request = engine.query_pending_choice(state, 1)
		if request == null:
			return true
		var choice_actor := request.player if request.player in [0, 1] else actor
		var response: ChoiceResponse = null
		if trusted_choice_resolver.is_valid():
			var trusted_response: Variant = trusted_choice_resolver.call(
				state, request, match_seed, cancel_check, deadline_usec)
			if trusted_response is ChoiceResponse:
				response = trusted_response
		if response == null:
			var simulated_information := AIInformationSet.capture(
				state, choice_actor, engine.catalog, [], [], match_seed)
			response = _ranked_choice(
				strategy if choice_actor == actor else null,
				simulated_information.read_only_view() if simulated_information.is_valid() else {},
				request,
				_semantic_context_for_choice(request, engine.catalog),
				engine.catalog,
				cancel_check,
				deadline_usec,
			)
		if not AIChoiceSelector.response_is_shape_legal(
			request, response.option_ids, engine.catalog, response.cancelled):
			return false
		var step := engine.apply_choice_response(state, response, rng)
		if not step.success:
			return false
	return false


static func _ranked_choice(
	strategy: Variant,
	public_view: Dictionary,
	request: ChoiceView,
	semantic_context: Dictionary,
	catalog: CardCatalog,
	cancel_check: Callable = Callable(),
	deadline_usec: int = 0,
) -> ChoiceResponse:
	var choice_row: Dictionary = request.to_dict()
	_deep_make_read_only(choice_row)
	var ranked: Array[Dictionary] = []
	var scored: Dictionary = {}
	for index in range(request.options.size()):
		if _is_cancelled(cancel_check) or _deadline_reached(deadline_usec):
			break
		var option: Dictionary = Dictionary(request.options[index]).duplicate(true)
		_deep_make_read_only(option)
		var score_value: Variant = _strategy_call(
			strategy,
			"choice_score",
			[public_view, choice_row, option, semantic_context],
			0.0,
		)
		var score: float = float(score_value) if score_value is int or score_value is float else 0.0
		ranked.append({"option": option, "score": score, "index": index})
		scored[index] = true
	# Unscored public options remain deterministic zero-score fallbacks so a
	# deadline cannot manufacture an under-minimum response.
	for index in range(request.options.size()):
		if not scored.has(index):
			ranked.append({"option": request.options[index], "score": 0.0, "index": index})
	ranked.sort_custom(_rank_descending)
	return AIChoiceSelector.response_from_ranked_scores(request, ranked, catalog)


static func _rank_descending(left: Dictionary, right: Dictionary) -> bool:
	var left_score := float(left.get("score", 0.0))
	var right_score := float(right.get("score", 0.0))
	if left_score == right_score:
		return int(left.get("index", 0)) < int(right.get("index", 0))
	return left_score > right_score


static func _coerce_action(value: Variant) -> GameAction:
	if value is GameAction:
		return value
	if value is Dictionary:
		if value.get("action") is GameAction:
			return value["action"]
		if value.has("kind"):
			return GameAction.from_dict(value)
	return null


static func _semantic_context_for_actions(
	actions: Array[GameAction],
	catalog: CardCatalog,
) -> Dictionary:
	var ids: Array[String] = []
	for action in actions:
		for ref_value in [action.source, action.target]:
			var ref: EntityRef = ref_value
			if ref != null and not ref.card_id.is_empty() and ref.card_id not in ids:
				ids.append(ref.card_id)
	return _semantic_context(ids, catalog)


static func _semantic_context_for_choice(
	request: ChoiceView,
	catalog: CardCatalog,
) -> Dictionary:
	var ids: Array[String] = []
	for option_value in request.options:
		var option: Dictionary = option_value
		var ref_value: Variant = option.get("ref")
		if ref_value is Dictionary:
			var card_id := str(Dictionary(ref_value).get("card_id", ""))
			if not card_id.is_empty() and card_id not in ids:
				ids.append(card_id)
	return _semantic_context(ids, catalog)


static func _semantic_context(card_ids: Array[String], catalog: CardCatalog) -> Dictionary:
	var semantic_catalog := CardSemanticCatalog.new(catalog)
	var cards: Dictionary = {}
	for card_id in card_ids:
		cards[card_id] = semantic_catalog.semantics_for(card_id)
	var result := {"cards": cards}
	_deep_make_read_only(result)
	return result


static func _find_legal_equivalent(
	candidate: GameAction,
	actions: Array[GameAction],
) -> GameAction:
	var signature := _action_signature(candidate)
	for action in actions:
		if _action_signature(action) == signature:
			return action
	return null


static func _action_signature(action: GameAction) -> String:
	if action == null:
		return ""
	return "%s|%d|%s|%s|%s" % [
		action.kind,
		action.actor,
		JSON.stringify(action.source.to_dict() if action.source else null),
		JSON.stringify(action.target.to_dict() if action.target else null),
		JSON.stringify(action.payload),
	]


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


static func _is_cancelled(cancel_check: Callable) -> bool:
	return cancel_check.is_valid() and bool(cancel_check.call())


static func _deadline_reached(deadline_usec: int) -> bool:
	return deadline_usec > 0 and Time.get_ticks_usec() >= deadline_usec


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


static func _resolved(action: GameAction, reason: String, expanded: int) -> Dictionary:
	return {
		"resolved": true,
		"action": action,
		"reason": reason,
		"nodes_expanded": expanded,
	}


static func _unresolved(reason: String, expanded: int) -> Dictionary:
	return {
		"resolved": false,
		"action": null,
		"reason": reason,
		"nodes_expanded": expanded,
	}
