class_name PausePanel
extends VBoxContainer

signal help_requested


func configure(message: String) -> void:
	(get_node("Message") as Label).text = message
	var button := get_node("HelpButton") as Button
	if not button.pressed.is_connected(help_requested.emit):
		button.pressed.connect(help_requested.emit)
