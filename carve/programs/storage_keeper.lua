-- built by Carve Designer v4.7
-- Carve storage keeper: a warehouse of chests that builds itself, remembers what is in every chest and
-- reports the list to the Designer app (Storage tab of the Fleet page).
--
--   behind the start : the DROP chest. Anything put in there (by you or by a hauler) is sorted into storage.
--   left of the start: the PICKUP chest. Items you ask for on the web page are put there.
--   in front         : a corridor with up to 4 storage chests per step (right, left, above, below).
--
-- Start it with a chest in the first slot (more chests, fuel in other slots). It places the drop chest, the
-- pickup chest and then one storage chest at a time when it needs room. Chests dropped into the drop chest
-- are kept by the turtle and used to grow the warehouse.
-- Run again with  stop  to cancel the automatic restart;  reset  forgets the list of what is stored.

local args = { ... }

local PLAN = {kind = "keeper", label = "Jupiter", length = 8, live = "http://127.0.0.1:8765", name = "Storage keeper", rescan = 1800, wait = 10}

local STATE_FILE = "carve.keeper"
local INDEX_FILE = "carve.keeperidx"
local TITLE = PLAN.name or "Storage keeper"
local FUEL_HINT = "coal or charcoal"
local BURN = { "coal", "charcoal" }
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
                done = false, msg = "", seq = 0, n = 0, total = 0, cmd = nil, arg = "", world = nil, peers = {},
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

-- a GPS fix of where the turtle is right now (needs a GPS tower and a wireless modem); nil otherwise
local function gpsFix(now)
  if fleet.gpsDead or not (gps and gps.locate) or now - fleet.gpsLast < 20 then return nil end
  fleet.gpsLast = now
  local ok, x, y, z = pcall(gps.locate, 1)
  if ok and x then fleet.gpsOk, fleet.gpsFails = true, 0; return { x, y, z } end
  fleet.gpsFails = fleet.gpsFails + 1
  if fleet.gpsFails >= 2 and not fleet.gpsOk then fleet.gpsDead = true end
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
    '"msg":' .. jq(fleet.msg), '"n":' .. fleet.n, '"total":' .. fleet.total,
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
        sleep(3)
      else
        dig()
      end
    else
      attack()
      sleep(0.4)
    end
    if tries % 25 == 0 then sleep(2) end
  end
end

-- go to (x, y, z), moving along the axes in the order given, e.g. "yzx"
local function goTo(x, y, z, order)
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
    return true
  end
  return false
end

-- walk to (x, y, z) in this turtle's own frame, climbing over whatever is in the way; false if it can't
local function travelTo(x, y, z)
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


local MAXC = PLAN.length * 4            -- most storage chests this warehouse may grow to
local STACKMAX = 64
local built = 0                         -- storage chests placed so far
local idx = {}                          -- idx[k] = { [item name] = count }  for chest k
local full = {}                         -- full[k] = true while chest k refused items
local orders = {}                       -- { { item =, count = } } waiting to be put in the pickup chest
local reported = -100
local hasPeripheral = peripheral ~= nil and peripheral.wrap ~= nil
local dirty = true

local SIDES = {
  { name = "right", face = 2, drop = "drop", suck = "suck", wrap = "front" },
  { name = "left", face = 4, drop = "drop", suck = "suck", wrap = "front" },
  { name = "above", face = nil, drop = "dropUp", suck = "suckUp", wrap = "top" },
  { name = "below", face = nil, drop = "dropDown", suck = "suckDown", wrap = "bottom" },
}

local function cellOf(k) return math.floor((k - 1) / 4) + 1 end
local function sideOf(k) return SIDES[(k - 1) % 4 + 1] end

---------------------------------------------------------------- the list of what is stored
local function saveIndex()
  local out = { "built " .. built }
  for k = 1, built do
    for name, c in pairs(idx[k] or {}) do
      if c > 0 then out[#out + 1] = k .. " " .. c .. " " .. name end
    end
  end
  writeFile(INDEX_FILE, table.concat(out, "\n") .. "\n")
  dirty = true
end

local function loadIndex()
  local s = readFile(INDEX_FILE)
  if not s then return end
  built = 0
  for line in s:gmatch("[^\n]+") do
    local b = line:match("^built (%d+)$")
    if b then
      built = tonumber(b)
      for k = 1, built do idx[k] = idx[k] or {} end
    else
      local k, c, name = line:match("^(%d+) (%d+) (.+)$")
      k = tonumber(k)
      if k and k <= built then idx[k][name] = tonumber(c) end
    end
  end
end

local function totals()
  local t, stacks = {}, 0
  for k = 1, built do
    for name, c in pairs(idx[k] or {}) do
      t[name] = (t[name] or 0) + c
      stacks = stacks + math.ceil(c / STACKMAX)
    end
  end
  return t, stacks
end

local function emptyChests()
  local n = 0
  for k = 1, built do
    if next(idx[k]) == nil and not full[k] then n = n + 1 end
  end
  return n
end

---------------------------------------------------------------- talking to the app
local function chestsHeld()
  local n = 0
  for s = 1, 16 do
    if isChestItem(itemName(s)) then n = n + turtle.getItemCount(s) end
  end
  return n
end

-- send the list, get the orders back ("order <count> <item>" lines)
local function sync(force)
  if not fleet.on then return end
  local now = os.clock()
  if not force and not dirty and now - reported < 20 then return end
  if not force and now - reported < 4 then return end
  reported = now
  local t, stacks = totals()
  local parts = {}
  for name, c in pairs(t) do
    if c > 0 then parts[#parts + 1] = jq(name) .. ":" .. c end
  end
  table.sort(parts)
  local body = '{"v":1,"id":' .. os.getComputerID() .. ',"name":' .. jq(PLAN.name or "") ..
    ',"chests":' .. built .. ',"max":' .. MAXC .. ',"stacks":' .. stacks .. ',"slots":' .. (built * 27) ..
    ',"spare":' .. chestsHeld() .. ',"items":{' .. table.concat(parts, ",") .. "}}"
  local ok, res = pcall(http.post, { url = LIVE_URL .. "/storage", body = body, timeout = 5,
                                     headers = { ["Content-Type"] = "application/json" } })
  if not ok or not res then return end
  dirty = false
  local text = ""
  pcall(function() text = res.readAll() or ""; res.close() end)
  for line in text:gmatch("[^\n]+") do
    local n, item = line:match("^order (%d+) ([%w_:%.%-]+)$")
    if n and #orders < 40 then orders[#orders + 1] = { item = item, count = math.min(tonumber(n), 4096) } end
  end
end

local function status(...)
  fleet.n = built
  fleet.total = MAXC
  say(TITLE, "", ...)
  sync(false)
end

---------------------------------------------------------------- walking the corridor
local function toCell(z)
  if pos.x ~= 0 or pos.y ~= 0 then goTo(0, 0, pos.z, "yx") end
  goTo(0, 0, z, "yzx")
end

-- turn to / get ready for a chest at storage position k (or the special "pickup" / "drop" chests)
local function aim(side)
  if side.face then turnTo(side.face) end
end

local function call(side, which, ...)
  if which == "drop" then return turtle[side.drop](...) end
  return turtle[side.suck](...)
end

-- what the chest in front says it holds (needs the peripheral API); nil when it can't be asked
local function peek(side)
  if not hasPeripheral then return nil end
  local ok, p = pcall(peripheral.wrap, side.wrap)
  if not ok or type(p) ~= "table" or not p.list then return nil end
  local ok2, list = pcall(p.list)
  if not ok2 or type(list) ~= "table" then return nil end
  local out = {}
  for _, st in pairs(list) do
    if st and st.name then out[st.name] = (out[st.name] or 0) + (st.count or 0) end
  end
  return out
end

local function refresh(k, side)
  local now = peek(side)
  if now then idx[k] = now end
end

-- is there already a chest in the cell in front / above / below?
local function chestThere(side)
  local fn = side.drop == "dropUp" and turtle.inspectUp or side.drop == "dropDown" and turtle.inspectDown or turtle.inspect
  local ok, data = fn()
  return ok and isChestItem(type(data) == "table" and data.name or nil)
end

-- dig whatever is in the cell, throwing the rubble away so it doesn't fill my inventory
local function clearCell(side)
  local before = {}
  for s = 1, 16 do before[s] = { itemName(s), turtle.getItemCount(s) } end
  local detect = side.drop == "dropUp" and turtle.detectUp or side.drop == "dropDown" and turtle.detectDown or turtle.detect
  local inspect = side.drop == "dropUp" and turtle.inspectUp or side.drop == "dropDown" and turtle.inspectDown or turtle.inspect
  local dig = side.drop == "dropUp" and turtle.digUp or side.drop == "dropDown" and turtle.digDown or turtle.dig
  if detect() then
    local _, data = inspect()
    if isProtected(data) then return false end
    dig()
  end
  for s = 1, 16 do
    local n = itemName(s)
    local c = turtle.getItemCount(s)
    local b = before[s]
    local added = (b[1] == n or b[1] == nil) and (c - (b[1] == n and b[2] or 0)) or 0
    if n and added > 0 and not isChestItem(n) then
      turtle.select(s)
      turtle[side.drop](added)
    end
  end
  turtle.select(1)
  return true
end

local function placeChest(side)
  for s = 1, 16 do
    if isChestItem(itemName(s)) then
      turtle.select(s)
      local fn = side.drop == "dropUp" and turtle.placeUp or side.drop == "dropDown" and turtle.placeDown or turtle.place
      local ok = fn()
      turtle.select(1)
      return ok
    end
  end
  return false
end

-- build storage chest number built+1 if I have a chest and there is room in the plan
local function buildNext()
  if built >= MAXC or chestsHeld() == 0 then return false end
  local k = built + 1
  toCell(cellOf(k))
  local side = sideOf(k)
  aim(side)
  if not chestThere(side) then
    if not clearCell(side) or not placeChest(side) then return false end
  end
  built = k
  idx[k] = {}
  full[k] = nil
  saveIndex()
  status("Built storage chest " .. built .. " of " .. MAXC)
  return true
end

---------------------------------------------------------------- putting things away
local function dropInto(k, s)
  local side = sideOf(k)
  toCell(cellOf(k))
  aim(side)
  turtle.select(s)
  local name = itemName(s)
  local before = turtle.getItemCount(s)
  local ok = call(side, "drop")
  local moved = before - turtle.getItemCount(s)
  turtle.select(1)
  if moved > 0 then
    idx[k][name] = (idx[k][name] or 0) + moved
  end
  if not ok or turtle.getItemCount(s) > 0 then full[k] = true end
  if hasPeripheral then refresh(k, side) end
  return moved
end

-- phase 1: chests that already hold this item, 2: empty chests, 3: any other chest with room
local function tryChests(s, name, phase)
  for k = 1, built do
    if not full[k] then
      local has = idx[k][name] ~= nil
      local empty = next(idx[k]) == nil
      if (phase == 1 and has) or (phase == 2 and empty) or (phase == 3 and not has and not empty) then
        status("Storing " .. name:gsub("^minecraft:", ""))
        dropInto(k, s)
        if turtle.getItemCount(s) == 0 then return true end
      end
    end
  end
  return false
end

-- put the stack in slot s into storage. false when there is no room (and I couldn't build more)
local function storeSlot(s)
  while turtle.getItemCount(s) > 0 do
    local name = itemName(s)
    if tryChests(s, name, 1) or tryChests(s, name, 2) then break end
    if not buildNext() then                     -- a new kind of item gets its own chest if I can build one
      if tryChests(s, name, 3) then break end
      saveIndex()
      return false
    end
  end
  saveIndex()
  return true
end

-- fuel from what comes in: burn a few coal/charcoal when low
local function topUpFuel(s)
  local n = itemName(s)
  if not n or not (n:find("coal", 1, true) or n:find("charcoal", 1, true)) then return end
  local lvl = turtle.getFuelLevel()
  if lvl ~= "unlimited" and lvl < 1500 then
    turtle.select(s)
    turtle.refuel(math.min(turtle.getItemCount(s), 8))
    turtle.select(1)
  end
end

-- chests are kept to build with (up to 2 stacks); everything else goes into storage
local function storeInventory()
  local keptChests = 0
  local ok = true
  for s = 1, 16 do
    local n = itemName(s)
    if n then
      if isChestItem(n) and keptChests < 2 then
        keptChests = keptChests + 1
      elseif n == "minecraft:furnace" then
        -- never mine
      else
        topUpFuel(s)
        if turtle.getItemCount(s) > 0 and not storeSlot(s) then
          ok = false
        end
      end
    end
  end
  return ok
end

local function intake()
  toCell(0)
  turnTo(3)
  local got = 0
  while turtle.suck() do
    got = got + 1
    if freeSlots() <= 3 then
      storeInventory()
      toCell(0)
      turnTo(3)
    end
    if got > 200 then break end
  end
  turnTo(1)
  return got
end

---------------------------------------------------------------- taking things out
local function countInv(name)
  local c = 0
  for s = 1, 16 do
    if itemName(s) == name then c = c + turtle.getItemCount(s) end
  end
  return c
end

local function takeFromChest(k, name, want)
  local side = sideOf(k)
  toCell(cellOf(k))
  aim(side)
  full[k] = nil
  local before = countInv(name)
  local held = {}
  for s = 1, 16 do held[s] = itemName(s) end
  for _ = 1, 40 do
    if countInv(name) >= want or freeSlots() <= 1 then break end
    if not call(side, "suck") then break end
  end
  -- anything else I pulled out goes straight back
  for s = 1, 16 do
    local n = itemName(s)
    if n and n ~= name and n ~= held[s] and not isChestItem(n) then
      turtle.select(s)
      call(side, "drop")
    end
  end
  turtle.select(1)
  if hasPeripheral and peek(side) then
    refresh(k, side)
  else
    local left = (idx[k][name] or 0) - (countInv(name) - before)
    idx[k][name] = left > 0 and left or nil
  end
end

-- carry what is in my inventory of this item to the pickup chest. Returns how many arrived.
local function deliver(name, want)
  toCell(0)
  turnTo(4)
  local moved = 0
  for s = 1, 16 do
    if itemName(s) == name and moved < want then
      turtle.select(s)
      local before = turtle.getItemCount(s)
      turtle.drop(math.min(before, want - moved))
      moved = moved + before - turtle.getItemCount(s)
    end
  end
  turtle.select(1)
  turnTo(1)
  return moved
end

local function fulfil(order)
  local name, want = order.item, order.count
  status("Fetching " .. want .. " " .. name:gsub("^minecraft:", ""))
  local fetched = 0
  for k = 1, built do
    if (idx[k][name] or 0) > 0 and fetched < want then
      takeFromChest(k, name, want - fetched)
      fetched = countInv(name)
      if freeSlots() <= 1 then break end
    end
  end
  -- never hand out more than asked for: the surplus goes back into storage
  local moved = deliver(name, want)
  if moved == 0 and countInv(name) > 0 then
    status("The pickup chest is full.", "Empty it, then ask again.")
    storeInventory()
    return false
  end
  if countInv(name) > 0 then storeInventory() end
  saveIndex()
  return true
end

---------------------------------------------------------------- full scan of every chest
local function rescan()
  if not hasPeripheral then return end
  for k = 1, built do
    local side = sideOf(k)
    toCell(cellOf(k))
    aim(side)
    refresh(k, side)
    full[k] = nil
  end
  saveIndex()
end

local function main()
  if not turtle then printError("This program must run on a turtle."); return end
  if args[1] == "stop" then
    removeStartup(); fs.delete(STATE_FILE)
    finish(TITLE, "", "Stopped. The automatic restart is removed.")
    return
  end
  if args[1] == "reset" then fs.delete(INDEX_FILE) end
  if args[1] == "resume" and loadPos() then
    say(TITLE, "", "Resuming after a restart...")
  else
    pos.x, pos.y, pos.z, face = 0, 0, 0, 1
    savePos()
  end
  loadIndex()
  installStartup()
  ensureChest(3, "drop chest")
  ensureChest(4, "pickup chest")
  turnTo(1)
  local lastScan = os.clock()
  rescan()
  while true do
    -- 1. things people put in the drop chest
    local got = intake()
    if got > 0 then storeInventory() end
    -- 2. grow when there is no empty chest left for a new kind of item
    if emptyChests() == 0 and built < MAXC and chestsHeld() > 0 then buildNext() end
    -- 3. tell the app, then carry out what it asked for
    sync(true)
    local order = table.remove(orders, 1)
    while order do
      fulfil(order)
      order = table.remove(orders, 1)
      sync(true)
    end
    -- 4. now and then look into every chest, in case somebody changed one by hand
    if PLAN.rescan > 0 and os.clock() - lastScan >= PLAN.rescan then
      rescan()
      lastScan = os.clock()
    end
    toCell(0)
    turnTo(1)
    local t, stacks = totals()
    local kinds = 0
    for _ in pairs(t) do kinds = kinds + 1 end
    status("Waiting for deliveries", kinds .. " kinds, " .. stacks .. " stacks, " .. built .. "/" .. MAXC .. " chests",
           chestsHeld() > 0 and "" or (built >= MAXC and "Warehouse is at its maximum." or "Out of spare chests. Add some."))
    sleep(PLAN.wait)
  end
end

if rawget(_G, "CARVE_TEST") then
  return { main = main, pos = pos }
end
runMain(main)
