class_name DotBrowserFavourites
extends RefCounted

## A player's saved servers and where they have been, on disk.
##
## Two lists that look the same and are not. A favourite is a deliberate act and is
## kept until it is removed; history is automatic, capped, and ordered by when a
## player last connected. Merging them produces a list that either forgets a
## favourite or grows without bound, and both have shipped.
##
## Stored as one JSON document under [code]user://[/code], written atomically and
## flushed — [code]user://[/code] on the web is an IndexedDB mirror that needs an
## explicit sync, and a favourite that survives a page reload only sometimes is worse
## than one that never does.

const CHANNEL := "browser"

const DEFAULT_PATH := "user://dot_browser/servers.json"

## Most history rows kept. Ten servers is a session; a thousand is a file a player's
## browser opens slower every week.
const MAX_HISTORY := 64

var path: String = DEFAULT_PATH

var _favourites: Dictionary = {}
var _history: Array[Dictionary] = []
var _loaded: bool = false


func _init(p_path: String = DEFAULT_PATH) -> void:
	path = p_path


func load_from_disk() -> DotResult:
	_loaded = true
	_favourites.clear()
	_history.clear()

	if not FileAccess.file_exists(path):
		# Not a failure. The first run of every game reaches this, and reporting it
		# as an error trains people to ignore the log that will one day say something.
		return DotResult.success(0)

	var read := DotPaths.read_json(path)
	if not read.ok:
		DotLog.warn(CHANNEL, "the saved server list could not be read", {
			"file": path, "error": str(read.error)
		})
		return read.wrap("Could not read the saved server list.")

	var data: Variant = read.value
	if typeof(data) != TYPE_DICTIONARY:
		DotLog.warn(CHANNEL, "the saved server list is not an object", {
			"file": path, "found": type_string(typeof(data))
		})
		return DotResult.fail(
			DotError.CODE_PARSE, "The saved server list is not an object.", path
		)

	var doc: Dictionary = data
	var loaded := 0
	var dropped := 0

	var saved: Variant = doc.get("favourites")
	if typeof(saved) == TYPE_ARRAY:
		for row in (saved as Array):
			if typeof(row) != TYPE_DICTIONARY:
				dropped += 1
				continue
			var parsed := DotBrowserEntry.from_dictionary(row as Dictionary)
			if not parsed.ok:
				dropped += 1
				continue
			var entry: DotBrowserEntry = parsed.value
			_favourites[entry.key()] = entry.to_dictionary()
			loaded += 1

	var past: Variant = doc.get("history")
	if typeof(past) == TYPE_ARRAY:
		for row in (past as Array):
			if typeof(row) != TYPE_DICTIONARY:
				dropped += 1
				continue
			_history.append((row as Dictionary).duplicate(true))

	_trim_history()

	# [b]A row this could not read is a server a player saved and will not see
	# again[/b], and the next [method save] writes the file back without it. Skipping
	# it is right -- one bad row must not cost somebody the other forty -- but doing it
	# in silence means the only evidence is a favourite that is simply gone, which
	# reads as the feature not working.
	if dropped > 0:
		DotLog.warn(CHANNEL, "saved servers could not be read and were dropped", {
			"dropped": dropped, "kept": loaded, "file": path
		})
	else:
		DotLog.debug(CHANNEL, "saved servers loaded", {
			"favourites": loaded, "history": _history.size(), "file": path
		})

	return DotResult.success(loaded)


func save() -> DotResult:
	var favourites: Array = []
	for key in _favourites.keys():
		favourites.append((_favourites[key] as Dictionary).duplicate(true))

	var written := DotPaths.write_json(path, {
		"version": 1,
		"favourites": favourites,
		"history": _history.duplicate(true),
	})

	if not written.ok:
		# [b]ERROR, where a refused favourite would be DEBUG.[/b] Nothing was wrong
		# with what was asked for -- the entry validated, it is in the list in memory,
		# and this addon then failed to make that survive the process. The caller is a
		# button somebody pressed, and the ones that exist drop this DotResult on the
		# floor: without a line here the whole symptom is favourites that are there
		# until the game is restarted.
		DotLog.error(CHANNEL, "the server list could not be saved", {
			"file": path, "favourites": favourites.size(), "error": str(written.error)
		})
		return written.wrap("Could not save the server list.")

	# user:// on the web is an IndexedDB mirror. Without this the file exists in the
	# tab and not in the browser's storage, and the first reload loses it.
	DotWeb.sync_filesystem()

	return DotResult.success(favourites.size())


## [b]The one caller that cannot report anything, which is why load_from_disk logs.[/b]
## Every read path goes through here and there is nowhere for a [DotResult] to go: a
## corrupt file makes `entries()` return an empty array, and an empty array is exactly
## what a player with no favourites gets.
func _ensure_loaded() -> void:
	if not _loaded:
		load_from_disk()


func add(entry: DotBrowserEntry) -> DotResult:
	_ensure_loaded()

	if entry == null or entry.target == null:
		return DotResult.fail(DotError.CODE_INVALID, "No server.")

	_favourites[entry.key()] = entry.to_dictionary()
	return save()


func remove(key: String) -> DotResult:
	_ensure_loaded()
	_favourites.erase(key)
	return save()


func has(key: String) -> bool:
	_ensure_loaded()
	return _favourites.has(key)


## Every favourite as an entry with no live data on it.
##
## [b]Targets, not results.[/b] What was saved is where a server was, not what it was
## doing — the player counts in the file are from whenever it was last seen and are
## there to draw something before the first refresh answers, not to be believed.
func entries() -> Array[DotBrowserEntry]:
	_ensure_loaded()

	var out: Array[DotBrowserEntry] = []
	for key in _favourites.keys():
		var parsed := DotBrowserEntry.from_dictionary(_favourites[key] as Dictionary)
		if parsed.ok:
			out.append(parsed.value)

	return out


func targets() -> Array[DotBrowserTarget]:
	var out: Array[DotBrowserTarget] = []
	for entry in entries():
		out.append(entry.target)
	return out


## The keys, for [method DotBrowserFilter.apply_sort].
func keys() -> Dictionary:
	_ensure_loaded()
	return _favourites.duplicate()


## Records that a player connected to a server.
func note_visit(entry: DotBrowserEntry) -> DotResult:
	_ensure_loaded()

	if entry == null or entry.target == null:
		return DotResult.fail(DotError.CODE_INVALID, "No server.")

	var key := entry.key()
	var row := entry.to_dictionary()
	row["last_played"] = int(Time.get_unix_time_from_system())

	for i in range(_history.size() - 1, -1, -1):
		var held: Dictionary = _history[i]
		var target: Variant = held.get("target")
		if typeof(target) == TYPE_DICTIONARY:
			var t: Dictionary = target
			if "%s:%d" % [str(t.get("address", "")), int(t.get("port", 0))] == key:
				_history.remove_at(i)

	_history.push_front(row)
	_trim_history()

	return save()


func history() -> Array[DotBrowserEntry]:
	_ensure_loaded()

	var out: Array[DotBrowserEntry] = []
	for row in _history:
		var parsed := DotBrowserEntry.from_dictionary(row)
		if parsed.ok:
			out.append(parsed.value)

	return out


func clear_history() -> DotResult:
	_ensure_loaded()
	_history.clear()
	return save()


func _trim_history() -> void:
	while _history.size() > MAX_HISTORY:
		_history.remove_at(_history.size() - 1)


func describe_lines() -> PackedStringArray:
	_ensure_loaded()
	var out := PackedStringArray()
	out.append("saved servers: %d favourites, %d in history" % [
		_favourites.size(), _history.size()
	])
	out.append("  file: %s" % path)
	return out
