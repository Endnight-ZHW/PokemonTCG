class_name ScreenRouter
extends Node

var host: Control


func configure(screen_host: Control) -> void:
	host = screen_host


func clear_screen() -> void:
	if host == null:
		return
	for child in host.get_children():
		host.remove_child(child)
		child.queue_free()


func mount(scene: PackedScene) -> Node:
	if host == null or scene == null:
		return null
	clear_screen()
	var page := scene.instantiate()
	host.add_child(page)
	return page
