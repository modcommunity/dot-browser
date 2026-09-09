class_name DotBrowser
extends Node

## A server list: where the servers are, what they are doing, and in what order to
## draw them.
##
## [b]The gap this fills.[/b] dot-server has answered queries since it was written —
## A2S for the twenty years of tooling that speaks nothing else, and its own richer
## protocol for everything else — and nothing in this family has ever asked one
## anything. A server that answers and a client that never asks is the family's most
## repeated shape, one level up: a whole protocol produced correctly and consumed by
## nobody.
##
## [codeblock]
## var browser := DotBrowser.new()
## browser.add_source(DotBrowserSourceList.of(PackedStringArray([
##     "eu1.example.com:27015", "127.0.0.1:27016",
## ])))
## browser.entry_updated.connect(_redraw_row)
## add_child(browser)
##
## await browser.refresh()
## for entry in browser.filtered():
##     print(entry.describe())
## [/codeblock]
##
## [b]Refreshing is a fan-out, and GDScript has one working shape for that.[/b] Both
## obvious spellings — appending coroutines to an array, or awaiting a completion
## signal per worker — are wrong, the second because a worker that finishes
## synchronously emits before the await exists and the wait never ends. So the
## queries are objects with a [code]poll()[/code], this node pumps them in
## [method _process], and the count of outstanding ones is a member. A query that
## fails instantly is already accounted for.

const CHANNEL := "browser"

const SERVICE := &"dot_browser"

## A refresh began. [param count] is how many servers will be asked.
signal refresh_started(count: int)

## One server answered, or did not.
signal entry_updated(entry: DotBrowserEntry)

## Every query in a refresh has finished.
signal refresh_finished(online: int, total: int)

## A source could not produce addresses. Not fatal: the others still run.
signal source_failed(source: StringName, error: DotError)

@export_group("Querying")

## How many queries may be outstanding at once.
##
## Eight is deliberately modest. A refresh is a burst of UDP to a great many
## addresses at once, which looks like a scan to anything watching a home
## connection — and a list of a thousand servers at full parallelism will lose
## replies to the receive buffer long before it saturates a link.
@export_range(1, 64, 1) var concurrency: int = 8

## Milliseconds to wait for each reply.
@export_range(200, 15000, 100) var timeout_ms: int = 2500

## Resends of an unanswered request. UDP loses packets, and a browser that reports a
## server offline because one datagram was dropped is one nobody trusts.
@export_range(0, 4, 1) var retries: int = 1

## Which DQP sections to ask for on a list refresh.
##
## [code]info[/code] only, by default. A response over 1174 bytes fragments, and a
## roster of forty players fragments; on a list of two hundred servers that is a lot
## of datagrams to lose one of. Ask for [code]players[/code] on the one server a
## player clicked, through [method query].
@export var sections: PackedStringArray = PackedStringArray(["info"])

## Send the revision an entry already holds, so an unchanged server answers in forty
## bytes rather than in a kilobyte.
@export var conditional: bool = true

@export_group("Integration")

@export var register_as: StringName = SERVICE

## Where favourites and history are kept. Empty uses the default under
## [code]user://[/code].
@export var favourites_path: String = ""

## What to show and in what order. Applied by [method filtered], never by the query.
var filter: DotBrowserFilter = null

var favourites: DotBrowserFavourites = null

var _entries: Dictionary = {}
var _order: Array[String] = []
var _pending: Array[DotBrowserTarget] = []
var _active: Array[_Attempt] = []
var _sources: Array[DotBrowserSource] = []
var _refreshing: bool = false
var _refresh_total: int = 0
var _started: bool = false


## One server's query, including the fallback from DQP to A2S.
##
## Kept as an object rather than as parallel arrays because "which protocol are we on
## for this address" is per address, and a browser that tracked it globally would
## fall back the whole list to A2S the first time one server was a Source server.
class _Attempt extends RefCounted:
	var entry: DotBrowserEntry = null
	var client: DotBrowserQuery = null
	var tried_dqp: bool = false
	var tried_a2s: bool = false
	var tried_web: bool = false

	func poll(now_ms: int) -> bool:
		if client == null:
			return true
		return client.poll(now_ms)

	func result() -> DotResult:
		if client == null:
			return DotResult.fail(DotError.CODE_INTERNAL, "No query was started.")
		return client.result

	func ping_ms() -> int:
		if client == null:
			return -1
		return client.ping_ms


func _ready() -> void:
	start()


func start() -> DotResult:
	if _started:
		return DotResult.success(self)

	if filter == null:
		filter = DotBrowserFilter.new()

	if favourites == null:
		favourites = DotBrowserFavourites.new(
			favourites_path if favourites_path != "" else DotBrowserFavourites.DEFAULT_PATH
		)

	if register_as != &"":
		DotRegistry.register(register_as, self)

	set_process(true)
	_started = true

	return DotResult.success(self)


# --- Sources ---------------------------------------------------------------

func add_source(source: DotBrowserSource) -> void:
	if source == null:
		return
	_sources.append(source)


func remove_source(source: DotBrowserSource) -> void:
	var index := _sources.find(source)
	if index >= 0:
		_sources.remove_at(index)


func sources() -> Array[DotBrowserSource]:
	return _sources.duplicate()


## Adds a target by hand — the "connect to this address" box.
func add_target(target: DotBrowserTarget) -> DotBrowserEntry:
	if target == null:
		return null

	var key := target.key()
	if _entries.has(key):
		return _entries[key]

	var entry := DotBrowserEntry.of(target)
	_entries[key] = entry
	_order.append(key)

	return entry


# --- Refreshing ------------------------------------------------------------

## Asks every source for addresses, then asks every address what it is.
##
## Returns when the last query has finished or timed out. Safe to call again while
## one is running: the second call is refused with [constant DotError.CODE_STATE]
## rather than doubling the outstanding queries, because a player holding the refresh
## button is the most ordinary input there is.
func refresh() -> DotResult:
	if not _started:
		start()

	if _refreshing:
		return DotResult.fail(
			DotError.CODE_STATE, "A refresh is already running."
		)

	for source in _sources:
		if not source.enabled:
			continue

		var res: DotResult = await source.fetch()
		if not res.ok:
			source_failed.emit(source.source_name(), res.error)
			DotLog.warn(CHANNEL, "a server source failed", {
				"source": String(source.source_name()), "error": str(res.error)
			})
			continue

		for target in (res.value as Array):
			add_target(target as DotBrowserTarget)

	return await refresh_known()


## Re-queries every server already in the list, asking no source for more.
##
## What a periodic refresh calls. A master server is polled far less often than the
## servers themselves: the list of who exists changes in minutes and what they are
## doing changes in seconds.
func refresh_known() -> DotResult:
	if not _started:
		start()

	if _refreshing:
		return DotResult.fail(DotError.CODE_STATE, "A refresh is already running.")

	_pending.clear()
	for key in _order:
		var entry: DotBrowserEntry = _entries[key]
		_pending.append(entry.target)

	_refresh_total = _pending.size()
	refresh_started.emit(_refresh_total)

	if _refresh_total == 0:
		# Emitted anyway. A caller that only ever hears about a refresh that had work
		# to do cannot tell "finished with nothing" from "never started".
		refresh_finished.emit(0, 0)
		return DotResult.success(0)

	_refreshing = true
	_fill_active()

	# The await goes here and not earlier. _fill_active() can complete every query
	# before this line on a loopback, which is the case that hangs a fan-out written
	# the obvious way; _refreshing is checked first so the await is skipped entirely.
	if _refreshing:
		await refresh_finished

	return DotResult.success(_online_count())


## Queries one server directly, with whatever sections the caller wants.
##
## For the server a player clicked, which is where a roster is worth a round trip.
func query(
	target: DotBrowserTarget, want: PackedStringArray = PackedStringArray()
) -> DotResult:
	if not _started:
		start()

	var entry := add_target(target)
	if entry == null:
		return DotResult.fail(DotError.CODE_INVALID, "No target.")

	var attempt := _begin(entry, want if not want.is_empty() else sections)

	while not attempt.poll(Time.get_ticks_msec()):
		await get_tree().process_frame

	_apply(attempt)
	return DotResult.success(entry)


func _process(_delta: float) -> void:
	if _active.is_empty():
		return

	var now := Time.get_ticks_msec()

	for i in range(_active.size() - 1, -1, -1):
		var attempt: _Attempt = _active[i]
		if not attempt.poll(now):
			continue

		if _should_fall_back(attempt):
			_fall_back(attempt)
			continue

		_active.remove_at(i)
		_apply(attempt)

	if not _refreshing:
		return

	_fill_active()

	if _active.is_empty() and _pending.is_empty():
		_refreshing = false
		refresh_finished.emit(_online_count(), _refresh_total)


func _fill_active() -> void:
	while _active.size() < concurrency and not _pending.is_empty():
		var target: DotBrowserTarget = _pending.pop_front()
		var entry: DotBrowserEntry = _entries[target.key()]
		_begin(entry, sections)


func _begin(entry: DotBrowserEntry, want: PackedStringArray) -> _Attempt:
	var attempt := _Attempt.new()
	attempt.entry = entry

	var protocol := entry.target.protocol

	if protocol == DotBrowserTarget.Protocol.AUTO:
		# A browser build has no UDP at all, so AUTO there means the WebSocket form.
		# Asking about the capability rather than the platform name is the family
		# rule, and here it is also the only correct question: a desktop export with
		# UDP blocked by a firewall is in the same position.
		protocol = (
			DotBrowserTarget.Protocol.DQP if DotPlatform.has_udp()
			else DotBrowserTarget.Protocol.DQP_WEB
		)

	match protocol:
		DotBrowserTarget.Protocol.A2S:
			attempt.tried_a2s = true
			var a2s := DotBrowserA2sClient.new(entry.target)
			a2s.timeout_ms = timeout_ms
			a2s.retries = retries
			a2s.want_players = want.has("players")
			attempt.client = a2s
			a2s.begin()

		DotBrowserTarget.Protocol.DQP_WEB:
			attempt.tried_web = true
			var ws := DotBrowserWsClient.new(entry.target)
			ws.timeout_ms = timeout_ms * 2
			ws.sections = want
			ws.if_rev = entry.rev if conditional else 0
			attempt.client = ws
			ws.begin()

		_:
			attempt.tried_dqp = true
			var dqp := DotBrowserDqpClient.new(entry.target)
			dqp.timeout_ms = timeout_ms
			dqp.retries = retries
			dqp.sections = want
			dqp.if_rev = entry.rev if conditional else 0
			attempt.client = dqp
			dqp.begin()

	_active.append(attempt)
	return attempt


## Whether a failed DQP attempt should be retried as A2S.
##
## Only on AUTO, only once, and only for a timeout or a parse failure — never for a
## refusal. A server that answered DQP with an error understood the question, and
## asking it again in another protocol doubles the traffic to a server that already
## said no.
func _should_fall_back(attempt: _Attempt) -> bool:
	if attempt.entry.target.protocol != DotBrowserTarget.Protocol.AUTO:
		return false
	if attempt.tried_a2s or not DotPlatform.has_udp():
		return false

	var res := attempt.result()
	if res == null or res.ok:
		return false

	return res.code() == DotError.CODE_TIMEOUT or res.code() == DotError.CODE_PARSE


func _fall_back(attempt: _Attempt) -> void:
	attempt.tried_a2s = true

	var a2s := DotBrowserA2sClient.new(attempt.entry.target)
	a2s.timeout_ms = timeout_ms
	a2s.retries = retries
	a2s.want_players = sections.has("players")
	attempt.client = a2s
	a2s.begin()


func _apply(attempt: _Attempt) -> void:
	var entry := attempt.entry
	var res := attempt.result()

	if res == null:
		entry.mark_offline(DotError.make(
			DotError.CODE_INTERNAL, "The query produced no result."
		))
		entry_updated.emit(entry)
		return

	if not res.ok:
		entry.mark_offline(res.error)
		entry_updated.emit(entry)
		return

	entry.ping_ms = attempt.ping_ms()

	var value: Variant = res.value

	if attempt.tried_a2s:
		var body: Dictionary = value
		var info: Variant = body.get("info")
		if typeof(info) == TYPE_DICTIONARY:
			entry.apply_a2s(info as Dictionary)
		var players: Variant = body.get("players")
		if typeof(players) == TYPE_ARRAY:
			entry.apply_a2s_players(players as Array)
	else:
		var applied := entry.apply_dqp(value as Dictionary)
		if not applied.ok:
			entry.mark_offline(applied.error)

	entry_updated.emit(entry)


func _online_count() -> int:
	var total := 0
	for key in _order:
		if (_entries[key] as DotBrowserEntry).is_online():
			total += 1
	return total


## Stops every outstanding query.
##
## What a player leaving the browser screen calls. Without it a refresh of two
## hundred servers keeps a socket open per outstanding query for as long as the
## timeouts last, on a screen nobody is looking at.
func cancel() -> void:
	for attempt in _active:
		if attempt.client != null:
			attempt.client.close()

	_active.clear()
	_pending.clear()

	if _refreshing:
		_refreshing = false
		refresh_finished.emit(_online_count(), _refresh_total)


func is_refreshing() -> bool:
	return _refreshing


# --- Reading ---------------------------------------------------------------

func entries() -> Array[DotBrowserEntry]:
	var out: Array[DotBrowserEntry] = []
	for key in _order:
		out.append(_entries[key])
	return out


func entry_for(key: String) -> DotBrowserEntry:
	if _entries.has(key):
		return _entries[key]
	return null


func count() -> int:
	return _order.size()


## The rows to draw: filtered and ordered.
func filtered() -> Array[DotBrowserEntry]:
	var saved := favourites.keys()
	var out: Array[DotBrowserEntry] = []

	for key in _order:
		var entry: DotBrowserEntry = _entries[key]
		if filter.matches(entry, saved.has(key)):
			out.append(entry)

	filter.apply_sort(out, saved)
	return out


func clear() -> void:
	cancel()
	_entries.clear()
	_order.clear()


# --- Favourites ------------------------------------------------------------

func favourite(key: String) -> DotResult:
	var entry := entry_for(key)
	if entry == null:
		return DotResult.fail(DotError.CODE_INVALID, "No such server.", key)
	return favourites.add(entry)


func unfavourite(key: String) -> DotResult:
	return favourites.remove(key)


func is_favourite(key: String) -> bool:
	return favourites.has(key)


## Adds every saved favourite to the list, so they are drawn before any refresh.
func load_favourites() -> int:
	var added := 0
	for target in favourites.targets():
		if not _entries.has(target.key()):
			add_target(target)
			added += 1
	return added


func note_connected(key: String) -> DotResult:
	var entry := entry_for(key)
	if entry == null:
		return DotResult.fail(DotError.CODE_INVALID, "No such server.", key)
	return favourites.note_visit(entry)


func _exit_tree() -> void:
	cancel()
	if register_as != &"":
		DotRegistry.unregister_instance(register_as, self)


func describe() -> Dictionary:
	return {
		"servers": _order.size(),
		"online": _online_count(),
		"sources": _sources.size(),
		"refreshing": _refreshing,
		"outstanding": _active.size() + _pending.size(),
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("server browser: %d servers, %d online, %d sources" % [
		_order.size(), _online_count(), _sources.size()
	])
	out.append("  filter: %s" % filter.describe())

	for entry in filtered():
		out.append("  " + entry.describe())

	if favourites != null:
		out.append_array(favourites.describe_lines())

	return out
