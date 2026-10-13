class_name DeckLibrary
extends CardCatalog

## UI-owned deck repository. Cards/IR and preset definitions remain immutable;
## only this instance's deck index changes. Never send this repository to AI.
signal changed

const FORMAT := "ptcg.decks/1"
const PROFILE := "casual60"
const SHARE_PREFIX := "PTCG1:"
const MAX_SHARE_BYTES := 65536
const MAX_FILE_BYTES := 4194304
static var _default_library: DeckLibrary

var storage_path := "user://decks.json"
var load_message := ""
var _custom: Dictionary = {}
var _validator: Variant

func _init(path: String = "user://decks.json") -> void:
	super(false, false)
	storage_path = path
	load_library()

static func default_library() -> DeckLibrary:
	if _default_library == null:
		_default_library = DeckLibrary.new()
	return _default_library

func is_custom(key: String) -> bool:
	return _custom.has(key)

func custom_keys() -> Array[String]:
	var result: Array[String] = []
	result.assign(_custom.keys())
	result.sort()
	return result

func load_library() -> void:
	_custom = {}
	load_message = ""
	if FileAccess.file_exists(storage_path) or FileAccess.file_exists(storage_path + ".bak"):
		var parsed: Variant = _read_store(storage_path)
		if parsed == null:
			parsed = _read_store(storage_path + ".bak")
			load_message = "卡组文件损坏，已从备份恢复。" if parsed != null else "卡组文件无法读取，原文件已保留。"
		if parsed is Dictionary:
			_custom = parsed
	_refresh_index()

func _read_store(path: String) -> Variant:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > MAX_FILE_BYTES:
		return null
	var parser := JSON.new()
	if parser.parse(file.get_as_text()) != OK: return null
	var value: Variant = parser.data
	if not value is Dictionary or value.get("format") != FORMAT or not value.get("decks") is Array:
		return null
	var loaded: Dictionary = {}
	for entry in value.decks:
		if not entry is Dictionary:
			return null
		var key := str(entry.get("id", ""))
		if not key.begins_with("custom:") or key.length() > 128 or loaded.has(key):
			return null
		var normalized := normalize_definition(entry)
		if not normalized.ok:
			return null
		loaded[key] = normalized.deck
	return loaded

func _refresh_index() -> void:
	decks = CardCatalog.shared().decks.duplicate()
	_expanded_deck_cache = {}
	for key in _custom:
		var definition: Dictionary = _custom[key].duplicate(true)
		definition["key"] = key
		definition["card_count"] = 0
		definition["energy_type"] = "Colorless"
		var types: Dictionary = {}
		for row in definition.cards:
			definition.card_count += int(row.count)
			var card := get_card(str(row.card_id))
			for energy_type in card.get("energy_types", []):
				types[energy_type] = int(types.get(energy_type, 0)) + int(row.count)
		var largest := 0
		for energy_type in types:
			if int(types[energy_type]) > largest:
				largest = int(types[energy_type])
				definition.energy_type = energy_type
		definition["description"] = "自定义卡组"
		decks[key] = definition

static func normalize_definition(value: Variant) -> Dictionary:
	if not value is Dictionary or not value.get("cards") is Array:
		return {"ok": false, "error": "卡表格式无效。"}
	if value.get("profile", PROFILE) != PROFILE or value.cards.size() > 1000:
		return {"ok": false, "error": "不支持的构筑规则或卡表过长。"}
	if not value.get("name", "未命名卡组") is String:
		return {"ok": false, "error": "卡组名称无效。"}
	var counts: Dictionary = {}
	for row in value.cards:
		if not row is Dictionary or not row.get("card_id") is String:
			return {"ok": false, "error": "卡牌记录无效。"}
		var id: String = row.card_id
		var count: Variant = row.get("count")
		if id.is_empty() or id.length() > 128 or not (count is int or count is float):
			return {"ok": false, "error": "卡牌编号或数量无效。"}
		if not is_finite(float(count)) or float(count) != floor(float(count)) or count <= 0 or count > 1000:
			return {"ok": false, "error": "卡牌数量必须为正整数。"}
		counts[id] = int(counts.get(id, 0)) + int(count)
		if counts[id] > 1000:
			return {"ok": false, "error": "单张卡牌数量过大。"}
	var keys: Array = counts.keys()
	keys.sort()
	var rows: Array[Dictionary] = []
	for id in keys:
		rows.append({"card_id": id, "count": counts[id]})
	var deck_name := str(value.get("name", "未命名卡组")).strip_edges().left(80)
	return {"ok": true, "deck": {"name": deck_name if not deck_name.is_empty() else "未命名卡组", "profile": PROFILE, "cards": rows}}

func save_deck(definition: Dictionary, key: String = "") -> Dictionary:
	var normalized := normalize_definition(definition)
	if not normalized.ok:
		return normalized
	if not key.is_empty() and not _custom.has(key):
		return {"ok": false, "error": "只能修改已有的自定义卡组。"}
	if key.is_empty():
		key = "custom:" + Crypto.new().generate_random_bytes(16).hex_encode()
	var candidate := _custom.duplicate(true)
	candidate[key] = normalized.deck
	var error := _write_store(candidate)
	if error != OK:
		return {"ok": false, "error": "保存失败（%s），原卡组已保留。" % error_string(error)}
	_custom = candidate
	_refresh_index()
	changed.emit()
	return {"ok": true, "key": key}

func delete_deck(key: String) -> Dictionary:
	if not _custom.has(key):
		return {"ok": false, "error": "无法删除预设或不存在的卡组。"}
	var candidate := _custom.duplicate(true)
	candidate.erase(key)
	var error := _write_store(candidate)
	if error != OK:
		return {"ok": false, "error": "删除失败，原卡组已保留。"}
	_custom = candidate
	_refresh_index()
	changed.emit()
	return {"ok": true}

func _write_store(candidate: Dictionary) -> Error:
	var records: Array = []
	var keys: Array = candidate.keys()
	keys.sort()
	for key in keys:
		var record: Dictionary = candidate[key].duplicate(true)
		record["id"] = key
		records.append(record)
	var serialized := JSON.stringify({"format": FORMAT, "decks": records}, "\t")
	if serialized.to_utf8_buffer().size() > MAX_FILE_BYTES:
		return ERR_OUT_OF_MEMORY
	var temp := storage_path + ".tmp"
	var file := FileAccess.open(temp, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(serialized)
	file.flush()
	var error := file.get_error()
	file.close()
	if error != OK:
		return error
	if FileAccess.file_exists(storage_path) and _read_store(storage_path) != null:
		error = DirAccess.copy_absolute(storage_path, storage_path + ".bak")
		if error != OK:
			return error
	elif _read_store(storage_path + ".bak") == null:
		# Even the first save must survive corruption of the primary file.
		error = DirAccess.copy_absolute(temp, storage_path + ".bak")
		if error != OK:
			return error
	return DirAccess.rename_absolute(temp, storage_path)

func validate_rows(rows: Array) -> Dictionary:
	if _validator == null and ClassDB.class_exists("NativeRulesSession"):
		_validator = ClassDB.instantiate("NativeRulesSession")
		if not _validator.set_catalog(native_rules_catalog()):
			_validator = null
	if _validator == null or not _validator.has_method("validate_deck"):
		return {"valid": false, "card_count": 0, "errors": [{"code": "native_rules_unavailable"}]}
	return _validator.validate_deck(rows)

func validate_key(key: String) -> Dictionary:
	return validate_rows(Array(get_deck(key).get("cards", [])))

func freeze_deck(key: String) -> Dictionary:
	var deck := get_deck(key)
	if deck.is_empty():
		return {"ok": false, "error": "未知卡组。"}
	var validation := validate_rows(deck.cards)
	if not validation.valid:
		return {"ok": false, "error": validation_text(validation)}
	var normalized := normalize_definition(deck)
	var definition: Dictionary = normalized.deck
	return {"ok": true, "definition": definition, "cards": expand_deck(key), "digest": deck_digest(definition), "public_key": "custom" if is_custom(key) else key}

static func deck_digest(definition: Dictionary) -> String:
	var normalized := normalize_definition(definition)
	if not normalized.ok:
		return ""
	return JSON.stringify({"profile": PROFILE, "cards": normalized.deck.cards}).sha256_text()

func export_code(definition: Dictionary) -> String:
	var normalized := normalize_definition(definition)
	if not normalized.ok:
		return ""
	var data: Dictionary = normalized.deck
	data["version"] = 1
	var code := SHARE_PREFIX + Marshalls.raw_to_base64(JSON.stringify(data).to_utf8_buffer()).replace("+", "-").replace("/", "_").trim_suffix("=").trim_suffix("=")
	return code if code.to_utf8_buffer().size() <= MAX_SHARE_BYTES else ""

func import_code(code: String) -> Dictionary:
	code = code.strip_edges()
	if not code.begins_with(SHARE_PREFIX) or code.to_utf8_buffer().size() > MAX_SHARE_BYTES:
		return {"ok": false, "error": "分享码格式或版本无效。"}
	var encoded := code.substr(SHARE_PREFIX.length())
	if RegEx.create_from_string("^[A-Za-z0-9_-]+$").search(encoded) == null or encoded.length() % 4 == 1:
		return {"ok": false, "error": "分享码已损坏。"}
	encoded = encoded.replace("-", "+").replace("_", "/")
	while encoded.length() % 4 != 0:
		encoded += "="
	var parser := JSON.new()
	if parser.parse(Marshalls.base64_to_raw(encoded).get_string_from_utf8()) != OK:
		return {"ok": false, "error": "分享码已损坏。"}
	var data: Variant = parser.data
	if not data is Dictionary or not WireValue.is_integer(data.get("version")) or data.get("version") != 1:
		return {"ok": false, "error": "无法读取此版本的分享码。"}
	if data.size() != 4 or not data.has_all(["version", "name", "profile", "cards"]) or data.profile != PROFILE:
		return {"ok": false, "error": "分享码缺少必要字段或包含未知字段。"}
	return save_deck(data)

static func validation_text(validation: Dictionary) -> String:
	if validation.get("valid", false):
		return "卡组合法，可以对战"
	var messages: PackedStringArray = []
	for issue in validation.get("errors", []):
		match str(issue.get("code", "")):
			"invalid_deck_size": messages.append("需要 60 张，目前 %d 张" % int(issue.get("count", 0)))
			"missing_basic_pokemon": messages.append("至少需要 1 张基础宝可梦")
			"deck_name_limit", "deck_group_limit": messages.append("%s 最多 %d 张，当前 %d 张" % [issue.get("card_id", ""), int(issue.get("limit", 4)), int(issue.get("count", 0))])
			"unknown_card": messages.append("缺少卡牌：%s" % issue.get("card_id", ""))
			"native_rules_unavailable": messages.append("原生规则服务不可用")
			_: messages.append("卡牌记录或数量无效")
	return "；".join(messages)
