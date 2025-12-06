-- door_fob.lua
-- Pocket Computer wireless keypad for DoorAuth system
-- NOW WITH AUTO-DOOR DISCOVERY + scroll menu

local PROTOCOL     = "doorAuth.v1"
local SERVER_NAME  = "DoorAuthServer"

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

local function getDoorList()
  local server = findServer()
  if not server then return nil, "Server offline." end

  rednet.send(server, {type="door_list"}, PROTOCOL)
  local id, msg = rednet.receive(PROTOCOL, 3)

  if not id then return nil, "Timeout." end
  if msg.type ~= "door_list" then return nil, "Bad response." end

  return msg.tags, nil
end

local function askPin()
  term.clear()
  term.setCursorPos(1,1)
  print("Enter PIN:")
  write("> ")
  local pin = read("*")
  return pin
end

local function sendVerify(tag, pin)
  local server = findServer()
  if not server then return nil, "Server offline." end

  rednet.send(server, {
    type="verify",
    tag=tag,
    pin=pin
  }, PROTOCOL)

  local id, msg = rednet.receive(PROTOCOL, 3)
  if not id then return nil, "No response." end
  if msg.type ~= "verify_result" then return nil, "Bad response." end

  return msg.ok, nil
end

---------------------------------------------------
-- DOOR SELECTION MENU
---------------------------------------------------
local function pickDoor()
  local list, err = getDoorList()
  if not list then
    term.clear()
    term.setCursorPos(1,1)
    print("Error loading doors:")
    print(err)
    sleep(1.5)
    return nil
  end

  if #list == 0 then
    term.clear()
    term.setCursorPos(1,1)
    print("No doors registered.")
    sleep(1.5)
    return nil
  end

  local sel = 1
  local maxVisible = 6

  local function draw()
    term.clear()
    term.setCursorPos(1,1)
    print("=== Select Door ===")
    print("W/S to move, Enter to choose")

    local start = math.max(1, sel - math.floor(maxVisible/2))
    local finish = math.min(#list, start + maxVisible - 1)

    for i=start, finish do
      term.setCursorPos(2, i - start + 4)
      if i == sel then
        if term.isColor() then term.setTextColor(colors.cyan) end
        print(" > "..list[i])
        term.setTextColor(colors.white)
      else
        print("   "..list[i])
      end
    end
  end

  while true do
    draw()
    term.setCursorPos(1, maxVisible + 6)
    write("Command: ")
    local c = read()

    c = string.lower(c)

    if c == "w" then
      if sel > 1 then sel = sel - 1 end
    elseif c == "s" then
      if sel < #list then sel = sel + 1 end
    elseif c == "" or c == "enter" then
      return list[sel]
    end
  end
end

---------------------------------------------------
-- MAIN LOOP
---------------------------------------------------
openModems()

while true do
  local door = pickDoor()
  if not door then
    term.clear()
    term.setCursorPos(1,1)
    print("No door selected.")
    sleep(1)
    goto continue
  end

  local pin = askPin()
  term.clear()
  term.setCursorPos(1,1)
  print("Sending…")

  local ok, err = sendVerify(door, pin)

  term.clear()
  term.setCursorPos(1,1)
  print("=== Access Result ===")
  print("Door: "..door)
  print("")

  if err then
    print("Error: "..err)
  elseif ok then
    print("ACCESS GRANTED")
    print("Door opening…")
  else
    print("ACCESS DENIED")
  end

  print("\nPress Enter…")
  read()
  ::continue::
end
