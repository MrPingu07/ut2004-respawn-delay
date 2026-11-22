# Spectator banner broadcast

Detailed design of the RespawnDelay spectator overlays: the bottom-screen
typewriter banner, its server-authored broadcast, the client-side HUD takeover,
and the adjacent beacon/countdown behaviour. For the wider respawn design see
[APPROACH.md](APPROACH.md); for engine-level findings see
[FINDINGS.md](FINDINGS.md).

This document describes the implementation rather than the requirements. Code
references are relative to `RespawnDelay/Classes/`.

---

## 1. What the system does

While a human player is waiting out a RespawnDelay respawn, the mutator can:

1. **Replace the stock HUD** with `RespawnDelayBannerHUD`.
2. **Draw a broadcast banner** at the bottom of the screen. The text is authored
   once by the server and replicated to every client, so all waiting players
   see the same message in the same animation phase. **This live feed is an
   effective broadcast system fully synchronized for all players in the server:
   the server picks one message, expands tokens once, and replicates the
   finished string plus a cycle timestamp. Every waiting player (and even
   players who die mid-cycle) draws the identical text at the identical typewriter
   phase, like a radio feed tuned to the same station.**
3. **Draw custom beacons** over living players (`RespawnDelayBeaconInteraction`),
   team-coloured in team games and white in solo modes.
4. **Keep the existing centre-screen countdown** (`RespawnDelayCountdown`)
   working in the replacement HUD.

Banner and beacons are independently switchable (`EnableBanner`,
`EnableBeacons`). The countdown has its own `Countdown` switch and is not part
of the broadcast.

---

## 2. Why a broadcast, and why the old feed was private

The first version expanded the message on each client. Every waiting player:

* picked the next line from its own shuffled bag (`Rand`),
* rolled its own `$RANDOM…` values,
* expanded tokens from its own replicated state,
* started the typewriter at its own death.

Two players waiting at the same time therefore usually saw different text,
different random numbers, and unrelated animation phases. Even the message pool
was not guaranteed to match, because `RespawnDelayFeed` is `config(RespawnDelay)`
and was read from each machine's own ini.

The current design makes the **server** the single author of the broadcast:

```
server                                    every client
------                                    -------------
shuffle one bag                           receive CurrentText
pick one line                             receive CycleStart
expand tokens once          ──────────▶   anchor the local phase
replicate text + cycle      (reliable)    draw the same text
```

`$RANDOM…` and scores are now frozen for the whole cycle, so the message cannot
change halfway through typing.

---

## 3. Component map

| class / file | runs on | responsibility |
|---|---|---|
| `RespawnDelay.uc` | server (authority) | spawns the broadcast, drives its cycle, decides when a player needs the overlays, sends the client hook |
| `RespawnDelayBroadcast.uc` | server + clients | server-authoritative broadcast state: message bag, token expansion, `CurrentText`, `CycleStart` |
| `RespawnDelayFeed.uc` | server (normal path) / client (fallback) | config-backed message pool, token expansion helpers, team-only detection |
| `RespawnDelayHUDMessage.uc` | both (hook) | invisible `LocalMessage`; `ClientReceive` performs the HUD swap and beacon attach/detach on the owning client |
| `RespawnDelayBannerHUD.uc` | client | replacement HUD; draws the banner, team score/time, suppresses native beacons/vehicle names; finds the broadcast actor |
| `RespawnDelayBeaconInteraction.uc` | client | renders living-player nameplates through the local `InteractionMaster` |
| `RespawnDelayCountdown.uc` | client | existing centre-screen countdown `LocalMessage`, drawn by the HUD |

The mutator does **not** assign `PlayerController.myHUD` or
`Player.InteractionMaster` directly. Both objects are client-side; assigning
them on the server has no effect on a network client.

---

## 4. Lifecycle

### 4.1 Install

`RespawnDelay.RegisterDeath()` calls `SetSpectatorOverlays(PC, true)` as soon as
a human death is registered. This is deliberate: the banner and beacons must
cover the whole wait, including the death-camera hold-off. Installing only at
`StartSpectating()` would leave them on screen for one tick when
`ServerCycle <= SpectateDelay` (the Arena 3 s preset).

`StartSpectating()` sends the same activation again. It is idempotent:

* the banner install reuses the existing `RespawnDelayBannerHUD`;
* the beacon attach reuses an existing `RespawnDelayBeaconInteraction`.

### 4.2 Teardown

The overlays are removed on every path that ends a wait:

* the player respawns (the supervisor sees `PC.Pawn != None`);
* the game takes the controller over (`RoundEnded`, MaxLives, round reset);
* Assault round transition;
* the scheduled respawn keeps failing and the controller is handed back;
* match end / `bGameEnded`;
* logout (`NotifyLogout`).

Every removal sends `SetSpectatorOverlays(PC, false)`, which restores the saved
stock HUD and detaches the beacon interaction.

The interaction also has its own safety net: `Tick()`/`PostRender()` call
`Cleanup()` when `PC.Pawn != None` or the controller disappears.

---

## 5. Client takeover protocol

### 5.1 The hook message

`RespawnDelayHUDMessage` is an invisible `LocalMessage` with empty
`GetString()`, no lifetime and no console/chat output. The server calls:

```uc
PC.ReceiveLocalizedMessage(class'RespawnDelayHUDMessage', Flags);
```

`PlayerController.ReceiveLocalizedMessage` is a reliable server→client RPC. On
the owning client it invokes `RespawnDelayHUDMessage.ClientReceive()`, which is
where the real work happens.

`Switch` is a bit mask:

| value | meaning |
|---|---|
| `0` | teardown: restore the stock HUD, detach beacons |
| `1` | install the banner HUD |
| `2` | install the beacon interaction |
| `3` | both |

The server builds the mask from `EnableBanner` / `EnableBeacons`; both disabled
means no message is sent.

### 5.2 Banner install / restore

`InstallBannerHUD(P)`:

1. Ignores the call if the player already has a `RespawnDelayBannerHUD`
   (idempotent re-sends keep the saved originals intact).
2. Spawns `RespawnDelayBannerHUD` owned by the `PlayerController`.
3. Stores the current HUD class in `BannerHUD.OriginalHUDClass` and its
   scoreboard class in `BannerHUD.OriginalScoreBoardClass`.
4. Assigns `P.myHUD = BannerHUD`.
5. Re-applies the original scoreboard class so F1 keeps working.

`RestoreBannerHUD(P)` spawns a fresh instance of `OriginalHUDClass`, restores
its scoreboard class, points `P.myHUD` at it, and destroys the banner HUD. The
original classes live on the banner HUD itself, so no extra server-side
ReplicationInfo is needed.

### 5.3 Beacon attach / detach

`InstallBeaconInteraction(P)` scans `P.Player.LocalInteractions` for an existing
`RespawnDelayBeaconInteraction`. If none exists it calls:

```uc
P.Player.InteractionMaster.AddInteraction(
    "RespawnDelay.RespawnDelayBeaconInteraction", P.Player);
```

`DetachBeaconInteraction(P)` calls `Cleanup()` on every one it finds.
`Cleanup()` removes itself from the `InteractionMaster`.

---

## 6. Broadcast state machine

### 6.1 Creation

`RespawnDelay.PostBeginPlay()` spawns the RI only on the authority and only
when the banner is enabled:

```uc
if (Role == ROLE_Authority && EnableBanner && Broadcast == None)
{
    Broadcast = Spawn(class'RespawnDelayBroadcast', Self);
    if (Broadcast != None)
        Broadcast.InitBroadcast();
}
```

`InitBroadcast()` sets `CycleStart = Level.TimeSeconds`, stores
`CycleLength = TOTAL_CYCLE` (22 s), reads `bTeamGame`, and selects the first
message.

### 6.2 Cycle advance

The mutator's existing 20 Hz supervisor timer calls
`Broadcast.UpdateBroadcast()` once per tick. `UpdateBroadcast()` advances when
`Level.TimeSeconds - CycleStart >= CycleLength`:

```uc
while (Level.TimeSeconds - CycleStart >= CycleLength)
{
    CycleStart += CycleLength;
    AdvanceMessage();
}
```

`CycleStart` moves by whole cycle lengths, so boundaries stay aligned with the
original anchor instead of drifting with timer jitter. A pathological hitch is
capped at eight skipped cycles, after which the clock is re-anchored.

### 6.3 Message selection

`AdvanceMessage()` runs on the server only and:

1. Reads `class'RespawnDelayFeed'.default.Messages` (the server's config).
2. Rebuilds and reshuffles a no-repeat bag when the source length changes or
   the bag empties.
3. Skips empty entries.
4. Skips lines with team-only tokens in non-team games.
5. Expands the template **once** with `RespawnDelayFeed.ExpandTokens(...)`.
6. Stores the final string in `CurrentText` and logs it.

The bag is server-local; clients never see the template or the random draws.

### 6.4 Replication

Replicated from server to every client:

```uc
reliable if (Role == ROLE_Authority)
    CurrentText, CycleStart, CycleLength, MessageIndex, bTeamGame;
```

These change only once per cycle, so the traffic is a handful of bytes every
ten seconds. Relevant defaults on the RI:

| property | value | why |
|---|---|---|
| `bAlwaysRelevant` | True | every client needs the broadcast, including players not currently waiting |
| `RemoteRole` | `ROLE_SimulatedProxy` | the actor exists on clients as a simulated proxy |
| `bNetNotify` | True | required for `PostNetReceive()` to fire |
| `bNetInitial` | True | send the initial state when a client joins |
| `NetUpdateFrequency` | 30 | cycle changes reach clients within roughly one frame-to-33 ms window |

### 6.5 Client phase anchoring

Absolute `Level.TimeSeconds` is not guaranteed to have the same origin on the
server and every client. The broadcast therefore anchors the animation to the
**replication receipt**:

* `PostNetBeginPlay()` records `LocalCycleStart = Level.TimeSeconds`.
* `PostNetReceive()` compares the newly received `CycleStart` with
  `LastSeenCycleStart`; on a change it re-anchors `LocalCycleStart`.
* `GetCycleElapsed()` returns the server-clock delta on the authority, and the
  local-anchor delta on clients.

Because the actor is `bAlwaysRelevant`, clients track cycles even while nobody
is waiting. A player who dies mid-cycle joins the broadcast already in
progress, rather than starting the message from the beginning.

---

## 7. Message feed and tokens

### 7.1 Config source

`RespawnDelayFeed` is `config(RespawnDelay)`, so the server reads:

```ini
[RespawnDelay.RespawnDelayFeed]
Messages=RESPAWN DELAY ACTIVE
Messages=WAITING FOR NEXT REINFORCEMENT WAVE
Messages=$MAPNAME - $GAMETYPE - $PLAYERCOUNT COMBATANTS
Messages=$SERVERNAME
```

`Messages` is a dynamic string array: use repeated bare `Messages=` keys, not
`Messages(0)=...`.

The client-side fallback feed reads the same section, but in the normal path the
text always comes from the server's replicated `CurrentText`.

### 7.2 Viewer-agnostic semantics

Because the server expands once for everybody, no token may depend on who is
looking. The important consequence is:

* `$TOPTEAMSHORT`, `$TOPTEAMNAME`, `$TOPTEAMFRAGGER` refer to the team of the
  **overall scoreboard leader**, not “my team”.
* `$LEADTEAM*` still refers to the team with the higher total score.
* In non-team games, every line containing a team-only token is skipped
  entirely (the expander also blanks those tokens as a safety net).

### 7.3 Token reference

Expansion is case-insensitive (`ExpandTokens` uppercases the template first and
uppercases the final string). Longest tokens are replaced first.

| token | value | fallback |
|---|---|---|
| `$MAPNAME` | map title, or the map filename when untitled | `Unknown Arena` |
| `$SERVERNAME` | replicated server name | `Local Arena` |
| `$GAMETYPE` | replicated game name | `Tournament` |
| `$PLAYERCOUNT` | non-spectators in `GRI.PRIArray` (bots and dead included) | `0` |
| `$TOPFRAGGER` | global score leader's name | `Someone` |
| `$TOPFRAGGERSCORE` | global score leader's score | `lots of` |
| `$TOPTEAMNAME` | display name of the leader's team | `Our Team` / `Neither` |
| `$TOPTEAMSHORT` | team name with a trailing ` TEAM` removed | `Our Team` / `Neither` |
| `$TOPTEAMFRAGGER` | top scorer on the leader's team | `Someone` |
| `$LEADTEAMNAME` | team with the higher total score | `Neither` |
| `$LEADTEAMSHORT` | short form of that team | `Neither` |
| `$LEADTEAMFRAGGER` | top scorer on the leading team | `Someone` |
| `$LEADTEAM` | `Red`, `Blue`, or `Neither` | `Neither` |
| `$REDVAL` / `$BLUEVAL` | team scores as integers | `0` |
| `$GOALSCORE` | `GRI.GoalScore`, or “No Limit” | `No Limit` |
| `$TOTALFRAGS` | sum of every non-spectator score | `0` |
| `$HIGHESTSCORE` | highest individual score | `0` |
| `$LEADMARGIN` | highest minus second-highest score | `0` |
| `$MATCHSTATUS` | `Warmup` / `Live` / `Overtime` / `Concluded` | `Unknown` |
| `$TIMEELAPSED` | `m:ss` from `GRI.ElapsedTime` | `0:00` |
| `$TIMEREMAINING` | `m:ss`, or `Warmup` / `Overtime` / `No Limit` | `Unknown` |

`$RANDOM<min>_<max>` is expanded server-side, so all clients share the roll:

| form | result |
|---|---|
| `$RANDOM1_9` | integer 1–9 |
| `$RANDOM25_50` | integer 25–50 |
| `$RANDOM1_50K` | 1–50000, printed grouped (`43.781`) |
| `$RANDOM1_5M` | 1–5000000, clamped to the hard ceiling |

Malformed random tokens are left untouched and scanning resumes after them.

### 7.4 Team-only detection

`HasTeamOnlyTokens()` checks for any of:

```
$TOPTEAM   $LEADTEAM   $REDVAL   $BLUEVAL
```

A line containing one of these is skipped in non-team games rather than
broadcast as a half-empty sentence. This is broader than token blanking on
purpose.

---

## 8. Banner rendering

### 8.1 Draw paths

`RespawnDelayBannerHUD` draws the banner in both HUD paths:

* `DrawSpectatingHud()` — the stock spectator path (`state Spectating`); also
  calls `DisplayLocalMessages()` because this path does not call
  `Super.DrawHud()`.
* `DrawHud()` — the death-camera path (`state Dead`, `PawnOwner == None`);
  calls `Super.DrawHud()` and then `DrawBanner()`.

The banner therefore covers the whole wait, including the hold-off before
spectating starts.

### 8.2 Finding the broadcast

`FindBroadcast()` caches the result of
`foreach AllActors(class'RespawnDelayBroadcast', B)`.
`GetBroadcastState()` returns false when the actor is absent or `CurrentText` is
still empty. In that case the HUD falls back to its local `PickMessage()` feed,
which mirrors the broadcast rules. This fallback only matters for the first
frame(s) before the RI replicates; in normal play the broadcast always wins.

### 8.3 Layout

Scaling uses `Scale = C.ClipY / 768.0` (1024×768 is the 1.0 reference).

| element | geometry / colour |
|---|---|
| dark band | full width, `80 * Scale` tall, anchored to the bottom, black at alpha 204 |
| top/bottom stripes | `3 * Scale` tall |
| Unreal logo | `LastManStanding.LMSLogoSmall`, `BannerHeight + 16*Scale` tall, `8*Scale` above the band |
| message | `FontEurostile17` at `0.8 * Scale`, word-wrapped at the last space before 60 characters, each line centred horizontally in the area right of the Unreal logo, whole block centred vertically, team colour |
| team score counter | team games only, top centre, 2× font, red/blue |
| match clock | team games only, above the score |

Team colours:

| context | stripe | text |
|---|---|---|
| red team | `255,0,0` | `255,100,100` |
| blue team | `51,102,255` | `100,150,255` |
| non-team mode | white | white |

The stripe uses the viewed living target's team when available, otherwise the
waiting player's own team; non-team modes are always white.

The message deliberately does **not** use `GetFontSizeIndex()`: that HUD font
ladder stops growing past the 1600 px breakpoint, so on larger screens the feed
would keep its absolute pixel size and become proportionally smaller. A fixed
`FontEurostile17` scaled by `0.8 * Scale` keeps the feed the same size relative
to the banner at every resolution.

Messages longer than `FEED_WRAP_CHARS` (60) are word-wrapped into additional
lines. The break is the last space at or before the 60-character limit, so a
word is never split; only a single word longer than the limit falls back to a
hard break. The limit was reduced from 70 because the Unreal Tournament logo on
the left occupies horizontal space; the text area starts at the logo's right
edge and extends to the screen's right edge. The complete line block is measured
first, then centred vertically between the top and bottom stripes, so a
two-line message sits in the middle of the band rather than being anchored to
one edge. Each line is centred horizontally **within the text area** (right of
the logo), and the typewriter reveal and delete phases operate on the wrapped
layout in place.

### 8.4 Animation

`TOTAL_CYCLE = 22.0` (matching the TeamDirector booth feed) is divided into a
full typewriter + delete cycle with holding periods:

| time | phase | behaviour |
|---|---|---|
| 0.0–1.0 s | 0 | cursor flicker (3 blinks, ends OFF) |
| 1.0–2.0 s | 1 | cursor blink |
| 2.0–3.0 s | 2 | typewriter: text appears over ~1 s |
| 3.0–6.0 s | 3 | cursor blink during hold |
| 6.0–11.0 s | 4 | full text held; cursor OFF |
| 11.0–12.0 s | 5 | cursor flicker (pre-delete) |
| 12.0–13.0 s | 6 | cursor blink (pre-delete) |
| 13.0–14.0 s | 7 | delete: text removed character by character |
| 14.0–17.0 s | 8 | cursor blink (post-delete) |
| 17.0–22.0 s | 9 | rest: empty, waiting for next cycle |

At 22 s the shared cycle advances and a new message replaces the old one. The
full typewriter + delete animation ensures the banner behaves like a
professional broadcast ticker: text types in, holds for readability, then
deletes out before the next message. This matches the TeamDirector booth feed
timing exactly.

The text is centred and clipped by the canvas. No width filtering or scrolling
is applied; token values such as player and server names vary legitimately.

### 8.5 Suppressed native drawing

The replacement HUD intentionally overrides:

* `DrawVehicleName()` — removes the native forced vehicle names.
* `DrawCustomBeacon()` — removes native team beacons; the custom interaction
  draws them instead.
* `DrawCrosshair()` — waiting players have no crosshair.

### 8.6 Do not override `DrawMessage()`

`RespawnDelayCountdown` is a `bIsSpecial` `LocalMessage`. `HudBase.
DisplayLocalMessages()` renders every such message through `DrawMessage()`.
An earlier empty `DrawMessage()` override in the banner HUD silently ate the
big countdown number. The override was removed and must not come back.

---

## 9. Beacons

`RespawnDelayBeaconInteraction` is a client-side `Interaction` attached through
the `InteractionMaster` while the player waits.

Rules:

* **Team game**: only living teammates.
* **Solo/non-team**: every living player, white.
* Data source: `GRI.PRIArray`, resolving each PRI's controller/pawn.
* No line-of-sight check: spectators see through walls, like the Director.
* Pawns behind the camera or outside the screen are skipped.

Each beacon draws three centred lines in the small font:

```
Name
HP [X]
Shield [X]
```

Colours match the banner: red `255,0,0`, blue `51,102,255`, white in solo.

There is no `Spectating` state guard. The interaction is only attached while the
player is waiting, so drawing during the death-camera hold-off is intentional
and required for short wave cycles.

---

## 10. Configuration

### 10.1 Mutator switches

In `UT2004.ini`:

```ini
[RespawnDelay.RespawnDelay]
EnableBanner=True
EnableBeacons=True
```

`EnableBanner` controls both the banner HUD and whether the server spawns the
broadcast RI. `EnableBeacons` controls only the interaction. The two are
independent; if both are off no client hook is sent.

### 10.2 Broadcast feed

In `RespawnDelay.ini`:

```ini
[RespawnDelay.RespawnDelayFeed]
Messages=RESPAWN DELAY ACTIVE
Messages=WAITING FOR NEXT REINFORCEMENT WAVE
Messages=$MAPNAME - $GAMETYPE - $PLAYERCOUNT COMBATANTS
Messages=$SERVERNAME
```

Use repeated `Messages=` keys. Empty entries are skipped. Lines with team-only
tokens are skipped automatically in solo games.

### 10.3 Cycle length

The broadcast cycle is the `TOTAL_CYCLE` constant in
`RespawnDelayBroadcast.uc` (22.0 s). The banner HUD has the same constant for
its local fallback; keep the two in sync when changing it.

---

## 11. Failure modes and fallbacks

| situation | result |
|---|---|
| broadcast RI has not replicated yet | HUD uses the local feed for that frame |
| broadcast RI missing entirely | every client uses its own local feed (previous behaviour) |
| client connects mid-cycle | content is correct; animation starts at the current message from the beginning and aligns at the next cycle boundary |
| client clock differs from server | no effect on phase; the local receipt anchor is used |
| network latency | phase differs by at most one net update (~33 ms) plus frame time |
| banner disabled | no RI is spawned, no HUD hook is sent |
| beacons disabled | only flag `1` is sent; no beacon interaction is attached |
| player respawns | hook `0` restores the stock HUD and detaches beacons; the interaction also self-cleans |
| HUD already installed | activation is idempotent; saved originals are preserved |
| scoreboard open (F1) | banner still draws; team score counter hides while `bShowScoreBoard` is true |

---

## 12. Diagnostics

Server log, once per broadcast cycle:

```
RespawnDelay: broadcast message 2: RANKIN - DEATHMATCH - 12 COMBATANTS
```

Client log, once per install/teardown:

```
RespawnDelay: installed banner HUD for <PC> (original XInterface.HudCDeathmatch)
RespawnDelay: attached beacon interaction for <PC>
RespawnDelay: restored original HUD for <PC>
RespawnDelay: detached beacon interaction for <PC>
```

If the client shows install/restore lines but no banner:

* confirm the client received the broadcast actor (it should be
  `bAlwaysRelevant`);
* confirm `bNetNotify=True` was not removed from
  `RespawnDelayBroadcast.uc`;
* confirm `banner message`/`broadcast message` logging appears on the server;
* confirm no other mutator replaces `myHUD` afterwards.

---

## 13. Known limitations

* **Content is a 22-second snapshot.** Scores, clock and `$RANDOM` values stay
  fixed for the cycle, which is what keeps the typewriter stable.
* **Late joiners start the current message at phase 0.** They align on the next
  cycle boundary. A player who was already connected and then dies mid-cycle
  joins in progress normally.
* **Phase is not frame-perfect.** It is anchored at replication receipt, so it
  differs by network update/frame time, not by absolute clock skew. This is the
  intended trade-off for not requiring synchronized wall clocks.
* **No viewer-specific tokens.** A broadcast cannot say “your team” or “you”.
  Use global concepts (`$TOPTEAM*` = leader's team, `$LEADTEAM*` = leading
  team).
* **Server config wins.** Clients do not need `RespawnDelay.ini` for the
  normal broadcast path; only the one-frame fallback uses local config.
* **The broadcast runs even when nobody is waiting.** This keeps one continuous
  schedule so a newly dying player joins mid-cycle. It costs one message
  selection every 22 seconds.

---

## 14. Extending the system

### Adding a token

1. Add the `ReplaceText(Msg, "$TOKEN", value)` call in
   `RespawnDelayFeed.ExpandTokens()`.
2. Put longer tokens before shorter ones when one is a prefix of another.
3. If the token is team-only, make sure `HasTeamOnlyTokens()` catches its
   prefix, or extend that function.
4. Add it to the table in section 7.3.
5. Remember: the token must be meaningful without knowing the viewer.

### Changing the cycle

Change `TOTAL_CYCLE` in both `RespawnDelayBroadcast.uc` and
`RespawnDelayBannerHUD.uc` (fallback), then rebuild.

### Changing the feed

Edit the server's `[RespawnDelay.RespawnDelayFeed] Messages=...` entries. No
client-side changes are needed; the text is replicated.

---

## 15. Source map

```
RespawnDelay/Classes/RespawnDelay.uc                 activation/teardown, broadcast tick
RespawnDelay/Classes/RespawnDelayBroadcast.uc        server-authoritative broadcast RI
RespawnDelay/Classes/RespawnDelayFeed.uc             message pool + token expansion
RespawnDelay/Classes/RespawnDelayHUDMessage.uc       invisible client hook / HUD swap
RespawnDelay/Classes/RespawnDelayBannerHUD.uc        replacement HUD + banner rendering
RespawnDelay/Classes/RespawnDelayBeaconInteraction.uc custom nameplates
RespawnDelay/Classes/RespawnDelayCountdown.uc        centre-screen countdown
docs/APPROACH.md                                     high-level respawn design
docs/FINDINGS.md                                     engine research
docs/BROADCAST.md                                    this document
```
