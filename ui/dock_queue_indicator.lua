local ffi = require("ffi")
local C = ffi.C

ffi.cdef [[
  typedef uint64_t UniverseID;
  UniverseID GetPlayerID(void);
]]

local dqi = {
  configBlackboard = "$DockQueueIndicatorConfig",
  countsBlackboard = "$DockQueueCounts",
  shipsBlackboard = "$DockQueueShips",
  textPage = 1972092443,
  icon = "dqi_dockqueue",
  debugLevel = "none",
  enabled = true,
  greenMax = 2,
  yellowMax = 5,
  counts = {},
  ships = {},
  pendingHover = nil,
  playerId = nil,
}

local function write(message, ...)
  if select("#", ...) > 0 then
    message = string.format(message, ...)
  end
  DebugError("DockQueueIndicator: " .. message)
end

function dqi.Error(message, ...) write(message, ...) end
function dqi.Debug(message, ...) if dqi.debugLevel ~= "none" then write(message, ...) end end
function dqi.Trace(message, ...) if dqi.debugLevel == "trace" then write(message, ...) end end

-- MD booleans arrive as true or 1, false as 0.
local function boolOf(value)
  return value == true or value == 1
end

function dqi.ReadConfig()
  local config = GetNPCBlackboard(dqi.playerId, dqi.configBlackboard)
  if type(config) ~= "table" then
    return
  end
  if config.debugLevel then
    dqi.debugLevel = tostring(config.debugLevel)
  end
  if config.enabled ~= nil then
    dqi.enabled = boolOf(config.enabled)
  end
  dqi.greenMax = math.floor(tonumber(config.greenMax) or dqi.greenMax)
  dqi.yellowMax = math.floor(tonumber(config.yellowMax) or dqi.yellowMax)
  if dqi.yellowMax < dqi.greenMax then
    dqi.yellowMax = dqi.greenMax
  end
  dqi.Debug("config: enabled %s, green up to %d, yellow up to %d, debug level %s",
    tostring(dqi.enabled), dqi.greenMax, dqi.yellowMax, dqi.debugLevel)
end

function dqi.ColorFor(count)
  if count <= dqi.greenMax then
    return Color["text_positive"]
  elseif count <= dqi.yellowMax then
    return Color["text_warning"]
  end
  return Color["text_error"]
end

-- Once per list build: the config and what MD publishes per station idcode.
function dqi.OnInitInfoTableData(_infoTableData)
  dqi.counts = {}
  dqi.ships = {}
  dqi.pendingHover = nil
  dqi.ReadConfig()
  if not dqi.enabled then
    return
  end
  local counts = GetNPCBlackboard(dqi.playerId, dqi.countsBlackboard)
  if type(counts) == "table" then
    dqi.counts = counts
  end
  local ships = GetNPCBlackboard(dqi.playerId, dqi.shipsBlackboard)
  if type(ships) == "table" then
    dqi.ships = ships
  end
end

-- Puts the queue entry in front of the docked-ships icon; the surplus folds into the last entry as vanilla does.
function dqi.PrependQueueIcon(component, result, maxentries)
  if (not dqi.enabled) or (next(dqi.counts) == nil) or (type(result) ~= "table") then
    return
  end
  local idcode = GetComponentData(component, "idcode")
  local count = idcode and tonumber(dqi.counts[idcode])
  if (not count) or (count <= 0) then
    return
  end
  count = math.floor(count)
  table.insert(result, 1, { icon = dqi.icon, count = count, color = dqi.ColorFor(count) })
  while maxentries and (#result > maxentries) do
    local removed = table.remove(result)
    result[maxentries].count = (result[maxentries].count or 0) + (removed.count or 0)
    result[maxentries].icon = nil
  end
  local hover = string.format(tostring(ReadText(dqi.textPage, 1000)), count)
  local names = dqi.ships[idcode]
  if type(names) == "table" then
    for _, name in ipairs(names) do
      hover = hover .. "\n" .. tostring(name)
    end
  end
  dqi.pendingHover = hover
  dqi.Trace("%s: %d waiting for a dock", idcode, count)
end

-- The row's cells exist now; the icon cell is the one carrying our icon markup.
function dqi.OnRowFinished(row)
  local hover = dqi.pendingHover
  dqi.pendingHover = nil
  if (not hover) or (type(row) ~= "table") then
    return
  end
  for _, cell in ipairs(row) do
    -- Helper's property table raises on a property the widget type lacks, so only text cells are read.
    local text = (cell.type == "text") and cell.properties and cell.properties.text
    if type(text) == "table" then
      text = text.text
    end
    if (type(text) == "string") and string.find(text, dqi.icon, 1, true) then
      cell.properties.mouseOverText = hover
      return
    end
  end
end

function dqi.WrapFleetData(menuMap)
  if menuMap.dqi_originalFleetData then
    return
  end
  menuMap.dqi_originalFleetData = menuMap.getPropertyOwnedFleetData
  menuMap.getPropertyOwnedFleetData = function(instance, component, macro, maxentries)
    local result = menuMap.dqi_originalFleetData(instance, component, macro, maxentries)
    dqi.PrependQueueIcon(component, result, maxentries)
    return result
  end
end

local function Init()
  dqi.playerId = ConvertStringTo64Bit(tostring(C.GetPlayerID()))
  local menuMap = Helper.getMenu("MapMenu")
  if menuMap == nil or type(menuMap.registerCallback) ~= "function" or type(menuMap.getPropertyOwnedFleetData) ~= "function" then
    dqi.Error("MapMenu hooks are not available, is kuertee UI Extensions loaded?")
    return
  end
  RegisterEvent("DockQueueIndicator.ConfigChanged", dqi.ReadConfig)
  dqi.ReadConfig()
  menuMap.registerCallback("createPropertyOwned_on_init_infoTableData", dqi.OnInitInfoTableData)
  menuMap.registerCallback("createPropertyRow_after_row_height", dqi.OnRowFinished)
  dqi.WrapFleetData(menuMap)
  dqi.Debug("initialised")
end

Register_OnLoad_Init(Init)
