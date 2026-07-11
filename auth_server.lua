
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

local function clearUserCode(name)
  local key = trim(name)
  local user = db.users[key]
  if not user then return false end
  user.codeHash = nil
  return true
end

local function clearUserDoors(name)
  local key = trim(name)
  local user = db.users[key]
  if not user then return false end
  user.doors = {}
  return true
end

local function cloneUserAccess(sourceName, targetName, includeCode)
  local sourceKey = trim(sourceName)
  local targetKey = trim(targetName)
  if sourceKey == "" or targetKey == "" then return false end

  local source = db.users[sourceKey]
  local target = ensureUser(targetKey)
  if not source or not target then return false end

  target.doors = {}
  for tag, enabled in pairs(source.doors or {}) do
    if enabled then
      target.doors[tag] = true
    end
  end

  if includeCode then
    target.codeHash = source.codeHash
  end

  return true
end

local listUsers

local function searchUsers(query)
  query = trim(query):lower()
  local users = listUsers()
  if query == "" then
    return users
  end

  local out = {}
  for _, user in ipairs(users) do
    local haystack = table.concat({
      user.name or "",
      table.concat(user.doors or {}, " "),
      user.hasCode and "code" or "",
      user.hasCard and "card" or "",
    }, " "):lower()
    if haystack:find(query, 1, true) then
      table.insert(out, user)
    end
  end
  return out
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

listUsers = function()
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

local function setColor(col)
  if term.isColor and term.isColor() then
    term.setTextColor(col)
  end
end

local function isPocketComputer()
  return pocket ~= nil and type(pocket.equipBack) == "function"
end

local function findCardManipulator()
  for _, name in ipairs(peripheral.getNames()) do
    local wrapped = peripheral.wrap(name)
    if wrapped and type(wrapped.writeCard) == "function" and type(wrapped.hasCard) == "function" then
      return name, wrapped
    end
  end

  return nil, nil
end

local function waitForCard(reader, timeoutSeconds)
  local timer = os.startTimer(timeoutSeconds or 20)
  while true do
    if reader.hasCard() then
      return true
    end

    local event, timerId = os.pullEvent()
    if event == "timer" and timerId == timer then
      return false
    end
  end
end

local function writeCard(reader, token, label)
  if not waitForCard(reader, 20) then
    return false, "No card detected."
  end

  local ok, err = reader.writeCard(token)
  if not ok then
    return false, err or "Write failed."
  end

  if type(reader.setLabel) == "function" then
    pcall(reader.setLabel, label)
  end
  if type(reader.setSecure) == "function" then
    pcall(reader.setSecure, true)
  end
  if type(reader.ejectCard) == "function" then
    pcall(reader.ejectCard)
  end

  return true
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

    elseif msg.cmd=="user_clear_code" then
      local ok = clearUserCode(msg.name)
      logEvent({event="user_clear_code", tag=msg.name, ok=ok, source="remote"})
      rednet.send(sender,{type="admin_result", ok=ok},PROTOCOL)

    elseif msg.cmd=="user_clear_doors" then
      local ok = clearUserDoors(msg.name)
      logEvent({event="user_clear_doors", tag=msg.name, ok=ok, source="remote"})
      rednet.send(sender,{type="admin_result", ok=ok},PROTOCOL)

    elseif msg.cmd=="user_clone" then
      local ok = cloneUserAccess(msg.source, msg.name, msg.includeCode)
      logEvent({event="user_clone", tag=msg.name, ok=ok, source="remote", detail=tostring(msg.source)})
      rednet.send(sender,{type="admin_result", ok=ok},PROTOCOL)

    elseif msg.cmd=="user_search" then
      rednet.send(sender,{type="admin_users", users=searchUsers(msg.query)},PROTOCOL)

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
local function pause(message)
  if message and message ~= "" then
    print(message)
  end
  print("Press Enter to continue.")
  read()
end

local function drawHeader(title, subtitle)
  term.clear()
  term.setCursorPos(1, 1)
  setColor(colors.cyan)
  print(title)
  setColor(colors.white)
  if subtitle and subtitle ~= "" then
    print(subtitle)
  end
  print(string.rep("-", 36))
end

local function printDoorSummary(tag, door)
  local userCount = 0
  for _, user in pairs(db.users) do
    if user and user.doors and user.doors[tag] then
      userCount = userCount + 1
    end
  end

  print(('%s | pins:%d | open:%ss | users:%d')
    :format(tag, #(door.pins or {}), tonumber(door.openTime) or 3, userCount))
end

local function printUserSummary(user)
  print(('%s | doors:%d | code:%s | card:%s')
    :format(user.name, user.doorCount or 0, user.hasCode and "yes" or "no", user.hasCard and "yes" or "no"))
end

local function showControllers()
  drawHeader("[DoorAuth Server] Controllers", "Registered controllers by door tag")
  local count = 0
  for tag, set in pairs(controllersByTag) do
    local ids = {}
    for id, _ in pairs(set) do
      table.insert(ids, tostring(id))
    end
    table.sort(ids)
    print(tag .. " -> " .. table.concat(ids, ", "))
    count = count + 1
  end
  if count == 0 then
    print("No controllers are registered.")
  end
  pause()
end

local function showDoorList()
  drawHeader("[DoorAuth Server] Doors", "Available doors and current access totals")
  local tags = {}
  for tag in pairs(db.doors) do
    table.insert(tags, tag)
  end
  table.sort(tags)

  if #tags == 0 then
    print("No doors configured yet.")
    pause()
    return
  end

  for _, tag in ipairs(tags) do
    printDoorSummary(tag, db.doors[tag])
  end
  pause()
end

local function showDoorDetail()
  drawHeader("[DoorAuth Server] Door Detail", "Inspect one door at a time")
  write("Door tag: ")
  local tag = trim(read())
  local door = db.doors[tag]
  drawHeader("[DoorAuth Server] Door Detail", tag ~= "" and tag or "No tag entered")

  if not door then
    print("No such door.")
    pause()
    return
  end

  print("Open time: " .. tostring(door.openTime or 3) .. " seconds")
  print("Pins:")
  if type(door.pins) ~= "table" or #door.pins == 0 then
    print("  (none)")
  else
    for _, pin in ipairs(door.pins) do
      print("  " .. tostring(pin))
    end
  end

  print("Users:")
  local found = false
  for name, user in pairs(db.users) do
    if user and user.doors and user.doors[tag] then
      found = true
      print("  " .. name .. (user.cardToken and " [card]" or ""))
    end
  end
  if not found then
    print("  (none)")
  end

  pause()
end

local function editDoorPin(action)
  drawHeader("[DoorAuth Server] Door PINs", action == "add" and "Add a PIN to a door" or "Remove a PIN from a door")
  write("Door tag: ")
  local tag = trim(read())
  write(action == "add" and "New PIN: " or "PIN to remove: ")
  local pin = trim(read())
  if tag == "" or pin == "" then
    pause("Missing door tag or PIN.")
    return
  end

  local ok = action == "add" and addPin(tag, pin) or removePin(tag, pin)
  logEvent({event = action == "add" and "pin_add" or "pin_del", tag = tag, ok = ok, source = "console"})
  pause(ok and "Saved." or "No change.")
end

local function setDoorOpenTime()
  drawHeader("[DoorAuth Server] Open Time", "Set how long the door stays open")
  write("Door tag: ")
  local tag = trim(read())
  write("Seconds: ")
  local seconds = tonumber(read())
  if tag == "" or not seconds then
    pause("Missing door tag or invalid seconds.")
    return
  end

  ensureDoor(tag)
  db.doors[tag].openTime = seconds
  logEvent({event = "opentime_set", tag = tag, ok = true, source = "console", detail = tostring(seconds)})
  pause("Updated.")
end

local function removeDoor()
  drawHeader("[DoorAuth Server] Remove Door", "Delete a door and all of its PINs")
  write("Door tag: ")
  local tag = trim(read())
  if tag == "" then
    pause("Missing door tag.")
    return
  end

  local existed = db.doors[tag] ~= nil
  db.doors[tag] = nil
  logEvent({event = "door_remove", tag = tag, ok = existed, source = "console"})
  pause(existed and "Door removed." or "No such door.")
end

local function listUsersScreen()
  drawHeader("[DoorAuth Server] Users", "Current users and access state")
  local users = listUsers()
  if #users == 0 then
    print("No users configured yet.")
  else
    for _, user in ipairs(users) do
      printUserSummary(user)
    end
  end
  pause()
end

local function showUserScreen()
  drawHeader("[DoorAuth Server] User Detail", "Inspect one user at a time")
  write("User name: ")
  local name = trim(read())
  local user = db.users[name]
  local doors = listUserDoors(name) or {}
  drawHeader("[DoorAuth Server] User Detail", name ~= "" and name or "No name entered")

  if not user then
    print("No such user.")
    pause()
    return
  end

  print("Code set: " .. tostring(user.codeHash and "yes" or "no"))
  print("Card token: " .. tostring(user.cardToken and "yes" or "no"))
  print("Doors:")
  if #doors == 0 then
    print("  (none)")
  else
    for _, door in ipairs(doors) do
      print("  " .. door)
    end
  end

  pause()
end

local function editUserCode()
  drawHeader("[DoorAuth Server] User Code", "Add or update a per-user code")
  write("User name: ")
  local name = trim(read())
  write("New code: ")
  local code = read()
  if name == "" or trim(code) == "" then
    pause("Missing user name or code.")
    return
  end

  local ok = addUser(name, code)
  logEvent({event = "user_add", tag = name, ok = ok, source = "console"})
  pause(ok and "Saved." or "Failed.")
end

local function removeUserScreen()
  drawHeader("[DoorAuth Server] Remove User", "Delete a user and all of their access")
  write("User name: ")
  local name = trim(read())
  if name == "" then
    pause("Missing user name.")
    return
  end

  local ok = removeUser(name)
  logEvent({event = "user_del", tag = name, ok = ok, source = "console"})
  pause(ok and "User removed." or "Not found.")
end

local function userDoorAccess(action)
  drawHeader("[DoorAuth Server] User Door Access", action == "enable" and "Grant access to a door" or "Revoke access from a door")
  write("User name: ")
  local name = trim(read())
  write("Door tag: ")
  local tag = trim(read())
  if name == "" or tag == "" then
    pause("Missing user name or door tag.")
    return
  end

  local ok = action == "enable" and enableUserDoor(name, tag) or disableUserDoor(name, tag)
  logEvent({event = action == "enable" and "user_enable" or "user_disable", tag = tag, ok = ok, source = "console", detail = name})
  pause(ok and "Updated." or "Failed.")
end

local function userDoorsScreen()
  drawHeader("[DoorAuth Server] User Doors", "Show every door enabled for one user")
  write("User name: ")
  local name = trim(read())
  local doors = listUserDoors(name)
  drawHeader("[DoorAuth Server] User Doors", name ~= "" and name or "No name entered")

  if not doors then
    print("No such user.")
  elseif #doors == 0 then
    print("(none)")
  else
    for _, door in ipairs(doors) do
      print("  " .. door)
    end
  end

  pause()
end

local function userCardScreen(action)
  drawHeader("[DoorAuth Server] User Cards", action == "issue" and "Issue a reusable card token" or "Clear a card token")
  write("User name: ")
  local name = trim(read())
  if name == "" then
    pause("Missing user name.")
    return
  end

  if action == "issue" then
    local token = issueUserCard(name)
    local ok = token ~= nil
    logEvent({event = "user_card_issue", tag = name, ok = ok, source = "console"})
    if ok then
      print("Card token:")
      print(token)
    else
      print("Failed.")
    end
  else
    local ok = clearUserCard(name)
    logEvent({event = "user_card_clear", tag = name, ok = ok, source = "console"})
    print(ok and "Cleared." or "Not found.")
  end

  pause()
end

local function userCardStatusScreen()
  drawHeader("[DoorAuth Server] User Card Status", "View whether a user currently has a card token")
  write("User name: ")
  local name = trim(read())
  local user = db.users[name]
  drawHeader("[DoorAuth Server] User Card Status", name ~= "" and name or "No name entered")

  if not user then
    print("No such user.")
  else
    print("Card token: " .. tostring(user.cardToken and "yes" or "no"))
    if user.cardToken then
      print(user.cardToken)
    end
  end

  pause()
end

local function lockdownScreen(enable)
  lockdown = enable and true or false
  logEvent({event = enable and "lockdown_on" or "lockdown_off", ok = true, source = "console"})
  pause(enable and "LOCKDOWN ENABLED" or "Lockdown disabled.")
end

local function remoteOpenScreen()
  drawHeader("[DoorAuth Server] Remote Open", "Trigger a door pulse from the server")
  write("Door tag: ")
  local tag = trim(read())
  if tag == "" then
    pause("Missing door tag.")
    return
  end

  if lockdown then
    logEvent({event = "remote_open", tag = tag, ok = false, source = "console", detail = "blocked_by_lockdown"})
    pause("Blocked by lockdown.")
    return
  end

  local door = db.doors[tag]
  local duration = (door and door.openTime) or 3
  broadcastOpen(tag, duration)
  logEvent({event = "remote_open", tag = tag, ok = true, source = "console"})
  pause("Door opened for " .. tostring(duration) .. " seconds.")
end

local function logsScreen()
  local index = math.max(#logs - 24 + 1, 1)
  while true do
    drawHeader("[DoorAuth Server] Audit Logs", "W/S scroll, Enter returns")
    if #logs == 0 then
      print("No log entries yet.")
    else
      local last = math.min(index + 23, #logs)
      for i = index, last do
        local e = logs[i]
        local status = e.ok == nil and "" or (e.ok and "OK" or "FAIL")
        print(('%4d %s %-14s %s %s')
          :format(i, e.time or "??:??", e.event or "?", status, e.detail or ""))
      end
      print(string.format("Showing %d-%d of %d", index, math.min(index + 23, #logs), #logs))
    end

    write("Command: ")
    local choice = string.lower(trim(read()))
    if choice == "w" then
      index = math.max(1, index - 1)
    elseif choice == "s" then
      index = math.min(math.max(#logs - 23 + 1, 1), index + 1)
    else
      return
    end
  end
end

local function systemScreen()
  while true do
    drawHeader("[DoorAuth Server] System", "Maintenance and device status")
    print("1) List controllers")
    print("2) Save now")
    print("3) Reboot server")
    print("4) Back")
    write("Choose: ")
    local choice = trim(read())
    if choice == "1" then
      showControllers()
    elseif choice == "2" then
      saveDB()
      saveLogs()
      pause("Saved.")
    elseif choice == "3" then
      saveDB()
      saveLogs()
      pause("Rebooting...")
      sleep(0.2)
      os.reboot()
    elseif choice == "4" or choice == "" then
      return
    end
  end
end

local function doorsMenu()
  while true do
    drawHeader("[DoorAuth Server] Doors", "Manage door PINs and open times")
    print("1) List doors")
    print("2) Show door")
    print("3) Add PIN")
    print("4) Remove PIN")
    print("5) Set open time")
    print("6) Remove door")
    print("7) Back")
    write("Choose: ")
    local choice = trim(read())
    if choice == "1" then
      showDoorList()
    elseif choice == "2" then
      showDoorDetail()
    elseif choice == "3" then
      editDoorPin("add")
    elseif choice == "4" then
      editDoorPin("del")
    elseif choice == "5" then
      setDoorOpenTime()
    elseif choice == "6" then
      removeDoor()
    elseif choice == "7" or choice == "" then
      return
    end
  end
end

local function usersMenu()
  while true do
    drawHeader("[DoorAuth Server] Users", "Manage per-user codes, doors, and cards")
    print("1) List users")
    print("2) Show user")
    print("3) Add or update code")
    print("4) Remove user")
    print("5) Enable door for user")
    print("6) Disable door for user")
    print("7) Show user's doors")
    print("8) Issue card token")
    print("9) Clear card token")
    print("10) Clear user code")
    print("11) Clear all doors")
    print("12) Clone access from user")
    print("13) Search users")
    print("14) Card status")
    print("15) Back")
    write("Choose: ")
    local choice = trim(read())
    if choice == "1" then
      listUsersScreen()
    elseif choice == "2" then
      showUserScreen()
    elseif choice == "3" then
      editUserCode()
    elseif choice == "4" then
      removeUserScreen()
    elseif choice == "5" then
      userDoorAccess("enable")
    elseif choice == "6" then
      userDoorAccess("disable")
    elseif choice == "7" then
      userDoorsScreen()
    elseif choice == "8" then
      userCardScreen("issue")
    elseif choice == "9" then
      userCardScreen("clear")
    elseif choice == "10" then
      drawHeader("[DoorAuth Server] Users", "Clear a user's code")
      write("User name: ")
      local name = trim(read())
      if name ~= "" then
        local ok = clearUserCode(name)
        logEvent({event = "user_clear_code", tag = name, ok = ok, source = "console"})
        pause(ok and "Code cleared." or "Not found.")
      else
        pause("Missing user name.")
      end
    elseif choice == "11" then
      drawHeader("[DoorAuth Server] Users", "Remove every enabled door from a user")
      write("User name: ")
      local name = trim(read())
      if name ~= "" then
        local ok = clearUserDoors(name)
        logEvent({event = "user_clear_doors", tag = name, ok = ok, source = "console"})
        pause(ok and "Doors cleared." or "Not found.")
      else
        pause("Missing user name.")
      end
    elseif choice == "12" then
      drawHeader("[DoorAuth Server] Users", "Clone access from one user to another")
      write("Source user: ")
      local source = trim(read())
      write("Target user: ")
      local target = trim(read())
      write("Copy code too? (yes/no): ")
      local copyCode = trim(read())
      if source ~= "" and target ~= "" then
        local ok = cloneUserAccess(source, target, copyCode == "yes" or copyCode == "y" or copyCode == "true" or copyCode == "1")
        logEvent({event = "user_clone", tag = target, ok = ok, source = "console", detail = source})
        pause(ok and "Access cloned." or "Failed.")
      else
        pause("Missing source or target user.")
      end
    elseif choice == "13" then
      drawHeader("[DoorAuth Server] Users", "Search by name, door, code, or card")
      write("Search: ")
      local query = trim(read())
      local users = searchUsers(query)
      if #users == 0 then
        print("No matching users.")
      else
        for _, user in ipairs(users) do
          printUserSummary(user)
        end
      end
      pause()
    elseif choice == "14" then
      userCardStatusScreen()
    elseif choice == "15" or choice == "" then
      return
    end
  end
end

local function securityMenu()
  while true do
    drawHeader("[DoorAuth Server] Security", lockdown and "Lockdown is currently ON" or "Lockdown is currently OFF")
    print("1) Enable lockdown")
    print("2) Disable lockdown")
    print("3) Remote open door")
    print("4) Back")
    write("Choose: ")
    local choice = trim(read())
    if choice == "1" then
      lockdownScreen(true)
    elseif choice == "2" then
      lockdownScreen(false)
    elseif choice == "3" then
      remoteOpenScreen()
    elseif choice == "4" or choice == "" then
      return
    end
  end
end

local function helpScreen()
  drawHeader("[DoorAuth Server] Help", "Menu-driven console actions")
  print("Use the numbered menus to manage doors, users, cards, logs, and server maintenance.")
  print("The admin PIN prompt still protects privileged actions.")
  pause()
end

local function consoleLoop()
  while true do
    drawHeader("[DoorAuth Server] Console", "Structured admin navigation")
    print("1) Doors")
    print("2) Users")
    print("3) Security")
    print("4) Logs")
    print("5) System")
    print("6) Help")
    write("Choose: ")
    local choice = trim(read())
    if choice == "1" then
      doorsMenu()
    elseif choice == "2" then
      usersMenu()
    elseif choice == "3" then
      securityMenu()
    elseif choice == "4" then
      logsScreen()
    elseif choice == "5" then
      systemScreen()
    elseif choice == "6" then
      helpScreen()
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
