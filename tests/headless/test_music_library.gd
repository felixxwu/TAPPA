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
		assert_true(song["stream"] is AudioStream, who + " has an AudioStream")


func test_by_id_returns_a_real_catalogue_entry() -> void:
	var first_id: String = MusicLibrary.SONGS[0]["id"]
	var got := MusicLibrary.by_id(first_id)
	assert_eq(got, MusicLibrary.SONGS[0], "by_id returns the matching entry")


func test_by_id_unknown_returns_empty() -> void:
	assert_eq(MusicLibrary.by_id("no_such_song_xyz"), {}, "unknown id -> {}")


func test_context_songs_resolve_to_real_catalogue_entries() -> void:
	# The HQ and run context ids must point at real songs (contract, not pinning
	# which song or its bpm).
	assert_false(MusicLibrary.by_id(MusicLibrary.HQ_SONG).is_empty(),
		"HQ_SONG is a real catalogue entry")
	assert_false(MusicLibrary.by_id(MusicLibrary.RUN_SONG).is_empty(),
		"RUN_SONG is a real catalogue entry")


func test_song_for_scene_picks_hq_song_only_in_the_hq_scene() -> void:
	assert_eq(MusicLibrary.song_for_scene(MusicLibrary.HQ_SCENE), MusicLibrary.HQ_SONG,
		"the HQ scene plays the HQ song")
	# Anything that is not the HQ scene is a "run" context -> the run song.
	for other in ["res://main.tscn", "res://standings.tscn", "res://podium.tscn", ""]:
		assert_eq(MusicLibrary.song_for_scene(other), MusicLibrary.RUN_SONG,
			"non-HQ scene '%s' plays the run song" % other)
