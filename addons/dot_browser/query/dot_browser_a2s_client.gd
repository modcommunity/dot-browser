class_name DotBrowserA2sClient
extends DotBrowserQuery

## One A2S query in flight, pumped the same way [DotBrowserDqpClient] is.
##
## Asks [code]A2S_INFO[/code], and optionally [code]A2S_PLAYER[/code] after it. Both
## are challenged — [code]A2S_INFO[/code] gained a challenge in 2020 after years of
## being a reflection amplifier — so the exchange is:
##
## [codeblock]
## A2S_INFO                 ->
##                          <-  'A' challenge      (or 'I' from an old server)
## A2S_INFO with challenge  ->
##                          <-  'I' info
## [/codeblock]
##
## A server old enough not to challenge answers the first request, which is why the
## first one is sent without one and both replies are handled.

const CHANNEL := "browser"

enum State { IDLE, INFO, PLAYERS, DONE }

## Ask for the roster after the info. One more round trip per server, so a browser
## leaves it off for a list and turns it on for the server a player clicked.
var want_players: bool = false

var retries: int = 1

var state: State = State.IDLE

var _socket: PacketPeerUDP = null
var _challenge: int = DotBrowserA2s.NO_CHALLENGE
var _deadline: int = 0
var _sent_at: int = 0
var _attempts_left: int = 0
var _info: Dictionary = {}
var _players: Array = []
var _split: Array[PackedByteArray] = []
var _split_id: int = -1


func begin() -> DotResult:
	if not DotPlatform.has_udp():
		return _finish(DotResult.fail(
			DotError.CODE_UNSUPPORTED,
			"A2S is UDP only and this platform has none. A browser build cannot "
			+ "speak it at any price."
		))

	if target == null or target.address == "":
		return _finish(DotResult.fail(DotError.CODE_INVALID, "No address to query."))

	_socket = PacketPeerUDP.new()
	var err := _socket.connect_to_host(target.address, target.effective_query_port())
	if err != OK:
		return _finish(DotResult.failure(
			DotError.from_engine(err, "could not open a socket to %s" % target.key())
		))

	_attempts_left = maxi(0, retries)
	_send_info()

	return DotResult.success(self)


func poll(now_ms: int) -> bool:
	if state == State.DONE:
		return true
	if state == State.IDLE or _socket == null:
		return false

	while _socket.get_available_packet_count() > 0:
		if _handle(_socket.get_packet(), now_ms):
			return true

	if now_ms >= _deadline:
		if _attempts_left > 0:
			_attempts_left -= 1
			if state == State.INFO:
				_send_info()
			else:
				_send_players()
			return false

		if state == State.PLAYERS and not _info.is_empty():
			# The roster is an extra. A server that answered the info and then went
			# quiet is still a server worth listing, and reporting it offline because
			# the second request was dropped would be wrong about the first.
			_finish(DotResult.success({"info": _info, "players": _players}))
			return true

		_finish(DotResult.fail(
			DotError.CODE_TIMEOUT, "The server did not answer.", target.key()
		))
		return true

	return false


func close() -> void:
	if _socket != null:
		_socket.close()
		_socket = null


func _handle(data: PackedByteArray, now_ms: int) -> bool:
	if DotBrowserA2s.is_split(data):
		return _handle_split(data, now_ms)

	if not DotBrowserA2s.is_single(data):
		return false

	return _handle_single(data, now_ms)


func _handle_split(data: PackedByteArray, now_ms: int) -> bool:
	var head := DotBrowserA2s.parse_split_header(data)
	if head.is_empty():
		return false

	var id := int(head["id"])
	if _split_id < 0:
		_split_id = id
	elif id != _split_id:
		return false

	for held in _split:
		if held.decode_u8(9) == data.decode_u8(9):
			return false

	_split.append(data)

	if _split.size() < int(head["total"]):
		return false

	var joined := DotBrowserA2s.reassemble_split(_split)
	_split.clear()
	_split_id = -1

	if not joined.ok:
		_finish(joined)
		return true

	return _handle_single(joined.value, now_ms)


func _handle_single(data: PackedByteArray, now_ms: int) -> bool:
	var type := DotBrowserA2s.response_type(data)

	if type == DotBrowserA2s.RESPONSE_CHALLENGE:
		_challenge = DotBrowserA2s.challenge_of(data)
		_attempts_left = maxi(0, retries)
		if state == State.INFO:
			_send_info()
		else:
			_send_players()
		return false

	if type == DotBrowserA2s.RESPONSE_INFO:
		if ping_ms < 0:
			ping_ms = maxi(0, now_ms - _sent_at)

		var parsed := DotBrowserA2s.parse_info(data)
		if not parsed.ok:
			_finish(parsed)
			return true

		_info = parsed.value

		if want_players and _challenge != DotBrowserA2s.NO_CHALLENGE:
			_attempts_left = maxi(0, retries)
			_send_players()
			return false

		if want_players:
			# No challenge in hand, because this server answered the first INFO
			# without issuing one. A2S_PLAYER still needs one, so it is asked for
			# explicitly rather than being sent a guess.
			_attempts_left = maxi(0, retries)
			_send_players()
			return false

		_finish(DotResult.success({"info": _info, "players": _players}))
		return true

	if type == DotBrowserA2s.RESPONSE_PLAYER:
		var rows := DotBrowserA2s.parse_players(data)
		if rows.ok:
			_players = rows.value
		_finish(DotResult.success({"info": _info, "players": _players}))
		return true

	return false


func _send_info() -> void:
	state = State.INFO
	_sent_at = Time.get_ticks_msec()
	_deadline = _sent_at + timeout_ms
	_socket.put_packet(DotBrowserA2s.build_info(_challenge))


func _send_players() -> void:
	state = State.PLAYERS
	_sent_at = Time.get_ticks_msec()
	_deadline = _sent_at + timeout_ms
	_socket.put_packet(DotBrowserA2s.build_player(_challenge))


func _finish(res: DotResult) -> DotResult:
	state = State.DONE
	return finish(res)
