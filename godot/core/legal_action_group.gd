class_name LegalActionGroup
extends RefCounted

var group_id: String
var base_revision: int
var actor: int
var kind: String
var source: EntityRef
var payload: Dictionary
var targets: Array[EntityRef]


func _init(
	p_group_id: String = "",
	p_base_revision: int = -1,
	p_actor: int = -1,
	p_kind: String = "",
	p_source: EntityRef = null,
	p_payload: Dictionary = {},
	p_targets: Array[EntityRef] = [],
) -> void:
	group_id = p_group_id
	base_revision = p_base_revision
	actor = p_actor
	kind = p_kind
	source = p_source
	payload = p_payload.duplicate(true)
	targets.assign(p_targets)


static func from_action(
	action: GameAction,
	p_group_id: String = "",
) -> LegalActionGroup:
	var group := LegalActionGroup.new(
		p_group_id if not p_group_id.is_empty() else group_id_for_action(action),
		action.base_revision,
		action.actor,
		action.kind,
		action.source,
		action.payload,
		[],
	)
	if action.target != null:
		group.targets.append(action.target)
	return group


static func group_id_for_action(action: GameAction) -> String:
	var signature := "%d|%d|%s|%s|%s" % [
		action.base_revision,
		action.actor,
		action.kind,
		_ref_signature(action.source),
		_payload_signature(action.payload),
	]
	return "group:%08x%08x" % [signature.hash(), signature.reverse().hash()]


static func _ref_signature(ref: EntityRef) -> String:
	if ref == null:
		return "-"
	match ref.kind:
		"card":
			return "card/%d/%s/%d/%s" % [
				ref.player, ref.zone, ref.index, ref.card_id]
		"pokemon":
			return "pokemon/%d/%s/%s" % [ref.player, ref.slot, ref.card_id]
		"slot":
			return "slot/%d/%s" % [ref.player, ref.slot]
		"attachment":
			return "attachment/%d/%s/%s/%d/%s" % [
				ref.player,
				ref.slot,
				ref.attachment_type,
				ref.index,
				ref.card_id,
			]
		_:
			return "invalid/%s" % ref.kind


static func _payload_signature(payload: Dictionary) -> String:
	if payload.is_empty():
		return "-"
	if payload.size() == 1 and payload.has("attack_index"):
		return "attack_index=%d" % int(payload["attack_index"])
	if payload.size() == 1 and payload.has("ability_name"):
		return "ability_name=%s" % str(payload["ability_name"])
	# No current public schema reaches this fallback; keep it deterministic for
	# future registry additions until they receive an explicit fast signature.
	return JSON.stringify(payload)


func add_target(target: EntityRef) -> void:
	if target == null:
		return
	for existing in targets:
		if existing.same_identity(target):
			return
	targets.append(target)


func bind(target: EntityRef = null, action_id: String = "") -> GameAction:
	if targets.is_empty():
		if target != null:
			return null
	else:
		if target == null:
			return null
		var found := false
		for candidate in targets:
			if candidate.same_identity(target):
				found = true
				break
		if not found:
			return null
	return GameAction.create(
		kind, payload, actor, source, target, action_id, base_revision)


func concrete_actions() -> Array[GameAction]:
	var result: Array[GameAction] = []
	if targets.is_empty():
		result.append(bind())
	else:
		for target in targets:
			result.append(bind(target))
	return result


func to_dict() -> Dictionary:
	var target_rows: Array[Dictionary] = []
	for target in targets:
		target_rows.append(target.to_dict())
	return {
		"group_id": group_id,
		"base_revision": base_revision,
		"actor": actor,
		"kind": kind,
		"source": source.to_dict() if source else null,
		"payload": payload.duplicate(true),
		"targets": target_rows,
	}


func immutable_copy() -> LegalActionGroup:
	var copied_targets: Array[EntityRef] = []
	for target in targets:
		copied_targets.append(target.immutable_copy())
	return LegalActionGroup.new(
		group_id,
		base_revision,
		actor,
		kind,
		source.immutable_copy() if source else null,
		payload,
		copied_targets,
	)


static func from_dict(data: Dictionary) -> LegalActionGroup:
	var parsed_targets: Array[EntityRef] = []
	for target_value in data.get("targets", []):
		if target_value is Dictionary:
			parsed_targets.append(EntityRef.from_dict(target_value))
	return LegalActionGroup.new(
		str(data.get("group_id", "")),
		int(data.get("base_revision", -1)),
		int(data.get("actor", -1)),
		str(data.get("kind", "")),
		EntityRef.from_dict(data["source"]) if data.get("source") is Dictionary else null,
		Dictionary(data.get("payload", {})),
		parsed_targets,
	)
