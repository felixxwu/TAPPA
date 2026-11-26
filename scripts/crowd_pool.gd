class_name CrowdPool
extends RefCounted
# Docs: features/spectators.md — update in the same change as this file.
# Tests: tests/headless/test_level_spectators.gd — extend in the same change.
# One shared MultiMesh per character model for every crowd group of a level, so all crowds cost a draw call per model; groups lease slots and write their own transforms.

const HIDDEN := Transform3D(Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO), Vector3.ZERO)

var _parent: Node3D
var _meshes: Array[Mesh]
var _mms: Array[MultiMesh] = []
var _free: Array[PackedInt32Array] = []
var _xfs: Array = []  # per model, the transform of every slot, kept so growing can rewrite them


func _init(parent: Node3D, meshes: Array[Mesh]) -> void:
	_parent = parent
	_meshes = meshes
	for mesh in meshes:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Crowd%d" % _mms.size()
		mmi.multimesh = mm
		parent.add_child(mmi)
		_mms.append(mm)
		_free.append(PackedInt32Array())
		_xfs.append([])


func model_count() -> int:
	return _mms.size()


func multimesh(model: int) -> MultiMesh:
	return _mms[model]


func free_count(model: int) -> int:
	return _free[model].size()


# Leases `n` slots of `model`, growing its MultiMesh when too few are free.
func acquire(model: int, n: int) -> PackedInt32Array:
	var free := _free[model]
	if free.size() < n:
		_grow(model, n - free.size())
		free = _free[model]
	var out := PackedInt32Array()
	for _k in n:
		out.append(free[free.size() - 1])
		free.remove_at(free.size() - 1)
	return out


func release(model: int, slots: PackedInt32Array) -> void:
	for s in slots:
		set_xf(model, s, HIDDEN)
		_free[model].append(s)


# A slot's transform as last written; headless runs keep no MultiMesh data to read back.
func slot_xf(model: int, slot: int) -> Transform3D:
	return _xfs[model][slot]


func set_xf(model: int, slot: int, xf: Transform3D) -> void:
	_xfs[model][slot] = xf
	_mms[model].set_instance_transform(slot, xf)


func _grow(model: int, extra: int) -> void:
	var xfs: Array = _xfs[model]
	var old := xfs.size()
	var cap := maxi(old * 2, old + extra)
	xfs.resize(cap)
	for s in range(old, cap):
		xfs[s] = HIDDEN
		_free[model].append(s)
	var mm := _mms[model]
	mm.instance_count = cap
	for s in cap:
		mm.set_instance_transform(s, xfs[s])
