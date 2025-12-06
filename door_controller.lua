-- door_controller.lua
-- Listens for OPEN messages for its tag and pulses redstone.

------------- Config -------------
local PROTOCOL     = "doorAuth.v1"
local OPEN_EVENT   = "doorAuth.open.v1"
local DOOR_TAG     = "lobby"   -- <--- set this to your door tag
local REDSTONE_SIDE= "right"   -- side to power (attach dust/door/pistons)
local PULSE_DEFAULT= 3         -- fallback if server doesn't specify
---------------------------------

local function openModems()
  for _, side in ipairs(rs.getSides()) do
    if peripheral.getType(side) == "modem" then rednet.open(side) end
  end
end

local function findServer()
  return rednet.lookup(PROTOCOL, "DoorAuthServer")
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

      local timer = os.startTimer(3)
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
      if os.epoch("utc") - lastHeartbeat > 30000 then
        print("[DoorCtrl] Server silent for 30s, attempting re-register...")
        server = registerLoop(DOOR_TAG)
        lastHeartbeat = os.epoch("utc")
      end
    end
  end
end


main()
