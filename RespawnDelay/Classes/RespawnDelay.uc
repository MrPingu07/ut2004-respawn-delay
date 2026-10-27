//=============================================================================
// RespawnDelay.uc
//
// Levels: Mutator "Respawn Delay".
//
// Forces players to wait before they can respawn after dying:
//
//  * Team based game modes (TDM, CTF, BR, DOM, ONS, AS, ...):
//      a GLOBAL 5 second server cycle (reinforcement waves, always on cycle
//      multiples). When a player dies, the remaining time of the current
//      cycle is calculated:
//          exactly 5 s left (died right at a cycle start)
//                  -> wait 5 s, spawn at the end of the current cycle
//          less    -> pushed to the NEXT wave: wait = TimeRemaining + 5 s,
//                     i.e. everyone in the cycle spawns together at the end
//                     of the next cycle
//      Every respawn lands exactly on a 5 s boundary (perfect batches) and
//      nobody waits outside 5-10 seconds. The wait is locked at death until
//      respawn.
//
//  * Non team modes (DM, LMS, ...): plain ServerCycle wait (no batching),
//      i.e. the same GUI-selectable wave-cycle value as team games (default
//      5 seconds). BaseDelay is only a fallback for ServerCycle <= 0.
//
//  * Bots are delayed the same way (config AffectBots): a dying bot is parked
//    in the passive controller state 'RoundEnded' (it just idles there, like
//    when an Assault round ends) and GameInfo.RestartPlayer() is called at the
//    locked time. Possess -> Restart() -> Bot.Restart() then drops it straight
//    into 'Roaming', i.e. the exact vanilla wake-up path. Respawnless game
//    modes (Invasion's bOutOfLives waves) are excluded (AffectInvasion).
//
//  * Assault uses its own "reinforcements" machinery (batch respawn waves +
//    PlayerCanRestart refusals between waves + tuned bot SpawnWait). AffectAssault
//    (default) turns reinforcements off at match start (ASGameInfo.bDisableReinforcements)
//    so this mutator fully governs Assault respawns instead.
//
//  * While waiting, players are put in the vanilla 'Spectating' state:
//      FIRE            cycles the camera through the living players allowed by
//                      the game type (own team members in team games, every
//                      player in solo games, as enforced by GameInfo.CanSpectate).
//                      Dead players are skipped; if the player currently being
//                      watched dies, the camera stays at that death spot in
//                      free camera (orbit/fly around it) instead of following
//                      the corpse. With no living player left, free camera is
//                      forced immediately.
//      ALT-FIRE        returns to the own (free) camera
//      Aggression AE   spectator free camera (fly around the map)
//
//  * While waiting, a per-second HUD countdown ("Respawn in 10, 9, 8...")
//      is shown to the waiting player only (RespawnDelayCountdown localized
//      message; it lives in the HUD queue, never in the chat log).
//
// Technical notes (see docs/ in the project repository):
//  The vanilla respawn paths (PlayerController "state Dead" / firing, or
//  DeathMatch "MatchInProgress" auto respawn loop with bForceRespawn) are not
//  touched. Instead a supervisor runs on the mutator's Timer:
//    1. A fresh death is detected when a PlayerController enters "state Dead"
//       with no pawn and is not flagged as unable to respawn (bOnlySpectator,
//       bOutOfLives).
//    2. During the death-camera / spectate hold-off the waiting player's
//       PRI.bOutOfLives is set: DeathMatch.RestartPlayer() returns before
//       spawning anyone flagged "out of lives", so every early respawn request
//       (Onslaught's death-map "Spawn Here" button, FIRE, bForceRespawn, ...)
//       is refused instead of bypassing the locked RespawnAt. The flag is
//       cleared before spectator mode / the scheduled respawn. After the
//       hold-off the controller is moved to the vanilla 'Spectating' state
//       (same thing UT2004 itself does for Last Man Standing, via
//       UnrealPlayer.ServerSpectate).
//    3. When the locked respawn time is reached, the supervisor calls
//       GameInfo.PlayerCanRestart() and GameInfo.RestartPlayer(), i.e. the
//       exact vanilla respawn routine (bots get RestartPlayer() directly,
//       exactly what vanilla Bot "state Dead" does).
//    3b. Network clients must be driven out of 'Spectating' on BOTH sides at
//       respawn: state 'Spectating' has ClientRestart in its ignores list
//       (PlayerController.uc), so a client still sitting in Spectating
//       silently drops the replicated ClientRestart() that Possess()/Restart()
//       sends for the respawn. It would then stay glued to the spectated pawn
//       (only freed when that pawn dies) and never re-sync its weapon
//       inventory (no viewmodel in first person). The supervisor therefore
//       pairs every server-side GotoState with ClientGotoState - the same
//       pattern the engine uses itself (GameInfo.RestartPlayer's failure
//       path, AskForPawn()); reliable calls on one channel are applied in
//       order, so the client leaves Spectating before ClientRestart lands.
//    4. Every waiting entry is dropped the moment the condition changes and a
//       stale HUD countdown is killed with a "clear" localized message
//       (Switch < 0 renders an empty string), so no number can outlive a wait.
//=============================================================================
class RespawnDelay extends Mutator
	config(UT2004);

// ---------------------------------------------------------------------------
// Configuration (UT2004.ini section [RespawnDelay.RespawnDelay])
// ---------------------------------------------------------------------------

/** Master switch; can be toggled in UT2004.ini between matches. */
var() config bool	Enabled;

/** Fallback respawn delay (seconds) for non team games when ServerCycle <= 0. */
var() config float	BaseDelay;

/**
 * Length of the global reinforcement cycle (seconds); team waves land on its
 * multiples. In solo games the same value is used as the plain respawn wait.
 * Configurable in the Mutator GUI as one of five presets ("Arena", "Standard",
 * "Methodic", "Strategic", "Tactical").
 */
var() config float	ServerCycle;

/** Seconds still spent in the vanilla death camera before spectator mode starts. */
var() config float	DeathCamTime;

/**
 * Seconds after death before spectator mode starts. Spectating is held off
 * until max(DeathCamTime, SpectateDelay) so dead players stay in the death
 * camera / dead state a bit longer instead of being dropped into spectator
 * view right away.
 */
var() config float	SpectateDelay;

/** Show a per-second HUD countdown while waiting (only visible to the waiting player). */
var() config bool	Countdown;

/**
 * Apply the delay to bots as well. The dying bot is parked in the passive
 * 'RoundEnded' controller state until its delay runs out, then spawned with
 * the vanilla GameInfo.RestartPlayer().
 */
var() config bool	AffectBots;

/**
 * Invasion respawns by wave and the game itself keeps dead players waiting.
 * Leave disabled unless the delay should pile up on top of the wave logic.
 */
var() config bool	AffectInvasion;

/**
 * Assault runs its own "reinforcements" respawn waves: PlayerCanRestart()
 * refuses respawns between waves, dead players with ASPlayerReplicationInfo
 * bAutoRespawn are batch-respawned, and bot SpawnWait() is wave-tuned.
 * With AffectAssault enabled (default) the mutator disables that machinery
 * (ASGameInfo.bDisableReinforcements = true) at match start and governs
 * Assault respawns itself. Leave disabled to keep vanilla Assault waves -
 * the mutator then stays completely hands-off in Assault.
 */
var() config bool	AffectAssault;

// ---------------------------------------------------------------------------
// Localization (see RespawnDelay.int)
// ---------------------------------------------------------------------------
var localized string	MsgRespawnTeam;		// "%1" the seconds left in the cycle
var localized string	MsgRespawnSolo;		// "%1" number of seconds
var localized string	MsgSpectateHint;
var localized string	MsgStatusWaiting;	// "%1" the seconds remaining
var localized string	MsgStatusIdle;

// -- mutator GUI (PlayInfo / "Configure" pages) ------------------------------
// Rendered by UT2004's mutator configuration pages ("Configure" button after
// picking the mutator, and the admin Rules page). One single dropdown Select
// control whose Extras string is a "value;Label" pair list: the engine shows
// the labels and stores the value into `ServerCycle`. The value strings use
// the full "5.000000" float format on purpose: the GUI re-matches the ini's
// stored value against those pairs to highlight the current preset.
var() localized string	RespGroup;		// group header shown above the control
var() localized string	CycleDisplayText;	// name of the dropdown control
var() localized string	CycleDescText;		// tooltip of the dropdown control
var() localized string	CyclePresetText;	// "value;Label;value;Label;..." pairs

// ---------------------------------------------------------------------------
// Internal state
// ---------------------------------------------------------------------------

// one entry per controller (human or bot) currently sitting out the delay
struct TWaitingPlayer
{
	var Controller			C;			// PlayerController or Bot
	var bool				bBot;
	var float				DiedAt;		// server time of the detected death
	var float				RespawnAt;	// locked respawn time
	var float				LastAttempt;// last RestartPlayer attempt (rate limiter)
	var int					Tries;		// failed RestartPlayer attempts
	var int					LastCountdown;	// whole seconds already displayed (-1 = none yet, -2 = cleared)
	var bool				bRespawnLocked;	// we set PRI.bOutOfLives during the death-camera hold-off
	// spectator camera bookkeeping (human only)
	var Actor				LastViewTarget;	// last PC.ViewTarget handled
	var vector				LastViewLocation;	// last alive seen / free-camera anchor
	var bool				bHasViewLocation;
	var bool				bFreeCam;		// currently viewing from own camera
};

var array<TWaitingPlayer>	Waiting;

// game-type knobs, cached once at PostBeginPlay
var bool					bIsAssault;		// running ASGameInfo
var bool					bGameExcluded;	// the game manages respawns itself (Invasion, or Assault with AffectAssault=False)

// ---------------------------------------------------------------------------
// Init
// ---------------------------------------------------------------------------

function PostBeginPlay()
{
	local Controller C;

	Super.PostBeginPlay();

	// The vanilla ServerViewSelf()/ViewSelf() chat message is noise here.
	// An empty OwnCamera makes those ClientMessage() calls render nothing;
	// new players get the same treatment in ModifyPlayer().
	for ( C = Level.ControllerList; C != None; C = C.NextController )
		if ( PlayerController(C) != None )
			PlayerController(C).OwnCamera = "";

	// Assault: the game runs its own reinforcement waves that would co-govern
	// respawns. With AffectAssault enabled, shut them off so this mutator's
	// own batch cycle is the only respawn authority; if disabled, stay
	// hands-off in Assault.
	if ( Level.Game != None && Level.Game.IsA('ASGameInfo') )
	{
		bIsAssault = true;
		if ( AffectAssault )
		{
			ASGameInfo(Level.Game).bDisableReinforcements = true;
			log("RespawnDelay: Assault reinforcements disabled (mutator governs respawns)", 'RespawnDelay');
		}
		else
		{
			bGameExcluded = true;
			log("RespawnDelay: Assault left to vanilla reinforcements (mutator inactive here)", 'RespawnDelay');
		}
	}
	else if ( Level.Game != None && Level.Game.IsA('Invasion') && !AffectInvasion )
		bGameExcluded = true;

	// supervisor: 20 checks per second is plenty, the loops are trivial
	SetTimer(0.05, true);

	log("RespawnDelay enabled ("$Level.Game$" team="$Level.Game.bTeamGame$")"
		@"solo delay="$BaseDelay@"wave cycle="$ServerCycle, 'RespawnDelay');
}

/** Every player (not only the waiting ones) gets the quiet free-camera switch. */
function ModifyPlayer(Pawn Other)
{
	local PlayerController PC;

	Super.ModifyPlayer(Other);

	PC = PlayerController(Other.Controller);
	if ( PC != None )
		PC.OwnCamera = "";
}

// ---------------------------------------------------------------------------
// Respawn math
// ---------------------------------------------------------------------------

/**
 * Seconds still left in the current batch cycle. Cycles are counted on the
 * global server clock: every Level.TimeSeconds multiple of ServerCycle is a
 * batch boundary.
 */
function float CycleRemaining()
{
	local float Offset;

	// Level.TimeSeconds is the plain server clock (running from ~0 at map
	// load); int() truncation gives the current cycle index.
	Offset = Level.TimeSeconds - (ServerCycle * float(int(Level.TimeSeconds / ServerCycle)));
	return FMax(0.0, ServerCycle - Offset);
}

/**
 * The delay for the death of C, evaluated once at death; the result is locked
 * until respawn.
 *
 * Team games - perfect batch alignment on the global cycle:
 *   - dying exactly on a cycle boundary (TimeRemaining == ServerCycle,
 *     the cycle has just started) -> wait exactly ServerCycle seconds and
 *     spawn at the end of the current cycle;
 *   - dying anywhere else -> pushed to the NEXT wave: wait =
 *     TimeRemaining + ServerCycle, i.e. the whole cycle's dead spawn
 *     together on the closing boundary of the next cycle.
 *
 * Every respawn therefore lands exactly on a ServerCycle multiple of the
 * server clock (synchronized batches), and waits are always within
 * [ServerCycle, 2*ServerCycle] = 5-10 s with the default 5 s cycle.
 * Solo games (no batching): plain ServerCycle, i.e. the same GUI-selectable
 * value the team wave cycle uses. BaseDelay is only a fallback for a
 * misconfigured (<= 0) ServerCycle.
 */
function float RespawnDelayFor(Controller C)
{
	local float Remain;

	if ( Level.Game != None && Level.Game.bTeamGame && ServerCycle > 0 )
	{
		Remain = CycleRemaining();
		if ( Remain >= ServerCycle )		// died exactly on a boundary
			return ServerCycle;

		// pushed to the next wave; RespawnAt = DiedAt + Remain + ServerCycle
		// is an exact cycle multiple again (float-rounding aside), so the
		// whole batch spawns in the same tick.
		return Remain + ServerCycle;
	}

	// Solo games use the same wave-cycle length as the team preset instead of
	// a hard-coded 5 s (BaseDelay only as a fallback for ServerCycle <= 0).
	if ( ServerCycle > 0 )
		return ServerCycle;

	return BaseDelay;
}

// ---------------------------------------------------------------------------
// Supervision
// ---------------------------------------------------------------------------

function Timer()
{
	local Controller			C;
	local PlayerController		PC;
	local Bot					B;
	local int					i, Secs;

	if ( !Enabled )
		return;

	if ( Level.Game == None || Level.Game.bGameEnded )
	{
		// the game takes over from here; drop everything (and never leave our
		// temporary out-of-lives lock behind)
		for ( i = 0; i < Waiting.Length; i++ )
			ClearRespawnLock(i);
		Waiting.Remove(0, Waiting.Length);
		return;
	}

	// --- 1) controllers that are waiting ------------------------------------
	for ( i = Waiting.Length - 1; i >= 0; i-- )
	{
		C = Waiting[i].C;

		// gone
		if ( C == None || C.bDeleteMe )
		{
			Waiting.Remove(i, 1);
			continue;
		}

		// respawned or taken over by the game (round end, MaxLives, invasion wave ...).
		// bOutOfLives is also our own early-respawn lock during the hold-off,
		// so ignore it while we own it.
		if ( C.Pawn != None || C.PlayerReplicationInfo == None
			|| (C.PlayerReplicationInfo.bOutOfLives && !Waiting[i].bRespawnLocked) )
		{
			// a bot parked by us must go back to the vanilla machine
			B = Bot(C);
			if ( B != None && C.Pawn == None )
				B.GotoState('Dead');
			ClearRespawnLock(i);
			ClearCountdown(i);
			Waiting.Remove(i, 1);
			continue;
		}

		if ( Waiting[i].bBot )
		{
			B = Bot(C);

			// Assault round transition: the game takes every controller to
			// 'RoundEnded' (the same state we park bots in) and resets/spawns
			// them at round start - hand this bot back so the round machinery
			// owns it.
			if ( bIsAssault && ASGameInfo(Level.Game).ResetCountDown != 0 )
			{
				B.GotoState('Dead');
				Waiting.Remove(i, 1);
				continue;
			}

			// the game moved the bot out of our parking spot (round
			// transition, ...): hand it back and trust vanilla
			if ( !B.IsInState('RoundEnded') && !B.IsInState('Dead') )
			{
				B.GotoState('Dead');
				Waiting.Remove(i, 1);
				continue;
			}

			// time up -> vanilla respawn routine (what Bot "state Dead" does)
			if ( Level.TimeSeconds >= Waiting[i].RespawnAt
				&& !Level.Game.bWaitingToStartMatch
				&& Level.TimeSeconds - Waiting[i].LastAttempt > 0.5 )
			{
				Waiting[i].LastAttempt	= Level.TimeSeconds;
				Waiting[i].Tries		+= 1;
				Level.Game.RestartPlayer(C);

				// respawn keeps failing (round over, no spawn spots, ...):
				// restore the bot's own dead loop
				if ( Waiting[i].Tries > 10 )
				{
					B.GotoState('Dead');
					Waiting.Remove(i, 1);
				}
			}
			continue;
		}

		// below only humans
		PC = PlayerController(C);
		if ( PC == None )
		{
			ClearRespawnLock(i);
			Waiting.Remove(i, 1);
			continue;
		}

		// Assault round transition: the game moves every controller to
		// 'RoundEnded' and resets/spawns them at round start. Hand this human
		// back so the round machinery owns it.
		if ( bIsAssault && ASGameInfo(Level.Game).ResetCountDown != 0 )
		{
			ClearRespawnLock(i);
			ClearCountdown(i);
			Waiting.Remove(i, 1);
			continue;
		}

		// match/round machinery moved the controller (state 'RoundEnded', ...)
		if ( !PC.IsInState('Dead') && !PC.IsInState('Spectating') )
		{
			ClearRespawnLock(i);
			ClearCountdown(i);
			Waiting.Remove(i, 1);
			continue;
		}

		// Early-respawn lock: 'state Dead' lets ServerReStartPlayer() through
		// (PlayerCanRestart() -> RestartPlayer()), and Onslaught's death map
		// ("Choose Your Spawn Point" / "Spawn Here") calls exactly that RPC.
		// Clicking a power node during the hold-off therefore respawned the
		// player instantly, bypassing the locked RespawnAt (the 1 s bFrozen
		// window only guarded FIRE, not the map button). DeathMatch's
		// RestartPlayer() refuses to spawn a PRI with bOutOfLives, so flagging
		// the player for the hold-off turns every early request into a no-op
		// without touching the death camera or the client state.
		//
		// Only players who died without being out of lives reach this point
		// (the scan skips bOutOfLives), and a dead player cannot lose another
		// MaxLives life, so the flag cannot mask a legitimate "out of lives".
		// ClearRespawnLock() drops it as soon as Spectating is reached (or the
		// game takes the player over), before the scheduled respawn.
		//
		// MaxLives games and overtime are excluded from the lock
		// (CheckMaxLives() / CheckEndGame() read the flag to decide the match
		// is over); their early-respawn hole via the bForceRespawn loop / ONS
		// map cannot be closed without a safe flag.
		if ( Waiting[i].bRespawnLocked
			&& (Level.Game.MaxLives > 0 || Level.Game.bOverTime) )
		{
			ClearRespawnLock(i);		// overtime just started: drop the lock
		}
		else if ( PC.IsInState('Dead') && !Waiting[i].bRespawnLocked
			&& Level.Game.MaxLives <= 0 && !Level.Game.bOverTime )
		{
			PC.PlayerReplicationInfo.bOutOfLives = true;
			Waiting[i].bRespawnLocked = true;
		}

		// per-second HUD countdown, one pulse per whole second left
		if ( Countdown )
		{
			Secs = int(Waiting[i].RespawnAt - Level.TimeSeconds);
			if ( Secs != Waiting[i].LastCountdown && Secs >= 0 )
			{
				Waiting[i].LastCountdown = Secs;
				PC.ReceiveLocalizedMessage(class'RespawnDelayCountdown', Secs);
			}
		}

		if ( PC.IsInState('Spectating') )
		{
			// Spectating means the death-camera hold-off is over (either we
			// moved the player there or FIRE -> ServerSpectate() did): the
			// temporary out-of-lives lock must not block the scheduled spawn.
			ClearRespawnLock(i);

			// Dead players are not spectator targets: keep the camera in
			// freecam at the death spot / skip to a living player.
			UpdateSpectatorCamera(PC, i);

			// time up -> vanilla respawn routine
			if ( Level.TimeSeconds >= Waiting[i].RespawnAt
				&& !Level.Game.bWaitingToStartMatch
				&& Level.TimeSeconds - Waiting[i].LastAttempt > 0.5 )
			{
				Waiting[i].LastAttempt	= Level.TimeSeconds;
				Waiting[i].Tries		+= 1;
				if ( Level.Game.PlayerCanRestart(PC) )
				{
					// Network-critical: state 'Spectating' has ClientRestart in
					// its ignores list, so a client still sitting in Spectating
					// silently swallows the ClientRestart() the respawn sends
					// - it never leaves the spectator view (stuck until the
					// viewed pawn dies) and never re-syncs its weapon (no
					// viewmodel in first person). Leave Spectating on the
					// CLIENT first: ClientGotoState and the later ClientRestart
					// ride the same reliable channel and are applied in order,
					// so the hand-over works. Same pairing the engine itself
					// uses (RestartPlayer failure path, AskForPawn()).
					PC.ClientGotoState('PlayerWalking', 'Begin');
					Level.Game.RestartPlayer(PC);
				}
				// entry is dropped automatically once PC.Pawn != None

				// respawn keeps failing (must join before start, ...):
				// hand back to the vanilla dead state
				if ( Waiting[i].Tries > 30 )
				{
					ClearRespawnLock(i);
					ClearCountdown(i);
					PC.GotoState('Dead');
					// keep the client in step (ClientGotoState pairing, see the
					// respawn branch above) so its FIRE -> ServerRestartPlayer
					// works again afterwards
					PC.ClientGotoState('Dead', 'Begin');
					Waiting.Remove(i, 1);
				}
			}
		}
		else
		{
			// Still in the death-camera hold-off. Keep the vanilla FIRE gate
			// armed as well: in standalone / listen play this is the same
			// object the client fires through, so FIRE keeps doing nothing
			// until SpectateDelay instead of jumping to the spectator view
			// early. (Network clients have their own bFrozen and may start
			// spectating early with FIRE, but can never respawn early: the
			// bOutOfLives lock above refuses RestartPlayer.)
			PC.bFrozen = true;
			PC.SetTimer(1.0, false);

			if ( Level.TimeSeconds - Waiting[i].DiedAt >= FMax(DeathCamTime, SpectateDelay) )
			{
				// death camera (DeathCamTime) and the spectate hold-off
				// (SpectateDelay) both over -> drop the lock, vanilla spectating
				ClearRespawnLock(i);
				StartSpectating(PC);
			}
		}
	}

	// --- 2) look for fresh deaths --------------------------------------------
	for ( C = Level.ControllerList; C != None; C = C.NextController )
	{
		if ( C.bDeleteMe || C.PlayerReplicationInfo == None || !C.bIsPlayer )
			continue;
		if ( C.PlayerReplicationInfo.bOnlySpectator )
			continue;
		if ( C.PlayerReplicationInfo.bOutOfLives )
			continue;
		if ( C.Pawn != None )
			continue;
		if ( GetWaitingIndex(C) >= 0 )
			continue;
		if ( bGameExcluded )
			continue;
		PC = PlayerController(C);
		if ( PC != None )
		{
			if ( PC.IsInState('Dead') )
				RegisterDeath(PC);
			continue;
		}

		B = Bot(C);
		if ( B != None && AffectBots )
		{
			// a bot sits in "state Dead" both right after AddBot (waiting for
			// the match to start) and after its death. PreviousPawnClass is
			// only set once it has actually spawned, so it filters out the
			// match-start case.
			if ( B.IsInState('Dead') && B.PreviousPawnClass != None )
				RegisterDeath(B);
		}
	}
}

function int GetWaitingIndex(Controller C)
{
	local int i;

	for ( i = 0; i < Waiting.Length; i++ )
		if ( Waiting[i].C == C )
			return i;
	return -1;
}

function RegisterDeath(Controller C)
{
	local TWaitingPlayer	W;
	local PlayerController	PC;

	W.C				= C;
	W.bBot			= (Bot(C) != None);
	W.DiedAt		= Level.TimeSeconds;
	W.LastAttempt	= 0.0;
	W.Tries			= 0;
	W.LastCountdown	= -1;		// forces the first countdown pulse immediately
	W.bRespawnLocked	= false;
	W.LastViewTarget	= None;
	W.LastViewLocation	= vect(0,0,0);
	W.bHasViewLocation	= false;
	W.bFreeCam		= false;
	W.RespawnAt		= Level.TimeSeconds + RespawnDelayFor(C);

	Waiting[Waiting.Length] = W;

	// park bots immediately: "state Dead" is their own auto-respawn loop
	// (RestartPlayer every ~0.5 s), we own the controller until RespawnAt.
	// Leaving it would also abort the loop's pending latent Sleep.
	if ( W.bBot )
		Bot(C).GotoState('RoundEnded');

	PC = PlayerController(C);
	if ( PC != None )
		PC.OwnCamera = "";

	// Humans: lock respawns right away (see the Timer hold-off comment):
	// DeathMatch.RestartPlayer() refuses to spawn a PRI flagged bOutOfLives,
	// so even an immediate Onslaught map click / bForceRespawn tick cannot
	// bypass RespawnAt. Cleared in ClearRespawnLock(). MaxLives games and
	// overtime are excluded: CheckMaxLives() / CheckEndGame() read bOutOfLives
	// to decide the match is over, and a temporary lock could look like a full
	// wipe whenever every player happens to be dead at the same time.
	if ( PC != None && PC.PlayerReplicationInfo != None
		&& Level.Game.MaxLives <= 0 && !Level.Game.bOverTime )
	{
		PC.PlayerReplicationInfo.bOutOfLives = true;
		Waiting[Waiting.Length-1].bRespawnLocked = true;
	}

	// announce the locked delay
	if ( PC != None )
	{
		if ( Level.Game.bTeamGame )
			PC.ClientMessage(FillFormat(MsgRespawnTeam, string(W.RespawnAt - W.DiedAt)));
		else
			PC.ClientMessage(FillFormat(MsgRespawnSolo, string(W.RespawnAt - W.DiedAt)));
	}
}

/**
 * Kill the HUD countdown of a waiting human (any stale "Respawn in N" left on
 * screen while the player is alive must disappear immediately). Sent once per
 * wait: LastCountdown is moved to the "cleared" sentinel -2.
 */
function ClearCountdown(int i)
{
	local PlayerController PC;

	if ( Waiting[i].LastCountdown < 0 )
		return;								// never shown / already cleared

	Waiting[i].LastCountdown = -2;
	PC = PlayerController(Waiting[i].C);
	if ( PC != None && !PC.bDeleteMe )
		PC.ReceiveLocalizedMessage(class'RespawnDelayCountdown', -1);
}

/**
 * Remove our temporary bOutOfLives early-respawn lock and give the PRI back
 * its real value (false: only players who were not out of lives are managed).
 * Must run before spectator mode / the scheduled respawn so the vanilla
 * RestartPlayer() is not refused again.
 */
function ClearRespawnLock(int i)
{
	local PlayerController PC;

	if ( !Waiting[i].bRespawnLocked )
		return;

	Waiting[i].bRespawnLocked = false;
	PC = PlayerController(Waiting[i].C);
	if ( PC != None && !PC.bDeleteMe && PC.PlayerReplicationInfo != None )
		PC.PlayerReplicationInfo.bOutOfLives = false;
}

/**
 * Vanilla spectator mode, exactly like UnrealPlayer.ServerSpectate() does for
 * Last Man Standing: 'Spectating' state, behind view, view a living player.
 * GameInfo.CanSpectate takes care of the restriction:
 *   team games -> own team members only, DM -> all players.
 */
function StartSpectating(PlayerController PC)
{
	local Controller Target;

	PC.bFrozen		= false;	// carried over from the death camera
	PC.bPressedJump	= false;
	PC.SetTimer(0.0, false);
	PC.OwnCamera	= "";		// no "Now viewing from own camera" chat spam

	PC.GotoState('Spectating');
	// keep the client in step: force spectating on the client too (the
	// engine does the same in AskForPawn() for Spectating controllers) so
	// the FIRE/ALT-FIRE view execs exist there as well
	PC.ClientGotoState('Spectating', 'Begin');

	// Prefer a living player. If nobody is alive (solo mode with every
	// player dead, or a full team wipe), go straight to the free camera.
	Target = FirstLivingSpectateTarget(PC);
	if ( Target != None )
	{
		PC.bBehindView = true;
		PC.SetViewTarget(Target);
		PC.ClientSetViewTarget(Target);
		PC.ClientSetBehindView(true);
	}
	else
	{
		EnterFreeCam(PC, SpectateSpot(PC));
	}

	PC.ClientMessage(MsgSpectateHint);
}

/** Best current position for a free camera: death pawn, controller, or PC. */
function vector SpectateSpot(PlayerController PC)
{
	if ( PC.ViewTarget != None && PC.ViewTarget != PC && !PC.ViewTarget.bDeleteMe )
		return PC.ViewTarget.Location;
	if ( PC.RealViewTarget != None && !PC.RealViewTarget.bDeleteMe )
		return PC.RealViewTarget.Location;
	return PC.Location;
}

/** Living player the viewer is allowed to watch? (team rules included) */
function bool IsLivingSpectateTarget(PlayerController Viewer, Controller C)
{
	if ( C == None || C == Viewer || C.bDeleteMe || C.PlayerReplicationInfo == None )
		return false;
	if ( C.PlayerReplicationInfo.bOnlySpectator )
		return false;
	if ( C.Pawn == None || C.Pawn.bDeleteMe || C.Pawn.Health <= 0 )
		return false;

	return Level.Game.CanSpectate(Viewer, false, C);
}

/** First living allowed target, or None when everybody is dead. */
function Controller FirstLivingSpectateTarget(PlayerController Viewer)
{
	local Controller C;

	for ( C = Level.ControllerList; C != None; C = C.NextController )
		if ( IsLivingSpectateTarget(Viewer, C) )
			return C;

	return None;
}

function bool HasLivingSpectateTarget(PlayerController Viewer)
{
	return (FirstLivingSpectateTarget(Viewer) != None);
}

/** Is the current view target a live pawn (not a corpse and not freecam)? */
function bool IsLivingViewTarget(PlayerController PC)
{
	local Pawn P;

	P = Pawn(PC.ViewTarget);
	if ( P == None && Controller(PC.ViewTarget) != None )
		P = Controller(PC.ViewTarget).Pawn;

	return (P != None && !P.bDeleteMe && P.Health > 0);
}

/**
 * Engine FIRE cycling may land on a dead teammate. Walk the same cycle until
 * a living target is found; return false when there is nobody left alive.
 */
function bool AdvanceToLiving(PlayerController PC)
{
	local int Guard, Count;
	local Controller C;

	for ( C = Level.ControllerList; C != None; C = C.NextController )
		Count++;

	for ( Guard = 0; Guard <= Count; Guard++ )
	{
		PC.ServerViewNextPlayer();
		if ( IsLivingViewTarget(PC) )
			return true;
	}

	return false;
}

/**
 * Own free camera, anchored at Loc. This is ServerViewSelf() without its
 * "Now viewing from own camera" ClientMessage().
 */
function EnterFreeCam(PlayerController PC, vector Loc)
{
	PC.bBehindView = false;
	PC.ClientSetBehindView(false);
	PC.SetLocation(Loc);
	PC.ClientSetLocation(Loc, PC.Rotation);
	PC.SetViewTarget(PC);
	PC.ClientSetViewTarget(PC);
}

/**
 * Keep the waiting spectator camera sane every supervisor tick:
 *  - while the watched player is alive, remember their location;
 *  - when that player dies, stay at the death spot in free camera;
 *  - when FIRE lands on an already-dead player, skip to the next living one;
 *  - when nobody is alive, force free camera.
 */
function UpdateSpectatorCamera(PlayerController PC, int i)
{
	local Actor		VT;
	local Pawn		P;
	local vector	Loc;
	local bool		bLiving, bVanished;

	VT = PC.ViewTarget;

	if ( VT == PC )
	{
		// Already in freecam. Anchor once if we arrived here because the
		// watched pawn vanished, then leave the player free to orbit.
		if ( !Waiting[i].bFreeCam && Waiting[i].bHasViewLocation )
			EnterFreeCam(PC, Waiting[i].LastViewLocation);
		Waiting[i].bFreeCam		= true;
		Waiting[i].LastViewTarget	= PC;
		return;
	}

	P = Pawn(VT);
	if ( P == None && Controller(VT) != None )
		P = Controller(VT).Pawn;

	bLiving = (P != None && !P.bDeleteMe && P.Health > 0);
	if ( bLiving )
	{
		Waiting[i].LastViewTarget	= VT;
		Waiting[i].LastViewLocation	= P.Location;
		Waiting[i].bHasViewLocation	= true;
		Waiting[i].bFreeCam		= false;
		return;
	}

	// The view target is dead / gone: its location is the death spot.
	// A destroyed pawn can linger as a zeroed actor for a tick, so prefer
	// the last position we saw while it was alive.
	bVanished = ( VT == None || VT.bDeleteMe
		|| (P != None && P.bDeleteMe) );
	if ( P != None && !P.bDeleteMe )
		Loc = P.Location;
	else if ( Waiting[i].bHasViewLocation )
		Loc = Waiting[i].LastViewLocation;
	else if ( VT != None && !VT.bDeleteMe )
		Loc = VT.Location;
	else if ( PC.RealViewTarget != None && !PC.RealViewTarget.bDeleteMe )
		Loc = PC.RealViewTarget.Location;
	else
		Loc = PC.Location;

	// FIRE just moved us onto a dead player -> skip it, don't park there.
	// (If the player we were already watching just died, VT is still the
	// LastViewTarget - or it vanished - and we fall through to freecam at
	// the death spot.)
	if ( !bVanished && VT != Waiting[i].LastViewTarget
		&& HasLivingSpectateTarget(PC) )
	{
		if ( AdvanceToLiving(PC) )
			return;
	}

	EnterFreeCam(PC, Loc);
	Waiting[i].bFreeCam		= true;
	Waiting[i].LastViewTarget	= PC;
	Waiting[i].LastViewLocation	= Loc;
	Waiting[i].bHasViewLocation	= true;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function string FillFormat(string F, string V1)
{
	ReplaceText(F, "%1", V1);
	return F;
}

// ---------------------------------------------------------------------------
// Console: "mutate respawnstatus" prints the current delay situation
// ---------------------------------------------------------------------------

function Mutate(string MutateString, PlayerController Sender)
{
	local int Idx;

	if ( Sender != None && MutateString ~= "respawnstatus" )
	{
		Idx = GetWaitingIndex(Sender);
		if ( Idx >= 0 )
			Sender.ClientMessage(FillFormat(MsgStatusWaiting, string(FMax(0.0, Waiting[Idx].RespawnAt - Level.TimeSeconds))));
		else
			Sender.ClientMessage(MsgStatusIdle);
	}

	Super.Mutate(MutateString, Sender);
}

// ---------------------------------------------------------------------------
// Mutator GUI (PlayInfo): the "Respawn wave cycle" preset dropdown
// ---------------------------------------------------------------------------

static function FillPlayInfo(PlayInfo PlayInfo)
{
	Super.FillPlayInfo(PlayInfo);	// always begin with calling the parent

	PlayInfo.AddSetting(default.RespGroup, "ServerCycle",
		GetDisplayText("ServerCycle"), 0, 1, "Select", default.CyclePresetText);
}

static function string GetDisplayText(string PropName)
{
	if ( PropName ~= "ServerCycle" )
		return default.CycleDisplayText;

	return "";
}

static event string GetDescriptionText(string PropName)
{
	if ( PropName ~= "ServerCycle" )
		return default.CycleDescText;

	return "";
}

// ---------------------------------------------------------------------------
// Defaults
// ---------------------------------------------------------------------------

defaultproperties
{
	Enabled=True
	BaseDelay=5.000000
	ServerCycle=5.000000
	DeathCamTime=1.000000
	SpectateDelay=3.000000
	Countdown=True
	AffectBots=True
	AffectInvasion=False
	AffectAssault=True
	RespGroup="Respawn Delay"
	CycleDisplayText="Respawn wave cycle"
	CycleDescText="Server wave cycle for team games: everyone dying within a wave respawns together at the end of the next one, and waits always span one to two cycles. Arena [3-6s]: continuous chaos, fast micro-batches. Standard [5-10s]: competitive balance. Methodic [10-20s]: methodical pushing waves. Strategic [15-30s]: large coordinated waves. Tactical [30-60s]: heavy combat simulation. Solo games use the selected cycle length as a plain wait, so waits are exactly 3s, 5s, 10s, 15s or 30s."
	CyclePresetText="3.000000;Arena [3-6s];5.000000;Standard [5-10s];10.000000;Methodic [10-20s];15.000000;Strategic [15-30s];30.000000;Tactical [30-60s]"
}
