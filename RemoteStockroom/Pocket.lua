local PROTOCOL = "CHANGEME"
local HOSTNAME = "CHANGEME"
local SETTINGS_FILE = "settings"

local settings = {
  username = "",
  password = "",
  search = "",
  selectedTab = "Items",
  selectedKey = nil,
  requestQty = 1,
  favorites = {},
  itemCache = {}
}

local cache = {}
local favorites = {}
local selectedKey = nil
local scroll = 0
local message = "Ready."
local inputMode = false
local inputBuffer = ""
local inputTitle = nil
local inputCallback = nil
local pingTimer = nil

local uiButtons = {}
local serverID = nil

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
  favorites = settings.favorites or {}
  cache = settings.itemCache or {}
end

local function saveSettings()
  settings.favorites = favorites
  settings.itemCache = cache
  local f = fs.open(SETTINGS_FILE, "w")
  if not f then return end
  f.write(textutils.serialize(settings))
  f.close()
end

local function setMessage(msg)
  message = tostring(msg or "")
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
  put(t, x + math.max(0, math.floor((ww - #label) / 2)), y, label, fg or colors.white, bg or colors.gray)
  local r = { x = x, y = y, w = ww, h = 1, fn = fn }
  uiButtons[#uiButtons + 1] = r
  return r
end

local function rectHit(x, y, r)
  return x >= r.x and x <= r.x + r.w - 1 and y >= r.y and y <= r.y + r.h - 1
end

local function promptInput(title, default, callback)
  inputMode = true
  inputTitle = title
  inputBuffer = default or ""
  inputCallback = callback
  setMessage("Type text, Enter to save, Esc to cancel.")
end

local function clearInput()
  inputMode = false
  inputTitle = nil
  inputBuffer = ""
  inputCallback = nil
end

local function openRednet()
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then
        pcall(rednet.open, side)
      end
      return side
    end
  end
  return nil
end

local function findServer()
  serverID = rednet.lookup(PROTOCOL, HOSTNAME)
  return serverID
end

local function sendPacket(payload, timeout)
  timeout = timeout or 8
  local id = serverID or findServer()
  if not id then return nil, "Server not found" end

  payload.username = settings.username
  payload.password = settings.password
  rednet.send(id, payload, PROTOCOL)

  local deadline = os.clock() + timeout
  while os.clock() < deadline do
    local remaining = math.max(0.05, deadline - os.clock())
    local sender, msg, proto = rednet.receive(PROTOCOL, remaining)
    if sender == id and proto == PROTOCOL then
      return msg
    end
  end

  serverID = nil
  return nil, "Timed out"
end

local function authenticate()
  local reply = sendPacket({ type = "auth" }, 4)
  if reply and type(reply) == "table" and reply.type == "auth_result" and reply.ok then
    setMessage("Auth OK")
    return true
  end
  setMessage("Auth failed")
  return false
end

local function sendPing()
  local id = serverID or findServer()
  if not id then return false end
  rednet.send(id, {
    type = "ping",
    username = settings.username,
    password = settings.password
  }, PROTOCOL)
  return true
end

local function mergeCache(newItems)
  local newMap = {}
  local changed = false

  for _, item in ipairs(newItems or {}) do
    if item and item.key then
      local key = tostring(item.key)
      newMap[key] = true

      local old = cache[key]
      local newName = item.name or item.id or key
      local newTotal = tonumber(item.total) or 0
      local newColor = item.lineColor or colors.white

      if not old or old.name ~= newName or tonumber(old.total or 0) ~= newTotal or old.lineColor ~= newColor then
        changed = true
      end

      cache[key] = {
        key = key,
        name = newName,
        id = item.id or newName,
        total = newTotal,
        lineColor = newColor
      }
    end
  end

  for k in pairs(cache) do
    if not newMap[k] then
      cache[k] = nil
      changed = true
    end
  end

  return changed
end

local function refreshInventory()
  local reply, err = sendPacket({
    type = "search",
    query = settings.search or ""
  }, 6)

  local items = nil
  if reply and type(reply) == "table" then
    if reply.type == "reply" and reply.ok and type(reply.result) == "table" then
      items = reply.result
    elseif reply.ok and type(reply.result) == "table" then
      items = reply.result
    elseif reply.ok and type(reply.items) == "table" then
      items = reply.items
    end
  end

  if type(items) == "table" then
    local changed = mergeCache(items)
    if changed then saveSettings() end
    local count = 0
    for _ in pairs(cache) do count = count + 1 end
    setMessage("Items: " .. tostring(count))
  else
    setMessage(err or "No items found.")
  end
end

local function allItems()
  local list = {}
  for _, item in pairs(cache) do
    list[#list + 1] = item
  end
  table.sort(list, function(a, b)
    if a.name == b.name then return a.key < b.key end
    return a.name < b.name
  end)
  return list
end

local function filteredItems()
  local list = {}
  local query = tostring(settings.search or ""):lower()

  for _, item in ipairs(allItems()) do
    local favOK = settings.selectedTab ~= "Favs" or favorites[item.key]
    local hay = (tostring(item.name or "") .. " " .. tostring(item.id or "") .. " " .. tostring(item.key or "")):lower()
    if favOK and (query == "" or hay:find(query, 1, true)) then
      list[#list + 1] = item
    end
  end

  return list
end

local function getSelectedItem()
  if selectedKey and cache[tostring(selectedKey)] then
    return cache[tostring(selectedKey)]
  end
  return nil
end

local function toggleFavorite(key)
  key = tostring(key)
  favorites[key] = not favorites[key] or nil
  saveSettings()
end

local function requestSelected()
  local item = getSelectedItem()
  if not item then
    setMessage("Select an item first.")
    return
  end

  local qty = tonumber(settings.requestQty) or 1
  setMessage("Requesting...")

  local reply, err = sendPacket({
    type = "request",
    key = item.key,
    qty = qty,
    output = ""
  }, 12)

  if reply and type(reply) == "table" and reply.ok then
    if reply.moved and tonumber(reply.moved) and tonumber(reply.moved) > 0 then
      setMessage("Moved " .. tostring(reply.moved) .. " items.")
    else
      setMessage("Request sent.")
    end
    refreshInventory()
  else
    setMessage((reply and reply.error) or err or "Request failed.")
  end
end

local function drawHeader()
  local t = term.current()
  local w, _ = t.getSize()
  fillRect(t, 1, 1, w, 1, colors.blue)
  put(t, 2, 1, "Pocket Stockroom", colors.white, colors.blue)

  fillRect(t, 1, 2, w, 1, colors.lightGray)
  put(t, 2, 2, "Search: " .. tostring(settings.search or ""), colors.black, colors.lightGray, math.max(6, w - 12))

  button(t, math.max(2, w - 6), 2, 5, "Fav", function()
    settings.selectedTab = "Favs"
    saveSettings()
  end, settings.selectedTab == "Favs" and colors.orange or colors.gray, colors.white)

  fillRect(t, 1, 3, w, 1, colors.black)
  button(t, 2, 3, 12, "Items", function()
    settings.selectedTab = "Items"
    saveSettings()
  end, settings.selectedTab == "Items" and colors.green or colors.gray, colors.white)

  button(t, 15, 3, 10, "Request", function()
    settings.selectedTab = "Req"
    saveSettings()
  end, settings.selectedTab == "Req" and colors.green or colors.gray, colors.white)
end

local function drawItemsTab()
  local t = term.current()
  local w, h = t.getSize()
  local list = filteredItems()
  local startY = 5
  local maxRows = h - 6
  local maxScroll = math.max(0, #list - maxRows)
  scroll = math.max(0, math.min(scroll, maxScroll))

  if #list == 0 then
    put(t, 2, 5, "No items found.", colors.lightGray, colors.black)
    put(t, 2, 7, "Press F5 to refresh.", colors.gray, colors.black)
    return
  end

  local y = startY
  for i = scroll + 1, math.min(#list, scroll + maxRows) do
    local item = list[i]
    local bg = tostring(settings.selectedKey) == tostring(item.key) and colors.green or colors.black
    local fg = bg == colors.green and colors.black or colors.white

    fillRect(t, 1, y, w, 1, bg)
    local isFav = favorites[tostring(item.key)]
    put(t, 2, y, (isFav and "★ " or "") .. tostring(item.name or item.id or item.key or "Unknown"), fg, bg, math.floor(w * 0.82))
    put(t, math.floor(w * 0.84), y, "x" .. tostring(item.total or 0), fg, bg, 7)

    if y + 1 <= h - 1 then
      fillRect(t, 1, y + 1, w, 1, item.lineColor or colors.white)
    end

    y = y + 2
    if y > h - 1 then break end
  end

  put(t, 2, h, "F5 refresh | wheel scroll | tap item to request", colors.gray, colors.black, w - 4)
end

local function drawRequestTab()
  local t = term.current()
  local w, h = t.getSize()
  fillRect(t, 1, 5, w, h - 4, colors.black)

  local item = getSelectedItem()
  if not item then
    put(t, 2, 5, "Tap an item in Items first.", colors.lightGray, colors.black)
    return
  end

  local isFav = favorites[tostring(item.key)]
  put(t, 2, 5, "Item: " .. (isFav and "★ " or "") .. tostring(item.name or item.id or item.key), colors.white, colors.black, w - 4)
  put(t, 2, 6, "Available: " .. tostring(item.total or 0), colors.white, colors.black)
  put(t, 2, 7, "Qty selected: " .. tostring(settings.requestQty or 1), colors.white, colors.black)

  button(t, 2, 9, 12, "Qty: 1", function()
    settings.requestQty = 1
    saveSettings()
    setMessage("Quantity set to 1.")
  end, colors.gray, colors.white)

  button(t, 15, 9, 14, "Custom", function()
    promptInput("Custom quantity", tostring(settings.requestQty or 1), function(v)
      local n = tonumber(v)
      if n and n >= 1 then
        settings.requestQty = math.floor(n)
        saveSettings()
        setMessage("Quantity set to " .. tostring(settings.requestQty))
      end
    end)
  end, colors.cyan, colors.black)

  button(t, 2, 12, 22, "Send Request", function()
    requestSelected()
  end, colors.green, colors.black)

  local favLabel = isFav and "★ Remove Fav" or "★ Add Favorite"
  button(t, 2, 14, 22, favLabel, function()
    toggleFavorite(item.key)
    setMessage(favorites[tostring(item.key)] and "Added to favorites." or "Removed from favorites.")
  end, isFav and colors.yellow or colors.gray, isFav and colors.black or colors.white)

  put(t, 2, h, message, colors.gray, colors.black, w - 4)
end

local function drawFavoritesTab()
  local t = term.current()
  local w, h = t.getSize()
  local list = {}
  for _, item in ipairs(allItems()) do
    if favorites[item.key] then
      list[#list + 1] = item
    end
  end

  fillRect(t, 1, 5, w, h - 4, colors.black)
  put(t, 2, 5, "Favorites", colors.orange, colors.black)

  if #list == 0 then
    put(t, 2, 7, "No favorites yet.", colors.lightGray, colors.black)
    return
  end

  local y = 7
  for i = 1 + scroll, math.min(#list, scroll + (h - 8)) do
    local item = list[i]
    fillRect(t, 1, y, w, 1, colors.black)
    put(t, 2, y, "★ " .. tostring(item.name or item.key), colors.white, colors.black, math.floor(w * 0.8))
    y = y + 1
    if y > h - 1 then break end
  end
end

local function drawInputLine()
  local t = term.current()
  local w, h = t.getSize()
  if inputMode then
    fillRect(t, 1, h, w, 1, colors.black)
    put(t, 2, h, tostring(inputTitle or "Input") .. ": " .. inputBuffer, colors.yellow, colors.black, w - 4)
    t.setCursorPos(math.min(w, 4 + #inputBuffer), h)
    t.setCursorBlink(true)
  else
    t.setCursorBlink(false)
  end
end

local function draw()
  local t = term.current()
  local w, h = t.getSize()
  fillRect(t, 1, 1, w, h, colors.black)
  uiButtons = {}
  drawHeader()

  if settings.selectedTab == "Req" then
    drawRequestTab()
  elseif settings.selectedTab == "Favs" then
    drawFavoritesTab()
  else
    drawItemsTab()
  end

  if not inputMode then
    put(t, 2, h, message, colors.gray, colors.black, w - 4)
  end
  drawInputLine()
end

local function handleTouch(x, y)
  if inputMode then return end

  local w = term.getSize()

  if y == 2 then
    if x >= math.max(2, w - 6) then
      settings.selectedTab = "Favs"
      saveSettings()
      draw()
      return
    end
    promptInput("Search", settings.search or "", function(v)
      settings.search = v or ""
      saveSettings()
      refreshInventory()
    end)
    draw()
    return
  end

  if y == 3 then
    if x >= 2 and x <= 13 then
      settings.selectedTab = "Items"
      saveSettings()
    elseif x >= 15 and x <= 24 then
      settings.selectedTab = "Req"
      saveSettings()
    end
    draw()
    return
  end

  if settings.selectedTab == "Items" then
    local list = filteredItems()
    local idx = math.floor((y - 5) / 2) + 1 + scroll
    if list[idx] then
      if x == 1 then
        toggleFavorite(list[idx].key)
        draw()
        return
      end
      settings.selectedKey = list[idx].key
      selectedKey = list[idx].key
      settings.selectedTab = "Req"
      saveSettings()
      draw()
      return
    end
  elseif settings.selectedTab == "Req" then
    local item = getSelectedItem()
    if not item then return end

    if rectHit(x, y, { x = 2, y = 9, w = 12, h = 1 }) then
      settings.requestQty = 1
      saveSettings()
      setMessage("Quantity set to 1.")
      draw()
      return
    end

    if rectHit(x, y, { x = 15, y = 9, w = 14, h = 1 }) then
      promptInput("Custom quantity", tostring(settings.requestQty or 1), function(v)
        local n = tonumber(v)
        if n and n >= 1 then
          settings.requestQty = math.floor(n)
          saveSettings()
          setMessage("Quantity set to " .. tostring(settings.requestQty))
        end
      end)
      draw()
      return
    end

    if rectHit(x, y, { x = 2, y = 12, w = 22, h = 1 }) then
      requestSelected()
      draw()
      return
    end

    if rectHit(x, y, { x = 2, y = 14, w = 22, h = 1 }) then
      toggleFavorite(item.key)
      setMessage(favorites[tostring(item.key)] and "Added to favorites." or "Removed from favorites.")
      draw()
      return
    end
  elseif settings.selectedTab == "Favs" then
    local list = {}
    for _, item in ipairs(allItems()) do
      if favorites[item.key] then list[#list + 1] = item end
    end
    local idx = y - 6 + scroll
    if list[idx] then
      settings.selectedKey = list[idx].key
      selectedKey = list[idx].key
      settings.selectedTab = "Req"
      saveSettings()
      draw()
      return
    end
  end
end

local function handleKey(k)
  if inputMode then
    if k == keys.enter then
      local cb = inputCallback
      local val = inputBuffer
      clearInput()
      if cb then cb(val) end
      saveSettings()
      refreshInventory()
    elseif k == keys.backspace then
      inputBuffer = inputBuffer:sub(1, -2)
    elseif k == keys.escape then
      clearInput()
    end
    draw()
    return
  end

  if k == keys.f5 or k == keys.f6 then
    serverID = nil
    authenticate()
    refreshInventory()
    draw()
  elseif k == keys.left then
    scroll = math.max(0, scroll - 1)
    draw()
  elseif k == keys.right then
    scroll = scroll + 1
    draw()
  elseif k == keys.tab then
    if settings.selectedTab == "Items" then
      settings.selectedTab = "Req"
    elseif settings.selectedTab == "Req" then
      settings.selectedTab = "Favs"
    else
      settings.selectedTab = "Items"
    end
    saveSettings()
    draw()
  end
end

local function init()
  loadSettings()
  if not openRednet() then
    error("No modem attached.")
  end

  authenticate()
  refreshInventory()
  draw()
  pingTimer = os.startTimer(10)
end

init()

while true do
  local event, a, b, c = os.pullEvent()

  if event == "mouse_click" then
    handleTouch(b, c)

  elseif event == "mouse_scroll" then
    if settings.selectedTab == "Items" or settings.selectedTab == "Favs" then
      scroll = math.max(0, scroll + a)
      draw()
    end

  elseif event == "char" then
    if inputMode then
      inputBuffer = inputBuffer .. a
      draw()
    end

  elseif event == "key" then
    handleKey(a)

  elseif event == "timer" and a == pingTimer then
    sendPing()
    pingTimer = os.startTimer(10)

  elseif event == "term_resize" then
    draw()
  end
end
