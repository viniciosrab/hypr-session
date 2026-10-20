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
  property string clientsText: ""
  property string restoredText: ""
  property string logText: ""
  property int launches: 0
  Process { id: readCalls; command: ["cat", harness.fake + "/calls"]; stdout: StdioCollector { onStreamFinished: harness.callsText = text } }
  Process { id: readClients; command: ["cat", harness.fake + "/clients.json"]; stdout: StdioCollector { onStreamFinished: harness.clientsText = text } }
  Process { id: readRestored; command: ["cat", harness.home + "/.local/state/hypr-session.restored.json"]; stdout: StdioCollector { onStreamFinished: harness.restoredText = text } }
  property string modeText: ""
  Process { id: readMode; command: ["sh", "-c", 'stat -c %a "$1" "$2" 2>/dev/null | tr "\\n" " "', "_", harness.statePath, harness.home + "/.local/state/hypr-session.restored.json"]; stdout: StdioCollector { onStreamFinished: harness.modeText = text.trim() } }
  Process { id: readLog; command: ["cat", harness.logPath]; stdout: StdioCollector { onStreamFinished: harness.logText = text } }

  function clients() { try { return JSON.parse(clientsText) } catch (e) { return [] } }
  function wsOf(cls) { var c = clients().filter(function(x) { return x.class === cls })[0]; return c ? c.workspace.name : null }
  function called(text) { return callsText.indexOf(text) !== -1 }

  readonly property string pressureDir: Quickshell.env("HYPR_SESSION_PRESSURE")
  property real busyTotal: 1000000
  property bool busy: false
  property bool early: false

  property var service: null
  property int stepIndex: -1
  property int waited: 0
  property bool ran: false

  readonly property var steps: [
    { name: "waits for a calm system before launching an app, then launches",
      run: function() { harness.busy = true },
      until: function() {
        var execs = harness.callsText.split("exec_cmd").length - 1
        if (harness.busy) {
          if (execs > 0) harness.early = true
          if (harness.waited > 5500) harness.busy = false
          return false
        }
        return !harness.early && execs > 0 && harness.logText.indexOf("waited") !== -1
          && harness.logText.indexOf("for the system to calm down before a") !== -1
      } },
    { name: "relaunches saved apps and sends each window to its workspace",
      until: function() { return harness.service.lastRestoreAt > 0 && harness.wsOf("a") === "3" && harness.wsOf("f") === "5" } },
    { name: "an ignored app is not relaunched",
      until: function() { return !harness.called("fakeapp-c") && harness.called("fakeapp-a") && harness.called("fakeapp-f") } },
    { name: "window rules are set before the launch and switched off after",
      until: function() {
        var on = harness.callsText.indexOf("hypr-session-1")
        var off = harness.callsText.lastIndexOf("set_enabled(false)")
        var launch = harness.callsText.indexOf("exec_cmd")
        return on !== -1 && on < launch && launch < off
      } },
    { name: "a floating window gets its exact size and position",
      until: function() { return harness.called("float({ action = \"enable\"") && harness.called("resize({ x = 300, y = 200") && harness.called("move({ x = 50, y = 60") } },
    { name: "keeps a copy of what was restored and reports it",
      until: function() {
        return JSON.parse(harness.restoredText || "[]").length === 3 && harness.service.lastRestoreText === "tudo no lugar"
          && harness.service.restoring === false && harness.service.watching === true
      } },
    { name: "restoring again over the open apps launches nothing",
      run: function() { harness.launches = harness.callsText.split("exec_cmd").length; harness.service.restore() },
      until: function() {
        return harness.waited > 1000 && !harness.service.restoring && harness.callsText.split("exec_cmd").length === harness.launches
          && harness.logText.indexOf("restore: a already open, left alone") !== -1
      } },
    { name: "the saved session and the restored copy are readable only by the user",
      until: function() { return harness.modeText === "600 600" } },
    { name: "logs the restore",
      until: function() { return harness.logText.indexOf("restore: a 1/1 windows -> 3") !== -1 && harness.logText.indexOf("restore: 2 apps") !== -1 } }
  ]


  Process {
    id: fixture
    running: true
    command: ["sh", "-c", 'printf "%s" "$1" >"$3" && printf "%s" "$2" >"$4"',
      "_",
      JSON.stringify([
        { cmd: ["fakeapp-a"], class: "a", workspaces: ["3"], geometry: [{ at: [0, 0], size: [100, 100], floating: false }] },
        { cmd: ["fakeapp-c"], class: "c", workspaces: ["4"], geometry: [{ at: [0, 0], size: [100, 100], floating: false }] },
        { cmd: ["fakeapp-f", "--x"], class: "f", workspaces: ["5"], geometry: [{ at: [50, 60], size: [300, 200], floating: true }] }
      ]),
      JSON.stringify({ ignored: ["c"] }),
      harness.home + "/.local/state/hypr-session.json", harness.settingsPath]
    onExited: function(code) {
      if (code !== 0) return harness.finish("could not write fixtures")
      harness.service = serviceComponent.createObject(harness)
      harness.advance()
    }
  }


  // Keeps the cpu pressure fully stalled (+1s of stall every 200ms) while busy
  Process {
    id: busyWriter
    command: ["sh", "-c", 'printf "some avg10=0.00 avg60=0.00 avg300=0.00 total=%s\\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\\n" "$1" >"$2/cpu"', "_", String(harness.busyTotal), harness.pressureDir]
  }
  Timer {
    interval: 200; repeat: true; running: harness.busy
    onTriggered: { harness.busyTotal += 1000000; busyWriter.running = true }
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
      readClients.running = true
      readRestored.running = true
      readLog.running = true
      readMode.running = true
      var step = harness.steps[harness.stepIndex]
      if (!harness.ran) { harness.ran = true; if (step.run) step.run() }
      harness.waited += interval
      var ok = false
      try { ok = step.until() } catch (e) { console.log("step threw: " + e) }
      if (ok) { stop(); console.log("ok  - " + step.name); harness.advance(); return }
      if (harness.waited > 30000) { stop(); harness.finish("timed out: " + step.name + "\ncalls: " + harness.callsText + "\nclients: " + harness.clientsText + "\nlog: " + harness.logText) }
    }
  }

  function finish(error) {
    if (error) console.log("SESSION_FAIL " + error)
    else console.log("SESSION_PASS")
    Qt.quit()
  }
}
