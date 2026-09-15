import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "seanpk.dock-workspaces"

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  readonly property bool needsSetup: panelLoader.item
    ? (panelLoader.item.loaderChecked === true && panelLoader.item.loaderInstalled !== true)
    : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }
  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }
  function toggle() {
    if (panelLoader.item) panelLoader.item.toggle()
  }
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰍺"
    tooltipText: root.needsSetup ? "Dock workspaces: add the Hyprland loader" : "Dock workspaces"
    onPressed: function (code) {
      if (code === Qt.LeftButton) root.toggle()
    }
  }

  Rectangle {
    visible: root.needsSetup
    z: 1
    width: Math.max(7, Math.round((button.slotSize || Style.bar.iconSlot) * 0.34))
    height: width
    radius: width / 2
    color: root.bar ? root.bar.urgent : Color.urgent
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.rightMargin: 1
    anchors.topMargin: 1
    border.width: 1
    border.color: root.bar ? root.bar.background : Color.background

    Text {
      anchors.centerIn: parent
      text: "!"
      textFormat: Text.PlainText
      color: Color.background
      font.family: root.bar && root.bar.fontFamily ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Math.max(6, Math.round(parent.height * 0.72))
      font.bold: true
    }
  }
}
