//=============================================================================
// RespawnDelayCountdown.uc
//
// HUD countdown shown to players waiting for a RespawnDelay respawn.
// Sent with PlayerController.ReceiveLocalizedMessage, i.e. it only ever
// reaches the waiting player's HUD:
//
//  - bIsSpecial=True      -> rendered as a positioned HUD message
//  - bIsUnique=True       -> the new update REPLACES the previous one
//                            (single clean line that ticks 10, 9, 8, ...)
//  - bIsConsoleMessage=False -> never written to the chat/console area,
//                            other players never see it
//  - bFadeMessage=True    -> the HUD culls the line once its LifeTime is over
//                            (without this an expired line would sit on the
//                            screen forever - the "frozen number" bug)
//  - bBeep=False          -> silence
//
// Switch encodes the seconds remaining (the mutator emits one message per
// whole second while the player waits). Switch < 0 is the "clear" pulse: the
// mutator sends it whenever a waiting entry is dropped, so a stale number can
// never outlive the wait (GetString returns an empty string for it).
//=============================================================================
class RespawnDelayCountdown extends LocalMessage;

var localized string Label;				// "RESPAWN IN "
var localized string FinalLabel;		// "RESPAWN" (no seconds left)

// ---------------------------------------------------------------------------
// Text
// ---------------------------------------------------------------------------

static function string GetString(
	optional int Switch,
	optional PlayerReplicationInfo RelatedPRI_1,
	optional PlayerReplicationInfo RelatedPRI_2,
	optional Object OptionalObject
	)
{
	if ( Switch < 0 )
		return "";						// "clear" pulse: renders nothing

	if ( Switch <= 0 )
		return Default.FinalLabel;

	return Default.Label $ Switch;
}

// ---------------------------------------------------------------------------
// Look & feel
// ---------------------------------------------------------------------------

// always white: no GetColor override; DrawColor below is pure white

static function int GetFontSize(
	int Switch,
	PlayerReplicationInfo RelatedPRI1,
	PlayerReplicationInfo RelatedPRI2,
	PlayerReplicationInfo LocalPlayer
	)
{
	if ( Switch <= 3 )
		return 0;	// huge

	return Default.FontSize;
}

static function float GetLifeTime(int Switch)
{
	return 1.25;		// replaced every second anyway
}

// ---------------------------------------------------------------------------
// Defaults
// ---------------------------------------------------------------------------

defaultproperties
{
	bIsSpecial=True
	bIsUnique=True
	bIsConsoleMessage=False
	bFadeMessage=True
	bBeep=False

	Lifetime=1.25
	FontSize=1
	PosX=0.500000
	PosY=0.720000
	DrawPivot=DP_MiddleMiddle
	StackMode=SM_None
	DrawColor=(R=255,G=255,B=255,A=255)
}
