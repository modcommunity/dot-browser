# dot-browser

The server browser half: a query client that speaks DQP over UDP, DQP over a
WebSocket and A2S, plus a list model with sources, filters, sorting, favourites and
history.

**The distributable is `addons/dot_browser/`.** It requires [dot-core](../dot-core),
a separate repository, and nothing else.

```bash
# Local development setup — the symlink is gitignored on purpose.
ln -s ../../dot-core/addons/dot_core addons/dot_core
```

## Why this exists

From the family CLAUDE.md's list of gaps: *"there is no query client, so nothing in
the family shows a server browser."* dot-server has answered A2S and its own DQP
since it was written, over UDP and over WebSocket, with a challenge, fragmentation,
conditional polling and a documented protocol — and nothing had ever sent it a
datagram. That is this family's most repeated shape one level up: a whole protocol
produced correctly and consumed by nobody.

## The deliberate duplication, and how it is kept honest

`DotBrowserDqp` is a **second implementation of a wire format dot-server already
implements**. It has to be: only dot-core may ever be a hard dependency, and in
GDScript a script that merely *mentions* an absent `class_name` fails to parse and
takes every script referencing it down with it. Naming `DotQueryProtocol` would make
a server browser impossible to ship without a dedicated server installed.

Two implementations of one format is also exactly the shape that has bitten this
family repeatedly — dot-map asking a cloud client for `ensure()` when it offered
`acquire()`; a punishment written under one name and read under another. So the
self-test does **not** check this codec against itself. Its fixtures are bytes
`DotQueryProtocol` actually produced, pasted in as hex:

```gdscript
const GOLDEN_QUERY := "445150310104070000000000000001000000efcdab8967452301..."
```

If the two ever drift, a fixture fails rather than a browser quietly showing nothing.
**Regenerate them from dot-server, never from here.**

## The A2S trap that is worth the whole file

A2S's player-count byte is `humans + bots`. Source has always written it that way and
so does dot-server; the bot count has a byte of its own. A browser that shows the
first number shows a server with eight bots and nobody on it as an eight-player
server, and the player who joins finds an empty map.

`DotBrowserA2s.parse_info` subtracts, clamps at zero (a server whose bot byte exceeds
its player byte is describing something impossible, and a negative count sorts to the
top of a list), and reports `players` as humans. Every other field it produces uses
**DQP's names**, so a `DotBrowserEntry` never learns which protocol answered it.

## The fan-out

A refresh is N concurrent queries and GDScript has two obvious spellings for that,
both wrong — appending a void coroutine is a parse error, and awaiting a per-worker
signal hangs when a worker finishes synchronously, which on a loopback is all of
them. The family's working shape is bare calls plus a member counter.

Here that is: a query is an object with `poll(now_ms)`, `DotBrowser` pumps them in
`_process`, and `_active` plus `_pending` *is* the counter. `refresh_known()` checks
`_refreshing` **after** filling the active set, so a refresh that completed inside
`_fill_active()` skips the await entirely.

`DotBrowserQuery` is a real base class rather than a duck-typed interface, which is
unusual for this family. The rule about duck typing is a rule about *cross-repository*
seams; three classes inside one addon that must not drift are better held together by
the compiler — and the alternative was `client.call("poll", now)` returning a Variant
at every call site, which throws away the return type the whole design turns on.

## Decisions that look arbitrary and are not

- **`concurrency` defaults to 8.** A burst of UDP to hundreds of addresses at once
  looks like a scan to anything watching a home connection, and a thousand at full
  parallelism loses replies to the receive buffer long before it saturates a link.
- **Identity is the game port, not the query port.** A query port that moves must not
  create a second row a player thinks is a new server.
- **A timeout does not zero the player counts.** A row that flickers to zero on one
  dropped datagram is a row nobody trusts; a stale count beside an "offline" marker
  is more honest than a fresh zero.
- **An unmeasured ping is -1 and sorts last.** Reading it as zero puts every server
  nobody has reached above every server somebody has.
- **Every sort has one stable tie-break.** Without it two servers with equal ping
  swap places on every refresh and the row a player is about to click moves.
- **An `unchanged` response applies nothing.** It carries a revision and no sections;
  applying it as a full one would blank every field, which is the failure a
  conditional refresh exists to avoid.
- **The AUTO fallback to A2S runs on a timeout or a parse failure, never on a
  refusal.** A server that answered DQP with an error understood the question.
- **`is_plausible_host` refuses an address with a space in it.** Without it a typo in
  a shipped list becomes a socket to nowhere and a row that reads "offline" — a
  server that looks down rather than a line that was never an address.
- **Compressed A2S multi-packet is not supported.** That framing differs between
  engine branches and is the single most common source of broken query clients; a
  browser that guesses wrong shows garbage rather than nothing.

## Where it runs

| | |
| --- | --- |
| Desktop, mobile | DQP and A2S over UDP, and the WebSocket form if a server offers it. |
| **Browser** | **DQP over WebSocket only.** A tab cannot open a UDP socket, so A2S is unreachable at any price. `Protocol.AUTO` picks the WebSocket form from `DotPlatform.has_udp()` — the capability, not the platform name, because a desktop build behind a firewall that blocks UDP is in the same position. |

`DotBrowserWsClient` does **not** upgrade `ws://` to `wss://` on a secure page.
`DotWeb.is_secure_context()` is not "the page is HTTPS" — a browser treats
`http://localhost` as a trustworthy origin — and dot-core's transport once upgraded
every development page's socket and failed against a server with no certificate.

## Validating changes

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done
godot --headless --path . res://examples/browser_selftest.tscn
# 10 sections, 113 checks. The last one boots a DQP server on the loopback and
# runs the whole browser through it.
```

## Things deliberately not here

- **A window.** No scene, no table, no theme. `DotBrowserEntry.describe()` gives you
  a row and dot-ui gives you somewhere to put it.
- **A master server.** dot-server has no heartbeat and nothing announces itself
  anywhere yet; `DotBrowserSourceBackbone` reads a listing that a deployment has to
  be publishing. That is the other half of this gap and it is not in this addon.
- **LAN discovery.** DQP has no broadcast form, and a subnet sweep is a different
  thing with different consequences. A `DotBrowserSource` that sweeps is twenty
  lines and belongs to whoever wants it.
- **Connecting.** A browser produces an address. What a game does with one is
  dot-server's client link, and pretending otherwise would put a transport in here.
- **Trusting a listing.** Every field a source carries about a server is discarded
  and asked of the server directly.
