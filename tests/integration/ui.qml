import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import "host" as Host
import "plugin" as Plugin

// Mounts the bar widget and its panel the way omarchy-shell does (Omarchy's
// own PluginShellApi and PluginBarApi), backed by the real service and the
// fake hyprctl. Fails on any QML binding or type error in the output.
ShellRoot {
  id: harness

  readonly property string fake: Quickshell.env("FAKE_HYPR")
  readonly property string pid: Quickshell.env("FAKE_PID")

  property var service: null
  property var widget: null
  readonly property var panel: widget ? widget.children[0].item : null

  Host.PluginShellApi {
    id: hostShell
    pluginId: "vinicios.hypr-session"
    _serviceLookup: function(id) { return id === "vinicios.hypr-session" ? harness.service : null }
  }

  PluginBarApi {
    id: hostBar
    pluginId: "vinicios.hypr-session"
    moduleName: "vinicios.hypr-session"
    shell: hostShell
  }

  Component { id: serviceComponent; Plugin.Service {} }
  Component { id: widgetComponent; Plugin.BarWidget { bar: hostBar } }

  property int stepIndex: -1
  property int waited: 0
  property bool ran: false

  function names() { return harness.panel.apps.map(function(a) { return a.name }) }

  readonly property var steps: [
    { name: "widget finds the service and its tooltip tells the last save",
      until: function() {
        if (harness.widget.children[1].text !== "\u{F0031}") return false
        return harness.widget.service === harness.service && harness.service.lastSaveAt > 0
          && harness.widget.children[1].tooltipText === "Sessão salva agora · 1 app"
      } },
    { name: "clicking the icon opens the panel: saved status, three restore switches, apps collapsed",
      run: function() { harness.widget.toggle() },
      until: function() {
        var p = harness.panel
        return p && p.opened && p.heroTitle === "Sessão salva" && p.heroMeta === "agora · 1 app"
          && p.options.length === 3 && p.appsExpanded === false && p.restoreLine === ""
      } },
    { name: "apps show the program name when no launcher knows the class, all saved",
      until: function() { return harness.names().indexOf("sleep") !== -1 && harness.panel.savedCount === harness.panel.apps.length } },
    { name: "switching an app off leaves it out, and it stays listed after it closes",
      run: function() { harness.service.setIgnored("gone", true) },
      until: function() {
        var p = harness.panel
        return p.apps.some(function(a) { return a.class === "gone" }) && p.savedCount === p.apps.length - 1
      } },
    { name: "an incomplete restore keeps the anchor and turns the panel line into a warning",
      run: function() { harness.service.lastRestore = { placed: 1, expected: 2, off: 0, layout: true } },
      until: function() {
        var b = harness.widget.children[1]
        return b.text === "\u{F0031}" && harness.panel.restoreOk === false
      } },
    { name: "pausing autosave changes the headline and dims the bar icon",
      run: function() { harness.service.setSetting("autoSave", false) },
      until: function() {
        return harness.panel.heroTitle === "Salvamento pausado" && harness.widget.children[1].dimmed === true
          && harness.widget.children[1].tooltipText === ""
      } }
  ]

  Process {
    id: fixture
    running: true
    command: ["sh", "-c", 'printf "%s" "$1" >"$2/clients.json"', "_",
      JSON.stringify([{ address: "0x1", class: "fakeapp", pid: Number(harness.pid), workspace: { id: 2, name: "2" }, at: [0, 0], size: [800, 600], floating: false }]),
      harness.fake]
    onExited: function(code) {
      if (code !== 0) return harness.finish("could not write fixtures")
      harness.service = serviceComponent.createObject(harness)
      harness.widget = widgetComponent.createObject(harness)
      harness.advance()
    }
  }

  function advance() {
    stepIndex++
    waited = 0
    ran = false
    if (stepIndex >= steps.length) return finish("")
    poll.start()
  }

  Timer {
    id: poll
    interval: 200; repeat: true
    onTriggered: {
      var step = harness.steps[harness.stepIndex]
      if (!harness.ran) { harness.ran = true; if (step.run) step.run() }
      harness.waited += interval
      var ok = false
      try { ok = step.until() } catch (e) { console.log("step threw: " + e) }
      if (ok) { stop(); console.log("ok  - " + step.name); harness.advance(); return }
      if (harness.waited > 12000) { stop(); harness.finish("timed out: " + step.name + (harness.panel ? " [" + harness.panel.heroTitle + " / " + harness.panel.heroMeta + " / " + harness.panel.restoreLine + " / " + harness.panel.opened + "]" : "")) }
    }
  }

  function finish(error) {
    if (error) console.log("SESSION_FAIL " + error)
    else console.log("SESSION_PASS")
    Qt.quit()
  }
}
