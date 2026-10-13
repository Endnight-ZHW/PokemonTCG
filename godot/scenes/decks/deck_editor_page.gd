class_name DeckEditorPage
extends Control

signal back_requested
signal card_requested(card_id: String)
signal confirmation_requested(message: String, action: Callable)
signal import_requested
signal share_requested(code: String)
signal validation_requested(message: String)

const PAGE_SIZE := 24
var library: DeckLibrary
var selected_key := ""
var draft: Dictionary = {"name": "未命名卡组", "profile": "casual60", "cards": []}
var _saved := ""
var _filtered: Array[String] = []
var _page := 0
var _search_text: Dictionary = {}
var _pool_tiles: Dictionary = {}
var _row_controls: Dictionary = {}
var _group_labels: Dictionary = {}
var _validation_message := ""
var _laying_out := false

@onready var deck_picker: OptionButton = %DeckPicker
@onready var deck_name: LineEdit = %DeckName
@onready var search: LineEdit = %Search
@onready var category: OptionButton = %Category
@onready var attribute: OptionButton = %Attribute
@onready var series: OptionButton = %Series
@onready var rarity: OptionButton = %Rarity
@onready var grid: GridContainer = %CardGrid
@onready var rows: VBoxContainer = %DeckRows
@onready var status_label: Label = %Status
@onready var notice: Label = %Notice

func _ready() -> void:
	%BackButton.pressed.connect(handle_back)
	%NewButton.pressed.connect(func() -> void: _guard(_load_deck.bind("")))
	%CopyButton.pressed.connect(_copy_draft)
	%SaveButton.pressed.connect(save)
	%DeleteButton.pressed.connect(_delete)
	%ImportButton.pressed.connect(func() -> void: _guard(import_requested.emit))
	%ShareButton.pressed.connect(_share)
	%ResetFiltersButton.pressed.connect(_reset_filters)
	%ValidationButton.pressed.connect(func() -> void: validation_requested.emit(_validation_message))
	%PreviousButton.pressed.connect(_change_page.bind(-1))
	%NextButton.pressed.connect(_change_page.bind(1))
	deck_picker.item_selected.connect(_choose_deck)
	deck_name.text_changed.connect(func(value: String) -> void:
		draft.name = value
		notice.text = "尚未保存修改"
		_refresh_status()
	)
	search.text_changed.connect(func(_value: String) -> void: _filter())
	for option in [category, attribute, series, rarity]:
		option.item_selected.connect(func(_index: int) -> void: _filter())
	resized.connect(_layout)
	(%PoolScroll as ScrollContainer).resized.connect(_layout)
	FrontendPalette.style_scrollbar((%PoolScroll as ScrollContainer).get_v_scroll_bar())
	FrontendPalette.style_scrollbar((%DeckScroll as ScrollContainer).get_v_scroll_bar())

func configure(p_library: DeckLibrary, key: String = "") -> void:
	library = p_library
	_options(category, {"全部类别": "", "宝可梦": "Pokémon", "物品": "Item", "支援者": "Supporter", "宝可梦道具": "Tool", "竞技场": "Stadium", "能量": "Energy"})
	var attributes := {"全部属性": ""}
	for type_name in ["Grass", "Fire", "Water", "Lightning", "Psychic", "Fighting", "Darkness", "Metal", "Dragon", "Colorless"]:
		attributes[EnergyIconCatalog.type_display_name_for(type_name)] = type_name
	_options(attribute, attributes)
	var sets := {"全部系列": ""}
	var rarities := {"全部稀有度": ""}
	for id in library.cards:
		var card := library.get_card(id)
		sets[str(card.get("set_name", ""))] = str(card.get("set_id", ""))
		var rarity_value := str(card.get("rarity", ""))
		rarities[rarity_value if not rarity_value.is_empty() else "无稀有度"] = rarity_value if not rarity_value.is_empty() else "__none__"
		var text_parts: PackedStringArray = [str(card.get("name","")),str(card.get("number","")),str(card.get("trainer_text",""))]
		for block in Array(card.get("attacks",[])) + Array(card.get("abilities",[])):
			text_parts.append(str(block.get("name","")))
			text_parts.append(str(block.get("text","")))
		for rule in card.get("rules",[]): text_parts.append(str(rule))
		_search_text[id] = "\n".join(text_parts).to_lower()
	_options(series, sets)
	_options(rarity, rarities)
	_refresh_picker()
	_load_deck(key)
	_filter()
	if not library.load_message.is_empty(): notice.text = library.load_message
	_layout()
	call_deferred("_play_enter_animation")

func _play_enter_animation() -> void:
	_layout()
	FrontendMotion.play_enter(self)

func _options(option: OptionButton, values: Dictionary) -> void:
	option.clip_text = true
	option.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	option.clear()
	for label in values:
		option.add_item(label)
		option.set_item_metadata(option.item_count - 1, values[label])

func _refresh_picker() -> void:
	deck_picker.clip_text = true
	deck_picker.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	deck_picker.clear()
	deck_picker.add_item("新卡组")
	deck_picker.set_item_metadata(0, "")
	for key in library.custom_keys() + DeckVisualCatalog.ordered_deck_keys(CardCatalog.shared()):
		var prefix := "我的 · " if library.is_custom(key) else "预设 · "
		deck_picker.add_item(prefix + str(library.get_deck(key).get("name", key)))
		deck_picker.set_item_metadata(deck_picker.item_count - 1, key)
	_sync_picker()

func _sync_picker() -> void:
	for index in range(deck_picker.item_count):
		if deck_picker.get_item_metadata(index) == selected_key:
			deck_picker.select(index)
			return
	deck_picker.select(0)

func _choose_deck(index: int) -> void:
	var key := str(deck_picker.get_item_metadata(index))
	_sync_picker()
	_guard(_load_deck.bind(key))

func _load_deck(key: String) -> void:
	if not key.is_empty() and library.get_deck(key).is_empty(): key = ""
	selected_key = key
	if key.is_empty():
		draft = {"name": "未命名卡组", "profile": DeckLibrary.PROFILE, "cards": []}
	else:
		draft = DeckLibrary.normalize_definition(library.get_deck(key)).deck
	deck_name.text = draft.name
	_saved = JSON.stringify(draft)
	_sync_picker()
	notice.text = "预设卡组：修改后保存为新的自定义卡组。" if not key.is_empty() and not library.is_custom(key) else ""
	_render_rows()
	_render_pool()
	%DeckScroll.scroll_vertical = 0

func is_dirty() -> bool:
	return JSON.stringify(draft) != _saved

func handle_back() -> bool:
	_guard(back_requested.emit)
	return true

func _guard(action: Callable) -> void:
	if is_dirty():
		confirmation_requested.emit("有未保存的修改，确定放弃这些修改吗？", action)
	else:
		action.call()

func _copy_draft() -> void:
	selected_key = ""
	draft = draft.duplicate(true)
	draft.name = str(draft.name).left(70) + " 副本"
	deck_name.text = draft.name
	_saved = ""
	_sync_picker()
	notice.text = "副本尚未保存，保存后会成为独立卡组。"
	_refresh_status()

func _share() -> void:
	var code := library.export_code(draft)
	if code.is_empty():
		notice.text = "草稿过大，暂时无法分享，请减少卡牌种类后重试。"
		return
	share_requested.emit(code)

func save() -> void:
	var key := selected_key if library.is_custom(selected_key) else ""
	var result := library.save_deck(draft, key)
	if not result.ok:
		notice.text = result.error
		return
	selected_key = result.key
	_refresh_picker()
	_load_deck(selected_key)
	notice.text = "卡组已保存。" if library.validate_key(selected_key).valid else "草稿已保存；修正构筑问题后即可对战。"

func _delete() -> void:
	if not library.is_custom(selected_key):
		return
	var key := selected_key
	confirmation_requested.emit("确定删除“%s”吗？" % draft.name, func() -> void:
		var result := library.delete_deck(key)
		if result.ok:
			_refresh_picker()
			_load_deck("")
		else:
			notice.text = result.error
	)

func import_text(code: String) -> bool:
	var result := library.import_code(code)
	if not result.ok:
		notice.text = result.error
		return false
	_refresh_picker()
	_load_deck(result.key)
	notice.text = "已导入为新的卡组。"
	return true

func _selected_value(option: OptionButton) -> String:
	return str(option.get_item_metadata(option.selected)) if option.selected >= 0 else ""

func _filter() -> void:
	if library == null:
		return
	_filtered.clear()
	var query := search.text.strip_edges().to_lower()
	var kind := _selected_value(category)
	var type_name := _selected_value(attribute)
	var set_id := _selected_value(series)
	var rarity_name := _selected_value(rarity)
	for id in library.cards:
		var card := library.get_card(id)
		if not query.is_empty() and not str(_search_text[id]).contains(query): continue
		if not kind.is_empty() and card.get("supertype") != kind and kind not in card.get("subtypes", []): continue
		if not type_name.is_empty() and type_name not in card.get("energy_types", []) and type_name not in card.get("provides_energy", []): continue
		if not set_id.is_empty() and card.get("set_id") != set_id: continue
		if rarity_name == "__none__" and not str(card.get("rarity", "")).is_empty(): continue
		if not rarity_name.is_empty() and rarity_name != "__none__" and card.get("rarity") != rarity_name: continue
		_filtered.append(id)
	_filtered.sort()
	_page = 0
	_render_pool()
	%PoolScroll.scroll_vertical = 0
	%ResetFiltersButton.disabled = query.is_empty() and kind.is_empty() and type_name.is_empty() and set_id.is_empty() and rarity_name.is_empty()

func _reset_filters() -> void:
	search.text = ""
	for option in [category, attribute, series, rarity]: option.select(0)
	_filter()

func _clear(container: Node) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()

func _count(id: String) -> int:
	for row in draft.cards:
		if row.card_id == id: return int(row.count)
	return 0

func change_count(id: String, delta: int) -> void:
	var count := maxi(0, _count(id) + delta)
	var entries: Array = []
	for row in draft.cards:
		if row.card_id != id: entries.append(row)
	if count > 0: entries.append({"card_id": id, "count": mini(count, 1000)})
	draft.cards = DeckLibrary.normalize_definition({"cards": entries}).deck.cards
	var scroll: int = %DeckScroll.scroll_vertical
	_render_rows()
	if _pool_tiles.has(id): (_pool_tiles[id] as FrontendCardTile).set_count(count)
	%DeckScroll.set_deferred("scroll_vertical", scroll)
	notice.text = "尚未保存修改"
	_layout()

func _button(label: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = label
	button.custom_minimum_size = Vector2(48, 48)
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(action)
	return button

func _render_pool() -> void:
	if library == null: return
	_clear(grid)
	_pool_tiles.clear()
	for index in range(_page * PAGE_SIZE, mini((_page + 1) * PAGE_SIZE, _filtered.size())):
		var id := _filtered[index]
		var cell := VBoxContainer.new()
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(cell)
		var tile := FrontendCardTile.new()
		cell.add_child(tile)
		tile.configure(library, id, _count(id), true)
		_pool_tiles[id] = tile
		tile.pressed.connect(card_requested.emit.bind(id))
		var add := _button("＋ 加入卡组", change_count.bind(id, 1))
		add.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.add_child(add)
	var pages := maxi(1, ceili(float(_filtered.size()) / PAGE_SIZE))
	%PageLabel.text = "%d 张卡牌 · %d / %d" % [_filtered.size(), _page + 1, pages]
	%PreviousButton.disabled = _page == 0
	%NextButton.disabled = _page + 1 >= pages
	%PoolEmpty.visible = _filtered.is_empty()
	_layout()

func _change_page(delta: int) -> void:
	_page += delta
	_render_pool()
	%PoolScroll.scroll_vertical = 0

func _render_rows() -> void:
	var groups := {"Pokémon": [], "Trainer": [], "Energy": [], "未知": []}
	var wanted: Dictionary = {}
	for row in draft.cards:
		var id := str(row.card_id)
		wanted[id] = true
		var kind := str(library.get_card(id).get("supertype", "未知"))
		groups[kind if groups.has(kind) else "未知"].append(id)
		if not _row_controls.has(id): _row_controls[id] = _create_row(id)
		(_row_controls[id].quantity as Label).text = str(row.count)
		(_row_controls[id].plus as Button).disabled = int(row.count) >= 1000
	for id in _row_controls.keys():
		if not wanted.has(id):
			var line: Control = _row_controls[id].line
			rows.remove_child(line)
			line.queue_free()
			_row_controls.erase(id)
	var position := 0
	var titles := {"Pokémon": "宝可梦", "Trainer": "训练家", "Energy": "能量", "未知": "缺失卡牌"}
	for kind in groups:
		if groups[kind].is_empty():
			if _group_labels.has(kind): (_group_labels[kind] as Label).hide()
			continue
		if not _group_labels.has(kind):
			var label := Label.new()
			label.add_theme_font_size_override("font_size", 15)
			label.add_theme_color_override("font_color", FrontendPalette.MUTED)
			label.custom_minimum_size.y = 28
			rows.add_child(label)
			_group_labels[kind] = label
		var label: Label = _group_labels[kind]
		var total := 0
		for id in groups[kind]: total += _count(id)
		label.text = "%s · %d 张" % [titles[kind], total]
		label.show()
		rows.move_child(label, position)
		position += 1
		for id in groups[kind]:
			rows.move_child(_row_controls[id].line, position)
			position += 1
	%DeckEmpty.visible = draft.cards.is_empty()
	_refresh_status()

func _create_row(id: String) -> Dictionary:
	var card := library.get_card(id)
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 6)
	rows.add_child(line)
	var title := _button("", card_requested.emit.bind(id))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.theme_type_variation = &"DeckGalleryTileButton"
	title.disabled = card.is_empty()
	title.tooltip_text = library.card_name(id) + "\n" + FrontendCardTile.printing_caption(card)
	title.accessibility_name = title.tooltip_text
	line.add_child(title)
	var body := HBoxContainer.new()
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.add_child(body)
	body.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	body.offset_left = 10
	body.offset_right = -10
	body.offset_top = 6
	body.offset_bottom = -6
	body.add_theme_constant_override("separation", 9)
	var art := TextureRect.new()
	art.custom_minimum_size = Vector2(34, 44)
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	art.texture = FrontendAttributes.card_texture(library, id) if not card.is_empty() else null
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(art)
	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.alignment = BoxContainer.ALIGNMENT_CENTER
	text.add_theme_constant_override("separation", 1)
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(text)
	for caption in [library.card_name(id) if not card.is_empty() else "缺失卡牌", FrontendCardTile.printing_caption(card) if not card.is_empty() else id]:
		var label := Label.new()
		label.text = caption
		label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		label.add_theme_font_size_override("font_size", 17 if text.get_child_count() == 0 else 13)
		label.add_theme_color_override("font_color", FrontendPalette.TEXT if text.get_child_count() == 0 else FrontendPalette.MUTED)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		text.add_child(label)
	line.add_child(_button("−", change_count.bind(id, -1)))
	var quantity := Label.new()
	quantity.custom_minimum_size.x = 28
	quantity.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	line.add_child(quantity)
	var plus := _button("＋", change_count.bind(id, 1))
	line.add_child(plus)
	return {"line": line, "title": title, "quantity": quantity, "plus": plus}

func _refresh_status() -> void:
	if library == null: return
	var validation := library.validate_rows(draft.cards)
	_validation_message = DeckLibrary.validation_text(validation).replace("；", "\n\n")
	status_label.text = "卡组合法，可以对战" if validation.valid else "草稿 · %d 项构筑问题，可保存后继续编辑" % validation.errors.size()
	status_label.tooltip_text = _validation_message
	status_label.add_theme_color_override("font_color", FrontendPalette.SUCCESS if validation.valid else FrontendPalette.DANGER)
	%ValidationButton.disabled = validation.valid
	%ValidationButton.visible = not validation.valid
	%ValidationButton.text = "构筑合法" if validation.valid else "查看问题 (%d)" % validation.errors.size()
	var counts := {"Pokémon": 0, "Trainer": 0, "Energy": 0}
	for row in draft.cards:
		var kind := str(library.get_card(row.card_id).get("supertype", "未知"))
		counts[kind] = int(counts.get(kind, 0)) + int(row.count)
	%DeckStats.text = "%d / 60 张  ·  宝可梦 %d  ·  训练家 %d  ·  能量 %d" % [int(validation.card_count), counts["Pokémon"], counts.Trainer, counts.Energy]
	%SaveButton.text = "保存 *" if is_dirty() else "保存"
	%DeleteButton.disabled = not library.is_custom(selected_key)

func _layout() -> void:
	if not is_node_ready() or _laying_out: return
	_laying_out = true
	var scale_y := maxf(0.1, get_viewport().get_final_transform().get_scale().y)
	var touch_size := float(ceili(48.0 / scale_y))
	for control in find_children("*", "BaseButton", true, false):
		if control is FrontendCardTile: continue
		(control as Control).custom_minimum_size.y = touch_size
		if control is Button and control.text in ["＋", "−"]: control.custom_minimum_size.x = touch_size
	for input in [search,deck_name]: input.custom_minimum_size.y = touch_size
	for entry in _row_controls.values(): (entry.title as Button).custom_minimum_size.y = maxf(62, touch_size)
	%Filters.columns = 4 if (%PoolScroll as ScrollContainer).size.x >= 650 else 2
	var pool_width := (%PoolScroll as ScrollContainer).size.x - 12
	grid.columns = clampi(int(pool_width / 154.0), 2, 5)
	var tile_width := (pool_width - (grid.columns - 1) * 10.0) / grid.columns
	var available_height := maxf(180, (%PoolScroll as ScrollContainer).size.y - touch_size - 16)
	for tile in _pool_tiles.values(): tile.set_tile_height(minf(maxf(240, tile_width * 1.396 + 70), available_height))
	var margin := UILayoutPolicy.content_margin(size, 1560.0, 12, 24)
	for edge in ["left", "right", "top", "bottom"]:
		%Margin.add_theme_constant_override("margin_" + edge, margin)
	_laying_out = false
