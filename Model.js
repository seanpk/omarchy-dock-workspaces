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
    laptop: String(parsed.laptop == null ? "" : parsed.laptop).slice(0, 200),
    primary: String(parsed.primary == null ? "" : parsed.primary).slice(0, 200)
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
  var name = String(mon.name || "").replace(/[\0\r\n]/g, "").slice(0, 64)
  var desc = String(mon.description || "").replace(/\s*\([^)]*\)\s*$/, "").trim()
  desc = desc.replace(/[\0\r\n]/g, "").slice(0, 200)
  if (isInternalName(name)) return name
  if (desc) return "desc:" + desc
  return name
}

function monitorLabel(mon) {
  if (!mon) return ""
  var name = plainLabel(mon.name, 64)
  var desc = plainLabel(String(mon.description || "").trim(), 80)
  return desc ? desc + " (" + name + ")" : name
}

function parseAffinityIds(text) {
  var ids = []
  var seen = {}
  String(text || "").split(/\n/).forEach(function (line) {
    if (ids.length >= 64) return
    var n = parseInt(String(line).trim(), 10)
    if (n > 0 && n <= 99999 && !seen[n]) {
      seen[n] = true
      ids.push(n)
    }
  })
  ids.sort(function (a, b) { return a - b })
  return ids
}

function plainLabel(value, maxLen) {
  var max = maxLen || 120
  var text = String(value || "")
  var out = ""
  for (var i = 0; i < text.length && out.length < max; i++) {
    var code = text.charCodeAt(i)
    if (code === 60 || code === 62 || code === 38) continue
    if (code < 32 || code === 127) continue
    out += text.charAt(i)
  }
  return out
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

function loaderState(hyprlandLua) {
  var text = String(hyprlandLua || "")
  var beginCount = 0
  var endCount = 0
  var i = 0
  while (true) {
    var found = text.indexOf(LOADER_BEGIN, i)
    if (found === -1) break
    beginCount += 1
    i = found + LOADER_BEGIN.length
  }
  i = 0
  while (true) {
    var found = text.indexOf(LOADER_END, i)
    if (found === -1) break
    endCount += 1
    i = found + LOADER_END.length
  }
  if (beginCount === 0 && endCount === 0) return "absent"
  if (beginCount !== 1 || endCount !== 1) return "malformed"
  var begin = text.indexOf(LOADER_BEGIN)
  var end = text.indexOf(LOADER_END)
  if (end < begin) return "malformed"
  var expected = loaderBlock()
  var actual = text.slice(begin, end + LOADER_END.length)
  if (actual !== expected) return "malformed"
  return "present"
}

function needsLoader(hyprlandLua) {
  return loaderState(hyprlandLua) === "absent"
}

function withLoader(hyprlandLua) {
  var text = String(hyprlandLua || "")
  if (loaderState(text) !== "absent") return text
  var separator = text.length === 0 || /\n\s*$/.test(text) ? "\n" : "\n\n"
  return text + separator + loaderBlock() + "\n"
}

function withoutLoader(hyprlandLua) {
  var text = String(hyprlandLua || "")
  if (loaderState(text) !== "present") return text
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
    plainLabel: plainLabel,
    loaderBlock: loaderBlock,
    loaderState: loaderState,
    needsLoader: needsLoader,
    withLoader: withLoader,
    withoutLoader: withoutLoader
  }
}
