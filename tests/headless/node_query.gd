class_name NodeQuery
extends RefCounted
# Small read-only node-tree query helpers for menu/UI tests, which repeatedly
# hand-roll "walk the tree and collect the Buttons / find the label with this
# text". Centralising the recursion keeps those tests short and consistent.
#
# ADOPTION IS DEFERRED — this is added as a shared helper; existing UI tests are
# not rewritten to adopt it here. New tests are encouraged to use it.
#
# Usage:
#   const NodeQuery = preload("res://tests/headless/node_query.gd")
#   var start := NodeQuery.button_with_text(panel, "Start")
#   for text in NodeQuery.all_label_text(panel): ...


# The first descendant of `root` (depth-first, including `root` itself) that is
# of class/type `type_name` (e.g. "Button", "Label"); null if none.
static func first_of_type(root: Node, type_name: String) -> Node:
	if root == null:
		return null
	if root.is_class(type_name):
		return root
	for child in root.get_children():
		var found := first_of_type(child, type_name)
		if found != null:
			return found
	return null


# Every descendant of `root` (depth-first, including `root` itself) of
# class/type `type_name`, in tree order.
static func all_of_type(root: Node, type_name: String) -> Array:
	var out: Array = []
	if root == null:
		return out
	if root.is_class(type_name):
		out.append(root)
	for child in root.get_children():
		out.append_array(all_of_type(child, type_name))
	return out


# The first Button/BaseButton descendant whose `text` matches `text` (trimmed,
# case-sensitive); null if none. Accepts any button exposing a `text` property.
static func button_with_text(root: Node, text: String) -> Node:
	for b in all_of_type(root, "BaseButton"):
		if "text" in b and String(b.text).strip_edges() == text:
			return b
	return null


# The `text` of every Label descendant of `root`, in tree order (trimmed).
static func all_label_text(root: Node) -> Array:
	var out: Array = []
	for l in all_of_type(root, "Label"):
		out.append(String(l.text).strip_edges())
	return out
