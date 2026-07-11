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

local function trim(value)
  value = tostring(value or "")
  return value:gsub("^%s+", ""):gsub("%s+$", "")
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

local defaults = {
  protocol = "doorAuth.v1",
  server_name = "DoorAuthServer",
  request_timeout = 3,
  poll_interval = 2,
  output_side = "back",
  active_high = true,
}

local fields = {
  { key = "protocol", label = "Protocol" },
  { key = "server_name", label = "Server Name" },
  { key = "request_timeout", label = "Request Timeout" },
  { key = "poll_interval", label = "Poll Interval" },
  { key = "output_side", label = "Output Side", help = "Use a side name like back, front, left, right, top, bottom, or all." },
  { key = "active_high", label = "Active High", help = "true means lockdown turns the signal on; false inverts it." },
}

local config = startupPrompt("DoorAuth Lockdown Alarm Setup", "lockdown_alarm", defaults, fields)

local PROTOCOL = config.protocol
local SERVER_NAME = config.server_name
local REQUEST_TIMEOUT = config.request_timeout
local POLL_INTERVAL = math.max(0.5, tonumber(config.poll_interval) or 2)
local OUTPUT_SIDE = string.lower(trim(config.output_side))
local ACTIVE_HIGH = config.active_high ~= false

local validSides = {}
for _, side in ipairs(rs.getSides()) do
  validSides[side] = true
end

local function openModems()
  if not rs or not rednet or not peripheral then
    return
  end

  for _, side in ipairs(rs.getSides()) do
    if peripheral.getType(side) == "modem" and not rednet.isOpen(side) then
      rednet.open(side)
    end
  end
end

local function findServer()
  openModems()
  return rednet.lookup(PROTOCOL, SERVER_NAME)
end

local function setAlarm(active)
  local signal = ACTIVE_HIGH and active or not active
  if OUTPUT_SIDE == "all" then
    for _, side in ipairs(rs.getSides()) do
      redstone.setOutput(side, signal)
    end
    return
  end

  if not validSides[OUTPUT_SIDE] then
    OUTPUT_SIDE = "back"
  end
  redstone.setOutput(OUTPUT_SIDE, signal)
end

local function requestStatus()
  local server = findServer()
  if not server then
    return nil, "Server offline."
  end

  rednet.send(server, { type = "status" }, PROTOCOL)
  local id, message = rednet.receive(PROTOCOL, REQUEST_TIMEOUT)
  if id ~= server or type(message) ~= "table" or message.type ~= "status_result" then
    return nil, "No response."
  end

  return message, nil
end

local function drawScreen(lockdown, state)
  term.clear()
  term.setCursorPos(1, 1)
  print("DoorAuth Lockdown Alarm")
  print("Server: " .. SERVER_NAME)
  print("Protocol: " .. PROTOCOL)
  print("Output: " .. (OUTPUT_SIDE == "all" and "all sides" or OUTPUT_SIDE))
  print("Mode: " .. (ACTIVE_HIGH and "active-high" or "active-low"))
  print("")
  if lockdown == nil then
    print("Lockdown: unknown")
  else
    print("Lockdown: " .. tostring(lockdown and "ON" or "OFF"))
  end
  print("Alarm: " .. state)
end

local alarmActive = false
local currentState = "waiting"

setAlarm(false)
drawScreen(nil, currentState)

while true do
  local message, err = requestStatus()
  if message and type(message.lockdown) == "boolean" then
    alarmActive = message.lockdown
    setAlarm(alarmActive)
    currentState = alarmActive and "SIGNAL ON" or "signal off"
    drawScreen(message.lockdown, currentState)
  else
    alarmActive = false
    setAlarm(false)
    currentState = "server offline"
    drawScreen(nil, currentState)
  end

  sleep(POLL_INTERVAL)
end