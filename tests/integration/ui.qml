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

  readonly property var steps: [
    { name: "widget finds the service and its tooltip tells the last save",
      until: function() { return harness.widget.service === harness.service && harness.service.lastSaveAt > 0 && harness.service.lastSaveApps === 1 } },
    { name: "clicking the icon opens the panel with the four switches",
      run: function() { harness.widget.toggle() },
      until: function() {
        var p = harness.panel
        return p && p.opened && p.service === harness.service && p.options.length === 4 && p.settingsNow.restoreOnStart === true
      } },
    { name: "the panel lists the open apps",
      until: function() { return harness.panel.appList.indexOf("fakeapp") !== -1 } },
    { name: "switches follow the service settings, and ignored apps stay listed after they close",
      run: function() { harness.service.setSetting("rearrangeLayout", false); harness.service.setIgnored("gone", true) },
      until: function() {
        var p = harness.panel
        return p.settingsNow.rearrangeLayout === false && p.appList.indexOf("gone") !== -1
      } },
    { name: "the icon is dimmed while autosave is off",
      run: function() { harness.service.setSetting("autoSave", false) },
      until: function() { return harness.widget.children[1].dimmed === true } }
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
      if (harness.waited > 12000) { stop(); harness.finish("timed out: " + step.name) }
    }
  }

  function finish(error) {
    if (error) console.log("SESSION_FAIL " + error)
    else console.log("SESSION_PASS")
    Qt.quit()
  }
}
