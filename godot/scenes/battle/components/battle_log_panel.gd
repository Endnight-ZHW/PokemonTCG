class_name BattleLogPanel
extends PanelContainer

@onready var log_label: RichTextLabel = %LogLabel


func _ready() -> void:
	_resolve_nodes()
	_configure_label()
	resized.connect(_on_resized)


func update_entries(action_log: Array) -> void:
	_resolve_nodes()
	_configure_label()
	if action_log.is_empty():
		visible = false
		log_label.text = ""
		return
	var lines: Array[String] = []
	for index in range(action_log.size()):
		lines.append("- " + _single_line(str(action_log[index])))
	visible = not lines.is_empty()
	log_label.text = "\n".join(lines)
	call_deferred("_scroll_to_latest")


func _resolve_nodes() -> void:
	log_label = get_node("Content/LogLabel") as RichTextLabel


func _configure_label() -> void:
	if log_label == null:
		return
	log_label.bbcode_enabled = false
	log_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	log_label.scroll_active = true
	log_label.scroll_following = true


func _single_line(value: String) -> String:
	return value.replace("\r\n", " ").replace("\n", " ").replace("\r", " ").strip_edges()


func _scroll_to_latest() -> void:
	if log_label == null:
		return
	log_label.scroll_to_line(maxi(0, log_label.get_line_count() - 1))


func _on_resized() -> void:
	if visible and log_label and not log_label.text.is_empty():
		call_deferred("_scroll_to_latest")
