class_name BoardAnchorResolver
extends RefCounted

var _table_ref: WeakRef


func configure(table: BattleTable) -> void:
	_table_ref = weakref(table) if table != null else null


func resolve(endpoint: Dictionary) -> Vector2:
	var table := _table()
	if table == null:
		return Vector2.ZERO
	return table._resolve_endpoint_center_direct(endpoint)


func control_center(control: Control) -> Vector2:
	var table := _table()
	if table == null or control == null or not is_instance_valid(control):
		return Vector2.ZERO
	if control is CardView:
		return table._effects_local((control as CardView).global_center())
	return table._effects_local(control.get_global_rect().get_center())


func _table() -> BattleTable:
	if _table_ref == null:
		return null
	var value: Variant = _table_ref.get_ref()
	return value as BattleTable if is_instance_valid(value) else null
