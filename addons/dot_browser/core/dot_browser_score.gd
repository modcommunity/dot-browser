@tool
class_name DotBrowserScore
extends RefCounted

## The one "Best" ranking, shared by the server list's Best sort and Quick Play.

const W_PING := 0.35
const W_FILL := 0.30
const W_FRIENDS := 0.20
const W_OFFICIAL := 0.15

## Ping at or above this scores zero.
const PING_CEILING_MS := 300
## Below this fill a server is still warming up; above it, it is filling.
const FILL_SWEET_SPOT := 0.75

## Returned for a server a party cannot fit in; sorts below every real score.
const NO_FIT := -1.0

## Score in 0..1, higher is better, or [constant NO_FIT]. [param friends] is the friends on the
## server, [param party_size] the seats the caller needs, [param official] whether the server is
## official or verified.
static func score(entry: DotBrowserEntry, friends: int = 0, party_size: int = 1, official: bool = false) -> float:
	if not entry.is_online() or entry.is_full() or entry.slots_free() < maxi(party_size, 1):
		return NO_FIT
	return (W_PING * ping_part(entry.ping_ms) + W_FILL * fill_part(entry.players, entry.max_players)
		+ W_FRIENDS * minf(float(maxi(friends, 0)), 3.0) / 3.0 + W_OFFICIAL * (1.0 if official else 0.0))


## 1 at zero ping, 0 at the ceiling. Unmeasured (-1) is a middling 0.25, never the best.
static func ping_part(ping_ms: int) -> float:
	if ping_ms < 0:
		return 0.25
	return clampf(1.0 - float(ping_ms) / PING_CEILING_MS, 0.0, 1.0)


## Busy but not full beats empty and beats packed: empty servers are rarely worth joining.
static func fill_part(players: int, max_players: int) -> float:
	if max_players <= 0 or players <= 0:
		return 0.0
	var ratio := clampf(float(players) / max_players, 0.0, 1.0)
	if ratio <= FILL_SWEET_SPOT:
		return ratio / FILL_SWEET_SPOT
	return 1.0 - 0.7 * (ratio - FILL_SWEET_SPOT) / (1.0 - FILL_SWEET_SPOT)
