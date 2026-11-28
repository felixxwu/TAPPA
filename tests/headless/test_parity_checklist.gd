extends GutTest
# Guards the Rust-migration parity checklist (todo/2026-11-28-parity-checklist.md): every feature doc needs a row,
# and nothing the checklist names may point at a file that no longer exists.

const CHECKLIST := "res://todo/2026-11-28-parity-checklist.md"
const ROW_PATTERN := "^\\| \\[([a-z0-9_-]+\\.md)\\]"
const SCRIPT_PATTERN := "scripts/[A-Za-z0-9_./-]+\\.gd"


func _rows() -> Array[String]:
	var re := RegEx.create_from_string(ROW_PATTERN)
	var out: Array[String] = []
	for line in FileAccess.get_file_as_string(CHECKLIST).split("\n"):
		var m := re.search(line)
		if m != null:
			out.append(m.get_string(1))
	return out


func test_every_feature_doc_has_a_row() -> void:
	var rows := _rows()
	var missing: Array[String] = []
	for file in DirAccess.open("res://features").get_files():
		if file.ends_with(".md") and file != "README.md" and not rows.has(file):
			missing.append(file)
	assert_eq(missing, [], "features/ docs with no row in the parity checklist")


func test_every_row_names_an_existing_feature_doc() -> void:
	var gone: Array[String] = []
	for file in _rows():
		if not FileAccess.file_exists("res://features/" + file):
			gone.append(file)
	assert_eq(gone, [], "parity checklist rows for feature docs that do not exist")


func test_every_cited_script_exists() -> void:
	var re := RegEx.create_from_string(SCRIPT_PATTERN)
	var gone: Array[String] = []
	for m in re.search_all(FileAccess.get_file_as_string(CHECKLIST)):
		if not FileAccess.file_exists("res://" + m.get_string()):
			gone.append(m.get_string())
	assert_eq(gone, [], "parity checklist cites scripts that do not exist")
