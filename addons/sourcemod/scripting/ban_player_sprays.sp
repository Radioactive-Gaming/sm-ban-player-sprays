/* Ban Player Sprays
 *
 * 	DESCRIPTION
 * 		Allow you to permanently remove a player's ability to use the in-game spray function
 *
 * 	VERSIONS and ChangeLog
 *       * See CHANGELOG.md
 *
 * 	CREDITS
 * 		Credit for some of the code goes to the author(s) of SprayTracer (https://forums.alliedmods.net/showthread.php?t=75480)
 */

#pragma semicolon 1
#pragma newdecls required

#include <adminmenu>
#include <clientprefs>
#include <multicolors>
#include <regex>
#include <sdktools>
#include <sourcemod>

#define STEAMID64_LENGTH   18

#define PLUGIN_NAME        "Banned Sprays"
#define PLUGIN_AUTHOR      "TnTSCS aka ClarkKent, X8ETr1x, burlindw"
#define PLUGIN_URL         "https://github.com/Radioactive-Gaming/sm-ban-player-sprays"
#define PLUGIN_DESCRIPTION "Delete sprays and ban players from using sprays"
#define PLUGIN_VERSION     "0.5.3"

public Plugin myinfo = {
    name        = PLUGIN_NAME,
    description = PLUGIN_DESCRIPTION,
    author      = PLUGIN_AUTHOR,
    version     = PLUGIN_VERSION,
    url         = PLUGIN_URL,
}

bool   AllowSpraysBeforeAuthentication;
bool   CanViewSprayInfo[MAXPLAYERS + 1];
bool   Debug;
bool   lateLoad;
bool   PlayerCachedCookie[MAXPLAYERS + 1] = {false, ...};
bool   PlayerCanSpray[MAXPLAYERS + 1]     = {false, ...};
bool   RemoveSprayOnBan;
bool   TraceSprays;
char   g_BanSprayTarget[MAXPLAYERS + 1];
char   SprayerID[MAXPLAYERS + 1][32];
char   SprayerName[MAXPLAYERS + 1][MAX_NAME_LENGTH];
char   TmpLoc[30];
int    DisplayType;
int    SprayProtection;
int    WarnType;
float  SprayLocation[MAXPLAYERS + 1][3];
float  SprayTime[MAXPLAYERS + 1];
float  TraceDistance;
float  TraceRate;
float  vecTempLoc[3];
float  vectorPos[3];
Handle g_cookie;
Handle g_adminMenu = INVALID_HANDLE;
Handle g_TraceTimer;

/**
 * Called when the plugin is fully initialized and all known external references
 * are resolved. This is only called once in the lifetime of the plugin, and is
 * paired with OnPluginEnd().
 *
 * If any run-time error is thrown during this callback, the plugin will be
 * marked as failed.
 **/
public void OnPluginStart()
{
    Handle hRandom;

    hRandom = CreateConVar("sm_bannedsprays_version", PLUGIN_VERSION, "The version of Banned Sprays", FCVAR_PLUGIN | FCVAR_SPONLY | FCVAR_REPLICATED | FCVAR_NOTIFY | FCVAR_DONTRECORD);
    HookConVarChange(hRandom, OnVersionChanged);

    hRandom          = CreateConVar("sm_bannedsprays_remove", "1", "Remove the player's spray after they are banned from using sprays?\n0 = Leave Spray\n1 = Remove Spray");
    RemoveSprayOnBan = GetConVarBool(hRandom);
    HookConVarChange(hRandom, OnRemoveSprayChanged);

    hRandom                         = CreateConVar("sm_bannedsprays_auth", "0", "If player's SteamID hasn't been authenticated yet, restrict sprays?\n0 = No, allow\n1 = Yes Do Not Allow");
    AllowSpraysBeforeAuthentication = GetConVarBool(hRandom);
    HookConVarChange(hRandom, OnAuthenticationChanged);

    hRandom = CreateConVar("sm_bannedsprays_tmploc", "0.00 0.00 0.00", "Location for sprays to be moved to.\nMust have 2+ decimal places to be valid");
    GetConVarString(hRandom, TmpLoc, sizeof(TmpLoc));
    StringToVector(TmpLoc, vecTempLoc);
    HookConVarChange(hRandom, OnTempLocChanged);

    hRandom = CreateConVar("sm_bannedsprays_debug", "0", "Enable some debug logging?\n0 = No\n1 = Yes");
    Debug   = GetConVarBool(hRandom);
    HookConVarChange(hRandom, OnDebugChanged);

    hRandom     = CreateConVar("sm_bannedsprays_trace", "1", "Trace all player sprays to display info when aimed at?\n0 = No\n1 = Yes");
    TraceSprays = GetConVarBool(hRandom);
    HookConVarChange(hRandom, OnTraceChanged);

    hRandom   = CreateConVar("sm_bannedsprays_tracerate", "3.0", "Rate at which to check all player sprays (in seconds)", _, true, 1.0);
    TraceRate = GetConVarFloat(hRandom);
    HookConVarChange(hRandom, OnTraceRateChanged);

    hRandom       = CreateConVar("sm_bannedsprays_tracedist", "25.0", "How far away the spray is from the aim to be traced", _, true, 1.0, true, 250.0);
    TraceDistance = GetConVarFloat(hRandom);
    HookConVarChange(hRandom, OnTraceDistChanged);

    hRandom     = CreateConVar("sm_bannedsprays_display", "4", "Display Options (add them up and put total in CVar)\n1 = CenterText\n2 = HintText\n4 = HudHintText", _, true, 1.0, true, 7.0);
    DisplayType = GetConVarInt(hRandom);
    HookConVarChange(hRandom, OnDisplayChanged);

    hRandom         = CreateConVar("sm_bannedsprays_protection", "0", "Distance, in hammer units, to not allow another user to spray next to a user's current spray\n0 = DISABLED\n>0 = Distance to protect sprays", _, true, 0.0, true, 1000.0);
    SprayProtection = GetConVarInt(hRandom);
    HookConVarChange(hRandom, OnProtectionChanged);

    hRandom  = CreateConVar("sm_bannedsprays_warntype", "2", "Display Options (add them up and put total in CVar) for warning players when they try to spray over another player's spray\n1 = CenterText\n2 = HintText\n4 = HudHintText", _, true, 1.0, true, 7.0);
    WarnType = GetConVarInt(hRandom);
    HookConVarChange(hRandom, OnWarnTypeChanged);

    AddTempEntHook("Player Decal", PlayerSpray);

    SetCookieMenuItem(Menu_Status, 0, "Display Banned Spray Status");

    g_cookie = RegClientCookie("banned-spray", "Banned spray status", CookieAccess_Protected);

    LoadTranslations("common.phrases");
    LoadTranslations("ban_player_sprays.phrases");

    RegAdminCmd("sm_banspray", Command_BanSpray, ADMFLAG_BAN, "Permanently remove a players ability to use spray");
    RegAdminCmd("sm_unbanspray", Command_UnBanSpray, ADMFLAG_BAN, "Permanently remove a players ability to use spray");
    RegAdminCmd("sm_deletespray", Command_DeleteSpray, ADMFLAG_BAN, "Remove a player's spray by either looking at it or providing a player's name");
    RegAdminCmd("sm_banspray_list", Command_BanSprayList, ADMFLAG_GENERIC, "List of player's currently connected who are banned from using sprays");

    RegAdminCmd("sm_banspray_steamid", Command_BanSpraySteamID, ADMFLAG_BAN, "Manually add a SteamID to the list of players who are banned from using sprays");

    hRandom = INVALID_HANDLE;

    if (LibraryExists("adminmenu") && ((hRandom = GetAdminTopMenu()) != INVALID_HANDLE))
    {
        OnAdminMenuReady(hRandom);
    }

    AutoExecConfig(true, "plugin.ban_player_sprays");

    if (lateLoad)
    {
        for (int i = 1; i <= MaxClients; i++)
        {
            if (IsClientInGame(i))
            {
                OnClientPostAdminCheck(i);
            }
        }
    }
}

/**
 * Called before OnPluginStart, in case the plugin wants to check for load failure.
 * This is called even if the plugin type is "private."  Any natives from modules are
 * not available at this point.  Thus, this forward should only be used for explicit
 * pre-emptive things, such as adding dynamic natives, setting certain types of load
 * filters (such as not loading the plugin for certain games).
 *
 * @note It is not safe to call externally resolved natives until OnPluginStart().
 * @note Any sort of RTE in this function will cause the plugin to fail loading.
 * @note If you do not return anything, it is treated like returning success.
 * @note If a plugin has an AskPluginLoad2(), AskPluginLoad() will not be called.
 *
 *
 * @param myself	Handle to the plugin.
 * @param late		Whether or not the plugin was loaded "late" (after map load).
 * @param error		Error message buffer in case load failed.
 * @param err_max	Maximum number of characters for error message buffer.
 * @return		APLRes_Success for load success, APLRes_Failure or APLRes_SilentFailure otherwise
 */
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    lateLoad = late;
    return APLRes_Success;
}

/**
 * Called after a library is added that the current plugin references
 * optionally. A library is either a plugin name or extension name, as
 * exposed via its include file.
 *
 * @param name			Library name.
 */

/**
 * Called right before a library is removed that the current plugin references
 * optionally.  A library is either a plugin name or extension name, as
 * exposed via its include file.
 *
 * @param name			Library name.
 */
public void OnLibraryRemoved(const char[] name)
{
    if (StrEqual(name, "adminmenu"))
    {
        g_adminMenu = INVALID_HANDLE;
    }
}

/**
 * Called when your plugin's update has been completed. It is safe
 * to reload your plugin at this time.
 *
 * @noreturn
 */

/**
 * Called when the map has loaded, servercfgfile (server.cfg) has been
 * executed, and all plugin configs are done executing.  This is the best
 * place to initialize plugin functions which are based on cvar data.
 *
 * @note This will always be called once and only once per map.  It will be
 * called after OnMapStart().
 *
 * @noreturn
 */

/**
 * Called once a client is authorized and fully in-game, and
 * after all post-connection authorizations have been performed.
 *
 * This callback is gauranteed to occur on all clients, and always
 * after each OnClientPutInServer() call.
 *
 * @param client		Client index.
 * @noreturn
 */
public void OnClientPostAdminCheck(int client)
{
    if (!IsFakeClient(client))
    {
        ResetVariables(client);

        if (AreClientCookiesCached(client))
        {
            ProcessCookies(client);
        }
        else
        {
            CreateTimer(2.0, Timer_Cookies, GetClientSerial(client), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
        }

        CanViewSprayInfo[client] = CheckCommandAccess(client, "AllowSprayTrace", ADMFLAG_GENERIC);
    }
}

/**
 * Called when a client is disconnecting from the server.
 *
 * @param client		Client index.
 * @noreturn
 */
public void OnClientDisconnect(int client)
{
    if (IsClientConnected(client) && !IsFakeClient(client))
    {
        ResetVariables(client);
    }
}

/**
 * Called when the map is loaded.
 *
 * @note This used to be OnServerLoad(), which is now deprecated.
 * Plugins still using the old forward will work.
 */
public void OnMapStart()
{
    if (TraceSprays)
    {
        ClearTimer(g_TraceTimer);

        g_TraceTimer = CreateTimer(TraceRate, TraceAllSprays, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    }
}

/**
 * Called right before a map ends.
 */
public void OnMapEnd()
{
    ResetVariables(0);

    ClearTimer(g_TraceTimer);
}

/**
 * Timer callback for handling cookies
 * @param	timer	Handle to the timer
 * @param serial	Client serial passed through the timer
 * @noreturn
 */
public Action Timer_Cookies(Handle timer, int serial)
{
    int client = GetClientFromSerial(serial);

    if (client == 0)
    {
        return Plugin_Stop;
    }

    if (AreClientCookiesCached(client))
    {
        ProcessCookies(client);
        return Plugin_Stop;
    }

    return Plugin_Continue;
}

/**
 * Process client cookies
 * @param	client	ClientID of player
 * @noreturn
 */

public void ProcessCookies(int client)
{
    PlayerCachedCookie[client] = true;
    PlayerCanSpray[client]     = true;

    if (PlayerSprayIsBanned(client))
    {
        LogMessage("%t", "Ban Added", client);

        PerformSprayBan(0, client);
    }
}

/**
 * Function to handle all spray bans
 * @param	admin	ClientID of admin cuasing the banning of the player's spray (0 for console)
 * @param	client	ClientID of player having their sprays banned
 * @noreturn
 */
public void PerformSprayBan(int admin, int client)
{
    if (RemoveSprayOnBan)
    {
        SprayDecal(client, 0, vecTempLoc);
    }

    PlayerCanSpray[client] = false;
    SetClientCookie(client, g_cookie, "1");

    ShowActivity2(admin, "[Banned Sprays] ", "%t", "Banned Spray", client);
    LogAction(admin, client, "%N banned the sprays for %L", admin, client);
}

/**
 * Function to handle all spray unbans
 * @param	admin	ClientID of admin cuasing the unbanning of the player's spray (0 for console)
 * @param	client	ClientID of player having their sprays unbanned
 * @noreturn
 */
public void PerformSprayUnBan(int admin, int client)
{
    PlayerCanSpray[client] = true;

    SetClientCookie(client, g_cookie, "0");

    ShowActivity2(admin, "[Banned Sprays] ", "%t", "Unbanned Spray", client);
    LogAction(admin, client, "%N unbanned the sprays for %L", admin, client);
}

/**
 * Check if a player's spray ability is banned or not
 * @param	client	ClientID of player to check
 * @return True if player's ability to use sprays is banned, false otherwise
 */
bool PlayerSprayIsBanned(int client)
{
    char cookie[2];

    GetClientCookie(client, g_cookie, cookie, sizeof(cookie));

    if (StrEqual(cookie, "1", false))
    {
        return true;
    }

    return false;
}

public Action PlayerSpray(const char[] te_name, const int[] Players, int numClients, float delay)
{
    int client = TE_ReadNum("m_nPlayer");

    if (IsClientInGame(client))
    {
        if (Debug)
        {
            LogMessage("%N is attempting to spray...", client);
        }

        TE_ReadVector("m_vecOrigin", SprayLocation[client]);

        if (SprayProtection > 0)
        {
            for (int i = 1; i <= MaxClients; i++)
            {
                if (i == client || !IsClientInGame(i))
                {
                    continue;
                }

                if (Debug)
                {
                    PrintToChatAll("Spray Location for %N: %f %f %f", client, SprayLocation[client][0], SprayLocation[client][1], SprayLocation[client][2]);
                    PrintToChatAll("Spray Location for %N: %f %f %f", i, SprayLocation[i][0], SprayLocation[i][1], SprayLocation[i][2]);
                }

                bool cantspray = false;

                if (SprayLocation[client][0] == SprayLocation[i][0] ||
                    SprayLocation[client][1] == SprayLocation[i][1] ||
                    SprayLocation[client][2] == SprayLocation[i][2])
                { // The client's spray is on the same wall as the i's spray, let's check the distance
                    if (GetVectorDistance(SprayLocation[client], SprayLocation[i]) <= SprayProtection)
                    { // The client's spray is too close to the i's spray, disallow it.
                        cantspray = true;
                    }
                }
                else
                { // Not the same perpendicular wall, might be on angle wall, let's check distance
                    if (GetVectorDistance(SprayLocation[client], SprayLocation[i]) <= SprayProtection)
                    { // The client's spray is too close to the i's spray, disallow it.
                        cantspray = true;
                    }
                }

                if (cantspray)
                {
                    if (WarnType & 1)
                    {
                        PrintCenterText(client, "%t", "Spray On Spray Center", i);
                    }

                    if (WarnType & 2)
                    {
                        PrintHintText(client, "%t", "Spray On Spray Hint", i);
                    }

                    if (WarnType & 4)
                    {
                        Client_PrintKeyHintText(client, "%t", "Spray On Spray KeyHint", i);
                    }

                    return Plugin_Handled;
                }
            }
        }

        SprayTime[client] = GetGameTime();

        if (!GetClientName(client, SprayerName[client], sizeof(SprayerName[])))
        {
            Format(SprayerName[client], sizeof(SprayerName[]), "Unk Name");
        }

        if (!GetClientAuthId(client, AuthId_SteamID64, SprayerID[client], sizeof(SprayerID[])))
        {
            Format(SprayerID[client], sizeof(SprayerID[]), "Unk SteamID");
        }

        if (Debug)
        {
            float vec[3];
            GetVectorAngles(SprayLocation[client], vec);
            PrintToChatAll("Spray Location: %f %f %f", SprayLocation[client][0], SprayLocation[client][1], SprayLocation[client][2]);
            PrintToChatAll("Vector Angle is: %f %f %f", vec[0], vec[1], vec[2]);
            LogMessage("%N's spray info:", client);
            LogMessage("Spray Location: %.2f %.2f %.2f", SprayLocation[client][0], SprayLocation[client][1], SprayLocation[client][2]);
            LogMessage("Spray Time [%.2f] - Sprayer Name [%s] - SprayerID [%s]", SprayTime[client], SprayerName[client], SprayerID[client]);
        }

        if (!PlayerCachedCookie[client])
        {
            if (Debug)
            {
                LogMessage("%N's cookies are not cached yet", client);
            }

            if (AllowSpraysBeforeAuthentication)
            {
                if (Debug)
                {
                    LogMessage("%N's Spray is allowed, even though client's cookie hasn't been cached yet", client);
                }

                return Plugin_Continue;
            }
            else
            {
                CPrintToChat(client, "{green}[{red}Banned Sprays{green}] %t", "Checking Permissions");
                return Plugin_Handled;
            }
        }

        if (!PlayerCanSpray[client])
        {
            CPrintToChat(client, "{red}[{green}Banned Sprays{red}] %t", "Cant Spray");
            return Plugin_Handled;
        }
    }

    return Plugin_Continue;
}

/**
 * Used to cause the spraying of a player's decal
 * @param	client	ClientID of player who is having their decal sprayed
 * @param	entIndex	Usually 0
 * @param	vecPos	Vector position to spray the decal
 * @noreturn
 */
public void SprayDecal(int client, int entIndex, float vecPos[3])
{
    if (!IsValidClient(client))
    {
        if (Debug)
        {
            LogMessage("Client (%i) is not a valid client, cannot remove spray.", client);
        }

        return;
    }

    TE_Start("Player Decal");
    TE_WriteVector("m_vecOrigin", vecPos);
    TE_WriteNum("m_nEntity", entIndex);
    TE_WriteNum("m_nPlayer", client);
    TE_SendToAll();
}

// ------------------------------------------------------------------------------------------
// --- Thanks to author(s) of Spray Tracer for the following four pieces of code ---
// ------------------------------------------------------------------------------------------
public Action TraceAllSprays(Handle timer)
{
    vectorPos[0] = 0.0;
    vectorPos[1] = 0.0;
    vectorPos[2] = 0.0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || !CanViewSprayInfo[i] || IsFakeClient(i))
        {
            continue;
        }

        if (GetPlayerAimPosition(i, vectorPos))
        {
            for (int a = 1; a <= MaxClients; a++)
            {
                if (!IsClientInGame(a) || IsFakeClient(a))
                {
                    continue;
                }

                if (GetVectorDistance(vectorPos, SprayLocation[a]) <= TraceDistance)
                {
                    if (DisplayType & 1)
                    {
                        PrintCenterText(i, "%t", "Sprayed By center", SprayerName[a], SprayerID[a], (GetGameTime() - SprayTime[a]));
                    }

                    if (DisplayType & 2)
                    {
                        PrintHintText(i, "%t", "Sprayed By hint", SprayerName[a], SprayerID[a], (GetGameTime() - SprayTime[a]));
                    }

                    if (DisplayType & 4)
                    {
                        Client_PrintKeyHintText(i, "%t", "Sprayed By keyhint", SprayerName[a], SprayerID[a], (GetGameTime() - SprayTime[a]));
                    }
                }
            }
        }
    }

    return Plugin_Handled;
}

/**
 * @param		client		Player's ClientID
 * @param		vecPos	Vector Position player is aiming at
 *
 * @return			True if player aim vector is found, false otherwise
 */
public bool GetPlayerAimPosition(int client, float vecPos[3])
{
    if (!IsClientInGame(client))
    {
        return false;
    }

    float vecAngles[3];
    float vecOrigin[3];

    GetClientEyePosition(client, vecOrigin);
    GetClientEyeAngles(client, vecAngles);

    Handle hTrace = TR_TraceRayFilterEx(vecOrigin, vecAngles, MASK_SHOT, RayType_Infinite, TraceEntityFilterPlayer);

    if (TR_DidHit(hTrace))
    {
        TR_GetEndPosition(vecPos, hTrace);
        CloseHandle(hTrace);
        return true;
    }

    CloseHandle(hTrace);
    return false;
}

public bool TraceEntityFilterPlayer(int entity, int contentsMask)
{
    return entity > MaxClients;
}

bool IsValidClient(int client)
{
    if (client <= 0 || client > MaxClients)
    {
        return false;
    }

    return IsClientInGame(client);
}

/**
 * Function to clear/kill the timer and set to INVALID_HANDLE if it's still active
 *
 * @param	timer		Handle of the timer
 * @noreturn
 */
public void ClearTimer(Handle timer)
{
    if (timer != INVALID_HANDLE)
    {
        KillTimer(timer);
        timer = INVALID_HANDLE;
    }
}

public void ResetVariables(int client)
{
    if (client == 0)
    {
        for (int i = 1; i <= MaxClients; i++)
        {
            if (IsClientInGame(i))
            {
                SprayerID[i][0]     = '\0';
                SprayerName[i][0]   = '\0';
                SprayLocation[i][0] = 0.0;
                SprayLocation[i][1] = 0.0;
                SprayLocation[i][2] = 0.0;
                SprayTime[i]        = 0.0;
            }
        }

        return;
    }

    SprayerID[client][0]       = '\0';
    SprayerName[client][0]     = '\0';
    SprayLocation[client][0]   = 0.0;
    SprayLocation[client][1]   = 0.0;
    SprayLocation[client][2]   = 0.0;
    SprayTime[client]          = 0.0;
    PlayerCachedCookie[client] = false;
    PlayerCanSpray[client]     = false;
}

/**
 * Converts a string to a vector.
 *
 * @param str			String to convert to a vector.
 * @param vector		Vector to store the converted string to vector
 * @return			True on success, false on failure
 */
bool StringToVector(char str[30], float vector[3])
{
    char t_str[3][20];

    ReplaceString(str, sizeof(str), ",", " ", false);
    ReplaceString(str, sizeof(str), ";", " ", false);
    ReplaceString(str, sizeof(str), "  ", " ", false);
    TrimString(str);

    ExplodeString(str, " ", t_str, sizeof(t_str), sizeof(t_str[]));

    vector[0] = StringToFloat(t_str[0]);
    vector[1] = StringToFloat(t_str[1]);
    vector[2] = StringToFloat(t_str[2]);

    if (Debug)
    {
        LogMessage("Converted string [%s] to vector [%f %f %f]", str, vector[0], vector[1], vector[2]);
    }

    return true;
}

// ----------------------------------------------
// --------------- COMMANDS ---------------
// ----------------------------------------------
public Action Command_BanSpray(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[Ban Spray] Usage: sm_banspray <player>");
        return Plugin_Handled;
    }

    int  target;
    char target_name[MAX_NAME_LENGTH];
    target_name[0] = '\0';

    GetCmdArg(1, target_name, sizeof(target_name));

    if ((target = FindTarget(
             client,
             target_name,
             true,
             true)) <= 0)
    {
        return Plugin_Handled;
    }

    PerformSprayBan(client, target);

    return Plugin_Handled;
}

public Action Command_BanSpraySteamID(int client, int args)
{
    if (args < 2)
    {
        ReplyToCommand(client, "[Ban Spray] Usage: sm_banspray_steamid <SteamID64> <1/0>");
        return Plugin_Handled;
    }

    char arg_string[256];
    char authid[18];
    char yesno[10];

    GetCmdArgString(arg_string, sizeof(arg_string));

    int len;
    int total_len;

    // Get SteamID
    if ((len = BreakString(arg_string, authid, sizeof(authid))) != -1)
    {
        total_len += len;
    }

    // Validate SteamID
    char   steamid_regex[10] = "[0-9]{17}";
    Handle steamid_regex_cmp = CompileRegex(steamid_regex, PCRE_CASELESS);
    if (MatchRegex(steamid_regex_cmp, authid) != 1)
    {
        ReplyToCommand(client, "[Ban Spray] Invalid SteamID format, must be in SteamID64 format.");
        return Plugin_Handled;
    }

    // Validate on/off
    if (strcmp(arg_string[total_len], "1", false) == 0 || strcmp(arg_string[total_len], "0", false) == 0)
    {
        int value = StringToInt(arg_string[total_len]);
        value == 1 ? Format(yesno, sizeof(yesno), "banned") : Format(yesno, sizeof(yesno), "unbanned");

        SetAuthIdCookie(authid, g_cookie, arg_string[total_len]);

        ShowActivity2(client, "[Ban Spray] ", "%t", "Set Spray", authid, yesno);
        LogAction(client, -1, "%L %t", client, "Set Spray", authid, yesno);

        return Plugin_Handled;
    }
    else
    {
        ReplyToCommand(client, "%t", "Valid Parameters", authid, arg_string[total_len]);
    }

    return Plugin_Handled;
}

public Action Command_UnBanSpray(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[Ban Spray] Usage: sm_unbanspray <player>");
        return Plugin_Handled;
    }

    int  target;
    char target_name[MAX_NAME_LENGTH];

    GetCmdArg(1, target_name, sizeof(target_name));

    if ((target = FindTarget(client, target_name, false, true)) <= 0)
    {
        return Plugin_Handled;
    }

    PerformSprayUnBan(client, target);

    return Plugin_Handled;
}

public Action Command_BanSprayList(int client, int args)
{
    char bannedlist[4096], count;

    Format(bannedlist, sizeof(bannedlist), "\n%t:\n", "List");
    Format(bannedlist, sizeof(bannedlist), "%s%t\n\n", bannedlist, "List2");

    char cookie[32];

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i))
        {
            count++;

            GetClientCookie(i, g_cookie, cookie, sizeof(cookie));

            if (StrEqual(cookie, "1"))
            {
                Format(bannedlist, sizeof(bannedlist), "%s*** BANNED : %L\n", bannedlist, i);
            }
            else
            {
                Format(bannedlist, sizeof(bannedlist), "%sNot Banned : %L\n", bannedlist, i);
            }
        }
    }

    Format(bannedlist, sizeof(bannedlist), "%s\n============================ end of list =============================\n", bannedlist);

    if (count == 0)
    {
        ReplyToCommand(client, "%t", "No Players");
        return Plugin_Handled;
    }

    PrintToConsole(client, bannedlist);
    return Plugin_Continue;
}

public Action Command_DeleteSpray(int client, int args)
{
    float vPos[3];

    if (args < 1)
    {
        if (GetPlayerAimPosition(client, vPos))
        {
            for (int a = 1; a <= MaxClients; a++)
            {
                if (!IsClientInGame(a) || IsFakeClient(a))
                {
                    continue;
                }

                if (GetVectorDistance(vPos, SprayLocation[a]) <= TraceDistance)
                {
                    SprayDecal(a, 0, vecTempLoc);
                    PrintToChat(client, "%t", "Removed", a);

                    ShowActivity2(client, "[Ban Spray] ", "%t", a);
                    LogAction(client, a, "%L removed spray of %L", client, a);
                }
                else
                {
                    PrintToChat(client, "%t", "Error");
                }
            }
        }

        return Plugin_Handled;
    }

    int  target;
    char target_name[MAX_NAME_LENGTH];

    GetCmdArg(1, target_name, sizeof(target_name));

    if ((target = FindTarget(client, target_name, false, true)) <= 0)
    {
        return Plugin_Handled;
    }

    // Remove Player's Spray
    SprayDecal(target, 0, vecTempLoc);
    PrintToChat(client, "%t", "Removed", target);

    ShowActivity2(client, "[Ban Spray] ", "%t", target);
    LogAction(client, target, "%L removed spray of %L", client, target);

    return Plugin_Handled;
}

// ------------------------------------------
// ---------------- MENU -----------------
// ------------------------------------------
public void OnAdminMenuReady(Handle topmenu)
{
    if (topmenu == g_adminMenu)
    {
        return;
    }

    g_adminMenu                   = topmenu;

    TopMenuObject player_commands = FindTopMenuCategory(g_adminMenu, ADMINMENU_PLAYERCOMMANDS);

    if (player_commands == INVALID_TOPMENUOBJECT)
    {
        return;
    }

    AddToTopMenu(g_adminMenu, "sm_banspray", TopMenuObject_Item, AdminMenu_BanSpray, player_commands, "sm_banspray", ADMFLAG_BAN);
}

public void Menu_Status(int client, CookieMenuAction action, any info, char[] buffer, int maxlen)
{
    if (action == CookieMenuAction_DisplayOption)
    {
        Format(buffer, maxlen, "%t", "Display");
    }
    else if (action == CookieMenuAction_SelectOption)
    {
        CreateMenuStatus(client);
    }
}

public void AdminMenu_BanSpray(Handle topmenu, TopMenuAction action, TopMenuObject object_id, int param, char[] buffer, int maxlength)
{
    switch (action)
    {
        case TopMenuAction_DisplayOption: {
            Format(buffer, maxlength, "%t", "Ban Unban");
        }

        case TopMenuAction_SelectOption: {
            DisplayBanSprayPlayerMenu(param);
        }
    }
}

public void DisplayBanSprayPlayerMenu(int client)
{
    Handle menu = CreateMenu(MenuHandler_BanSpray);

    char   title[100];
    Format(title, sizeof(title), "%t", "Ban Sprays");
    SetMenuTitle(menu, title);
    SetMenuExitBackButton(menu, true);
    AddTargetsToMenu2(menu, client, COMMAND_FILTER_CONNECTED | COMMAND_FILTER_NO_BOTS);
    DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

public void MenuHandler_BanSpray(Handle menu, MenuAction action, int param1, int param2)
{
    int client = param1;

    switch (action)
    {
        case MenuAction_End: {
            CloseHandle(menu);
        }

        case MenuAction_Cancel: {
            if (param2 == MenuCancel_ExitBack && g_adminMenu != INVALID_HANDLE)
            {
                DisplayTopMenu(g_adminMenu, client, TopMenuPosition_LastCategory);
            }
        }

        case MenuAction_Select: {
            char info[32];

            GetMenuItem(menu, param2, info, sizeof(info));
            int userid = StringToInt(info);
            int target = GetClientOfUserId(userid);

            if (!target)
            {
                PrintToChat(client, "[Banned Spray] %t", "Player no longer available");
            }
            else if (!CanUserTarget(client, target))
            {
                PrintToChat(client, "[Banned Spray] %t", "Unable to target");
            }
            else
            {
                g_BanSprayTarget[client] = target;
                DisplayBanSprayMenu(client, target);
            }
        }
    }
}

public void DisplayBanSprayMenu(int client, int target)
{
    Handle menu = CreateMenu(MenuHandler_BanSprays);

    char   title[100];
    Format(title, sizeof(title), "%t", "Choose");
    SetMenuTitle(menu, title);
    SetMenuExitBackButton(menu, true);

    char cookie[8];

    GetClientCookie(target, g_cookie, cookie, sizeof(cookie));

    if (!strcmp(cookie, "1"))
    {
        AddMenuItem(menu, "0", "UnBan Player's Spray");
    }
    else
    {
        AddMenuItem(menu, "1", "Ban Player's Spray");
    }

    DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

public void MenuHandler_BanSprays(Handle menu, MenuAction action, int param1, int param2)
{
    int client = param1;

    switch (action)
    {
        case MenuAction_End: {
            CloseHandle(menu);
        }

        case MenuAction_Cancel: {
            if (param1 == MenuCancel_ExitBack && g_adminMenu != INVALID_HANDLE)
            {
                DisplayTopMenu(g_adminMenu, client, TopMenuPosition_LastCategory);
            }
        }

        case MenuAction_Select: {
            char info[32];

            GetMenuItem(menu, param2, info, sizeof(info));
            int action_info = StringToInt(info);

            switch (action_info)
            {
                case 0: {
                    PerformSprayUnBan(client, g_BanSprayTarget[client]);
                }

                case 1: {
                    PerformSprayBan(client, g_BanSprayTarget[client]);
                }
            }
        }
    }
}

public void CreateMenuStatus(int client)
{
    Handle menu = CreateMenu(Menu_StatusDisplay);
    char   text[64];
    char   cookie[8];
    char   msg[64];

    Format(text, sizeof(text), "%t", "Status");
    SetMenuTitle(menu, text);

    GetClientCookie(client, g_cookie, cookie, sizeof(cookie));

    if (!strcmp(cookie, "1"))
    {
        Format(msg, sizeof(msg), "%t", "You are banned");
        AddMenuItem(menu, "banned-spray", msg, ITEMDRAW_DISABLED);
    }
    else
    {
        Format(msg, sizeof(msg), "%t", "You are not banned");
        AddMenuItem(menu, "banned-spray", msg, ITEMDRAW_DISABLED);
    }

    SetMenuExitBackButton(menu, true);
    SetMenuExitButton(menu, true);
    DisplayMenu(menu, client, 15);
}

public void Menu_StatusDisplay(Handle menu, MenuAction action, int param1, int param2)
{
    int client = param1;

    switch (action)
    {
        case MenuAction_Cancel: {
            switch (param2)
            {
                case MenuCancel_ExitBack: {
                    ShowCookieMenu(client);
                }
            }
        }

        case MenuAction_End: {
            CloseHandle(menu);
        }
    }
}

// --------------------------------
// --------- SMLib Stuff -------
// -------- Thanks Berni --------
/**
 * Prints white text to the right-center side of the screen
 * for one client. Does not work in all games.
 * Line Breaks can be done with "\n".
 *
 * @param client		Client Index.
 * @param format		Formatting rules.
 * @param ...			Variable number of format parameters.
 * @return				True on success, false if this usermessage doesn't exist.
 */
bool Client_PrintKeyHintText(int client, const char[] format, any...)
{
    Handle userMessage = StartMessageOne("KeyHintText", client);

    if (userMessage == INVALID_HANDLE)
    {
        return false;
    }

    char buffer[MAX_MESSAGE_LENGTH];

    SetGlobalTransTarget(client);
    VFormat(buffer, sizeof(buffer), format, 3);

    if (GetFeatureStatus(FeatureType_Native, "GetUserMessageType") == FeatureStatus_Available && GetUserMessageType() == UM_Protobuf)
    {
        PbSetString(userMessage, "hints", format);
    }
    else
    {
        BfWriteByte(userMessage, 1);
        BfWriteString(userMessage, buffer);
    }

    EndMessage();

    return true;
}

public void OnVersionChanged(Handle cvar, const char[] oldValue, const char[] newValue)
{
    if (!StrEqual(newValue, PLUGIN_VERSION))
    {
        SetConVarString(cvar, PLUGIN_VERSION);
    }
}

public void OnRemoveSprayChanged(Handle cvar, const char[] oldVal, const char[] newVal)
{
    RemoveSprayOnBan = GetConVarBool(cvar);
}

public void OnAuthenticationChanged(Handle cvar, const char[] oldVal, const char[] newVal)
{
    AllowSpraysBeforeAuthentication = GetConVarBool(cvar);
}

public void OnTempLocChanged(Handle cvar, const char[] oldVal, const char[] newVal)
{
    GetConVarString(cvar, TmpLoc, sizeof(TmpLoc));
    StringToVector(TmpLoc, vecTempLoc);
}

public void OnDebugChanged(Handle cvar, const char[] oldVal, const char[] newVal)
{
    Debug = GetConVarBool(cvar);
}

public void OnTraceChanged(Handle cvar, const char[] oldVal, const char[] newVal)
{
    TraceSprays = GetConVarBool(cvar);

    ClearTimer(g_TraceTimer);

    if (TraceSprays)
    {
        g_TraceTimer = CreateTimer(TraceRate, TraceAllSprays, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    }
}

public void OnTraceRateChanged(Handle cvar, const char[] oldVal, const char[] newVal)
{
    TraceRate = GetConVarFloat(cvar);

    ClearTimer(g_TraceTimer);

    g_TraceTimer = CreateTimer(TraceRate, TraceAllSprays, _, TIMER_REPEAT);
}

public void OnDisplayChanged(Handle cvar, const char[] oldVal, const char[] newVal)
{
    DisplayType = GetConVarInt(cvar);
}

public void OnTraceDistChanged(Handle cvar, const char[] oldVal, const char[] newVal)
{
    TraceDistance = GetConVarFloat(cvar);
}

public void OnProtectionChanged(Handle cvar, const char[] oldVal, const char[] newVal)
{
    SprayProtection = GetConVarInt(cvar);
}

public void OnWarnTypeChanged(Handle cvar, const char[] oldVal, const char[] newVal)
{
    WarnType = GetConVarInt(cvar);
}
