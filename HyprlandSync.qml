import QtQuick
import Quickshell.Io
import "Model.js" as Model

// Installs or removes the guarded dofile in hyprland.lua. Never runs on
// load: the settings panel has to ask first.
Item {
  id: root

  property bool loaderInstalled: false
  property bool loaderChecked: false
  property bool loaderMalformed: false
  property bool busy: files.busy || reloadProc.running || errorsProc.running
  property string lastError: ""
  property string loaderStatus: "unknown"

  property string _original: ""
  property string _pending: ""
  property string _reloadStdout: ""
  property var _afterReload: null

  FileHelper {
    id: files
  }

  function checkLoader() {
    files.run("read-hyprland", "", function (ok, status, body) {
      root.loaderChecked = true
      if (!ok) {
        root.loaderInstalled = false
        root.loaderMalformed = false
        root.loaderStatus = "error"
        root.lastError = files.lastError || "could not read hyprland.lua"
        return
      }
      if (status === "MISSING") {
        root.loaderInstalled = false
        root.loaderMalformed = false
        root.loaderStatus = "missing-file"
        root.lastError = "hyprland.lua not found"
        return
      }
      var state = Model.loaderState(body)
      root.loaderMalformed = state === "malformed"
      root.loaderInstalled = state === "present"
      root.loaderStatus = state
      root.lastError = state === "malformed"
        ? "hyprland.lua has a damaged Dock Workspaces block; not rewriting it"
        : ""
    })
  }

  function installLoader() {
    files.run("read-hyprland", "", function (ok, status, body) {
      if (!ok || status === "MISSING") {
        root.lastError = files.lastError || "hyprland.lua not found"
        return
      }
      var state = Model.loaderState(body)
      if (state === "present") {
        root.loaderInstalled = true
        root.loaderStatus = "present"
        return
      }
      if (state !== "absent") {
        root.loaderMalformed = true
        root.loaderStatus = state
        root.lastError = "hyprland.lua has a damaged Dock Workspaces block; not rewriting it"
        return
      }
      root._original = body
      root._pending = Model.withLoader(body)
      files.run("write-hyprland", root._pending, function (wrote, writeStatus) {
        if (!wrote) {
          root.lastError = files.lastError || "could not write hyprland.lua"
          return
        }
        root._reloadThenCheck(function (reloadOk) {
          if (reloadOk) {
            root.loaderInstalled = true
            root.loaderMalformed = false
            root.loaderStatus = "present"
            root.lastError = ""
            return
          }
          files.run("write-hyprland", root._original, function () {
            root._reload()
            root.loaderInstalled = false
            root.lastError = "Hyprland rejected the loader; restored the previous hyprland.lua"
          })
        })
      })
    })
  }

  function removeLoader() {
    files.run("read-hyprland", "", function (ok, status, body) {
      if (!ok || status === "MISSING") {
        root.lastError = files.lastError || "hyprland.lua not found"
        return
      }
      var state = Model.loaderState(body)
      if (state === "absent") {
        root.loaderInstalled = false
        root.loaderStatus = "absent"
        return
      }
      if (state !== "present") {
        root.loaderMalformed = true
        root.loaderStatus = state
        root.lastError = "hyprland.lua has a damaged Dock Workspaces block; not rewriting it"
        return
      }
      root._original = body
      root._pending = Model.withoutLoader(body)
      files.run("write-hyprland", root._pending, function (wrote) {
        if (!wrote) {
          root.lastError = files.lastError || "could not write hyprland.lua"
          return
        }
        root._reloadThenCheck(function (reloadOk) {
          if (reloadOk) {
            root.loaderInstalled = false
            root.loaderMalformed = false
            root.loaderStatus = "absent"
            root.lastError = ""
            return
          }
          files.run("write-hyprland", root._original, function () {
            root._reload()
            root.lastError = "Hyprland rejected the removal; restored the previous hyprland.lua"
          })
        })
      })
    })
  }

  function _reloadThenCheck(callback) {
    root._afterReload = function () {
      root._reloadStdout = ""
      errorsDeadline.restart()
      errorsProc.running = true
      root._afterErrors = callback
    }
    root._reload()
  }

  function _reload() {
    root._reloadStdout = ""
    reloadDeadline.restart()
    reloadProc.running = true
  }

  property var _afterErrors: null

  Process {
    id: reloadProc
    command: ["/usr/bin/hyprctl", "reload"]
    stdout: SplitParser {
      splitMarker: ""
      onRead: function (chunk) {
        if (root._reloadStdout.length + String(chunk).length > 4096) {
          reloadProc.signal(15)
          reloadKill.start()
          return
        }
        root._reloadStdout += chunk
      }
    }
    stderr: SplitParser {
      splitMarker: ""
      onRead: function (chunk) {
        if (root._reloadStdout.length + String(chunk).length > 4096) {
          reloadProc.signal(15)
          reloadKill.start()
          return
        }
        root._reloadStdout += chunk
      }
    }
    onExited: function () {
      reloadDeadline.stop()
      reloadKill.stop()
      var cb = root._afterReload
      root._afterReload = null
      if (typeof cb === "function")
        cb()
    }
  }

  Process {
    id: errorsProc
    command: ["/usr/bin/hyprctl", "configerrors"]
    stdout: SplitParser {
      splitMarker: ""
      onRead: function (chunk) {
        if (root._reloadStdout.length + String(chunk).length > 4096) {
          errorsProc.signal(15)
          errorsKill.start()
          return
        }
        root._reloadStdout += chunk
      }
    }
    onExited: function () {
      errorsDeadline.stop()
      errorsKill.stop()
      var cb = root._afterErrors
      root._afterErrors = null
      var message = String(root._reloadStdout || "").trim()
      var ok = message === "" || message === "ok"
      if (!ok)
        root.lastError = root._plain(message, 200)
      if (typeof cb === "function")
        cb(ok)
    }
  }

  function _plain(value, maxLen) {
    return Model.plainLabel(value, maxLen)
  }

  Timer { id: reloadDeadline; interval: 10000; repeat: false; onTriggered: { reloadProc.signal(15); reloadKill.start() } }
  Timer { id: reloadKill; interval: 2000; repeat: false; onTriggered: reloadProc.signal(9) }
  Timer { id: errorsDeadline; interval: 10000; repeat: false; onTriggered: { errorsProc.signal(15); errorsKill.start() } }
  Timer { id: errorsKill; interval: 2000; repeat: false; onTriggered: errorsProc.signal(9) }

  Component.onDestruction: {
    if (reloadProc.running) reloadProc.signal(15)
    if (errorsProc.running) errorsProc.signal(15)
  }
}
