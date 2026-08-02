extends SceneTree


func _initialize() -> void:
	if not ClassDB.class_exists("NativeDeepSearch"):
		push_error("NativeDeepSearch unavailable")
		quit(1)
		return
	var kernel: Variant = ClassDB.instantiate("NativeDeepSearch")
	var row := {
		"schema_version": 4,
		"action_id": "test:1",
		"base_revision": 7,
		"actor": 1,
		"kind": "ATTACH_ENERGY",
		"source": {
			"kind": "card",
			"player": 1,
			"zone": "hand",
			"index": 2,
			"card_id": "energy-fire",
		},
		"target": {
			"kind": "pokemon",
			"player": 1,
			"slot": "active",
			"card_id": "svi-chim",
		},
		"payload": {
			"nested": [true, 3, "fire"],
			"target_slot": "active",
		},
	}
	var action := GameAction.from_dict(row)
	var expected := AIPositionEvaluator.action_signature(action)
	var actual := str(kernel.action_signature_v2(row))
	if actual != expected:
		push_error("signature mismatch expected=%s actual=%s" % [expected, actual])
		quit(1)
		return
	print("NATIVE_ACTION_SIGNATURE_CONTRACT_OK")
	quit(0)
