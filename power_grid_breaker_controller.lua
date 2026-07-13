-- power_grid_breaker_controller.lua
-- Left side = batteries, right side = generators.
-- Keyboard CLI controls the breaker states.
-- Left lamp is on bottom, right lamp is on top.

local STATE_PATH = "power_grid_breaker_state.json"

local SOURCES_PROTOCOL = "powerGrid.sources.v1"
local SOURCES_SERVER_NAME = "PowerGridSourcesController"
local INTERLOCK_TIMEOUT = 3

local PULSE_SECONDS = 0.5
local COOLDOWN_SECONDS = 2

local LEFT_BREAKER_SIDE = "left"
local RIGHT_BREAKER_SIDE = "right"
local LEFT_LAMP_SIDE = "bottom"
local RIGHT_LAMP_SIDE = "top"

local function readAll(path)
  if not fs.exists(path) then return nil end
  local handle = fs.open(path, "r")
  if not handle then return nil end
  local data = handle.readAll()
  handle.close()
  return data
end

local function writeAll(path, data)
  local handle = fs.open(path, "w")
  if not handle then return false end
  handle.write(data)
  handle.close()
  return true
end

local function openModems()
  for _, side in ipairs(rs.getSides()) do
    if peripheral.getType(side) == "modem" and not rednet.isOpen(side) then
      rednet.open(side)
    end
  end
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

local function loadState()
  local parsed = jsonDecode(readAll(STATE_PATH))
  if type(parsed) ~= "table" then
    return { leftState = false, rightState = false }
  end

  return {
    leftState = parsed.leftState == true,
    rightState = parsed.rightState == true,
  }
end

local function saveState(state)
  writeAll(STATE_PATH, jsonEncode({
    leftState = state.leftState == true,
    rightState = state.rightState == true,
  }))
end

local state = loadState()

local function pauseSourcesForBatterySwitch()
  openModems()

  local server = rednet.lookup(SOURCES_PROTOCOL, SOURCES_SERVER_NAME)
  if not server then
    return false, "sources controller offline"
  end

  local token = tostring(os.epoch("utc")) .. tostring(math.random(100000, 999999))
  rednet.send(server, { type = "sources_pause", token = token }, SOURCES_PROTOCOL)

  local timer = os.startTimer(INTERLOCK_TIMEOUT)
  while true do
    local event = { os.pullEvent() }
    if event[1] == "rednet_message" then
      local sender, msg, proto = event[2], event[3], event[4]
      if sender == server and proto == SOURCES_PROTOCOL and type(msg) == "table" then
        if msg.type == "sources_paused" and msg.token == token then
          return token
        end
      end
    elseif event[1] == "timer" and event[2] == timer then
      return false, "sources pause timeout"
    end
  end
end

local function restoreSources(token)
  if not token then
    return false, "missing restore token"
  end

  openModems()
  local server = rednet.lookup(SOURCES_PROTOCOL, SOURCES_SERVER_NAME)
  if not server then
    return false, "sources controller offline"
  end

  rednet.send(server, { type = "sources_restore", token = token }, SOURCES_PROTOCOL)
  local timer = os.startTimer(INTERLOCK_TIMEOUT)
  while true do
    local event = { os.pullEvent() }
    if event[1] == "rednet_message" then
      local sender, msg, proto = event[2], event[3], event[4]
      if sender == server and proto == SOURCES_PROTOCOL and type(msg) == "table" then
        if msg.type == "sources_restored" and msg.ok == true and msg.token == token then
          return true
        end
      end
    elseif event[1] == "timer" and event[2] == timer then
      return false, "sources restore timeout"
    end
  end
end

local function pulse(side)
  redstone.setOutput(side, true)
  sleep(PULSE_SECONDS)
  redstone.setOutput(side, false)
end

local function updateLamps()
  redstone.setOutput(LEFT_LAMP_SIDE, state.leftState == true)
  redstone.setOutput(RIGHT_LAMP_SIDE, state.rightState == true)
end

local function forceBothOff()
  local leftWasOn = state.leftState == true
  local rightWasOn = state.rightState == true

  if leftWasOn then
    pulse(LEFT_BREAKER_SIDE)
  end

  if rightWasOn then
    pulse(RIGHT_BREAKER_SIDE)
  end

  state.leftState = false
  state.rightState = false
  saveState(state)
  updateLamps()
end

local function turnOnLeft()
  local token, err = pauseSourcesForBatterySwitch()
  if not token then
    print("Cannot switch batteries: " .. tostring(err))
    sleep(1)
    return
  end

  forceBothOff()
  sleep(COOLDOWN_SECONDS)
  pulse(LEFT_BREAKER_SIDE)
  state.leftState = true
  state.rightState = false
  saveState(state)
  updateLamps()

  sleep(1)

  restoreSources(token)
end

local function turnOnRight()
  local token, err = pauseSourcesForBatterySwitch()
  if not token then
    print("Cannot switch batteries: " .. tostring(err))
    sleep(1)
    return
  end

  forceBothOff()
  sleep(COOLDOWN_SECONDS)
  pulse(RIGHT_BREAKER_SIDE)
  state.leftState = false
  state.rightState = true
  saveState(state)
  updateLamps()

  sleep(1)

  restoreSources(token)
end

local function turnAllOff()
  forceBothOff()
  print("Both breakers are off.")
  sleep(0.5)
end

local function toggle()
  if state.leftState == false and state.rightState == false then
    turnOnLeft()
    return
  end

  if state.leftState == true and state.rightState == false then
    turnOnRight()
    return
  end

  if state.rightState == true and state.leftState == false then
    turnOnLeft()
    return
  end

  turnOnLeft()
end

local function showMenu()
  term.clear()
  term.setCursorPos(1, 1)
  print("Breaker Controller Menu")
  print("Left = batteries, right = generators")
  print("")
  print("Left  (batteries):   " .. (state.leftState and "ON" or "OFF"))
  print("Right (generators):   " .. (state.rightState and "ON" or "OFF"))
  print("")
  print("1) Toggle Breakers")
  print("2) Turn all off")
  print("3) Turn Batteries on")
  print("4) Turn Generators on")
  print("5) Refresh display")
  print("Q) Quit")
  write("Choose: ")
end

local function drawStatus()
  term.clear()
  term.setCursorPos(1, 1)
  print("Create: Power Grid Breaker Controller")
  print("Keyboard CLI controls the breaker states.")
  print("")
  print("Left  (batteries):   " .. (state.leftState and "ON" or "OFF"))
  print("Right (generators):   " .. (state.rightState and "ON" or "OFF"))
  print("")
  print("Lamps: bottom = left, top = right")
  print("State file: " .. STATE_PATH)
end

updateLamps()
drawStatus()

while true do
  showMenu()
  local choice = string.lower((read() or "")):gsub("^%s+", ""):gsub("%s+$", "")

  if choice == "1" or choice == "" then
    toggle()
  elseif choice == "2" then
    turnAllOff()
  elseif choice == "3" then
    turnOnLeft()
  elseif choice == "4" then
    turnOnRight()
  elseif choice == "5" then
    -- just redraw below
  elseif choice == "q" then
    term.clear()
    term.setCursorPos(1, 1)
    print("Controller stopped.")
    break
  end

  drawStatus()
end
