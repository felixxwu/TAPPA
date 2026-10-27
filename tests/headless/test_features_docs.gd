extends GutTest
# Guards the features/ docs: every repo path they cite (scripts/, tools/, data/, .github/) must exist,
# unless the line says the file is deleted.

const PATH_PATTERN := "(?:scripts|tools|data|\\.github)/[A-Za-z0-9_./-]+\\.[a-z0-9]+"


func test_every_cited_path_exists() -> void:
	var re := RegEx.create_from_string(PATH_PATTERN)
	var missing: Array[String] = []
	var dir := DirAccess.open("res://features")
	for file in dir.get_files():
		if not file.ends_with(".md"):
			continue
		var lines := FileAccess.get_file_as_string("res://features/" + file).split("\n")
		for i in lines.size():
			if lines[i].to_lower().contains("deleted"):
				continue
			for m in re.search_all(lines[i]):
				var path := m.get_string()
				if not FileAccess.file_exists("res://" + path):
					missing.append("%s:%d %s" % [file, i + 1, path])
	assert_eq(missing, [], "features/ cites files that do not exist")


func test_every_feature_doc_is_indexed_and_every_index_link_exists() -> void:
	var index := FileAccess.get_file_as_string("res://features/README.md")
	var dir := DirAccess.open("res://features")
	for file in dir.get_files():
		if file.ends_with(".md") and file != "README.md":
			assert_true(index.contains("(%s)" % file), "%s is not indexed in features/README.md" % file)
	var link := RegEx.create_from_string("\\]\\(([a-z0-9_-]+\\.md)\\)")
	for m in link.search_all(index):
		assert_true(FileAccess.file_exists("res://features/" + m.get_string(1)), "README links missing %s" % m.get_string(1))
