// Config, monitor selectors, and the one-time Hyprland loader line.
// No QML imports, so node --test can exercise the same functions.

var PLUGIN_ID = "seanpk.dock-workspaces"
var LOADER_BEGIN = "-- seanpk.dock-workspaces start"
var LOADER_END = "-- seanpk.dock-workspaces end"

function defaultConfig() {
  return { version: 1, enabled: true, laptop: "", primary: "" }
}

function parseConfig(text) {
  var fallback = defaultConfig()
  var raw = String(text || "").trim()
  if (raw === "") return fallback
  var parsed
  try {
    parsed = JSON.parse(raw)
  } catch (err) {
    return fallback
  }
  if (!parsed || typeof parsed !== "object") return fallback
  return {
    version: 1,
    enabled: parsed.enabled !== false,
    laptop: String(parsed.laptop == null ? "" : parsed.laptop),
    primary: String(parsed.primary == null ? "" : parsed.primary)
  }
}

function serializeConfig(config) {
  var cfg = parseConfig(JSON.stringify(config || {}))
  return JSON.stringify({
    version: 1,
    enabled: cfg.enabled,
    laptop: cfg.laptop,
    primary: cfg.primary
  }, null, 2) + "\n"
}

function isInternalName(name) {
  return /^(eDP|LVDS|DSI)/i.test(String(name || ""))
}

function selectorFor(mon) {
  if (!mon) return ""
  var name = String(mon.name || "")
  var desc = String(mon.description || "").replace(/\s*\([^)]*\)\s*$/, "").trim()
  if (isInternalName(name)) return name
  if (desc) return "desc:" + desc
  return name
}

function monitorLabel(mon) {
  if (!mon) return ""
  var name = String(mon.name || "")
  var desc = String(mon.description || "").trim()
  return desc ? desc + " (" + name + ")" : name
}

function parseAffinityIds(text) {
  var ids = []
  var seen = {}
  String(text || "").split(/\n/).forEach(function (line) {
    var n = parseInt(String(line).trim(), 10)
    if (n > 0 && !seen[n]) {
      seen[n] = true
      ids.push(n)
    }
  })
  ids.sort(function (a, b) { return a - b })
  return ids
}

function loaderBlock() {
  return [
    LOADER_BEGIN,
    "do",
    "  local path = (os.getenv(\"XDG_CONFIG_HOME\") or (os.getenv(\"HOME\") .. \"/.config\"))",
    "    .. \"/omarchy/plugins/seanpk.dock-workspaces/hypr/dock-workspaces.lua\"",
    "  local file = io.open(path, \"r\")",
    "  if file then file:close(); dofile(path) end",
    "end",
    LOADER_END
  ].join("\n")
}

function needsLoader(hyprlandLua) {
  return String(hyprlandLua || "").indexOf(PLUGIN_ID) === -1
}

function withLoader(hyprlandLua) {
  var text = String(hyprlandLua || "")
  if (!needsLoader(text)) return text
  var separator = text.length === 0 || /\n\s*$/.test(text) ? "\n" : "\n\n"
  return text + separator + loaderBlock() + "\n"
}

function withoutLoader(hyprlandLua) {
  var text = String(hyprlandLua || "")
  var stripped = text.replace(
    /\n?-- seanpk\.dock-workspaces start[\s\S]*?-- seanpk\.dock-workspaces end\n?/,
    "\n"
  )
  return stripped.replace(/\n{3,}/g, "\n\n")
}

if (typeof module !== "undefined") {
  module.exports = {
    PLUGIN_ID: PLUGIN_ID,
    defaultConfig: defaultConfig,
    parseConfig: parseConfig,
    serializeConfig: serializeConfig,
    isInternalName: isInternalName,
    selectorFor: selectorFor,
    monitorLabel: monitorLabel,
    parseAffinityIds: parseAffinityIds,
    loaderBlock: loaderBlock,
    needsLoader: needsLoader,
    withLoader: withLoader,
    withoutLoader: withoutLoader
  }
}
