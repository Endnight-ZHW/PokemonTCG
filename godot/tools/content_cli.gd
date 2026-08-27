extends SceneTree

const AUTHORING_ROOT := "res://authoring"
const CARD_ROOT := AUTHORING_ROOT + "/cards"
const DATA_ROOT := "res://data"
const EXPECTED_CARDS := 137
const EXPECTED_DECKS := 10
const EXPECTED_EFFECTS := 160
const EXPECTED_VM_DESCRIPTORS := 80


func _init() -> void:
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	var args := OS.get_cmdline_user_args()
	var command := str(args[0]).to_lower() if not args.is_empty() else "lint"
	if command not in ["lint", "status", "test", "export", "check"]:
		printerr("CONTENT_ERROR unknown command: %s" % command)
		return 2
	if not ClassDB.class_exists("NativeContentCompiler"):
		printerr("CONTENT_ERROR NativeContentCompiler is unavailable; build the native debug runtime first.")
		return 2
	var loaded := _load_authoring_bundle()
	if not bool(loaded.get("success", false)):
		printerr("CONTENT_ERROR %s" % str(loaded.get("error", "authoring_load_failed")))
		return 2
	var compiler: Variant = ClassDB.instantiate("NativeContentCompiler")
	var result: Dictionary = compiler.compile(loaded["bundle"])
	if not bool(result.get("success", false)):
		for diagnostic in result.get("diagnostics", []):
			printerr("CONTENT_DIAGNOSTIC %s" % JSON.stringify(diagnostic))
		return 1
	var finalized := _finalize_outputs(
		Dictionary(result.get("outputs", {})))
	if not bool(finalized.get("success", false)):
		printerr("CONTENT_ERROR %s" % str(finalized.get("error", "content_finalize_failed")))
		return 1
	var outputs: Dictionary = finalized["outputs"]
	var summary: Dictionary = Dictionary(result.get("summary", {})).duplicate(true)
	summary["content_fingerprint"] = str(
		Dictionary(outputs["card_ir"]).get("content_fingerprint", ""))
	summary["source_fingerprint"] = str(
		Dictionary(outputs["card_ir"]).get("source_fingerprint", ""))
	if not _summary_is_release_ready(summary):
		printerr("CONTENT_ERROR release content counts are invalid: %s" % JSON.stringify(summary))
		return 1
	if command == "status":
		if "-Json" in args or "--json" in args:
			print(JSON.stringify(summary))
		else:
			_print_summary("CONTENT_STATUS", summary)
		return 0
	if command == "test":
		var compiler_test_error := _run_compiler_tests(
			compiler, Dictionary(loaded["bundle"]), result)
		if not compiler_test_error.is_empty():
			printerr("CONTENT_ERROR %s" % compiler_test_error)
			return 1
		var card_id := _argument_value(args, "-CardId", "--card-id")
		if not card_id.is_empty() and not Dictionary(outputs["cards"]).has(card_id):
			printerr("CONTENT_ERROR unknown card id: %s" % card_id)
			return 1
		_print_summary("CONTENT_TEST_OK", summary)
		return 0
	if command == "export":
		var write_error := _write_outputs(outputs)
		if not write_error.is_empty():
			printerr("CONTENT_ERROR %s" % write_error)
			return 1
		_print_summary("CONTENT_EXPORT_OK", summary)
		return 0
	if command == "check":
		var stale := _stale_outputs(outputs)
		if not stale.is_empty():
			printerr("CONTENT_STALE %s" % ", ".join(stale))
			return 1
		_print_summary("CONTENT_CHECK_OK", summary)
		return 0
	_print_summary("CONTENT_LINT_OK", summary)
	return 0


func _run_compiler_tests(compiler: Variant, bundle: Dictionary, baseline: Dictionary) -> String:
	var contract: Dictionary = compiler.get_contract()
	if (
		str(contract.get("boundary_id", "")) != "ptcg.native_content_compiler/1"
		or str(contract.get("card_ir_format", "")) != "ptcg_card_ir/4"
		or str(contract.get("fingerprint_algorithm", "")) != "sha256-canonical-json"
	):
		return "compiler_contract_invalid"
	var repeated: Dictionary = compiler.compile(bundle.duplicate(true))
	if not bool(repeated.get("success", false)):
		return "compiler_repeat_failed"
	if _canonical_json(repeated.get("outputs", {})) != _canonical_json(baseline.get("outputs", {})):
		return "compiler_output_not_deterministic"

	var baseline_ir: Dictionary = Dictionary(Dictionary(baseline["outputs"])["card_ir"])
	var source_check := {"count": 0, "valid": true}
	_visit_source_maps(baseline_ir, source_check)
	if not bool(source_check["valid"]) or int(source_check["count"]) != EXPECTED_EFFECTS:
		return "compiler_source_map_invalid"

	var invalid_op := bundle.duplicate(true)
	if not _mutate_first_command(Dictionary(invalid_op["cards"]), "unknown_op"):
		return "compiler_test_command_missing"
	if bool(Dictionary(compiler.compile(invalid_op)).get("success", false)):
		return "compiler_accepted_unknown_vm_op"

	var invalid_branch := bundle.duplicate(true)
	if not _mutate_first_command(Dictionary(invalid_branch["cards"]), "invalid_branch"):
		return "compiler_test_branch_missing"
	if bool(Dictionary(compiler.compile(invalid_branch)).get("success", false)):
		return "compiler_accepted_invalid_branch"

	var invalid_schema := bundle.duplicate(true)
	var schema_card_keys := Dictionary(invalid_schema["cards"]).keys()
	schema_card_keys.sort()
	Dictionary(Dictionary(invalid_schema["cards"])[schema_card_keys[0]])["attacks"] = {}
	if bool(Dictionary(compiler.compile(invalid_schema)).get("success", false)):
		return "compiler_accepted_invalid_card_schema"

	var invalid_deck := bundle.duplicate(true)
	var deck_keys := Dictionary(invalid_deck["decks"]).keys()
	deck_keys.sort()
	var first_deck: Dictionary = Dictionary(invalid_deck["decks"])[deck_keys[0]]
	var deck_rows: Array = first_deck["cards"]
	Dictionary(deck_rows[0])["count"] = int(Dictionary(deck_rows[0])["count"]) + 1
	if bool(Dictionary(compiler.compile(invalid_deck)).get("success", false)):
		return "compiler_accepted_invalid_deck_size"

	var invalid_strategy := bundle.duplicate(true)
	var strategy_rows: Dictionary = Dictionary(Dictionary(invalid_strategy["strategies"])["strategies"])
	strategy_rows.erase(deck_keys[0])
	if bool(Dictionary(compiler.compile(invalid_strategy)).get("success", false)):
		return "compiler_accepted_missing_strategy"

	var invalid_strategy_card := bundle.duplicate(true)
	var strategy_catalog: Dictionary = Dictionary(
		Dictionary(invalid_strategy_card["strategies"])["strategies"])
	var strategy: Dictionary = strategy_catalog[deck_keys[0]]
	var role_keys := Dictionary(strategy["card_roles"]).keys()
	role_keys.sort()
	var role_cards: Array = Dictionary(strategy["card_roles"])[role_keys[0]]
	role_cards[0] = "__unknown_strategy_card__"
	if bool(Dictionary(compiler.compile(invalid_strategy_card)).get("success", false)):
		return "compiler_accepted_unknown_strategy_card"

	var invalid_descriptors := bundle.duplicate(true)
	Dictionary(invalid_descriptors["vm_descriptors"])["descriptor_digest"] = "0".repeat(64)
	if bool(Dictionary(compiler.compile(invalid_descriptors)).get("success", false)):
		return "compiler_accepted_invalid_descriptor_digest"

	var invalid_pointer := bundle.duplicate(true)
	var pointer_keys := Dictionary(invalid_pointer["card_sources"]).keys()
	pointer_keys.sort()
	Dictionary(Dictionary(invalid_pointer["card_sources"])[pointer_keys[0]])["pointer"] = "/wrong"
	if bool(Dictionary(compiler.compile(invalid_pointer)).get("success", false)):
		return "compiler_accepted_invalid_source_pointer"

	var moved_source := bundle.duplicate(true)
	var card_keys := Dictionary(moved_source["card_sources"]).keys()
	card_keys.sort()
	Dictionary(Dictionary(moved_source["card_sources"])[card_keys[0]])["path"] = \
		"godot/authoring/cards/moved.json"
	var moved_result: Dictionary = compiler.compile(moved_source)
	if not bool(moved_result.get("success", false)):
		return "compiler_rejected_valid_source_move"
	var moved_ir: Dictionary = Dictionary(Dictionary(moved_result["outputs"])["card_ir"])
	if str(moved_ir["content_fingerprint"]) != str(baseline_ir["content_fingerprint"]) \
		or str(moved_ir["source_fingerprint"]) == str(baseline_ir["source_fingerprint"]):
		return "compiler_source_fingerprint_scope_invalid"

	var semantic_change := bundle.duplicate(true)
	var semantic_cards: Dictionary = semantic_change["cards"]
	Dictionary(semantic_cards[card_keys[0]])["name"] = \
		str(Dictionary(semantic_cards[card_keys[0]])["name"]) + " test"
	var semantic_result: Dictionary = compiler.compile(semantic_change)
	if not bool(semantic_result.get("success", false)):
		return "compiler_rejected_valid_semantic_change"
	var semantic_ir: Dictionary = Dictionary(Dictionary(semantic_result["outputs"])["card_ir"])
	if str(semantic_ir["content_fingerprint"]) == str(baseline_ir["content_fingerprint"]) \
		or str(semantic_ir["source_fingerprint"]) != str(baseline_ir["source_fingerprint"]):
		return "compiler_content_fingerprint_scope_invalid"
	return ""


func _mutate_first_command(cards: Dictionary, mutation: String) -> bool:
	var card_keys := cards.keys()
	card_keys.sort()
	for card_id in card_keys:
		var card: Dictionary = cards[card_id]
		var command_lists: Array = [card.get("commands", [])]
		for block in card.get("attacks", []):
			command_lists.append(Dictionary(block).get("commands", []))
		for block in card.get("abilities", []):
			command_lists.append(Dictionary(block).get("commands", []))
		for commands_value in command_lists:
			if commands_value is Array and not Array(commands_value).is_empty():
				var command: Dictionary = Array(commands_value)[0]
				if mutation == "unknown_op":
					command["op"] = "__unknown_vm_op__"
				else:
					command["branches"] = {"on_heads": {"not": "an array"}}
				return true
	return false


func _visit_source_maps(value: Variant, state: Dictionary) -> void:
	if value is Dictionary:
		var row: Dictionary = value
		if row.get("source_map") is Array:
			for location_value in row["source_map"]:
				if not location_value is Dictionary:
					state["valid"] = false
					continue
				var location: Dictionary = location_value
				state["count"] = int(state["count"]) + 1
				if not str(location.get("source_path", "")).begins_with("godot/authoring/cards/") \
						or not str(location.get("pointer", "")).begins_with("/cards/"):
					state["valid"] = false
		for child in row.values():
			_visit_source_maps(child, state)
	elif value is Array:
		for child in value:
			_visit_source_maps(child, state)


func _load_authoring_bundle() -> Dictionary:
	var cards: Dictionary = {}
	var card_sources: Dictionary = {}
	var source_cards: Dictionary = {}
	var directory := DirAccess.open(CARD_ROOT)
	if directory == null:
		return {"success": false, "error": "authoring_card_directory_missing"}
	var filenames := directory.get_files()
	filenames.sort()
	for filename in filenames:
		if filename.get_extension().to_lower() != "json":
			continue
		var path := CARD_ROOT + "/" + filename
		var parsed: Variant = _read_json(path)
		if not parsed is Dictionary:
			return {"success": false, "error": "invalid_authoring_json:%s" % path}
		var document: Dictionary = parsed
		if str(document.get("format", "")) != "ptcg_card_source/1":
			return {"success": false, "error": "invalid_card_source_format:%s" % path}
		var rows: Variant = document.get("cards")
		if not rows is Dictionary:
			return {"success": false, "error": "invalid_card_source_rows:%s" % path}
		for card_id_value in rows:
			var card_id := str(card_id_value)
			if cards.has(card_id):
				return {"success": false, "error": "duplicate_card_id:%s" % card_id}
			cards[card_id] = Dictionary(rows)[card_id_value]
			card_sources[card_id] = {
				"path": "godot/authoring/cards/%s" % filename,
				"pointer": "/cards/%s" % _pointer_token(card_id),
			}
		source_cards[filename] = document
	var decks_document: Variant = _read_json(AUTHORING_ROOT + "/decks.json")
	var strategies_document: Variant = _read_json(AUTHORING_ROOT + "/ai_strategies.json")
	var descriptors_document: Variant = _read_json(AUTHORING_ROOT + "/vm_command_descriptors.json")
	if not decks_document is Dictionary or not strategies_document is Dictionary \
			or not descriptors_document is Dictionary:
		return {"success": false, "error": "invalid_authoring_catalog_document"}
	var decks: Variant = Dictionary(decks_document).get("decks")
	var strategies: Variant = Dictionary(strategies_document).get("strategies")
	var descriptors: Variant = Dictionary(descriptors_document).get("payload")
	if not decks is Dictionary or not strategies is Dictionary or not descriptors is Dictionary:
		return {"success": false, "error": "invalid_authoring_catalog_payload"}
	var bundle := {
		"cards": cards,
		"card_sources": card_sources,
		"decks": decks,
		"strategies": strategies,
		"vm_descriptors": descriptors,
	}
	return {
		"success": true,
		"bundle": bundle,
		"source_bundle": {
			"cards": source_cards,
			"decks": decks_document,
			"strategies": strategies_document,
			"descriptors": descriptors_document,
		},
	}


func _finalize_outputs(outputs: Dictionary) -> Dictionary:
	for key in ["cards", "card_ir", "decks", "ai_strategies", "vm_command_descriptors"]:
		if not outputs.get(key) is Dictionary:
			return {"success": false, "error": "compiler_output_missing:%s" % key}
	var cards: Dictionary = Dictionary(outputs["cards"]).duplicate(true)
	var card_ir: Dictionary = Dictionary(outputs["card_ir"]).duplicate(true)
	var decks: Dictionary = Dictionary(outputs["decks"]).duplicate(true)
	var strategies: Dictionary = Dictionary(outputs["ai_strategies"]).duplicate(true)
	var descriptors: Dictionary = Dictionary(outputs["vm_command_descriptors"]).duplicate(true)
	var image_mapping: Dictionary = {}
	var image_hashes: Dictionary = {}
	for card_id_value in cards:
		var card_id := str(card_id_value)
		var filename := "%s.webp" % card_id
		var path := "res://assets/cards/%s" % filename
		if not FileAccess.file_exists(path):
			return {"success": false, "error": "missing_card_image:%s" % card_id}
		image_mapping[card_id] = path
		image_hashes[card_id] = FileAccess.get_sha256(path).to_lower()
	var descriptor_digest := str(descriptors.get("descriptor_digest", ""))
	var content_fingerprint := str(card_ir.get("content_fingerprint", ""))
	var source_fingerprint := str(card_ir.get("source_fingerprint", ""))
	var contract_fingerprint := str(card_ir.get("contract_fingerprint", ""))
	for value in [content_fingerprint, source_fingerprint, contract_fingerprint]:
		if value.length() != 64 or not value.is_valid_hex_number(false):
			return {"success": false, "error": "compiler_fingerprint_invalid"}
	card_ir["descriptor_digest"] = descriptor_digest
	card_ir["used_vm_ops"] = _used_vm_ops(card_ir)
	strategies.erase("content_hash")
	strategies["content_hash"] = _canonical_json(strategies).sha256_text()
	var manifest_value: Variant = _read_json(DATA_ROOT + "/release_manifest.json")
	if not manifest_value is Dictionary:
		return {"success": false, "error": "release_manifest_missing"}
	var manifest: Dictionary = Dictionary(manifest_value).duplicate(true)
	manifest["version"] = "0.8.0"
	manifest["android_version_code"] = 9
	var schemas: Dictionary = Dictionary(manifest.get("schemas", {})).duplicate(true)
	schemas["card_ir"] = 4
	manifest["schemas"] = schemas
	var native_rules: Dictionary = Dictionary(manifest.get("native_rules", {})).duplicate(true)
	native_rules["card_ir_version"] = 4
	native_rules["card_ir_content_fingerprint"] = content_fingerprint
	native_rules["card_ir_source_fingerprint"] = source_fingerprint
	native_rules["card_ir_contract_fingerprint"] = contract_fingerprint
	native_rules["vm_descriptor_digest"] = descriptor_digest
	manifest["native_rules"] = native_rules
	return {"success": true, "outputs": {
		"cards": cards,
		"card_ir": card_ir,
		"decks": decks,
		"ai_strategies": strategies,
		"vm_command_descriptors": descriptors,
		"card_images": image_mapping,
		"card_image_hashes": image_hashes,
		"release_manifest": manifest,
	}}


func _output_paths() -> Dictionary:
	return {
		"cards": DATA_ROOT + "/cards.json",
		"card_ir": DATA_ROOT + "/card_ir_v4.json",
		"decks": DATA_ROOT + "/decks.json",
		"ai_strategies": DATA_ROOT + "/ai_strategies.json",
		"vm_command_descriptors": DATA_ROOT + "/vm_command_descriptors.json",
		"card_images": DATA_ROOT + "/card_images.json",
		"card_image_hashes": DATA_ROOT + "/card_image_hashes.json",
		"release_manifest": DATA_ROOT + "/release_manifest.json",
	}


func _write_outputs(outputs: Dictionary) -> String:
	for key_value in _output_paths():
		var key := str(key_value)
		var path := str(_output_paths()[key])
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file == null:
			return "unable_to_write:%s" % path
		file.store_string(_pretty_json(outputs[key]))
	return ""


func _stale_outputs(outputs: Dictionary) -> Array[String]:
	var stale: Array[String] = []
	var paths := _output_paths()
	for key_value in paths:
		var key := str(key_value)
		var path := str(paths[key])
		if not FileAccess.file_exists(path) \
				or FileAccess.get_file_as_string(path) != _pretty_json(outputs[key]):
			stale.append(path.trim_prefix("res://"))
	return stale


func _summary_is_release_ready(summary: Dictionary) -> bool:
	return (
		int(summary.get("card_count", -1)) == EXPECTED_CARDS
		and int(summary.get("deck_count", -1)) == EXPECTED_DECKS
		and int(summary.get("effect_count", -1)) == EXPECTED_EFFECTS
		and int(summary.get("vm_descriptor_count", -1)) == EXPECTED_VM_DESCRIPTORS
		and is_equal_approx(float(summary.get("source_map_coverage", 0.0)), 1.0)
	)


func _used_vm_ops(card_ir: Dictionary) -> Array[String]:
	var found: Dictionary = {}
	_collect_ops(card_ir.get("cards", {}), found)
	var result: Array[String] = []
	for op_value in found:
		result.append(str(op_value))
	result.sort()
	return result


func _collect_ops(value: Variant, found: Dictionary) -> void:
	if value is Dictionary:
		var row: Dictionary = value
		if row.get("op") is String and not str(row["op"]).is_empty():
			found[str(row["op"])] = true
		for child in row.values():
			_collect_ops(child, found)
	elif value is Array:
		for child in value:
			_collect_ops(child, found)


func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return _normalize_json_numbers(
		JSON.parse_string(FileAccess.get_file_as_string(path)))


func _normalize_json_numbers(value: Variant) -> Variant:
	if value is float:
		var number := float(value)
		if not is_nan(number) and not is_inf(number) and floor(number) == number:
			return int(number)
		return number
	if value is Dictionary:
		var dictionary: Dictionary = value
		for key in dictionary.keys():
			dictionary[key] = _normalize_json_numbers(dictionary[key])
		return dictionary
	if value is Array:
		var array: Array = value
		for index in range(array.size()):
			array[index] = _normalize_json_numbers(array[index])
		return array
	return value


func _canonical_json(value: Variant) -> String:
	return JSON.stringify(value, "", true, true)


func _pretty_json(value: Variant) -> String:
	return JSON.stringify(value, "  ", true, true) + "\n"


func _pointer_token(value: String) -> String:
	return value.replace("~", "~0").replace("/", "~1")


func _argument_value(args: PackedStringArray, first: String, second: String) -> String:
	for index in range(args.size() - 1):
		if args[index] in [first, second]:
			return str(args[index + 1])
	return ""


func _print_summary(prefix: String, summary: Dictionary) -> void:
	print(
		"%s cards=%d decks=%d effects=%d vm_ops=%d source_map=%.1f%% fingerprint=%s" % [
			prefix,
			int(summary.get("card_count", 0)),
			int(summary.get("deck_count", 0)),
			int(summary.get("effect_count", 0)),
			int(summary.get("vm_descriptor_count", 0)),
			float(summary.get("source_map_coverage", 0.0)) * 100.0,
			str(summary.get("content_fingerprint", "")),
		])
