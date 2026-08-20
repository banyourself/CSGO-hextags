/*
 * HexTags Plugin.
 * by: Hexah
 * https://github.com/Hexer10/HexTags
 * 
 * Copyright (C) 2017-2020 Mattia (Hexah|Hexer10|Papero)
 *
 * This file is part of the HexTags SourceMod Plugin.
 *
 * This program is free software; you can redistribute it and/or modify it under
 * the terms of the GNU General Public License, version 3.0, as published by the
 * Free Software Foundation.
 * 
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE. See the GNU General Public License for more
 * details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program. If not, see <http://www.gnu.org/licenses/>.
 */
//#define DEBUG 0

#include <sourcemod>
#include <sdktools>

#undef REQUIRE_EXTENSIONS
#include <cstrike>
#define REQUIRE_EXTENSIONS

#include <chat-processor>
#include <geoip>
#include <hextags>
#include <clientprefs>

#define PLUGIN_AUTHOR         "Hexah + Kevin"
#define PLUGIN_VERSION        "2.09"

#pragma semicolon 1
#pragma newdecls required


PrivateForward pfCustomSelector;

Handle fTagsUpdated;
Handle fMessageProcess;
Handle fMessageProcessed;
Handle fMessagePreProcess;
Cookie g_hVisibilityCookie;
Cookie g_hSelectionCookie;
Cookie g_hLegacySelectionCookie;

ConVar cv_bParseRoundEnd;
ConVar cv_bEnableTagsList;
ConVar cv_fForceTagInterval;
ConVar cv_bAdminOnly;

Handle g_hForceTagTimer;

bool bLate;
bool bHideTag[MAXPLAYERS+1];
bool bHasRoundEnded;
bool bTagsAuthorized[MAXPLAYERS+1];
bool bTagsCookiesReady[MAXPLAYERS+1];

int iNextDefTag;

char sUserTag[MAXPLAYERS+1][64];
// Prefixes owned by another plugin (hnsmix pushes the elo rank tag here). Kept separate
// from the config tag so a reload cannot lose them and re-applying cannot double up.
char sExtScorePrefix[MAXPLAYERS+1][64];
char sExtChatPrefix[MAXPLAYERS+1][64];
// KeyValues section symbols are shared by duplicate selector names, so keep the unique tag name.
char sSelectedTagName[MAXPLAYERS+1][32];
char sTagConf[PLATFORM_MAX_PATH];
char sCountryCode[MAXPLAYERS+1][3];

ArrayList userTags[MAXPLAYERS+1];
CustomTags selectedTags[MAXPLAYERS+1];
KeyValues tagsKv;


//Plugin info
public Plugin myinfo =
{
	name = "hextags",
	author = PLUGIN_AUTHOR,
	description = "Edit Tags & Colors!",
	version = PLUGIN_VERSION,
	url = "github.com/Hexer10/HexTags"
};

//Startup
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	if (GetEngineVersion() != Engine_CSGO)
	{
		strcopy(error, err_max, "HexTags is configured for CS:GO only.");
		return APLRes_Failure;
	}

	//API
	RegPluginLibrary("hextags");
	
	CreateNative("HexTags_GetClientTag", Native_GetClientTag);
	CreateNative("HexTags_SetClientTag", Native_SetClientTag);
	CreateNative("HexTags_SetClientPrefix", Native_SetClientPrefix);
	CreateNative("HexTags_ResetClientTag", Native_ResetClientTags);
	CreateNative("HexTags_AddCustomSelector", Native_AddCustomSelector);
	CreateNative("HexTags_RemoveCustomSelector", Native_RemoveCustomSelector);
	
	fTagsUpdated = new GlobalForward("HexTags_OnTagsUpdated", ET_Ignore, Param_Cell);
	
	fMessageProcess = new GlobalForward("HexTags_OnMessageProcess", ET_Single, Param_Cell, Param_String, Param_String);
	fMessageProcessed = new GlobalForward("HexTags_OnMessageProcessed", ET_Ignore, Param_Cell, Param_String, Param_String);
	fMessagePreProcess = new GlobalForward("HexTags_OnMessagePreProcess", ET_Single, Param_Cell, Param_String, Param_String);
	
	pfCustomSelector = new PrivateForward(ET_Single, Param_Cell, Param_String);
	
	//LateLoad
	bLate = late;
	return APLRes_Success;
}

//TODO: Cache client ip instead of getting it every time.
public void OnPluginStart()
{
	//ConVars
	CreateConVar("sm_hextags_version", PLUGIN_VERSION, "HexTags plugin version", FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY);
	cv_bParseRoundEnd = CreateConVar("sm_hextags_roundend", "0", "If 1, reload tags on round end.");
	cv_bEnableTagsList = CreateConVar("sm_hextags_enable_tagslist", "1", "Set to 1 to enable !tagslist, !tags, and !hextags.");
	cv_fForceTagInterval = CreateConVar("sm_hextags_timer_interval", "5.0", "Seconds between forced clan-tag checks. Set to 0 to disable checks.", _, true, 0.0);
	cv_fForceTagInterval.AddChangeHook(OnForceTagIntervalChanged);
	cv_bAdminOnly = CreateConVar("sm_hextags_admin_only", "1", "If 1, !tags/!tagslist/!hextags/!getteam require the 'b' (generic) admin flag. 0 lets everyone use them.", _, true, 0.0, true, 1.0);

	AutoExecConfig();

	//Reg Cmds
	RegAdminCmd("sm_reloadtags", Cmd_ReloadTags, ADMFLAG_GENERIC, "Reload HexTags plugin config");
	RegAdminCmd("sm_toggletags", Cmd_ToggleTags, ADMFLAG_GENERIC, "Toggle the visibility of your tags");
	RegAdminCmd("sm_resetalltags", Cmd_ResetAllTags, ADMFLAG_GENERIC, "Reset every connected player's selected tag back to None");
	RegConsoleCmd("sm_tagslist", Cmd_TagsList, "Select your tag!");
	RegConsoleCmd("sm_tags", Cmd_TagsList, "Select your tag!");
	RegConsoleCmd("sm_hextags", Cmd_TagsList, "Select your tag!");
	RegConsoleCmd("sm_getteam", Cmd_GetTeam, "Get current team name");
	
	//Event hooks
	if (!HookEventEx("round_end", Event_RoundEnd))
	LogError("Failed to hook \"round_end\", \"sm_hextags_roundend\" won't produce any effect.");
	HookEvent("round_start", Event_RoundStart);
	
	g_hVisibilityCookie = RegClientCookie("HexTags_Visibility", "Show or hide the tags.", CookieAccess_Private);
	// Do not reuse the legacy selector cookie: older builds stored a KeyValues symbol, which
	// is not stable when the config has duplicate selectors such as several z blocks.
	g_hSelectionCookie = RegClientCookie("HexTags_SelectionV2", "Selected HexTags tag.", CookieAccess_Private);
	g_hLegacySelectionCookie = RegClientCookie("HexTags_SelectedTag", "Legacy HexTags selected tag.", CookieAccess_Private);
	
#if defined DEBUG
	RegConsoleCmd("sm_gettagvars", Cmd_GetVars);
	RegConsoleCmd("sm_firesel", Cmd_FireSel);
#endif
}

public void OnAllPluginsLoaded()
{	
	Debug_Print("Called OnAllPlugins!");
	
	if (FindPluginByFile("custom-chatcolors-cp.smx") || LibraryExists("ccc"))
	LogMessage("[HexTags] Found Custom Chat Colors running!\n	Please avoid running it with this plugin!");
	
	LoadKv();
	if (bLate) for (int i = 1; i <= MaxClients; i++)if (IsClientInGame(i)) 
	{
		OnClientPutInServer(i);
		if (AreClientCookiesCached(i))
			OnClientCookiesCached(i);
		
		OnClientPostAdminCheck(i);
	}
	ResetForceTagTimer();
}

public void OnConfigsExecuted()
{
	ResetForceTagTimer();
}

public void OnPluginEnd()
{
	// SourceMod destroys plugin-owned timers on unload; closing here races that and yields an invalid handle.
	g_hForceTagTimer = null;
}

public void OnForceTagIntervalChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	ResetForceTagTimer();
}

void ResetForceTagTimer()
{
	delete g_hForceTagTimer;
	float interval = cv_fForceTagInterval.FloatValue;
	if (interval > 0.0)
		// No TIMER_FLAG_NO_MAPCHANGE: SM frees those at map end without clearing our handle, leaving a stale one.
		g_hForceTagTimer = CreateTimer(interval, Timer_ForceTag, _, TIMER_REPEAT);
}

//Thanks to https://forums.alliedmods.net/showpost.php?p=2573907&postcount=6
public Action OnClientCommandKeyValues(int client, KeyValues kv)
{
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
		return Plugin_Continue;

	if (bHideTag[client])
		return Plugin_Continue;
	
	char sKey[64];
	
	if (!kv.GetSectionName(sKey, sizeof(sKey)))
	return Plugin_Continue;
	
#if defined DEBUG
	char sKV[256];
	kv.ExportToString(sKV, sizeof(sKV));
	Debug_Print("Called ClientCmdKv: %s\n%s\n", sKey, sKV);
#endif
	
	if(StrEqual(sKey, "ClanTagChanged"))
	{
		kv.GetString("tag", sUserTag[client], sizeof(sUserTag[]));

		// Force=0 means another plugin or the player may own the clan tag, so do not reload - it would set it again.
		if (!HasManagedScoreTag(client))
			return Plugin_Continue;

		TryLoadTags(client);
		if (!HasManagedScoreTag(client))
			return Plugin_Continue;

		char sEffective[96];
		GetEffectiveScoreTag(client, sEffective, sizeof(sEffective));
		kv.SetString("tag", sEffective);
		Debug_Print("[ClanTagChanged] Setted tag: %s ", sEffective);
		return Plugin_Changed;
	}
	
	return Plugin_Continue; 
}

public void OnClientDisconnect(int client)
{
	ResetTags(client);
	sSelectedTagName[client][0] = '\0';
	bHideTag[client] = false;
	bTagsAuthorized[client] = false;
	bTagsCookiesReady[client] = false;
	sUserTag[client][0] = '\0';
	sCountryCode[client][0] = '\0';
	// A prefix belongs to the occupant who is leaving, so this is where it goes.
	sExtScorePrefix[client][0] = '\0';
	sExtChatPrefix[client][0] = '\0';
	delete userTags[client];
}

//Commands
public Action Cmd_ReloadTags(int client, int args)
{
	LoadKv();
	for (int i = 1; i <= MaxClients; i++)if (IsClientInGame(i))TryLoadTags(i);
	
	ReplyToCommand(client, "[SM] Tags succesfully reloaded!");
	return Plugin_Handled;
}

public Action Cmd_ToggleTags(int client, int args)
{
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		ReplyToCommand(client, "[SM] In-game only command.");
		return Plugin_Handled;
	}
	if (!bTagsCookiesReady[client])
	{
		ReplyToCommand(client, "[SM] Tag preferences are still loading. Try again in a moment.");
		return Plugin_Handled;
	}

	if (bHideTag[client])
	{
		bHideTag[client] = false;
		TryLoadTags(client);
		ReplyToCommand(client, "[SM] Your tags are visible again.");
	} 
	else
	{
		bHideTag[client] = true;
		CS_SetClientClanTag(client, sUserTag[client]);
		ReplyToCommand(client, "[SM] Your tags are no longer visible.");
	}
	
	if (AreClientCookiesCached(client))
		g_hVisibilityCookie.Set(client, bHideTag[client] ? "0" : "1");
	return Plugin_Handled;
}

public Action Cmd_TagsList(int client, int args)
{
	if (!client)
	{
		ReplyToCommand(client, "[SM] In-game only command.");
		return Plugin_Handled;
	}
	if (!bTagsCookiesReady[client])
	{
		ReplyToCommand(client, "[SM] Tag preferences are still loading. Try again in a moment.");
		return Plugin_Handled;
	}
	
	if (userTags[client] == null)
	{
		ReplyToCommand(client, "[SM] Tags not yet loaded.");
		return Plugin_Handled;
	}
	
	if (!cv_bEnableTagsList.BoolValue)
	{
		ReplyToCommand(client, "[SM] This feature is not enabled.");
		return Plugin_Handled;
	}

	if (!HasTagsCommandAccess(client))
	{
		ReplyToCommand(client, "[SM] Tag selection is currently admin-only.");
		return Plugin_Handled;
	}

	if (userTags[client].Length == 0)
	{
		ReplyToCommand(client, "[SM] No tags available.");
		return Plugin_Handled;
	}
	
	Menu menu = new Menu(Handler_TagsMenu);
	menu.SetTitle("Choose your tag:");
	static char sIndex[16];
	int len = userTags[client].Length;
	CustomTags tags;
	for (int i = 0; i < len; i++)
	{
		userTags[client].GetArray(i, tags, sizeof(tags));
		IntToString(i, sIndex, sizeof(sIndex));
		menu.AddItem(sIndex, tags.TagName);
	}
	menu.Display(client, MENU_TIME_FOREVER);
	return Plugin_Handled;
}

public int Handler_TagsMenu(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		if (param1 < 1 || param1 > MaxClients || !IsClientInGame(param1) || !bTagsCookiesReady[param1])
			return 0;

		static char sIndex[16];
		menu.GetItem(param2, sIndex, sizeof(sIndex));
		int iTag = StringToInt(sIndex);
		// The menu can outlive a !hextags_reload that shrank this client's list.
		if (userTags[param1] == null || iTag < 0 || iTag >= userTags[param1].Length)
		{
			PrintToChat(param1, "[SM] Tags were reloaded, please reopen the list.");
			return 0;
		}
		CustomTags selectedTag;
		userTags[param1].GetArray(iTag, selectedTag, sizeof(selectedTag));
		SaveSelectedTag(param1, selectedTag.TagName);
		ApplySelectedTag(param1, selectedTag);
		PrintToChat(param1, "[SM] Set %s tag.", selectedTag.TagName);
	}
	return 0;
}

// sm_hextags_admin_only gate for the RegConsoleCmd entries; RegAdminCmd ones are already gated by SourceMod.
bool HasTagsCommandAccess(int client)
{
	if (!cv_bAdminOnly.BoolValue)
		return true;
	if (client == 0)
		return true; // server console
	return CheckCommandAccess(client, "sm_hextags_tagslist", ADMFLAG_GENERIC, false);
}

// Force one client onto the explicit None tag and persist it, so a Force=1 selector cannot re-grant next map.
bool ApplyNoneTag(int client)
{
	if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
		return false;

	if (userTags[client] != null)
	{
		CustomTags tags;
		int length = userTags[client].Length;
		for (int i = 0; i < length; i++)
		{
			userTags[client].GetArray(i, tags, sizeof(tags));
			if (StrEqual(tags.TagName, "None", false))
			{
				SaveSelectedTag(client, tags.TagName);
				ApplySelectedTag(client, tags);
				return true;
			}
		}
	}

	// No "None" entry in the config - strip the tag outright instead.
	ClearSelectedTag(client);
	ResetTags(client);
	CS_SetClientClanTag(client, "");
	return true;
}

public Action Cmd_ResetAllTags(int client, int args)
{
	int count = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (ApplyNoneTag(i))
			count++;
	}

	ReplyToCommand(client, "[SM] Reset %d player%s to the None tag.", count, count == 1 ? "" : "s");
	LogAction(client, -1, "\"%L\" reset every player's HexTags selection to None.", client);
	return Plugin_Handled;
}

public Action Cmd_GetTeam(int client, int args)
{
	if (!client)
	{
		ReplyToCommand(client, "[SM] In-game only command.");
		return Plugin_Handled;
	}

	if (!HasTagsCommandAccess(client))
	{
		ReplyToCommand(client, "[SM] This command is currently admin-only.");
		return Plugin_Handled;
	}

	char sTeam[32];
	GetTeamName(GetClientTeam(client), sTeam, sizeof(sTeam));
	ReplyToCommand(client, "[SM] Current team name: %s", sTeam);
	return Plugin_Handled;
}

#if defined DEBUG
public Action Cmd_GetVars(int client, int args)
{
	ReplyToCommand(client, selectedTags[client].ScoreTag);
	ReplyToCommand(client, selectedTags[client].ChatTag);
	ReplyToCommand(client, selectedTags[client].ChatColor);
	ReplyToCommand(client, selectedTags[client].NameColor);
	return Plugin_Handled;
}

public Action Cmd_FireSel(int client, int args)
{
	int count = pfCustomSelector.FunctionCount;
	int res;
	
	Call_StartForward(pfCustomSelector);
	Call_PushCell(client);
	Call_PushString("thistoggle");
	Call_Finish(res);
	ReplyToCommand(client, "[SM] Fire %i functions, res: %i!", count, res);
	return Plugin_Handled;
}
#endif

//Events
public void OnClientPutInServer(int client)
{
	delete userTags[client];
	userTags[client] = new ArrayList(sizeof(CustomTags));
	ResetTags(client);
	CS_SetClientClanTag(client, "");
	// External prefixes are NOT cleared here. OnClientPostAdminCheck fires BEFORE
	// OnClientPutInServer, so a plugin pushing a prefix from post-admin-check (hnsmix does,
	// off an async elo query) can already have set one; clearing it left the player on their
	// Steam clan tag for the session. The slot is emptied in OnClientDisconnect instead.
	sSelectedTagName[client][0] = '\0';
	bHideTag[client] = false;
	CacheClientCountry(client);
	// Do not parse selectors before SourceMod resolves admin flags, or the tag list is built wrong.
	bTagsAuthorized[client] = false;
	bTagsCookiesReady[client] = false;

	// The callback is not guaranteed to repeat after a late load. Read cached state here, but
	// still wait for OnClientPostAdminCheck before applying a tag.
	if (AreClientCookiesCached(client))
		LoadClientCookieState(client);
}

public void OnClientPostAdminCheck(int client)
{
	bTagsAuthorized[client] = true;
	if (AreClientCookiesCached(client))
		LoadClientCookieState(client);
	TryLoadTags(client);
}

public void OnClientCookiesCached(int client)
{
	LoadClientCookieState(client);
	TryLoadTags(client);
}

void LoadClientCookieState(int client)
{
	if (client < 1 || client > MaxClients || !IsClientConnected(client))
		return;
	if (!AreClientCookiesCached(client))
		return;

	char sValue[64];
	g_hVisibilityCookie.Get(client, sValue, sizeof(sValue));
	
	bHideTag[client] = sValue[0] == '\0' ? false : !StringToInt(sValue);

	// Version two stores a tag name, not a KeyValues symbol: stable across map changes and
	// reloads even with duplicate selector names. The old cookie is read once for migration.
	g_hSelectionCookie.Get(client, sValue, sizeof(sValue));
	sSelectedTagName[client][0] = '\0';
	if (StrContains(sValue, "v2:", false) == 0)
	{
		strcopy(sSelectedTagName[client], sizeof(sSelectedTagName[]), sValue);
		ReplaceString(sSelectedTagName[client], sizeof(sSelectedTagName[]), "v2:", "", false);
	}
	else
	{
		if (sValue[0] != '\0')
			g_hSelectionCookie.Set(client, "");

		g_hLegacySelectionCookie.Get(client, sValue, sizeof(sValue));
		if (StrContains(sValue, "tag:", false) == 0)
		{
			strcopy(sSelectedTagName[client], sizeof(sSelectedTagName[]), sValue);
			ReplaceString(sSelectedTagName[client], sizeof(sSelectedTagName[]), "tag:", "", false);
			SaveSelectedTag(client, sSelectedTagName[client]);
		}

		// Remove the obsolete cookie even when invalid, so it can never override a future V2 selection.
		g_hLegacySelectionCookie.Set(client, "");
	}
	bTagsCookiesReady[client] = true;
}

void SaveSelectedTag(int client, const char[] tagName)
{
	if (client < 1 || client > MaxClients || !AreClientCookiesCached(client))
		return;

	strcopy(sSelectedTagName[client], sizeof(sSelectedTagName[]), tagName);

	char sValue[40];
	FormatEx(sValue, sizeof(sValue), "v2:%s", sSelectedTagName[client]);
	g_hSelectionCookie.Set(client, sValue);
	// Stop a legacy value being re-imported after the player explicitly chooses a tag, or None.
	g_hLegacySelectionCookie.Set(client, "");
}

void ClearSelectedTag(int client)
{
	if (client < 1 || client > MaxClients)
		return;

	sSelectedTagName[client][0] = '\0';
	if (!AreClientCookiesCached(client))
		return;

	g_hSelectionCookie.Set(client, "");
	g_hLegacySelectionCookie.Set(client, "");
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	bHasRoundEnded = true;
	if (!cv_bParseRoundEnd.BoolValue)
	return;

	for (int i = 1; i <= MaxClients; i++)if (IsClientInGame(i))TryLoadTags(i);
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	bHasRoundEnded = false;
}

public Action CP_OnChatMessage(int& author, ArrayList recipients, char[] flagstring, char[] name, char[] message, bool& processcolors, bool& removecolors)
{
	Debug_Setup(true, false, false, true); // Disable chat.
	if (bHideTag[author])
	{
		return Plugin_Continue;
	}
	
	Action result = Plugin_Continue;
	//Call the forward
	Call_StartForward(fMessagePreProcess);
	Call_PushCell(author);
	Call_PushStringEx(name, MAXLENGTH_NAME, SM_PARAM_STRING_UTF8|SM_PARAM_STRING_COPY, SM_PARAM_COPYBACK);
	Call_PushStringEx(message, MAXLENGTH_MESSAGE, SM_PARAM_STRING_UTF8|SM_PARAM_STRING_COPY, SM_PARAM_COPYBACK);
	Call_Finish(result);
	
	if (result >= Plugin_Handled)
	{
		return Plugin_Continue;
	}
	
	//Add colors & tags
	char sNewName[MAXLENGTH_NAME];
	char sNewMessage[MAXLENGTH_MESSAGE];
	char sChatTag[128];
	GetEffectiveChatTag(author, sChatTag, sizeof(sChatTag));
	// Rainbow name
	if (StrEqual(selectedTags[author].NameColor, "{rainbow}"))
	{
		Debug_Print("Rainbow name");
		char sTemp[MAXLENGTH_MESSAGE]; 
		
		int color;
		int len = strlen(name);
		for(int i = 0; i < len; i++)
		{
			if (IsCharSpace(name[i]))
			{
				Format(sTemp, sizeof(sTemp), "%s%c", sTemp, name[i]);
				continue;
			}
			
			int bytes = GetCharBytes(name[i])+1;
			char[] c = new char[bytes];
			strcopy(c, bytes, name[i]);
			Format(sTemp, sizeof(sTemp), "%s%c%s", sTemp, GetColor(++color), c);
			if (IsCharMB(name[i]))
			i += bytes-2;
		}		
		Format(sNewName, MAXLENGTH_NAME, "%s%s{default}", sChatTag, sTemp);
	}
	else if (StrEqual(selectedTags[author].NameColor, "{random}")) //Random name
	{
		Debug_Print("Random name");
		char sTemp[MAXLENGTH_MESSAGE]; 
		
		int len = strlen(name);
		for(int i = 0; i < len; i++)
		{
			if (IsCharSpace(name[i]))
			{
				Format(sTemp, sizeof(sTemp), "%s%c", sTemp, name[i]);
				continue;
			}
			
			int bytes = GetCharBytes(name[i])+1;
			char[] c = new char[bytes];
			strcopy(c, bytes, name[i]);
			Format(sTemp, sizeof(sTemp), "%s%c%s", sTemp, GetRandomColor(), c);
			if (IsCharMB(name[i]))
			i += bytes-2;
		}		
		Format(sNewName, MAXLENGTH_NAME, "%s%s{default}", sChatTag, sTemp);
	}
	else
	{
		Debug_Print("Default name");
		Format(sNewName, MAXLENGTH_NAME, "%s%s%s{default}", sChatTag, selectedTags[author].NameColor, name);
	}
	Format(sNewMessage, MAXLENGTH_MESSAGE, "%s%s", selectedTags[author].ChatColor, message);
	
	//Update the params
	static char sTime[16];
	FormatTime(sTime, sizeof(sTime), "%H:%M");  
	ReplaceString(sNewName, sizeof(sNewName), "{time}", sTime);
	ReplaceString(sNewMessage, sizeof(sNewMessage), "{time}", sTime);
	
	
	ReplaceString(sNewName, sizeof(sNewName), "{country}", sCountryCode[author]);
	ReplaceString(sNewMessage, sizeof(sNewMessage), "{country}", sCountryCode[author]);
	
	//Rainbow Chat
	if (StrEqual(selectedTags[author].ChatColor, "{rainbow}", false))
	{
		Debug_Print("Rainbow chat");
		ReplaceString(sNewMessage, sizeof(sNewMessage), "{rainbow}", "");
		char sTemp[MAXLENGTH_MESSAGE]; 
		
		int color;
		int len = strlen(sNewMessage);
		for(int i = 0; i < len; i++)
		{
			if (IsCharSpace(sNewMessage[i]))
			{
				Format(sTemp, sizeof(sTemp), "%s%c", sTemp, sNewMessage[i]);
				continue;
			}
			
			int bytes = GetCharBytes(sNewMessage[i])+1;
			char[] c = new char[bytes];
			strcopy(c, bytes, sNewMessage[i]);
			Format(sTemp, sizeof(sTemp), "%s%c%s", sTemp, GetColor(++color), c);
			if (IsCharMB(sNewMessage[i]))
			i += bytes-2;
		}		
		Format(sNewMessage, MAXLENGTH_MESSAGE, "%s", sTemp); 
	}
	
	//Random Chat
	if (StrEqual(selectedTags[author].ChatColor, "{random}", false))
	{
		Debug_Print("Random chat");
		ReplaceString(sNewMessage, sizeof(sNewMessage), "{random}", "");
		char sTemp[MAXLENGTH_MESSAGE]; 
		
		int len = strlen(sNewMessage);
		for(int i = 0; i < len; i++)
		{
			if (IsCharSpace(sNewMessage[i]))
			{
				Format(sTemp, sizeof(sTemp), "%s%c", sTemp, sNewMessage[i]);
				continue;
			}
			
			int bytes = GetCharBytes(sNewMessage[i])+1;
			char[] c = new char[bytes];
			strcopy(c, bytes, sNewMessage[i]);
			Format(sTemp, sizeof(sTemp), "%s%c%s", sTemp, GetRandomColor(), c);
			if (IsCharMB(sNewMessage[i]))
			i += bytes-2;
		}		
		Format(sNewMessage, MAXLENGTH_MESSAGE, "%s", sTemp); 
	}
	
	static char sPassedName[MAXLENGTH_NAME];
	static char sPassedMessage[MAXLENGTH_MESSAGE];
	sPassedName = sNewName;
	sPassedMessage = sNewMessage;
	
	
	result = Plugin_Continue;
	//Call the forward
	Call_StartForward(fMessageProcess);
	Call_PushCell(author);
	Call_PushStringEx(sPassedName, sizeof(sPassedName), SM_PARAM_STRING_UTF8|SM_PARAM_STRING_COPY, SM_PARAM_COPYBACK);
	Call_PushStringEx(sPassedMessage, sizeof(sPassedMessage), SM_PARAM_STRING_UTF8|SM_PARAM_STRING_COPY, SM_PARAM_COPYBACK);
	Call_Finish(result);

	if (result == Plugin_Continue)
	{
    	//Update the name & message
		strcopy(name, MAXLENGTH_NAME, sNewName);
		strcopy(message, MAXLENGTH_MESSAGE, sNewMessage);
	}
	else if (result == Plugin_Changed)
	{
    	//Update the name & message
		strcopy(name, MAXLENGTH_NAME, sPassedName);
		strcopy(message, MAXLENGTH_MESSAGE, sPassedMessage);
	}
	else
	{
		Debug_Setup();
		return Plugin_Continue;
	}
	
	processcolors = true;
	removecolors = false;
	
	//Call the (post)forward
	Call_StartForward(fMessageProcessed);
	Call_PushCell(author);
	Call_PushString(sPassedName);
	Call_PushString(sPassedMessage);
	Call_Finish();
	
	
	Debug_Print("Message sent");
	Debug_Setup();
	return Plugin_Changed;
}

//Functions
void LoadKv()
{
	static char sConfig[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sConfig, sizeof(sConfig), "configs/hextags.cfg"); //Get cfg file
	
	File configFile = OpenFile(sConfig, "rt");
	if (configFile == null)
		SetFailState("Couldn't find: \"%s\"", sConfig); //Check if cfg exist
	delete configFile;
	
	KeyValues kv = new KeyValues("HexTags"); //Create the kv
	
	if (!kv.ImportFromFile(sConfig))
		SetFailState("Couldn't import: \"%s\"", sConfig); //Check if file was imported properly
	
	if (!kv.GotoFirstSubKey())
		LogMessage("No entries found in: \"%s\"", sConfig); //Notify that there aren't any entries
	
	delete kv;
	strcopy(sTagConf, sizeof(sTagConf), sConfig);
	delete tagsKv;
}

void LoadTags(int client)
{
	if (bHideTag[client])
		return;
	
	if (!IsValidClient(client, true, true))
		return;
	
	//Clear the tags when re-checking
	ResetTags(client);
	
	if (tagsKv == null)
	{
		tagsKv = new KeyValues("HexTags");
		tagsKv.ImportFromFile(sTagConf);
		Debug_Print("KeyValue handle: %i", tagsKv);
	}
	tagsKv.Rewind();
	if (userTags[client] == null)
	{
		userTags[client] = new ArrayList(sizeof(CustomTags));
	}
	// Keep fallback names stable across reloads so an omitted TagName cannot invalidate a saved cookie.
	iNextDefTag = 0;
	ParseConfig(tagsKv, client);
	
	SelectClientTag(client);
}

// A player's saved choice always wins, so a first matching selector such as the first z
// entry cannot replace a selected DEV tag on map change. Without a saved choice the first
// matching Force=1 entry is used, otherwise the explicit empty None tag.
void SelectClientTag(int client)
{
	if (userTags[client] == null || userTags[client].Length == 0)
	{
		ResetTags(client);
		CS_SetClientClanTag(client, "");
		return;
	}

	int length = userTags[client].Length;
	CustomTags tags;

	// A saved tag stays valid while the menu is disabled: the menu cvar controls command access only.
	if (sSelectedTagName[client][0] != '\0')
	{
		for (int i = 0; i < length; i++)
		{
			userTags[client].GetArray(i, tags, sizeof(tags));
			if (StrEqual(tags.TagName, sSelectedTagName[client], false))
			{
				ApplySelectedTag(client, tags);
				return;
			}
		}

		// The selection no longer exists in hextags.cfg.
		ClearSelectedTag(client);
	}

	for (int i = 0; i < length; i++)
	{
		userTags[client].GetArray(i, tags, sizeof(tags));
		if (tags.ForceTag)
		{
			ApplySelectedTag(client, tags);
			return;
		}
	}

	for (int i = 0; i < length; i++)
	{
		userTags[client].GetArray(i, tags, sizeof(tags));
		if (StrEqual(tags.TagName, "None", false))
		{
			ApplySelectedTag(client, tags);
			return;
		}
	}

	// A configuration without a None entry must never silently grant its first tag.
	ResetTags(client);
	CS_SetClientClanTag(client, "");
}

void ApplySelectedTag(int client, CustomTags tags)
{
	selectedTags[client] = tags;

	char sTag[96];
	GetEffectiveScoreTag(client, sTag, sizeof(sTag));
	CS_SetClientClanTag(client, sTag);

	Call_StartForward(fTagsUpdated);
	Call_PushCell(client);
	Call_Finish();
}

// HexTags_SetClientPrefix(client, ScoreTag|ChatTag, prefix) - stored beside the config tag,
// so a reload keeps the prefix and re-applying cannot double it. Only ScoreTag and ChatTag.
public int Native_SetClientPrefix(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);

	if (client < 1 || client > MaxClients)
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index (%d)", client);
	}
	if (!IsClientConnected(client))
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Client %d is not connected", client);
	}

	char sPrefix[64];
	GetNativeString(3, sPrefix, sizeof(sPrefix));
	// {white} is not a supported chat-processor token here, so treat old external prefixes as {default}.
	ReplaceString(sPrefix, sizeof(sPrefix), "{white}", "{default}", false);
	ReplaceString(sPrefix, sizeof(sPrefix), "{darkgray}", "{gray2}");

	switch (view_as<eTags>(GetNativeCell(2)))
	{
		case (ScoreTag):
		{
			strcopy(sExtScorePrefix[client], sizeof(sExtScorePrefix[]), sPrefix);
			RefreshClanTag(client);
		}
		case (ChatTag):
		{
			strcopy(sExtChatPrefix[client], sizeof(sExtChatPrefix[]), sPrefix);
		}
	}
	return 0;
}

// Is HexTags responsible for this client's clan tag? Either the config forced a ScoreTag or
// another plugin pushed an external prefix. Without the second half a player on the None
// tag is skipped by the force timer, so an external prefix is set once then lost.
bool HasManagedScoreTag(int client)
{
	if (sExtScorePrefix[client][0] != '\0')
		return true;
	return (selectedTags[client].ForceTag && selectedTags[client].ScoreTag[0] != '\0');
}

// The scoreboard clan tag as the engine should see it: external prefix first, then the config tag.
void GetEffectiveScoreTag(int client, char[] buffer, int maxlength)
{
	FormatEx(buffer, maxlength, "%s%s", sExtScorePrefix[client], selectedTags[client].ScoreTag);
}

void GetEffectiveChatTag(int client, char[] buffer, int maxlength)
{
	FormatEx(buffer, maxlength, "%s%s", sExtChatPrefix[client], selectedTags[client].ChatTag);
}

// Re-push the clan tag after an external prefix changes. Safe with no config tag: the prefix alone is valid.
void RefreshClanTag(int client)
{
	if (client < 1 || client > MaxClients || !IsClientInGame(client) || bHideTag[client])
		return;

	char sTag[96];
	GetEffectiveScoreTag(client, sTag, sizeof(sTag));
	CS_SetClientClanTag(client, sTag);
}

void ParseConfig(KeyValues kv, int client)
{
	userTags[client].Clear();
	kv.Rewind();
	if (!kv.GotoFirstSubKey())
		return;

	do
	{
		ParseConfigEntry(kv, client);
	} while (kv.GotoNextKey());
}

void ParseConfigEntry(KeyValues kv, int client)
{
	char sSectionName[64];
	kv.GetSectionName(sSectionName, sizeof(sSectionName));
	if (!CheckSelector(sSectionName, client))
		return;

	// A selector can nest selector blocks, so clear the client's list once in ParseConfig, not per block.
	if (kv.GotoFirstSubKey())
	{
		do
		{
			ParseConfigEntry(kv, client);
		} while (kv.GotoNextKey());
		kv.GoBack();
		return;
	}

	GetTags(client, kv);
}

bool CheckSelector(const char[] selector, int client)
{
	/* CHECK DEFAULT */
	if (StrEqual(selector, "default", false))
	{
		return true;
	}
	
	/* CHECK STEAMID */
	if(strlen(selector) > 11 && StrContains(selector, "STEAM_", true) == 0)
	{
		char steamid[32];
		if (!GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid)))
			return false;
		
		if (StrEqual(steamid, selector)) 
		{
			return true;
		}
		
			//Replace the STEAM_1 to STEAM_0 or viceversa
		(steamid[6] == '1') ? (steamid[6] = '0') : (steamid[6] = '1');
		if (StrEqual(steamid, selector)) 
		{
			return true;
		}
	}
	
	
	/* PERMISSIONS RELATED CHECKS */
	AdminId admin = GetUserAdmin(client);
	if (admin != INVALID_ADMIN_ID)
	{
		
		Debug_Print("Found as admin! %N", client);
		/* CHECK ADMIN GROUP */
		if (selector[0] == '@')
		{
			Debug_Print("Check group: %s",selector);
			static char sGroup[32];
			
			GroupId group = admin.GetGroup(0, sGroup, sizeof(sGroup));
			if (group != INVALID_GROUP_ID)
			{
				if (StrEqual(selector[1], sGroup))
				{
					return true;
				}
			}
		}
		
		/* CHECK ADMIN FLAGS (1)*/
		if (strlen(selector) == 1)
		{
			Debug_Print("Check for flag (1char): ",selector);
			AdminFlag flag;
			if (FindFlagByChar(CharToLower(selector[0]), flag))
			{
				if (admin.HasFlag(flag))
				{
					return true;
				}
			}
		}
		
		/* CHECK ADMIN FLAGS (2)*/
		if (selector[0] == '&')
		{
			Debug_Print("Check group: %s",selector);
			for (int i = 1; i < strlen(selector); i++)
			{
				AdminFlag flag;
				if (FindFlagByChar(selector[i], flag))
				{
					if (admin.HasFlag(flag))
					{
						return true;
					}
				}
			}
		}
		Debug_Print("Unmatched admin: %s", selector);
	}
	
	/* CHECK PLAYER TEAM */
	int team = GetClientTeam(client);
	static char sTeam[32];
	
	GetTeamName(team, sTeam, sizeof(sTeam));
	if (StrEqual(sTeam, selector))
	{
		return true;
	}
	

	bool res = false;
	
	Call_StartForward(pfCustomSelector);
	Call_PushCell(client);
	Call_PushString(selector);
	Call_Finish(res);
	
	return res;
}

//Timers
public Action Timer_ForceTag(Handle timer)
{
	for (int i = 1; i <= MaxClients; i++)if (IsClientInGame(i) && HasManagedScoreTag(i) && !bHideTag[i])
	{
		char sWant[96];
		GetEffectiveScoreTag(i, sWant, sizeof(sWant));

		char sTag[96];
		CS_GetClientClanTag(i, sTag, sizeof(sTag));
		if (StrEqual(sTag, sWant))
		continue;

		if (!bHasRoundEnded){
			LogMessage("%L was changed by an external plugin, forcing him back to the HexTags' default one!", i, sTag);
		}

		CS_SetClientClanTag(i, sWant);
	}
	return Plugin_Continue;
}

void CacheClientCountry(int client)
{
	sCountryCode[client][0] = '\0';
	char address[64];
	if (!GetClientIP(client, address, sizeof(address)) || !GeoipCode2(address, sCountryCode[client]))
		strcopy(sCountryCode[client], sizeof(sCountryCode[]), "??");
}

//Frames
public void Frame_LoadTag(any client)
{
	TryLoadTags(client);
}

// Cookie loading and admin authorization arrive independently. Loading tags before both are
// ready overwrote the saved selection, which is why tags appeared to reset after reconnects.
void TryLoadTags(int client)
{
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
		return;
	if (!bTagsAuthorized[client] || !bTagsCookiesReady[client])
		return;
	LoadTags(client);
}

//Stocks
// HexTags' upstream debug helpers came from a private include; keep debug off in this standalone build.
stock void Debug_Setup(bool chat = false, bool console = false, bool log = false, bool disable = false)
{
}

stock void Debug_Print(const char[] format, any ...)
{
}

// Kept local so HexTags does not depend on the optional hexstocks.inc, preserving its argument order.
stock bool IsValidClient(int client, bool AllowBots = false, bool AllowDead = false)
{
	if (client < 1 || client > MaxClients || !IsClientInGame(client)
		|| (IsFakeClient(client) && !AllowBots) || IsClientSourceTV(client)
		|| IsClientReplay(client) || (!AllowDead && !IsPlayerAlive(client)))
		return false;
	return true;
}

void GetTags(int client, KeyValues kv)
{
	static char sSection[64];
	static char sDef[8];
	IntToString(iNextDefTag++, sDef, sizeof(sDef));
	
	kv.GetSectionName(sSection, sizeof(sSection));
	Debug_Print("Section: %s", sSection);
	int id;
	if (!kv.GetSectionSymbol(id))
	{
		LogError("Unable to get section symbol.");
	}
	
	CustomTags tags;
	
	tags.SectionId = id;
	kv.GetString("TagName", tags.TagName, sizeof(CustomTags::TagName), sDef);
	kv.GetString("ScoreTag", tags.ScoreTag, sizeof(CustomTags::ScoreTag), "");
	kv.GetString("ChatTag", tags.ChatTag, sizeof(CustomTags::ChatTag), "");
	kv.GetString("ChatColor", tags.ChatColor, sizeof(CustomTags::ChatColor), "");
	kv.GetString("NameColor", tags.NameColor, sizeof(CustomTags::NameColor), "{teamcolor}");
	// Existing configs use Force, newer examples use ForceTag. Support both, preferring the established key.
	tags.ForceTag = kv.GetNum("Force", kv.GetNum("ForceTag", 1)) == 1;

	// The persisted selection is the TagName. Reject duplicates rather than restoring whichever appears first.
	int length = userTags[client].Length;
	CustomTags existing;
	for (int i = 0; i < length; i++)
	{
		userTags[client].GetArray(i, existing, sizeof(existing));
		if (StrEqual(existing.TagName, tags.TagName, false))
		{
			LogError("Duplicate TagName \"%s\" in %s. Later duplicate skipped.", tags.TagName, sTagConf);
			return;
		}
	}

	
	if (tags.ScoreTag[0] != '\0')
	{
		//Update params
		if (StrContains(tags.ScoreTag, "{country}") != -1)
		{
			ReplaceString(tags.ScoreTag, sizeof(CustomTags::ScoreTag), "{country}", sCountryCode[client]);
		}
		Debug_Print("Prepared score tag: %s", tags.ScoreTag);
	}
	if (StrContains(tags.ChatTag, "{rainbow}") == 0) 
	{
		Debug_Print("Found {rainbow} in ChatTag");
		ReplaceString(tags.ChatTag, sizeof(CustomTags::ChatTag), "{rainbow}", "");
		char sTemp[MAXLENGTH_MESSAGE]; 
		
		int color;
		int len = strlen(tags.ChatTag);
		for(int i = 0; i < len; i++)
		{
			if (IsCharSpace(tags.ChatTag[i]))
			{
				Format(sTemp, sizeof(sTemp), "%s%c", sTemp, tags.ChatTag[i]);
				continue;
			}
			
			int bytes = GetCharBytes(tags.ChatTag[i])+1;
			char[] c = new char[bytes];
			strcopy(c, bytes, tags.ChatTag[i]);
			Format(sTemp, sizeof(sTemp), "%s%c%s", sTemp, GetColor(++color), c);
			if (IsCharMB(tags.ChatTag[i]))
			i += bytes-2;
		}
		strcopy(tags.ChatTag, sizeof(CustomTags::ChatTag), sTemp);
		Debug_Print("Replaced ChatTag with %s", tags.ChatTag);
	}
	if (StrContains(tags.ChatTag, "{random}") == 0) 
	{
		ReplaceString(tags.ChatTag, sizeof(CustomTags::ChatTag), "{random}", "");
		char sTemp[MAXLENGTH_MESSAGE];
		int len = strlen(tags.ChatTag);
		for(int i = 0; i < len; i++)
		{
			if (IsCharSpace(tags.ChatTag[i]))
			{
				Format(sTemp, sizeof(sTemp), "%s%c", sTemp, tags.ChatTag[i]);
				continue;
			}
			
			int bytes = GetCharBytes(tags.ChatTag[i])+1;
			char[] c = new char[bytes];
			strcopy(c, bytes, tags.ChatTag[i]);
			Format(sTemp, sizeof(sTemp), "%s%c%s", sTemp, GetRandomColor(), c);
			if (IsCharMB(tags.ChatTag[i]))
			i += bytes-2;
		}
		strcopy(tags.ChatTag, sizeof(CustomTags::ChatTag), sTemp);
	}
	Debug_Print("Succesfully setted tags");
	userTags[client].PushArray(tags, sizeof(tags));
}

void ResetTags(int client)
{
	strcopy(selectedTags[client].TagName, sizeof(CustomTags::TagName), "");
	strcopy(selectedTags[client].ScoreTag, sizeof(CustomTags::ScoreTag), "");
	strcopy(selectedTags[client].ChatTag, sizeof(CustomTags::ChatTag), "");
	strcopy(selectedTags[client].ChatColor, sizeof(CustomTags::ChatColor), "");
	strcopy(selectedTags[client].NameColor, sizeof(CustomTags::NameColor), "");
	selectedTags[client].ForceTag = false;
	selectedTags[client].SectionId = 0;
}

int GetRandomColor()
{
	switch(GetRandomInt(1, 16))
	{
		case  1: return '\x01';
		case  2: return '\x02';
		case  3: return '\x03';
		case  4: return '\x03';
		case  5: return '\x04';
		case  6: return '\x05';
		case  7: return '\x06';
		case  8: return '\x07';
		case  9: return '\x08';
		case 10: return '\x09';
		case 11: return '\x10';
		case 12: return '\x0A';
		case 13: return '\x0B';
		case 14: return '\x0C';
		case 15: return '\x0E';
		case 16: return '\x0F';
	}
	return '\x01';
}

int GetColor(int color)
{
	// TODO: Use modulo operator.
	while(color > 7)
	color -= 7;
	
	switch(color)
	{
		case  1: return '\x02';
		case  2: return '\x10';
		case  3: return '\x09';
		case  4: return '\x06';
		case  5: return '\x0B';
		case  6: return '\x0C';
		case  7: return '\x0E';
	}
	return '\x01';
}

//API
public int Native_GetClientTag(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	
	if (client < 1 || client > MaxClients)
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index (%d)", client);
	}
	if (!IsClientConnected(client))
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Client %d is not connected", client);
	}
	
	eTags tag = view_as<eTags>(GetNativeCell(2));
	switch (tag)
	{
		case (ScoreTag): 
		{
			SetNativeString(3, selectedTags[client].ScoreTag, GetNativeCell(4));
		}
		case (ChatTag): 
		{
			SetNativeString(3, selectedTags[client].ChatTag, GetNativeCell(4));
		}
		case (ChatColor): 
		{
			SetNativeString(3, selectedTags[client].ChatColor, GetNativeCell(4));
		}
		case (NameColor): 
		{
			SetNativeString(3, selectedTags[client].NameColor, GetNativeCell(4));
		}
	}
	return 0;
}

public int Native_SetClientTag(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	
	if (client < 1 || client > MaxClients)
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index (%d)", client);
	}
	if (!IsClientConnected(client))
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Client %d is not connected", client);
	}
	
	char sTag[64];
	eTags tag = view_as<eTags>(GetNativeCell(2));
	
	GetNativeString(3, sTag, sizeof(sTag));
	ReplaceString(sTag, sizeof(sTag), "{darkgray}", "{gray2}");
	
	switch (tag)
	{
		case (ScoreTag): 
		{
			strcopy(selectedTags[client].ScoreTag, sizeof(CustomTags::ScoreTag), sTag);
		}
		case (ChatTag): 
		{
			strcopy(selectedTags[client].ChatTag, sizeof(CustomTags::ChatTag), sTag);
		}
		case (ChatColor): 
		{
			strcopy(selectedTags[client].ChatColor, sizeof(CustomTags::ChatColor), sTag);
		}
		case (NameColor): 
		{
			strcopy(selectedTags[client].NameColor, sizeof(CustomTags::NameColor), sTag);
		}
	}
	
	
	Debug_Print("Called Native_SetClientTag(%i, %i, %s)", client, tag, sTag);

//	strcopy(selectedTags[client][Tag], sizeof(sTags[][]), sTag);
	return 0;
}

public int Native_ResetClientTags(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	
	if (client < 1 || client > MaxClients)
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index (%d)", client);
	}
	if (!IsClientConnected(client))
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Client %d is not connected", client);
	}
	
	TryLoadTags(client);
	return 0;
}

public int Native_AddCustomSelector(Handle plugin, int numParams)
{
	return pfCustomSelector.AddFunction(plugin, GetNativeFunction(1));
}

public int Native_RemoveCustomSelector(Handle plugin, int numParams)
{
	return pfCustomSelector.RemoveFunction(plugin, GetNativeFunction(1));
}


/* From smlib */
stock void String_ToLower(const char[] input, char[] output, int size)
{
	size--;

	int x=0;
	while (input[x] != '\0' && x < size) {

		output[x] = CharToLower(input[x]);

		x++;
	}

	output[x] = '\0';
}
