-- keypad.lua (no door label on monitor)

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
  server_name = "DoorAuthServer",
  door_tag = "lobby",
  request_timeout = 3,
  max_code_length = 12,
  entry_label = "Code",
}

local configFields = {
  { key = "protocol", label = "Protocol" },
  { key = "server_name", label = "Server Name" },
  { key = "door_tag", label = "Door Tag" },
  { key = "request_timeout", label = "Request Timeout" },
  { key = "max_code_length", label = "Max Code Length" },
  { key = "entry_label", label = "Entry Label" },
}

local config = startupPrompt("DoorAuth Keypad/Card Setup", "keypad_door", defaultConfig, configFields)

local PROTOCOL = config.protocol
local SERVER_NAME = config.server_name
local DOOR_TAG = config.door_tag
local REQUEST_TIMEOUT = tonumber(config.request_timeout) or 3
local MAX_CODE_LENGTH = tonumber(config.max_code_length) or 12
local ENTRY_LABEL = config.entry_label or "Code"

-- ---------- Modem ----------
local function openModems()
  for _, side in ipairs(rs.getSides()) do
    if peripheral.getType(side) == "modem" then rednet.open(side) end
  end
end

local function findServer()
  return rednet.lookup(PROTOCOL, SERVER_NAME)
end

-- ---------- Terminal UI ----------
local function terminalPIN()
  term.clear()
  term.setCursorPos(1,1)
  write("Enter " .. ENTRY_LABEL .. ": ")
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
  mon.setCursorPos(2, pinY); mon.write(ENTRY_LABEL .. ":")

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
                if #pin < MAX_CODE_LENGTH then pin = pin .. label; refreshPIN() end
              end
            end
          end
        end
      end

    elseif event == "char" then
      local ch = p1
      if ch:match("%d") and #pin < MAX_CODE_LENGTH then pin = pin .. ch; refreshPIN() end

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
  rednet.send(serverID, {type="verify", tag=tag, code=pin}, PROTOCOL)
  local timer = os.startTimer(REQUEST_TIMEOUT)
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

local function findCardManipulator()
  for _, name in ipairs(peripheral.getNames()) do
    local wrapped = peripheral.wrap(name)
    if wrapped and type(wrapped.readCard) == "function" and type(wrapped.hasCard) == "function" then
      return name, wrapped
    end
  end

  return nil, nil
end

local function readCardCode(readerName, reader)
  while not reader.hasCard() do
    sleep(0.2)
  end

  local value, err = reader.readCard()
  if value == false then
    return nil, err or "read_failed"
  end

  if type(value) == "string" or type(value) == "number" then
    value = tostring(value)
  elseif type(value) == "table" then
    value = value.code or value.pin or value.id or value.uuid or value.card or value.value or value.data or value.tag
    if value ~= nil then
      value = tostring(value)
    end
  end

  value = trim(value)
  if value == "" then
    return nil, "empty_card"
  end

  return value
end

local function chooseAccessMode(hasCardReader)
  if not hasCardReader then
    return "pin"
  end

  term.clear()
  term.setCursorPos(1,1)
  print("=== Access Mode ===")
  print("1) PIN")
  print("2) Magnetic Card")
  write("Choose: ")
  local choice = string.lower(read() or "")

  if choice == "2" or choice == "c" or choice == "card" then
    return "card"
  end

  return "pin"
end

-- ---------- Main ----------
local function main()
  openModems()
  local mon = peripheral.find("monitor")
  local readerName, reader = findCardManipulator()

  local server = findServer()
  if not server then
    print("Finding server...")
    while not server do sleep(2); server = findServer() end
  end
  if readerName then
    print("[Keypad/Card] Server #" .. server .. " | Manipulator '" .. readerName .. "' | Door '" .. DOOR_TAG .. "'")
  else
    print("[Keypad] Server #" .. server .. " | Door '"..DOOR_TAG.."'")
  end

  while true do
    local pin
    local accessMode = chooseAccessMode(readerName ~= nil)

    if accessMode == "card" and readerName then
      term.clear()
      term.setCursorPos(1,1)
      print("Insert magnetic card for door: " .. DOOR_TAG)
      pin = readCardCode(readerName, reader)
    elseif mon then
      pin = keypadLoop(mon)
    else
      pin = terminalPIN()
    end

    pin = trim(pin)

    if pin == "" then
      if accessMode == "card" and readerName then
        print("No code read.")
        sleep(1)
      elseif mon then
        drawKeypad(mon, decideLayout(mon.getSize()))
      else
        print("No code entered.")
      end
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
