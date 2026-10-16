import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "Model.js" as Model

// Saves the Hyprland session as windows change and puts it back after a
// reboot: apps on their workspaces, terminals running what they ran, and the
// exact dwindle layout, rebuilt without focusing or showing anything.
//
// What to save and how to lay it out is decided in Model.js (pure, tested
// under node). This file does the I/O: it reads /proc, runs hyprctl and
// waits. The restore is a long sequence of "do, wait, check" steps, so it is
// written as generators run by `co()` (this QML has no async/await).
//
// The state files and their format are the ones the old bash script used:
//   ~/.local/state/hypr-session.json           saved session
//   ~/.local/state/hypr-session.restored.json  what the last boot restored
//   ~/.local/state/hypr-session.log            what happened
Item {
  id: root

  // Injected by omarchy-shell.
  property var shell: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")
  readonly property string statePath: Quickshell.env("HYPR_SESSION_FILE") || (stateDir + "/hypr-session.json")
  readonly property string restoredPath: statePath.replace(/\.json$/, "") + ".restored.json"
  readonly property string logPath: statePath.replace(/\.json$/, "") + ".log"
  readonly property string settingsDir: home + "/.local/state/omarchy/settings"
  readonly property string settingsPath: settingsDir + "/hypr-session.json"
  readonly property string markerPath: Quickshell.env("HYPR_SESSION_MARKER") || ((Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/hypr-session.restored."
    + Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE"))

  // ---- State shown by the panel ------------------------------------------------

  property var settings: Model.defaultSettings()
  property bool settingsLoaded: false
  property real lastSaveAt: 0
  property int lastSaveApps: 0
  property real lastRestoreAt: 0
  property string lastRestoreText: ""
  property bool restoring: false
  property bool watching: false
  property var openClasses: []

  property string stateText: ""
  property bool stateKnown: false
  property bool saving: false
  property bool saveAgain: false
  property bool ending: false
  property int logWrites: 0
  property string sessionEnv: ""

  // ---- Plumbing: processes, timers, files -----------------------------------------

  Component {
    id: procFactory
    Process {
      id: p
      property var done: null
      property string out: ""
      property int code: -1
      property bool streamDone: false
      property bool exitDone: false
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: { p.out = text; p.streamDone = true; p.settle() }
      }
      onExited: function(exitCode) { p.code = exitCode; p.exitDone = true; p.settle() }
      function settle() {
        if (!streamDone || !exitDone) return
        if (done) done({ out: out, code: code })
        destroy()
      }
    }
  }

  Component {
    id: timerFactory
    Timer {
      property var done: null
      repeat: false
      onTriggered: { if (done) done(); destroy() }
    }
  }

  Component {
    id: readerFactory
    FileView { blockLoading: true; printErrors: false }
  }

  // Runs argv, resolves { out, code }.
  function run(argv) {
    return new Promise(function(resolve) {
      var p = procFactory.createObject(root, { command: argv, done: resolve })
      p.running = true
    })
  }

  function sleep(ms) {
    return new Promise(function(resolve) {
      var t = timerFactory.createObject(root, { interval: ms, done: resolve })
      t.running = true
    })
  }

  // Runs a generator as a sequence of steps; every yielded Promise is awaited.
  function co(generator) {
    return new Promise(function(resolve, reject) {
      var it = generator()
      function step(method, arg) {
        var r
        try { r = it[method](arg) } catch (e) { reject(e); return }
        if (r.done) resolve(r.value)
        else Promise.resolve(r.value).then(function(v) { step("next", v) }, function(e) { step("throw", e) })
      }
      step("next")
    })
  }

  // Reads a (small, /proc style) file at once.
  function readFile(path) {
    var reader = readerFactory.createObject(root, { path: path })
    var text = ""
    try { text = reader.text() } catch (e) { text = "" }
    reader.destroy()
    return text
  }

  function hypr(args) { return run(["hyprctl"].concat(args)) }
  function hyprJson(args) {
    return hypr(args).then(function(r) {
      try { return JSON.parse(r.out) } catch (e) { return null }
    })
  }
  function dispatch(lua) {
    return hypr(["dispatch", lua]).then(function() { return sleep(150) })
  }

  function log(message) {
    run(["sh", "-c", 'printf "%s" "$1" >>"$2"', "_", Model.logLine(new Date(), message), logPath])
    if (++logWrites % 50 === 0) trimLog()
  }
  function trimLog() {
    run(["cat", logPath]).then(function(r) {
      var trimmed = Model.trimLog(r.out)
      if (trimmed !== null) logWriter.setText(trimmed)
    })
  }

  FileView { id: logWriter; path: root.logPath; atomicWrites: true; printErrors: false }
  FileView { id: stateWriter; path: root.statePath; atomicWrites: true; printErrors: false }
  FileView { id: restoredWriter; path: root.restoredPath; atomicWrites: true; printErrors: false }
  FileView { id: settingsWriter; path: root.settingsPath; atomicWrites: true; printErrors: false }

  // ---- Settings -----------------------------------------------------------------

  function setSetting(key, value) {
    if (!(key in settings) || key === "ignored" || typeof settings[key] !== "boolean") return false
    var next = JSON.parse(JSON.stringify(settings))
    next[key] = value === true
    persistSettings(next)
    return true
  }

  function setIgnored(cls, ignored) { persistSettings(Model.withIgnored(settings, cls, ignored)) }

  function persistSettings(next) {
    settings = next
    run(["mkdir", "-p", settingsDir]).then(function() { settingsWriter.setText(Model.serializeSettings(next)) })
  }

  // ---- Shutdown detection -----------------------------------------------------------

  function isShuttingDown() {
    return co(function*() {
      var facts = { uwsmStop: false, systemState: "", timerExecStarts: [] }
      facts.uwsmStop = (yield run(["pgrep", "-f", "uwsm stop"])).code === 0
      if (facts.uwsmStop) return true
      facts.systemState = (yield run(["systemctl", "is-system-running"])).out
      if (Model.shuttingDown(facts)) return true
      var timers = (yield run(["systemctl", "--user", "list-units", "--type=timer", "--plain", "--no-legend", "run-*"])).out
      var names = timers.split("\n").map(function(l) { return l.trim().split(/\s+/)[0] }).filter(function(n) { return n })
      for (var i = 0; i < names.length; i++) {
        var service = names[i].replace(/\.timer$/, ".service")
        facts.timerExecStarts.push((yield run(["systemctl", "--user", "show", service, "-p", "ExecStart", "--value"])).out)
      }
      return Model.shuttingDown(facts)
    })
  }

  // ---- Save ---------------------------------------------------------------------------

  // Seconds since the epoch when process `pid` started.
  function procStart(pid) {
    var stat = readFile("/proc/" + pid + "/stat")
    var tail = stat.slice(stat.lastIndexOf(")") + 2).split(" ")
    var ticks = parseInt(tail[19], 10)
    var boot = /^btime (\d+)/m.exec(readFile("/proc/stat"))
    return isNaN(ticks) || !boot ? 0 : parseInt(boot[1], 10) + Math.floor(ticks / 100)
  }

  // Process table: { children: {pid: [pid]}, name: {pid: comm} }.
  function processTable() {
    return run(["ps", "-eo", "pid=,ppid=,comm="]).then(function(r) {
      var table = { children: {}, name: {} }
      r.out.split("\n").forEach(function(line) {
        var m = /^\s*(\d+)\s+(\d+)\s+(.*)$/.exec(line)
        if (!m) return
        table.name[m[1]] = m[3]
        ;(table.children[m[2]] || (table.children[m[2]] = [])).push(m[1])
      })
      Object.keys(table.children).forEach(function(k) { table.children[k].sort(function(a, b) { return a - b }) })
      return table
    })
  }

  // cwd of each pid, as { pid: path }.
  function cwds(pids) {
    if (!pids.length) return Promise.resolve({})
    var argv = ["find"].concat(pids.map(function(p) { return "/proc/" + p }), ["-maxdepth", "1", "-name", "cwd", "-printf", "%h\\t%l\\n"])
    return run(argv).then(function(r) {
      var out = {}
      r.out.split("\n").forEach(function(line) {
        var tab = line.indexOf("\t")
        if (tab > 0) out[line.slice(0, tab).replace("/proc/", "")] = line.slice(tab + 1)
      })
      return out
    })
  }

  // The program running inside terminal `pid`: { cwd, command } or null.
  function terminalProgram(pid, table, cwdOf) {
    return co(function*() {
      var queue = [String(pid)]
      while (queue.length) {
        var current = queue.shift()
        queue = queue.concat(table.children[current] || [])
        var name = table.name[current] || ""
        var cwd = cwdOf[current] || ""
        var id = ""
        if (name === "claude") {
          try { id = JSON.parse(readFile(home + "/.claude/sessions/" + current + ".json")).sessionId || "" } catch (e) { id = "" }
        } else if (name === "codex") {
          var start = procStart(current)
          var sql = "select id from threads where cwd = '" + cwd.replace(/'/g, "''") + "' and updated_at >= " + start
            + " order by updated_at desc limit 1"
          id = (yield run(["sqlite3", "-readonly", home + "/.codex/state_5.sqlite", sql])).out.trim()
        } else if (name === "pi") {
          var dir = home + "/.pi/agent/sessions/--" + cwd.replace(/^\//, "").replace(/\//g, "-") + "--"
          var found = (yield run(["find", dir, "-name", "*.jsonl", "-newermt", "@" + procStart(current), "-printf", "%T@ %f\\n"])).out
          var newest = found.split("\n").filter(function(l) { return l }).sort(function(a, b) { return parseFloat(b) - parseFloat(a) })[0] || ""
          var m = /_([0-9a-f-]+)\.jsonl$/.exec(newest)
          id = m ? m[1] : ""
        }
        var args = Model.agentName(name) ? [] : Model.parseCmdline(readFile("/proc/" + current + "/cmdline"))
        var program = Model.classifyProgram(name, cwd, id, args, settings.resumeAgents)
        if (program) return program
      }
      return null
    })
  }

  function save() {
    if (saving) { saveAgain = true; return Promise.resolve() }
    saving = true
    return co(function*() {
      try {
        if (ending || (yield isShuttingDown())) return
        var clients = yield hyprJson(["clients", "-j"])
        if (!clients || clients.length === 0) return // never overwrite with an empty desktop
        root.openClasses = Model.targets(clients, null).map(function(t) { return t.class })
          .filter(function(c, i, all) { return all.indexOf(c) === i }).sort()

        var targets = Model.targets(clients, settings)
        var terminalPids = targets.filter(function(t) { return Model.TERMINALS.indexOf(t.class) !== -1 }).map(function(t) { return t.pid })
        var table = { children: {}, name: {} }
        if (terminalPids.length) table = yield processTable()
        var cwdPids = []
        terminalPids.forEach(function(pid) {
          var queue = [String(pid)]
          while (queue.length && cwdPids.length < 400) {
            var current = queue.shift()
            cwdPids.push(current)
            queue = queue.concat(table.children[current] || [])
          }
        })
        var cwdOf = yield cwds(cwdPids)

        var launcherUrls = null
        var shell = Quickshell.env("SHELL") || "zsh"
        var entries = []
        for (var i = 0; i < targets.length; i++) {
          var t = targets[i]
          var cmdline = readFile("/proc/" + t.pid + "/cmdline")
          if (cmdline === "") continue
          var terminal = Model.TERMINALS.indexOf(t.class) !== -1
          var webUrl = ""
          if (Model.isWebAppClass(t.class)) {
            if (launcherUrls === null) {
              var grep = yield run(["grep", "-rhs", "--include=*.desktop", "^Exec=omarchy-launch-webapp", home + "/.local/share/applications"])
              launcherUrls = grep.out.split("\n").map(Model.launcherUrl).filter(function(u) { return u })
            }
            webUrl = Model.webAppUrl(t.class, launcherUrls)
          }
          var program = null
          if (terminal) program = yield terminalProgram(t.pid, table, cwdOf)
          var entry = Model.buildEntry({
            class: t.class,
            windows: Model.windowsOf(clients, t.pid, t.class),
            cmdline: cmdline,
            webUrl: webUrl,
            cwd: terminal ? (table.children[String(t.pid)] && cwdOf[table.children[String(t.pid)][0]]) || "" : "",
            program: program,
            env: terminal || Model.isWebAppClass(t.class) ? {} : Model.envDiff(sessionEnv, readFile("/proc/" + t.pid + "/environ")),
            shell: shell
          })
          if (entry) entries.push(entry)
        }

        var text = Model.serializeEntries(entries)
        root.lastSaveAt = Date.now()
        root.lastSaveApps = entries.length
        if (text !== stateText) {
          yield run(["mkdir", "-p", stateDir])
          stateWriter.setText(text)
          stateText = text
          log("save: " + Model.summary(entries))
        }
      } catch (e) {
        log("save: failed: " + e)
      }
    }).then(function() {
      saving = false
      if (saveAgain) { saveAgain = false; save() }
    })
  }

  // ---- Restore ------------------------------------------------------------------------

  function addresses(clients) { return (clients || []).map(function(c) { return c.address }) }

  function moveWindow(addr, ws) {
    return hypr(["dispatch", "hl.dsp.window.move({ workspace = \"" + ws + "\", follow = false, window = \"address:" + addr + "\" })"])
  }

  function restore() {
    if (restoring) return Promise.resolve()
    restoring = true
    return co(function*() {
      var read = yield run(["cat", statePath])
      var entries
      try { entries = JSON.parse(read.out) } catch (e) { return }
      entries = Model.restorable(entries, settings)
      if (!entries.length) return
      restoredWriter.setText(read.out)

      var claimed = addresses(yield hyprJson(["clients", "-j"]))
      var placements = []
      var expected = 0
      var rules = Model.rulesLua(Model.ruleSpecs(entries))
      yield hypr(["eval", rules])
      log("restore: " + entries.length + " apps")
      try {
        for (var i = 0; i < entries.length; i++) {
          var entry = entries[i]
          var cls = entry.class
          var known = addresses(yield hyprJson(["clients", "-j"]))

          // A browser restoring its last session reopens its windows and web
          // apps by itself: take those over instead of opening duplicates
          if (/^(google-chrome|chromium|Chromium|brave-browser|chrome-.+)$/.test(cls)) {
            known = claimed.slice()
            yield sleep(1000)
          }
          var already = ((yield hyprJson(["clients", "-j"])) || []).some(function(c) {
            return c.class === cls && known.indexOf(c.address) === -1
          })
          if (!already) yield hypr(["dispatch", Model.launchLua(entry, entry.workspaces[0])])

          // Wait up to 20s for the app's windows and send each to its saved workspace
          var placed = 0
          for (var tick = 0; tick < 40 && placed < entry.workspaces.length; tick++) {
            yield sleep(500)
            var now = (yield hyprJson(["clients", "-j"])) || []
            var fresh = now.filter(function(c) { return c.class === cls && known.indexOf(c.address) === -1 })
            for (var j = 0; j < fresh.length && placed < entry.workspaces.length; j++) {
              var addr = fresh[j].address
              yield moveWindow(addr, entry.workspaces[placed])
              var spot = Model.placement(entry, addr, placed)
              if (spot) placements.push(spot)
              known.push(addr)
              claimed.push(addr)
              placed++
            }
          }
          expected += entry.workspaces.length
          log("restore: " + cls + " " + placed + "/" + entry.workspaces.length + " windows -> " + entry.workspaces.join(" "))
        }
        var off = []
        if (settings.rearrangeLayout) off = yield arrange(placements)
        root.lastRestoreText = placements.length + "/" + expected + " janelas"
          + (settings.rearrangeLayout ? (off.length ? ", layout com " + off.length + " fora" : ", layout ok") : "")
      } finally {
        yield hypr(["eval", Model.RULES_OFF_LUA])
      }
      root.lastRestoreAt = Date.now()
    }).then(function() { restoring = false }, function(e) {
      restoring = false
      log("restore: failed: " + e)
    })
  }

  // Make window `a` the tiled window under the cursor on workspace `ws` (the
  // one dwindle splits next), by moving the split lines around it.
  function aim(a, ws) {
    return co(function*() {
      var cursor = (yield hypr(["cursorpos"])).out.replace(/,/g, " ").trim().split(/\s+/)
      var px = parseFloat(cursor[0]), py = parseFloat(cursor[1])
      var axes = ["x", "y", "x", "y"]
      for (var i = 0; i < axes.length; i++) {
        var clients = (yield hyprJson(["clients", "-j"])) || []
        var plan = Model.aimPlan(clients, a, ws, axes[i], px, py)
        if (plan) yield dispatch("hl.dsp.window.resize({ x = " + plan.w + ", y = " + plan.h + ", window = \"address:" + plan.addr + "\" })")
      }
    })
  }

  function onScreen() {
    return hyprJson(["monitors", "-j"]).then(function(monitors) {
      var names = []
      ;(monitors || []).forEach(function(m) { names.push(m.activeWorkspace.name, m.specialWorkspace.name) })
      return names
    })
  }

  function option(name) {
    return hypr(["getoption", name]).then(function(r) { return (r.out.split("\n")[0].trim().split(/\s+/)[1]) || "" })
  }

  // Put every restored window back where it was, without ever focusing or
  // showing anything: floating ones at their exact position and size, tiled
  // ones rebuilt split by split on their (hidden) workspace, then resized.
  // Returns the windows still off at the end.
  function arrange(placements) {
    return co(function*() {
      var allOff = []
      if (!placements.length) return allOff

      var floaters = placements.filter(function(p) { return p.floating })
      for (var f = 0; f < floaters.length; f++) {
        var fl = floaters[f]
        yield dispatch("hl.dsp.window.float({ action = \"enable\", window = \"address:" + fl.addr + "\" })")
        yield dispatch("hl.dsp.window.resize({ x = " + fl.w + ", y = " + fl.h + ", window = \"address:" + fl.addr + "\" })")
        yield dispatch("hl.dsp.window.move({ x = " + fl.x + ", y = " + fl.y + ", window = \"address:" + fl.addr + "\" })")
      }

      var focusedWindow = yield hyprJson(["activewindow", "-j"])
      var focused = focusedWindow && focusedWindow.address ? focusedWindow.address : ""
      var multiplier = yield option("dwindle:split_width_multiplier")
      var force = yield option("dwindle:force_split")

      var tiled = placements.filter(function(p) { return !p.floating })
      var workspaces = tiled.map(function(p) { return p.ws }).filter(function(w, i, all) { return all.indexOf(w) === i }).sort()
      for (var w = 0; w < workspaces.length; w++) {
        var ws = workspaces[w]
        var wins = tiled.filter(function(p) { return p.ws === ws })
        if (wins.length < 2) continue
        var plan = Model.layoutPlan(wins)
        if (!plan) { log("arrange: " + ws + " is not a dwindle layout, left as launched"); continue }

        // Apps still settling right after launch can knock a split off, so
        // check the result against the saved rectangles and rebuild when off
        var off = []
        var attempt
        for (attempt = 1; attempt <= 3; attempt++) {
          var on = yield onScreen()
          var shown = on.indexOf(ws) !== -1
          // Dwindle splits the focused window whenever it sits on the
          // workspace being built; hand focus to one already on screen.
          var active = yield hyprJson(["activewindow", "-j"])
          if (!shown && active && active.workspace && active.workspace.name === ws) {
            var visible = ((yield hyprJson(["clients", "-j"])) || []).filter(function(c) { return on.indexOf(c.workspace.name) !== -1 })
              .sort(function(a, b) { return a.focusHistoryID - b.focusHistoryID })[0]
            if (visible) yield dispatch("hl.dsp.focus({ window = \"address:" + visible.address + "\" })")
          }

          // Park every window but the first as floating (floating windows are
          // not part of the tiling tree), then tile them back one at a time.
          var s
          for (s = 0; s < plan.splits.length; s++) {
            yield dispatch("hl.dsp.window.float({ action = \"enable\", window = \"address:" + plan.splits[s].add + "\" })")
          }
          for (s = 0; s < plan.splits.length; s++) {
            var split = plan.splits[s]
            if (shown) {
              yield dispatch("hl.dsp.focus({ window = \"address:" + split.base + "\" })")
              yield dispatch("hl.dsp.layout(\"preselect " + split.dir + "\")")
            } else {
              yield aim(split.base, ws)
              var m = split.dir === "r" ? 0.01 : 100
              yield hypr(["eval", "hl.config({ dwindle = { split_width_multiplier = " + m + ", force_split = 2 } })"])
            }
            yield dispatch("hl.dsp.window.float({ action = \"disable\", window = \"address:" + split.add + "\" })")
          }
          yield hypr(["eval", "hl.config({ dwindle = { split_width_multiplier = " + multiplier + ", force_split = " + force + " } })"])

          // Two passes: each resize moves the splits the next window hangs off
          for (var pass = 0; pass < 2; pass++) {
            for (var k = 0; k < wins.length; k++) {
              yield dispatch("hl.dsp.window.resize({ x = " + wins[k].w + ", y = " + wins[k].h + ", window = \"address:" + wins[k].addr + "\" })")
            }
          }

          off = Model.offWindows((yield hyprJson(["clients", "-j"])) || [], wins)
          if (off.length === 0) break
          log("arrange: " + ws + " attempt " + attempt + " off (cursor " + (yield hypr(["cursorpos"])).out.trim() + "): " + off.join("; "))
          yield sleep(2000)
        }
        if (attempt > 3) attempt = 3
        log("arrange: " + ws + " rebuilt (" + wins.length + " windows, attempt " + attempt + (off.length ? ", still off" : "") + ")")
        allOff = allOff.concat(off)
      }

      // Give focus back if that window is on screen (focusing a hidden one would show it)
      if (focused) {
        var onNow = yield onScreen()
        var still = ((yield hyprJson(["clients", "-j"])) || []).some(function(c) { return c.address === focused && onNow.indexOf(c.workspace.name) !== -1 })
        if (still) yield dispatch("hl.dsp.focus({ window = \"address:" + focused + "\" })")
      }
      return allOff
    })
  }

  // ---- Watching -------------------------------------------------------------------------

  function onWindowEvent(name) {
    var delay = Model.eventDelay(name)
    if (delay === null || !watching || !settings.autoSave) return
    // At shutdown every window closes first: cancel the pending save for good
    if (name === "closewindow") {
      isShuttingDown().then(function(down) {
        if (!down) return
        debounce.stop()
        if (!ending) log("watch: session ending, saving stopped")
        ending = true
      })
    }
    debounce.interval = delay * 1000
    debounce.restart()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) { root.onWindowEvent(String(event && event.name ? event.name : "")) }
  }

  Timer {
    id: debounce
    repeat: false
    onTriggered: root.save()
  }

  // Programs started inside a terminal fire no window event: save every 15s
  // too (the file is only rewritten when something changed).
  Timer {
    interval: 15000
    repeat: true
    running: root.watching && root.settings.autoSave
    onTriggered: root.save()
  }

  // ---- Start ----------------------------------------------------------------------------

  // The restore runs once per Hyprland session: a shell restart or a plugin
  // reload must never relaunch the apps.
  function start() {
    return co(function*() {
      sessionEnv = readFile("/proc/" + Quickshell.processId + "/environ")
      var cat = yield run(["cat", statePath])
      if (cat.code === 0) { stateText = cat.out; stateKnown = true }
      var first = (yield run(["sh", "-c", '[ -e "$1" ] && echo no || { : >"$1"; echo yes; }', "_", markerPath])).out.trim() === "yes"
      if (first && settings.restoreOnStart) {
        yield sleep(3000) // let the startup config finish, as the old post-boot hook did
        yield restore()
      }
      watching = true
      yield save()
    })
  }

  Component.onCompleted: {
    run(["cat", settingsPath]).then(function(r) {
      settings = Model.parseSettings(r.out)
      settingsLoaded = true
      start().then(null, function(e) { console.warn("hypr-session: start failed: " + e) })
    })
  }

  // Classes of the windows open now, for the "ignore an app" list.
  function refreshOpen() {
    return hyprJson(["clients", "-j"]).then(function(clients) {
      if (!clients) return
      root.openClasses = Model.targets(clients, null).map(function(t) { return t.class })
        .filter(function(c, i, all) { return all.indexOf(c) === i }).sort()
    })
  }

  function statusPayload() {
    return {
      watching: watching, restoring: restoring, lastSaveAt: lastSaveAt, apps: lastSaveApps,
      lastRestoreAt: lastRestoreAt, lastRestore: lastRestoreText, settings: settings, state: statePath
    }
  }

  IpcHandler {
    target: "hypr-session"

    function save(): string { root.save(); return "ok" }
    function restore(): string { root.restore(); return "ok" }
    function status(): string { return JSON.stringify(root.statusPayload()) }
    function set(key: string, value: string): string {
      return root.setSetting(key, value === "true" || value === "on" || value === "1")
        ? "ok" : "error: options are restoreOnStart, autoSave, rearrangeLayout, resumeAgents"
    }
    function ignore(cls: string): string { root.setIgnored(cls, true); return "ok" }
    function unignore(cls: string): string { root.setIgnored(cls, false); return "ok" }
  }
}
