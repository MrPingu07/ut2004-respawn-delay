# RespawnDelay — a respawn-delay mutator for Unreal Tournament 2004

Team games respawn in **perfectly synchronized waves** on a global server cycle
(default 5 seconds, selectable in the Mutator GUI as one of five presets):
everyone dead within a cycle comes back together at the end of the next one, so
every spawn lands exactly on a cycle boundary and no wait ever falls outside
one to two cycles (**5–10 seconds** with the default). Solo games use the same
selectable cycle length as a plain wait (default 5 seconds).
Bots follow the same rules (in team games they join the same waves). While
waiting you are a spectator: `FIRE` cycles living player views (own team in
team games, everybody in solo games), `ALT-FIRE` returns to your own free
camera. Dead players are skipped; if the player you are watching dies, the
camera stays at that death spot in free camera, and when nobody is alive you
get free camera automatically. The wait is computed once when you die and
stays locked until you respawn.

| mode | delay rule |
|---|---|
| Team games (TDM, CTF, BR, DOM, ONS, AS, ...) | global **wave cycle** (5 s default): die exactly on a cycle start → one full cycle wait (spawn at the imminent wave); die later → wait = **time remaining + cycle**, i.e. spawn together at the end of the next wave (always one to two cycles) |
| Solo games (DM, LMS, ...) | the same **selectable cycle length** as a plain wait (default 5 s) |

While waiting you also get a live HUD countdown — "Respawn in 10, 9, 8, ..."
— rendered only on the waiting player's screen (never in the chat log), always
in white; the last 3 seconds are shown in a huge font. The number is scrubbed
from the screen the moment you respawn, so no stale counter ever survives.

**Assault**: the game type's vanilla "reinforcements" (respawn waves every
`ReinforcementsFreq` seconds, respawns refused between waves) are disabled at
match start, so the same delay rules apply there (`AffectAssault=True`; set
it false to keep vanilla waves and have the mutator stay off in Assault).

**Onslaught spawn map**: the "Choose Your Spawn Point" map that pops up after
death may still be used to pick a power node during the wait — the choice is
remembered and used when the wave spawns you — but its "Spawn Here" button can
no longer respawn you early and skip the remaining delay. (Games with
`MaxLives` set, or matches in overtime, cannot use this per-player lock
safely, because the game reads the same flag to detect a match wipe; there the
spawn map keeps its vanilla instant-respawn behaviour.)

## Install

Download the latest `RespawnDelay-<version>.zip` from the
[Releases](https://github.com/MrPingu07/ut2004-respawn-delay/releases) page.
It is a normal UT2004 mutator package — no installer:

```
RespawnDelay-<version>.zip
├── README.md
└── RespawnDelay/
    ├── RespawnDelay.u      compiled mutator
    ├── RespawnDelay.ucl    mutator cache
    └── RespawnDelay.int    name and description for the mutator list
```

Extract the zip into your UT2004 installation folder (the one that contains
`System/`) on every client and on the server. The files land in
`RespawnDelay/` next to `System/` so `ucc` can find the package. Start the
game, open **Mutators**, enable **Respawn Delay**, and optionally press
**[Configure]**. When upgrading, overwrite the three `RespawnDelay.*` files.

For a server, add the mutator to the command line or server setup:

```
open CTF-FaceClassic?mutator=RespawnDelay.RespawnDelay
```

The server and its clients all need the same `RespawnDelay/RespawnDelay.u`;
clients joining an internet server can also get it from a redirect server.

## Build from source (developers)

Building needs a full UT2004 installation (the Windows edition, run through
Wine on Linux or natively on Windows) because `ucc make` compiles against the
retail packages.

```bash
export UT2004_DIR=/path/to/UT2004
./make.sh                       # compile, install, refresh prebuilt/
```

`make.sh` is idempotent: it links the package dir into the game root, makes
sure `EditPackages=RespawnDelay` is present in `UT2004.ini`, compiles
`System/RespawnDelay.u`, deploys `.int`/`.ucl`, and refreshes the tracked
release artifacts in `prebuilt/`.

### Packaging a release

GitHub Actions cannot compile UnrealScript, so the compiled package is
committed under `prebuilt/` and CI only zips it with `tools/package.sh`.
`make.sh` refreshes `prebuilt/`; `tools/package.sh` refuses to package if
the source classes changed since that build.

```bash
./make.sh                              # refresh prebuilt/ after source changes
tools/package.sh 1.7                   # -> dist/RespawnDelay-1.7.zip
tools/release.sh 1.7 --publish         # build + package + create/update the GitHub release
```

Commit `prebuilt/` together with any source change, otherwise the release
workflow will (correctly) fail the staleness check.

## Configuration

`UT2004.ini`, section `[RespawnDelay.RespawnDelay]`:

```ini
[RespawnDelay.RespawnDelay]
Enabled=True
BaseDelay=5.000000
ServerCycle=5.000000
DeathCamTime=1.000000
SpectateDelay=3.000000
Countdown=True
AffectBots=True
AffectInvasion=False
AffectAssault=True
```

* `ServerCycle` — team games: length of the global wave cycle (waves land on
  its multiples of the server clock, waits span one to two cycles); solo
  games: the same value is used as a plain respawn wait. Set it in the
  **Mutator GUI** ("Configure" screen after selecting the mutator) as one of
  five presets:

  | preset | cycle | waits | intended for |
  |---|---|---|---|
  | Arena [3-6s] | 3 s | 3–6 s | continuous chaos; near-instant respawns and fast micro-batches; Team Deathmatch and small maps |
  | Standard [5-10s] (default) | 5 s | 5–10 s | competitive balance; tactical flow and squad spawning in Onslaught and Assault |
  | Methodic [10-20s] | 10 s | 10–20 s | methodical pacing; moderate punishment for dying, teams regroup into waves before pushing |
  | Strategic [15-30s] | 15 s | 15–30 s | strategic pacing; every death matters, defenders mass into large waves before committing |
  | Tactical [30-60s] | 30 s | 30–60 s | heavy combat simulation; every death is critical, full battalions for macro maps with heavy vehicles |
* `Countdown=False` hides the per-second HUD counter.
* `SpectateDelay=3.0` keeps dead players out of spectator mode (and in the
  death camera) for 3 seconds after dying, so spectating doesn't start too
  early. Spectating begins at `max(DeathCamTime, SpectateDelay)`. During this
  hold-off the player stays frozen, so `FIRE` cannot respawn early.
* Console while dead: `mutate respawnstatus` — remaining seconds.
* Extras: `BaseDelay` is only a fallback used when `ServerCycle <= 0`;
  `AffectBots=False` leaves bots on their vanilla (instant) respawn;
  `AffectAssault=False` keeps Assault's vanilla reinforcement waves (the
  mutator stays inactive in Assault then); `AffectInvasion=True` applies
  delays on top of Invasion's wave respawn (off by default, the game already
  waits for the next wave).
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
