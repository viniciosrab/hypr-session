import QtQuick
import Quickshell
import Quickshell.Io
import "plugin" as Plugin

// Drives the real Service.qml against the fake hyprctl (tests/bin): Super + P
// tells the service which window it flipped, the service follows its size,
// remembers it for the app as soon as it changes, and opens the app's next
// window pseudotiled at that size: its main window through a window rule in
// Hyprland, any other tiled one right after it opens. Off, or during a
// restore, it does nothing. The windows it follows survive a shell restart.
ShellRoot {
  id: harness

  readonly property string fake: Quickshell.env("FAKE_HYPR")
  readonly property string pid: Quickshell.env("FAKE_PID")
  readonly property string home: Quickshell.env("HOME")
  readonly property string sizesPath: home + "/.local/state/hypr-session.sizes.json"
  readonly property string trackedPath: home + "/.local/state/hypr-session.pseudo.json"
  readonly property string instance: Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || ""

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
  property string trackedText: ""
  property string trackedMode: ""
  Process {
    id: readTracked
    command: ["sh", "-c", 'cat "$1" && printf "\\nmode=%s" "$(stat -c %a "$1")"', "_", harness.trackedPath]
    stdout: StdioCollector {
      onStreamFinished: {
        var at = text.lastIndexOf("\nmode=")
        harness.trackedText = at === -1 ? "" : text.slice(0, at)
        harness.trackedMode = at === -1 ? "" : text.slice(at + 6).trim()
      }
    }
  }
  function parsed(text) { try { return JSON.parse(text) } catch (e) { return null } }
  Process { id: writeClients; property string json: "[]"; command: ["sh", "-c", 'printf "%s" "$1" >"$2/clients.json"', "_", json, harness.fake] }

  function setClients(list) {
    writeClients.json = JSON.stringify(list.map(function(c) {
      var ws = c[5] || 2
      return { address: c[0], class: c[6] || "fakeapp", initialTitle: c[4] || "Main", pid: Number(harness.pid), workspace: { id: ws, name: String(ws) }, at: [0, 0], size: [c[1], c[2]], floating: !!c[3] }
    }))
    writeClients.running = true
  }

  function called(text) { return harness.callsText.indexOf(text) !== -1 }
  function evals() { return harness.callsText.split("\n").filter(function(l) { return l.indexOf("eval ") === 0 }) }
  function lastEval() { var e = evals(); return e.length ? e[e.length - 1].slice(5) : "" }

  readonly property string rulesOff: "for _, r in ipairs(_G.hypr_session_pseudo_rules or {}) do r:set_enabled(false) end; _G.hypr_session_pseudo_rules = {}"
  // The fake border is 1px: Hyprland's size counts it on both sides
  readonly property string rulesAlone: rulesOff + '; table.insert(_G.hypr_session_pseudo_rules, hl.window_rule({ name = "hypr-session-pseudo-1", match = { class = [==[^(fakeapp)$]==], initial_title = [==[^(Main)$]==], workspace = "w[t0]" }, pseudo = true, size = "702 502" }))'
  readonly property string rulesBoth: rulesAlone + '; table.insert(_G.hypr_session_pseudo_rules, hl.window_rule({ name = "hypr-session-pseudo-2", match = { class = [==[^(fakeapp)$]==], initial_title = [==[^(Main)$]==], workspace = "w[t1-99]" }, pseudo = true, size = "602 402" }))'
  readonly property string sizesAlone: '{\n  "fakeapp": {\n    "alone": [\n      700,\n      500,\n      "Main"\n    ]\n  }\n}\n'
  readonly property string sizesBoth: '{\n  "fakeapp": {\n    "alone": [\n      700,\n      500,\n      "Main"\n    ],\n    "shared": [\n      600,\n      400,\n      "Main"\n    ]\n  }\n}\n'
  function same(a, b) { return JSON.stringify(a) === JSON.stringify(b) }
  property int evalsBefore: 0
  property int resizedAt: -1

  property var service: null
  property int stepIndex: -1
  property int waited: 0
  property bool ran: false

  readonly property var steps: [
    { name: "the service starts watching with the switch on by default",
      until: function() { return harness.service.watching && harness.service.settings.rememberPseudoSize === true } },
    { name: "Super + P on a window makes the service follow its size, alone on its workspace",
      run: function() { harness.service.pseudoToggled("0x1") },
      until: function() {
        var t = harness.service.pseudoTracked["0x1"]
        return !!t && t.pseudo && t.class === "fakeapp" && t.last === "alone" && harness.same(t.sizes, { alone: [800, 600] })
      } },
    { name: "resizing it keeps the app's size in a private file before it closes",
      run: function() { harness.setClients([["0x1", 700, 500]]) },
      until: function() {
        readSizes.running = true
        return harness.same(harness.service.pseudoTracked["0x1"].sizes, { alone: [700, 500] })
          && harness.sizesText === harness.sizesAlone && harness.sizesMode === "600"
      } },
    { name: "beside a tiled window its size is kept as its size there",
      run: function() { harness.setClients([["0x1", 600, 400], ["0x9", 600, 400, false, "Other", 2, "otherapp"]]) },
      until: function() {
        readSizes.running = true
        var t = harness.service.pseudoTracked["0x1"]
        return t.last === "shared" && harness.same(t.sizes, { alone: [700, 500], shared: [600, 400] }) && harness.sizesText === harness.sizesBoth
      } },
    { name: "closing it remembers both sizes of the app in a private file",
      run: function() { harness.setClients([]); harness.service.onHyprEvent("closewindow", "1") },
      until: function() {
        readSizes.running = true
        return harness.sizesText === harness.sizesBoth && harness.sizesMode === "600" && !("0x1" in harness.service.pseudoTracked)
      } },
    { name: "the app gets a rule per size opening its main window pseudotiled at it",
      until: function() { return harness.lastEval() === harness.rulesBoth } },
    { name: "its main window opens alone through the rule, already at its alone size",
      run: function() { harness.setClients([["0x2", 700, 500]]); harness.service.onHyprEvent("openwindow", "2,2,fakeapp,Main") },
      until: function() {
        var t = harness.service.pseudoTracked["0x2"]
        return !!t && t.pseudo && t.last === "alone" && harness.same(t.sizes, { alone: [700, 500] }) && t.title === "Main"
          && harness.waited > 1000 && !harness.called("address:0x2")
      } },
    { name: "its main window opens beside a tiled window through the rule, already at its size there",
      run: function() { harness.setClients([["0x2", 700, 500, false, "Main", 3], ["0x9", 945, 1000, false, "Other", 2, "otherapp"], ["0xb", 600, 400]]); harness.service.onHyprEvent("openwindow", "b,2,fakeapp,Main") },
      until: function() {
        var t = harness.service.pseudoTracked["0xb"]
        return !!t && t.pseudo && t.last === "shared" && harness.same(t.sizes, { shared: [600, 400] })
          && harness.waited > 1000 && !harness.called("address:0xb")
      } },
    { name: "its main window shown again without the rule (from the tray) is pseudotiled right after",
      run: function() { harness.resizedAt = -1; harness.setClients([["0x2", 700, 500, false, "Main", 3], ["0x7", 1900, 1000]]); harness.service.onHyprEvent("openwindow", "7,2,fakeapp,Main") },
      until: function() {
        var t = harness.service.pseudoTracked["0x7"]
        if (harness.resizedAt === -1 && harness.called('hl.dsp.window.pseudo({ action = "enable", window = "address:0x7" })')
            && harness.called('hl.dsp.window.resize({ x = 700, y = 500, window = "address:0x7" })') && t && t.pseudo) {
          // The fake hyprctl doesn't resize: show the window at its new size
          harness.resizedAt = harness.waited
          harness.setClients([["0x2", 700, 500, false, "Main", 3], ["0x7", 700, 500]])
        }
        return harness.resizedAt !== -1 && harness.waited - harness.resizedAt > 2500 && harness.same(t.sizes, { alone: [700, 500] })
      } },
    { name: "closing it keeps the app's sizes",
      run: function() { harness.setClients([["0x2", 700, 500, false, "Main", 3]]); harness.service.onHyprEvent("closewindow", "7") },
      until: function() {
        readSizes.running = true
        return !("0x7" in harness.service.pseudoTracked) && harness.sizesText === harness.sizesBoth
      } },
    { name: "another tiled window of the app beside a tiled window is pseudotiled at its size there right after it opens",
      run: function() { harness.setClients([["0x2", 700, 500, false, "Main", 3], ["0x9", 945, 1000, false, "Other", 2, "otherapp"], ["0x6", 945, 1000, false, "Other"]]); harness.service.onHyprEvent("openwindow", "6,2,fakeapp,Other") },
      until: function() {
        return harness.called('hl.dsp.window.pseudo({ action = "enable", window = "address:0x6" })')
          && harness.called('hl.dsp.window.resize({ x = 600, y = 400, window = "address:0x6" })')
          && harness.service.pseudoTracked["0x6"] && harness.service.pseudoTracked["0x6"].pseudo
      } },
    { name: "Super + P off on it, then closing it, forgets only the app's size beside a tiled window",
      run: function() {
        harness.service.pseudoToggled("0x6")
        harness.setClients([["0x2", 700, 500, false, "Main", 3], ["0x9", 945, 1000, false, "Other", 2, "otherapp"]])
        harness.service.onHyprEvent("closewindow", "6")
      },
      until: function() {
        readSizes.running = true
        return !("0x6" in harness.service.pseudoTracked) && harness.sizesText === harness.sizesAlone && harness.lastEval() === harness.rulesAlone
      } },
    { name: "its main window opening beside a tiled window with no size there tiles, even pseudotiled by a rule",
      run: function() { harness.setClients([["0x2", 700, 500, false, "Main", 3], ["0x9", 945, 1000, false, "Other", 2, "otherapp"], ["0xa", 700, 500]]); harness.service.onHyprEvent("openwindow", "a,2,fakeapp,Main") },
      until: function() {
        return harness.called('hl.dsp.window.pseudo({ action = "disable", window = "address:0xa" })') && !("0xa" in harness.service.pseudoTracked)
      } },
    { name: "another tiled window of the app beside a tiled window with no size there tiles",
      run: function() { harness.setClients([["0x2", 700, 500, false, "Main", 3], ["0x9", 945, 1000, false, "Other", 2, "otherapp"], ["0x8", 945, 1000, false, "Other"]]); harness.service.onHyprEvent("openwindow", "8,2,fakeapp,Other") },
      until: function() { return harness.waited > 2500 && !harness.called("address:0x8") && !("0x8" in harness.service.pseudoTracked) } },
    { name: "a config reload drops the rules, so they are made again",
      run: function() { harness.evalsBefore = harness.evals().length; harness.service.onHyprEvent("configreloaded", "") },
      until: function() { return harness.evals().length > harness.evalsBefore && harness.lastEval() === harness.rulesAlone } },
    { name: "a floating window of the app is left alone",
      run: function() { harness.setClients([["0x2", 700, 500], ["0x3", 400, 300, true]]); harness.service.onHyprEvent("openwindow", "3,2,fakeapp,title") },
      until: function() { return harness.waited > 2500 && !harness.called("address:0x3") } },
    { name: "during a restore a new window is left alone",
      run: function() { harness.service.restoring = true; harness.setClients([["0x2", 700, 500], ["0x4", 1900, 1000, false, "title", 4]]); harness.service.onHyprEvent("openwindow", "4,4,fakeapp,title") },
      until: function() { return harness.waited > 2500 && !harness.called("address:0x4") && harness.lastEval() === harness.rulesOff } },
    { name: "switched off, Super + P is not followed and new windows are left alone",
      run: function() {
        harness.service.restoring = false
        harness.service.setSetting("rememberPseudoSize", false)
        harness.service.pseudoToggled("0x2")
        harness.setClients([["0x2", 700, 500], ["0x5", 1900, 1000, false, "title", 4]])
        harness.service.onHyprEvent("openwindow", "5,4,fakeapp,title")
      },
      until: function() {
        return harness.waited > 2500 && !harness.called("address:0x5") && harness.service.pseudoTracked["0x2"].pseudo === true
          && harness.lastEval() === harness.rulesOff
      } },
    { name: "Super + P on the plugin's own window alone, then closing it, forgets the app's last size",
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
      } },
    { name: "the windows followed are kept, with the Hyprland instance, in a private file",
      run: function() { harness.setClients([["0xc", 800, 600]]); harness.service.pseudoToggled("0xc") },
      until: function() {
        readTracked.running = true
        var f = harness.parsed(harness.trackedText)
        return !!f && f.instance === harness.instance && !!f.windows["0xc"] && f.windows["0xc"].pseudo === true
          && f.windows["0xc"].class === "fakeapp" && harness.trackedMode === "600"
      } },
    { name: "after a shell restart the window is still followed, and its new size kept",
      run: function() {
        harness.service.destroy()
        harness.service = null
        harness.setClients([["0xc", 650, 450]])
      },
      until: function() {
        if (!harness.service) {
          if (harness.waited >= 600) harness.service = serviceComponent.createObject(harness)
          return false
        }
        readSizes.running = true
        var t = harness.service.pseudoTracked["0xc"]
        var sizes = harness.parsed(harness.sizesText)
        return !!t && t.pseudo && !!sizes && harness.same(sizes, { fakeapp: { alone: [650, 450, "Main"] } })
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
