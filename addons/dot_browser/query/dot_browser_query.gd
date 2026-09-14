class_name DotBrowserQuery
extends RefCounted

## One query in flight. The interface [DotBrowser] pumps, and the reason it can.
##
## Three protocols answer the same question — DQP over UDP, A2S over UDP, DQP as
## JSON over a WebSocket — and a browser that special-cased each would carry the
## fallback logic three times. They share this instead: [method begin], then
## [method poll] until it returns true, then read [member result].
##
## [b]A base class rather than duck typing, which is unusual for this family.[/b]
## The family rule is that cross-addon seams are duck-typed, because a script that
## mentions an absent [code]class_name[/code] fails to parse. That reasoning applies
## between repositories; inside one, three classes that must not drift from one
## another are better held together by the compiler — and the alternative here was
## [code]client.call("poll", now)[/code] returning a [Variant] at every call site,
## which throws away the return type of the one method the whole design turns on.

const CHANNEL := "browser"

## Where to ask.
var target: DotBrowserTarget = null

## Milliseconds to wait for a reply.
var timeout_ms: int = 2500

## Set exactly once, when [method poll] first returns true.
var result: DotResult = null

## Round-trip time in milliseconds, or -1 when it was never measured.
##
## Measured on the first exchange of the conversation — the challenge, where there
## is one — rather than on the whole thing, because the whole thing includes the
## server building a response and a player wants to know how far away it is.
var ping_ms: int = -1


func _init(p_target: DotBrowserTarget = null) -> void:
	target = p_target


## What this query calls itself in a log line. Override.
##
## [b]Worth the three lines because of the fallback.[/b] A target on AUTO that times
## out on DQP is retried over A2S, so one address can produce two failures in one
## refresh -- and "the server did not answer" twice, with no way to tell which
## protocol was speaking, is a log that makes a working fallback look like a flapping
## server.
func query_name() -> StringName:
	return &"query"


## Opens whatever is needed and sends the first request. Override.
func begin() -> DotResult:
	return DotResult.fail(
		DotError.CODE_UNSUPPORTED, "This query does not know how to start."
	)


## Advances the exchange. Returns true when [member result] is set. Override.
func poll(_now_ms: int) -> bool:
	return true


## Releases the socket. Safe to call twice, and called on every finishing path —
## a browser that abandons two hundred queries holds two hundred sockets otherwise.
func close() -> void:
	pass


## Sets the result, closes, and returns it. What every finishing path calls.
##
## [b]And the one place a failed query is written down.[/b] Every failure here becomes
## an offline row in [DotBrowser] and nothing else: a refresh of two hundred servers
## that answers none of them draws two hundred grey lines and leaves no record of why.
## Logging in the base rather than in each of the three clients is deliberate -- they
## all finish through this method by construction, so the three cannot drift, and a
## fourth protocol gets it for nothing.
##
## [b]The level is chosen by who is expected to act.[/b] A server that did not answer
## is not a fault, it is what a browser is FOR -- servers are down, and WARN for each
## one would fill an operator's log with the sound of the list working. What is not
## routine is a query that could never have been made: no UDP on this platform, no
## WebSocket in this build, no address on the target. Nobody can fix those by waiting,
## and every server in the list fails the same way, which is the report a player
## actually sends in.
func finish(res: DotResult) -> DotResult:
	result = res
	close()

	if not res.ok:
		var fields := {
			"protocol": String(query_name()),
			"address": target.address if target != null else "",
			"port": target.effective_query_port() if target != null else 0,
			"error": str(res.error),
		}

		match res.code():
			DotError.CODE_UNSUPPORTED, DotError.CODE_INVALID:
				DotLog.warn(CHANNEL, "a server query could not be made at all", fields)
			_:
				DotLog.debug(CHANNEL, "a server query did not come back", fields)

	return res
