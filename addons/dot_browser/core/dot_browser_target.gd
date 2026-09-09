class_name DotBrowserTarget
extends RefCounted

## An address to ask, and which protocol to ask it in.
##
## Kept apart from [DotBrowserEntry] because the two answer different questions. A
## target is what a source hands the browser: somewhere to send a datagram. An entry
## is what came back. A list that conflates them cannot represent the two states that
## matter most in a server browser — "we have not asked yet" and "we asked and got
## nothing" — and shows both as an empty row.

enum Protocol {
	## Try DQP, and fall back to A2S if nothing answers.
	##
	## The right default. A dot server answers both on one socket; anything else
	## answers one, and which one is not knowable from an address.
	AUTO,
	## The dot query protocol over UDP.
	DQP,
	## A2S over UDP.
	A2S,
	## DQP as JSON over a WebSocket. The only one a browser build can use.
	DQP_WEB,
}

## Host or IP. No port, no scheme.
var address: String = ""

## The game port, and the port A2S is served on unless [member query_port] says
## otherwise. This is also the address a player is given to connect to.
var port: int = 27015

## The query port, when it differs from [member port].
##
## Zero means "the same one". A UDP game transport already holds the game port, so an
## ENet server's operator has to move its queries somewhere else — and most trackers
## will not look there, which is why this is worth carrying rather than assuming.
var query_port: int = 0

var protocol: Protocol = Protocol.AUTO

## For [constant Protocol.DQP_WEB]: the full URL, e.g. [code]ws://host:27018[/code].
var websocket_url: String = ""

## Free-form: which source produced this target, for a browser that groups by it.
var source: StringName = &""


static func make(
	p_address: String, p_port: int = 27015, p_protocol: Protocol = Protocol.AUTO
) -> DotBrowserTarget:
	var out := DotBrowserTarget.new()
	out.address = p_address
	out.port = p_port
	out.protocol = p_protocol
	return out


## Parses [code]host:port[/code], [code]host[/code], or an IPv6 [code][::1]:27015[/code].
static func parse(text: String, default_port: int = 27015) -> DotResult:
	var raw := text.strip_edges()
	if raw == "":
		return DotResult.fail(DotError.CODE_INVALID, "No address.")

	var host := raw
	var port := default_port

	if raw.begins_with("["):
		# IPv6 in brackets. Splitting on the last colon without this turns
		# `[::1]:27015` into a host of `[` and a port of nothing, and splitting on the
		# first turns every IPv6 address into a host of `[` too.
		var close := raw.find("]")
		if close < 0:
			return DotResult.fail(
				DotError.CODE_INVALID, "Unbalanced brackets in the address.", raw
			)
		host = raw.substr(1, close - 1)
		var rest := raw.substr(close + 1)
		if rest.begins_with(":"):
			port = int(rest.substr(1))
	else:
		var colon := raw.rfind(":")
		if colon > 0 and raw.count(":") == 1:
			host = raw.substr(0, colon)
			port = int(raw.substr(colon + 1))

	if not is_plausible_host(host):
		return DotResult.fail(
			DotError.CODE_INVALID, "That is not a host.", "%s -> %s" % [raw, host]
		)

	if port <= 0 or port > 65535:
		return DotResult.fail(
			DotError.CODE_INVALID, "That is not a port.", "%s -> %d" % [raw, port]
		)

	return DotResult.success(make(host, port))


## Whether [param host] could be a hostname or an IP address at all.
##
## Not a resolver and not a validator — a name that passes here may still not exist.
## It is a filter against the thing a shipped server list actually contains: a line
## somebody typed. Without it "not a host:::" parses as a host, the browser opens a
## socket to it, and the entry sits at "offline" looking like a server that is down
## rather than like a typo in a file.
static func is_plausible_host(host: String) -> bool:
	if host == "" or host.length() > 253:
		return false

	if host.begins_with(".") or host.ends_with(".") or host.begins_with("-"):
		return false

	var alphanumerics := 0

	for i in host.length():
		var c := host[i]
		var is_letter := (c >= "a" and c <= "z") or (c >= "A" and c <= "Z")
		var is_digit := c >= "0" and c <= "9"

		if is_letter or is_digit:
			alphanumerics += 1
			continue

		# Colons for IPv6, and a percent sign for its zone id — `fe80::1%eth0` is a
		# perfectly ordinary link-local address and refusing it would make a LAN
		# browser useless on exactly the network it is for.
		if c == "." or c == "-" or c == "_" or c == ":" or c == "%":
			continue

		return false

	return alphanumerics > 0


## The port to send a query to.
func effective_query_port() -> int:
	return query_port if query_port > 0 else port


## The stable identity of a server in a list.
##
## Keyed on the [i]game[/i] port rather than the query port: the same server behind
## two query ports is one server, and a query port that moves must not create a
## second row a player thinks is somewhere new.
func key() -> String:
	return "%s:%d" % [address, port]


## What a player pastes to connect.
func join_address() -> String:
	if address.contains(":"):
		return "[%s]:%d" % [address, port]
	return "%s:%d" % [address, port]


func duplicate_target() -> DotBrowserTarget:
	var out := DotBrowserTarget.new()
	out.address = address
	out.port = port
	out.query_port = query_port
	out.protocol = protocol
	out.websocket_url = websocket_url
	out.source = source
	return out


func to_dictionary() -> Dictionary:
	var out := {"address": address, "port": port}
	if query_port > 0:
		out["query_port"] = query_port
	if protocol != Protocol.AUTO:
		out["protocol"] = protocol_name()
	if websocket_url != "":
		out["websocket_url"] = websocket_url
	if source != &"":
		out["source"] = String(source)
	return out


static func from_dictionary(data: Dictionary) -> DotResult:
	var address := str(data.get("address", ""))
	if address == "":
		return DotResult.fail(DotError.CODE_PARSE, "A target needs an address.")

	var out := make(address, int(data.get("port", 27015)))
	out.query_port = int(data.get("query_port", 0))
	out.websocket_url = str(data.get("websocket_url", ""))
	out.source = StringName(str(data.get("source", "")))

	var named := protocol_from_name(str(data.get("protocol", "auto")))
	if named < 0:
		return DotResult.fail(
			DotError.CODE_PARSE, "Unknown query protocol.", str(data.get("protocol", ""))
		)
	out.protocol = named as Protocol

	return DotResult.success(out)


const PROTOCOL_NAMES: Array[String] = ["auto", "dqp", "a2s", "dqp_web"]


func protocol_name() -> String:
	return PROTOCOL_NAMES[int(protocol)]


static func protocol_from_name(name: String) -> int:
	return PROTOCOL_NAMES.find(name)


func _to_string() -> String:
	return "DotBrowserTarget(%s, %s)" % [join_address(), protocol_name()]
