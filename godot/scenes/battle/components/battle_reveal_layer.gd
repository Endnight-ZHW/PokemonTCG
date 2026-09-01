class_name BattleRevealLayer
extends Control

const CARD_BASE_SIZE := Vector2(100.0, 140.0)
const CARD_GAP := 14.0
const MIN_READ_HOLD := 0.90

var _showcase: Control
var _motion_handle: MotionHandle


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func present(
	rows: Array[Dictionary],
	card_back: Texture2D,
	face_textures: Array[Texture2D],
	deck_origin: Vector2,
	destination_points: Array[Vector2],
	content_rect: Rect2,
	summary: Dictionary,
	duration: float,
	reduced_motion: bool,
) -> MotionHandle:
	clear()
	var handle := MotionHandle.new()
	_motion_handle = handle
	if (
		(not rows.is_empty() and card_back == null)
		or content_rect.size == Vector2.ZERO
	):
		handle.finish()
		return handle

	var geometry := _showcase_geometry(rows.size(), content_rect)
	_showcase = _build_showcase(
		rows,
		card_back,
		face_textures,
		geometry,
		summary,
	)
	add_child(_showcase)
	var cards: Array[Control] = []
	for value in _showcase.get_meta("reveal_cards", []):
		var card := value as Control
		if card != null:
			cards.append(card)

	if reduced_motion:
		_apply_reduced_result(cards, face_textures, geometry)
		_showcase.modulate.a = 0.0
		var reduced_tween := create_tween()
		reduced_tween.tween_property(_showcase, "modulate:a", 1.0, 0.10)
		reduced_tween.tween_interval(maxf(MIN_READ_HOLD, duration - 0.20))
		reduced_tween.tween_property(_showcase, "modulate:a", 0.0, 0.10)
		handle.bind_tween(reduced_tween)
		return handle

	for card in cards:
		card.position = deck_origin - card.size * 0.5
	for node_name in ["Dimmer", "RevealPanel", "RevealTitle", "RevealSummary"]:
		var fade_node := _showcase.get_node_or_null(str(node_name)) as CanvasItem
		if fade_node != null:
			fade_node.modulate.a = 0.0
	var tween := create_tween()
	tween.tween_method(
		_update_showcase.bind(
			_showcase,
			cards,
			face_textures,
			deck_origin,
			destination_points,
			geometry,
			duration,
		),
		0.0,
		1.0,
		maxf(0.01, duration),
	).set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_IN_OUT)
	handle.bind_tween(tween)
	return handle


func clear() -> void:
	if _motion_handle != null and not _motion_handle.is_finished():
		_motion_handle.cancel()
	_motion_handle = null
	if _showcase != null and is_instance_valid(_showcase):
		_showcase.visible = false
		_showcase.free()
	_showcase = null


func is_presenting() -> bool:
	return _showcase != null and is_instance_valid(_showcase) and _showcase.visible


func _showcase_geometry(card_count: int, content_rect: Rect2) -> Dictionary:
	var available_width := maxf(220.0, content_rect.size.x - 68.0)
	var natural_width := (
		CARD_BASE_SIZE.x * float(card_count)
		+ CARD_GAP * float(maxi(0, card_count - 1))
	)
	var scale_value := minf(1.0, available_width / maxf(1.0, natural_width))
	var card_size := CARD_BASE_SIZE * maxf(0.62, scale_value)
	var gap := CARD_GAP * maxf(0.70, scale_value)
	var row_width := (
		card_size.x * float(card_count)
		+ gap * float(maxi(0, card_count - 1))
	)
	if card_count == 0:
		row_width = minf(300.0, available_width)
	var center := content_rect.get_center()
	var centers: Array[Vector2] = []
	var first_x := center.x - row_width * 0.5 + card_size.x * 0.5
	for index in range(card_count):
		centers.append(Vector2(
			first_x + float(index) * (card_size.x + gap),
			center.y,
		))
	return {
		"card_size": card_size,
		"centers": centers,
		"panel_rect": (
			Rect2(
				Vector2(center.x - row_width * 0.5 - 22.0, center.y - 58.0),
				Vector2(row_width + 44.0, 116.0),
			)
			if card_count == 0
			else Rect2(
				Vector2(
					center.x - row_width * 0.5 - 22.0,
					center.y - card_size.y * 0.5 - 44.0,
				),
				Vector2(row_width + 44.0, card_size.y + 88.0),
			)
		),
	}


func _build_showcase(
	rows: Array[Dictionary],
	card_back: Texture2D,
	face_textures: Array[Texture2D],
	geometry: Dictionary,
	summary: Dictionary,
) -> Control:
	var root := Control.new()
	root.name = "RevealShowcase"
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.z_index = 145

	var dimmer := ColorRect.new()
	dimmer.name = "Dimmer"
	dimmer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dimmer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dimmer.color = Color(0.01, 0.025, 0.055, 0.30)
	dimmer.z_index = -2
	root.add_child(dimmer)

	var panel_rect: Rect2 = geometry.get("panel_rect", Rect2())
	var panel := Panel.new()
	panel.name = "RevealPanel"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.position = panel_rect.position
	panel.size = panel_rect.size
	panel.z_index = -1
	panel.add_theme_stylebox_override(
		"panel",
		DesignTokens.panel_style(
			Color(DesignTokens.PANEL_GLASS, 0.97),
			DesignTokens.RADIUS_LARGE,
			Color(DesignTokens.CYAN, 0.48),
			1,
			0,
		),
	)
	root.add_child(panel)

	var title := Label.new()
	title.name = "RevealTitle"
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.text = str(summary.get("title", "公开翻牌"))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.position = Vector2(panel_rect.position.x + 12.0, panel_rect.position.y + 8.0)
	title.size = Vector2(panel_rect.size.x - 24.0, 28.0)
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", DesignTokens.CYAN)
	root.add_child(title)

	var summary_label := Label.new()
	summary_label.name = "RevealSummary"
	summary_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var final_summary_text := _summary_text(rows.size(), summary)
	# Do not expose the rule result while the cards are still face down.  In
	# particular, damage belongs to the later damage_dealt presentation event;
	# this layer only reports what the public reveal matched.
	summary_label.text = final_summary_text if rows.is_empty() else "正在翻牌…"
	summary_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	summary_label.position = Vector2(
		panel_rect.position.x + 12.0,
		panel_rect.end.y - 34.0,
	)
	summary_label.size = Vector2(panel_rect.size.x - 24.0, 26.0)
	summary_label.add_theme_font_size_override("font_size", 15)
	summary_label.add_theme_color_override("font_color", DesignTokens.TEXT)
	root.add_child(summary_label)
	root.set_meta("reveal_summary_text", final_summary_text)
	root.set_meta("reveal_summary_ready", rows.is_empty())

	var card_size: Vector2 = geometry.get("card_size", CARD_BASE_SIZE)
	var cards: Array[Control] = []
	for index in range(rows.size()):
		var face_texture := (
			face_textures[index]
			if index < face_textures.size() and face_textures[index] != null
			else card_back
		)
		var card := _create_card(
			card_back,
			face_texture,
			card_size,
			bool(rows[index].get("matched", false)),
			str(rows[index].get("outcome_label", "")),
		)
		card.name = "RevealCard%d" % index
		card.z_index = index
		root.add_child(card)
		cards.append(card)
	root.set_meta("reveal_cards", cards)
	return root


func _create_card(
	card_back: Texture2D,
	face_texture: Texture2D,
	size_value: Vector2,
	matched: bool,
	outcome_label: String = "",
) -> Control:
	var card := Control.new()
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.size = size_value
	card.pivot_offset = size_value * 0.5
	card.set_meta("face_texture", face_texture)
	card.set_meta("face_swapped", false)
	card.set_meta("matched", matched)

	var shadow := Panel.new()
	shadow.name = "Shadow"
	shadow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shadow.size = size_value
	var shadow_style := DesignTokens.shadow_style(12)
	shadow_style.bg_color = Color.TRANSPARENT
	shadow_style.shadow_color = Color(0.0, 0.0, 0.0, 0.58)
	shadow_style.shadow_size = 11
	shadow_style.shadow_offset = Vector2(0.0, 7.0)
	shadow.add_theme_stylebox_override("panel", shadow_style)
	card.add_child(shadow)

	var image := TextureRect.new()
	image.name = "Image"
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	image.texture = card_back
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	image.size = size_value
	card.add_child(image)

	var outline := Panel.new()
	outline.name = "OutcomeOutline"
	outline.mouse_filter = Control.MOUSE_FILTER_IGNORE
	outline.size = size_value
	outline.modulate.a = 0.0
	outline.add_theme_stylebox_override(
		"panel",
		DesignTokens.panel_style(
			Color.TRANSPARENT,
			9,
			DesignTokens.GOLD if matched else DesignTokens.TEXT_MUTED,
			3 if matched else 1,
			0,
		),
	)
	card.add_child(outline)

	var badge := Label.new()
	badge.name = "OutcomeBadge"
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.text = (
		outcome_label
		if not outcome_label.is_empty()
		else ("能量" if matched else "洗回牌库")
	)
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	badge.position = Vector2(6.0, size_value.y - 27.0)
	badge.size = Vector2(size_value.x - 12.0, 22.0)
	badge.modulate.a = 0.0
	badge.add_theme_font_size_override("font_size", 12)
	badge.add_theme_color_override(
		"font_color",
		DesignTokens.BG_DEEP if matched else DesignTokens.TEXT,
	)
	badge.add_theme_stylebox_override(
		"normal",
		DesignTokens.panel_style(
			DesignTokens.GOLD if matched else Color(DesignTokens.BG_DEEP, 0.84),
			7,
			DesignTokens.GOLD if matched else DesignTokens.BORDER,
			1,
			2,
		),
	)
	card.add_child(badge)
	return card


func _apply_reduced_result(
	cards: Array[Control],
	face_textures: Array[Texture2D],
	geometry: Dictionary,
) -> void:
	if _showcase != null and is_instance_valid(_showcase):
		var summary := _showcase.get_node_or_null("RevealSummary") as Label
		if summary != null:
			summary.text = str(_showcase.get_meta("reveal_summary_text", ""))
		_showcase.set_meta("reveal_summary_ready", true)
	var centers: Array = geometry.get("centers", [])
	for index in range(cards.size()):
		var card := cards[index]
		var center: Vector2 = centers[index] if index < centers.size() else Vector2.ZERO
		card.position = center - card.size * 0.5
		var image := card.get_node_or_null("Image") as TextureRect
		if image != null and index < face_textures.size() and face_textures[index] != null:
			image.texture = face_textures[index]
		card.set_meta("face_swapped", true)
		var outline := card.get_node_or_null("OutcomeOutline") as Panel
		if outline != null:
			outline.modulate.a = 1.0
		var badge := card.get_node_or_null("OutcomeBadge") as Label
		if badge != null:
			badge.modulate.a = 1.0


func _update_showcase(
	progress: float,
	showcase_value: Variant,
	cards: Array[Control],
	face_textures: Array[Texture2D],
	deck_origin: Vector2,
	destination_points: Array[Vector2],
	geometry: Dictionary,
	duration: float,
) -> void:
	if not is_instance_valid(showcase_value):
		return
	var showcase := showcase_value as Control
	if showcase == null:
		return
	var elapsed := clampf(progress, 0.0, 1.0) * duration
	var route_duration := minf(0.46, maxf(0.34, duration * 0.18))
	var entry_duration := minf(
		0.65,
		maxf(0.30, duration - route_duration - MIN_READ_HOLD),
	)
	var route_start := maxf(entry_duration, duration - route_duration)
	var panel_alpha := minf(1.0, elapsed / 0.12)
	if elapsed >= route_start:
		panel_alpha = 1.0 - clampf((elapsed - route_start) / route_duration, 0.0, 1.0)
	var dimmer := showcase.get_node_or_null("Dimmer") as ColorRect
	var panel := showcase.get_node_or_null("RevealPanel") as Panel
	var title := showcase.get_node_or_null("RevealTitle") as Label
	var summary := showcase.get_node_or_null("RevealSummary") as Label
	if (
		summary != null
		and not bool(showcase.get_meta("reveal_summary_ready", false))
		and elapsed >= entry_duration
	):
		summary.text = str(showcase.get_meta("reveal_summary_text", ""))
		showcase.set_meta("reveal_summary_ready", true)
	if dimmer != null:
		dimmer.modulate.a = panel_alpha
	if panel != null:
		panel.modulate.a = panel_alpha
	if title != null:
		title.modulate.a = panel_alpha
	if summary != null:
		summary.modulate.a = panel_alpha

	var centers: Array = geometry.get("centers", [])
	var max_launch_delay := minf(0.18, entry_duration * 0.28)
	var launch_step := max_launch_delay / float(maxi(1, cards.size() - 1))
	var travel_duration := maxf(0.24, entry_duration - max_launch_delay)
	for index in range(cards.size()):
		var card := cards[index]
		if card == null or not is_instance_valid(card):
			continue
		var target: Vector2 = centers[index] if index < centers.size() else deck_origin
		var launch_delay := float(index) * launch_step
		if elapsed < route_start:
			var travel_progress := clampf(
				(elapsed - launch_delay) / travel_duration,
				0.0,
				1.0,
			)
			travel_progress = _ease_out_cubic(travel_progress)
			var start := deck_origin + Vector2(float(index) * 1.4, -float(index) * 2.0)
			var control := Vector2(
				(start.x + target.x) * 0.5,
				minf(start.y, target.y) - 92.0 - float(index) * 5.0,
			)
			var point := _quadratic(start, control, target, travel_progress)
			card.position = point - card.size * 0.5
			card.rotation_degrees = lerpf(
				-7.0 + float(index) * 2.0,
				(float(index) - float(cards.size() - 1) * 0.5) * 1.5,
				travel_progress,
			)
			var flip_start := launch_delay + travel_duration * 0.48
			var flip_duration := minf(0.28, travel_duration * 0.52)
			var flip_progress := clampf(
				(elapsed - flip_start) / maxf(0.01, flip_duration),
				0.0,
				1.0,
			)
			_update_card_flip(card, face_textures, index, flip_progress)
			var lift := 1.0 + sin(travel_progress * PI) * 0.10
			card.scale.y = lift
		else:
			var route_delay := float(index) * minf(0.025, route_duration * 0.06)
			var route_progress := clampf(
				(elapsed - route_start - route_delay)
				/ maxf(0.01, route_duration - route_delay),
				0.0,
				1.0,
			)
			route_progress = _ease_in_out_cubic(route_progress)
			var destination := (
				destination_points[index]
				if index < destination_points.size()
				else deck_origin
			)
			var control := Vector2(
				(target.x + destination.x) * 0.5,
				minf(target.y, destination.y) - 64.0 - float(index) * 4.0,
			)
			var point := _quadratic(target, control, destination, route_progress)
			card.position = point - card.size * 0.5
			card.rotation_degrees = lerpf(
				(float(index) - float(cards.size() - 1) * 0.5) * 1.5,
				(10.0 if bool(card.get_meta("matched", false)) else -5.0),
				route_progress,
			)
			card.scale = Vector2.ONE * lerpf(1.0, 0.82, route_progress)
			card.modulate.a = 1.0 - clampf((route_progress - 0.88) / 0.12, 0.0, 1.0)


func _update_card_flip(
	card: Control,
	face_textures: Array[Texture2D],
	index: int,
	progress: float,
) -> void:
	if progress >= 0.5 and not bool(card.get_meta("face_swapped", false)):
		var image := card.get_node_or_null("Image") as TextureRect
		if image != null and index < face_textures.size() and face_textures[index] != null:
			image.texture = face_textures[index]
		card.set_meta("face_swapped", true)
	card.scale.x = maxf(0.025, absf(cos(progress * PI)))
	var outcome_alpha := clampf((progress - 0.68) / 0.24, 0.0, 1.0)
	var outline := card.get_node_or_null("OutcomeOutline") as Panel
	if outline != null:
		outline.modulate.a = outcome_alpha
	var badge := card.get_node_or_null("OutcomeBadge") as Label
	if badge != null:
		badge.modulate.a = outcome_alpha


func _summary_text(card_count: int, summary: Dictionary) -> String:
	var matched_count := int(summary.get("matched_count", 0))
	if str(summary.get("kind", "")) == "public_selection":
		return "公开了 %d 张所选卡牌" % card_count
	if str(summary.get("kind", "")) == "energy_damage":
		if matched_count <= 0:
			return "未翻到能量"
		return "翻到 %d 张能量" % matched_count
	return "公开了 %d 张卡" % card_count


func _quadratic(start: Vector2, control: Vector2, finish: Vector2, t: float) -> Vector2:
	var inverse := 1.0 - t
	return start * inverse * inverse + control * 2.0 * inverse * t + finish * t * t


func _ease_out_cubic(value: float) -> float:
	return 1.0 - pow(1.0 - clampf(value, 0.0, 1.0), 3.0)


func _ease_in_out_cubic(value: float) -> float:
	var t := clampf(value, 0.0, 1.0)
	if t < 0.5:
		return 4.0 * t * t * t
	return 1.0 - pow(-2.0 * t + 2.0, 3.0) * 0.5
