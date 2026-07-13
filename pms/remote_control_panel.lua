---@diagnostic disable: undefined-global, undefined-field
local common = {}

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

local function loadRoot(configPath)
  local parsed = jsonDecode(readAll(configPath))
  return type(parsed) == "table" and parsed or {}
end

local function saveRoot(configPath, root)
  writeAll(configPath, jsonEncode(root))
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

local function startupPrompt(title, section, defaults, fields, configPath)
  local root = loadRoot(configPath)
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
        print(("%d) %s = %s"):format(index, field.label, fieldValue(cfg, field)))
      end
      print("")
      print("S) Save and start")
      print("Q) Start without saving")
      write("Choice: ")
      local choice = tostring(read() or ""):lower()

      if choice == "s" then
        root[section] = cfg
        saveRoot(configPath, root)
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
  saveRoot(configPath, root)
  return cfg
end

local function openModems()
  for _, side in ipairs(rs.getSides()) do
    if peripheral.getType(side) == "modem" then
      rednet.open(side)
    end
  end
end

local function findServer(protocol, serverName)
  return rednet.lookup(protocol, serverName)
end

local function trim(value)
  value = tostring(value or "")
  return value:gsub("^%s+", ""):gsub("%s+$", "")
end

common.readAll = readAll
common.writeAll = writeAll
common.jsonEncode = jsonEncode
common.jsonDecode = jsonDecode
common.deepCopy = deepCopy
common.mergeDefaults = mergeDefaults
common.loadRoot = loadRoot
common.saveRoot = saveRoot
common.normalizeValue = normalizeValue
common.fieldValue = fieldValue
common.startupPrompt = startupPrompt
common.openModems = openModems
common.findServer = findServer
common.trim = trim

local CONFIG_PATH = "pms/pms_config.json"

local panelDefaults = {
  auth_protocol = "doorAuth.v1",
  auth_server_name = "DoorAuthServer",
  auth_tag = "power_grid_panel",
  grid_protocol = "powerGrid.v1",
  grid_server_name = "PowerGridServer",
  request_timeout = 5,
}

local panelFields = {
  { key = "auth_protocol", label = "Auth Protocol" },
  { key = "auth_server_name", label = "Auth Server Name" },
  { key = "auth_tag", label = "Auth Door Tag" },
  { key = "grid_protocol", label = "Grid Protocol" },
  { key = "grid_server_name", label = "Grid Server Name" },
  { key = "request_timeout", label = "Request Timeout" },
}

local config = common.startupPrompt("Power Grid Remote Panel Setup", "remote_control_panel", panelDefaults, panelFields, CONFIG_PATH)

local AUTH_PROTOCOL = config.auth_protocol
local AUTH_SERVER_NAME = config.auth_server_name
local AUTH_TAG = common.trim(config.auth_tag)
local GRID_PROTOCOL = config.grid_protocol
local GRID_SERVER_NAME = config.grid_server_name
local REQUEST_TIMEOUT = tonumber(config.request_timeout) or 5

local function drawHeader(title, subtitle)
  term.clear()
  term.setCursorPos(1, 1)
  term.setTextColor(colors.cyan)
  print(title)
  term.setTextColor(colors.white)
  if subtitle and subtitle ~= "" then
    print(subtitle)
  end
  print(string.rep("-", 42))
end

local function pause(message)
  if message and message ~= "" then
    print(message)
  end
  print("Press Enter to continue.")
  read()
end

local function loginWithDoorAuth(pin)
  local server = common.findServer(AUTH_PROTOCOL, AUTH_SERVER_NAME)
  if not server then
    return false, "DoorAuth server not found."
  end

  rednet.send(server, {
    type = "verify",
    tag = AUTH_TAG,
    code = pin,
  }, AUTH_PROTOCOL)

  local sender, message = rednet.receive(AUTH_PROTOCOL, REQUEST_TIMEOUT)
  if sender == server and type(message) == "table" and message.type == "verify_result" and message.ok then
    return true, nil
  end

  return false, (type(message) == "table" and message.reason) or "Access denied."
end

local function login()
  drawHeader("[Power Grid Panel] Login", "Enter the DoorAuth code for the control panel door")
  write("Code: ")
  local pin = read("*")
  local ok, reason = loginWithDoorAuth(tostring(pin or ""))
  if ok then
    return true
  end

  pause(reason or "Login failed.")
  return false
end

local function findGridServer()
  return common.findServer(GRID_PROTOCOL, GRID_SERVER_NAME)
end

local function fetchStatus()
  local server = findGridServer()
  if not server then
    return nil, "Power grid server offline."
  end

  rednet.send(server, { type = "status" }, GRID_PROTOCOL)
  local sender, message = rednet.receive(GRID_PROTOCOL, REQUEST_TIMEOUT)
  if sender ~= server or type(message) ~= "table" or message.type ~= "status_result" then
    return nil, "No status response."
  end

  return message.status, nil
end

local function setBreaker(breakerId, desiredState)
  local server = findGridServer()
  if not server then
    return nil, "Power grid server offline."
  end

  rednet.send(server, {
    type = "setBreaker",
    breaker_id = breakerId,
    state = desiredState == true,
  }, GRID_PROTOCOL)

  local sender, message = rednet.receive(GRID_PROTOCOL, REQUEST_TIMEOUT)
  if sender ~= server or type(message) ~= "table" or message.type ~= "set_result" then
    return nil, "No response from grid server."
  end

  return message, nil
end

local function breakerLabel(breaker)
  local label = breaker.label or breaker.id or "?"
  local state = breaker.state and "ON" or "OFF"
  local kind = breaker.kind or "?"
  local controller = breaker.controller and "online" or "offline"
  return ("%s | %s | %s | controller:%s"):format(label, kind, state, controller)
end

local function findBreaker(status, kind)
  if not status or type(status.breakers) ~= "table" then return nil end
  for _, breaker in ipairs(status.breakers) do
    if breaker.kind == kind then
      return breaker
    end
  end
  return nil
end

local function findBreakerById(status, breakerId)
  if not status or type(status.breakers) ~= "table" then return nil end
  for _, breaker in ipairs(status.breakers) do
    if breaker.id == breakerId then
      return breaker
    end
  end
  return nil
end

local function breakerActionLabel(breaker, action)
  if not breaker then return "Unavailable" end
  return ("%s -> %s"):format(breaker.label or breaker.id or "?", action)
end

local function showPanel(status)
  drawHeader("[Power Grid Panel] Status", "Registered under DoorAuth tag: " .. AUTH_TAG)

  if not status then
    print("No status available.")
    print("R) refresh")
    print("Q) quit")
    return
  end

  print("Active source: " .. tostring(status.active_source or "none"))
  print("Sources available: " .. tostring(status.sources_on and "yes" or "no"))
  print("")

  local battery = findBreaker(status, "battery")
  local generators = findBreaker(status, "generator")
  local internal = findBreakerById(status, "internal_building")
  local residential = findBreakerById(status, "residential_grid")

  print("1) " .. breakerActionLabel(battery, battery and battery.state and "turn off" or "turn on"))
  print("2) " .. breakerActionLabel(generators, generators and generators.state and "turn off" or "turn on"))
  print("3) " .. breakerActionLabel(internal, "turn on"))
  print("4) " .. breakerActionLabel(internal, "turn off"))
  print("5) " .. breakerActionLabel(residential, "turn on"))
  print("6) " .. breakerActionLabel(residential, "turn off"))
  print("")
  print("R) refresh")
  print("Q) quit")
end

local function menuLoop()
  while true do
    local status, statusErr = fetchStatus()
    showPanel(status)
    if statusErr then
      print(statusErr)
    end

    write("Choice: ")
    local choice = string.lower(tostring(read() or ""))
    if choice == "q" or choice == "" then
      break
    elseif choice == "r" then
      -- refresh by looping
    else
      local actionMap = {
        ["1"] = { id = "battery", state = nil, title = "Battery" },
        ["2"] = { id = "generators", state = nil, title = "Generators" },
        ["3"] = { kind = "load", id = "internal_building", state = true, title = "Internal Building" },
        ["4"] = { kind = "load", id = "internal_building", state = false, title = "Internal Building" },
        ["5"] = { kind = "load", id = "residential_grid", state = true, title = "Residential Grid" },
        ["6"] = { kind = "load", id = "residential_grid", state = false, title = "Residential Grid" },
      }

      local action = actionMap[choice]
      if action and status then
        local breaker = action.id and findBreakerById(status, action.id) or nil

        if breaker then
          local result, err = setBreaker(breaker.id, action.state == nil and not breaker.state or action.state)
          if not result then
            drawHeader("[Power Grid Panel] Action", breaker.label or breaker.id or "Unknown")
            pause(err or "Action failed.")
          else
            drawHeader("[Power Grid Panel] Action", breaker.label or breaker.id or "Updated")
            print(result.ok and "Updated." or (result.reason or "Action failed."))
            print("Active source: " .. tostring(result.status and result.status.active_source or "none"))
            pause()
          end
        end
      end
    end
  end
end

common.openModems()

if login() then
  menuLoop()
end