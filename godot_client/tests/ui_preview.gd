extends SceneTree

const OUTPUT_ROOT := "res://../build/ui-preview"


func _initialize() -> void:
	root.size = Vector2i(1600, 900)
	call_deferred("_render_previews")


func _render_previews() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_ROOT))
	var packed := load("res://scenes/main/main.tscn") as PackedScene
	if packed == null:
		push_error("Unable to load main UI scene")
		quit(1)
		return
	var ui := packed.instantiate()
	root.add_child(ui)
	ui.initialize_ui()
	await process_frame
	await create_timer(0.25).timeout
	if not _capture("title.png"):
		quit(1)
		return

	ui._show_deck_select()
	await process_frame
	await create_timer(0.25).timeout
	if not _capture("decks.png"):
		quit(1)
		return

	if not ui.start_local_match_for_test("fire", "water"):
		push_error("Unable to start preview match")
		quit(1)
		return
	await process_frame
	await create_timer(0.25).timeout
	if not _capture("privacy.png"):
		quit(1)
		return

	ui._close_modal()
	ui._refresh_game()
	await process_frame
	await create_timer(0.25).timeout
	if not _capture("game.png"):
		quit(1)
		return
	root.size = Vector2i(2000, 900)
	await process_frame
	await create_timer(0.1).timeout
	if not _capture("game-20x9.png"):
		quit(1)
		return
	print("UI_PREVIEWS_OK")
	quit(0)


func _capture(filename: String) -> bool:
	var texture := root.get_texture()
	if texture == null:
		push_error("Unable to capture preview %s: viewport texture is unavailable" % filename)
		return false
	var image := texture.get_image()
	if image == null:
		push_error("Unable to capture preview %s: viewport image is unavailable" % filename)
		return false
	var result := image.save_png(ProjectSettings.globalize_path(
		"%s/%s" % [OUTPUT_ROOT, filename]))
	if result != OK:
		push_error("Unable to save preview %s" % filename)
		return false
	return true
