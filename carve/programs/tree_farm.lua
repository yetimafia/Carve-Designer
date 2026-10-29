-- built by Carve Designer v5.6
-- Carve tree farm: plants saplings on a grid, waits (or uses bone meal), chops the trees,
-- replants and keeps the logs in the chest behind the start. Stop it with Ctrl+T; it resumes by itself.
-- Setup: flat ground (dirt or grass) with free space. Stand on the START cell facing the first row.
--   slot 1 = saplings, slot 2 = bone meal (only if you chose to use it). A chest goes right behind the start.
-- Run again with  stop  to cancel the automatic restart.

local args = { ... }

local PLAN = {bonemeal = false, chest = true, cols = 2, cycles = 0, kind = "treefarm", label = "Juno", live = "http://127.0.0.1:8765", name = "Tree farm", rows = 2, sapling = "minecraft:oak_sapling", spacing = 4, wait = 60}

local STATE_FILE = "carve.farm"
local TITLE = PLAN.name or "Tree farm"
local FUEL_HINT = "logs, sticks or coal"
local BURN = { "log", "stick", "coal", "charcoal", "planks" }
local KEEP = {}

---------------------------------------------------------------- shared helpers (position, moving, fuel)
-- directions: 1 = +z (forward at start), 2 = +x (right), 3 = -z (back), 4 = -x (left), 5 = up, 6 = down
-- every turtle names itself after a Roman god (by its id) the first time it starts, if it has no label yet
do
  local GODS = { "Jupiter", "Juno", "Neptune", "Minerva", "Mars", "Venus", "Apollo", "Diana", "Vulcan", "Vesta", "Mercury", "Ceres", "Bacchus", "Pluto", "Saturn", "Janus", "Aurora", "Bellona", "Cupid", "Faunus", "Flora", "Fortuna", "Juventas", "Luna", "Sol", "Terra", "Pomona", "Proserpina", "Quirinus", "Somnus", "Victoria", "Vertumnus", "Tellus", "Ops", "Orcus", "Nox" }
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
  if cmd == "stop" then os.queueEvent("terminate") end
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
    fleet.msg = tostring(err):find("Terminated") and "Stopped (resumes with: carve resume)" or ("Error: " .. tostring(err))
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


local SAPLING_SLOT, BONE_SLOT = 1, 2
local cycle = 0

local SAP = PLAN.sapling                -- the kind I plant; changes if I was given another kind of sapling

local function isAnySapling(name)
  return name ~= nil and (name:find("sapling", 1, true) ~= nil or name:find("propagule", 1, true) ~= nil)
end

local function isSapling(name)
  if not name then return false end
  if SAP == "any" then return isAnySapling(name) end
  return name == SAP
end

-- look through the whole inventory: if there are none of the chosen kind but there are saplings of another kind, plant those
local function adoptSaplings()
  local count, best = {}, nil
  for s = 1, 16 do
    local n = itemName(s)
    if isAnySapling(n) then
      count[n] = (count[n] or 0) + turtle.getItemCount(s)
      if not best or count[n] > count[best] then best = n end
    end
  end
  if SAP ~= "any" and (count[SAP] or 0) == 0 and best then
    SAP = best
    say(TITLE, "", "No " .. tostring(PLAN.sapling):gsub("minecraft:", "") .. " found.", "Planting " .. best:gsub("minecraft:", "") .. " instead.")
    sleep(2)
  end
end

-- move whatever is in slot `s` to another empty slot (false if there is none)
local function clearSlot(s)
  for t = 16, 1, -1 do
    if t ~= s and turtle.getItemCount(t) == 0 then
      turtle.select(s)
      turtle.transferTo(t)
      turtle.select(1)
      return true
    end
  end
  return false
end

-- make slot 1 hold saplings of the right kind (collect them from other slots)
local function gatherSaplings()
  local first = itemName(SAPLING_SLOT)
  if first and not isSapling(first) then clearSlot(SAPLING_SLOT) end
  for s = 1, 16 do
    if s ~= SAPLING_SLOT and isSapling(itemName(s)) then
      local here = itemName(SAPLING_SLOT)
      if here == nil or here == itemName(s) then
        turtle.select(s)
        turtle.transferTo(SAPLING_SLOT)
      end
    end
  end
  if PLAN.bonemeal then                                       -- and bone meal in slot 2, wherever I was handed it
    local second = itemName(BONE_SLOT)
    if second and not has(second, "bone_meal") then clearSlot(BONE_SLOT) end
    for s = 1, 16 do
      if s ~= SAPLING_SLOT and s ~= BONE_SLOT and has(itemName(s), "bone_meal") then
        local here = itemName(BONE_SLOT)
        if here == nil or has(here, "bone_meal") then
          turtle.select(s)
          turtle.transferTo(BONE_SLOT)
        end
      end
    end
  end
  turtle.select(1)
end

local function saplingsLeft()                       -- every slot counts, not just slot 1
  local n = 0
  for s = 1, 16 do
    if isSapling(itemName(s)) then n = n + turtle.getItemCount(s) end
  end
  return n
end

local function boneLeft()
  if not PLAN.bonemeal then return 0 end
  local n = itemName(BONE_SLOT)
  return (n and n:find("bone_meal", 1, true)) and turtle.getItemCount(BONE_SLOT) or 0
end

local function front()
  local ok, data = turtle.inspect()
  if not ok then return nil end
  return data.name or "?"
end

local function chop()
  turtle.dig()
  step(1)                                 -- into the trunk's base cell
  while true do
    local ok, data = turtle.inspectUp()
    if ok and (has(data.name, "log") or has(data.name, "wood") or has(data.name, "stem")) then
      turtle.digUp()
      step(5)
    else
      break
    end
  end
  while pos.y > 0 do step(6) end
  for _ = 1, 3 do turtle.suckDown() ; turtle.suck(); turtle.suckUp() end   -- saplings and apples that fell here
  step(3)                                 -- back to where I stood
  turnTo(1)
  for _ = 1, 3 do turtle.suck() end
  gatherSaplings()
end

local function plant()
  if not isSapling(itemName(SAPLING_SLOT)) then gatherSaplings() end       -- slot 1 ran out: refill it from the other slots
  if saplingsLeft() == 0 then return false end
  turtle.select(SAPLING_SLOT)
  local ok = turtle.place()
  turtle.select(1)
  return ok
end

local function useBone()
  local tries = 0
  while boneLeft() > 0 and tries < 8 do
    local n = front()
    if not has(n, "sapling") and not has(n, "propagule") then break end
    turtle.select(BONE_SLOT)
    turtle.place()
    turtle.select(1)
    tries = tries + 1
  end
end

-- what to do at one spot (I stand next to it, looking at it). Returns "chopped", "planted", "growing" or "skipped"
local function handleSpot()
  turnTo(1)
  local n = front()
  local result
  if n == nil then
    result = plant() and "planted" or "skipped"
  elseif has(n, "log") or has(n, "wood") or has(n, "stem") then
    chop()
    plant()
    result = "chopped"
  elseif has(n, "leaves") then
    turtle.dig()
    result = plant() and "planted" or "skipped"
  elseif has(n, "sapling") or has(n, "propagule") then
    result = "growing"
  else
    result = "skipped"
  end
  if PLAN.bonemeal and (result == "planted" or result == "growing" or result == "chopped") then
    useBone()
    n = front()
    if n and (has(n, "log") or has(n, "wood") or has(n, "stem")) then
      chop()
      plant()
      useBone()
      result = "chopped"
    elseif n and (has(n, "sapling") or has(n, "propagule")) then
      result = "growing"
    end
  end
  return result
end

local function home()
  goTo(0, 0, pos.z, "y")
  goTo(0, 0, pos.z, "x")
  goTo(0, 0, 0, "z")
  turnTo(1)
end

local function unload()
  home()
  gatherSaplings()
  burn(500)
  local keep = {}
  for s = 1, 16 do
    if isSapling(itemName(s)) then keep[s] = true end                       -- never drop saplings into the chest
  end
  if PLAN.bonemeal and has(itemName(BONE_SLOT), "bone_meal") then keep[BONE_SLOT] = true end
  if PLAN.chest then
    turnTo(3)
    dumpFront(keep)
    turnTo(1)
  elseif freeSlots() < 3 then
    while freeSlots() < 3 do
      say(TITLE, "", "Inventory full - empty me.", "Waiting...")
      sleep(3)
    end
  end
end

-- walk to the lane of row z (only ever along the free corridor at x = 0 and the lane cells)
local function toLane(z)
  goTo(0, 0, pos.z, "yx")
  goTo(0, 0, z, "z")
end

local function pass()
  local stats = { chopped = 0, planted = 0, growing = 0, skipped = 0 }
  local S = PLAN.spacing
  for j = 0, PLAN.rows - 1 do
    local z = j * S
    toLane(z)                             -- via the free corridor at x = 0
    for i = 1, PLAN.cols do
      local x = i * S
      goTo(x, 0, z, "x")
      say(TITLE, "", "Row " .. (j + 1) .. "/" .. PLAN.rows .. "  tree " .. i .. "/" .. PLAN.cols,
          "Cycle " .. (cycle + 1), "Saplings " .. saplingsLeft() .. "  bone meal " .. boneLeft())
      local r = handleSpot()
      stats[r] = stats[r] + 1
      if freeSlots() < 2 then
        if PLAN.chest then unload(); toLane(z); goTo(x, 0, z, "x") end
      end
    end
    goTo(0, 0, z, "x")
  end
  return stats
end

-- after a restart the turtle may be up a tree or standing where a tree is: get back to the corridor
local function recover()
  while pos.y > 0 do step(6) end
  while pos.y < 0 do step(5) end
  if pos.z % PLAN.spacing ~= 0 then
    goTo(pos.x, 0, pos.z - (pos.z % PLAN.spacing), "z")
  end
  home()
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
    recover()
  else
    fs.delete(STATE_FILE)
    pos.x, pos.y, pos.z, face = 0, 0, 0, 1
    savePos()
  end
  installStartup()
  if PLAN.chest then ensureChest(3, "logs"); turnTo(1) end      -- place my own chest behind the start if there is none
  adoptSaplings()
  gatherSaplings()
  if args[1] ~= "resume" then
    while saplingsLeft() == 0 do
      say(TITLE, "", "No saplings in my inventory.", "Put some in (any slot). Waiting...")
      sleep(5)
      adoptSaplings()
    end
    gatherSaplings()
  end
  while true do
    local st = pass()
    cycle = cycle + 1
    fleet.n, fleet.total = cycle, PLAN.cycles
    unload()
    if PLAN.cycles > 0 and cycle >= PLAN.cycles then break end
    if not (PLAN.bonemeal and st.growing == 0 and boneLeft() > 0) then
      waitSeconds(PLAN.wait, "Chopped " .. st.chopped .. " planted " .. st.planted .. " growing " .. st.growing)
    end
  end
  removeStartup()
  fs.delete(STATE_FILE)
  finish(TITLE, "", "Done after " .. cycle .. " cycle(s).")
end

if rawget(_G, "CARVE_TEST") then
  return { main = main, pos = pos }
end
runMain(main)
