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
		# Each song is a sequence of segment streams (4 bars in / 8 main / 4 out).
		var segs: Array = song["segments"]
		assert_gt(segs.size(), 0, who + " has at least one segment")
		for seg in segs:
			assert_true(seg is AudioStream, who + " segment is an AudioStream")


func test_segment_count_matches_the_segments_array() -> void:
	for song in MusicLibrary.SONGS:
		assert_eq(MusicLibrary.segment_count(String(song["id"])), (song["segments"] as Array).size(),
			"segment_count matches the segments array")
	assert_eq(MusicLibrary.segment_count("no_such_song"), 0, "unknown song -> 0 segments")


func test_by_id_returns_a_real_catalogue_entry() -> void:
	var first_id: String = MusicLibrary.SONGS[0]["id"]
	var got := MusicLibrary.by_id(first_id)
	assert_eq(got, MusicLibrary.SONGS[0], "by_id returns the matching entry")


func test_by_id_unknown_returns_empty() -> void:
	assert_eq(MusicLibrary.by_id("no_such_song_xyz"), {}, "unknown id -> {}")


func test_context_songs_resolve_to_real_catalogue_entries() -> void:
	# The HQ song and every rally-pool id must point at real songs (contract, not
	# pinning which song or its bpm).
	assert_false(MusicLibrary.by_id(MusicLibrary.HQ_SONG).is_empty(),
		"HQ_SONG is a real catalogue entry")
	for id in MusicLibrary.RALLY_SONGS:
		assert_false(MusicLibrary.by_id(id).is_empty(),
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
