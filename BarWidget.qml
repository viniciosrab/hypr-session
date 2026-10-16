import QtQuick
import qs.Commons
import qs.Ui

// Icon in the bar. Click opens the panel; the tooltip says when the session
// was last saved.
BarWidget {
  id: root
  moduleName: "vinicios.hypr-session"

  readonly property var service: bar && bar.shell ? bar.shell.serviceFor("vinicios.hypr-session") : null
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    target.bar = root.bar
    target.settings = root.settings
    target.anchorItem = button
    target.hostWidget = root
  }

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

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
    text: "󰆓"
    dimmed: root.service ? !root.service.settings.autoSave : false
    tooltipText: root.opened || !root.service ? ""
      : (root.service.lastSaveAt > 0
        ? "Salvo às " + Qt.formatTime(new Date(root.service.lastSaveAt), "HH:mm") + " · " + root.service.lastSaveApps + " apps"
        : "Sessão ainda não salva")

    onPressed: function(b) { root.toggle() }
  }
}
