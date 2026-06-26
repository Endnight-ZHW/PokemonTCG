class_name BattleLogPanel
extends PanelContainer

@onready var log_label: RichTextLabel = %LogLabel


func _ready() -> void:
	_resolve_nodes()


func update_entries(action_log: Array) -> void:
	_resolve_nodes()
	var start := maxi(0, action_log.size() - 7)
	var lines: Array[String] = []
	for index in range(start, action_log.size()):
		lines.append("[color=#62d7ff]◆[/color] " + str(action_log[index]))
	visible = not lines.is_empty()
	log_label.text = "\n".join(lines)
	log_label.scroll_to_line(maxi(0, lines.size() - 1))


func _resolve_nodes() -> void:
	log_label = get_node("Content/LogLabel") as RichTextLabel
