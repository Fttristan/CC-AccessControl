
------------------ Config ------------------
local CONFIG_PATH = "doorauth_config.json"

local function readAll(path)
  if not fs.exists(path) then return nil end
  local handle = fs.open(path, "r")
  local data = handle.readAll()
  handle.close()
  return data
end

local function writeAll(path, data)
  local handle = fs.open(path, "w")
  handle.write(data)
  handle.close()
end

local function jsonEncode(tbl)
  if textutils.serializeJSON then return textutils.serializeJSON(tbl) end
  return textutils.serialize(tbl)
end

local function jsonDecode(data)
  if not data then return nil end
  if textutils.unserializeJSON then return textutils.unserializeJSON(data) end
  return textutils.unserialize(data)
end

local function deepCopy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do
    out[deepCopy(key)] = deepCopy(item)
  end
  return out
end

local function mergeDefaults(defaults, config)
  local out = deepCopy(defaults or {})
  config = config or {}
  for key, value in pairs(config) do
    if type(value) == "table" and type(out[key]) == "table" then
      out[key] = mergeDefaults(out[key], value)
    else
      out[key] = value
    end
  end
  return out
end

local function loadRoot()
  local parsed = jsonDecode(readAll(CONFIG_PATH))
  return type(parsed) == "table" and parsed or {}
end

local function saveRoot(root)
  writeAll(CONFIG_PATH, jsonEncode(root))
end

local function normalizeValue(raw, current)
  if type(current) == "number" then
    local value = tonumber(raw)
    return value ~= nil and value or current
  end
  if type(current) == "boolean" then
    local value = tostring(raw or ""):lower()
    if value == "true" or value == "yes" or value == "1" or value == "y" then return true end
    if value == "false" or value == "no" or value == "0" or value == "n" then return false end
    return current
  end
  return tostring(raw or current or "")
end

local function fieldValue(cfg, field)
  local value = cfg[field.key]
  if value == nil then return "" end
  if type(value) == "boolean" then return value and "true" or "false" end
  return tostring(value)
end

local function startupPrompt(title, section, defaults, fields)
  local root = loadRoot()
  root[section] = mergeDefaults(defaults, root[section])
  local cfg = root[section]

  term.clear()
  term.setCursorPos(1, 1)
  print(title)
  print("Press any key within 3 seconds to open setup.")
  print("Starting automatically if you wait.")

  local timer = os.startTimer(3)
  local openMenu = false
  while true do
    local event = { os.pullEvent() }
    if event[1] == "timer" and event[2] == timer then
      break
    elseif event[1] == "key" or event[1] == "char" or event[1] == "mouse_click" then
      openMenu = true
      break
    end
  end

  if openMenu then
    while true do
      term.clear()
      term.setCursorPos(1, 1)
      print(title)
      print("Config section: " .. section)
      print("")
      for index, field in ipairs(fields) do
        print(('%d) %s = %s'):format(index, field.label, fieldValue(cfg, field)))
      end
      print("")
      print("S) Save and start")
      print("Q) Start without saving")
      write("Choice: ")
      local choice = tostring(read() or ""):lower()

      if choice == "s" then
        root[section] = cfg
        saveRoot(root)
        term.clear()
        term.setCursorPos(1, 1)
        print("Saved configuration.")
        sleep(0.6)
        break
      elseif choice == "q" or choice == "" then
        break
      else
        local index = tonumber(choice)
        if index and fields[index] then
          local field = fields[index]
          term.clear()
          term.setCursorPos(1, 1)
          print(field.label)
          print("Current: " .. fieldValue(cfg, field))
          if field.help then print(field.help) end
          write("New value: ")
          local raw = read()
          if raw ~= nil and raw ~= "" then
            cfg[field.key] = normalizeValue(raw, cfg[field.key])
          end
        end
      end
    end
  end

  root[section] = cfg
  saveRoot(root)
  return cfg
end

local serverDefaults = {
  protocol = "doorAuth.v1",
  open_event = "doorAuth.open.v1",
  heartbeat_event = "doorAuth.heartbeat.v1",
  host_name = "DoorAuthServer",
  db_path = "door_db.json",
  admin_path = "admin.json",
  log_path = "door_logs.json",
  save_interval = 30,
  admin_timeout = 120,
  heartbeat_rate = 10,
  log_max = 1000,
}

local serverFields = {
  { key = "protocol", label = "Protocol" },
  { key = "open_event", label = "Open Event" },
  { key = "heartbeat_event", label = "Heartbeat Event" },
  { key = "host_name", label = "Host Name" },
  { key = "db_path", label = "Database File" },
  { key = "admin_path", label = "Admin File" },
  { key = "log_path", label = "Log File" },
  { key = "save_interval", label = "Save Interval" },
  { key = "admin_timeout", label = "Admin Timeout" },
  { key = "heartbeat_rate", label = "Heartbeat Rate" },
  { key = "log_max", label = "Log Max" },
}

local serverConfig = startupPrompt("DoorAuth Server Setup", "auth_server", serverDefaults, serverFields)

local db = { doors = {}, users = {} }
local PROTOCOL        = serverConfig.protocol
local OPEN_EVENT      = serverConfig.open_event
local HEARTBEAT_EVENT = serverConfig.heartbeat_event
local HOST_NAME       = serverConfig.host_name

local DB_PATH         = serverConfig.db_path
local ADMIN_PATH      = serverConfig.admin_path
local LOG_PATH        = serverConfig.log_path

local SAVE_INTERVAL   = tonumber(serverConfig.save_interval) or 30
local ADMIN_TIMEOUT   = tonumber(serverConfig.admin_timeout) or 120
local HEARTBEAT_RATE  = tonumber(serverConfig.heartbeat_rate) or 10
local LOG_MAX         = tonumber(serverConfig.log_max) or 1000

local function ensureDBShape()
  db = db or {}
  db.doors = type(db.doors) == "table" and db.doors or {}
  db.users = type(db.users) == "table" and db.users or {}
end
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
      ensureDBShape()
      print("[DB] Loaded.")
      return
    end
  end
  print("[DB] Starting fresh.")
end

local function saveDB()
  ensureDBShape()
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

local function ensureUser(name)
  ensureDBShape()
  local key = trim(name)
  if key == "" then return nil end
  db.users[key] = db.users[key] or { codeHash = nil, doors = {} }
  db.users[key].doors = type(db.users[key].doors) == "table" and db.users[key].doors or {}
  return db.users[key], key
end

local function addUser(name, code)
  local user = ensureUser(name)
  if not user or trim(code) == "" then return false end
  user.codeHash = sha256(code)
  return true
end

local function generateCardToken(name)
  return ("card_%s_%s_%s"):format(trim(name), tostring(os.epoch("utc")), tostring(math.random(100000, 999999)))
end

local function issueUserCard(name)
  local user = ensureUser(name)
  if not user then return nil end
  user.cardToken = generateCardToken(name)
  return user.cardToken
end

local function clearUserCard(name)
  local key = trim(name)
  local user = db.users[key]
  if not user then return false end
  user.cardToken = nil
  return true
end

local function findUserByCardToken(token)
  token = tostring(token or "")
  if token == "" then return nil, nil end
  for name, user in pairs(db.users) do
    if user and user.cardToken == token then
      return name, user
    end
  end
  return nil, nil
end

local function removeUser(name)
  local key = trim(name)
  if key == "" or not db.users[key] then return false end
  db.users[key] = nil
  return true
end

local function findUserByCode(code)
  local codeHash = sha256(code)
  for name,user in pairs(db.users) do
    if user and user.codeHash == codeHash then
      return name, user
    end
  end
  return nil, nil
end

local function userDoorEnabled(user, tag)
  if not user or not tag then return false end
  return user.doors and user.doors[tag] == true
end

local function enableUserDoor(name, tag)
  local user = ensureUser(name)
  if not user or trim(tag) == "" then return false end
  user.doors[tag] = true
  return true
end

local function disableUserDoor(name, tag)
  local key = trim(name)
  local user = db.users[key]
  if not user or trim(tag) == "" then return false end
  user.doors[tag] = nil
  return true
end

local function listUserDoors(name)
  local key = trim(name)
  local user = db.users[key]
  if not user then return nil end
  local doors = {}
  for tag, enabled in pairs(user.doors or {}) do
    if enabled then table.insert(doors, tag) end
  end
  table.sort(doors)
  return doors
end

local function listUsers()
  local out = {}
  for name,user in pairs(db.users) do
    local doors = listUserDoors(name) or {}
    table.insert(out, {
      name = name,
      doors = doors,
      doorCount = #doors,
      hasCode = user and user.codeHash ~= nil or false,
      hasCard = user and user.cardToken ~= nil or false
    })
  end
  table.sort(out, function(a,b) return a.name < b.name end)
  return out
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

local function verifyAccess(tag, code)
  if lockdown then
    return false, nil, "lockdown"
  end

  local tokenUserName, tokenUser = findUserByCardToken(code)
  if tokenUser then
    return userDoorEnabled(tokenUser, tag), tokenUserName, nil
  end

  local userName, user = findUserByCode(code)
  if user then
    return userDoorEnabled(user, tag), userName, nil
  end

  return hasPin(tag, code), nil, nil
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

    elseif msg.cmd=="user_list" then
      rednet.send(sender,{type="admin_users", users=listUsers()},PROTOCOL)

    elseif msg.cmd=="user_show" then
      local user = db.users[trim(msg.name or "")]
      local doors = listUserDoors(msg.name or "") or {}
      rednet.send(sender,{type="admin_user", name=trim(msg.name or ""), user=user, doors=doors, hasCard=user and user.cardToken ~= nil or false},PROTOCOL)


    elseif cmd=="user_show" and args[2] then
      if requireAdmin() then
        local user = db.users[args[2]]
        local doors = listUserDoors(args[2]) or {}
        if not user then
          print("No such user.")
        else
          print("User:", args[2])
          print("Code set:", user.codeHash and "yes" or "no")
          print("Card:", user.cardToken and "yes" or "no")
          print("Doors:")
          if #doors == 0 then
            print("  (none)")
          else
            for _,door in ipairs(doors) do
              print("  "..door)
            end
          end
        end
      end

    elseif msg.cmd=="user_add" then
      local ok = addUser(msg.name, msg.code)
      logEvent({event="user_add", tag=msg.name, ok=ok, source="remote"})
      rednet.send(sender,{type="admin_result", ok=ok},PROTOCOL)

    elseif msg.cmd=="user_card_issue" then
      local token = issueUserCard(msg.name)
      local ok = token ~= nil
      logEvent({event="user_card_issue", tag=msg.name, ok=ok, source="remote"})
      rednet.send(sender,{type="admin_user_card", ok=ok, token=token, name=trim(msg.name or "")},PROTOCOL)

    elseif msg.cmd=="user_card_clear" then
      local ok = clearUserCard(msg.name)
      logEvent({event="user_card_clear", tag=msg.name, ok=ok, source="remote"})
      rednet.send(sender,{type="admin_result", ok=ok},PROTOCOL)

    elseif msg.cmd=="user_del" then
      local ok = removeUser(msg.name)
      logEvent({event="user_del", tag=msg.name, ok=ok, source="remote"})
      rednet.send(sender,{type="admin_result", ok=ok},PROTOCOL)

    elseif msg.cmd=="user_enable" then
      local ok = enableUserDoor(msg.name, msg.tag)
      logEvent({event="user_enable", tag=msg.tag, ok=ok, source="remote", detail=tostring(msg.name)})
      rednet.send(sender,{type="admin_result", ok=ok},PROTOCOL)

    elseif msg.cmd=="user_disable" then
      local ok = disableUserDoor(msg.name, msg.tag)
      logEvent({event="user_disable", tag=msg.tag, ok=ok, source="remote", detail=tostring(msg.name)})
      rednet.send(sender,{type="admin_result", ok=ok},PROTOCOL)

    elseif msg.cmd=="user_doors" then
      rednet.send(sender,{type="admin_user_doors", name=trim(msg.name or ""), doors=listUserDoors(msg.name or "") or {}},PROTOCOL)
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
    local code=trim(msg.pin or msg.code)

    local ok,userName,reason = verifyAccess(tag,code)
    rednet.send(sender,{type="verify_result",ok=ok,tag=tag},PROTOCOL)

    logEvent({
      event="pin_attempt",
      tag=tag, ok=ok,
      source=(userName and ("user#"..userName) or ("keypad#"..sender)),
      detail=reason
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
  user_add <name> <code>
  user_del <name>
  user_card_issue <name>
  user_card_clear <name>
  user_card_show <name>
  user_enable <name> <tag>
  user_disable <name> <tag>
  user_doors <name>
  user_list
  user_show <name>
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
          local userCount = 0
          for _,user in pairs(db.users) do
            if user and user.doors and user.doors[tag] then
              userCount = userCount + 1
            end
          end
          print(("- %s (pins:%d, open:%ds, users:%d)")
            :format(tag,#d.pins,d.openTime or 3,userCount))
        end
      end

    elseif cmd=="show" and args[2] then
      if requireAdmin() then
        local d=db.doors[args[2]]
        if not d then print("No such door.") else
          print("OpenTime:",d.openTime)
          print("Pins:")
          for _,p in ipairs(d.pins) do print("  "..p) end
          print("Users:")
          local found = false
          for name,user in pairs(db.users) do
            if user and user.doors and user.doors[args[2]] then
              found = true
              print("  "..name..(user.cardToken and " [card]" or ""))
            end
          end
          if not found then print("  (none)") end
        end
      end

    elseif cmd=="add" and args[2] and args[3] then
      if requireAdmin() then
        local ok=addPin(args[2],args[3])
        logEvent({event="pin_add",tag=args[2],ok=ok,source="console"})
        print(ok and "Added." or "Already present.")
      end

    elseif cmd=="user_card_issue" and args[2] then
      if requireAdmin() then
        local token = issueUserCard(args[2])
        local ok = token ~= nil
        logEvent({event="user_card_issue",tag=args[2],ok=ok,source="console"})
        if ok then
          print("Card token:", token)
        else
          print("Failed.")
        end
      end

    elseif cmd=="user_card_clear" and args[2] then
      if requireAdmin() then
        local ok = clearUserCard(args[2])
        logEvent({event="user_card_clear",tag=args[2],ok=ok,source="console"})
        print(ok and "Cleared." or "Not found.")
      end

    elseif cmd=="user_add" and args[2] and args[3] then
      if requireAdmin() then
        local ok=addUser(args[2],args[3])
        logEvent({event="user_add",tag=args[2],ok=ok,source="console"})
        print(ok and "User saved." or "Failed.")
      end

    elseif cmd=="user_del" and args[2] then
      if requireAdmin() then
        local ok=removeUser(args[2])
        logEvent({event="user_del",tag=args[2],ok=ok,source="console"})
        print(ok and "User removed." or "Not found.")
      end

    elseif cmd=="user_enable" and args[2] and args[3] then
      if requireAdmin() then
        local ok=enableUserDoor(args[2],args[3])
        logEvent({event="user_enable",tag=args[3],ok=ok,source="console",detail=args[2]})
        print(ok and "Door enabled for user." or "Failed.")
      end

    elseif cmd=="user_disable" and args[2] and args[3] then
      if requireAdmin() then
        local ok=disableUserDoor(args[2],args[3])
        logEvent({event="user_disable",tag=args[3],ok=ok,source="console",detail=args[2]})
        print(ok and "Door disabled for user." or "Failed.")
      end

    elseif cmd=="user_doors" and args[2] then
      if requireAdmin() then
        local doors = listUserDoors(args[2])
        if not doors then
          print("No such user.")
        else
          print("Doors for "..args[2]..":")
          if #doors == 0 then
            print("  (none)")
          else
            for _,door in ipairs(doors) do
              print("  "..door)
            end
          end
        end
      end

    elseif cmd=="user_card_show" and args[2] then
      if requireAdmin() then
        local user = db.users[args[2]]
        if not user then
          print("No such user.")
        else
          print("Card:", user.cardToken and "yes" or "no")
        end
      end

    elseif cmd=="user_list" then
      if requireAdmin() then
        local users = listUsers()
        if #users == 0 then
          print("No users configured.")
        else
          for _,user in ipairs(users) do
            print(("- %s (doors:%d, card:%s)"):format(user.name, user.doorCount or 0, user.hasCard and "yes" or "no"))
          end
        end
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
