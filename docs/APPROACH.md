# Respawn Delay — approach

## Requirements recap

| situation | behaviour |
|---|---|
| team game (TDM, CTF, BR, DOM, ONS, AS, ...) | **global wave cycle**: global 5 s server cycle; die right at a cycle start → 5 s wait (imminent wave); die later → wait = time remaining + 5 s, spawning in a synchronized batch at the end of the next cycle. Locked at death *until respawn*; waits always 5–10 s |
| solo game (DM, LMS, ...) | the same selectable cycle length as a plain wait (default 5 s, no batching) |
| bots | same rules; a dying bot waits its delay instead of respawning ~instantly (`AffectBots=True`) — in team games bots join the same waves |
| while waiting | spectator mode: switch between team-mates, or between all players when solo |

## Why not hook-based approaches

Surveyed the available hooks (see [FINDINGS.md](FINDINGS.md)):

* `Mutator` class has **no** `PreventDeath` / `ScoreKill` in UT2004, only
  ModifyLogin/ModifyPlayer/NotifyLogout/etc. — no death or respawn gate.
* `GameRules` has `PreventDeath`, but `true` means *"pawn must not die"*
  (Pawn.Health is clamped, death cancelled) — not a respawn delay mechanism.
  GameRules has **no restart/responder hook** at all.
* `GameInfo.PlayerCanRestart()` is the actual respawn gate, but it is a
  GameInfo method and cannot be overridden from a mutator.

Blocking respawn "upstream" is therefore not possible without replacing the
GameInfo or PlayerController class (both too invasive / network-sensitive).

## Chosen architecture: supervised epoch

The mutator (`RespawnDelay.RespawnDelay`) runs a **supervisor** on its own
`Timer` at 20 Hz and manages each dead player personally:

```
[alive] --death--> [Dead + PRI.bOutOfLives lock: death camera, RestartPlayer refused]
        --max(DeathCamTime, SpectateDelay)--> [state Spectating: free cam + FIRE cycles views]
        --locked time reached--> [GameInfo.RestartPlayer(PC) -> state PlayerWalking]
```

1. **Death detection** — scan `Level.ControllerList`; a *fresh death* is a
   `PlayerController` in `state Dead`, `Pawn == None`, `bIsPlayer`, not
   `PRI.bOnlySpectator`, not `PRI.bOutOfLives`, not yet tracked, and (option)
   not an Invasion game. The vanilla death camera is preserved for
   `DeathCamTime` (default 1.0 s, i.e. the vanilla bFrozen window).
   For **bots**: same scan, `Bot` in `state Dead` with
   `PreviousPawnClass != None` (a freshly added bot idles in `state Dead`
   before its first spawn — `PreviousPawnClass` only gets set inside
   `GameInfo.RestartPlayer`, so it filters out that match-start case).
2. **Delay computation (set in stone)** — at registration,
   `RespawnDelayFor(C)` is evaluated once:
   * solo games → `ServerCycle` (the same GUI-selectable value as the team
     wave cycle; default 5 s, `BaseDelay` only as a fallback if `<= 0`)
   * team games → the global wave cycle (perfect synchronization):

     waves land on every `Level.TimeSeconds` multiple of `ServerCycle`
     (5 s by default). At death the remaining time of the cycle picks the
     wave:

     - **remain == ServerCycle** (died exactly on a boundary, i.e. the
       cycle just started) → wait `ServerCycle` and spawn at the imminent
       wave (its closing boundary);
     - **remain < ServerCycle** → pushed to the NEXT wave: wait =
       `remain + ServerCycle`, so everyone dead within a cycle spawns
       together on the closing boundary of the next cycle.

     Every `RespawnAt` is an exact `ServerCycle` multiple of the server
     clock — synchronized batches by construction — and waits are always
     within `[ServerCycle, 2*ServerCycle]` (5–10 s with the default).
     The value is stored as `RespawnAt = DiedAt + delay` and **never
     recomputed** until respawn.
3. **Spectator mode** — after `max(DeathCamTime, SpectateDelay)` (default
   3.0 s via `SpectateDelay`), the controller is moved exactly the way vanilla
   LMS does (`UnrealPlayer.ServerSpectate`):
   `GotoState('Spectating')`, `bBehindView = true`, and a living player is
   selected (or free camera when nobody is alive). Remaining frozen/jump flags
   from the death camera are cleared, the controller's pending Timer cancelled.
   * **The hold-off locks respawns with `PRI.bOutOfLives`.** In `state Dead`,
     `ServerReStartPlayer()` honours any respawn request
     (`PlayerCanRestart()` → `RestartPlayer()`), so pressing FIRE once the 1 s
     vanilla freeze expired — or, more importantly, clicking Onslaught's
     death-map **"Spawn Here"** button, which calls the same RPC — respawned
     the player instantly and bypassed the locked `RespawnAt`.
     `DeathMatch.RestartPlayer()` refuses to spawn a PRI flagged
     `bOutOfLives`, so the supervisor raises that flag for the hold-off and
     clears it right before spectator mode / the scheduled spawn. The death
     camera, controller state and client-side behaviour stay vanilla; the
     player is just temporarily "out of lives" server-side. In standalone /
     listen play the Dead state's `bFrozen` gate is re-armed every tick, so
     FIRE keeps doing nothing until `SpectateDelay`; on network clients FIRE
     may start spectator view early but cannot respawn before `RespawnAt`.
     `MaxLives` games and overtime are excluded from the lock: `CheckMaxLives()`
     / `CheckEndGame()` read `bOutOfLives` to decide the match is over, so a
     temporary lock could look like a full wipe. The chosen power node is kept
     by Onslaught for the scheduled spawn.
   * FIRE cycles **living** player views; `TeamGame.CanSpectate` limits
     players to their own team, DM allows everybody. The supervisor filters
     out dead targets (the engine's own cycle does not), and when FIRE lands
     on a corpse it advances to the next living player. If the player being
     watched dies, the camera anchors at that death spot in free camera
     instead of following the corpse. With every player dead (always the case
     at a solo-mode wipe), free camera is forced immediately.
   * ALT-FIRE returns to the own (flying) camera. Every player's
     `PlayerController.OwnCamera` is emptied, so `ServerViewSelf()` does not
     print its vanilla "Now viewing from own camera" chat line.
   * `Possess()` would refuse to possess a `bOnlySpectator` PC, so waiting
     players keep their normal player flags (scoreboard, team, chat intact).
4. **Respawn** — when `Level.TimeSeconds >= RespawnAt` (and the match is not
   waiting to start), the supervisor calls
   `Level.Game.PlayerCanRestart(PC)` and then `Level.Game.RestartPlayer(PC)` —
   the vanilla spawn routine, including `Possess()`/`EnterStartState()` which
   returns the PC to `state PlayerWalking`. Attempts are rate-limited
   (0.5 s) and an entry is only dropped once `PC.Pawn != None` (a silent
   failure, e.g. late-comer rules, just retries).
   * **Network clients: paired GotoState/ClientGotoState.** `state Spectating`
     has `ClientRestart` in its *ignores* list, so a client still sitting in
     Spectating would silently drop the replicated `ClientRestart()` that the
     respawn sends (see [FINDINGS.md](FINDINGS.md) §8): it would stay glued to
     the spectated pawn until that pawn died, and never re-sync its weapon (no
     viewmodel in first person). Therefore every state hand-over is paired
     server+client, exactly the pattern the engine uses itself
     (`RestartPlayer`'s failure path, `AskForPawn()`):
     - spectate: server `GotoState('Spectating')` + `ClientGotoState('Spectating')`
     - respawn: `ClientGotoState('PlayerWalking')` **before**
       `RestartPlayer(PC)` — ClientGotoState and the later ClientRestart share
       one reliable channel and are applied in order, so the hand-over works
     - escape hatch (30 failed restarts): `GotoState('Dead')` +
       `ClientGotoState('Dead')`
5. **Bots are parked, not spectated** — a dying bot has no spectator mode
   (`AIController` has no camera/AI in that state). Instead the bot is moved
   out of its own respawn loop *at registration* by
   `GotoState('RoundEnded')` (a passive Controller state —-engine version
   ignores AI/perception events and only unpossesses a live pawn, which a
   dead bot does not have; abandoning `state Dead` drops its pending latent
   `Sleep`). The park must happen immediately: `state Dead` in Bot is a
   self-restart loop that respawns in ~0.5 s by itself.
   At `RespawnAt` the supervisor calls `Level.Game.RestartPlayer(B)` —
   `Possess() → Restart() → Bot.Restart()` then drops the bot straight into
   `state Roaming` (vanilla wake-up path, verified in Bot.uc:1979), so no extra
   AI reactivation code is needed. Safety valves:
   * if `RestartPlayer` keeps failing (e.g. map's spawn spots blocked, round
     over), after ~10 tries the bot is restored to `state Dead` and its own
     vanilla loop takes over again;
   * if the game moves the parked bot to a different state (round
     transitions, `GameEnded`), it is likewise handed back to vanilla;
   * if the game takes the bot over (`bOutOfLives`, respawned by other code),
     the entry is dropped and any parked bot returns to `state Dead` first.
   Humans get the same escape hatch after ~30 failed restart attempts
   (`GotoState('Dead')`, vanilla fire-respawn resumes).

Book-keeping lives in a `struct TWaitingPlayer` dynamic array (`C`, `bBot`,
`DiedAt`, `RespawnAt`, `AlliesAlive`, `LastAttempt`, `Tries`, `LastCountdown`);
entries are dropped when the controller respawns, logs out, receives
`bOutOfLives` (LMS/Invasion), or is moved by match/round machinery
(`state RoundEnded`, `GameEnded`, etc.).

Announcements: the locked delay is sent via `PlayerController.ClientMessage`
(server → client replication confirmed: `reliable if Role==ROLE_Authority ClientMessage`
in PlayerController); `mutate respawnstatus` reports the remaining time.

### Countdown HUD ("Respawn in 10, 9, 8, ...")

While waiting, the mutator emits once per whole second
`PC.ReceiveLocalizedMessage(class'RespawnDelayCountdown', SecondsLeft)`.

That class (`RespawnDelay.RespawnDelayCountdown extends LocalMessage`) is
configured for a clean, client-side-only display:

| setting | value | effect |
|---|---|---|
| `bIsSpecial` | True | rendered as a positioned HUD message, not in the chat queue |
| `bIsUnique`  | True | the new pulse **replaces** the previous one (HudBase.LocalizedMessage reuses the slot) — one always-fresh line ticking down |
| `bIsConsoleMessage` | False | never written to the console/chat — other players see nothing |
| `bFadeMessage` | True | expired pulses are **culled** by HudBase pass 1 — without it a stale line would stay drawn forever (the "frozen number" bug) |
| `bBeep` | False | silent |
| `LifeTime` | 1.25 s | until the next pulse |
| position | PosX 0.5 / PosY 0.72, `DP_MiddleMiddle`, `SM_None` | centered, slightly below mid-screen |
| font/color | white; `Switch <= 3` → huge font; numbers always white | urgency cue |

**Guaranteeing no stale number**: HudBase culling alone leaves a window in
which the last pulse could yet be visible (up to 1.25 s past the respawn), and
doubling as a belt-and-braces measure the mutator sends a *clear* pulse
(`Switch = -1`, `GetString()` returns `""`) through the same
`ReceiveLocalizedMessage` channel the moment it drops a waiting entry — since
`bIsUnique` replaces, whatever was on screen is replaced by nothing. The
sentinel `LastCountdown = -2` makes the clear pulse fire at most once per wait.

Because `GetString()` re-formats on the client and the server only sends a
small integer, the whole counter costs ~0 bytes of chat bandwidth and is only
visible to the affected player. The initial "locked delay" notice and the
spectator hint remain one-shot `ClientMessage`s (once per death, not per
second). Toggle the whole feature with the `Countdown` config var.

## Deliberate limitations (documented trade-offs)

* **bForceRespawn=true** servers: the vanilla auto-respawn loop could fire
  inside the ≤ 1 s death-camera window (it bypasses `bFrozen`). In practice
  DeathCamTime ≤ the bFrozen window makes ours switch first; worst case a
  bForceRespawn player sneaks out up to ~1 s early.
* **Assault**: reinforcements disabled at match start (`AffectAssault=True`,
  default) so the mutator governs respawns; with it off, the mutator is
  hands-off in Assault.
* **Invasion** is skipped by default (wave logic already delays respawn);
  `AffectInvasion=True` piles the delay on top. `AffectBots` applies to
  Invasion too when forced.
* **MaxLives / LMS lives**: when the last life is spent the player becomes an
  out-of-lives spectator at once — handled vanilla-style, never managed.

## Files

```
RespawnDelay/Classes/RespawnDelay.uc           the mutator
RespawnDelay/Classes/RespawnDelayCountdown.uc  the HUD countdown LocalMessage
RespawnDelay/RespawnDelay.int                 registration + localized strings
RespawnDelay/RespawnDelay.ucl                 mutator-list registration
make.sh                                builds into the game dir via wine UCC make
docs/FINDINGS.md                       engine research (with source references)
docs/APPROACH.md                       this document
```

## Configuration (UT2004.ini `[RespawnDelay.RespawnDelay]`)

| var | default | meaning |
|---|---|---|
| `Enabled` | True | master switch (applied between matches) |
| `BaseDelay` | 5.0 | fallback respawn delay for solo (non-team) games when `ServerCycle <= 0` |
| `ServerCycle` | 5.0 | global wave cycle length (team games) and plain respawn wait (solo games); waits span one to two cycles in team games. Exposed in the **Mutator GUI** as a 5-preset dropdown ("Arena [3-6s]", "Standard [5-10s]", "Methodic [10-20s]", "Strategic [15-30s]", "Tactical [30-60s]") |
| `DeathCamTime` | 1.0 | vanilla death camera seconds before spectator mode |
| `SpectateDelay` | 3.0 | seconds after death before spectator mode starts; spectating begins at `max(DeathCamTime, SpectateDelay)` so players stay in the death camera longer |
| `Countdown` | True | per-second HUD countdown while waiting |
| `AffectBots` | True | apply the rules to bots as well |
| `AffectInvasion` | False | apply delays in Invasion as well |
| `AffectAssault` | True | take respawn authority in Assault (disables the vanilla reinforcement waves); False = hands-off in Assault |

### Mutator GUI (PlayInfo)

`FillPlayInfo()` adds one *Select* (dropdown) control so server admins pick a
wave-cycle preset on the mutator "Configure"/admin Rules pages:

* `PlayInfo.AddSetting(default.RespGroup, "ServerCycle", GetDisplayText(...),
  0, 1, "Select", default.CyclePresetText)` — the Extras string is
  `"3.000000;Arena [3-6s];5.000000;Standard [5-10s];10.000000;Methodic [10-20s];
  15.000000;Strategic [15-30s];30.000000;Tactical [30-60s]"` (value;Label pairs,
  exactly like the engine's own GameDifficulty dropdown). The labels come out
  of `RespawnDelay.int` (`RespGroup`, `CycleDisplayText`, `CycleDescText`,
  `CyclePresetText`).
* The value strings are formatted as full six-decimal floats on purpose: the
  GUI re-matches the value stored in the ini (`5.000000`) against those pairs
  to highlight the current preset, and stores the selected pair value back
  via `PlayInfo.StoreSetting`.
* The per-control tooltip (`CycleDescText`) lists every preset's wait range,
  since UT2004's rules GUI supports only one static hint per control — per
  option tooltips do not exist.
* Selecting a preset simply rewrites `ServerCycle=...` into
  `[RespawnDelay.RespawnDelay]` under `UT2004.ini`; the wave math reads the
  variable live at death time, so changes apply to the next deaths.

## Build & install

```bash
./make.sh                       # symlink package dir into the game root, wine UCC make, deploy .int/.ucl
```

* Requires `EditPackages=RespawnDelay` in `UT2004.ini [Editor.EditorEngine]` (already present).
* If a previous binary exists but is stale, delete `System/RespawnDelay.u`
  first — `ucc make` trusts an existing package.
* The stale `RespawnDelay.RespawnDelay` entry in `User.ini LastActiveMutators`
  is harmless; the game rewrites it on first use.

## Test checklist (manual, in-game)

1. DM/TDM with a few bots:
   - die → death camera ≈ 1 s → spectator fly view on a player only after the
     `SpectateDelay` (3 s default) has elapsed
   - press FIRE during that hold-off → nothing happens (no early respawn)
   - `_ "FIRE"` cycles living players only; AltFire returns to free camera
     with no "Now viewing from own camera" chat line
   - let the watched player die → camera stays at that death spot in free
     camera (can be moved around), it does not follow the corpse
   - with every player dead, free camera is entered automatically
   - console message shows the locked delay; respawn happens only after it
   - `mutate respawnstatus` while waiting prints the remaining time
2. Team games: everyone dying within the same cycle shows counts that all
   hit 0 within the same half-second and respawn together at the next wave's
   boundary; waits never fall outside one to two cycles (5–10 s by default).
   Watch a full wave: several players/bots popping at (almost) the same
   instant, then silence.
3. Solo DM: every death waits the selected cycle length (default 5 s) regardless
   of timing; picking a different preset in the Mutator GUI changes it too.
4. Bots: kill a bot → it should not reappear before its delay; simplest check
   is relative respawn timing (yours vs. the bots'), and bots fighting again
   after the wait rather than standing idle (idle → a safety valve fired —
   report it).
5. Countdown: numbers always white, growing in the last 3 s, no leftover
   number when alive (the counter disappears at respawn even if the last
   pulse's 1.25 s lifetime had not run out).
6. Smoke tests already performed headless (dedicated server via wine):
   DM-Gael (`team=False`) and CTF-Avaris (`team=True`) load the mutator with
   `0 error(s), 0 warning(s)`, and the ini section is read
   (`BaseDelay=5.00` in the startup log). Note a headless dedicated server
   never starts a match without a real client connected (`PendingMatch`
   waits for `NumPlayers > 0`), so respawn flows need a live client to test.
7. Mutator GUI: Instant Action or Lan game → Mutators → pick Respawn Delay →
   "Configure" → the "Respawn wave cycle" dropdown shows the five presets,
   choosing one (e.g. Tactical [30-60s]) writes `ServerCycle=30.000000` into
   `UT2004.ini` `[RespawnDelay.RespawnDelay]`, and the next team match runs
   30–60 s waits. Check the startup log line (`wave cycle=30.00`).
8. **Network client** (dedicated server + a second machine/client, per
   FINDINGS §8): die → watch a team-mate through the wait → at RespawnAt the
   view must switch back to the own pawn, in first person with the weapon in
   hand, without waiting for the watched player's death; `mutate respawnstatus`
   prints a remaining time > 0 during the whole wait; FIRE cycles living views,
   not respawn; if the watched player dies, the client camera stays at the
   death spot in free camera; if everyone dies, free camera is forced; AltFire
   prints no chat line.
