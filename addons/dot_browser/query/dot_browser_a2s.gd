class_name DotBrowserA2s
extends RefCounted

## The client half of A2S, the twenty-year-old query protocol.
##
## A2S is here for one reason and it is a good enough one: every server-list site,
## chat bot and uptime monitor on earth speaks it, and a great many servers speak
## nothing else. A browser that cannot ask an A2S server anything is a browser that
## shows an empty row for a server that is full.
##
## It is also a protocol whose fields are positional, whose optional extras are
## selected by a bitfield, whose counts are single bytes, and whose multi-packet
## format differs between engine branches. Everything unpleasant in this file is
## unpleasant in the protocol.
##
## [b]The trap worth naming.[/b] A2S's player-count byte is
## [code]humans + bots[/code] — Source has always written it that way and dot-server
## writes it that way — while the bot count has a byte of its own. A browser that
## shows the first number shows a server with eight bots and no people as an
## eight-player server, and the player who joins it finds nobody there.
## [method parse_info] subtracts, and reports [code]players[/code] as humans.

const HEADER_SINGLE := 0xFFFFFFFF
const HEADER_MULTI := 0xFFFFFFFE

const REQUEST_INFO := 0x54            ## 'T'
const REQUEST_PLAYER := 0x55          ## 'U'
const REQUEST_RULES := 0x56           ## 'V'
const REQUEST_PING := 0x69            ## 'i'

const RESPONSE_INFO := 0x49           ## 'I'
const RESPONSE_PLAYER := 0x44         ## 'D'
const RESPONSE_RULES := 0x45          ## 'E'
const RESPONSE_CHALLENGE := 0x41      ## 'A'
const RESPONSE_PING := 0x6A           ## 'j'

## The A2S_INFO payload byte-for-byte.
##
## Part of the wire format rather than a description of anything, so it is spelled
## exactly as the protocol spells it: a server receiving anything else is not being
## asked in A2S, and will answer nothing. dot-server's own responder carries the same
## constant with the same note.
const INFO_PAYLOAD := "Source Engine Query"

const EDF_GAME_ID := 0x01
const EDF_STEAM_ID := 0x10
const EDF_KEYWORDS := 0x20
const EDF_SPECTATOR := 0x40
const EDF_PORT := 0x80

## A response is never allowed to become more than this many packets.
const MAX_SPLIT_PACKETS := 8

## An empty challenge, which is what a first request carries. The server answers
## with [constant RESPONSE_CHALLENGE] and the request is repeated.
const NO_CHALLENGE := -1


static func build_info(challenge: int = NO_CHALLENGE) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u32(HEADER_SINGLE)
	buf.put_u8(REQUEST_INFO)
	buf.put_data(INFO_PAYLOAD.to_utf8_buffer())
	buf.put_u8(0)

	# A2S_INFO gained a challenge in 2020, after years of being a reflection
	# amplifier. A server old enough not to challenge simply answers the first
	# request, so sending none the first time costs nothing either way.
	if challenge != NO_CHALLENGE:
		buf.put_u32(challenge)

	return buf.data_array


static func build_player(challenge: int) -> PackedByteArray:
	return _challenged(REQUEST_PLAYER, challenge)


static func build_rules(challenge: int) -> PackedByteArray:
	return _challenged(REQUEST_RULES, challenge)


static func build_ping() -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u32(HEADER_SINGLE)
	buf.put_u8(REQUEST_PING)
	return buf.data_array


static func _challenged(request: int, challenge: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u32(HEADER_SINGLE)
	buf.put_u8(request)
	buf.put_u32(challenge if challenge != NO_CHALLENGE else 0xFFFFFFFF)
	return buf.data_array


## Whether a datagram is a whole single-packet A2S response.
static func is_single(data: PackedByteArray) -> bool:
	return data.size() >= 5 and data.decode_u32(0) == HEADER_SINGLE


static func is_split(data: PackedByteArray) -> bool:
	return data.size() >= 12 and data.decode_u32(0) == HEADER_MULTI


## The response type byte of a single packet, or -1.
static func response_type(data: PackedByteArray) -> int:
	if not is_single(data):
		return -1
	return data.decode_u8(4)


## The challenge in an [constant RESPONSE_CHALLENGE] packet, or
## [constant NO_CHALLENGE].
static func challenge_of(data: PackedByteArray) -> int:
	if response_type(data) != RESPONSE_CHALLENGE or data.size() < 9:
		return NO_CHALLENGE
	return int(data.decode_u32(5))


## Reads one split-packet header. Returns
## [code]{id, total, index, payload}[/code], or an empty dictionary.
##
## This is the uncompressed Source format, which is what dot-server writes. The
## compressed variant carries two extra fields on the first packet only and is
## deliberately not supported: the branches that use it are the branches whose
## multi-packet framing has been the single most common source of broken query
## clients for twenty years, and a browser that guesses wrong shows garbage rather
## than nothing.
static func parse_split_header(data: PackedByteArray) -> Dictionary:
	if not is_split(data):
		return {}

	return {
		"id": int(data.decode_u32(4)),
		"total": int(data.decode_u8(8)),
		"index": int(data.decode_u8(9)),
		"size": int(data.decode_u16(10)),
		"payload": data.slice(12),
	}


## Joins split packets. The reassembled bytes are a complete single packet,
## [code]FF FF FF FF[/code] included, which is what every A2S client expects.
static func reassemble_split(packets: Array) -> DotResult:
	if packets.is_empty():
		return DotResult.fail(DotError.CODE_PARSE, "No packets.")

	var head := parse_split_header(packets[0] as PackedByteArray)
	if head.is_empty():
		return DotResult.fail(DotError.CODE_PARSE, "Not a split A2S packet.")

	var total := int(head["total"])
	var id := int(head["id"])

	if total <= 0 or total > MAX_SPLIT_PACKETS:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A split response claimed %d packets; the ceiling is %d." % [
				total, MAX_SPLIT_PACKETS
			]
		)

	var chunks: Dictionary = {}

	for entry in packets:
		var part := parse_split_header(entry as PackedByteArray)
		if part.is_empty():
			continue
		# Same rule as DQP's response id, and for the same reason: a socket refreshing
		# a list receives interleaved replies, and a piece of one response stitched
		# into another produces bytes that parse.
		if int(part["id"]) != id or int(part["total"]) != total:
			continue
		chunks[int(part["index"])] = part["payload"]

	if chunks.size() != total:
		return DotResult.fail(
			DotError.CODE_TIMEOUT,
			"Incomplete split response: %d of %d." % [chunks.size(), total]
		)

	var out := PackedByteArray()
	for index in range(total):
		out.append_array(chunks[index] as PackedByteArray)

	return DotResult.success(out)


# --- Bodies ----------------------------------------------------------------

## Parses an [code]A2S_INFO[/code] response.
##
## The returned dictionary uses DQP's field names, not A2S's, so a
## [DotBrowserEntry] does not care which protocol answered it.
static func parse_info(data: PackedByteArray) -> DotResult:
	if response_type(data) != RESPONSE_INFO:
		return DotResult.fail(DotError.CODE_PARSE, "Not an A2S_INFO response.")

	var reader := _Reader.new(data, 5)

	var out := {
		"protocol": reader.u8(),
		"name": reader.cstring(),
		"map": reader.cstring(),
		"folder": reader.cstring(),
		"game": reader.cstring(),
	}

	var app_id := reader.u16()
	var total_players := reader.u8()
	var max_players := reader.u8()
	var bots := reader.u8()
	var server_type := reader.u8()
	var environment := reader.u8()
	var visibility := reader.u8()
	var vac := reader.u8()

	out["version"] = reader.cstring()

	if not reader.ok:
		return DotResult.fail(
			DotError.CODE_PARSE, "The A2S_INFO response ended early."
		)

	# The subtraction this protocol's shape makes necessary. Clamped at zero because
	# a server whose bot byte exceeds its player byte is describing something
	# impossible, and a negative player count would sort to the top of a browser.
	out["bots"] = bots
	out["players"] = maxi(0, total_players - bots)
	out["max_players"] = max_players
	out["app_id"] = app_id
	out["server_type"] = "dedicated" if server_type == 0x64 else "listen"
	out["os"] = _os_name(environment)
	out["visibility"] = "password" if visibility == 1 else "public"
	out["secure"] = vac == 1

	var edf := reader.u8()
	if reader.ok and edf != 0:
		if edf & EDF_PORT:
			out["port"] = reader.u16()
		if edf & EDF_STEAM_ID:
			reader.skip(8)
		if edf & EDF_SPECTATOR:
			reader.skip(2)
			reader.cstring()
		if edf & EDF_KEYWORDS:
			var keywords := reader.cstring()
			out["keywords"] = keywords
			out["tags"] = _tags_of(keywords)
			var dqp := _dqp_port_of(keywords)
			if dqp > 0:
				# A dot server advertises its richer protocol in the one extensible
				# field A2S has. A browser that notices can stop guessing.
				out["dqp_port"] = dqp
		if edf & EDF_GAME_ID:
			reader.skip(8)

	return DotResult.success(out)


## Parses an [code]A2S_PLAYER[/code] response into DQP-shaped player rows.
static func parse_players(data: PackedByteArray) -> DotResult:
	if response_type(data) != RESPONSE_PLAYER:
		return DotResult.fail(DotError.CODE_PARSE, "Not an A2S_PLAYER response.")

	var reader := _Reader.new(data, 5)
	var count := reader.u8()
	var out: Array[Dictionary] = []

	for i in count:
		reader.skip(1)
		var name := reader.cstring()
		var score := reader.i32()
		var duration := reader.f32()
		if not reader.ok:
			# Truncated rather than fatal. A2S's count byte is unreliable by its own
			# specification and a partial roster is more useful than none — but the
			# rows that were read are the rows that were on the wire, not zeros.
			break
		out.append({"name": name, "score": score, "duration": duration})

	return DotResult.success(out)


## Parses an [code]A2S_RULES[/code] response into [code]name -> value[/code].
static func parse_rules(data: PackedByteArray) -> DotResult:
	if response_type(data) != RESPONSE_RULES:
		return DotResult.fail(DotError.CODE_PARSE, "Not an A2S_RULES response.")

	var reader := _Reader.new(data, 5)
	var count := reader.u16()
	var out: Dictionary = {}

	for i in count:
		var key := reader.cstring()
		var value := reader.cstring()
		if not reader.ok:
			break
		out[key] = value

	return DotResult.success(out)


static func _os_name(byte: int) -> String:
	match byte:
		0x6C: return "linux"
		0x77: return "windows"
		0x6D, 0x6F: return "macos"
	return "unknown"


static func _tags_of(keywords: String) -> PackedStringArray:
	var out := PackedStringArray()
	for part in keywords.split(",", false):
		var tag := str(part).strip_edges()
		if tag != "" and not tag.begins_with("dqp:"):
			out.append(tag)
	return out


static func _dqp_port_of(keywords: String) -> int:
	for part in keywords.split(",", false):
		var tag := str(part).strip_edges()
		if tag.begins_with("dqp:"):
			return int(tag.substr(4))
	return 0


## A bounds-checked reader over a response.
##
## [b][member ok] is sticky.[/b] dot-net shipped a reader whose exhaustion was not,
## so a decoder that skipped the check got a plausible value for the field *after*
## the overrun — which is worse than a wrong one, because it is in range. Here, once
## a read runs past the end every later read returns a zero and [member ok] stays
## false for good.
class _Reader extends RefCounted:
	var data: PackedByteArray
	var at: int = 0
	var ok: bool = true

	func _init(p_data: PackedByteArray, p_at: int = 0) -> void:
		data = p_data
		at = p_at

	func _room(n: int) -> bool:
		if not ok:
			return false
		if at + n > data.size():
			ok = false
			return false
		return true

	func skip(n: int) -> void:
		if _room(n):
			at += n

	func u8() -> int:
		if not _room(1):
			return 0
		var v := data.decode_u8(at)
		at += 1
		return v

	func u16() -> int:
		if not _room(2):
			return 0
		var v := data.decode_u16(at)
		at += 2
		return v

	func i32() -> int:
		if not _room(4):
			return 0
		var v := data.decode_s32(at)
		at += 4
		return v

	func f32() -> float:
		if not _room(4):
			return 0.0
		var v := data.decode_float(at)
		at += 4
		return v

	## A NUL-terminated UTF-8 string.
	##
	## A server truncating a hostname on bytes can cut a UTF-8 sequence in half, so
	## the bytes are repaired rather than refused: dropping the whole response over a
	## broken character is how a server vanishes from a listing the day somebody
	## renames it.
	func cstring() -> String:
		if not ok:
			return ""

		var start := at
		while at < data.size() and data.decode_u8(at) != 0:
			at += 1

		if at >= data.size():
			ok = false
			return ""

		var raw := data.slice(start, at)
		at += 1

		var text := raw.get_string_from_utf8()
		if text == "" and raw.size() > 0:
			text = raw.get_string_from_ascii()

		return text
