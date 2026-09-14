import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "seanpk.dock-workspaces"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string home: Quickshell.env("HOME")
  readonly property string configDir: Quickshell.env("XDG_CONFIG_HOME") || (home + "/.config")
  readonly property string stateDir: Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")
  readonly property string configPath: configDir + "/omarchy/dock-workspaces.json"
  readonly property string affinityPath: stateDir + "/omarchy/dock-workspaces-laptop-ids"

  property var config: Model.defaultConfig()
  property var affinityIds: []

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Color.muted
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property var monitors: Hyprland.monitors ? Hyprland.monitors.values : []

  function open() { root.controller.show() }

  onOpenedChanged: {
    if (!opened)
      return
    files.run("read-config", "", root._applyConfig)
    files.run("read-state", "", root._applyState)
    sync.checkLoader()
  }
  function close() { root.controller.hide() }
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  function _applyConfig(ok, status, body) {
    if (!ok && status !== "MISSING") {
      root.config = Model.defaultConfig()
      return
    }
    root.config = Model.parseConfig(status === "MISSING" ? "" : body)
  }

  function _applyState(ok, status, body) {
    if (!ok && status !== "MISSING") {
      root.affinityIds = []
      return
    }
    root.affinityIds = Model.parseAffinityIds(status === "MISSING" ? "" : body)
  }

  function save(patch) {
    var next = {
      version: 1,
      enabled: config.enabled,
      laptop: config.laptop,
      primary: config.primary
    }
    for (var key in patch) next[key] = patch[key]
    config = Model.parseConfig(JSON.stringify(next))
    files.run("write-config", Model.serializeConfig(config), function (ok) {
      if (!ok)
        sync.lastError = files.lastError || "could not save settings"
    })
  }

  function statusText() {
    if (sync.loaderStatus === "missing-file")
      return "hyprland.lua was not found. Dock Workspaces cannot load into Hyprland."
    if (sync.loaderMalformed)
      return "The Dock Workspaces block in hyprland.lua is damaged. It will not be rewritten."
    if (!sync.loaderInstalled)
      return "Hyprland loader is off. Jump on connect does nothing until you add it."
    if (!config.enabled) return "Paused. Workspaces stay where Hyprland puts them."
    var laptop = laptopMonitor()
    var primary = primaryMonitor()
    if (laptop && primary && laptop.name !== primary.name)
      return "Docked. " + Model.monitorLabel(primary) + " is primary."
    if (laptop) return "Laptop only. Plug in a display to restore workspaces."
    return "No internal panel detected. Pin laptop and primary below."
  }

  function laptopMonitor() {
    if (config.laptop)
      return monitorForSelector(config.laptop)
    for (var i = 0; i < monitors.length; i++) {
      if (Model.isInternalName(monitors[i].name)) return monitors[i]
    }
    return null
  }

  function primaryMonitor() {
    if (config.primary)
      return monitorForSelector(config.primary)
    var laptop = laptopMonitor()
    var laptopName = laptop ? laptop.name : ""
    for (var i = 0; i < monitors.length; i++) {
      if (monitors[i].name !== laptopName && !Model.isInternalName(monitors[i].name))
        return monitors[i]
    }
    return null
  }

  function monitorForSelector(selector) {
    var value = String(selector || "")
    for (var i = 0; i < monitors.length; i++) {
      var mon = monitors[i]
      if (value.indexOf("desc:") === 0) {
        var prefix = value.slice(5)
        if (String(mon.description || "").indexOf(prefix) === 0) return mon
      } else if (mon.name === value) {
        return mon
      }
    }
    return null
  }

  function affinityText() {
    if (affinityIds.length === 0) return "None yet. Create or fill a workspace on the laptop while docked."
    return affinityIds.join(", ")
  }

  FileHelper {
    id: files
  }

  HyprlandSync {
    id: sync
  }

  FileView {
    id: configFile
    preload: false
    blockAllReads: true
    watchChanges: true
    printErrors: false
    path: root.configPath
    onFileChanged: files.run("read-config", "", root._applyConfig)
  }

  FileView {
    id: affinityFile
    preload: false
    blockAllReads: true
    watchChanges: true
    printErrors: false
    path: root.affinityPath
    onFileChanged: files.run("read-state", "", root._applyState)
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(10)

        Text {
          width: parent.width
          text: "Dock Workspaces"
          textFormat: Text.PlainText
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          text: root.statusText()
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          width: parent.width
          visible: sync.lastError !== ""
          wrapMode: Text.WordWrap
          text: sync.lastError
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Button {
          width: parent.width
          visible: !sync.loaderInstalled && !sync.loaderMalformed
          text: "Add Hyprland loader"
          bordered: true
          foreground: root.fg
          fontFamily: root.fontFamily
          enabled: !sync.busy && sync.loaderStatus !== "missing-file"
          onClicked: sync.installLoader()
        }

        Button {
          width: parent.width
          visible: sync.loaderInstalled
          text: "Remove Hyprland loader"
          bordered: true
          foreground: root.fg
          fontFamily: root.fontFamily
          enabled: !sync.busy
          onClicked: sync.removeLoader()
        }

        Toggle {
          width: parent.width
          label: "Jump on connect"
          description: "Send workspaces to the primary display when it is plugged in."
          checked: root.config.enabled
          foreground: root.fg
          onClicked: root.save({ enabled: !root.config.enabled })
        }

        PanelSeparator { width: parent.width }

        PanelSectionHeader {
          text: "Laptop"
          foreground: root.fg
          fontFamily: root.fontFamily
        }

        MonitorChoice {
          width: parent.width
          autoSelected: root.config.laptop === ""
          autoLabel: "Auto (internal panel)"
          onAutoClicked: root.save({ laptop: "" })
          selectedSelector: root.config.laptop
          onMonitorClicked: function (selector) { root.save({ laptop: selector }) }
        }

        PanelSectionHeader {
          text: "Primary"
          foreground: root.fg
          fontFamily: root.fontFamily
        }

        MonitorChoice {
          width: parent.width
          autoSelected: root.config.primary === ""
          autoLabel: "Auto (any other display)"
          onAutoClicked: root.save({ primary: "" })
          selectedSelector: root.config.primary
          onMonitorClicked: function (selector) { root.save({ primary: selector }) }
        }

        PanelSeparator { width: parent.width }

        PanelSectionHeader {
          text: "Kept on the laptop"
          foreground: root.fg
          fontFamily: root.fontFamily
        }

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          text: root.affinityText()
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  component MonitorChoice: Column {
    id: choice
    spacing: Style.space(6)
    property bool autoSelected: false
    property string autoLabel: "Auto"
    property string selectedSelector: ""
    signal autoClicked()
    signal monitorClicked(string selector)

    Button {
      width: parent.width
      text: choice.autoLabel
      bordered: true
      selected: choice.autoSelected
      foreground: root.fg
      fontFamily: root.fontFamily
      onClicked: choice.autoClicked()
    }

    Repeater {
      model: root.monitors
      Button {
        required property var modelData
        width: parent.width
        text: Model.monitorLabel(modelData)
        bordered: true
        selected: !choice.autoSelected && choice.selectedSelector === Model.selectorFor(modelData)
        foreground: root.fg
        fontFamily: root.fontFamily
        onClicked: choice.monitorClicked(Model.selectorFor(modelData))
      }
    }
  }
}
