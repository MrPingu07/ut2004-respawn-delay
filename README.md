# RespawnDelay — a respawn-delay mutator for Unreal Tournament 2004

Team games respawn in **batches** on a global 10-second server cycle: when you
die with 5+ seconds left in the current cycle you spawn when it ends; die any
later and you wait exactly 10 seconds (pushed toward the next batch, capped).
Nobody waits outside the 5–10 second range, and players dying in the same
window come back together, like vanilla Assault's reinforcement waves.
Solo games keep the simple fixed rule: always 5 seconds.
Bots follow the same rules (in team games they join the batches too). While
waiting you are a spectator: `FIRE` cycles player views (own team in team
games, everybody in solo games), `ALT-FIRE` returns to your own free camera.
The wait is computed once when you die and stays locked until you respawn.

| mode | delay rule |
|---|---|
| Team games (TDM, CTF, BR, DOM, ONS, AS, TDM...) | global **10 s cycle**: ≥ 5 s left in the cycle → spawn at the cycle's end (5–10 s wait), otherwise → exactly **10 s** wait |
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
BatchCycleLen=10.000000
BatchMinLeft=5.000000
DeathCamTime=1.000000
Countdown=True
AffectBots=True
AffectInvasion=False
AffectAssault=True
```

* `BatchCycleLen` — team games only: length of the global reinforcement cycle;
  every multiple of it is a batch boundary.
* `BatchMinLeft` — team games only: deaths with at least this many seconds
  left in the cycle ride it out; later deaths wait a full `BatchCycleLen`
  (10 s), so waits always land in the `BatchMinLeft`–`BatchCycleLen` range.
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
