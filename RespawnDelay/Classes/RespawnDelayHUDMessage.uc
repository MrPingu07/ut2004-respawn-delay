//=============================================================================
// RespawnDelayHUDMessage
//
// Invisible "message" whose only job is to run code on the owning client.
//
// PlayerController.myHUD and Player.InteractionMaster are CLIENT-side objects.
// Assigning them on the server does nothing for a network client (and the
// objects do not even exist there), which is why the banner/beacon takeover
// must be triggered from the receiving machine.  UT2004 has no generic
// server->client script RPC, but LocalMessage.ClientReceive runs on the client
// when the server sends a reliable PlayerController.ReceiveLocalizedMessage.
//
// Switch encodes what to install:
//   0  -> teardown: restore the original HUD and detach the beacons
//   1  -> install the banner HUD
//   2  -> install the beacon interaction
//   3  -> both
//
// The original HUD/ScoreBoard classes are stored on the RespawnDelayBannerHUD
// itself so the teardown pulse can restore exactly what the player had.
//=============================================================================
class RespawnDelayHUDMessage extends LocalMessage;

/** Nothing is ever drawn: this is a client-side code hook, not a notice. */
static function string GetString(
	optional int Switch,
	optional PlayerReplicationInfo RelatedPRI_1,
	optional PlayerReplicationInfo RelatedPRI_2,
	optional Object OptionalObject
	)
{
	return "";
}

static function bool IsConsoleMessage(int Switch)
{
	return False;
}

static function float GetLifeTime(int Switch)
{
	return 0.0;
}

static function ClientReceive(
	PlayerController P,
	optional int Switch,
	optional PlayerReplicationInfo RelatedPRI_1,
	optional PlayerReplicationInfo RelatedPRI_2,
	optional Object OptionalObject
	)
{
	if ( P == None || P.bDeleteMe )
		return;

	if ( Switch <= 0 )
	{
		RestoreBannerHUD(P);
		DetachBeaconInteraction(P);
		return;
	}

	if ( (Switch & 1) != 0 )
		InstallBannerHUD(P);
	if ( (Switch & 2) != 0 )
		InstallBeaconInteraction(P);
}

/**
 * Replace the stock HUD with RespawnDelayBannerHUD, remembering what to
 * restore later.  Idempotent: a second activation pulse while the banner is
 * already installed just leaves the saved classes untouched.
 */
static function InstallBannerHUD(PlayerController P)
{
	local RespawnDelayBannerHUD BannerHUD;

	if ( P == None || P.bDeleteMe || P.myHUD == None )
		return;

	// Already ours (re-entry / repeated pulse): keep the saved originals.
	BannerHUD = RespawnDelayBannerHUD(P.myHUD);
	if ( BannerHUD != None )
		return;

	BannerHUD = P.Spawn(class'RespawnDelayBannerHUD', P);
	if ( BannerHUD == None )
	{
		log("RespawnDelay: failed to spawn banner HUD for " $ P, 'RespawnDelay');
		return;
	}

	BannerHUD.OriginalHUDClass = P.myHUD.Class;
	if ( P.myHUD.ScoreBoard != None )
		BannerHUD.OriginalScoreBoardClass = P.myHUD.ScoreBoard.Class;
	else
		BannerHUD.OriginalScoreBoardClass = None;

	P.myHUD = BannerHUD;

	// Keep the stock scoreboard (F1) working on the replacement HUD.
	if ( BannerHUD.OriginalScoreBoardClass != None )
		BannerHUD.SetScoreBoardClass(BannerHUD.OriginalScoreBoardClass);

	log("RespawnDelay: installed banner HUD for " $ P
		$ " (original " $ BannerHUD.OriginalHUDClass $ ")", 'RespawnDelay');
}

/** Put the saved stock HUD back and drop the banner. */
static function RestoreBannerHUD(PlayerController P)
{
	local RespawnDelayBannerHUD BannerHUD;
	local HUD RestoredHUD;

	if ( P == None || P.bDeleteMe )
		return;

	BannerHUD = RespawnDelayBannerHUD(P.myHUD);
	if ( BannerHUD == None )
		return;						// banner not installed (or already restored)

	if ( BannerHUD.OriginalHUDClass == None )
		return;						// nothing to restore to; leave it alone

	RestoredHUD = P.Spawn(BannerHUD.OriginalHUDClass, P);
	if ( RestoredHUD != None )
	{
		P.myHUD = RestoredHUD;
		if ( BannerHUD.OriginalScoreBoardClass != None )
			RestoredHUD.SetScoreBoardClass(BannerHUD.OriginalScoreBoardClass);
		BannerHUD.Destroy();
		log("RespawnDelay: restored original HUD for " $ P, 'RespawnDelay');
	}
	else
	{
		log("RespawnDelay: failed to restore original HUD for " $ P, 'RespawnDelay');
	}
}

/**
 * Attach the beacon interaction to the local InteractionMaster.  Reuses an
 * existing one so repeated pulses never stack duplicate nameplates.
 */
static function InstallBeaconInteraction(PlayerController P)
{
	local RespawnDelayBeaconInteraction Beacon;
	local int i;

	if ( P == None || P.bDeleteMe || P.Player == None
		|| P.Player.InteractionMaster == None )
		return;

	for ( i = 0; i < P.Player.LocalInteractions.Length; i++ )
	{
		Beacon = RespawnDelayBeaconInteraction(P.Player.LocalInteractions[i]);
		if ( Beacon != None )
		{
			Beacon.PC = P;
			Beacon.bVisible = True;
			Beacon.bActive = True;
			return;
		}
	}

	Beacon = RespawnDelayBeaconInteraction(
		P.Player.InteractionMaster.AddInteraction(
			"RespawnDelay.RespawnDelayBeaconInteraction", P.Player));

	if ( Beacon != None )
	{
		Beacon.PC = P;
		Beacon.bVisible = True;
		Beacon.bActive = True;
		log("RespawnDelay: attached beacon interaction for " $ P, 'RespawnDelay');
	}
	else
	{
		log("RespawnDelay: failed to attach beacon interaction for " $ P, 'RespawnDelay');
	}
}

/** Remove every beacon interaction we own from this client. */
static function DetachBeaconInteraction(PlayerController P)
{
	local RespawnDelayBeaconInteraction Beacon;
	local int i;

	if ( P == None || P.bDeleteMe || P.Player == None )
		return;

	for ( i = P.Player.LocalInteractions.Length - 1; i >= 0; i-- )
	{
		Beacon = RespawnDelayBeaconInteraction(P.Player.LocalInteractions[i]);
		if ( Beacon != None )
		{
			Beacon.Cleanup();
			log("RespawnDelay: detached beacon interaction for " $ P, 'RespawnDelay');
		}
	}
}

defaultproperties
{
	bIsSpecial=False
	bIsUnique=False
	bIsConsoleMessage=False
	bFadeMessage=False
	bBeep=False
	Lifetime=0.0
}
