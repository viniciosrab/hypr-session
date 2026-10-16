import QtQuick
import qs.Commons
import qs.Ui

// Popup for the session: when it was last saved and restored, save/restore
// now, the four switches that shape the defaults, and the apps to leave out.
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
  readonly property var settingsNow: service ? service.settings : ({ restoreOnStart: true, autoSave: true, rearrangeLayout: true, resumeAgents: true, ignored: [] })
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string fontName: bar ? bar.fontFamily : Style.font.family

  // Open apps plus the ones already left out, so an ignored app that is
  // closed right now can still be brought back.
  readonly property var appList: {
    var names = service ? service.openClasses.slice() : []
    settingsNow.ignored.forEach(function(c) { if (names.indexOf(c) === -1) names.push(c) })
    return names.sort()
  }

  readonly property var options: [
    { key: "restoreOnStart", label: "Restaurar ao iniciar", description: "Reabre os apps depois de um reboot" },
    { key: "autoSave", label: "Salvar automaticamente", description: "Pause para manter a sessão atual" },
    { key: "rearrangeLayout", label: "Remontar layout", description: "Posição e divisões de cada janela" },
    { key: "resumeAgents", label: "Retomar agentes nos terminais", description: "Claude, Codex e pi voltam na mesma conversa" }
  ]

  function open() {
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

  function stamp(ms) { return ms > 0 ? Qt.formatTime(new Date(ms), "HH:mm") : "—" }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
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

        Column {
          width: parent.width
          spacing: Style.space(2)
          Text {
            text: "Sessão do Hyprland"
            color: root.fg
            font.family: root.fontName
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }
          Text {
            width: parent.width
            text: root.service ? "Último save: " + root.stamp(root.service.lastSaveAt) + " · " + root.service.lastSaveApps + " apps"
              : "Serviço não está rodando"
            color: root.fg
            font.family: root.fontName
            font.pixelSize: Style.font.body
          }
          Text {
            width: parent.width
            visible: root.service !== null
            text: root.service && root.service.restoring ? "Restaurando…"
              : root.service && root.service.lastRestoreAt > 0
                ? "Última restauração: " + root.stamp(root.service.lastRestoreAt) + " · " + root.service.lastRestoreText
                : "Nenhuma restauração nesta sessão"
            color: Qt.darker(root.fg, 1.4)
            font.family: root.fontName
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
          }
        }

        Row {
          spacing: Style.space(8)
          Button {
            text: "Salvar agora"
            bordered: true
            foreground: root.fg
            fontFamily: root.fontName
            enabled: root.service !== null
            onClicked: root.service.save()
          }
          Button {
            text: "Restaurar agora"
            bordered: true
            foreground: root.fg
            fontFamily: root.fontName
            enabled: root.service !== null && !root.service.restoring
            onClicked: root.service.restore()
          }
        }

        PanelSeparator { width: parent.width }

        Repeater {
          model: root.options
          Toggle {
            required property var modelData
            width: column.width
            label: modelData.label
            description: modelData.description
            checked: root.settingsNow[modelData.key] === true
            foreground: root.fg
            fontFamily: root.fontName
            onClicked: if (root.service) root.service.setSetting(modelData.key, !checked)
          }
        }

        PanelSeparator { width: parent.width; visible: root.appList.length > 0 }

        PanelSectionHeader {
          visible: root.appList.length > 0
          text: "Não salvar estes apps"
          foreground: root.fg
          fontFamily: root.fontName
        }

        Repeater {
          model: root.appList
          Toggle {
            required property string modelData
            width: column.width
            label: modelData
            checked: root.settingsNow.ignored.indexOf(modelData) !== -1
            foreground: root.fg
            fontFamily: root.fontName
            onClicked: if (root.service) root.service.setIgnored(modelData, !checked)
          }
        }
      }
    }
  }
}
