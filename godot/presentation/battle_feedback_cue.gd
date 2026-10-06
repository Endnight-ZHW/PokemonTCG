class_name BattleFeedbackCue
extends RefCounted

## Presentation-only data. Never serialized into rules, journals or networking.
const ELEMENTS := ["Grass", "Fire", "Water", "Lightning", "Psychic", "Fighting", "Darkness", "Metal", "Dragon", "Colorless"]
const FEEDBACK_EVENTS := ["attack_declared", "damage_dealt", "damage_counters_placed", "confusion_failed", "dazzled_failed", "damage_prevented", "direct_knockout_applied", "healed", "status_applied", "status_removed", "pokemon_ko", "game_over"]
const STATE_EVENTS := ["damage_dealt", "damage_counters_placed", "confusion_failed", "healed", "status_applied", "status_removed"]
const STATUS_NAMES := {"POISONED": "中毒", "BURNED": "灼伤", "ASLEEP": "睡眠", "PARALYZED": "麻痹", "CONFUSED": "混乱"}

var event_id := ""
var kind := "land"
var element := ""
var status := ""
var color := Color.WHITE
var text_color := Color.WHITE
var text := ""
var audio := ""
var source := Vector3.ZERO
var target := Vector3.ZERO
var badge_target := Vector3.ZERO
var attachment_card_id := ""
var source_endpoint: Dictionary = {}
var target_endpoint: Dictionary = {}
var duration := 0.32
var impact_fraction := 0.0
var width := 1.0
var surface_pose := Transform3D.IDENTITY
var has_surface_pose := false
var quality := "high"
var spatial := true
var lunge := false
## Physical arrivals sample this clock from their own flight/settle tween.
## This keeps the visible contact exact even during frame stalls or resize.
var motion_driven := false
var profile: BattleAnimationProfile = MotionPolicy.PROFILE
var heavy := false
var intensity := 1.0
var sample_progress := 0.0


func set_damage_weight(amount: int, maximum_hp: int) -> void:
	if not lunge or maximum_hp <= 0:
		return
	var ratio := float(amount) / maximum_hp
	heavy = ratio >= profile.heavy_damage_ratio
	intensity = lerpf(0.85, 1.35, clampf(ratio, 0.0, 1.0))


func contact_progress(progress: float) -> float:
	var p := clampf((progress - impact_fraction) / maxf(0.01, 1.0 - impact_fraction), 0.0, 1.0)
	if kind != "attack":
		return p
	# A local plateau freezes the hit silhouette, never the semantic clock.
	# Normalize against standard timing so fast/cinematic scale the hold too.
	var hold := (profile.heavy_impact_hold if heavy else profile.impact_hold) / maxf(0.01, float(profile.durations.get("attack_impact", 0.44)) * (1.0 - impact_fraction))
	return clampf((p - hold) / maxf(0.01, 1.0 - hold), 0.0, 1.0)


func bind_surface(pose: Transform3D) -> void:
	surface_pose = pose
	# The origin of a physical card is in its paper, not on the face.
	surface_pose.origin += pose.basis.y * CardEntity3D.THICKNESS * 0.5
	has_surface_pose = true
	target = surface_pose.origin
	width = pose.basis.x.length()


static func from_event(event: Dictionary, source_card_id: String, catalog: CardCatalog, seconds: float) -> BattleFeedbackCue:
	var cue := BattleFeedbackCue.new()
	var data: Dictionary = event.get("data", {})
	var type := str(event.get("event_type", ""))
	cue.event_id = str(event.get("event_id", ""))
	cue.source_endpoint = Dictionary(event.get("source", {})).duplicate(true)
	cue.target_endpoint = Dictionary(event.get("target", {})).duplicate(true)
	cue.duration = seconds
	cue.attachment_card_id = str(event.get("card_id", data.get("card_id", "")))
	cue.spatial = not MotionPolicy.reduced()
	cue.status = str(data.get("status", "")).to_upper()
	var attribute_card := source_card_id
	if type in ["energy_attached", "pokemon_evolved", "pokemon_played"]:
		attribute_card = str(event.get("card_id", data.get("card_id", "")))
	var types: Array = catalog.get_card(attribute_card).get("energy_types", []) if not attribute_card.is_empty() else []
	cue.element = str(types[0]) if not types.is_empty() and str(types[0]) in ELEMENTS else ""
	cue.color = MotionPolicy.PROFILE.element_color(cue.element)
	cue.text_color = cue.color.darkened(0.28)
	var amount := maxi(0, int(event.get("amount", data.get("amount", 0))))
	match type:
		"attack_declared":
			cue.kind = "charge"
			cue.target_endpoint = cue.source_endpoint.duplicate(true)
			cue.audio = "attack_charge"
		"damage_dealt", "damage_counters_placed":
			cue.lunge = type == "damage_dealt" and str(data.get("damage_kind", "")) == "attack_damage" and cue.source_endpoint != cue.target_endpoint
			cue.kind = "attack" if cue.lunge else "counters" if type == "damage_counters_placed" else "recoil"
			if str(data.get("source_kind", "")) == "special_condition":
				cue.kind = "status_damage"
				cue.color = DesignTokens.status_color(cue.status)
			cue.impact_fraction = MotionPolicy.PROFILE.impact_fraction if cue.lunge else 0.20
			cue.text = "-%d" % amount
			cue.text_color = DesignTokens.RED
			cue.audio = "attack_hit" if type == "damage_dealt" else "status"
		"healed":
			cue.kind = "heal"
			cue.color = Color("67a876")
			cue.text_color = DesignTokens.GREEN
			cue.text = "+%d" % amount
			cue.audio = "heal"
			cue.impact_fraction = 0.25
		"status_applied", "status_removed":
			cue.kind = "cleanse" if type == "status_removed" else "status"
			cue.text = str(STATUS_NAMES.get(cue.status, "状态")) + ("解除" if type == "status_removed" else "")
			cue.color = DesignTokens.GREEN if type == "status_removed" else DesignTokens.status_color(cue.status)
			cue.text_color = cue.color
			cue.audio = "status"
			cue.impact_fraction = 0.25
		"confusion_failed", "dazzled_failed":
			cue.kind = "status_damage" if type == "confusion_failed" else "status"
			cue.status = "CONFUSED"
			cue.color = DesignTokens.PURPLE
			cue.text_color = cue.color
			cue.text = "混乱 -%d" % amount if type == "confusion_failed" else "眩目：攻击失败"
			cue.audio = "status"
			cue.impact_fraction = 0.20
		"damage_prevented":
			cue.kind = "shield"
			cue.color = DesignTokens.CYAN
			cue.text_color = cue.color
			cue.text = "伤害无效"
			cue.audio = "status"
			cue.impact_fraction = 0.20
		"direct_knockout_applied":
			cue.kind = "direct_ko"
			cue.color = DesignTokens.PURPLE
			cue.text_color = cue.color
			cue.text = "直接昏厥"
			cue.audio = "status"
			cue.impact_fraction = 0.30
		"pokemon_ko":
			cue.kind = "ko"
			cue.target_endpoint = cue.source_endpoint.duplicate(true)
			cue.color = Color("a98bb4")
			cue.text_color = DesignTokens.PURPLE
			cue.text = "击倒"
			cue.audio = "pokemon_ko"
			cue.impact_fraction = 0.12
		"game_over":
			cue.kind = "victory"
			cue.color = Color("d1a250")
			cue.audio = "victory"
			cue.target_endpoint = {"player": int(data.get("winner", data.get("winner_idx", event.get("actor", 0)))), "slot": "active"}
		"energy_attached":
			cue.kind = "energy"
			cue.audio = "energy_attach"
		"pokemon_evolved":
			cue.kind = "evolution"
			cue.audio = "evolution"
		"stadium_changed":
			cue.kind = "stadium"
			cue.audio = "card_place"
		"tool_attached":
			cue.kind = "tool"
			cue.color = Color("86a5af")
			cue.audio = "card_place"
		"trainer_played", "pokemon_played":
			cue.kind = "trainer" if type == "trainer_played" else "land"
			cue.audio = "card_place"
	# Audio follows semantic effects, independently of visual shape or quality.
	match cue.kind:
		"attack": cue.audio = "attack_hit"
		"recoil": cue.audio = "recoil"
		"counters": cue.audio = "counters"
		"status_damage": cue.audio = "status_damage"
		"cleanse": cue.audio = "cleanse"
		"shield": cue.audio = "shield"
		"direct_ko": cue.audio = "direct_ko"
		"stadium": cue.audio = "stadium"
		"tool": cue.audio = "tool"
		"trainer": cue.audio = "trainer"
		"land": cue.audio = "pokemon_play"
		"status": cue.audio = "status_" + cue.status.to_lower() if cue.status in STATUS_NAMES else "status"
		"victory": cue.audio = "" # The result screen owns the sole outcome cue.
	if type in ["confusion_failed", "dazzled_failed"]:
		cue.audio = "attack_failed"
	return cue
