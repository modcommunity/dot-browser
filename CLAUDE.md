# dot-browser

The server browser half: a query client that speaks DQP over UDP, DQP over a WebSocket and A2S, plus a list model with sources, filters, sorting, favourites and history. It ships no window.

Read the family [CLAUDE.md](../../CLAUDE.md) first.

**The distributable is `addons/dot_browser/`.** It requires [dot-core](../dot-core) and nothing else (`ln -s ../../dot-core/addons/dot_core addons/dot_core`, gitignored). It never names dot-server-query's classes or dot-auth's client.

## Read before

| Read | Before |
| --- | --- |
| [docs/design.md](docs/design.md) | changing a codec, the fan-out, sorting, sources or the WebSocket client: the duplicated DQP codec and its golden fixtures, A2S bots, the fan-out, the decisions that look arbitrary, where it runs, the listing, what is deliberately not here |

## Layout

| Path | What |
| --- | --- |
| `core/dot_browser_target.gd` | `DotBrowserTarget`: an address and a `Protocol` (`AUTO`, DQP, WebSocket, A2S); `is_plausible_host` |
| `core/dot_browser_entry.gd` | `DotBrowserEntry`: one row, in DQP's field names whatever answered |
| `core/dot_browser_filter.gd` | `DotBrowserFilter`: local filtering |
| `query/dot_browser_query.gd` | `DotBrowserQuery`: the base class with `poll(now_ms)` |
| `query/dot_browser_dqp.gd`, `_dqp_client.gd` | `DotBrowserDqp` (the second DQP codec), `DotBrowserDqpClient` (UDP) |
| `query/dot_browser_ws_client.gd` | `DotBrowserWsClient`: DQP over WebSocket; never upgrades the scheme |
| `query/dot_browser_a2s.gd`, `_a2s_client.gd` | `DotBrowserA2s` (`parse_info` subtracts bots), `DotBrowserA2sClient` |
| `runtime/dot_browser.gd` | `DotBrowser`: the node; `concurrency`, refresh, sorting |
| `runtime/dot_browser_favourites.gd` | favourites and history on disk |
| `sources/` | `DotBrowserSource`, `DotBrowserSourceList`, `DotBrowserSourceBackbone` |
| `examples/browser_selftest.tscn` | the suite; its last section runs the browser against a DQP server on the loopback |

Paths except `examples/` are in `addons/dot_browser/`.

## Running and testing

The family's two steps ([game-dev/CLAUDE.md](../../CLAUDE.md#validating-anything)), then `timeout 120 godot --headless --path . res://examples/browser_selftest.tscn`.

## Rules that bite

- The golden DQP fixtures come from dot-server-query's `DotQueryProtocol`; regenerate them there, never from this codec. [design](docs/design.md#the-deliberate-duplication-and-how-it-is-kept-honest)
- A2S `players` is humans: subtract bots, clamp at zero, and use DQP's field names. [design](docs/design.md#a2s-counts-bots-as-players)
- No compressed A2S multi-packet. [design](docs/design.md#a2s-counts-bots-as-players)
- Fan out with `poll` objects and the `_active`/`_pending` counter, never awaited per-worker signals; check `_refreshing` after `_fill_active()`. [design](docs/design.md#the-fan-out)
- Identity is the game port; a timeout keeps the old counts; unmeasured ping is -1 and sorts last; every sort has a stable tie-break; `unchanged` applies nothing. [design](docs/design.md#decisions-that-look-arbitrary-and-are-not)
- AUTO falls back to A2S on a timeout or parse failure, never on a refusal, and picks WebSocket from `DotPlatform.has_udp()`. [design](docs/design.md#where-it-runs)
- Never upgrade `ws://` to `wss://` from `is_secure_context()`. [design](docs/design.md#where-it-runs)
- Discard every field a listing carries; ask the server. [design](docs/design.md#sources-and-the-listing-nobody-publishes-yet)

## Open

- **`DotBrowserSourceBackbone` has nothing to read.** Its default `path`, `/api/content/server/list`, has no route on website-city main, and nothing else publishes a server listing for it. Not built yet on the site side; game-hungario's browser ships without it for that reason.

Deliberately not here: a window, a master server, LAN discovery, connecting. [design](docs/design.md#deliberately-not-here)
