class_name BattleMulliganReveal3D
extends RefCounted

var presenter: Battle3DPresenter
var actor := -1
var labels: Control
var title: Label
var footer: Label
var captions: Array[Label] = []
var centers: Array[Vector2] = []
var card_width := 0.0
var panel_rect := Rect2()
var _size := Vector2.ZERO

func _init(value: Battle3DPresenter) -> void: presenter = value

func begin(player: int, ids: Array) -> void:
	clear()
	actor = player
	labels = Control.new()
	labels.name = "MulliganRevealLabels"
	labels.mouse_filter = Control.MOUSE_FILTER_IGNORE
	labels.z_index = 145
	presenter.table.add_child(labels)
	labels.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	title = _label("对手再战 · 公开手牌", 20, DesignTokens.TEXT)
	footer = _label("没有基础宝可梦，将重新抽取手牌", 14, DesignTokens.TEXT_MUTED)
	for id in ids: captions.append(_label(presenter.table.catalog.card_name(str(id)), 16, DesignTokens.TEXT))
	_layout()

func _label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	labels.add_child(label)
	return label

func _layout() -> void:
	if labels == null or _size == presenter.size: return
	_size = presenter.size
	var table := presenter.table
	var inverse := table.get_global_transform_with_canvas().affine_inverse()
	var right := (inverse * (table.hud.get_node("PhasePanel") as Control).get_global_rect()).position.x - 12.0
	var top := maxf(88.0, (inverse * table.header.get_global_rect()).end.y + 12.0)
	var available := Rect2(Vector2(20, top), Vector2(maxf(300, right - 20), maxf(280, _size.y - top - 16)))
	var columns := mini(4 if _size.x < 1100 else 7, captions.size())
	var rows := ceili(float(captions.size()) / maxi(1, columns))
	card_width = minf(180.0, (available.size.x - 32.0 - (columns - 1) * 12.0) / maxi(1, columns))
	card_width = minf(card_width, (available.size.y - 76.0 - (rows - 1) * 14.0 - rows * 22.0) / maxi(1, rows) / CardEntity3D.ASPECT)
	var card_height := card_width * CardEntity3D.ASPECT
	var panel_size := Vector2(columns * card_width + (columns - 1) * 12.0 + 32.0, rows * (card_height + 22.0) + (rows - 1) * 14.0 + 76.0)
	panel_rect = Rect2(available.get_center() - panel_size * 0.5, panel_size)
	title.position = panel_rect.position + Vector2(12, 10)
	title.size = Vector2(panel_size.x - 24, 30)
	footer.position = Vector2(panel_rect.position.x + 12, panel_rect.end.y - 27)
	footer.size = Vector2(panel_size.x - 24, 20)
	centers.clear()
	for index in range(captions.size()):
		var row := index / columns
		var count := mini(columns, captions.size() - row * columns)
		var row_width := count * card_width + (count - 1) * 12.0
		var center := Vector2(panel_rect.get_center().x - row_width * 0.5 + card_width * 0.5 + (index % columns) * (card_width + 12.0), panel_rect.position.y + 44.0 + card_height * 0.5 + row * (card_height + 36.0))
		centers.append(center)
		captions[index].position = center + Vector2(-card_width * 0.5, card_height * 0.5 + 2)
		captions[index].size = Vector2(card_width, 20)

func pose(index: int) -> Transform3D:
	_layout()
	return presenter.world.projection.camera_plane_pose(centers[index], card_width, 18.0)

func frame(row: Dictionary) -> Dictionary:
	if labels == null: return {}
	_layout()
	var elapsed := float(row.get("progress", 1.0)) * float(row.get("duration", 1.0))
	var alpha := 1.0
	if row.phase == "cards_revealed": alpha = clampf((elapsed - 0.32) / 0.10, 0.0, 1.0) if not MotionPolicy.reduced() else 1.0
	elif row.phase == "card_moved": alpha = 1.0 - clampf(elapsed / 0.10, 0.0, 1.0)
	labels.modulate.a = alpha
	return {"panel_rect": panel_rect, "alpha": alpha}

func clear() -> void:
	if is_instance_valid(labels): labels.free()
	labels = null
	actor = -1
	_size = Vector2.ZERO
	captions.clear()
	centers.clear()
