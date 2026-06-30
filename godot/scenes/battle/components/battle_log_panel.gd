class_name BattleLogPanel
extends PanelContainer

const MIN_VISIBLE_ENTRIES := 4
const MAX_VISIBLE_ENTRIES := 7

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
	var start := maxi(0, action_log.size() - _entry_limit())
	var lines: Array[String] = []
	for index in range(start, action_log.size()):
		lines.append("[color=#62d7ff]◆[/color] " + str(action_log[index]))
	visible = not lines.is_empty()
	log_label.text = "\n".join(lines)
	call_deferred("_scroll_to_latest")


func _resolve_nodes() -> void:
	log_label = get_node("Content/LogLabel") as RichTextLabel


func _configure_label() -> void:
	if log_label == null:
		return
	log_label.bbcode_enabled = true
	log_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	log_label.scroll_active = true
	log_label.scroll_following = true


func _entry_limit() -> int:
	var line_height := 17.0
	if log_label:
		line_height = maxf(
			line_height,
			float(log_label.get_theme_font_size("normal_font_size")) * 1.45,
		)
	var available_height := maxf(0.0, size.y - 48.0)
	var estimated := int(floor(available_height / line_height))
	return clampi(estimated, MIN_VISIBLE_ENTRIES, MAX_VISIBLE_ENTRIES)


func _scroll_to_latest() -> void:
	if log_label == null:
		return
	log_label.scroll_to_line(maxi(0, log_label.get_line_count() - 1))


func _on_resized() -> void:
	if visible and log_label and not log_label.text.is_empty():
		call_deferred("_scroll_to_latest")
