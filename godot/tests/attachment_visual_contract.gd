extends SceneTree

const ATTACHMENT_VISUALS := preload("res://ui/attachment_visual_descriptor.gd")

var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = Vector2i(960, 720)
	var catalog := CardCatalog.new(true)
	var energy_ids := [
		"sv1-ener-2",
		"sv1-ener-2",
		"svi-mirc",
		"svi-dtur",
		"svi-jete",
		"svi-trea",
		"svg2-lume",
		"missing-energy",
	]
	var grouped: Array = ATTACHMENT_VISUALS.grouped_energy(energy_ids, catalog)
	_check(grouped.size() == 3, "Colorless-providing Special Energy did not share one stack")
	var fire = _descriptor_for(grouped, "energy:type:Fire")
	var colorless = _descriptor_for(grouped, "energy:type:Colorless")
	var unknown = _descriptor_for(grouped, "energy:card:missing-energy")
	_check(
		fire != null
		and fire.count == 2
		and fire.physical_indices == [0, 1]
		and fire.card_ids == ["sv1-ener-2", "sv1-ener-2"],
		"Basic energy did not group by provided type with every physical index",
	)
	_check(
		colorless != null
		and colorless.count == 5
		and colorless.physical_indices == [2, 3, 4, 5, 6]
		and colorless.card_ids == [
			"svi-mirc",
			"svi-dtur",
			"svi-jete",
			"svi-trea",
			"svg2-lume",
		]
		and colorless.provided_energy_units == [
			"Colorless",
			"Colorless",
			"Colorless",
			"Colorless",
			"Colorless",
			"Colorless",
		]
		and colorless.provided_unit_count() == 6
		and colorless.visual_count() == 6
		and colorless.energy_type == "Colorless"
		and colorless.display_name == "无色能量"
		and colorless.icon != null
		and colorless.marker.is_empty(),
		"Colorless Special Energy did not stack by effective provided units",
	)
	var lone_luminous_groups: Array = ATTACHMENT_VISUALS.grouped_energy(
		["svg2-lume"],
		catalog,
	)
	var lone_luminous = _descriptor_for(
		lone_luminous_groups,
		"energy:card:svg2-lume",
	)
	_check(
		lone_luminous != null
		and lone_luminous.energy_type == "Rainbow"
		and lone_luminous.icon != null
		and lone_luminous.marker.is_empty(),
		"A Special Energy that is not currently Colorless lost its exact visual",
	)
	_check(
		unknown != null
		and unknown.icon == null
		and unknown.energy_type == "Unknown"
		and unknown.fallback_label == "?",
		"Unknown energy incorrectly masqueraded as a Colorless symbol",
	)

	var canonical_ref: Dictionary = ATTACHMENT_VISUALS.canonical_ref({
		"attachment_type": "energy",
		"card_id": "svi-dtur",
		"index": 3,
	})
	_check(
		int(canonical_ref.get("index", -1)) == 3,
		"Canonical attachment index was not retained",
	)

	var scene := load("res://ui/card_view.tscn") as PackedScene
	_check(scene != null, "CardView scene did not load")
	if scene == null:
		_finish()
		return
	var card := scene.instantiate() as CardView
	root.add_child(card)
	card.position = Vector2(180, 180)
	card.size = Vector2(130, 180)
	card.set_catalog(catalog)
	var pokemon := PokemonState.new("sv1-104")
	pokemon.energy_card_ids.assign(energy_ids)
	card.configure("sv1-104", pokemon, false, -1, 0, "active")
	await process_frame
	await process_frame
	_check(
		card.tooltip_text.is_empty()
		and card.get_tooltip(Vector2(20, 20)).is_empty()
		and not card.accessibility_description.is_empty()
		and "附加能量" in card.accessibility_description,
		"CardView must suppress hover text while preserving full accessibility text",
	)

	var energy_row := card.find_child("EnergyRow", true, false) as HBoxContainer
	var overflow := card.find_child("EnergyOverflowBadge", true, false) as Control
	var colorless_badge := _badge_for_group(energy_row, "energy:type:Colorless")
	var colorless_count_badge := (
		colorless_badge.find_child("CountBadge", true, false) as Control
		if colorless_badge != null
		else null
	)
	_check(
		energy_row != null
		and energy_row.get_child_count() == 3
		and overflow == null
		and colorless_badge != null
		and colorless_badge.find_child("SpecialMarker", true, false) == null
		and colorless_badge.get_meta("energy_indices", []) == [2, 3, 4, 5, 6]
		and colorless_badge.get_meta("energy_card_ids", []) == [
			"svi-mirc",
			"svi-dtur",
			"svi-jete",
			"svi-trea",
			"svg2-lume",
		]
		and int(colorless_badge.get_meta("provided_unit_count", 0)) == 6
		and int(colorless_badge.get_meta("physical_card_count", 0)) == 5
		and colorless_badge.tooltip_text.is_empty()
		and not colorless_badge.accessibility_name.is_empty()
		and colorless_count_badge != null
		and str(colorless_count_badge.get_meta("count_text", "")) == "6",
		"CardView did not render one marker-free Colorless badge with the effective unit count",
	)
	var fire_badge := _badge_for_group(energy_row, "energy:type:Fire")
	var fire_plate := (
		fire_badge.find_child("Plate", true, false) as Panel
		if fire_badge != null
		else null
	)
	var fire_style := (
		fire_plate.get_theme_stylebox("panel") as StyleBoxFlat
		if fire_plate != null
		else null
	)
	var count_badge := (
		fire_badge.find_child("CountBadge", true, false) as Control
		if fire_badge != null
		else null
	)
	_check(
		fire_style != null
		and fire_style.bg_color.a <= 0.16
		and fire_style.corner_radius_top_left >= 8
		and fire_style.shadow_size <= 1,
		"Textured energy badge retained an opaque square backing plate",
	)
	_check(
		count_badge != null
		and str(count_badge.get_meta("count_text", "")) == "2"
		and int(count_badge.get_meta("font_size", 0)) >= 9
		and int(count_badge.get_meta("outline_size", 0)) >= 1
		and Rect2(Vector2.ZERO, fire_badge.size).encloses(
			Rect2(count_badge.position, count_badge.size)
		),
		"Energy count badge was too small, low contrast, or clipped outside its icon",
	)

	var overflow_card := scene.instantiate() as CardView
	root.add_child(overflow_card)
	overflow_card.position = Vector2(20, 440)
	overflow_card.size = Vector2(130, 180)
	overflow_card.set_catalog(catalog)
	var overflow_pokemon := PokemonState.new("sv1-104")
	overflow_pokemon.energy_card_ids.assign([
		"sv1-ener-2",
		"sv1-ener-2",
		"sv1-ener-1",
		"sv1-ener-3",
		"sv1-ener-4",
		"svg2-lume",
		"missing-energy",
	])
	overflow_card.configure("sv1-104", overflow_pokemon, false, -1, 0, "active")
	await process_frame
	await process_frame
	var overflow_row := overflow_card.find_child("EnergyRow", true, false) as HBoxContainer
	var overflow_badge := overflow_card.find_child(
		"EnergyOverflowBadge",
		true,
		false,
	) as Control
	_check(
		overflow_row != null
		and overflow_row.get_child_count() == 4
		and overflow_badge != null
		and overflow_badge.get_meta("energy_indices", []) == [4, 5, 6]
		and overflow_badge.get_meta("energy_card_ids", []) == [
			"sv1-ener-4",
			"svg2-lume",
			"missing-energy",
		],
		"Overflow badge did not preserve every hidden card identity and physical index",
	)
	var overflow_rect := overflow_card.attachment_visual_global_rect(
		"energy", "missing-energy", 6
	)
	var legacy_center := overflow_card.attachment_anchor_global(
		"energy",
		"missing-energy",
		6,
	)
	_check(
		overflow_rect.size.x > 0.0
		and overflow_rect.is_equal_approx(
			overflow_card.battle_overlay._control_visual_global_rect(overflow_badge)
		)
		and legacy_center.is_equal_approx(overflow_rect.get_center()),
		"Attachment rect/legacy center did not resolve a hidden overflow energy",
	)
	var turbo_badge := _badge_for_group(energy_row, "energy:type:Colorless")
	var mismatched_index_rect := card.attachment_visual_global_rect(
		"energy", "svi-dtur", 0
	)
	_check(
		turbo_badge != null
		and mismatched_index_rect.is_equal_approx(
			card.battle_overlay._control_visual_global_rect(turbo_badge)
		),
		"A stale/inferred index overrode the exact energy card identity",
	)

	var tool_was_hidden := not card.battle_overlay.tool_badge.visible
	var prospective_tool_rect := card.prospective_attachment_visual_global_rect(
		"tool",
		"sv1-202",
	)
	var tool_remained_hidden := (
		not card.battle_overlay.tool_badge.visible
		and pokemon.attached_tool_id.is_empty()
	)
	pokemon.attached_tool_id = "sv1-202"
	card.configure("sv1-104", pokemon, false, -1, 0, "active")
	await process_frame
	await process_frame
	var rendered_tool_rect := card.attachment_visual_global_rect(
		"tool",
		"sv1-202",
	)
	_check(
		tool_was_hidden
		and tool_remained_hidden
		and prospective_tool_rect.size.x > 0.0
		and prospective_tool_rect.size.y > 0.0
		and prospective_tool_rect.is_equal_approx(rendered_tool_rect)
		and rendered_tool_rect.is_equal_approx(
			card.battle_overlay._control_visual_global_rect(
				card.battle_overlay.tool_badge
			)
		)
		and prospective_tool_rect.get_center().distance_to(
			card.global_center()
		) > 4.0,
		"Pre-attach CardView did not predict the complete future tool-badge rect",
	)

	card.set_interaction_state(false, "", "选择能量", [], false)
	await process_frame
	_check(
		not card.interaction_hint.visible
		and card.targetable
		and card.target_glow.visible
		and "选择能量" in card.accessibility_description,
		"Attachment-source choice did not keep its outline/accessibility hint while hiding the inline strip",
	)

	card.custom_minimum_size = Vector2(86, 120)
	card.size = Vector2(86, 120)
	await process_frame
	await process_frame
	var responsive_sizes_ok := energy_row.size.y <= 18.01
	var rendered_badge_sizes: Array[String] = []
	for badge_value in energy_row.get_children():
		var badge := badge_value as Control
		rendered_badge_sizes.append(str(badge.custom_minimum_size))
		responsive_sizes_ok = (
			responsive_sizes_ok
			and badge.custom_minimum_size.x <= energy_row.size.y + 0.01
			and badge.custom_minimum_size.y <= energy_row.size.y + 0.01
		)
	_check(
		responsive_sizes_ok,
		"Compact Pokemon energy badges did not respect the rendered row height "
		+ "row=%s badges=%s card=%s" % [
			energy_row.size,
			rendered_badge_sizes,
			card.size,
		],
	)

	var count_card := scene.instantiate() as CardView
	root.add_child(count_card)
	count_card.position = Vector2(520, 180)
	count_card.size = Vector2(130, 180)
	count_card.set_catalog(catalog)
	var count_pokemon := PokemonState.new("sv1-104")
	for _index in range(12):
		count_pokemon.energy_card_ids.append("sv1-ener-2")
	count_card.configure("sv1-104", count_pokemon, false, -1, 0, "active")
	await process_frame
	await process_frame
	_check_count_badge(count_card, "12", "active")
	count_card.size = Vector2(104, 146)
	await process_frame
	await process_frame
	_check_count_badge(count_card, "12", "bench")
	count_card.size = Vector2(86, 120)
	await process_frame
	await process_frame
	_check_count_badge(count_card, "12", "compact")

	var unknown_card := scene.instantiate() as CardView
	root.add_child(unknown_card)
	unknown_card.position = Vector2(360, 180)
	unknown_card.size = Vector2(104, 146)
	unknown_card.set_catalog(catalog)
	var unknown_pokemon := PokemonState.new("sv1-104")
	unknown_pokemon.energy_card_ids.append("missing-energy")
	unknown_pokemon.energy_card_ids.append("missing-energy")
	unknown_card.configure("sv1-104", unknown_pokemon, false, -1, 0, "bench:0")
	await process_frame
	var unknown_badge := unknown_card.find_child("EnergyBadge", true, false) as Control
	var unknown_fallback := (
		unknown_badge.find_child("FallbackLabel", true, false) as Label
		if unknown_badge != null
		else null
	)
	_check(
		unknown_badge != null
		and unknown_badge.find_child("Icon", true, false) == null
		and unknown_fallback != null
		and unknown_fallback.text == "?"
		and str((unknown_badge.find_child("CountBadge", true, false) as Control).get_meta(
			"count_text", ""
		)) == "2",
		"Unknown attached energy did not separate its neutral marker from the readable count",
	)

	var popover := AttachmentChoicePopover.new()
	root.add_child(popover)
	await process_frame
	popover.show_for_source(
		[
			{
				"option_id": "turbo",
				"label": "双重涡轮能量",
				"ref": {
					"attachment_type": "energy",
					"card_id": "svi-dtur",
					"index": 3,
				},
			},
			{
				"option_id": "unknown",
				"label": "未知能量",
				"ref": {
					"attachment_type": "energy",
					"card_id": "missing-energy",
					"index": 5,
				},
			},
		],
		[],
		{},
		1,
		1,
		true,
		card,
		Rect2(Vector2.ZERO, Vector2(960, 720)),
		catalog,
		"测试宝可梦",
	)
	await process_frame
	var turbo_button := popover._button_by_id.get("turbo") as Button
	var unknown_button := popover._button_by_id.get("unknown") as Button
	_check(
		turbo_button != null
		and turbo_button.icon != null
		and turbo_button.text.begins_with("双重涡轮能量")
		and int(turbo_button.get_meta("attachment_index", -1)) == 3
		and str(turbo_button.get_meta("attachment_group_key", ""))
		== "energy:type:Colorless"
		and turbo_button.get_meta("provided_energy_units", [])
		== ["Colorless", "Colorless"],
		"Attachment popover did not retain the exact Colorless Special Energy option",
	)
	_check(
		unknown_button != null
		and unknown_button.icon == null
		and str(unknown_button.get_meta("attachment_fallback_label", "")) == "?",
		"Attachment popover assigned a Colorless icon to an unknown energy",
	)

	popover.queue_free()
	unknown_card.queue_free()
	count_card.queue_free()
	overflow_card.queue_free()
	card.queue_free()
	await process_frame
	_finish()


func _descriptor_for(grouped: Array, group_key: String):
	for descriptor_value in grouped:
		var descriptor := descriptor_value as AttachmentVisualDescriptor
		if descriptor != null and descriptor.group_key == group_key:
			return descriptor
	return null


func _badge_for_group(row: HBoxContainer, group_key: String) -> Control:
	if row == null:
		return null
	for child_value in row.get_children():
		var child := child_value as Control
		if child != null and str(child.get_meta("energy_group_key", "")) == group_key:
			return child
	return null


func _check_count_badge(card: CardView, expected: String, layout_name: String) -> void:
	var row := card.find_child("EnergyRow", true, false) as HBoxContainer
	var badge := _badge_for_group(row, "energy:type:Fire")
	var count_badge := (
		badge.find_child("CountBadge", true, false) as Control
		if badge != null
		else null
	)
	var style := (
		count_badge.get_theme_stylebox("normal") as StyleBoxFlat
		if count_badge != null
		else null
	)
	_check(
		count_badge != null
		and str(count_badge.get_meta("count_text", "")) == expected
		and count_badge.size.x > count_badge.size.y
		and int(count_badge.get_meta("font_size", 0)) >= 9
		and int(count_badge.get_meta("outline_size", 0)) >= 1
		and count_badge.z_index > 0
		and style != null
		and style.bg_color.a >= 0.95
		and style.border_color.a >= 0.95
		and Rect2(Vector2.ZERO, badge.size).encloses(
			Rect2(count_badge.position, count_badge.size)
		),
		"Two-digit energy count was unreadable or clipped in %s layout: badge=%s count=%s"
		% [layout_name, badge.size if badge != null else Vector2.ZERO, count_badge.size if count_badge != null else Vector2.ZERO],
	)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("ATTACHMENT_VISUAL_CONTRACT_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)
