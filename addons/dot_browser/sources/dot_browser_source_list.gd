class_name DotBrowserSourceList
extends DotBrowserSource

## A fixed list of addresses: typed in, shipped in a file, or pasted by a player.
##
## The one every deployment starts with, and the one a LAN party never outgrows.
## Also what a "connect to this address" box uses, because a browser that can only
## show servers a master server told it about cannot show a friend's.

## Addresses as text — [code]host[/code], [code]host:port[/code] or
## [code][::1]:27015[/code]. Unparseable ones are reported, not silently dropped.
var addresses: PackedStringArray = PackedStringArray()

var default_port: int = 27015

var name_override: StringName = &"list"

## A JSON file to read instead of, or as well as, [member addresses].
##
## Either an array of address strings, or an array of objects in
## [method DotBrowserTarget.from_dictionary]'s shape — a community shipping a list
## with per-server query ports needs the second.
var file_path: String = ""


static func of(entries: PackedStringArray, port: int = 27015) -> DotBrowserSourceList:
	# Not this class's own name. A script that names itself in an expression, loaded after
	# its base, cuts Godot 4.7.2's exit teardown short and leaks every script loaded before
	# it. See docs/gdscript-hazards.md, "A script that names itself".
	var out := new()
	out.addresses = entries
	out.default_port = port
	return out


static func of_file(path: String) -> DotBrowserSourceList:
	var out := new()
	out.file_path = path
	return out


func _source_name() -> StringName:
	return name_override


func _fetch() -> DotResult:
	var out: Array[DotBrowserTarget] = []
	var refused := PackedStringArray()

	for raw in addresses:
		var parsed := DotBrowserTarget.parse(str(raw), default_port)
		if parsed.ok:
			out.append(parsed.value)
		else:
			refused.append(str(raw))

	if file_path != "":
		var loaded := _from_file(out, refused)
		if not loaded.ok:
			return loaded

	if not refused.is_empty():
		# Reported and not fatal. One typo in a shipped list must not take out every
		# other server in it, and a list that silently loses entries is one nobody
		# can debug.
		DotLog.warn(CHANNEL, "some server addresses could not be parsed", {
			"source": String(source_name()), "addresses": Array(refused)
		})

	return DotResult.success(out)


func _from_file(out: Array[DotBrowserTarget], refused: PackedStringArray) -> DotResult:
	if not FileAccess.file_exists(file_path):
		return DotResult.fail(
			DotError.CODE_IO, "No such server list file.", file_path
		)

	var read := DotPaths.read_json(file_path)
	if not read.ok:
		return read.wrap("Could not read the server list.")

	var data: Variant = read.value
	if typeof(data) != TYPE_ARRAY:
		return DotResult.fail(
			DotError.CODE_PARSE,
			"A server list file is an array of addresses or objects.",
			file_path
		)

	for row in (data as Array):
		if typeof(row) == TYPE_STRING:
			var parsed := DotBrowserTarget.parse(str(row), default_port)
			if parsed.ok:
				out.append(parsed.value)
			else:
				refused.append(str(row))
			continue

		if typeof(row) == TYPE_DICTIONARY:
			var built := DotBrowserTarget.from_dictionary(row as Dictionary)
			if built.ok:
				out.append(built.value)
			else:
				refused.append(JSON.stringify(row))

	return DotResult.success(out)
