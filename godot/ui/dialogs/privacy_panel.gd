class_name PrivacyPanel
extends VBoxContainer


func configure(body_text: String) -> void:
	(get_node("Body") as Label).text = body_text
