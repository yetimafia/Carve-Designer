-- built by Carve Designer v5.7
-- Carve scout: walks (and flies) through open space, looks at every block around it and reports what it
-- sees to the Designer's Fleet map. It never digs, never places and never enters water or lava.
-- Stand on the START cell facing forward (+z). It explores within PLAN.radius blocks of the start and from
-- PLAN.down below to PLAN.up above it, then comes back. Fuel: put coal (or anything burnable) in its inventory.
-- Run again with  stop  to cancel the automatic restart.

local args = { ... }

local PLAN = {down = 2, kind = "scout", label = "Venus", live = "http://127.0.0.1:8765", name = "Scout", radius = 8, up = 3}

local STATE_FILE = "carve.scout"
local TITLE = PLAN.name or "Scout"
local FUEL_HINT = "coal, charcoal or wood"
local BURN = { "coal", "charcoal", "log", "planks", "stick" }

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


local R, UP, DOWN = PLAN.radius, PLAN.up, PLAN.down
local home = { 0, 0, 0 }
local known = {}                -- key -> block name ("air" for empty space)
local seen = 0                  -- how many cells are known
local visited = {}
local nvisited = 0
local outbox = {}               -- cells not yet sent to the app
local lastFlush = 0

local function key(x, y, z) return ((x + 256) * 512 + (z + 256)) * 512 + (y + 256) end
local function inside(x, y, z) return math.abs(x) <= R and math.abs(z) <= R and y >= -DOWN and y <= UP end

local function learn(x, y, z, name)
  local k = key(x, y, z)
  if known[k] then return end
  known[k] = name
  seen = seen + 1
  outbox[#outbox + 1] = { x, y, z, name }
end

local function flush(force)
  if #outbox == 0 or not fleet.on then outbox = fleet.on and outbox or {}; return end
  if not force and #outbox < 60 and os.clock() - lastFlush < 5 then return end
  lastFlush = os.clock()
  while #outbox > 0 do
    local parts, sent = {}, {}
    for i = 1, math.min(#outbox, 400) do
      local c = table.remove(outbox)
      sent[#sent + 1] = c
      parts[#parts + 1] = "[" .. c[1] .. "," .. c[2] .. "," .. c[3] .. "," .. jq(c[4]) .. "]"
    end
    local ok, res = pcall(http.post, { url = LIVE_URL .. "/map", timeout = 5, headers = { ["Content-Type"] = "application/json" },
      body = '{"v":1,"id":' .. os.getComputerID() .. ',"cells":[' .. table.concat(parts, ",") .. "]}" })
    if ok and res then
      pcall(function() res.readAll(); res.close() end)
    else
      for _, part in ipairs(sent) do outbox[#outbox + 1] = part end      -- the app didn't get them: keep them and try again later
      break
    end
  end
end

-- what is in front of / above / below me
local function look(d)
  local ok, data
  if d == 5 then ok, data = turtle.inspectUp()
  elseif d == 6 then ok, data = turtle.inspectDown()
  else ok, data = turtle.inspect() end
  if not ok then return "air" end
  return type(data) == "table" and data.name or "unknown"
end

local function nx(d) return pos.x + DX[d], pos.y + DY[d], pos.z + DZ[d] end

-- look at all six neighbours (turning only when a side is still unknown)
local function scan()
  for _, d in ipairs({ 5, 6 }) do
    local x, y, z = nx(d)
    if not known[key(x, y, z)] then learn(x, y, z, look(d)) end
  end
  for step = 0, 3 do
    local d = (face - 1 + step) % 4 + 1
    local x, y, z = nx(d)
    if not known[key(x, y, z)] then
      turnTo(d)
      learn(x, y, z, look(d))
    end
  end
end

-- one move to a neighbouring cell that is known to be empty; false if something is in the way
local function move(d)
  ensureFuel()
  if d <= 4 then turnTo(d) end
  local fn = d == 5 and turtle.up or d == 6 and turtle.down or turtle.forward
  for _ = 1, 3 do
    if fn() then
      pos.x, pos.y, pos.z = pos.x + DX[d], pos.y + DY[d], pos.z + DZ[d]
      savePos()
      return true
    end
    sleep(0.5)
  end
  local x, y, z = nx(d)
  known[key(x, y, z)] = "blocked"          -- something we can't see (a mob, a block that changed): don't try again
  return false
end

-- shortest way through known empty cells from here to the nearest cell that satisfies goal(x, y, z)
local function route(goal)
  local start = key(pos.x, pos.y, pos.z)
  local prev, queue, head = { [start] = false }, { { pos.x, pos.y, pos.z } }, 1
  while head <= #queue do
    local c = queue[head]
    head = head + 1
    if goal(c[1], c[2], c[3]) then
      local path, k = {}, key(c[1], c[2], c[3])
      while prev[k] do
        table.insert(path, 1, prev[k][2])
        k = prev[k][1]
      end
      return path
    end
    for d = 1, 6 do
      local x, y, z = c[1] + DX[d], c[2] + DY[d], c[3] + DZ[d]
      local k = key(x, y, z)
      if prev[k] == nil and known[k] == "air" and inside(x, y, z) then
        prev[k] = { key(c[1], c[2], c[3]), d }
        queue[#queue + 1] = { x, y, z }
      end
    end
    if head % 400 == 0 then sleep(0) end
  end
  return nil
end

local function isFrontier(x, y, z)
  return not visited[key(x, y, z)]
end

-- go back to the start cell by the known way (waits for fuel if needed)
local function goHome()
  local path = route(function(x, y, z) return x == home[1] and y == home[2] and z == home[3] end)
  if not path then return false end
  for _, d in ipairs(path) do
    if not move(d) then return false end
  end
  return true
end

local function visit()
  local k = key(pos.x, pos.y, pos.z)
  if not visited[k] then visited[k] = true; nvisited = nvisited + 1 end
  known[k] = "air"
  scan()
  if nvisited % 4 == 0 then
    fleet.n, fleet.total = seen, 0
    say(TITLE, "", "Scouting: " .. nvisited .. " places visited", seen .. " blocks seen", "At " .. pos.x .. " " .. pos.y .. " " .. pos.z)
  end
  flush(false)
end

local function fuelNow()
  local f = turtle.getFuelLevel()
  return f == "unlimited" and math.huge or f
end

-- false when fuel is too low to keep going and still get home
local function explore()
  visit()
  while true do
    local path = route(isFrontier)
    if not path then return true end                      -- nothing reachable is left to look at
    local need = (math.abs(pos.x - home[1]) + math.abs(pos.y - home[2]) + math.abs(pos.z - home[3])) * 2 + #path + 30
    if fuelNow() < need then
      burn(need + 200)
      if fuelNow() < need then return false end
    end
    for _, d in ipairs(path) do
      if not move(d) then break end
    end
    visit()
  end
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
    home = { pos.x, pos.y, pos.z }                        -- what it knew is gone: finish where it stands
  else
    fs.delete(STATE_FILE)
    pos.x, pos.y, pos.z, face = 0, 0, 0, 1
    savePos()
  end
  installStartup()
  while true do
    local complete = explore()
    flush(true)
    if complete then break end
    goHome()
    while fuelNow() < 400 do
      say(TITLE, "", "Low on fuel - waiting at the start.", "Put " .. FUEL_HINT .. " in my inventory.")
      sleep(10)
      burn(1000)
    end
  end
  goHome()
  turnTo(1)
  flush(true)
  removeStartup()
  fs.delete(STATE_FILE)
  finish(TITLE, "", "Done. " .. seen .. " blocks mapped", "from " .. nvisited .. " places.")
end

if rawget(_G, "CARVE_TEST") then
  return { main = main, pos = pos }
end
runMain(main)
