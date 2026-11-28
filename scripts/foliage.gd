class_name Foliage
extends RefCounted
# Docs: features/trees.md — update in the same change as this file.
# Tests: tests/headless/test_foliage.gd — extend in the same change.
# The star card mesh the level's trees are drawn on (LevelTrees and the level bake).

# Six vertical cards through the trunk at 60 degree steps, each showing its own frame of the
# tree's 6-frame atlas texture (tools/tree_lab.html). Seen from behind, a card shows its frame
# mirrored, which is intended.
const STAR_CARDS := 6


static func _alpha_card_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var corners := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 0), Vector2(1, 1), Vector2(0, 1)]
	for i in STAR_CARDS:
		var theta := deg_to_rad(i * 60.0)
		var right := Vector3(cos(theta), 0.0, -sin(theta))
		var normal := Vector3(sin(theta), 0.0, cos(theta))
		for uv: Vector2 in corners:
			st.set_uv(Vector2((i + uv.x) / STAR_CARDS, uv.y))
			st.set_normal(normal)
			st.add_vertex(right * (uv.x - 0.5) + Vector3(0.0, 1.0 - uv.y, 0.0))
	return st.commit()
