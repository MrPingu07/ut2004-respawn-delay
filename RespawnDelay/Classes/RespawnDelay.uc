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
//  * Non team modes (DM, LMS, ...): fixed BaseDelay (default 3 seconds).
//
//  * While waiting, players are put in the vanilla 'Spectating' state:
//      FIRE            cycles the camera through the players allowed by the
//                      game type (own team members in team games, every
//                      player in solo games, as enforced by GameInfo.CanSpectate)
//      ALT-FIRE        returns to the own (free) camera
//      Aggression AE   spectator free camera (fly around the map)
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
//       exact vanilla respawn routine.
//=============================================================================
class RespawnDelay extends Mutator
	config(RespawnDelay);

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

// one entry per player currently sitting out the delay
struct TWaitingPlayer
{
	var PlayerController	PC;
	var float				DiedAt;		// server time of the detected death
	var float				RespawnAt;	// locked respawn time
	var int					AlliesAlive;// snapshot taken at death
	var float				LastAttempt;// last RestartPlayer attempt (rate limiter)
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
 * The delay for the death of PC, evaluated with the CURRENT number of allies
 * alive. Called exactly once per death; the result is locked until respawn.
 */
function float RespawnDelayFor(PlayerController PC)
{
	if ( Level.Game != None && Level.Game.bTeamGame && TeamFormula )
		return TeamRespawnDelay(PC);

	return BaseDelay;
}

function float TeamRespawnDelay(PlayerController PC)
{
	local int N;
	local int i;
	local float N0, D0, N1, D1;

	N = CountAliveAllies(PC);

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
	local int					i;

	if ( !Enabled )
		return;

	if ( Level.Game == None || Level.Game.bGameEnded )
	{
		// the game takes over from here; drop everything
		Waiting.Remove(0, Waiting.Length);
		return;
	}

	// --- 1) players that are waiting ----------------------------------------
	for ( i = Waiting.Length - 1; i >= 0; i-- )
	{
		PC = Waiting[i].PC;

		// gone
		if ( PC == None || PC.bDeleteMe )
		{
			Waiting.Remove(i, 1);
			continue;
		}

		//respawned or taken over by the game (round end, MaxLives, invasion wave ...)
		if ( PC.Pawn != None || PC.PlayerReplicationInfo.bOutOfLives )
		{
			Waiting.Remove(i, 1);
			continue;
		}

		// match/round machinery moved the controller (state 'RoundEnded', ...)
		if ( !PC.IsInState('Dead') && !PC.IsInState('Spectating') )
		{
			Waiting.Remove(i, 1);
			continue;
		}

		if ( PC.IsInState('Spectating') )
		{
			// time up -> vanilla respawn routine
			if ( Level.TimeSeconds >= Waiting[i].RespawnAt
				&& !Level.Game.bWaitingToStartMatch
				&& Level.TimeSeconds - Waiting[i].LastAttempt > 0.5 )
			{
				Waiting[i].LastAttempt = Level.TimeSeconds;
				if ( Level.Game.PlayerCanRestart(PC) )
					Level.Game.RestartPlayer(PC);
				// entry is dropped automatically once PC.Pawn != None
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
		PC = PlayerController(C);
		if ( PC == None || PC.bDeleteMe || PC.PlayerReplicationInfo == None )
			continue;
		if ( PC.PlayerReplicationInfo.bOnlySpectator )
			continue;
		if ( PC.PlayerReplicationInfo.bOutOfLives )
			continue;
		if ( !PC.IsInState('Dead') || PC.Pawn != None )
			continue;
		if ( GetWaitingIndex(PC) >= 0 )
			continue;
		if ( Level.Game.IsA('Invasion') && !AffectInvasion )
			continue;

		RegisterDeath(PC);
	}
}

function int GetWaitingIndex(PlayerController PC)
{
	local int i;

	for ( i = 0; i < Waiting.Length; i++ )
		if ( Waiting[i].PC == PC )
			return i;
	return -1;
}

function RegisterDeath(PlayerController PC)
{
	local TWaitingPlayer W;

	W.PC			= PC;
	W.DiedAt		= Level.TimeSeconds;
	W.LastAttempt	= 0.0;
	W.AlliesAlive	= CountAliveAllies(PC);
	W.RespawnAt		= Level.TimeSeconds + RespawnDelayFor(PC);

	Waiting[Waiting.Length] = W;

	// announce the locked delay
	if ( Level.Game.bTeamGame && TeamFormula )
		PC.ClientMessage(FillFormat2(MsgRespawnTeam, string(W.RespawnAt - W.DiedAt), string(W.AlliesAlive)));
	else
		PC.ClientMessage(FillFormat(MsgRespawnSolo, string(W.RespawnAt - W.DiedAt)));
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
	BaseDelay=3.000000
	DeathCamTime=1.000000
	TeamFormula=True
	AffectInvasion=False
	DelayTable="1,3 5,8 10,15"
}
