class_name DotBrowserSourceBackbone
extends DotBrowserSource

## The servers a site lists for a game: website-city's [code]GET /api/content/server/list[/code].
##
## dot-server already reports its own player count and map to its site listing. This is the
## other direction: reading the listing back, so a player's browser starts with the servers a
## community actually runs rather than with an empty window.
##
## [codeblock]
## var source := DotBrowserSourceBackbone.for_site("https://api.example.com", "arena")
## browser.add_source(source)   # DotBrowser hands the source somewhere to put its HTTP node
## [/codeblock]
##
## [b]Anonymous, over plain HTTP, never through dot-auth.[/b] The listing is public and the
## site answers it without a key, so a browser needs no sign-in to open — and a server
## browser is the last thing that should. The first version of this source went through
## dot-auth's backbone client instead, which could never have worked: that client prefixes
## every path with the integration surface and sends a SERVER's integration token, which a
## player's game does not have.
##
## [b]And the listing is still only a list of addresses.[/b] The site sends nothing else (an
## address, the ports, the game's query protocols), and if it ever did, this would discard
## it: what a server is doing is what the server says when asked. A site that has not heard
## from a server in ten minutes still lists it, and the player who clicks it wants to know
## that before they connect, not after.

## Where to read from. [method DotBrowserBackboneConfig.enabled] false means the source is
## off: [method is_available] is false and a fetch says so.
var config: DotBrowserBackboneConfig = DotBrowserBackboneConfig.new()

## Anything answering [code]get_json(url, headers) -> DotResult[/code] — a [DotHttp] in
## practice. Left null, the source makes its own [DotHttp] under the node it was attached to
## (see [method DotBrowserSource.attached]).
var http: Object = null

var name_override: StringName = &"backbone"

var _parent: WeakRef = null
var _owned_http: DotHttp = null


## A source for one game on one site. [param app] is the site's app URL slug.
static func for_site(base_url: String, app: String = "") -> DotBrowserSourceBackbone:
	# `new()`, never this class's own name: a script that names itself in an expression
	# leaks every script at exit on 4.7.2 (game-dev docs/gdscript-hazards.md).
	var out := new()
	out.config.backbone_url = base_url
	out.config.app = app
	return out


## A source configured from the layered config: defaults, then [param file_path] if given,
## then [code]DOT_BROWSER_*[/code] and [code]--browser-*[/code].
static func from_config(
	defaults: DotBrowserBackboneConfig = null, file_path: String = ""
) -> DotResult:
	var cfg := defaults if defaults != null else DotBrowserBackboneConfig.new()
	var loaded := cfg.load_layered(file_path)
	if not loaded.ok:
		return loaded

	var out := new()
	out.config = cfg
	return DotResult.success(out)


func _source_name() -> StringName:
	return name_override


func _attached(browser: Node) -> void:
	_parent = weakref(browser)


func is_available() -> bool:
	return config != null and config.enabled()


func _http() -> Object:
	if http != null and is_instance_valid(http):
		return http

	if _owned_http != null and is_instance_valid(_owned_http):
		return _owned_http

	var parent: Node = _parent.get_ref() if _parent != null else null
	if parent == null:
		return null

	_owned_http = DotHttp.new()
	_owned_http.name = "BackboneHttp"
	# A listing is advisory. Two retries on a dead site is a refresh that hangs for half a
	# minute before showing the servers the player already knew about.
	_owned_http.max_retries = 1
	_owned_http.timeout_sec = 10.0
	parent.add_child(_owned_http)
	return _owned_http


func _fetch() -> DotResult:
	if not is_available():
		return DotResult.fail(
			DotError.CODE_STATE,
			"No backbone URL is configured, so there is no server listing to read."
		)

	var client := _http()
	if client == null:
		return DotResult.fail(
			DotError.CODE_STATE,
			"The backbone source has no HTTP client: add it to a DotBrowser, or set http."
		)

	var out: Array[DotBrowserTarget] = []
	var seen := {}
	var page := 1
	var pages := 1

	while page <= pages and page <= config.max_pages:
		# Assigned before the check, never `await x.f().ok`: that binds the await to the
		# property access, so the coroutine is never awaited.
		var res: DotResult = await client.call("get_json", config.page_url(page), {})
		if not res.ok:
			return res.wrap("Could not read the server listing.")

		var doc: Variant = res.value
		_collect(doc, out, seen)

		pages = _total_pages(doc)
		page += 1

	if pages > config.max_pages:
		DotLog.warn(CHANNEL, "the server listing has more pages than this browser reads", {
			"pages": pages, "read": config.max_pages, "kept": out.size(),
		})

	return DotResult.success(out)


## The rows of one page. Reads website-city's shape ([code]data[/code] with [code]host[/code],
## [code]port[/code], [code]queryPort[/code]) and the looser shapes a community's own listing
## might send: a bare array, [code]servers[/code], [code]ip[/code]/[code]address[/code],
## [code]query_port[/code].
static func _collect(doc: Variant, out: Array[DotBrowserTarget], seen: Dictionary) -> void:
	var rows: Array = []

	if typeof(doc) == TYPE_ARRAY:
		rows = doc
	elif typeof(doc) == TYPE_DICTIONARY:
		for key in ["data", "servers", "results", "items"]:
			if typeof((doc as Dictionary).get(key)) == TYPE_ARRAY:
				rows = (doc as Dictionary)[key]
				break

	for entry in rows:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var row: Dictionary = entry

		var address := str(row.get("host", row.get("address", row.get("ip", "")))).strip_edges()
		if address == "" or not DotBrowserTarget.is_plausible_host(address):
			continue

		var port := _port(row.get("port"))
		if port < 1 or port > 65535:
			continue

		var target := DotBrowserTarget.make(address, port)

		var query_port := _port(row.get("queryPort", row.get("query_port")))
		if query_port > 0 and query_port <= 65535 and query_port != port:
			target.query_port = query_port

		# One server listed twice (a page boundary moved under a refresh) is one row.
		var key := target.key()
		if seen.has(key):
			continue
		seen[key] = true

		out.append(target)


static func _total_pages(doc: Variant) -> int:
	if typeof(doc) != TYPE_DICTIONARY:
		return 1
	var pagination: Variant = (doc as Dictionary).get("pagination")
	if typeof(pagination) != TYPE_DICTIONARY:
		return 1
	return maxi(1, int((pagination as Dictionary).get("totalPages", 1)))


## A port from JSON, where it is a float, possibly a string, and [code]null[/code] for "the
## same as the game port". [code]int(null)[/code] is a script error, not a zero.
static func _port(value: Variant) -> int:
	match typeof(value):
		TYPE_INT, TYPE_FLOAT:
			return int(value)
		TYPE_STRING:
			return int(value) if (value as String).is_valid_int() else 0
	return 0
