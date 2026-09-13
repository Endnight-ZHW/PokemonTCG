extends SceneTree

var failures: Array[String] = []

func _initialize() -> void: call_deferred("run")

func check(condition: bool, message: String) -> void:
	if not condition: failures.append(message)

func run() -> void:
	var native_session := NativeRulesSessionAdapter.new()
	var result := native_session.start_match("fire", "water", 20260623, 0)
	check(result.success and result.message == "match_created", "Localization changed the native rules result or its protocol key")
	var main := load("res://scenes/main/main.tscn").instantiate() as Control
	# This contract exercises notifications, not the headless audio mixer.
	var quiet_audio := GDScript.new()
	quiet_audio.source_code = "extends AudioDirector\nfunc play_music(_track: String) -> void:\n\tpass\n"
	check(quiet_audio.reload() == OK, "Could not isolate notification checks from background music")
	main.get_node("AudioDirector").set_script(quiet_audio)
	root.add_child(main)
	await process_frame
	var rows := {"action_applied": "操作已完成。", "choice_applied": "选择已结算。", "stale_revision": "局面已更新，请重新选择操作。", "pending_choice": "请先完成当前选择。", "unrecognized_native_error": "操作未能完成，请重试。"}
	for key in rows:
		main.shell_view.show_toast(key, not key.ends_with("_applied"))
		check(main.toast_label.text == rows[key], "The visible toast leaks a native result key: " + key)
	for unchanged in ["操作已完成。", "玩家_a 已连接。", "Relay", "https://example.com/my_room", "PokemonTCG"]:
		check(PlayerFacingText.message(unchanged) == unchanged, "Localization rewrites a user name, URL or product name")
	var choice := load("res://ui/dialogs/choice_panel.tscn").instantiate() as ChoicePanel
	root.add_child(choice)
	choice.show_blocked_reason("invalid_choice")
	check(choice.blocked_reason_label.text == "该选项当前不可用，请重新选择。", "Choice error still displays its internal key")
	choice.queue_free()
	main.queue_free()
	await process_frame
	for failure in failures: push_error(failure)
	if failures.is_empty(): print("PLAYER_FACING_TEXT_OK")
	quit(0 if failures.is_empty() else 1)
