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
local STATE_PATH = "pms/power_grid_state.json"

local serverDefaults = {
  protocol = "powerGrid.v1",
  host_name = "PowerGridServer",
  save_interval = 15,
  default_battery_id = "battery",
  default_generators_id = "generators",
  default_internal_id = "internal_building",
  default_residential_id = "residential_grid",
}

local serverFields = {
  { key = "protocol", label = "Protocol" },
  { key = "host_name", label = "Host Name" },
  { key = "save_interval", label = "Save Interval" },
  { key = "default_battery_id", label = "Battery Breaker Id" },
  { key = "default_generators_id", label = "Generators Breaker Id" },
  { key = "default_internal_id", label = "Internal Load Id" },
  { key = "default_residential_id", label = "Residential Load Id" },
}

local serverConfig = common.startupPrompt("Power Grid Server Setup", "power_grid_server", serverDefaults, serverFields, CONFIG_PATH)

local PROTOCOL = serverConfig.protocol
local HOST_NAME = serverConfig.host_name
local SAVE_INTERVAL = tonumber(serverConfig.save_interval) or 15

local state = {
  breakers = {},
  logs = {},
}

local DEFAULT_BREAKERS = {
  [serverConfig.default_battery_id] = { label = "Battery", kind = "battery" },
  [serverConfig.default_generators_id] = { label = "Generators", kind = "generator" },
  [serverConfig.default_internal_id] = { label = "Internal Building", kind = "load" },
  [serverConfig.default_residential_id] = { label = "Residential Grid", kind = "load" },
}

local function timestamp()
  return tostring(os.epoch("utc"))
end

local function saveState()
  common.writeAll(STATE_PATH, common.jsonEncode(state))
end

local function loadState()
  local parsed = common.jsonDecode(common.readAll(STATE_PATH))
  if type(parsed) == "table" then
    state = parsed
  end
  state.breakers = type(state.breakers) == "table" and state.breakers or {}
  state.logs = type(state.logs) == "table" and state.logs or {}
end

local function appendLog(eventName, details)
  local entry = { time = timestamp(), event = eventName }
  if type(details) == "table" then
    for key, value in pairs(details) do
      entry[key] = value
    end
  end
  table.insert(state.logs, entry)
  while #state.logs > 200 do
    table.remove(state.logs, 1)
  end
end

local function ensureBreaker(breakerId, label, kind)
  local breaker = state.breakers[breakerId]
  if type(breaker) ~= "table" then
    breaker = {}
    state.breakers[breakerId] = breaker
  end
  breaker.id = breakerId
  breaker.label = label or breaker.label or breakerId
  breaker.kind = kind or breaker.kind or "load"
  breaker.state = breaker.state == true
  breaker.controller = breaker.controller
  breaker.last_seen = breaker.last_seen or timestamp()
  return breaker
end

local function initDefaultBreakers()
  for breakerId, descriptor in pairs(DEFAULT_BREAKERS) do
    ensureBreaker(breakerId, descriptor.label, descriptor.kind)
  end
end

local function sortedBreakerIds()
  local ids = {}
  for breakerId in pairs(state.breakers) do
    table.insert(ids, breakerId)
  end
  table.sort(ids)
  return ids
end

local function breakerList()
  local list = {}
  for _, breakerId in ipairs(sortedBreakerIds()) do
    local breaker = state.breakers[breakerId]
    table.insert(list, {
      id = breaker.id,
      label = breaker.label,
      kind = breaker.kind,
      state = breaker.state == true,
      controller = breaker.controller,
      last_seen = breaker.last_seen,
    })
  end
  return list
end

local function sourceState(kind)
  local list = {}
  for _, breakerId in ipairs(sortedBreakerIds()) do
    local breaker = state.breakers[breakerId]
    if breaker.kind == kind and breaker.state == true then
      table.insert(list, breaker)
    end
  end
  return list
end

local function anySourceOn()
  return #sourceState("battery") > 0 or #sourceState("generator") > 0
end

local function activeSourceLabel()
  local batteries = sourceState("battery")
  local generators = sourceState("generator")

  if #batteries > 0 and #generators > 0 then
    return "mixed"
  elseif #batteries > 0 then
    return "battery"
  elseif #generators > 0 then
    return "generators"
  end

  return "none"
end

local function notifyBreaker(breaker)
  if not breaker or not breaker.controller then return end
  rednet.send(breaker.controller, {
    type = "breaker_state",
    breaker_id = breaker.id,
    state = breaker.state == true,
    kind = breaker.kind,
    label = breaker.label,
  }, PROTOCOL)
end

local function notifyLoadsIfNeeded()
  if anySourceOn() then return end

  for _, breakerId in ipairs(sortedBreakerIds()) do
    local breaker = state.breakers[breakerId]
    if breaker.kind == "load" and breaker.state == true then
      breaker.state = false
      appendLog("auto_off", { breaker_id = breaker.id, label = breaker.label, reason = "no_source" })
      notifyBreaker(breaker)
    end
  end
end

local function canSetBreaker(breaker, desiredState)
  desiredState = desiredState == true

  if not breaker then
    return false, "Unknown breaker."
  end

  if breaker.state == desiredState then
    return true, "Already in that state."
  end

  if desiredState then
    if breaker.kind == "battery" and #sourceState("generator") > 0 then
      return false, "Generators must be off before turning on the battery."
    end
    if breaker.kind == "generator" and #sourceState("battery") > 0 then
      return false, "Battery must be off before turning on the generators."
    end
    if breaker.kind == "load" and not anySourceOn() then
      return false, "At least one power source must be on first."
    end
  end

  return true, "OK"
end

local function setBreakerState(breakerId, desiredState, source)
  local breaker = state.breakers[breakerId]
  if not breaker then
    return false, "Unknown breaker."
  end

  local ok, reason = canSetBreaker(breaker, desiredState)
  if not ok then
    return false, reason
  end

  breaker.state = desiredState == true
  breaker.last_seen = timestamp()
  appendLog("breaker_set", {
    breaker_id = breaker.id,
    label = breaker.label,
    state = breaker.state,
    source = source or "unknown",
  })
  notifyBreaker(breaker)
  if breaker.kind == "battery" or breaker.kind == "generator" then
    notifyLoadsIfNeeded()
  end
  saveState()
  return true, "OK"
end

local function toggleBreaker(breakerId, source)
  local breaker = state.breakers[breakerId]
  if not breaker then
    return false, "Unknown breaker."
  end
  return setBreakerState(breakerId, not breaker.state, source)
end

local function buildStatus()
  return {
    server = HOST_NAME,
    active_source = activeSourceLabel(),
    sources_on = anySourceOn(),
    breakers = breakerList(),
  }
end

local function handleMessage(sender, message, protocol)
  if protocol ~= PROTOCOL or type(message) ~= "table" then return end

  if message.type == "registerBreaker" then
    local breakerId = common.trim(message.breaker_id or message.id)
    if breakerId == "" then
      rednet.send(sender, { type = "register_ack", ok = false, reason = "Missing breaker id." }, PROTOCOL)
      return
    end

    local breaker = ensureBreaker(breakerId, message.label, message.kind)
    breaker.controller = sender
    breaker.last_seen = timestamp()
    appendLog("breaker_register", { breaker_id = breaker.id, label = breaker.label, kind = breaker.kind, controller = sender })
    saveState()

    rednet.send(sender, {
      type = "register_ack",
      ok = true,
      breaker = {
        id = breaker.id,
        label = breaker.label,
        kind = breaker.kind,
        state = breaker.state == true,
      },
    }, PROTOCOL)

    notifyBreaker(breaker)
    return
  end

  if message.type == "status" then
    rednet.send(sender, { type = "status_result", ok = true, status = buildStatus() }, PROTOCOL)
    return
  end

  if message.type == "setBreaker" then
    local breakerId = common.trim(message.breaker_id or message.id)
    local ok, reason = setBreakerState(breakerId, message.state == true, sender)
    rednet.send(sender, {
      type = "set_result",
      ok = ok,
      reason = reason,
      breaker_id = breakerId,
      status = buildStatus(),
    }, PROTOCOL)
    return
  end

  if message.type == "toggleBreaker" then
    local breakerId = common.trim(message.breaker_id or message.id)
    local ok, reason = toggleBreaker(breakerId, sender)
    rednet.send(sender, {
      type = "set_result",
      ok = ok,
      reason = reason,
      breaker_id = breakerId,
      status = buildStatus(),
    }, PROTOCOL)
    return
  end
end

local function netLoop()
  while true do
    local sender, message, protocol = rednet.receive()
    handleMessage(sender, message, protocol)
  end
end

local function autosaveLoop()
  while true do
    sleep(SAVE_INTERVAL)
    saveState()
  end
end

term.setTextColor(colors.cyan)
print("[PowerGrid] starting...")
term.setTextColor(colors.white)

common.openModems()
rednet.host(PROTOCOL, HOST_NAME)
loadState()
initDefaultBreakers()
saveState()
appendLog("server_start", { server = HOST_NAME })
saveState()

parallel.waitForAny(netLoop, autosaveLoop)