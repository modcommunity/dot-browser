class_name DotBrowserDqp
extends RefCounted

## The client half of the dot query protocol (DQP), as a codec with no socket.
##
## [b]This is a second implementation of a wire format dot-server already
## implements, and that is deliberate.[/b] dot-browser depends on dot-core and
## nothing else, and in GDScript a script that merely [i]mentions[/i] a
## [code]class_name[/code] the project does not have fails to parse and takes every
## script referencing it down with it — so naming [code]DotQueryProtocol[/code] here
## would make a server browser impossible to ship without a dedicated server.
##
## Two implementations of one format is also the exact shape this family has been
## bitten by repeatedly: dot-map asking a cloud client for [code]ensure()[/code] when
## it offered [code]acquire()[/code], a punishment written under one name and read
## under another. So the self-test does not check this against itself. It checks it
## against [b]bytes dot-server's encoder actually produced[/b], pasted in as hex.
## If the two drift, a fixture fails rather than a browser quietly showing nothing.
##
## The format, little-endian throughout:
##
## [codeblock]
## offset size field
## 0      4    magic "DQP1"
## 4      1    type
## 5      1    flags
## 6      4    transaction id   (echoed by the server)
## 10     4    response id      (shared by every fragment of one response)
## 14     2    fragment count
## 16     2    fragment index
## 18     8    challenge cookie
## 26     ...  payload, JSON, optionally gzip
## [/codeblock]

const MAGIC := "DQP1"
const HEADER_BYTES := 26

## Requests.
const TYPE_QUERY := 0x01
const TYPE_CHALLENGE_REQUEST := 0x02
const TYPE_PING := 0x03

## Responses. The high bit is set on all of them.
const TYPE_RESULT := 0x81
const TYPE_CHALLENGE := 0x82
const TYPE_ERROR := 0x83
const TYPE_PONG := 0x84

const FLAG_GZIP := 1 << 0
const FLAG_FRAGMENTED := 1 << 1
const FLAG_ACCEPT_GZIP := 1 << 2

const MAX_DATAGRAM := 1200
const MAX_FRAGMENTS := 16

## Cap on a reassembled body.
##
## A querier is talking to an address a stranger supplied — that is what a server
## browser is — so every bound here is a bound on what a hostile server can make this
## process allocate. [method _gunzip] uses the dynamic decompressor for the same
## reason: the uncompressed size is not on the wire, so without a ceiling a kilobyte
## of gzip is however much memory the sender chose.
const MAX_BODY_BYTES := 1 << 20

## The sections a browser asks for when the caller does not say.
##
## A static function rather than a const: a PackedStringArray built from a call is
## not a constant expression, and a const Array here would be shared and mutable.
static func default_sections() -> PackedStringArray:
	return PackedStringArray(["info"])


static func looks_like_dqp(data: PackedByteArray) -> bool:
	if data.size() < HEADER_BYTES:
		return false
	return data.slice(0, 4).get_string_from_ascii() == MAGIC


## Builds one request datagram.
##
## Requests are never fragmented — a server that reassembled them would be holding
## state an unauthenticated sender chose — so this returns one packet, not a list.
static func build_request(
	type: int,
	txn: int,
	challenge: int,
	body: Dictionary = {},
	accept_gzip: bool = true
) -> PackedByteArray:
	var payload := PackedByteArray()
	if not body.is_empty():
		payload = JSON.stringify(body).to_utf8_buffer()

	var flags := FLAG_ACCEPT_GZIP if accept_gzip else 0

	var packet := PackedByteArray()
	packet.resize(HEADER_BYTES)
	packet.encode_u8(0, MAGIC.unicode_at(0))
	packet.encode_u8(1, MAGIC.unicode_at(1))
	packet.encode_u8(2, MAGIC.unicode_at(2))
	packet.encode_u8(3, MAGIC.unicode_at(3))
	packet.encode_u8(4, type)
	packet.encode_u8(5, flags)
	packet.encode_u32(6, txn)
	packet.encode_u32(10, 0)
	packet.encode_u16(14, 1)
	packet.encode_u16(16, 0)
	packet.encode_u64(18, challenge)
	packet.append_array(payload)

	return packet


## Reads a datagram's header, and its body when it carries a whole one.
##
## A fragment's payload is a slice of a compressed, serialised whole, so neither
## gunzipping nor parsing it makes sense until [method reassemble] has put the pieces
## back — attempting either logs an engine error on a completely normal path, which
## is how a working protocol comes to look broken in a bug report.
static func parse(data: PackedByteArray) -> DotResult:
	if not looks_like_dqp(data):
		return DotResult.fail(DotError.CODE_PARSE, "Not a dot query packet.")

	var type := data.decode_u8(4)
	var flags := data.decode_u8(5)

	if not (type & 0x80):
		# A request arriving where a response was expected is somebody else's traffic
		# on a shared socket, or a server that has confused itself. Never treated as
		# an answer.
		return DotResult.fail(
			DotError.CODE_INVALID, "That is a request, not a response."
		)

	var payload := data.slice(HEADER_BYTES)
	var is_fragment := bool(flags & FLAG_FRAGMENTED)

	if (flags & FLAG_GZIP) and not is_fragment:
		var inflated := _gunzip(payload)
		if not inflated.ok:
			return inflated
		payload = inflated.value

	var out := {
		"type": type,
		"flags": flags,
		"txn": data.decode_u32(6),
		"response_id": data.decode_u32(10),
		"fragment_count": data.decode_u16(14),
		"fragment_index": data.decode_u16(16),
		"challenge": data.decode_u64(18),
		"payload": payload,
		"body": {},
	}

	if payload.is_empty() or is_fragment:
		return DotResult.success(out)

	var parsed: Variant = JSON.parse_string(payload.get_string_from_utf8())
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		out["body_error"] = "payload is not a JSON object"
		return DotResult.success(out)

	out["body"] = parsed as Dictionary
	return DotResult.success(out)


## Reassembles a complete response body from its datagrams, in any order.
##
## [b]Fragments whose response id differs are discarded, never blended.[/b] A querier
## refreshing a list of two hundred servers has one socket receiving two hundred
## replies, and stitching a piece of one response into another produces a body that
## parses and is wrong — which is worse than one that visibly fails.
static func reassemble(fragments: Array) -> DotResult:
	if fragments.is_empty():
		return DotResult.fail(DotError.CODE_PARSE, "No fragments.")

	var first: PackedByteArray = fragments[0]
	if not looks_like_dqp(first):
		return DotResult.fail(DotError.CODE_PARSE, "Not a dot query packet.")

	var total := int(first.decode_u16(14))
	var response_id := int(first.decode_u32(10))

	if total <= 1:
		var single := parse(first)
		if not single.ok:
			return single
		return DotResult.success((single.value as Dictionary).get("body", {}))

	if total > MAX_FRAGMENTS:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A response claimed %d fragments; the ceiling is %d." % [total, MAX_FRAGMENTS]
		)

	var chunks: Dictionary = {}
	var flags := 0

	for entry in fragments:
		var data: PackedByteArray = entry
		if not looks_like_dqp(data):
			continue
		if int(data.decode_u32(10)) != response_id:
			continue
		if int(data.decode_u16(14)) != total:
			continue
		flags = data.decode_u8(5)
		chunks[int(data.decode_u16(16))] = data.slice(HEADER_BYTES)

	if chunks.size() != total:
		return DotResult.fail(
			DotError.CODE_TIMEOUT,
			"Incomplete response: %d of %d fragments." % [chunks.size(), total]
		)

	var payload := PackedByteArray()
	for index in range(total):
		payload.append_array(chunks[index] as PackedByteArray)

	if flags & FLAG_GZIP:
		var inflated := _gunzip(payload)
		if not inflated.ok:
			return inflated
		payload = inflated.value

	var parsed: Variant = JSON.parse_string(payload.get_string_from_utf8())
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		return DotResult.fail(
			DotError.CODE_PARSE, "Reassembled payload is not a JSON object."
		)

	return DotResult.success(parsed as Dictionary)


## Turns an ERROR response body into a failed [DotResult].
static func error_from_body(body: Dictionary) -> DotResult:
	var code := str(body.get("code", DotError.CODE_INVALID))
	var message := str(body.get("error", "The server refused the query."))
	return DotResult.fail(code, message)


static func type_name(type: int) -> String:
	match type:
		TYPE_QUERY: return "query"
		TYPE_CHALLENGE_REQUEST: return "challenge_request"
		TYPE_PING: return "ping"
		TYPE_RESULT: return "result"
		TYPE_CHALLENGE: return "challenge"
		TYPE_ERROR: return "error"
		TYPE_PONG: return "pong"
	return "unknown(%d)" % type


static func _gunzip(payload: PackedByteArray) -> DotResult:
	if payload.is_empty():
		return DotResult.success(payload)

	var inflated := payload.decompress_dynamic(
		MAX_BODY_BYTES, FileAccess.COMPRESSION_GZIP
	)

	if inflated.is_empty():
		return DotResult.fail(
			DotError.CODE_PARSE,
			"Could not decompress the payload.",
			"claimed gzip, %d bytes" % payload.size()
		)

	return DotResult.success(inflated)
