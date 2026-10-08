extends SceneTree
## Import printing metadata and original pixels; gameplay stays in author JSON.

const Sources = preload("res://tools/card_source_registry.gd")
const PrintingAudit = preload("res://tools/card_printing_audit.gd")
const CARD_ROOT := "res://authoring/cards"


func _init() -> void:
	var error := _run()
	if not error.is_empty():
		printerr("CARD_SOURCE_ERROR %s" % error)
	quit(0 if error.is_empty() else 1)


func _run() -> String:
	var args := OS.get_cmdline_user_args()
	if args.size() != 2 or args[0] not in ["import", "check"]:
		return "usage: import|check <verified-cache-directory>"
	var checking := args[0] == "check"
	var cache := args[1]
	var manifest_value: Variant = Sources.read_json(Sources.PATH)
	if not manifest_value is Dictionary:
		return "manifest_missing"
	var manifest: Dictionary = manifest_value
	var review: Dictionary = Sources.read_json("res://authoring/card_review_manifest.json")
	var overrides: Dictionary = review.get("printed_text_review", {}).get("source_overrides", {})
	var documents: Dictionary = {}
	var cards: Dictionary = {}
	for filename in DirAccess.get_files_at(CARD_ROOT):
		if not filename.ends_with(".json"):
			continue
		var path := CARD_ROOT.path_join(filename)
		var document_value: Variant = Sources.read_json(path)
		if not document_value is Dictionary or not document_value.get("cards") is Dictionary:
			return "invalid_authoring_document:%s" % path
		var document: Dictionary = document_value
		for card_id in document["cards"]:
			if cards.has(card_id):
				return "duplicate_card_id:%s" % card_id
			cards[card_id] = document["cards"][card_id]
		documents[path] = document
	var error := Sources.validate_manifest(manifest, cards.keys())
	if not error.is_empty():
		return error
	var dataset_path := cache.path_join(str(manifest["source"]["dataset_path"]))
	if FileAccess.get_sha256(dataset_path) != str(manifest["source"]["dataset_sha256"]):
		return "dataset_sha256_mismatch"
	var dataset: Dictionary = Sources.read_json(dataset_path)
	var collections: Dictionary = {}
	var printed_sets: Dictionary = {}
	for collection in dataset.get("collections", []):
		collections[int(collection["id"])] = collection
		printed_sets[str(collection["commodityCode"])] = collection
	var images: Dictionary = {}
	var stale: Array[String] = []
	for card_id in cards:
		var card: Dictionary = cards[card_id]
		var source: Dictionary = manifest["cards"][card_id]
		var collection: Dictionary = collections.get(int(source["collection_id"]), {})
		var row: Dictionary = {}
		for candidate in collection.get("cards", []):
			if int(candidate.get("id", 0)) == int(source["source_card_id"]):
				row = candidate
				break
		if row.is_empty() or str(row.get("image", "")) != str(source["image"]):
			return "printing_not_found:%s" % card_id
		var override: Dictionary = overrides.get(card_id, {})
		if not override.is_empty() and override.get("image_sha256") != source["image_sha256"]:
			return "stale_printing_override:%s" % card_id
		error = ",".join(PrintingAudit.mismatches(card, row, override))
		if not error.is_empty():
			return "printing_mismatch:%s:%s" % [card_id, error]
		var printed_set: Dictionary = printed_sets.get(str(row["details"]["commodityCode"]), {})
		var metadata := Sources.metadata(row, printed_set, Sources.image_url(manifest, card_id))
		for field in metadata:
			if checking and card.get(field) != metadata[field]:
				stale.append("%s:%s" % [card_id, field])
			card[field] = metadata[field]
		# Local paths and executable fields are solely compiler output.
		if checking and (card.has("image_path") or card.has("compiled_trainer_effects")):
			stale.append("%s:generated_fields" % card_id)
		card.erase("image_path")
		card.erase("compiled_trainer_effects")
		for block in Array(card.get("attacks", [])) + Array(card.get("abilities", [])):
			if checking and block.has("compiled_effects"):
				stale.append("%s:generated_effects" % card_id)
			block.erase("compiled_effects")
		var image_path := cache.path_join(str(source["image"]))
		if FileAccess.get_sha256(image_path) != str(source["image_sha256"]):
			return "image_sha256_mismatch:%s" % card_id
		var scan := Image.load_from_file(image_path)
		if scan == null or scan.get_size() != Vector2i(300, 419):
			return "image_dimensions_invalid:%s" % card_id
		scan.convert(Image.FORMAT_RGB8)
		var image_bytes := scan.save_webp_to_buffer(false)
		if image_bytes.is_empty():
			return "image_encode_failed:%s" % card_id
		var target := "res://assets/cards/%s.webp" % card_id
		images[target] = image_bytes
		if checking and (not FileAccess.file_exists(target) \
				or FileAccess.get_file_as_bytes(target) != image_bytes):
			stale.append("%s:image" % card_id)
	if not stale.is_empty():
		return "stale_sources:" + ",".join(stale)
	error = Sources.validate_cards(cards, manifest)
	if not error.is_empty():
		return error
	# Prepare and validate the entire batch before replacing authored metadata/art.
	if not checking:
		for path in images:
			if FileAccess.file_exists(path) and FileAccess.get_file_as_bytes(path) == images[path]:
				continue
			var image_file := FileAccess.open(path, FileAccess.WRITE)
			if image_file == null:
				return "image_write_failed:%s" % path
			image_file.store_buffer(images[path])
		for path in documents:
			var serialized := JSON.stringify(documents[path], "  ", true, true) + "\n"
			if FileAccess.get_file_as_string(path).replace("\r\n", "\n") == serialized:
				continue
			var document_file := FileAccess.open(path, FileAccess.WRITE)
			if document_file == null:
				return "authoring_write_failed:%s" % path
			document_file.store_string(serialized)
	print("CARD_SOURCE_%s_OK cards=%d format=lossless_webp revision=%s" % [
		"CHECK" if checking else "IMPORT", cards.size(), str(manifest["source"]["revision"]),
	])
	return ""
