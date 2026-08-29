class_name CardBattleOverlay
extends Node

var card: CardView
var hp_pill: Label
var damage_badge: Label
var energy_row: HBoxContainer
var tool_badge: Label


func configure(p_card: CardView) -> void:
	card = p_card


func attachment_visual_global_rect(
	attachment_type: String,
	attachment_card_id: String = "",
	attachment_index: int = -1,
) -> Rect2:
	# Attachments are summarized as badges on a Pokemon card. Motion that starts
	# at the Pokemon's centre makes it look as if the Pokemon itself moved, and is
	# especially ambiguous when an opponent chooses one of several bench slots.
	# Expose the complete rendered badge bounds so presentation can preserve its
	# visual footprint as well as a stable source/landing point.
	var anchor: Control
	match attachment_type:
		"energy":
			anchor = energy_row
			# The row spans the card width while its badges are packed from the
			# leading edge. Anchor to a rendered badge rather than the card.empty centre
			# of that container so the energy visibly peels out of the icon itself.
			if energy_row != null and energy_row.get_child_count() > 0:
				var energy_badges: Array[Control] = []
				for child_value in energy_row.get_children():
					var child := child_value as Control
					if child == null:
						continue
					energy_badges.append(child)
					var physical_indices: Array = child.get_meta("energy_indices", [])
					var card_ids: Array = child.get_meta("energy_card_ids", [])
					if (
						attachment_index >= 0
						and attachment_index in physical_indices
						and (
							attachment_card_id.is_empty()
							or attachment_card_id in card_ids
						)
					):
						anchor = child
						break
					if (
						anchor == energy_row
						and not attachment_card_id.is_empty()
						and attachment_card_id in card_ids
					):
						anchor = child
				if (
					anchor == energy_row
					and attachment_index >= 0
					and attachment_index < energy_badges.size()
				):
					anchor = energy_badges[attachment_index]
				elif anchor == energy_row and not energy_badges.is_empty():
					anchor = energy_badges[0]
		"tool":
			anchor = tool_badge
	if anchor != null and is_instance_valid(anchor) and anchor.visible:
		return _control_visual_global_rect(anchor)
	return Rect2(card.global_center(), Vector2.ZERO)

func prospective_attachment_visual_global_rect(
	attachment_type: String,
	attachment_card_id: String = "",
	attachment_index: int = -1,
) -> Rect2:
	# A serialized attach event lands before its target CardView is updated.  The
	# moving badge still needs the geometry of the group that will exist at
	# contact, especially when a new energy type creates/reorders a badge or falls
	# into overflow.  Keep that prediction beside the rendering algorithm so both
	# paths share the same capacity and sizing rules.
	if attachment_type == "tool" and card.pokemon != null:
		card._resolve_scene_nodes()
		if tool_badge != null and tool_badge.visible:
			return _control_visual_global_rect(tool_badge)
		var overlay_parent: Control = (
			card.content_root if card.content_root != null else card
		)
		return _local_control_rect_global_bounds(
			overlay_parent,
			_tool_badge_layout_rect(),
		)
	if (
		attachment_type != "energy"
		or card.pokemon == null
		or attachment_card_id.is_empty()
	):
		return attachment_visual_global_rect(
			attachment_type,
			attachment_card_id,
			attachment_index,
		)
	card._resolve_scene_nodes()
	if energy_row == null:
		return Rect2(card.global_center(), Vector2.ZERO)
	var prospective_ids: Array = card.pokemon.energy_card_ids.duplicate()
	var target_index := attachment_index
	if (
		target_index >= 0
		and target_index < prospective_ids.size()
		and str(prospective_ids[target_index]) == attachment_card_id
	):
		return attachment_visual_global_rect(
			attachment_type,
			attachment_card_id,
			target_index,
		)
	if target_index >= 0 and target_index < prospective_ids.size():
		prospective_ids.insert(target_index, attachment_card_id)
	else:
		target_index = prospective_ids.size()
		prospective_ids.append(attachment_card_id)
	var grouped := card.ATTACHMENT_VISUALS.grouped_energy(prospective_ids, card.catalog)
	if grouped.is_empty():
		return Rect2(card.global_center(), Vector2.ZERO)
	return _energy_group_layout_global_rect(
		grouped,
		target_index,
		attachment_card_id,
		attachment_index,
	)

func attachment_layout_visual_global_rect(
	attachment_type: String,
	attachment_card_id: String = "",
	attachment_index: int = -1,
) -> Rect2:
	# Newly-created batch covers can be queried before BoxContainer has received
	# its first sort notification. Resolve current energy geometry from the same
	# deterministic layout math instead of briefly treating every child as x=0.
	if attachment_type != "energy" or card.pokemon == null:
		return attachment_visual_global_rect(
			attachment_type,
			attachment_card_id,
			attachment_index,
		)
	card._resolve_scene_nodes()
	if energy_row == null:
		return Rect2(card.global_center(), Vector2.ZERO)
	var target_index := attachment_index
	if (
		target_index < 0
		or target_index >= card.pokemon.energy_card_ids.size()
		or (
			not attachment_card_id.is_empty()
			and str(card.pokemon.energy_card_ids[target_index]) != attachment_card_id
		)
	):
		target_index = -1
		if not attachment_card_id.is_empty():
			for index in range(card.pokemon.energy_card_ids.size()):
				if str(card.pokemon.energy_card_ids[index]) == attachment_card_id:
					target_index = index
					break
	if target_index < 0:
		return attachment_visual_global_rect(
			attachment_type,
			attachment_card_id,
			attachment_index,
		)
	var grouped := card.ATTACHMENT_VISUALS.grouped_energy(
		card.pokemon.energy_card_ids,
		card.catalog,
	)
	return _energy_group_layout_global_rect(
		grouped,
		target_index,
		attachment_card_id,
		attachment_index,
	)

func _energy_group_layout_global_rect(
	grouped: Array,
	target_index: int,
	attachment_card_id: String,
	attachment_index: int,
) -> Rect2:
	var layout := _energy_badge_layout(grouped)
	var capacity := int(layout.get("capacity", 1))
	var visible_group_count := int(layout.get("visible_group_count", 0))
	var badge_ordinal := -1
	for group_index in range(grouped.size()):
		var descriptor := grouped[group_index] as AttachmentVisualDescriptor
		if descriptor != null and target_index in descriptor.physical_indices:
			badge_ordinal = (
				mini(group_index, capacity - 1)
				if group_index >= visible_group_count
				else group_index
			)
			break
	if badge_ordinal < 0:
		return attachment_visual_global_rect(
			"energy",
			attachment_card_id,
			attachment_index,
		)
	var badge_size := float(layout.get("badge_size", card.DEFAULT_ENERGY_BADGE_SIZE))
	var local_rect := Rect2(
		Vector2(float(badge_ordinal) * (badge_size + card.ENERGY_BADGE_SEPARATION), 0.0),
		Vector2(badge_size, badge_size),
	)
	return _local_control_rect_global_bounds(energy_row, local_rect)

func _control_visual_global_rect(control: Control) -> Rect2:
	var transform := control.get_global_transform_with_canvas()
	var corners := PackedVector2Array([
		transform * Vector2.ZERO,
		transform * Vector2(control.size.x, 0.0),
		transform * control.size,
		transform * Vector2(0.0, control.size.y),
	])
	var minimum := corners[0]
	var maximum := corners[0]
	for corner in corners:
		minimum = minimum.min(corner)
		maximum = maximum.max(corner)
	return Rect2(minimum, maximum - minimum)

func _local_control_rect_global_bounds(control: Control, local_rect: Rect2) -> Rect2:
	var transform := control.get_global_transform_with_canvas()
	var corners := PackedVector2Array([
		transform * local_rect.position,
		transform * Vector2(local_rect.end.x, local_rect.position.y),
		transform * local_rect.end,
		transform * Vector2(local_rect.position.x, local_rect.end.y),
	])
	var minimum := corners[0]
	var maximum := corners[0]
	for corner in corners:
		minimum = minimum.min(corner)
		maximum = maximum.max(corner)
	return Rect2(minimum, maximum - minimum)

func _ensure_overlay_nodes() -> void:
	if card.depth_edge != null:
		return
	card._resolve_scene_nodes()
	var overlay_parent: Control = card.content_root if card.content_root else self
	card.depth_edge = Panel.new()
	card.depth_edge.name = "DepthEdge"
	card.depth_edge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.depth_edge.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	card.depth_edge.z_index = -1
	overlay_parent.add_child(card.depth_edge)
	overlay_parent.move_child(card.depth_edge, 1)

	card.top_gloss = ColorRect.new()
	card.top_gloss.name = "TopGloss"
	card.top_gloss.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.top_gloss.color = Color(1, 1, 1, 0.09)
	card.top_gloss.z_index = 3
	overlay_parent.add_child(card.top_gloss)

	hp_pill = _new_overlay_label("HPPill")
	hp_pill.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hp_pill.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hp_pill.z_index = 8
	overlay_parent.add_child(hp_pill)

	damage_badge = _new_overlay_label("DamageBadge")
	damage_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	damage_badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	damage_badge.z_index = 9
	overlay_parent.add_child(damage_badge)

	energy_row = HBoxContainer.new()
	energy_row.name = "EnergyRow"
	energy_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	energy_row.add_theme_constant_override("separation", int(card.ENERGY_BADGE_SEPARATION))
	energy_row.z_index = 8
	overlay_parent.add_child(energy_row)

	tool_badge = _new_overlay_label("ToolBadge")
	tool_badge.text = "道具"
	tool_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tool_badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	tool_badge.z_index = 8
	overlay_parent.add_child(tool_badge)

func _new_overlay_label(node_name: String) -> Label:
	var label := Label.new()
	label.name = node_name
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return label

func _refresh_battle_overlay(card_data: Dictionary, border_color: Color) -> void:
	if hp_pill == null or damage_badge == null or energy_row == null or tool_badge == null:
		return
	var show_overlay: bool = (
		card.pokemon != null
		and not card.compact
		and not card.empty
		and not card.is_hidden_card
	)
	hp_pill.visible = show_overlay
	damage_badge.visible = false
	energy_row.visible = show_overlay
	tool_badge.visible = false
	card.top_gloss.visible = not card.empty
	if not show_overlay:
		_clear_energy_badges()
		_set_energy_summary([])
		return
	var maximum := _pokemon_max_hp(card_data, card.pokemon)
	var current: int = card.pokemon.current_hp(card.catalog) if card.catalog else maximum - (
		card.pokemon.damage_counters * 10
	)
	var hp_ratio := float(current) / float(maxi(1, maximum))
	var hp_color := (
		DesignTokens.GREEN
		if hp_ratio > 0.55
		else DesignTokens.GOLD
		if hp_ratio > 0.25
		else DesignTokens.RED
	)
	hp_pill.text = "HP%d" % current
	hp_pill.tooltip_text = ""
	hp_pill.accessibility_name = "HP %d/%d" % [current, maximum]
	hp_pill.add_theme_color_override("font_color", DesignTokens.BG_DEEP)
	hp_pill.add_theme_stylebox_override(
		"normal",
		DesignTokens.panel_style(hp_color, 4, Color(1, 1, 1, 0.78), 1, 0),
	)
	var damage: int = card.pokemon.damage_counters * 10
	if damage > 0:
		damage_badge.visible = true
		damage_badge.text = "%d" % damage
		damage_badge.tooltip_text = ""
		damage_badge.accessibility_name = "伤害 %d" % damage
		damage_badge.add_theme_color_override("font_color", DesignTokens.BG_DEEP)
		damage_badge.add_theme_stylebox_override(
			"normal",
			DesignTokens.panel_style(
				DesignTokens.RED.lightened(0.16),
				4,
				Color(1, 1, 1, 0.72),
				1,
				0,
			),
		)
	_layout_battle_overlay()
	_refresh_energy_badges()
	if not card.pokemon.attached_tool_id.is_empty():
		tool_badge.visible = true
		tool_badge.tooltip_text = ""
		tool_badge.accessibility_name = "宝可梦道具：%s" % card._card_data(
			card.pokemon.attached_tool_id
		).get("name", card.pokemon.attached_tool_id)
		tool_badge.add_theme_color_override("font_color", DesignTokens.TEXT)
		tool_badge.add_theme_stylebox_override(
			"normal",
			DesignTokens.panel_style(
				Color("#213146"),
				3,
				border_color.lightened(0.25),
				1,
				0,
			),
		)

func _refresh_energy_badges() -> void:
	_clear_energy_badges()
	var badge_scale := clampf(card.size.x / 130.0, 0.68, 1.06)
	energy_row.size = Vector2(maxf(0.0, card.size.x - 10.0), 25.0 * badge_scale)
	if card.pokemon == null:
		_set_energy_summary([])
		return
	var grouped := _attached_energy_groups()
	_set_energy_summary(grouped)
	if grouped.is_empty():
		return
	var layout := _energy_badge_layout(grouped)
	var capacity := int(layout.get("capacity", 1))
	var has_overflow := bool(layout.get("has_overflow", false))
	var visible_group_count := int(layout.get("visible_group_count", 0))
	var badge_size := float(layout.get("badge_size", card.DEFAULT_ENERGY_BADGE_SIZE))
	for index in range(visible_group_count):
		var row_value: Variant = grouped[index]
		var row: Dictionary = row_value
		var energy_type := str(row.get("type", "Colorless"))
		# Badge numerals describe effective energy units. This differs from the
		# number of physical attachments for cards such as Double Turbo Energy and
		# for a shared stack of several Colorless-providing Special Energy cards.
		var count := int(row.get("visual_count", row.get("count", 1)))
		var badge := _new_energy_badge(
			energy_type,
			count,
			str(row.get("icon_card_id", "")),
			str(row.get("display_name", "")),
			badge_size,
			str(row.get("marker", "")),
			row.get("icon") as Texture2D,
			str(row.get("fallback_label", "?")),
		)
		badge.set_meta("energy_type", energy_type)
		badge.set_meta("energy_group_key", str(row.get("group_key", "")))
		badge.set_meta("energy_card_ids", row.get("card_ids", []).duplicate())
		badge.set_meta("energy_indices", row.get("indices", []).duplicate())
		badge.set_meta(
			"provided_energy_units",
			row.get("provided_energy_units", []).duplicate(),
		)
		badge.set_meta("provided_unit_count", int(row.get("provided_unit_count", 0)))
		badge.set_meta("physical_card_count", int(row.get("count", 1)))
		energy_row.add_child(badge)
	if has_overflow:
		var overflow_count := 0
		var overflow_card_ids: Array = []
		var overflow_indices: Array = []
		var overflow_group_keys: Array[String] = []
		for index in range(visible_group_count, grouped.size()):
			var overflow_row := grouped[index] as Dictionary
			overflow_count += int(overflow_row.get("count", 1))
			overflow_card_ids.append_array(overflow_row.get("card_ids", []))
			overflow_indices.append_array(overflow_row.get("indices", []))
			overflow_group_keys.append(str(overflow_row.get("group_key", "")))
		var overflow_badge := _new_energy_overflow_badge(overflow_count, badge_size)
		overflow_badge.set_meta("energy_card_ids", overflow_card_ids)
		overflow_badge.set_meta("energy_indices", overflow_indices)
		overflow_badge.set_meta("energy_group_keys", overflow_group_keys)
		energy_row.add_child(overflow_badge)

func _energy_badge_layout(grouped: Array) -> Dictionary:
	# Derive the badge budget from CardView, not EnergyRow's current minimum.
	# Otherwise old 24px children can keep a just-resized bench row artificially
	# large and make the next generation of badges perpetuate that overflow.
	var badge_scale := clampf(card.size.x / 130.0, 0.68, 1.06)
	var available_width := maxf(0.0, card.size.x - 10.0)
	var available_height := maxf(1.0, 25.0 * badge_scale)
	var maximum_badge_size := minf(card.DEFAULT_ENERGY_BADGE_SIZE, floor(available_height))
	var minimum_badge_size := minf(card.MINIMUM_ENERGY_BADGE_SIZE, maximum_badge_size)
	var capacity := clampi(
		int(floor(
			(available_width + card.ENERGY_BADGE_SEPARATION)
			/ (minimum_badge_size + card.ENERGY_BADGE_SEPARATION)
		)),
		1,
		card.MAXIMUM_ENERGY_BADGES,
	)
	var has_overflow := grouped.size() > capacity
	var visible_group_count := capacity - 1 if has_overflow else grouped.size()
	var slot_count := capacity if has_overflow else visible_group_count
	var badge_size := minf(
		maximum_badge_size,
		floor(
			(available_width - card.ENERGY_BADGE_SEPARATION * float(maxi(0, slot_count - 1)))
			/ float(maxi(1, slot_count))
		),
	)
	return {
		"capacity": capacity,
		"has_overflow": has_overflow,
		"visible_group_count": visible_group_count,
		"badge_size": maxf(minimum_badge_size, badge_size),
	}

func _new_energy_badge(
	energy_type: String,
	count: int,
	icon_card_id := "",
	display_name := "",
	badge_size := card.DEFAULT_ENERGY_BADGE_SIZE,
	marker := "",
	texture_override: Texture2D = null,
	fallback_label := "?",
) -> Control:
	var badge := Control.new()
	badge.name = "EnergyBadge"
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.custom_minimum_size = Vector2(badge_size, badge_size)
	badge.size = badge.custom_minimum_size
	var accessible_name := (
		display_name
		if not display_name.is_empty()
		else card.ENERGY_ICONS.display_name_for(energy_type)
	)
	badge.tooltip_text = ""
	badge.accessibility_name = "%s x%d" % [accessible_name, count]

	var texture: Texture2D = texture_override
	if texture == null:
		texture = (
			card.ENERGY_ICONS.texture_for_card_id(icon_card_id)
			if not icon_card_id.is_empty()
			else card.ENERGY_ICONS.texture_for(energy_type)
		)

	var plate := Panel.new()
	plate.name = "Plate"
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plate.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var plate_style := DesignTokens.panel_style(
		(
			Color(0.018, 0.038, 0.065, 0.14)
			if texture != null
			else Color(0.09, 0.115, 0.15, 0.82)
		),
		int(round(badge_size * 0.5)),
		_energy_color(energy_type).lightened(0.38),
		1,
		0,
	)
	plate_style.shadow_color = Color(0.0, 0.0, 0.0, 0.32)
	plate_style.shadow_size = 1
	plate_style.shadow_offset = Vector2(0, 1)
	plate.add_theme_stylebox_override("panel", plate_style)
	badge.add_child(plate)

	if texture == null:
		var fallback := Label.new()
		fallback.name = "FallbackLabel"
		fallback.mouse_filter = Control.MOUSE_FILTER_IGNORE
		fallback.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		fallback.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		fallback.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		fallback.text = fallback_label
		fallback.add_theme_font_size_override(
			"font_size",
			maxi(8, int(round(badge_size * 0.42))),
		)
		fallback.add_theme_color_override("font_color", DesignTokens.TEXT)
		fallback.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.72))
		fallback.add_theme_constant_override("outline_size", 2)
		badge.add_child(fallback)
	else:
		var icon := TextureRect.new()
		icon.name = "Icon"
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var icon_inset := maxf(1.0, round(badge_size * 0.07))
		icon.offset_left = icon_inset
		icon.offset_top = icon_inset
		icon.offset_right = -icon_inset
		icon.offset_bottom = -icon_inset
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.texture = texture
		badge.add_child(icon)

		if not marker.is_empty():
			var marker_size := clampf(round(badge_size * 0.45), 8.0, 11.0)
			var marker_badge := Label.new()
			marker_badge.name = "SpecialMarker"
			marker_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
			marker_badge.position = Vector2(-1.0, -1.0)
			marker_badge.size = Vector2(marker_size, marker_size)
			marker_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			marker_badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			marker_badge.text = marker
			marker_badge.add_theme_font_size_override(
				"font_size",
				maxi(7, int(round(badge_size * 0.30))),
			)
			marker_badge.add_theme_color_override("font_color", Color.WHITE)
			marker_badge.add_theme_stylebox_override(
				"normal",
				DesignTokens.panel_style(
					Color(0.075, 0.10, 0.145, 0.90),
					int(round(marker_size * 0.5)),
					_energy_color(energy_type).lightened(0.42),
					1,
					0,
				),
			)
			badge.add_child(marker_badge)

	if count > 1:
		var count_text := str(count)
		var count_height := clampf(round(badge_size * 0.62), 11.0, 15.0)
		var extra_digit_width := float(maxi(0, count_text.length() - 1)) * 4.0
		var count_width := minf(badge_size, count_height + extra_digit_width)
		var count_badge := CardView.EnergyCountBadgeVisual.new()
		count_badge.name = "CountBadge"
		count_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		count_badge.position = Vector2(
			badge_size - count_width,
			badge_size - count_height,
		)
		count_badge.size = Vector2(count_width, count_height)
		count_badge.custom_minimum_size = count_badge.size
		count_badge.z_index = 4
		count_badge.add_theme_stylebox_override(
			"normal",
			DesignTokens.panel_style(
				Color(0.012, 0.028, 0.055, 0.98),
				int(round(count_height * 0.5)),
				Color(0.94, 0.975, 1.0, 0.98),
				1,
				0,
			),
		)
		count_badge.configure(
			count_text,
			card.ENERGY_COUNT_FONT,
			clampi(int(round(badge_size * 0.50)), 9, 12),
		)
		badge.add_child(count_badge)
	return badge

func _new_energy_overflow_badge(count: int, badge_size: float) -> Control:
	var badge := Control.new()
	badge.name = "EnergyOverflowBadge"
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.custom_minimum_size = Vector2(badge_size, badge_size)
	badge.size = badge.custom_minimum_size
	badge.tooltip_text = ""
	badge.accessibility_name = "另有 %d 张附加能量" % count

	var plate := Panel.new()
	plate.name = "Plate"
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plate.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	plate.add_theme_stylebox_override(
		"panel",
		DesignTokens.panel_style(
			Color(0.055, 0.075, 0.105, 0.74),
			int(round(badge_size * 0.5)),
			DesignTokens.GOLD.lightened(0.12),
			1,
			0,
		),
	)
	badge.add_child(plate)

	var label := Label.new()
	label.name = "OverflowLabel"
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.text = "+%d" % count
	label.add_theme_font_size_override(
		"font_size",
		maxi(8, int(round(badge_size * 0.38))),
	)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.72))
	label.add_theme_constant_override("outline_size", 2)
	badge.add_child(label)
	return badge

func _set_energy_summary(grouped: Array[Dictionary]) -> void:
	_refresh_accessibility_summary(grouped)

func _refresh_accessibility_summary(energy_groups: Array[Dictionary] = []) -> void:
	var parts: Array[String] = []
	if card.is_hidden_card:
		parts.append("隐藏卡牌")
	elif card.empty:
		parts.append(card._empty_slot_label_text if not card._empty_slot_label_text.is_empty() else "空牌位")
	else:
		var card_data := card._card_data(card.card_id)
		parts.append(str(card_data.get("name", card.card_id)))
		if card.pokemon != null:
			var maximum := _pokemon_max_hp(card_data, card.pokemon)
			var current: int = card.pokemon.current_hp(card.catalog) if card.catalog else maximum - (
				card.pokemon.damage_counters * 10
			)
			parts.append("HP %d/%d" % [current, maximum])
			var damage: int = card.pokemon.damage_counters * 10
			if damage > 0:
				parts.append("伤害 %d" % damage)
			if not card.pokemon.status_conditions.is_empty():
				parts.append("状态：%s" % "、".join(card.pokemon.status_conditions))
			if not card.pokemon.attached_tool_id.is_empty():
				parts.append("宝可梦道具：%s" % card._card_data(
					card.pokemon.attached_tool_id
				).get("name", card.pokemon.attached_tool_id))
			if energy_groups.is_empty():
				energy_groups = _attached_energy_groups()
			var energy_parts: Array[String] = []
			for row in energy_groups:
				var display_name := str(row.get("display_name", ""))
				if display_name.is_empty():
					display_name = card.ENERGY_ICONS.display_name_for(
						str(row.get("type", "Colorless"))
					)
				energy_parts.append("%s ×%d" % [
					display_name,
					int(row.get("visual_count", row.get("count", 1))),
				])
			if not energy_parts.is_empty():
				parts.append("附加能量：%s" % "、".join(energy_parts))
	if card.selected and not card.actionable and not card._disabled_reason.is_empty():
		parts.append(card._disabled_reason)
	elif card.targetable and not card._legal_target_hint.is_empty():
		parts.append(card._legal_target_hint)
	var summary := "；".join(parts)
	card.tooltip_text = ""
	card.accessibility_description = summary
	card.accessibility_name = parts[0] if not parts.is_empty() else "卡牌"

func _clear_energy_badges() -> void:
	if energy_row == null:
		return
	for child in energy_row.get_children():
		energy_row.remove_child(child)
		child.queue_free()

func _attached_energy_groups() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if card.pokemon == null:
		return result
	for descriptor_value in card.ATTACHMENT_VISUALS.grouped_energy(
		card.pokemon.energy_card_ids,
		card.catalog,
	):
		var descriptor := descriptor_value as AttachmentVisualDescriptor
		if descriptor != null:
			result.append(descriptor.to_dictionary())
	return result

func _energy_color(energy_type: String) -> Color:
	if energy_type == "Rainbow":
		return Color("#f4c84a")
	if energy_type == "Special":
		return Color("#7a87a8")
	return DesignTokens.type_color(energy_type)

func _pokemon_max_hp(card_data: Dictionary, pokemon_value: PokemonState) -> int:
	var maximum := maxi(1, int(card_data.get("hp", 1)))
	if pokemon_value == null or card.catalog == null:
		return maximum
	var native_maximum := pokemon_value.max_hp(card.catalog)
	return native_maximum if native_maximum > 0 else maximum

func _layout_battle_overlay() -> void:
	if hp_pill == null:
		return
	var badge_scale := clampf(card.size.x / 130.0, 0.68, 1.06)
	var hp_size := Vector2(58, 24) * badge_scale
	hp_pill.position = Vector2(card.size.x - hp_size.x - 5.0, 4.0)
	hp_pill.size = hp_size
	hp_pill.add_theme_font_size_override("font_size", int(17 * badge_scale))
	var damage_size := Vector2(30, 30) * badge_scale
	damage_badge.position = Vector2(
		card.size.x - damage_size.x - 3.0,
		card.size.y * 0.42,
	)
	damage_badge.size = damage_size
	damage_badge.add_theme_font_size_override("font_size", int(14 * badge_scale))
	energy_row.position = Vector2(5.0, card.size.y - 26.0 * badge_scale)
	energy_row.size = Vector2(card.size.x - 10.0, 25.0 * badge_scale)
	if card.interaction_hint != null:
		card.interaction_hint.offset_left = 5.0
		card.interaction_hint.offset_right = -5.0
		if energy_row.visible:
			# Source-selection hints used to sit on the same bottom strip as the
			# attachment badges. Reserve the energy row and keep the hint directly
			# above it so every physical attachment remains readable and anchorable.
			var hint_bottom := -26.0 * badge_scale - 2.0
			var hint_height := clampf(27.0 * badge_scale, 20.0, 29.0)
			card.interaction_hint.offset_bottom = hint_bottom
			card.interaction_hint.offset_top = hint_bottom - hint_height
		else:
			card.interaction_hint.offset_top = -34.0
			card.interaction_hint.offset_bottom = -5.0
	var tool_rect := _tool_badge_layout_rect()
	tool_badge.position = tool_rect.position
	tool_badge.size = tool_rect.size
	tool_badge.add_theme_font_size_override("font_size", int(10 * badge_scale))
	card.status_row.offset_left = -6.0
	card.status_row.offset_top = 6.0
	card.status_row.offset_right = -6.0
	if card.top_gloss:
		card.top_gloss.position = Vector2(3.0, 3.0)
		card.top_gloss.size = Vector2(maxf(0.0, card.size.x - 6.0), maxf(3.0, card.size.y * 0.14))

func _tool_badge_layout_rect() -> Rect2:
	var badge_scale := clampf(card.size.x / 130.0, 0.68, 1.06)
	return Rect2(
		Vector2(5.0, 5.0),
		Vector2(42.0, 20.0) * badge_scale,
	)
