extends SceneTree

const DEFAULT_DECK_KEYS := [
	"colorless",
	"darkness",
	"dragon",
	"fighting",
	"fire",
	"grass",
	"lightning",
	"psychic",
	"steel",
	"water",
]
const SCHEMA_VERSION := 2
const DEFAULT_SEED_BLOCKS_PER_DECK := 50
const DEFAULT_SEED := 17
const DEFAULT_MAX_ACTIONS := 1200
const BOOTSTRAP_ITERATIONS := 400
const BOOTSTRAP_SEED := 90210

var _had_error := false


func _initialize() -> void:
	var config := _parse_args(OS.get_cmdline_user_args())
	var started_ms := Time.get_ticks_msec()
	var catalog := CardCatalog.new()
	var validation_errors := _validation_errors(catalog)
	if not validation_errors.is_empty():
		for message in validation_errors:
			push_error(message)
		quit(1)
		return

	var payload := _run_evaluation(catalog, config)
	payload["elapsed_ms"] = Time.get_ticks_msec() - started_ms
	if _had_error:
		quit(1)
		return

	var output_path := _output_path(config)
	if not _write_json(output_path, payload):
		quit(1)
		return
	print("AI_EVALUATION_OK ", JSON.stringify({
		"output": output_path,
		"games": int(payload.get("summary", {}).get("games", 0)),
		"decks": payload.get("deck_keys", []),
	}))
	quit(0)


func _parse_args(args: Array[String]) -> Dictionary:
	var config := {
		"strategy_a_path": "",
		"strategy_b_path": "",
		"deck_keys": [],
		"seed_blocks_per_deck": DEFAULT_SEED_BLOCKS_PER_DECK,
		"seed": DEFAULT_SEED,
		"max_actions": DEFAULT_MAX_ACTIONS,
		"eval_preset": "Custom",
		"output": "",
		"output_dir": "",
	}
	var index := 0
	while index < args.size():
		var key := str(args[index])
		var value := ""
		if index + 1 < args.size():
			value = str(args[index + 1])
		match key:
			"--strategy-a":
				config["strategy_a_path"] = value
				index += 2
			"--strategy-b":
				config["strategy_b_path"] = value
				index += 2
			"--deck":
				var decks: Array = config["deck_keys"]
				for part in value.split(",", false):
					var deck_key := str(part).strip_edges()
					if not deck_key.is_empty():
						decks.append(deck_key)
				index += 2
			"--seed-blocks-per-deck":
				config["seed_blocks_per_deck"] = maxi(1, int(value))
				index += 2
			"--seed":
				config["seed"] = int(value)
				index += 2
			"--max-actions":
				config["max_actions"] = maxi(1, int(value))
				index += 2
			"--eval-preset":
				config["eval_preset"] = value
				index += 2
			"--output":
				config["output"] = value
				index += 2
			"--output-dir":
				config["output_dir"] = value
				index += 2
			_:
				index += 1
	return config


func _validation_errors(catalog: CardCatalog) -> Array[String]:
	var errors: Array[String] = []
	var deck_keys := catalog.decks.keys()
	deck_keys.sort()
	var profile_keys := AIDeckProfiles.PROFILES.keys()
	profile_keys.sort()
	if deck_keys != profile_keys:
		errors.append("Godot deck keys and AI profile keys differ. decks=%s profiles=%s" % [
			JSON.stringify(deck_keys),
			JSON.stringify(profile_keys),
		])
	if deck_keys != DEFAULT_DECK_KEYS:
		errors.append("Godot AI evaluation expected the release 10 deck keys. got=%s" % [
			JSON.stringify(deck_keys),
		])
	for deck_key in DEFAULT_DECK_KEYS:
		var deck := catalog.get_deck(deck_key)
		if deck.is_empty():
			errors.append("Missing deck: %s" % deck_key)
		elif int(deck.get("card_count", 0)) != 60:
			errors.append("Deck %s must contain 60 cards." % deck_key)
		if AIDeckProfiles.get_profile(deck_key).is_empty():
			errors.append("Missing AI profile: %s" % deck_key)
	return errors


func _run_evaluation(catalog: CardCatalog, config: Dictionary) -> Dictionary:
	var selected_decks: Array = _selected_deck_keys(config)
	var strategy_a := _load_strategy(
		str(config.get("strategy_a_path", "")),
		"A",
		"Strategy A",
	)
	var strategy_b := _load_strategy(
		str(config.get("strategy_b_path", "")),
		"B",
		"Strategy B",
	)
	if _had_error:
		var empty_summary := _summarize_matches([])
		return {
			"schema_version": SCHEMA_VERSION,
			"created_at_unix": int(Time.get_unix_time_from_system()),
			"self_check": false,
			"eval_preset": str(config.get("eval_preset", "Custom")),
			"mode": "mirror",
			"deck_keys": selected_decks,
			"config": config,
			"strategies": {},
			"strategy_fingerprint": {"A": "", "B": "", "equal": false},
			"summary": empty_summary,
			"per_deck": {},
			"paired": _summarize_pairs([]),
			"seat": _summarize_seats([]),
			"terminal_reasons": {},
			"matches": [],
		}
	var self_check := str(config.get("strategy_a_path", "")).is_empty() and str(config.get("strategy_b_path", "")).is_empty()
	var engine := GameEngine.new(catalog)
	var worker := NativeChallengeAI.new()
	var matches: Array[Dictionary] = []
	var seed_blocks := maxi(1, int(config.get("seed_blocks_per_deck", DEFAULT_SEED_BLOCKS_PER_DECK)))
	var base_seed := int(config.get("seed", DEFAULT_SEED))
	var max_actions := maxi(1, int(config.get("max_actions", DEFAULT_MAX_ACTIONS)))
	for deck_index in range(selected_decks.size()):
		var deck_key := str(selected_decks[deck_index])
		for block_index in range(seed_blocks):
			var game_seed := _game_seed(base_seed, deck_index, block_index)
			var forced_first := block_index % 2
			matches.append(_play_match(
				catalog,
				engine,
				worker,
				deck_key,
				strategy_a,
				strategy_b,
				game_seed,
				block_index,
				0,
				forced_first,
				max_actions,
			))
			matches.append(_play_match(
				catalog,
				engine,
				worker,
				deck_key,
				strategy_a,
				strategy_b,
				game_seed,
				block_index,
				1,
				forced_first,
				max_actions,
			))
	var summary := _summarize_matches(matches)
	summary["point_rate_ci95"] = _bootstrap_point_rate_ci(matches, BOOTSTRAP_SEED)
	var paired := _summarize_pairs(matches)
	_apply_paired_summary(summary, paired)
	var per_deck := _summarize_by_deck(matches)
	_apply_per_deck_paired_summaries(per_deck, matches)
	var strategy_fingerprint := _strategy_fingerprint_summary(strategy_a, strategy_b, selected_decks)
	return {
		"schema_version": SCHEMA_VERSION,
		"created_at_unix": int(Time.get_unix_time_from_system()),
		"self_check": self_check,
		"eval_preset": str(config.get("eval_preset", "Custom")),
		"mode": "mirror",
		"deck_keys": selected_decks,
		"config": {
			"seed": base_seed,
			"seed_blocks_per_deck": seed_blocks,
			"max_actions": max_actions,
			"eval_preset": str(config.get("eval_preset", "Custom")),
		},
		"strategies": {
			"A": _public_strategy(strategy_a),
			"B": _public_strategy(strategy_b),
		},
		"strategy_fingerprint": strategy_fingerprint,
		"summary": summary,
		"per_deck": per_deck,
		"paired": paired,
		"seat": _summarize_seats(matches),
		"terminal_reasons": _count_by(matches, "terminal_reason"),
		"matches": matches,
	}


func _selected_deck_keys(config: Dictionary) -> Array:
	var requested: Array = config.get("deck_keys", [])
	if requested.is_empty():
		return DEFAULT_DECK_KEYS.duplicate()
	var selected: Array[String] = []
	for value in requested:
		var deck_key := str(value)
		if deck_key in DEFAULT_DECK_KEYS and deck_key not in selected:
			selected.append(deck_key)
	if selected.is_empty():
		return DEFAULT_DECK_KEYS.duplicate()
	selected.sort()
	return selected


func _game_seed(base_seed: int, deck_index: int, block_index: int) -> int:
	return int(base_seed + deck_index * 1_000_003 + block_index * 10_007)


func _load_strategy(path: String, fallback_id: String, fallback_label: String) -> Dictionary:
	var payload := {}
	if not path.is_empty():
		var parsed: Variant = _read_json(path)
		if parsed is Dictionary:
			payload = parsed
	var strategy := {
		"id": str(payload.get("id", fallback_id)),
		"label": str(payload.get("label", fallback_label)),
		"path": path,
		"preset": str(payload.get("preset", NativeChallengeAI.STRONGEST_DIFFICULTY)),
		"simulation_budget": payload.get("simulation_budget", null),
		"seconds": payload.get("seconds", null),
		"max_depth": payload.get("max_depth", null),
		"deterministic": payload.get("deterministic", null),
		"per_deck_overrides": Dictionary(payload.get("per_deck_overrides", {})).duplicate(true),
	}
	return strategy


func _public_strategy(strategy: Dictionary) -> Dictionary:
	var effective := _strategy_params(strategy, "")
	return {
		"id": strategy.get("id", ""),
		"label": strategy.get("label", ""),
		"path": strategy.get("path", ""),
		"preset": strategy.get("preset", NativeChallengeAI.STRONGEST_DIFFICULTY),
		"simulation_budget": strategy.get("simulation_budget", null),
		"seconds": strategy.get("seconds", null),
		"max_depth": strategy.get("max_depth", null),
		"deterministic": strategy.get("deterministic", null),
		"effective_default": effective,
		"per_deck_overrides": strategy.get("per_deck_overrides", {}),
	}


func _strategy_params(strategy: Dictionary, deck_key: String) -> Dictionary:
	var preset_name := str(strategy.get("preset", NativeChallengeAI.STRONGEST_DIFFICULTY))
	var preset := NativeChallengeAI.strongest_preset()
	if NativeChallengeAI.DIFFICULTIES.has(preset_name):
		preset = Dictionary(NativeChallengeAI.DIFFICULTIES[preset_name]).duplicate(true)
	var params := {
		"simulation_budget": int(preset.get("simulations", 1)),
		"seconds": float(preset.get("seconds", 0.0)),
		"max_depth": int(preset.get("depth", 1)),
		"deterministic": false,
	}
	_apply_strategy_overrides(params, strategy)
	var per_deck := Dictionary(strategy.get("per_deck_overrides", {}))
	if per_deck.get(deck_key) is Dictionary:
		_apply_strategy_overrides(params, Dictionary(per_deck[deck_key]))
	params["simulation_budget"] = maxi(1, int(params["simulation_budget"]))
	params["seconds"] = max(0.0, float(params["seconds"]))
	params["max_depth"] = maxi(1, int(params["max_depth"]))
	params["deterministic"] = bool(params["deterministic"])
	return params


func _apply_strategy_overrides(params: Dictionary, source: Dictionary) -> void:
	if source.get("simulation_budget") != null:
		params["simulation_budget"] = int(source["simulation_budget"])
	if source.get("simulations") != null:
		params["simulation_budget"] = int(source["simulations"])
	if source.get("seconds") != null:
		params["seconds"] = float(source["seconds"])
	if source.get("max_depth") != null:
		params["max_depth"] = int(source["max_depth"])
	if source.get("depth") != null:
		params["max_depth"] = int(source["depth"])
	if source.get("deterministic") != null:
		params["deterministic"] = bool(source["deterministic"])


func _play_match(
	catalog: CardCatalog,
	engine: GameEngine,
	worker: NativeChallengeAI,
	deck_key: String,
	strategy_a: Dictionary,
	strategy_b: Dictionary,
	seed: int,
	seed_block: int,
	seat: int,
	forced_first: int,
	max_actions: int,
) -> Dictionary:
	var started_ms := Time.get_ticks_msec()
	var strategy_a_player := 0 if seat == 0 else 1
	var state := GameState.new()
	state.public_deck_keys = [deck_key, deck_key]
	var rng := PortableRandomSource.new(seed)
	var setup := engine.setup_game(
		state,
		catalog.expand_deck(deck_key),
		catalog.expand_deck(deck_key),
		rng,
		forced_first,
	)
	if not setup.success:
		return _failed_match_row(deck_key, seed, seed_block, seat, strategy_a_player, "setup_failed", setup.message)
	state.public_deck_keys = [deck_key, deck_key]

	var actions_taken := 0
	var decisions := 0
	var choices := 0
	var total_decision_ms := 0.0
	var time_capped_decisions := 0
	var invalid_actions := 0
	var choice_failures := 0
	var rule_exceptions := 0
	var terminal_reason := ""
	var terminal_message := ""
	while state.winner < 0 and actions_taken < max_actions:
		var pending := ResolutionStack.from_dict(state.resolution_stack).pending_request
		if pending:
			var choice_actor := _choice_actor(state, pending)
			var choice_strategy := strategy_a if choice_actor == strategy_a_player else strategy_b
			var choice_result := _decide_choice(worker, state, pending, choice_actor, deck_key, choice_strategy, seed, actions_taken + choices)
			total_decision_ms += float(choice_result.get("elapsed_ms", 0.0))
			if not bool(choice_result.get("success", false)):
				choice_failures += 1
				terminal_reason = "choice_failed"
				terminal_message = str(choice_result.get("error", "choice_failed"))
				break
			var response := ChoiceResponse.from_dict(choice_result["choice_response"])
			var choice_step := engine.apply_choice(state, pending, response, rng)
			choices += 1
			if not choice_step.success:
				choice_failures += 1
				terminal_reason = "choice_failed"
				terminal_message = choice_step.message
				break
			continue

		var actor := _current_actor(state)
		var legal := engine.legal_actions(state, actor, true)
		if legal.is_empty():
			terminal_reason = "no_legal_action"
			terminal_message = "No legal action for actor=%d phase=%s" % [actor, state.phase]
			break
		var actor_strategy := strategy_a if actor == strategy_a_player else strategy_b
		var decision := _decide_action(worker, state, legal, actor, deck_key, actor_strategy, seed, actions_taken)
		total_decision_ms += float(decision.get("elapsed_ms", 0.0))
		decisions += 1
		var requested_budget := int(_strategy_params(actor_strategy, deck_key).get("simulation_budget", 1))
		if int(decision.get("simulations", requested_budget)) < requested_budget:
			time_capped_decisions += 1
		if not bool(decision.get("success", false)):
			rule_exceptions += 1
			terminal_reason = "decision_failed"
			terminal_message = str(decision.get("error", "decision_failed"))
			break
		var action := GameAction.from_dict(decision["action"])
		if not _action_matches_legal(action, legal):
			invalid_actions += 1
		action.action_id = "eval:%d:%d:%d" % [state.revision, actions_taken, actor]
		var step := engine.apply_action(state, action, rng)
		actions_taken += 1
		if not step.success:
			invalid_actions += 1
			terminal_reason = "illegal_action"
			terminal_message = step.message
			break

	if terminal_reason.is_empty():
		terminal_reason = "game_over" if state.winner >= 0 else "max_actions"
	var winner := _winner_label(state.winner, strategy_a_player)
	var score := _score_state(state, strategy_a_player, catalog)
	return {
		"deck": deck_key,
		"seed": seed,
		"seed_block": seed_block,
		"seat": seat,
		"strategy_a_player": strategy_a_player,
		"forced_first_player": forced_first,
		"strategy_a_first": strategy_a_player == forced_first,
		"winner": winner,
		"engine_winner": state.winner,
		"score": round(score * 1000.0) / 1000.0,
		"terminal_reason": terminal_reason,
		"terminal_message": terminal_message,
		"actions": actions_taken,
		"turns": state.turn_number,
		"decisions": decisions,
		"choices": choices,
		"average_decision_ms": round(total_decision_ms / max(1, decisions + choices) * 1000.0) / 1000.0,
		"elapsed_ms": Time.get_ticks_msec() - started_ms,
		"invalid_actions": invalid_actions,
		"choice_failures": choice_failures,
		"rule_exceptions": rule_exceptions,
		"time_capped_decisions": time_capped_decisions,
		"max_actions_exhausted": terminal_reason == "max_actions",
	}


func _failed_match_row(
	deck_key: String,
	seed: int,
	seed_block: int,
	seat: int,
	strategy_a_player: int,
	reason: String,
	message: String,
) -> Dictionary:
	return {
		"deck": deck_key,
		"seed": seed,
		"seed_block": seed_block,
		"seat": seat,
		"strategy_a_player": strategy_a_player,
		"forced_first_player": 0,
		"strategy_a_first": strategy_a_player == 0,
		"winner": "draw",
		"engine_winner": -1,
		"score": 0.0,
		"terminal_reason": reason,
		"terminal_message": message,
		"actions": 0,
		"turns": 0,
		"decisions": 0,
		"choices": 0,
		"average_decision_ms": 0.0,
		"elapsed_ms": 0,
		"invalid_actions": 0,
		"choice_failures": 0,
		"rule_exceptions": 1,
		"time_capped_decisions": 0,
		"max_actions_exhausted": false,
	}


func _decide_action(
	worker: NativeChallengeAI,
	state: GameState,
	legal: Array[GameAction],
	actor: int,
	deck_key: String,
	strategy: Dictionary,
	seed: int,
	action_index: int,
) -> Dictionary:
	var rows: Array = []
	for action in legal:
		rows.append(action.to_dict())
	var params := _strategy_params(strategy, deck_key)
	return worker.decide({
		"kind": "action",
		"state": state.snapshot(),
		"actor": actor,
		"revision": state.revision,
		"request_id": "eval-action:%d:%d" % [state.revision, action_index],
		"mode": "challenge",
		"deck_key": deck_key,
		"seed": seed + action_index * 7919 + actor * 17,
		"simulation_budget": int(params["simulation_budget"]),
		"seconds": float(params["seconds"]),
		"max_depth": int(params["max_depth"]),
		"deterministic": bool(params["deterministic"]),
		"actions": rows,
	}, Callable(self, "_not_cancelled"), null)


func _decide_choice(
	worker: NativeChallengeAI,
	state: GameState,
	request: ChoiceRequest,
	actor: int,
	deck_key: String,
	strategy: Dictionary,
	seed: int,
	choice_index: int,
) -> Dictionary:
	var params := _strategy_params(strategy, deck_key)
	return worker.decide({
		"kind": "choice",
		"state": state.snapshot(),
		"choice": request.to_dict(),
		"actor": actor,
		"revision": state.revision,
		"request_id": "eval-choice:%d:%d" % [state.revision, choice_index],
		"mode": "challenge",
		"deck_key": deck_key,
		"seed": seed + choice_index * 104729 + actor * 31,
		"simulation_budget": int(params["simulation_budget"]),
		"seconds": float(params["seconds"]),
		"max_depth": int(params["max_depth"]),
		"deterministic": bool(params["deterministic"]),
	}, Callable(self, "_not_cancelled"), null)


func _not_cancelled() -> bool:
	return false


func _choice_actor(state: GameState, request: ChoiceRequest) -> int:
	if request.player in [0, 1]:
		return request.player
	return _current_actor(state)


func _current_actor(state: GameState) -> int:
	if not state.pending_promotions.is_empty():
		return int(state.pending_promotions[0])
	if state.phase == "SETUP":
		return 0 if not state.setup_ready[0] else 1
	return state.active_player_idx


func _winner_label(engine_winner: int, strategy_a_player: int) -> String:
	if engine_winner == strategy_a_player:
		return "A"
	if engine_winner == 1 - strategy_a_player:
		return "B"
	return "draw"


func _score_state(state: GameState, strategy_a_player: int, catalog: CardCatalog) -> float:
	var base := 0.0
	if state.winner == strategy_a_player:
		base = 1_000_000.0
	elif state.winner == 1 - strategy_a_player:
		base = -1_000_000.0
	return base + _board_margin(state, strategy_a_player, catalog)


func _board_margin(state: GameState, perspective: int, catalog: CardCatalog) -> float:
	var own := state.get_player(perspective)
	var opponent := state.get_player(1 - perspective)
	var score := float(opponent.prizes.size() - own.prizes.size()) * 220.0
	score += float(own.hand.size() - opponent.hand.size()) * 4.0
	score += float(own.deck.size() - opponent.deck.size()) * 0.5
	for row in own.get_all_pokemon():
		score += _pokemon_strength(row["pokemon"], catalog)
	for row in opponent.get_all_pokemon():
		score -= _pokemon_strength(row["pokemon"], catalog)
	return score


func _pokemon_strength(pokemon: PokemonState, catalog: CardCatalog) -> float:
	if pokemon == null:
		return 0.0
	var best_damage := 0
	for attack in catalog.get_card(pokemon.card_id).get("attacks", []):
		best_damage = max(best_damage, int(Dictionary(attack).get("damage", 0)))
	return float(pokemon.current_hp(catalog)) + float(best_damage) * 2.0 + float(pokemon.energy_card_ids.size()) * 35.0


func _action_matches_legal(action: GameAction, legal: Array[GameAction]) -> bool:
	for candidate in legal:
		if (
			candidate.action == action.action
			and candidate.actor == action.actor
			and _deep_equal(candidate.params, action.params)
			and _ref_equal(candidate.source, action.source)
			and _ref_equal(candidate.target, action.target)
		):
			return true
	return false


func _ref_equal(left: EntityRef, right: EntityRef) -> bool:
	if left == null and right == null:
		return true
	if left == null or right == null:
		return false
	return _deep_equal(left.to_dict(), right.to_dict())


func _deep_equal(left: Variant, right: Variant) -> bool:
	if (left is int or left is float) and (right is int or right is float):
		return is_equal_approx(float(left), float(right))
	if left is Dictionary and right is Dictionary:
		if left.size() != right.size():
			return false
		for key in left:
			if not right.has(key) or not _deep_equal(left[key], right[key]):
				return false
		return true
	if left is Array and right is Array:
		if left.size() != right.size():
			return false
		for index in range(left.size()):
			if not _deep_equal(left[index], right[index]):
				return false
		return true
	return left == right


func _empty_stats() -> Dictionary:
	return {
		"games": 0,
		"wins": 0,
		"losses": 0,
		"draws": 0,
		"completed_games": 0,
		"clean_games": 0,
		"clean_wins": 0,
		"clean_losses": 0,
		"clean_draws": 0,
		"score_total": 0.0,
		"actions": 0,
		"turns": 0,
		"decisions": 0,
		"choices": 0,
		"decision_ms_total": 0.0,
		"decision_ms_values": [],
		"invalid_actions": 0,
		"choice_failures": 0,
		"rule_exceptions": 0,
		"time_capped_decisions": 0,
		"max_actions_exhaustions": 0,
	}


func _merge_match(stats: Dictionary, row: Dictionary) -> void:
	stats["games"] = int(stats["games"]) + 1
	match str(row.get("winner", "draw")):
		"A":
			stats["wins"] = int(stats["wins"]) + 1
		"B":
			stats["losses"] = int(stats["losses"]) + 1
		_:
			stats["draws"] = int(stats["draws"]) + 1
	if str(row.get("terminal_reason", "")) == "game_over":
		stats["completed_games"] = int(stats["completed_games"]) + 1
	if _is_clean_match(row):
		stats["clean_games"] = int(stats["clean_games"]) + 1
		match str(row.get("winner", "draw")):
			"A":
				stats["clean_wins"] = int(stats["clean_wins"]) + 1
			"B":
				stats["clean_losses"] = int(stats["clean_losses"]) + 1
			_:
				stats["clean_draws"] = int(stats["clean_draws"]) + 1
	stats["score_total"] = float(stats["score_total"]) + float(row.get("score", 0.0))
	stats["actions"] = int(stats["actions"]) + int(row.get("actions", 0))
	stats["turns"] = int(stats["turns"]) + int(row.get("turns", 0))
	stats["decisions"] = int(stats["decisions"]) + int(row.get("decisions", 0))
	stats["choices"] = int(stats["choices"]) + int(row.get("choices", 0))
	var average_decision_ms := float(row.get("average_decision_ms", 0.0))
	stats["decision_ms_total"] = float(stats["decision_ms_total"]) + (
		average_decision_ms
		* float(max(1, int(row.get("decisions", 0)) + int(row.get("choices", 0))))
	)
	var decision_values: Array = stats["decision_ms_values"]
	decision_values.append(average_decision_ms)
	stats["invalid_actions"] = int(stats["invalid_actions"]) + int(row.get("invalid_actions", 0))
	stats["choice_failures"] = int(stats["choice_failures"]) + int(row.get("choice_failures", 0))
	stats["rule_exceptions"] = int(stats["rule_exceptions"]) + int(row.get("rule_exceptions", 0))
	stats["time_capped_decisions"] = int(stats["time_capped_decisions"]) + int(row.get("time_capped_decisions", 0))
	if bool(row.get("max_actions_exhausted", false)):
		stats["max_actions_exhaustions"] = int(stats["max_actions_exhaustions"]) + 1


func _is_clean_match(row: Dictionary) -> bool:
	return (
		str(row.get("terminal_reason", "")) == "game_over"
		and int(row.get("invalid_actions", 0)) == 0
		and int(row.get("choice_failures", 0)) == 0
		and int(row.get("rule_exceptions", 0)) == 0
		and not bool(row.get("max_actions_exhausted", false))
	)


func _finalize_stats(stats: Dictionary) -> Dictionary:
	var games: int = max(1, int(stats.get("games", 0)))
	var decisions_and_choices: int = max(1, int(stats.get("decisions", 0)) + int(stats.get("choices", 0)))
	var decisions: int = max(1, int(stats.get("decisions", 0)))
	var point_rate := (float(stats.get("wins", 0)) + float(stats.get("draws", 0)) * 0.5) / float(games)
	var clean_games := int(stats.get("clean_games", 0))
	var clean_point_rate := 0.0
	if clean_games > 0:
		clean_point_rate = (
			float(stats.get("clean_wins", 0))
			+ float(stats.get("clean_draws", 0)) * 0.5
		) / float(clean_games)
	var decision_values: Array = stats.get("decision_ms_values", [])
	var result := stats.duplicate(true)
	result["win_rate"] = round(float(stats.get("wins", 0)) / float(games) * 10000.0) / 10000.0
	result["draw_rate"] = round(float(stats.get("draws", 0)) / float(games) * 10000.0) / 10000.0
	result["point_rate"] = round(point_rate * 10000.0) / 10000.0
	result["completion_rate"] = round(float(stats.get("completed_games", 0)) / float(games) * 10000.0) / 10000.0
	result["max_action_exhaustion_rate"] = round(float(stats.get("max_actions_exhaustions", 0)) / float(games) * 10000.0) / 10000.0
	result["clean_point_rate"] = round(clean_point_rate * 10000.0) / 10000.0
	result["average_score"] = round(float(stats.get("score_total", 0.0)) / float(games) * 1000.0) / 1000.0
	result["average_actions"] = round(float(stats.get("actions", 0)) / float(games) * 1000.0) / 1000.0
	result["average_turns"] = round(float(stats.get("turns", 0)) / float(games) * 1000.0) / 1000.0
	result["average_decision_ms"] = round(float(stats.get("decision_ms_total", 0.0)) / float(decisions_and_choices) * 1000.0) / 1000.0
	result["decision_ms_p50"] = _round_to(_percentile(decision_values, 0.50), 3)
	result["decision_ms_p95"] = _round_to(_percentile(decision_values, 0.95), 3)
	result["time_capped_decision_rate"] = round(float(stats.get("time_capped_decisions", 0)) / float(decisions) * 10000.0) / 10000.0
	result["elo_delta"] = round(_elo_delta(point_rate) * 1000.0) / 1000.0
	result.erase("decision_ms_values")
	return result


func _elo_delta(point_rate: float) -> float:
	var clamped := clampf(point_rate, 0.001, 0.999)
	return 400.0 * log(clamped / (1.0 - clamped)) / log(10.0)


func _summarize_matches(matches: Array[Dictionary]) -> Dictionary:
	var stats := _empty_stats()
	for row in matches:
		_merge_match(stats, row)
	return _finalize_stats(stats)


func _summarize_by_deck(matches: Array[Dictionary]) -> Dictionary:
	var rows := {}
	var grouped_matches := {}
	for row in matches:
		var deck_key := str(row.get("deck", ""))
		if not rows.has(deck_key):
			rows[deck_key] = _empty_stats()
			grouped_matches[deck_key] = []
		_merge_match(rows[deck_key], row)
		grouped_matches[deck_key].append(row)
	for deck_key in rows:
		rows[deck_key] = _finalize_stats(rows[deck_key])
		rows[deck_key]["point_rate_ci95"] = _bootstrap_point_rate_ci(
			grouped_matches[deck_key],
			BOOTSTRAP_SEED + absi(str(deck_key).hash()) % 100000,
		)
	return rows


func _summarize_seats(matches: Array[Dictionary]) -> Dictionary:
	var first := _empty_stats()
	var second := _empty_stats()
	var seat_counts := {"a_player_0": 0, "a_player_1": 0}
	for row in matches:
		if bool(row.get("strategy_a_first", false)):
			_merge_match(first, row)
		else:
			_merge_match(second, row)
		if int(row.get("strategy_a_player", 0)) == 0:
			seat_counts["a_player_0"] = int(seat_counts["a_player_0"]) + 1
		else:
			seat_counts["a_player_1"] = int(seat_counts["a_player_1"]) + 1
	var first_stats := _finalize_stats(first)
	var second_stats := _finalize_stats(second)
	return {
		"strategy_a_first": first_stats,
		"strategy_a_second": second_stats,
		"seat_counts": seat_counts,
		"seat_gap": abs(int(seat_counts["a_player_0"]) - int(seat_counts["a_player_1"])),
		"first_player_point_rate_gap": round(
			abs(float(first_stats["point_rate"]) - float(second_stats["point_rate"])) * 10000.0
		) / 10000.0,
	}


func _match_point(row: Dictionary) -> float:
	match str(row.get("winner", "draw")):
		"A":
			return 1.0
		"B":
			return 0.0
		_:
			return 0.5


func _round_to(value: float, digits: int) -> float:
	var scale := pow(10.0, float(maxi(0, digits)))
	return round(value * scale) / scale


func _percentile(values_input: Array, percentile: float) -> float:
	if values_input.is_empty():
		return 0.0
	var values: Array = []
	for value in values_input:
		values.append(float(value))
	values.sort()
	var clamped := clampf(percentile, 0.0, 1.0)
	var index := int(floor(clamped * float(values.size() - 1)))
	return float(values[index])


func _confidence_interval(values: Array) -> Dictionary:
	return {
		"lower": _round_to(_percentile(values, 0.025), 4),
		"upper": _round_to(_percentile(values, 0.975), 4),
		"samples": values.size(),
	}


func _group_matches_by_deck(matches: Array) -> Dictionary:
	var groups := {}
	for row in matches:
		var deck_key := str(row.get("deck", ""))
		if not groups.has(deck_key):
			groups[deck_key] = []
		var deck_rows: Array = groups[deck_key]
		deck_rows.append(row)
	return groups


func _bootstrap_point_rate_ci(matches: Array, seed: int) -> Dictionary:
	if matches.is_empty():
		return _confidence_interval([])
	var groups := _group_matches_by_deck(matches)
	var deck_keys := groups.keys()
	deck_keys.sort()
	var rng := RandomNumberGenerator.new()
	rng.seed = int(maxi(1, absi(seed)))
	var values: Array = []
	for _iteration in range(BOOTSTRAP_ITERATIONS):
		var points := 0.0
		var count := 0
		for deck_key in deck_keys:
			var rows: Array = groups[deck_key]
			for _sample_index in range(rows.size()):
				var row: Dictionary = rows[rng.randi_range(0, rows.size() - 1)]
				points += _match_point(row)
				count += 1
		values.append(points / float(maxi(1, count)))
	return _confidence_interval(values)


func _pair_key(row: Dictionary) -> String:
	return "%s:%d:%d" % [
		str(row.get("deck", "")),
		int(row.get("seed_block", 0)),
		int(row.get("seed", 0)),
	]


func _pair_row_from_matches(rows: Array) -> Dictionary:
	if rows.is_empty():
		return {}
	var first: Dictionary = rows[0]
	var points := 0.0
	var score := 0.0
	var clean := true
	for row_value in rows:
		var row: Dictionary = row_value
		points += _match_point(row)
		score += float(row.get("score", 0.0))
		clean = clean and _is_clean_match(row)
	var games := maxi(1, rows.size())
	var point_rate := points / float(games)
	return {
		"deck": str(first.get("deck", "")),
		"seed": int(first.get("seed", 0)),
		"seed_block": int(first.get("seed_block", 0)),
		"games": games,
		"complete": rows.size() >= 2,
		"clean": clean,
		"point_rate": _round_to(point_rate, 4),
		"point_delta": _round_to(point_rate - 0.5, 4),
		"score_delta": _round_to(score / float(games), 3),
	}


func _paired_rows(matches: Array[Dictionary]) -> Array[Dictionary]:
	var groups := {}
	for row in matches:
		var key := _pair_key(row)
		if not groups.has(key):
			groups[key] = []
		var rows: Array = groups[key]
		rows.append(row)
	var keys := groups.keys()
	keys.sort()
	var result: Array[Dictionary] = []
	for key in keys:
		var pair_row := _pair_row_from_matches(groups[key])
		if not pair_row.is_empty():
			result.append(pair_row)
	return result


func _group_pairs_by_deck(pair_rows: Array) -> Dictionary:
	var groups := {}
	for row_value in pair_rows:
		var row: Dictionary = row_value
		var deck_key := str(row.get("deck", ""))
		if not groups.has(deck_key):
			groups[deck_key] = []
		var rows: Array = groups[deck_key]
		rows.append(row)
	return groups


func _bootstrap_pair_delta_values(pair_rows: Array, seed: int) -> Array:
	if pair_rows.is_empty():
		return []
	var groups := _group_pairs_by_deck(pair_rows)
	var deck_keys := groups.keys()
	deck_keys.sort()
	var rng := RandomNumberGenerator.new()
	rng.seed = int(maxi(1, absi(seed)))
	var values: Array = []
	for _iteration in range(BOOTSTRAP_ITERATIONS):
		var total := 0.0
		var count := 0
		for deck_key in deck_keys:
			var rows: Array = groups[deck_key]
			for _sample_index in range(rows.size()):
				var row: Dictionary = rows[rng.randi_range(0, rows.size() - 1)]
				total += float(row.get("point_delta", 0.0))
				count += 1
		values.append(total / float(maxi(1, count)))
	return values


func _probability_positive(values: Array) -> float:
	if values.is_empty():
		return 0.5
	var positive := 0.0
	for value in values:
		var number := float(value)
		if number > 0.0:
			positive += 1.0
		elif is_equal_approx(number, 0.0):
			positive += 0.5
	return _round_to(positive / float(values.size()), 4)


func _summarize_pair_rows(pair_rows: Array, seed: int) -> Dictionary:
	var total_delta := 0.0
	var total_score := 0.0
	var clean_pairs := 0
	for row_value in pair_rows:
		var row: Dictionary = row_value
		total_delta += float(row.get("point_delta", 0.0))
		total_score += float(row.get("score_delta", 0.0))
		if bool(row.get("clean", false)):
			clean_pairs += 1
	var pair_count := pair_rows.size()
	var boot_values := _bootstrap_pair_delta_values(pair_rows, seed)
	var mean_delta := 0.0
	var mean_score := 0.0
	if pair_count > 0:
		mean_delta = total_delta / float(pair_count)
		mean_score = total_score / float(pair_count)
	return {
		"pairs": pair_rows,
		"paired_pairs": pair_count,
		"clean_pairs": clean_pairs,
		"paired_point_delta": _round_to(mean_delta, 4),
		"paired_score_delta": _round_to(mean_score, 3),
		"paired_delta_ci95": _confidence_interval(boot_values),
		"probability_a_better": _probability_positive(boot_values),
	}


func _summarize_pairs(matches: Array[Dictionary]) -> Dictionary:
	return _summarize_pair_rows(_paired_rows(matches), BOOTSTRAP_SEED + 777)


func _apply_paired_summary(target: Dictionary, paired: Dictionary) -> void:
	for key in [
		"paired_pairs",
		"clean_pairs",
		"paired_point_delta",
		"paired_score_delta",
		"paired_delta_ci95",
		"probability_a_better",
	]:
		target[key] = paired.get(key)


func _apply_per_deck_paired_summaries(per_deck: Dictionary, matches: Array[Dictionary]) -> void:
	var grouped_pairs := _group_pairs_by_deck(_paired_rows(matches))
	for deck_key in per_deck.keys():
		var pair_rows: Array = grouped_pairs.get(deck_key, [])
		var paired := _summarize_pair_rows(
			pair_rows,
			BOOTSTRAP_SEED + 1000 + absi(str(deck_key).hash()) % 100000,
		)
		_apply_paired_summary(per_deck[deck_key], paired)


func _strategy_fingerprint_summary(
	strategy_a: Dictionary,
	strategy_b: Dictionary,
	deck_keys: Array,
) -> Dictionary:
	var fingerprint_a := _strategy_fingerprint(strategy_a, deck_keys)
	var fingerprint_b := _strategy_fingerprint(strategy_b, deck_keys)
	return {
		"A": fingerprint_a,
		"B": fingerprint_b,
		"equal": fingerprint_a == fingerprint_b,
	}


func _strategy_fingerprint(strategy: Dictionary, deck_keys: Array) -> String:
	var payload := {
		"default": _strategy_params(strategy, ""),
		"per_deck": {},
	}
	for deck_key in deck_keys:
		payload["per_deck"][str(deck_key)] = _strategy_params(strategy, str(deck_key))
	return _canonical_json(payload).sha256_text()


func _canonical_json(value: Variant) -> String:
	if value is Dictionary:
		var keys: Array = value.keys()
		keys.sort()
		var parts: Array[String] = []
		for key in keys:
			parts.append("%s:%s" % [JSON.stringify(str(key)), _canonical_json(value[key])])
		return "{%s}" % _join_strings(parts, ",")
	if value is Array:
		var array_parts: Array[String] = []
		for item in value:
			array_parts.append(_canonical_json(item))
		return "[%s]" % _join_strings(array_parts, ",")
	return JSON.stringify(value)


func _join_strings(parts: Array[String], separator: String) -> String:
	var result := ""
	for index in range(parts.size()):
		if index > 0:
			result += separator
		result += parts[index]
	return result


func _count_by(matches: Array[Dictionary], key: String) -> Dictionary:
	var result := {}
	for row in matches:
		var value := str(row.get(key, ""))
		result[value] = int(result.get(value, 0)) + 1
	return result


func _read_json(path: String) -> Variant:
	var resolved := _absolute_path(path)
	var file := FileAccess.open(resolved, FileAccess.READ)
	if file == null:
		push_error("Unable to open JSON file: %s" % path)
		_had_error = true
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed == null:
		push_error("Invalid JSON file: %s" % path)
		_had_error = true
		return {}
	return parsed


func _write_json(path: String, payload: Dictionary) -> bool:
	var resolved := _absolute_path(path)
	var directory := resolved.get_base_dir()
	if not directory.is_empty():
		var err := DirAccess.make_dir_recursive_absolute(directory)
		if err != OK:
			push_error("Unable to create output directory %s: %d" % [directory, err])
			return false
	var file := FileAccess.open(resolved, FileAccess.WRITE)
	if file == null:
		push_error("Unable to write output JSON: %s" % path)
		return false
	file.store_string(JSON.stringify(payload, "\t"))
	file.store_string("\n")
	return true


func _output_path(config: Dictionary) -> String:
	var explicit := str(config.get("output", ""))
	if not explicit.is_empty():
		return explicit
	var output_dir := str(config.get("output_dir", ""))
	if output_dir.is_empty():
		output_dir = ".test_tmp/ai_eval/%d" % int(Time.get_unix_time_from_system())
	return output_dir.path_join("results.json")


func _absolute_path(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		return ProjectSettings.globalize_path(path)
	return path
