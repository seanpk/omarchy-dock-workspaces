-- Dock Workspaces: on external connect, send workspaces to the primary
-- display unless they were created or given windows on the laptop during
-- the last dual-monitor session.

local function env_or(name, fallback)
  local value = os.getenv(name)
  if value == nil or value == "" then
    return fallback
  end
  return value
end

local home = os.getenv("HOME") or ""
local config_home = env_or("XDG_CONFIG_HOME", home .. "/.config")
local state_home = env_or("XDG_STATE_HOME", home .. "/.local/state")
local SETTINGS_FILE = config_home .. "/omarchy/dock-workspaces.json"
local STATE_DIR = state_home .. "/omarchy"
local STATE_FILE = STATE_DIR .. "/dock-workspaces-laptop-ids"
local LEGACY_STATE_FILE = STATE_DIR .. "/workspace-laptop-affinity"

local laptop_ids = {}
local restoring = false
local restore_timer = nil

local function read_file(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local text = file:read("*a") or ""
  file:close()
  return text
end

local function json_string(text, key)
  return text:match('"' .. key .. '"%s*:%s*"([^"]*)"') or ""
end

local function read_settings()
  local text = read_file(SETTINGS_FILE) or ""
  return {
    enabled = not text:find('"enabled"%s*:%s*false'),
    laptop = json_string(text, "laptop"),
    primary = json_string(text, "primary"),
  }
end

local function looks_internal(mon)
  local name = mon and mon.name or ""
  return name:match("^eDP") or name:match("^LVDS") or name:match("^DSI")
    or name:match("^edp") or name:match("^lvds") or name:match("^dsi")
end

local function resolve(selector)
  if selector == nil or selector == "" then
    return nil
  end
  return hl.get_monitor(selector)
end

local function find_laptop()
  local settings = read_settings()
  local pinned = resolve(settings.laptop)
  if pinned then
    return pinned
  end
  for _, mon in ipairs(hl.get_monitors()) do
    if looks_internal(mon) then
      return mon
    end
  end
  return nil
end

local function find_primary()
  local settings = read_settings()
  local pinned = resolve(settings.primary)
  if pinned then
    return pinned
  end
  local laptop = find_laptop()
  local laptop_name = laptop and laptop.name
  for _, mon in ipairs(hl.get_monitors()) do
    if mon.name ~= laptop_name and not looks_internal(mon) then
      return mon
    end
  end
  return nil
end

local function same_monitor(a, b)
  return a ~= nil and b ~= nil and a.name == b.name
end

local function is_laptop(mon)
  return same_monitor(mon, find_laptop())
end

local function is_primary(mon)
  return same_monitor(mon, find_primary())
end

local function docked()
  local laptop = find_laptop()
  local primary = find_primary()
  return laptop ~= nil and primary ~= nil and laptop.name ~= primary.name
end

local function load_ids()
  laptop_ids = {}
  local text = read_file(STATE_FILE)
  if text == nil then
    text = read_file(LEGACY_STATE_FILE)
  end
  if text == nil then
    return
  end
  for line in string.gmatch(text, "[^\r\n]+") do
    local id = tonumber(line)
    if id then
      laptop_ids[id] = true
    end
  end
end

local function save_ids()
  os.execute("mkdir -p '" .. STATE_DIR:gsub("'", "'\\''") .. "'")
  local file = io.open(STATE_FILE, "w")
  if not file then
    return
  end
  local ids = {}
  for id in pairs(laptop_ids) do
    table.insert(ids, id)
  end
  table.sort(ids)
  for _, id in ipairs(ids) do
    file:write(tostring(id) .. "\n")
  end
  file:close()
end

local function remember(ws, mon)
  if restoring or not read_settings().enabled or not docked() then
    return
  end
  if ws == nil or ws.special then
    return
  end

  local id = ws.id
  if is_laptop(mon) then
    if not laptop_ids[id] then
      laptop_ids[id] = true
      save_ids()
    end
  elseif is_primary(mon) then
    if laptop_ids[id] then
      laptop_ids[id] = nil
      save_ids()
    end
  end
end

local function restore()
  if not read_settings().enabled then
    restoring = false
    return
  end

  local primary = find_primary()
  local laptop = find_laptop()
  if not primary or not laptop or primary.name == laptop.name then
    restoring = false
    return
  end

  restoring = true

  for _, ws in ipairs(hl.get_workspaces()) do
    if not ws.special then
      local want = laptop_ids[ws.id] and laptop or primary
      local current = ws.monitor
      if current == nil or current.name ~= want.name then
        hl.dispatch(hl.dsp.workspace.move({
          workspace = tostring(ws.id),
          monitor = want.name,
        }))
      end
    end
  end

  hl.dispatch(hl.dsp.focus({ monitor = primary.name }))

  hl.timer(function()
    restoring = false
  end, { timeout = 250, type = "oneshot" })
end

local function schedule_restore()
  restoring = true
  if restore_timer then
    restore_timer:set_enabled(false)
  end
  restore_timer = hl.timer(restore, { timeout = 200, type = "oneshot" })
end

load_ids()

hl.on("monitor.added", function(mon)
  if is_primary(mon) then
    schedule_restore()
  end
end)

hl.on("workspace.created", function(ws)
  remember(ws, ws.monitor)
end)

hl.on("workspace.move_to_monitor", function(ws, mon)
  if ws ~= nil and is_laptop(mon) and ws.windows == 0 then
    return
  end
  remember(ws, mon)
end)

hl.on("workspace.removed", function(ws)
  if restoring or not docked() or ws == nil or ws.special then
    return
  end
  if laptop_ids[ws.id] then
    laptop_ids[ws.id] = nil
    save_ids()
  end
end)

hl.on("window.open", function(win)
  if win == nil then
    return
  end
  remember(win.workspace, win.monitor)
end)

hl.on("window.move_to_workspace", function(win, ws)
  if win == nil then
    return
  end
  remember(ws, win.monitor)
end)

hl.on("hyprland.start", function()
  if docked() then
    schedule_restore()
  end
end)

hl.on("hyprland.shutdown", function()
  if restore_timer then
    restore_timer:set_enabled(false)
  end
end)

if docked() then
  schedule_restore()
end
