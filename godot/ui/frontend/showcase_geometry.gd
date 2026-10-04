class_name ShowcaseGeometry
extends RefCounted

## Rounded solids with actual bevel normals, rather than intersecting edge strips.
static func rounded_box(dimensions: Vector3, radius: float) -> ArrayMesh:
	var half := dimensions * 0.5
	var inner := half - Vector3.ONE * radius
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for axis in range(3):
		var u := (axis + 1) % 3
		var v := (axis + 2) % 3
		var us := _coordinates(half[u], radius)
		var vs := _coordinates(half[v], radius)
		for sign_value in [-1.0, 1.0]:
			var start := vertices.size()
			for y in range(vs.size()):
				for x in range(us.size()):
					var p := Vector3.ZERO
					p[axis] = half[axis] * sign_value
					p[u] = us[x]
					p[v] = vs[y]
					var core := p.clamp(-inner, inner)
					var normal := (p - core).normalized()
					vertices.append(core + normal * radius)
					normals.append(normal)
					uvs.append(Vector2(p[u] / dimensions[u] + 0.5, p[v] / dimensions[v] + 0.5))
			for y in range(vs.size() - 1):
				for x in range(us.size() - 1):
					var a := start + y * us.size() + x
					var b := a + 1
					var c := a + us.size() + 1
					var d := a + us.size()
					indices.append_array(PackedInt32Array([a, c, b, a, d, c] if sign_value > 0 else [a, b, c, a, c, d]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

static func _coordinates(half: float, radius: float) -> PackedFloat32Array:
	return PackedFloat32Array([-half, -half + radius * 0.134, -half + radius * 0.5,
		-half + radius, half - radius, half - radius * 0.5, half - radius * 0.134, half])


## A single instanced draw for all stitches; spacing carries across corners.
static func stitches(paths: Array[PackedVector3Array], material: Material) -> MultiMeshInstance3D:
	var transforms: Array[Transform3D] = []
	for path in paths:
		var remaining := 0.0
		for i in range(path.size() - 1):
			var start := path[i]
			var delta := path[i + 1] - start
			var length := delta.length()
			if length < 0.0001:
				continue
			var direction := delta / length
			while remaining + 0.024 <= length:
				transforms.append(Transform3D(Basis(Quaternion(Vector3.UP, direction)), start + direction * (remaining + 0.012)))
				remaining += 0.043
			remaining = maxf(0.0, remaining - length)
	var stitch := CapsuleMesh.new()
	stitch.radius = 0.0035
	stitch.height = 0.024
	stitch.radial_segments = 4
	stitch.rings = 1
	stitch.material = material
	var instances := MultiMesh.new()
	instances.transform_format = MultiMesh.TRANSFORM_3D
	instances.mesh = stitch
	instances.instance_count = transforms.size()
	for i in range(transforms.size()):
		instances.set_instance_transform(i, transforms[i])
	var node := MultiMeshInstance3D.new()
	node.multimesh = instances
	return node
