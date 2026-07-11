-- admin_remote.lua (REMOTE OPEN + LOCKDOWN + LOG VIEW)

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

local defaultConfig = {
  protocol = "doorAuth.v1",
  server_name = "DoorAuthServer",
  request_timeout = 3,
}

local configFields = {
  { key = "protocol", label = "Protocol" },
  { key = "server_name", label = "Server Name" },
  { key = "request_timeout", label = "Request Timeout" },
}

local config = startupPrompt("DoorAuth Admin Remote Setup", "admin_remote", defaultConfig, configFields)

local PROTOCOL = config.protocol
local SERVER_NAME = config.server_name
local REQUEST_TIMEOUT = tonumber(config.request_timeout) or 3

---------------------------------------------------
-- UTILS
---------------------------------------------------
local function openModems()
  for _,side in ipairs(rs.getSides()) do
    if peripheral.getType(side)=="modem" then
      rednet.open(side)
    end
  end
end

local function findServer()
  return rednet.lookup(PROTOCOL, SERVER_NAME)
end

-- fallback hash (same as server)
local function hash(str)
  local h=0
  for i=1,#str do h=(h*31 + str:byte(i)) % 2^31 end
  return tostring(h)
end

local function setColor(col)
  if term.isColor and term.isColor() then
    term.setTextColor(col)
  end
end

local function drawHeader(title, subtitle)
  term.clear()
  term.setCursorPos(1,1)
  setColor(colors.cyan)
  print(title)
  setColor(colors.white)
  if subtitle and subtitle ~= "" then
    print(subtitle)
  end
  print(string.rep("-", 38))
end

local function pause(message)
  if message and message ~= "" then
    print(message)
  end
  print("Press Enter to continue.")
  read()
end

local function loginWithPin(pin)
  local server = findServer()
  if not server then
    return nil, "Server not found!"
  end

  local stamp = tostring(os.epoch("utc"))
  local sig = hash(hash(pin) .. stamp)

  rednet.send(server, {
    type = "admin_login",
    timestamp = stamp,
    sig = sig,
  }, PROTOCOL)

  local id, msg = rednet.receive(PROTOCOL, REQUEST_TIMEOUT)
  if id == server and msg and msg.type == "admin_login_ok" then
    return msg.token, nil
  end

  return nil, "Login failed."
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

  local ok, err = pcall(reader.writeCard, token)
  if not ok then
    return false, err or "Write failed."
  end

  sleep(0.2)

  local readBack = nil
  local readOk, readErr = pcall(reader.readCard)
  if readOk then
    readBack = readErr
  end

  if readBack ~= token then
    return false, "Card verification failed."
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

---------------------------------------------------
-- LOGIN
---------------------------------------------------
local function login()
  drawHeader("[DoorAuth Admin Remote] Login", "Enter the admin PIN to open the session")
  local pin=read("*")
  local token, err = loginWithPin(pin)
  if token then
    sleep(0.4)
    drawHeader("[DoorAuth Admin Remote] Login", "Session established")
    return { token = token, pin = pin, startedAt = os.epoch("utc") }
  end

  pause(err or "Login failed.")
  return nil
end

---------------------------------------------------
-- SEND ADMIN CMD
---------------------------------------------------
local function adminCmd(token,cmdTable)
  local server=findServer()
  if not server then
    print("Server offline.")
    sleep(1)
    return nil
  end

  local function sendOnce(currentToken)
    cmdTable.type = "admin_cmd"
    cmdTable.token = currentToken

    rednet.send(server, cmdTable, PROTOCOL)
    local _, msg = rednet.receive(PROTOCOL, REQUEST_TIMEOUT)
    return msg
  end

  local msg = sendOnce(token.token)
  if msg and msg.type == "admin_denied" and token.pin then
    drawHeader("[DoorAuth Admin Remote] Session", "Session expired, reauthenticating")
    local renewed, err = loginWithPin(token.pin)
    if renewed then
      token.token = renewed
      token.startedAt = os.epoch("utc")
      msg = sendOnce(token.token)
    else
      pause(err or "Unable to renew the session.")
      return nil
    end
  end

  return msg
end

---------------------------------------------------
-- LOG VIEWER (Mode 3: interactive scroll)
---------------------------------------------------
local function viewLogs(session)
  local msg = adminCmd(session, {cmd="logs"})
  if not msg or msg.type ~= "admin_logs" or type(msg.logs) ~= "table" then
    drawHeader("[DoorAuth Admin Remote] Logs", "No logs or error fetching logs")
    pause()
    return
  end

  local logs = msg.logs
  if #logs == 0 then
    drawHeader("[DoorAuth Admin Remote] Logs", "No log entries yet")
    pause()
    return
  end

  local maxVisible = 8
  local pos = math.max(#logs - maxVisible + 1, 1) -- start near newest

  local function draw()
    drawHeader("[DoorAuth Admin Remote] Audit Logs", "W/S scroll, Q back")

    local last = math.min(pos + maxVisible - 1, #logs)
    for i = pos, last do
      local e = logs[i]
      local lineY = 3 + (i - pos) + 1
      term.setCursorPos(1, lineY)

      local label = string.format("%4d %s %-14s", i, e.time or "??:??", e.event or "?")

      local tail = ""
      if e.tag then tail = tail .. " tag="..tostring(e.tag) end
      if e.ok ~= nil then
        tail = tail .. " "..(e.ok and "OK" or "FAIL")
      end
      if e.detail then
        tail = tail .. " "..tostring(e.detail)
      end

      local color = colors.white
      if e.event == "pin_attempt" then
        color = e.ok and colors.lime or colors.red
      elseif e.event == "door_open" or e.event == "remote_open" then
        color = colors.cyan
      elseif e.event == "lockdown_on" or e.event == "lockdown_off" then
        color = colors.orange or colors.yellow
      elseif e.event == "admin_login" then
        color = e.ok and colors.lime or colors.red
      end

      setColor(color)
      write(label.." "..tail)
      setColor(colors.white)
    end

    local footerY = maxVisible + 5
    term.setCursorPos(1, footerY)
    print(string.format("Showing %d-%d of %d", pos, last, #logs))
  end

  while true do
    draw()
    term.setCursorPos(1, maxVisible + 7)
    write("Command (W/S/Q): ")
    local inp = read()
    inp = string.lower(inp or "")

    if inp == "w" then
      if pos > 1 then pos = pos - 1 end
    elseif inp == "s" then
      if pos < math.max(#logs - maxVisible + 1, 1) then
        pos = pos + 1
      end
    elseif inp == "q" or inp == "" then
      break
    end
  end

  drawHeader("[DoorAuth Admin Remote] Logs", "Returning to menu")
end

local function manageUsers(session)
  while true do
    drawHeader("[DoorAuth Admin Remote] Users", "Manage per-user codes, doors, and cards")
    print("1) List users")
    print("2) Show user")
    print("3) Add or update code")
    print("4) Remove user")
    print("5) Enable door for user")
    print("6) Disable door for user")
    print("7) Show user's doors")
    print("8) Issue/write magnetic card")
    print("9) Clear magnetic card")
    print("10) Clear user code")
    print("11) Clear all doors")
    print("12) Clone access from user")
    print("13) Search users")
    print("14) Back")
    write("Choose: ")
    local c = read()

    if c == "1" then
      local msg = adminCmd(session, {cmd="user_list"})
      drawHeader("[DoorAuth Admin Remote] Users", "Registered users")
      if msg and msg.users then
        print("Users:")
        for _,user in ipairs(msg.users) do
          print(("%s (doors:%d, card:%s)"):format(user.name, user.doorCount or 0, user.hasCard and "yes" or "no"))
        end
      else
        print("No response.")
      end
      print("\nPress Enter…")
      read()

    elseif c == "2" then
      write("User name: ") local name = read()
      local msg = adminCmd(session, {cmd="user_show", name=name})
      drawHeader("[DoorAuth Admin Remote] Users", name)
      if msg and msg.user then
        print("User:", msg.name or name)
        print("Code set:", msg.user.codeHash and "yes" or "no")
        print("Card:", msg.user.hasCard and "yes" or "no")
        print("Doors:")
        for _,door in ipairs(msg.doors or {}) do print("  "..door) end
      else
        print("No such user.")
      end
      print("\nPress Enter…")
      read()

    elseif c == "3" then
      write("User name: ") local name = read()
      write("New code: ") local code = read()
      local msg = adminCmd(session, {cmd="user_add", name=name, code=code})
      drawHeader("[DoorAuth Admin Remote] Users", name)
      print(msg and msg.ok and "Saved." or "Failed.")
      sleep(1)

    elseif c == "4" then
      write("User name: ") local name = read()
      local msg = adminCmd(session, {cmd="user_del", name=name})
      drawHeader("[DoorAuth Admin Remote] Users", name)
      print(msg and msg.ok and "Removed." or "Not found or error.")
      sleep(1)

    elseif c == "5" then
      write("User name: ") local name = read()
      write("Door tag: ") local tag = read()
      local msg = adminCmd(session, {cmd="user_enable", name=name, tag=tag})
      drawHeader("[DoorAuth Admin Remote] Users", name .. " -> " .. tag)
      print(msg and msg.ok and "Enabled." or "Failed.")
      sleep(1)

    elseif c == "6" then
      write("User name: ") local name = read()
      write("Door tag: ") local tag = read()
      local msg = adminCmd(session, {cmd="user_disable", name=name, tag=tag})
      drawHeader("[DoorAuth Admin Remote] Users", name .. " -> " .. tag)
      print(msg and msg.ok and "Disabled." or "Failed.")
      sleep(1)

    elseif c == "7" then
      write("User name: ") local name = read()
      local msg = adminCmd(session, {cmd="user_doors", name=name})
      drawHeader("[DoorAuth Admin Remote] Users", name)
      if msg and msg.doors then
        print("Doors for "..(msg.name or name)..":")
        if #msg.doors == 0 then
          print("  (none)")
        else
          for _,door in ipairs(msg.doors) do
            print("  "..door)
          end
        end
      else
        print("No such user.")
      end
      print("\nPress Enter…")
      read()

    elseif c == "8" then
      if isPocketComputer() then
        drawHeader("[DoorAuth Admin Remote] Users", name)
        print("Card writing is not supported on pocket computers.")
        sleep(1.5)
      else
        local manipName, manip = findCardManipulator()
        if not manipName then
          drawHeader("[DoorAuth Admin Remote] Users", name)
          print("No magnetic card manipulator found.")
          sleep(1.5)
        else
          write("User name: ") local name = read()
          local msg = adminCmd(session, {cmd="user_card_issue", name=name})
          drawHeader("[DoorAuth Admin Remote] Users", name)
          if not msg or not msg.ok or not msg.token then
            print("Failed to issue card token.")
            sleep(1.5)
          else
            print("Insert a magnetic card into " .. manipName .. ".")
            print("Writing card for " .. name .. "...")
            local ok, err = writeCard(manip, msg.token, name)
            if ok then
              print("Card written.")
            else
              adminCmd(session, {cmd="user_card_clear", name=name})
              print("Write failed: " .. tostring(err))
            end
            print("\nPress Enter…")
            read()
          end
        end
      end

    elseif c == "9" then
      write("User name: ") local name = read()
      local msg = adminCmd(session, {cmd="user_card_clear", name=name})
      drawHeader("[DoorAuth Admin Remote] Users", name)
      print(msg and msg.ok and "Card cleared." or "Not found or error.")
      sleep(1)

    elseif c == "10" then
      write("User name: ") local name = read()
      local msg = adminCmd(session, {cmd="user_clear_code", name=name})
      drawHeader("[DoorAuth Admin Remote] Users", name)
      print(msg and msg.ok and "Code cleared." or "Not found or error.")
      sleep(1)

    elseif c == "11" then
      write("User name: ") local name = read()
      local msg = adminCmd(session, {cmd="user_clear_doors", name=name})
      drawHeader("[DoorAuth Admin Remote] Users", name)
      print(msg and msg.ok and "Doors cleared." or "Not found or error.")
      sleep(1)

    elseif c == "12" then
      write("Source user: ") local source = read()
      write("Target user: ") local target = read()
      write("Copy code too? (yes/no): ") local copyCode = read()
      local copyCodeValue = tostring(copyCode or ""):lower()
      local includeCode = copyCodeValue == "yes" or copyCodeValue == "y" or copyCodeValue == "true" or copyCodeValue == "1"
      local msg = adminCmd(session, {cmd="user_clone", source=source, name=target, includeCode=includeCode})
      drawHeader("[DoorAuth Admin Remote] Users", target)
      print(msg and msg.ok and "Access cloned." or "Failed.")
      sleep(1)

    elseif c == "13" then
      write("Search: ") local query = read()
      local msg = adminCmd(session, {cmd="user_search", query=query})
      drawHeader("[DoorAuth Admin Remote] Users", query)
      if msg and msg.users then
        for _,user in ipairs(msg.users) do
          print(('%s (doors:%d, card:%s)'):format(user.name, user.doorCount or 0, user.hasCard and "yes" or "no"))
        end
      else
        print("No matching users.")
      end
      print("\nPress Enter…")
      read()

    elseif c == "14" then
      return
    end
  end
end

local function doorsMenu(session)
  while true do
    drawHeader("[DoorAuth Admin Remote] Doors", "Manage door PINs and open times")
    print("1) List doors")
    print("2) Show door")
    print("3) Add PIN")
    print("4) Remove PIN")
    print("5) Remove door")
    print("6) Set open time")
    print("7) Back")
    write("Choose: ")
    local c = read()

    if c == "1" then
      local msg = adminCmd(session, {cmd = "list"})
      drawHeader("[DoorAuth Admin Remote] Doors", "Registered door list")
      if msg and msg.doors then
        print("Doors:")
        for tag, data in pairs(msg.doors) do
          print(("%s (pins:%d, open:%s)"):format(tag, #data.pins, data.openTime))
        end
      else
        print("No response.")
      end
      print("\nPress Enter…")
      read()

    elseif c == "2" then
      write("Door tag: ") local tag = read()
      local msg = adminCmd(session, {cmd = "show", tag = tag})
      drawHeader("[DoorAuth Admin Remote] Doors", tag)
      if msg and msg.door then
        print("Door:", tag)
        print("OpenTime:", msg.door.openTime)
        print("Pins:")
        for _, p in ipairs(msg.door.pins) do print("  " .. p) end
      else
        print("No such door.")
      end
      print("\nPress Enter…")
      read()

    elseif c == "3" then
      write("Door tag: ") local tag = read()
      write("New PIN: ") local pin = read()
      local msg = adminCmd(session, {cmd = "add", tag = tag, pin = pin})
      drawHeader("[DoorAuth Admin Remote] Doors", tag)
      print(msg and msg.ok and "Added." or "Already exists or error.")
      sleep(1)

    elseif c == "4" then
      write("Door tag: ") local tag = read()
      write("PIN to remove: ") local pin = read()
      local msg = adminCmd(session, {cmd = "del", tag = tag, pin = pin})
      drawHeader("[DoorAuth Admin Remote] Doors", tag)
      print(msg and msg.ok and "Removed." or "Not found or error.")
      sleep(1)

    elseif c == "5" then
      write("Door tag: ") local tag = read()
      local msg = adminCmd(session, {cmd = "remove", tag = tag})
      drawHeader("[DoorAuth Admin Remote] Doors", tag)
      print(msg and msg.ok and "Door removed." or "No such door.")
      sleep(1)

    elseif c == "6" then
      write("Door tag: ") local tag = read()
      write("Seconds: ") local sec = read()
      local msg = adminCmd(session, {cmd = "opentime", tag = tag, seconds = sec})
      drawHeader("[DoorAuth Admin Remote] Doors", tag)
      print(msg and msg.ok and "Updated." or "Failed.")
      sleep(1)

    elseif c == "7" or c == "" then
      return
    end
  end
end

local function securityMenu(session)
  while true do
    drawHeader("[DoorAuth Admin Remote] Security", "Lockdown and remote door control")
    print("1) Remote open door")
    print("2) Enable lockdown")
    print("3) Disable lockdown")
    print("4) Back")
    write("Choose: ")
    local c = read()

    if c == "1" then
      write("Door tag to open: ") local tag = read()
      local msg = adminCmd(session, {cmd = "open", tag = tag})
      drawHeader("[DoorAuth Admin Remote] Security", tag)
      if msg and msg.ok then
        print("Door opened.")
      else
        print("Blocked (lockdown active or error).")
      end
      sleep(1)

    elseif c == "2" then
      local msg = adminCmd(session, {cmd = "lockdown_on"})
      drawHeader("[DoorAuth Admin Remote] Security", "Lockdown enabled")
      print(msg and msg.ok and "LOCKDOWN ENABLED" or "Failed.")
      sleep(1)

    elseif c == "3" then
      local msg = adminCmd(session, {cmd = "lockdown_off"})
      drawHeader("[DoorAuth Admin Remote] Security", "Lockdown disabled")
      print(msg and msg.ok and "Lockdown disabled." or "Failed.")
      sleep(1)

    elseif c == "4" or c == "" then
      return
    end
  end
end

local function helpScreen()
  drawHeader("[DoorAuth Admin Remote] Help", "Menu-driven admin categories")
  print("Use the numbered categories to manage doors, users, security, and logs.")
  print("Each screen keeps the same action set, but the navigation now mirrors the server.")
  pause()
end

---------------------------------------------------
-- MAIN MENU
---------------------------------------------------
local function mainMenu(session)
  while true do
    drawHeader("[DoorAuth Admin Remote] Console", "Structured admin navigation")
    print("1) Doors")
    print("2) Users")
    print("3) Security")
    print("4) Logs")
    print("5) Help")
    print("6) Logout")
    write("Choose: ")
    local c = read()

    if c == "1" then
      doorsMenu(session)
    elseif c == "2" then
      manageUsers(session)
    elseif c == "3" then
      securityMenu(session)
    elseif c == "4" then
      viewLogs(session)
    elseif c == "5" then
      helpScreen()
    elseif c == "6" or c == "" then
      drawHeader("[DoorAuth Admin Remote] Session", "Logged out")
      print("Logged out.")
      sleep(0.4)
      drawHeader("[DoorAuth Admin Remote] Session", "Returning to login")
      return
    end
  end
end

---------------------------------------------------
-- ENTRY
---------------------------------------------------
openModems()

while true do
  local session=login()
  if session then mainMenu(session) end
end
