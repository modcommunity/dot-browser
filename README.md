This is the **server browser** asset for TMC's **Dot** collection. dot-server has answered queries since the day it was written, and until now nothing in this family had ever asked one anything.

This collection of assets provides modular building blocks for creating games and applications within the TMC ecosystem, ensuring consistency and interoperability across all `dot-*` assets. This includes core functionality, networking, authentication, cloud integration, and more.

**These assets are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This asset, along with all the others, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** Every asset has its own headless test suite and those suites pass, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## Finding A Server To Play On
**A query client and a list model.** Speaks dot-server's DQP over UDP, the same
protocol as JSON over a WebSocket for browser builds, and A2S for the twenty years of
servers and tooling that speak nothing else. On top of that: sources, filters,
sorting, favourites and history.

## Why

"Click a link and play" needs a link to come from somewhere. A server that answers
and a client that never asks is half a feature, and every game that ships a server
browser writes the same query client — usually the A2S half of it, usually with the
same three bugs:

- **The player count is humans plus bots.** A2S has always written it that way. A
  browser that shows it shows a server with eight bots as an eight-player server.
- **Multi-packet responses get stitched together wrong.** A socket refreshing two
  hundred servers receives replies interleaved, and a fragment of one response mixed
  into another produces bytes that parse and are wrong.
- **Refreshing hangs.** Two hundred concurrent queries is a fan-out, and GDScript
  has two obvious spellings for that and both are broken.

## Installing

Copy `addons/dot_browser/` and [`dot-core`](https://github.com/modcommunity/dot-core)'s
`addons/dot_core/` into your project and enable dot-browser in
*Project → Project Settings → Plugins*.

[dot-server](https://github.com/modcommunity/dot-server) is what this asks, and is
not a dependency — the wire format is implemented here, and nothing in this addon
names a class from it. Requires Godot 4.7 or newer.

## Five minutes

```gdscript
var browser := DotBrowser.new()
browser.add_source(DotBrowserSourceList.of(PackedStringArray([
    "eu1.example.com:27015",
    "127.0.0.1:27016",
])))
browser.entry_updated.connect(func(entry: DotBrowserEntry) -> void:
    table.redraw(entry))
add_child(browser)

await browser.refresh()

for entry in browser.filtered():
    print(entry.describe())
    # 127.0.0.1:27016  A dot server  dm_atrium  8/32  14 ms
```

Asking one server everything, for the details panel when a player clicks a row:

```gdscript
await browser.query(entry.target, PackedStringArray(["info", "players", "rules"]))
for player in entry.player_list:
    print(player["name"], player["score"])
```

## Sources

A browser knows how to ask a server what it is. It has no idea which servers exist —
that is a different problem with a different answer per deployment.

| | |
| --- | --- |
| `DotBrowserSourceList` | Addresses typed in, or a JSON file you ship. |
| `DotBrowserSourceBackbone` | A community's listing on the TMC backbone, read through a duck-typed client. |
| your own | Subclass `DotBrowserSource` and return targets. |

A source produces **addresses**, never player counts. What a server is, is what the
server says when asked — a listing that has not heard from a server in ten minutes
still lists it, and the player clicking it wants to know that before they connect.

## In a browser build

A web page cannot open a UDP socket, so it can never speak A2S at any price. dot-server
serves DQP as plain JSON over a WebSocket for exactly this, and `Protocol.AUTO` picks
it automatically when the platform has no UDP — the capability, not the platform name.

## Validating

```bash
godot --headless --path . --import
godot --headless --path . res://examples/browser_selftest.tscn
# 113 checks, including a real query over a real loopback socket.
```
