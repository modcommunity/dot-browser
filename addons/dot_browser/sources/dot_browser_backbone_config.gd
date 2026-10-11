class_name DotBrowserBackboneConfig
extends DotConfig

## Where [DotBrowserSourceBackbone] reads its listing from, layered like every dot-* config.
##
## [codeblock]
## godot --path . -- --browser-backbone-url=https://api.example.com --browser-app=arena
## DOT_BROWSER_BACKBONE_URL=https://api.example.com godot --path .
## [/codeblock]
##
## [b]Off unless a URL is set.[/b] The default is empty rather than the public site, because
## a browser that reaches out to a website the moment it opens is a surprise in a LAN build,
## a test, or a game whose community runs its own listing; a game that wants the public site
## sets it in its own defaults, where somebody reading the game can see it.

## The site's origin, e.g. [code]https://api.example.com[/code]. Empty turns the source off.
@export var backbone_url: String = ""

## The listing's path on that origin. A community running its own site has its own.
@export var path: String = "/api/content/server/list"

## The game whose servers to list, as the site's app URL slug. Empty lists every game's,
## which a game's own browser almost never wants: servers of another game cannot be joined.
@export var app: String = ""

## Rows per page asked for. The site caps it at its own ceiling either way.
@export_range(1, 1000, 1) var page_limit: int = 200

## Pages read per refresh at most.
##
## A ceiling, not a target: a listing that grows past it is truncated with a warning rather
## than read without end, because each row is a packet the browser will send next.
@export_range(1, 100, 1) var max_pages: int = 5


func env_prefix() -> String:
	return "DOT_BROWSER_"


func cli_prefix() -> String:
	return "--browser-"


func enabled() -> bool:
	return backbone_url.strip_edges() != ""


## The first page's URL, and the template the rest follow.
func page_url(page: int) -> String:
	var params := PackedStringArray()
	if app.strip_edges() != "":
		params.append("app=%s" % app.strip_edges().uri_encode())
	params.append("limit=%d" % page_limit)
	params.append("page=%d" % page)

	return "%s/%s?%s" % [
		backbone_url.strip_edges().trim_suffix("/"),
		path.strip_edges().trim_prefix("/"),
		"&".join(params),
	]


func validate() -> DotResult:
	var url := backbone_url.strip_edges()
	if url != "" and not (url.begins_with("http://") or url.begins_with("https://")):
		return DotResult.fail(
			DotError.CODE_INVALID,
			"backbone_url needs an http:// or https:// scheme.",
			url
		)

	return DotResult.success(self)
