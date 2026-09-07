import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Appends a guarded dofile to hyprland.lua so Hyprland loads this plugin's
// Lua. The line is an existence check: removing the plugin checkout cannot
// break the user's config.
Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string configDir: Quickshell.env("XDG_CONFIG_HOME") || (home + "/.config")
  readonly property string hyprlandLuaPath: configDir + "/hypr/hyprland.lua"

  property bool loaderInstalled: false
  property bool loaderChecked: false
  property string lastError: ""

  FileView {
    id: hyprlandLuaFile
    path: root.hyprlandLuaPath
    atomicWrites: true
    watchChanges: false
    printErrors: false

    onLoaded: {
      var current = text()
      root.loaderChecked = true
      if (Model.needsLoader(current)) {
        setText(Model.withLoader(current))
        reloadProcess.running = true
      }
      root.loaderInstalled = true
    }

    onLoadFailed: {
      root.loaderChecked = true
      root.loaderInstalled = false
      root.lastError = "hyprland.lua not found"
    }
  }

  Process {
    id: reloadProcess
    command: ["hyprctl", "reload"]
    stderr: StdioCollector {
      onStreamFinished: {
        var message = String(text || "").trim()
        root.lastError = (message.length > 0 && message !== "ok") ? message : ""
      }
    }
  }

  function ensureLoader() {
    hyprlandLuaFile.reload()
  }

  function removeLoader() {
    var current = hyprlandLuaFile.text()
    if (current === undefined || current === null || current === "") {
      hyprlandLuaFile.reload()
      return
    }
    hyprlandLuaFile.setText(Model.withoutLoader(current))
    root.loaderInstalled = false
    reloadProcess.running = true
  }
}
