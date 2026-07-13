-- power_grid_sources_controller.lua
-- Left side = internal building, right side = grid.
-- CLI controls the stored source states.
-- The battery controller can snapshot both states, turn them off, then restore them later.

local STATE_PATH = "power_grid_sources_state.json"

local PROTOCOL = "powerGrid.sources.v1"
local SERVER_NAME = "PowerGridSourcesController"

local PULSE_SECONDS = 0.5
local COOLDOWN_SECONDS = 2
local REQUEST_TIMEOUT = 3

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
local running = true
local snapshotState = nil
local snapshotToken = nil

local function openModems()
  for _, side in ipairs(rs.getSides()) do
    if peripheral.getType(side) == "modem" and not rednet.isOpen(side) then
      rednet.open(side)
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

local function setLeftState(enabled)
  if enabled then
    forceBothOff()
    sleep(COOLDOWN_SECONDS)
    pulse(LEFT_BREAKER_SIDE)
    state.leftState = true
    state.rightState = false
  else
    if state.leftState == true then
      pulse(LEFT_BREAKER_SIDE)
    end
    state.leftState = false
  end

  saveState(state)
  updateLamps()
end

local function setRightState(enabled)
  if enabled then
    forceBothOff()
    sleep(COOLDOWN_SECONDS)
    pulse(RIGHT_BREAKER_SIDE)
    state.leftState = false
    state.rightState = true
  else
    if state.rightState == true then
      pulse(RIGHT_BREAKER_SIDE)
    end
    state.rightState = false
  end

  saveState(state)
  updateLamps()
end

local function turnOnLeft()
  forceBothOff()
  sleep(COOLDOWN_SECONDS)
  pulse(LEFT_BREAKER_SIDE)
  state.leftState = true
  state.rightState = false
  saveState(state)
  updateLamps()
end

local function turnOnRight()
  forceBothOff()
  sleep(COOLDOWN_SECONDS)
  pulse(RIGHT_BREAKER_SIDE)
  state.leftState = false
  state.rightState = true
  saveState(state)
  updateLamps()
end

local function turnAllOff()
  forceBothOff()
  print("Both sources are off.")
  sleep(0.5)
end

local function drawStatus()
  term.clear()
  term.setCursorPos(1, 1)
  print("Create: Power Grid Sources Controller")
  print("Left = internal building, right = grid")
  print("")
  print("Left  (internal building): " .. (state.leftState and "ON" or "OFF"))
  print("Right (grid):             " .. (state.rightState and "ON" or "OFF"))
  print("")
  print("Snapshot: " .. (snapshotToken and "saved" or "none"))
  print("State file: " .. STATE_PATH)
end

local function snapshotSources(token)
  snapshotState = {
    leftState = state.leftState == true,
    rightState = state.rightState == true,
  }
  snapshotToken = token or tostring(os.epoch("utc"))
  forceBothOff()
  return snapshotToken
end

local function restoreSources(token)
  if snapshotToken == nil or (token and token ~= snapshotToken) then
    return false, "no_snapshot"
  end

  local snapshot = snapshotState or { leftState = false, rightState = false }
  snapshotState = nil
  snapshotToken = nil

  if snapshot.leftState == true and snapshot.rightState ~= true then
    turnOnLeft()
  elseif snapshot.rightState == true and snapshot.leftState ~= true then
    turnOnRight()
  else
    forceBothOff()
  end

  return true
end

local function handleRemoteMessage(sender, msg)
  if type(msg) ~= "table" then
    return false
  end

  if msg.type == "sources_status" then
    rednet.send(sender, {
      type = "sources_status_result",
      leftState = state.leftState == true,
      rightState = state.rightState == true,
      snapshot = snapshotToken ~= nil,
    }, PROTOCOL)
    return true
  end

  if msg.type == "sources_pause" then
    local token = snapshotSources(msg.token)
    rednet.send(sender, {
      type = "sources_paused",
      ok = true,
      token = token,
    }, PROTOCOL)
    return true
  end

  if msg.type == "sources_restore" then
    local ok, err = restoreSources(msg.token)
    if ok then
      rednet.send(sender, {
        type = "sources_restored",
        ok = true,
        token = msg.token,
      }, PROTOCOL)
    else
      rednet.send(sender, {
        type = "sources_restored",
        ok = false,
        reason = err or "restore_failed",
      }, PROTOCOL)
    end
    return true
  end

  if msg.type == "sources_left_on" then
    setLeftState(true)
    rednet.send(sender, { type = "sources_result", ok = true, leftState = true, rightState = false }, PROTOCOL)
    return true
  end

  if msg.type == "sources_right_on" then
    setRightState(true)
    rednet.send(sender, { type = "sources_result", ok = true, leftState = false, rightState = true }, PROTOCOL)
    return true
  end

  if msg.type == "sources_left_toggle" then
    setLeftState(not (state.leftState == true))
    rednet.send(sender, { type = "sources_result", ok = true, leftState = state.leftState == true, rightState = state.rightState == true }, PROTOCOL)
    return true
  end

  if msg.type == "sources_right_toggle" then
    setRightState(not (state.rightState == true))
    rednet.send(sender, { type = "sources_result", ok = true, leftState = state.leftState == true, rightState = state.rightState == true }, PROTOCOL)
    return true
  end

  if msg.type == "sources_all_off" then
    forceBothOff()
    rednet.send(sender, { type = "sources_result", ok = true, leftState = false, rightState = false }, PROTOCOL)
    return true
  end

  return false
end

local function networkLoop()
  openModems()
  rednet.host(PROTOCOL, SERVER_NAME)

  while running do
    local event = { os.pullEvent() }

    if event[1] == "rednet_message" then
      local sender, msg, proto = event[2], event[3], event[4]
      if proto == PROTOCOL then
        handleRemoteMessage(sender, msg)
      end
    end
  end
end

local function uiLoop()
  while running do
    drawStatus()
    print("")
    print("1) Toggle internal building")
    print("2) Toggle grid")
    print("3) Turn all off")
    print("4) Turn internal building on")
    print("5) Turn grid on")
    print("6) Refresh display")
    print("Q) Quit")
    write("Choose: ")

    local choice = string.lower((read() or "")):gsub("^%s+", ""):gsub("%s+$", "")

    if choice == "1" or choice == "" then
      setLeftState(not (state.leftState == true))
    elseif choice == "2" then
      setRightState(not (state.rightState == true))
    elseif choice == "3" then
      turnAllOff()
    elseif choice == "4" then
      turnOnLeft()
    elseif choice == "5" then
      turnOnRight()
    elseif choice == "6" then
      -- just redraw below
    elseif choice == "q" then
      running = false
      break
    end
  end
end

updateLamps()

parallel.waitForAny(uiLoop, networkLoop)

rednet.unhost(PROTOCOL)
term.clear()
term.setCursorPos(1, 1)
print("Sources controller stopped.")