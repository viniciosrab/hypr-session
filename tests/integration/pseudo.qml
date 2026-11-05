import QtQuick
import Quickshell
import Quickshell.Io
import "plugin" as Plugin

// Drives the real Service.qml against the fake hyprctl (tests/bin): Super + P
// tells the service which window it flipped, the service follows its size,
// remembers it for the app when the window closes, and opens the app's next
// window pseudotiled at that size: its main window through a window rule in
// Hyprland, any other tiled one right after it opens. Off, or during a
// restore, it does nothing.
ShellRoot {
  id: harness

  readonly property string fake: Quickshell.env("FAKE_HYPR")
  readonly property string pid: Quickshell.env("FAKE_PID")
  readonly property string home: Quickshell.env("HOME")
  readonly property string sizesPath: home + "/.local/state/hypr-session.sizes.json"

  property string callsText: ""
  property string sizesText: ""
  property string sizesMode: ""
  Process { id: readCalls; command: ["cat", harness.fake + "/calls"]; stdout: StdioCollector { onStreamFinished: harness.callsText = text } }
  Process {
    id: readSizes
    command: ["sh", "-c", 'cat "$1" && printf "\\nmode=%s" "$(stat -c %a "$1")"', "_", harness.sizesPath]
    stdout: StdioCollector {
      onStreamFinished: {
        var at = text.lastIndexOf("\nmode=")
        harness.sizesText = at === -1 ? "" : text.slice(0, at)
        harness.sizesMode = at === -1 ? "" : text.slice(at + 6).trim()
      }
    }
  }
  Process { id: writeClients; property string json: "[]"; command: ["sh", "-c", 'printf "%s" "$1" >"$2/clients.json"', "_", json, harness.fake] }

  function setClients(list) {
    writeClients.json = JSON.stringify(list.map(function(c) {
      return { address: c[0], class: "fakeapp", initialTitle: c[4] || "Main", pid: Number(harness.pid), workspace: { id: 2, name: "2" }, at: [0, 0], size: [c[1], c[2]], floating: !!c[3] }
    }))
    writeClients.running = true
  }

  function called(text) { return harness.callsText.indexOf(text) !== -1 }
  function evals() { return harness.callsText.split("\n").filter(function(l) { return l.indexOf("eval ") === 0 }) }
  function lastEval() { var e = evals(); return e.length ? e[e.length - 1].slice(5) : "" }

  readonly property string rulesOff: "for _, r in ipairs(_G.hypr_session_pseudo_rules or {}) do r:set_enabled(false) end; _G.hypr_session_pseudo_rules = {}"
  // The fake border is 1px: Hyprland's size counts it on both sides
  readonly property string rulesOn: rulesOff + '; table.insert(_G.hypr_session_pseudo_rules, hl.window_rule({ name = "hypr-session-pseudo-1", match = { class = [==[^(fakeapp)$]==], initial_title = [==[^(Main)$]==] }, pseudo = true, size = "702 502" }))'
  property int evalsBefore: 0

  property var service: null
  property int stepIndex: -1
  property int waited: 0
  property bool ran: false

  readonly property var steps: [
    { name: "the service starts watching with the switch on by default",
      until: function() { return harness.service.watching && harness.service.settings.rememberPseudoSize === true } },
    { name: "Super + P on a window makes the service follow its size",
      run: function() { harness.service.pseudoToggled("0x1") },
      until: function() {
        var t = harness.service.pseudoTracked["0x1"]
        return !!t && t.pseudo && t.class === "fakeapp" && t.size && t.size[0] === 800 && t.size[1] === 600
      } },
    { name: "resizing it is followed",
      run: function() { harness.setClients([["0x1", 700, 500]]) },
      until: function() { var t = harness.service.pseudoTracked["0x1"]; return t.size[0] === 700 && t.size[1] === 500 } },
    { name: "closing it remembers the app's size in a private file",
      run: function() { harness.setClients([]); harness.service.onHyprEvent("closewindow", "1") },
      until: function() {
        readSizes.running = true
        return harness.sizesText === '{\n  "fakeapp": [\n    700,\n    500,\n    "Main"\n  ]\n}\n' && harness.sizesMode === "600"
          && !("0x1" in harness.service.pseudoTracked)
      } },
    { name: "the app gets a rule opening its main window pseudotiled at that size",
      until: function() { return harness.lastEval() === harness.rulesOn } },
    { name: "its main window opens through the rule, already at the size",
      run: function() { harness.setClients([["0x2", 700, 500]]); harness.service.onHyprEvent("openwindow", "2,2,fakeapp,Main") },
      until: function() {
        var t = harness.service.pseudoTracked["0x2"]
        return !!t && t.pseudo && t.size[0] === 700 && t.size[1] === 500 && t.title === "Main"
          && harness.waited > 1000 && !harness.called("address:0x2")
      } },
    { name: "another tiled window of the app is pseudotiled at that size right after it opens",
      run: function() { harness.setClients([["0x2", 700, 500], ["0x6", 1900, 1000, false, "Other"]]); harness.service.onHyprEvent("openwindow", "6,2,fakeapp,Other") },
      until: function() {
        return harness.called('hl.dsp.window.pseudo({ action = "enable", window = "address:0x6" })')
          && harness.called('hl.dsp.window.resize({ x = 700, y = 500, window = "address:0x6" })')
          && harness.service.pseudoTracked["0x6"] && harness.service.pseudoTracked["0x6"].pseudo
      } },
    { name: "closing that one keeps the main window's title in the rule",
      run: function() { harness.setClients([["0x2", 700, 500]]); harness.service.onHyprEvent("closewindow", "6") },
      until: function() {
        readSizes.running = true
        return !("0x6" in harness.service.pseudoTracked) && harness.sizesText.indexOf('"Main"') !== -1
          && harness.lastEval() === harness.rulesOn
      } },
    { name: "a config reload drops the rules, so they are made again",
      run: function() { harness.evalsBefore = harness.evals().length; harness.service.onHyprEvent("configreloaded", "") },
      until: function() { return harness.evals().length > harness.evalsBefore && harness.lastEval() === harness.rulesOn } },
    { name: "a floating window of the app is left alone",
      run: function() { harness.setClients([["0x2", 700, 500], ["0x3", 400, 300, true]]); harness.service.onHyprEvent("openwindow", "3,2,fakeapp,title") },
      until: function() { return harness.waited > 2500 && !harness.called("address:0x3") } },
    { name: "during a restore a new window is left alone",
      run: function() { harness.service.restoring = true; harness.setClients([["0x2", 700, 500], ["0x4", 1900, 1000]]); harness.service.onHyprEvent("openwindow", "4,2,fakeapp,title") },
      until: function() { return harness.waited > 2500 && !harness.called("address:0x4") && harness.lastEval() === harness.rulesOff } },
    { name: "switched off, Super + P is not followed and new windows are left alone",
      run: function() {
        harness.service.restoring = false
        harness.service.setSetting("rememberPseudoSize", false)
        harness.service.pseudoToggled("0x2")
        harness.setClients([["0x2", 700, 500], ["0x5", 1900, 1000]])
        harness.service.onHyprEvent("openwindow", "5,2,fakeapp,title")
      },
      until: function() {
        return harness.waited > 2500 && !harness.called("address:0x5") && harness.service.pseudoTracked["0x2"].pseudo === true
          && harness.lastEval() === harness.rulesOff
      } },
    { name: "Super + P on the plugin's own window then closing it forgets the app's size",
      run: function() {
        harness.service.setSetting("rememberPseudoSize", true)
        harness.service.pseudoToggled("0x2")
        harness.setClients([])
        harness.service.onHyprEvent("closewindow", "2")
      },
      until: function() {
        readSizes.running = true
        return harness.sizesText === "{}\n" && Object.keys(harness.service.pseudoSizes).length === 0
          && harness.lastEval() === harness.rulesOff
      } }
  ]

  Process {
    id: fixture
    running: true
    command: ["sh", "-c", 'printf "%s" "$1" >"$2/clients.json"', "_",
      JSON.stringify([{ address: "0x1", class: "fakeapp", initialTitle: "Main", pid: Number(harness.pid), workspace: { id: 2, name: "2" }, at: [0, 0], size: [800, 600], floating: false }]),
      harness.fake]
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
      var step = harness.steps[harness.stepIndex]
      if (!harness.ran) { harness.ran = true; if (step.run) step.run() }
      harness.waited += interval
      var ok = false
      try { ok = step.until() } catch (e) { console.log("step threw: " + e) }
      if (ok) { stop(); console.log("ok  - " + step.name); harness.advance(); return }
      if (harness.waited > 12000) { stop(); harness.finish("timed out: " + step.name + "\ncalls: " + harness.callsText + "\nsizes: " + harness.sizesText) }
    }
  }

  function finish(error) {
    if (error) console.log("SESSION_FAIL " + error)
    else console.log("SESSION_PASS")
    Qt.quit()
  }
}
