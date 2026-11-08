local VERSION = "1.89.4"
local SERVICE_TYPE = "CHANGEME"
local HOSTNAME = "CHANGEME"
local SETTINGS_FILE = "settings"
local PAGE_SIZE = 10

local settings = {
  query = "",
  sort = "name",
  selectedTab = "Inventory",
  selectedKey = nil,
  requestQty = 1,
  monitor = "",
  sources = {},
  output = "",
  names = {},
  labels = {},
  favorites = {},
  lineColors = {},
  kits = {},
  debug = true,
  autoSourceAll = true,
  deliveryLog = {},
  refreshInterval = 10,
  selectedKit = nil,
  kitPage = 1,
  requestSubTab = "Normal",
  networkEnabled = true,
  networkUser = "",
  networkPassword = "",
  networkModem = "",
  networkStatus = "disabled"
}

local devices = {}
local monitor = nil
local monitorName = nil
local items = {}
local scanners = {}          -- Indexed by sender computer ID
local connectedClients = {}  -- Tracks pocket computers & scanners
local computerClicks = {}
local monitorClicks = {}
local message = "Ready."
local inputMode = nil
local inputBuffer = ""
local page = 1
local selectedTab = settings.selectedTab or "Inventory"
local selectedKey = settings.selectedKey
local query = settings.query or ""
local requestQty = settings.requestQty or 1
local requestSubTab = settings.requestSubTab or "Normal"
local selectedKit = settings.selectedKit
local kitPage = settings.kitPage or 1
local debugLines = {}

local SCANNER_MESSAGE_TYPES = {
  connect = true,
  hello = true,
  sync = true,
  scan = true,
  update = true,
  ping = true,
  request_items = true
}

-- =========================================================
-- Helpers
-- =========================================================

local function clamp(v, a, b)
  if v < a then return a end
  if v > b then return b end
  return v
end

local function safeCall(fn, ...)
  local ok, res = pcall(fn, ...)
  if ok then return true, res end
  return false, res
end

local function fmt(n)
  n = tonumber(n) or 0
  local s = tostring(math.floor(n))
  local out = ""
  while #s > 3 do
    out = "," .. s:sub(-3) .. out
    s = s:sub(1, -4)
  end
  return s .. out
end

local function normalizeText(s)
  s = tostring(s or ""):lower()
  s = s:gsub("[%s_%-%.:/\\%[%]%(%),]", "")
  return s
end

local function searchMatch(haystack, needle)
  haystack = normalizeText(haystack)
  needle = normalizeText(needle)
  if needle == "" then return true end
  if haystack:find(needle, 1, true) then return true end
  return false
end

local function prettyName(id)
  local s = tostring(id or "")
  s = s:match(":(.+)") or s
  s = s:gsub("_", " ")
  return s:gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end)
end

local function fillRect(t, x, y, ww, hh, bg)
  t.setBackgroundColor(bg)
  for yy = y, y + hh - 1 do
    t.setCursorPos(x, yy)
    t.write(string.rep(" ", ww))
  end
end

local function put(t, x, y, s, fg, bg, width)
  local ww = select(1, t.getSize())
  if y < 1 or x > ww then return end
  s = tostring(s or "")
  width = width or #s
  width = math.min(width, ww - x + 1)
  if width <= 0 then return end
  s = s:sub(1, width)
  if bg then t.setBackgroundColor(bg) end
  if fg then t.setTextColor(fg) end
  t.setCursorPos(x, y)
  t.write(s)
end

local function button(t, x, y, ww, label, fn, bg, fg)
  fillRect(t, x, y, ww, 1, bg or colors.gray)
  local text = tostring(label):sub(1, ww)
  put(t, x + math.max(0, math.floor((ww - #text) / 2)), y, text, fg or colors.white, bg or colors.gray)
  return { x = x, y = y, w = ww, h = 1, fn = fn }
end

local function blackOutlineButton(t, x, y, ww, label, fn, fillColor, textColor, height)
  height = height or 3
  fillRect(t, x, y, ww, height, colors.black)
  fillRect(t, x + 1, y + 1, ww - 2, height - 2, fillColor or colors.gray)
  local tx = x + math.max(0, math.floor((ww - #label) / 2))
  local ty = y + math.floor(height / 2)
  put(t, tx, ty, label, textColor or colors.white, colors.black)
  return { x = x, y = y, w = ww, h = height, fn = fn }
end

local function rectHit(x, y, r)
  return x >= r.x and x <= r.x + (r.w or 1) - 1 and y >= r.y and y <= r.y + (r.h or 1) - 1
end

local function setMessage(msg)
  message = tostring(msg or "")
end

local function promptInput(title, default, callback)
  inputMode = { title = title, callback = callback }
  inputBuffer = default or ""
  setMessage("Type text, Enter to save, Esc to cancel.")
end

local function clearInput()
  inputMode = nil
  inputBuffer = ""
end

local function saveSettings()
  settings.selectedTab = selectedTab
  settings.selectedKey = selectedKey
  settings.query = query
  settings.requestQty = requestQty
  settings.requestSubTab = requestSubTab
  settings.selectedKit = selectedKit
  settings.kitPage = kitPage
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

local function getCustomName(item)
  return settings.names[item.key]
end

local function getDisplayName(item)
  return settings.names[item.key] or item.name or item.id or item.key
end

local function getLabel(item)
  return settings.labels[item.key]
end

local function isFavorite(key)
  return settings.favorites[key] == true
end

local function toggleFavorite(key)
  settings.favorites[key] = not settings.favorites[key] or nil
  saveSettings()
end

local function colorName(c)
  local map = {
    [colors.white] = "white",
    [colors.lightGray] = "light gray",
    [colors.gray] = "gray",
    [colors.red] = "red",
    [colors.orange] = "orange",
    [colors.yellow] = "yellow",
    [colors.lime] = "lime",
    [colors.green] = "green",
    [colors.cyan] = "cyan",
    [colors.blue] = "blue",
    [colors.purple] = "purple",
    [colors.pink] = "pink",
    [colors.brown] = "brown",
    [colors.black] = "black"
  }
  return map[c] or "custom"
end

local function cycleLineColor(key)
  local list = {
    colors.white, colors.lightGray, colors.gray, colors.red, colors.orange,
    colors.yellow, colors.lime, colors.green, colors.cyan, colors.blue,
    colors.purple, colors.pink, colors.brown, colors.black
  }
  local current = settings.lineColors[key] or colors.white
  local idx = 1
  for i, c in ipairs(list) do
    if c == current then
      idx = (i % #list) + 1
      break
    end
  end
  settings.lineColors[key] = list[idx]
  saveSettings()
end

-- =========================================================
-- Metadata and NBT Distinct Key Generation
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

local function stackKeyFrom(detail, stack)
  local name = (detail and (detail.name or detail.id or detail.itemName)) or (stack and (stack.name or stack.id)) or "unknown"
  local dmg = getDamageValue(detail, stack)
  local nbtSig = getNbtSignature(detail, stack)

  local key = tostring(name) .. ":" .. tostring(dmg)
  if nbtSig ~= "" then
    key = key .. "@" .. nbtSig
  end
  return key
end

local function displayNameFrom(detail, stack)
  if detail and (detail.displayName or detail.display or detail.title) then
    return detail.displayName or detail.display or detail.title
  end
  if stack and (stack.displayName or stack.display or stack.title) then
    return stack.displayName or stack.display or stack.title
  end
  local fallbackName = (detail and (detail.name or detail.id)) or (stack and (stack.name or stack.id)) or "Unknown"
  return prettyName(fallbackName)
end

local function isInventoryLike(methods)
  return methods.list or methods.pushItems or methods.pullItems or methods.getItemDetail or methods.itemDetail or methods.getAllStacks or methods.size or methods.items
end

local function methodSetFor(name)
  local methods = {}
  local okMethods, list = pcall(peripheral.getMethods, name)
  if okMethods and type(list) == "table" then
    for _, m in ipairs(list) do
      methods[m] = true
    end
  end
  return methods
end

local function safeTostring(v, fallback)
  if v == nil then return fallback or "" end
  return tostring(v)
end

local function nowTime()
  return os.clock and os.clock() or os.time()
end

-- =========================================================
-- Device Discovery / Local Inventories
-- =========================================================

local function discoverDevices()
  devices = {}
  local names = peripheral.getNames() or {}
  table.sort(names)

  for _, name in ipairs(names) do
    local typ = peripheral.getType(name) or "unknown"
    local methods = methodSetFor(name)
    local inv = isInventoryLike(methods)
    devices[#devices + 1] = {
      name = name,
      type = typ,
      methods = methods,
      inventory = inv,
      monitor = methods.setTextScale and methods.getSize,
      modem = methods.open and (methods.isWireless ~= nil)
    }
  end

  if settings.autoSourceAll then
    for _, d in ipairs(devices) do
      if d.inventory then
        settings.sources[d.name] = true
      end
    end
  end
end

local function chooseMonitor()
  monitor = nil
  monitorName = nil
  monitorClicks = {}

  if settings.monitor ~= "" then
    local p = peripheral.wrap(settings.monitor)
    if p and type(p.setTextScale) == "function" and type(p.getSize) == "function" then
      monitor = p
      monitorName = settings.monitor
      pcall(monitor.setTextScale, 0.5)
      return
    end
  end

  for _, d in ipairs(devices) do
    if d.monitor then
      local p = peripheral.wrap(d.name)
      if p then
        monitor = p
        monitorName = d.name
        settings.monitor = d.name
        saveSettings()
        pcall(monitor.setTextScale, 0.5)
        return
      end
    end
  end
end

local function readStacksFromDevice(deviceName)
  local stacks = {}
  local p = peripheral.wrap(deviceName)
  if not p then return stacks end

  local function addStack(slot, stack, detail)
    local src = detail or stack
    if type(src) ~= "table" then return end

    local itemName = src.name or src.id or src.itemName or src.type
    if not itemName then return end

    local count = tonumber(src.count or src.amount or src.size or src.qty or 1) or 1
    local display = displayNameFrom(detail, stack)

    stacks[#stacks + 1] = {
      slot = slot,
      name = itemName,
      id = itemName,
      display = display,
      count = count,
      raw = src,
      nbt = src.nbt or src.nbtHash,
      damage = getDamageValue(detail, stack)
    }
  end

  if type(p.list) == "function" then
    local ok, list = pcall(p.list)
    if ok and type(list) == "table" then
      for slot, stack in pairs(list) do
        local detail = nil
        if type(p.getItemDetail) == "function" then
          local okD, d = pcall(p.getItemDetail, slot)
          if okD and type(d) == "table" then detail = d end
        end
        addStack(slot, stack, detail)
      end
      if #stacks > 0 then return stacks end
    end
  end

  return stacks
end

local function itemSourceCount(item)
  local c = 0
  for _ in pairs(item.sources or {}) do c = c + 1 end
  return c
end

-- =========================================================
-- Multi-Scanner Aggregation & Rebuild (With Auto-Suffixing)
-- =========================================================

local function rebuildGlobalIndex()
  discoverDevices()
  local aggregate = {}

  -- 1. Local Inventories
  for _, dev in ipairs(devices) do
    if dev.inventory and settings.sources[dev.name] ~= false then
      local list = readStacksFromDevice(dev.name)
      for _, stack in ipairs(list) do
        local detail = stack.raw or stack
        local key = stackKeyFrom(detail, stack)

        if not aggregate[key] then
          local base = displayNameFrom(detail, stack)
          aggregate[key] = {
            key = key,
            baseName = base,
            name = base,
            id = (detail and (detail.name or detail.id or detail.itemName)) or stack.name or "unknown",
            nbt = getNbtSignature(detail, stack),
            damage = getDamageValue(detail, stack),
            total = 0,
            sources = {},
            locations = {}
          }
        end

        aggregate[key].total = aggregate[key].total + (stack.count or 0)
        aggregate[key].sources[dev.name] = (aggregate[key].sources[dev.name] or 0) + (stack.count or 0)
        aggregate[key].locations[#aggregate[key].locations + 1] = {
          isRemote = false,
          inv = dev.name,
          slot = stack.slot,
          count = stack.count or 0,
          display = stack.display
        }
      end
    end
  end

  -- 2. Remote Scanners
  for scannerId, scannerRec in pairs(scanners) do
    local sName = scannerRec.name or ("scanner_" .. tostring(scannerId))
    if type(scannerRec.items) == "table" then
      for _, sItem in ipairs(scannerRec.items) do
        if type(sItem) == "table" and sItem.key then
          local key = safeTostring(sItem.key, "")
          if key ~= "" then
            if not aggregate[key] then
              local base = sItem.name or key
              aggregate[key] = {
                key = key,
                baseName = base,
                name = base,
                id = sItem.id or key,
                nbt = sItem.nbt,
                damage = sItem.damage or 0,
                total = 0,
                sources = {},
                locations = {}
              }
            end

            local sTotal = tonumber(sItem.total) or 0
            aggregate[key].total = aggregate[key].total + sTotal
            aggregate[key].sources["scanner:" .. sName] = (aggregate[key].sources["scanner:" .. sName] or 0) + sTotal

            for _, loc in ipairs(sItem.locations or {}) do
              if type(loc) == "table" then
                aggregate[key].locations[#aggregate[key].locations + 1] = {
                  isRemote = true,
                  scannerName = sName,
                  scannerId = scannerId,
                  inv = loc.inv,
                  slot = tonumber(loc.slot) or 0,
                  count = tonumber(loc.count) or 0,
                  display = loc.display or sItem.name
                }
              end
            end
          end
        end
      end
    end
  end

  -- 3. Group by baseName to detect splits and assign "Item 1, Item 2..." suffixes
  local baseGroups = {}
  for _, item in pairs(aggregate) do
    local b = item.baseName or item.id or "Unknown"
    baseGroups[b] = baseGroups[b] or {}
    table.insert(baseGroups[b], item)
  end

  for _, group in pairs(baseGroups) do
    if #group > 1 then
      table.sort(group, function(a, b)
        if a.damage ~= b.damage then
          return (a.damage or 0) < (b.damage or 0)
        end
        return tostring(a.key) < tostring(b.key)
      end)
      for idx, item in ipairs(group) do
        item.name = item.baseName .. " " .. tostring(idx)
      end
    end
  end

  local merged = {}
  for _, item in pairs(aggregate) do
    if settings.names and settings.names[item.key] then
      item.name = settings.names[item.key]
    end
    if settings.lineColors and settings.lineColors[item.key] then
      item.lineColor = settings.lineColors[item.key]
    end
    merged[#merged + 1] = item
  end

  if settings.sort == "count" then
    table.sort(merged, function(a, b)
      if a.total == b.total then return a.name < b.name end
      return a.total > b.total
    end)
  elseif settings.sort == "sources" then
    table.sort(merged, function(a, b)
      local ca = itemSourceCount(a)
      local cb = itemSourceCount(b)
      if ca == cb then return a.name < b.name end
      return ca > cb
    end)
  else
    table.sort(merged, function(a, b)
      if a.name == b.name then return a.id < b.id end
      return a.name < b.name
    end)
  end

  items = merged
end

local function getItem(key)
  for _, item in ipairs(items) do
    if item.key == key then return item end
  end
  return nil
end

local function filteredItems()
  local out = {}
  for _, item in ipairs(items) do
    if item.total > 0 then
      local title = getDisplayName(item)
      local hay = title .. " " .. item.id .. " " .. tostring(item.key)
      if searchMatch(hay, query) then
        out[#out + 1] = item
      end
    end
  end
  return out
end

-- =========================================================
-- Option C Remote Scanner Dispatcher
-- =========================================================

local function dispatchScannerTransfer(scannerId, reqKey, slot, invName, qty, outputName)
  if not scannerId or not rednet.isOpen() then return 0 end
  rednet.send(scannerId, {
    type = "transfer_request",
    key = reqKey,
    slot = slot,
    inv = invName,
    qty = qty,
    output = outputName,
    server = HOSTNAME
  }, SERVICE_TYPE)

  local deadline = os.clock() + 1.5
  while os.clock() < deadline do
    local sender, reply = rednet.receive(SERVICE_TYPE, 0.1)
    if sender == scannerId and type(reply) == "table" and reply.type == "transfer_result" then
      if reply.ok and tonumber(reply.moved) then
        return tonumber(reply.moved)
      end
      break
    end
  end
  return 0
end

-- =========================================================
-- Requests Execution
-- =========================================================

local function requestItem(itemKey, qty, requestedOutput)
  qty = math.floor(tonumber(qty) or 0)
  if qty < 1 then
    setMessage("Quantity must be at least 1.")
    return 0
  end

  rebuildGlobalIndex()
  local item = getItem(itemKey)
  if not item then
    setMessage("Item not found.")
    return 0
  end
  if qty > item.total then
    setMessage("Not enough stock.")
    return 0
  end

  local outputName = (requestedOutput and requestedOutput ~= "") and requestedOutput or settings.output

  local moved = 0
  for _, loc in ipairs(item.locations) do
    if moved >= qty then break end
    local take = math.min(qty - moved, loc.count)

    if loc.isRemote then
      local sent = dispatchScannerTransfer(loc.scannerId, item.key, loc.slot, loc.inv, take, outputName)
      moved = moved + sent
    else
      if outputName ~= "" then
        local src = peripheral.wrap(loc.inv)
        if src and type(src.pushItems) == "function" then
          local ok, sent = safeCall(src.pushItems, outputName, loc.slot, take)
          if ok and type(sent) == "number" then
            moved = moved + sent
          end
        end
      end
    end
  end

  if moved > 0 then
    local msg = textutils.formatTime(os.time(), true) .. "  " .. moved .. " x " .. getDisplayName(item) .. " -> " .. (outputName ~= "" and outputName or "default output")
    table.insert(settings.deliveryLog, 1, msg)
    while #settings.deliveryLog > 12 do table.remove(settings.deliveryLog, 13) end
    saveSettings()
    setMessage("Delivered " .. fmt(moved) .. " x " .. getDisplayName(item))
    rebuildGlobalIndex()
  else
    setMessage("No items moved.")
  end

  return moved
end

local function kitList()
  local arr = {}
  for key, kit in pairs(settings.kits or {}) do
    kit.key = key
    arr[#arr + 1] = kit
  end
  table.sort(arr, function(a, b)
    return tostring(a.name or a.key) < tostring(b.name or b.key)
  end)
  return arr
end

local function createKit()
  local base = "Kit"
  local n = 1
  while settings.kits[base .. " " .. n] do n = n + 1 end
  local name = base .. " " .. n
  settings.kits[name] = { name = name, output = settings.output or "", items = {} }
  selectedKit = name
  saveSettings()
  setMessage("Created " .. name)
end

local function renameKit(oldKey, newName)
  if not oldKey or not settings.kits[oldKey] then return end
  if newName == "" then return end
  if oldKey == newName then return end
  if settings.kits[newName] then return end
  settings.kits[newName] = settings.kits[oldKey]
  settings.kits[newName].name = newName
  settings.kits[oldKey] = nil
  selectedKit = newName
  saveSettings()
end

local function deleteKit(key)
  if not key then return end
  settings.kits[key] = nil
  if selectedKit == key then selectedKit = nil end
  saveSettings()
end

local function addSelectedItemToKit(kitKey, amount)
  local kit = settings.kits[kitKey]
  local item = getItem(selectedKey)
  if not kit or not item then return end
  amount = math.floor(tonumber(amount) or 0)
  if amount < 1 then return end
  kit.items = kit.items or {}

  local found = false
  for _, entry in ipairs(kit.items) do
    if entry.itemKey == item.key then
      entry.amount = entry.amount + amount
      found = true
      break
    end
  end

  if not found then
    kit.items[#kit.items + 1] = {
      itemKey = item.key,
      name = getDisplayName(item),
      id = item.id,
      amount = amount
    }
  end

  saveSettings()
  setMessage("Added " .. amount .. "x to " .. tostring(kit.name or kitKey))
end

local function transferKit(kitKey)
  local kit = settings.kits[kitKey]
  if not kit then return end

  local outDest = (kit.output and kit.output ~= "") and kit.output or settings.output
  if not outDest or outDest == "" then
    setMessage("Kit/Ender chest output not set.")
    return
  end

  rebuildGlobalIndex()
  local totalMoved = 0
  for _, entry in ipairs(kit.items or {}) do
    local moved = requestItem(entry.itemKey, entry.amount, outDest)
    totalMoved = totalMoved + moved
  end

  if totalMoved > 0 then
    local msg = textutils.formatTime(os.time(), true) .. " Kit " .. tostring(kit.name or kitKey) .. " -> " .. tostring(outDest)
    table.insert(settings.deliveryLog, 1, msg)
    while #settings.deliveryLog > 12 do table.remove(settings.deliveryLog, 13) end
    saveSettings()
    setMessage("Kit delivered to " .. outDest)
    rebuildGlobalIndex()
  else
    setMessage("No kit items moved (check stock/output).")
  end
end

-- =========================================================
-- Network Protocol & Multi-Client Registry
-- =========================================================

local function findAndOpenModem()
  local names = peripheral.getNames() or {}
  local best = nil
  local fallback = nil

  for _, name in ipairs(names) do
    if peripheral.getType(name) == "modem" then
      local p = peripheral.wrap(name)
      if p then
        if type(p.isWireless) == "function" then
          local ok, wireless = safeCall(p.isWireless)
          if ok and wireless then
            best = name
            break
          end
        end
        fallback = fallback or name
      end
    end
  end

  local chosen = (settings.networkModem ~= "" and settings.networkModem) or best or fallback
  if not chosen then
    settings.networkStatus = "no modem"
    saveSettings()
    return false
  end

  if not rednet.isOpen(chosen) then
    local ok = pcall(rednet.open, chosen)
    if not ok then
      settings.networkStatus = "rednet open failed"
      saveSettings()
      return false
    end
  end

  settings.networkModem = chosen
  settings.networkStatus = "online"
  pcall(rednet.host, SERVICE_TYPE, HOSTNAME)
  saveSettings()
  return true
end

local function ensureRednet()
  if not settings.networkEnabled then
    settings.networkStatus = "disabled"
    saveSettings()
    return false
  end
  return findAndOpenModem()
end

local function registerClient(sender, clientType, clientLabel)
  connectedClients[sender] = {
    id = sender,
    type = clientType or "Client",
    label = clientLabel or ("client_" .. tostring(sender)),
    lastSeen = nowTime()
  }
end

local function networkAuthenticate(msg)
  local user = tostring(msg.username or "")
  local pass = tostring(msg.password or "")
  if user == tostring(settings.networkUser or "") and pass == tostring(settings.networkPassword or "") then
    return true, "ok"
  end
  return false, "denied"
end

local function networkSearch(msg)
  local q = tostring(msg.query or "")
  local out = {}

  for _, item in ipairs(items) do
    if item.total > 0 then
      local title = getDisplayName(item)
      local hay = title .. " " .. item.id .. " " .. tostring(item.key)
      if searchMatch(hay, q) then
        out[#out + 1] = {
          key = item.key,
          name = getDisplayName(item),
          id = item.id,
          total = item.total,
          sources = itemSourceCount(item),
          lineColor = settings.lineColors[item.key] or colors.white
        }
      end
    end
  end

  return { ok = true, result = out, server = HOSTNAME }
end

local function networkRequest(msg)
  local key = tostring(msg.key or "")
  local qty = math.floor(tonumber(msg.qty) or 0)
  local item = getItem(key)
  if not item then return { ok = false, error = "item not found" } end
  if qty < 1 then return { ok = false, error = "quantity invalid" } end
  if qty > item.total then return { ok = false, error = "not enough stock" } end

  local outDest = tostring(msg.output or "")
  local moved = requestItem(key, qty, outDest)

  if moved > 0 then
    return { ok = true, moved = moved, item = getDisplayName(item), output = outDest, server = HOSTNAME }
  end

  return { ok = false, error = "no items moved" }
end

-- =========================================================
-- Multi-Scanner Synchronization
-- =========================================================

local function normalizeLocation(loc)
  if type(loc) ~= "table" then return nil end
  return {
    inv = safeTostring(loc.inv or loc.inventory or loc.name, ""),
    slot = tonumber(loc.slot) or 0,
    count = tonumber(loc.count) or 0,
    display = loc.display
  }
end

local function normalizeItem(item, fallbackName)
  if type(item) ~= "table" then return nil end
  local key = safeTostring(item.key, "")
  if key == "" then return nil end

  local locations = {}
  if type(item.locations) == "table" then
    for _, loc in ipairs(item.locations) do
      local n = normalizeLocation(loc)
      if n then locations[#locations + 1] = n end
    end
  end

  return {
    key = key,
    name = safeTostring(item.name or item.displayName or fallbackName or key, key),
    id = safeTostring(item.id or fallbackName or key, key),
    total = tonumber(item.total) or 0,
    damage = item.damage or 0,
    nbt = item.nbt or "",
    lineColor = tonumber(item.lineColor) or colors.gray,
    locations = locations
  }
end

local function normalizeItemList(list)
  local out = {}
  if type(list) ~= "table" then return out end

  if #list > 0 then
    for _, item in ipairs(list) do
      local n = normalizeItem(item)
      if n then out[#out + 1] = n end
    end
  else
    for k, v in pairs(list) do
      if type(v) == "table" then
        local n = normalizeItem(v, safeTostring(k, ""))
        if n then out[#out + 1] = n end
      elseif type(k) == "string" then
        out[#out + 1] = {
          key = k,
          name = k,
          id = k,
          total = tonumber(v) or 0,
          lineColor = colors.gray,
          locations = {}
        }
      end
    end
  end

  return out
end

local function updateScannerRecord(sender, msg)
  local scannerName = safeTostring(msg.scanner or msg.name or msg.label, "scanner_" .. tostring(sender))

  local rec = scanners[sender] or {
    name = scannerName,
    id = sender,
    lastSeen = 0,
    wireless = true,
    output = nil,
    items = {}
  }

  rec.name = scannerName
  rec.id = sender
  rec.lastSeen = nowTime()
  rec.wireless = true
  rec.output = msg.output or rec.output
  rec.items = normalizeItemList(msg.items or {})
  rec.peripherals = msg.peripherals or rec.peripherals

  scanners[sender] = rec
  registerClient(sender, "Scanner", scannerName)

  return scannerName, rec
end

local function cleanupStaleClients()
  local now = nowTime()
  local changed = false

  for id, rec in pairs(scanners) do
    local last = tonumber(rec.lastSeen) or 0
    if last > 0 and (now - last) > 45 then
      scanners[id] = nil
      changed = true
    end
  end

  for id, client in pairs(connectedClients) do
    local last = tonumber(client.lastSeen) or 0
    if last > 0 and (now - last) > 45 then
      connectedClients[id] = nil
    end
  end

  if changed then
    rebuildGlobalIndex()
  end
end

local function handleScannerPacket(sender, msg)
  local mtype = tostring(msg.type or msg.command or "")

  if mtype == "connect" or mtype == "hello" then
    local scannerName = updateScannerRecord(sender, msg)
    return {
      type = "connect_result",
      ok = true,
      connected = true,
      scanner = scannerName,
      server = HOSTNAME,
      wireless = true
    }
  end

  if mtype == "sync" or mtype == "scan" or mtype == "update" then
    local scannerName = updateScannerRecord(sender, msg)
    rebuildGlobalIndex()
    return {
      type = "sync_result",
      ok = true,
      scanner = scannerName,
      server = HOSTNAME,
      wireless = true
    }
  end

  if mtype == "ping" then
    local scannerName = updateScannerRecord(sender, msg)
    return {
      type = "pong",
      ok = true,
      scanner = scannerName,
      server = HOSTNAME,
      time = os.time()
    }
  end

  if mtype == "request_items" then
    rebuildGlobalIndex()
    return {
      type = "items_result",
      ok = true,
      server = HOSTNAME,
      items = items or {}
    }
  end

  return nil
end

-- =========================================================
-- Monitor & Terminal Rendering
-- =========================================================

local function drawComputerPanel()
  local t = term.current()
  local w, h = t.getSize()
  fillRect(t, 1, 1, w, h, colors.black)
  fillRect(t, 1, 1, w, 3, colors.blue)
  put(t, 2, 2, "STOCKROOM / CONTROL", colors.white, colors.blue)
  computerClicks = {}

  local bw = math.max(8, math.floor((w - 6) / 2))
  local x1 = 2
  local x2 = 4 + bw

  table.insert(computerClicks, button(t, x1, 7, bw, "Inventory", function()
    selectedTab = "Inventory"; saveSettings()
  end, selectedTab == "Inventory" and colors.green or colors.gray))

  table.insert(computerClicks, button(t, x2, 7, bw, "Requests", function()
    selectedTab = "Requests"; saveSettings()
  end, selectedTab == "Requests" and colors.green or colors.gray))

  table.insert(computerClicks, button(t, x1, 10, bw, "Favorites", function()
    selectedTab = "Favorites"; saveSettings()
  end, selectedTab == "Favorites" and colors.green or colors.gray))

  table.insert(computerClicks, button(t, x2, 10, bw, "Peripherals", function()
    selectedTab = "Peripherals"; saveSettings()
  end, selectedTab == "Peripherals" and colors.green or colors.gray))

  table.insert(computerClicks, button(t, x1, 13, bw, "Kits", function()
    selectedTab = "Kits"; saveSettings()
  end, selectedTab == "Kits" and colors.green or colors.gray))

  table.insert(computerClicks, button(t, x2, 13, bw, "Network", function()
    selectedTab = "Network"; saveSettings()
  end, selectedTab == "Network" and colors.green or colors.gray))

  table.insert(computerClicks, button(t, x1, 16, bw * 2 + 1, "Debug", function()
    selectedTab = "Debug"; saveSettings()
  end, selectedTab == "Debug" and colors.green or colors.gray))

  local clientCount = 0
  for _ in pairs(connectedClients) do clientCount = clientCount + 1 end
  put(t, 2, h - 3, "Press / to Search items", colors.yellow, colors.black)
  put(t, 2, h - 2, "Active Clients: " .. tostring(clientCount), colors.lime, colors.black)
  put(t, 2, h - 1, "Press F5/F6 to refresh", colors.lightGray, colors.black)
end

local function drawHeader(t, w)
  fillRect(t, 1, 1, w, 3, colors.blue)
  put(t, 2, 2, "STOCKROOM / FULL INVENTORY", colors.white, colors.blue)
  local tabs = { "Inventory", "Requests", "Favorites", "Peripherals", "Kits", "Debug", "Network" }
  local tx = 2
  monitorClicks = {}
  for _, tab in ipairs(tabs) do
    local label = " " .. tab .. " "
    local active = selectedTab == tab
    local rect = button(t, tx, 4, #label, label, function()
      selectedTab = tab
      saveSettings()
    end, active and colors.green or colors.gray)
    table.insert(monitorClicks, rect)
    tx = tx + #label + 1
  end
  put(t, w - 24, 4, tostring(monitorName or "none"), colors.white, colors.gray)
end

local function drawInventoryPage(t, w, h)
  local leftW = math.floor(w * 0.72)
  local rightX = leftW + 1
  local rightW = w - leftW

  fillRect(t, 1, 5, leftW, h - 4, colors.black)
  fillRect(t, rightX, 5, rightW, h - 4, colors.gray)

  button(t, 2, 6, leftW - 2, "Search [/]: " .. query, function()
    promptInput("Search", query, function(v)
      query = v or ""
      page = 1
      saveSettings()
    end)
  end)

  button(t, 2, 7, leftW - 2, "Sort: " .. tostring(settings.sort), function()
    settings.sort = settings.sort == "count" and "name" or settings.sort == "name" and "sources" or "count"
    saveSettings()
    rebuildGlobalIndex()
  end)

  put(t, 2, 9, "Item", colors.lime, colors.black)
  put(t, math.floor(leftW * 0.58), 9, "Count", colors.lime, colors.black)
  put(t, math.floor(leftW * 0.80), 9, "Src", colors.lime, colors.black)

  local list = filteredItems()
  local startIndex = (page - 1) * PAGE_SIZE + 1
  local totalPages = math.max(1, math.ceil(#list / PAGE_SIZE))
  page = clamp(page, 1, totalPages)

  local y = 10
  for i = startIndex, math.min(#list, startIndex + PAGE_SIZE - 1) do
    local item = list[i]
    local bg = selectedKey == item.key and colors.green or colors.black
    local fg = selectedKey == item.key and colors.black or colors.white
    fillRect(t, 2, y, leftW - 2, 1, bg)
    fillRect(t, 2, y + 1, leftW - 2, 1, colors.black)

    local main = getDisplayName(item)
    local secondary = item.id
    if item.damage and tonumber(item.damage) and tonumber(item.damage) ~= 0 then
      secondary = secondary .. " [meta:" .. tostring(item.damage) .. "]"
    end
    if getCustomName(item) then secondary = secondary .. "  [" .. getCustomName(item) .. "]" end

    put(t, 3, y, (isFavorite(item.key) and "★ " or "") .. main, fg, bg, math.floor(leftW * 0.62))
    put(t, math.floor(leftW * 0.58), y, fmt(item.total), fg, bg, 12)
    put(t, math.floor(leftW * 0.80), y, fmt(itemSourceCount(item)), fg, bg, 8)
    put(t, 3, y + 1, secondary, colors.lightGray, colors.black, leftW - 5)

    fillRect(t, 2, y + 2, leftW - 2, 1, settings.lineColors[item.key] or colors.white)

    table.insert(monitorClicks, { x = 2, y = y, w = leftW - 2, h = 2, fn = function()
      selectedKey = item.key
      saveSettings()
    end })

    y = y + 4
  end

  if #list == 0 then
    put(t, 2, 10, "No items matched.", colors.lightGray, colors.black)
  end

  local prevRect = button(t, 2, h - 2, 12, "< Previous", function() page = math.max(1, page - 1) end)
  local nextRect = button(t, leftW - 10, h - 2, 9, "Next >", function() page = math.min(totalPages, page + 1) end)
  table.insert(monitorClicks, prevRect)
  table.insert(monitorClicks, nextRect)

  put(t, leftW - 27, h - 1, "Page " .. page .. " / " .. totalPages, colors.white, colors.gray)

  fillRect(t, rightX, 5, rightW, h - 4, colors.gray)
  local item = getItem(selectedKey)

  if not item then
    put(t, rightX + 2, 7, "Select an item to inspect.", colors.white, colors.gray)
  else
    put(t, rightX + 2, 6, getDisplayName(item), colors.lime, colors.gray)
    put(t, rightX + 2, 7, item.id, colors.white, colors.gray)
    if item.damage and tonumber(item.damage) and tonumber(item.damage) ~= 0 then
      put(t, rightX + 2, 8, "Meta/Damage: " .. tostring(item.damage), colors.yellow, colors.gray)
    end
    if getCustomName(item) then put(t, rightX + 2, 9, "Custom: " .. getCustomName(item), colors.lightGray, colors.gray) end
    put(t, rightX + 2, 11, "Count: " .. fmt(item.total), colors.white, colors.gray)
    put(t, rightX + 2, 12, "Sources: " .. fmt(itemSourceCount(item)), colors.white, colors.gray)
    put(t, rightX + 2, 13, "Stacks: " .. fmt(#item.locations), colors.white, colors.gray)
    put(t, rightX + 2, 14, "Label: " .. tostring(getLabel(item) or "none"), colors.white, colors.gray)
    put(t, rightX + 2, 15, "Favorite: " .. tostring(isFavorite(item.key)), colors.white, colors.gray)
    put(t, rightX + 2, 16, "Line color: " .. colorName(settings.lineColors[item.key] or colors.white), colors.white, colors.gray)

    local req1 = blackOutlineButton(t, rightX + 1, 19, rightW - 2, "Request 1", function()
      requestItem(item.key, 1)
    end, colors.green, colors.black, 3)

    local reqTab = blackOutlineButton(t, rightX + 1, 23, rightW - 2, "Request tab", function()
      selectedTab = "Requests"
      requestSubTab = "Normal"
      selectedKey = item.key
      requestQty = 1
      saveSettings()
    end, colors.cyan, colors.black, 3)

    local renameBtn = blackOutlineButton(t, rightX + 1, 27, rightW - 2, "Rename", function()
      promptInput("Rename display name", settings.names[item.key] or item.name, function(v)
        settings.names[item.key] = (v and v ~= "") and v or nil
        saveSettings()
        rebuildGlobalIndex()
      end)
    end, colors.lightGray, colors.black, 3)

    local labelBtn = blackOutlineButton(t, rightX + 1, 31, rightW - 2, "Color label", function()
      promptInput("Label color", tostring(getLabel(item) or "none"), function(v)
        settings.labels[item.key] = (v and v ~= "" and v ~= "none") and v or nil
        saveSettings()
        rebuildGlobalIndex()
      end)
    end, colors.lightGray, colors.black, 3)

    local favText = isFavorite(item.key) and "Remove Favorite" or "Add to Favorites"
    local favBtn = blackOutlineButton(t, rightX + 1, 35, rightW - 2, favText, function()
      toggleFavorite(item.key)
    end, colors.yellow, colors.black, 3)

    local lineBtn = blackOutlineButton(t, rightX + 1, 39, rightW - 2, "Line color", function()
      cycleLineColor(item.key)
    end, settings.lineColors[item.key] or colors.white, colors.black, 3)

    table.insert(monitorClicks, req1)
    table.insert(monitorClicks, reqTab)
    table.insert(monitorClicks, renameBtn)
    table.insert(monitorClicks, labelBtn)
    table.insert(monitorClicks, favBtn)
    table.insert(monitorClicks, lineBtn)
  end
end

local function drawRequestsNormal(t, w, h)
  fillRect(t, 1, 5, w, h - 4, colors.black)
  put(t, 2, 6, "Request items", colors.lime, colors.black)

  local item = getItem(selectedKey)
  if not item then
    put(t, 2, 8, "Select an item first.", colors.lightGray, colors.black)
    return
  end

  put(t, 2, 8, "Item: " .. getDisplayName(item), colors.white, colors.black)
  put(t, 2, 9, "Available: " .. fmt(item.total), colors.white, colors.black)

  local qtyBtn = button(t, 2, 11, 14, "Qty: " .. tostring(requestQty), function()
    promptInput("Request quantity", tostring(requestQty), function(v)
      local n = tonumber(v)
      if n and n >= 1 then
        requestQty = math.floor(n)
        saveSettings()
      end
    end)
  end)

  local b1 = button(t, 17, 11, 12, "1", function() requestQty = 1; saveSettings() end)
  local b16 = button(t, 30, 11, 12, "16", function() requestQty = 16; saveSettings() end)
  local b64 = button(t, 43, 11, 12, "64", function() requestQty = 64; saveSettings() end)
  local bc = button(t, 56, 11, 18, "Custom", function()
    promptInput("Custom count", tostring(requestQty), function(v)
      local n = tonumber(v)
      if n and n >= 1 then requestQty = math.floor(n); saveSettings() end
    end)
  end)

  table.insert(monitorClicks, qtyBtn)
  table.insert(monitorClicks, b1)
  table.insert(monitorClicks, b16)
  table.insert(monitorClicks, b64)
  table.insert(monitorClicks, bc)

  local deliverBtn = button(t, 2, 13, 20, "Deliver request", function()
    requestItem(item.key, requestQty)
  end, colors.green)

  local destBtn = button(t, 23, 13, 22, "Set destination", function()
    promptInput("Destination (e.g. Ender Chest)", settings.output or "", function(v)
      settings.output = v or ""
      saveSettings()
    end)
  end, colors.cyan)

  local addToKitBtn = button(t, 46, 13, 22, "+ Add to Kit", function()
    local allKits = kitList()
    if #allKits == 0 then
      createKit()
    end
    promptInput("Kit name to add to", selectedKit or (allKits[1] and allKits[1].name) or "Kit 1", function(targetName)
      if targetName and targetName ~= "" then
        if not settings.kits[targetName] then
          settings.kits[targetName] = { name = targetName, output = settings.output or "", items = {} }
        end
        selectedKit = targetName
        addSelectedItemToKit(targetName, requestQty)
      end
    end)
  end, colors.yellow, colors.black)

  table.insert(monitorClicks, deliverBtn)
  table.insert(monitorClicks, destBtn)
  table.insert(monitorClicks, addToKitBtn)

  put(t, 2, 16, "Current destination: " .. tostring(settings.output ~= "" and settings.output or "not set"), colors.white, colors.black)
  put(t, 2, 18, "Request helpers", colors.lime, colors.black)
  put(t, 2, 19, "Use '+ Add to Kit' to bundle items together and send them to your Ender Chest.", colors.lightGray, colors.black)
end

local function drawKitsTab(t, w, h)
  fillRect(t, 1, 5, w, h - 4, colors.black)
  put(t, 2, 6, "Kits (Bundle multiple items for delivery)", colors.lime, colors.black)

  local list = kitList()
  local startIndex = (kitPage - 1) * PAGE_SIZE + 1
  local totalPages = math.max(1, math.ceil(#list / PAGE_SIZE))
  kitPage = clamp(kitPage, 1, totalPages)

  local y = 8
  for i = startIndex, math.min(#list, startIndex + PAGE_SIZE - 1) do
    local kit = list[i]
    local key = kit.key
    local bg = selectedKit == key and colors.green or colors.black
    local fg = selectedKit == key and colors.black or colors.white
    fillRect(t, 2, y, math.floor(w * 0.45), 1, bg)
    put(t, 3, y, kit.name or key, fg, bg, math.floor(w * 0.45) - 2)
    put(t, math.floor(w * 0.50), y, "Dest: " .. tostring((kit.output ~= "" and kit.output) or (settings.output ~= "" and settings.output) or "not set"), colors.white, colors.black, math.floor(w * 0.22))
    put(t, math.floor(w * 0.74), y, "Items: " .. fmt((kit.items and #kit.items) or 0), colors.white, colors.black, math.floor(w * 0.20))
    table.insert(monitorClicks, { x = 2, y = y, w = math.floor(w * 0.45), h = 1, fn = function()
      selectedKit = key
      saveSettings()
    end })
    table.insert(monitorClicks, { x = math.floor(w * 0.50), y = y, w = math.floor(w * 0.45), h = 1, fn = function()
      selectedKit = key
      saveSettings()
      transferKit(key)
    end })
    y = y + 2
  end

  if #list == 0 then
    put(t, 2, 8, "No kits yet. Tap 'New' below.", colors.lightGray, colors.black)
  end

  local prevRect = button(t, 2, h - 2, 12, "< Previous", function()
    kitPage = math.max(1, kitPage - 1)
    saveSettings()
  end)
  local nextRect = button(t, 15, h - 2, 9, "Next >", function()
    kitPage = math.min(totalPages, kitPage + 1)
    saveSettings()
  end)
  table.insert(monitorClicks, prevRect)
  table.insert(monitorClicks, nextRect)

  local newBtn = button(t, 26, h - 2, 10, "New", function() createKit() end, colors.green)
  local renameBtn = button(t, 37, h - 2, 10, "Rename", function()
    if not selectedKit then return end
    promptInput("Rename kit", selectedKit, function(v)
      if v and v ~= "" then renameKit(selectedKit, v) end
    end)
  end, colors.cyan)
  local addBtn = button(t, 48, h - 2, 16, "Add item", function()
    if not selectedKit then setMessage("Select a kit first."); return end
    local item = getItem(selectedKey)
    if not item then setMessage("Select an inventory item first."); return end
    promptInput("Add amount to kit", tostring(requestQty), function(v)
      local n = tonumber(v)
      if n and n >= 1 then addSelectedItemToKit(selectedKit, n) end
    end)
  end, colors.yellow, colors.black)
  local destBtn = button(t, 65, h - 2, 16, "Set Output", function()
    if not selectedKit then return end
    promptInput("Kit output / Ender Chest", settings.kits[selectedKit] and settings.kits[selectedKit].output or settings.output or "", function(v)
      if settings.kits[selectedKit] then
        settings.kits[selectedKit].output = v or ""
        saveSettings()
      end
    end)
  end, colors.lightGray, colors.black)

  table.insert(monitorClicks, newBtn)
  table.insert(monitorClicks, renameBtn)
  table.insert(monitorClicks, addBtn)
  table.insert(monitorClicks, destBtn)

  local kit = selectedKit and settings.kits[selectedKit] or nil
  if kit then
    local outText = (kit.output ~= "" and kit.output) or (settings.output ~= "" and settings.output .. " (default)") or "not set"
    put(t, 2, 22, "Selected kit: " .. tostring(kit.name) .. "  |  Destination: " .. outText, colors.lime, colors.black)
    put(t, 2, 23, "Kit Contents:", colors.white, colors.black)
    local sy = 24
    for i = 1, math.min(7, #(kit.items or {})) do
      local entry = kit.items[i]
      put(t, 2, sy, "• " .. tostring(entry.amount) .. "x " .. tostring(entry.name or entry.id or entry.itemKey), colors.lightGray, colors.black, w - 4)
      sy = sy + 1
    end
    if #(kit.items or {}) == 0 then
      put(t, 2, 24, "Empty kit. Select an item in Inventory or Requests and tap 'Add item'.", colors.lightGray, colors.black)
    end

    local deliverKitBtn = button(t, 2, 32, 18, "Deliver Kit", function()
      transferKit(selectedKit)
    end, colors.green, colors.black)

    local delBtn = button(t, 22, 32, 16, "Delete kit", function()
      deleteKit(selectedKit)
    end, colors.red, colors.white)

    table.insert(monitorClicks, deliverKitBtn)
    table.insert(monitorClicks, delBtn)
  end
end

local function drawPeripheralsTab(t, w, h)
  fillRect(t, 1, 5, w, h - 4, colors.black)
  put(t, 2, 6, "Peripheral diagnostics", colors.lime, colors.black)
  put(t, 2, 7, "Auto-source is enabled: every readable inventory is used.", colors.lightGray, colors.black)
  local y = 9
  for _, d in ipairs(devices) do
    if y > h - 4 then break end
    put(t, 2, y, d.name .. " (" .. d.type .. ")" .. (d.inventory and " [inventory]" or ""), colors.white, colors.black, w - 4)
    y = y + 1
  end
  for scannerId, rec in pairs(scanners) do
    if y > h - 4 then break end
    put(t, 2, y, "scanner ID #" .. tostring(scannerId) .. ": " .. tostring(rec.name) .. " (" .. tostring(#(rec.items or {})) .. " items)", colors.yellow, colors.black, w - 4)
    y = y + 1
  end
end

local function drawDebugTab(t, w, h)
  fillRect(t, 1, 5, w, h - 4, colors.black)
  put(t, 2, 6, "Debug tab", colors.yellow, colors.black)
  put(t, 2, 7, "Delivery log:", colors.lime, colors.black)

  local y = 8
  if #settings.deliveryLog == 0 then
    put(t, 2, y, "No deliveries yet.", colors.lightGray, colors.black)
    y = y + 1
  else
    for i = 1, math.min(#settings.deliveryLog, 8) do
      put(t, 2, y, settings.deliveryLog[i], colors.white, colors.black, w - 4)
      y = y + 1
    end
  end

  y = y + 1
  put(t, 2, y, "Debug messages:", colors.lime, colors.black)
  y = y + 1
  if #debugLines == 0 then
    put(t, 2, y, "No debug lines yet.", colors.lightGray, colors.black)
  else
    for i = 1, math.min(#debugLines, 10) do
      put(t, 2, y, debugLines[i], colors.lightGray, colors.black, w - 4)
      y = y + 1
    end
  end
end

-- =========================================================
-- Network Tab (Showing all Connections)
-- =========================================================

local function drawNetworkTab(t, w, h)
  fillRect(t, 1, 5, w, h - 4, colors.black)
  put(t, 2, 6, "Network Status & Connections", colors.lime, colors.black)
  put(t, 2, 7, "Rednet Server: " .. HOSTNAME .. " | Protocol: " .. SERVICE_TYPE, colors.lightGray, colors.black)
  put(t, 2, 8, "Status: " .. tostring(settings.networkEnabled and "ENABLED" or "DISABLED") .. " (" .. tostring(settings.networkStatus or "unknown") .. ")", colors.white, colors.black)
  put(t, 2, 9, "Modem: " .. tostring(settings.networkModem ~= "" and settings.networkModem or "auto"), colors.white, colors.black)

  local btn1 = blackOutlineButton(t, 2, 11, 18, settings.networkEnabled and "Disable" or "Enable", function()
    settings.networkEnabled = not settings.networkEnabled
    if settings.networkEnabled then
      ensureRednet()
      setMessage("Network enabled.")
    else
      settings.networkStatus = "disabled"
      setMessage("Network disabled.")
    end
    saveSettings()
  end, settings.networkEnabled and colors.red or colors.green, colors.white, 3)

  local btn2 = blackOutlineButton(t, 22, 11, 18, "Set Username", function()
    promptInput("Network username", settings.networkUser or "", function(v)
      settings.networkUser = v or ""
      saveSettings()
    end)
  end, colors.cyan, colors.black, 3)

  local btn3 = blackOutlineButton(t, 42, 11, 18, "Set Password", function()
    promptInput("Network password", settings.networkPassword or "", function(v)
      settings.networkPassword = v or ""
      saveSettings()
    end)
  end, colors.yellow, colors.black, 3)

  local btn4 = blackOutlineButton(t, 62, 11, 18, "Set Modem", function()
    promptInput("Modem name (blank=auto)", settings.networkModem or "", function(v)
      settings.networkModem = v or ""
      saveSettings()
      ensureRednet()
    end)
  end, colors.lightGray, colors.black, 3)

  table.insert(monitorClicks, btn1)
  table.insert(monitorClicks, btn2)
  table.insert(monitorClicks, btn3)
  table.insert(monitorClicks, btn4)

  -- Connections Table Header
  fillRect(t, 2, 15, w - 4, 1, colors.gray)
  put(t, 3, 15, "ID", colors.yellow, colors.gray, 6)
  put(t, 10, 15, "DEVICE / CLIENT NAME", colors.yellow, colors.gray, 26)
  put(t, 38, 15, "TYPE", colors.yellow, colors.gray, 16)
  put(t, 56, 15, "STATUS", colors.yellow, colors.gray, 14)
  put(t, 72, 15, "LAST SEEN", colors.yellow, colors.gray, 14)

  local clientList = {}
  for _, c in pairs(connectedClients) do
    clientList[#clientList + 1] = c
  end
  table.sort(clientList, function(a, b) return a.id < b.id end)

  local y = 17
  local now = nowTime()

  if #clientList == 0 then
    put(t, 3, y, "No active connections detected.", colors.lightGray, colors.black)
  else
    for _, c in ipairs(clientList) do
      if y > h - 2 then break end
      local age = math.floor(now - (c.lastSeen or now))
      local statusText = age < 30 and "CONNECTED" or "IDLE"
      local statusColor = age < 30 and colors.lime or colors.yellow

      fillRect(t, 2, y, w - 4, 1, colors.black)
      put(t, 3, y, "#" .. tostring(c.id), colors.white, colors.black, 6)
      put(t, 10, y, tostring(c.label), colors.white, colors.black, 26)
      put(t, 38, y, tostring(c.type), colors.cyan, colors.black, 16)
      put(t, 56, y, statusText, statusColor, colors.black, 14)
      put(t, 72, y, tostring(age) .. "s ago", colors.lightGray, colors.black, 14)

      y = y + 1
    end
  end
end

local function drawRequestsTab(t, w, h)
  fillRect(t, 1, 5, w, h - 4, colors.black)
  local nbtn = button(t, 2, 6, 14, "Normal", function()
    requestSubTab = "Normal"; saveSettings()
  end, requestSubTab == "Normal" and colors.green or colors.gray, colors.white)
  local kbtn = button(t, 17, 6, 8, "Kits", function()
    requestSubTab = "Kits"; saveSettings()
  end, requestSubTab == "Kits" and colors.green or colors.gray, colors.white)
  table.insert(monitorClicks, nbtn)
  table.insert(monitorClicks, kbtn)

  if requestSubTab == "Normal" then
    drawRequestsNormal(t, w, h)
  else
    drawKitsTab(t, w, h)
  end
end

local function renderMonitor()
  if not monitor then return end
  local t = monitor
  local w, h = t.getSize()
  fillRect(t, 1, 1, w, h, colors.black)
  drawHeader(t, w)

  if selectedTab == "Inventory" then
    drawInventoryPage(t, w, h)
  elseif selectedTab == "Requests" then
    drawRequestsTab(t, w, h)
  elseif selectedTab == "Favorites" then
    fillRect(t, 1, 5, w, h - 4, colors.black)
    put(t, 2, 6, "Favorites", colors.lime, colors.black)
    local fav = {}
    for _, item in ipairs(items) do
      if isFavorite(item.key) then fav[#fav + 1] = item end
    end
    if #fav == 0 then
      put(t, 2, 8, "No favorites yet.", colors.lightGray, colors.black)
    else
      local y = 8
      for _, item in ipairs(fav) do
        if y > h - 3 then break end
        local r = button(t, 2, y, math.floor(w * 0.6), "★ " .. getDisplayName(item), function()
          selectedKey = item.key
          selectedTab = "Inventory"
          saveSettings()
        end, colors.black)
        table.insert(monitorClicks, r)
        put(t, math.floor(w * 0.65), y, "Count: " .. fmt(item.total), colors.white, colors.black)
        y = y + 2
      end
    end
  elseif selectedTab == "Peripherals" then
    drawPeripheralsTab(t, w, h)
  elseif selectedTab == "Kits" then
    drawKitsTab(t, w, h)
  elseif selectedTab == "Debug" then
    drawDebugTab(t, w, h)
  elseif selectedTab == "Network" then
    drawNetworkTab(t, w, h)
  end

  if inputMode then
    fillRect(t, 1, h, w, 1, colors.black)
    put(t, 2, h, inputMode.title .. ": " .. inputBuffer, colors.yellow, colors.black, w - 4)
    t.setCursorPos(math.min(w, 4 + #inputBuffer), h)
    t.setCursorBlink(true)
  else
    put(t, 2, h, message, colors.gray, colors.black, w - 4)
    t.setCursorBlink(false)
  end
end

local function clickAction(x, y, target)
  if target == "computer" then
    for _, r in ipairs(computerClicks) do
      if rectHit(x, y, r) then
        if r.fn then r.fn() end
        return true
      end
    end
  elseif target == "monitor" then
    for _, r in ipairs(monitorClicks) do
      if rectHit(x, y, r) then
        if r.fn then r.fn() end
        return true
      end
    end
  end
  return false
end

-- =========================================================
-- Concurrent Network Loop
-- =========================================================

local function networkLoop()
  while true do
    if settings.networkEnabled then
      ensureRednet()

      local sender, msg = rednet.receive(SERVICE_TYPE, 0.1)
      if sender and type(msg) == "table" then
        local mtype = tostring(msg.type or msg.command or "")

        if SCANNER_MESSAGE_TYPES[mtype] then
          local reply = handleScannerPacket(sender, msg)
          if reply then
            rednet.send(sender, reply, SERVICE_TYPE)
          end

        elseif msg.type == "auth" then
          local ok, reason = networkAuthenticate(msg)
          if ok then
            registerClient(sender, "Pocket Computer", msg.username or ("pocket_" .. tostring(sender)))
          end
          rednet.send(sender, {
            type = "auth_result",
            ok = ok,
            reason = reason,
            server = HOSTNAME
          }, SERVICE_TYPE)

        elseif msg.type == "search" then
          local ok = select(1, networkAuthenticate(msg))
          if not ok then
            rednet.send(sender, {
              type = "reply",
              ok = false,
              error = "auth required",
              server = HOSTNAME
            }, SERVICE_TYPE)
          else
            registerClient(sender, "Pocket Computer", msg.username or ("pocket_" .. tostring(sender)))
            local reply = networkSearch(msg)
            rednet.send(sender, {
              type = "reply",
              ok = true,
              result = reply.result or {},
              server = HOSTNAME
            }, SERVICE_TYPE)
          end

        elseif msg.type == "request" then
          local ok = select(1, networkAuthenticate(msg))
          if not ok then
            rednet.send(sender, {
              type = "reply",
              ok = false,
              error = "auth required",
              server = HOSTNAME
            }, SERVICE_TYPE)
          else
            registerClient(sender, "Pocket Computer", msg.username or ("pocket_" .. tostring(sender)))
            local reply = networkRequest(msg)
            rednet.send(sender, {
              type = "reply",
              ok = reply and reply.ok or false,
              result = reply and reply.result or nil,
              moved = reply and reply.moved or nil,
              item = reply and reply.item or nil,
              output = reply and reply.output or nil,
              error = reply and reply.error or nil,
              server = HOSTNAME
            }, SERVICE_TYPE)
          end
        end
      end

      cleanupStaleClients()
    end

    sleep(0.05)
  end
end

-- =========================================================
-- Main Startup & Event Dispatcher
-- =========================================================

loadSettings()
discoverDevices()
chooseMonitor()
rebuildGlobalIndex()
ensureRednet()

local function render()
  drawComputerPanel()
  if monitor then
    local ok, err = pcall(renderMonitor)
    if not ok then
      monitor = nil
      monitorName = nil
      setMessage("Monitor error: " .. tostring(err))
    end
  end
end

render()

local refreshTimer = os.startTimer(math.max(1, settings.refreshInterval or 10))

parallel.waitForAny(function()
  while true do
    render()
    local event, a, b, c = os.pullEvent()

    if event == "mouse_click" then
      clickAction(b, c, "computer")
      render()
    elseif event == "monitor_touch" then
      if a == monitorName then
        clickAction(b, c, "monitor")
        render()
      end
    elseif event == "char" then
      if inputMode then
        inputBuffer = inputBuffer .. a
        render()
      elseif a == "/" then
        selectedTab = "Inventory"
        promptInput("Search", query, function(v)
          query = v or ""
          page = 1
          saveSettings()
        end)
        render()
      end
    elseif event == "key" then
      if inputMode then
        if a == keys.enter then
          local mode = inputMode
          local value = inputBuffer
          clearInput()
          if mode.callback then mode.callback(value) end
          saveSettings()
          rebuildGlobalIndex()
        elseif a == keys.backspace then
          inputBuffer = inputBuffer:sub(1, -2)
        elseif a == keys.escape then
          clearInput()
        end
        render()
      else
        if a == keys.slash then
          selectedTab = "Inventory"
          promptInput("Search", query, function(v)
            query = v or ""
            page = 1
            saveSettings()
          end)
          render()
        elseif a == keys.f5 or a == keys.f6 then
          discoverDevices()
          chooseMonitor()
          rebuildGlobalIndex()
          ensureRednet()
          setMessage("Refreshed.")
          render()
        elseif a == keys.tab then
          if selectedTab == "Inventory" then selectedTab = "Requests"
          elseif selectedTab == "Requests" then selectedTab = "Favorites"
          elseif selectedTab == "Favorites" then selectedTab = "Peripherals"
          elseif selectedTab == "Peripherals" then selectedTab = "Kits"
          elseif selectedTab == "Kits" then selectedTab = "Debug"
          elseif selectedTab == "Debug" then selectedTab = "Network"
          else selectedTab = "Inventory" end
          saveSettings()
          render()
        elseif a == keys.left then
          if selectedTab == "Inventory" or selectedTab == "Favorites" then
            page = math.max(1, page - 1)
          elseif (selectedTab == "Requests" and requestSubTab == "Kits") or selectedTab == "Kits" then
            kitPage = math.max(1, kitPage - 1)
          end
          render()
        elseif a == keys.right then
          if selectedTab == "Inventory" or selectedTab == "Favorites" then
            page = page + 1
          elseif (selectedTab == "Requests" and requestSubTab == "Kits") or selectedTab == "Kits" then
            kitPage = kitPage + 1
          end
          render()
        end
      end
    elseif event == "timer" and a == refreshTimer then
      discoverDevices()
      chooseMonitor()
      rebuildGlobalIndex()
      ensureRednet()
      refreshTimer = os.startTimer(math.max(1, settings.refreshInterval or 10))
      render()
    elseif event == "peripheral" or event == "peripheral_detach" then
      discoverDevices()
      chooseMonitor()
      rebuildGlobalIndex()
      ensureRednet()
      render()
    elseif event == "term_resize" then
      render()
    end
  end
end, networkLoop)
