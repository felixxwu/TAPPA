class_name NeutralFile
# Docs: features/level-editor.md — update in the same change as this file.
# Tests: tests/headless/test_neutral_file.gd — extend in the same change.
# The one container every neutral (Godot-free) export uses: u32 header length, a sorted JSON header, then each section as u32 raw size + one zstd frame, in header.sections order.

const FORMAT := 1


# `sections` is [[name, zipped], ...] with zipped from zip(); an optional third Dictionary adds fields to that section's header entry.
static func write(path: String, header: Dictionary, sections: Array) -> Error:
	var h := header.duplicate()
	h["format"] = FORMAT
	var entries := []
	for s: Array in sections:
		var entry := {"name": s[0], "bytes": (s[1] as PackedByteArray).size()}
		if s.size() > 2:
			entry.merge(s[2])
		entries.append(entry)
	h["sections"] = entries
	var head := JSON.stringify(h, "", true, true).to_utf8_buffer()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_32(head.size())
	f.store_buffer(head)
	for s: Array in sections:
		f.store_buffer(s[1])
	f.close()
	return OK


# An empty `raw` is just the 4-byte size 0 with no zstd frame after it.
static func zip(raw: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(4)
	out.encode_u32(0, raw.size())
	if not raw.is_empty():
		out.append_array(raw.compress(FileAccess.COMPRESSION_ZSTD))
	return out


static func sha256(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	if not bytes.is_empty():
		ctx.update(bytes)
	return ctx.finish().hex_encode()


# One parity manifest line: `file<TAB>field<TAB>value`, where a float is the hex of its 8 little-endian f64 bytes so formatting never differs.
static func line(file: String, field: String, value: Variant) -> String:
	var v: String
	match typeof(value):
		TYPE_FLOAT: v = PackedFloat64Array([value]).to_byte_array().hex_encode()
		TYPE_INT: v = str(value)
		TYPE_PACKED_BYTE_ARRAY: v = sha256(value)
		_: v = str(value)
	return "%s\t%s\t%s" % [file, field, v]
