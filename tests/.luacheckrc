-- luacheck config for the addon files (WoW globals).
std = "lua51"
max_line_length = 130
self = false
globals = {
  "VulcanDuoQuestCharDB", "VulcanDuoQuestDB", "SlashCmdList", "SLASH_VULCANDUOQUEST1", "SLASH_VULCANDUOQUEST2",
  "VulcanDuoQuest_OnAddonCompartmentClick", "VulcanDuoQuest_ToggleWindow", "VulcanDuoQuest_ShareNext",
  "BINDING_HEADER_VULCANDUOQUEST", "BINDING_NAME_VULCANDUOQUEST_TOGGLE", "BINDING_NAME_VULCANDUOQUEST_SHARE",
}
read_globals = {
  "issecretvalue", "C_ChatInfo", "C_QuestLog", "C_Timer", "CreateFrame", "UIParent", "GameTooltip",
  "UIErrorsFrame", "PlaySound", "SOUNDKIT", "Enum", "BackdropTemplateMixin", "GetTime", "GetBuildInfo",
  "UnitName", "IsInGroup", "IsInRaid", "GetNumGroupMembers", "LE_PARTY_CATEGORY_HOME", "LE_PARTY_CATEGORY_INSTANCE",
  "Ambiguate", "IsResting", "SendAddonMessage", "RegisterAddonMessagePrefix", "wipe",
  "GetQuestProgressBarPercent", "GetNumQuestLogEntries", "GetQuestLogTitle", "GetNumQuestLeaderBoards",
  "GetQuestLogLeaderBoard", "IsQuestFlaggedCompleted", "QuestLogPushQuest", "SelectQuestLogEntry",
  "GetQuestLogIndexByID", "GetQuestLogSelection", "time", "UISpecialFrames", "C_AddOns", "GetAddOnMetadata",
  "IsMouseButtonDown", "InCombatLockdown", "UnitAffectingCombat", "GetRealZoneText", "UnitOnTaxi", "UnitInRange", "UnitIsUnit",
  "GetNormalizedRealmName", "GetRealmName", "UNKNOWNOBJECT", "GetSubZoneText", "UnitIsDeadOrGhost", "UnitIsConnected", "UnitIsVisible", "IsInInstance", "C_Spell",
  "UnitDistanceSquared", "C_Map",
}
