class_name UILayoutPolicy
extends RefCounted

## One desktop composition, with continuously fitted dimensions. Inputs are
## logical safe-content sizes; only canvas_size() accepts physical window pixels.
const DESIGN_SIZE := Vector2i(1600, 900)
const MINIMUM_SIZE := Vector2i(1024, 720)
const WINDOW_MINIMUM := Vector2i(640, 540)
const SAFE_MARGIN := Vector2i(18, 14)
const TOUCH_MIN := 48.0


static func canvas_size(window_size: Vector2i, design_size := DESIGN_SIZE) -> Vector2i:
	if window_size.x < 320 or window_size.y < 240:
		return design_size
	if window_size.x < MINIMUM_SIZE.x or window_size.y < MINIMUM_SIZE.y:
		return MINIMUM_SIZE
	var fit := minf(float(window_size.x) / design_size.x, float(window_size.y) / design_size.y)
	return window_size if fit < 1.0 else design_size


static func density(available: Vector2) -> float:
	# Include a 48 px inset on every side at the smallest supported tablet size.
	return clampf(minf((available.x - 928.0) / 636.0, (available.y - 624.0) / 248.0), 0.0, 1.0)


static func fit(available: Vector2, minimum: float, desktop: float) -> float:
	return lerpf(minimum, desktop, density(available))


static func fit_int(available: Vector2, minimum: float, desktop: float) -> int:
	return roundi(fit(available, minimum, desktop))


static func content_margin(available: Vector2, maximum_width: float, minimum := 16.0, desktop := 24.0) -> int:
	return roundi(maxf(fit(available, minimum, desktop), (available.x - maximum_width) * 0.5))


static func modal_inset(available: Vector2) -> Vector2:
	return Vector2(fit(available, 24.0, 96.0), fit(available, 24.0, 72.0))


static func battle_detail_width(available: Vector2) -> float:
	return clampf(available.x * 0.27, 240.0, 420.0)


static func battle_prize_width(available: Vector2, preferred: float) -> float:
	# The mirrored Prize rows bound the desktop reading corridor vertically.
	# Keep a readable preview between them even at 720p with device insets.
	return minf(preferred, maxf(TOUCH_MIN, (available.y - 480.0) * 0.29))
