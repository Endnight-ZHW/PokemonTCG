class_name BattleTableRenderer
extends RefCounted

## Owns the synchronous render pass for BattleTable. Layout calculations remain
## in BattleTableLayout; this component only coordinates the concrete views.

var _table_ref: WeakRef


func configure(table: BattleTable) -> void:
	_table_ref = weakref(table) if table != null else null


func render_current_view() -> void:
	var table := _table()
	if table == null or not table._initialized or table.state_ref == null:
		return
	table._refresh_header()
	table._refresh_field()
	table._refresh_opponent_hand()
	table._refresh_hand()
	table._refresh_actions()
	table._refresh_log()
	table._refresh_target_hints()
	table._refresh_ai_thinking_indicator()


func _table() -> BattleTable:
	if _table_ref == null:
		return null
	var value: Variant = _table_ref.get_ref()
	return value as BattleTable if is_instance_valid(value) else null
