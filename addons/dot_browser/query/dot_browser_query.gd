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
func finish(res: DotResult) -> DotResult:
	result = res
	close()
	return res
