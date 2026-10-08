extends SceneTree

const Sources = preload("res://tools/card_source_registry.gd")
const Audit = preload("res://tools/card_printing_audit.gd")
const OUTPUT := "res://../build/card-text-audit"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var manifest: Dictionary = Sources.read_json(Sources.PATH)
	var review: Dictionary = Sources.read_json("res://authoring/card_review_manifest.json")
	var audit: Dictionary = review.printed_text_review
	var cache := "res://../.cache/card_sources/" + str(manifest.source.revision)
	var dataset_path := cache.path_join(str(manifest.source.dataset_path))
	if FileAccess.get_sha256(dataset_path) != str(manifest.source.dataset_sha256):
		push_error("Run tools/sync_card_sources.ps1 -Check to verify the pinned source cache first.")
		quit(1)
		return
	var source_data: Dictionary = Sources.read_json(dataset_path)
	var collections: Dictionary = {}
	for collection in source_data.collections:
		collections[int(collection.id)] = collection
	var catalog := CardCatalog.shared()
	var rows: Array[Dictionary] = []
	var failures: Array[String] = []
	var ids := catalog.cards.keys()
	ids.sort()
	for id in ids:
		var card: Dictionary = catalog.get_card(id)
		var ref: Dictionary = manifest.cards[id]
		var source_row: Dictionary = {}
		for row in collections[int(ref.collection_id)].cards:
			if int(row.id) == int(ref.source_card_id):
				source_row = row
				break
		var override: Dictionary = audit.source_overrides.get(id, {})
		var errors := Audit.mismatches(card, source_row, override)
		if FileAccess.get_sha256(cache.path_join(str(ref.image))) != str(ref.image_sha256):
			errors.append("image_sha256")
		for error in errors:
			failures.append("%s:%s" % [id, error])
		var groups: Array[Dictionary] = []
		for group in CardPresentation.detail_groups(card, catalog):
			groups.append({"kind": group.kind, "title": group.title, "text": _plain(str(group.bbcode))})
		rows.append({
			"id": id, "name": card.name, "meta": CardPresentation.meta_text(card),
			"image": "../../godot/assets/cards/%s.webp" % id,
			"printing": "%s · %s" % [card.set_name, card.number],
			"groups": groups,
			"compact": _plain(CardPresentation.detail_bbcode(card, catalog, null, CardPresentation.DetailLevel.COMPACT)),
			"changes": audit.corrected_fields.get(id, []),
			"format_only": id in audit.format_only_cards,
			"source_note": override.get("reason", ""), "errors": errors,
		})
	var report := {"date": audit.date, "cards": rows, "failures": failures,
		"source_revision": manifest.source.revision, "corrected_cards": audit.corrected_fields.size(),
		"format_only_cards": audit.format_only_cards.size(), "checked_fields": audit.checked_fields}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	var json := JSON.stringify(report, "  ", false, true)
	FileAccess.open(OUTPUT.path_join("report.json"), FileAccess.WRITE).store_string(json + "\n")
	var html := FileAccess.get_file_as_string("res://tools/reviews/card_printings.html")
	html = html.replace("__REPORT__", json.replace("</", "<\\/"))
	FileAccess.open(OUTPUT.path_join("review.html"), FileAccess.WRITE).store_string(html)
	if failures.is_empty():
		print("CARD_PRINTING_REVIEW_OK cards=%d corrected=%d format_only=%d" % [rows.size(), audit.corrected_fields.size(), audit.format_only_cards.size()])
	else:
		for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)


func _plain(value: String) -> String:
	return RegEx.create_from_string("\\[[^\\]]+\\]").sub(value, "", true)
