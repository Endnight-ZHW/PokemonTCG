extends SceneTree


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 2:
		push_error("Expected Android SDK path and JDK path.")
		quit(2)
		return

	var editor_settings := EditorInterface.get_editor_settings()
	editor_settings.set_setting("export/android/android_sdk_path", args[0])
	editor_settings.set_setting("export/android/java_sdk_path", args[1])
	print("ANDROID_EDITOR_SETTINGS_OK")
	quit(0)
