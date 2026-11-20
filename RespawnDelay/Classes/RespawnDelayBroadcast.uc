//=============================================================================
// RespawnDelayBroadcast
//
// Server-authoritative banner broadcast, replicated to every client.
//
// The banner used to be authored independently on each waiting client: every
// viewer picked its own line from its own shuffled bag, rolled its own
// $RANDOM values and started its own typewriter at its own death.  That made
// the "broadcast" a private feed that happened to look similar.
//
// This ReplicationInfo is spawned once by RespawnDelay on the server (when the
// banner is enabled).  It advances a single global message cycle:
//
//   * one shared message bag, shuffled on the server, team-only lines skipped
//     in non-team modes;
//   * tokens expanded ONCE on the server (so $RANDOM and scores are identical
//     for everybody and cannot change mid-typewriter);
//   * CurrentText + CycleStart replicated to all clients.
//
// Clients simply draw CurrentText against Level.TimeSeconds - CycleStart.
// Level.TimeSeconds tracks the server clock, so the typewriter/cursor phase is
// within a frame or two on every machine.  A player who dies mid-cycle joins
// the broadcast in progress, exactly like a radio feed.
//=============================================================================
class RespawnDelayBroadcast extends ReplicationInfo;

/** Length of one banner message cycle.  Must match the HUD's constant. */
const TOTAL_CYCLE = 10.0;

/** Finished (already expanded) line every client must draw. */
var string CurrentText;

/** Server Level.TimeSeconds at which the current cycle started. */
var float CycleStart;

/** Cycle length in seconds (replicated so the HUD never has to guess). */
var float CycleLength;

/** Index of CurrentText in the source array, for diagnostics (-1 = fallback). */
var int MessageIndex;

/** True when the server is running a team game (team tokens are valid). */
var bool bTeamGame;

// Server-side only: no-repeat bag over the configured message array.
var transient array<int> FeedBag;
var transient int FeedBagSize;

// Client-side phase anchor.  Absolute Level.TimeSeconds is not guaranteed to
// have the same origin on every machine, so each client anchors the cycle when
// the replicated CycleStart actually arrives.  The actor is bAlwaysRelevant and
// keeps tracking cycles even while nobody is waiting, so a player who dies
// mid-cycle joins the broadcast already in progress.
var transient float LocalCycleStart;
var transient float LastSeenCycleStart;
var transient bool bCycleAnchored;

replication
{
	// Server -> every client: the shared broadcast state.  These change once
	// per cycle, so this is a handful of bytes every ten seconds.
	reliable if ( Role == ROLE_Authority )
		CurrentText, CycleStart, CycleLength, MessageIndex, bTeamGame;
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

/** Client: remember when the first replicated cycle reached this machine. */
simulated event PostNetBeginPlay()
{
	Super.PostNetBeginPlay();

	LastSeenCycleStart = CycleStart;
	LocalCycleStart = Level.TimeSeconds;
	bCycleAnchored = True;
}

/** Client: a new CycleStart arrived, start the local typewriter clock. */
simulated event PostNetReceive()
{
	Super.PostNetReceive();

	if ( !bCycleAnchored || CycleStart != LastSeenCycleStart )
	{
		LastSeenCycleStart = CycleStart;
		LocalCycleStart = Level.TimeSeconds;
		bCycleAnchored = True;
	}
}

/**
 * Seconds into the current cycle as seen from this machine.
 *
 * On the authority the server clock is the reference.  On a client the phase
 * is anchored to the moment the replicated CycleStart arrived, so machines do
 * not need synchronized absolute clocks; the only skew is one network update
 * plus their frame times.
 */
simulated function float GetCycleElapsed()
{
	if ( Role == ROLE_Authority )
		return FMax(0.0, Level.TimeSeconds - CycleStart);

	if ( !bCycleAnchored )
	{
		// The HUD can theoretically draw before PostNetBeginPlay; anchor now
		// rather than producing a huge elapsed time.
		LastSeenCycleStart = CycleStart;
		LocalCycleStart = Level.TimeSeconds;
		bCycleAnchored = True;
	}

	return FMax(0.0, Level.TimeSeconds - LocalCycleStart);
}

/** First cycle: anchor the shared clock and pick the opening message. */
function InitBroadcast()
{
	if ( Role < ROLE_Authority )
		return;

	bTeamGame = (Level.Game != None && Level.Game.bTeamGame);
	CycleLength = TOTAL_CYCLE;
	CycleStart = Level.TimeSeconds;
	AdvanceMessage();
}

/**
 * Called from the mutator's supervisor timer.  Advances the shared cycle when
 * it expires.  CycleStart is moved forward by whole CycleLength steps so the
 * boundaries stay aligned with the original anchor (a long server hitch skips
 * the messages that would have played meanwhile instead of drifting).
 */
function UpdateBroadcast()
{
	local int Guard;

	if ( Role < ROLE_Authority )
		return;

	if ( CycleLength <= 0.0 )
		CycleLength = TOTAL_CYCLE;

	while ( Level.TimeSeconds - CycleStart >= CycleLength )
	{
		CycleStart += CycleLength;
		AdvanceMessage();

		Guard++;
		if ( Guard > 8 )
		{
			// Pathological hitch or clock jump: re-anchor rather than spin.
			CycleStart = Level.TimeSeconds;
			break;
		}
	}
}

/**
 * Select the next line from the server's configured feed, skip team-only
 * lines in non-team modes, and expand its tokens once.  The result is what
 * every client will draw for the next CycleLength seconds.
 */
function AdvanceMessage()
{
	local array<string> Source;
	local int i, j, tmp, Tries, Count;
	local string Msg;
	local GameReplicationInfo GRI;

	bTeamGame = (Level.Game != None && Level.Game.bTeamGame);

	Source = class'RespawnDelayFeed'.default.Messages;
	Count = Source.Length;

	// A changed source invalidates old bag indices.
	if ( Count != FeedBagSize )
	{
		FeedBag.Length = 0;
		FeedBagSize = Count;
	}

	if ( Count == 0 )
	{
		CurrentText = "RESPAWN DELAY ACTIVE";
		MessageIndex = -1;
		return;
	}

	GRI = None;
	if ( Level.Game != None )
		GRI = Level.Game.GameReplicationInfo;

	for ( Tries = 0; Tries < Count; Tries++ )
	{
		if ( FeedBag.Length == 0 )
		{
			FeedBag.Length = Count;
			for ( i = 0; i < Count; i++ )
				FeedBag[i] = i;
			for ( i = Count - 1; i > 0; i-- )
			{
				j = Rand(i + 1);
				tmp = FeedBag[i];
				FeedBag[i] = FeedBag[j];
				FeedBag[j] = tmp;
			}
		}

		i = FeedBag[FeedBag.Length - 1];
		FeedBag.Length = FeedBag.Length - 1;
		Msg = Source[i];

		if ( Msg == "" )
			continue;

		// Team-only lines are meaningless in DM/LMS/etc.  The token expander
		// still blanks those tokens as a safety net, but skipping the whole
		// line avoids broadcasts like " ... DEFEND THE CORNER".
		if ( !bTeamGame && class'RespawnDelayFeed'.static.HasTeamOnlyTokens(Msg) )
			continue;

		CurrentText = class'RespawnDelayFeed'.static.ExpandTokens(
			Msg, GRI, bTeamGame, Level);
		MessageIndex = i;

		log("RespawnDelay: broadcast message " $ MessageIndex $ ": " $ CurrentText, 'RespawnDelay');
		return;
	}

	CurrentText = "RESPAWN DELAY ACTIVE";
	MessageIndex = -1;
}

defaultproperties
{
	bAlwaysRelevant=True
	bOnlyRelevantToOwner=False
	RemoteRole=ROLE_SimulatedProxy
	NetUpdateFrequency=30.000000
	bNetInitial=True
	bNetNotify=True
	bStatic=False
	bNoDelete=False
}
