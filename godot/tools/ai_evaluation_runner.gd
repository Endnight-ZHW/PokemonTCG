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
const SCHEMA_VERSION := 3
const DEFAULT_SEED_BLOCKS_PER_DECK := 50
const DEFAULT_CROSS_SEED_BLOCKS_PER_MATCHUP := 10
const DEFAULT_SEED := 17
const DEFAULT_MAX_ACTIONS := 1200
const BOOTSTRAP_ITERATIONS := 400
const BOOTSTRAP_SEED := 90210
const MATCHUP_MODE_MIRROR := "Mirror"
const MATCHUP_MODE_BALANCED := "Balanced"
const MATCHUP_MODE_MATRIX := "Matrix"

var _had_error := false
var _deep_runtime_cache: Dictionary = {}
var _deep_unavailable: Dictionary = {}


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
		"cross_seed_blocks_per_matchup": DEFAULT_CROSS_SEED_BLOCKS_PER_MATCHUP,
		"seed_block_start": 0,
		"seed_block_count": 0,
		"task_start": 0,
		"task_count": 0,
		"task_shard_index": 0,
		"task_shard_count": 1,
		"seed": DEFAULT_SEED,
		"max_actions": DEFAULT_MAX_ACTIONS,
		"eval_preset": "Custom",
		"matchup_mode": "",
		"skip_golden": false,
		"profile": false,
		"disable_ai_cache": false,
		"disable_native_math": false,
		"distill_output": "",
		"progress": false,
		"progress_every_pairs": 1,
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
			"--cross-seed-blocks-per-matchup":
				config["cross_seed_blocks_per_matchup"] = maxi(0, int(value))
				index += 2
			"--seed-block-start":
				config["seed_block_start"] = maxi(0, int(value))
				index += 2
			"--seed-block-count":
				config["seed_block_count"] = maxi(0, int(value))
				index += 2
			"--task-start":
				config["task_start"] = maxi(0, int(value))
				index += 2
			"--task-count":
				config["task_count"] = maxi(0, int(value))
				index += 2
			"--task-shard-index":
				config["task_shard_index"] = maxi(0, int(value))
				index += 2
			"--task-shard-count":
				config["task_shard_count"] = maxi(1, int(value))
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
			"--matchup-mode":
				config["matchup_mode"] = _canonical_matchup_mode(value)
				index += 2
			"--skip-golden":
				config["skip_golden"] = true
				index += 1
			"--profile":
				config["profile"] = true
				index += 1
			"--disable-ai-cache":
				config["disable_ai_cache"] = true
				index += 1
			"--disable-native-math":
				config["disable_native_math"] = true
				index += 1
			"--distill-output":
				config["distill_output"] = value
				index += 2
			"--progress":
				config["progress"] = true
				index += 1
			"--progress-every-pairs":
				config["progress_every_pairs"] = maxi(1, int(value))
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


func _canonical_matchup_mode(value: String) -> String:
	var normalized := value.strip_edges().to_lower()
	match normalized:
		"mirror":
			return MATCHUP_MODE_MIRROR
		"balanced":
			return MATCHUP_MODE_BALANCED
		"matrix":
			return MATCHUP_MODE_MATRIX
		_:
			return ""


func _matchup_mode(config: Dictionary) -> String:
	var explicit := _canonical_matchup_mode(str(config.get("matchup_mode", "")))
	if not explicit.is_empty():
		return explicit
	var preset := str(config.get("eval_preset", "Custom"))
	if preset == "Nightly":
		return MATCHUP_MODE_BALANCED
	return MATCHUP_MODE_MIRROR


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
			"mode": _matchup_mode(config).to_lower(),
			"matchup_mode": _matchup_mode(config),
			"deck_keys": selected_decks,
			"config": config,
			"strategies": {},
			"strategy_fingerprint": {"A": "", "B": "", "equal": false},
			"summary": empty_summary,
			"per_deck": {},
			"per_matchup": {},
			"matrix": {},
			"paired": _summarize_pairs([]),
			"seat": _summarize_seats([]),
			"decision_diagnostics": _empty_diagnostics_summary(),
			"golden_scenarios": _empty_golden_summary(),
			"performance_profile": _finalize_performance_profile(_new_performance_profile(false)),
			"terminal_reasons": {},
			"matches": [],
		}
	var self_check := str(config.get("strategy_a_path", "")).is_empty() and str(config.get("strategy_b_path", "")).is_empty()
	var engine := GameEngine.new(catalog)
	var worker := NativeChallengeAI.new()
	var matches: Array[Dictionary] = []
	var performance_profile := _new_performance_profile(bool(config.get("profile", false)))
	var disable_ai_cache := bool(config.get("disable_ai_cache", false))
	var disable_native_math := bool(config.get("disable_native_math", false))
	var seed_blocks := maxi(1, int(config.get("seed_blocks_per_deck", DEFAULT_SEED_BLOCKS_PER_DECK)))
	var cross_seed_blocks := maxi(0, int(config.get(
		"cross_seed_blocks_per_matchup", DEFAULT_CROSS_SEED_BLOCKS_PER_MATCHUP)))
	var seed_block_start := clampi(int(config.get("seed_block_start", 0)), 0, seed_blocks - 1)
	var requested_seed_block_count := int(config.get("seed_block_count", 0))
	var seed_block_count := seed_blocks - seed_block_start
	if requested_seed_block_count > 0:
		seed_block_count = mini(seed_block_count, requested_seed_block_count)
	var base_seed := int(config.get("seed", DEFAULT_SEED))
	var max_actions := maxi(1, int(config.get("max_actions", DEFAULT_MAX_ACTIONS)))
	var matchup_mode := _matchup_mode(config)
	var run_mirror := matchup_mode in [MATCHUP_MODE_MIRROR, MATCHUP_MODE_BALANCED]
	var run_cross := matchup_mode in [MATCHUP_MODE_BALANCED, MATCHUP_MODE_MATRIX]
	var task_start := maxi(0, int(config.get("task_start", 0)))
	var task_count := maxi(0, int(config.get("task_count", 0)))
	var task_shard_count := maxi(1, int(config.get("task_shard_count", 1)))
	var task_shard_index := clampi(int(config.get("task_shard_index", 0)), 0, task_shard_count - 1)
	var progress_enabled := bool(config.get("progress", false))
	var progress_every_pairs := maxi(1, int(config.get("progress_every_pairs", 1)))
	var progress_started_ms := Time.get_ticks_msec()
	var total_task_pairs := _count_task_pairs(
		selected_decks,
		cross_seed_blocks,
		seed_block_start,
		seed_block_count,
		matchup_mode,
		task_start,
		task_count,
		task_shard_index,
		task_shard_count,
	)
	var completed_task_pairs := 0
	var completed_games := 0
	var total_games := total_task_pairs * 2
	var task_candidates := 0
	var task_pairs_run := 0
	for selected_deck_index in range(selected_decks.size()):
		var deck_key := str(selected_decks[selected_deck_index])
		var deck_index := DEFAULT_DECK_KEYS.find(deck_key)
		if deck_index < 0:
			deck_index = selected_deck_index
		if run_mirror:
			for block_offset in range(seed_block_count):
				var block_index := seed_block_start + block_offset
				var task_index := task_candidates
				task_candidates += 1
				if not _task_belongs_to_range(task_index, task_start, task_count):
					continue
				if not _task_belongs_to_shard(task_index, task_shard_index, task_shard_count):
					continue
				task_pairs_run += 1
				var game_seed := _game_seed(base_seed, deck_index, block_index)
				var forced_first := block_index % 2
				matches.append(_play_match(
					catalog,
					engine,
					worker,
					deck_key,
					deck_key,
					strategy_a,
					strategy_b,
					game_seed,
					block_index,
					0,
					forced_first,
					max_actions,
					"mirror",
					task_index,
					task_shard_index,
					task_shard_count,
					performance_profile,
					disable_ai_cache,
					disable_native_math,
					str(config.get("distill_output", "")),
				))
				matches.append(_play_match(
					catalog,
					engine,
					worker,
					deck_key,
					deck_key,
					strategy_a,
					strategy_b,
					game_seed,
					block_index,
					1,
					forced_first,
					max_actions,
					"mirror",
					task_index,
					task_shard_index,
					task_shard_count,
					performance_profile,
					disable_ai_cache,
					disable_native_math,
					str(config.get("distill_output", "")),
				))
				completed_task_pairs += 1
				completed_games += 2
				_maybe_emit_progress(
					progress_enabled,
					progress_every_pairs,
					completed_task_pairs,
					total_task_pairs,
					completed_games,
					total_games,
					task_shard_index,
					task_shard_count,
					deck_key,
					_matchup_key(deck_key, deck_key),
					progress_started_ms,
				)
	if run_cross and cross_seed_blocks > 0:
		var cross_end := mini(cross_seed_blocks, seed_block_start + seed_block_count)
		for strategy_a_deck_index in range(selected_decks.size()):
			var strategy_a_deck := str(selected_decks[strategy_a_deck_index])
			var deck_a_index := DEFAULT_DECK_KEYS.find(strategy_a_deck)
			if deck_a_index < 0:
				deck_a_index = strategy_a_deck_index
			for strategy_b_deck_index in range(selected_decks.size()):
				var strategy_b_deck := str(selected_decks[strategy_b_deck_index])
				if strategy_b_deck == strategy_a_deck:
					continue
				var deck_b_index := DEFAULT_DECK_KEYS.find(strategy_b_deck)
				if deck_b_index < 0:
					deck_b_index = strategy_b_deck_index
				for block_index in range(seed_block_start, cross_end):
					var task_index := task_candidates
					task_candidates += 1
					if not _task_belongs_to_range(task_index, task_start, task_count):
						continue
					if not _task_belongs_to_shard(task_index, task_shard_index, task_shard_count):
						continue
					task_pairs_run += 1
					var cross_seed := _cross_game_seed(
						base_seed, deck_a_index, deck_b_index, block_index)
					var forced_first := block_index % 2
					matches.append(_play_match(
						catalog,
						engine,
						worker,
						strategy_a_deck,
						strategy_b_deck,
						strategy_a,
						strategy_b,
						cross_seed,
						block_index,
						0,
						forced_first,
						max_actions,
						"cross",
						task_index,
						task_shard_index,
						task_shard_count,
						performance_profile,
						disable_ai_cache,
						disable_native_math,
						str(config.get("distill_output", "")),
					))
					matches.append(_play_match(
						catalog,
						engine,
						worker,
						strategy_a_deck,
						strategy_b_deck,
						strategy_a,
						strategy_b,
						cross_seed,
						block_index,
						1,
						forced_first,
						max_actions,
						"cross",
						task_index,
						task_shard_index,
						task_shard_count,
						performance_profile,
						disable_ai_cache,
						disable_native_math,
						str(config.get("distill_output", "")),
					))
					completed_task_pairs += 1
					completed_games += 2
					_maybe_emit_progress(
						progress_enabled,
						progress_every_pairs,
						completed_task_pairs,
						total_task_pairs,
						completed_games,
						total_games,
						task_shard_index,
						task_shard_count,
						strategy_a_deck,
						_matchup_key(strategy_a_deck, strategy_b_deck),
						progress_started_ms,
					)
	var summary := _summarize_matches(matches)
	summary["point_rate_ci95"] = _bootstrap_point_rate_ci(matches, BOOTSTRAP_SEED)
	var paired := _summarize_pairs(matches)
	_apply_paired_summary(summary, paired)
	var per_deck := _summarize_by_deck(matches)
	_apply_per_deck_paired_summaries(per_deck, matches)
	var per_matchup := _summarize_by_matchup(matches)
	_apply_per_matchup_paired_summaries(per_matchup, matches)
	var strategy_fingerprint := _strategy_fingerprint_summary(strategy_a, strategy_b, selected_decks)
	var diagnostics := _summarize_decision_diagnostics(matches)
	var golden_scenarios := _empty_golden_summary()
	if not bool(config.get("skip_golden", false)):
		golden_scenarios = _run_golden_scenarios(catalog, engine, worker)
	return {
		"schema_version": SCHEMA_VERSION,
		"created_at_unix": int(Time.get_unix_time_from_system()),
		"self_check": self_check,
		"eval_preset": str(config.get("eval_preset", "Custom")),
		"mode": matchup_mode.to_lower(),
		"matchup_mode": matchup_mode,
		"deck_keys": selected_decks,
		"config": {
			"seed": base_seed,
			"seed_blocks_per_deck": seed_blocks,
			"cross_seed_blocks_per_matchup": cross_seed_blocks,
			"seed_block_start": seed_block_start,
			"seed_block_count": seed_block_count,
			"task_start": task_start,
			"task_count": task_count,
			"task_shard_index": task_shard_index,
			"task_shard_count": task_shard_count,
			"task_candidates": task_candidates,
			"task_pairs_run": task_pairs_run,
			"max_actions": max_actions,
			"eval_preset": str(config.get("eval_preset", "Custom")),
			"matchup_mode": matchup_mode,
			"skip_golden": bool(config.get("skip_golden", false)),
			"profile": bool(config.get("profile", false)),
			"disable_ai_cache": disable_ai_cache,
			"disable_native_math": disable_native_math,
			"progress": progress_enabled,
			"progress_every_pairs": progress_every_pairs,
		},
		"strategies": {
			"A": _public_strategy(strategy_a),
			"B": _public_strategy(strategy_b),
		},
		"strategy_fingerprint": strategy_fingerprint,
		"summary": summary,
		"per_deck": per_deck,
		"per_matchup": per_matchup,
		"matrix": _summarize_matrix(matches),
		"paired": paired,
		"seat": _summarize_seats(matches),
		"decision_diagnostics": diagnostics,
		"golden_scenarios": golden_scenarios,
		"performance_profile": _finalize_performance_profile(performance_profile),
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


func _count_task_pairs(
	selected_decks: Array,
	cross_seed_blocks: int,
	seed_block_start: int,
	seed_block_count: int,
	matchup_mode: String,
	task_start: int,
	task_count: int,
	task_shard_index: int,
	task_shard_count: int,
) -> int:
	var run_mirror := matchup_mode in [MATCHUP_MODE_MIRROR, MATCHUP_MODE_BALANCED]
	var run_cross := matchup_mode in [MATCHUP_MODE_BALANCED, MATCHUP_MODE_MATRIX]
	var task_candidates := 0
	var task_pairs := 0
	if run_mirror:
		for _deck_key in selected_decks:
			for _block_offset in range(seed_block_count):
				var task_index := task_candidates
				task_candidates += 1
				if not _task_belongs_to_range(task_index, task_start, task_count):
					continue
				if not _task_belongs_to_shard(task_index, task_shard_index, task_shard_count):
					continue
				task_pairs += 1
	if run_cross and cross_seed_blocks > 0:
		var cross_end := mini(cross_seed_blocks, seed_block_start + seed_block_count)
		for strategy_a_deck in selected_decks:
			for strategy_b_deck in selected_decks:
				if str(strategy_b_deck) == str(strategy_a_deck):
					continue
				for _block_index in range(seed_block_start, cross_end):
					var task_index := task_candidates
					task_candidates += 1
					if not _task_belongs_to_range(task_index, task_start, task_count):
						continue
					if not _task_belongs_to_shard(task_index, task_shard_index, task_shard_count):
						continue
					task_pairs += 1
	return task_pairs


func _maybe_emit_progress(
	enabled: bool,
	progress_every_pairs: int,
	completed_pairs: int,
	total_pairs: int,
	completed_games: int,
	total_games: int,
	task_shard_index: int,
	task_shard_count: int,
	deck: String,
	matchup_key: String,
	started_ms: int,
) -> void:
	if not enabled:
		return
	if completed_pairs < total_pairs and completed_pairs % maxi(1, progress_every_pairs) != 0:
		return
	var payload := {
		"completed_pairs": completed_pairs,
		"total_pairs": total_pairs,
		"completed_games": completed_games,
		"total_games": total_games,
		"task_shard_index": task_shard_index,
		"task_shard_count": task_shard_count,
		"deck": deck,
		"matchup_key": matchup_key,
		"elapsed_ms": Time.get_ticks_msec() - started_ms,
	}
	print("AI_EVALUATION_PROGRESS ", JSON.stringify(payload))


func _game_seed(base_seed: int, deck_index: int, block_index: int) -> int:
	return int(base_seed + deck_index * 1_000_003 + block_index * 10_007)


func _cross_game_seed(base_seed: int, deck_a_index: int, deck_b_index: int, block_index: int) -> int:
	return int(
		base_seed
		+ 50_000_000
		+ deck_a_index * 1_000_003
		+ deck_b_index * 97_409
		+ block_index * 10_007
	)


func _load_strategy(path: String, fallback_id: String, fallback_label: String) -> Dictionary:
	var payload := {}
	if not path.is_empty():
		var parsed: Variant = _read_json(path)
		if parsed is Dictionary:
			payload = parsed
	var param_payload := {}
	if payload.get("params", {}) is Dictionary:
		param_payload = Dictionary(payload.get("params", {}))
	var per_deck_payload: Variant = payload.get(
		"per_deck_overrides",
		param_payload.get("per_deck_overrides", {}),
	)
	var strategy := {
		"id": str(payload.get("id", fallback_id)),
		"label": str(payload.get("label", fallback_label)),
		"path": path,
		"mode": str(payload.get("mode", "challenge")),
		"preset": str(payload.get("preset", NativeChallengeAI.STRONGEST_DIFFICULTY)),
		"simulation_budget": param_payload.get("simulation_budget", payload.get("simulation_budget", null)),
		"seconds": param_payload.get("seconds", payload.get("seconds", null)),
		"max_depth": param_payload.get("max_depth", payload.get("max_depth", null)),
		"deterministic": param_payload.get("deterministic", payload.get("deterministic", null)),
		"heuristic_variant": str(param_payload.get(
			"heuristic_variant",
			payload.get("heuristic_variant", NativeChallengeAI.DEFAULT_HEURISTIC_VARIANT),
		)),
		"dynamic_budget": _copy_dynamic_budget(param_payload.get(
			"dynamic_budget",
			payload.get("dynamic_budget", null),
		)),
		"per_deck_overrides": Dictionary(per_deck_payload if per_deck_payload is Dictionary else {}).duplicate(true),
	}
	return strategy


func _public_strategy(strategy: Dictionary) -> Dictionary:
	var effective := _strategy_params(strategy, "")
	return {
		"id": strategy.get("id", ""),
		"label": strategy.get("label", ""),
		"path": strategy.get("path", ""),
		"mode": strategy.get("mode", "challenge"),
		"preset": strategy.get("preset", NativeChallengeAI.STRONGEST_DIFFICULTY),
		"simulation_budget": strategy.get("simulation_budget", null),
		"seconds": strategy.get("seconds", null),
		"max_depth": strategy.get("max_depth", null),
		"deterministic": strategy.get("deterministic", null),
		"heuristic_variant": strategy.get("heuristic_variant", NativeChallengeAI.DEFAULT_HEURISTIC_VARIANT),
		"dynamic_budget": _copy_dynamic_budget(strategy.get("dynamic_budget", null)),
		"effective_default": effective,
		"per_deck_overrides": strategy.get("per_deck_overrides", {}),
	}


func _strategy_params(strategy: Dictionary, deck_key: String) -> Dictionary:
	var params_cache: Dictionary = Dictionary(strategy.get("_params_cache", {}))
	if params_cache.has(deck_key):
		return Dictionary(params_cache[deck_key]).duplicate(true)
	var preset_name := str(strategy.get("preset", NativeChallengeAI.STRONGEST_DIFFICULTY))
	var preset := NativeChallengeAI.strongest_preset()
	if NativeChallengeAI.DIFFICULTIES.has(preset_name):
		preset = Dictionary(NativeChallengeAI.DIFFICULTIES[preset_name]).duplicate(true)
	var params := {
		"simulation_budget": int(preset.get("simulations", 1)),
		"seconds": float(preset.get("seconds", 0.0)),
		"max_depth": int(preset.get("depth", 1)),
		"deterministic": false,
		"heuristic_variant": NativeChallengeAI.DEFAULT_HEURISTIC_VARIANT,
		"dynamic_budget": {},
	}
	if str(strategy.get("mode", "challenge")) == "deep":
		params["simulation_budget"] = NativeChallengeAI.DEEP_DEFAULT_SIMULATIONS
		params["seconds"] = NativeChallengeAI.DEEP_DEFAULT_SECONDS
		params["max_depth"] = NativeChallengeAI.DEEP_DEFAULT_DEPTH
	_apply_strategy_overrides(params, strategy)
	var per_deck := Dictionary(strategy.get("per_deck_overrides", {}))
	if per_deck.get(deck_key) is Dictionary:
		_apply_strategy_overrides(params, Dictionary(per_deck[deck_key]))
	params["simulation_budget"] = maxi(1, int(params["simulation_budget"]))
	params["seconds"] = max(0.0, float(params["seconds"]))
	params["max_depth"] = maxi(1, int(params["max_depth"]))
	params["deterministic"] = bool(params["deterministic"])
	params["heuristic_variant"] = str(params.get(
		"heuristic_variant",
		NativeChallengeAI.DEFAULT_HEURISTIC_VARIANT,
	))
	params["dynamic_budget"] = _copy_dynamic_budget(params.get("dynamic_budget", {}))
	params_cache[deck_key] = params.duplicate(true)
	strategy["_params_cache"] = params_cache
	return params.duplicate(true)


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
	if source.get("heuristic_variant") != null:
		params["heuristic_variant"] = str(source["heuristic_variant"])
	if source.get("dynamic_budget") != null:
		params["dynamic_budget"] = _copy_dynamic_budget(source["dynamic_budget"])


func _copy_dynamic_budget(value: Variant) -> Variant:
	if value is Dictionary:
		return Dictionary(value).duplicate(true)
	if value is bool:
		return bool(value)
	return {}


func _strategy_mode(strategy: Dictionary) -> String:
	return "deep" if str(strategy.get("mode", "challenge")) == "deep" else "challenge"


func _deep_inference_for_deck(deck_key: String) -> Variant:
	if _deep_unavailable.has(deck_key):
		return null
	if _deep_runtime_cache.has(deck_key):
		var cached: DeepAIRuntime = _deep_runtime_cache[deck_key]
		return cached.get_backend()
	var runtime := DeepAIRuntime.new()
	if not runtime.load_for_deck(deck_key):
		_deep_unavailable[deck_key] = runtime.last_error
		return null
	_deep_runtime_cache[deck_key] = runtime
	return runtime.get_backend()


func _strategy_inference(strategy: Dictionary, deck_key: String) -> Variant:
	if _strategy_mode(strategy) != "deep":
		return null
	return _deep_inference_for_deck(deck_key)


func _jsonl_path(path: String) -> String:
	if path.is_empty():
		return ""
	if path.is_absolute_path():
		return path
	return ProjectSettings.globalize_path(path)


func _append_jsonl(path: String, row: Dictionary) -> void:
	var resolved := _jsonl_path(path)
	if resolved.is_empty() or row.is_empty():
		return
	var directory := resolved.get_base_dir()
	if not directory.is_empty():
		DirAccess.make_dir_recursive_absolute(directory)
	var file := FileAccess.open(resolved, FileAccess.READ_WRITE)
	if file == null:
		file = FileAccess.open(resolved, FileAccess.WRITE)
	if file == null:
		push_error("Failed to write distill JSONL: %s" % resolved)
		return
	file.seek_end()
	file.store_line(JSON.stringify(row))
	file.close()


func _add_distill_context(
	row: Dictionary,
	seed: int,
	seed_block: int,
	seat: int,
	matchup_key: String,
	matchup_kind: String,
	strategy_a_deck: String,
	strategy_b_deck: String,
) -> void:
	if row.is_empty():
		return
	row["seed"] = seed
	row["seed_block"] = seed_block
	row["seat"] = seat
	row["matchup_key"] = matchup_key
	row["matchup_kind"] = matchup_kind
	row["strategy_a_deck"] = strategy_a_deck
	row["strategy_b_deck"] = strategy_b_deck


func _distill_action_row(
	state: GameState,
	actor: int,
	deck_key: String,
	actions: Array[GameAction],
	decision: Dictionary,
	catalog: CardCatalog,
	strategy: Dictionary,
) -> Dictionary:
	if not decision.has("action"):
		return {}
	var selected := GameAction.from_dict(decision["action"])
	var target_index := _find_action_match_index(selected, actions)
	if target_index < 0:
		return {}
	var observation := AIObservationBuilder.build(state, actor)
	var encoder := AIActionEncoder.new(catalog)
	var encoded_state := encoder.encode_observation(observation, deck_key)
	var action_numeric: Array = []
	var action_cards: Array[int] = []
	for action in actions:
		var encoded := encoder.encode_action(observation, action, deck_key)
		action_numeric.append(encoded["numeric"])
		action_cards.append(int(encoded["card_id"]))
	return {
		"kind": "action",
		"deck_key": deck_key,
		"actor": actor,
		"phase": state.phase,
		"turn_number": state.turn_number,
		"revision": state.revision,
		"strategy_id": str(strategy.get("id", "")),
		"strategy_mode": _strategy_mode(strategy),
		"state_numeric": encoded_state["numeric"],
		"state_card_ids": encoded_state["card_ids"],
		"candidate_action_numeric": action_numeric,
		"candidate_action_cards": action_cards,
		"target_index": target_index,
		"elapsed_ms": float(decision.get("elapsed_ms", 0.0)),
		"simulations": int(decision.get("simulations", 0)),
	}


func _distill_choice_row(
	state: GameState,
	request: ChoiceRequest,
	actor: int,
	deck_key: String,
	choice_result: Dictionary,
	catalog: CardCatalog,
	strategy: Dictionary,
) -> Dictionary:
	if request.options.is_empty() or not choice_result.has("choice_response"):
		return {}
	var response := ChoiceResponse.from_dict(choice_result["choice_response"])
	if response.option_ids.is_empty():
		return {}
	var target_index := -1
	for index in range(request.options.size()):
		if str(request.options[index].get("option_id", "")) == str(response.option_ids[0]):
			target_index = index
			break
	if target_index < 0:
		return {}
	var observation := AIObservationBuilder.build(state, actor)
	var encoder := AIActionEncoder.new(catalog)
	var encoded_state := encoder.encode_observation(observation, deck_key)
	var choice_numeric: Array = []
	var choice_cards: Array[int] = []
	for index in range(request.options.size()):
		var encoded := encoder.encode_choice(observation, request, request.options[index], index)
		choice_numeric.append(encoded["numeric"])
		choice_cards.append(int(encoded["card_id"]))
	return {
		"kind": "choice",
		"deck_key": deck_key,
		"actor": actor,
		"request_type": request.request_type,
		"phase": state.phase,
		"turn_number": state.turn_number,
		"revision": state.revision,
		"strategy_id": str(strategy.get("id", "")),
		"strategy_mode": _strategy_mode(strategy),
		"state_numeric": encoded_state["numeric"],
		"state_card_ids": encoded_state["card_ids"],
		"candidate_choice_numeric": choice_numeric,
		"candidate_choice_cards": choice_cards,
		"target_index": target_index,
		"elapsed_ms": float(choice_result.get("elapsed_ms", 0.0)),
	}


func _find_action_match_index(selected: GameAction, actions: Array[GameAction]) -> int:
	for index in range(actions.size()):
		var candidate := actions[index]
		if candidate.action == selected.action and _deep_equal(candidate.params, selected.params):
			return index
	return -1


func _play_match(
	catalog: CardCatalog,
	engine: GameEngine,
	worker: NativeChallengeAI,
	strategy_a_deck: String,
	strategy_b_deck: String,
	strategy_a: Dictionary,
	strategy_b: Dictionary,
	seed: int,
	seed_block: int,
	seat: int,
	forced_first: int,
	max_actions: int,
	matchup_kind: String,
	task_index: int,
	task_shard_index: int,
	task_shard_count: int,
	performance_profile: Dictionary,
	disable_ai_cache: bool,
	disable_native_math: bool,
	distill_output: String,
) -> Dictionary:
	var started_ms := Time.get_ticks_msec()
	var strategy_a_player := 0 if seat == 0 else 1
	var player_decks: Array[String] = []
	if strategy_a_player == 0:
		player_decks.assign([strategy_a_deck, strategy_b_deck])
	else:
		player_decks.assign([strategy_b_deck, strategy_a_deck])
	var state := GameState.new()
	state.public_deck_keys = player_decks
	var rng := PortableRandomSource.new(seed)
	var setup_started := _perf_start(performance_profile)
	var setup := engine.setup_game(
		state,
		catalog.expand_deck(player_decks[0]),
		catalog.expand_deck(player_decks[1]),
		rng,
		forced_first,
	)
	_perf_add_elapsed(performance_profile, "runner_setup_game_ms", setup_started)
	if not setup.success:
		_perf_count(performance_profile, "matches_failed_setup")
		return _failed_match_row(
			strategy_a_deck,
			strategy_b_deck,
			player_decks,
			seed,
			seed_block,
			seat,
			strategy_a_player,
			forced_first,
			matchup_kind,
			task_index,
			task_shard_index,
			task_shard_count,
			"setup_failed",
			setup.message,
		)
	state.public_deck_keys = player_decks
	var matchup_key := _matchup_key(strategy_a_deck, strategy_b_deck)

	var actions_taken := 0
	var decisions := 0
	var choices := 0
	var total_decision_ms := 0.0
	var decision_diagnostics := _empty_diagnostic_counts()
	var decision_diagnostics_by_strategy := {
		"A": _empty_diagnostic_counts(),
		"B": _empty_diagnostic_counts(),
	}
	var time_capped_decisions := 0
	var dynamic_budget_stop_reasons := {}
	var deep_fallbacks := 0
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
			var choice_deck_key := str(player_decks[choice_actor])
			var choice_result := _decide_choice(
				worker, state, pending, choice_actor, choice_deck_key,
				choice_strategy, seed, actions_taken + choices,
				_perf_enabled(performance_profile), disable_ai_cache, disable_native_math)
			total_decision_ms += float(choice_result.get("elapsed_ms", 0.0))
			_merge_decision_profile(performance_profile, choice_result.get("profile", {}))
			if bool(choice_result.get("deep_fallback", false)):
				deep_fallbacks += 1
			if not bool(choice_result.get("success", false)):
				choice_failures += 1
				terminal_reason = "choice_failed"
				terminal_message = str(choice_result.get("error", "choice_failed"))
				break
			var choice_distill_row := _distill_choice_row(
				state,
				pending,
				choice_actor,
				choice_deck_key,
				choice_result,
				catalog,
				choice_strategy,
			)
			_add_distill_context(
				choice_distill_row,
				seed,
				seed_block,
				seat,
				matchup_key,
				matchup_kind,
				strategy_a_deck,
				strategy_b_deck,
			)
			_append_jsonl(distill_output, choice_distill_row)
			var response := ChoiceResponse.from_dict(choice_result["choice_response"])
			_perf_count(performance_profile, "choices")
			var choice_apply_started := _perf_start(performance_profile)
			var choice_step := engine.apply_choice(state, pending, response, rng)
			_perf_add_elapsed(performance_profile, "runner_apply_choice_ms", choice_apply_started)
			choices += 1
			if not choice_step.success:
				choice_failures += 1
				terminal_reason = "choice_failed"
				terminal_message = choice_step.message
				break
			continue

		var actor := _current_actor(state)
		var legal_started := _perf_start(performance_profile)
		var legal := engine.legal_actions(state, actor, true)
		_perf_add_elapsed(performance_profile, "runner_legal_actions_ms", legal_started)
		if legal.is_empty():
			terminal_reason = "no_legal_action"
			terminal_message = "No legal action for actor=%d phase=%s" % [actor, state.phase]
			break
		var actor_strategy := strategy_a if actor == strategy_a_player else strategy_b
		var actor_deck_key := str(player_decks[actor])
		var decide_started := _perf_start(performance_profile)
		var decision := _decide_action(
			worker, state, legal, actor, actor_deck_key, actor_strategy, seed, actions_taken,
			_perf_enabled(performance_profile), disable_ai_cache, disable_native_math)
		_perf_add_elapsed(performance_profile, "runner_decide_action_wall_ms", decide_started)
		_merge_decision_profile(performance_profile, decision.get("profile", {}))
		total_decision_ms += float(decision.get("elapsed_ms", 0.0))
		if bool(decision.get("deep_fallback", false)):
			deep_fallbacks += 1
		decisions += 1
		_perf_count(performance_profile, "decisions")
		var requested_budget := int(_strategy_params(actor_strategy, actor_deck_key).get("simulation_budget", 1))
		var budget_stop_reason := str(decision.get("budget_stop_reason", ""))
		if budget_stop_reason.is_empty() and int(decision.get("simulations", requested_budget)) < requested_budget:
			budget_stop_reason = "deadline"
		if not budget_stop_reason.is_empty():
			dynamic_budget_stop_reasons[budget_stop_reason] = (
				int(dynamic_budget_stop_reasons.get(budget_stop_reason, 0)) + 1
			)
		if budget_stop_reason == "deadline":
			time_capped_decisions += 1
		if not bool(decision.get("success", false)):
			rule_exceptions += 1
			terminal_reason = "decision_failed"
			terminal_message = str(decision.get("error", "decision_failed"))
			break
		var action_distill_row := _distill_action_row(
			state,
			actor,
			actor_deck_key,
			legal,
			decision,
			catalog,
			actor_strategy,
		)
		_add_distill_context(
			action_distill_row,
			seed,
			seed_block,
			seat,
			matchup_key,
			matchup_kind,
			strategy_a_deck,
			strategy_b_deck,
		)
		_append_jsonl(distill_output, action_distill_row)
		var action := GameAction.from_dict(decision["action"])
		var diagnose_started := _perf_start(performance_profile)
		var diagnostics := worker.diagnose_decision(
			state,
			actor,
			action,
			legal,
			actor_deck_key,
			catalog,
			engine,
			seed + actions_taken * 65537 + actor,
			str(_strategy_params(actor_strategy, actor_deck_key).get(
				"heuristic_variant",
				NativeChallengeAI.DEFAULT_HEURISTIC_VARIANT,
			)),
		)
		_merge_diagnostic_counts(decision_diagnostics, diagnostics)
		var actor_strategy_label := "A" if actor == strategy_a_player else "B"
		_merge_diagnostic_counts(decision_diagnostics_by_strategy[actor_strategy_label], diagnostics)
		_perf_add_elapsed(performance_profile, "runner_diagnose_ms", diagnose_started)
		if not _action_matches_legal(action, legal):
			invalid_actions += 1
		action.action_id = "eval:%d:%d:%d" % [state.revision, actions_taken, actor]
		var apply_started := _perf_start(performance_profile)
		var step := engine.apply_action(state, action, rng)
		_perf_add_elapsed(performance_profile, "runner_apply_action_ms", apply_started)
		actions_taken += 1
		if not step.success:
			invalid_actions += 1
			terminal_reason = "illegal_action"
			terminal_message = step.message
			break

	if terminal_reason.is_empty():
		terminal_reason = "game_over" if state.winner >= 0 else "max_actions"
	_perf_count(performance_profile, "matches")
	_perf_count(performance_profile, "actions", actions_taken)
	var winner := _winner_label(state.winner, strategy_a_player)
	var score_started := _perf_start(performance_profile)
	var score := _score_state(state, strategy_a_player, catalog)
	_perf_add_elapsed(performance_profile, "runner_score_state_ms", score_started)
	var pair_key := _pair_key_for_values(strategy_a_deck, strategy_b_deck, seed_block, seed)
	return {
		"deck": strategy_a_deck,
		"strategy_a_deck": strategy_a_deck,
		"strategy_b_deck": strategy_b_deck,
		"player_decks": player_decks,
		"matchup_key": matchup_key,
		"matchup_kind": matchup_kind,
		"task_index": task_index,
		"task_shard_index": task_shard_index,
		"task_shard_count": task_shard_count,
		"pair_key": pair_key,
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
		"decision_diagnostics": decision_diagnostics,
		"decision_diagnostics_by_strategy": decision_diagnostics_by_strategy,
		"invalid_actions": invalid_actions,
		"choice_failures": choice_failures,
		"rule_exceptions": rule_exceptions,
		"time_capped_decisions": time_capped_decisions,
		"dynamic_budget_stop_reasons": dynamic_budget_stop_reasons,
		"deep_fallbacks": deep_fallbacks,
		"max_actions_exhausted": terminal_reason == "max_actions",
	}


func _failed_match_row(
	strategy_a_deck: String,
	strategy_b_deck: String,
	player_decks: Array[String],
	seed: int,
	seed_block: int,
	seat: int,
	strategy_a_player: int,
	forced_first: int,
	matchup_kind: String,
	task_index: int,
	task_shard_index: int,
	task_shard_count: int,
	reason: String,
	message: String,
) -> Dictionary:
	var matchup_key := _matchup_key(strategy_a_deck, strategy_b_deck)
	return {
		"deck": strategy_a_deck,
		"strategy_a_deck": strategy_a_deck,
		"strategy_b_deck": strategy_b_deck,
		"player_decks": player_decks,
		"matchup_key": matchup_key,
		"matchup_kind": matchup_kind,
		"task_index": task_index,
		"task_shard_index": task_shard_index,
		"task_shard_count": task_shard_count,
		"pair_key": _pair_key_for_values(strategy_a_deck, strategy_b_deck, seed_block, seed),
		"seed": seed,
		"seed_block": seed_block,
		"seat": seat,
		"strategy_a_player": strategy_a_player,
		"forced_first_player": forced_first,
		"strategy_a_first": strategy_a_player == forced_first,
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
		"decision_diagnostics": _empty_diagnostic_counts(),
		"decision_diagnostics_by_strategy": {
			"A": _empty_diagnostic_counts(),
			"B": _empty_diagnostic_counts(),
		},
		"invalid_actions": 0,
		"choice_failures": 0,
		"rule_exceptions": 1,
		"time_capped_decisions": 0,
		"dynamic_budget_stop_reasons": {},
		"deep_fallbacks": 0,
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
	profile_enabled: bool,
	disable_ai_cache: bool,
	disable_native_math: bool,
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
		"mode": _strategy_mode(strategy),
		"deck_key": deck_key,
		"seed": seed + action_index * 7919 + actor * 17,
		"simulation_budget": int(params["simulation_budget"]),
		"seconds": float(params["seconds"]),
		"max_depth": int(params["max_depth"]),
		"deterministic": bool(params["deterministic"]),
		"heuristic_variant": str(params.get(
			"heuristic_variant",
			NativeChallengeAI.DEFAULT_HEURISTIC_VARIANT,
		)),
		"dynamic_budget": _copy_dynamic_budget(params.get("dynamic_budget", {})),
		"profile": profile_enabled,
		"disable_cache": disable_ai_cache,
		"disable_native_math": disable_native_math,
		"actions": rows,
	}, Callable(self, "_not_cancelled"), _strategy_inference(strategy, deck_key))


func _decide_choice(
	worker: NativeChallengeAI,
	state: GameState,
	request: ChoiceRequest,
	actor: int,
	deck_key: String,
	strategy: Dictionary,
	seed: int,
	choice_index: int,
	profile_enabled: bool,
	disable_ai_cache: bool,
	disable_native_math: bool,
) -> Dictionary:
	var params := _strategy_params(strategy, deck_key)
	return worker.decide({
		"kind": "choice",
		"state": state.snapshot(),
		"choice": request.to_dict(),
		"actor": actor,
		"revision": state.revision,
		"request_id": "eval-choice:%d:%d" % [state.revision, choice_index],
		"mode": _strategy_mode(strategy),
		"deck_key": deck_key,
		"seed": seed + choice_index * 104729 + actor * 31,
		"simulation_budget": int(params["simulation_budget"]),
		"seconds": float(params["seconds"]),
		"max_depth": int(params["max_depth"]),
		"deterministic": bool(params["deterministic"]),
		"heuristic_variant": str(params.get(
			"heuristic_variant",
			NativeChallengeAI.DEFAULT_HEURISTIC_VARIANT,
		)),
		"profile": profile_enabled,
		"disable_cache": disable_ai_cache,
		"disable_native_math": disable_native_math,
	}, Callable(self, "_not_cancelled"), _strategy_inference(strategy, deck_key))


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


func _matchup_key(strategy_a_deck: String, strategy_b_deck: String) -> String:
	return "%s_vs_%s" % [strategy_a_deck, strategy_b_deck]


func _pair_key_for_values(strategy_a_deck: String, strategy_b_deck: String, seed_block: int, seed: int) -> String:
	return "%s:%s:%d:%d" % [strategy_a_deck, strategy_b_deck, seed_block, seed]


func _new_performance_profile(enabled: bool) -> Dictionary:
	return {
		"enabled": enabled,
		"segments_ms": {},
		"counts": {},
	}


func _perf_enabled(profile: Dictionary) -> bool:
	return bool(profile.get("enabled", false))


func _perf_add_ms(profile: Dictionary, key: String, elapsed_ms: float) -> void:
	if not _perf_enabled(profile):
		return
	var segments: Dictionary = profile["segments_ms"]
	segments[key] = float(segments.get(key, 0.0)) + elapsed_ms


func _perf_add_elapsed(profile: Dictionary, key: String, started_usec: int) -> void:
	if not _perf_enabled(profile):
		return
	_perf_add_ms(profile, key, float(Time.get_ticks_usec() - started_usec) / 1000.0)


func _perf_start(profile: Dictionary) -> int:
	return Time.get_ticks_usec() if _perf_enabled(profile) else 0


func _perf_count(profile: Dictionary, key: String, value: int = 1) -> void:
	if not _perf_enabled(profile):
		return
	var counts: Dictionary = profile["counts"]
	counts[key] = int(counts.get(key, 0)) + value


func _merge_decision_profile(target: Dictionary, source_variant: Variant) -> void:
	if not _perf_enabled(target) or not (source_variant is Dictionary):
		return
	var source: Dictionary = source_variant
	for key in Dictionary(source.get("segments_ms", {})).keys():
		_perf_add_ms(target, "ai_%s" % str(key), float(source["segments_ms"][key]))
	for key in Dictionary(source.get("counts", {})).keys():
		_perf_count(target, "ai_%s" % str(key), int(source["counts"][key]))


func _finalize_performance_profile(profile: Dictionary) -> Dictionary:
	if not _perf_enabled(profile):
		return {"enabled": false}
	var segments := {}
	var segment_keys: Array = Dictionary(profile.get("segments_ms", {})).keys()
	segment_keys.sort()
	for key in segment_keys:
		segments[str(key)] = _round_to(float(profile["segments_ms"][key]), 3)
	var counts := {}
	var count_keys: Array = Dictionary(profile.get("counts", {})).keys()
	count_keys.sort()
	for key in count_keys:
		counts[str(key)] = int(profile["counts"][key])
	return {
		"enabled": true,
		"segments_ms": segments,
		"counts": counts,
	}


func _task_belongs_to_range(task_index: int, task_start: int, task_count: int) -> bool:
	return task_count <= 0 or (task_index >= task_start and task_index < task_start + task_count)


func _task_belongs_to_shard(task_index: int, task_shard_index: int, task_shard_count: int) -> bool:
	return task_shard_count <= 1 or task_index % task_shard_count == task_shard_index


func _empty_diagnostic_counts() -> Dictionary:
	var result := {}
	for label in NativeChallengeAI.diagnostic_labels():
		result[str(label)] = 0
	return result


func _merge_diagnostic_counts(target: Dictionary, source: Dictionary) -> void:
	for label in NativeChallengeAI.diagnostic_labels():
		var key := str(label)
		target[key] = int(target.get(key, 0)) + int(source.get(key, 0))


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
		"dynamic_budget_stop_reasons": {},
		"deep_fallbacks": 0,
		"max_actions_exhaustions": 0,
	}


func _merge_count_dict(target: Dictionary, source: Variant) -> void:
	if not (source is Dictionary):
		return
	var source_dict := Dictionary(source)
	for key in source_dict.keys():
		var name := str(key)
		if name.is_empty():
			continue
		target[name] = int(target.get(name, 0)) + int(source_dict[key])


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
	stats["deep_fallbacks"] = int(stats["deep_fallbacks"]) + int(row.get("deep_fallbacks", 0))
	_merge_count_dict(stats["dynamic_budget_stop_reasons"], row.get("dynamic_budget_stop_reasons", {}))
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
	result["deep_fallback_rate"] = round(float(stats.get("deep_fallbacks", 0)) / float(decisions_and_choices) * 10000.0) / 10000.0
	var stop_reasons := Dictionary(stats.get("dynamic_budget_stop_reasons", {})).duplicate(true)
	var dynamic_stops := (
		int(stop_reasons.get("single_action", 0))
		+ int(stop_reasons.get("confidence", 0))
	)
	result["dynamic_budget_stop_reasons"] = stop_reasons
	result["dynamic_budget_stops"] = dynamic_stops
	result["dynamic_budget_stop_rate"] = round(float(dynamic_stops) / float(decisions) * 10000.0) / 10000.0
	result["elo_delta"] = round(_elo_delta(point_rate) * 1000.0) / 1000.0
	result.erase("decision_ms_values")
	return result


func _elo_delta(point_rate: float) -> float:
	var clamped := clampf(point_rate, 0.001, 0.999)
	return 400.0 * log(clamped / (1.0 - clamped)) / log(10.0)


func _summarize_matches(matches: Array) -> Dictionary:
	var stats := _empty_stats()
	for row in matches:
		_merge_match(stats, row)
	return _finalize_stats(stats)


func _summarize_by_deck(matches: Array) -> Dictionary:
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
	var explicit := str(row.get("pair_key", ""))
	if not explicit.is_empty():
		return explicit
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
		"strategy_a_deck": str(first.get("strategy_a_deck", first.get("deck", ""))),
		"strategy_b_deck": str(first.get("strategy_b_deck", first.get("deck", ""))),
		"matchup_key": str(first.get("matchup_key", "")),
		"matchup_kind": str(first.get("matchup_kind", "mirror")),
		"seed": int(first.get("seed", 0)),
		"seed_block": int(first.get("seed_block", 0)),
		"games": games,
		"complete": rows.size() >= 2,
		"clean": clean,
		"point_rate": _round_to(point_rate, 4),
		"point_delta": _round_to(point_rate - 0.5, 4),
		"score_delta": _round_to(score / float(games), 3),
	}


func _paired_rows(matches: Array) -> Array[Dictionary]:
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


func _group_matches_by_matchup(matches: Array) -> Dictionary:
	var groups := {}
	for row_value in matches:
		var row: Dictionary = row_value
		var key := str(row.get("matchup_key", ""))
		if key.is_empty():
			key = _matchup_key(str(row.get("deck", "")), str(row.get("deck", "")))
		if not groups.has(key):
			groups[key] = []
		var rows: Array = groups[key]
		rows.append(row)
	return groups


func _group_pairs_by_matchup(pair_rows: Array) -> Dictionary:
	var groups := {}
	for row_value in pair_rows:
		var row: Dictionary = row_value
		var key := str(row.get("matchup_key", ""))
		if key.is_empty():
			key = _matchup_key(str(row.get("deck", "")), str(row.get("deck", "")))
		if not groups.has(key):
			groups[key] = []
		var rows: Array = groups[key]
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


func _summarize_pairs(matches: Array) -> Dictionary:
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


func _apply_per_deck_paired_summaries(per_deck: Dictionary, matches: Array) -> void:
	var grouped_pairs := _group_pairs_by_deck(_paired_rows(matches))
	for deck_key in per_deck.keys():
		var pair_rows: Array = grouped_pairs.get(deck_key, [])
		var paired := _summarize_pair_rows(
			pair_rows,
			BOOTSTRAP_SEED + 1000 + absi(str(deck_key).hash()) % 100000,
		)
		_apply_paired_summary(per_deck[deck_key], paired)


func _summarize_by_matchup(matches: Array) -> Dictionary:
	var result := {}
	var grouped := _group_matches_by_matchup(matches)
	var keys := grouped.keys()
	keys.sort()
	for key in keys:
		var rows: Array = grouped[key]
		var stats := _summarize_matches(rows)
		stats["point_rate_ci95"] = _bootstrap_point_rate_ci(
			rows,
			BOOTSTRAP_SEED + absi(str(key).hash()) % 100000,
		)
		result[key] = stats
	return result


func _apply_per_matchup_paired_summaries(per_matchup: Dictionary, matches: Array) -> void:
	var grouped_pairs := _group_pairs_by_matchup(_paired_rows(matches))
	for key in per_matchup.keys():
		var pair_rows: Array = grouped_pairs.get(key, [])
		var paired := _summarize_pair_rows(
			pair_rows,
			BOOTSTRAP_SEED + 2000 + absi(str(key).hash()) % 100000,
		)
		_apply_paired_summary(per_matchup[key], paired)


func _summarize_matrix(matches: Array) -> Dictionary:
	var cells := {}
	for row in matches:
		var strategy_a_deck := str(row.get("strategy_a_deck", row.get("deck", "")))
		var strategy_b_deck := str(row.get("strategy_b_deck", row.get("deck", "")))
		if not cells.has(strategy_a_deck):
			cells[strategy_a_deck] = {}
		var deck_row: Dictionary = cells[strategy_a_deck]
		if not deck_row.has(strategy_b_deck):
			deck_row[strategy_b_deck] = []
		var rows: Array = deck_row[strategy_b_deck]
		rows.append(row)
	var result := {}
	var deck_keys := cells.keys()
	deck_keys.sort()
	for strategy_a_deck in deck_keys:
		result[strategy_a_deck] = {}
		var opponent_keys: Array = Dictionary(cells[strategy_a_deck]).keys()
		opponent_keys.sort()
		for strategy_b_deck in opponent_keys:
			result[strategy_a_deck][strategy_b_deck] = _summarize_matches(
				cells[strategy_a_deck][strategy_b_deck])
	return result


func _empty_diagnostics_summary() -> Dictionary:
	return {
		"total": 0,
		"labels": _empty_diagnostic_counts(),
		"by_strategy": {
			"A": {"total": 0, "labels": _empty_diagnostic_counts()},
			"B": {"total": 0, "labels": _empty_diagnostic_counts()},
			"delta": {"total": 0, "labels": _empty_diagnostic_counts()},
		},
	}


func _summarize_decision_diagnostics(matches: Array) -> Dictionary:
	var labels := _empty_diagnostic_counts()
	var total := 0
	var per_deck := {}
	var per_matchup := {}
	var by_strategy := {
		"A": _empty_diagnostic_counts(),
		"B": _empty_diagnostic_counts(),
	}
	for row in matches:
		var row_counts: Dictionary = row.get("decision_diagnostics", {})
		var row_by_strategy := Dictionary(row.get("decision_diagnostics_by_strategy", {}))
		var deck_key := str(row.get("strategy_a_deck", row.get("deck", "")))
		var matchup_key := str(row.get("matchup_key", ""))
		if not per_deck.has(deck_key):
			per_deck[deck_key] = _empty_diagnostic_counts()
		if not per_matchup.has(matchup_key):
			per_matchup[matchup_key] = _empty_diagnostic_counts()
		for label in NativeChallengeAI.diagnostic_labels():
			var key := str(label)
			var value := int(row_counts.get(key, 0))
			labels[key] = int(labels.get(key, 0)) + value
			per_deck[deck_key][key] = int(per_deck[deck_key].get(key, 0)) + value
			per_matchup[matchup_key][key] = int(per_matchup[matchup_key].get(key, 0)) + value
			total += value
			for strategy_key in ["A", "B"]:
				var strategy_counts := Dictionary(row_by_strategy.get(strategy_key, {}))
				by_strategy[strategy_key][key] = (
					int(by_strategy[strategy_key].get(key, 0))
					+ int(strategy_counts.get(key, 0))
				)
	var by_strategy_summary := {}
	var delta_labels := _empty_diagnostic_counts()
	for strategy_key in ["A", "B"]:
		var strategy_total := 0
		for label in NativeChallengeAI.diagnostic_labels():
			strategy_total += int(by_strategy[strategy_key].get(str(label), 0))
		by_strategy_summary[strategy_key] = {
			"total": strategy_total,
			"labels": by_strategy[strategy_key],
		}
	var delta_total := 0
	for label in NativeChallengeAI.diagnostic_labels():
		var key := str(label)
		var delta := int(by_strategy["A"].get(key, 0)) - int(by_strategy["B"].get(key, 0))
		delta_labels[key] = delta
		delta_total += delta
	by_strategy_summary["delta"] = {
		"total": delta_total,
		"labels": delta_labels,
	}
	return {
		"total": total,
		"labels": labels,
		"per_deck": per_deck,
		"per_matchup": per_matchup,
		"by_strategy": by_strategy_summary,
	}


func _empty_golden_summary() -> Dictionary:
	return {
		"total": 0,
		"passed": 0,
		"failed": 0,
		"cases": [],
	}


func _run_golden_scenarios(catalog: CardCatalog, engine: GameEngine, worker: NativeChallengeAI) -> Dictionary:
	var cases: Array[Dictionary] = []

	var ko_state := GameState.new()
	ko_state.phase = "MAIN"
	ko_state.turn_number = 5
	ko_state.first_player_idx = 1
	ko_state.active_player_idx = 0
	ko_state.public_deck_keys = ["lightning", "water"]
	ko_state.players[0].active = PokemonState.new("svl-zera")
	ko_state.players[0].active.placed_this_turn = false
	ko_state.players[0].active.energy_card_ids.assign(["sv1-ener-4", "sv1-ener-4"])
	ko_state.players[1].active = PokemonState.new("sv2-delib")
	ko_state.players[1].active.placed_this_turn = false
	var ko_action := _golden_decision_for_actions(worker, ko_state, 0, "lightning", [
		GameAction.new("END_TURN", {}, true, 0),
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0),
	], "golden-ko")
	cases.append(_golden_case(
		"immediate_ko_before_pass",
		ko_action != null and ko_action.action == "DECLARE_ATTACK",
		ko_action,
		"DECLARE_ATTACK",
	))

	var energy_state := GameState.new()
	energy_state.phase = "MAIN"
	energy_state.turn_number = 5
	energy_state.first_player_idx = 0
	energy_state.active_player_idx = 1
	energy_state.public_deck_keys = ["dragon", "lightning"]
	energy_state.players[0].active = PokemonState.new("svg-dram")
	energy_state.players[0].active.placed_this_turn = false
	energy_state.players[1].active = PokemonState.new("svl-pikaex")
	energy_state.players[1].active.placed_this_turn = false
	energy_state.players[1].active.energy_card_ids.assign(["sv1-ener-4"])
	energy_state.players[1].hand = ["sv1-ener-4"]
	var energy_action := _golden_decision_for_actions(worker, energy_state, 1, "lightning", [
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 1),
		GameAction.new("ATTACH_ENERGY", {"hand_idx": 0, "target_slot": "active"}, false, 1),
		GameAction.new("END_TURN", {}, true, 1),
	], "golden-energy")
	cases.append(_golden_case(
		"weak_attack_waits_for_core_energy",
		energy_action != null
		and energy_action.action == "ATTACH_ENERGY"
		and str(energy_action.params.get("target_slot", "")) == "active",
		energy_action,
		"ATTACH_ENERGY active",
	))

	var draw_state := GameState.new()
	draw_state.phase = "MAIN"
	draw_state.turn_number = 5
	draw_state.first_player_idx = 0
	draw_state.active_player_idx = 1
	draw_state.public_deck_keys = ["dragon", "psychic"]
	draw_state.players[0].active = PokemonState.new("svg-dram")
	draw_state.players[0].active.placed_this_turn = false
	draw_state.players[1].active = PokemonState.new("sv1-104")
	draw_state.players[1].active.placed_this_turn = false
	draw_state.players[1].active.energy_card_ids = ["sv1-ener-5"]
	draw_state.players[1].hand = ["sv1-180"]
	draw_state.players[1].deck = [
		"sv1-ener-5", "sv1-ener-5", "sv1-ener-5", "sv1-ener-5",
		"sv1-ener-5", "sv1-ener-5", "sv1-ener-5", "sv1-ener-5",
	]
	var draw_action := _golden_decision_for_actions(worker, draw_state, 1, "psychic", [
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 1),
		GameAction.new("PLAY_TRAINER", {"hand_idx": 0}, false, 1),
		GameAction.new("END_TURN", {}, true, 1),
	], "golden-draw")
	cases.append(_golden_case(
		"weak_attack_waits_for_productive_draw",
		draw_action != null and draw_action.action == "PLAY_TRAINER",
		draw_action,
		"PLAY_TRAINER",
	))

	var failed := 0
	for row in cases:
		if not bool(row.get("passed", false)):
			failed += 1
	return {
		"total": cases.size(),
		"passed": cases.size() - failed,
		"failed": failed,
		"cases": cases,
	}


func _golden_decision_for_actions(
	worker: NativeChallengeAI,
	state: GameState,
	actor: int,
	deck_key: String,
	actions: Array,
	request_id: String,
) -> GameAction:
	var rows: Array = []
	for action in actions:
		rows.append(action.to_dict())
	var result := worker.decide({
		"kind": "action",
		"state": state.snapshot(),
		"actor": actor,
		"revision": state.revision,
		"request_id": request_id,
		"mode": "challenge",
		"deck_key": deck_key,
		"seed": 20260702,
		"simulation_budget": 0,
		"seconds": 0.0,
		"max_depth": 1,
		"deterministic": true,
		"actions": rows,
	}, Callable(self, "_not_cancelled"), null)
	if not bool(result.get("success", false)):
		return null
	return GameAction.from_dict(result["action"])


func _golden_case(name: String, passed: bool, action: GameAction, expected: String) -> Dictionary:
	return {
		"name": name,
		"passed": passed,
		"expected": expected,
		"actual": _action_summary(action),
	}


func _action_summary(action: GameAction) -> String:
	if action == null:
		return "null"
	return "%s %s" % [action.action, JSON.stringify(action.params)]


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
		"mode": str(strategy.get("mode", "challenge")),
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
