extends Node

## Reads a real site's server listing and asks every server on it what it is.
##
## [codeblock]
## godot --headless --path . res://examples/backbone_listing.tscn -- \
##     --browser-backbone-url=http://127.0.0.1:3002 --browser-app=hungario \
##     --expect=127.0.0.1:27081
## [/codeblock]
##
## The round trip the selftest cannot make: the suite reads canned pages, and this reads
## website-city's [code]GET /api/content/server/list[/code] over HTTP, then queries each
## address it got. Configured like any game's browser would be ([DotBrowserBackboneConfig]:
## [code]--browser-*[/code] or [code]DOT_BROWSER_*[/code]); with no URL it says so and exits
## 2, because a run that read nothing must not look like a site with no servers.
##
## Exits 0 when the listing produced at least one server and, with [code]--expect=host:port[/code],
## that server was listed AND answered a query.

const CHANNEL := "browser.example"


func _ready() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	await _run()


func _run() -> void:
	var made := DotBrowserSourceBackbone.from_config()
	if not made.ok:
		print("configuration: %s" % str(made.error))
		get_tree().quit(2)
		return

	var source: DotBrowserSourceBackbone = made.value
	if not source.is_available():
		print("No backbone URL: pass --browser-backbone-url=<site origin>.")
		get_tree().quit(2)
		return

	var expect := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--expect="):
			expect = arg.trim_prefix("--expect=")

	var browser := DotBrowser.new()
	browser.register_as = &""
	browser.timeout_ms = 1500
	browser.retries = 1
	browser.sections = PackedStringArray(["info"])
	browser.favourites_path = "user://backbone_listing_example.json"
	browser.add_source(source)
	add_child(browser)

	var failed_with: Array[String] = []
	browser.source_failed.connect(func(_name: StringName, error: DotError) -> void:
		failed_with.append(str(error))
	)

	print("listing: %s" % source.config.page_url(1))
	await browser.refresh()

	if not failed_with.is_empty():
		print("the listing could not be read: %s" % failed_with[0])
		get_tree().quit(1)
		return

	var listed := 0
	var found_expected := false

	for entry in browser.entries():
		if entry.target.source != &"backbone":
			continue
		listed += 1
		print("  %s" % entry.describe())
		if expect != "" and entry.target.key() == expect:
			found_expected = entry.is_online()
			print("    -> expected server %s" % ("answered" if found_expected else "did NOT answer"))

	print("%d servers from the listing, %d answering" % [listed, browser.filtered().filter(
		func(e: DotBrowserEntry) -> bool: return e.is_online()
	).size()])

	var ok := listed > 0 and (expect == "" or found_expected)
	if expect != "" and not found_expected:
		print("expected %s listed and answering; it was not" % expect)

	browser.queue_free()
	get_tree().quit(0 if ok else 1)
