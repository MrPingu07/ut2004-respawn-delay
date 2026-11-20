//=============================================================================
// RespawnDelayBannerHUD
//
// Purpose-built HUD for players waiting to respawn in RespawnDelay.
// Replaces the stock HUD while the player is in the spectator wait state
// so we can draw a custom banner at the bottom with:
// - Typewriter-animated broadcast messages (server-authored by
//   RespawnDelayBroadcast, local RespawnDelayFeed only as a fallback)
// - Team-colored stripes (white in non-team modes)
// - Unreal "U" logo at left
// - Team score counter at top center (team games only)
// The existing RespawnDelayCountdown (center screen) continues to work separately.
//=============================================================================
class RespawnDelayBannerHUD extends XInterface.HudBase;

const FLICKER_STEP = 0.1666667;
const BLINK_INTERVAL = 0.5;
/**
 * Full broadcast cycle matching the Director booth feed (TeamDirector).
 * 9 phases over 22 seconds:
 *   0: flicker     0.0 - 1.0   cursor flicker (3 blinks, ends OFF)
 *   1: blink       1.0 - 2.0   cursor blink (starts ON)
 *   2: type        2.0 - 3.0   typewriter: text appears over ~1 s
 *   3: blink       3.0 - 6.0   cursor blink during hold
 *   4: hold        6.0 - 11.0  full text held; cursor OFF
 *   5: flicker     11.0 - 12.0 cursor flicker before delete
 *   6: blink       12.0 - 13.0 cursor blink before delete
 *   7: delete      13.0 - 14.0 text deleted character by character
 *   8: blink       14.0 - 17.0 cursor blink after delete
 *   9: rest        17.0 - 22.0 empty; wait for next cycle
 */
const TOTAL_CYCLE = 22.0;

/**
 * Server-authored broadcast state.  When present, CurrentMessage and the
 * typewriter phase come from this actor, so every waiting player sees the same
 * text at the same point in the animation.  The local fields below are only a
 * fallback for the first tick before the actor replicates.
 */
var transient RespawnDelayBroadcast Broadcast;

var transient float CycleStart;
var transient float LastDrawTime;
var transient string CurrentMessage;
var transient array<int> FeedBag;
/** Number of messages the current bag was built from; reset when it changes. */
var transient int FeedBagSize;

/**
 * Stock HUD class that was replaced by this banner.  Saved on the client by
 * RespawnDelayHUDMessage when the swap happens, so the same message can
 * restore it when the wait is over.  The server never sees these.
 */
var transient class<HUD> OriginalHUDClass;
var transient class<Scoreboard> OriginalScoreBoardClass;

/**
 * Override the native vehicle name drawing.  This is called from native C++
 * code during the spectator overlay pass and draws the vehicle's class name
 * above every vehicle.  By overriding it to do nothing, we eliminate the
 * forced vehicle names entirely for waiting players.
 */
simulated function DrawVehicleName(Canvas C)
{
    // Intentionally empty: suppress all native vehicle name rendering.
}

/**
 * Override the native team beacon drawing.  This is called from
 * Pawn.PostRender2D() for every pawn with bScriptPostRender=true
 * (including vehicles/sentinels).  The engine calls:
 *   PC.myHUD.DrawCustomBeacon(Canvas, Pawn, ScreenX, ScreenY)
 * which draws the beacon texture + name/health text.  We override it to
 * do nothing so waiting players see only our custom beacons drawn by
 * RespawnDelayBeaconInteraction.PostRender.
 */
simulated function DrawCustomBeacon(Canvas C, Pawn P, float ScreenLocX, float ScreenLocY)
{
    // Intentionally empty: suppress ALL native team beacon rendering.
}

/**
 * Draw the regular HUD, then the banner on top.  This is the path used while
 * the player is still in the death camera (state Dead, not yet Spectating), so
 * the banner is visible for the whole wait and not only once spectating starts.
 */
simulated function DrawHud(Canvas C)
{
    Super.DrawHud(C);       // also calls DisplayLocalMessages()
    DrawBanner(C);
}

/**
 * Override the crosshair drawing.  Waiting players have no crosshair.
 */
simulated function DrawCrosshair(Canvas C)
{
    // Intentionally empty.
}

// NOTE: do not override DrawMessage() here.  DisplayLocalMessages() renders
// every bIsSpecial LocalMessage through it, including RespawnDelayCountdown
// (the big centre-screen number).  An empty override would silently eat the
// countdown once this HUD replaced the stock one.

/**
 * Returns the current phase (0-9) and its start time for a given cycle time T.
 * Phases: 0=flicker(0-1), 1=blink(1-2), 2=type(2-3), 3=blink(3-6), 4=hold(6-11),
 *         5=flicker(11-12), 6=blink(12-13), 7=delete(13-14), 8=blink(14-17), 9=rest(17-22).
 */
simulated function GetPhaseInfo(float T, out int Phase, out float PhaseStart)
{
    if (T < 1.0)       { Phase = 0; PhaseStart = 0.0;  }
    else if (T < 2.0)  { Phase = 1; PhaseStart = 1.0;  }
    else if (T < 3.0)  { Phase = 2; PhaseStart = 2.0;  }
    else if (T < 6.0)  { Phase = 3; PhaseStart = 3.0;  }
    else if (T < 11.0) { Phase = 4; PhaseStart = 6.0;  }
    else if (T < 12.0) { Phase = 5; PhaseStart = 11.0; }
    else if (T < 13.0) { Phase = 6; PhaseStart = 12.0; }
    else if (T < 14.0) { Phase = 7; PhaseStart = 13.0; }
    else if (T < 17.0) { Phase = 8; PhaseStart = 14.0; }
    else               { Phase = 9; PhaseStart = 17.0; }
}

/**
 * Returns whether the cursor should be visible at the given phase time.
 * FLICKER phases (0,5): 3 blinks in 1s ending OFF (step 1/6s, starts ON).
 * BLINK phases (1,3,6,8): toggles every 0.5s, starts ON.
 * TYPE/DELETE phases (2,7): always ON.
 * HOLD/REST phases (4,9): always OFF.
 */
simulated function bool GetCursorVisible(float PhaseTime, int Phase)
{
    if (Phase == 0 || Phase == 5)
        return (int(PhaseTime / FLICKER_STEP) % 2) == 0;
    if (Phase == 1 || Phase == 3 || Phase == 6 || Phase == 8)
        return (int(PhaseTime / BLINK_INTERVAL) % 2) == 0;
    if (Phase == 2 || Phase == 7)
        return true;
    return false;
}

/**
 * Stock spectator path (state Spectating).  The stock HudCDeathmatch banner
 * ("Now viewing...") is replaced entirely by DrawBanner.  Local messages
 * (chat + the RespawnDelayCountdown) are drawn here because this path does not
 * call Super.DrawHud.
 */
simulated function DrawSpectatingHud(Canvas C)
{
    DisplayLocalMessages(C);
    DrawBanner(C);
}

/**
 * Locate the server broadcast actor.  It is spawned with bAlwaysRelevant, so
 * every client has a copy.  Cached because AllActors every frame is wasteful.
 */
simulated function RespawnDelayBroadcast FindBroadcast()
{
    local RespawnDelayBroadcast B;

    if (Broadcast != None && !Broadcast.bDeleteMe)
        return Broadcast;

    foreach AllActors(class'RespawnDelayBroadcast', B)
    {
        Broadcast = B;
        break;
    }

    return Broadcast;
}

/**
 * Feed the typewriter from the shared broadcast so the text and its animation
 * phase are identical on every machine.  Returns false when the actor has not
 * replicated to this client yet (the caller then uses the local fallback).
 */
simulated function bool GetBroadcastState(out float CycleElapsed)
{
    local RespawnDelayBroadcast B;

    B = FindBroadcast();
    if (B == None || B.CurrentText == "")
        return false;

    CurrentMessage = B.CurrentText;
    CycleElapsed = B.GetCycleElapsed();
    return true;
}

/**
 * The banner itself, shared by the spectator path and the death-camera path
 * (DrawHud).  Draws:
 * - Unreal "U" logo at left margin
 * - Dark transparent horizontal band spanning screen width
 * - Team-colored stripes at top and bottom edges (white in non-team modes)
 * - Typewriter message in the middle
 */
simulated function DrawBanner(Canvas C)
{
    local float BannerHeight;
    local float BannerY;
    local float BannerX;
    local float BannerWidth;
    local float StripeWidth;
    local float LogoSize;
    local float LogoX;
    local float LogoY;
    local color TeamColor;
    local color StripeColor;
    local float TextYPos;
    local int TeamNum;
    local bool bTeamGame;
    local Pawn TargetPawn;
    local PlayerReplicationInfo TargetPRI;

    // Typewriter + cursor locals
    local float CycleElapsed, PhaseStart, PhaseTime;
    local int Phase, L, Shown, Start;
    local float FullWidth, AnchorX, SliceX, CursorX, PH, Dummy;
    local bool CursorVisible;
    local byte OldStyle;

    // Team score counter locals
    local GameReplicationInfo GRI;
    local string RedScore, BlueScore;
    local float RedW, BlueW, DashW, TScoreY, TTotalW, TStartX;
    local HUD MyHUD;
    local float TimeW, TimeY;
    local int Minutes, Seconds;
    local string TimeStr;

    // Resolution-independent scaling (1024x768 as reference = scale 1.0)
    local float Scale;
    
    Scale = C.ClipY / 768.0;
    
    // Don't draw our custom banner if no valid player owner
    if (PlayerOwner == None)
        return;
    
    // Obtain GameReplicationInfo early so team detection can fall back to it
    GRI = PlayerOwner.GameReplicationInfo;
    if (GRI == None && Level != None)
        GRI = Level.GRI;

    // Determine if we're in a team game
    bTeamGame = ((PlayerOwner.Level != None && PlayerOwner.Level.Game != None && PlayerOwner.Level.Game.bTeamGame)
        || (GRI != None && GRI.bTeamGame));
    
    // Try to get target info for team color (who we're spectating)
    TargetPawn = Pawn(PlayerOwner.ViewTarget);
    if (TargetPawn != None)
        TargetPRI = TargetPawn.PlayerReplicationInfo;
    else
        TargetPRI = None;
    
    // Determine team: use live target, or fall back to player's own team
    if (TargetPRI != None && TargetPawn != None && TargetPawn.Health > 0)
    {
        TeamNum = TargetPawn.GetTeamNum();
    }
    else if (PlayerOwner.PlayerReplicationInfo != None && PlayerOwner.PlayerReplicationInfo.Team != None)
    {
        TeamNum = PlayerOwner.PlayerReplicationInfo.Team.TeamIndex;
    }
    else
    {
        TeamNum = 0; // Default to red
    }
    
    // Team color for stripes and text
    // In non-team games, use white
    if (bTeamGame)
    {
        if (TeamNum == 0)
        {
            // Red team
            StripeColor.R = 255; StripeColor.G = 0;   StripeColor.B = 0;   StripeColor.A = 255;
            TeamColor.R = 255; TeamColor.G = 100; TeamColor.B = 100; TeamColor.A = 255;
        }
        else
        {
            // Blue team
            StripeColor.R = 51;  StripeColor.G = 102; StripeColor.B = 255; StripeColor.A = 255;
            TeamColor.R = 100; TeamColor.G = 150; TeamColor.B = 255; TeamColor.A = 255;
        }
    }
    else
    {
        // Non-team mode: white
        StripeColor.R = 255; StripeColor.G = 255; StripeColor.B = 255; StripeColor.A = 255;
        TeamColor.R = 255; TeamColor.G = 255; TeamColor.B = 255; TeamColor.A = 255;
    }
    
    // Banner dimensions (8% of screen height, scaled)
    BannerHeight = 80.0 * Scale;
    BannerY = C.ClipY - BannerHeight;
    BannerX = 0.0;
    BannerWidth = C.ClipX;
    
    // Dark transparent band (80% opacity black)
    C.Style = ERenderStyle.STY_Alpha;
    C.SetDrawColor(0, 0, 0, 204);
    C.SetPos(0, BannerY);
    C.DrawTileStretched(material'InterfaceContent.SquareBoxA', C.ClipX, BannerHeight);
    C.Style = ERenderStyle.STY_Normal;
    
    // Team-colored stripes at top and bottom of banner (3px scaled)
    StripeWidth = 3.0 * Scale;
    C.SetDrawColor(StripeColor.R, StripeColor.G, StripeColor.B, 255);
    C.SetPos(0, BannerY);
    C.DrawTileStretched(material'InterfaceContent.SquareBoxA', C.ClipX, StripeWidth);
    C.SetPos(0, BannerY + BannerHeight - StripeWidth);
    C.DrawTileStretched(material'InterfaceContent.SquareBoxA', C.ClipX, StripeWidth);
    
    // Stock spectator HUD logo (LastManStanding.LMSLogoSmall) at left, scaled to banner
    // Matches HudBDeathMatch/HudCDeathmatch: logo height = BannerHeight + 16*Scale, drawn 8*Scale above banner top
    LogoSize = BannerHeight + 16.0 * Scale;
    LogoX = 0.0;
    LogoY = BannerY - 8.0 * Scale;
    
    C.Style = ERenderStyle.STY_Alpha;
    C.SetDrawColor(255, 255, 255, 255);
    C.SetPos(LogoX, LogoY);
    C.DrawTile(
        material'LastManStanding.LMSLogoSmall',
        LogoSize * 2.0,  // width = 2 * height (256/128 aspect)
        LogoSize,
        0, 0,
        256, 128
    );
    C.Style = ERenderStyle.STY_Normal;
    
    // Team score counter + match time at top center - same font and scale as clock
    if (bTeamGame && PlayerOwner != None && GRI != None && GRI.Teams[0] != None && GRI.Teams[1] != None)
    {
        RedScore = string(int(GRI.Teams[0].Score));
        BlueScore = string(int(GRI.Teams[1].Score));

        C.FontScaleX = 1.0;
        C.FontScaleY = 1.0;
        C.StrLen("X", Dummy, PH);

        TimeY = 15.0 * Scale;

        // Match time remaining (mm:ss) in white at top center
        if (Level.Game != None && Level.Game.TimeLimit > 0)
        {
            Minutes = int((Level.Game.TimeLimit * 60.0 - Level.TimeSeconds) / 60.0);
            Seconds = int((Level.Game.TimeLimit * 60.0 - Level.TimeSeconds)) % 60;
            if (Minutes < 0) Minutes = 0;
            if (Seconds < 0) Seconds = 0;
            TimeStr = string(Minutes) $ ":" $ string(Seconds);
            if (Seconds < 10) TimeStr = string(Minutes) $ ":0" $ string(Seconds);

            C.StrLen(TimeStr, TimeW, Dummy);
            C.SetDrawColor(255, 255, 255, 255);
            C.SetPos((C.ClipX - TimeW) * 0.5, TimeY);
            C.DrawText(TimeStr);

            TScoreY = TimeY + PH + 4.0 * Scale;
        }
        else
        {
            TScoreY = TimeY;
        }

        // Centered score string: Red - Blue (same font & scale as clock)
        C.StrLen(RedScore, RedW, Dummy);
        C.StrLen(" - ", DashW, Dummy);
        C.StrLen(BlueScore, BlueW, Dummy);

        TTotalW = RedW + DashW + BlueW;
        TStartX = (C.ClipX - TTotalW) * 0.5;

        //Red Score
        C.SetDrawColor(255, 80, 80, 255);
        C.SetPos(TStartX, TScoreY);
        C.DrawText(RedScore);

        //Dash
        C.SetDrawColor(255, 255, 255, 255);
        C.SetPos(TStartX + RedW, TScoreY);
        C.DrawText(" - ");

        //Blue score
        C.SetDrawColor(100, 150, 255, 255);
        C.SetPos(TStartX + RedW + DashW, TScoreY);
        C.DrawText(BlueScore);
    }
    
    // Typewriter + blinking cursor banner (centered, no horizontal motion)
    
    // Center text vertically in banner
    C.Font = C.MedFont;
    C.StrLen("X", Dummy, PH);  // PH = line height for MedFont
    TextYPos = BannerY + (BannerHeight - PH) * 0.5;
    
    // Shared broadcast first (identical text + phase for every waiting
    // player); the local feed is only a fallback for the tick before the
    // broadcast actor has replicated to this client.
    if ( !GetBroadcastState(CycleElapsed) )
    {
        if (CurrentMessage == "" || Level.TimeSeconds < CycleStart
            || Level.TimeSeconds - CycleStart >= TOTAL_CYCLE
            || Level.TimeSeconds - LastDrawTime > 0.5)
        {
            CycleStart = Level.TimeSeconds;
            CurrentMessage = PickMessage();
        }
        CycleElapsed = FMax(0.0, Level.TimeSeconds - CycleStart);
    }
    LastDrawTime = Level.TimeSeconds;
    
    GetPhaseInfo(CycleElapsed, Phase, PhaseStart);
    PhaseTime = FMax(0.0, CycleElapsed - PhaseStart);
    CursorVisible = GetCursorVisible(PhaseTime, Phase);
    
    C.Font = C.MedFont;
    C.StrLen(CurrentMessage, FullWidth, PH);
    AnchorX = (C.ClipX - FullWidth) * 0.5;
    L = Len(CurrentMessage);
    
    if (Phase == 2)
        Shown = Min(L, int(PhaseTime * L));
    else if (Phase == 7)
        Shown = L - Min(L, int(PhaseTime * L));
    else if (Phase >= 3 && Phase <= 6)
        Shown = L;
    else
        Shown = 0;
    Start = (L - Shown) / 2;
    
    if (Shown > 0)
    {
        C.StrLen(Left(CurrentMessage, Start), SliceX, Dummy);
        SliceX += AnchorX;
        C.SetDrawColor(TeamColor.R, TeamColor.G, TeamColor.B, 255);
        C.SetPos(SliceX, TextYPos);
        C.DrawText(Mid(CurrentMessage, Start, Shown), false);
    }
    
    if (CursorVisible)
    {
        C.StrLen(Left(CurrentMessage, Start + Shown), CursorX, Dummy);
        CursorX += AnchorX;
        OldStyle = C.Style;
        C.Style = ERenderStyle.STY_Alpha;
        C.SetDrawColor(TeamColor.R, TeamColor.G, TeamColor.B, 255);
        C.SetPos(CursorX, TextYPos);
        C.DrawTileStretched(material'InterfaceContent.SquareBoxA', 8.0 * Scale, PH);
        C.Style = OldStyle;
    }
}

/**
 * LOCAL FALLBACK feed.  Normally the banner draws RespawnDelayBroadcast, which
 * is authored on the server and identical for every client.  This path is only
 * used for the frame(s) before that actor replicates (and in the editor), so it
 * intentionally mirrors the same rules.
 *
 * No message repeats until all have been shown. Empty entries are skipped.
 * Width is deliberately not filtered: token values vary in length, and the
 * game already validates the player/server names that feed them. The banner
 * is centred and clipped by the canvas instead.
 */
simulated function string PickMessage()
{
    local int i, j, tmp, Tries;
    local string Msg;
    local array<string> SourceMessages;
    local int SourceCount;
    local bool bTeamGame;
    local GameReplicationInfo GRI;

    // Team-only lines are meaningless in DM/LMS/etc.  The token expander still
    // blanks those tokens as a safety net, but skipping the whole line avoids
    // broadcasts like " ... DEFEND THE CORNER".
    bTeamGame = (PlayerOwner != None && PlayerOwner.Level != None
        && PlayerOwner.Level.Game != None && PlayerOwner.Level.Game.bTeamGame);

    GRI = None;
    if (PlayerOwner != None)
        GRI = PlayerOwner.GameReplicationInfo;

    // Get messages from config (RespawnDelayFeed)
    SourceCount = class'RespawnDelayFeed'.default.Messages.Length;
    if (SourceCount > 0)
    {
        SourceMessages = class'RespawnDelayFeed'.default.Messages;
    }
    else
    {
        SourceCount = 0;
    }

    if (SourceCount == 0)
        return "RESPAWN DELAY ACTIVE";

    // A changed source invalidates old indices.
    if (FeedBagSize != SourceCount)
    {
        FeedBag.Length = 0;
        FeedBagSize = SourceCount;
    }

    for (Tries = 0; Tries < SourceCount; Tries++)
    {
        if (FeedBag.Length == 0)
        {
            FeedBag.Length = SourceCount;
            for (i = 0; i < SourceCount; i++)
                FeedBag[i] = i;
            for (i = SourceCount - 1; i > 0; i--)
            {
                j = Rand(i + 1);
                tmp = FeedBag[i];
                FeedBag[i] = FeedBag[j];
                FeedBag[j] = tmp;
            }
        }

        i = FeedBag[FeedBag.Length - 1];
        FeedBag.Length = FeedBag.Length - 1;
        Msg = SourceMessages[i];
        if (Msg != "")
        {
            if (!bTeamGame && class'RespawnDelayFeed'.static.HasTeamOnlyTokens(Msg))
                continue;
            return class'RespawnDelayFeed'.static.ExpandTokens(Msg, GRI, bTeamGame, Level);
        }
    }

    return "RESPAWN DELAY ACTIVE";
}

defaultproperties
{
    // Match HudBDeathMatch so console chat (DisplayMessages) sits above the banner
    ConsoleMessagePosX=0.005000
    // Align chat bottom (last message) with banner area
    ConsoleMessagePosY=0.910000
}
