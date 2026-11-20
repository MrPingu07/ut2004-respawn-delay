//=============================================================================
// RespawnDelayBeaconInteraction
//
// Lightweight client-side interaction attached to spectators (waiting players)
// to render friendly player beacons with team colors (white in non-team modes).
//
// The spectator sees beacons for:
// - Team games: living teammates only
// - Solo/non-team games: all living players (white beacons)
// Format: Name / HP [X] / Shield [X] - team-colored, centered.
// No line-of-sight check: spectators see through walls like the Director.
//=============================================================================
class RespawnDelayBeaconInteraction extends Interaction;

var transient PlayerController PC;

function Cleanup()
{
    bVisible = False;
    bActive = False;

    if (Master != None)
        Master.RemoveInteraction(Self);

    PC = None;
}

function Tick(float DeltaTime)
{
    if (PC == None || PC.bDeleteMe)
    {
        Cleanup();
        return;
    }
    // Auto-cleanup when player respawns (leaves spectating)
    if (PC.Pawn != None)
    {
        Cleanup();
        return;
    }
}

event PostRender(Canvas C)
{
    local PlayerReplicationInfo PRI;
    local Controller Ctr;
    local Pawn P;
    local vector CamLoc, Head, Screen;
    local Rotator CamRot;
    local float XL, YL, LineH;
    local color TeamColor;
    local string BeaconText;
    local string DisplayName;
    local int TeamNum;
    local bool bTeamGame;
    local bool bIsSpectator;
    local int i;
    local int PRICount;
    local GameReplicationInfo GRI;

    Super.PostRender(C);

    if (PC == None || PC.bDeleteMe || PC.Pawn != None)
    {
        Cleanup();
        return;
    }

    // Don't draw for pure spectators (not waiting to respawn)
    bIsSpectator = (PC.PlayerReplicationInfo != None && PC.PlayerReplicationInfo.bOnlySpectator);
    if (bIsSpectator)
        return;

    // No state guard here: the interaction is only attached while this player
    // is waiting out a RespawnDelay respawn, and it detaches on respawn.  That
    // covers the death-camera hold-off too, which matters when the wait is as
    // short as the spectate delay (e.g. the Arena 3 s preset).

    bTeamGame = (PC.Level != None && PC.Level.Game != None && PC.Level.Game.bTeamGame);

    C.FontScaleX = 1.0;
    C.FontScaleY = 1.0;
    if (C.SmallFont != None)
        C.Font = C.SmallFont;
    C.StrLen("Mg", XL, YL);
    if (YL < 10.0)
        YL = 12.0;
    LineH = YL + 2.0;

    C.GetCameraLocation(CamLoc, CamRot);

    // Get GameReplicationInfo for replicated PRI array
    GRI = PC.GameReplicationInfo;
    if (GRI == None)
        return;

    PRICount = GRI.PRIArray.Length;

    // Iterate through replicated PRI array to find living teammates/all players
    for (i = 0; i < PRICount; i++)
    {
        PRI = GRI.PRIArray[i];
        if (PRI == None || PRI.bOnlySpectator)
            continue;
        Ctr = Controller(PRI.Owner);
        if (Ctr == None || Ctr.Pawn == None || Ctr.Pawn.Health <= 0)
            continue;

        // Team filter: in team games, only show teammates
        if (bTeamGame)
        {
            if (PRI.Team == None ||
                PC.PlayerReplicationInfo == None ||
                PC.PlayerReplicationInfo.Team == None ||
                PRI.Team.TeamIndex != PC.PlayerReplicationInfo.Team.TeamIndex)
                continue;
        }

        P = Ctr.Pawn;
        Head = P.Location + vect(0, 0, 60);

        // Skip anything behind the camera.
        if ((Head - CamLoc) Dot vector(CamRot) <= 0.0)
            continue;

        Screen = C.WorldToScreen(Head);
        if (Screen.X < 0.0 || Screen.X > C.ClipX ||
            Screen.Y < 0.0 || Screen.Y > C.ClipY)
            continue;

        // Determine display name
        if (P.PlayerReplicationInfo != None)
            DisplayName = P.PlayerReplicationInfo.PlayerName;
        else if (P.Controller != None && P.Controller.PlayerReplicationInfo != None)
            DisplayName = P.Controller.PlayerReplicationInfo.PlayerName;
        else
            DisplayName = string(P.Name);

        // Team colours
        if (bTeamGame)
        {
            TeamNum = P.GetTeamNum();
            if (TeamNum == 0)
            {
                // Red team
                TeamColor.R = 255; TeamColor.G = 0;   TeamColor.B = 0;   TeamColor.A = 255;
            }
            else
            {
                // Blue team
                TeamColor.R = 51;  TeamColor.G = 102; TeamColor.B = 255; TeamColor.A = 255;
            }
        }
        else
        {
            // Non-team mode: white
            TeamColor.R = 255; TeamColor.G = 255; TeamColor.B = 255; TeamColor.A = 255;
        }

        // Format: 3 lines: Name / HP [X] / Shield [X]
        // Name
        BeaconText = DisplayName;
        C.StrLen(BeaconText, XL, YL);
        if (Screen.X - XL * 0.5 >= 0.0 && Screen.X + XL * 0.5 <= C.ClipX)
        {
            C.DrawColor = TeamColor;
            C.SetPos(Screen.X - XL * 0.5, Screen.Y - 3.0 * LineH);
            C.DrawText(BeaconText);
        }

        // HP
        BeaconText = "HP [" $ P.Health $ "]";
        C.StrLen(BeaconText, XL, YL);
        if (Screen.X - XL * 0.5 >= 0.0 && Screen.X + XL * 0.5 <= C.ClipX)
        {
            C.DrawColor = TeamColor;
            C.SetPos(Screen.X - XL * 0.5, Screen.Y - 2.0 * LineH);
            C.DrawText(BeaconText);
        }

        // Shield
        BeaconText = "Shield [" $ int(P.ShieldStrength) $ "]";
        C.StrLen(BeaconText, XL, YL);
        if (Screen.X - XL * 0.5 >= 0.0 && Screen.X + XL * 0.5 <= C.ClipX)
        {
            C.DrawColor = TeamColor;
            C.SetPos(Screen.X - XL * 0.5, Screen.Y - LineH);
            C.DrawText(BeaconText);
        }
    }
}

defaultproperties
{
    bVisible=True
    bActive=True
    bRequiresTick=True
}