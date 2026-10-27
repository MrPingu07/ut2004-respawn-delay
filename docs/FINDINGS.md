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

* **Assault** (`UT2k4Assault/ASGameInfo.uc`) runs its own respawn machinery,
  "reinforcements" — three levers, all keyed off `ASGameInfo.bDisableReinforcements`
  (plain bool, ASGameInfo.uc:34):
  - `state MatchInProgress.Timer` (line ~249) batch-respawns every dead
    controller whose `ASPlayerReplicationInfo.bAutoRespawn` is set every
    `ReinforcementsFreq` seconds;
  - `PlayerCanRestart()` (line ~327) *refuses* respawns between reinforcement
    waves and pro-actively marks dead players `bAutoRespawn=true` — this is
    where Assault "takes control" of respawn timing;
  - `SpawnWait()` (line ~318) returns wave-tuned waits for bots so they
    respawn on the waves as well.
  With `bDisableReinforcements = true` all three fall back to vanilla
  (restarts allowed anytime, no batches, `SpawnWait` = `super`), and the
  mutator becomes the only respawn authority. It sets the flag once in
  `PostBeginPlay` when `AffectAssault` is on (default); with `AffectAssault`
  off the mutator stays completely hands-off in Assault instead.
  Round transitions: at `StartNewRound` the game moves **all** controllers to
  `state RoundEnded` (ASGameInfo around line 465/684) and respawns everyone
  at round start (`ResetLevel` → `Controller.Reset()`; bots additionally
  leave via `Bot.Reset() → GotoState('Dead')`). The mutator therefore drops
  its bot entries while `ResetCountDown != 0` so the round machinery owns
  the controller; the landed `ResetCountDown` check also prevents spawning a
  bot in the middle of a round transition.
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

## 6. How bots respawn (and how to delay them)

* `Controller.PawnDied()` puts *bots* (bIsPlayer=true) in `state Dead` too.
* `Bot.state Dead` (UnrealGame/Bot.uc:5023) is a respawn loop:
  `Sleep(0.25 + UnrealMPGameInfo.SpawnWait(self)) → Level.Game.ReStartPlayer(self) → Goto('TryAgain')`.
  `SpawnWait` (UnrealGame/UnrealMPGameInfo.uc:253) is tiny in netgames
  (0…1 s, 0 for bPlayersVsBots) — hence "bots respawn almost instantly".
  `SpawnWait` is a GameInfo method, not overridable from a mutator.
  The loop calls `RestartPlayer` **directly** — there is no `PlayerCanRestart`
  gate for bots, so GameRules/mutators cannot veto the vanilla bot respawn.
* How the bot *leaves* `state Dead`: `GameInfo.RestartPlayer → Possess →
  Restart()`, and **`Bot.Restart()` (UnrealGame/Bot.uc:1979) does
  `GotoState('Roaming','DoneRoaming')`** — that is the whole vanilla escape
  from Dead; no extra code is needed to re-activate a bot after a foreign
  `RestartPlayer()` call.
* Because bots self-restart at ~0.5 s, delaying one means *moving it out of its
  own loop*: the mutator parks the dying bot in the passive controller state
  **`RoundEnded`** (a Controller state that does nothing but exist — vanilla
  uses it at round end in Assault; `BeginState()` only unpossesses a live pawn,
  which a dead bot does not have). Latent actions of the abandoned `state Dead`
  loop are dropped when a foreign `GotoState` happens.
* A freshly added bot also sits in `state Dead` (DeathMatch.AddBot:
  `GotoState('Dead','MPStart')` for net games) *before* ever spawning.
  `Controller.PreviousPawnClass` (Engine/Controller.uc) is only set inside
  `GameInfo.RestartPlayer`, so it cleanly distinguishes "added, waiting for
  match start" from "died once".
* Failure safety: if `RestartPlayer` keeps failing (round over, no spawn
  spots, ...), the bot is put back into `state Dead` after ~10 retries so its
  own loop takes over again; humans get the same escape hatch after ~30 tries.

## 7. HUD localized-message lifecycle ("frozen number" bug)

`HudBase.DisplayLocalMessages` (XInterface/HudBase.uc:600-680) iterates the
client's `LocalMessages[]` in two passes. Pass 1 culls expired entries **only
if `Message.default.bFadeMessage` is true**; an expired non-fade message keeps
being drawn by pass 2 (`DrawMessage` never re-checks `EndOfLife`). A countdown
LocalMessage without `bFadeMessage` therefore stays on screen forever once its
`LifeTime` has elapsed (until enough new messages shuffle it out) — exactly the
reported "frozen number that only disappears when you die". Fix:
`bFadeMessage=True` on the countdown class *and* an explicit "clear" pulse
(`Switch < 0`, GetString returns an empty string) sent by the mutator whenever
a waiting player's entry is dropped.

## 8. Network clients in 'state Spectating' silently drop ClientRestart (trap)

The trap that broke every client-side symptom (stuck-overdue respawn, respawn
only after the *viewed* pawn died, missing viewmodels in first person):

* `state Spectating` for PlayerController ignores `ClientRestart`
  (Engine/PlayerController.uc:5723):
  `ignores SwitchWeapon, RestartLevel, ClientRestart, Suicide, ...`
* The ONLY client-side respawn hand-over is the reliable replicated
  `PlayerController.ClientRestart(Pawn)` (Engine/PlayerController.uc:3640),
  called by `Restart()` (3617) inside `Possess()`. It performs
  `SetViewTarget(Pawn)`, `bBehindView = Pawn.PointOfView()`,
  `Pawn.ClientRestart()` (weapon/inventory re-sync) and `EnterStartState()`.
* When the respawn is triggered while the client's controller is *also* sitting
  in `state Spectating`, that `ClientRestart()` is discarded client-side
  (ignored functions are not dispatched). Result: the client never leaves
  Spectating, keeps the spectated `ViewTarget` until that pawn dies
  (invalidation is what finally frees the camera), and never re-syncs its
  weapon -> no viewmodel in first person. Server-side everything already
  respawned fine.
* Vanilla avoids this because humans only respawn from `state Dead`
  (does not ignore ClientRestart); vanilla Spectating players are out for good,
  so vanilla never respawns out of Spectating in netgames.
* The engine's own remedy is the server/goto **ClientGotoState pairing**:
  GameInfo.RestartPlayer's failure path (Engine/GameInfo.uc:1360-1362) and
  AskForPawn() (Engine/PlayerController.uc:856-860) both send
  `PC.ClientGotoState(...)` next to a server GotoState. `ClientGotoState` and
  `ClientRestart` share one reliable channel
  (`reliable if (Role==ROLE_Authority)`, PlayerController.uc:361-367) and are
  applied in order: leaving Spectating first makes the following
  `ClientRestart()` dispatched again.
* `EnterStartState()` (PlayerController.uc:3621) explicitly supports the case
  with `if (IsInState(NewState)) BeginState(); else GotoState(NewState);` -
  pre-empting the client into 'PlayerWalking' right before RestartPlayer is
  engine-sanctioned, and ClientRestart recomputes the real start state
  (water -> 'PlayerSwimming') for the spawned pawn afterwards.

## 9. Onslaught death map bypasses `state Dead` respawn gates

`ONSPlayerReplicationInfo.OwnerDied()` → `ClientShowMap()` (Onslaught/
ONSPlayerReplicationInfo.uc:121-130) pops the mid-game map after death, and its
"Spawn Here" button (GUI2K4/UT2K4Tab_OnslaughtMap.uc:345-388) calls
`PC.ServerRestartPlayer()`. In UnrealScript identifiers are case-insensitive,
so that is the same function as `Controller.ServerReStartPlayer()`; the
`state Dead` override (Engine/PlayerController.uc:6339) runs
`Level.Game.PlayerCanRestart()` + `GameInfo.RestartPlayer()` immediately. That
path does **not** look at `bFrozen`, so the 1 s freeze only blocks `Fire()` and
clicking a power node respawns the player instantly, bypassing a scheduled
delay. `GameInfo.PlayerCanRestart()` is not a GameRules hook and ONS does not
override it.

Controller states with a no-op `ServerReStartPlayer()`:

| state | `ServerReStartPlayer` | usable for a human hold-off? |
|---|---|---|
| `Dead` | `PlayerCanRestart` + `RestartPlayer` (respawn!) | — |
| `RoundEnded` (Controller) | empty | bots only; the PlayerController version of the state loops over **all** pawns and calls `TurnOff()` |
| `GameEnded` (Controller) | empty | same all-pawns shutdown, match over only |

The safe per-player lever is `PlayerReplicationInfo.bOutOfLives`:
`DeathMatch.RestartPlayer()` (UnrealGame/DeathMatch.uc:652) returns **before**
spawning when `aPlayer.PlayerReplicationInfo.bOutOfLives` is set, and it is a
per-player flag that does not affect the controller state or camera. The
mutator sets it for the death-camera hold-off and clears it before the
scheduled respawn, which turns every early request (map button, FIRE,
`bForceRespawn` loop) into a no-op. ONS keeps the selected node in
`ONSPlayerReplicationInfo.TemporaryStartCore` for the later `RestartPlayer()`.

Caveat: `MaxLives` games and overtime cannot borrow the flag, because
`CheckMaxLives()` (UnrealGame/TeamGame.uc:417, UnrealGame/DeathMatch.uc:1367)
and the overtime `bLastMan` scan in `DeathMatch.CheckEndGame()` treat
`bOutOfLives` as "this player is gone for good" and may end the match when
everybody is temporarily flagged. The mutator therefore applies the lock only
when `Level.Game.MaxLives <= 0 && !Level.Game.bOverTime` and falls back to the
`bFrozen` FIRE gate there.

## 10. Environment of this install

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
* Mutator config lives in **UT2004.ini** (`class ... config(UT2004)`); an
  earlier `config(RespawnDelay)` declaration silently read a nonexistent
  `RespawnDelay.ini` instead, which is why appended UT2004.ini sections had no
  effect for a while.
* A dedicated server started headless (`ucc server MAP?...`) **never leaves
  `state PendingMatch` without a connected human**:
  `DeathMatch.state PendingMatch.Timer` does `if (NumPlayers == 0)
  bWaitForNetPlayers = true;` every tick, regardless of `MinPlayers`/bots.
  So foreign-bot smoke tests must be done with a real client connected.
