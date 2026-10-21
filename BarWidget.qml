import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Icon in the bar. Click opens the panel; the tooltip says when the session
// was last saved.
BarWidget {
  id: root
  moduleName: "vinicios.hypr-session"

  readonly property var service: bar && bar.shell ? bar.shell.serviceFor("vinicios.hypr-session") : null
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  // Text in the language picked under Omarchy's Setup > Language
  Translations { id: tr; directory: Qt.resolvedUrl("i18n") }

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
    text: root.service ? Model.sessionIcon({ restoring: root.service.restoring, lastRestore: root.service.lastRestore }) : Model.sessionIcon({ restoring: false, lastRestore: null })
    dimmed: root.service ? !root.service.settings.autoSave : false
    tooltipText: {
      if (root.opened || !root.service) return ""
      if (root.service.restoring) return tr.t("tooltip.restoring")
      if (Model.restoreProblem(root.service.lastRestore)) return Model.fill(tr.t("tooltip.incomplete"), [Model.restoreSummary(root.service.lastRestore, tr)])
      if (!root.service.settings.autoSave) return tr.t("tooltip.paused")
      return root.service.lastSaveAt > 0
        ? Model.fill(tr.t("tooltip.saved"), [Model.relativeTime(root.service.lastSaveAt, Date.now(), tr), Model.appCount(root.service.lastSaveApps, tr)])
        : tr.t("tooltip.notSaved")
    }

    onPressed: function(b) { root.toggle() }
  }
}
