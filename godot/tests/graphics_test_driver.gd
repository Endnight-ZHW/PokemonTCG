extends Node

## A minimized desktop window stops normal frame_post_draw notifications. Keep
## graphical contracts rendering offscreen without restoring or focusing it.
static func attach(tree: SceneTree) -> void:
	if DisplayServer.get_name() == "headless": return
	var driver := preload("res://tests/graphics_test_driver.gd").new() as Node
	driver.process_mode = Node.PROCESS_MODE_ALWAYS
	tree.root.add_child(driver)


func _process(_delta: float) -> void:
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_MINIMIZED:
		call_deferred("_draw_minimized_frame")


func _draw_minimized_frame() -> void:
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_MINIMIZED: return
	RenderingServer.force_draw(false)
