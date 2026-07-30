extends GutTest
# MusicLibrary is the song catalogue. Tests assert the DATA CONTRACT (shape),
# iterating SONGS as opaque data — never that a specific song exists or has a
# specific bpm (those are authored values a designer may change).


func test_catalogue_entries_are_well_formed() -> void:
	assert_gt(MusicLibrary.SONGS.size(), 0, "catalogue is non-empty")
	var ids := {}
	for song in MusicLibrary.SONGS:
		var who: String = song.get("id", "?")
		assert_false(ids.has(song["id"]), "id '%s' is unique" % who)
		ids[song["id"]] = true
		assert_ne(String(song["id"]), "", who + " has a non-empty id")
		assert_gt(song["bpm"], 0.0, who + " has positive bpm")  # sanity guard, not a pinned value
		# Each song is a sequence of segment PATHS (4 bars in / 8 main / 4 out),
		# loaded lazily by by_id.
		var paths: Array = song["segment_paths"]
		assert_gt(paths.size(), 0, who + " has at least one segment")
		for path in paths:
			assert_true(ResourceLoader.exists(String(path)),
				"%s segment path '%s' exists" % [who, path])


func test_segment_count_matches_the_segments_array() -> void:
	for song in MusicLibrary.SONGS:
		assert_eq(MusicLibrary.segment_count(String(song["id"])),
			(song["segment_paths"] as Array).size(),
			"segment_count matches the segments array")
	assert_eq(MusicLibrary.segment_count("no_such_song"), 0, "unknown song -> 0 segments")


func test_by_id_returns_a_real_catalogue_entry() -> void:
	var first_id: String = MusicLibrary.SONGS[0]["id"]
	var got := MusicLibrary.by_id(first_id)
	assert_eq(String(got.get("id", "")), first_id, "by_id returns the matching entry")
	assert_eq(got.get("bpm"), MusicLibrary.SONGS[0]["bpm"], "with the authored bpm")


func test_by_id_loads_the_segment_streams() -> void:
	var id: String = MusicLibrary.SONGS[0]["id"]
	var segs: Array = MusicLibrary.by_id(id)["segments"]
	assert_eq(segs.size(), (MusicLibrary.SONGS[0]["segment_paths"] as Array).size(),
		"every authored segment path resolved to a stream")
	for seg in segs:
		assert_true(seg is AudioStream, "a loaded segment is an AudioStream")


func test_loaded_segments_are_cached_across_requests() -> void:
	MusicLibrary.clear_cache()
	var id: String = MusicLibrary.SONGS[0]["id"]
	var first: Array = MusicLibrary.by_id(id)["segments"]
	var second: Array = MusicLibrary.by_id(id)["segments"]
	assert_eq(first, second, "the same segment array is handed back, not re-loaded")
	for i in first.size():
		assert_true(first[i] == second[i], "segment %d is the same stream object" % i)


func test_reading_the_catalogue_does_not_load_any_audio() -> void:
	# The whole point of the lazy table: the Music autoload touches MusicLibrary at
	# boot, and that must not pull every segment of every song into memory.
	MusicLibrary.clear_cache()
	for song in MusicLibrary.SONGS:
		var _paths: Array = song["segment_paths"]
		var _n := MusicLibrary.segment_count(String(song["id"]))
		var _raw := MusicLibrary.entry_of(String(song["id"]))
		assert_false(MusicLibrary.is_loaded(String(song["id"])),
			"reading '%s' as data did not load its streams" % song["id"])
	# Only the song actually asked for by_id gets loaded.
	var wanted: String = MusicLibrary.SONGS[0]["id"]
	MusicLibrary.by_id(wanted)
	assert_true(MusicLibrary.is_loaded(wanted), "the requested song is loaded")
	for song in MusicLibrary.SONGS:
		if String(song["id"]) == wanted:
			continue
		assert_false(MusicLibrary.is_loaded(String(song["id"])),
			"unrequested song '%s' stayed unloaded" % song["id"])


func test_by_id_unknown_returns_empty() -> void:
	assert_eq(MusicLibrary.by_id("no_such_song_xyz"), {}, "unknown id -> {}")


func test_context_songs_resolve_to_real_catalogue_entries() -> void:
	# Every HQ-pool and rally-pool id must point at real songs (contract, not
	# pinning which song or its bpm).
	for id in MusicLibrary.HQ_SONGS:
		assert_false(MusicLibrary.entry_of(id).is_empty(),
			"HQ song '%s' is a real catalogue entry" % id)
	for id in MusicLibrary.RALLY_SONGS:
		assert_false(MusicLibrary.entry_of(id).is_empty(),
			"rally song '%s' is a real catalogue entry" % id)


func test_is_hq_scene_only_true_for_the_hq_scene() -> void:
	assert_true(MusicLibrary.is_hq_scene(MusicLibrary.HQ_SCENE), "the HQ scene is the HQ")
	for other in ["res://main.tscn", "res://standings.tscn", "res://podium.tscn", ""]:
		assert_false(MusicLibrary.is_hq_scene(other), "non-HQ scene '%s' is not the HQ" % other)


func test_random_rally_song_is_always_a_pool_member() -> void:
	for i in 50:
		assert_true(MusicLibrary.RALLY_SONGS.has(MusicLibrary.random_rally_song()),
			"a random rally song is a member of the pool")


func test_random_rally_song_avoids_the_excluded_id() -> void:
	# With a >1 pool, the excluded id (the song just played) never comes back.
	var exclude: String = MusicLibrary.RALLY_SONGS[0]
	for i in 50:
		assert_ne(MusicLibrary.random_rally_song(exclude), exclude,
			"random_rally_song must not return the excluded id")


func test_random_hq_song_is_always_a_pool_member() -> void:
	for i in 50:
		assert_true(MusicLibrary.HQ_SONGS.has(MusicLibrary.random_hq_song()),
			"a random HQ song is a member of the pool")


func test_random_hq_song_avoids_the_excluded_id() -> void:
	# With a >1 pool, the excluded id (the song just played) never comes back.
	var exclude: String = MusicLibrary.HQ_SONGS[0]
	for i in 50:
		assert_ne(MusicLibrary.random_hq_song(exclude), exclude,
			"random_hq_song must not return the excluded id")
