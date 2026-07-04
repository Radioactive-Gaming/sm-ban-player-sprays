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
#define LOCATION_MAXLENGTH 30

#define PLUGIN_NAME        "Banned Sprays"
#define PLUGIN_AUTHOR      "TnTSCS aka ClarkKent, X8ETr1x, burlindw"
#define PLUGIN_URL         "https://github.com/Radioactive-Gaming/sm-ban-player-sprays"
#define PLUGIN_DESCRIPTION "Delete sprays and ban players from using sprays"
#define PLUGIN_VERSION     "1.0.0"

public Plugin myinfo = {
    name        = PLUGIN_NAME,
    description = PLUGIN_DESCRIPTION,
    author      = PLUGIN_AUTHOR,
    version     = PLUGIN_VERSION,
    url         = PLUGIN_URL,
}

bool   CanViewSprayInfo[MAXPLAYERS + 1];
bool   PlayerCachedCookie[MAXPLAYERS + 1] = {false, ...};
bool   PlayerCanSpray[MAXPLAYERS + 1]     = {false, ...};
char   g_BanSprayTarget[MAXPLAYERS + 1];
char   SprayerID[MAXPLAYERS + 1][32];
char   SprayerName[MAXPLAYERS + 1][MAX_NAME_LENGTH];
float  SprayLocation[MAXPLAYERS + 1][3];
float  SprayTime[MAXPLAYERS + 1];
float  vectorPos[3];
Handle g_cookie;
Handle g_adminMenu = INVALID_HANDLE;
Handle g_TraceTimer;

/**
 * Automatically remove a player's spray when that player's spray is banned.
 **/
bool   config_autoremove = true;
Handle convar_autoremove = INVALID_HANDLE;

/**
 * Deleted sprays are moved to this location on the map.
 *
 * @note Spray's can't actually be deleted; they can only be moved. The origin
 * is usually a safe place to move them, but some maps may require a custom
 * location.
 **/
Handle convar_delete_loc    = INVALID_HANDLE;
float  config_delete_loc[3] = {0.0, 0.0, 0.0};

/**
 * The frequency (in seconds) to raycast for sprays under the client's
 * crosshair. Setting this to zero disables raycasting.
 **/
Handle convar_tracing_freq = INVALID_HANDLE;
float  config_tracing_freq = 3.0;

/**
 * The distance (in hammer units) to raycast for sprays under the client's
 * crosshair. Setting this to zero disables raycasting.
 **/
Handle convar_tracing_dist = INVALID_HANDLE;
float  config_tracing_dist = 25.0;

/**
 * Admins with this permission flag may ban players' sprays. It is parsed and
 * passed to RegAdminCmd(), which means we do not need to store it ourselves.
 **/
Handle convar_adminflag_ban = INVALID_HANDLE;

/**
 * Admins with this permission flag may delete sprays. It is parsed and passed
 * to RegAdminCmd(), which means we do not need to store it ourselves.
 **/
Handle convar_adminflag_delete = INVALID_HANDLE;

/**
 * Players may not create sprays within this radius (in hammer units) of an
 * existing spray. Setting this to zero disables the feature.
 **/
Handle convar_occlusion_radius = INVALID_HANDLE;
float  config_occlusion_radius = 0.0;

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
    CreateConVar("sm_bannedsprays_version", PLUGIN_VERSION, "The version of Banned Sprays", FCVAR_SPONLY | FCVAR_REPLICATED | FCVAR_DONTRECORD);

    convar_autoremove       = CreateConVar("sm_bannedsprays_autoremove", "1", "Automatically remove a player's spray from the map when their spray is banned");
    convar_delete_loc       = CreateConVar("sm_bannedsprays_delete_loc", "0.00 0.00 0.00", "Deleted sprays are moved to this location on the map");
    convar_tracing_freq     = CreateConVar("sm_bannedsprays_tracing_freq", "3.0", "The frequency to raycast for sprays", _, true, 0.0);
    convar_tracing_dist     = CreateConVar("sm_bannedsprays_tracing_dist", "25", "The distance to raycast for sprays", _, true, 0.0, true, 250.0);
    convar_adminflag_ban    = CreateConVar("sm_bannedsprays_adminflag_ban", "d", "Admins with this permission flag may ban players' sprays");
    convar_adminflag_delete = CreateConVar("sm_bannedsprays_adminflag_delete", "c", "Admins with this permission flag may delete sprays");
    convar_occlusion_radius = CreateConVar("sm_bannedsprays_occlusion_radius", "0", "Players may not create sprays within this radius of an existing spray", _, true, 0.0, false, 1000.0);

    AddTempEntHook("Player Decal", PlayerSpray);

    SetCookieMenuItem(Menu_Status, 0, "Display Banned Spray Status");

    g_cookie = RegClientCookie("banned-spray", "Banned spray status", CookieAccess_Protected);

    LoadTranslations("common.phrases");
    LoadTranslations("ban_player_sprays.phrases");

    AutoExecConfig(true, "plugin.ban_player_sprays");

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            OnClientPostAdminCheck(i);
        }
    }
}

/**
 * Called when the map has loaded, servercfgfile (server.cfg) has been executed,
 * and all plugin configs are done executing. This is the best place to
 * initialize plugin functions which are based on cvar data.
 *
 * @note This will always be called once and only once per map. It will be
 * called after OnMapStart().
 **/
public void OnConfigsExecuted()
{
    char buffer[LOCATION_MAXLENGTH];

    // Simple configuration variables.
    config_autoremove       = GetConVarBool(convar_autoremove);
    config_tracing_freq     = GetConVarFloat(convar_tracing_freq);
    config_tracing_dist     = GetConVarFloat(convar_tracing_dist);
    config_occlusion_radius = GetConVarFloat(convar_occlusion_radius);

    // There is no vector primitive for console variables. We must parse it ourselves.
    GetConVarString(convar_delete_loc, buffer, sizeof(buffer));
    StringToVector(buffer, config_delete_loc);

    AdminFlag flag;

    GetConVarString(convar_adminflag_ban, buffer, sizeof(buffer));
    if (strlen(buffer) == 1 && FindFlagByChar(buffer[0], flag))
    {
        int bit = FlagToBit(flag);
        RegAdminCmd("sm_banspray", Command_BanSpray, bit, "Permanently remove a players ability to use spray");
        RegAdminCmd("sm_unbanspray", Command_UnBanSpray, bit, "Permanently remove a players ability to use spray");
        RegAdminCmd("sm_banspray_steamid", Command_BanSpraySteamID, bit, "Manually add a SteamID to the list of players who are banned from using sprays");
    }
    else
    {
        LogInvalidConVarValue(convar_adminflag_ban);
    }

    GetConVarString(convar_adminflag_delete, buffer, sizeof(buffer));
    if (strlen(buffer) == 1 && FindFlagByChar(buffer[0], flag))
    {
        int bit = FlagToBit(flag);
        RegAdminCmd("sm_deletespray", Command_DeleteSpray, bit, "Remove a player's spray by either looking at it or providing a player's name");
    }
    else
    {
        LogInvalidConVarValue(convar_adminflag_delete);
    }
}

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
    if (IsTracingEnabled())
    {
        ClearTimer(g_TraceTimer);

        g_TraceTimer = CreateTimer(config_tracing_freq, TraceAllSprays, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
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

bool IsTracingEnabled()
{
    return config_tracing_dist != 0 && config_tracing_freq != 0;
}

void LogInvalidConVarValue(Handle convar)
{
    char name[50];
    char value[50];

    GetConVarName(convar, name, sizeof(name));
    GetConVarString(convar, value, sizeof(value));

    LogError("Invalid value '%s' for console variable '%s'", name, value);
    SetFailState("Invalid value '%s' for console variable '%s'", name, value);
}

/**
 * Timer callback for handling cookies
 * @param	timer	Handle to the timer
 * @param serial	Client serial passed through the timer
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
    if (config_autoremove)
    {
        SprayDecal(client, 0, config_delete_loc);
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
        LogMessage("%N is attempting to spray...", client);

        TE_ReadVector("m_vecOrigin", SprayLocation[client]);

        if (config_occlusion_radius > 0)
        {
            for (int i = 1; i <= MaxClients; i++)
            {
                if (i == client || !IsClientInGame(i))
                {
                    continue;
                }

                PrintToChatAll("Spray Location for %N: %f %f %f", client, SprayLocation[client][0], SprayLocation[client][1], SprayLocation[client][2]);
                PrintToChatAll("Spray Location for %N: %f %f %f", i, SprayLocation[i][0], SprayLocation[i][1], SprayLocation[i][2]);

                bool cantspray = false;

                if (SprayLocation[client][0] == SprayLocation[i][0] ||
                    SprayLocation[client][1] == SprayLocation[i][1] ||
                    SprayLocation[client][2] == SprayLocation[i][2])
                { // The client's spray is on the same wall as the i's spray, let's check the distance
                    if (GetVectorDistance(SprayLocation[client], SprayLocation[i]) <= config_occlusion_radius)
                    { // The client's spray is too close to the i's spray, disallow it.
                        cantspray = true;
                    }
                }
                else
                { // Not the same perpendicular wall, might be on angle wall, let's check distance
                    if (GetVectorDistance(SprayLocation[client], SprayLocation[i]) <= config_occlusion_radius)
                    { // The client's spray is too close to the i's spray, disallow it.
                        cantspray = true;
                    }
                }

                if (cantspray)
                {
                    PrintHintText(client, "%t", "Spray On Spray Hint", i);

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

        float vec[3];
        GetVectorAngles(SprayLocation[client], vec);
        PrintToChatAll("Spray Location: %f %f %f", SprayLocation[client][0], SprayLocation[client][1], SprayLocation[client][2]);
        PrintToChatAll("Vector Angle is: %f %f %f", vec[0], vec[1], vec[2]);
        LogMessage("%N's spray info:", client);
        LogMessage("Spray Location: %.2f %.2f %.2f", SprayLocation[client][0], SprayLocation[client][1], SprayLocation[client][2]);
        LogMessage("Spray Time [%.2f] - Sprayer Name [%s] - SprayerID [%s]", SprayTime[client], SprayerName[client], SprayerID[client]);

        if (!PlayerCachedCookie[client])
        {
            LogMessage("%N's cookies are not cached yet", client);

            CPrintToChat(client, "{green}[{red}Banned Sprays{green}] %t", "Checking Permissions");
            return Plugin_Handled;
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
        LogMessage("Client (%i) is not a valid client, cannot remove spray.", client);

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

                if (GetVectorDistance(vectorPos, SprayLocation[a]) <= config_tracing_dist)
                {
                    PrintHintText(i, "%t", "Sprayed By hint", SprayerName[a], SprayerID[a], (GetGameTime() - SprayTime[a]));
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
 * @param str String to convert to a vector.
 * @param vector Vector to store the converted string to vector
 **/
void StringToVector(char str[LOCATION_MAXLENGTH], float vector[3])
{
    char t_str[3][LOCATION_MAXLENGTH];

    ReplaceString(str, sizeof(str), ",", " ", false);
    ReplaceString(str, sizeof(str), ";", " ", false);
    ReplaceString(str, sizeof(str), "  ", " ", false);
    TrimString(str);

    ExplodeString(str, " ", t_str, 3, LOCATION_MAXLENGTH);

    vector[0] = StringToFloat(t_str[0]);
    vector[1] = StringToFloat(t_str[1]);
    vector[2] = StringToFloat(t_str[2]);

    LogMessage("Converted string [%s] to vector [%f %f %f]", str, vector[0], vector[1], vector[2]);
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

                if (GetVectorDistance(vPos, SprayLocation[a]) <= config_tracing_dist)
                {
                    SprayDecal(a, 0, config_delete_loc);
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
    SprayDecal(target, 0, config_delete_loc);
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
