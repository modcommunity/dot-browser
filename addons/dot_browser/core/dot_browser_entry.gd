class_name DotBrowserEntry
extends RefCounted

## One row in a server browser: what a server said about itself, plus what asking it
## cost.
##
## Filled from a DQP body or an A2S response, and once filled the two are
## indistinguishable — a browser sorts, filters and draws one shape. The A2S path
## fills fewer fields, and the ones it cannot fill stay at their defaults rather than
## being invented.
##
## [b]Every string in here came off a socket from an address a stranger supplied.[/b]
## Names, maps and tags are capped on the way in, and a browser drawing them through
## a [RichTextLabel] must escape them for exactly dot-chat's reason.

## What the last query said.
enum Status {
	UNKNOWN,    ## Never asked.
	ONLINE,     ## Answered.
	OFFLINE,    ## Did not answer in time.
	REFUSED,    ## Answered with an error, or with something unparseable.
}

## Longest string kept from a response. A hostname of forty kilobytes is not a
## hostname, and a list holding two hundred of them is a list holding eight megabytes
## of somebody else's choosing.
const MAX_TEXT := 128

## Most player rows kept from one response.
const MAX_PLAYERS_LISTED := 128

var target: DotBrowserTarget = null

var status: Status = Status.UNKNOWN

## The failure from the last attempt, when [member status] is not
## [constant Status.ONLINE].
var error: DotError = null

var name: String = ""
var map: String = ""
var game: String = ""
var game_id: String = ""
var version: String = ""
var folder: String = ""

## Humans. [b]Never humans plus bots[/b] — see [DotBrowserA2s.parse_info].
var players: int = 0
var bots: int = 0

## Connected but not yet playing: authenticating, downloading or loading.
##
## DQP's own field, and the one A2S has no room for. It is the difference between
## "empty server" and "server nobody can finish joining", and a browser that cannot
## show it cannot show the second.
var connecting: int = 0

var max_players: int = 0
var reserved_slots: int = 0

var tags: PackedStringArray = PackedStringArray()
var visibility: String = ""
var server_type: String = ""
var os: String = ""
var secure: bool = false
var tickrate: int = 0
var transport: String = ""

## The revision the server last reported, for a conditional refresh.
##
## DQP's cheapest feature: send it back as [code]if_rev[/code] and a server that has
## not changed answers in forty bytes. A list of a thousand servers refreshed every
## thirty seconds costs almost nothing on either end.
var rev: int = 0
var etag: String = ""

var rules: Dictionary = {}
var player_list: Array[Dictionary] = []

## Round-trip time in milliseconds, or -1 when it was never measured.
var ping_ms: int = -1

var last_seen: int = 0

## Which protocol actually answered.
var answered_with: String = ""


static func of(target_: DotBrowserTarget) -> DotBrowserEntry:
	var out := DotBrowserEntry.new()
	out.target = target_
	return out


func key() -> String:
	return target.key() if target != null else ""


func join_address() -> String:
	return target.join_address() if target != null else ""


func slots_free() -> int:
	return maxi(0, max_players - players - bots - connecting)


func is_full() -> bool:
	return max_players > 0 and slots_free() <= 0


func is_empty() -> bool:
	return players == 0


func needs_password() -> bool:
	return visibility == "password"


func is_online() -> bool:
	return status == Status.ONLINE


## Fills from a DQP response body — the whole document, sections and all.
func apply_dqp(body: Dictionary) -> DotResult:
	# An unchanged response carries the revision and nothing else. Overwriting the
	# fields from it would blank every one of them, which is the failure mode a
	# conditional refresh exists to avoid.
	if bool(body.get("unchanged", false)):
		status = Status.ONLINE
		last_seen = int(Time.get_unix_time_from_system())
		answered_with = "dqp"
		return DotResult.success(self)

	var sections: Variant = body.get("sections")
	if typeof(sections) != TYPE_DICTIONARY:
		return DotResult.fail(
			DotError.CODE_PARSE, "The query response carried no sections."
		)

	var doc: Dictionary = sections

	if doc.has("info") and typeof(doc["info"]) == TYPE_DICTIONARY:
		_apply_info(doc["info"] as Dictionary)

	if doc.has("players") and typeof(doc["players"]) == TYPE_ARRAY:
		_apply_players(doc["players"] as Array)

	if doc.has("rules") and typeof(doc["rules"]) == TYPE_DICTIONARY:
		rules = (doc["rules"] as Dictionary).duplicate(true)

	if doc.has("game") and typeof(doc["game"]) == TYPE_DICTIONARY:
		# The game's own section — a round number, team scores, a ready count. Kept
		# whole under one key rather than flattened, because a browser cannot know
		# what a game will put in it and flattening would collide with the fields
		# above the first time one was called `map`.
		rules["game"] = (doc["game"] as Dictionary).duplicate(true)

	rev = int(body.get("rev", 0))
	etag = _clip(str(body.get("etag", "")))
	status = Status.ONLINE
	error = null
	answered_with = "dqp"
	last_seen = int(Time.get_unix_time_from_system())

	return DotResult.success(self)


## Fills from [method DotBrowserA2s.parse_info]'s dictionary.
func apply_a2s(info: Dictionary) -> DotResult:
	_apply_info(info)

	# A2S carries a port in its extra data, and it is the *game* port. If a server
	# answered on a query port that differs, this is what says where a player
	# actually connects — and it is the only place that says so.
	if info.has("port") and target != null and int(info["port"]) > 0:
		target.port = int(info["port"])

	if info.has("dqp_port") and target != null:
		target.query_port = int(info["dqp_port"])

	status = Status.ONLINE
	error = null
	answered_with = "a2s"
	last_seen = int(Time.get_unix_time_from_system())

	return DotResult.success(self)


func apply_a2s_players(rows: Array) -> void:
	_apply_players(rows)


func mark_offline(err: DotError) -> void:
	status = Status.OFFLINE if err.code == DotError.CODE_TIMEOUT else Status.REFUSED
	error = err
	ping_ms = -1

	# The player counts are deliberately left where they were. A row that goes to
	# zero players the moment one refresh is dropped flickers on every list, and a
	# stale count beside an "offline" marker is more honest than a fresh zero.


func _apply_info(info: Dictionary) -> void:
	name = _clip(str(info.get("name", name)))
	map = _clip(str(info.get("map", map)))
	game = _clip(str(info.get("game", game)))
	game_id = _clip(str(info.get("game_id", game_id)))
	version = _clip(str(info.get("version", version)))
	folder = _clip(str(info.get("folder", folder)))

	players = maxi(0, int(info.get("players", players)))
	bots = maxi(0, int(info.get("bots", bots)))
	connecting = maxi(0, int(info.get("connecting", connecting)))
	max_players = maxi(0, int(info.get("max_players", max_players)))
	reserved_slots = maxi(0, int(info.get("reserved_slots", reserved_slots)))

	visibility = _clip(str(info.get("visibility", visibility)))
	server_type = _clip(str(info.get("server_type", server_type)))
	os = _clip(str(info.get("os", os)))
	secure = bool(info.get("secure", secure))
	tickrate = int(info.get("tickrate", tickrate))
	transport = _clip(str(info.get("transport", transport)))

	var raw_tags: Variant = info.get("tags")
	if typeof(raw_tags) == TYPE_ARRAY or typeof(raw_tags) == TYPE_PACKED_STRING_ARRAY:
		var out := PackedStringArray()
		for tag in (raw_tags as Array):
			out.append(_clip(str(tag)))
		tags = out

	var query: Variant = info.get("query")
	if typeof(query) == TYPE_DICTIONARY and target != null:
		var q: Dictionary = query
		if int(q.get("port", 0)) > 0:
			target.query_port = int(q["port"])


func _apply_players(rows: Array) -> void:
	var out: Array[Dictionary] = []

	for entry in rows:
		if out.size() >= MAX_PLAYERS_LISTED:
			break
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var row: Dictionary = entry
		out.append({
			"name": _clip(str(row.get("name", ""))),
			"score": int(row.get("score", 0)),
			"duration": float(row.get("duration", 0.0)),
			"bot": bool(row.get("bot", false)),
			"ping": int(row.get("ping", 0)),
		})

	player_list = out


static func _clip(text: String) -> String:
	if text.length() <= MAX_TEXT:
		return text
	return text.substr(0, MAX_TEXT)


## The persisted form, for favourites and history. Not a query response.
func to_dictionary() -> Dictionary:
	var out := {
		"target": target.to_dictionary() if target != null else {},
		"name": name,
		"map": map,
		"game": game,
		"game_id": game_id,
		"players": players,
		"max_players": max_players,
		"last_seen": last_seen,
	}
	if not tags.is_empty():
		out["tags"] = Array(tags)
	return out


static func from_dictionary(data: Dictionary) -> DotResult:
	var raw: Variant = data.get("target")
	if typeof(raw) != TYPE_DICTIONARY:
		return DotResult.fail(DotError.CODE_PARSE, "An entry needs a target.")

	var parsed := DotBrowserTarget.from_dictionary(raw as Dictionary)
	if not parsed.ok:
		return parsed

	var out := DotBrowserEntry.of(parsed.value)
	out.name = _clip(str(data.get("name", "")))
	out.map = _clip(str(data.get("map", "")))
	out.game = _clip(str(data.get("game", "")))
	out.game_id = _clip(str(data.get("game_id", "")))
	out.players = int(data.get("players", 0))
	out.max_players = int(data.get("max_players", 0))
	out.last_seen = int(data.get("last_seen", 0))

	var tags_raw: Variant = data.get("tags")
	if typeof(tags_raw) == TYPE_ARRAY:
		for tag in (tags_raw as Array):
			out.tags.append(_clip(str(tag)))

	return DotResult.success(out)


func status_name() -> String:
	return ["unknown", "online", "offline", "refused"][int(status)]


func describe() -> String:
	if status != Status.ONLINE:
		return "%s  [%s]" % [join_address(), status_name()]

	return "%-22s %-24s %-16s %2d/%-2d %4d ms" % [
		join_address(), name.substr(0, 24), map.substr(0, 16),
		players, max_players, ping_ms
	]


func _to_string() -> String:
	return "DotBrowserEntry(%s)" % describe()
