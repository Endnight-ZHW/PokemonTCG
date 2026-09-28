class_name BattleAnimationProfile
extends Resource

## Complete standard-mode seconds, including settling. Tune the shared .tres.
@export_group("Timing")
@export var durations: Dictionary = {
	"hover": 0.12, "hand_reflow": 0.18, "draw_flight": 0.36,
	"draw_landing": 0.06, "landing": 0.10, "multi_card_stagger": 0.06,
	"card_place": 0.40, "energy_attach": 0.40, "switch": 0.42,
	"evolution": 0.62, "damage": 0.32, "ko": 0.50, "return": 0.32,
	"panel": 0.16, "announcement": 0.30,
	"cards_drawn": 0.36, "cards_revealed": 2.05, "cards_selected": 0.40,
	"cards_discarded": 0.32, "card_moved": 0.32, "pokemon_played": 0.40,
	"trainer_played": 0.44, "stadium_changed": 0.50, "tool_attached": 0.40,
	"energy_attached": 0.40, "pokemon_evolved": 0.62,
	"attack_declared": 0.18, "damage_dealt": 0.32,
	"damage_counters_placed": 0.30, "damage_prevented": 0.24,
	"direct_knockout_applied": 0.30, "confusion_failed": 0.30,
	"dazzled_failed": 0.30, "healed": 0.30,
	"status_applied": 0.30, "status_removed": 0.30,
	"retreat": 0.42, "switched": 0.42, "promoted": 0.42,
	"pokemon_ko": 0.50, "prize_taken": 0.40, "deck_shuffled": 0.70,
	"deck_exhausted": 0.30, "coin_flip": 0.74, "game_over": 0.50,
	"coin_first": 0.74, "coin_followup": 0.45, "coin_quick": 0.13,
	"coin_fade": 0.16,
}
@export var mode_scales: Dictionary = {
	"cinematic": 1.0, "standard": 0.82, "fast": 0.58, "reduced": 0.0,
}
@export_range(0.1, 3.0) var public_reveal_floor := 1.85
@export_range(0.1, 3.0) var reduced_public_hold := 1.15
@export_range(0.1, 1.0) var reduced_announcement_hold := 0.22
@export_range(0.1, 1.0) var coin_result_hold := 0.34
@export_range(0.01, 0.3) var coin_result_gap := 0.08
@export_range(0.1, 1.0) var coin_reduced_hold := 0.45
@export_range(1.0, 5.0) var mulligan_public_hold := 3.30
@export_range(1.0, 5.0) var mulligan_reduced_hold := 2.80
@export_range(0.1, 1.0) var mulligan_return := 0.55

@export_group("Physical Motion")
@export_range(0.02, 0.5) var flight_lift_ratio := 0.11
@export_range(0.0, 0.4) var attack_lunge := 0.18
@export_range(0.0, 0.2) var hit_recoil := 0.065
@export_range(0.0, 0.3) var charge_lift := 0.06
@export_range(0.1, 0.8) var impact_fraction := 0.42
@export_range(0.0, 3.0) var ko_camera_pixels := 2.5
@export_range(0.0, 0.12) var ko_camera_seconds := 0.12
@export_enum("Linear:0", "Sine:1", "Cubic:7", "Quad:4") var flight_transition := 1
@export_range(0.0, 0.5) var draw_peel := 0.12
@export_range(0.0, 0.6) var prize_lift := 0.38
@export_range(0.0, 0.5) var play_lift := 0.24
@export_range(0.0, 0.1) var landing_rebound := 0.026
@export_range(0.0, 0.2) var landing_rock := 0.055
@export_range(0.0, 0.18) var shuffle_spread := 0.15
@export_range(0.0, 0.2) var shuffle_lift := 0.065
@export_range(1, 6) var coin_turns := 4
@export_range(0.0, 1.5) var coin_lift := 0.95
@export_range(0.5, 0.95) var coin_contact_fraction := 0.78

@export_group("Attribute Palette")
@export var element_colors: Dictionary = {
	"Grass": Color("559a55"), "Fire": Color("ed7835"),
	"Water": Color("369fc7"), "Lightning": Color("e0ad25"),
	"Psychic": Color("a870cb"), "Fighting": Color("ba7648"),
	"Darkness": Color("66517d"), "Metal": Color("769798"),
	"Dragon": Color("bda14a"), "Colorless": Color("a9987b"),
}
@export var neutral_color := Color("b09872")
@export_group("Quality")
@export var particle_counts: Dictionary = {"high": 24, "medium": 16, "low": 8}


func duration(kind: String, mode: String) -> float:
	return maxf(0.0, float(durations.get(kind, 0.0))) * float(mode_scales.get(mode, 0.82)) / 0.82


func element_color(element: String) -> Color:
	return element_colors.get(element, neutral_color) as Color
