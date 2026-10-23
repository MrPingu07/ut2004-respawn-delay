# RespawnDelay — a respawn-delay mutator for Unreal Tournament 2004

Teams only also get a *team-scaled* wait; solo players always wait 3 seconds.
While waiting you are a spectator: `FIRE` cycles player views (own team in team
games, everybody in solo games), `ALT-FIRE` returns to your own free camera.
The delay is computed once when you die and stays locked until you respawn.

| mode | delay rule |
|---|---|
| Team games (TDM, CTF, BR, DOM, ONS, AS...) | 1 ally alive → **3 s**, 5 allies → **8 s**, 10 allies → **15 s** (linear in between, clamped) |
| Solo games (DM, LMS, ...) | **3 s** |

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
BaseDelay=3.000000
DelayTable="1,3 5,8 10,15"
DeathCamTime=1.000000
TeamFormula=True
AffectInvasion=False
```

* `DelayTable` — "alliesAlive,delaySeconds" pairs: fewer allies than the first
  anchor → first delay; more than the last → last delay; linear between.
* Console while dead: `mutate respawnstatus` — remaining seconds.
* Two extras: `TeamFormula=False` forces `BaseDelay` everywhere;
  `AffectInvasion=True` applies delays on top of Invasion's wave respawn
  (off by default, the game already waits for the next wave).

## Documentation

* [docs/FINDINGS.md](docs/FINDINGS.md) — how UT2004 respawn/spectate actually
  works (verified against retail UnrealScript source) and what hooks exist.
* [docs/APPROACH.md](docs/APPROACH.md) — design, edge cases, config reference,
  test checklist.

## Notes on the previous attempt

A compiled-only mutator of the same name shipped in `System/` (fixed
"DelaySeconds=5", console `mutate setdelay`). Its binary was replaced by this
build; there was no source to salvage.
