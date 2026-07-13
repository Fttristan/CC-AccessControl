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

local controllerDefaults = {
  protocol = "powerGrid.v1",
  server_name = "PowerGridServer",
  breaker_id = "battery",
  breaker_label = "Battery",
  breaker_kind = "battery",
  redstone_side = "right",
  active_high = true,
  retry_delay = 3,
  receive_timeout = 5,
}

local controllerFields = {
  { key = "protocol", label = "Protocol" },
  { key = "server_name", label = "Server Name" },
  { key = "breaker_id", label = "Breaker Id" },
  { key = "breaker_label", label = "Breaker Label" },
  { key = "breaker_kind", label = "Breaker Kind" },
  { key = "redstone_side", label = "Redstone Side" },
  { key = "active_high", label = "Active High" },
  { key = "retry_delay", label = "Retry Delay" },
  { key = "receive_timeout", label = "Receive Timeout" },
}

local config = common.startupPrompt("Power Grid Breaker Controller Setup", "breaker_controller", controllerDefaults, controllerFields, CONFIG_PATH)

local PROTOCOL = config.protocol
local SERVER_NAME = config.server_name
local BREAKER_ID = common.trim(config.breaker_id)
local BREAKER_LABEL = config.breaker_label
local BREAKER_KIND = common.trim(config.breaker_kind)
local REDSTONE_SIDE = config.redstone_side
local ACTIVE_HIGH = config.active_high ~= false
local RETRY_DELAY = tonumber(config.retry_delay) or 3
local RECEIVE_TIMEOUT = tonumber(config.receive_timeout) or 5

local desiredState = false

local function applyState(state)
  desiredState = state == true
  local output = desiredState
  if not ACTIVE_HIGH then
    output = not output
  end
  redstone.setOutput(REDSTONE_SIDE, output)
end

local function registerWithServer()
  while true do
    local server = common.findServer(PROTOCOL, SERVER_NAME)
    if server then
      rednet.send(server, {
        type = "registerBreaker",
        breaker_id = BREAKER_ID,
        label = BREAKER_LABEL,
        kind = BREAKER_KIND,
      }, PROTOCOL)

      local timer = os.startTimer(RECEIVE_TIMEOUT)
      while true do
        local event, id, message, protocol = os.pullEvent()
        if event == "rednet_message" and id == server and protocol == PROTOCOL and type(message) == "table" then
          if message.type == "register_ack" and message.ok then
            if type(message.breaker) == "table" and message.breaker.state ~= nil then
              applyState(message.breaker.state)
            else
              applyState(false)
            end
            print(("[BreakerCtrl] Registered %s (%s)"):format(BREAKER_ID, BREAKER_KIND))
            return server
          elseif message.type == "register_ack" and not message.ok then
            print("[BreakerCtrl] Registration denied: " .. tostring(message.reason or "unknown"))
            sleep(RETRY_DELAY)
            break
          end
        elseif event == "timer" and id == timer then
          print("[BreakerCtrl] No response, retrying...")
          break
        end
      end
    else
      print("[BreakerCtrl] Waiting for server...")
      sleep(RETRY_DELAY)
    end
  end
end

local function main()
  common.openModems()
  print(("[BreakerCtrl] %s -> %s on %s"):format(BREAKER_ID, BREAKER_KIND, REDSTONE_SIDE))
  local server = registerWithServer()

  while true do
    local sender, message, protocol = rednet.receive(PROTOCOL, RECEIVE_TIMEOUT)

    if sender and sender ~= server then
      server = registerWithServer()
    end

    if sender and protocol == PROTOCOL and type(message) == "table" then
      if message.type == "breaker_state" and message.breaker_id == BREAKER_ID then
        applyState(message.state == true)
      elseif message.type == "status_result" then
        if type(message.status) == "table" then
          server = sender
        end
      end
    end

    local lookup = common.findServer(PROTOCOL, SERVER_NAME)
    if not lookup then
      server = registerWithServer()
    end
  end
end

main()