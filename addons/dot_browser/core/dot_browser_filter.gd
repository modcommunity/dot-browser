@tool
class_name DotBrowserFilter
extends Resource

## What a player wants to see, and in what order.
##
## Everything here is applied locally to entries that have already answered. A filter
## is not a query: a server does not get to decide whether it matches, which is what
## stops a server that lies about its player count from also deciding it belongs at
## the top of the list.

enum Sort {
	PING,          ## Nearest first. What most players want and the default.
	PLAYERS,       ## Busiest first.
	PLAYERS_ASC,   ## Emptiest first, for somebody who wants a quiet server.
	NAME,
	MAP,
	SLOTS_FREE,    ## Most room first.
}

@export_group("Text")

## Matched case-insensitively against the name, the map and the game.
@export var text: String = ""

## Exact map id. Empty matches every map.
@export var map: String = ""

@export var game_id: String = ""

@export_group("Occupancy")

## Hide servers with nobody on them.
##
## [b]Counts humans.[/b] A server with eight bots is empty as far as a player looking
## for a game is concerned, and A2S's player byte includes them — which is why
## [DotBrowserEntry.players] is the subtracted number.
@export var hide_empty: bool = false

## Hide servers a player cannot get into.
@export var hide_full: bool = false

@export var hide_password: bool = false

@export_range(0, 128, 1) var min_players: int = 0

@export_group("Quality")

## Milliseconds. 0 means no ceiling.
##
## Applied only to entries whose ping was measured. An unmeasured ping is -1, and
## treating that as "faster than anything" would float every server nobody has
## reached to the top of a list sorted by ping.
@export_range(0, 1000, 5) var max_ping: int = 0

## Every one of these must be present in the server's tags.
@export var tags_all: PackedStringArray = PackedStringArray()

## At least one of these must be. Empty matches everything.
@export var tags_any: PackedStringArray = PackedStringArray()

## Exact version. For a game whose protocol changed.
@export var version: String = ""

## Only entries that answered.
@export var online_only: bool = true

@export_group("Order")

@export var sort: Sort = Sort.PING

## Favourites first, whatever the sort says.
##
## Not a sort mode of its own: a player who has favourited four servers wants those
## four at the top *and* the rest in their chosen order, and a "favourites" sort would
## leave the other two hundred in whatever order they arrived.
@export var favourites_first: bool = true


func matches(entry: DotBrowserEntry, is_favourite: bool = false) -> bool:
	if online_only and not entry.is_online():
		return false

	if text != "":
		var needle := text.to_lower()
		var haystack := "%s %s %s" % [entry.name, entry.map, entry.game]
		if not haystack.to_lower().contains(needle):
			return false

	if map != "" and entry.map.to_lower() != map.to_lower():
		return false

	if game_id != "" and entry.game_id != game_id:
		return false

	if version != "" and entry.version != version:
		return false

	if hide_empty and entry.players <= 0:
		return false

	if hide_full and entry.is_full():
		return false

	if hide_password and entry.needs_password():
		return false

	if entry.players < min_players:
		return false

	if max_ping > 0 and entry.ping_ms >= 0 and entry.ping_ms > max_ping:
		return false

	for tag in tags_all:
		if not _has_tag(entry, str(tag)):
			return false

	if not tags_any.is_empty():
		var any := false
		for tag in tags_any:
			if _has_tag(entry, str(tag)):
				any = true
				break
		if not any:
			return false

	# The favourite flag is read for ordering, not for filtering, unless a caller
	# asked for it. Kept as a parameter rather than a field on the entry because
	# whether something is a favourite belongs to the player, not to the server.
	if is_favourite:
		return true

	return true


func _has_tag(entry: DotBrowserEntry, tag: String) -> bool:
	var wanted := tag.to_lower()
	for held in entry.tags:
		if str(held).to_lower() == wanted:
			return true
	return false


## Orders [param entries] in place under [member sort].
##
## [param favourites] is the set of keys to float, when [member favourites_first].
func apply_sort(entries: Array[DotBrowserEntry], favourites: Dictionary = {}) -> void:
	var mode := sort
	var float_favourites := favourites_first and not favourites.is_empty()

	entries.sort_custom(func(a: DotBrowserEntry, b: DotBrowserEntry) -> bool:
		if float_favourites:
			var fa := favourites.has(a.key())
			var fb := favourites.has(b.key())
			if fa != fb:
				return fa

		match mode:
			Sort.PING:
				# An unmeasured ping sorts last rather than first. -1 is "we do not
				# know", and a browser that reads it as zero puts every server nobody
				# has reached above every server somebody has.
				var pa := a.ping_ms if a.ping_ms >= 0 else 1 << 30
				var pb := b.ping_ms if b.ping_ms >= 0 else 1 << 30
				if pa != pb:
					return pa < pb
			Sort.PLAYERS:
				if a.players != b.players:
					return a.players > b.players
			Sort.PLAYERS_ASC:
				if a.players != b.players:
					return a.players < b.players
			Sort.SLOTS_FREE:
				if a.slots_free() != b.slots_free():
					return a.slots_free() > b.slots_free()
			Sort.NAME:
				if a.name != b.name:
					return a.name.nocasecmp_to(b.name) < 0
			Sort.MAP:
				if a.map != b.map:
					return a.map.nocasecmp_to(b.map) < 0

		# One stable tie-break for every mode. Without it two servers with the same
		# ping swap places on every refresh and the row a player was about to click
		# moves out from under them.
		return a.key() < b.key()
	)


func sort_name() -> String:
	return ["ping", "players", "players_asc", "name", "map", "slots_free"][int(sort)]


func describe() -> String:
	var parts := PackedStringArray()
	if text != "":
		parts.append("text=%s" % text)
	if map != "":
		parts.append("map=%s" % map)
	if hide_empty:
		parts.append("not empty")
	if hide_full:
		parts.append("not full")
	if max_ping > 0:
		parts.append("ping<=%d" % max_ping)
	parts.append("sort=%s" % sort_name())
	return ", ".join(Array(parts))
