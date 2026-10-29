-- built by Carve Designer v4.6
-- Carve auto smelter: feeds a row of furnaces from an input chest and puts the results in an output chest.
--
-- Layout (top view, you stand on START facing the furnaces, "F" = furnace, it needs free air above and below):
--        F F F F ...        furnaces, 2 blocks in front of the start row
--        . . . . ...        the turtle's walkway (1 block in front)
--      [out] T              T = START, [out] = output chest on its left, [in] = input chest behind it
--            [in]
-- Put raw items AND your fuel (coal) in the input chest. Run with  setup  to let the turtle place the furnaces.
-- It can't dig out furnaces or chests, but it will dig dirt/stone out of its own way (it walks above and below the furnaces).

local args = { ... }

local PLAN = {fuel = "minecraft:coal", furnaces = 4, kind = "smelter", label = "Neptune", live = "http://127.0.0.1:8765", name = "Smelter", once = false}

local STATE_FILE = "carve.smelter"
local TITLE = PLAN.name or "Auto smelter"
local FUEL = PLAN.fuel or "minecraft:coal"
local FUEL_HINT = FUEL:gsub("^minecraft:", "")
local BURN = { (FUEL:gsub("^minecraft:", "")), "charcoal" }
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


local F = PLAN.furnaces

-- how many items one piece of fuel smelts
local FUEL_ITEMS = { coal = 8, charcoal = 8, coal_block = 80, lava_bucket = 100, blaze_rod = 12,
                     log = 1.5, planks = 1.5, wood = 1.5, stick = 0.5 }
local PER_FUEL = 1.5
do
  local short = FUEL:gsub("^minecraft:", "")
  for k, v in pairs(FUEL_ITEMS) do
    if short:find(k, 1, true) then PER_FUEL = v end
  end
end
local KEEP_FUEL = 64                                   -- how much of my own fuel I hold on to

local CHARCOAL = "minecraft:charcoal"
local SWITCH_AT = 32          -- once I hold this much charcoal I burn that instead of coal or wood
local function isWood(n) return n ~= nil and (n:find("log", 1, true) or n:find("planks", 1, true) or n:find("_wood", 1, true)) ~= nil end
local function isFuelName(n) return n == FUEL or n == CHARCOAL or n == "minecraft:coal" end

local function slotsOf(name)
  local t = {}
  for s = 1, 16 do
    if itemName(s) == name then t[#t + 1] = s end
  end
  return t
end

local function countOf(name)
  local n = 0
  for _, s in ipairs(slotsOf(name)) do n = n + turtle.getItemCount(s) end
  return n
end

local function fuelSlots()
  return slotsOf(FUEL)
end

local function fuelCount()
  return countOf(FUEL)
end

local function perFuel(name)
  local short = (name or ""):gsub("^minecraft:", "")
  local v = 1.5
  for k, x in pairs(FUEL_ITEMS) do
    if short:find(k, 1, true) then v = x end
  end
  return v
end

-- what to burn for the stack `st`: charcoal once there is a decent supply, else my coal, else the wood itself (making charcoal)
local function chooseFuel(st)
  if countOf(CHARCOAL) >= SWITCH_AT and st.name ~= CHARCOAL then return CHARCOAL end
  if countOf(FUEL) > 1 then return FUEL end
  if countOf("minecraft:coal") > 1 then return "minecraft:coal" end
  if countOf(CHARCOAL) > 1 then return CHARCOAL end
  if isWood(st.name) then return st.name end                 -- bootstrap: burn some of the logs to make the first charcoal
  for s = 1, 16 do
    if isWood(itemName(s)) then return itemName(s) end
  end
  return nil
end

local function home()
  goTo(pos.x, 0, 1, "y")
  goTo(0, 0, 1, "x")
  goTo(0, 0, 0, "z")
end

-- walk to the walkway cell in front of furnace k (k = 1 .. F) facing the furnace
local function toFurnace(k)
  goTo(k - 1, 0, 1, "yzx")
  turnTo(1)
end

-- take what is in the input chest into my inventory (keeps two slots free)
local function pull()
  turnTo(3)
  local got = false
  for _ = 1, 60 do
    if freeSlots() < 3 then break end
    if not turtle.suck() then break end
    got = true
  end
  return got
end

-- put the smelted items (and anything else that is not on its way to a furnace) in the output chest
local function unload(pending)
  local keep = {}
  for s in pairs(pending or {}) do keep[s] = true end
  for _, name in ipairs({ FUEL, CHARCOAL }) do                -- my own fuel and charcoal I made: keep up to a stack, send the rest on
    local held = 0
    for _, s in ipairs(slotsOf(name)) do
      if held < KEEP_FUEL then keep[s] = true; held = held + turtle.getItemCount(s) end
    end
  end
  turnTo(4)
  dumpFront(keep)
  turnTo(1)
end

-- drop n of item `name` (not from slot `except`) into the furnace in front: its fuel slot
local function dropFuel(name, n, except)
  for _, s in ipairs(slotsOf(name)) do
    if n <= 0 then break end
    if s ~= except then
      turtle.select(s)
      local k = math.min(n, turtle.getItemCount(s))
      if turtle.drop(k) then n = n - k end
    end
  end
  turtle.select(1)
end

local fuelNote = ""
local function feed(k, st)
  toFurnace(k)
  local fuel = chooseFuel(st)
  local input = st.count
  if fuel == st.name then                                   -- burning the very logs I am smelting: split the stack
    input = math.floor(st.count * 0.6)
    local f = st.count - input
    turtle.select(st.slot)
    turtle.drop(f)
    turtle.select(1)
    fuelNote = "burning logs for fuel"
  elseif fuel then
    local need = math.ceil(st.count / perFuel(fuel))
    local keepOne = (fuel == FUEL or fuel == CHARCOAL) and 1 or 0     -- one for the turtle itself
    dropFuel(fuel, math.min(need, countOf(fuel) - keepOne), st.slot)
    fuelNote = "burning " .. fuel:gsub("^minecraft:", "")
  else
    fuelNote = "no fuel: waiting for logs or coal"
  end
  step(5); step(1)                                          -- above the furnace
  turtle.select(st.slot)
  turtle.dropDown(input)
  turtle.select(1)
  step(3); step(6)
end

local function collect(k)
  toFurnace(k)
  step(6); step(1)                                  -- below the furnace
  local n = 0
  while turtle.suckUp() do
    n = n + 1
    if n > 10 or freeSlots() < 1 then break end
  end
  step(3); step(5)
end

local function furnaceSlot()
  for s = 1, 16 do
    if itemName(s) == "minecraft:furnace" then return s end
  end
end

-- place the missing furnaces (and the two chests). With waitForItems it waits until somebody hands me the furnaces.
local function setup(waitForItems)
  ensureChest(3, "raw items")
  ensureChest(4, "results")
  turnTo(1)
  for k = 1, F do
    toFurnace(k)
    local ok, data = turtle.inspect()
    if not (ok and has(data.name, "furnace")) then
      if ok then turtle.dig() end
      local s = furnaceSlot()
      while not s do
        if not waitForItems then
          say(TITLE, "", "Put " .. F .. " furnaces in my inventory", "(furnace " .. k .. " is missing), then", "run setup again.")
          home(); turnTo(1)
          return false
        end
        say(TITLE, "", "Put furnaces in my inventory", "(furnace " .. k .. "/" .. F .. " is missing). Waiting...")
        sleep(5)
        s = furnaceSlot()
      end
      turtle.select(s)
      turtle.place()
    end
  end
  turtle.select(1)
  home(); turnTo(1)
  return true
end

local function recover()
  if pos.y ~= 0 then goTo(pos.x, 0, pos.z, "y") end
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
  if args[1] == "setup" then
    if setup(false) then
      say(TITLE, "", "Furnaces and chests are in place.", "Chest BEHIND me = input,", "chest on my LEFT = output.", "Run me again without setup.")
    end
    return
  end
  installStartup()
  setup(true)                                        -- builds whatever is missing: chests from my inventory, furnaces
  local idle, stuck = 0, 0
  while true do
    pull()
    local stacks, pending = {}, {}
    for s = 1, 16 do
      local n = itemName(s)
      if n and not isFuelName(n) and not isBuildItem(n) then stacks[#stacks + 1] = { slot = s, count = turtle.getItemCount(s), name = n } end
    end
    table.sort(stacks, function(a, b) return a.count > b.count end)
    -- anything that is not a stack to smelt goes to the output chest first (earlier results)
    if #stacks == 0 then
      turnTo(1)
      idle = idle + 1
      if PLAN.once then break end
      waitSeconds(30, "Nothing to smelt. Waiting for items.")
    else
      idle = 0
      local used, longest = {}, 0
      for i, st in ipairs(stacks) do
        if i <= F then
          used[#used + 1] = st
          longest = math.max(longest, st.count)
        else
          pending[st.slot] = true
        end
      end
      for i, st in ipairs(used) do
        say(TITLE, "", "Loading furnace " .. i .. "/" .. #used, "Items " .. st.count .. " x " .. st.name:gsub("^minecraft:", ""),
            fuelNote ~= "" and fuelNote or ("charcoal " .. countOf(CHARCOAL) .. "/" .. SWITCH_AT))
        feed(i, st)
      end
      home()
      waitSeconds(longest * 10 + 6, "Smelting " .. #used .. " furnace(s)...")
      for i = 1, #used do collect(i) end
      home()
      -- the leftovers of a stack that did not fit stay in me (they are "pending"), then dump the rest
      local moved = false
      for _, st in ipairs(used) do
        local left = itemName(st.slot) == st.name and turtle.getItemCount(st.slot) or 0
        if left < st.count then moved = true end
        if left > 0 then pending[st.slot] = true end
      end
      stuck = moved and 0 or stuck + 1
      if stuck >= 2 then
        say(TITLE, "", "Some items won't go into the", "furnaces (not smeltable?).", "Putting them in the output chest.")
        pending = {}
        stuck = 0
      end
      unload(pending)
    end
  end
  removeStartup()
  fs.delete(STATE_FILE)
  finish(TITLE, "", "All done. Output is in the chest.")
end

if rawget(_G, "CARVE_TEST") then
  return { main = main, pos = pos }
end
runMain(main)
