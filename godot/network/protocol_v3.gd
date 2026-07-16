class_name ProtocolV3
extends RefCounted

## Historical diagnostic marker only. Protocol v3 rooms and snapshots are not
## resumed because they cannot represent v4 hidden setup cards or draw results.
const VERSION := 3
const INCOMPATIBILITY_CODE := "protocol_v3_restore_unsupported"


static func diagnostic_error() -> Dictionary:
	return {
		"ok": false,
		"code": INCOMPATIBILITY_CODE,
		"message": "协议 v3 房间与当前规则不兼容，无法恢复，请创建新房间。",
	}
