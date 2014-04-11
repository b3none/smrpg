#pragma semicolon 1
#include <sourcemod>
#include <smlib>

new g_iCachedRank[MAXPLAYERS+1] = {-1,...};
new g_iCachedRankCount = 0;

enum SessionStats {
	SS_JoinTime,
	SS_JoinLevel,
	SS_JoinExperience,
	SS_JoinCredits,
	SS_JoinRank,
	bool:SS_WantsAutoUpdate,
	bool:SS_WantsMenuOpen,
	bool:SS_OKToClose
};

new g_iPlayerSessionStartStats[MAXPLAYERS+1][SessionStats];

new Handle:g_hfwdOnAddExperience;

// AFK Handling
enum AFKInfo {
	Float:AFK_lastPosition[3],
	AFK_startTime,
	AFK_spawnTime,
	AFK_deathTime
}
new g_PlayerAFKInfo[MAXPLAYERS+1][AFKInfo];

RegisterStatsNatives()
{
	// native bool:SMRPG_AddClientExperience(client, exp, bool:bHideNotice);
	CreateNative("SMRPG_AddClientExperience", Native_AddClientExperience);
	// native SMRPG_LevelToExperience(iLevel);
	CreateNative("SMRPG_LevelToExperience", Native_LevelToExperience);
	
	// native bool:SMRPG_IsClientAFK(client);
	CreateNative("SMRPG_IsClientAFK", Native_IsClientAFK);
}

RegisterStatsForwards()
{
	// forward Action:SMRPG_OnAddExperience(client, ExperienceReason:reason, &iExperience);
	g_hfwdOnAddExperience = CreateGlobalForward("SMRPG_OnAddExperience", ET_Hook, Param_Cell, Param_Cell, Param_CellByRef);
}

/* Calculate the experience needed for this level */
Stats_LvlToExp(iLevel)
{
	new iExp;
	
	if(iLevel <= 1)
		iExp = GetConVarInt(g_hCVExpStart);
	else
		iExp = iLevel * GetConVarInt(g_hCVExpInc) + GetConVarInt(g_hCVExpStart);
	
	return iExp > GetConVarInt(g_hCVExpMax) ? GetConVarInt(g_hCVExpMax) : iExp;
}

/* Calculate how many levels to increase by current level and experience */
Stats_CalcLvlInc(iLevel, iExp)
{
	new iLevelIncrease;
	
	new iExpRequired = Stats_LvlToExp(iLevel);
	while(iExp >= iExpRequired)
	{
		iLevelIncrease++;
		iExp -= iExpRequired;
		iExpRequired = Stats_LvlToExp(iLevel+iLevelIncrease);
	}
	
	return iLevelIncrease;
}

Stats_PlayerNewLevel(client, iLevelIncrease)
{
	new iMaxLevel, bool:bMaxLevelReset;
	if(IsFakeClient(client))
	{
		iMaxLevel = GetConVarInt(g_hCVBotMaxlevel);
		bMaxLevelReset = GetConVarBool(g_hCVBotMaxlevelReset);
	}
	else
	{
		iMaxLevel = GetConVarInt(g_hCVPlayerMaxlevel);
		bMaxLevelReset = GetConVarBool(g_hCVPlayerMaxlevelReset);
	}
	
	// Check if the player reached the maxlevel
	if(iMaxLevel > 0)
	{
		new iNewLevel = GetClientLevel(client) + iLevelIncrease;
		// Player surpassed the maxlevel?
		if(iNewLevel > iMaxLevel)
		{
			// Reset him immediately if we want to.
			if(bMaxLevelReset)
			{
				DebugMsg("Player %N has surpassed the maximum level of %d, resetting his stats", client, iMaxLevel);
				Client_PrintToChatAll(false, "%t", "Player reached maxlevel", client, iMaxLevel);
				LogMessage("%L surpassed the maximum level of %d, resetting his stats.", client, iMaxLevel);
				ResetStats(client);
				return;
			}
			else
			{
				// Only increase so much until we reach the maxlevel.
				iLevelIncrease = iMaxLevel - iNewLevel;
			}
		}
	}
	
	// Don't do anything, if we don't really have a new level.
	if(iLevelIncrease <= 0)
		return;
	
	// Make sure to keep the experience he gained in addition to the needed exp for the levels.
	new iExperience = GetClientExperience(client);
	for(new i=0;i<iLevelIncrease;i++)
	{
		iExperience -= Stats_LvlToExp(GetClientLevel(client)+i);
	}
	
	// Some admin gave him a level even though he didn't have enough exp? well well..
	if(iExperience < 0)
		iExperience = 0;
	
	SetClientExperience(client, iExperience);
	
	SetClientLevel(client, GetClientLevel(client)+iLevelIncrease);
	SetClientCredits(client, GetClientCredits(client) + iLevelIncrease * GetConVarInt(g_hCVCreditsInc));
	
	DebugMsg("%N is now level %d (%d level increase(s))", client, GetClientLevel(client), iLevelIncrease);
	
	// Player wants to get prompted with the rpgmenu automatically when he levels up?
	// Make sure he isn't viewing another menu at the moment.
	if(ShowMenuOnLevelUp(client) && GetClientMenu(client) == MenuSource_None)
	{
		DisplayUpgradesMenu(client);
	}
	
	if(FadeScreenOnLevelUp(client))
	{
		Client_ScreenFade(client, 255, FFADE_OUT|FFADE_PURGE, 255, 255, 215, 0, 120);
	}
	
	if(GetConVarBool(g_hCVAnnounceNewLvl))
		Client_PrintToChatAll(false, "%t", "Client level changed", client, GetClientLevel(client));
	
	if(!IsFakeClient(client))
	{
		EmitSoundToClient(client, "buttons/blip2.wav");
		if((GetClientLevel(client) - iLevelIncrease) <= 1)
		{
			/* for newbies */
			Client_PrintToChat(client, false, "%t", "Newbie instructions new level");
			Client_PrintToChat(client, false, "%t", "Newbie instructions use rpgmenu");
		}
		else
		{
			Client_PrintToChat(client, false, "%t", "You have new credits", GetClientCredits(client));
		}
	}
	else if(GetConVarBool(g_hCVBotEnable))
	{
		BotPickUpgrade(client);
	}
}

bool:Stats_AddExperience(client, iExperience, bool:bHideNotice)
{
	IF_IGNORE_BOTS(client)
		return false;
	
	if(GetConVarBool(g_hCVNeedEnemies))
	{
		// No enemies in the opposite team?
		if(!Team_HaveAllPlayers(GetConVarBool(g_hCVBotEnable)))
			return false;
	}
	
	// Don't give the players any more exp when they already reached the maxlevel.
	new iMaxlevel;
	if(IsFakeClient(client))
		iMaxlevel = GetConVarInt(g_hCVBotMaxlevel);
	else
		iMaxlevel = GetConVarInt(g_hCVPlayerMaxlevel);
	
	if(iMaxlevel > 0 && GetClientLevel(client) >= iMaxlevel)
		return false;
	
	SetClientExperience(client, GetClientExperience(client) + iExperience);
	
	new iExpRequired = Stats_LvlToExp(GetClientLevel(client));
	
	if(GetClientExperience(client) >= iExpRequired)
		Stats_PlayerNewLevel(client, Stats_CalcLvlInc(GetClientLevel(client), GetClientExperience(client)));
	
	if(!bHideNotice && GetConVarBool(g_hCVExpNotice))
		PrintHintText(client, "%t", "Experience Gained Hintbox", iExperience, GetClientExperience(client), Stats_LvlToExp(GetClientLevel(client)));
	
	return true;
}

Stats_PlayerDamage(attacker, victim, Float:fDamage)
{
	if(!GetConVarBool(g_hCVEnable))
		return;
	
	// Don't give the attacker any exp when his victim was afk.
	if(IsClientAFK(victim))
		return;
	
	// Ignore teamattack
	if(GetClientTeam(attacker) == GetClientTeam(victim))
		return;
	
	new iExp = RoundToCeil(fDamage * GetConVarFloat(g_hCVExpDamage));
	
	if(Stats_CallOnExperienceForward(attacker, ER_PlayerHurt, iExp) <= Plugin_Changed)
		Stats_AddExperience(attacker, iExp, true);
}

Stats_PlayerKill(attacker, victim)
{
	if(!GetConVarBool(g_hCVEnable))
		return;
	
	// Don't give the attacker any exp when his victim was afk.
	if(IsClientAFK(victim))
		return;
	
	// Ignore teamattack
	if(GetClientTeam(attacker) == GetClientTeam(victim))
		return;
	
	new iExp = RoundToCeil(GetClientLevel(victim) * GetConVarFloat(g_hCVExpKill));
	new iExpMax = GetConVarInt(g_hCVExpKillMax);
	// Limit the possible experience to this.
	if(iExpMax > 0 && iExp > iExpMax)
		iExp = iExpMax;
	
	if(Stats_CallOnExperienceForward(attacker, ER_PlayerKill, iExp) <= Plugin_Changed)
		Stats_AddExperience(attacker, iExp, false);
}

Stats_WinningTeam(iTeam)
{
	if(!GetConVarBool(g_hCVEnable))
		return;
	
	new Float:fTeamRatio;
	if(iTeam == 2)
		fTeamRatio = SMRPG_TeamRatio(3);
	else if(iTeam == 3)
		fTeamRatio = SMRPG_TeamRatio(2);
	else
		return;
	
	new iExperience;
	for(new i=1;i<=MaxClients;i++)
	{
		if(IsClientInGame(i) && GetClientTeam(i) == iTeam)
		{
			iExperience = RoundToCeil(float(Stats_LvlToExp(GetClientLevel(i))) * GetConVarFloat(g_hCVExpTeamwin) * fTeamRatio);
			if(Stats_CallOnExperienceForward(i, ER_RoundEnd, iExperience) <= Plugin_Changed)
				Stats_AddExperience(i, iExperience, false);
		}
	}
}

Action:Stats_CallOnExperienceForward(client, ExperienceReason:reason, iExperience)
{
	new Action:result;
	Call_StartForward(g_hfwdOnAddExperience);
	Call_PushCell(client);
	Call_PushCell(reason);
	Call_PushCellRef(iExperience);
	Call_Finish(result);
	return result;
}

// AFK Handling
StartAFKChecker()
{
	CreateTimer(0.5, Timer_CheckAFKPlayers, _, TIMER_FLAG_NO_MAPCHANGE|TIMER_REPEAT);
}

public Action:Timer_CheckAFKPlayers(Handle:timer)
{
	new Float:fOrigin[3], Float:fLastPosition[3];
	for(new i=1;i<=MaxClients;i++)
	{
		if(IsClientInGame(i) && IsPlayerAlive(i) && GetClientTeam(i) > 1)
		{
			GetClientAbsOrigin(i, fOrigin);
			
			// See if the player just spawned..
			if(g_PlayerAFKInfo[i][AFK_spawnTime] > 0)
			{
				new iDifference = GetTime() - g_PlayerAFKInfo[i][AFK_spawnTime];
				// The player spawned 2 seconds ago. He's now ready to be checked for being afk again.
				if(iDifference > 2)
				{
					g_PlayerAFKInfo[i][AFK_spawnTime] = 0;
					if(g_PlayerAFKInfo[i][AFK_startTime] > 0)
						g_PlayerAFKInfo[i][AFK_startTime] += iDifference;
					Array_Copy(fOrigin, g_PlayerAFKInfo[i][AFK_lastPosition], 3);
				}
				continue;
			}
			
			// See if we need to subtract some time while he was dead.
			if(g_PlayerAFKInfo[i][AFK_deathTime] > 0)
			{
				if(g_PlayerAFKInfo[i][AFK_startTime] > 0)
					g_PlayerAFKInfo[i][AFK_startTime] += GetTime() - g_PlayerAFKInfo[i][AFK_deathTime];
				g_PlayerAFKInfo[i][AFK_deathTime] = 0;
			}
			
			Array_Copy(g_PlayerAFKInfo[i][AFK_lastPosition], fLastPosition, 3);
			if(Math_VectorsEqual(fOrigin, fLastPosition, 1.0))
			{
				if(g_PlayerAFKInfo[i][AFK_startTime] == 0)
					g_PlayerAFKInfo[i][AFK_startTime] = GetTime();
			}
			else
			{
				g_PlayerAFKInfo[i][AFK_startTime] = 0;
			}
			
			Array_Copy(fOrigin, g_PlayerAFKInfo[i][AFK_lastPosition], 3);
		}
	}
	
	return Plugin_Continue;
}

bool:IsClientAFK(client)
{
	if(g_PlayerAFKInfo[client][AFK_startTime] == 0)
		return false;
	
	new iAFKTime = GetConVarInt(g_hCVAFKTime);
	if(iAFKTime <= 0)
		return false;
	
	if((GetTime() - g_PlayerAFKInfo[client][AFK_startTime]) > iAFKTime)
		return true;
	return false;
}

ResetAFKPlayer(client)
{
	g_PlayerAFKInfo[client][AFK_startTime] = 0;
	g_PlayerAFKInfo[client][AFK_spawnTime] = 0;
	g_PlayerAFKInfo[client][AFK_deathTime] = 0;
	Array_Copy(g_PlayerAFKInfo[client][AFK_lastPosition], Float:{0.0,0.0,0.0}, 3);
}

/**
 * Native Callbacks
 */
// native SMRPG_AddClientExperience(client, exp, bool:bHideNotice);
public Native_AddClientExperience(Handle:plugin, numParams)
{
	new client = GetNativeCell(1);
	if(client < 0 || client > MaxClients)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index %d.", client);
		return;
	}
	
	new iExperience = GetNativeCell(2);
	new bool:bHideNotice = bool:GetNativeCell(3);
	Stats_AddExperience(client, iExperience, bHideNotice);
}

public Native_LevelToExperience(Handle:plugin, numParams)
{
	new iLevel = GetNativeCell(1);
	return Stats_LvlToExp(iLevel);
}

public Native_IsClientAFK(Handle:plugin, numParams)
{
	new client = GetNativeCell(1);
	if(client < 0 || client > MaxClients)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index %d.", client);
		return false;
	}
	
	return IsClientAFK(client);
}

// rpgsession handling
InitPlayerSessionStartStats(client)
{
	g_iPlayerSessionStartStats[client][SS_JoinTime] = GetTime();
	g_iPlayerSessionStartStats[client][SS_JoinLevel] = GetClientLevel(client);
	g_iPlayerSessionStartStats[client][SS_JoinExperience] = GetClientExperience(client);
	g_iPlayerSessionStartStats[client][SS_JoinCredits] = GetClientCredits(client);
	g_iPlayerSessionStartStats[client][SS_JoinRank] = -1;
	g_iPlayerSessionStartStats[client][SS_WantsAutoUpdate] = false;
	g_iPlayerSessionStartStats[client][SS_WantsMenuOpen] = false;
	g_iPlayerSessionStartStats[client][SS_OKToClose] = false;
}

ResetPlayerSessionStats(client)
{
	g_iPlayerSessionStartStats[client][SS_JoinTime] = 0;
	g_iPlayerSessionStartStats[client][SS_JoinLevel] = 0;
	g_iPlayerSessionStartStats[client][SS_JoinExperience] = 0;
	g_iPlayerSessionStartStats[client][SS_JoinCredits] = 0;
	g_iPlayerSessionStartStats[client][SS_JoinRank] = -1;
	g_iPlayerSessionStartStats[client][SS_WantsAutoUpdate] = false;
	g_iPlayerSessionStartStats[client][SS_WantsMenuOpen] = false;
	g_iPlayerSessionStartStats[client][SS_OKToClose] = false;
}

// Use our own forward to initialize the session info :)
public SMRPG_OnClientLoaded(client)
{
	// Only set it once and leave it that way until he really disconnects.
	if(g_iPlayerSessionStartStats[client][SS_JoinTime] == 0)
		InitPlayerSessionStartStats(client);
}

StartSessionMenuUpdater()
{
	CreateTimer(1.0, Timer_UpdateSessionMenus, _, TIMER_FLAG_NO_MAPCHANGE|TIMER_REPEAT);
}

public Action:Timer_UpdateSessionMenus(Handle:timer)
{
	for(new i=1;i<=MaxClients;i++)
	{
		// Refresh the contents of the menu here.
		if(IsClientInGame(i) && !IsFakeClient(i) && g_iPlayerSessionStartStats[i][SS_WantsMenuOpen] && g_iPlayerSessionStartStats[i][SS_WantsAutoUpdate])
			DisplaySessionStatsMenu(i);
	}
	
	return Plugin_Continue;
}

DisplaySessionStatsMenu(client)
{
	new Handle:hPanel = CreatePanel();
	
	decl String:sBuffer[128];
	Format(sBuffer, sizeof(sBuffer), "%T", "Stats", client);
	DrawPanelItem(hPanel, sBuffer);
	
	Format(sBuffer, sizeof(sBuffer), "  %T", "Level", client, GetClientLevel(client));
	DrawPanelText(hPanel, sBuffer);
	Format(sBuffer, sizeof(sBuffer), "  %T", "Experience short", client, GetClientExperience(client), Stats_LvlToExp(GetClientLevel(client)));
	DrawPanelText(hPanel, sBuffer);
	Format(sBuffer, sizeof(sBuffer), "  %T", "Credits", client, GetClientCredits(client));
	DrawPanelText(hPanel, sBuffer);
	Format(sBuffer, sizeof(sBuffer), "  %T", "Rank", client, GetClientRank(client), GetRankCount());
	DrawPanelText(hPanel, sBuffer);
	
	Format(sBuffer, sizeof(sBuffer), "%T", "Session", client);
	DrawPanelItem(hPanel, sBuffer);
	
	SecondsToString(sBuffer, sizeof(sBuffer), GetTime()-g_iPlayerSessionStartStats[client][SS_JoinTime], false);
	Format(sBuffer, sizeof(sBuffer), "  %T", "Playtime", client, sBuffer);
	DrawPanelText(hPanel, sBuffer);
	
	new iChangedLevels = GetClientLevel(client) - g_iPlayerSessionStartStats[client][SS_JoinLevel];
	Format(sBuffer, sizeof(sBuffer), "  %T: %s%d", "Changed level", client, iChangedLevels>0?"+":"", iChangedLevels);
	DrawPanelText(hPanel, sBuffer);
	
	// Need to calculate the total earned experience.
	new iEarnedExperience = GetClientExperience(client) - g_iPlayerSessionStartStats[client][SS_JoinExperience];
	for(new i=0;i<iChangedLevels;i++)
	{
		iEarnedExperience += Stats_LvlToExp(g_iPlayerSessionStartStats[client][SS_JoinLevel]+i);
	}
	
	Format(sBuffer, sizeof(sBuffer), "  %T: %s%d", "Changed experience", client, iEarnedExperience>0?"+":"", iEarnedExperience);
	DrawPanelText(hPanel, sBuffer);
	
	new iBuffer = GetClientCredits(client) - g_iPlayerSessionStartStats[client][SS_JoinCredits];
	Format(sBuffer, sizeof(sBuffer), "  %T: %s%d", "Changed credits", client, iBuffer>0?"+":"", iBuffer);
	DrawPanelText(hPanel, sBuffer);
	
	if(g_iPlayerSessionStartStats[client][SS_JoinRank] != -1)
	{
		iBuffer = g_iPlayerSessionStartStats[client][SS_JoinRank] - GetClientRank(client);
		Format(sBuffer, sizeof(sBuffer), "  %T: %s%d", "Changed rank", client, iBuffer>0?"+":"", iBuffer);
		DrawPanelText(hPanel, sBuffer);
	}
	
	DrawPanelItem(hPanel, "", ITEMDRAW_SPACER);
	
	Format(sBuffer, sizeof(sBuffer), "%T: %T", "Auto refresh panel", client, (g_iPlayerSessionStartStats[client][SS_WantsAutoUpdate]?"Yes":"No"), client);
	DrawPanelItem(hPanel, sBuffer);
	
	// The old menu is closed when we open the new one.
	// The logic here is like this:
	// We want to stop redisplaying the session menu, if the menu was closed gracefully or was interrupted by a different menu.
	// If the old menu is currently displaying (callback was not called yet) we don't want it to stay closed when we display it again.
	// So we set OKToClose to true, so it doesn't set WantsMenuOpen to false as if the menu was closed by an interrupting menu.
	// That way the menu stays open and is refreshed every second while staying closed if the player closes it or some other menu is displayed over it.
	if(g_iPlayerSessionStartStats[client][SS_WantsMenuOpen])
		g_iPlayerSessionStartStats[client][SS_OKToClose] = true;
	g_iPlayerSessionStartStats[client][SS_WantsMenuOpen] = true;
	
	SendPanelToClient(hPanel, client, Panel_HandleSessionMenu, MENU_TIME_FOREVER);
	CloseHandle(hPanel);
}

public Panel_HandleSessionMenu(Handle:menu, MenuAction:action, param1, param2)
{
	if(action == MenuAction_Select)
	{
		g_iPlayerSessionStartStats[param1][SS_WantsMenuOpen] = false;
		g_iPlayerSessionStartStats[param1][SS_OKToClose] = false;
		
		// Toggle the auto update
		if(param2 == 4)
		{
			g_iPlayerSessionStartStats[param1][SS_WantsAutoUpdate] = !g_iPlayerSessionStartStats[param1][SS_WantsAutoUpdate];
			DisplaySessionStatsMenu(param1);
			return;
		}
	}
	else if(action == MenuAction_Cancel)
	{
		
		if(!g_iPlayerSessionStartStats[param1][SS_OKToClose])
			g_iPlayerSessionStartStats[param1][SS_WantsMenuOpen] = false;
		g_iPlayerSessionStartStats[param1][SS_OKToClose] = false;
	}
}


/*	//////////////////////////////////////
	CRPG_RankManager
	////////////////////////////////////// */

UpdateClientRank(client)
{
	decl String:sQuery[128];
	Format(sQuery, sizeof(sQuery), "SELECT COUNT(*) FROM %s WHERE level > '%d' OR (level = '%d' AND experience > '%d')", TBL_PLAYERS, GetClientLevel(client), GetClientLevel(client), GetClientExperience(client));
	SQL_TQuery(g_hDatabase, SQL_GetClientRank, sQuery, GetClientUserId(client));
}

GetClientRank(client)
{
	if(IsFakeClient(client))
		return -1;
	
	UpdateClientRank(client);
	return g_iCachedRank[client];
}

ClearClientRankCache(client)
{
	g_iCachedRank[client] = -1;
}

public SQL_GetClientRank(Handle:owner, Handle:hndl, const String:error[], any:userid)
{
	new client = GetClientOfUserId(userid);
	if(!client)
		return;
	
	if(hndl == INVALID_HANDLE || strlen(error) > 0)
	{
		LogError("Unable to get player rank (%s)", error);
		return;
	}
	
	SQL_FetchRow(hndl);
	
	g_iCachedRank[client] = SQL_FetchInt(hndl, 0) + 1; // +1 since the query returns the count, not the rank
	
	// Save the first time we fetch the rank for him.
	if(g_iPlayerSessionStartStats[client][SS_JoinRank] == -1)
		g_iPlayerSessionStartStats[client][SS_JoinRank] = g_iCachedRank[client];
}

UpdateRankCount()
{
	decl String:sQuery[128];
	Format(sQuery, sizeof(sQuery), "SELECT COUNT(*) FROM %s", TBL_PLAYERS);
	SQL_TQuery(g_hDatabase, SQL_GetRankCount, sQuery);
}

GetRankCount()
{
	UpdateRankCount();
	
	if(g_iCachedRankCount > 0)
		return g_iCachedRankCount;
	
	return 0;
}

public SQL_GetRankCount(Handle:owner, Handle:hndl, const String:error[], any:data)
{
	if(hndl == INVALID_HANDLE || strlen(error) > 0)
	{
		LogError("Unable to get player rank count (%s)", error);
		return;
	}
	
	SQL_FetchRow(hndl);
	
	g_iCachedRankCount = SQL_FetchInt(hndl, 0);
	
	new info[PlayerInfo];
	for(new i=1;i<=MaxClients;i++)
	{
		if(IsClientInGame(i) && !IsFakeClient(i))
		{
			GetClientRPGInfo(i, info);
			if(info[PLR_dbId] < 0)
				g_iCachedRankCount++; /* accounts for players not saved in the db */
		}
	}
}

PrintRankToChat(client, sendto)
{
	if(sendto == -1)
		Client_PrintToChatAll(false, "%t", "rpgrank", client, GetClientLevel(client), GetClientRank(client), GetRankCount(), GetClientExperience(client), Stats_LvlToExp(GetClientLevel(client)), GetClientCredits(client));
	else
		Client_PrintToChat(sendto, false, "%t", "rpgrank", client, GetClientLevel(client), GetClientRank(client), GetRankCount(), GetClientExperience(client), Stats_LvlToExp(GetClientLevel(client)), GetClientCredits(client));
}

stock DisplayTop10Menu(client)
{
	decl String:sQuery[128];
	Format(sQuery, sizeof(sQuery), "SELECT name, level, experience, credits FROM %s ORDER BY level DESC, experience DESC LIMIT 10", TBL_PLAYERS);
	SQL_TQuery(g_hDatabase, SQL_GetTop10, sQuery, GetClientUserId(client));
}

public SQL_GetTop10(Handle:owner, Handle:hndl, const String:error[], any:userid)
{
	new client = GetClientOfUserId(userid);
	if(!client)
		return;
	
	if(hndl == INVALID_HANDLE || strlen(error) > 0)
	{
		LogError("Unable to get player top10 (%s)", error);
		return;
	}
	
	decl String:sBuffer[128];
	Format(sBuffer, sizeof(sBuffer), "%T\n-----\n", "Top 10 Players", client);
	
	new Handle:hPanel = CreatePanel();
	SetPanelTitle(hPanel, sBuffer);
	
	new iIndex = 1;
	while(SQL_MoreRows(hndl))
	{
		if(!SQL_FetchRow(hndl))
			continue;
		
		SQL_FetchString(hndl, 0, sBuffer, sizeof(sBuffer));
		Format(sBuffer, sizeof(sBuffer), "%d. %s Lvl: %d Exp: %d Cr: %d", iIndex++, sBuffer, SQL_FetchInt(hndl, 1), SQL_FetchInt(hndl, 2), SQL_FetchInt(hndl, 3));
		DrawPanelText(hPanel, sBuffer);
	}
	
	// Let the panel close on any number
	SetPanelKeys(hPanel, 255);
	
	SendPanelToClient(hPanel, client, Panel_DoNothing, MENU_TIME_FOREVER);
	CloseHandle(hPanel);
}

public Panel_DoNothing(Handle:menu, MenuAction:action, param1, param2)
{
}

DisplayNextPlayersInRanking(client)
{
	decl String:sQuery[512];
	Format(sQuery, sizeof(sQuery), "SELECT name, level, experience, credits, (SELECT COUNT(*) FROM %s ps WHERE p.level < ps.level OR (p.level = ps.level AND p.experience < ps.experience))+1 AS rank FROM %s p WHERE level >= %d OR (level = %d AND experience >= %d) ORDER BY level ASC, experience ASC LIMIT 10", TBL_PLAYERS, TBL_PLAYERS, GetClientLevel(client), GetClientLevel(client), GetClientExperience(client));
	SQL_TQuery(g_hDatabase, SQL_GetNext10, sQuery, GetClientUserId(client));
}

public SQL_GetNext10(Handle:owner, Handle:hndl, const String:error[], any:userid)
{
	new client = GetClientOfUserId(userid);
	if(!client)
		return;
	
	if(hndl == INVALID_HANDLE || strlen(error) > 0)
	{
		LogError("Unable to get the next 10 players in front of the current rank of a player (%s)", error);
		return;
	}
	
	decl String:sBuffer[128];
	Format(sBuffer, sizeof(sBuffer), "%T\n-----\n", "Next ranked players", client);
	
	new Handle:hPanel = CreatePanel();
	SetPanelTitle(hPanel, sBuffer);
	
	while(SQL_MoreRows(hndl))
	{
		if(!SQL_FetchRow(hndl))
			continue;
		
		SQL_FetchString(hndl, 0, sBuffer, sizeof(sBuffer));
		Format(sBuffer, sizeof(sBuffer), "%d. %s Lvl: %d Exp: %d Cr: %d", SQL_FetchInt(hndl, 4), sBuffer, SQL_FetchInt(hndl, 1), SQL_FetchInt(hndl, 2), SQL_FetchInt(hndl, 3));
		DrawPanelText(hPanel, sBuffer);
	}
	
	// Let the panel close on any number
	SetPanelKeys(hPanel, 255);
	
	SendPanelToClient(hPanel, client, Panel_DoNothing, MENU_TIME_FOREVER);
	CloseHandle(hPanel);
}

// Taken from SourceBans 2's sb_bans :)
SecondsToString(String:sBuffer[], iLength, iSecs, bool:bTextual = true)
{
	if(bTextual)
	{
		decl String:sDesc[6][8] = {"mo",              "wk",             "d",          "hr",    "min", "sec"};
		new  iCount, iDiv[6]    = {60 * 60 * 24 * 30, 60 * 60 * 24 * 7, 60 * 60 * 24, 60 * 60, 60,    1};
		sBuffer[0]              = '\0';
		
		for(new i = 0; i < sizeof(iDiv); i++)
		{
			if((iCount = iSecs / iDiv[i]) > 0)
			{
				Format(sBuffer, iLength, "%s%i %s, ", sBuffer, iCount, sDesc[i]);
				iSecs %= iDiv[i];
			}
		}
		sBuffer[strlen(sBuffer) - 2] = '\0';
	}
	else
	{
		new iHours = iSecs  / 60 / 60;
		iSecs     -= iHours * 60 * 60;
		new iMins  = iSecs  / 60;
		iSecs     %= 60;
		Format(sBuffer, iLength, "%02i:%02i:%02i", iHours, iMins, iSecs);
	}
}