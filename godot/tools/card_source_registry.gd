extends RefCounted
## One pinned Simplified Chinese source for every authored card and local scan.

const PATH := "res://authoring/card_source_manifest.json"
const REPOSITORY := "https://github.com/duanxr/PTCG-CHS-Datasets"
const RAW_ROOT := "https://raw.githubusercontent.com/duanxr/PTCG-CHS-Datasets/"
const METADATA_FIELDS := [
	"artist", "flavor_text", "image_url_large", "image_url_small", "number",
	"rarity", "regulation_mark", "set_id", "set_name",
]


static func validate_manifest(manifest: Dictionary, card_ids: Array) -> String:
	var source: Dictionary = manifest.get("source", {})
	var revision := str(source.get("revision", ""))
	if str(manifest.get("schema", "")) != "ptcg.card_sources/1" \
			or str(source.get("repository", "")) != REPOSITORY \
			or str(source.get("language", "")) != "zh-Hans" \
			or str(source.get("dataset_path", "")) != "ptcg_chs_infos.json" \
			or not _is_digest(revision, 40) \
			or not _is_digest(str(source.get("dataset_sha256", "")), 64):
		return "card_source_manifest_contract_invalid"
	var image_format: Dictionary = manifest.get("image_format", {})
	if str(image_format.get("format", "")) != "webp" \
			or image_format.get("lossless") != true \
			or float(image_format.get("width", 0)) != 300.0 \
			or float(image_format.get("height", 0)) != 419.0:
		return "card_source_image_format_invalid"
	var sources: Dictionary = manifest.get("cards", {})
	if sources.size() != card_ids.size():
		return "card_source_coverage_invalid"
	var image_pattern := RegEx.create_from_string("^img/[0-9]+/[0-9]+\\.png$")
	for card_id in card_ids:
		if not sources.get(card_id) is Dictionary:
			return "card_source_missing:%s" % card_id
		var row: Dictionary = sources[card_id]
		var image := str(row.get("image", ""))
		if int(row.get("source_card_id", 0)) <= 0 \
				or int(row.get("collection_id", 0)) <= 0 \
				or image_pattern.search(image) == null \
				or not image.begins_with("img/%d/" % int(row.get("collection_id", 0))) \
				or not _is_digest(str(row.get("image_sha256", "")), 64):
			return "card_source_entry_invalid:%s" % card_id
	return ""


static func validate_cards(cards: Dictionary, manifest: Dictionary) -> String:
	var error := validate_manifest(manifest, cards.keys())
	if not error.is_empty():
		return error
	for card_id in cards:
		var card: Dictionary = cards[card_id]
		for field in METADATA_FIELDS:
			if not card.get(field) is String:
				return "card_source_metadata_type:%s:%s" % [card_id, field]
		for field in ["set_id", "set_name", "number", "rarity"]:
			if str(card[field]).strip_edges().is_empty():
				return "card_source_metadata_missing:%s:%s" % [card_id, field]
		if str(card["image_url_large"]) != image_url(manifest, card_id) \
				or not str(card["image_url_small"]).is_empty():
			return "card_source_image_url_mismatch:%s" % card_id
		if card.has("image_path") or card.has("compiled_trainer_effects"):
			return "card_source_contains_generated_fields:%s" % card_id
		for block in Array(card.get("attacks", [])) + Array(card.get("abilities", [])):
			if Dictionary(block).has("compiled_effects"):
				return "card_source_contains_generated_fields:%s" % card_id
	return ""


static func image_url(manifest: Dictionary, card_id: String) -> String:
	return RAW_ROOT + str(manifest["source"]["revision"]) + "/" \
		+ str(manifest["cards"][card_id]["image"])


static func metadata(row: Dictionary, collection: Dictionary, url: String) -> Dictionary:
	var details: Dictionary = row["details"]
	return {
		"artist": ", ".join(details.get("illustratorName", [])),
		"flavor_text": str(details.get("pokedexText", "")),
		"image_url_large": url,
		"image_url_small": "",
		"number": str(details.get("collectionNumber", "")),
		"rarity": str(details.get("rarityText", "")),
		"regulation_mark": str(details.get("regulationMarkText", "")),
		"set_id": str(details.get("commodityCode", "")),
		"set_name": str(collection.get("name", "")).strip_edges(),
	}


static func read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return _normalize_numbers(JSON.parse_string(FileAccess.get_file_as_string(path)))


static func _is_digest(value: String, length: int) -> bool:
	return value.length() == length and value.is_valid_hex_number(false) \
		and value == value.to_lower()


static func _normalize_numbers(value: Variant) -> Variant:
	if value is float and is_finite(value) and floor(value) == value:
		return int(value)
	if value is Dictionary:
		for key in value:
			value[key] = _normalize_numbers(value[key])
	elif value is Array:
		for index in range(value.size()):
			value[index] = _normalize_numbers(value[index])
	return value
