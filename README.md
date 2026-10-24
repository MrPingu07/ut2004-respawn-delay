# RespawnDelay — a respawn-delay mutator for Unreal Tournament 2004

Team games respawn in **perfectly synchronized waves** on a global server cycle
(default 5 seconds, selectable in the Mutator GUI as one of five presets):
everyone dead within a cycle comes back together at the end of the next one, so
every spawn lands exactly on a cycle boundary and no wait ever falls outside
one to two cycles (**5–10 seconds** with the default). Solo games keep the
simple fixed rule: always 5 seconds.
Bots follow the same rules (in team games they join the same waves). While
waiting you are a spectator: `FIRE` cycles player views (own team in team
games, everybody in solo games), `ALT-FIRE` returns to your own free camera.
The wait is computed once when you die and stays locked until you respawn.

| mode | delay rule |
|---|---|
| Team games (TDM, CTF, BR, DOM, ONS, AS, ...) | global **wave cycle** (5 s default): die exactly on a cycle start → one full cycle wait (spawn at the imminent wave); die later → wait = **time remaining + cycle**, i.e. spawn together at the end of the next wave (always one to two cycles) |
| Solo games (DM, LMS, ...) | **5 s** |

While waiting you also get a live HUD countdown — "Respawn in 10, 9, 8, ..."
— rendered only on the waiting player's screen (never in the chat log), always
in white; the last 3 seconds are shown in a huge font. The number is scrubbed
from the screen the moment you respawn, so no stale counter ever survives.

**Assault**: the game type's vanilla "reinforcements" (respawn waves every
`ReinforcementsFreq` seconds, respawns refused between waves) are disabled at
match start, so the same delay rules apply there (`AffectAssault=True`; set
it false to keep vanilla waves and have the mutator stay off in Assault).

## Build

```bash
./make.sh
```

Builds the package through wine (`UCC.exe make`) into
`~/Juegos/UT2004/System/RespawnDelay.u` and deploys the `.int`/`.ucl`.
Requires `EditPackages=RespawnDelay` in `UT2004.ini` (already present here).

## Enable in-game

Add "Respawn Delay" to the mutator list in Instant Action / the server
browser, or run a map with:

```
open CTF-FaceClassic?mutator=RespawnDelay.RespawnDelay
```

## Configuration

`UT2004.ini`, section `[RespawnDelay.RespawnDelay]`:

```ini
[RespawnDelay.RespawnDelay]
Enabled=True
BaseDelay=5.000000
ServerCycle=5.000000
DeathCamTime=1.000000
Countdown=True
AffectBots=True
AffectInvasion=False
AffectAssault=True
```

* `ServerCycle` — team games only: length of the global wave cycle; waves
  land on its multiples of the server clock, waits span one to two cycles.
  Set it in the **Mutator GUI** ("Configure" screen after selecting the
  mutator) as one of five presets:

  | preset | cycle | waits | intended for |
  |---|---|---|---|
  | Arena [2s] | 2 s | 2–4 s | continuous chaos; near-instant respawns, batches happen mostly by accident from simultaneous explosions; Team Deathmatch |
  | Blitz [3s] | 3 s | 3–6 s | frenetic attack; fast-paced micro-batches; small maps and Capture the Flag |
  | Standard [5s] (default) | 5 s | 5–10 s | competitive balance; tactical flow and squad spawning in Onslaught and Assault |
  | Strategic [7s] | 7 s | 7–14 s | semi-tactical pacing; forces defenders to group into large waves before pushing |
  | Tactical [10s] | 10 s | 10–20 s | heavy combat simulation; teams respawn in full battalions for macro maps with heavy vehicles |
* `Countdown=False` hides the per-second HUD counter.
* Console while dead: `mutate respawnstatus` — remaining seconds.
* Extras: `BaseDelay` is the solo-mode wait; `AffectBots=False` leaves bots on
  their vanilla (instant) respawn; `AffectAssault=False` keeps Assault's
  vanilla reinforcement waves (the mutator stays inactive in Assault then);
  `AffectInvasion=True` applies delays on top of Invasion's wave respawn
  (off by default, the game already waits for the next wave).
* Network play: add `ServerPackages=RespawnDelay` to `UT2004.ini`
  `[Engine.GameEngine]` so joining clients can load the HUD message class
  (local / instant-action / listen play needs nothing).

## Documentation

* [docs/FINDINGS.md](docs/FINDINGS.md) — how UT2004 respawn/spectate actually
  works (verified against retail UnrealScript source) and what hooks exist.
* [docs/APPROACH.md](docs/APPROACH.md) — design, edge cases, config reference,
  test checklist.

## Notes on the previous attempt

A compiled-only mutator of the same name shipped in `System/` (fixed
"DelaySeconds=5", console `mutate setdelay`). Its binary was replaced by this
build; there was no source to salvage.
