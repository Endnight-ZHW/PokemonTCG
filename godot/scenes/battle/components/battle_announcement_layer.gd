class_name BattleAnnouncementLayer
extends Control

const ENTER_OFFSET := Vector2(0.0, -10.0)
## These totals intentionally match PresentationDirector.ANNOUNCEMENT_DURATIONS.
## Reduced motion removes translation/fades, but retains a short semantic hold.
const MODE_TIMINGS := {
	"cinematic": Vector3(0.12, 0.26, 0.08),
	"standard": Vector3(0.10, 0.20, 0.07),
	"fast": Vector3(0.06, 0.16, 0.05),
	"reduced": Vector3(0.0, 0.22, 0.0),
}

@onready var motion_root: Control = %MotionRoot
@onready var announcement_panel: PanelContainer = %AnnouncementPanel
@onready var announcement_label: Label = %AnnouncementLabel

var current_text := ""
var _generation := 0
var _active_tween: Tween
var _active_handle: MotionHandle
var _queue: Array[Dictionary] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	announcement_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	announcement_label.mouse_filter = Control.MOUSE_FILTER_IGNORE


func show_announcement(
	text: String,
	color: Color,
	reduced_motion: bool,
) -> MotionHandle:
	var handle := MotionHandle.new()
	if text.strip_edges().is_empty():
		handle.finish()
		return handle
	_queue.append({
		"text": text,
		"color": color,
		"reduced_motion": reduced_motion,
		"handle": handle,
	})
	if _active_handle == null:
		_play_next()
	return handle


func clear() -> void:
	_generation += 1
	var queued := _queue.duplicate()
	_queue.clear()
	var active_handle := _active_handle
	_active_handle = null
	_stop_tween()
	current_text = ""
	visible = false
	if motion_root:
		motion_root.position = Vector2.ZERO
		motion_root.modulate = Color.WHITE
	# Cancel only after the local state is clean. A waiting Director can resume
	# synchronously from completed and enqueue a new event without this clear()
	# accidentally killing or hiding that new announcement.
	for row_value in queued:
		var row: Dictionary = row_value
		var queued_handle := row.get("handle") as MotionHandle
		if queued_handle != null:
			queued_handle.cancel()
	if active_handle != null:
		active_handle.cancel()


func is_presenting() -> bool:
	return _active_handle != null or not _queue.is_empty()


func pending_count() -> int:
	return _queue.size() + (1 if _active_handle != null else 0)


func _exit_tree() -> void:
	clear()


func _play_next() -> void:
	if _active_handle != null or _queue.is_empty():
		return
	if not is_inside_tree():
		clear()
		return
	var row: Dictionary = _queue.pop_front()
	var handle := row.get("handle") as MotionHandle
	if handle == null or handle.is_finished():
		_play_next()
		return
	_active_handle = handle
	var run_generation := _generation
	var text := str(row.get("text", ""))
	var color: Color = row.get("color", Color.WHITE)
	var reduced_motion := bool(row.get("reduced_motion", false))
	var timings := _timings(reduced_motion)
	var enter_duration := timings.x
	var hold_duration := timings.y
	var exit_duration := timings.z

	current_text = text
	announcement_label.text = text
	announcement_label.add_theme_color_override("font_color", color)
	announcement_label.add_theme_color_override(
		"font_outline_color",
		Color(0.005, 0.012, 0.025, 0.96),
	)
	announcement_panel.add_theme_stylebox_override(
		"panel",
		_announcement_style(color),
	)
	visible = true
	motion_root.position = Vector2.ZERO if reduced_motion else ENTER_OFFSET
	motion_root.modulate = Color.WHITE if reduced_motion else Color(1, 1, 1, 0)

	_active_tween = create_tween()
	if reduced_motion:
		_active_tween.tween_interval(hold_duration)
	else:
		_active_tween.set_parallel(true)
		_active_tween.tween_property(
			motion_root,
			"position",
			Vector2.ZERO,
			enter_duration,
		).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		_active_tween.tween_property(
			motion_root,
			"modulate:a",
			1.0,
			enter_duration,
		).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		_active_tween.chain().tween_interval(hold_duration)
	_active_tween.chain().tween_property(
		motion_root,
		"modulate:a",
		0.0,
		exit_duration,
	)
	handle.completed.connect(
		_on_active_completed.bind(run_generation),
		CONNECT_ONE_SHOT,
	)
	handle.bind_tween(_active_tween)


func _on_active_completed(
	handle: MotionHandle,
	expected_generation: int,
) -> void:
	if expected_generation != _generation or handle != _active_handle:
		return
	_active_tween = null
	_active_handle = null
	current_text = ""
	visible = false
	motion_root.position = Vector2.ZERO
	motion_root.modulate = Color.WHITE
	# Defer so a Director waiting on this handle can synchronously enqueue the
	# next semantic event without racing this Tween's finished callback.
	call_deferred("_play_next")


func _stop_tween() -> void:
	if _active_tween != null and _active_tween.is_valid():
		_active_tween.kill()
	_active_tween = null


func _timings(reduced_motion: bool) -> Vector3:
	if reduced_motion:
		return MODE_TIMINGS["reduced"]
	var mode := "cinematic"
	var settings := get_tree().root.get_node_or_null("AppSettings") if get_tree() else null
	if settings != null:
		mode = str(settings.get("animation_mode"))
	return MODE_TIMINGS.get(mode, MODE_TIMINGS["cinematic"])


func _announcement_style(accent: Color) -> StyleBoxFlat:
	var style := DesignTokens.panel_style(
		Color(0.018, 0.038, 0.070, 0.96),
		12,
		accent.darkened(0.08),
		1,
		10,
	)
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.46)
	style.shadow_size = 10
	style.shadow_offset = Vector2(0.0, 4.0)
	return style
