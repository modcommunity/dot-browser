class_name DotBrowserSourceBackbone
extends DotBrowserSource

## Servers the TMC backbone knows about, through a client this addon never names.
##
## dot-server already reports its own player count, map and roster to its site
## listing through [code]POST /api/content/server/integration/stats[/code]. This is
## the other direction: reading that listing back, so a player's browser starts with
## the servers a community actually runs rather than with an empty window.
##
## [b]Duck-typed, exactly like dot-stats' reporter.[/b] The client is anything with
## [code]get_integration(path, query)[/code] — dot-auth's [code]DotBackboneClient[/code]
## in practice. Naming the class would make dot-browser fail to parse in a project
## without dot-auth, and a server browser is the last thing that should require a
## sign-in to open.
##
## [b]And the listing is still only a list of addresses.[/b] Every field it carries
## about a server is discarded here and asked of the server directly. A listing is a
## place to find servers, not a source of truth about what they are doing: a site
## that has not heard from a server in ten minutes still lists it, and the player who
## clicks it wants to know that before they connect, not after.

## Where a listing is read from. Overridable, because a community running its own
## site has its own path.
var path: String = "/api/content/server/list"

## Query parameters passed through — a game id, a region, a page size.
var query: Dictionary = {}

## The backbone client. Anything answering [code]get_integration()[/code].
var client: Object = null

## Registry name to find one under when [member client] is not set.
var client_service: StringName = &"dot_backbone_client"

var name_override: StringName = &"backbone"


func _source_name() -> StringName:
	return name_override


func is_available() -> bool:
	return _client() != null


func _client() -> Object:
	if client != null and is_instance_valid(client):
		return client

	var found := DotRegistry.get_service(client_service)
	if found != null and found.has_method("get_integration"):
		return found

	return null


func _fetch() -> DotResult:
	var backbone := _client()
	if backbone == null:
		return DotResult.fail(
			DotError.CODE_STATE,
			"No backbone client is available to read a server listing from."
		)

	# Assigned before the check, never `await x.f().ok`. That spelling binds the
	# await to the property access rather than to the call, so the coroutine is never
	# awaited and the branch reads a property of a signal.
	var res: DotResult = await backbone.call("get_integration", path, query)
	if not res.ok:
		return res

	var value: Variant = res.value
	var rows: Array = []

	if typeof(value) == TYPE_ARRAY:
		rows = value
	elif typeof(value) == TYPE_DICTIONARY:
		var doc: Dictionary = value
		for key in ["servers", "results", "items", "data"]:
			if typeof(doc.get(key)) == TYPE_ARRAY:
				rows = doc[key]
				break

	if rows.is_empty():
		return DotResult.success([] as Array[DotBrowserTarget])

	var out: Array[DotBrowserTarget] = []

	for entry in rows:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var row: Dictionary = entry

		var address := str(row.get("ip", row.get("address", row.get("host", ""))))
		if address == "":
			continue

		var port := int(row.get("port", 27015))
		var target := DotBrowserTarget.make(address, port)

		if int(row.get("query_port", 0)) > 0:
			target.query_port = int(row["query_port"])

		out.append(target)

	return DotResult.success(out)
