class_name UIWorkbench
extends Control

signal presentation_checkpoint_ready(percent: int, kind: String)

const TITLE_SCENE := preload("res://scenes/title/title_page.tscn")
const DECK_SCENE := preload("res://scenes/decks/deck_select_page.tscn")
const NETWORK_SCENE := preload("res://scenes/network/network_lobby_page.tscn")
const BATTLE_SCENE := preload("res://scenes/battle/components/battle_table.tscn")
const VICTORY_SCENE := preload("res://scenes/end/victory_screen.tscn")
const SETTINGS_SCENE := preload("res://ui/dialogs/settings_panel.tscn")
const CHOICE_SCENE := preload("res://ui/dialogs/choice_panel.tscn")
const HELP_PANEL_SCENE := preload("res://ui/panels/help_panel.tscn")
const CARD_INSPECTOR_PANEL_SCENE := preload("res://ui/panels/card_inspector_panel.tscn")
const ZONE_INSPECTOR_PANEL_SCENE := preload("res://ui/panels/zone_inspector_panel.tscn")
const DECK_DETAIL_PANEL_SCENE := preload("res://ui/panels/deck_detail_panel.tscn")
const FRONTEND_THEME := preload("res://ui/frontend/front_end_theme.tres")

var catalog := CardCatalog.new()
var rules_adapter: NativeRulesSessionAdapter
var current_battle: BattleTable
var sample_state: GameState
var event_sequence := 0
var current_presentation_kind := "draw"
var presentation_checkpoint_percent := -1
var presentation_before_view: BattleViewModel
var presentation_after_view: BattleViewModel
var presentation_request: BattleTransitionRequest
var _checkpoint_generation := 0

@onready var preview_host: Control = %PreviewHost
@onready var preview_caption: Label = %PreviewCaption
@onready var checkpoint_status: Label = %CheckpointStatus


func _ready() -> void:
	_resolve_nodes()
	_bind_toolbar()
	show_preview("battle")


func show_preview(kind: String) -> void:
	_resolve_nodes()
	_clear_preview()
	match kind:
		"title":
			_show_title()
		"decks":
			_show_decks()
		"network":
			_show_network()
		"settings":
			_show_settings()
		"choice":
			_show_choice()
		"energy_choice":
			_show_energy_choice()
		"ai_thinking":
			_show_ai_thinking()
		"help":
			_show_help()
		"inspector":
			_show_inspector()
		"zone":
			_show_zone()
		"deck_detail":
			_show_deck_detail()
		"victory":
			_show_victory()
		_:
			_show_battle()


func trigger_presentation(kind: String) -> PresentationHandle:
	_resolve_nodes()
	if kind == "victory":
		show_preview("victory")
		return null
	if current_battle == null or not is_instance_valid(current_battle):
		show_preview("battle")
	_checkpoint_generation += 1
	var generation := _checkpoint_generation
	current_presentation_kind = kind
	presentation_checkpoint_percent = -1
	var fixture := _build_presentation_fixture(kind)
	_apply_presentation_fixture(fixture)
	_set_checkpoint_status("实时播放 · %s" % _presentation_label(kind))
	var handle := current_battle.submit_transition(presentation_request)
	if handle != null and not handle.is_completed():
		handle.completed.connect(
			_on_live_presentation_completed.bind(generation, kind),
			CONNECT_ONE_SHOT,
		)
	else:
		_on_live_presentation_completed(handle, generation, kind)
	return handle


## Rebuilds the selected before/after fixture and leaves it at an exact capture
## checkpoint. Values may be expressed as 0/50/100 or as 0.0/0.5/1.0.
## Await this method (or presentation_checkpoint_ready) before taking a capture.
func set_presentation_checkpoint(percent: float, kind: String = "") -> void:
	_resolve_nodes()
	if not kind.is_empty():
		current_presentation_kind = kind
	if current_presentation_kind == "victory":
		current_presentation_kind = "draw"
	if current_battle == null or not is_instance_valid(current_battle):
		show_preview("battle")
	_checkpoint_generation += 1
	var generation := _checkpoint_generation
	var checkpoint := _normalize_checkpoint(percent)
	var fixture := _build_presentation_fixture(current_presentation_kind)
	_apply_presentation_fixture(fixture)
	if checkpoint == 0:
		presentation_checkpoint_percent = 0
		_set_checkpoint_status(
			"0%% · %s · before" % _presentation_label(current_presentation_kind)
		)
		presentation_checkpoint_ready.emit(0, current_presentation_kind)
		return
	_set_checkpoint_status(
		"%d%% · %s · 捕获中…" % [
			checkpoint,
			_presentation_label(current_presentation_kind),
		]
	)
	var event: Dictionary = presentation_request.events[0]
	var handle := current_battle.submit_transition(presentation_request)
	if checkpoint == 100:
		if handle != null and not handle.is_completed():
			await handle.completed
		if generation != _checkpoint_generation:
			return
		if is_inside_tree() and get_tree() != null:
			await get_tree().process_frame
		if generation != _checkpoint_generation:
			return
		presentation_checkpoint_percent = 100
		_set_checkpoint_status(
			"100%% · %s · after" % _presentation_label(current_presentation_kind)
		)
		presentation_checkpoint_ready.emit(100, current_presentation_kind)
		return
	# Let the coordinator enter the batch before measuring its real event timing.
	if is_inside_tree() and get_tree() != null:
		await get_tree().process_frame
	if generation != _checkpoint_generation:
		return
	var half_duration := _presentation_duration(event) * 0.5
	if half_duration > 0.0 and get_tree() != null:
		await get_tree().create_timer(half_duration, true, false, true).timeout
	if generation != _checkpoint_generation:
		return
	# Node-bound tweens stop with the battle subtree while the toolbar remains live.
	if current_battle != null and is_instance_valid(current_battle):
		current_battle.process_mode = Node.PROCESS_MODE_DISABLED
	presentation_checkpoint_percent = 50
	_set_checkpoint_status(
		"50%% · %s · motion paused" % _presentation_label(current_presentation_kind)
	)
	presentation_checkpoint_ready.emit(50, current_presentation_kind)


func capture_presentation_checkpoint(percent: float, kind: String = "") -> void:
	await set_presentation_checkpoint(percent, kind)


func get_presentation_checkpoint() -> Dictionary:
	return {
		"percent": presentation_checkpoint_percent,
		"kind": current_presentation_kind,
		"before_view": presentation_before_view,
		"after_view": presentation_after_view,
		"request": presentation_request,
	}


func load_native_scenario(
	snapshot: Dictionary,
	p_rng_state: int,
	viewer: int = 0,
	render: bool = true,
) -> Dictionary:
	## Developer-only Snapshot 3 entry point. The Workbench never mutates the
	## restored state; all subsequent rule steps remain inside ptcg_core.
	rules_adapter = NativeRulesSessionAdapter.new(catalog)
	if not rules_adapter.restore(snapshot, p_rng_state):
		return {"success": false, "error_code": "scenario_restore_failed"}
	if render:
		_render_native_state(viewer)
	return {
		"success": true,
		"error_code": "",
		"revision": rules_adapter.state.revision,
		"state_hash": rules_adapter.state_hash(),
	}


func replay_match_journal(
	journal: Dictionary,
	deck_keys: Array[String] = ["fire", "water"],
	viewer: int = 0,
	render: bool = true,
) -> Dictionary:
	## Deterministically replays MatchJournal v1 and reports the first divergent
	## revision/hash. Full journals stay local to this developer tool.
	if (
		str(journal.get("schema", "")) != "ptcg_match_journal/1"
		or int(journal.get("format_version", 0)) != 1
		or int(journal.get("native_abi_version", 0)) != 2
		or deck_keys.size() != 2
		or not catalog.decks.has(deck_keys[0])
		or not catalog.decks.has(deck_keys[1])
	):
		return {"success": false, "error_code": "journal_contract_invalid"}
	var native_session: Variant = ClassDB.instantiate("NativeRulesSession")
	if native_session == null:
		return {"success": false, "error_code": "native_rules_unavailable"}
	var created: Dictionary = native_session.create(
		catalog.native_rules_catalog(),
		[
			catalog.expand_deck(deck_keys[0]),
			catalog.expand_deck(deck_keys[1]),
		],
		Dictionary(journal.get("match_config", {})),
		int(journal.get("initial_seed", 0)),
	)
	if not bool(created.get("success", false)):
		return {
			"success": false,
			"error_code": str(created.get("error_code", "journal_create_failed")),
			"mismatch_index": 0,
		}
	var expected_entries: Array = journal.get("entries", [])
	var actual_journal: Dictionary = native_session.journal()
	for field in [
		"catalog_fingerprint", "content_fingerprint", "contract_fingerprint",
		"vm_descriptor_digest",
	]:
		if journal.get(field) != actual_journal.get(field):
			return {
				"success": false,
				"error_code": "journal_%s_mismatch" % field,
				"mismatch_index": 0,
			}
	if expected_entries.is_empty():
		return {"success": false, "error_code": "journal_create_missing"}
	var mismatch := _journal_entry_mismatch(
		Dictionary(expected_entries[0]),
		Dictionary(native_session.journal().get("entries", [])[0]),
	)
	if not mismatch.is_empty():
		return {
			"success": false,
			"error_code": mismatch,
			"mismatch_index": 0,
		}
	for index in range(1, expected_entries.size()):
		var expected := Dictionary(expected_entries[index])
		var input := Dictionary(expected.get("input", {}))
		var step: Dictionary
		match str(expected.get("kind", "")):
			"action":
				step = native_session.apply_action(input)
			"choice":
				step = native_session.apply_choice(input)
			"command":
				if str(input.get("command", "")) != "surrender":
					return {
						"success": false,
						"error_code": "journal_command_unsupported",
						"mismatch_index": index,
					}
				step = native_session.surrender(int(input.get("actor", -1)))
			_:
				return {
					"success": false,
					"error_code": "journal_kind_unsupported",
					"mismatch_index": index,
				}
		if not bool(step.get("success", false)):
			return {
				"success": false,
				"error_code": str(step.get("error_code", "journal_step_failed")),
				"mismatch_index": index,
			}
		var actual_entries: Array = native_session.journal().get("entries", [])
		mismatch = _journal_entry_mismatch(
			expected,
			Dictionary(actual_entries[-1]),
		)
		if not mismatch.is_empty():
			return {
				"success": false,
				"error_code": mismatch,
				"mismatch_index": index,
				"expected": expected,
				"actual": actual_entries[-1],
			}
	rules_adapter = NativeRulesSessionAdapter.new(catalog)
	rules_adapter.native = native_session
	rules_adapter.rng_state = native_session.rng_state()
	rules_adapter.state = GameState.from_snapshot(native_session.snapshot())
	if rules_adapter.state == null:
		return {"success": false, "error_code": "journal_final_state_invalid"}
	if render:
		_render_native_state(viewer)
	return {
		"success": true,
		"error_code": "",
		"mismatch_index": -1,
		"revision": rules_adapter.state.revision,
		"state_hash": rules_adapter.state_hash(),
	}


static func _journal_entry_mismatch(
	expected: Dictionary,
	actual: Dictionary,
) -> String:
	for field in [
		"index", "kind", "revision_before", "revision_after",
		"input", "state_hash", "event_hash", "rng_state",
	]:
		if expected.get(field) != actual.get(field):
			return "journal_%s_mismatch" % field
	return ""


func _render_native_state(viewer: int) -> void:
	if current_battle == null or not is_instance_valid(current_battle):
		show_preview("battle")
	if current_battle == null or rules_adapter == null or rules_adapter.state == null:
		return
	sample_state = rules_adapter.state.clone_state()
	preview_caption.text = "Native ABI 2 · revision %d · %s" % [
		sample_state.revision,
		rules_adapter.state_hash(),
	]
	current_battle.update_view(
		sample_state,
		viewer,
		[],
		"",
		false,
		"native_workbench",
	)


func _bind_toolbar() -> void:
	for button_name in [
		"TitlePreview",
		"DeckPreview",
		"NetworkPreview",
		"SettingsPreview",
		"ChoicePreview",
		"EnergyChoicePreview",
		"BattlePreview",
		"AIThinkingPreview",
		"VictoryPreview",
		"HelpPreview",
		"InspectorPreview",
		"ZonePreview",
		"DeckDetailsPreview",
	]:
		var button := get_node(
			"Layout/Sidebar/Scroll/Buttons/" + button_name
		) as Button
		button.custom_minimum_size.y = 48.0
		var key := str(button.get_meta("preview"))
		button.pressed.connect(show_preview.bind(key))
	for button_name in [
		"DrawEvent",
		"EnergyAttachEvent",
		"EvolveEvent",
		"AttackEvent",
		"DamageEvent",
		"KOEvent",
		"VictoryEvent",
	]:
		var button := get_node(
			"Layout/Sidebar/Scroll/Buttons/" + button_name
		) as Button
		button.custom_minimum_size.y = 48.0
		var key := str(button.get_meta("event"))
		button.pressed.connect(trigger_presentation.bind(key))
	for button_name in ["Checkpoint0", "Checkpoint50", "Checkpoint100"]:
		var button := get_node(
			"Layout/Sidebar/Scroll/Buttons/" + button_name
		) as Button
		button.custom_minimum_size.y = 48.0
		var percent := float(button.get_meta("checkpoint"))
		button.pressed.connect(set_presentation_checkpoint.bind(percent, ""))


func _show_title() -> void:
	preview_caption.text = "标题页 · 可编辑文字、按钮和进入动画"
	var page := TITLE_SCENE.instantiate() as TitlePage
	preview_host.add_child(page)
	page.configure("v%s" % AppState.APP_VERSION)


func _show_decks() -> void:
	preview_caption.text = "牌组选择 · 动态数据填入静态场景"
	var page := DECK_SCENE.instantiate() as DeckSelectPage
	preview_host.add_child(page)
	page.configure(catalog, "challenge")


func _show_network() -> void:
	preview_caption.text = "网络大厅 · LAN/Relay 共用布局"
	var page := NETWORK_SCENE.instantiate() as NetworkLobbyPage
	preview_host.add_child(page)
	page.configure(catalog, "relay", "wss://relay.example.invalid")


func _show_settings() -> void:
	preview_caption.text = "设置面板 · 前台主题、分区表单与实时数值"
	var panel := _centered_panel(Vector2(700, 650), true)
	var settings := SETTINGS_SCENE.instantiate() as SettingsPanel
	panel.add_child(settings)
	settings.configure()


func _show_choice() -> void:
	preview_caption.text = "复杂选择 · 卡图网格与文本选项"
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	preview_host.add_child(center)
	var panel_container := PanelContainer.new()
	panel_container.custom_minimum_size = Vector2(720, 560)
	center.add_child(panel_container)
	var panel := CHOICE_SCENE.instantiate() as ChoicePanel
	panel_container.add_child(panel)
	panel.configure("选择 1～2 张卡牌；此预览不会提交规则响应。", true)
	for card_id in ["sv1-151", "sv1-189", "svf-potion", "svi-jete"]:
		var card := load("res://ui/card_view.tscn").instantiate() as CardView
		card.custom_minimum_size = Vector2(86, 121)
		card.configure(card_id, null, false, -1, 0, "", true)
		panel.card_grid.add_child(card)
	for text in ["选择第一项", "选择第二项", "取消并返回"]:
		var button := Button.new()
		button.focus_mode = Control.FOCUS_NONE
		button.custom_minimum_size.y = 48
		button.text = text
		panel.option_list.add_child(button)


func _show_energy_choice() -> void:
	preview_caption.text = "能量分配选择 · 多张能量可重复选择同一目标"
	var center := _centered_panel(Vector2(760, 620))
	var panel := CHOICE_SCENE.instantiate() as ChoicePanel
	center.add_child(panel)
	panel.configure("请选择 2–2 项。重复点击同一目标表示多张能量分到同一处。", true)
	panel.add_child(_label("待分配能量", 18, DesignTokens.GOLD))
	var energy_grid := GridContainer.new()
	energy_grid.columns = 4
	energy_grid.add_theme_constant_override("h_separation", 8)
	panel.add_child(energy_grid)
	panel.move_child(energy_grid, 2)
	for card_id in ["sv1-ener-2", "sv1-ener-2"]:
		energy_grid.add_child(_card_thumb(card_id, false))
	for card_id in ["svi-hrot", "svi-chim", "svi-ente"]:
		var button := Button.new()
		button.focus_mode = Control.FOCUS_NONE
		button.custom_minimum_size.y = 48
		button.text = catalog.card_name(card_id)
		panel.option_list.add_child(button)


func _show_help() -> void:
	preview_caption.text = "帮助面板 · 四类导航与单一纵向滚动区"
	var panel := _centered_panel(Vector2(860, 650), true)
	var content := HELP_PANEL_SCENE.instantiate() as HelpPanel
	panel.add_child(content)
	content.configure()


func _show_inspector() -> void:
	preview_caption.text = "卡牌检查器 · 大图、完整卡文和附属卡"
	var panel := _centered_panel(Vector2(860, 650))
	var content := CARD_INSPECTOR_PANEL_SCENE.instantiate() as CardInspectorPanel
	panel.add_child(content)
	var pokemon := PokemonState.new("svi-hrot")
	pokemon.energy_card_ids.assign(["sv1-ener-2", "sv1-ener-2"])
	content.configure(catalog, {
		"card_id": "svi-hrot",
		"location": "加热洛托姆 · 我方战斗区",
		"pokemon": pokemon,
	})


func _show_zone() -> void:
	preview_caption.text = "区域查看 · 公开弃牌与隐藏牌库/奖赏卡"
	var panel := _centered_panel(Vector2(820, 620))
	var content := ZONE_INSPECTOR_PANEL_SCENE.instantiate() as ZoneInspectorPanel
	panel.add_child(content)
	content.configure(catalog, {
		"hidden": false,
		"card_ids": ["sv1-180", "sv1-189", "svf-potion", "sv1-ener-2"],
		"count": 4,
	})


func _show_deck_detail() -> void:
	preview_caption.text = "牌组详情 · 核心卡与 Pokémon/Trainer/Energy 分组"
	var panel := _centered_panel(Vector2(900, 680), true)
	var content := DECK_DETAIL_PANEL_SCENE.instantiate() as DeckDetailPanel
	panel.add_child(content)
	content.configure(catalog, "fire")


func _show_battle() -> void:
	preview_caption.text = "战斗场景 · 使用左侧按钮触发演出"
	sample_state = UIPreviewStateFactory.battle_state()
	current_battle = BATTLE_SCENE.instantiate() as BattleTable
	preview_host.add_child(current_battle)
	current_battle.initialize_ui()
	current_battle.update_view(
		sample_state,
		0,
		UIPreviewStateFactory.action_rows(sample_state),
		"pokemon:0:active",
		false,
		"preview",
	)
	_set_checkpoint_status("选择表现事件，然后捕获 0% / 50% / 100%")


func _show_ai_thinking() -> void:
	preview_caption.text = "AI 思考 · 轻量状态层与对手侧牌位反馈"
	sample_state = UIPreviewStateFactory.battle_state()
	sample_state.active_player_idx = 1
	sample_state.players[1].name = "Challenge AI"
	current_battle = BATTLE_SCENE.instantiate() as BattleTable
	preview_host.add_child(current_battle)
	current_battle.initialize_ui()
	current_battle.update_view(
		sample_state,
		0,
		[],
		"",
		true,
		"challenge",
	)


func _show_victory() -> void:
	preview_caption.text = "胜利页 · 模式、牌组与代表卡摘要"
	var victory := VICTORY_SCENE.instantiate() as VictoryScreen
	victory.configure(0, 12, "预览玩家", "svi-hrot", {
		"mode_label": "Challenge AI",
		"winner_deck_name": "烈焰猴",
		"winner_card_name": catalog.card_name("svi-hrot"),
	})
	preview_host.add_child(victory)


func _presentation_event(kind: String) -> Dictionary:
	var base := {
		"event_id": "workbench:%d" % event_sequence,
		"actor": 0,
		"visibility": "public",
	}
	match kind:
		"draw", "draw_sparse", "cross_owner_draw":
			base.merge({
				"event_type": "cards_drawn",
				"source": {"player": 0, "zone": "deck"},
				"target": {"player": 0, "zone": "hand"},
				"amount": 1,
				"data": {"player": 0, "count": 1},
			})
			if kind in ["draw", "cross_owner_draw"]:
				base["card_id"] = "sv1-151"
				base["data"]["card_ids"] = ["sv1-151"]
			if kind == "cross_owner_draw":
				# The effect's causal actor differs from the owner of the hidden
				# movement, as it does for each side of Judge.
				base["actor"] = 1
				base["visibility"] = "owner"
				base["data"]["visibility_owner"] = 0
		"attach_energy":
			base.merge({
				"event_type": "energy_attached",
				"card_id": "sv1-ener-2",
				"source": {"player": 0, "zone": "hand", "index": 0},
				"target": {"player": 0, "slot": "active"},
				"data": {
					"player": 0,
					"slot": "active",
					"card_id": "sv1-ener-2",
					"source_zone": "hand",
					"source_index": 0,
				},
			})
		"evolve":
			base.merge({
				"event_type": "pokemon_evolved",
				"card_id": "svi-infr",
				"source": {"player": 0, "zone": "hand", "index": 0},
				"target": {"player": 0, "slot": "active"},
				"data": {
					"player": 0,
					"slot": "active",
					"card_id": "svi-infr",
					"source_index": 0,
				},
			})
		"attack":
			base.merge({
				"event_type": "attack_declared",
				"source": {"player": 0, "slot": "active"},
				"target": {"player": 1, "slot": "active"},
			})
		"ko":
			base.merge({
				"event_type": "pokemon_ko",
				"card_id": "sv2-keldeo",
				"source": {"player": 1, "slot": "active"},
				# KO declaration/trigger feedback still targets the in-play stack.
				# The serialized ko_leave_play event owns the later discard move.
				"target": {"player": 1, "slot": "active"},
				"amount": 1,
				"data": {
					"player": 1,
					"slot": "active",
					"card_ids": ["sv2-keldeo"],
				},
			})
		"retreat_identical":
			base.merge({
				"event_type": "retreat",
				"source": {"player": 0, "slot": "bench_0"},
				"target": {"player": 0, "slot": "active"},
				"data": {
					"actor": 0,
					"player": 0,
					"slot": "bench_0",
					"bench_idx": 0,
					"outgoing_card_id": "svi-chim",
					"incoming_card_id": "svi-chim",
				},
			})
		_:
			base.merge({
				"event_type": "damage_dealt",
				"source": {"player": 0, "slot": "active"},
				"target": {"player": 1, "slot": "active"},
				"amount": 90,
				"counter_count": 9,
			})
	return base


func _build_presentation_fixture(kind: String) -> Dictionary:
	event_sequence += 1
	var before := UIPreviewStateFactory.battle_state(20260623 + event_sequence)
	before.revision = event_sequence * 2
	match kind:
		"draw", "draw_sparse", "cross_owner_draw":
			before.players[0].deck[-1] = "sv1-151"
		"evolve":
			before.players[0].hand.insert(0, "svi-infr")
		"retreat_identical":
			before.players[0].active = PokemonState.new("svi-chim")
			before.players[0].active.placed_this_turn = false
			before.players[0].bench[0] = PokemonState.new("svi-chim")
			before.players[0].bench[0].placed_this_turn = false
	var after := before.clone_state()
	match kind:
		"draw", "draw_sparse", "cross_owner_draw":
			if not after.players[0].deck.is_empty():
				after.players[0].hand.append(after.players[0].deck.pop_back())
			after.log_action("预览玩家抽到了 妙蛙种子。")
		"attach_energy":
			var energy_id: String = after.players[0].hand.pop_at(0)
			after.players[0].active.energy_card_ids.append(energy_id)
			after.players[0].energy_attached_this_turn = true
			after.log_action("预览玩家为战斗宝可梦附加了能量。")
		"evolve":
			after.players[0].hand.pop_at(0)
			var old_card_id := after.players[0].active.card_id
			after.players[0].active.evolution_stack_ids.append(old_card_id)
			after.players[0].active.card_id = "svi-infr"
			after.log_action("预览玩家进化了战斗宝可梦。")
		"attack":
			after.log_action("预览玩家使用了 高温冲撞。")
		"ko":
			var knocked_out := after.players[1].active
			if knocked_out != null:
				after.players[1].discard.append(knocked_out.card_id)
				after.players[1].discard.append_array(
					knocked_out.evolution_stack_ids)
				if not knocked_out.attached_tool_id.is_empty():
					after.players[1].discard.append(
						knocked_out.attached_tool_id)
				after.players[1].discard.append_array(
					knocked_out.energy_card_ids)
				after.players[1].active = null
			after.log_action("预览对手的战斗宝可梦气绝了。")
		"retreat_identical":
			var outgoing := after.players[0].active
			after.players[0].active = after.players[0].bench[0]
			after.players[0].bench[0] = outgoing
			after.players[0].retreated_this_turn = true
			after.log_action("预览玩家在两张同名宝可梦之间完成了撤退。")
		_:
			after.players[1].active.damage_counters += 9
			after.log_action("预览对手的战斗宝可梦受到了 90 点伤害。")
	after.revision = before.revision + 1
	var before_view := BattleViewModel.capture(
		before,
		0,
		UIPreviewStateFactory.action_rows(before),
		"pokemon:0:active",
		false,
		"preview",
	)
	var after_action_rows: Array[Dictionary] = []
	if after.players[0].active != null and after.players[1].active != null:
		after_action_rows = UIPreviewStateFactory.action_rows(after)
	var after_view := BattleViewModel.capture(
		after,
		0,
		after_action_rows,
		"pokemon:0:active",
		false,
		"preview",
	)
	var events: Array[Dictionary] = [_presentation_event(kind)]
	if kind == "ko":
		# KO is a two-step presentation lifecycle.  The declaration keeps the
		# old stack available for impact feedback; the following move owns the
		# physical departure to the discard pile.
		events[0]["data"]["defer_leave_play"] = true
		var leave_event: Dictionary = events[0].duplicate(true)
		leave_event["event_id"] = "%s:leave" % str(events[0].get("event_id", ""))
		leave_event["event_type"] = "card_moved"
		leave_event["source"] = {"player": 1, "slot": "active"}
		leave_event["target"] = {"player": 1, "zone": "discard"}
		leave_event["data"] = {
			"player": 1,
			"source_player": 1,
			"source_slot": "active",
			"target_player": 1,
			"target_zone": "discard",
			"card_ids": ["sv2-keldeo"],
			"ko_leave_play": true,
		}
		events.append(leave_event)
	var request := BattleTransitionRequest.create(
		after_view,
		events,
		0,
		BattleTransitionRequest.CAUSE_REFRESH,
		"workbench:%d" % event_sequence,
		"",
		"",
		false,
	)
	return {
		"before_state": before,
		"after_state": after,
		"before_view": before_view,
		"after_view": after_view,
		"request": request,
	}


func _apply_presentation_fixture(fixture: Dictionary) -> void:
	if current_battle == null or not is_instance_valid(current_battle):
		return
	current_battle.process_mode = Node.PROCESS_MODE_INHERIT
	presentation_before_view = fixture.get("before_view") as BattleViewModel
	presentation_after_view = fixture.get("after_view") as BattleViewModel
	presentation_request = fixture.get("request") as BattleTransitionRequest
	sample_state = (fixture.get("before_state") as GameState).clone_state()
	current_battle.cancel_presentations("workbench_fixture_reset", presentation_before_view)


func _presentation_duration(event: Dictionary) -> float:
	if current_battle == null or not is_instance_valid(current_battle):
		return 0.0
	if current_battle == null or current_battle.director == null:
		return 0.0
	return float(current_battle.director.call("_duration_for", event))


func _normalize_checkpoint(percent: float) -> int:
	var resolved := percent * 100.0 if percent > 0.0 and percent <= 1.0 else percent
	if resolved < 25.0:
		return 0
	if resolved < 75.0:
		return 50
	return 100


func _presentation_label(kind: String) -> String:
	return {
		"draw": "抽牌",
		"attach_energy": "附能",
		"evolve": "进化",
		"attack": "攻击蓄力",
		"damage": "伤害",
		"ko": "击倒",
		"retreat_identical": "同名宝可梦撤退",
	}.get(kind, kind)


func _on_live_presentation_completed(
	_handle: PresentationHandle,
	generation: int,
	kind: String,
) -> void:
	if generation != _checkpoint_generation:
		return
	presentation_checkpoint_percent = 100
	_set_checkpoint_status("播放完成 · %s" % _presentation_label(kind))


func _set_checkpoint_status(text_value: String) -> void:
	if checkpoint_status != null:
		checkpoint_status.text = text_value


func _centered_panel(min_size: Vector2, frontend_surface: bool = false) -> Container:
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	preview_host.add_child(center)
	var panel := PanelContainer.new()
	var available := preview_host.size
	if available.x <= 0.0 or available.y <= 0.0:
		available = Vector2(1280, 720)
	panel.custom_minimum_size = Vector2(
		minf(min_size.x, maxf(320.0, available.x - 32.0)),
		minf(min_size.y, maxf(320.0, available.y - 32.0)),
	)
	if frontend_surface:
		panel.theme = FRONTEND_THEME
	center.add_child(panel)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.follow_focus = false
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 12)
	scroll.add_child(content)
	return content


func _label(text_value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text_value
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_constant_override("outline_size", 0)
	label.add_theme_color_override("font_outline_color", Color.TRANSPARENT)
	return label


func _card_thumb(card_id: String, hidden: bool) -> CardView:
	var card := load("res://ui/card_view.tscn").instantiate() as CardView
	card.custom_minimum_size = Vector2(76, 107)
	card.configure(card_id, null, hidden, -1, -1, "", true)
	card.tooltip_text = "隐藏卡牌" if hidden else catalog.card_name(card_id)
	return card


func _clear_preview() -> void:
	_checkpoint_generation += 1
	if current_battle != null and is_instance_valid(current_battle):
		current_battle.process_mode = Node.PROCESS_MODE_INHERIT
	current_battle = null
	presentation_checkpoint_percent = -1
	presentation_before_view = null
	presentation_after_view = null
	presentation_request = null
	for child in preview_host.get_children():
		preview_host.remove_child(child)
		child.queue_free()


func _resolve_nodes() -> void:
	preview_host = get_node("Layout/PreviewColumn/PreviewHost") as Control
	preview_caption = get_node("Layout/PreviewColumn/PreviewCaption") as Label
	checkpoint_status = get_node(
		"Layout/Sidebar/Scroll/Buttons/CheckpointStatus"
	) as Label
