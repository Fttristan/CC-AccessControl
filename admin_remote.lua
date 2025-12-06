-- admin_remote.lua (REMOTE OPEN + LOCKDOWN + LOG VIEW)

local PROTOCOL = "doorAuth.v1"
local SERVER_NAME = "DoorAuthServer"

---------------------------------------------------
-- UTILS
---------------------------------------------------
local function openModems()
  for _,side in ipairs(rs.getSides()) do
    if peripheral.getType(side)=="modem" then
      rednet.open(side)
    end
  end
end

local function findServer()
  return rednet.lookup(PROTOCOL, SERVER_NAME)
end

-- fallback hash (same as server)
local function hash(str)
  local h=0
  for i=1,#str do h=(h*31 + str:byte(i)) % 2^31 end
  return tostring(h)
end

local function setColor(col)
  if term.isColor and term.isColor() then
    term.setTextColor(col)
  end
end

---------------------------------------------------
-- LOGIN
---------------------------------------------------
local function login()
  term.clear()
  term.setCursorPos(1,1)
  print("=== DoorAuth Admin Remote ===")
  print("Enter Admin PIN:")
  local pin=read("*")

  local server=findServer()
  if not server then
    print("Server not found!")
    sleep(1) return nil
  end

  local stamp=tostring(os.epoch("utc"))
  local sig=hash(hash(pin) .. stamp)

  rednet.send(server,{
    type="admin_login",
    timestamp=stamp,
    sig=sig
  },PROTOCOL)

  local id,msg=rednet.receive(PROTOCOL,3)
  if id==server and msg and msg.type=="admin_login_ok" then
    sleep(0.4)
    term.clear()
    term.setCursorPos(1,1)
    return msg.token, pin
  end

  print("Login failed.")
  sleep(1)
  return nil
end

---------------------------------------------------
-- SEND ADMIN CMD
---------------------------------------------------
local function adminCmd(token,cmdTable)
  local server=findServer()
  if not server then
    print("Server offline.")
    sleep(1)
    return nil
  end

  cmdTable.type="admin_cmd"
  cmdTable.token=token

  rednet.send(server,cmdTable,PROTOCOL)
  local _,msg=rednet.receive(PROTOCOL,3)
  return msg
end

---------------------------------------------------
-- LOG VIEWER (Mode 3: interactive scroll)
---------------------------------------------------
local function viewLogs(token)
  local msg = adminCmd(token, {cmd="logs"})
  if not msg or msg.type ~= "admin_logs" or type(msg.logs) ~= "table" then
    term.clear()
    term.setCursorPos(1,1)
    print("No logs or error fetching logs.")
    sleep(1.2)
    return
  end

  local logs = msg.logs
  if #logs == 0 then
    term.clear()
    term.setCursorPos(1,1)
    print("No log entries yet.")
    sleep(1.2)
    return
  end

  local maxVisible = 8
  local pos = math.max(#logs - maxVisible + 1, 1) -- start near newest

  local function draw()
    term.clear()
    term.setCursorPos(1,1)
    print("=== Audit Logs ("..#logs.." entries) ===")
    print("W/S = scroll, Q = back")

    local last = math.min(pos + maxVisible - 1, #logs)
    for i = pos, last do
      local e = logs[i]
      local lineY = 3 + (i - pos) + 1
      term.setCursorPos(1, lineY)

      local label = string.format("%4d %s %-14s", i, e.time or "??:??", e.event or "?")

      local tail = ""
      if e.tag then tail = tail .. " tag="..tostring(e.tag) end
      if e.ok ~= nil then
        tail = tail .. " "..(e.ok and "OK" or "FAIL")
      end
      if e.detail then
        tail = tail .. " "..tostring(e.detail)
      end

      local color = colors.white
      if e.event == "pin_attempt" then
        color = e.ok and colors.lime or colors.red
      elseif e.event == "door_open" or e.event == "remote_open" then
        color = colors.cyan
      elseif e.event == "lockdown_on" or e.event == "lockdown_off" then
        color = colors.orange or colors.yellow
      elseif e.event == "admin_login" then
        color = e.ok and colors.lime or colors.red
      end

      setColor(color)
      write(label.." "..tail)
      setColor(colors.white)
    end

    local footerY = maxVisible + 5
    term.setCursorPos(1, footerY)
    print(string.format("Showing %d-%d of %d", pos, last, #logs))
  end

  while true do
    draw()
    term.setCursorPos(1, maxVisible + 7)
    write("Command (W/S/Q): ")
    local inp = read()
    inp = string.lower(inp or "")

    if inp == "w" then
      if pos > 1 then pos = pos - 1 end
    elseif inp == "s" then
      if pos < math.max(#logs - maxVisible + 1, 1) then
        pos = pos + 1
      end
    elseif inp == "q" or inp == "" then
      break
    end
  end

  term.clear()
  term.setCursorPos(1,1)
end

---------------------------------------------------
-- MAIN MENU
---------------------------------------------------
local function mainMenu(token)
  while true do
    term.clear()
    term.setCursorPos(1,1)
    print([[=== DoorAuth Admin ===

1) List Doors
2) Show Door
3) Add PIN
4) Delete PIN
5) Remove Door
6) Set OpenTime
7) Logout
8) Remote Open Door
9) LOCKDOWN ON
10) LOCKDOWN OFF
11) View Audit Logs
]])

    write("Choose: ")
    local c=read()

    if c=="1" then
      local msg=adminCmd(token,{cmd="list"})
      term.clear() term.setCursorPos(1,1)
      if msg and msg.doors then
        print("Doors:")
        for tag,data in pairs(msg.doors) do
          print(("%s (pins:%d, open:%s)"):format(tag,#data.pins,data.openTime))
        end
      else
        print("No response.")
      end
      print("\nPress Enter…") read()

    elseif c=="2" then
      write("Door tag: ") local tag=read()
      local msg=adminCmd(token,{cmd="show",tag=tag})
      term.clear() term.setCursorPos(1,1)
      if msg and msg.door then
        print("Door:",tag)
        print("OpenTime:",msg.door.openTime)
        print("Pins:")
        for _,p in ipairs(msg.door.pins) do print("  "..p) end
      else
        print("No such door.")
      end
      print("\nPress Enter…") read()

    elseif c=="3" then
      write("Door tag: ") local tag=read()
      write("New PIN: ") local pin=read()
      local msg=adminCmd(token,{cmd="add",tag=tag,pin=pin})
      term.clear() term.setCursorPos(1,1)
      print(msg and msg.ok and "Added." or "Already exists or error.")
      sleep(1)

    elseif c=="4" then
      write("Door tag: ") local tag=read()
      write("PIN to remove: ") local pin=read()
      local msg=adminCmd(token,{cmd="del",tag=tag,pin=pin})
      term.clear() term.setCursorPos(1,1)
      print(msg and msg.ok and "Removed." or "Not found or error.")
      sleep(1)

    elseif c=="5" then
      write("Door tag: ") local tag=read()
      local msg=adminCmd(token,{cmd="remove",tag=tag})
      term.clear() term.setCursorPos(1,1)
      print("Door removed.")
      sleep(1)

    elseif c=="6" then
      write("Door tag: ") local tag=read()
      write("Seconds: ") local sec=read()
      local msg=adminCmd(token,{cmd="opentime",tag=tag,seconds=sec})
      term.clear() term.setCursorPos(1,1)
      print("Updated.")
      sleep(1)

    elseif c=="8" then
      write("Door tag to open: ") local tag=read()
      local msg=adminCmd(token,{cmd="open",tag=tag})
      term.clear() term.setCursorPos(1,1)
      if msg and msg.ok then
        print("Door opened.")
      else
        print("Blocked (lockdown active or error).")
      end
      sleep(1)

    elseif c=="9" then
      local msg=adminCmd(token,{cmd="lockdown_on"})
      term.clear() term.setCursorPos(1,1)
      print("LOCKDOWN ENABLED")
      sleep(1)

    elseif c=="10" then
      local msg=adminCmd(token,{cmd="lockdown_off"})
      term.clear() term.setCursorPos(1,1)
      print("Lockdown disabled.")
      sleep(1)

    elseif c=="11" then
      viewLogs(token)

    elseif c=="7" then
      term.clear() term.setCursorPos(1,1)
      print("Logged out.")
      sleep(0.4)
      term.clear() term.setCursorPos(1,1)
      return
    end
  end
end

---------------------------------------------------
-- ENTRY
---------------------------------------------------
openModems()

while true do
  local token=login()
  if token then mainMenu(token) end
end
