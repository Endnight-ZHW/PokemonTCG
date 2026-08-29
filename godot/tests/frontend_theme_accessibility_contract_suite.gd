extends RefCounted

var context: FrontendContractContext


func configure(contract_context: FrontendContractContext) -> void:
	context = contract_context


func _check_theme_contract() -> void:
	context._check(FileAccess.file_exists(context.FRONT_THEME_PATH), "Frontend theme resource is missing")
	var theme := load(context.FRONT_THEME_PATH) as Theme
	context._check(theme != null, "Frontend theme must load as Theme")
	if theme == null:
		return
	var expected_variations := {
		"FrontPrimaryButton": "Button",
		"FrontSecondaryButton": "Button",
		"FrontGhostButton": "Button",
		"FrontDangerButton": "Button",
		"FrontRuleToggle": "CheckButton",
		"FrontModeTileButton": "Button",
		"FrontSectionPanel": "PanelContainer",
		"FrontRaisedPanel": "PanelContainer",
		"FrontCardFrame": "PanelContainer",
		"FrontStatusPanel": "PanelContainer",
		"FrontHeadingLabel": "Label",
		"FrontMutedLabel": "Label",
		"DeckGalleryTileButton": "Button",
		"TitleLogoLabel": "Label",
	}
	for variation in expected_variations:
		context._check(
			theme.get_type_variation_base(StringName(variation))
			== StringName(expected_variations[variation]),
			"Frontend theme variation %s must derive from %s" % [
				variation, expected_variations[variation],
			],
		)
	for variation in [
		&"FrontSecondaryButton", &"FrontGhostButton",
		&"FrontDangerButton", &"FrontCategoryButton",
	]:
		_check_button_state_geometry(theme, variation)
	_check_button_state_geometry(theme, &"FrontRuleToggle")
	var rule_toggle_normal := (
		theme.get_stylebox(&"normal", &"FrontRuleToggle") as StyleBoxFlat
	)
	var rule_toggle_hover := (
		theme.get_stylebox(&"hover", &"FrontRuleToggle") as StyleBoxFlat
	)
	var rule_toggle_pressed := (
		theme.get_stylebox(&"pressed", &"FrontRuleToggle") as StyleBoxFlat
	)
	var rule_toggle_hover_pressed := (
		theme.get_stylebox(&"hover_pressed", &"FrontRuleToggle") as StyleBoxFlat
	)
	var rule_toggle_disabled := (
		theme.get_stylebox(&"disabled", &"FrontRuleToggle") as StyleBoxFlat
	)
	var rule_toggle_on := theme.get_icon(&"checked", &"FrontRuleToggle")
	var rule_toggle_off := theme.get_icon(&"unchecked", &"FrontRuleToggle")
	context._check(
		rule_toggle_on != null
		and rule_toggle_off != null
		and rule_toggle_on.get_size().x >= 40.0
		and rule_toggle_on.get_size().y >= 24.0
		and rule_toggle_off.get_size() == rule_toggle_on.get_size(),
		"Rule toggle must use a legible, size-stable switch track in both states",
	)
	context._check(
		rule_toggle_normal != null
		and rule_toggle_hover != null
		and rule_toggle_pressed != null
		and rule_toggle_hover_pressed != null
		and rule_toggle_disabled != null
		and not rule_toggle_hover.bg_color.is_equal_approx(rule_toggle_normal.bg_color)
		and not rule_toggle_pressed.bg_color.is_equal_approx(rule_toggle_normal.bg_color)
		and rule_toggle_disabled.bg_color.a < rule_toggle_normal.bg_color.a
		and theme.get_color(&"icon_disabled_color", &"FrontRuleToggle").a
		< theme.get_color(&"icon_normal_color", &"FrontRuleToggle").a,
		"Rule toggle needs distinct hover/on states and a visibly subdued locked state",
	)
	if (
		rule_toggle_normal != null
		and rule_toggle_pressed != null
		and rule_toggle_hover_pressed != null
	):
		for state_style in [
			rule_toggle_normal, rule_toggle_pressed, rule_toggle_hover_pressed,
		]:
			for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
				context._check(
					state_style.get_border_width(side)
					== rule_toggle_normal.get_border_width(side)
					and state_style.get_border_width(side) >= 2,
					"Rule toggle normal/on/enabled-hover borders must remain visible and size-stable",
				)
			context._check(
				state_style.border_color.a >= 0.9
				and absf(
					state_style.border_color.get_luminance()
					- state_style.bg_color.get_luminance()
				) >= 0.12,
				"Rule toggle normal/on/enabled-hover border color blends into its background",
			)
	context._check(
		theme.has_stylebox(&"normal", &"FrontPrimaryButton")
		and theme.has_stylebox(&"hover", &"FrontPrimaryButton")
		and theme.has_stylebox(&"pressed", &"FrontPrimaryButton")
		and theme.has_stylebox(&"disabled", &"FrontPrimaryButton"),
		"Primary button variation must define pointer and disabled states",
	)
	context._check(
		theme.has_stylebox(&"normal", &"DeckGalleryTileButton")
		and theme.has_stylebox(&"hover", &"DeckGalleryTileButton")
		and theme.has_stylebox(&"pressed", &"DeckGalleryTileButton")
		and theme.has_stylebox(&"hover_pressed", &"DeckGalleryTileButton")
		and theme.has_stylebox(&"disabled", &"DeckGalleryTileButton"),
		"Deck-gallery tile variation must define every pointer interaction state",
	)
	context._check(
		theme.get_constant(&"v_separation", &"PopupMenu") >= 24,
		"Frontend PopupMenu rows must reserve touch-friendly vertical spacing",
	)
	context._check(
		theme.get_icon(&"grabber", &"HSlider")
		!= theme.get_icon(&"grabber_highlight", &"HSlider"),
		"Frontend sliders need a visible hover grabber state",
	)
	context._check(
		_font_weight(theme.default_font) >= 600.0,
		"Frontend compact body text must use Noto Semibold 600 or heavier",
	)
	context._check(
		theme.has_font(&"font", &"Button")
		and _font_weight(theme.get_font(&"font", &"Button")) >= 700.0,
		"Frontend controls must use Noto Bold 700",
	)
	for heading_type in [&"FrontHeadingLabel", &"FrontSectionLabel", &"TitleLogoLabel"]:
		context._check(
			theme.has_font(&"font", heading_type)
			and _font_weight(theme.get_font(&"font", heading_type)) >= 700.0,
			"Frontend heading weight must remain Bold 700: %s" % heading_type,
		)
	_check_frontend_contrast(theme)
	var battle_theme := load(context.GAME_THEME_PATH) as Theme
	context._check(battle_theme != null, "Battle theme must load for semantic button checks")
	if battle_theme:
		for variation in [
			&"BattlePrimaryButton", &"BattleSecondaryButton", &"BattleDangerButton",
		]:
			context._check(
				battle_theme.get_type_variation_base(variation) == &"Button"
				and battle_theme.has_stylebox(&"normal", variation)
				and battle_theme.has_stylebox(&"hover", variation)
				and battle_theme.has_stylebox(&"pressed", variation)
				and battle_theme.has_stylebox(&"disabled", variation),
				"Battle semantic button variation is incomplete: %s" % variation,
			)


func _check_button_state_geometry(theme: Theme, variation: StringName) -> void:
	var states := [&"normal", &"hover", &"pressed", &"hover_pressed", &"disabled"]
	var styles: Array[StyleBoxFlat] = []
	for state in states:
		var style := theme.get_stylebox(state, variation) as StyleBoxFlat
		context._check(style != null, "%s lacks %s style" % [variation, state])
		if style:
			styles.append(style)
	context._check(theme.has_stylebox(&"focus", variation), "%s lacks focus style" % variation)
	if styles.size() != states.size():
		return
	var reference := styles[0]
	for style in styles.slice(1):
		for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
			context._check(
				is_equal_approx(
					reference.get_content_margin(side),
					style.get_content_margin(side),
				)
				and reference.get_border_width(side) == style.get_border_width(side),
				"%s changes padding or border width between pointer states" % variation,
			)
		for corner in [CORNER_TOP_LEFT, CORNER_TOP_RIGHT, CORNER_BOTTOM_RIGHT, CORNER_BOTTOM_LEFT]:
			context._check(
				reference.get_corner_radius(corner) == style.get_corner_radius(corner),
				"%s changes corner radius between pointer states" % variation,
			)


func _check_frontend_contrast(theme: Theme) -> void:
	var raised := theme.get_stylebox(&"panel", &"FrontRaisedPanel") as StyleBoxFlat
	var primary := theme.get_stylebox(&"normal", &"FrontPrimaryButton") as StyleBoxFlat
	var primary_hover := theme.get_stylebox(&"hover", &"FrontPrimaryButton") as StyleBoxFlat
	var primary_pressed := theme.get_stylebox(&"pressed", &"FrontPrimaryButton") as StyleBoxFlat
	var status := theme.get_stylebox(&"panel", &"FrontStatusPanel") as StyleBoxFlat
	var input := theme.get_stylebox(&"normal", &"LineEdit") as StyleBoxFlat
	var scroll_track := theme.get_stylebox(&"scroll", &"VScrollBar") as StyleBoxFlat
	var scroll_grabber := theme.get_stylebox(&"grabber", &"VScrollBar") as StyleBoxFlat
	context._check(raised != null, "Raised frontend panel style is unavailable for contrast checks")
	context._check(primary != null, "Primary frontend button style is unavailable for contrast checks")
	context._check(
		primary_hover != null and primary_pressed != null,
		"Primary frontend pointer styles are unavailable for contrast checks",
	)
	context._check(status != null, "Status frontend panel style is unavailable for contrast checks")
	context._check(input != null, "Frontend input style is unavailable for contrast checks")
	context._check(scroll_track != null and scroll_grabber != null,
		"Frontend scrollbar styles are unavailable for contrast checks")
	if (
		raised == null
		or primary == null
		or primary_hover == null
		or primary_pressed == null
		or status == null
		or input == null
		or scroll_track == null
		or scroll_grabber == null
	):
		return
	var body_text := theme.get_color(&"font_color", &"Label")
	var muted_text := theme.get_color(&"font_color", &"FrontMutedLabel")
	context._check(
		context._contrast_ratio(body_text, raised.bg_color) >= 4.5,
		"Frontend body text contrast must be at least 4.5:1 (actual %.2f:1)" % [
			context._contrast_ratio(body_text, raised.bg_color),
		],
	)
	context._check(
		context._contrast_ratio(muted_text, raised.bg_color) >= 4.5,
		"Frontend secondary text contrast must be at least 4.5:1 (actual %.2f:1)" % [
			context._contrast_ratio(muted_text, raised.bg_color),
		],
	)
	context._check(
		context._contrast_ratio(primary.bg_color, raised.bg_color) >= 3.0,
		"Gold primary state contrast must be at least 3:1 (actual %.2f:1)" % [
			context._contrast_ratio(primary.bg_color, raised.bg_color),
		],
	)
	context._check(
		context._contrast_ratio(status.border_color, status.bg_color) >= 3.0,
		"Cyan status boundary contrast must be at least 3:1 (actual %.2f:1)" % [
			context._contrast_ratio(status.border_color, status.bg_color),
		],
	)
	var status_background := context._composite_color(status.bg_color, raised.bg_color)
	var error_text := Color("#ff9aa4")
	context._check(
		context._contrast_ratio(error_text, status_background) >= 4.5,
		"Frontend error text contrast must be at least 4.5:1 (actual %.2f:1)" % [
			context._contrast_ratio(error_text, status_background),
		],
	)
	context._check(
		context._contrast_ratio(input.border_color, raised.bg_color) >= 3.0,
		"Frontend input boundary contrast must be at least 3:1 (actual %.2f:1)" % [
			context._contrast_ratio(input.border_color, raised.bg_color),
		],
	)
	var track_background := context._composite_color(scroll_track.bg_color, raised.bg_color)
	var grabber_background := context._composite_color(
		scroll_grabber.bg_color,
		track_background,
	)
	context._check(
		context._contrast_ratio(grabber_background, track_background) >= 3.0,
		"Frontend scrollbar boundary contrast must be at least 3:1 (actual %.2f:1)" % [
			context._contrast_ratio(grabber_background, track_background),
		],
	)


func _check_frontend_font_coverage() -> void:
	context._check(FileAccess.file_exists(context.FRONT_FONT_PATH), "Frontend CJK font file is missing")
	context._check(
		FileAccess.get_sha256(context.FRONT_FONT_PATH).to_upper()
		== "990C807E79C25662A5A9ECF7F971BAEB2BF2EAB9A559E5ECF15CDFDB8561D21F",
		"Frontend CJK font checksum does not match the documented Noto 2.004 source",
	)
	context._check(
		FileAccess.file_exists("res://assets/ui/fonts/OFL.txt")
		and FileAccess.file_exists("res://assets/ui/fonts/SOURCE.md"),
		"Frontend CJK font license/source notice is missing",
	)
	var font := load(context.FRONT_FONT_PATH) as Font
	context._check(font != null, "Frontend CJK font must load as a Font resource")
	if font == null:
		return
	var font_rows := [
		["res://assets/ui/fonts/noto_sans_cjk_sc_regular.tres", 400.0],
		["res://assets/ui/fonts/noto_sans_cjk_sc_medium.tres", 500.0],
		["res://assets/ui/fonts/noto_sans_cjk_sc_semibold.tres", 600.0],
		["res://assets/ui/fonts/noto_sans_cjk_sc_bold.tres", 700.0],
	]
	for row in font_rows:
		var variation := load(str(row[0])) as FontVariation
		context._check(
			variation != null
			and is_equal_approx(
				float(variation.variation_opentype.get(context.FONT_WEIGHT_TAG, -1.0)),
				float(row[1]),
			),
			"Frontend FontVariation has the wrong weight: %s" % row[0],
		)
	var game_theme := load(context.GAME_THEME_PATH) as Theme
	context._check(game_theme != null, "Game theme must load for font-weight checks")
	if game_theme:
		context._check(
			_font_weight(game_theme.default_font) >= 600.0,
			"Game body/HUD text must use Noto Semibold 600 or heavier",
		)
		for control_type in [&"Button", &"CheckButton", &"OptionButton", &"PopupMenu"]:
			context._check(
				game_theme.has_font(&"font", control_type)
				and _font_weight(game_theme.get_font(&"font", control_type)) >= 700.0,
				"Game control text must use Noto Bold 700: %s" % control_type,
			)
	var sources: Array[String] = []
	for directory in ["res://scenes", "res://ui"]:
		for path in context._files_recursive(directory):
			if path.get_extension() in ["gd", "tscn", "tres"]:
				sources.append(path)
	for path in [
		"res://data/cards.json",
		"res://data/decks.json",
	]:
		if FileAccess.file_exists(path):
			sources.append(path)
	var checked: Dictionary = {}
	var missing: Array[String] = []
	for path in sources:
		var source := FileAccess.get_file_as_string(path)
		for character in source:
			var codepoint := (character as String).unicode_at(0)
			if codepoint < 33 or checked.has(codepoint):
				continue
			checked[codepoint] = true
			if not font.has_char(codepoint):
				missing.append("U+%04X %s" % [codepoint, character])
	context._check(
		missing.is_empty(),
		"Frontend CJK font is missing current UI/data characters: %s" % [
			", ".join(missing.slice(0, mini(12, missing.size()))),
		],
	)


func _font_weight(font: Font) -> float:
	if font is FontVariation:
		return float((font as FontVariation).variation_opentype.get(context.FONT_WEIGHT_TAG, -1.0))
	return -1.0


func _check_battle_theme_isolation() -> void:
	var battle_scene := load("res://scenes/battle/components/battle_table.tscn") as PackedScene
	context._check(battle_scene != null, "Battle screen must remain loadable for theme isolation")
	if battle_scene:
		var battle := battle_scene.instantiate() as Control
		context._check(battle.theme == null, "BattleTable context.tree.root must continue inheriting the game theme")
		battle.free()
