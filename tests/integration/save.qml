import QtQuick
import Quickshell
import Quickshell.Io
import "plugin" as Plugin

// Drives the real Service.qml against the fake hyprctl (tests/bin): what gets
// saved, that an unchanged desktop is not rewritten, and that settings stick.
ShellRoot {
  id: harness

  readonly property string fake: Quickshell.env("FAKE_HYPR")
  readonly property string pid: Quickshell.env("FAKE_PID")
  readonly property string home: Quickshell.env("HOME")
  readonly property string statePath: home + "/.local/state/hypr-session.json"
  readonly property string settingsPath: home + "/.local/state/omarchy/settings/hypr-session.json"
  readonly property string logPath: home + "/.local/state/hypr-session.log"

  property string stateText: ""
  property string settingsText: ""
  property string logText: ""
  Process { id: readState; command: ["cat", harness.statePath]; stdout: StdioCollector { onStreamFinished: harness.stateText = text } }
  Process { id: readSettings; command: ["cat", harness.settingsPath]; stdout: StdioCollector { onStreamFinished: harness.settingsText = text } }
  property string modeText: ""
  Process { id: readMode; command: ["sh", "-c", 'stat -c %a "$1" 2>/dev/null', "_", harness.statePath]; stdout: StdioCollector { onStreamFinished: harness.modeText = text.trim() } }
  Process { id: readLog; command: ["cat", harness.logPath]; stdout: StdioCollector { onStreamFinished: harness.logText = text } }

  function state() { try { return JSON.parse(stateText) } catch (e) { return null } }
  function saves() { return logText.split("\n").filter(function(l) { return l.indexOf("save:") !== -1 }).length }

  property var service: null
  property int stepIndex: -1
  property int waited: 0
  property bool ran: false

  readonly property var steps: [
    { name: "saves the open apps from /proc, in the old state format",
      until: function() {
        var s = harness.state()
        return s && s.length === 1 && s[0].class === "fakeapp" && s[0].cmd.join(" ") === "sleep 600"
          && s[0].workspaces[0] === "2" && s[0].geometry[0].size[0] === 800
      } },
    { name: "the saved session is readable only by the user",
      until: function() { return harness.modeText === "600" } },
    { name: "an unchanged desktop is not rewritten",
      run: function() { harness.service.save() },
      until: function() { return harness.service.lastSaveAt > 0 && harness.waited > 1500 && harness.saves() === 1 } },
    { name: "the panel can list the open apps",
      until: function() { return harness.service.openClasses.indexOf("fakeapp") !== -1 && harness.service.openClasses.indexOf("skipme") !== -1 } },
    { name: "an ignored app is left out and the choice persists",
      run: function() { harness.service.setIgnored("skipme", true); harness.service.setSetting("autoSave", false) },
      until: function() {
        var s = JSON.parse(harness.settingsText || "{}")
        return s.ignored && s.ignored[0] === "skipme" && s.autoSave === false && s.restoreOnStart === true
      } },
    { name: "ignoring the last app saves an empty list, an empty desktop saves nothing",
      run: function() { harness.service.setIgnored("fakeapp", true); harness.service.save() },
      until: function() { var s = harness.state(); return s && s.length === 0 } },
    { name: "status is JSON",
      until: function() {
        var p = JSON.parse(JSON.stringify(harness.service.statusPayload()))
        return p.watching === true && p.settings.ignored.length === 2 && p.restoring === false
      } }
  ]

  Process {
    id: fixture
    running: true
    command: ["sh", "-c", 'printf "%s" "$1" >"$2/clients.json" && printf "%s" "$3" >"$4/hypr-session.fixture"',
      "_",
      JSON.stringify([
        { address: "0x1", class: "fakeapp", pid: Number(harness.pid), workspace: { id: 2, name: "2" }, at: [10, 20], size: [800, 600], floating: false },
        { address: "0x2", class: "skipme", pid: Number(harness.pid), workspace: { id: 2, name: "2" }, at: [10, 20], size: [800, 600], floating: false }
      ]),
      harness.fake,
      JSON.stringify({ ignored: ["skipme"] }), harness.fake]
    onExited: function(code) {
      if (code !== 0) return harness.finish("could not write fixtures")
      settingsFixture.running = true
    }
  }

  Process {
    id: settingsFixture
    command: ["sh", "-c", 'cp "$1/hypr-session.fixture" "$2"', "_", harness.fake, harness.settingsPath]
    onExited: function(code) {
      if (code !== 0) return harness.finish("could not write settings")
      harness.service = serviceComponent.createObject(harness)
      harness.advance()
    }
  }

  Component { id: serviceComponent; Plugin.Service {} }

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
      readState.running = true
      readSettings.running = true
      readLog.running = true
      readMode.running = true
      var step = harness.steps[harness.stepIndex]
      if (!harness.ran) { harness.ran = true; if (step.run) step.run() }
      harness.waited += interval
      var ok = false
      try { ok = step.until() } catch (e) { console.log("step threw: " + e) }
      if (ok) { stop(); console.log("ok  - " + step.name); harness.advance(); return }
      if (harness.waited > 12000) { stop(); harness.finish("timed out: " + step.name + "\nstate: " + harness.stateText + "\nsettings: " + harness.settingsText + "\nlog: " + harness.logText) }
    }
  }

  function finish(error) {
    if (error) console.log("SESSION_FAIL " + error)
    else console.log("SESSION_PASS")
    Qt.quit()
  }
}
