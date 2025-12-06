-- keypad.lua (no door label on monitor)

local PROTOCOL = "doorAuth.v1"
local DOOR_TAG = "lobby"   -- <--- set this to your door tag

-- ---------- Modem ----------
local function openModems()
  for _, side in ipairs(rs.getSides()) do
    if peripheral.getType(side) == "modem" then rednet.open(side) end
  end
end

local function findServer()
  return rednet.lookup(PROTOCOL, "DoorAuthServer")
end

-- ---------- Terminal UI ----------
local function terminalPIN()
  term.clear()
  term.setCursorPos(1,1)
  write("Enter PIN: ")
  local pin = read("*") -- masked
  return pin
end

-- ---------- Autoscale + Layout ----------
local function tryScales(mon, scales)
  for _, s in ipairs(scales) do
    mon.setTextScale(s)
    local w,h = mon.getSize()
    if w >= 10 and h >= 9 then return s,w,h end
  end
  return nil, mon.getSize()
end

local function decideLayout(w,h)
  return { compact = (w < 24 or h < 12) }
end

-- ---------- Drawing ----------
local function drawKeypad(mon, layout)
  mon.setBackgroundColor(colors.black)
  mon.setTextColor(colors.white)
  mon.clear()

  local pinY = layout.compact and 1 or 2
  mon.setCursorPos(2, pinY); mon.write("PIN:")

  local keys = {
    {"1","2","3"},
    {"4","5","6"},
    {"7","8","9"},
    {"CLR","0","OK"},
  }

  local startX, startY, bw, bh, gap
  if layout.compact then
    bw, bh, gap = 3, 1, 1
    startX = 2
    startY = pinY + 2
  else
    bw, bh, gap = 6, 3, 1
    startX = 3
    startY = pinY + 2
  end

  for r=1,4 do
    for c=1,3 do
      local x = startX + (c-1)*(bw+gap)
      local y = startY + (r-1)*(bh+gap)
      for yy=y, y+bh-1 do
        mon.setCursorPos(x, yy)
        mon.write(string.rep(" ", bw))
      end
      local label = keys[r][c]
      mon.setCursorPos(x + math.floor((bw-#label)/2), y + math.floor(bh/2))
      mon.write(label)
    end
  end

  return { keys=keys, startX=startX, startY=startY, bw=bw, bh=bh, gap=gap, pinY=pinY }
end

-- ---------- Keypad Loop ----------
local function keypadLoop(mon)
  tryScales(mon, {0.5, 0.75, 1})
  local w,h = mon.getSize()
  local layout = decideLayout(w,h)
  local geo = drawKeypad(mon, layout)

  local pin = ""
  local function refreshPIN()
    local x = 6
    mon.setCursorPos(x, geo.pinY)
    mon.write(string.rep(" ", (layout.compact and 10 or 20)))
    mon.setCursorPos(x, geo.pinY)
    mon.write(string.rep("*", #pin))
  end
  refreshPIN()

  while true do
    local event, p1, p2, p3 = os.pullEvent()

    if event == "monitor_touch" then
      local touchedSide, x, y = p1, p2, p3
      if peripheral.getName(mon) == touchedSide then
        for r=1,4 do
          for c=1,3 do
            local bx = geo.startX + (c-1)*(geo.bw+geo.gap)
            local by = geo.startY + (r-1)*(geo.bh+geo.gap)
            if x >= bx and x < bx+geo.bw and y >= by and y < by+geo.bh then
              local label = geo.keys[r][c]
              if label == "OK" then return pin
              elseif label == "CLR" then pin = ""; refreshPIN()
              else
                if #pin < 12 then pin = pin .. label; refreshPIN() end
              end
            end
          end
        end
      end

    elseif event == "char" then
      local ch = p1
      if ch:match("%d") and #pin < 12 then pin = pin .. ch; refreshPIN() end

    elseif event == "key" then
      local keyCode = p1
      if keyCode == keys.backspace then pin = pin:sub(1, #pin-1); refreshPIN()
      elseif keyCode == keys.enter then return pin end
    end
  end
end

-- ---------- Verify ----------
local function trim(s) return tostring(s or ""):gsub("^%s+",""):gsub("%s+$","") end

local function verifyWithServer(serverID, tag, pin)
  rednet.send(serverID, {type="verify", tag=tag, pin=pin}, PROTOCOL)
  local timer = os.startTimer(3)
  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "rednet_message" then
      local id, msg, proto = ev[2], ev[3], ev[4]
      if id==serverID and proto==PROTOCOL and type(msg)=="table"
         and msg.type=="verify_result" and msg.tag==tag then
        return msg.ok
      end
    elseif ev[1] == "timer" and ev[2] == timer then
      return false,"timeout"
    end
  end
end

-- ---------- Main ----------
local function main()
  openModems()
  local mon = peripheral.find("monitor")

  local server = findServer()
  if not server then
    print("Finding server...")
    while not server do sleep(2); server = findServer() end
  end
  print("[Keypad] Server #" .. server .. " | Door '"..DOOR_TAG.."'")

  while true do
    local pin = mon and keypadLoop(mon) or terminalPIN()
    pin = trim(pin)

    if pin == "" then
      if mon then drawKeypad(mon, decideLayout(mon.getSize())) else print("No PIN entered.") end
    else
      local ok = verifyWithServer(server, DOOR_TAG, pin)
      if mon then
        local msg = ok and "GRANTED" or "DENIED"
        mon.setCursorPos(2, (decideLayout(mon.getSize())).compact and 1 or 1)
        mon.write("Access: "..msg.."        ")
        sleep(ok and 0.8 or 1.2)
        drawKeypad(mon, decideLayout(mon.getSize()))
      else
        print(ok and "Access GRANTED" or "Access DENIED")
      end
    end
  end
end

main()
