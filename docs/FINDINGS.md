# UT2004 respawn architecture — research findings

Verified against the retail UnrealScript source (build v3369) via the
[Deaod/UT2004](https://github.com/Deaod/UT2004) dump; local copies in
`/tmp/opencode/ut2004src/`. Line numbers below refer to those files.

## 1. How respawn actually happens

After a pawn dies, `Controller.PawnDied()` (Engine/Controller.uc:435) puts the
controller in `state Dead` if `bIsPlayer`. Engine/Controller.uc:989 keeps a
base `state Dead` whose `ServerRestartPlayer()` calls `Level.Game.RestartPlayer(self)`.

`PlayerController.state Dead` (Engine/PlayerController.uc:6325):

```
state Dead
{
    function ServerReStartPlayer()
    {
        if ( !Level.Game.PlayerCanRestart( Self ) )
            return;
        super.ServerRestartPlayer();          // -> GameInfo.RestartPlayer()
    }

    exec function Fire() { ... if (bFrozen) {...} else ServerRestartPlayer(); }
```

* `GameInfo.PlayerCanRestart(PC)` (Engine/GameInfo.uc:1309) is the single
  respawn gate — but it is a GameInfo method, **not** a mutator/GameRules hook
  (GameRules has no restart hook; `GameRules.PreventDeath` returning `true`
  means *"the pawn does not die"*, Pawn.Health is clamped to >= 1
  (Engine/Pawn.Died), i.e. it is for "don't die" mods, not for delayed respawn).
* Two callers reach it:
  1. the player pressing FIRE while in `state Dead`
  2. `DeathMatch.state MatchInProgress.Timer()` (UnrealGame/DeathMatch.uc:1204):
     if `bForceRespawn` is true, the game loop calls
     `PlayerController(P).ServerReStartPlayer()` every second for dead players.
     That loop skips `PRI.bOnlySpectator` controllers.
* `bFrozen` only guards the manual FIRE path, for ~1.0 s (death camera freeze
  window, `Dead.BeginState()` sets it, `Timer()` clears it).

## 2. Where the respawn routine can be driven from outside

`GameInfo.RestartPlayer(Controller aPlayer)` (Engine/GameInfo.uc:1322) is a
plain public GameInfo function — anyone may call it. Inside:

```
startSpot = FindPlayerStart(...);
aPlayer.Pawn = Spawn(...);
aPlayer.Possess(aPlayer.Pawn);
```

and `PlayerController.Possess()` (Engine/PlayerController.uc:899) ends with
`Restart()`, whose `EnterStartState()` (Engine/PlayerController.uc:~930) does
`GotoState(Pawn.LandMovementState)` → `state PlayerWalking`.

**Consequence:** calling `Level.Game.RestartPlayer(PC)` from a foreign actor
while the PC is in *any* state (Spectating, Dead, ...) correctly resurrects the
player and puts him back into `PlayerWalking`. That is the lever a mutator can
use to *schedule* respawns, instead of only trying to block them.

Guard rails inside the call chain:

* `PlayerController.Possess()` returns immediately if
  `PRI.bOnlySpectator == true` — so waiting players must NOT be flagged as
  real spectators.
* `DeathMatch.RestartPlayer()` (UnrealGame/DeathMatch.uc:652) returns early for
  `PRI.bOutOfLives` (MaxLives/LMS) and for late-comer spectators — failures are
  silent (void), so the caller must re-check `PC.Pawn != None` and retry.

## 3. The 'Spectating' state — vanilla "dead/camera-only spectator"

Engine/PlayerController.uc:5721:

```
state Spectating extends BaseSpectating
{
    exec function Fire()  { ... ServerViewNextPlayer(); }   // cycle views
    exec function AltFire() { bBehindView=false; ServerViewSelf(); }
    function BeginState() { if (Pawn != None) {SetLocation; UnPossess;} bCollideWorld=true; }
    function EndState() { PlayerReplicationInfo.bIsSpectator = false; ... }
}
```

* `state BaseSpectating` (5518) provides a free fly camera
  (`MoveSmooth(SpectateSpeed * ...)`).
* `ServerViewNextPlayer()` (6284) iterates `Level.ControllerList` and filters
  through `Level.Game.CanSpectate(self, bRealSpec, C)`.
* `TeamGame.CanSpectate` (UnrealGame/TeamGame.uc:783): a *player* (not a real
  spectator) may only view members of his **own team**.
* `DeathMatch.CanSpectate` (UnrealGame/DeathMatch.uc:719): a player may view
  **any** non spectator. — Exactly the requested behaviour:
  teammates while waiting in team games, everybody in solo games.
* UnrealPlayer.ServerSpectate (`UnrealGame/UnrealPlayer.uc`):
  vanilla precedent for *living-player → Spectating*: sets `GotoState('Spectating')`,
  `bBehindView = true`, `ServerViewNextPlayer()`. Last Man Standing uses it
  (UnrealPlayer.state Dead: `if (PRI.bOutOfLives) ServerSpectate();`).
  Server-side state changes for PlayerControllers propagate to the owning client
  (see `GameInfo.RestartPlayer` failure path, which pairs server `GotoState` with
  `ClientGotoState`); `Restart()` also calls `ClientRestart(Pawn)` which drives the
  client into `EnterStartState()` regardless.
* `Controller.Possess()` needs no special handling for a controller in
  `state Spectating` — respawning from Spectating is what StartMatch does
  for every late joiner, every day.

## 4. States used elsewhere that matter

| state | who | relevance |
|---|---|---|
| `PlayerWaiting` | clients waiting for match start | its `ServerRestartPlayer` honours `WaitDelay` — not reached by dead players |
| `GameEnded` / `RoundEnded` | match/round over (Assault rounds) | supervision must not touch players in these states |
| `WaitingForPawn` | client-side interlock | irrelevant |

## 5. Special game types

* **Assault** (`UT2k4Assault/ASGameInfo.uc:255`): `state MatchInProgress.Timer`
  auto-respawns players who had `ASPlayerReplicationInfo.bAutoRespawn` set
  ("reinforcements"), by calling `GameInfo.RestartPlayer(PC)` directly.
  Those respawn *bypass* any attempted block — documented limitation.
* **Invasion** (`SkaarjPack/Invasion.uc`): dead players get `PRI.bOutOfLives = true`
  at death (line 200) and can only spawn at the next wave
  (line 663: `C.ServerReStartPlayer()`). The wave logic already gates respawn;
  managing it would overlap with the wave control → the mutator skips Invasion
  by default.
* **MaxLives / LMS**: `PRI.bOutOfLives` is set at `GameInfo.ScoreKill`
  (DeathMatch.uc:1455) *at the moment the last life is spent*; those players
  must never be managed (they are permanent spectators until the game ends).
* **Team detection**: `GameInfo.bTeamGame` (Engine/GameInfo.uc:63);
  `TeamGame` sets it `True` in defaultproperties (TeamGame.uc:1693), DM leaves
  it False. TDM/CTF/BR/DOM/ONS/AS all derive from TeamGame → True.

## 6. Environment of this install

* Windows build running through wine 11.20-staging; `wine UCC.exe make` works
  (cwd = game `System/`).
* `UT2004.ini` already had `EditPackages=RespawnDelay` (`[Editor.EditorEngine]`,
  line ~514) and stale `LastActiveMutators` in `User.ini` from the failed
  attempt. The old compiled package (`System/RespawnDelay.u`) had to be deleted
  before `ucc make` would recompile from source (it considered the binary
  up to date; only then did "Parsing/Compiling RespawnDelay" appear in UCC.log).
* There were no source files for the failed attempt anywhere in the game tree
  (only the stale `RespawnDelay.u/.int/.ucl` in System) — nothing to salvage.
  The old build was a fixed-delay mutator ("DelaySeconds=5", `mutate setdelay`).
