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

#define CMD_DELETESPRAY "sm_deletespray"
#define CMD_BANSPRAY    "sm_banspray"
#define CMD_UNBANSPRAY  "sm_unbanspray"
#define CMD_BANSPRAYID  "sm_banspray_steamid"

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
Handle g_cookie = INVALID_HANDLE;
Regex  g_regex_steamid64;

/**
 * Automatically remove a player's spray when that player's spray is banned.
 **/
bool   g_config_autoremove = true;
Handle g_convar_autoremove = INVALID_HANDLE;

/**
 * Deleted sprays are moved to this location on the map.
 *
 * @note Spray's can't actually be deleted; they can only be moved. The origin
 * is usually a safe place to move them, but some maps may require a custom
 * location.
 **/
Handle g_convar_delete_loc    = INVALID_HANDLE;
float  g_config_delete_loc[3] = {0.0, 0.0, 0.0};

/**
 * Sprays within this distance (in hammer units) are included in during
 * raycasts.
 **/
Handle g_convar_targeting_radius = INVALID_HANDLE;
float  g_config_targeting_radius = 25.0;

/**
 * Admins with this permission flag may ban players' sprays.
 **/
Handle    g_convar_adminflag_ban = INVALID_HANDLE;
AdminFlag g_config_adminflag_ban = Admin_Ban;

/**
 * Admins with this permission flag may delete sprays.
 **/
Handle    g_convar_adminflag_delete = INVALID_HANDLE;
AdminFlag g_config_adminflag_delete = Admin_Kick;

/**
 * Players may not create sprays within this radius (in hammer units) of an
 * existing spray. Setting this to zero disables the feature.
 **/
Handle g_convar_occlusion_radius = INVALID_HANDLE;
float  g_config_occlusion_radius = 0.0;

Handle g_convar_assume_banned = INVALID_HANDLE;
bool   g_config_assume_banned = false;

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

    g_convar_autoremove       = CreateConVar("sm_bannedsprays_autoremove", "1", "Automatically remove a player's spray from the map when their spray is banned");
    g_convar_delete_loc       = CreateConVar("sm_bannedsprays_delete_loc", "0.00 0.00 0.00", "Deleted sprays are moved to this location on the map");
    g_convar_targeting_radius = CreateConVar("sm_bannedsprays_targeting_radius", "25", "The distance to include sprays during a raycast", _, true, 0.0, true, 250.0);
    g_convar_adminflag_ban    = CreateConVar("sm_bannedsprays_adminflag_ban", "d", "Admins with this permission flag may ban players' sprays");
    g_convar_adminflag_delete = CreateConVar("sm_bannedsprays_adminflag_delete", "c", "Admins with this permission flag may delete sprays");
    g_convar_occlusion_radius = CreateConVar("sm_bannedsprays_occlusion_radius", "0", "Players may not create sprays within this radius of an existing spray", _, true, 0.0, false, 1000.0);
    g_convar_assume_banned    = CreateConVar("sm_bannedsprays_assume_banned", "0", "Assume clients are banned while waiting for the database to load their status");

    // This regular expression may be reused multiple times.
    g_regex_steamid64 = CompileRegex("[0-9]{17}");
    if (g_regex_steamid64 == INVALID_HANDLE)
    {
        LogError("Failed to compile regular expression");
        SetFailState("Failed to compile regular expression");
    }

    AddTempEntHook("Player Decal", OnTempEntPlayerDecal);

    SetCookieMenuItem(UserSettingsMenu, 0, "Spray Permission");

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
    g_config_autoremove       = GetConVarBool(g_convar_autoremove);
    g_config_targeting_radius = GetConVarFloat(g_convar_targeting_radius);
    g_config_occlusion_radius = GetConVarFloat(g_convar_occlusion_radius);
    g_config_assume_banned    = GetConVarBool(g_convar_assume_banned);

    // There is no vector primitive for console variables. We must parse it ourselves.
    GetConVarString(g_convar_delete_loc, buffer, sizeof(buffer));
    StringToVector(buffer, g_config_delete_loc);

    GetConVarString(g_convar_adminflag_ban, buffer, sizeof(buffer));
    if (strlen(buffer) == 1 && FindFlagByChar(buffer[0], g_config_adminflag_ban))
    {
        int bit = FlagToBit(g_config_adminflag_ban);
        RegAdminCmd(CMD_BANSPRAY, OnCmdBanSpray, bit, "Remove a player's ability to use sprays");
        RegAdminCmd(CMD_UNBANSPRAY, OnCmdUnbanSpray, bit, "Restore a player's ability to use sprays");
        RegAdminCmd(CMD_BANSPRAYID, OnCmdBanSpraySteamID, bit, "Manually add a SteamID to the list of players who are banned from using sprays");
    }
    else
    {
        LogInvalidConVarValue(g_convar_adminflag_ban);
    }

    GetConVarString(g_convar_adminflag_delete, buffer, sizeof(buffer));
    if (strlen(buffer) == 1 && FindFlagByChar(buffer[0], g_config_adminflag_delete))
    {
        int bit = FlagToBit(g_config_adminflag_delete);
        RegAdminCmd(CMD_DELETESPRAY, OnCmdDeleteSpray, bit, "Remove a player's spray by either looking at it or providing a player's name");
    }
    else
    {
        LogInvalidConVarValue(g_convar_adminflag_delete);
    }

    AddCommandListener(OnUserCmdSpray, "say");
    AddCommandListener(OnUserCmdSpray, "say_team");
}

public void OnClientPostAdminCheck(int client)
{
    g_clients[client].location[0] = g_config_delete_loc[0];
    g_clients[client].location[1] = g_config_delete_loc[1];
    g_clients[client].location[2] = g_config_delete_loc[2];

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
public Action OnCmdBanSpray(int admin, int args)
{
    if (args < 1)
    {
        CreateBanSprayMenu(admin);
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
public Action OnCmdBanSpraySteamID(int admin, int args)
{
    if (args < 2)
    {
        ReplyToCommand(admin, "Usage: sm_banspray_steamid <SteamID64> <allowed | banned>");
        return Plugin_Handled;
    }

    // The first argument must be a SteamID64.
    char steamid[STEAMID64_LENGTH];
    GetCmdArg(1, steamid, sizeof(steamid));
    if (!MatchRegex(g_regex_steamid64, steamid))
    {
        ReplyToCommand(admin, "Invalid SteamID '%s': Expected SteamID64", steamid);
        return Plugin_Handled;
    }

    // The second argument indicates whether they are banned or allowed.
    char value[9];
    GetCmdArg(2, value, sizeof(value));

    if (StrEqual(value, "banned", false))
    {
        SetAuthIdCookie(steamid, g_cookie, COOKIE_VALUE_BANNED);
    }
    else if (StrEqual(value, "allowed", false))
    {
        SetAuthIdCookie(steamid, g_cookie, COOKIE_VALUE_ALLOWED);
    }
    else
    {
        ReplyToCommand(admin, "Invalid ban status: Expected allowed or banned");
        return Plugin_Handled;
    }

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
        CreateUnbanSprayMenu(admin);
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

    if (g_config_occlusion_radius > 0)
    {
        for (int other = 1; other <= MaxClients; other++)
        {
            if (other == client || !IsClientInGame(other))
            {
                continue;
            }

            float distance = GetVectorDistance(location, g_clients[other].location);
            if (distance <= g_config_occlusion_radius)
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
    TE_WriteVector("m_vecOrigin", g_config_delete_loc);
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
    if (g_config_autoremove)
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
            return g_config_assume_banned;
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
    float best = g_config_targeting_radius;
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
    return best < g_config_targeting_radius;
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

/**
 * Create the item for this plugin that appears in the `!settings` menu.
 **/
void UserSettingsMenu(int client, CookieMenuAction action, any info, char[] buffer, int maxlen)
{
    switch (action)
    {
        case CookieMenuAction_DisplayOption:
        {
            Format(buffer, maxlen, "%t", "Display");
        }

        case CookieMenuAction_SelectOption:
        {
            Handle menu = CreateMenu(OnUserSettingsMenuEvent);

            char text[64];
            char msg[64];

            Format(text, sizeof(text), "%t", "Status");
            SetMenuTitle(menu, text);

            if (IsClientBanned(client))
            {
                // TODO: Translation
                Format(msg, sizeof(msg), "%t", "You are banned");
                AddMenuItem(menu, "banned-spray", msg, ITEMDRAW_DISABLED);
            }
            else
            {
                // TODO: Translation
                Format(msg, sizeof(msg), "%t", "You are not banned");
                AddMenuItem(menu, "banned-spray", msg, ITEMDRAW_DISABLED);
            }

            SetMenuExitBackButton(menu, true);
            SetMenuExitButton(menu, true);
            DisplayMenu(menu, client, 15);
        }
    }
}

/**
 * Process events for the submenu for this plugin in the `!settings` menu.
 **/
void OnUserSettingsMenuEvent(Handle menu, MenuAction action, int param1, int param2)
{
    // The menu created in OnUserSettingsMenu() is a default menu, which means
    // that it might receive the following MenuActions: MenuAction_Start,
    // MenuAction_Cancel, or MenuAction_End. We don't need to do anything with
    // MenuAction_Start.
    switch (action)
    {
        case MenuAction_Cancel:
        {
            if (param2 == MenuCancel_ExitBack)
            {
                ShowCookieMenu(param1);
            }
        }

        case MenuAction_End:
        {
            CloseHandle(menu);
        }
    }
}

public void OnAdminMenuReady(Handle topmenu)
{
    TopMenuObject playercmds = FindTopMenuCategory(topmenu, ADMINMENU_PLAYERCOMMANDS);
    if (playercmds == INVALID_TOPMENUOBJECT)
    {
        return;
    }

    TopMenuObject topobj;

    topobj = AddToTopMenu(topmenu, "ban-sprays-delete", TopMenuObject_Item, OnAdminDeleteSprayMenu, playercmds, _, g_config_adminflag_delete);
    if (topobj == INVALID_TOPMENUOBJECT)
    {
        LogError("Failed to create admin menu item for %s", CMD_DELETESPRAY);
        SetFailState("Failed to create admin menu item for %s", CMD_DELETESPRAY);
    }

    topobj = AddToTopMenu(topmenu, "ban-sprays-ban", TopMenuObject_Item, OnAdminBanSprayMenu, playercmds, _, g_config_adminflag_ban);
    if (topobj == INVALID_TOPMENUOBJECT)
    {
        LogError("Failed to create admin menu item for %s", CMD_BANSPRAY);
        SetFailState("Failed to create admin menu item for %s", CMD_BANSPRAY);
    }

    topobj = AddToTopMenu(topmenu, "ban-sprays-unban", TopMenuObject_Item, OnAdminUnbanSprayMenu, playercmds, _, g_config_adminflag_ban);
    if (topobj == INVALID_TOPMENUOBJECT)
    {
        LogError("Failed to create admin menu item for %s", CMD_UNBANSPRAY);
        SetFailState("Failed to create admin menu item for %s", CMD_UNBANSPRAY);
    }
}

/**
 * The `TopMenuHandler` callback function for the admin menu item to delete sprays.
 **/
void OnAdminDeleteSprayMenu(TopMenu topmenu, TopMenuAction action, TopMenuObject topobj, int admin, char[] buffer, int maxlen)
{
    switch (action)
    {
        case TopMenuAction_DisplayOption:
        {
            // TODO: Translation
            Format(buffer, maxlen, "Delete spray");
        }

        case TopMenuAction_SelectOption:
        {
            int target;
            if (GetTargetedSpray(admin, target))
            {
                DeleteSpray(admin, target);
            }
        }
    }
}

/**
 * The `TopMenuHandler` callback function for the admin menu item to ban sprays.
 **/
void OnAdminBanSprayMenu(TopMenu topmenu, TopMenuAction action, TopMenuObject topobj, int admin, char[] buffer, int maxlen)
{
    switch (action)
    {
        case TopMenuAction_DisplayOption:
        {
            // TODO: Translation
            Format(buffer, maxlen, "%s", "Ban spray");
        }

        case TopMenuAction_SelectOption:
        {
            CreateBanSprayMenu(admin);
        }
    }
}

void CreateBanSprayMenu(int admin)
{
    Handle menu = CreateMenu(OnBanSprayMenuEvent);

    // TODO: Translation
    SetMenuTitle(menu, "%s", "Ban spray");
    SetMenuExitButton(menu, true);
    SetMenuExitBackButton(menu, true);

    // TODO: Translation
    AddMenuItem(menu, ":crosshair:", ":crosshair:", ITEMDRAW_DEFAULT);
    AddMenuItem(menu, "", "", ITEMDRAW_SPACER);
    AddMenuItemTargets(menu, admin, false);

    DisplayMenu(menu, admin, MENU_TIME_FOREVER);
}

/**
 * The `MenuHandler` callback function for the submenu to ban sprays.
 **/
void OnBanSprayMenuEvent(Handle menu, MenuAction action, int admin, int param2)
{
    switch (action)
    {
        case MenuAction_Select:
        {
            int target;
            if (GetMenuItemTarget(menu, param2, admin, target))
            {
                BanSpray(admin, target);
            }
        }

        case MenuAction_Cancel:
        {
            if (param2 == MenuCancel_ExitBack)
            {
                Handle topmenu = view_as<Handle>(GetAdminTopMenu());
                DisplayTopMenu(topmenu, admin, TopMenuPosition_LastCategory);
            }
        }

        case MenuAction_End:
        {
            CloseHandle(menu);
        }
    }
}

/**
 * The `TopMenuHandler` callback function for the admin menu item to unban sprays.
 **/
void OnAdminUnbanSprayMenu(TopMenu topmenu, TopMenuAction action, TopMenuObject topobj, int admin, char[] buffer, int maxlen)
{
    switch (action)
    {
        case TopMenuAction_DisplayOption:
        {
            // TODO: Translation
            Format(buffer, maxlen, "%s", "Unban spray");
        }

        case TopMenuAction_SelectOption:
        {
            CreateUnbanSprayMenu(admin);
        }
    }
}

void CreateUnbanSprayMenu(int admin)
{
    Handle menu = CreateMenu(OnUnbanSprayMenuEvent);

    // TODO: Translation
    SetMenuTitle(menu, "%s", "Unban spray");
    SetMenuExitButton(menu, true);
    SetMenuExitBackButton(menu, true);

    AddMenuItemTargets(menu, admin, true);

    DisplayMenu(menu, admin, MENU_TIME_FOREVER);
}

/**
 * The `MenuHandler` callback function for the submenu to unban sprays.
 **/
void OnUnbanSprayMenuEvent(Handle menu, MenuAction action, int admin, int param2)
{
    switch (action)
    {
        case MenuAction_Select:
        {
            int target;
            if (GetMenuItemTarget(menu, param2, admin, target))
            {
                UnbanSpray(admin, target);
            }
        }

        case MenuAction_Cancel:
        {
            if (param2 == MenuCancel_ExitBack)
            {
                Handle topmenu = view_as<Handle>(GetAdminTopMenu());
                DisplayTopMenu(topmenu, admin, TopMenuPosition_LastCategory);
            }
        }

        case MenuAction_End:
        {
            CloseHandle(menu);
        }
    }
}

void AddMenuItemTargets(Handle menu, int admin, bool banned)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        // Do not include any invalid clients, clients who have immunity
        // from the current admin, or clients who already have the
        // status this would apply.
        if (IsClientInGame(client) &&
            !IsFakeClient(client) &&
            CanUserTarget(admin, client) &&
            (IsClientBanned(client)) == banned)
        {
            char name[MAX_NAME_LENGTH];
            GetClientName(client, name, sizeof(name));

            char userid[STEAMID64_LENGTH];
            IntToString(GetClientUserId(client), userid, sizeof(userid));

            AddMenuItem(menu, userid, name, ITEMDRAW_DEFAULT);
        }
    }
}

bool GetMenuItemTarget(Handle menu, int item, int admin, int &target)
{
    char info[STEAMID64_LENGTH];
    GetMenuItem(menu, item, info, sizeof(info));

    if (StrEqual(info, ":crosshair:"))
    {
        if (!GetTargetedSpray(admin, target))
        {
            // TODO: Translation
            PrintHintText(admin, "No targeted spray");
            return false;
        }
    }
    else
    {
        target = GetClientOfUserId(StringToInt(info));
        if (!IsValidClient(target))
        {
            // TODO: Translation
            PrintHintText(admin, "Invalid client");
            return false;
        }
    }

    return true;
}
