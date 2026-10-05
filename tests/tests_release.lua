-- Release checks: TOC fields and the addon-message prefix. (The version token is
-- checked in tests_static.lua, and "dev" partners in tests_duocore.lua.)
package.path = assert(os.getenv("DQ_TESTS"), "DQ_TESTS unset: run tests/run.sh") .. "?.lua;" .. package.path
local H = require("harness")
local check = H.check
local DIR = assert(os.getenv("DQ_DIR"), "DQ_DIR unset: run tests/run.sh")

local function read(name)
  local f = assert(io.open(DIR .. name, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

local toc = read("VulcanDuoQuest.toc")
check("TOC version is the packager token", toc:find("\n## Version: @project-version@\n", 1, true) ~= nil)
check("TOC author is Tavlius", toc:find("\n## Author: Tavlius\n", 1, true) ~= nil)
check("TOC title", toc:find("\n## Title: Vulcan DuoQuest\n", 1, true) ~= nil)
check("TOC interface is Forever 1.60.1 (16001)", toc:find("^## Interface: 16001\n") ~= nil)

-- Addon-message prefixes: at most 16 characters, and every Vulcan add-on's is different.
local SUITE_PREFIXES = {
  VulcanGrindWatch = "VulcanGrindWatch", VulcanRunBook = "VulcanRunBook", VulcanDuoQuest = "VulcanDuoQuest",
}
local prefix = read("Sync.lua"):match('prefix = "([^"]+)"')
check("prefix is this add-on's suite prefix", prefix == SUITE_PREFIXES.VulcanDuoQuest, prefix)
local seen, distinct = {}, true
for _, p in pairs(SUITE_PREFIXES) do
  check("prefix " .. p .. " fits 16 characters", #p <= 16, #p)
  if seen[p] then distinct = false end
  seen[p] = true
end
check("suite prefixes are all different", distinct)
do
  local c = H.boot()
  c.login()
  check("the prefix is what gets registered", c.prefixes[prefix] == true)
end

os.exit(H.summary() and 0 or 1)
