//=============================================================================
// RespawnDelay.uc
//
// Levels: Mutator "Respawn Delay".
//
// Forces players to wait before they can respawn after dying:
//
//  * Team based game modes (TDM, CTF, BR, DOM, ONS, AS, ...):
//      the delay scales with how many team-mates are ALIVE at the moment of
//      death. Defaults (broken in through DelayTable):
//          1  alive ally -> 3s
//          5  alive allies -> 8s
//          10 alive allies -> 15s
//      piecewise linear in between, clamped below the first and above the
//      last anchor. The value is computed ONCE (at death) and "set in
//      stone" until the player respawns.
//
//  * Non team modes (DM, LMS, ...): fixed BaseDelay (default 5 seconds).
//
//  * Bots are delayed the same way (config AffectBots): a dying bot is parked
//    in the passive controller state 'RoundEnded' (it just idles there, like
//    when an Assault round ends) and GameInfo.RestartPlayer() is called at the
//    locked time. Possess -> Restart() -> Bot.Restart() then drops it straight
//    into 'Roaming', i.e. the exact vanilla wake-up path. Respawnless game
//    modes (Invasion's bOutOfLives waves) are excluded (AffectInvasion).
//
//  * While waiting, players are put in the vanilla 'Spectating' state:
//      FIRE            cycles the camera through the players allowed by the
//                      game type (own team members in team games, every
//                      player in solo games, as enforced by GameInfo.CanSpectate)
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
//    2. After the vanilla death camera window (DeathCamTime) the controller is
//       moved to the vanilla 'Spectating' state (same thing UT2004 itself does
//       for Last Man Standing, via UnrealPlayer.ServerSpectate).
//    3. When the locked respawn time is reached, the supervisor calls
//       GameInfo.PlayerCanRestart() and GameInfo.RestartPlayer(), i.e. the
//       exact vanilla respawn routine (bots get RestartPlayer() directly,
//       exactly what vanilla Bot "state Dead" does).
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

/** Respawn delay (seconds) in non team games (and in team games if TeamFormula is disabled). */
var() config float	BaseDelay;

/**
 * Team curve, "aliveAllies,delaySeconds" pairs separated by spaces.
 * Default: "1,3 5,8 10,15"
 *   - fewer alive allies than the first anchor -> first anchor's delay
 *   - between anchors                          -> linear interpolation
 *   - more alive allies than the last anchor   -> last anchor's delay
 */
var() config string	DelayTable;

/** Seconds still spent in the vanilla death camera before spectator mode starts. */
var() config float	DeathCamTime;

/** False to apply BaseDelay in team games as well (formula off). */
var() config bool	TeamFormula;

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

// ---------------------------------------------------------------------------
// Localization (see RespawnDelay.int)
// ---------------------------------------------------------------------------
var localized string	MsgRespawnTeam;		// "%1" all of the seconds, "%2" their alive allies
var localized string	MsgRespawnSolo;		// "%1" number of seconds
var localized string	MsgSpectateHint;
var localized string	MsgStatusWaiting;	// "%1" the seconds remaining
var localized string	MsgStatusIdle;

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
	var int					AlliesAlive;// snapshot taken at death
	var float				LastAttempt;// last RestartPlayer attempt (rate limiter)
	var int					Tries;		// failed RestartPlayer attempts
	var int					LastCountdown;	// whole seconds already displayed (-1 = none yet, -2 = cleared)
};

var array<TWaitingPlayer>	Waiting;

// DelayTable parsed into these
var array<float>			CurveN;		// "alive allies" breakpoints
var array<float>			CurveT;		// "delay seconds" breakpoints

// ---------------------------------------------------------------------------
// Init
// ---------------------------------------------------------------------------

function PostBeginPlay()
{
	Super.PostBeginPlay();

	ParseDelayTable();

	// supervisor: 20 checks per second is plenty, the loops are trivial
	SetTimer(0.05, true);

	log("RespawnDelay enabled ("$Level.Game$" team="$Level.Game.bTeamGame$") BaseDelay="$BaseDelay@"Table="$DelayTable, 'RespawnDelay');
}

// ---------------------------------------------------------------------------
// Delay table parsing
// ---------------------------------------------------------------------------

function ParseDelayTable()
{
	local string Remaining, Pair;
	local int i, Comma;
	local float n, t;

	CurveN.Length = 0;
	CurveT.Length = 0;

	Remaining = DelayTable;
	while ( Remaining != "" )
	{
		// strip leading spaces
		while ( Left(Remaining, 1) == " " )
			Remaining = Mid(Remaining, 1);
		if ( Remaining == "" )
			break;

		i = InStr(Remaining, " ");
		if ( i >= 0 )
		{
			Pair = Left(Remaining, i);
			Remaining = Mid(Remaining, i + 1);
		}
		else
		{
			Pair = Remaining;
			Remaining = "";
		}

		Comma = InStr(Pair, ",");
		if ( Comma <= 0 )
			continue;

		n = float(Left(Pair, Comma));
		t = float(Mid(Pair, Comma + 1));
		if ( n < 0.0 || t < 0.0 )
			continue;

		CurveN[CurveN.Length] = n;
		CurveT[CurveT.Length] = t;
	}

	// fall back to the documented defaults on a broken table
	if ( CurveN.Length == 0 )
	{
		CurveN[0] = 1.0;  CurveT[0] = 3.0;
		CurveN[1] = 5.0;  CurveT[1] = 8.0;
		CurveN[2] = 10.0; CurveT[2] = 15.0;
		log("RespawnDelay: DelayTable could not be parsed, using default curve", 'RespawnDelay');
	}
}

// ---------------------------------------------------------------------------
// Curve evaluation
// ---------------------------------------------------------------------------

/**
 * The delay for the death of C, evaluated with the CURRENT number of allies
 * alive. Called exactly once per death; the result is locked until respawn.
 */
function float RespawnDelayFor(Controller C)
{
	if ( Level.Game != None && Level.Game.bTeamGame && TeamFormula )
		return TeamRespawnDelay(C);

	return BaseDelay;
}

function float TeamRespawnDelay(Controller C)
{
	local int N;
	local int i;
	local float N0, D0, N1, D1;

	N = CountAliveAllies(C);

	// before the first anchor / no curve
	if ( N <= CurveN[0] )
		return CurveT[0];

	// linear interpolation between anchors
	for ( i = 1; i < CurveN.Length; i++ )
	{
		if ( N <= CurveN[i] )
		{
			N0 = CurveN[i-1];
			D0 = CurveT[i-1];
			N1 = CurveN[i];
			D1 = CurveT[i];
			return D0 + (D1 - D0) * ( (N - N0) / (N1 - N0) );
		}
	}

	// beyond the last anchor
	return CurveT[CurveN.Length - 1];
}

/**
 * Number of team-mates (appointments/bots aside: any non spectator
 * team member) that are currently alive, Observer excluded.
 */
function int CountAliveAllies(Controller Observer)
{
	local Controller C;
	local int N;

	for ( C = Level.ControllerList; C != None; C = C.NextController )
	{
		if ( C == Observer || C.bDeleteMe )
			continue;
		if ( C.PlayerReplicationInfo == None )
			continue;
		if ( C.PlayerReplicationInfo.bOnlySpectator )
			continue;
		if ( C.PlayerReplicationInfo.bOutOfLives )
			continue;
		if ( C.GetTeamNum() != Observer.GetTeamNum() )
			continue;
		if ( C.Pawn == None || C.Pawn.bDeleteMe || C.Pawn.Health <= 0 )
			continue;
		N++;
	}
	return N;
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
		// the game takes over from here; drop everything
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

		// respawned or taken over by the game (round end, MaxLives, invasion wave ...)
		if ( C.Pawn != None || C.PlayerReplicationInfo == None || C.PlayerReplicationInfo.bOutOfLives )
		{
			// a bot parked by us must go back to the vanilla machine
			B = Bot(C);
			if ( B != None && C.Pawn == None )
				B.GotoState('Dead');
			ClearCountdown(i);
			Waiting.Remove(i, 1);
			continue;
		}

		if ( Waiting[i].bBot )
		{
			B = Bot(C);

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
			Waiting.Remove(i, 1);
			continue;
		}

		// match/round machinery moved the controller (state 'RoundEnded', ...)
		if ( !PC.IsInState('Dead') && !PC.IsInState('Spectating') )
		{
			ClearCountdown(i);
			Waiting.Remove(i, 1);
			continue;
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
			// time up -> vanilla respawn routine
			if ( Level.TimeSeconds >= Waiting[i].RespawnAt
				&& !Level.Game.bWaitingToStartMatch
				&& Level.TimeSeconds - Waiting[i].LastAttempt > 0.5 )
			{
				Waiting[i].LastAttempt	= Level.TimeSeconds;
				Waiting[i].Tries		+= 1;
				if ( Level.Game.PlayerCanRestart(PC) )
					Level.Game.RestartPlayer(PC);
				// entry is dropped automatically once PC.Pawn != None

				// respawn keeps failing (must join before start, ...):
				// hand back to the vanilla dead state
				if ( Waiting[i].Tries > 30 )
				{
					ClearCountdown(i);
					PC.GotoState('Dead');
					Waiting.Remove(i, 1);
				}
			}
		}
		else if ( Level.TimeSeconds - Waiting[i].DiedAt >= DeathCamTime )
		{
			// death camera over -> vanilla spectator mode
			StartSpectating(PC);
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
		if ( Level.Game.IsA('Invasion') && !AffectInvasion )
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
	W.AlliesAlive	= CountAliveAllies(C);
	W.RespawnAt		= Level.TimeSeconds + RespawnDelayFor(C);

	Waiting[Waiting.Length] = W;

	// announce the locked delay
	PC = PlayerController(C);
	if ( PC != None )
	{
		if ( Level.Game.bTeamGame && TeamFormula )
			PC.ClientMessage(FillFormat2(MsgRespawnTeam, string(W.RespawnAt - W.DiedAt), string(W.AlliesAlive)));
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
 * Vanilla spectator mode, exactly like UnrealPlayer.ServerSpectate() does for
 * Last Man Standing: 'Spectating' state, behind view, cycle to a player view.
 * GameInfo.CanSpectate takes care of the restriction:
 *   team games -> own team members only, DM -> all players.
 */
function StartSpectating(PlayerController PC)
{
	PC.bFrozen		= false;	// carried over from the death camera
	PC.bPressedJump	= false;
	PC.SetTimer(0.0, false);

	PC.GotoState('Spectating');
	PC.bBehindView	= true;
	PC.ServerViewNextPlayer();

	PC.ClientMessage(MsgSpectateHint);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function string FillFormat(string F, string V1)
{
	ReplaceText(F, "%1", V1);
	return F;
}

function string FillFormat2(string F, string V1, string V2)
{
	F = FillFormat(F, V1);
	ReplaceText(F, "%2", V2);
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
// Defaults
// ---------------------------------------------------------------------------

defaultproperties
{
	Enabled=True
	BaseDelay=5.000000
	DeathCamTime=1.000000
	TeamFormula=True
	Countdown=True
	AffectBots=True
	AffectInvasion=False
	DelayTable="1,3 5,8 10,15"
}
