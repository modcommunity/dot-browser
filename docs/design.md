# dot-browser design

Why the addon is shaped the way it is, and why the obvious alternative is wrong at each point. The rules are one line each in [CLAUDE.md](../CLAUDE.md).

## The deliberate duplication, and how it is kept honest

`DotBrowserDqp` is a second implementation of a wire format dot-server-query already implements. It has to be: only dot-core may ever be a hard dependency, and in GDScript a script that merely mentions an absent `class_name` fails to parse and takes every script referencing it down with it. Naming `DotQueryProtocol` would make a server browser impossible to ship without a dedicated server installed.

Two implementations of one format is also exactly the shape that has bitten this family repeatedly (a caller asking for one method name while the provider offered another; a value written under one name and read under another). So the self-test does not check this codec against itself. Its fixtures (`GOLDEN_QUERY`, `GOLDEN_PING`, `GOLDEN_CHALLENGE` in `examples/browser_selftest.gd`) are bytes `DotQueryProtocol` actually produced, pasted in as hex. If the two ever drift, a fixture fails rather than a browser quietly showing nothing. Regenerate them from dot-server-query, never from here.

## A2S counts bots as players

A2S's player-count byte is `humans + bots`; the reference implementations have always written it that way, and so does dot-server-query, with the bot count in a byte of its own. A browser that shows the first number shows a server with eight bots and nobody on it as an eight-player server, and the player who joins finds an empty map.

`DotBrowserA2s.parse_info` subtracts, clamps at zero (a server whose bot byte exceeds its player byte is describing something impossible, and a negative count sorts to the top of a list), and reports `players` as humans. Every other field it produces uses DQP's names, so a `DotBrowserEntry` never learns which protocol answered it.

Compressed A2S multi-packet is not supported. That framing differs between implementations and is the single most common source of broken query clients; a browser that guesses wrong shows garbage rather than nothing.

## The fan-out

A refresh is N concurrent queries, and GDScript has two obvious spellings for that, both wrong: appending a void coroutine is a parse error, and awaiting a per-worker signal hangs when a worker finishes synchronously, which on a loopback is all of them. The family's working shape is bare calls plus a member counter.

Here a query is an object with `poll(now_ms)`, `DotBrowser` pumps them in `_process`, and `_active` plus `_pending` is the counter. `refresh_known()` checks `_refreshing` after filling the active set, so a refresh that completed inside `_fill_active()` skips the await entirely.

`DotBrowserQuery` is a real base class rather than a duck-typed interface, which is unusual for this family. The rule about duck typing is a rule about cross-repository seams; three classes inside one addon that must not drift are better held together by the compiler, and the alternative was `client.call("poll", now)` returning a Variant at every call site, which throws away the return type the whole design turns on.

## Decisions that look arbitrary and are not

- **`concurrency` defaults to 8.** A burst of UDP to hundreds of addresses at once looks like a scan to anything watching a home connection, and a thousand at full parallelism loses replies to the receive buffer long before it saturates a link.
- **Identity is the game port, not the query port.** A query port that moves must not create a second row a player thinks is a new server.
- **A timeout does not zero the player counts.** A row that flickers to zero on one dropped datagram is a row nobody trusts; a stale count beside an "offline" marker is more honest than a fresh zero.
- **An unmeasured ping is -1 and sorts last.** Reading it as zero puts every server nobody has reached above every server somebody has.
- **Every sort has one stable tie-break.** Without it two servers with equal ping swap places on every refresh and the row a player is about to click moves.
- **An `unchanged` response applies nothing.** It carries a revision and no sections; applying it as a full one would blank every field, which is the failure a conditional refresh exists to avoid.
- **The AUTO fallback to A2S runs on a timeout or a parse failure, never on a refusal.** A server that answered DQP with an error understood the question.
- **`DotBrowserTarget.is_plausible_host` refuses an address with a space in it.** Without it a typo in a shipped list becomes a socket to nowhere and a row that reads "offline": a server that looks down rather than a line that was never an address.

## Where it runs

| | |
| --- | --- |
| Desktop, mobile | DQP and A2S over UDP, and the WebSocket form if a server offers it. |
| Browser | DQP over WebSocket only. A tab cannot open a UDP socket, so A2S is unreachable at any price. `Protocol.AUTO` picks the WebSocket form from `DotPlatform.has_udp()`: the capability, not the platform name, because a desktop build behind a firewall that blocks UDP is in the same position. |

`DotBrowserWsClient` does not upgrade `ws://` to `wss://` on a secure page. `DotWeb.is_secure_context()` is not "the page is HTTPS" (a browser treats `http://localhost` as a trustworthy origin), and dot-core's transport once upgraded every development page's socket and failed against a server with no certificate. The scheme is the caller's.

## Sources, and the site's listing

A `DotBrowserSource` produces addresses. `DotBrowserSourceList` is a fixed list; `DotBrowserSourceBackbone` reads website-city's `GET /api/content/server/list` (contract: website-city `docs/api/public-content-api.md#the-server-listing`): `data` rows of `host`, `port`, `queryPort`, `protocols`, `app`, paged by `pagination.totalPages`, filtered to one game by `?app=<slug>`. It also reads the looser shapes a community's own listing might send (a bare array, `servers`, `ip`/`address`, `query_port`).

It is anonymous, over dot-core's `DotHttp`, and never goes through dot-auth. The first version took a duck-typed dot-auth `DotBackboneClient` and called `get_integration(path)`, which could not have worked: that client prefixes every path with `/api/integration/v1/` and sends a server's integration token, which a player's game does not have. The listing is public, so nothing is needed but an origin.

Configuration is `DotBrowserBackboneConfig` (`--browser-*`, `DOT_BROWSER_*`), and an empty `backbone_url` turns the source off: a browser that reaches out to a website as it opens is a surprise in a LAN build or a test. `max_pages` caps how much of a long listing one refresh reads, because every row is a packet the browser sends next. The source is a `RefCounted` and HTTP needs a node in the tree, so `DotBrowser.add_source` calls `DotBrowserSource.attached(browser)` and the source puts its own `DotHttp` under the browser unless `http` was assigned.

Every field a source carries about a server is discarded and asked of the server directly. A listing is a place to find servers, not a source of truth about what they are doing: a site that has not heard from a server in ten minutes still lists it.

A listing hands out names as well as IPs (a server whose team addresses it by hostname is listed by that name), and `PacketPeerUDP.connect_to_host` takes only an IP. So the UDP clients look a name up first through the engine's threaded resolver (`DotBrowserQuery.lookup_begin` / `lookup_poll`), preferring an IPv4 answer, and a name that does not resolve is an offline row. Before this, every hostname-listed server showed as refused, with an "Invalid IP address" engine error per row.

`examples/backbone_listing.tscn` is the round trip against a real site: `-- --browser-backbone-url=http://127.0.0.1:3002 --browser-app=hungario --expect=127.0.0.1:27081` reads the listing, queries every row, and exits 0 only if the expected server was listed and answered.

## Deliberately not here

- **A window.** No scene, no table, no theme. `DotBrowserEntry.describe()` gives you a row and dot-ui gives you somewhere to put it.
- **A master server.** Nothing announces itself to a list here. The site listing above is the nearest thing, and a server reaches it by being listed on the site, not by anything in this addon.
- **LAN discovery.** DQP has no broadcast form, and a subnet sweep is a different thing with different consequences. A `DotBrowserSource` that sweeps is twenty lines and belongs to whoever wants it.
- **Connecting.** A browser produces an address. What a game does with one is dot-server's client link, and pretending otherwise would put a transport in here.
