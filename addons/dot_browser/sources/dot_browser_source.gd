class_name DotBrowserSource
extends RefCounted

## Where a list of addresses comes from. Subclass point.
##
## A browser knows how to ask a server what it is; it has no idea which servers
## exist. That is a different problem with a different answer per deployment — a
## master server, a community's own listing, a LAN sweep, a file an operator ships,
## or four addresses hardcoded for a playtest — and none of them belongs inside a
## query client.
##
## [b]A source produces targets, never entries.[/b] It says where to ask. What a
## server is, is what the server says when asked, and a source that filled in player
## counts would be a source a listing site could use to lie about them.
##
## [codeblock]
## class MyMasterServer extends DotBrowserSource:
##     func _source_name() -> StringName:
##         return &"master"
##
##     func _fetch() -> DotResult:
##         var res := await http.get_json("https://example.com/servers")
##         if not res.ok:
##             return res
##         var out: Array[DotBrowserTarget] = []
##         for row in res.value:
##             out.append(DotBrowserTarget.make(row["ip"], int(row["port"])))
##         return DotResult.success(out)
## [/codeblock]

const CHANNEL := "browser"

## Whether this source is consulted on a refresh.
var enabled: bool = true


## What this source calls itself. Stamped onto every target it produces, so a browser
## can group by it and a failure names which one failed.
func _source_name() -> StringName:
	return &"source"


## Produces the addresses. Override.
##
## May be a coroutine — [DotBrowser] awaits the call either way. Return a
## [DotResult] whose value is an [code]Array[DotBrowserTarget][/code].
func _fetch() -> DotResult:
	return DotResult.fail(
		DotError.CODE_UNSUPPORTED, "This source does not know how to fetch anything."
	)


func source_name() -> StringName:
	return _source_name()


## Fetches and stamps every target with this source's name.
##
## The stamping happens here rather than in each subclass because a subclass that
## forgot it would produce targets a browser cannot attribute — and the symptom is a
## list that works, which is the kind of bug that survives.
func fetch() -> DotResult:
	var res: DotResult = await _fetch()
	if not res.ok:
		return res.wrap("The '%s' server source failed." % String(source_name()))

	var value: Variant = res.value
	if typeof(value) != TYPE_ARRAY:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A server source must produce an array of targets.",
			String(source_name())
		)

	var out: Array[DotBrowserTarget] = []
	for entry in (value as Array):
		var target := entry as DotBrowserTarget
		if target == null:
			continue
		target.source = source_name()
		out.append(target)

	return DotResult.success(out)
