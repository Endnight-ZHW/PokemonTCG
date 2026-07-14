class_name CardDragSession
extends RefCounted

const CANDIDATE := "candidate"
const DRAGGING := "dragging"
const AWAITING_VARIANT := "awaiting_variant"
const PENDING_AUTHORITY := "pending_authority"
const COMMITTED := "committed"
const RETURNING := "returning"
const CANCELLED := "cancelled"

var session_id := ""
var state := CANDIDATE
var revision := -1
var actor := -1
var hand_index := -1
var card_id := ""
var visual_id := ""
var source_view: CardView
var source_position := Vector2.ZERO
var source_size := Vector2.ZERO
var source_rotation := 0.0
var grab_offset := Vector2.ZERO
var release_position := Vector2.ZERO
var target_player := -1
var target_slot := ""
var origin_action_id := ""
var proxy: Control


func matches(index: int, id: String, current_revision: int) -> bool:
	return hand_index == index and card_id == id and revision == current_revision


func is_pending() -> bool:
	return state in [AWAITING_VARIANT, PENDING_AUTHORITY, COMMITTED]
