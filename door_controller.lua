-- door_controller.lua
-- Listens for OPEN messages for its tag and pulses redstone.

------------- Config -------------
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
  open_event = "doorAuth.open.v1",
  server_name = "DoorAuthServer",
  door_tag = "lobby",
  redstone_side = "right",
  pulse_default = 3,
  register_timeout = 3,
  heartbeat_timeout = 30,
}

local configFields = {
  { key = "protocol", label = "Protocol" },
  { key = "open_event", label = "Open Event" },
  { key = "server_name", label = "Server Name" },
  { key = "door_tag", label = "Door Tag" },
  { key = "redstone_side", label = "Redstone Side" },
  { key = "pulse_default", label = "Pulse Default" },
  { key = "register_timeout", label = "Register Timeout" },
  { key = "heartbeat_timeout", label = "Heartbeat Timeout" },
}

local config = startupPrompt("DoorAuth Controller Setup", "door_controller", defaultConfig, configFields)

local PROTOCOL     = config.protocol
local OPEN_EVENT   = config.open_event
local SERVER_NAME  = config.server_name
local DOOR_TAG     = config.door_tag
local REDSTONE_SIDE= config.redstone_side
local PULSE_DEFAULT= tonumber(config.pulse_default) or 3
local REGISTER_TIMEOUT = tonumber(config.register_timeout) or 3
local HEARTBEAT_TIMEOUT = tonumber(config.heartbeat_timeout) or 30
---------------------------------

local function openModems()
  for _, side in ipairs(rs.getSides()) do
    if peripheral.getType(side) == "modem" then rednet.open(side) end
  end
end

local function findServer()
  return rednet.lookup(PROTOCOL, SERVER_NAME)
end

local function pulseDoor(seconds)
  seconds = tonumber(seconds) or PULSE_DEFAULT
  redstone.setOutput(REDSTONE_SIDE, true)
  sleep(seconds)
  redstone.setOutput(REDSTONE_SIDE, false)
end

local function registerLoop(expectedTag)
  while true do
    local server = findServer()
    if server then
      print("[DoorCtrl] Server #" .. server .. " found. Registering...")
      print("[DoorCtrl] Registering with tag '"..expectedTag.."'")
      rednet.send(server, {type="registerController", tag=expectedTag}, PROTOCOL)

      local timer = os.startTimer(REGISTER_TIMEOUT)
      while true do
        local e = { os.pullEvent() }
        if e[1] == "rednet_message" then
          local id, msg, proto = e[2], e[3], e[4]
          if id == server and proto == PROTOCOL and type(msg)=="table" then
            if msg.type == "register_ack" and msg.tag == expectedTag then
              print("[DoorCtrl] Registered for tag '"..expectedTag.."'")
              return server
            elseif msg.type == "error" then
              print("[DoorCtrl] Registration error: "..tostring(msg.reason))
              sleep(2) ; break
            end
          end
        elseif e[1] == "timer" and e[2] == timer then
          print("[DoorCtrl] No ack, retrying...")
          break
        end
      end
    else
      print("[DoorCtrl] Waiting for server...")
      sleep(2)
    end
  end
end

local function main()
  print(("[DoorCtrl] Tag='%s', side='%s'"):format(DOOR_TAG, REDSTONE_SIDE))
  openModems()

  -- Register initially
  local server = registerLoop(DOOR_TAG)
  local lastHeartbeat = os.epoch("utc")

  while true do
    local id, msg, proto = rednet.receive(OPEN_EVENT, 5)

    if id then
      -- If server ID changed, re-register immediately
      if id ~= server then
        print("[DoorCtrl] Different server detected! Re-registering...")
        server = registerLoop(DOOR_TAG)
      end

      if type(msg) == "table" and msg.type == "open" and msg.tag == DOOR_TAG then
        lastHeartbeat = os.epoch("utc")
        print(("[DoorCtrl] OPEN for '%s' (%ss)"):format(DOOR_TAG, msg.duration or PULSE_DEFAULT))
        pulseDoor(msg.duration)
      end

    else
      -- No messages received for 5 seconds
      -- Check if server heartbeat expired
      if os.epoch("utc") - lastHeartbeat > HEARTBEAT_TIMEOUT * 1000 then
        print(("[DoorCtrl] Server silent for %ds, attempting re-register..."):format(HEARTBEAT_TIMEOUT))
        server = registerLoop(DOOR_TAG)
        lastHeartbeat = os.epoch("utc")
      end
    end
  end
end


main()
