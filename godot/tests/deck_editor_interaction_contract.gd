extends SceneTree

var failures: Array[String] = []
var path := "user://deck-editor-review-%d.json" % Time.get_ticks_usec()

func _initialize() -> void:
	call_deferred("run")

func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)

func settle() -> void:
	for _frame in 6: await process_frame

func run() -> void:
	var library := DeckLibrary.new(path)
	var definition := library.get_deck("fire").duplicate(true)
	definition.name = "长名字测试".repeat(16)
	var saved := library.save_deck(definition)
	check(saved.ok, "Could not create review fixture")
	check(FileAccess.file_exists(path + ".bak"), "First saved deck has no recovery backup")
	var damaged := FileAccess.open(path, FileAccess.WRITE)
	damaged.store_string("damaged first save")
	damaged.close()
	var recovered := DeckLibrary.new(path)
	check(recovered.get_deck(saved.key).get("cards") == library.get_deck(saved.key).cards, "First-save backup did not recover the original cards")
	var oversized: Array = []
	for index in 1000: oversized.append({"card_id": "%04d-" % index + "x".repeat(120), "count": 1})
	check(library.export_code({"name": "large", "cards": oversized}).is_empty(), "Export produced a share code its importer refuses")
	var page := preload("res://scenes/decks/deck_editor_page.tscn").instantiate() as DeckEditorPage
	root.add_child(page)
	page.set_deferred("size", Vector2(1280, 720))
	page.configure(library, saved.key)
	await settle()
	check(page.deck_picker.get_minimum_size().x <= page.size.x * 0.5, "Long deck name expands the header outside the editor")
	var longest := 0
	for index in page.series.item_count:
		if page.series.get_item_text(index).length() > page.series.get_item_text(longest).length(): longest = index
	page.series.select(longest)
	page._filter()
	await settle()
	check(page.get_node("%PoolScroll").get_global_rect().end.x < page.deck_name.get_global_rect().position.x, "Long series filter expands over the deck list")
	page._reset_filters()
	await settle()
	var pool: ScrollContainer = page.get_node("%PoolScroll")
	pool.scroll_vertical = 450
	await settle()
	var before_scroll := pool.scroll_vertical
	var first_tile := page.grid.get_child(0).get_child(0)
	var first_id := first_tile.get_instance_id()
	page.change_count(page._filtered[0], 1)
	await settle()
	check(page.grid.get_child(0).get_child(0).get_instance_id() == first_id, "Changing quantity destroys card pool controls")
	check(pool.scroll_vertical == before_scroll, "Changing quantity moves the card pool's reading position")
	var edited_id := str(page.draft.cards[0].card_id)
	var row: Node = page._row_controls[edited_id].line
	var row_id := row.get_instance_id()
	page.change_count(edited_id, 1)
	await settle()
	check(page._row_controls[edited_id].line.get_instance_id() == row_id, "Repeated quantity edits destroy deck rows")
	page.search.text = "不存在的卡牌搜索"
	page._filter()
	check(page.get_node("%PoolEmpty").visible, "Empty card search has no explanation")
	page._reset_filters()
	check(page._filtered.size() == 341 and not page.get_node("%PoolEmpty").visible, "Clearing filters did not restore the card pool")
	var picker := preload("res://scenes/decks/deck_select_page.tscn").instantiate() as DeckSelectPage
	root.add_child(picker)
	picker.configure(library, "local")
	picker.select_deck(0, saved.key)
	picker.select_deck(1, "water")
	picker.matchup_toggle.set_pressed_no_signal(true)
	var context := picker.editor_context()
	library.save_deck({"name": "unfinished", "cards": []}, saved.key)
	picker.configure(library, "local")
	picker.restore_editor_context(context)
	check(picker.selected_deck_key(0) == saved.key and picker.selected_deck_key(1) == "water" and picker.matchup_toggle.button_pressed, "Editing lost assignments or match rules")
	check(picker.start_button.disabled, "Edited invalid draft can start a match")
	library.delete_deck(saved.key)
	picker.configure(library, "local")
	picker.restore_editor_context(context)
	check(picker.selected_deck_key(0).is_empty() and picker.start_button.disabled, "Deleting selected deck silently substituted a preset")
	picker.queue_free()
	page.queue_free()
	await settle()
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(path + suffix): DirAccess.remove_absolute(path + suffix)
	if failures.is_empty(): print("DECK_EDITOR_INTERACTION_CONTRACT_OK")
	quit(0 if failures.is_empty() else 1)
