-- carve : menu of your Carve Designer programs, stored on GitHub.
--
--   carve                  pick a program from the list
--   carve <name>           download and run one directly   (name = its short name)
--   carve <name> nochest   anything after the name is passed to the program
--   carve list             just show the list
--   carve resume           carry on with the job that was interrupted
--   carve ping [address]  check that this turtle can reach the Designer app (for live reporting)
--   carve start <id> <name>   tell another turtle (running the "agent" program) to start a program
--
-- Every run downloads the newest version, so after you upload a changed design
-- from the designer you don't need to do anything else on the turtle.

-- every turtle names itself after a Deadlock hero (by its id) the first time it starts, if it has no label yet
do
  local GODS = { "Abrams", "Bebop", "Dynamo", "Grey Talon", "Haze", "Infernus", "Ivy", "Kelvin", "Lady Geist", "Lash", "McGinnis", "Krill", "Paradox", "Pocket", "Seven", "Shiv", "Vindicta", "Viscous", "Warden", "Wraith", "Yamato", "Calico", "Holliday", "Vyper", "Sinclair", "Mirage", "Drifter", "Victor", "Paige", "Billy", "Rem", "Mo" }
  if os.getComputerLabel and os.setComputerLabel and os.getComputerID and not os.getComputerLabel() then
    pcall(os.setComputerLabel, GODS[os.getComputerID() % #GODS + 1])
  end
end

local BASE = "https://raw.githubusercontent.com/yetimafia/Carve-Designer/main/carve"
local args = { ... }

if not http then
  error("HTTP is turned off on this computer/server, so I can't reach GitHub.", 0)
end

if args[1] == "ping" then
  local url = args[2]
  if not url then
    local f = fs.open("carve.live", "r")
    url = f and f.readAll() or nil
    if f then f.close() end
  end
  if not url or url == "" then
    print("Use:  carve ping http://<address of the Designer>:8765")
    return
  end
  url = url:gsub("/+$", "")
  print("Trying " .. url .. " ...")
  local h, err = http.get(url .. "/")
  if h then
    h.close()
    print("OK: the Designer answered. Programs on this turtle can report to it.")
    return
  end
  err = tostring(err)
  print("Failed: " .. err)
  local low = err:lower()
  if low:find("not permitted", 1, true) or low:find("blocked", 1, true) or low:find("denied", 1, true) then
    print("Minecraft blocks that address. In computercraft-server.toml set the")
    print("\"$private\" http rule to allow (or add the address), then restart the world/server.")
  elseif low:find("refused", 1, true) or low:find("connect", 1, true) or low:find("timed out", 1, true) or low:find("timeout", 1, true) then
    print("Nothing answered. Is 'Start listening' on in the Designer? Is the address the PC's")
    print("network address (not 127.0.0.1) if this turtle is on a server or another computer?")
    print("Tick 'Accept turtles from other computers' and allow the firewall prompt.")
  else
    print("Check the address: http://<PC address>:8765")
  end
  return
end

if args[1] == "start" then
  local id, slug = tonumber(args[2]), args[3]
  if not id or not slug or not slug:match("^[%w_%-]+$") then
    print("Use:  carve start <turtle id> <program>")
    return
  end
  local f = fs.open("carve.live", "r")
  local url = f and f.readAll() or ""
  if f then f.close() end
  if url == "" then
    error("I don't know where the Designer app is yet. Run any program with live reporting on this turtle once.", 0)
  end
  local h, err = http.post(url .. "/cmd", textutils.serialiseJSON({ id = id, cmd = "run", arg = slug }))
  if h then
    h.close()
    print("Asked turtle " .. id .. " to start " .. slug .. ".")
  else
    print("Not accepted (" .. tostring(err) .. "). Is turtle " .. id .. " running the agent program?")
  end
  return
end

local function fetch(path)
  -- the extra number defeats GitHub's short-lived cache so you always get the latest
  local stamp = tostring(os.epoch and os.epoch("utc") or os.time())
  local h, err = http.get(BASE .. "/" .. path .. "?nocache=" .. stamp)
  if not h then return nil, tostring(err) end
  local body = h.readAll()
  h.close()
  return body
end

local function loadList()
  local body, err = fetch("index.json")
  if not body then
    return nil, "Could not download the list (" .. err .. "). Is the repo public and the address right?"
  end
  local ok, data = pcall(textutils.unserialiseJSON, body)
  if not ok or type(data) ~= "table" or type(data.programs) ~= "table" then
    return nil, "The list on GitHub isn't readable. Upload a design from the designer again."
  end
  return data.programs
end

local function valid(p)
  return type(p) == "table" and type(p.slug) == "string" and p.slug:match("^[%w_%-]+$")
    and type(p.file) == "string" and not p.file:find("..", 1, true) and not p.file:find("^/")
end

local function describe(p)
  local size = ""
  if type(p.size) == "table" then size = (" %dx%dx%d"):format(p.size[1] or 0, p.size[2] or 0, p.size[3] or 0) end
  local blocks = p.blocks and (" - " .. tostring(p.blocks) .. " blocks") or ""
  return tostring(p.name or p.slug) .. size .. blocks
end

local function run(p, extra)
  local body, err = fetch(p.file)
  if not body then error("Could not download " .. p.slug .. ": " .. err, 0) end
  local localName = "job_" .. p.slug
  local f = fs.open(localName, "w")
  if not f then error("Could not save " .. localName, 0) end
  f.write(body)
  f.close()
  print("Downloaded " .. localName .. " (" .. #body .. " bytes)")
  local lf = fs.open("carve.last", "w")
  if lf then lf.write(p.slug); lf.close() end
  shell.run(localName, table.unpack(extra))
end

local programs, err = loadList()
if not programs then error(err, 0) end
local list = {}
for _, p in ipairs(programs) do
  if valid(p) then list[#list + 1] = p end
end
if #list == 0 then error("No programs on GitHub yet. Upload one from the designer.", 0) end

local function find(slug)
  for _, p in ipairs(list) do
    if p.slug == slug then return p end
  end
end

if args[1] == "list" then
  for i, p in ipairs(list) do print(i .. ") " .. p.slug .. "  " .. describe(p)) end
  return
end

local function lastSlug()
  if not (fs.exists("carve.job") and fs.exists("carve.last")) then return nil end
  local f = fs.open("carve.last", "r")
  if not f then return nil end
  local slug = f.readAll()
  f.close()
  return slug
end

if args[1] == "resume" then
  local slug = lastSlug()
  local p = slug and find(slug)
  if not p then
    print("Nothing to resume here.")
    return
  end
  run(p, { "resume" })
  return
end

if args[1] and args[1] ~= "" then
  local p = find(args[1])
  if not p then error("No program called '" .. args[1] .. "'. Try: carve list", 0) end
  run(p, { table.unpack(args, 2) })
  return
end

local _, termH = term.getSize()
local perPage = math.max(3, termH - 5)
local page = 1
local pages = math.ceil(#list / perPage)
while true do
  term.clear()
  term.setCursorPos(1, 1)
  print("Carve programs (" .. page .. "/" .. pages .. ")")
  for i = (page - 1) * perPage + 1, math.min(#list, page * perPage) do
    print(i .. ") " .. describe(list[i]))
  end
  print("")
  local pending = lastSlug()
  if pending and find(pending) then print("r = resume the unfinished " .. pending .. " job") end
  write("Number" .. (pages > 1 and ", n/p = page" or "") .. ", q = quit: ")
  local answer = read()
  local n = tonumber(answer)
  if answer == "q" or answer == "Q" then
    return
  elseif (answer == "r" or answer == "R") and pending and find(pending) then
    term.clear()
    term.setCursorPos(1, 1)
    run(find(pending), { "resume" })
    return
  elseif answer == "n" and page < pages then
    page = page + 1
  elseif answer == "p" and page > 1 then
    page = page - 1
  elseif n and list[n] then
    term.clear()
    term.setCursorPos(1, 1)
    run(list[n], {})
    return
  end
end
