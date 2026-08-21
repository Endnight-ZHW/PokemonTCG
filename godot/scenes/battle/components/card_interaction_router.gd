class_name CardInteractionRouter
extends RefCounted

## Builds the card-first interaction index used by the battle table.
##
## Source keys deliberately match BattleTable's selection keys:
##   hand:<index>
##   pokemon:<player>:<slot>
##   zone:<player>:<zone>
##   stadium
## Target keys use pokemon:<player>:<slot> or stadium.

const SYSTEM_ACTIONS := {
	"END_TURN": true,
	"SETUP_DONE": true,
}

const CARD_ACTIONS := {
	"PLAY_BASIC": true,
	"EVOLVE": true,
	"ATTACH_ENERGY": true,
	"PLAY_TRAINER": true,
	"USE_ABILITY": true,
	"USE_STADIUM": true,
	"RETREAT": true,
	"DECLARE_ATTACK": true,
	"PROMOTE": true,
}

var selected_source_key := ""

var _action_rows: Array[Dictionary] = []
var _rows_by_source: Dictionary = {}
var _groups_by_source: Dictionary = {}
var _unreachable_rows: Array[Dictionary] = []
var _system_rows: Dictionary = {}


func rebuild(action_rows: Array[Dictionary], selected_key := "") -> void:
	_action_rows = action_rows.duplicate()
	selected_source_key = selected_key
	_rows_by_source.clear()
	_groups_by_source.clear()
	_unreachable_rows.clear()
	_system_rows.clear()

	for input_row in _action_rows:
		var row := _normalized_row(input_row)
		var action: GameAction = row.get("action") as GameAction
		if action == null:
			_unreachable_rows.append(row)
			continue
		if is_system_action(action):
			_system_rows[action.kind] = row
			continue
		if not is_supported_card_action(action):
			_unreachable_rows.append(row)
			continue
		var source_key := source_key_for_action(action, row)
		if source_key.is_empty():
			_unreachable_rows.append(row)
			continue
		if not _rows_by_source.has(source_key):
			_rows_by_source[source_key] = []
		(_rows_by_source[source_key] as Array).append(row)

	_build_groups()


## Alias kept for callers that describe this operation as configuration.
func configure(action_rows: Array[Dictionary], selected_key := "") -> void:
	rebuild(action_rows, selected_key)


func set_selected_source(selected_key: String) -> void:
	selected_source_key = selected_key


func rows() -> Array[Dictionary]:
	return _action_rows.duplicate()


func source_keys() -> Array[String]:
	var result: Array[String] = []
	for value in _rows_by_source.keys():
		result.append(str(value))
	return result


func has_source(source_key: String) -> bool:
	return _rows_by_source.has(source_key)


func rows_for_source(source_key: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for value in _rows_by_source.get(source_key, []):
		result.append(value as Dictionary)
	return result


func actions_for_source(source_key: String) -> Array[GameAction]:
	var result: Array[GameAction] = []
	for row in rows_for_source(source_key):
		var action: GameAction = row.get("action") as GameAction
		if action:
			result.append(action)
	return result


func rows_for_selected_source() -> Array[Dictionary]:
	return rows_for_source(selected_source_key)


func actions_for_selected_source() -> Array[GameAction]:
	return actions_for_source(selected_source_key)


## Returns UI-ready groups. Actions that differ only by legal target share a group;
## attacks and abilities remain distinct buttons.
func action_groups_for_source(source_key: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for value in _groups_by_source.get(source_key, []):
		result.append((value as Dictionary).duplicate())
	return result


func action_groups_for_selected_source() -> Array[Dictionary]:
	return action_groups_for_source(selected_source_key)


func direct_rows_for_source(source_key: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for row in rows_for_source(source_key):
		var action: GameAction = row.get("action") as GameAction
		if action and target_key_for_action(action, row).is_empty():
			result.append(row)
	return result


func targeted_rows_for_source(source_key: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for row in rows_for_source(source_key):
		var action: GameAction = row.get("action") as GameAction
		if action and not target_key_for_action(action, row).is_empty():
			result.append(row)
	return result


func target_keys_for_source(source_key: String) -> Array[String]:
	var result: Array[String] = []
	var seen: Dictionary = {}
	for row in rows_for_source(source_key):
		var action: GameAction = row.get("action") as GameAction
		if action == null:
			continue
		var target_keys := target_keys_for_action(action, row)
		for target_key in target_keys:
			if not target_key.is_empty() and not seen.has(target_key):
				seen[target_key] = true
				result.append(target_key)
	return result


func target_keys_for_selected_source() -> Array[String]:
	return target_keys_for_source(selected_source_key)


func is_target_legal(source_key: String, target_key: String) -> bool:
	return not matching_actions(source_key, target_key).is_empty()


func matching_rows(source_key: String, target_key: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for row in rows_for_source(source_key):
		var action: GameAction = row.get("action") as GameAction
		if action and target_key in target_keys_for_action(action, row):
			result.append(row)
	return result


func matching_actions(source_key: String, target_key: String) -> Array[GameAction]:
	var result: Array[GameAction] = []
	for row in matching_rows(source_key, target_key):
		var action: GameAction = row.get("action") as GameAction
		if action:
			result.append(action)
	return result


func matching_drag_rows(
	hand_index: int,
	target_player: int,
	target_slot: String,
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var source_key := hand_key(hand_index)
	var requested_target_key := target_key(target_player, target_slot)
	for row in rows_for_source(source_key):
		var action := row.get("action") as GameAction
		if action == null:
			continue
		if (
			requested_target_key in target_keys_for_action(action, row)
			or requested_target_key in drag_target_keys_for_action(action, row)
		):
			result.append(row)
	return result


func matching_drag_actions(
	hand_index: int,
	target_player: int,
	target_slot: String,
) -> Array[GameAction]:
	var result: Array[GameAction] = []
	for row in matching_drag_rows(hand_index, target_player, target_slot):
		var action := row.get("action") as GameAction
		if action:
			result.append(action)
	return result


func is_drop_legal(
	hand_index: int,
	target_player: int,
	target_slot: String,
) -> bool:
	return not matching_drag_actions(hand_index, target_player, target_slot).is_empty()


func system_row(action_name: String) -> Dictionary:
	return (_system_rows.get(action_name, {}) as Dictionary).duplicate()


func system_action(action_name: String) -> GameAction:
	return system_row(action_name).get("action") as GameAction


## Structural reachability: every non-system action must resolve to a card source.
func unreachable_rows() -> Array[Dictionary]:
	return _unreachable_rows.duplicate()


func unreachable_actions() -> Array[GameAction]:
	var result: Array[GameAction] = []
	for row in _unreachable_rows:
		var action: GameAction = row.get("action") as GameAction
		if action:
			result.append(action)
	return result


func all_card_actions_reachable() -> bool:
	return _unreachable_rows.is_empty()


## UI reachability additionally checks that each indexed source is currently
## represented by a visible card/zone control.
func unreachable_rows_for_sources(visible_source_keys: Array[String]) -> Array[Dictionary]:
	var visible: Dictionary = {}
	for source_key in visible_source_keys:
		visible[source_key] = true
	var result := unreachable_rows()
	for source_key_value in _rows_by_source.keys():
		var source_key := str(source_key_value)
		if visible.has(source_key):
			continue
		for row in rows_for_source(source_key):
			result.append(row)
	return result


func all_card_actions_reachable_from(visible_source_keys: Array[String]) -> bool:
	return unreachable_rows_for_sources(visible_source_keys).is_empty()


static func is_system_action(action: GameAction) -> bool:
	return action != null and SYSTEM_ACTIONS.has(action.kind)


static func is_supported_card_action(action: GameAction) -> bool:
	return action != null and CARD_ACTIONS.has(action.kind)


static func hand_key(hand_index: int) -> String:
	return "hand:%d" % hand_index


static func pokemon_key(player: int, slot: String) -> String:
	return "pokemon:%d:%s" % [player, slot]


static func zone_key(player: int, zone: String) -> String:
	if zone == "stadium":
		return "stadium"
	if zone.is_empty() or player not in [0, 1]:
		return ""
	return "zone:%d:%s" % [player, zone]


static func target_key(player: int, slot: String) -> String:
	if slot == "stadium":
		return "stadium"
	return pokemon_key(player, slot)


static func source_key_for_action(action: GameAction, row: Dictionary = {}) -> String:
	if action == null or is_system_action(action):
		return ""
	var explicit_source := str(row.get("source_key", ""))
	if not explicit_source.is_empty():
		return explicit_source

	var hand_index := action.hand_index()
	if hand_index < 0 and action.source and action.source.zone == "hand":
		hand_index = action.source.index
	if hand_index >= 0:
		return hand_key(hand_index)

	match action.kind:
		"RETREAT", "DECLARE_ATTACK":
			return pokemon_key(action.actor, "active")
		"PROMOTE":
			var bench_slot := _bench_slot(action)
			return pokemon_key(action.actor, bench_slot) if not bench_slot.is_empty() else ""
		"USE_STADIUM":
			return "stadium"

	if action.source:
		var source_key := _entity_key(action.source)
		if not source_key.is_empty():
			return source_key
	var slot := str(action.primary_slot())
	if not slot.is_empty():
		return pokemon_key(action.actor, slot)
	return ""


static func target_key_for_action(action: GameAction, row: Dictionary = {}) -> String:
	var keys := target_keys_for_action(action, row)
	return keys[0] if not keys.is_empty() else ""


static func drag_target_keys_for_action(
	_action: GameAction,
	row: Dictionary = {},
) -> Array[String]:
	var result: Array[String] = []
	for value in row.get("drag_target_keys", []):
		var key := str(value)
		if not key.is_empty() and key not in result:
			result.append(key)
	return result


static func target_keys_for_action(
	action: GameAction,
	row: Dictionary = {},
) -> Array[String]:
	var result: Array[String] = []
	if action == null:
		return result
	var explicit_keys = row.get("target_keys", [])
	if explicit_keys is Array:
		for value in explicit_keys:
			var explicit_key := str(value)
			if not explicit_key.is_empty() and explicit_key not in result:
				result.append(explicit_key)
	var explicit_key := str(row.get("target_key", ""))
	if not explicit_key.is_empty() and explicit_key not in result:
		result.append(explicit_key)
	if not result.is_empty():
		return result

	# Attacks, abilities and promotions execute from their source card. Any
	# EntityRef target on those rows is informational or resolved by ChoiceView.
	if action.kind in ["DECLARE_ATTACK", "USE_ABILITY", "USE_STADIUM", "PROMOTE"]:
		return result

	var slot := ""
	match action.kind:
		"PLAY_BASIC":
			slot = str(action.target_slot())
		"EVOLVE":
			slot = str(action.primary_slot())
		"ATTACH_ENERGY", "PLAY_TRAINER":
			slot = str(action.target_slot())
		"RETREAT":
			slot = _bench_slot(action)
	if slot.is_empty() and action.target:
		slot = action.target.slot
	if slot.is_empty():
		return result
	var player := action.actor
	if action.target and action.target.player >= 0:
		player = action.target.player
	result.append(target_key(player, slot))
	return result


static func _entity_key(entity: EntityRef) -> String:
	if entity == null:
		return ""
	if entity.kind == "stadium" or entity.zone == "stadium":
		return "stadium"
	if entity.zone == "hand" and entity.index >= 0:
		return hand_key(entity.index)
	if not entity.slot.is_empty():
		return pokemon_key(entity.player, entity.slot)
	if not entity.zone.is_empty():
		return zone_key(entity.player, entity.zone)
	return ""


static func _bench_slot(action: GameAction) -> String:
	if action == null:
		return ""
	if action.target and action.target.slot.begins_with("bench_"):
		return action.target.slot
	var bench_index := action.bench_index()
	return "bench_%d" % bench_index if bench_index >= 0 else ""


func _normalized_row(input_row: Dictionary) -> Dictionary:
	var row := input_row.duplicate()
	var action_value = row.get("action")
	if action_value is Dictionary:
		row["action"] = GameAction.from_dict(action_value)
	return row


func _build_groups() -> void:
	for source_key_value in _rows_by_source.keys():
		var source_key := str(source_key_value)
		var groups: Array[Dictionary] = []
		var group_indices: Dictionary = {}
		for row in rows_for_source(source_key):
			var action: GameAction = row.get("action") as GameAction
			if action == null:
				continue
			var group_key := _group_key(action, row)
			if not group_indices.has(group_key):
				var group := {
					"key": group_key,
					"action_type": action.kind,
					"label": str(row.get("label", action.kind)),
					"hint": str(row.get("hint", "")),
					"icon": row.get("icon"),
					"rows": [],
					"actions": [],
					"target_keys": [],
					"requires_target": false,
				}
				group_indices[group_key] = groups.size()
				groups.append(group)
			var group_index := int(group_indices[group_key])
			var current: Dictionary = groups[group_index]
			(current["rows"] as Array).append(row)
			(current["actions"] as Array).append(action)
			for target_value in target_keys_for_action(action, row):
				var group_target_keys: Array = current["target_keys"]
				if target_value not in group_target_keys:
					group_target_keys.append(target_value)
			current["requires_target"] = not (current["target_keys"] as Array).is_empty()
			groups[group_index] = current
		_groups_by_source[source_key] = groups


func _group_key(action: GameAction, row: Dictionary) -> String:
	var explicit_key := str(row.get("group_key", ""))
	if not explicit_key.is_empty():
		return explicit_key
	match action.kind:
		"DECLARE_ATTACK":
			return "%s:%d" % [action.kind, action.attack_index()]
		"USE_ABILITY":
			return "%s:%s" % [action.kind, str(action.ability_name())]
		"PLAY_TRAINER":
			return "%s:%s" % [
				action.kind,
				"targeted" if not target_keys_for_action(action, row).is_empty() else "direct",
			]
		_:
			return action.kind
