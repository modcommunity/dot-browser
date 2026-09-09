class_name DotBrowserDqpClient
extends DotBrowserQuery

## One DQP query in flight, as a state machine somebody else pumps.
##
## [b]Deliberately not a coroutine and deliberately not a Node.[/b] A browser
## refreshing two hundred servers has two hundred of these, and the two obvious
## GDScript spellings of "run N of these concurrently and wait" are both wrong —
## appending a void coroutine is a parse error, and awaiting a completion signal
## hangs when a worker finishes synchronously. The family's working pattern is bare
## calls plus a member counter, and the cheapest thing to count is an object with a
## [method poll] that says when it is done.
##
## So: [method begin], then [method poll] once a frame until it returns true, then
## read [member result]. [DotBrowser] does the pumping.
##
## The exchange:
##
## [codeblock]
## CHALLENGE_REQUEST  ->
##                    <-  CHALLENGE  cookie=X     (and the round trip is the ping)
## QUERY challenge=X  ->
##                    <-  RESULT {...}            (possibly in up to 16 fragments)
## [/codeblock]

const CHANNEL := "browser"

enum State { IDLE, CHALLENGING, QUERYING, DONE }

## Which sections to ask for. More sections is a bigger response, and a response over
## 1174 bytes fragments — which on UDP is where losses start to matter.
var sections: PackedStringArray = PackedStringArray(["info"])

## The revision the caller already holds. Non-zero turns this into a conditional
## query that a server with nothing new answers in forty bytes.
var if_rev: int = 0

## How many times to resend a request that went unanswered.
##
## One by default. UDP loses packets and a server browser that reports a server
## offline because one datagram was dropped is one nobody trusts; retrying forever,
## though, is how a refresh of a dead list takes a minute.
var retries: int = 1

var state: State = State.IDLE

var _socket: PacketPeerUDP = null
var _txn: int = 0
var _challenge: int = 0
var _deadline: int = 0
var _sent_at: int = 0
var _attempts_left: int = 0
var _fragments: Array[PackedByteArray] = []
var _response_id: int = -1
var _fragment_total: int = 0


## Opens the socket and sends the first request.
func begin() -> DotResult:
	if not DotPlatform.has_udp():
		# A browser tab cannot open a UDP socket at any price. This is not a failure
		# to work around: it is why DQP is also served over WebSocket, and
		# DotBrowserDqpWebClient is the path a web build takes.
		return _finish(DotResult.fail(
			DotError.CODE_UNSUPPORTED,
			"This platform has no UDP; query over WebSocket instead."
		))

	if target == null or target.address == "":
		return _finish(DotResult.fail(DotError.CODE_INVALID, "No address to query."))

	_socket = PacketPeerUDP.new()

	# connect_to_host rather than set_dest_address: it also filters what arrives, so
	# a reply forged from a third address is dropped by the socket rather than parsed
	# by us. On a browser refreshing hundreds of servers that matters — a querier is
	# a machine that has told a great many strangers its address.
	var err := _socket.connect_to_host(target.address, target.effective_query_port())
	if err != OK:
		return _finish(DotResult.failure(
			DotError.from_engine(err, "could not open a socket to %s" % target.key())
		))

	_txn = randi() & 0x7FFFFFFF
	_attempts_left = maxi(0, retries)
	_send_challenge_request()

	return DotResult.success(self)


## Advances the exchange. Returns true when [member result] is set.
func poll(now_ms: int) -> bool:
	if state == State.DONE:
		return true
	if state == State.IDLE or _socket == null:
		return false

	while _socket.get_available_packet_count() > 0:
		var data := _socket.get_packet()
		if _handle(data, now_ms):
			return true

	if now_ms >= _deadline:
		if _attempts_left > 0:
			_attempts_left -= 1
			if state == State.CHALLENGING:
				_send_challenge_request()
			else:
				_send_query()
			return false

		_finish(DotResult.fail(
			DotError.CODE_TIMEOUT,
			"The server did not answer.", target.key()
		))
		return true

	return false


func close() -> void:
	if _socket != null:
		_socket.close()
		_socket = null


func _handle(data: PackedByteArray, now_ms: int) -> bool:
	var parsed := DotBrowserDqp.parse(data)
	if not parsed.ok:
		# Not fatal. A socket can receive anything, including an A2S reply from a
		# server serving both on one port, and a querier that gave up on the first
		# unrecognised datagram would be defeated by a stray packet.
		return false

	var packet: Dictionary = parsed.value

	if int(packet["txn"]) != _txn:
		return false

	match int(packet["type"]):
		DotBrowserDqp.TYPE_CHALLENGE:
			if state != State.CHALLENGING:
				return false
			ping_ms = maxi(0, now_ms - _sent_at)
			_challenge = int(packet["challenge"])
			_attempts_left = maxi(0, retries)
			_send_query()
			return false

		DotBrowserDqp.TYPE_ERROR:
			_finish(DotBrowserDqp.error_from_body(packet["body"] as Dictionary))
			return true

		DotBrowserDqp.TYPE_RESULT:
			return _handle_result(packet, data)

		DotBrowserDqp.TYPE_PONG:
			ping_ms = maxi(0, now_ms - _sent_at)
			_finish(DotResult.success({}))
			return true

	return false


func _handle_result(packet: Dictionary, data: PackedByteArray) -> bool:
	var total := int(packet["fragment_count"])

	if total <= 1:
		_finish(DotResult.success(packet["body"]))
		return true

	var response_id := int(packet["response_id"])

	if _response_id < 0:
		_response_id = response_id
		_fragment_total = total
	elif response_id != _response_id:
		# Another response entirely, interleaved on the same socket. Discarded rather
		# than blended: a mixture of two bodies is bytes that parse and are wrong.
		return false

	for held in _fragments:
		if held.decode_u16(16) == data.decode_u16(16):
			return false

	_fragments.append(data)

	if _fragments.size() < _fragment_total:
		return false

	_finish(DotBrowserDqp.reassemble(_fragments))
	return true


func _send_challenge_request() -> void:
	state = State.CHALLENGING
	_sent_at = Time.get_ticks_msec()
	_deadline = _sent_at + timeout_ms
	_socket.put_packet(DotBrowserDqp.build_request(
		DotBrowserDqp.TYPE_CHALLENGE_REQUEST, _txn, 0
	))


func _send_query() -> void:
	state = State.QUERYING
	_sent_at = Time.get_ticks_msec()
	_deadline = _sent_at + timeout_ms
	_fragments.clear()
	_response_id = -1

	var body := {"sections": Array(sections)}
	if if_rev > 0:
		body["if_rev"] = if_rev

	_socket.put_packet(DotBrowserDqp.build_request(
		DotBrowserDqp.TYPE_QUERY, _txn, _challenge, body
	))


func _finish(res: DotResult) -> DotResult:
	state = State.DONE
	return finish(res)
