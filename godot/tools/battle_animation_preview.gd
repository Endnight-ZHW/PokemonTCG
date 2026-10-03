class_name BattleAnimationPreview
extends RefCounted

## Fixed, public fixtures shared by Workbench and graphics/semantic contracts.
const ACTIONS := {
	"attack": "完整攻击 · 普通命中", "heavy_attack": "完整攻击 · 重击", "knockout_prize": "击倒 → 离场 → 奖励", "attack_declared": "攻击蓄力", "damage_dealt": "属性命中", "heavy_hit": "属性命中 · 重击",
	"cards_drawn": "抽牌", "opening_draw": "连续发牌", "deck_shuffled": "洗牌",
	"pokemon_played": "基础宝可梦出场", "trainer_played": "训练家出牌",
	"duplicate_basic_left": "同名手牌 · 放置左侧", "duplicate_basic_right": "同名手牌 · 放置右侧",
	"jet_energy": "喷射能量 · 附能后换位",
	"stadium_changed": "替换场地", "tool_attached": "附加道具",
	"energy_attached": "附加能量", "energy_transfer": "转移能量", "pokemon_evolved": "进化",
	"damage_counters_placed": "放置伤害指示物", "recoil": "反伤",
	"healed": "治疗", "damage_prevented": "伤害无效", "direct_knockout_applied": "直接昏厥效果",
	"status_POISONED": "中毒", "status_BURNED": "灼伤", "status_ASLEEP": "睡眠",
	"status_PARALYZED": "麻痹", "status_CONFUSED": "混乱", "status_removed": "解除状态",
	"status_tick": "异常状态扣血", "confusion_failed": "混乱攻击失败", "dazzled_failed": "眩目攻击失败",
	"retreat": "撤退", "switched": "换位", "promoted": "升前", "pokemon_ko": "昏厥并离场",
	"cards_discarded": "弃牌", "card_moved": "回收卡牌", "prize_taken": "领取奖励卡",
	"cards_revealed": "公开卡牌", "cards_selected": "检索并公开",
	"coin_flip": "抛硬币", "setup_revealed": "开局公开", "turn_start": "回合开始",
	"turn_end": "回合结束", "checkup": "宝可梦检查", "game_over": "获胜光环",
}


static func card_for(element: String, catalog: CardCatalog) -> String:
	for id in catalog.cards:
		if catalog.is_pokemon(id) and element in catalog.get_card(id).get("energy_types", []):
			return str(id)
	return "svi-hrot"


static func build(kind: String, element: String, viewer: int, sequence: int, catalog: CardCatalog) -> Dictionary:
	if kind in ["duplicate_basic_left", "duplicate_basic_right", "jet_energy"]:
		return _build_real_action(kind, viewer, sequence, catalog)
	var before := UIPreviewStateFactory.battle_state(73101)
	before.revision = sequence * 2
	before.players[0].active.card_id = card_for(element, catalog)
	before.players[0].active.damage_counters = 0
	before.players[1].active.damage_counters = 1
	before.players[1].active.status_conditions.clear()
	# Both views have real owner hands before crossing the privacy boundary.
	before.players[1].hand.assign(["sv1-ener-3", "sv2-keldeo", "sv2-starm", "sv1-189", "svf-potion"])
	var type := kind
	if kind in ["attack", "heavy_attack", "heavy_hit"]: type = "damage_dealt"
	if kind == "knockout_prize": type = "pokemon_ko"
	if kind == "opening_draw": type = "cards_drawn"
	if kind == "energy_transfer": type = "energy_attached"
	if kind == "recoil": type = "damage_dealt"
	if kind == "status_tick": type = "damage_counters_placed"
	if kind.begins_with("status_") and kind.get_slice("_", 1) in BattleFeedbackCue.STATUS_NAMES:
		type = "status_applied"
	var source := {"player": 0, "slot": "active"}
	var target := {"player": 1, "slot": "active"}
	var data := {"player": 1, "target_player": 1, "slot": "active", "amount": 30, "counter_count": 3}
	var event := {"event_id": "animation:%d:0" % sequence, "event_type": type,
		"actor": 0, "visibility": "public", "source": source, "target": target, "amount": 30, "data": data}
	if kind in ["heavy_attack", "heavy_hit"]:
		event.amount = 60
		data.amount = 60
		data.counter_count = 6
	if type == "healed": before.players[1].active.damage_counters = 4
	if type == "status_removed": before.players[1].active.status_conditions.assign(["POISONED"])
	if type == "promoted": before.players[0].active = null
	var incoming := ""
	if type in ["energy_attached", "tool_attached", "pokemon_played", "trainer_played", "stadium_changed", "pokemon_evolved"]:
		incoming = "sv1-ener-2"
		match type:
			"energy_attached":
				incoming = str(EnergyIconCatalog.SOURCE_CARD_IDS.get(element, "svg2-lume"))
				if not catalog.is_energy(incoming): incoming = "svg2-lume"
			"tool_attached": incoming = "sv1-202"
			"pokemon_played": incoming = "svi-chim"
			"trainer_played": incoming = "sv1-189"
			"stadium_changed":
				incoming = "sv1-171"
				before.stadium_card_id = ""
			"pokemon_evolved":
				incoming = "svi-infr"
				before.players[0].active.card_id = "svi-chim"
		if kind == "energy_transfer":
			before.players[0].bench[0].energy_card_ids.assign([incoming])
			event.source = {"player": 0, "slot": "bench_0", "attachment_type": "energy", "index": 0}
		else:
			before.players[0].hand.push_front(incoming)
			event.source = {"player": 0, "zone": "hand", "index": 0}
		event.target = {"player": 0, "slot": "bench_2" if type == "pokemon_played" else "active"}
		if type == "trainer_played": event.target = {"player": 0, "zone": "discard"}
		if type == "stadium_changed": event.target = {"player": -1, "zone": "stadium"}
		event.card_id = incoming
		event.amount = 1
		event.data = {"player": 0, "card_id": incoming, "card_ids": [incoming]}
	var after := before.clone_state()
	match type:
		"damage_dealt", "damage_counters_placed", "confusion_failed":
			data.damage_kind = "attack_damage" if kind in ["attack", "heavy_attack", "heavy_hit", "damage_dealt"] else "damage_counters" if type == "damage_counters_placed" else "damage"
			if kind in ["recoil", "confusion_failed"]:
				event.target = {"player": 0, "slot": "active"}
				data.player = 0
				data.target_player = 0
				after.players[0].active.damage_counters += 3
			else:
				after.players[1].active.damage_counters += int(event.amount) / 10
			if kind == "status_tick":
				data.source_kind = "special_condition"
				data.status = "POISONED"
				event.source = event.target.duplicate()
		"healed": after.players[1].active.damage_counters -= 3
		"status_applied":
			data.status = kind.trim_prefix("status_")
			after.players[1].active.status_conditions.append(data.status)
		"status_removed":
			data.status = "POISONED"
			after.players[1].active.status_conditions.clear()
		"energy_attached", "tool_attached", "pokemon_played", "trainer_played", "stadium_changed", "pokemon_evolved":
			if kind == "energy_transfer": after.players[0].bench[0].energy_card_ids.clear()
			else: after.players[0].hand.pop_front()
			match type:
				"energy_attached": after.players[0].active.energy_card_ids.append(incoming)
				"tool_attached": after.players[0].active.attached_tool_id = incoming
				"pokemon_played": after.players[0].bench[2] = PokemonState.new(incoming)
				"trainer_played": after.players[0].discard.append(incoming)
				"stadium_changed": after.stadium_card_id = incoming
				"pokemon_evolved":
					after.players[0].active.evolution_stack_ids.append(before.players[0].active.card_id)
					after.players[0].active.card_id = incoming
					after.players[0].active.status_conditions.clear()
		"retreat", "switched", "promoted":
			event.source = {"player": 0, "slot": "bench_0"}
			event.target = {"player": 0, "slot": "active"}
			event.data = {"player": 0, "slot": "bench_0", "bench_idx": 0}
			var outgoing := after.players[0].active
			after.players[0].active = after.players[0].bench[0]
			after.players[0].bench[0] = outgoing
		"cards_drawn", "cards_selected", "prize_taken", "cards_discarded", "card_moved":
			var from := "hand" if type == "cards_discarded" else "discard" if type == "card_moved" else "prizes" if type == "prize_taken" else "deck"
			var to := "discard" if type == "cards_discarded" else "hand"
			event.source = {"player": 0, "zone": from}
			event.target = {"player": 0, "zone": to}
			event.amount = 7 if kind == "opening_draw" else 1
			var ids: Array[String] = []
			for i in range(event.amount):
				var id := str((after.players[0].get(from) as Array).pop_back())
				ids.append(id)
				(after.players[0].get(to) as Array).append(id)
			event.data = {"player": 0, "card_ids": ids, "count": ids.size()}
			if type in ["cards_drawn", "prize_taken"]: event.visibility = "owner"
		"cards_revealed":
			event.source = {"player": 0, "zone": "deck"}
			event.target = event.source.duplicate()
			event.amount = 2
			event.data = {"player": 0, "cards": [{"card_id": "svi-chim", "matched": true}, {"card_id": "sv1-ener-2", "matched": false}]}
		"deck_shuffled":
			event.source = {"player": 0, "zone": "deck"}
			event.target = event.source.duplicate()
			event.data = {"player": 0}
		"coin_flip": event.data = {"player": 0, "results": [true, false, true]}
		"turn_start", "turn_end", "checkup": event.data = {"player": 0, "turn": 5}
		"setup_revealed": event.data = {"players": [{"active": before.players[0].active.card_id, "bench": ["svi-chim", "svi-ente"]}, {"active": "sv2-keldeo", "bench": ["sv2-starm"]}]}
		"game_over": event.data = {"winner": 0}
	var events: Array[Dictionary] = []
	if kind in ["attack", "heavy_attack"]:
		events.append({"event_id": "animation:%d:charge" % sequence, "event_type": "attack_declared", "actor": 0,
			"source": source, "target": target, "card_id": before.players[0].active.card_id})
	events.append(event)
	if type == "pokemon_ko":
		var pokemon := before.players[1].active
		var ids: Array[String] = [pokemon.card_id]
		ids.append_array(pokemon.evolution_stack_ids)
		ids.append_array(pokemon.energy_card_ids)
		if not pokemon.attached_tool_id.is_empty(): ids.append(pokemon.attached_tool_id)
		event.source = {"player": 1, "slot": "active"}
		event.target = event.source.duplicate()
		event.card_id = pokemon.card_id
		event.amount = ids.size()
		event.data = {"player": 1, "slot": "active", "defer_leave_play": true, "card_ids": ids}
		events.append({"event_id": "animation:%d:leave" % sequence, "event_type": "card_moved", "actor": 0,
			"source": event.source, "target": {"player": 1, "zone": "discard"}, "amount": ids.size(),
			"data": {"player": 1, "card_ids": ids, "ko_leave_play": true}})
		after.players[1].active = null
		after.players[1].discard.append_array(ids)
	if kind == "knockout_prize":
		var prize_id := str(after.players[0].prizes.pop_back())
		after.players[0].hand.append(prize_id)
		events.append({"event_id": "animation:%d:prize" % sequence, "event_type": "prize_taken", "actor": 0,
			"visibility": "owner", "source": {"player": 0, "zone": "prizes"}, "target": {"player": 0, "zone": "hand"},
			"amount": 1, "data": {"player": 0, "card_ids": [prize_id], "count": 1}})
	after.revision = before.revision + 1
	var before_view := BattleViewModel.capture_player_view(before, viewer, [], "", false, "preview")
	var after_view := BattleViewModel.capture_player_view(after, viewer, [], "", false, "preview")
	return {"before_state": before, "after_state": after, "before_view": before_view, "after_view": after_view,
		"request": BattleTransitionRequest.create(after_view, events, 0, BattleTransitionRequest.CAUSE_REFRESH, "animation:%d" % sequence, "", false)}


static func _build_real_action(kind: String, viewer: int, sequence: int, catalog: CardCatalog) -> Dictionary:
	var before := GameState.new()
	before.revision = sequence * 2
	before.setup_stage = GameState.SETUP_COMPLETE
	before.phase = "MAIN"
	before.active_player_idx = 0
	before.first_player_idx = 1
	before.turn_number = 4
	for player in before.players:
		player.active = PokemonState.new("svl-emol")
		player.prizes.assign(["sv1-ener-1", "sv1-ener-1"])
		player.deck.assign(["sv1-ener-1", "sv1-ener-1", "sv1-189"])
		player.hand.assign(["sv1-ener-1", "sv1-189", "sv1-151"])
	var own := before.players[0]
	own.active.energy_card_ids.assign(["sv1-ener-1", "sv1-ener-1"])
	own.active.attached_tool_id = "sv1-202"
	own.energy_attached_this_turn = false
	own.bench[0] = PokemonState.new("svg2-turt")
	own.bench[0].energy_card_ids.assign(["sv1-ener-1"])
	own.bench[2] = null
	var incoming := "svi-jete" if kind == "jet_energy" else "svg2-turt"
	own.hand.assign([incoming, "sv1-189", incoming, "sv1-151", "sv1-ener-1"])
	var adapter := NativeRulesSessionAdapter.new(catalog)
	if not adapter.restore(before.snapshot(), 73101):
		push_error("Animation preview could not restore the native action fixture")
		return {}
	var index := 2 if kind == "duplicate_basic_right" else 0
	var action_kind := "ATTACH_ENERGY" if kind == "jet_energy" else "PLAY_BASIC"
	var target_slot := "bench_0" if kind == "jet_energy" else "bench_2"
	for action in adapter.legal_actions(0).concrete_actions():
		if action.kind != action_kind or action.source == null or action.source.index != index: continue
		if action.target == null or action.target.slot != target_slot: continue
		action.action_id = "animation:%d:%s" % [sequence, kind]
		var result := adapter.apply_action(action.to_dict())
		if not result.success: break
		var after := adapter.state
		var before_view := BattleViewModel.capture_player_view(before, viewer, [], "", false, "preview")
		var after_view := BattleViewModel.capture_player_view(after, viewer, [], "", false, "preview")
		return {"before_state": before, "after_state": after, "before_view": before_view, "after_view": after_view,
			"request": BattleTransitionRequest.create(after_view, result.events, 0, BattleTransitionRequest.CAUSE_REFRESH, action.action_id, "", false)}
	push_error("Animation preview has no valid native action: " + kind)
	return {}
