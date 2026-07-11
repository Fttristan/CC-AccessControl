-- door_fob.lua
-- Pocket Computer wireless keypad for DoorAuth system
-- NOW WITH AUTO-DOOR DISCOVERY + scroll menu

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

local config = startupPrompt("DoorAuth Fob Setup", "door_fob", defaultConfig, configFields)

local PROTOCOL     = config.protocol
local SERVER_NAME  = config.server_name
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

local function drawHeader(title, subtitle)
  term.clear()
  term.setCursorPos(1, 1)
  print(title)
  if subtitle and subtitle ~= "" then
    print(subtitle)
  end
  print(string.rep("-", 36))
end

local function pause(message)
  if message and message ~= "" then
    print(message)
  end
  print("Press Enter to continue.")
  read()
end

local function trim(s)
  s = tostring(s or "")
  return s:gsub("^%s+", ""):gsub("%s+$", "")
end

local function getDoorList()
  local server = findServer()
  if not server then return nil, "Server offline." end

  rednet.send(server, {type="door_list"}, PROTOCOL)
  local id, msg = rednet.receive(PROTOCOL, REQUEST_TIMEOUT)

  if not id then return nil, "Timeout." end
  if msg.type ~= "door_list" then return nil, "Bad response." end

  return msg.tags, nil
end

local function askPin()
  drawHeader("[DoorAuth Fob] Enter Code", "Leave blank to go back")
  write("Code: ")
  local pin = read("*")
  pin = trim(pin)
  if pin == "" then
    return nil
  end
  return pin
end

local function sendVerify(tag, pin)
  local server = findServer()
  if not server then return nil, "Server offline." end

  rednet.send(server, {
    type="verify",
    tag=tag,
    code=pin
  }, PROTOCOL)

  local id, msg = rednet.receive(PROTOCOL, REQUEST_TIMEOUT)
  if not id then return nil, "No response." end
  if msg.type ~= "verify_result" then return nil, "Bad response." end

  return msg.ok, nil
end

local lastDoor = nil

---------------------------------------------------
-- DOOR SELECTION MENU
---------------------------------------------------
local function pickDoor()
  local list, err = getDoorList()
  if not list then
    drawHeader("[DoorAuth Fob] Door List", "Could not load doors")
    print(err)
    pause()
    return nil
  end

  if #list == 0 then
    drawHeader("[DoorAuth Fob] Door List", "No doors registered")
    pause()
    return nil
  end

  local sel = 1
  local maxVisible = 6
  local filter = ""

  local function filteredDoors()
    if filter == "" then
      return list
    end

    local out = {}
    local needle = filter:lower()
    for _, door in ipairs(list) do
      if door:lower():find(needle, 1, true) then
        table.insert(out, door)
      end
    end
    return out
  end

  local function draw()
    local doors = filteredDoors()
    drawHeader("[DoorAuth Fob] Select Door", filter ~= "" and ("Filter: " .. filter) or "W/S move, Enter choose, / filter, R reset, Q back")

    if #doors == 0 then
      print("No matching doors.")
      return doors
    end

    if sel > #doors then
      sel = #doors
    end
    if sel < 1 then
      sel = 1
    end

    local start = math.max(1, sel - math.floor(maxVisible / 2))
    local finish = math.min(#doors, start + maxVisible - 1)

    for i=start, finish do
      term.setCursorPos(2, i - start + 4)
      if i == sel then
        if term.isColor() then term.setTextColor(colors.cyan) end
        print(" > "..doors[i])
        term.setTextColor(colors.white)
      else
        print("   "..doors[i])
      end
    end

    print("")
    print("Total: " .. tostring(#doors) .. " door(s)")

    return doors
  end

  while true do
    local doors = draw()
    if #doors == 0 then
      write("Filter or Q: ")
    else
      write("Command: ")
    end
    local c = string.lower(trim(read()))

    if c == "w" then
      if sel > 1 then sel = sel - 1 end
    elseif c == "s" then
      if sel < #doors then sel = sel + 1 end
    elseif c == "/" then
      write("Filter text: ")
      filter = trim(read())
      sel = 1
    elseif c == "r" then
      filter = ""
      sel = 1
    elseif c == "q" then
      return nil
    elseif c == "" or c == "enter" then
      return doors[sel]
    elseif filter == "" and #c > 0 then
      filter = c
      sel = 1
    end
  end
end

---------------------------------------------------
-- MAIN LOOP
---------------------------------------------------
openModems()

while true do
  drawHeader("[DoorAuth Fob] Main Menu", "1) Select door  2) Refresh list  3) Quit")
  if lastDoor then
    print("Last door: " .. tostring(lastDoor))
  end
  write("Choose: ")
  local choice = string.lower(trim(read()))

  if choice == "3" or choice == "q" then
    drawHeader("[DoorAuth Fob] Goodbye", "Session ended")
    return
  elseif choice == "2" then
    pause("Refreshing door list...")
  else
    local door = nil
    if choice == "1" or choice == "" then
      door = pickDoor()
    elseif lastDoor and (choice == "l" or choice == "last") then
      door = lastDoor
    end

    if not door then
      pause("No door selected.")
    else
      local pin = askPin()
      if not pin then
        pause("Canceled.")
      else
        drawHeader("[DoorAuth Fob] Sending", "Door: " .. door)
        print("Verifying code...")

        local ok, err = sendVerify(door, pin)
        lastDoor = door

        drawHeader("[DoorAuth Fob] Access Result", "Door: " .. door)
        if err then
          print("Error: " .. err)
        elseif ok then
          print("ACCESS GRANTED")
          print("Door opening...")
        else
          print("ACCESS DENIED")
        end

        pause()
      end
    end
  end
end
