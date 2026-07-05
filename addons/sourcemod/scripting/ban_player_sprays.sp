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
};

/**
 * Cookies are an empty string by default, this plugin is written so that *any*
 * value other than this default indicates a ban. It only sets the cookie to
 * "banned" for clarity when inspecting the database.
 **/
#define COOKIE_IDENTIFIER    "banned-spray"
#define COOKIE_VALUE_ALLOWED ""
#define COOKIE_VALUE_BANNED  "banned"
#define COOKIE_VALUE_LENGTH  8

#define STEAMID64_LENGTH   18
#define LOCATION_MAXLENGTH 30

enum SprayPermission {
    SPRAY_PERMISSION_UNKNOWN,
    SPRAY_PERMISSION_BANNED,
    SPRAY_PERMISSION_ALLOWED,
}

enum struct Client {
    // clang-format off
    SprayPermission permission;
    float           location[3];
    float           timestamp;
    // clang-format on
}

Client g_clients[MAXPLAYERS + 1];
Handle g_cookie;
Handle regex_steamid64;

// TODO: Clean these up
char   g_BanSprayTarget[MAXPLAYERS + 1];
Handle g_adminMenu = INVALID_HANDLE;

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
 * Sprays within this distance (in hammer units) are included in during
 * raycasts.
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

Handle convar_assume_banned = INVALID_HANDLE;
bool   config_assume_banned = false;

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
    convar_tracing_dist     = CreateConVar("sm_bannedsprays_tracing_dist", "25", "The distance to include sprays during a raycast", _, true, 0.0, true, 250.0);
    convar_adminflag_ban    = CreateConVar("sm_bannedsprays_adminflag_ban", "d", "Admins with this permission flag may ban players' sprays");
    convar_adminflag_delete = CreateConVar("sm_bannedsprays_adminflag_delete", "c", "Admins with this permission flag may delete sprays");
    convar_occlusion_radius = CreateConVar("sm_bannedsprays_occlusion_radius", "0", "Players may not create sprays within this radius of an existing spray", _, true, 0.0, false, 1000.0);
    convar_assume_banned    = CreateConVar("sm_bannedsprays_assume_banned", "0", "Assume clients are banned while waiting for the database to load their status");

    // This regular expression may be reused multiple times.
    regex_steamid64 = CompileRegex("[0-9]{17}");
    if (regex_steamid64 == INVALID_HANDLE)
    {
        LogError("Failed to compile regular expression");
        SetFailState("Failed to compile regular expression");
    }

    AddTempEntHook("Player Decal", OnTempEntPlayerDecal);

    SetCookieMenuItem(Menu_Status, 0, "Display Banned Spray Status");

    g_cookie = RegClientCookie(COOKIE_IDENTIFIER, "Banned spray status", CookieAccess_Protected);

    LoadTranslations("common.phrases");
    LoadTranslations("ban_player_sprays.phrases");

    AutoExecConfig(true, "plugin.ban_player_sprays");
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
    config_tracing_dist     = GetConVarFloat(convar_tracing_dist);
    config_occlusion_radius = GetConVarFloat(convar_occlusion_radius);
    config_assume_banned    = GetConVarBool(convar_assume_banned);

    // There is no vector primitive for console variables. We must parse it ourselves.
    GetConVarString(convar_delete_loc, buffer, sizeof(buffer));
    StringToVector(buffer, config_delete_loc);

    AdminFlag flag;

    GetConVarString(convar_adminflag_ban, buffer, sizeof(buffer));
    if (strlen(buffer) == 1 && FindFlagByChar(buffer[0], flag))
    {
        int bit = FlagToBit(flag);
        RegAdminCmd("sm_banspray", OnAdminCmdBanSpray, bit, "Remove a player's ability to use sprays");
        RegAdminCmd("sm_unbanspray", OnCmdUnbanSpray, bit, "Restore a player's ability to use sprays");
        RegAdminCmd("sm_banspray_steamid", OnAdminCmdBanSpraySteamID, bit, "Manually add a SteamID to the list of players who are banned from using sprays");
    }
    else
    {
        LogInvalidConVarValue(convar_adminflag_ban);
    }

    GetConVarString(convar_adminflag_delete, buffer, sizeof(buffer));
    if (strlen(buffer) == 1 && FindFlagByChar(buffer[0], flag))
    {
        int bit = FlagToBit(flag);
        RegAdminCmd("sm_deletespray", OnCmdDeleteSpray, bit, "Remove a player's spray by either looking at it or providing a player's name");
    }
    else
    {
        LogInvalidConVarValue(convar_adminflag_delete);
    }

    AddCommandListener(OnUserCmdSpray, "say");
    AddCommandListener(OnUserCmdSpray, "say_team");
}

public void OnClientPostAdminCheck(int client)
{
    g_clients[client].location[0] = config_delete_loc[0];
    g_clients[client].location[1] = config_delete_loc[1];
    g_clients[client].location[2] = config_delete_loc[2];

    if (!AreClientCookiesCached(client))
    {
        g_clients[client].permission = SPRAY_PERMISSION_UNKNOWN;
    }
}

public void OnClientCookiesCached(int client)
{
    char value[COOKIE_VALUE_LENGTH];
    GetClientCookie(client, g_cookie, value, sizeof(value));

    // Any value other than the allowed string indicates a ban.
    if (StrEqual(value, COOKIE_VALUE_ALLOWED, false))
    {
        g_clients[client].permission = SPRAY_PERMISSION_ALLOWED;
    }
    else
    {
        g_clients[client].permission = SPRAY_PERMISSION_BANNED;
    }
}

public void OnClientDisconnect(int client)
{
    DeleteSpray(0, client);
}

/**
 * Callback for the sm_banspray admin command.
 **/
public Action OnAdminCmdBanSpray(int admin, int args)
{
    if (args < 1)
    {
        ReplyToCommand(admin, "Usage: sm_banspray <player>");
        return Plugin_Handled;
    }

    char target_name[MAX_NAME_LENGTH];
    target_name[0] = '\0';

    GetCmdArg(1, target_name, sizeof(target_name));

    int target = FindTarget(admin, target_name, true, false);
    if (target > 0)
    {
        BanSpray(admin, target);
    }

    return Plugin_Handled;
}

/**
 * Callback for the sm_banspray_steamid admin command.
 **/
public Action OnAdminCmdBanSpraySteamID(int admin, int args)
{
    if (args < 2)
    {
        ReplyToCommand(admin, "Usage: sm_banspray_steamid <SteamID64> <%s/%s>", COOKIE_VALUE_BANNED, COOKIE_VALUE_ALLOWED);
        return Plugin_Handled;
    }

    // The first argument must be a SteamID64.
    char steamid[STEAMID64_LENGTH];
    GetCmdArg(1, steamid, sizeof(steamid));
    if (!MatchRegex(regex_steamid64, steamid))
    {
        ReplyToCommand(admin, "Invalid SteamID '%s': Expected SteamID64", steamid);
        return Plugin_Handled;
    }

    // The second argument indicates whether they are banned or allowed.
    char value[COOKIE_VALUE_LENGTH];
    GetCmdArg(2, value, sizeof(value));
    if (!StrEqual(value, COOKIE_VALUE_BANNED, false) && !StrEqual(value, COOKIE_VALUE_ALLOWED, false))
    {
        ReplyToCommand(admin, "Invalid ban status: Expected %s or %s", COOKIE_VALUE_BANNED, COOKIE_VALUE_ALLOWED);
        return Plugin_Handled;
    }

    // Set the cookie based on the provided id and log the message.
    SetAuthIdCookie(steamid, g_cookie, value);
    ShowActivity2(admin, "[Banned Sprays] ", "%t", "Set Spray", steamid, value);
    LogAction(admin, -1, "Set spray ban value for [%s] to %s", steamid, value);

    return Plugin_Handled;
}

/**
 * Callback for the sm_unbanspray admin command.
 **/
public Action OnCmdUnbanSpray(int admin, int args)
{
    if (args < 1)
    {
        ReplyToCommand(admin, "Usage: sm_unbanspray <player>");
        return Plugin_Handled;
    }

    char target_name[MAX_NAME_LENGTH];
    GetCmdArg(1, target_name, sizeof(target_name));

    int target = FindTarget(admin, target_name, false, true);
    if (IsValidClient(target))
    {
        UnbanSpray(admin, target);
    }

    return Plugin_Handled;
}

public Action OnCmdDeleteSpray(int admin, int args)
{
    switch (args)
    {
        // If no argument is provided, this does a raycast to remove the
        // spray(s) under the admin's crosshair.
        case 0:
        {
            int client;
            if (GetTargetedSpray(admin, client))
            {
                DeleteSpray(admin, client);
            }
        }

        // If an argument is provided, it is resolved as a player and that
        // player's spray is deleted.
        case 1:
        {
            char name[MAX_NAME_LENGTH];
            GetCmdArg(1, name, sizeof(name));

            int client = FindTarget(admin, name, false, true);
            if (IsValidClient(client))
            {
                DeleteSpray(admin, client);
            }
        }

        default:
        {
            // TODO: Translation
            ReplyToCommand(admin, "Usage: sm_deletespray <player>?");
        }
    }

    return Plugin_Handled;
}

public Action OnUserCmdSpray(int client, const char[] command, int argc)
{
    if (argc < 1 || !IsValidClient(client))
    {
        return Plugin_Continue;
    }

    // The argument passed to the say command must be "!spray" exactly.
    char message[10];
    GetCmdArg(1, message, sizeof(message));
    if (!StrEqual(message, "!spray"))
    {
        return Plugin_Continue;
    }

    DisplaySpray(client);
    return Plugin_Stop;
}

/**
 * Intercept a player trying to spray a decal.
 *
 * This is almost completely undocumented but admins with RCON access can
 * generate a list of the Temp Entities and their properties with the following
 * RCON command. This creates a `teprops.txt` file in the mod directory (`tf`).
 *
 * ```
 * sm_dump_teprops teprops.txt
 * ```
 *
 * The Player Decal TE has the following properties:
 * - `m_vecOrigin` is a vector of three floats and holds spray's location.
 * - `m_nPlayer` is an int and holds the client id.
 * - `m_nEntity` is an unused int.
 **/
public Action OnTempEntPlayerDecal(const char[] te_name, const int[] Players, int numClients, float delay)
{
    int client = TE_ReadNum("m_nPlayer");
    if (!IsValidClient(client))
    {
        LogMessage("Invalid client index in Player Decal TE");
        return Plugin_Continue;
    }

    if (IsClientBanned(client))
    {
        // TODO: Translation
        PrintHintText(client, "You have been banned from using sprays");
        return Plugin_Handled;
    }

    float location[3];
    TE_ReadVector("m_vecOrigin", location);

    if (config_occlusion_radius > 0)
    {
        for (int other = 1; other <= MaxClients; other++)
        {
            if (other == client || !IsClientInGame(other))
            {
                continue;
            }

            float distance = GetVectorDistance(location, g_clients[other].location);
            if (distance <= config_occlusion_radius)
            {
                // TODO: Translation
                PrintHintText(client, "You are too close to another spray");
                return Plugin_Handled;
            }
        }
    }

    g_clients[client].location[0] = location[0];
    g_clients[client].location[1] = location[1];
    g_clients[client].location[2] = location[2];
    g_clients[client].timestamp   = GetGameTime();
    return Plugin_Continue;
}

void DeleteSpray(int admin, int client)
{
    TE_Start("Player Decal");
    TE_WriteVector("m_vecOrigin", config_delete_loc);
    TE_WriteNum("m_nEntity", 0);
    TE_WriteNum("m_nPlayer", client);
    TE_SendToAll();

    // The server needs to delete sprays when people leave to ensure that people
    // can spray something against server rules and leave before an admin
    // notices. The automatic removal does not warrant notication or logging.
    if (admin != 0)
    {
        // TODO: Translation
        ShowActivity2(admin, "[Banned Sprays] ", "deleted the spray for %N", client);
        LogAction(admin, client, "%L deleted the spray for %L", admin, client);
    }
}

void BanSpray(int admin, int client)
{
    if (config_autoremove)
    {
        DeleteSpray(admin, client);
    }

    g_clients[client].permission = SPRAY_PERMISSION_BANNED;
    SetClientCookie(client, g_cookie, COOKIE_VALUE_BANNED);

    // TODO: Translation
    ShowActivity2(admin, "[Banned Sprays] ", "banned sprays for %N", client);
    LogAction(admin, client, "%L banned sprays for %L", admin, client);
}

void UnbanSpray(int admin, int client)
{
    g_clients[client].permission = SPRAY_PERMISSION_ALLOWED;
    SetClientCookie(client, g_cookie, COOKIE_VALUE_ALLOWED);

    // TODO: Translation
    ShowActivity2(admin, "[Banned Sprays] ", "unbanned sprays for %N", client);
    LogAction(admin, client, "%L unbanned sprays for %L", admin, client);
}

void DisplaySpray(int client)
{
    int target;
    if (GetTargetedSpray(client, target))
    {
        char name[MAX_NAME_LENGTH];
        if (!GetClientName(target, name, sizeof(name)))
        {
            Format(name, sizeof(name), "UNKNOWN");
        }

        char steamid[STEAMID64_LENGTH];
        if (!GetClientAuthId(target, AuthId_SteamID64, steamid, sizeof(steamid)))
        {
            Format(name, sizeof(name), "UNKNOWN");
        }

        float duration = GetGameTime() - g_clients[target].timestamp;
        PrintHintText(client, "%t", "Sprayed By hint", name, steamid, duration);
    }
}

bool IsClientBanned(int client)
{
    switch (g_clients[client].permission)
    {
        case SPRAY_PERMISSION_UNKNOWN:
        {
            return config_assume_banned;
        }

        case SPRAY_PERMISSION_ALLOWED:
        {
            return false;
        }

        case SPRAY_PERMISSION_BANNED:
        {
            return true;
        }
    }

    LogError("Invalid client permission '%d'", view_as<int>(g_clients[client].permission));
    SetFailState("Invalid client permission '%d'", view_as<int>(g_clients[client].permission));
    return false; // unreachable
}

bool IsValidClient(int client)
{
    return 0 < client && client <= MaxClients && IsClientInGame(client);
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
}

bool GetTargetedSpray(int client, int &target)
{
    // Find where the client is looking and do nothing if they are not looking
    // at anything.
    float location[3];
    if (!GetPlayerAimPosition(client, location))
    {
        return false;
    }

    // Find the player with the spray closest to where the client is looking.
    // This has an upper bound to ensure it finds something at least close to
    // where they are looking.
    float best = config_tracing_dist;
    for (int other = 1; other <= MaxClients; other++)
    {
        if (!IsClientInGame(other) || IsFakeClient(other))
        {
            continue;
        }

        float distance = GetVectorDistance(location, g_clients[other].location);
        if (distance < best)
        {
            best   = distance;
            target = other;
        }
    }
    return best < config_tracing_dist;
}

bool GetPlayerAimPosition(int client, float vecPos[3])
{
    if (!IsValidClient(client))
    {
        return false;
    }

    float vecAngles[3];
    float vecOrigin[3];

    GetClientEyePosition(client, vecOrigin);
    GetClientEyeAngles(client, vecAngles);

    Handle hTrace = TR_TraceRayFilterEx(vecOrigin, vecAngles, MASK_SHOT, RayType_Infinite, TraceEntityFilterPlayer, _, TRACE_EVERYTHING);

    if (TR_DidHit(hTrace))
    {
        TR_GetEndPosition(vecPos, hTrace);
        CloseHandle(hTrace);
        return true;
    }

    CloseHandle(hTrace);
    return false;
}

bool TraceEntityFilterPlayer(int entity, int contentsMask)
{
    return entity > MaxClients;
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

    g_adminMenu = topmenu;

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
        case TopMenuAction_DisplayOption:
        {
            Format(buffer, maxlength, "%t", "Ban Unban");
        }

        case TopMenuAction_SelectOption:
        {
            DisplayBanSprayPlayerMenu(param);
        }
    }
}

public void DisplayBanSprayPlayerMenu(int client)
{
    Handle menu = CreateMenu(MenuHandler_BanSpray);

    char title[100];
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
        case MenuAction_End:
        {
            CloseHandle(menu);
        }

        case MenuAction_Cancel:
        {
            if (param2 == MenuCancel_ExitBack && g_adminMenu != INVALID_HANDLE)
            {
                DisplayTopMenu(g_adminMenu, client, TopMenuPosition_LastCategory);
            }
        }

        case MenuAction_Select:
        {
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

    char title[100];
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
        case MenuAction_End:
        {
            CloseHandle(menu);
        }

        case MenuAction_Cancel:
        {
            if (param1 == MenuCancel_ExitBack && g_adminMenu != INVALID_HANDLE)
            {
                DisplayTopMenu(g_adminMenu, client, TopMenuPosition_LastCategory);
            }
        }

        case MenuAction_Select:
        {
            char info[32];

            GetMenuItem(menu, param2, info, sizeof(info));
            int action_info = StringToInt(info);

            switch (action_info)
            {
                case 0:
                {
                    UnbanSpray(client, g_BanSprayTarget[client]);
                }

                case 1:
                {
                    BanSpray(client, g_BanSprayTarget[client]);
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
        case MenuAction_Cancel:
        {
            switch (param2)
            {
                case MenuCancel_ExitBack:
                {
                    ShowCookieMenu(client);
                }
            }
        }

        case MenuAction_End:
        {
            CloseHandle(menu);
        }
    }
}
