class_name AIDecisionSeed
extends RefCounted

const FNV_OFFSET_BASIS := 2166136261
const FNV_PRIME := 16777619
const UINT32_MASK := 0xFFFFFFFF


## Stable, platform-independent seed for AI-only simulation. It is deliberately
## derived from immutable/request metadata and never reads the rules RNG.
static func derive(
	match_seed: int,
	revision: int,
	actor: int,
	request_type: String,
	request_id: String,
) -> int:
	var hash := FNV_OFFSET_BASIS
	hash = _mix_int(hash, match_seed)
	hash = _mix_int(hash, revision)
	hash = _mix_int(hash, actor)
	hash = _mix_string(hash, request_type)
	hash = _mix_string(hash, request_id)
	return PortableRandomSource.FALLBACK_SEED if hash == 0 else hash


static func _mix_int(hash: int, value: int) -> int:
	var normalized := value & UINT32_MASK
	for shift in [0, 8, 16, 24]:
		hash = _mix_byte(hash, (normalized >> int(shift)) & 0xFF)
	return _mix_byte(hash, 0xFF)


static func _mix_string(hash: int, value: String) -> int:
	for byte in value.to_utf8_buffer():
		hash = _mix_byte(hash, int(byte))
	return _mix_byte(hash, 0xFF)


static func _mix_byte(hash: int, value: int) -> int:
	return ((hash ^ value) * FNV_PRIME) & UINT32_MASK
