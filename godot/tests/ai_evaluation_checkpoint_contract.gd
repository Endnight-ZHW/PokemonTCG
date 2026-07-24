extends SceneTree

const EVALUATION_RUNNER := preload("res://tools/ai_evaluation_runner.gd")
const CHALLENGE_AI := preload("res://ai/challenge_ai.gd")
const SIMULATION_A := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const SIMULATION_B := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
const ANALYSIS_A := "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
const ANALYSIS_B := "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
const TASK_MANIFEST := "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

var failures: Array[String] = []
var _runner: Variant
var _temporary_root := ""


func _initialize() -> void:
	_runner = EVALUATION_RUNNER.new()
	_temporary_root = ProjectSettings.globalize_path(
		"user://ai_evaluation_checkpoint_contract_%d" % OS.get_process_id())
	_remove_tree(_temporary_root)
	_check(
		DirAccess.make_dir_recursive_absolute(_temporary_root) == OK,
		"Unable to create the checkpoint contract temporary directory",
	)

	_check_corrupt_checkpoint_self_heals()
	_check_duplicate_conflict_fails_closed()
	_check_fingerprint_boundary()
	_check_cross_units_and_fifty_shards()
	_check_checkpoint_identity_sets()
	_check_invalid_seed_block_start()
	_check_decision_semantic_hash_contract()

	_remove_tree(_temporary_root)
	_runner.free()
	if failures.is_empty():
		print("AI_EVALUATION_CHECKPOINT_CONTRACT_OK ", JSON.stringify({
			"schema_version": 7,
			"evidence_units": 950,
			"logical_shards": 50,
		}))
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _check_corrupt_checkpoint_self_heals() -> void:
	var directory := _temporary_root.path_join("corrupt")
	var rows := _mirror_rows("fire", 0, 17, 0)
	var unit_id := str(_runner._evidence_unit_id(
		"mirror", "fire", "fire", 0, 17))
	_runner._had_error = false
	_check(
		bool(_runner._write_evaluation_checkpoint(
			directory,
			SIMULATION_A,
			TASK_MANIFEST,
			0,
			50,
			unit_id,
			rows,
		)),
		"Unable to write the initial checkpoint fixture",
	)
	var files := _json_files(directory)
	_check(files.size() == 1, "The initial checkpoint did not publish exactly one record")
	if files.size() != 1:
		return
	var corrupt_file := FileAccess.open(str(files[0]), FileAccess.WRITE)
	_check(corrupt_file != null, "Unable to corrupt the checkpoint fixture")
	if corrupt_file == null:
		return
	corrupt_file.store_string("{this is not valid json")
	corrupt_file.close()

	var previous_print_errors := Engine.print_error_messages
	Engine.print_error_messages = false
	var ignored: Dictionary = _runner._load_evaluation_checkpoints(
		directory, SIMULATION_A, TASK_MANIFEST, 0, 50)
	_check(ignored.is_empty(), "A corrupt checkpoint was restored")
	_check(
		bool(_runner._write_evaluation_checkpoint(
			directory,
			SIMULATION_A,
			TASK_MANIFEST,
			0,
			50,
			unit_id,
			rows,
		)),
		"A corrupt checkpoint could not be repaired",
	)
	var repaired: Dictionary = _runner._load_evaluation_checkpoints(
		directory, SIMULATION_A, TASK_MANIFEST, 0, 50)
	Engine.print_error_messages = previous_print_errors
	_check(
		repaired.size() == 1 and repaired.has(unit_id),
		"The repaired checkpoint was not reusable",
	)
	_check(
		_json_files(directory).size() == 2,
		"Checkpoint repair did not preserve the corrupt immutable record",
	)
	_check(not bool(_runner._had_error), "Corrupt checkpoint repair raised a fatal error")


func _check_duplicate_conflict_fails_closed() -> void:
	var directory := _temporary_root.path_join("conflict")
	var first_rows := _mirror_rows("water", 1, 101, 0)
	var second_rows := _mirror_rows("water", 1, 101, 1)
	var unit_id := str(_runner._evidence_unit_id(
		"mirror", "water", "water", 1, 101))
	_runner._had_error = false
	_check(
		bool(_runner._write_evaluation_checkpoint(
			directory,
			SIMULATION_A,
			TASK_MANIFEST,
			1,
			50,
			unit_id,
			first_rows,
		)),
		"Unable to write the first conflicting checkpoint fixture",
	)
	_check(
		bool(_runner._write_evaluation_checkpoint(
			directory,
			SIMULATION_A,
			TASK_MANIFEST,
			1,
			50,
			unit_id,
			second_rows,
		)),
		"Unable to write the second conflicting checkpoint fixture",
	)
	var previous_print_errors := Engine.print_error_messages
	Engine.print_error_messages = false
	var loaded: Dictionary = _runner._load_evaluation_checkpoints(
		directory, SIMULATION_A, TASK_MANIFEST, 1, 50)
	Engine.print_error_messages = previous_print_errors
	_check(
		bool(_runner._had_error),
		"Conflicting valid checkpoints did not fail closed",
	)
	_check(
		loaded.size() == 1 and loaded.has(unit_id),
		"Conflict detection accepted more than one version of an evidence unit",
	)
	_runner._had_error = false


func _check_fingerprint_boundary() -> void:
	var directory := _temporary_root.path_join("fingerprints")
	var rows := _mirror_rows("steel", 2, 202, 0)
	var unit_id := str(_runner._evidence_unit_id(
		"mirror", "steel", "steel", 2, 202))
	_check(
		bool(_runner._write_evaluation_checkpoint(
			directory,
			SIMULATION_A,
			TASK_MANIFEST,
			2,
			50,
			unit_id,
			rows,
		)),
		"Unable to write the fingerprint checkpoint fixture",
	)
	var files := _json_files(directory)
	_check(files.size() == 1, "Fingerprint checkpoint fixture is missing")
	if files.size() != 1:
		return
	var record_value: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(str(files[0])))
	_check(record_value is Dictionary, "Fingerprint checkpoint record is not valid JSON")
	if record_value is Dictionary:
		var record: Dictionary = record_value
		_check(
			not record.has("analysis_fingerprint"),
			"Checkpoint incorrectly binds analysis-only code",
		)
		_check(
			str(record.get("simulation_fingerprint", "")) == SIMULATION_A,
			"Checkpoint does not bind the simulation fingerprint",
		)
	# Changing analysis provenance leaves the simulation identity untouched.
	var analysis_before := ANALYSIS_A
	var analysis_after := ANALYSIS_B
	_check(analysis_before != analysis_after, "Analysis fingerprint fixture is ineffective")
	var analysis_reuse: Dictionary = _runner._load_evaluation_checkpoints(
		directory, SIMULATION_A, TASK_MANIFEST, 2, 50)
	var simulation_miss: Dictionary = _runner._load_evaluation_checkpoints(
		directory, SIMULATION_B, TASK_MANIFEST, 2, 50)
	_check(
		analysis_reuse.size() == 1 and analysis_reuse.has(unit_id),
		"Analysis-only changes prevented checkpoint reuse",
	)
	_check(
		simulation_miss.is_empty(),
		"A changed simulation fingerprint reused stale checkpoint evidence",
	)


func _check_cross_units_and_fifty_shards() -> void:
	var all_indices: Dictionary = {}
	var shard_counts: Array[int] = []
	shard_counts.resize(50)
	shard_counts.fill(0)
	for index in range(500):
		all_indices[index] = true
		shard_counts[index % 50] += 1
	for deck_a in range(10):
		for deck_b in range(deck_a + 1, 10):
			for block_index in range(10):
				var forward := int(_runner._cross_evidence_unit_index(
					10, 50, 10, deck_a, deck_b, block_index))
				var reverse := int(_runner._cross_evidence_unit_index(
					10, 50, 10, deck_b, deck_a, block_index))
				_check(
					forward == reverse,
					"Reciprocal cross-deck directions were assigned to different units",
				)
				_check(
					forward >= 500 and forward < 950,
					"Cross-deck evidence unit index escaped the fixed 500..949 range",
				)
				_check(
					not all_indices.has(forward),
					"Evidence unit index collision: %d" % forward,
				)
				all_indices[forward] = true
				shard_counts[forward % 50] += 1
	_check(
		all_indices.size() == 950,
		"The fixed schedule does not contain exactly 950 evidence units",
	)
	for shard_index in range(50):
		_check(
			shard_counts[shard_index] == 19,
			"Logical shard %d has %d units instead of 19" % [
				shard_index, shard_counts[shard_index]],
		)

	var cross_directory := _temporary_root.path_join("cross")
	var seed := int(_runner._cross_game_seed(17, 4, 9, 3))
	var cross_rows := _cross_rows("fire", "water", 3, seed)
	var unit_id := str(_runner._evidence_unit_id(
		"cross", "fire", "water", 3, seed))
	_check(
		int(_runner._expected_unit_games(unit_id)) == 4,
		"A cross-deck evidence unit does not require all four games",
	)
	_check(
		not bool(_runner._write_evaluation_checkpoint(
			cross_directory,
			SIMULATION_A,
			TASK_MANIFEST,
			int(_runner._cross_evidence_unit_index(10, 50, 10, 4, 9, 3)) % 50,
			50,
			unit_id,
			cross_rows.slice(0, 2),
		)),
		"A two-game half of a cross-deck closure was checkpointed",
	)
	_check(
		_json_files(cross_directory).is_empty(),
		"An incomplete cross-deck closure published a checkpoint file",
	)
	var shard_index := (
		int(_runner._cross_evidence_unit_index(10, 50, 10, 4, 9, 3)) % 50)
	_check(
		bool(_runner._write_evaluation_checkpoint(
			cross_directory,
			SIMULATION_A,
			TASK_MANIFEST,
			shard_index,
			50,
			unit_id,
			cross_rows,
		)),
		"A complete four-game cross-deck closure could not be checkpointed",
	)
	var restored: Dictionary = _runner._load_evaluation_checkpoints(
		cross_directory, SIMULATION_A, TASK_MANIFEST, shard_index, 50)
	_check(
		restored.size() == 1
		and Array(Dictionary(restored[unit_id]).get("matches", [])).size() == 4,
		"A cross-deck checkpoint did not restore all four games atomically",
	)
	_check(
		_runner._checkpoint_rows_for_pair(
			restored, unit_id, "fire", "water").size() == 2
		and _runner._checkpoint_rows_for_pair(
			restored, unit_id, "water", "fire").size() == 2,
		"The reciprocal directions were split or lost within a cross-deck unit",
	)


func _check_checkpoint_identity_sets() -> void:
	var mirror_unit := str(_runner._evidence_unit_id(
		"mirror", "psychic", "psychic", 4, 404))
	var duplicate_mirror_seat := _mirror_rows("psychic", 4, 404, 0)
	duplicate_mirror_seat[1]["seat"] = 0
	_check(
		not bool(_runner._checkpoint_rows_have_exact_unit_identities(
			mirror_unit, duplicate_mirror_seat)),
		"A mirror checkpoint accepted a duplicate seat identity",
	)

	var cross_unit := str(_runner._evidence_unit_id(
		"cross", "dragon", "steel", 5, 505))
	var missing_direction := _cross_rows("dragon", "steel", 5, 505)
	for row_value in missing_direction:
		var row: Dictionary = row_value
		row["strategy_a_deck"] = "dragon"
		row["strategy_b_deck"] = "steel"
	_check(
		not bool(_runner._checkpoint_rows_have_exact_unit_identities(
			cross_unit, missing_direction)),
		"A cross checkpoint accepted four rows from only one direction",
	)

	var duplicate_cross_seat := _cross_rows("dragon", "steel", 5, 505)
	duplicate_cross_seat[1]["seat"] = 0
	_check(
		not bool(_runner._checkpoint_rows_have_exact_unit_identities(
			cross_unit, duplicate_cross_seat)),
		"A cross checkpoint accepted a duplicate direction/seat identity",
	)
	var directory := _temporary_root.path_join("invalid-identities")
	_check(
		not bool(_runner._write_evaluation_checkpoint(
			directory,
			SIMULATION_A,
			TASK_MANIFEST,
			5,
			50,
			cross_unit,
			duplicate_cross_seat,
		)),
		"The checkpoint writer published an invalid identity set",
	)
	_check(
		_json_files(directory).is_empty(),
		"An invalid identity set left a checkpoint record on disk",
	)
	DirAccess.make_dir_recursive_absolute(directory)
	var invalid_record := {
		"schema_version": 7,
		"protocol_id": "traditional_ai_evaluation_v7",
		"artifact_kind": "ai_evaluation_checkpoint_unit",
		"simulation_fingerprint": SIMULATION_A,
		"task_manifest_id": TASK_MANIFEST,
		"evidence_shard_index": 5,
		"evidence_shard_count": 50,
		"unit_id": cross_unit,
		"expected_games": 4,
		"matches_sha256":
			_runner._checkpoint_matches_sha256(duplicate_cross_seat),
		"matches": duplicate_cross_seat,
	}
	var invalid_file := FileAccess.open(
		directory.path_join("invalid.json"), FileAccess.WRITE)
	_check(invalid_file != null, "Unable to write the invalid identity fixture")
	if invalid_file != null:
		invalid_file.store_string(JSON.stringify(invalid_record))
		invalid_file.close()
	var loaded: Dictionary = _runner._load_evaluation_checkpoints(
		directory, SIMULATION_A, TASK_MANIFEST, 5, 50)
	_check(
		loaded.is_empty(),
		"The checkpoint loader restored an invalid direction/seat identity set",
	)


func _check_decision_semantic_hash_contract() -> void:
	var ai: Variant = CHALLENGE_AI.new()
	var action := GameAction.new(
		"ATTACH_ENERGY",
		{"hand_idx": 0, "target_slot": "active"},
		false,
		0,
	)
	var planner_result := {
		"turn_plan": [{
			"signature": "attach-active",
			"action": "ATTACH_ENERGY",
			"params": {"hand_idx": 0, "target_slot": "active"},
			"expected_public_fingerprint": "public-a",
			"expected_actor": 0,
			"expected_phase": "MAIN",
		}, {
			"signature": "attack-zero",
			"action": "DECLARE_ATTACK",
			"params": {"attack_idx": 0},
			"expected_public_fingerprint": "public-b",
			"expected_actor": 0,
			"expected_phase": "MAIN",
		}],
		"root_signatures_attempted": ["root-a", "root-b"],
		"root_sample_counts": {"root-a": 3, "root-b": 3},
		"belief_seed_hash":
			"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		"nodes_expanded": 120,
		"score_milli": 9000,
		"requested_depth": 8,
		"completed_depth": 8,
		"max_path_depth": 8,
		"reply_requested_depth": 3,
		"reply_completed_depth": 3,
		"layers_completed": 8,
		"completion_reason": "depth_complete",
		"opponent_strategy_id": "water-control",
	}
	var trajectory_hash := (
		"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	planner_result["trajectory_hash"] = trajectory_hash
	var baseline := str(ai._traditional_decision_semantic_hash(
		action, "turn_beam_v2", planner_result, trajectory_hash))
	var repeated := str(ai._traditional_decision_semantic_hash(
		action, "turn_beam_v2", planner_result.duplicate(true), trajectory_hash))
	_check(
		baseline.length() == 64 and baseline == repeated,
		"Decision semantic hash is not a stable SHA-256",
	)
	var decision: Dictionary = ai._traditional_action_result(
		{},
		action,
		null,
		null,
		120,
		"depth_complete",
		false,
		planner_result,
	)
	_check(
		str(decision.get("decision_semantic_hash", "")) == baseline,
		"Traditional AI action result did not publish its semantic hash",
	)

	var changed_plan: Dictionary = planner_result.duplicate(true)
	changed_plan["turn_plan"][1]["params"]["attack_idx"] = 1
	_check(
		str(ai._traditional_decision_semantic_hash(
			action, "turn_beam_v2", changed_plan, trajectory_hash)) != baseline,
		"Decision semantic hash ignored the complete turn plan",
	)
	var changed_precondition: Dictionary = planner_result.duplicate(true)
	changed_precondition["turn_plan"][0][
		"expected_public_fingerprint"] = "changed"
	_check(
		str(ai._traditional_decision_semantic_hash(
			action,
			"turn_beam_v2",
			changed_precondition,
			trajectory_hash,
		)) != baseline,
		"Decision semantic hash ignored cache preconditions",
	)
	var changed_root_order: Dictionary = planner_result.duplicate(true)
	changed_root_order["root_signatures_attempted"].reverse()
	_check(
		str(ai._traditional_decision_semantic_hash(
			action,
			"turn_beam_v2",
			changed_root_order,
			trajectory_hash,
		)) != baseline,
		"Decision semantic hash ignored ranked root order",
	)
	var changed_sample_counts: Dictionary = planner_result.duplicate(true)
	changed_sample_counts["root_sample_counts"]["root-b"] = 2
	_check(
		str(ai._traditional_decision_semantic_hash(
			action,
			"turn_beam_v2",
			changed_sample_counts,
			trajectory_hash,
		)) != baseline,
		"Decision semantic hash ignored root sample counts",
	)
	var changed_belief: Dictionary = planner_result.duplicate(true)
	changed_belief["belief_seed_hash"] = "changed"
	_check(
		str(ai._traditional_decision_semantic_hash(
			action, "turn_beam_v2", changed_belief, trajectory_hash)) != baseline,
		"Decision semantic hash ignored belief seeds",
	)
	var different_action := GameAction.new("END_TURN", {}, true, 0)
	_check(
		str(ai._traditional_decision_semantic_hash(
			different_action,
			"turn_beam_v2",
			planner_result,
			trajectory_hash,
		)) != baseline,
		"Decision semantic hash ignored the selected action",
	)
	var runner_source := FileAccess.get_file_as_string(
		"res://tools/ai_evaluation_runner.gd")
	_check(
		runner_source.contains("\"decision_semantic_hash\""),
		"Evaluation runner does not persist decision_semantic_hash",
	)


func _check_invalid_seed_block_start() -> void:
	var provenance_path := _temporary_root.path_join("provenance.json")
	var provenance := {
		"schema_version": 7,
		"protocol_id": "traditional_ai_evaluation_v7",
		"simulation_fingerprint": SIMULATION_A,
		"analysis_fingerprint": ANALYSIS_A,
	}
	var provenance_file := FileAccess.open(provenance_path, FileAccess.WRITE)
	_check(provenance_file != null, "Unable to create the provenance fixture")
	if provenance_file == null:
		return
	provenance_file.store_string(JSON.stringify(provenance))
	provenance_file.close()
	var args: Array[String] = [
		"--deck", "fire",
		"--seed-blocks-per-deck", "1",
		"--seed-block-start", "1",
		"--seed-block-count", "1",
		"--skip-golden",
		"--provenance", provenance_path,
		"--task-manifest-id", TASK_MANIFEST,
	]
	var config: Dictionary = _runner._parse_args(args)
	_runner._had_error = false
	var previous_print_errors := Engine.print_error_messages
	Engine.print_error_messages = false
	var payload: Dictionary = _runner._run_evaluation(CardCatalog.new(), config)
	Engine.print_error_messages = previous_print_errors
	_check(
		bool(_runner._had_error),
		"seed_block_start equal to seed_blocks_per_deck was not rejected",
	)
	_check(
		Array(payload.get("matches", [])).is_empty(),
		"An invalid seed_block_start scheduled matches",
	)
	_runner._had_error = false


func _mirror_rows(
	deck_key: String,
	seed_block: int,
	seed: int,
	winner: int,
) -> Array:
	return [
		_clean_match("mirror", deck_key, deck_key, seed_block, seed, 0, winner),
		_clean_match("mirror", deck_key, deck_key, seed_block, seed, 1, winner),
	]


func _cross_rows(
	deck_a: String,
	deck_b: String,
	seed_block: int,
	seed: int,
) -> Array:
	return [
		_clean_match("cross", deck_a, deck_b, seed_block, seed, 0, 0),
		_clean_match("cross", deck_a, deck_b, seed_block, seed, 1, 1),
		_clean_match("cross", deck_b, deck_a, seed_block, seed, 0, 0),
		_clean_match("cross", deck_b, deck_a, seed_block, seed, 1, 1),
	]


func _clean_match(
	matchup_kind: String,
	deck_a: String,
	deck_b: String,
	seed_block: int,
	seed: int,
	seat: int,
	winner: int,
) -> Dictionary:
	return {
		"matchup_kind": matchup_kind,
		"deck": deck_a,
		"strategy_a_deck": deck_a,
		"strategy_b_deck": deck_b,
		"seed_block": seed_block,
		"seed": seed,
		"seat": seat,
		"winner": winner,
		"terminal_reason": "game_over",
		"invalid_actions": 0,
		"choice_failures": 0,
		"rule_exceptions": 0,
		"max_actions_exhausted": false,
	}


func _json_files(path: String) -> Array[String]:
	var result: Array[String] = []
	var directory := DirAccess.open(path)
	if directory == null:
		return result
	directory.list_dir_begin()
	while true:
		var file_name := directory.get_next()
		if file_name.is_empty():
			break
		if not directory.current_is_dir() and file_name.ends_with(".json"):
			result.append(path.path_join(file_name))
	directory.list_dir_end()
	result.sort()
	return result


func _remove_tree(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	directory.list_dir_begin()
	while true:
		var entry := directory.get_next()
		if entry.is_empty():
			break
		if entry in [".", ".."]:
			continue
		var child := path.path_join(entry)
		if directory.current_is_dir():
			_remove_tree(child)
		else:
			DirAccess.remove_absolute(child)
	directory.list_dir_end()
	DirAccess.remove_absolute(path)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
