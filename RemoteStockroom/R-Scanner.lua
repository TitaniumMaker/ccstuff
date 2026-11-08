local VERSION = "1.89.4"
local SERVICE_TYPE = "stockroom_network"
local SERVER_HOST = "NotYourSystem" -- Must match server HOSTNAME
local SETTINGS_FILE = "scanner_settings"

local settings = {
  output = "",
  refreshInterval = 10,
  monitor = "",
  scannerName = nil
}

-- Ensure distinct identity across all nodes
local myComputerID = os.getComputerID()
local scannerName = os.getComputerLabel() or ("scanner_" .. tostring(myComputerID))

local modemSide = nil
local monitor = nil
local monitorName = nil

local inventories = {}
local inventoryMap = {}
local knownItems = {}
local transferLogs = {}
local serverConnected = false
local lastSyncTime = 0
local totalItemCount = 0

-- =========================================================
-- Helpers & Settings
-- =========================================================

local function safeCall(fn, ...)
  local ok, res = pcall(fn, ...)
  if ok then return true, res end
  return false, res
end

local function logTransfer(msg)
  local entry = textutils.formatTime(os.time(), true) .. " " .. msg
  table.insert(transferLogs, 1, entry)
  while #transferLogs > 12 do
    table.remove(transferLogs, 13)
  end
end

local function saveSettings()
  local f = fs.open(SETTINGS_FILE, "w")
  if not f then return end
  f.write(textutils.serialize(settings))
  f.close()
end

local function loadSettings()
  if not fs.exists(SETTINGS_FILE) then return end
  local f = fs.open(SETTINGS_FILE, "r")
  if not f then return end
  local ok, tbl = pcall(textutils.unserialize, f.readAll())
  f.close()
  if ok and type(tbl) == "table" then
    for k, v in pairs(tbl) do
      settings[k] = v
    end
  end
end

local function fillRect(t, x, y, w, h, bg)
  t.setBackgroundColor(bg)
  for yy = y, y + h - 1 do
    t.setCursorPos(x, yy)
    t.write(string.rep(" ", w))
  end
end

local function put(t, x, y, s, fg, bg, maxWidth)
  local ww = select(1, t.getSize())
  if y < 1 or x > ww then return end
  s = tostring(s or "")
  local width = maxWidth or #s
  width = math.min(width, ww - x + 1)
  if width <= 0 then return end
  s = s:sub(1, width)
  if bg then t.setBackgroundColor(bg) end
  if fg then t.setTextColor(fg) end
  t.setCursorPos(x, y)
  t.write(s)
end

-- =========================================================
-- Hardware & Peripherals Discovery
-- =========================================================

local function findModem()
  modemSide = nil
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      local p = peripheral.wrap(name)
      if p then
        if type(p.isWireless) == "function" then
          local ok, wireless = safeCall(p.isWireless)
          if ok and wireless then
            modemSide = name
            return name
          end
        end
        modemSide = modemSide or name
      end
    end
  end
  return modemSide
end

local function openRednet()
  local side = findModem()
  if not side then return false end
  if not rednet.isOpen(side) then
    pcall(rednet.open, side)
  end
  return rednet.isOpen(side)
end

local function findMonitor()
  monitor = nil
  monitorName = nil

  if settings.monitor and settings.monitor ~= "" then
    local m = peripheral.wrap(settings.monitor)
    if m and type(m.setTextScale) == "function" then
      monitor = m
      monitorName = settings.monitor
      pcall(monitor.setTextScale, 0.5)
      return
    end
  end

  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "monitor" then
      local m = peripheral.wrap(name)
      if m and type(m.setTextScale) == "function" then
        monitor = m
        monitorName = name
        settings.monitor = name
        saveSettings()
        pcall(monitor.setTextScale, 0.5)
        return
      end
    end
  end
end

local function isInventoryPeripheral(name)
  local typ = peripheral.getType(name)
  if typ == "modem" or typ == "monitor" or typ == "computer" then return false end
  local p = peripheral.wrap(name)
  if not p then return false end
  local hasList = type(p.list) == "function" or type(p.items) == "function" or type(p.size) == "function"
  local hasPush = type(p.pushItems) == "function"
  return hasList and hasPush
end

local function discoverInventories()
  inventories = {}
  inventoryMap = {}
  for _, name in ipairs(peripheral.getNames()) do
    if isInventoryPeripheral(name) then
      inventories[#inventories + 1] = name
      inventoryMap[name] = true
    end
  end
  table.sort(inventories)
end

-- =========================================================
-- Local Item Scanning & Exact Metadata/NBT Key Extraction
-- =========================================================

local function getNbtSignature(detail, stack)
  local nbt = (detail and (detail.nbt or detail.nbtHash)) or (stack and (stack.nbt or stack.nbtHash))
  if type(nbt) == "table" then
    local ok, ser = pcall(textutils.serialize, nbt)
    return ok and ser or "table"
  elseif nbt ~= nil then
    return tostring(nbt)
  end
  return ""
end

local function getDamageValue(detail, stack)
  local dmg = (detail and (detail.damage or detail.metadata)) or (stack and (stack.damage or stack.metadata))
  if dmg ~= nil and tonumber(dmg) then
    return tonumber(dmg)
  end
  return 0
end

local function buildItemKey(detail, fallback, stack)
  local name = (detail and (detail.name or detail.id or detail.itemName)) or fallback or "unknown"
  local dmg = getDamageValue(detail, stack)
  local nbtSig = getNbtSignature(detail, stack)

  local key = tostring(name) .. ":" .. tostring(dmg)
  if nbtSig ~= "" then
    key = key .. "@" .. nbtSig
  end
  return key
end

local function prettyName(id)
  local s = tostring(id or "")
  s = s:match(":(.+)") or s
  s = s:gsub("_", " ")
  return s:gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end)
end

local function getDisplayName(detail, fallback, stack)
  if detail and (detail.displayName or detail.display or detail.title) then
    return detail.displayName or detail.display or detail.title
  end
  if stack and (stack.displayName or stack.display or stack.title) then
    return stack.displayName or stack.display or stack.title
  end
  local base = (detail and (detail.name or detail.id or detail.itemName)) or fallback or "Unknown"
  return prettyName(base)
end

local function scanItems()
  knownItems = {}
  totalItemCount = 0

  for _, invName in ipairs(inventories) do
    local inv = peripheral.wrap(invName)
    if inv and type(inv.list) == "function" then
      local ok, list = pcall(inv.list)
      if ok and type(list) == "table" then
        for slot, stack in pairs(list) do
          local detail = nil
          if type(inv.getItemDetail) == "function" then
            local okD, d = pcall(inv.getItemDetail, slot)
            if okD and type(d) == "table" then detail = d end
          end

          local fallbackId = stack.name or stack.id or "unknown"
          local itemKey = buildItemKey(detail, fallbackId, stack)
          local dmg = getDamageValue(detail, stack)
          local nbtSig = getNbtSignature(detail, stack)

          if not knownItems[itemKey] then
            knownItems[itemKey] = {
              key = itemKey,
              name = getDisplayName(detail, fallbackId, stack),
              id = (detail and (detail.name or detail.id or detail.itemName)) or fallbackId,
              damage = dmg,
              nbt = nbtSig,
              total = 0,
              locations = {},
              lineColor = colors.gray
            }
          end

          local count = tonumber(stack.count or 1) or 1
          knownItems[itemKey].total = knownItems[itemKey].total + count
          totalItemCount = totalItemCount + count

          knownItems[itemKey].locations[#knownItems[itemKey].locations + 1] = {
            inv = invName,
            slot = tonumber(slot) or 0,
            count = count
          }
        end
      end
    end
  end
end

local function itemsToArray()
  local arr = {}
  for _, item in pairs(knownItems) do
    arr[#arr + 1] = item
  end
  table.sort(arr, function(a, b)
    if a.name == b.name then return a.key < b.key end
    return a.name < b.name
  end)
  return arr
end

-- =========================================================
-- Network & Option C Transfer Execution
-- =========================================================

local function sendSync()
  if not openRednet() then return end
  scanItems()
  rednet.broadcast({
    type = "sync",
    scanner = scannerName,
    id = myComputerID,
    items = itemsToArray(),
    peripherals = inventories,
    output = settings.output,
    server = SERVER_HOST
  }, SERVICE_TYPE)
  lastSyncTime = os.clock()
end

local function sendConnect()
  if not openRednet() then return end
  rednet.broadcast({
    type = "connect",
    scanner = scannerName,
    id = myComputerID,
    server = SERVER_HOST
  }, SERVICE_TYPE)
end

local function executeLocalTransfer(invName, slot, qty, output)
  local inv = peripheral.wrap(invName)
  if not inv or type(inv.pushItems) ~= "function" then
    return false, 0, "invalid source inventory"
  end

  local ok, sent = safeCall(inv.pushItems, output, slot, qty)
  if not ok then
    return false, 0, tostring(sent)
  end

  local moved = tonumber(sent) or 0
  return true, moved, nil
end

local function handleTransferRequest(msg, sender)
  -- Filter check: verify this transfer request targets this scanner's local inventory
  local invName = tostring(msg.inv or "")
  if not inventoryMap[invName] then
    -- Inventory is not on this scanner machine; ignore packet
    return
  end

  local slot = tonumber(msg.slot) or 0
  local qty = math.floor(tonumber(msg.qty) or 0)
  -- Use local settings.output for transfer
  local output = tostring(settings.output or "")

  if slot < 1 or qty < 1 then
    rednet.send(sender, {
      type = "transfer_result",
      ok = false,
      moved = 0,
      error = "invalid parameters",
      scanner = scannerName
    }, SERVICE_TYPE)
    return
  end

  if output == "" then
    rednet.send(sender, {
      type = "transfer_result",
      ok = false,
      moved = 0,
      error = "no local output configured",
      scanner = scannerName
    }, SERVICE_TYPE)
    logTransfer("Transfer error: no local output configured")
    return
  end

  local ok, moved, err = executeLocalTransfer(invName, slot, qty, output)

  if ok and moved > 0 then
    logTransfer("Moved " .. moved .. "x -> " .. output)
  else
    logTransfer("Failed: " .. tostring(err or "pushItems 0"))
  end

  rednet.send(sender, {
    type = "transfer_result",
    ok = ok,
    moved = moved,
    error = err,
    scanner = scannerName,
    inv = invName,
    slot = slot,
    output = output
  }, SERVICE_TYPE)

  sendSync()
end

-- =========================================================
-- Terminal & Monitor UI Rendering
-- =========================================================

local function renderDisplay(target)
  if not target then return end
  local w, h = target.getSize()

  fillRect(target, 1, 1, w, h, colors.black)
  fillRect(target, 1, 1, w, 3, colors.blue)

  put(target, 2, 2, "SCANNER NODE: " .. scannerName, colors.white, colors.blue)
  put(target, w - 8, 2, "v" .. VERSION, colors.lightGray, colors.blue)

  put(target, 2, 5, "Modem: ", colors.gray, colors.black)
  put(target, 12, 5, modemSide or "none", modemSide and colors.lime or colors.red, colors.black)

  put(target, 2, 6, "Server: ", colors.gray, colors.black)
  put(target, 12, 6, SERVER_HOST, colors.white, colors.black)

  put(target, 2, 7, "Link: ", colors.gray, colors.black)
  put(target, 12, 7, serverConnected and "CONNECTED" or "ONLINE", serverConnected and colors.lime or colors.yellow, colors.black)

  put(target, 2, 8, "Output: ", colors.gray, colors.black)
  put(target, 12, 8, settings.output ~= "" and settings.output or "not configured", settings.output ~= "" and colors.lime or colors.orange, colors.black)

  put(target, 2, 9, "Inventories: " .. tostring(#inventories), colors.white, colors.black)
  put(target, 2, 10, "Total Items: " .. tostring(totalItemCount), colors.white, colors.black)

  put(target, 2, 12, "LOCAL INVENTORIES", colors.lime, colors.black)
  local y = 13
  for i = 1, math.min(#inventories, 4) do
    put(target, 3, y, "- " .. inventories[i], colors.lightGray, colors.black, w - 4)
    y = y + 1
  end
  if #inventories == 0 then
    put(target, 3, y, "No readable inventories attached", colors.red, colors.black)
    y = y + 1
  end

  y = y + 1
  put(target, 2, y, "TRANSFER / NETWORK LOG", colors.cyan, colors.black)
  y = y + 1

  local maxLogs = h - y
  for i = 1, math.min(#transferLogs, maxLogs) do
    put(target, 3, y, transferLogs[i], colors.white, colors.black, w - 4)
    y = y + 1
  end
  if #transferLogs == 0 then
    put(target, 3, y, "Awaiting requests...", colors.gray, colors.black)
  end
end

local function renderAll()
  pcall(renderDisplay, term.current())
  if monitor then
    local ok = pcall(renderDisplay, monitor)
    if not ok then
      monitor = nil
      monitorName = nil
    end
  end
end

-- =========================================================
-- Main Event Loops
-- =========================================================

local function scannerNetworkLoop()
  sendConnect()
  sendSync()

  while true do
    local event, sender, msg, protocol = os.pullEvent("rednet_message")
    if protocol == SERVICE_TYPE and type(msg) == "table" then
      local mtype = tostring(msg.type or "")

      if mtype == "transfer_request" then
        handleTransferRequest(msg, sender)
        renderAll()

      elseif mtype == "connect_result" or mtype == "sync_result" or mtype == "auth_result" then
        serverConnected = true
        renderAll()

      elseif mtype == "request_items" or mtype == "scan" or mtype == "update" then
        sendSync()
        renderAll()

      elseif mtype == "ping" then
        rednet.send(sender, {
          type = "pong",
          ok = true,
          scanner = scannerName,
          id = myComputerID,
          time = os.time()
        }, SERVICE_TYPE)
      end
    end
  end
end

local function scannerMaintenanceLoop()
  local syncTimer = os.startTimer(math.max(1, tonumber(settings.refreshInterval) or 10))
  while true do
    local event, p1 = os.pullEvent()

    if event == "timer" and p1 == syncTimer then
      sendSync()
      renderAll()
      syncTimer = os.startTimer(math.max(1, tonumber(settings.refreshInterval) or 10))

    elseif event == "peripheral" or event == "peripheral_detach" then
      openRednet()
      findMonitor()
      discoverInventories()
      sendSync()
      renderAll()

    elseif event == "term_resize" or event == "monitor_resize" then
      renderAll()
    end
  end
end

local function main()
  loadSettings()
  if settings.scannerName and settings.scannerName ~= "" then
    scannerName = settings.scannerName
  else
    settings.scannerName = scannerName
    saveSettings()
  end

  term.clear()
  findMonitor()
  openRednet()
  discoverInventories()
  scanItems()
  logTransfer("Scanner started")
  renderAll()

  parallel.waitForAny(scannerNetworkLoop, scannerMaintenanceLoop)
end

main()
