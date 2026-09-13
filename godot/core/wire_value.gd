class_name WireValue
extends RefCounted

## Native DTOs carry int64 values; JSON-decoded floats must be exact int32 values.
## Keep booleans, fractions and non-finite numbers out of integer fields.
static func is_integer(value: Variant) -> bool:
	if value is int:
		return true
	return (
		value is float
		and is_finite(value)
		and value >= -2147483648.0
		and value <= 2147483647.0
		and value == floorf(value)
	)
