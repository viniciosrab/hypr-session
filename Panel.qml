import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Popup for the session. Read top to bottom:
//   1. Is my session saved?  One line, with the autosave switch next to it.
//   2. Save / restore now.
//   3. How a restore behaves: three slim switches.
//   4. Which apps are saved: one collapsed line, real app names when opened.
// A thin front end to Service.qml, which owns the state and does the work.
Panel {
  id: root
  moduleName: "vinicios.hypr-session"
  ipcTarget: "vinicios.hypr-session"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  property alias surface: panel

  readonly property var service: bar && bar.shell ? bar.shell.serviceFor("vinicios.hypr-session") : null
  readonly property var prefs: service ? service.settings : Model.defaultSettings()
  readonly property var apps: service ? service.apps : []
  readonly property int savedCount: apps.filter(function(a) { return prefs.ignored.indexOf(a.class) === -1 }).length
  readonly property color fg: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property string fontName: bar ? bar.fontFamily : Style.font.family

  property bool appsExpanded: false
  // Ticks while open so "há 2 min" stays true.
  property real now: Date.now()

  readonly property string heroTitle: {
    if (!service) return "Sessão indisponível"
    if (service.restoring) return "Restaurando…"
    if (!prefs.autoSave) return "Salvamento pausado"
    return service.lastSaveAt > 0 ? "Sessão salva" : "Ainda não salva"
  }
  readonly property string heroMeta: {
    if (!service) return "O serviço não está rodando"
    if (service.lastSaveAt <= 0) return prefs.autoSave ? "Salva sozinha ao abrir ou fechar janelas" : "Ligue para começar a salvar"
    var when = Model.relativeTime(service.lastSaveAt, now)
    return (prefs.autoSave ? "" : "Último save ") + when + " · " + service.lastSaveApps + (service.lastSaveApps === 1 ? " app" : " apps")
  }
  readonly property string restoreLine: service && service.lastRestore
    ? "Restaurada " + Model.relativeTime(service.lastRestoreAt, now) + " · " + Model.restoreSummary(service.lastRestore)
    : ""
  readonly property bool restoreOk: !Model.restoreProblem(service ? service.lastRestore : null)

  readonly property var options: [
    { key: "restoreOnStart", label: "Reabrir apps ao ligar" },
    { key: "rearrangeLayout", label: "Refazer o layout das janelas" },
    { key: "resumeAgents", label: "Retomar Claude, Codex e pi" }
  ]

  function open() {
    now = Date.now()
    appsExpanded = false
    root.controller.show()
    if (service) service.refreshOpen()
  }
  function close() { root.controller.hide() }
  function toggle() { root.opened ? root.close() : root.open() }
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  Timer {
    interval: 20000
    repeat: true
    running: root.opened
    onTriggered: root.now = Date.now()
  }

  IpcHandler {
    target: "vinicios.hypr-session"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  // A label and a switch on one slim line; the whole line toggles.
  component SwitchRow: Item {
    id: row
    property string label: ""
    property bool checked: false
    property bool muted: false
    signal toggled()
    width: parent ? parent.width : 0
    implicitHeight: Math.max(rowText.implicitHeight, rowSwitch.implicitHeight)

    Text {
      id: rowText
      anchors.left: parent.left
      anchors.right: rowSwitch.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      text: row.label
      elide: Text.ElideRight
      color: row.muted ? root.dim : root.fg
      font.family: root.fontName
      font.pixelSize: Style.font.body
    }
    ToggleSwitch {
      id: rowSwitch
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      checked: row.checked
      foreground: root.fg
      onToggled: row.toggled()
    }
    MouseArea {
      anchors.fill: rowText
      cursorShape: Qt.PointingHandCursor
      onClicked: row.toggled()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(300))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // 1. Status, with autosave as the master switch
        PanelHero {
          width: parent.width
          title: root.heroTitle
          meta: root.heroMeta
          foreground: root.fg
          fontFamily: root.fontName
          iconOpacity: root.service && root.prefs.autoSave ? 1.0 : 0.45
          iconComponent: Component {
            Text {
              text: root.service ? Model.sessionIcon({ restoring: root.service.restoring, lastRestore: root.service.lastRestore }) : Model.sessionIcon({ restoring: false, lastRestore: null })
              color: root.fg
              font.family: root.fontName
              font.pixelSize: Style.font.display
            }
          }
          trailingControl: Component {
            ToggleSwitch {
              checked: root.prefs.autoSave
              foreground: root.fg
              onToggled: if (root.service) root.service.setSetting("autoSave", !root.prefs.autoSave)
            }
          }
        }

        Text {
          width: parent.width
          visible: root.restoreLine !== ""
          text: (root.restoreOk ? "󰄬 " : "󰀦 ") + root.restoreLine
          color: root.restoreOk ? root.dim : Commons.Color.urgent
          font.family: root.fontName
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        // 2. Actions
        Row {
          width: parent.width
          spacing: Style.space(8)
          Button {
            width: (parent.width - parent.spacing) / 2
            text: "Salvar agora"
            bordered: true
            foreground: root.fg
            fontFamily: root.fontName
            enabled: root.service !== null
            onClicked: root.service.save()
          }
          Button {
            width: (parent.width - parent.spacing) / 2
            text: "Restaurar agora"
            bordered: true
            foreground: root.fg
            fontFamily: root.fontName
            enabled: root.service !== null && !root.service.restoring
            onClicked: root.service.restore()
          }
        }

        PanelSeparator { width: parent.width }

        // 3. How a restore behaves
        Column {
          width: parent.width
          spacing: Style.space(8)
          PanelSectionHeader {
            text: "Ao restaurar"
            foreground: root.fg
            fontFamily: root.fontName
          }
          Repeater {
            model: root.options
            SwitchRow {
              required property var modelData
              label: modelData.label
              checked: root.prefs[modelData.key] === true
              onToggled: if (root.service) root.service.setSetting(modelData.key, !checked)
            }
          }
        }

        PanelSeparator { width: parent.width }

        // 4. Which apps are saved, collapsed to one line
        Column {
          width: parent.width
          spacing: Style.space(8)

          Item {
            width: parent.width
            implicitHeight: appsHeader.implicitHeight
            Text {
              id: appsHeader
              anchors.left: parent.left
              text: "Apps salvos"
              color: root.fg
              font.family: root.fontName
              font.pixelSize: Style.font.body
            }
            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.savedCount + " de " + root.apps.length + "  " + (root.appsExpanded ? "󰅀" : "󰅂")
              color: root.dim
              font.family: root.fontName
              font.pixelSize: Style.font.body
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.appsExpanded = !root.appsExpanded
            }
          }

          Repeater {
            model: root.appsExpanded ? root.apps : []
            SwitchRow {
              required property var modelData
              label: modelData.name
              checked: root.prefs.ignored.indexOf(modelData.class) === -1
              muted: !checked
              onToggled: if (root.service) root.service.setIgnored(modelData.class, checked)
            }
          }
        }
      }
    }
  }
}
