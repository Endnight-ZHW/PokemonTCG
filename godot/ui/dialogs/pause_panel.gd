class_name PausePanel
extends VBoxContainer


func configure(message: String) -> void:
	(get_node("Message") as Label).text = message
