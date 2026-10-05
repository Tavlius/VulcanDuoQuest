-- Saved-data safety (Persist.lua): a character file that didn't load is spotted and warned about.
package.path = assert(os.getenv("DQ_TESTS"), "DQ_TESTS unset: run tests/run.sh") .. "?.lua;" .. package.path
local H = require("harness")
local check = H.check

local function warned(c) return c.printedMatch("saved data didn't load") ~= nil end
local function errorsFrameWarned(c)
  for _, m in ipairs(c.errorsFrame or {}) do if m:find("saved data didn't load", 1, true) then return true end end
  return false
end

-- A first login and a normal logout: the marker the cross-check needs.
local function firstInstall(opts)
  local c = H.boot(opts)
  c.login()
  return c, c.logout()
end

-- 1. A genuine first install warns about nothing; logout lists the character.
do
  local c, saved = firstInstall()
  check("first install: no failure", c.ns.Persist.failure == nil and not warned(c))
  check("logout lists this character in the account marker",
    type(saved.marker) == "table" and type(saved.marker.chars) == "table" and type(saved.marker.chars["Tavlius-Realm"]) == "number")
  check("the marker holds nothing but the character list", next(saved.marker, next(saved.marker)) == nil)
  local c2 = H.boot({ saved = saved.char, marker = saved.marker })
  c2.login()
  check("normal reload: no failure, no warning", c2.ns.Persist.failure == nil and not warned(c2))
  c2.slash("check")
  check("/dq check says saved data loaded", c2.printedMatch("saved data: loaded normally") ~= nil)
end

-- 2. This character's file didn't load, but the marker lists the character.
do
  local _, saved = firstInstall()
  local c = H.boot({ marker = saved.marker })
  c.login()
  check("character load failure detected", c.ns.Persist.failure and c.ns.Persist.failure.char)
  check("warned in chat", warned(c))
  check("warned on screen", errorsFrameWarned(c))
  check("says it's a known Forever client problem", c.printedMatch("known problem with the World of Warcraft: Forever client") ~= nil)
  check("says the next save overwrites the file", c.printedMatch("overwrite it the next time you log out or /reload") ~= nil)
  check("names the file to copy", c.printedMatch("SavedVariables\\VulcanDuoQuest.lua", 1) ~= nil
    or c.printedMatch("SavedVariables%\\VulcanDuoQuest%.lua") ~= nil)
  check("not silently empty: works on, with the warning", c.ns.DB ~= nil and warned(c))
  c.slash("check")
  check("/dq check reports it", c.printedMatch("didn't load this session") ~= nil)
end

-- 3. Not failures: a new character, an unreadable realm, both files missing, a damaged marker.
do
  local _, saved = firstInstall()
  local a = H.boot({ marker = saved.marker, name = "Mirel" })
  a.login()
  check("new character on the account: no warning", a.ns.Persist.failure == nil and not warned(a))
  local b = H.boot({ marker = saved.marker })
  b.realmName = nil
  b.login()
  check("realm unreadable: no guess, no warning", b.ns.Persist.failure == nil and not warned(b))
  local sb = b.logout()
  check("realm unreadable at logout: the marker gains no entry", type(sb.marker.chars) == "table"
    and sb.marker.chars["Tavlius-Realm"] ~= nil and sb.marker.chars["Tavlius"] == nil)
  check("realm unreadable at logout: no errors", #b.errors() == 0, b.errors()[1])
  local d = H.boot()
  d.login()
  check("both missing looks like a first install", d.ns.Persist.failure == nil and not warned(d))
  local e = H.boot({ marker = { chars = "junk" } })
  e.login()
  check("damaged marker: ignored", e.ns.Persist.failure == nil)
  local s = e.logout()
  check("damaged marker replaced at logout", type(s.marker.chars) == "table" and s.marker.chars["Tavlius-Realm"] ~= nil)
  check("no errors", #e.errors() == 0, e.errors()[1])
end

-- 4. The realm can be unreadable while the game loads: the check waits for login.
do
  local _, saved = firstInstall()
  local c = H.boot({ marker = saved.marker })
  c.realmName = nil
  c.fire("ADDON_LOADED", "VulcanDuoQuest")
  check("realm unreadable at load: no verdict yet", c.ns.Persist.failure == nil and not warned(c))
  c.realmName = "Realm"
  c.fire("PLAYER_LOGIN")
  check("realm readable at login: the failure is caught then", c.ns.Persist.failure ~= nil and warned(c))
  local c2 = H.boot({ marker = saved.marker, name = "Mirel" })
  c2.realmName = nil
  c2.fire("ADDON_LOADED", "VulcanDuoQuest")
  c2.realmName = "Realm"
  c2.fire("PLAYER_LOGIN")
  check("late check: a new character is still not a failure", c2.ns.Persist.failure == nil and not warned(c2))
end

os.exit(H.summary() and 0 or 1)
