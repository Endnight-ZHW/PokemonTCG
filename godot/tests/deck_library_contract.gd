extends SceneTree

var failures: Array[String] = []
var path := "user://deck-library-contract-%d.json" % Time.get_ticks_usec()

func _init() -> void:
	call_deferred("run")

func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)

func run() -> void:
	var library := DeckLibrary.new(path)
	var preset := library.get_deck("fire").duplicate(true)
	var saved := library.save_deck(preset)
	check(saved.get("ok", false), "Could not save custom copy")
	if not saved.get("ok", false):
		quit(1)
		return
	var key: String = saved.key
	check(library.validate_key(key).valid, "Valid preset copy rejected")
	check(not CardCatalog.shared().decks.has(key) and CardCatalog.shared().is_read_only_repository(), "Custom deck mutated shared catalog")
	var reopened := DeckLibrary.new(path)
	check(reopened.expand_deck(key) == library.expand_deck(key), "Persistence round trip changed cards")
	var code := library.export_code(preset)
	var imported := library.import_code(code)
	check(imported.get("ok", false) and imported.get("key") != key, "Import reused local identity")
	check(library.expand_deck(imported.key) == library.expand_deck(key), "Share round trip changed cards")
	check(not library.import_code("PTCG1:!").ok, "Malformed share code accepted")
	check(not library.import_code(code + "A").ok, "Corrupt share code accepted")
	var rows: Array = preset.cards.duplicate(true)
	rows[0].count += 1
	check(not library.validate_rows(rows).valid, "61 cards accepted")
	rows[0].count -= 2
	check(not library.validate_rows(rows).valid, "59 cards accepted")
	check(not library.validate_rows([{ "card_id": "sv1-ener-2", "count": 60 }]).valid, "Deck without basic Pokemon accepted")
	check(not library.validate_rows([{ "card_id": "svi-chim", "count": 5 }, {"card_id": "sv1-ener-2", "count": 55}]).valid, "Five copies accepted")
	check(library.validate_rows([{ "card_id": "svi-chim", "count": 1 }, {"card_id": "sv1-ener-2", "count": 59}]).valid, "Basic energy exemption rejected")
	check(not library.validate_rows([{ "card_id": "svi-chim", "count": 1.5 }]).valid, "Fractional count accepted")
	check(not library.validate_rows([{ "card_id":"csv5-075", "count":3 }, {"card_id":"csv5-145", "count":2},
		{"card_id":"csv5-014", "count":1},{"card_id":"sv1-ener-2", "count":54}]).valid, "Cross-print same-name limit bypassed")
	for invalid in [0,-1,INF,NAN,true,"2"]:
		check(not library.validate_rows([{ "card_id":"csv5-014", "count":invalid }]).valid, "Invalid numeric count accepted")
	var unknown := library.save_deck({"name": "未来卡草稿", "cards": [{"card_id": "missing-card", "count": 60}]})
	check(unknown.ok and not library.validate_key(unknown.key).valid, "Missing cards were not retained as draft")
	var draft_restored := DeckLibrary.new(path)
	check(draft_restored.get_deck(unknown.key).cards[0].card_id == "missing-card", "Restart discarded missing card")
	var missing_import := library.import_code(library.export_code(library.get_deck(unknown.key)))
	check(missing_import.ok and library.get_deck(missing_import.key).cards[0].card_id == "missing-card", "Import discarded missing card")
	var broken_native: Variant = ClassDB.instantiate("NativeRulesSession")
	check(not broken_native.set_catalog({"bad-card":{"attacks":"wrong"}}) and not str(broken_native.get_catalog_error()).is_empty(), "Malformed catalog failed to report an error")
	var frozen := library.freeze_deck(key)
	check(frozen.ok, "Freeze failed: " + str(frozen.get("error", "")))
	check(library.freeze_deck("water").ok, "Preset freeze failed: " + str(library.freeze_deck("water")))
	var session := NativeRulesSessionAdapter.new(library)
	var started := session.start_match(key, "water", 1234, 0)
	check(started.success, "Custom deck could not start local match: " + started.error_code + " " + started.message)
	if started.success:
		check(session.state.public_deck_keys == ["custom", "water"], "Private local ID leaked into public keys")
		var view: Dictionary = session.native.ai_observation_for(1)
		check(not JSON.stringify(view).contains(key) and not JSON.stringify(view).contains("private_deck_definitions"), "AI observation leaked deck definition")
	library.save_deck({"name": "changed", "cards": []}, key)
	check(frozen.cards.size() == 60, "Editing changed a frozen match deck")
	var editor := preload("res://scenes/decks/deck_editor_page.tscn").instantiate() as DeckEditorPage
	root.add_child(editor)
	editor.set_deferred("size", Vector2(1280, 720))
	editor.configure(library, imported.key)
	await process_frame
	check(editor.grid.get_child_count() > 0, "Editor card pool empty")
	check(not editor.is_dirty(), "Loaded deck is incorrectly dirty")
	editor.change_count("svi-chim", 1)
	check(editor.is_dirty(), "Editing not tracked")
	editor.queue_free()
	await process_frame
	# The previous valid file is retained if a later write is damaged.
	var corrupt := FileAccess.open(path, FileAccess.WRITE)
	corrupt.store_string("broken")
	corrupt.close()
	var recovered := DeckLibrary.new(path)
	check(not recovered.load_message.is_empty() and not recovered.custom_keys().is_empty(), "Backup recovery failed")
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(path + suffix): DirAccess.remove_absolute(path + suffix)
	if failures.is_empty(): print("DECK_LIBRARY_CONTRACT_OK")
	quit(0 if failures.is_empty() else 1)
