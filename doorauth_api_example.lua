-- doorauth_api_example.lua
-- Example DoorAuth API wrapper for other CC:Tweaked programs.
-- Load with os.loadAPI("doorauth_api_example") or copy the functions you need.

local DoorAuthAPI = {}

DoorAuthAPI.config = {
  protocol = "doorAuth.v1",
  server_name = "DoorAuthServer",
  request_timeout = 3,
}

local function trim(value)
  value = tostring(value or "")
  return value:gsub("^%s+", ""):gsub("%s+$", "")
end

local function hash(value)
  local result = 0
  value = tostring(value or "")
  for i = 1, #value do
    result = (result * 31 + value:byte(i)) % 2 ^ 31
  end
  return tostring(result)
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

local function findServer(config)
  return rednet.lookup(config.protocol, config.server_name)
end

local function request(config, payload)
  openModems()
  local server = findServer(config)
  if not server then
    return nil, "Server offline."
  end

  rednet.send(server, payload, config.protocol)
  local id, message = rednet.receive(config.protocol, config.request_timeout)
  if id ~= server or type(message) ~= "table" then
    return nil, "No response."
  end

  return message, nil
end

function DoorAuthAPI.login(adminPin, config)
  config = config or DoorAuthAPI.config
  openModems()

  local server = findServer(config)
  if not server then
    return nil, "Server offline."
  end

  local stamp = tostring(os.epoch("utc"))
  local sig = hash(hash(adminPin) .. stamp)

  rednet.send(server, {
    type = "admin_login",
    timestamp = stamp,
    sig = sig,
  }, config.protocol)

  local id, message = rednet.receive(config.protocol, config.request_timeout)
  if id == server and type(message) == "table" and message.type == "admin_login_ok" then
    return {
      token = message.token,
      pin = adminPin,
      protocol = config.protocol,
      serverName = config.server_name,
      server = server,
      loginAt = os.epoch("utc"),
    }, nil
  end

  return nil, "Login failed."
end

function DoorAuthAPI.call(session, command, payload, config)
  config = config or DoorAuthAPI.config
  payload = payload or {}

  if not session or not session.token then
    return nil, "Missing session."
  end

  payload.type = "admin_cmd"
  payload.token = session.token
  payload.cmd = command

  local message, err = request(config, payload)
  if not message then
    return nil, err
  end

  if message.type == "admin_denied" and session.pin then
    local renewed, renewErr = DoorAuthAPI.login(session.pin, config)
    if not renewed then
      return nil, renewErr or "Session expired."
    end

    session.token = renewed.token
    session.loginAt = renewed.loginAt
    payload.token = session.token
    message, err = request(config, payload)
    if not message then
      return nil, err
    end
  end

  return message, nil
end

function DoorAuthAPI.listUsers(session, config)
  local message, err = DoorAuthAPI.call(session, "user_list", {}, config)
  if not message then return nil, err end
  return message.users or {}, nil
end

function DoorAuthAPI.searchUsers(session, query, config)
  local message, err = DoorAuthAPI.call(session, "user_search", { query = query }, config)
  if not message then return nil, err end
  return message.users or {}, nil
end

function DoorAuthAPI.showUser(session, name, config)
  local message, err = DoorAuthAPI.call(session, "user_show", { name = name }, config)
  if not message then return nil, err end
  return message.user, message.doors, nil
end

function DoorAuthAPI.addUser(session, name, code, config)
  local message, err = DoorAuthAPI.call(session, "user_add", { name = name, code = code }, config)
  if not message then return false, err end
  return message.ok == true, nil
end

function DoorAuthAPI.clearUserCode(session, name, config)
  local message, err = DoorAuthAPI.call(session, "user_clear_code", { name = name }, config)
  if not message then return false, err end
  return message.ok == true, nil
end

function DoorAuthAPI.clearUserDoors(session, name, config)
  local message, err = DoorAuthAPI.call(session, "user_clear_doors", { name = name }, config)
  if not message then return false, err end
  return message.ok == true, nil
end

function DoorAuthAPI.cloneUserAccess(session, sourceName, targetName, includeCode, config)
  local message, err = DoorAuthAPI.call(session, "user_clone", {
    source = sourceName,
    name = targetName,
    includeCode = includeCode and true or false,
  }, config)
  if not message then return false, err end
  return message.ok == true, nil
end

function DoorAuthAPI.enableDoorForUser(session, name, tag, config)
  local message, err = DoorAuthAPI.call(session, "user_enable", { name = name, tag = tag }, config)
  if not message then return false, err end
  return message.ok == true, nil
end

function DoorAuthAPI.disableDoorForUser(session, name, tag, config)
  local message, err = DoorAuthAPI.call(session, "user_disable", { name = name, tag = tag }, config)
  if not message then return false, err end
  return message.ok == true, nil
end

function DoorAuthAPI.issueCard(session, name, config)
  local message, err = DoorAuthAPI.call(session, "user_card_issue", { name = name }, config)
  if not message then return nil, err end
  return message.token, nil
end

function DoorAuthAPI.clearCard(session, name, config)
  local message, err = DoorAuthAPI.call(session, "user_card_clear", { name = name }, config)
  if not message then return false, err end
  return message.ok == true, nil
end

function DoorAuthAPI.listDoors(session, config)
  local message, err = DoorAuthAPI.call(session, "list", {}, config)
  if not message then return nil, err end
  return message.doors or {}, nil
end

function DoorAuthAPI.showDoor(session, tag, config)
  local message, err = DoorAuthAPI.call(session, "show", { tag = tag }, config)
  if not message then return nil, err end
  return message.door, nil
end

function DoorAuthAPI.addPin(session, tag, pin, config)
  local message, err = DoorAuthAPI.call(session, "add", { tag = tag, pin = pin }, config)
  if not message then return false, err end
  return message.ok == true, nil
end

function DoorAuthAPI.removePin(session, tag, pin, config)
  local message, err = DoorAuthAPI.call(session, "del", { tag = tag, pin = pin }, config)
  if not message then return false, err end
  return message.ok == true, nil
end

function DoorAuthAPI.setDoorOpenTime(session, tag, seconds, config)
  local message, err = DoorAuthAPI.call(session, "opentime", { tag = tag, seconds = seconds }, config)
  if not message then return false, err end
  return message.ok == true, nil
end

function DoorAuthAPI.remoteOpen(session, tag, config)
  local message, err = DoorAuthAPI.call(session, "open", { tag = tag }, config)
  if not message then return false, err end
  return message.ok == true, nil
end

function DoorAuthAPI.lockdown(session, enabled, config)
  local command = enabled and "lockdown_on" or "lockdown_off"
  local message, err = DoorAuthAPI.call(session, command, {}, config)
  if not message then return false, err end
  return message.ok == true, nil
end

function DoorAuthAPI.saveConfig(config)
  config = config or DoorAuthAPI.config
  return config
end

_G.doorauth_api_example = DoorAuthAPI

local function runExample()
  print("DoorAuth API example loaded.")
  print("Load it with os.loadAPI(\"doorauth_api_example\") and call the functions below.")
  print("")
  print("Example:")
  print("  os.loadAPI(\"doorauth_api_example\")")
  print("  local session, err = doorauth_api_example.login(\"1234\")")
  print("  if session then")
  print("    local users = doorauth_api_example.listUsers(session)")
  print("  end")
  print("")
  print("Available helpers:")
  print("  login, call, listUsers, searchUsers, showUser")
  print("  addUser, clearUserCode, clearUserDoors, cloneUserAccess")
  print("  enableDoorForUser, disableDoorForUser, issueCard, clearCard")
  print("  listDoors, showDoor, addPin, removePin, setDoorOpenTime")
  print("  remoteOpen, lockdown")
end

local runningProgram = shell and shell.getRunningProgram and shell.getRunningProgram() or nil
if runningProgram and runningProgram:match("doorauth_api_example%.lua$") then
  runExample()
end
