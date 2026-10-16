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

  property string callsText: ""
  property string logText: ""
  Process { id: readCalls; command: ["cat", harness.fake + "/calls"]; stdout: StdioCollector { onStreamFinished: harness.callsText = text } }
  Process { id: readLog; command: ["cat", harness.home + "/.local/state/hypr-session.log"]; stdout: StdioCollector { onStreamFinished: harness.logText = text } }

  property var service: null
  property int stepIndex: -1
  property int waited: 0
  property bool ran: false

  // The marker of this Hyprland session already exists, as after a shell restart.
  readonly property var steps: [
    { name: "a restarted shell does not relaunch the apps, and starts watching",
      until: function() { return harness.service.watching && harness.waited > 4500 && harness.callsText.indexOf("exec_cmd") === -1 && harness.service.lastRestoreAt === 0 } },
    { name: "still saves the session",
      until: function() { return harness.logText.indexOf("save: fakeapp@2") !== -1 } }
  ]

  Process {
    id: fixture
    running: true
    command: ["sh", "-c", 'printf "%s" "$1" >"$2/clients.json" && printf "%s" "$3" >"$4" && : >"$5"',
      "_",
      JSON.stringify([{ address: "0x1", class: "fakeapp", pid: Number(harness.pid), workspace: { id: 2, name: "2" }, at: [0, 0], size: [800, 600], floating: false }]),
      harness.fake,
      JSON.stringify([{ cmd: ["fakeapp-a"], class: "a", workspaces: ["3"], geometry: [] }]),
      harness.home + "/.local/state/hypr-session.json", Quickshell.env("HYPR_SESSION_MARKER")]
    onExited: function(code) {
      if (code !== 0) return harness.finish("could not write fixtures")
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
      readCalls.running = true
      readLog.running = true
      var step = harness.steps[harness.stepIndex]
      if (!harness.ran) { harness.ran = true; if (step.run) step.run() }
      harness.waited += interval
      var ok = false
      try { ok = step.until() } catch (e) { console.log("step threw: " + e) }
      if (ok) { stop(); console.log("ok  - " + step.name); harness.advance(); return }
      if (harness.waited > 12000) { stop(); harness.finish("timed out: " + step.name + "\ncalls: " + harness.callsText + "\nlog: " + harness.logText) }
    }
  }

  function finish(error) {
    if (error) console.log("SESSION_FAIL " + error)
    else console.log("SESSION_PASS")
    Qt.quit()
  }
}
