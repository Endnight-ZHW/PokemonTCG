extends SceneTree

const CARDS_PATH := "res://data/cards.json"
const DECKS_PATH := "res://data/decks.json"
const CARD_IR_PATH := "res://data/card_ir_v3.json"

var failures: Array[String] = []


func _initialize() -> void:
	_run()
	if failures.is_empty():
		print("NATIVE_RULES_SESSION_CONTRACT_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _run() -> void:
	if not ClassDB.class_exists("NativeRulesSession"):
		failures.append("NativeRulesSession GDExtension class is unavailable")
		return
	var cards := _read_json(CARDS_PATH)
	var card_ir := _read_json(CARD_IR_PATH)
	var deck_specs := _read_json(DECKS_PATH)
	var contract_session: Variant = ClassDB.instantiate("NativeRulesSession")
	contract_session.set_catalog(cards)
	var orthworm := {
		"card_id": "svm-orthworm",
		"damage_counters": 5,
		"energy_card_ids": ["sv1-ener-8", "sv1-ener-8", "sv1-ener-8"],
		"attached_tool_id": "",
		"evolution_stack_ids": [],
		"status_conditions": [],
		"modifiers": [],
	}
	_check(
		int(contract_session.pokemon_max_hp(orthworm)) == 230
		and int(contract_session.pokemon_current_hp(orthworm)) == 180,
		"native conditional HP projection ignored Nutritional Iron",
	)
	var core_contract: Dictionary = contract_session.get_contract()
	_check(
		int(core_contract.get("implemented_op_count", 0)) == 80
		and int(core_contract.get("required_op_count", 0)) == 80
		and int(core_contract.get("native_abi_version", 0)) == 2,
		"Native ABI 2 rules/VM contract is incomplete",
	)
	if ClassDB.class_exists("NativeDeepSearch"):
		var search_kernel: Variant = ClassDB.instantiate("NativeDeepSearch")
		var search_contract: Dictionary = search_kernel.get_contract()
		_check(
			int(search_contract.get("native_abi_version", 0)) == 2
			and int(search_contract.get("rules_session_abi_version", 0)) == 2,
			"Native ABI 2 search contract is incomplete",
		)
	var decks := [
		_expand_deck(Dictionary(deck_specs.get("fire", {}))),
		_expand_deck(Dictionary(deck_specs.get("water", {}))),
	]
	if decks[0].size() != 60 or decks[1].size() != 60:
		failures.append("release deck expansion did not produce two 60-card decks")
		return

	var first: Variant = ClassDB.instantiate("NativeRulesSession")
	var second: Variant = ClassDB.instantiate("NativeRulesSession")
	var config := {
		"forced_first": 0,
		"public_deck_keys": ["fire", "water"],
	}
	var created: Dictionary = first.create(cards, decks, config, 12345)
	var repeated: Dictionary = second.create(cards, decks, config, 12345)
	_check(bool(created.get("success", false)), "native session create failed")
	_check(bool(repeated.get("success", false)), "repeat session create failed")
	if not bool(created.get("success", false)):
		return
	var contract: Dictionary = first.get_contract()
	_check(
		int(contract.get("native_abi_version", 0)) == 2
		and int(contract.get("protocol_version", 0)) == 6
		and int(contract.get("action_schema_version", 0)) == 4
		and int(contract.get("choice_view_schema_version", 0)) == 2
		and int(contract.get("snapshot_schema_version", 0)) == 3
		and int(contract.get("vm_ir_version", 0)) == 3
		and int(contract.get("card_count", 0)) == cards.size()
		and Array(contract.get("framework_dependencies", ["unexpected"])).is_empty(),
		"native session ABI/schema contract mismatch",
	)
	_check(
		created.get("state") == repeated.get("state")
		and first.rng_state() == second.rng_state()
		and first.state_hash() == second.state_hash()
		and first.journal() == second.journal(),
		"same catalog/decks/seed did not create identical native sessions",
	)
	var ir_session: Variant = ClassDB.instantiate("NativeRulesSession")
	var ir_created: Dictionary = ir_session.create(
		{"cards": cards, "card_ir": card_ir}, decks, config, 12345)
	_check(
		bool(ir_created.get("success", false))
		and str(ir_session.get_contract().get(
			"card_ir_content_fingerprint", ""))
			== str(card_ir.get("content_fingerprint", ""))
		and str(ir_session.get_contract().get(
			"card_ir_contract_fingerprint", ""))
			== str(card_ir.get("contract_fingerprint", ""))
		and str(ir_session.journal().get("vm_descriptor_digest", ""))
			== str(card_ir.get("descriptor_digest", ""))
		and str(ir_session.journal().get("content_fingerprint", ""))
			== str(card_ir.get("content_fingerprint", ""))
		and str(ir_session.journal().get("contract_fingerprint", ""))
			== str(card_ir.get("contract_fingerprint", "")),
		"Card IR v3 envelope/fingerprint was not adopted by ptcg_core: %s" % [
			str(ir_created),
		],
	)

	var query: Dictionary = first.legal_actions(0)
	var groups: Array = query.get("groups", [])
	_check(
		bool(query.get("success", false))
		and int(query.get("schema_version", 0)) == 1
		and int(query.get("base_revision", -1)) == 0
		and not groups.is_empty(),
		"native LegalActionQueryResult is invalid",
	)
	if groups.is_empty():
		return
	var group: Dictionary = groups[0]
	var targets: Array = group.get("targets", [])
	var action := {
		"schema_version": 4,
		"action_id": "godot:setup:1",
		"base_revision": int(query.get("base_revision", -1)),
		"actor": int(group.get("actor", -1)),
		"kind": str(group.get("kind", "")),
		"source": group.get("source"),
		"target": targets[0] if not targets.is_empty() else null,
		"payload": Dictionary(group.get("payload", {})),
	}
	var applied: Dictionary = first.apply_action(action)
	_check(
		bool(applied.get("success", false)) and first.revision() == 1,
		"native session did not apply an engine-issued Action v4",
	)
	if str(action.get("kind", "")) == "PLAY_BASIC":
		var motion_events: Array = applied.get("events", [])
		var played_event: Dictionary = (
			Dictionary(motion_events[0]) if not motion_events.is_empty() else {}
		)
		var played_data: Dictionary = played_event.get("data", {})
		_check(
			str(played_event.get("event_type", "")) == "pokemon_played"
			and not str(played_event.get(
				"card_id", played_data.get("card_id", ""))).is_empty()
			and str(played_event.get("visibility", "")) == "owner"
			and str(Dictionary(played_event.get("source", {})).get(
				"zone", "")) == "hand"
			and not str(Dictionary(played_event.get("target", {})).get(
				"slot", "")).is_empty(),
			"native motion event lost card identity, endpoint, or setup privacy",
		)
	var stable_hash: String = first.state_hash()
	var stable_rng: int = first.rng_state()
	var stable_journal: Dictionary = first.journal()
	var duplicate: Dictionary = first.apply_action(action)
	_check(
		not bool(duplicate.get("success", true))
		and str(duplicate.get("error_code", "")) == "duplicate_action"
		and first.state_hash() == stable_hash
		and first.rng_state() == stable_rng
		and first.journal() == stable_journal,
		"duplicate Action v4 did not fail closed without mutation",
	)

	var owner_view: Dictionary = first.view_for(0)
	var opponent_view: Dictionary = first.view_for(1)
	var setup_log_rows: Array[String] = []
	for entry in Array(opponent_view.get("action_log", [])):
		setup_log_rows.append(str(entry))
	var setup_log := "\n".join(setup_log_rows)
	var hidden_card_id := str(Dictionary(action.get("source", {})).get(
		"card_id", ""))
	var hidden_card_name := CardCatalog.shared().card_name(hidden_card_id)
	_check(
		Dictionary(owner_view.get("your", {})).has("hand")
		and not Dictionary(owner_view.get("opponent", {})).has("hand")
		and Dictionary(opponent_view.get("opponent", {})).get("active")
			== {"hidden": true}
		and not Dictionary(owner_view.get("your", {})).has("deck")
		and not Dictionary(owner_view.get("your", {})).has("prizes")
		and "暗置宝可梦" in setup_log
		and (hidden_card_id.is_empty() or hidden_card_id not in setup_log)
		and (hidden_card_name.is_empty() or hidden_card_name not in setup_log),
		"native player view exposed a hidden zone or setup identity",
	)

	var snapshot: Dictionary = first.snapshot()
	var forked: Variant = first.fork()
	_check(
		int(snapshot.get("snapshot_version", 0)) == 3
		and forked.snapshot() == snapshot
		and forked.state_hash() == first.state_hash()
		and forked.rng_state() == first.rng_state(),
		"native Snapshot 3 fork is not deterministic",
	)
	var restored: Variant = ClassDB.instantiate("NativeRulesSession")
	_check(restored.set_catalog(cards), "native restore catalog setup failed")
	_check(
		restored.restore(snapshot, first.rng_state())
		and restored.snapshot() == snapshot
		and restored.state_hash() == first.state_hash(),
		"native Snapshot 3 restore failed",
	)
	var journal: Dictionary = first.journal()
	var entries: Array = journal.get("entries", [])
	_check(
		str(journal.get("schema", "")) == "ptcg_match_journal/1"
		and int(journal.get("format_version", 0)) == 1
		and int(journal.get("native_abi_version", 0)) == 2
		and str(journal.get("hash_algorithm", ""))
			== "fnv1a64-canonical-json"
		and entries.size() == 2
		and str(Dictionary(entries[-1]).get("state_hash", ""))
			== first.state_hash(),
		"MatchJournal v1 contract mismatch",
	)
	_check_turn_order_choice_privacy(cards, decks)
	_check_authoritative_session_adapter()
	_check_main_native_route()


func _check_turn_order_choice_privacy(cards: Dictionary, decks: Array) -> void:
	var session: Variant = ClassDB.instantiate("NativeRulesSession")
	var created: Dictionary = session.create(cards, decks, {}, 8080)
	_check(bool(created.get("success", false)), "turn-order session create failed")
	var pending_value: Variant = created.get("pending")
	_check(pending_value is Dictionary, "turn-order ChoiceView v2 is missing")
	if not pending_value is Dictionary:
		return
	var pending := Dictionary(pending_value)
	var owner := int(pending.get("player", -1))
	_check(
		int(pending.get("schema_version", 0)) == 2
		and session.pending_choice(owner) == pending
		and session.pending_choice(1 - owner) == null,
		"ChoiceView v2 crossed its owner boundary",
	)
	var before_hash: String = session.state_hash()
	var before_rng: int = session.rng_state()
	var rejected: Dictionary = session.apply_choice({
		"request_id": str(pending.get("request_id", "")),
		"option_ids": [],
		"cancelled": true,
	})
	_check(
		not bool(rejected.get("success", true))
		and session.state_hash() == before_hash
		and session.rng_state() == before_rng,
		"rejected setup choice did not roll back state and RNG",
	)


func _check_authoritative_session_adapter() -> void:
	var session := AuthoritativeSession.new("native-adapter-contract")
	_check(
		session.set_native_rules_enabled(true),
		"AuthoritativeSession could not enable Native ABI 2",
	)
	var started := session.start_match("fire", "water", 12345, 0)
	_check(
		started.success
		and session.state != null
		and session.state.revision == 0,
		"AuthoritativeSession native start failed: %s" % [str(started.error_code)],
	)
	if not started.success:
		return
	var view: Dictionary = session.view_for(0)
	var groups: Array = view.get("legal_action_groups", [])
	_check(not groups.is_empty(), "native authoritative view has no legal groups")
	if groups.is_empty():
		return
	var group := Dictionary(groups[0])
	var targets: Array = group.get("targets", [])
	var action := {
		"schema_version": 4,
		"action_id": "authoritative:native:1",
		"base_revision": int(group.get("base_revision", -1)),
		"actor": int(group.get("actor", -1)),
		"kind": str(group.get("kind", "")),
		"source": group.get("source"),
		"target": targets[0] if not targets.is_empty() else null,
		"payload": Dictionary(group.get("payload", {})),
	}
	var applied := session.submit_action(0, action)
	_check(
		applied.success and session.state.revision == 1,
		"AuthoritativeSession did not route Action v4 to native rules",
	)
	var surrendered := session.surrender(0)
	_check(
		surrendered.success
		and surrendered.terminal
		and session.state.winner == 1
		and session.state.result_reason == "surrender"
		and session.match_journal().get("entries", []).size() == 3,
		"native authoritative surrender/journal contract failed",
	)


func _check_main_native_route() -> void:
	var packed := load("res://scenes/main/main.tscn") as PackedScene
	_check(packed != null, "Main native-route scene could not be loaded")
	if packed == null:
		return
	var main: Control = packed.instantiate()
	root.add_child(main)
	main.call("initialize_ui")
	var active_ref := {
		"kind": "pokemon",
		"player": 0,
		"slot": "active",
		"card_id": "sv2-tatsu",
	}
	var bench_ref := {
		"kind": "pokemon",
		"player": 0,
		"slot": "bench_0",
		"card_id": "sv1-114",
	}
	var distribution_options: Array[Dictionary] = [
		{
			"option_id": "energy:0:sv1-ener-3->pokemon:0:active:sv2-tatsu",
			"label": "水能量 → 战斗场",
			"ref": active_ref,
		},
		{
			"option_id": "energy:1:sv1-ener-3->pokemon:0:active:sv2-tatsu",
			"label": "水能量 → 战斗场",
			"ref": active_ref,
		},
		{
			"option_id": "energy:1:sv1-ener-3->pokemon:0:bench_0:sv1-114",
			"label": "水能量 → 备战区",
			"ref": bench_ref,
		},
	]
	var same_target_choice := ChoiceView.new(
		"ui:energy:same-target",
		0,
		"distribute_energy",
		0,
		"",
		distribution_options,
		0,
		2,
		false,
		true,
		{"same_target": true, "max_per_target": 2},
	)
	var distribution_card_id := str(main.call(
		"_choice_option_card_id",
		distribution_options[0],
	))
	var distribution_caption := str(main.call(
		"_choice_option_caption",
		distribution_options[0],
	))
	_check(
		distribution_card_id == "sv1-ener-3"
		and "战斗" in distribution_caption,
		"energy distribution UI did not identify both source Energy and target: "
		+ "card=%s caption=%s" % [
			distribution_card_id,
			distribution_caption,
		],
	)
	var selected_energy: Array[String] = [str(
		distribution_options[0]["option_id"])]
	main.set("selected_choice_ids", selected_energy)
	_check(
		str(main.call(
			"_choice_addition_blocked_reason",
			same_target_choice,
			distribution_options[1]["option_id"],
		)).is_empty(),
		"energy UI blocked a second physical Energy for the same target",
	)
	_check(
		not str(main.call(
			"_choice_addition_blocked_reason",
			same_target_choice,
			distribution_options[2]["option_id"],
		)).is_empty(),
		"energy UI allowed a different target under same_target",
	)
	var per_target_choice := ChoiceView.new(
		"ui:energy:per-target",
		0,
		"distribute_energy",
		0,
		"",
		distribution_options,
		0,
		2,
		false,
		true,
		{"same_target": false, "max_per_target": 1},
	)
	_check(
		not str(main.call(
			"_choice_addition_blocked_reason",
			per_target_choice,
			distribution_options[1]["option_id"],
		)).is_empty(),
		"energy UI bypassed max_per_target for distinct Energy options",
	)
	var no_selected_energy: Array[String] = []
	main.set("selected_choice_ids", no_selected_energy)
	var started := bool(main.call(
		"start_local_match_for_test", "fire", "water", 556677, 0, false, false))
	_check(
		started
		and main.get("state") != null
		and int(main.get("state").revision) == 0,
		"local/Challenge/Deep authoritative route did not start on RulesSession",
	)
	if started:
		var actor := int(main.get("state").setup_actor_idx)
		var query: LegalActionQueryResult = main.call(
			"_rules_legal_actions", actor)
		var actions := query.concrete_actions() if query != null else []
		_check(not actions.is_empty(), "Main native route returned no setup action")
		if not actions.is_empty():
			var action: GameAction = actions[0]
			action.action_id = "main:native:setup:1"
			var step: StepResult = main.call("_rules_apply_action", action)
			_check(
				step.success
				and int(main.get("state").revision) == 1
				and Array(Dictionary(main.call("match_journal")).get(
					"entries", [])).size() == 2,
				"Main did not commit a local Action v4 through RulesSession",
			)
	main.free()


func _expand_deck(spec: Dictionary) -> Array:
	var result: Array = []
	for row_value in spec.get("cards", []):
		var row := Dictionary(row_value)
		for _index in range(int(row.get("count", 0))):
			result.append(str(row.get("card_id", "")))
	return result


func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		failures.append("cannot open JSON fixture: %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		failures.append("invalid JSON fixture: %s" % path)
		return {}
	return Dictionary(parsed)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
