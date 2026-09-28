class_name BattleEffectLayer
extends Control

var table: BattleTable
var floating_texts: Array[Dictionary] = []
var static_outlines: Dictionary = {}
const MAX_FLOATING_TEXTS := 18
const FLOATING_TEXT_FONT := preload("res://assets/ui/fonts/noto_sans_cjk_sc_bold.tres")



func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)


func configure(owner_table: BattleTable) -> void:
	table = owner_table


func floating_text(
	text: String,
	position_value: Vector2,
	color: Color,
	drift: bool = true,
	motion_window: float = -1.0,
	font_size: int = 28,
	target_rect: Rect2 = Rect2(),
) -> MotionHandle:
	while floating_texts.size() >= MAX_FLOATING_TEXTS:
		var removed: Dictionary = floating_texts.pop_front()
		var removed_handle := removed.get("motion_handle") as MotionHandle
		if removed_handle != null:
			removed_handle.cancel()
	var handle := MotionHandle.new()
	var motion_duration := _floating_motion_duration(drift)
	if motion_window >= 0.0:
		motion_duration = minf(motion_duration, motion_window)
	var extent := FLOATING_TEXT_FONT.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	var resolved_position := position_value
	var link := Vector2.INF
	if target_rect.has_area():
		resolved_position = Vector2(target_rect.end.x + extent.x * 0.5 + 14.0, target_rect.get_center().y + font_size * 0.32)
		link = Vector2(target_rect.end.x + 3.0, target_rect.get_center().y)
		if size.x > 1.0 and resolved_position.x + extent.x * 0.5 > size.x - 12.0:
			resolved_position.x = target_rect.position.x - extent.x * 0.5 - 14.0
			link.x = target_rect.position.x - 3.0
	resolved_position = _free_text_position(resolved_position, extent, font_size)
	if motion_duration <= 0.0:
		handle.finish()
	var plate := DesignTokens.panel_style(Color(DesignTokens.PANEL, 0.94), 7, Color(color, 0.40), 1, 4)
	floating_texts.append({
		"text": text,
		"font_size": font_size,
		"extent": extent,
		"link": link,
		"plate": plate,
		"numeric": text.begins_with("-") or text.begins_with("+"),
		"position": resolved_position,
		"anchor_position": position_value,
		"color": color,
		"life": 1.05,
		"total": 1.05,
		"velocity": Vector2(0.0, -38.0) if drift else Vector2.ZERO,
		"motion_remaining": motion_duration,
		"motion_total": motion_duration,
		"motion_handle": handle,
		"created_frame": Engine.get_process_frames(),
	})
	_update_processing()
	queue_redraw()
	return handle


func clear_transients() -> void:
	if table != null and table.render3d != null and table.render3d.world != null:
		table.render3d.world.feedback.clear()
	var removed_texts := floating_texts.duplicate()
	floating_texts.clear()
	static_outlines.clear()
	set_process(false)
	queue_redraw()
	# Cancel after clearing local arrays so a completion callback that advances
	# the Director cannot have its newly-created feedback erased reentrantly.
	for row_value in removed_texts:
		var row: Dictionary = row_value
		var handle := row.get("motion_handle") as MotionHandle
		if handle != null:
			handle.cancel()


func _process(delta: float) -> void:
	var had_transients := not floating_texts.is_empty() or not static_outlines.is_empty()
	for id in static_outlines.keys():
		var outline: Dictionary = static_outlines[id]
		outline.life = float(outline.life) - delta
		if float(outline.life) <= 0.0 or (outline.view as WeakRef).get_ref() == null:
			static_outlines.erase(id)
	var live_texts: Array[Dictionary] = []
	for row in floating_texts:
		row["life"] = float(row["life"]) - delta
		if float(row["life"]) <= 0.0:
			var expired_handle := row.get("motion_handle") as MotionHandle
			if expired_handle != null:
				expired_handle.finish()
			continue
		var motion_remaining := float(row.get("motion_remaining", 0.0))
		if motion_remaining > 0.0:
			var motion_step := minf(delta, motion_remaining)
			row["position"] = (
				Vector2(row["position"])
				+ Vector2(row.get("velocity", Vector2(0.0, -38.0)))
				* motion_step
			)
			motion_remaining = maxf(0.0, motion_remaining - motion_step)
			row["motion_remaining"] = motion_remaining
			if motion_remaining <= 0.0:
				var motion_handle := row.get("motion_handle") as MotionHandle
				if motion_handle != null:
					motion_handle.finish()
		live_texts.append(row)
	floating_texts = live_texts
	if had_transients:
		queue_redraw()
	_update_processing()


func _update_processing() -> void:
	set_process(not floating_texts.is_empty() or not static_outlines.is_empty())


func show_static_outline(card: CardView, color: Color) -> void:
	if card == null: return
	var style := StyleBoxFlat.new()
	style.draw_center = false
	style.border_color = color
	style.set_border_width_all(2)
	style.set_corner_radius_all(4)
	static_outlines[card.get_instance_id()] = {"view": weakref(card), "style": style,
		"life": MotionPolicy.PROFILE.reduced_announcement_hold}
	_update_processing()
	queue_redraw()


func _floating_motion_duration(drift: bool) -> float:
	if not drift or MotionPolicy.reduced():
		return 0.0
	# Finish positional writes before the shortest damage-event barrier. The text
	# may remain visible while fading, but its anchor is stable when input returns.
	# Keep more than one 30 FPS frame of headroom before the event barrier so
	# process ordering cannot produce a final positional write after input unlocks.
	return MotionPolicy.duration("damage") * 0.60


func _free_text_position(anchor: Vector2, extent: Vector2, font_size: int) -> Vector2:
	# Reserve actual text rectangles across frames, not only a same-frame offset.
	# Consecutive hits must remain legible while older results finish fading.
	for index in range(MAX_FLOATING_TEXTS):
		var band := ceili(float(index) / 2.0)
		var direction := -1.0 if index % 2 == 1 else 1.0
		var candidate := anchor + Vector2(0, direction * band * (font_size + 12.0))
		if size.x > extent.x + 24:
			candidate.x = clampf(candidate.x, extent.x * 0.5 + 12, size.x - extent.x * 0.5 - 12)
		if size.y > font_size + 24:
			candidate.y = clampf(candidate.y, font_size + 12, size.y - 12)
		var rect := Rect2(candidate - Vector2(extent.x * 0.5, font_size), Vector2(extent.x, font_size)).grow(6)
		var occupied := false
		for row in floating_texts:
			if float(row.life) < 0.12: continue
			var old_size := int(row.get("font_size", 28))
			var old_extent: Vector2 = row.get("extent", Vector2(60, old_size))
			var old_rect := Rect2(Vector2(row.position) - Vector2(old_extent.x * 0.5, old_size), Vector2(old_extent.x, old_size)).grow(6)
			if rect.intersects(old_rect):
				occupied = true
				break
		if not occupied: return candidate
	return anchor


func _draw() -> void:
	for outline in static_outlines.values():
		var card := (outline.view as WeakRef).get_ref() as CardView
		if card != null and card.is_visible_in_tree() and not card.card_id.is_empty():
			var bounds := get_global_transform_with_canvas().affine_inverse() * card.visual_global_bounds()
			draw_style_box(outline.style as StyleBoxFlat, bounds.grow(3))
	for row in floating_texts:
		var alpha := smoothstep(0.0, 0.28, float(row.life))
		var color: Color = row.color
		color.a = alpha
		var text := str(row.text)
		var position_value: Vector2 = row.position
		var text_size := int(row.get("font_size", 28))
		var total := float(row.get("motion_total", 0.0))
		var p := 1.0 - float(row.get("motion_remaining", 0.0)) / total if total > 0 else 1.0
		var display_size := int(round(text_size * (1.0 + sin(p * PI) * 0.10)))
		var width := FLOATING_TEXT_FONT.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, display_size).x
		var origin := position_value - Vector2(width * 0.5, 0)
		var link: Vector2 = row.get("link", Vector2.INF)
		if link != Vector2.INF:
			var edge := Vector2(origin.x - 5 if link.x < position_value.x else origin.x + width + 5, position_value.y - display_size * 0.32)
			draw_line(link, edge, Color(color, alpha * 0.35), 1.0, true)
			draw_circle(link, 2.0, Color(color, alpha * 0.60))
		if not bool(row.get("numeric", false)):
			var plate := row.plate as StyleBoxFlat
			plate.bg_color.a = alpha * 0.94
			plate.border_color.a = alpha * 0.40
			draw_style_box(plate, Rect2(origin - Vector2(7, display_size), Vector2(width + 14, display_size + 7)))
		draw_string(FLOATING_TEXT_FONT, origin + Vector2(0, 2), text, HORIZONTAL_ALIGNMENT_LEFT, -1, display_size, Color(DesignTokens.TEXT, alpha * 0.25))
		draw_string_outline(FLOATING_TEXT_FONT, origin, text, HORIZONTAL_ALIGNMENT_LEFT, -1, display_size, maxi(3, display_size / 12), Color(1.0, 0.976, 0.94, alpha))
		draw_string(FLOATING_TEXT_FONT, origin, text, HORIZONTAL_ALIGNMENT_LEFT, -1, display_size, color)
