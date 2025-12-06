--============================================================--
--  auth_server.lua  (FINAL VERSION)
--  Features:
--    ✔ Admin PIN (hashed)
--    ✔ Local admin console
--    ✔ Remote admin (secure login)
--    ✔ Lockdown mode
--    ✔ Door fob support (door_list + verify)
--    ✔ Audit logs (persistent)
--    ✔ Heartbeat to controllers
--    ✔ Autosave + DB persistence
--    ✔ Controller auto-registration
--============================================================--

------------------ Config ------------------
local PROTOCOL        = "doorAuth.v1"
local OPEN_EVENT      = "doorAuth.open.v1"
local HEARTBEAT_EVENT = "doorAuth.heartbeat.v1"
local HOST_NAME       = "DoorAuthServer"

local DB_PATH         = "door_db.json"
local ADMIN_PATH      = "admin.json"
local LOG_PATH        = "door_logs.json"

local SAVE_INTERVAL   = 30
local ADMIN_TIMEOUT   = 120     -- 2 minutes inactivity
local HEARTBEAT_RATE  = 10
local LOG_MAX         = 1000
--------------------------------------------

------------------ Utils -------------------
local function readAll(path)
  if not fs.exists(path) then return nil end
  local h = fs.open(path,"r")
  local d = h.readAll()
  h.close()
  return d
end

local function writeAll(path,data)
  local h = fs.open(path,"w")
  h.write(data)
  h.close()
end

local function jsonEncode(tbl)
  if textutils.serializeJSON then
    return textutils.serializeJSON(tbl)
  else
    return textutils.serialize(tbl)
  end
end

local function jsonDecode(s)
  if not s then return nil end
  if textutils.unserializeJSON then
    return textutils.unserializeJSON(s)
  else
    return textutils.unserialize(s)
  end
end

local function trim(s)
  s = tostring(s or "")
  return s:gsub("^%s+",""):gsub("%s+$","")
end

local function clockString()
  local ok,t = pcall(os.time)
  if ok and textutils.formatTime then
    return textutils.formatTime(t, true)
  end
  return "??:??"
end
--------------------------------------------

------------------ State -------------------
local db = { doors = {} }
local controllersByTag = {}
local lockdown = false
local logs = {}

local admin = {
  pinHash     = nil,
  loggedIn    = false,
  remoteToken = nil,
  lastAction  = 0
}
--------------------------------------------

------------------ Hashing -----------------
-- Fallback SHA256-like hash
local function sha256(str)
  local h=0
  for i=1,#str do
    h=(h*31 + str:byte(i)) % 2^31
  end
  return tostring(h)
end
--------------------------------------------

------------------ Admin Auth --------------
local function loadAdmin()
  if not fs.exists(ADMIN_PATH) then
    print("=== FIRST-TIME ADMIN SETUP ===")
    while true do
      write("New Admin PIN: ") local p1=read("*")
      write("Confirm PIN: ")   local p2=read("*")
      if p1==p2 and #p1>=4 then
        admin.pinHash = sha256(p1)
        writeAll(ADMIN_PATH, admin.pinHash)
        print("Admin PIN saved.")
        break
      end
      print("Pins did not match or too short. Try again.")
    end
  else
    admin.pinHash = trim(readAll(ADMIN_PATH))
  end
end

local function isAdminValid()
  if not admin.loggedIn then return false end
  if (os.epoch("utc") - admin.lastAction) > ADMIN_TIMEOUT*1000 then
    admin.loggedIn = false
    admin.remoteToken = nil
    print("[ADMIN] Session expired.")
    return false
  end
  return true
end

local function requireAdmin()
  if isAdminValid() then
    admin.lastAction = os.epoch("utc")
    return true
  end

  write("Admin PIN: ")
  local attempt = read("*")
  if sha256(attempt) == admin.pinHash then
    admin.loggedIn   = true
    admin.lastAction = os.epoch("utc")
    print("[ADMIN] Login OK")
    return true
  end

  print("[ADMIN] Incorrect PIN.")
  return false
end
--------------------------------------------

------------------ Logs ---------------------
local function loadLogs()
  local raw = readAll(LOG_PATH)
  if not raw then logs = {} return end
  local parsed = jsonDecode(raw)
  logs = type(parsed)=="table" and parsed or {}
end

local function saveLogs()
  writeAll(LOG_PATH, jsonEncode(logs))
end

local function logEvent(evt)
  local entry = {
    time   = clockString(),
    ts     = os.epoch("utc"),
    event  = evt.event or "unknown",
    tag    = evt.tag,
    ok     = evt.ok,
    source = evt.source,
    detail = evt.detail
  }
  table.insert(logs, entry)
  if #logs > LOG_MAX then table.remove(logs,1) end
end
--------------------------------------------

------------- Persistence ------------------
local function loadDB()
  local raw = readAll(DB_PATH)
  if raw then
    local parsed = jsonDecode(raw)
    if parsed and parsed.doors then
      db = parsed
      print("[DB] Loaded.")
      return
    end
  end
  print("[DB] Starting fresh.")
end

local function saveDB()
  writeAll(DB_PATH, jsonEncode(db))
  print("[DB] Saved.")
end
--------------------------------------------

--------------- Networking -----------------
local function openModems()
  for _,side in ipairs(rs.getSides()) do
    if peripheral.getType(side)=="modem" then
      if not rednet.isOpen(side) then rednet.open(side) end
    end
  end
end

local function broadcastOpen(tag, duration)
  local set = controllersByTag[tag]
  if not set then return end
  for id,_ in pairs(set) do
    rednet.send(id, {type="open", tag=tag, duration=duration}, OPEN_EVENT)
  end
end
--------------------------------------------

------------- Door Helpers -----------------
local function ensureDoor(tag)
  db.doors[tag] = db.doors[tag] or { pins={}, openTime=3 }
  return db.doors[tag]
end

local function hasPin(tag, pin)
  local d = db.doors[tag]
  if not d then return false end
  pin = tostring(pin)
  for _,p in ipairs(d.pins) do
    if tostring(p) == pin then return true end
  end
  return false
end

local function addPin(tag, pin)
  ensureDoor(tag)
  pin = tostring(pin)
  for _,p in ipairs(db.doors[tag].pins) do
    if p == pin then return false end
  end
  table.insert(db.doors[tag].pins, pin)
  return true
end

local function removePin(tag,pin)
  local d=db.doors[tag]
  if not d then return false end
  local out,removed={},false
  pin=tostring(pin)
  for _,p in ipairs(d.pins) do
    if p~=pin then table.insert(out,p)
    else removed=true end
  end
  d.pins=out
  return removed
end
--------------------------------------------

---------------- Remote Admin --------------
local function handleRemoteAdmin(sender,msg)

  --------------------------------------------------
  -- REMOTE LOGIN
  --------------------------------------------------
  if msg.type=="admin_login" then
    local stamp = tostring(msg.timestamp or "")
    local sig   = tostring(msg.sig or "")

    local expected = sha256(admin.pinHash .. stamp)

    if sig == expected then
      local token = tostring(math.random(100000,999999))..tostring(os.epoch("utc"))
      admin.loggedIn   = true
      admin.remoteToken= token
      admin.lastAction = os.epoch("utc")

      logEvent({event="admin_login", ok=true, source="remote#"..sender})
      rednet.send(sender,{type="admin_login_ok", token=token},PROTOCOL)
    else
      logEvent({event="admin_login", ok=false, source="remote#"..sender, detail="bad_sig"})
      rednet.send(sender,{type="admin_login_fail"},PROTOCOL)
    end

    return true
  end

  --------------------------------------------------
  -- REMOTE COMMANDS
  --------------------------------------------------
  if msg.type=="admin_cmd" then
    if msg.token ~= admin.remoteToken or not isAdminValid() then
      rednet.send(sender,{type="admin_denied"},PROTOCOL)
      return true
    end

    admin.lastAction = os.epoch("utc")

    if msg.cmd=="list" then
      rednet.send(sender,{type="admin_list", doors=db.doors},PROTOCOL)

    elseif msg.cmd=="show" then
      rednet.send(sender,{type="admin_show", tag=msg.tag, door=db.doors[msg.tag]},PROTOCOL)

    elseif msg.cmd=="add" then
      local ok=addPin(msg.tag,msg.pin)
      logEvent({event="pin_add", tag=msg.tag, ok=ok, source="remote"})
      rednet.send(sender,{type="admin_result",ok=ok},PROTOCOL)

    elseif msg.cmd=="del" then
      local ok=removePin(msg.tag,msg.pin)
      logEvent({event="pin_del", tag=msg.tag, ok=ok, source="remote"})
      rednet.send(sender,{type="admin_result",ok=ok},PROTOCOL)

    elseif msg.cmd=="remove" then
      db.doors[msg.tag]=nil
      logEvent({event="door_remove", tag=msg.tag, ok=true, source="remote"})
      rednet.send(sender,{type="admin_result",ok=true},PROTOCOL)

    elseif msg.cmd=="opentime" then
      ensureDoor(msg.tag)
      db.doors[msg.tag].openTime = tonumber(msg.seconds)
      logEvent({
        event="opentime_set", tag=msg.tag,
        ok=true, source="remote",
        detail="seconds="..tostring(msg.seconds)
      })
      rednet.send(sender,{type="admin_result",ok=true},PROTOCOL)

    elseif msg.cmd=="lockdown_on" then
      lockdown=true
      logEvent({event="lockdown_on", ok=true, source="remote"})
      rednet.send(sender,{type="admin_result",ok=true,state="locked"},PROTOCOL)

    elseif msg.cmd=="lockdown_off" then
      lockdown=false
      logEvent({event="lockdown_off", ok=true, source="remote"})
      rednet.send(sender,{type="admin_result",ok=true,state="unlocked"},PROTOCOL)

    elseif msg.cmd=="open" then
      if lockdown then
        logEvent({event="remote_open", tag=msg.tag, ok=false, source="remote", detail="blocked_by_lockdown"})
        rednet.send(sender,{type="admin_result",ok=false,reason="lockdown"},PROTOCOL)
        return true
      end
      local d=db.doors[msg.tag]
      local dur=(d and d.openTime) or 3
      broadcastOpen(msg.tag,dur)
      logEvent({event="remote_open",tag=msg.tag,ok=true,source="remote"})
      rednet.send(sender,{type="admin_result",ok=true},PROTOCOL)

    elseif msg.cmd=="logs" then
      rednet.send(sender,{type="admin_logs", logs=logs},PROTOCOL)
    end

    return true
  end

  return false
end
--------------------------------------------

---------------- Handlers ------------------
local function handleMessage(sender,msg,proto)
  if proto~=PROTOCOL or type(msg)~="table" then return end

  -- remote admin first
  if handleRemoteAdmin(sender,msg) then return end

  -------- door_list (for door_fob) --------
  if msg.type=="door_list" then
    local tags={}
    for tag,_ in pairs(db.doors) do table.insert(tags,tag) end
    rednet.send(sender,{type="door_list",tags=tags},PROTOCOL)
    return
  end

  -------------- verify (keypads + fob) -----
  if msg.type=="verify" then
    local tag=trim(msg.tag)
    local pin=trim(msg.pin)

    if lockdown then
      rednet.send(sender,{type="verify_result",ok=false,tag=tag},PROTOCOL)
      logEvent({event="pin_attempt",tag=tag,ok=false,source="keypad#"..sender,detail="lockdown"})
      return
    end

    local ok = hasPin(tag,pin)
    rednet.send(sender,{type="verify_result",ok=ok,tag=tag},PROTOCOL)

    logEvent({
      event="pin_attempt",
      tag=tag, ok=ok,
      source="keypad#"..sender
    })

    if ok then
      local d=db.doors[tag]
      local dur=(d and d.openTime) or 3
      broadcastOpen(tag,dur)
      logEvent({event="door_open",tag=tag,ok=true,source="keypad"})
    end

    return
  end

  -------------- controller registration ----
  if msg.type=="registerController" then
    local tag=trim(msg.tag)
    controllersByTag[tag]=controllersByTag[tag] or {}
    controllersByTag[tag][sender]=true
    rednet.send(sender,{type="register_ack",tag=tag},PROTOCOL)
    logEvent({event="controller_register",tag=tag,ok=true,source="ctrl#"..sender})
    return
  end

  if msg.type=="unregisterController" then
    local tag=trim(msg.tag)
    if controllersByTag[tag] then controllersByTag[tag][sender]=nil end
    rednet.send(sender,{type="unregister_ack"},PROTOCOL)
    logEvent({event="controller_unregister",tag=tag,ok=true,source="ctrl#"..sender})
    return
  end
end
--------------------------------------------

---------------- Console -------------------
local function help()
  print([[Commands:
  help
  controllers
  save
  reboot
  cls

  -- Admin commands --
  add <tag> <pin>
  del <tag> <pin>
  opentime <tag> <seconds>
  remove <tag>
  show <tag>
  list
  lockdown_on
  lockdown_off
  logs
]])
end

local function printLogsConsole(maxLines)
  if not requireAdmin() then return end
  maxLines=maxLines or 40
  local n=#logs
  local start = math.max(1, n-maxLines+1)
  for i=start,n do
    local e=logs[i]
    local status = e.ok==nil and "" or (e.ok and "OK" or "FAIL")
    print(("[%4d] %s %-14s tag=%s %s %s")
      :format(
        i,
        e.time or "??:??",
        e.event or "?",
        e.tag or "-",
        status,
        e.detail or ""
      ))
  end
end

local function consoleLoop()
  help()
  while true do
    term.setTextColor(colors.yellow) write("> ")
    term.setTextColor(colors.white)
    local line=read()

    local args={}
    for w in line:gmatch("%S+") do table.insert(args,w) end
    local cmd=args[1]

    if cmd=="help" then help()
    elseif cmd=="cls" or cmd=="clear" then term.clear() term.setCursorPos(1,1)

    elseif cmd=="controllers" then
      for tag,set in pairs(controllersByTag) do
        local ids={}
        for id,_ in pairs(set) do table.insert(ids,id) end
        print(tag.." -> "..table.concat(ids,",")) end

    elseif cmd=="save" then saveDB() saveLogs()
    elseif cmd=="reboot" then saveDB() saveLogs() sleep(0.2) os.reboot()

    elseif cmd=="list" then
      if requireAdmin() then
        for tag,d in pairs(db.doors) do
          print(("- %s (pins:%d, open:%ds)")
            :format(tag,#d.pins,d.openTime or 3))
        end
      end

    elseif cmd=="show" and args[2] then
      if requireAdmin() then
        local d=db.doors[args[2]]
        if not d then print("No such door.") else
          print("OpenTime:",d.openTime) print("Pins:")
          for _,p in ipairs(d.pins) do print("  "..p) end
        end
      end

    elseif cmd=="add" and args[2] and args[3] then
      if requireAdmin() then
        local ok=addPin(args[2],args[3])
        logEvent({event="pin_add",tag=args[2],ok=ok,source="console"})
        print(ok and "Added." or "Already present.")
      end

    elseif cmd=="del" and args[2] and args[3] then
      if requireAdmin() then
        local ok=removePin(args[2],args[3])
        logEvent({event="pin_del",tag=args[2],ok=ok,source="console"})
        print(ok and "Removed." or "Not found.")
      end

    elseif cmd=="opentime" and args[2] and tonumber(args[3]) then
      if requireAdmin() then
        ensureDoor(args[2])
        db.doors[args[2]].openTime = tonumber(args[3])
        logEvent({event="opentime_set",tag=args[2],ok=true,source="console"})
        print("Updated.")
      end

    elseif cmd=="remove" and args[2] then
      if requireAdmin() then
        db.doors[args[2]]=nil
        logEvent({event="door_remove",tag=args[2],ok=true,source="console"})
        print("Door removed.")
      end

    elseif cmd=="lockdown_on" then
      if requireAdmin() then
        lockdown=true
        logEvent({event="lockdown_on",ok=true,source="console"})
        print("LOCKDOWN ENABLED")
      end

    elseif cmd=="lockdown_off" then
      if requireAdmin() then
        lockdown=false
        logEvent({event="lockdown_off",ok=true,source="console"})
        print("Lockdown disabled.")
      end

    elseif cmd=="logs" then
      printLogsConsole(40)

    elseif cmd and cmd~="" then
      print("Unknown command.")
    end
  end
end
--------------------------------------------

---------------- Network -------------------
local function netLoop()
  while true do
    local id,msg,proto = rednet.receive()
    handleMessage(id,msg,proto)
  end
end

local function autosaveLoop()
  while true do
    sleep(SAVE_INTERVAL)
    saveDB()
    saveLogs()
  end
end

local function heartbeatLoop()
  while true do
    sleep(HEARTBEAT_RATE)
    for tag,set in pairs(controllersByTag) do
      for id,_ in pairs(set) do
        rednet.send(id,{type="hb"},HEARTBEAT_EVENT)
      end
    end
  end
end
--------------------------------------------

------------------- Main -------------------
term.setTextColor(colors.cyan)
print("[DoorAuth Server] starting...")
term.setTextColor(colors.white)

openModems()
rednet.host(PROTOCOL, HOST_NAME)
loadDB()
loadLogs()
loadAdmin()
logEvent({event="server_start",ok=true,source="server"})

parallel.waitForAny(netLoop, consoleLoop, autosaveLoop, heartbeatLoop)
