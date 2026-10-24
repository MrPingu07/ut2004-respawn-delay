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
//  - bBeep=False          -> silence
//
// Switch encodes the seconds remaining (the mutator emits one message per
// whole second while the player waits).
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
	if ( Switch <= 0 )
		return Default.FinalLabel;

	return Default.Label $ Switch;
}

// ---------------------------------------------------------------------------
// Look & feel
// ---------------------------------------------------------------------------

static function color GetColor(
	optional int Switch,
	optional PlayerReplicationInfo RelatedPRI_1,
	optional PlayerReplicationInfo RelatedPRI_2
	)
{
	local color C;

	C = Default.DrawColor;

	// last three seconds light up red
	if ( Switch <= 3 )
	{
		C.R = 255;
		C.G = 40;
		C.B = 40;
	}
	return C;
}

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
	bBeep=False

	Lifetime=1.25
	FontSize=1
	PosX=0.500000
	PosY=0.720000
	DrawPivot=DP_MiddleMiddle
	StackMode=SM_None
	DrawColor=(R=255,G=200,B=32,A=255)
}
