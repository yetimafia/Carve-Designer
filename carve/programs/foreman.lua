-- built by Carve Designer v7.8
-- Carve foreman: sets up the other turtles of the colony so you only have to start this one.
--
--   1. It asks the Designer app where every job's chests (and furnaces) belong, in this turtle's own frame.
--   2. It walks to each spot, stands on top of it and places a chest or a furnace from its inventory
--      (digging out earth that is in the way; it never breaks chests or furnaces).
--   3. It asks the app to hand each job to the nearest idle Agent turtle, which walks to its site and starts the job.
--
-- Needs: live reporting, its own start position (Fleet tab, Colony tab or GPS), the start position of every job
-- (Colony tab: Lay out), the chests and furnaces listed in the Colony tab in its inventory, and some coal.
-- Run again with  stop  to cancel the automatic restart.

local args = { ... }

local PLAN = {agent_url = "https://raw.githubusercontent.com/yetimafia/Carve-Designer/main/carve/programs/agent.lua", build = true, dispatch = true, jobs = {{crafty = false, foot = {-2, -1, -2, 2, 2, 4}, furnaces = 0, kind = "keeper", kit = {{"chest", 8}}, name = "Storage keeper", slug = "storage_keeper"}, {crafty = false, foot = {-3, -1, -2, 10, 9, 10}, furnaces = 0, kind = "treefarm", kit = {{"sapling", 4}, {"chest", 1}}, name = "Tree farm", slug = "tree_farm"}, {crafty = false, foot = {-2, -1, -2, 3, 2, 4}, furnaces = 2, kind = "smelter", kit = {{"furnace", 2}, {"chest", 2}}, name = "Smelter", slug = "smelter"}, {crafty = true, foot = {-2, -1, -2, 2, 2, 2}, furnaces = 0, kind = "crafter", kit = {{"chest", 2}}, name = "Compressor", slug = "compressor"}, {crafty = false, foot = false, furnaces = 0, kind = "hauler", kit = {}, name = "Hauler", slug = "hauler"}, {crafty = false, foot = false, furnaces = 0, kind = "scout", kit = {}, name = "Scout", slug = "scout"}}, kind = "foreman", label = "Sinclair", launcher_url = "https://raw.githubusercontent.com/yetimafia/Carve-Designer/main/carve/carve.lua", live = "http://127.0.0.1:8765", name = "Foreman"}

local STATE_FILE = "carve.foreman"
local TITLE = PLAN.name or "Foreman"
local FUEL_HINT = "coal or charcoal"
local BURN = { "coal", "charcoal" }
local KEEP = {}

---------------------------------------------------------------- shared helpers (position, moving, fuel)
-- directions: 1 = +z (forward at start), 2 = +x (right), 3 = -z (back), 4 = -x (left), 5 = up, 6 = down
-- every turtle names itself after a Deadlock hero (by its id) the first time it starts, if it has no label yet
do
  local GODS = { "Abrams", "Bebop", "Dynamo", "Grey Talon", "Haze", "Infernus", "Ivy", "Kelvin", "Lady Geist", "Lash", "McGinnis", "Krill", "Paradox", "Pocket", "Seven", "Shiv", "Vindicta", "Viscous", "Warden", "Wraith", "Yamato", "Calico", "Holliday", "Vyper", "Sinclair", "Mirage", "Drifter", "Victor", "Paige", "Billy", "Rem", "Mo" }
  if os.getComputerLabel and os.setComputerLabel and os.getComputerID and not os.getComputerLabel() then
    pcall(os.setComputerLabel, PLAN.label or GODS[os.getComputerID() % #GODS + 1])   -- the colony's name for it, else by id
  end
end

local DX = { 0, 1, 0, -1, 0, 0 }
local DZ = { 1, 0, -1, 0, 0, 0 }
local DY = { 0, 0, 0, 0, 1, -1 }
local pos = { x = 0, y = 0, z = 0 }
local face = 1
local MARK = "-- carve auto"
local PROGRAM = shell and shell.getRunningProgram and shell.getRunningProgram() or "job"

local function writeFile(name, text)
  local f = fs.open(name, "w")
  if f then f.write(text); f.close() end
end

local function readFile(name)
  if not fs.exists(name) then return nil end
  local f = fs.open(name, "r")
  if not f then return nil end
  local s = f.readAll()
  f.close()
  return s
end

local function savePos()
  writeFile(STATE_FILE, pos.x .. "," .. pos.y .. "," .. pos.z .. "," .. face)
end

local function loadPos()
  local s = readFile(STATE_FILE)
  if not s then return false end
  local x, y, z, f = s:match("^(-?%d+),(-?%d+),(-?%d+),(%d)")
  if not x then return false end
  pos.x, pos.y, pos.z, face = tonumber(x), tonumber(y), tonumber(z), tonumber(f)
  return true
end

local function installStartup()
  local cur = readFile("startup.lua")
  if cur and not cur:find(MARK, 1, true) then return end      -- someone else's startup file: leave it
  writeFile("startup.lua", MARK .. "\nshell.run(\"" .. PROGRAM .. "\", \"resume\")\n")
end

local function removeStartup()
  local cur = readFile("startup.lua")
  if cur and cur:find(MARK, 1, true) then fs.delete("startup.lua") end
end

---------------------------------------------------------------- fleet reporting (optional)
-- Tells the Carve Designer what this turtle is doing (name, place, fuel, message) every few seconds and
-- obeys a "stop" from its Fleet page. If the app isn't there nothing breaks.
local LIVE_URL = PLAN.live or ""
local fleet = { on = LIVE_URL ~= "" and http ~= nil and http.post ~= nil, last = -100, fails = 0, retryAt = 0, status = "",
                done = false, msg = "", act = "", seq = 0, n = 0, total = 0, cmd = nil, arg = "", world = nil, peers = {},
                run = os.epoch and math.floor(os.epoch("utc") / 1000) or 0,
                gpsLast = -100, gpsFails = 0, gpsOk = false, gpsDead = false }
for _, a in ipairs(args) do
  if a == "nolive" then fleet.on = false end
end
if LIVE_URL == "" then
  fleet.status = "live reporting is OFF (uploaded without it)"
elseif not (http and http.post) then
  fleet.status = "the http API is off on this computer"
elseif fleet.on then
  fleet.status = "connecting to " .. LIVE_URL
else
  fleet.status = "live reporting switched off (nolive)"
end

local function jq(s)
  s = tostring(s):gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"' end
    if c == "\\" then return "\\\\" end
    return string.format("\\u%04x", c:byte())
  end)
  return '"' .. s .. '"'
end

-- what I am trying to do this very moment (shown next to the status on the Fleet page)
local function act(text) fleet.act = text end

-- a GPS fix of where the turtle is right now (needs a GPS tower and a wireless modem); nil otherwise
local function gpsFix(now)
  if fleet.gpsDead or not (gps and gps.locate) or now - fleet.gpsLast < 20 then return nil end
  fleet.gpsLast = now
  local ok, x, y, z = pcall(gps.locate, 1)
  if ok and x then fleet.gpsOk, fleet.gpsFails = true, 0; return { x, y, z } end
  fleet.gpsFails = fleet.gpsFails + 1
  if fleet.gpsFails >= 2 and not fleet.gpsOk then fleet.gpsDead = true end
end

-- ---- shared map: every program tells the app what it sees on its way (scouts do it themselves)
local MAP_SHARE = fleet.on and PLAN.kind ~= "scout" and PLAN.map ~= false
local mapSeen, mapCount, mapOut, mapMoves, mapLast = {}, 0, {}, 0, 0
local function mapNote(x, y, z, name)
  local k = ((x + 512) * 1024 + (z + 512)) * 1024 + (y + 512)
  local old = mapSeen[k]
  if old == name then return end
  if old == nil then
    if mapCount >= 8000 then return end
    mapCount = mapCount + 1
  end
  mapSeen[k] = name
  mapOut[#mapOut + 1] = { x, y, z, name }
  if #mapOut > 1500 then table.remove(mapOut, 1) end
end
local function mapInspect(fn)
  local found, data = fn()
  if not found then return "air" end
  return type(data) == "table" and data.name or "unknown"
end
-- called after every move: my own cell is free, and the cell I face (and now and then above and below) is whatever it is
local function mapSee()
  if not MAP_SHARE then return end
  mapNote(pos.x, pos.y, pos.z, "air")
  mapMoves = mapMoves + 1
  local n = mapInspect(turtle.inspect)
  if n then mapNote(pos.x + DX[face], pos.y, pos.z + DZ[face], n) end
  if mapMoves % 4 == 0 then
    n = mapInspect(turtle.inspectUp); if n then mapNote(pos.x, pos.y + 1, pos.z, n) end
    n = mapInspect(turtle.inspectDown); if n then mapNote(pos.x, pos.y - 1, pos.z, n) end
  end
end
local function mapFlush(force)
  if not MAP_SHARE or #mapOut == 0 then return end
  local now = os.clock()
  if not force and #mapOut < 30 and now - mapLast < 10 then return end
  mapLast = now
  while #mapOut > 0 do
    local parts, sent = {}, {}
    for i = 1, math.min(#mapOut, 300) do
      local c = table.remove(mapOut)
      sent[#sent + 1] = c
      parts[#parts + 1] = "[" .. c[1] .. "," .. c[2] .. "," .. c[3] .. "," .. jq(c[4]) .. "]"
    end
    local ok, res = pcall(http.post, { url = LIVE_URL .. "/map", timeout = 5, headers = { ["Content-Type"] = "application/json" },
      body = '{"v":1,"id":' .. os.getComputerID() .. ',"cells":[' .. table.concat(parts, ",") .. "]}" })
    if ok and res then
      pcall(function() res.readAll(); res.close() end)
    else
      for _, c in ipairs(sent) do mapOut[#mapOut + 1] = c end
      break
    end
  end
end

-- what the app answered: "ok [command [argument]]", then "me x y z" (world position) and "peer id name x y z" lines
local function handleReply(reply)
  local cmd, arg = reply:match("^ok (%a+) ?([%w_%-]*)")
  if cmd then fleet.cmd, fleet.arg = cmd, arg or "" end        -- kept until the program has acted on it
  if cmd == "stop" then fleet.stopAsked = true; os.queueEvent("terminate") end
  fleet.world, fleet.peers = nil, {}
  for line in reply:gmatch("[^\n]+") do
    local gx, gy, gz, gf = line:match("^goto (-?%d+) (-?%d+) (-?%d+) (%d)$")
    if gx then fleet.dest = { tonumber(gx), tonumber(gy), tonumber(gz), tonumber(gf) } end
    local lab = line:match("^label ([%w_]+)$")
    if lab and os.setComputerLabel and not os.getComputerLabel() then pcall(os.setComputerLabel, (lab:gsub("_", " "))) end
    local x, y, z = line:match("^me (-?%d+) (-?%d+) (-?%d+)$")
    if x then fleet.world = { tonumber(x), tonumber(y), tonumber(z) } end
    local id, nm, px, py, pz = line:match("^peer (%d+) (%S+) (-?%d+) (-?%d+) (-?%d+)$")
    if id and #fleet.peers < 6 then
      fleet.peers[#fleet.peers + 1] = { id = tonumber(id), name = nm, x = tonumber(px), y = tonumber(py), z = tonumber(pz) }
    end
  end
end

local function fleetSend(force)
  if not fleet.on then return end
  local now = os.clock()
  if now < fleet.retryAt then return end
  if not force and now - fleet.last < 3 then return end
  fleet.last = now
  fleet.seq = fleet.seq + 1
  local fuel = turtle and turtle.getFuelLevel() or 0
  local label = os.getComputerLabel and os.getComputerLabel() or ""
  local body = table.concat({
    '{"v":1,"seq":' .. fleet.seq, '"id":' .. os.getComputerID(), '"label":' .. jq(label or ""),
    '"name":' .. jq(PLAN.name or ""), '"kind":' .. jq(PLAN.kind or "auto"),
    '"x":' .. pos.x, '"y":' .. pos.y, '"z":' .. pos.z, '"fuel":' .. jq(fuel),
    '"msg":' .. jq(fleet.msg), '"act":' .. jq(fleet.act or ""), '"f":' .. face, '"n":' .. fleet.n, '"total":' .. fleet.total,
    '"done":' .. (fleet.done and "true" or "false"), '"run":' .. fleet.run }, ",")
  local fix = gpsFix(now)
  if fix then body = body .. ',"gps":[' .. fix[1] .. "," .. fix[2] .. "," .. fix[3] .. "]" end
  if fleet.extra then                                          -- a program may add fields (the Foreman: inventory and crafting queue)
    local okx, frag = pcall(fleet.extra)
    if okx and type(frag) == "string" then body = body .. frag end
  end
  body = body .. "}"
  local ok, res, err = pcall(http.post, { url = LIVE_URL .. "/status", body = body, timeout = 5,
                                          headers = { ["Content-Type"] = "application/json" } })
  if ok and res then
    fleet.fails = 0
    fleet.status = "reporting OK to " .. LIVE_URL
    local reply = ""
    pcall(function() reply = res.readAll() or ""; res.close() end)
    handleReply(reply)
    mapFlush(false)
  else
    fleet.fails = fleet.fails + 1
    local why = tostring(ok and err or res or "no answer"):gsub("%s+", " ")
    fleet.status = "NOT reaching " .. LIVE_URL .. ": " .. why
    if fleet.fails >= 5 then fleet.retryAt = os.clock() + 30 end            -- keep trying every 30 s: the app may simply not be listening yet
  end
end

local function say(...)
  local lines = { ... }
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  for i, l in ipairs(lines) do
    term.setCursorPos(1, i)
    term.write(tostring(l))
  end
  local parts = {}
  for i = 2, #lines do
    if tostring(lines[i]) ~= "" then parts[#parts + 1] = tostring(lines[i]) end
  end
  fleet.msg = table.concat(parts, " ")
  fleet.act = ""                                               -- a new screen: the old "trying to ..." is stale
  fleetSend(false)
  local w, h = term.getSize()
  if fleet.status ~= "" and h > #lines + 1 then
    term.setCursorPos(1, h)
    term.write(("App: " .. fleet.status):sub(1, w))
  end
  if fleet.world and #lines + 3 <= h - 1 then
    term.setCursorPos(1, #lines + 2)
    term.write("World " .. fleet.world[1] .. " " .. fleet.world[2] .. " " .. fleet.world[3])
    local n = fleet.peers[1]
    if n then
      local d = math.abs(n.x - fleet.world[1]) + math.abs(n.y - fleet.world[2]) + math.abs(n.z - fleet.world[3])
      term.setCursorPos(1, #lines + 3)
      term.write("Nearest " .. n.name .. " " .. d .. " blocks")
    end
  end
end

-- the last screen of a program: shown, reported as finished
local function finish(...)
  fleet.done = true
  say(...)
  mapFlush(true)
  fleetSend(true)
end

-- run the program's main(); report errors / Ctrl+T / a Fleet "stop" before ending
local function runMain(main)
  if fleet.on then writeFile("carve.live", LIVE_URL) end       -- so "carve start <id> <program>" knows where the app is
  fleetSend(true)
  local ok, err = pcall(main)
  if not ok then
    if fleet.stopAsked and tostring(err):find("Terminated") then      -- Stop on the Fleet page really stops: no automatic restart afterwards
      pcall(removeStartup); if STATE_FILE then pcall(fs.delete, STATE_FILE) end
      fleet.msg = "Stopped from the Fleet page. It will not restart by itself."
    else
      fleet.msg = tostring(err):find("Terminated") and "Stopped (resumes with: carve resume)" or ("Error: " .. tostring(err))
    end
    fleetSend(true)
    error(err, 0)
  end
end

local function itemName(slot)
  local it = turtle.getItemDetail(slot)
  return it and it.name or nil
end

local function has(name, pattern)
  return name ~= nil and name:find(pattern, 1, true) ~= nil
end

-- chests (and furnaces) a turtle carries are building material: never dumped into a chest
local function isChestItem(n) return n ~= nil and (n:find("chest", 1, true) ~= nil or n:find("barrel", 1, true) ~= nil) end
local function isBuildItem(n) return isChestItem(n) or n == "minecraft:furnace" end

local PROTECTED = { "furnace", "chest", "barrel", "hopper", "crafting_table", "shulker", "smoker" }
local function isProtected(data)
  local n = type(data) == "table" and data.name or ""
  for _, w in ipairs(PROTECTED) do
    if n:find(w, 1, true) then return true end
  end
  return false
end

-- burn items whose name contains one of BURN (a list) until the turtle has `target` fuel
local function burn(target)
  local lvl = turtle.getFuelLevel()
  if lvl == "unlimited" then return end
  target = math.min(target, turtle.getFuelLimit())
  for s = 1, 16 do
    if turtle.getFuelLevel() >= target then break end
    local n = itemName(s)
    if n then
      for _, w in ipairs(BURN) do
        if n:find(w, 1, true) and not (KEEP and KEEP[s]) then
          turtle.select(s)
          while turtle.getItemCount(s) > 0 and turtle.getFuelLevel() < target do
            if not turtle.refuel(1) then break end
          end
          break
        end
      end
    end
  end
  turtle.select(1)
end

local function ensureFuel()
  local lvl = turtle.getFuelLevel()
  if lvl == "unlimited" or lvl > 150 then return end
  act("refuelling")
  burn(600)
  while turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() < 5 do
    say(TITLE, "", "Out of fuel! Put " .. FUEL_HINT, "in my inventory.")
    sleep(5)
    burn(600)
  end
end

local function turnTo(f)
  local diff = (f - face) % 4
  if diff == 3 then
    turtle.turnLeft()
    face = (face + 2) % 4 + 1
    savePos()
  else
    for _ = 1, diff do
      turtle.turnRight()
      face = face % 4 + 1
      savePos()
    end
  end
end

-- move one cell in direction d (digging leaves/dirt out of the way, never furnaces or chests)
local function step(d)
  ensureFuel()
  local detect, dig, inspect, attack, move
  if d == 5 then
    detect, dig, inspect, attack, move = turtle.detectUp, turtle.digUp, turtle.inspectUp, turtle.attackUp, turtle.up
  elseif d == 6 then
    detect, dig, inspect, attack, move = turtle.detectDown, turtle.digDown, turtle.inspectDown, turtle.attackDown, turtle.down
  else
    turnTo(d)
    detect, dig, inspect, attack, move = turtle.detect, turtle.dig, turtle.inspect, turtle.attack, turtle.forward
  end
  local tries = 0
  while true do
    local ok, err = move()
    if ok then
      pos.x, pos.y, pos.z = pos.x + DX[d], pos.y + DY[d], pos.z + DZ[d]
      savePos()
      mapSee()
      fleetSend(false)                                         -- keeps the position on the Fleet map moving
      return
    end
    tries = tries + 1
    if err and tostring(err):lower():find("fuel") then
      ensureFuel()
      sleep(1)
    elseif detect() then
      local _, data = inspect()
      if isProtected(data) then
        say(TITLE, "", "Blocked by " .. tostring(data.name), "Clear the way. Waiting...")
        act("blocked by " .. tostring(data.name):gsub("^minecraft:", "") .. ", waiting for it to be cleared")
        fleetSend(true)
        sleep(3)
      else
        act("digging through " .. tostring(type(data) == "table" and data.name or "a block"):gsub("^minecraft:", ""))
        dig()
      end
    else
      act("something is in my way, attacking it")
      attack()
      sleep(0.4)
    end
    if tries % 25 == 0 then sleep(2) end
  end
end

-- go to (x, y, z), moving along the axes in the order given, e.g. "yzx"
local function goTo(x, y, z, order)
  act("walking to " .. x .. ", " .. y .. ", " .. z)
  for c in (order or "yzx"):gmatch(".") do
    if c == "y" then
      while pos.y < y do step(5) end
      while pos.y > y do step(6) end
    elseif c == "z" then
      while pos.z < z do step(1) end
      while pos.z > z do step(3) end
    else
      while pos.x < x do step(2) end
      while pos.x > x do step(4) end
    end
  end
end

local function freeSlots()
  local n = 0
  for s = 1, 16 do
    if turtle.getItemCount(s) == 0 then n = n + 1 end
  end
  return n
end

-- drop everything except the slots in `keep` (a set) into whatever container is in front
local function dumpFront(keep)
  for s = 1, 16 do
    if turtle.getItemCount(s) > 0 and not (keep and keep[s]) and not isBuildItem(itemName(s)) then
      turtle.select(s)
      turtle.drop()
    end
  end
  turtle.select(1)
end

local function waitSeconds(total, label)
  act("waiting: " .. tostring(label))
  local left = total
  while left > 0 do
    say(TITLE, "", label, "Next check in " .. math.ceil(left) .. "s", "Ctrl+T stops (resumable).")
    local chunk = math.min(5, left)
    sleep(chunk)
    left = left - chunk
  end
end

-- make sure there is a chest in the neighbouring cell in direction d (1-4), placing one from my inventory if the
-- cell is empty. Waits until somebody gives me a chest.
local function ensureChest(d, label)
  act("making sure there is a chest for the " .. tostring(label))
  turnTo(d)
  local ok, data = turtle.inspect()
  if ok then
    if isChestItem(type(data) == "table" and data.name or nil) then return true end
    if isProtected(data) then return false end              -- a furnace or something else I must not break
    turtle.dig()                                           -- earth or stone where the chest goes: dig it out, then place the chest
  end
  while true do
    for s = 1, 16 do
      if isChestItem(itemName(s)) then
        turtle.select(s)
        local placed = turtle.place()
        turtle.select(1)
        if placed then return true end
      end
    end
    say(TITLE, "", "I need a chest for the " .. label .. ".", "Put one in my inventory", "(slot 1). Waiting...")
    sleep(5)
  end
end

-- one move without digging; false when something is in the way
local function tryMove(d)
  if d <= 4 then turnTo(d) end
  ensureFuel()
  local fn = d == 5 and turtle.up or d == 6 and turtle.down or turtle.forward
  if fn() then
    pos.x, pos.y, pos.z = pos.x + DX[d], pos.y + DY[d], pos.z + DZ[d]
    savePos()
    mapSee()
    fleetSend(false)
    return true
  end
  return false
end

-- walk to (x, y, z) in this turtle's own frame, climbing over whatever is in the way; false if it can't
local function travelTo(x, y, z)
  act("travelling to " .. x .. ", " .. y .. ", " .. z)
  for _ = 1, 3000 do
    if pos.x == x and pos.y == y and pos.z == z then return true end
    local d = pos.x < x and 2 or pos.x > x and 4 or pos.z < z and 1 or pos.z > z and 3 or nil
    if d then
      if not tryMove(d) then
        local up = 0
        while not tryMove(d) do                                 -- blocked: climb until the way is clear
          if not tryMove(5) then
            local ok, data = turtle.inspectUp()
            if ok and isProtected(data) then return false end
            turtle.digUp()
            if not tryMove(5) then return false end
          end
          up = up + 1
          if up > 40 then return false end
        end
      end
    elseif pos.y > y then
      if not tryMove(6) then return false end
    else
      if not tryMove(5) then return false end
    end
  end
  return false
end


local placed = { chest = 0, furnace = 0 }

local function jobsJson(list)
  local parts = {}
  for i, j in ipairs(list or PLAN.jobs) do
    local foot = "null"
    if j.foot then foot = "[" .. table.concat(j.foot, ",") .. "]" end
    parts[i] = '{"name":' .. jq(j.name) .. ',"slug":' .. jq(j.slug) .. ',"kind":' .. jq(j.kind) ..
      ',"furnaces":' .. (j.furnaces or 0) .. ',"foot":' .. foot .. "}"
  end
  return "[" .. table.concat(parts, ",") .. "]"
end

-- one question to the app; returns the lines of the answer, or nil and a reason
-- list = the jobs to send along (default: all of them), extra = more JSON fields like ',"turtle":12'
local function ask(action, list, extra)
  local ok, res = pcall(http.post, { url = LIVE_URL .. "/setup", timeout = 15, headers = { ["Content-Type"] = "application/json" },
    body = '{"v":1,"id":' .. os.getComputerID() .. ',"action":' .. jq(action) .. ',"jobs":' .. jobsJson(list) .. (extra or "") .. "}" })
  if not ok or not res then return nil, "Can't reach the app" end
  local text = ""
  pcall(function() text = res.readAll() or ""; res.close() end)
  local lines = {}
  for line in text:gmatch("[^\n]+") do lines[#lines + 1] = line end
  return lines
end

local function slotOf(what)
  for s = 1, 16 do
    local n = itemName(s)
    if what == "chest" and isChestItem(n) then return s end
    if what == "furnace" and n == "minecraft:furnace" then return s end
  end
end

-- standing above the target cell: put a chest / furnace in it
local function placeHere(what, label)
  local ok, data = turtle.inspectDown()
  if ok then
    local n = type(data) == "table" and data.name or ""
    if (what == "chest" and isChestItem(n)) or (what == "furnace" and n:find("furnace", 1, true)) then return true end   -- already there
    if isProtected(data) then return false end
    turtle.digDown()                                        -- earth or stone: dig it out first
  end
  while true do
    local s = slotOf(what)
    if s then
      turtle.select(s)
      local done = turtle.placeDown()
      turtle.select(1)
      if done then placed[what] = placed[what] + 1; return true end
      return false
    end
    say(TITLE, "", "I need a " .. what .. " for " .. label .. ".", "Put one in my inventory.", "Waiting...")
    sleep(5)
  end
end


-------------------------------------------------------------- build mode: craft the other turtles
-- Layout: the supply chest is BEHIND me (the materials), a sorting chest on my LEFT, the new turtle goes in FRONT of me
-- and a disk drive above it (its floppy holds the first-start program).
local GRID = { 1, 2, 3, 5, 6, 7, 9, 10, 11 }
local RESULT = 16
local function ends(n, suf) return n:sub(-#suf) == suf end
local TAG = {
  log = function(n) return ends(n, "_log") end,
  planks = function(n) return ends(n, "_planks") end,
  stone = function(n) return n == "minecraft:stone" end,
  cobble = function(n) return n == "minecraft:cobblestone" end,
  iron = function(n) return n == "minecraft:iron_ingot" end,
  redstone = function(n) return n == "minecraft:redstone" end,
  glass = function(n) return n == "minecraft:glass" end,
  pane = function(n) return n == "minecraft:glass_pane" end,
  diamond = function(n) return n == "minecraft:diamond" end,
  stick = function(n) return n == "minecraft:stick" end,
  cane = function(n) return n == "minecraft:sugar_cane" end,
  paper = function(n) return n == "minecraft:paper" end,
  coal = function(n) return n == "minecraft:coal" or n == "minecraft:charcoal" end,
  sapling = function(n) return n:find("sapling", 1, true) ~= nil end,
  chest = function(n) return n == "minecraft:chest" end,
  furnace = function(n) return n == "minecraft:furnace" end,
  computer = function(n) return n == "computercraft:computer_normal" end,
  turtle = function(n) return n == "computercraft:turtle_normal" end,
  pickaxe = function(n) return n == "minecraft:diamond_pickaxe" end,
  ctable = function(n) return n == "minecraft:crafting_table" end,
  drive = function(n) return n == "computercraft:disk_drive" end,
  disk = function(n) return n == "computercraft:disk" or (n:find("floppy", 1, true) ~= nil) end,
  hopper = function(n) return n == "minecraft:hopper" end,
  bonemeal = function(n) return n == "minecraft:bone_meal" end,
}
-- recipes: three rows of three tags ("-" = empty). supply = a ready-made one may be waiting in the chest
local R = {
  planks = { rows = { "log - -", "- - -", "- - -" }, supply = true },
  stick = { rows = { "planks - -", "planks - -", "- - -" } },
  chest = { rows = { "planks planks planks", "planks - planks", "planks planks planks" }, supply = true },
  pane = { rows = { "glass glass glass", "glass glass glass", "- - -" }, supply = true },
  computer = { rows = { "stone stone stone", "stone redstone stone", "stone pane stone" } },
  turtle = { rows = { "iron iron iron", "iron computer iron", "iron chest iron" } },
  pickaxe = { rows = { "diamond diamond diamond", "- stick -", "- stick -" } },
  ctable = { rows = { "planks planks -", "planks planks -", "- - -" } },
  furnace = { rows = { "cobble cobble cobble", "cobble - cobble", "cobble cobble cobble" }, supply = true },
  hopper = { rows = { "iron - iron", "iron chest iron", "- iron -" }, supply = true },
  drive = { rows = { "stone stone stone", "stone redstone stone", "stone redstone stone" } },        -- CC: Tweaked: 7 stone and 2 redstone
  paper = { rows = { "cane cane cane", "- - -", "- - -" }, supply = true },
  disk = { rows = { "redstone paper -", "- - -", "- - -" } },
}
local WORDS = { log = "logs", planks = "planks", stone = "stone", cobble = "cobblestone", iron = "iron ingots", redstone = "redstone",
  glass = "glass", pane = "glass panes", diamond = "diamonds", stick = "sticks", cane = "sugar cane", paper = "paper", coal = "coal",
  sapling = "saplings", hopper = "hoppers", chest = "chests", furnace = "furnaces", bonemeal = "bone meal" }

local function count(tag)
  local n = 0
  for s = 1, 16 do
    local nm = itemName(s)
    if nm and TAG[tag](nm) then n = n + turtle.getItemCount(s) end
  end
  return n
end
local function slotOfTag(tag)
  for s = 1, 16 do
    local nm = itemName(s)
    if nm and TAG[tag](nm) then return s end
  end
end
local function snapshot()
  local t = {}
  for s = 1, 16 do
    local nm = itemName(s)
    if nm then t[s] = { name = nm, count = turtle.getItemCount(s) } end
  end
  return t
end

-- what the Fleet page's Foreman tab shows: my inventory and the crafting queue
local crafting, recent, jobQ = {}, {}, {}                      -- tags being crafted (innermost last), finished ones, the turtles still to build
local function pretty(nm) return (tostring(nm or ""):gsub("^%a+:", ""):gsub("_", " ")) end
local function extraJson()
  local inv = {}
  for sl = 1, 16 do
    local nm = turtle.getItemDetail and turtle.getItemDetail(sl)
    nm = nm and nm.name
    if nm then inv[#inv + 1] = "[" .. sl .. "," .. jq(nm) .. "," .. turtle.getItemCount(sl) .. "]" end
  end
  local q = {}
  for i = #crafting, 1, -1 do
    q[#q + 1] = '{"t":' .. jq("Craft " .. pretty(crafting[i])) .. ',"s":"' .. (i == #crafting and "now" or "wait") .. '"}'
  end
  for _, j in ipairs(jobQ) do
    if j.s ~= "done" then q[#q + 1] = '{"t":' .. jq("Turtle for " .. j.name) .. ',"s":"' .. (#crafting == 0 and j.s == "now" and "now" or (j.s == "now" and "wait" or "todo")) .. '"}' end
  end
  for i = #recent, math.max(1, #recent - 5), -1 do
    q[#q + 1] = '{"t":' .. jq("Crafted " .. pretty(recent[i])) .. ',"s":"done"}'
  end
  for _, j in ipairs(jobQ) do
    if j.s == "done" then q[#q + 1] = '{"t":' .. jq("Turtle for " .. j.name) .. ',"s":"done"}' end
  end
  return ',"inv":[' .. table.concat(inv, ",") .. '],"q":[' .. table.concat(q, ",") .. "]"
end
fleet.extra = extraJson

-- Everything I own lives in two chests: the materials chest BEHIND me (3) and a sorting chest on my LEFT (4).
-- This pack only crafts when the grid holds ALL I carry, so every craft is: empty myself into the chests, take exactly the
-- ingredients, lay them out, craft, put the result into a chest. Nothing is ever carried across a craft.
local STORE = { 4, 8, 12, 13, 14, 15 }                          -- slots outside the crafting grid
local ledger = {}                                                -- [direction] = { item name = count }, from the last look into each chest

local function listChest(d)
  turnTo(d)
  local p = peripheral and peripheral.wrap and peripheral.wrap("front")
  if not (p and p.list) then ledger[d] = nil; return nil end
  local ok, l = pcall(p.list)
  if not ok or type(l) ~= "table" then return nil end
  local items = {}
  for _, st in pairs(l) do items[st.name] = (items[st.name] or 0) + st.count end
  ledger[d] = items
  return items
end
local function inChest(items, tag)
  local n = 0
  for nm, c in pairs(items) do if TAG[tag](nm) then n = n + c end end
  return n
end
local lastReport = -99
local function reportChests(force)                              -- the Foreman shows up on the Storage tab as a read-only warehouse of two chests
  if not fleet.on or not http then return end
  local now = os.clock()
  if not force and now - lastReport < 6 then return end
  lastReport = now
  local total, stacks = {}, 0
  for _, d in ipairs({ 3, 4 }) do
    for nm, c in pairs(ledger[d] or {}) do
      total[nm] = (total[nm] or 0) + c
      stacks = stacks + math.ceil(c / 64)
    end
  end
  local parts = {}
  for nm, c in pairs(total) do parts[#parts + 1] = jq(nm) .. ":" .. c end
  table.sort(parts)
  local body = '{"v":1,"id":' .. os.getComputerID() .. ',"name":' .. jq((PLAN.name or "Foreman") .. "'s chests") ..
    ',"chests":2,"max":2,"stacks":' .. stacks .. ',"slots":54,"spare":0,"items":{' .. table.concat(parts, ",") .. "}}"
  pcall(function()
    local res = http.post({ url = LIVE_URL .. "/storage", body = body, timeout = 5, headers = { ["Content-Type"] = "application/json" } })
    if res then res.readAll(); res.close() end
  end)
end

-- how many of tag I own: in my inventory plus both chests (a fresh look)
local function stock(tag)
  local n = count(tag)
  for _, d in ipairs({ 3, 4 }) do
    local it = listChest(d)
    if it then n = n + inChest(it, tag) end
  end
  turnTo(1)
  reportChests(false)
  return n
end

-- empty myself into the chests (sorting chest first). keep = a set of slots to leave alone
local function stash(keep)
  for s = 1, 16 do
    if itemName(s) and not (keep and keep[s]) then
      turtle.select(s)
      for _, d in ipairs({ 4, 3 }) do
        turnTo(d); turtle.drop()
        if turtle.getItemCount(s) == 0 then break end
      end
    end
  end
  turtle.select(1)
  turnTo(1)
  for s = 1, 16 do if itemName(s) and not (keep and keep[s]) then return false end end
  return true
end

-- take stacks from chest d until I hold n of tag; stacks of other things go to the other chest
local function pullFrom(d, tag, n)
  local other = d == 3 and 4 or 3
  turnTo(d)
  for _ = 1, 60 do
    local want = n - count(tag)
    if want <= 0 or freeSlots() < 2 then break end
    local first                                                -- suck always takes the chest's first stack: only ask for a few when that is what I want
    local p = peripheral and peripheral.wrap and peripheral.wrap("front")
    local okL, l = pcall(function() return p.list() end)
    if okL and type(l) == "table" then
      local lo
      for k in pairs(l) do if not lo or k < lo then lo = k end end
      first = lo and l[lo].name
    end
    local wanted = first and TAG[tag](first)
    local before = snapshot()
    if not (wanted and turtle.suck(want) or not wanted and turtle.suck()) then break end
    local after = snapshot()
    for s = 1, 16 do
      local a, b = after[s], before[s]
      if a and (not b or a.count > b.count) and not TAG[tag](a.name) then
        turtle.select(s); turnTo(other); turtle.drop(a.count - (b and b.count or 0)); turnTo(d)
      end
    end
    turtle.select(1)
  end
  turnTo(1)
end
local function take(tag, n)                                      -- bring n of tag into my inventory (it may already be there)
  if count(tag) >= n then return true end
  local have = {}
  for _, d in ipairs({ 3, 4 }) do
    local it = listChest(d)
    have[d] = it and inChest(it, tag) or 0
  end
  local order = have[4] > have[3] and { 4, 3 } or { 3, 4 }
  for _, d in ipairs(order) do
    if have[d] > 0 and count(tag) < n then pullFrom(d, tag, n) end
  end
  return count(tag) >= n
end

local function parseRows(rows)
  local cells = {}
  for r = 1, 3 do
    local i = 0
    for tok in rows[r]:gmatch("%S+") do i = i + 1; cells[(r - 1) * 3 + i] = tok ~= "-" and tok or false end
  end
  return cells
end

-- crafty turtles offer turtle.craft; some versions only give the crafting table's own "workbench" peripheral
local function craftFn()
  if turtle.craft then return turtle.craft end
  for _, side in ipairs({ "left", "right" }) do
    if peripheral and peripheral.getType and peripheral.getType(side) == "workbench" then
      local w = peripheral.wrap(side)
      if w and w.craft then return function(n) return w.craft(n) end end
    end
  end
  return nil
end

local function isMachine(n) return n and (n:find("turtle", 1, true) or n:find("computer", 1, true) or n:find("disk_drive", 1, true)) end

local function clearFront()
  turnTo(1)
  while turtle.detect() do
    local _, data = turtle.inspect()
    local n = type(data) == "table" and data.name or ""
    if isProtected(data) or isMachine(n) then
      say(TITLE, "", "Something is in the way in front:", n, "Waiting...")
      sleep(5)
    else
      turtle.dig()
    end
  end
end

local driveReady = false
-- the disk drive above the spot in front of me, with a floppy whose startup file installs the first-start programs
local function startupText()
  return table.concat({
    "-- written by the Carve foreman: first start of a new turtle",
    "local k = fs.open('carve.kit', 'w'); k.write('1'); k.close()      -- the agent looks for its starter kit chest once",
    "local function get(url, file)",
    "  local r = http and http.get(url)",
    "  if not r then return false end",
    "  local body = r.readAll(); r.close()",
    "  local f = fs.open(file, 'w'); f.write(body); f.close()",
    "  return true",
    "end",
    "get(" .. string.format("%q", PLAN.launcher_url or "") .. ", 'carve.lua')",
    "if get(" .. string.format("%q", PLAN.agent_url or "") .. ", 'agent.lua') then",
    "  local s = fs.open('startup.lua', 'w'); s.write('shell.run(\"agent\")'); s.close()",
    "  shell.run('agent')",
    "else print('Could not download the agent program.') end" }, "\n")
end

-- a disk drive with a floppy from an earlier run stays above the cell in front of me: use it again (nobody has to load it a second time)
local function reuseDrive()
  step(5)
  local okI, blk = turtle.inspect()
  local dv = okI and blk and tostring(blk.name):find("disk_drive", 1, true) and peripheral and peripheral.wrap and peripheral.wrap("front")
  if dv and dv.isDiskPresent and dv.isDiskPresent() and dv.getMountPath and dv.getMountPath() then
    local f = fs.open(dv.getMountPath() .. "/startup.lua", "w")
    f.write(startupText()); f.close()                           -- refresh the first-start program (the addresses may have changed)
    step(6)
    return true
  end
  step(6)
  return false
end

local function bootNew()
  turnTo(1)
  local t = peripheral and peripheral.wrap("front")
  if not (t and t.turnOn) then return nil end
  t.turnOn()
  local id
  for _ = 1, 20 do
    id = t.getID and t.getID()
    if id and id > 0 then return id end
    sleep(1)
  end
  return nil
end

local function doneList()
  local text = readFile("carve.foreman.done") or ""
  local set = {}
  for line in text:gmatch("[^\n]+") do set[line] = true end
  return set
end
local function markDone(name)
  local text = readFile("carve.foreman.done") or ""
  writeFile("carve.foreman.done", text .. name .. "\n")
end

local function waitFor(what, fn, seconds)
  local waited = 0
  while waited < seconds do
    if fn() then return true end
    say(TITLE, "", "Waiting " .. what, math.floor(waited) .. " s of " .. seconds .. " s")
    sleep(3)
    waited = waited + 3
  end
  return false
end

-- lay a recipe out and craft it once. The ingredients come out of the chests in exactly the right numbers, so nothing is left
-- over; the result goes back into a chest. Returns true, or false and why.
local function craftGrid(rows)
  local cells, total = parseRows(rows), {}
  for i = 1, 9 do if cells[i] then total[cells[i]] = (total[cells[i]] or 0) + 1 end end
  if not stash() then return false, "both chests are full: empty the chest on my left" end
  for t, c in pairs(total) do
    take(t, c)
    if count(t) < c then stash(); return false, "no " .. t end
  end
  local isStore, isGrid = {}, {}
  for _, s in ipairs(STORE) do isStore[s] = true end
  for _, g in ipairs(GRID) do isGrid[g] = true end
  for s = 1, 16 do                                             -- every stack into the store slots first: the grid is only for the layout
    local nm = itemName(s)
    if nm and not isStore[s] then
      local dest
      for _, d in ipairs(STORE) do
        if itemName(d) == nm and turtle.getItemCount(d) < 64 then dest = d; break end
      end
      for _, d in ipairs(STORE) do
        if not dest and turtle.getItemCount(d) == 0 then dest = d end
      end
      if not dest then stash(); return false, "inventory full" end
      turtle.select(s); turtle.transferTo(dest)
    end
  end
  for i = 1, 9 do
    local t = cells[i]
    if t then
      local donor
      for _, s in ipairs(STORE) do
        local nm = itemName(s)
        if not donor and nm and TAG[t](nm) then donor = s end
      end
      if not donor then stash(); return false, "no " .. t end
      turtle.select(donor); turtle.transferTo(GRID[i], 1)
    end
  end
  stash(isGrid)                                                -- the grid must hold everything I carry
  local cf = craftFn()
  if not cf then stash(); return false, "no crafting table attached" end
  turtle.select(RESULT)
  local ok, err = cf(1)
  if not ok then ok, err = cf() end
  turtle.select(1)
  local seen = {}
  if not ok then
    for i = 1, 9 do seen[i] = (itemName(GRID[i]) or "-"):gsub("^%a+:", "") .. "x" .. turtle.getItemCount(GRID[i]) end
  end
  stash()
  if ok then return true end
  return false, tostring(err or "no recipe") .. " [" .. table.concat(seen, " ") .. "]"
end

local need
local function craftOnce(tag)
  local total = {}
  for _, row in ipairs(R[tag].rows) do
    for t in row:gmatch("%S+") do if t ~= "-" then total[t] = (total[t] or 0) + 1 end end
  end
  crafting[#crafting + 1] = tag
  if fleetSend then fleetSend(false) end                       -- the Foreman tab shows what is being crafted
  for _ = 1, 2 do
    for t, c in pairs(total) do need(t, c) end                 -- every ingredient waits in a chest; a second round catches one that another craft used up
  end
  local ok, why = craftGrid(R[tag].rows)
  crafting[#crafting] = nil
  if ok then recent[#recent + 1] = tag end
  return ok, why
end

-- make sure I own n of tag (in the chests): craft what is missing, or wait for the person to put more in the chest
need = function(tag, n)
  local have = stock(tag)
  local tries, allowed = 0, n - have + 2                       -- more crafts than the shortage needs: this pack does not give me the item, so stop wasting materials
  while have < n do
    local why
    if R[tag] and tries < allowed then
      tries = tries + 1
      local ok
      ok, why = craftOnce(tag)
      if ok then why = nil end
    end
    have = stock(tag)
    if have < n and (why or not R[tag] or tries >= allowed) then
      local word = WORDS[tag] or tag
      local where = "back " .. inChest(ledger[3] or {}, tag) .. " left " .. inChest(ledger[4] or {}, tag)
      if why then
        say(TITLE, "", "Can't craft " .. word .. " here:", tostring(why):sub(1, 40), "Put " .. (n - have) .. " more " .. word .. " in the chest behind me.", where)
      elseif R[tag] then
        say(TITLE, "", "Crafting " .. word .. " does not give me " .. word .. " in this pack.", "Put " .. (n - have) .. " " .. word .. " in the chest behind me.", where)
      else
        say(TITLE, "", "Out of " .. word .. ": need " .. (n - have) .. " more.", "Put them in the chest behind me.", "Waiting... " .. where)
      end
      sleep(10)
    end
  end
end

-- a turtle with a pickaxe (or a crafting table): the upgrade recipes take the tool and the turtle side by side
local function upgrade(tool)
  need(tool, 1); need("turtle", 1)
  local last
  for _, rows in ipairs({ { tool .. " turtle -", "- - -", "- - -" }, { "turtle " .. tool .. " -", "- - -", "- - -" } }) do
    local ok, why = craftGrid(rows)
    if ok then return end
    last = why
  end
  error("could not fit the " .. tool .. " on the turtle: " .. tostring(last), 0)
end
local function makeTurtle(crafty)
  need("turtle", 1)
  upgrade("pickaxe")
  if crafty then upgrade("ctable") end
end

-- eat some of the chest's coal so I can walk (stepping up to the disk drive and back, placing chests); the rest goes back
local function topUpFuel(target)
  local lvl = turtle.getFuelLevel()
  if lvl == "unlimited" then return end
  target = math.min(target or 1000, turtle.getFuelLimit())
  if lvl >= target then return end
  act("refuelling")
  say(TITLE, "", "Getting some fuel from the chest...", "fuel " .. tostring(lvl) .. " of " .. target)
  take("coal", math.max(1, math.ceil((target - lvl) / 80)))
  burn(target)
  stash()
end

-- the disk drive with its floppy: crafted once, stays above the cell in front of me for every turtle
local function ensureDrive()
  if driveReady then return end
  if reuseDrive() then driveReady = true; return end
  for _ = 1, 3 do                                              -- craft all three into the chests first (a craft empties me), then take them
    need("drive", 1); need("disk", 1); need("hopper", 1)
    if stock("drive") >= 1 and stock("disk") >= 1 and stock("hopper") >= 1 then break end
  end
  stash()
  take("drive", 1); take("disk", 1); take("hopper", 1)
  step(5)
  clearFront()
  turtle.select(slotOfTag("drive") or 1)
  local placedDrive, whyDrive = turtle.place()
  turtle.select(1)
  if not placedDrive then error("could not place the disk drive: " .. tostring(whyDrive), 0) end
  local function present(side)
    local dv = peripheral and peripheral.wrap and peripheral.wrap(side or "front")
    return dv and dv.isDiskPresent and dv.isDiskPresent() and dv or nil
  end
  local function waitPresent(secs)
    for _ = 1, secs do
      if present() then return true end
      sleep(1)
    end
    return false
  end
  local function haveDisk()                                    -- a floppy in my inventory (craft another if one fell on the ground)
    if not slotOfTag("disk") then
      for sl = 1, 16 do                                        -- it may be lying in front of me: pick it up
        if turtle.getItemCount(sl) == 0 then turtle.select(sl); turtle.suck(); break end
      end
      turtle.select(1)
    end
    if not slotOfTag("disk") then                              -- the chests are down at the working level: go back, craft one, come up again
      local hadHopper = slotOfTag("hopper") ~= nil
      step(6)
      stash()
      need("disk", 1)
      take("disk", 1)
      if hadHopper then take("hopper", 1) end
      turnTo(1)
      step(5)
    end
    return slotOfTag("disk")
  end
  local inserted = false
  local notes = {}                                              -- what each try said, shown if I have to ask for help
  local hs = slotOfTag("hopper")
  local tries = 3
  if hs then                                                    -- a hopper above the drive feeds it: drop the floppy into the hopper from above
    local sl = haveDisk()
    if sl then
      hs = slotOfTag("hopper") or hs
      step(5); step(5); step(1)                                 -- two cells up and one forward: above the cell over the drive
      turtle.select(hs)
      local okH, whyH = turtle.placeDown()
      notes[#notes + 1] = "hopper " .. tostring(okH) .. (whyH and (" " .. tostring(whyH):sub(1, 18)) or "")
      sl = slotOfTag("disk") or sl
      turtle.select(sl)
      local okD, whyD = turtle.dropDown(1)
      notes[#notes + 1] = "into hopper " .. tostring(okD) .. (whyD and (" " .. tostring(whyD):sub(1, 18)) or "")
      turtle.select(1)
      sleep(2)
      step(3); step(6); step(6); turnTo(1)
      if waitPresent(8) then inserted = true end
      tries = 0                                                 -- dropping it elsewhere would only lose the floppy
    end
  end
  for attempt = 1, tries do
    local sl = haveDisk()
    if not sl then break end
    local okTry, whyTry
    if attempt == 3 then                                       -- from above, the way a hopper would feed it
      step(5); step(1)
      turtle.select(sl)
      okTry, whyTry = turtle.dropDown(1)
      turtle.select(1)
      local seen = false
      for _ = 1, 4 do
        if present("bottom") then seen = true; break end
        sleep(1)
      end
      step(3); step(6); turnTo(1)       -- back to the cell above me, facing the drive
      notes[#notes + 1] = "dropDown " .. tostring(okTry) .. (whyTry and (" " .. tostring(whyTry):sub(1, 18)) or "")
      if seen or waitPresent(2) then inserted = true; break end
    else
      turtle.select(sl)
      if attempt == 1 then okTry, whyTry = turtle.drop(1) else okTry, whyTry = turtle.place() end   -- 1: hand it over; 2: right-click the drive with it
      notes[#notes + 1] = (attempt == 1 and "drop " or "place ") .. tostring(okTry) .. (whyTry and (" " .. tostring(whyTry):sub(1, 18)) or "")
      turtle.select(1)
      if waitPresent(4) then inserted = true; break end
    end
  end
  if not inserted then
    local okI, blk = turtle.inspect()
    notes[#notes + 1] = "front " .. (okI and blk and tostring(blk.name):gsub("^%a+:", "") or "nothing")
    notes[#notes + 1] = "type " .. tostring(peripheral and peripheral.getType and peripheral.getType("front"))
    for waited = 0, 300, 3 do                                   -- neither worked: ask the person standing there
      if present() then inserted = true; break end
      local sl = slotOfTag("disk")
      say(TITLE, "", "Put the floppy in the disk drive in front of me.", sl and ("Take it from my slot " .. sl .. " and right-click the drive.") or "Pick it up from the ground and right-click the drive.", "Waiting... " .. waited .. " s", table.concat(notes, "; "))
      sleep(3)
    end
  end
  local d = present()
  local mount = d and d.getMountPath and d.getMountPath()
  if not mount then error("the disk drive did not take the floppy", 0) end
  local f = fs.open(mount .. "/startup.lua", "w")
  f.write(startupText()); f.close()
  step(6)
  driveReady = true
end

-- A new turtle does not take items from my hands (a turtle is no chest to drop into), so its starter kit goes into a CHEST standing
-- in front of the cell it will be placed in; the new turtle empties that chest by itself when it starts, then I take the chest back.
local function giveKit(job)
  local want, hasChest = { { "coal", 16 } }, false
  for _, k in ipairs(job.kit or {}) do
    if TAG[k[1]] and k[2] > 0 then
      want[#want + 1] = { k[1], k[2] + (k[1] == "chest" and 1 or 0) }          -- one more chest: the one that carries the kit
      if k[1] == "chest" then hasChest = true end
    end
  end
  if not hasChest then want[#want + 1] = { "chest", 1 } end
  for _ = 1, 2 do
    for _, k in ipairs(want) do need(k[1], k[2]) end           -- all of it waits in the chests; a second round catches one a craft used up
  end
  stash()
  for _, k in ipairs(want) do
    if not take(k[1], k[2]) then error("the kit for " .. job.name .. " is short of " .. (WORDS[k[1]] or k[1]), 0) end
  end
  step(1)                                                       -- onto the cell the new turtle will stand on; the chest goes one further
  turnTo(1)
  local okI, blk = turtle.inspect()
  local there = okI and type(blk) == "table" and tostring(blk.name):find("chest", 1, true)
  if not there then
    clearFront()
    local cs = slotOfTag("chest")
    if not cs then error("no chest to carry the kit", 0) end
    turtle.select(cs)
    local placed, why = turtle.place()
    turtle.select(1)
    if not placed then error("could not place the kit chest: " .. tostring(why), 0) end
  end
  for _, k in ipairs(want) do
    local tag = k[1]
    local left = k[2] - ((tag == "chest" and not there) and 1 or 0)        -- the placed chest is not part of the kit
    for sl = 1, 16 do
      local nm = itemName(sl)
      if left > 0 and nm and TAG[tag](nm) then
        turtle.select(sl)
        local c = math.min(left, turtle.getItemCount(sl))
        if turtle.drop(c) then left = left - c end
      end
    end
    turtle.select(1)
  end
  step(3)
  turnTo(1)
  stash()                                                       -- whatever is left over goes back to the chests
end

-- take the empty kit chest back (the new turtle has left): it is used again for the next one
local function takeKitChest()
  step(1)
  turnTo(1)
  local okI, blk = turtle.inspect()
  if okI and type(blk) == "table" and tostring(blk.name):find("chest", 1, true) then turtle.dig() end
  step(3)
  turnTo(1)
  stash()
end

local function buildAll(problems)
  ensureChest(3, "materials")
  ensureChest(4, "sorting")
  listChest(3); listChest(4); turnTo(1)
  reportChests(true)                                           -- what is in the chests, for the Storage tab
  topUpFuel(1000)
  local done = doneList()
  local todo = {}
  for _, j in ipairs(PLAN.jobs) do
    if j.kind ~= "agent" and j.kind ~= "foreman" then todo[#todo + 1] = j end
  end
  local made = 0
  jobQ = {}
  for _, j in ipairs(todo) do jobQ[#jobQ + 1] = { name = j.name, s = done[j.name] and "done" or "todo" } end
  for i, j in ipairs(todo) do
    fleet.n, fleet.total = i - 1, #todo
    if jobQ[i] and jobQ[i].s ~= "done" then jobQ[i].s = "now" end
    if not done[j.name] then
      say(TITLE, "", "Building the turtle for " .. j.name, i .. " of " .. #todo)
      topUpFuel(400)
      makeTurtle(j.crafty)
      ensureDrive()
      giveKit(j)                                                -- the kit waits in a chest in front of the cell the new turtle will take
      stash()
      take("turtle", 1)
      clearFront()
      turtle.select(slotOfTag("turtle") or 1)
      if not turtle.place() then
        turtle.select(1)
        problems[#problems + 1] = "couldn't place the turtle for " .. j.name
        return made
      end
      turtle.select(1)
      local id = bootNew()
      if not id then
        problems[#problems + 1] = "the new turtle for " .. j.name .. " did not start"
        return made
      end
      ask("spawn", { j }, ',"turtle":' .. id .. ',"rel":[0,0,1]')
      say(TITLE, "", "Waiting for " .. j.name .. "'s turtle", "(#" .. id .. ") to report in...")
      local ready = waitFor("for turtle #" .. id .. " to report", function()
        local lines = ask("ready", { j }, ',"turtle":' .. id)
        return lines and lines[1] == "ready"
      end, 600)
      if not ready then
        problems[#problems + 1] = "turtle #" .. id .. " never reported in (is the app address reachable from it?)"
        return made
      end
      local lines = ask("dispatch", { j }) or {}
      local sent = false
      for _, l in ipairs(lines) do
        if l:match("^sent ") then sent = true elseif l:match("^fail ") then problems[#problems + 1] = l end
      end
      if not sent then return made end
      waitFor("for " .. j.name .. "'s turtle to leave", function() return not turtle.detect() end, 1200)
      takeKitChest()
      markDone(j.name)
      if jobQ[i] then jobQ[i].s = "done" end
      made = made + 1
    end
  end
  fleet.n, fleet.total = #todo, #todo
  return made
end

local function main()
  if not turtle then printError("This program must run on a turtle."); return end
  if args[1] == "stop" then
    removeStartup(); fs.delete(STATE_FILE)
    finish(TITLE, "", "Stopped. The automatic restart is removed.")
    return
  end
  if args[1] == "resume" and loadPos() then
    say(TITLE, "", "Resuming after a restart...")
  else
    fs.delete(STATE_FILE)
    pos.x, pos.y, pos.z, face = 0, 0, 0, 1
    savePos()
  end
  if not fleet.on then
    say(TITLE, "", "Live reporting is off, so I can't", "ask where the jobs are.", "Upload me with live reporting", "ticked, and start the Fleet tab.")
    return
  end
  installStartup()
  local problems = {}
  if PLAN.build then
    if not craftFn() then                                   -- a plain turtle can become crafty by equipping a crafting table
      local notes, tableSide = {}, nil
      for s = 1, 16 do
        if itemName(s) == "minecraft:crafting_table" then
          turtle.select(s)
          for _, side in ipairs({ "Right", "Left" }) do
            if not craftFn() then
              local ok, res, err = pcall(turtle["equip" .. side])
              notes[#notes + 1] = side .. ": " .. tostring(ok and (res and "ok" or err) or res)
              if ok and res then tableSide = side end
              sleep(0.5)
            end
          end
          turtle.select(1)
          if craftFn() then break end
        end
      end
      if tableSide then                                       -- the tool goes on the other side (equipping on an occupied side swaps)
        for s = 1, 16 do
          if itemName(s) == "minecraft:diamond_pickaxe" then
            turtle.select(s)
            pcall(turtle["equip" .. (tableSide == "Right" and "Left" or "Right")])
            turtle.select(1)
            break
          end
        end
      end
      if not craftFn() then
        removeStartup()
        local eq = {}
        for _, side in ipairs({ "Left", "Right" }) do
          local fn = turtle["getEquipped" .. side]
          if fn then
            local ok, d = pcall(fn)
            eq[#eq + 1] = side:sub(1, 1) .. "=" .. tostring(ok and type(d) == "table" and d.name or ok and d or "?"):gsub("^%a+:", "")
          end
        end
        local sides = {}
        for _, side in ipairs({ "left", "right" }) do
          sides[#sides + 1] = side:sub(1, 1) .. "=" .. tostring(peripheral and peripheral.getType and peripheral.getType(side))
        end
        say(TITLE, "", "I can't craft yet.", "No crafting table is attached.", table.concat(notes, " "):sub(1, 38), "equipped " .. table.concat(eq, " "), "peripherals " .. table.concat(sides, " "))
        finish(TITLE, "", "Can't craft: " .. table.concat(notes, " "):sub(1, 24), "equipped " .. table.concat(eq, " "), "peripherals " .. table.concat(sides, " "))
        return
      end
    end
    if args[1] ~= "resume" then fs.delete("carve.foreman.done") end
    local made = buildAll(problems)
    local msg = made .. " turtles built and sent out."
    if #problems == 0 then
      removeStartup(); fs.delete(STATE_FILE)
      finish(TITLE, "", "Done. " .. msg)
    else
      finish(TITLE, "", msg, problems[1]:sub(1, 38))
    end
    return
  end
  -- 1. where everything goes
  local plan
  while true do
    local lines, why = ask("plan")
    if lines then
      plan = {}
      for _, l in ipairs(lines) do
        local what, name, x, y, z = l:match("^(%a+) (.-) (-?%d+) (-?%d+) (-?%d+)$")
        if what == "chest" or what == "furnace" then
          plan[#plan + 1] = { what = what, name = name, x = tonumber(x), y = tonumber(y), z = tonumber(z) }
        elseif l:match("^skip ") or l:match("^error ") then
          problems[#problems + 1] = l
        end
      end
      local err = problems[1] and problems[1]:match("^error (.*)$")
      if not err then break end
      say(TITLE, "", err, "Waiting...")
      problems = {}
    else
      say(TITLE, "", why or "No answer from the app", "Waiting...")
    end
    sleep(5)
  end
  -- 2. build the chests and furnaces
  for i, p in ipairs(plan) do
    fleet.n, fleet.total = i - 1, #plan
    say(TITLE, "", "Placing " .. p.what .. " for " .. p.name, i .. " of " .. #plan)
    if not travelTo(p.x, p.y, p.z) then
      goTo(p.x, p.y, p.z, "xzy")                            -- the gentle way failed: dig a path, level first (never down onto a chest)
    end
    if not placeHere(p.what, p.name) then
      problems[#problems + 1] = "couldn't place the " .. p.what .. " for " .. p.name
    end
  end
  fleet.n, fleet.total = #plan, #plan
  if not travelTo(0, 0, 0) then goTo(0, 0, 0, "xzy") end
  turnTo(1)
  -- 3. hand every job to an idle agent
  local sent = 0
  if PLAN.dispatch then
    say(TITLE, "", "Chests and furnaces are in place.", "Sending the jobs to idle agents...")
    local lines = ask("dispatch") or {}
    for _, l in ipairs(lines) do
      if l:match("^sent ") then sent = sent + 1 elseif l:match("^fail ") then problems[#problems + 1] = l end
    end
  end
  removeStartup()
  fs.delete(STATE_FILE)
  local msg = placed.chest .. " chests, " .. placed.furnace .. " furnaces placed."
  if PLAN.dispatch then msg = msg .. " " .. sent .. " jobs sent." end
  if #problems > 0 then
    finish(TITLE, "", msg, problems[1]:sub(1, 38), (#problems > 1) and ("(+" .. (#problems - 1) .. " more, see the app)") or "")
  else
    finish(TITLE, "", "Done. " .. msg)
  end
end

if rawget(_G, "CARVE_TEST") then
  return { main = main, pos = pos }
end
runMain(main)
