extends Node

## Exercises dot-browser against golden bytes, hand-built responses and a real
## socket.
##
## Three kinds of check, and the first one is the point:
##
## [b]Golden bytes.[/b] This addon carries a second implementation of a wire format
## dot-server already implements, because naming its [code]class_name[/code] would
## make a server browser fail to parse without a dedicated server installed. Two
## implementations of one format is the shape this family has been bitten by
## repeatedly, so the fixtures below are [b]bytes dot-server's own encoder
## produced[/b], pasted in as hex. Checking this codec against itself would prove
## nothing at all.
##
## [b]Hand-built responses.[/b] A2S's shape — positional fields, a bitfield of
## extras, counts in single bytes — is where a query client goes wrong, so the parser
## is fed buffers written to the specification, including truncated ones.
##
## [b]A real socket.[/b] The last section boots a fake DQP server on the loopback and
## runs the whole browser through it. Every bug in this family that mattered was
## found by running something rather than by reading it.
##
## [codeblock]
## godot --headless --path . res://examples/browser_selftest.tscn
## [/codeblock]

const SECTIONS := 10
const CHECKS := 113

## Produced by dot-server's DotQueryProtocol.build_request(TYPE_QUERY, 7,
## 0x0123456789abcdef, {"sections": ["info"]}, true).
const GOLDEN_QUERY := "445150310104070000000000000001000000efcdab89674523017b2273656374696f6e73223a5b22696e666f225d7d"

## build_request(TYPE_PING, 1, 0, {}, false).
const GOLDEN_PING := "4451503103000100000000000000010000000000000000000000"

## build_challenge(7, 0x0123456789abcdef).
const GOLDEN_CHALLENGE := "445150318200070000000000000001000000efcdab8967452301"

## build(TYPE_RESULT, 7, 0, JSON of {"rev": 42}, 0, 99).
const GOLDEN_RESULT := "44515031810007000000630000000100000000000000000000007b22726576223a34327d"

const TEST_COOKIE := 0x0123456789abcdef

var _passed := 0
var _failed := 0
var _section_count := 0


## A DQP server on the loopback, in the smallest form that is still the protocol.
##
## Challenges, then answers. Deliberately built from this addon's own encoder rather
## than from dot-server's, because what this section tests is the socket path — the
## byte-level agreement is what the golden fixtures are for.
class FakeDqpServer extends Node:
	var socket: PacketPeerUDP = null
	var port: int = 0
	var body: Dictionary = {}
	var answer_challenge: bool = true
	var queries_seen: int = 0
	var last_if_rev: int = -1

	func _init() -> void:
		socket = PacketPeerUDP.new()

	func listen() -> bool:
		if socket.bind(0, "127.0.0.1") != OK:
			return false
		port = socket.get_local_port()
		return true

	func _process(_delta: float) -> void:
		while socket.get_available_packet_count() > 0:
			var data := socket.get_packet()
			var from := socket.get_packet_ip()
			var from_port := socket.get_packet_port()

			if not DotBrowserDqp.looks_like_dqp(data):
				continue

			var type := data.decode_u8(4)
			var txn := data.decode_u32(6)

			socket.set_dest_address(from, from_port)

			if type == DotBrowserDqp.TYPE_CHALLENGE_REQUEST:
				if not answer_challenge:
					continue
				socket.put_packet(_packet(
					DotBrowserDqp.TYPE_CHALLENGE, txn, 0x1122334455667788, PackedByteArray()
				))
				continue

			if type == DotBrowserDqp.TYPE_QUERY:
				queries_seen += 1
				var payload := data.slice(DotBrowserDqp.HEADER_BYTES)
				var parsed: Variant = JSON.parse_string(payload.get_string_from_utf8())
				if typeof(parsed) == TYPE_DICTIONARY:
					last_if_rev = int((parsed as Dictionary).get("if_rev", 0))
				socket.put_packet(_packet(
					DotBrowserDqp.TYPE_RESULT, txn, 0,
					JSON.stringify(body).to_utf8_buffer()
				))

	func _packet(
		type: int, txn: int, cookie: int, payload: PackedByteArray
	) -> PackedByteArray:
		var out := PackedByteArray()
		out.resize(DotBrowserDqp.HEADER_BYTES)
		out.encode_u8(0, 68)
		out.encode_u8(1, 81)
		out.encode_u8(2, 80)
		out.encode_u8(3, 49)
		out.encode_u8(4, type)
		out.encode_u8(5, 0)
		out.encode_u32(6, txn)
		out.encode_u32(10, 0)
		out.encode_u16(14, 1)
		out.encode_u16(16, 0)
		out.encode_u64(18, cookie)
		out.append_array(payload)
		return out

	func stop() -> void:
		if socket != null:
			socket.close()


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	await _run()


func _run() -> void:
	_line("dot-browser self-test")
	_line("")

	_test_golden_bytes()
	_test_dqp_fragments()
	_test_a2s_info()
	_test_a2s_split()
	_test_targets()
	_test_entries()
	_test_filter()
	_test_favourites()
	_test_sources()
	await _test_over_a_socket()

	_line("")
	_line("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])

	if _section_count != SECTIONS:
		_line("ERROR: %d of %d sections ran." % [_section_count, SECTIONS])
		get_tree().quit(1)
		return

	# The total the section counter cannot be. A runtime error inside a section aborts
	# that function, and the counter is satisfied because the section had already
	# announced itself. See docs/testing.md.
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


# --- The wire format, against dot-server's own bytes -----------------------

func _test_golden_bytes() -> void:
	_section("DQP: golden bytes from dot-server's encoder")

	var query := DotBrowserDqp.build_request(
		DotBrowserDqp.TYPE_QUERY, 7, TEST_COOKIE, {"sections": ["info"]}, true
	)
	_check(
		_hex(query) == GOLDEN_QUERY,
		"a query request is byte-identical to the one dot-server builds"
	)

	var ping := DotBrowserDqp.build_request(
		DotBrowserDqp.TYPE_PING, 1, 0, {}, false
	)
	_check(_hex(ping) == GOLDEN_PING, "so is a ping, with no accept-gzip bit")

	var challenge := DotBrowserDqp.parse(_bytes(GOLDEN_CHALLENGE))
	_check(challenge.ok, "a challenge response parses")
	var head: Dictionary = challenge.value
	_check(int(head["type"]) == DotBrowserDqp.TYPE_CHALLENGE, "as a challenge")
	_check(int(head["txn"]) == 7, "with the transaction echoed")
	_check(int(head["challenge"]) == TEST_COOKIE, "and the cookie read back whole")

	var result := DotBrowserDqp.parse(_bytes(GOLDEN_RESULT))
	_check(result.ok, "a result response parses")
	var body: Dictionary = (result.value as Dictionary)["body"]
	_check(int(body.get("rev", 0)) == 42, "and its JSON body comes out")

	var request_reply := DotBrowserDqp.parse(query)
	_check(
		not request_reply.ok,
		"a request arriving where a response was expected is refused, not answered"
	)

	var junk := DotBrowserDqp.parse("hello".to_utf8_buffer())
	_check(not junk.ok and junk.code() == DotError.CODE_PARSE, "junk is not DQP")


func _test_dqp_fragments() -> void:
	_section("DQP: fragments")

	var payload := JSON.stringify({"rev": 1, "pad": "x".repeat(3000)}).to_utf8_buffer()
	var fragments := _fragment(payload, 41, 0)

	_check(fragments.size() == 3, "a large body needs three datagrams")

	var shuffled: Array = [fragments[2], fragments[0], fragments[1]]
	var joined := DotBrowserDqp.reassemble(shuffled)
	_check(joined.ok, "they reassemble in any order")
	_check(
		int((joined.value as Dictionary).get("rev", 0)) == 1,
		"into the body that was sent"
	)

	# A querier refreshing two hundred servers has one socket receiving two hundred
	# replies. A fragment of another response must be discarded, not blended: the
	# result of blending is bytes that parse and are wrong.
	var foreign: PackedByteArray = _fragment(
		JSON.stringify({"rev": 999}).to_utf8_buffer(), 77, 0
	)[0]
	var polluted: Array = [fragments[0], foreign, fragments[1]]
	var refused := DotBrowserDqp.reassemble(polluted)
	_check(
		not refused.ok,
		"a fragment from another response is discarded rather than stitched in"
	)

	var short: Array = [fragments[0], fragments[1]]
	var incomplete := DotBrowserDqp.reassemble(short)
	_check(
		not incomplete.ok and incomplete.code() == DotError.CODE_TIMEOUT,
		"a missing fragment is a timeout, not a truncated body"
	)

	var packed := payload.compress(FileAccess.COMPRESSION_GZIP)
	var gzipped := _fragment(packed, 55, DotBrowserDqp.FLAG_GZIP)
	var inflated := DotBrowserDqp.reassemble(gzipped)
	_check(inflated.ok, "a gzip response reassembles and inflates")

	# This one makes the engine print "incorrect header check" and "Decompression
	# failed" on stderr. That is the engine reporting the refusal being asserted, not
	# a failure in the run — and it is noted here because this family's own rule is to
	# read a suite's stderr even when it exits 0, which means the noise a suite makes
	# on purpose has to be labelled or it costs somebody an afternoon.
	var lying := _fragment("not gzip at all".to_utf8_buffer(), 56, DotBrowserDqp.FLAG_GZIP)
	var failed := DotBrowserDqp.reassemble(lying)
	_check(
		not failed.ok,
		"a payload that claims gzip and is not fails rather than producing garbage"
	)


# --- A2S -------------------------------------------------------------------

func _test_a2s_info() -> void:
	_section("A2S: info")

	var data := _a2s_info(12, 32, 4, "dev,eu,dqp:27019")
	var parsed := DotBrowserA2s.parse_info(data)
	_check(parsed.ok, "an A2S_INFO response parses")

	var info: Dictionary = parsed.value
	_check(str(info["name"]) == "A dot server", "the name comes out")
	_check(str(info["map"]) == "dm_atrium", "so does the map")

	# The trap. A2S's player byte is humans + bots and has always been; a browser
	# that shows it shows a server with four bots and eight people as twelve
	# players, and the player who joins finds eight.
	_check(
		int(info["players"]) == 8,
		"the bot count is subtracted: A2S reports humans plus bots in one byte"
	)
	_check(int(info["bots"]) == 4, "and the bots are reported separately")
	_check(int(info["max_players"]) == 32, "the maximum is what it said")

	_check(str(info["server_type"]) == "dedicated", "the server type decodes")
	_check(str(info["os"]) == "linux", "so does the operating system")
	_check(str(info["visibility"]) == "public", "and the password flag")
	_check(int(info["port"]) == 27015, "the game port comes out of the extra data")

	var tags: PackedStringArray = info["tags"]
	_check(
		tags.size() == 2 and tags.has("dev") and tags.has("eu"),
		"keywords split into tags"
	)
	_check(
		int(info.get("dqp_port", 0)) == 27019,
		"and a dot server's richer protocol is found in the one extensible field"
	)

	var impossible := _a2s_info(2, 32, 9, "")
	var clamped: Dictionary = DotBrowserA2s.parse_info(impossible).value
	_check(
		int(clamped["players"]) == 0,
		"more bots than players clamps at zero rather than going negative"
	)

	# A response that ends early must fail rather than hand back a plausible value
	# for the field after the overrun. dot-net shipped a reader whose exhaustion was
	# not sticky and that is exactly what it did.
	var truncated := data.slice(0, 20)
	var short := DotBrowserA2s.parse_info(truncated)
	_check(
		not short.ok,
		"a response that ends early is refused, not read past"
	)

	var wrong := PackedByteArray([0xFF, 0xFF, 0xFF, 0xFF, 0x44])
	_check(
		not DotBrowserA2s.parse_info(wrong).ok,
		"a response of the wrong type is refused"
	)


func _test_a2s_split() -> void:
	_section("A2S: split packets")

	var whole := _a2s_info(1, 16, 0, "")
	var packets := _a2s_split(whole, 4242, 3)

	var shuffled: Array = [packets[1], packets[2], packets[0]]
	var joined := DotBrowserA2s.reassemble_split(shuffled)
	_check(joined.ok, "split packets reassemble in any order")
	_check(
		_hex(joined.value) == _hex(whole),
		"into exactly the single packet that was split, header included"
	)

	var foreign: PackedByteArray = _a2s_split(whole, 9999, 3)[1]
	var polluted: Array = [packets[0], foreign, packets[2]]
	_check(
		not DotBrowserA2s.reassemble_split(polluted).ok,
		"a packet from another split response is discarded"
	)

	var parsed := DotBrowserA2s.parse_info(joined.value)
	_check(parsed.ok, "and the reassembled bytes parse as info")


# --- The list model --------------------------------------------------------

func _test_targets() -> void:
	_section("targets")

	var plain := DotBrowserTarget.parse("example.com:27016")
	_check(plain.ok, "host:port parses")
	var t: DotBrowserTarget = plain.value
	_check(t.address == "example.com" and t.port == 27016, "into a host and a port")

	var bare := DotBrowserTarget.parse("example.com")
	_check(
		(bare.value as DotBrowserTarget).port == 27015,
		"a bare host takes the default port"
	)

	# Splitting on the last colon turns `[::1]:27015` into a host of `[` unless the
	# brackets are handled first, and splitting on the first turns every IPv6 address
	# into one.
	var six := DotBrowserTarget.parse("[::1]:27015")
	_check(six.ok, "a bracketed IPv6 address parses")
	var t6: DotBrowserTarget = six.value
	_check(t6.address == "::1" and t6.port == 27015, "into the address and the port")
	_check(t6.join_address() == "[::1]:27015", "and goes back into brackets to connect")

	var loose := DotBrowserTarget.parse("fe80::1")
	_check(
		(loose.value as DotBrowserTarget).address == "fe80::1",
		"an unbracketed IPv6 address is not mistaken for a port"
	)

	_check(not DotBrowserTarget.parse("").ok, "nothing is not an address")
	_check(not DotBrowserTarget.parse("host:99999").ok, "and that is not a port")

	var moved := DotBrowserTarget.make("h", 27015)
	moved.query_port = 27019
	_check(moved.effective_query_port() == 27019, "a query port overrides the game port")
	_check(
		moved.key() == "h:27015",
		"but identity is the game port: a moved query port must not make a second row"
	)

	var round_trip := DotBrowserTarget.from_dictionary(moved.to_dictionary())
	_check(round_trip.ok, "a target round-trips through its dictionary")
	_check(
		(round_trip.value as DotBrowserTarget).query_port == 27019,
		"with the query port intact"
	)

	_check(
		not DotBrowserTarget.from_dictionary(
			{"address": "h", "protocol": "carrier pigeon"}
		).ok,
		"an unknown protocol name is refused rather than defaulted"
	)


func _test_entries() -> void:
	_section("entries")

	var entry := DotBrowserEntry.of(DotBrowserTarget.make("127.0.0.1", 27015))
	_check(entry.status == DotBrowserEntry.Status.UNKNOWN, "an entry starts unknown")

	var applied := entry.apply_dqp({
		"rev": 12,
		"sections": {
			"info": {
				"name": "A dot server", "map": "dm_atrium", "game_id": "arena",
				"players": 8, "bots": 4, "connecting": 2, "max_players": 32,
				"tags": ["eu", "casual"], "visibility": "public",
			},
			"players": [{"name": "Ada", "score": 12, "duration": 91.0}],
			"rules": {"sv_tickrate": "128"},
			"game": {"round": 3},
		},
	})
	_check(applied.ok, "a DQP body applies")
	_check(entry.is_online(), "and marks the server online")
	_check(entry.players == 8 and entry.bots == 4, "players and bots stay separate")
	_check(entry.connecting == 2, "and so does the count A2S has no room for")
	_check(entry.slots_free() == 18, "free slots account for all three")
	_check(entry.player_list.size() == 1, "the roster comes out")
	_check(
		int((entry.rules.get("game", {}) as Dictionary).get("round", 0)) == 3,
		"the game's own section is kept whole rather than flattened into the rest"
	)
	_check(entry.rev == 12, "the revision is kept, for a conditional refresh")

	# An unchanged response carries the revision and nothing else. Applying it as if
	# it were a full one would blank every field — which is the exact failure a
	# conditional refresh exists to avoid.
	entry.apply_dqp({"rev": 12, "unchanged": true})
	_check(
		entry.name == "A dot server" and entry.players == 8,
		"an unchanged response leaves every field alone"
	)

	var name := entry.name
	var players := entry.players
	entry.mark_offline(DotError.make(DotError.CODE_TIMEOUT, "no answer"))
	_check(entry.status == DotBrowserEntry.Status.OFFLINE, "a timeout marks it offline")
	_check(
		entry.name == name and entry.players == players,
		"and leaves the last known figures alone: a row that flickers to zero on one "
		+ "dropped datagram is a row nobody trusts"
	)
	_check(entry.ping_ms == -1, "the ping, which is now unknown, is cleared")

	var long := DotBrowserEntry.of(DotBrowserTarget.make("h", 1))
	long.apply_dqp({"sections": {"info": {"name": "x".repeat(9000)}}})
	_check(
		long.name.length() <= DotBrowserEntry.MAX_TEXT,
		"a hostname from a stranger is capped on the way in"
	)

	var saved := DotBrowserEntry.from_dictionary(entry.to_dictionary())
	_check(saved.ok, "an entry round-trips through its saved form")
	_check(
		(saved.value as DotBrowserEntry).key() == entry.key(),
		"keeping its identity"
	)


func _test_filter() -> void:
	_section("filter and sort")

	var rows: Array[DotBrowserEntry] = [
		_row("a", 27001, "Alpha", "dm_one", 0, 16, 40, ["eu"]),
		_row("b", 27002, "Bravo", "dm_two", 12, 12, 80, ["eu", "hard"]),
		_row("c", 27003, "Cosmo", "dm_one", 4, 16, 20, ["na"]),
	]

	var never := _row("d", 27004, "Delta", "dm_one", 0, 16, -1, [])
	never.status = DotBrowserEntry.Status.ONLINE
	rows.append(never)

	var filter := DotBrowserFilter.new()

	filter.hide_empty = true
	var busy: Array[DotBrowserEntry] = []
	for row in rows:
		if filter.matches(row):
			busy.append(row)
	_check(busy.size() == 2, "hiding empty servers hides the empty ones")

	filter.hide_empty = false
	filter.hide_full = true
	var open: Array[DotBrowserEntry] = []
	for row in rows:
		if filter.matches(row):
			open.append(row)
	_check(open.size() == 3, "hiding full ones hides the full one")

	filter.hide_full = false
	filter.text = "cos"
	_check(filter.matches(rows[2]) and not filter.matches(rows[0]), "text matches a name")

	filter.text = ""
	filter.tags_all = PackedStringArray(["eu", "hard"])
	_check(
		filter.matches(rows[1]) and not filter.matches(rows[0]),
		"tags_all needs every tag"
	)

	filter.tags_all = PackedStringArray()
	filter.max_ping = 50
	_check(not filter.matches(rows[1]), "a ping ceiling excludes a distant server")
	_check(
		filter.matches(never),
		"and does not exclude one whose ping was never measured"
	)

	filter.max_ping = 0
	filter.sort = DotBrowserFilter.Sort.PING
	var ordered := rows.duplicate()
	filter.apply_sort(ordered)
	_check(
		ordered[0].name == "Cosmo",
		"sorting by ping puts the nearest first"
	)
	_check(
		ordered[ordered.size() - 1].name == "Delta",
		"and an unmeasured ping last, not first: -1 is not 'faster than everything'"
	)

	filter.sort = DotBrowserFilter.Sort.PLAYERS
	var busiest := rows.duplicate()
	filter.apply_sort(busiest)
	_check(busiest[0].name == "Bravo", "sorting by players puts the busiest first")

	var favourites := {"c:27003": true}
	filter.apply_sort(busiest, favourites)
	_check(
		busiest[0].name == "Cosmo",
		"favourites float to the top without disturbing the rest of the order"
	)
	_check(busiest[1].name == "Bravo", "which is still by players")

	# Two servers with the same ping must not swap places on every refresh, or the
	# row a player is about to click moves out from under them.
	var tied: Array[DotBrowserEntry] = [
		_row("z", 1, "Zed", "m", 1, 8, 30, []),
		_row("y", 1, "Why", "m", 1, 8, 30, []),
	]
	filter.sort = DotBrowserFilter.Sort.PING
	filter.apply_sort(tied)
	var first := tied[0].name
	filter.apply_sort(tied)
	_check(tied[0].name == first, "a tie breaks the same way every time")


func _test_favourites() -> void:
	_section("favourites and history")

	var path := "user://dot_browser_selftest/servers.json"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

	var saved := DotBrowserFavourites.new(path)
	_check(saved.load_from_disk().ok, "a missing file is not a failure on a first run")

	var entry := _row("h", 27015, "Home", "dm_one", 3, 16, 12, ["eu"])
	_check(saved.add(entry).ok, "a favourite saves")
	_check(saved.has("h:27015"), "and is remembered")

	var reloaded := DotBrowserFavourites.new(path)
	_check(reloaded.load_from_disk().ok, "the file reads back")
	_check(reloaded.has("h:27015"), "with the favourite in it")
	_check(
		(reloaded.entries()[0] as DotBrowserEntry).name == "Home",
		"and the name it was saved with"
	)

	reloaded.note_visit(entry)
	reloaded.note_visit(_row("i", 27016, "Away", "dm_two", 1, 8, 30, []))
	reloaded.note_visit(entry)
	_check(
		reloaded.history().size() == 2,
		"visiting the same server twice moves it rather than adding it again"
	)
	_check(
		(reloaded.history()[0] as DotBrowserEntry).name == "Home",
		"and the most recent is first"
	)

	for i in DotBrowserFavourites.MAX_HISTORY + 10:
		reloaded.note_visit(_row("p%d" % i, 1000 + i, "S%d" % i, "m", 0, 8, 10, []))
	_check(
		reloaded.history().size() == DotBrowserFavourites.MAX_HISTORY,
		"history is capped"
	)
	_check(reloaded.has("h:27015"), "and capping history does not touch a favourite")

	reloaded.remove("h:27015")
	_check(not reloaded.has("h:27015"), "a favourite can be removed")


func _test_sources() -> void:
	_section("sources")

	var list := DotBrowserSourceList.of(PackedStringArray([
		"127.0.0.1:27015", "example.com", "not a host:::", "",
	]))

	var res: DotResult = await list.fetch()
	_check(res.ok, "a list source with a bad entry in it still produces the good ones")

	var targets: Array = res.value
	_check(targets.size() == 2, "and only the good ones")
	_check(
		(targets[0] as DotBrowserTarget).source == &"list",
		"every target is stamped with the source that produced it"
	)

	var file_path := "user://dot_browser_selftest/list.json"
	DotPaths.write_json(file_path, [
		"10.0.0.1:27015",
		{"address": "10.0.0.2", "port": 27016, "query_port": 27019},
	])

	var from_file := DotBrowserSourceList.of_file(file_path)
	var loaded: DotResult = await from_file.fetch()
	_check(loaded.ok, "a list file loads")
	var rows: Array = loaded.value
	_check(rows.size() == 2, "both forms of entry")
	_check(
		(rows[1] as DotBrowserTarget).query_port == 27019,
		"including the object form's query port"
	)

	var missing := DotBrowserSourceList.of_file("user://nothing/here.json")
	var failed: DotResult = await missing.fetch()
	_check(not failed.ok and failed.code() == DotError.CODE_IO, "a missing file fails")

	var backbone := DotBrowserSourceBackbone.new()
	_check(not backbone.is_available(), "the backbone source is absent with no client")
	var refused: DotResult = await backbone.fetch()
	_check(
		not refused.ok and refused.code() == DotError.CODE_STATE,
		"and says so rather than producing an empty list that looks like no servers"
	)

	var base := DotBrowserSource.new()
	var unimplemented: DotResult = await base.fetch()
	_check(not unimplemented.ok, "the base source fetches nothing")


# --- Over a real socket ----------------------------------------------------

func _test_over_a_socket() -> void:
	_section("a real query over a real socket")

	if not DotPlatform.has_udp():
		_check(true, "skipped: this platform has no UDP")
		return

	var server := FakeDqpServer.new()
	if not server.listen():
		_check(false, "the fake server could not bind a loopback socket")
		return

	server.body = {
		"rev": 7,
		"sections": {
			"info": {
				"name": "Loopback", "map": "dm_one", "game_id": "arena",
				"players": 3, "bots": 1, "max_players": 16, "tags": ["test"],
			},
		},
	}
	add_child(server)

	var browser := DotBrowser.new()
	browser.register_as = &""
	browser.timeout_ms = 400
	browser.retries = 1
	browser.favourites_path = "user://dot_browser_selftest/live.json"
	add_child(browser)

	var target := DotBrowserTarget.make("127.0.0.1", server.port)
	target.protocol = DotBrowserTarget.Protocol.DQP

	var queried: DotResult = await browser.query(target)
	_check(queried.ok, "a query over the loopback answers")

	var entry: DotBrowserEntry = queried.value
	_check(entry.is_online(), "the server is online")
	_check(entry.name == "Loopback", "and said what it is")
	_check(entry.players == 3 and entry.bots == 1, "with its counts")
	_check(entry.ping_ms >= 0, "and a measured ping")
	_check(entry.answered_with == "dqp", "over DQP")

	# The second refresh sends the revision the entry already holds. A server with
	# nothing new answers in forty bytes; the point of the check is that the client
	# actually sends it, because a conditional refresh nobody makes conditional is a
	# feature that never once saves a byte.
	var before := server.queries_seen
	var again: DotResult = await browser.refresh_known()
	_check(again.ok, "a refresh of the known list runs")
	_check(server.queries_seen > before, "and asks again")
	_check(
		server.last_if_rev == 7,
		"sending the revision it already holds, so an unchanged server answers small"
	)

	var dead := DotBrowserTarget.make("127.0.0.1", 1)
	dead.protocol = DotBrowserTarget.Protocol.DQP
	var missed: DotResult = await browser.query(dead)
	_check(missed.ok, "a query to nothing still produces an entry")
	_check(
		not (missed.value as DotBrowserEntry).is_online(),
		"marked offline rather than left looking unasked"
	)

	# A refresh with several servers in it goes through the fan-out path — the one
	# GDScript has two wrong spellings for. It must finish rather than hang.
	for i in 6:
		var extra := DotBrowserTarget.make("127.0.0.1", 1 + i)
		extra.protocol = DotBrowserTarget.Protocol.DQP
		browser.add_target(extra)

	var many: DotResult = await browser.refresh_known()
	_check(many.ok, "a refresh of eight servers, most of them dead, finishes")
	_check(not browser.is_refreshing(), "and leaves nothing outstanding")
	_check(int(many.value) >= 1, "with the one live server still online")

	browser.queue_free()
	server.stop()
	server.queue_free()


# --- Fixtures --------------------------------------------------------------

func _row(
	host: String, port: int, name: String, map: String,
	players: int, max_players: int, ping: int, tags: Array
) -> DotBrowserEntry:
	var entry := DotBrowserEntry.of(DotBrowserTarget.make(host, port))
	entry.name = name
	entry.map = map
	entry.players = players
	entry.max_players = max_players
	entry.ping_ms = ping
	entry.status = DotBrowserEntry.Status.ONLINE
	for tag in tags:
		entry.tags.append(str(tag))
	return entry


## An A2S_INFO response, written the way the specification says and the way
## dot-server's A2S server writes one.
func _a2s_info(
	total_players: int, max_players: int, bots: int, keywords: String
) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u32(0xFFFFFFFF)
	buf.put_u8(DotBrowserA2s.RESPONSE_INFO)
	buf.put_u8(17)
	_cstring(buf, "A dot server")
	_cstring(buf, "dm_atrium")
	_cstring(buf, "dot")
	_cstring(buf, "Arena Deathmatch")
	buf.put_u16(0)
	# Written verbatim, because the byte on the wire is humans plus bots and the
	# point of the check is that the parser knows it.
	buf.put_u8(total_players)
	buf.put_u8(max_players)
	buf.put_u8(bots)
	buf.put_u8(0x64)
	buf.put_u8(0x6C)
	buf.put_u8(0)
	buf.put_u8(0)
	_cstring(buf, "0.1.0")

	var edf := DotBrowserA2s.EDF_PORT
	if keywords != "":
		edf |= DotBrowserA2s.EDF_KEYWORDS

	buf.put_u8(edf)
	buf.put_u16(27015)
	if keywords != "":
		_cstring(buf, keywords)

	return buf.data_array


func _a2s_split(whole: PackedByteArray, id: int, count: int) -> Array:
	var out: Array = []
	var size := int(ceil(float(whole.size()) / float(count)))

	for index in count:
		var start := index * size
		var chunk := whole.slice(start, mini(start + size, whole.size()))
		var packet := PackedByteArray()
		packet.resize(12)
		packet.encode_u32(0, 0xFFFFFFFE)
		packet.encode_u32(4, id)
		packet.encode_u8(8, count)
		packet.encode_u8(9, index)
		packet.encode_u16(10, size)
		packet.append_array(chunk)
		out.append(packet)

	return out


func _fragment(payload: PackedByteArray, response_id: int, flags: int) -> Array:
	var max_payload := DotBrowserDqp.MAX_DATAGRAM - DotBrowserDqp.HEADER_BYTES
	var total := maxi(1, int(ceil(float(payload.size()) / float(max_payload))))
	var out: Array = []

	if total > 1:
		flags |= DotBrowserDqp.FLAG_FRAGMENTED

	for index in total:
		var start := index * max_payload
		var chunk := payload.slice(start, mini(start + max_payload, payload.size()))
		var packet := PackedByteArray()
		packet.resize(DotBrowserDqp.HEADER_BYTES)
		packet.encode_u8(0, 68)
		packet.encode_u8(1, 81)
		packet.encode_u8(2, 80)
		packet.encode_u8(3, 49)
		packet.encode_u8(4, DotBrowserDqp.TYPE_RESULT)
		packet.encode_u8(5, flags)
		packet.encode_u32(6, 1)
		packet.encode_u32(10, response_id)
		packet.encode_u16(14, total)
		packet.encode_u16(16, index)
		packet.encode_u64(18, 0)
		packet.append_array(chunk)
		out.append(packet)

	return out


func _cstring(buf: StreamPeerBuffer, text: String) -> void:
	buf.put_data(text.to_utf8_buffer())
	buf.put_u8(0)


func _hex(bytes: PackedByteArray) -> String:
	var out := ""
	for byte in bytes:
		out += "%02x" % byte
	return out


func _bytes(hex: String) -> PackedByteArray:
	var out := PackedByteArray()
	var i := 0
	while i + 1 < hex.length():
		out.append(("0x" + hex.substr(i, 2)).hex_to_int())
		i += 2
	return out


# --- Harness ---------------------------------------------------------------

func _section(title: String) -> void:
	_section_count += 1
	_line("")
	_line("-- %s" % title)


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		_line("   ok   %s" % what)
	else:
		_failed += 1
		_line("  FAIL  %s" % what)


func _line(text: String) -> void:
	print(text)
