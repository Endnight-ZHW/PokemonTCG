extends SceneTree

const FORMAT_VERSION := 1


func _initialize() -> void:
	var config := _parse_args(OS.get_cmdline_user_args())
	var runtime_path := str(config.get("runtime_manifest", ""))
	var release_path := str(config.get("release_manifest", ""))
	var output_path := str(config.get("output", ""))
	var candidate_path := str(config.get("candidate_manifest", ""))
	if (
		runtime_path.is_empty()
		or release_path.is_empty()
		or output_path.is_empty()
		or candidate_path.is_empty()
	):
		push_error(
			"candidate_runtime_smoke requires runtime, release, candidate and output paths")
		quit(2)
		return

	var payload := CandidateRuntimeVerifier.new().verify(
		runtime_path,
		release_path,
		candidate_path,
	)
	if not _write_json(output_path, payload):
		quit(3)
		return
	print("CANDIDATE_RUNTIME_SMOKE ", JSON.stringify({
		"passed": payload["passed"],
		"platform": payload["platform"],
		"architecture": payload["architecture"],
		"models": payload["model_count"],
		"output": output_path,
	}))
	quit(0 if bool(payload["passed"]) else 1)


func _parse_args(args: Array[String]) -> Dictionary:
	var result := {}
	var index := 0
	while index < args.size():
		var key := str(args[index])
		if index + 1 >= args.size():
			break
		var value := str(args[index + 1])
		match key:
			"--runtime-manifest":
				result["runtime_manifest"] = value
			"--release-manifest":
				result["release_manifest"] = value
			"--candidate-manifest":
				result["candidate_manifest"] = value
			"--output":
				result["output"] = value
		index += 2
	return result


func _write_json(path: String, payload: Dictionary) -> bool:
	var resolved := path if path.is_absolute_path() else ProjectSettings.globalize_path(path)
	var directory := resolved.get_base_dir()
	if not directory.is_empty():
		DirAccess.make_dir_recursive_absolute(directory)
	var file := FileAccess.open(resolved, FileAccess.WRITE)
	if file == null:
		push_error("Unable to write candidate runtime evidence: %s" % resolved)
		return false
	file.store_string(JSON.stringify(payload, "\t") + "\n")
	file.close()
	return true
