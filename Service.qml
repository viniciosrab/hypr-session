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
// waits. The restore is a long sequence of "do, wait, check" steps, written
// as Promise chains with `loop()` and `each()`.
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
  property var lastRestore: null
  property bool restoring: false
  property bool watching: false
  property var openClasses: []
  // Open apps (and ignored ones) as { class, name } with readable names.
  property var apps: []
  property var appNames: ({})

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

  // Runs fn() until it resolves to false. Each step is a plain Promise chain:
  // generators resumed from Qt events crashed this Quickshell build.
  function loop(fn) {
    return Promise.resolve(fn()).then(function(again) { return again ? loop(fn) : null })
  }

  // fn(item, index) for each item, one after another.
  function each(list, fn) {
    var i = 0
    return loop(function() {
      if (i >= list.length) return false
      var k = i++
      return Promise.resolve(fn(list[k], k)).then(function() { return true })
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

  function setIgnored(cls, ignored) {
    persistSettings(Model.withIgnored(settings, cls, ignored))
    updateApps(null)
  }

  function persistSettings(next) {
    settings = next
    run(["mkdir", "-p", settingsDir]).then(function() { settingsWriter.setText(Model.serializeSettings(next)) })
  }

  // ---- Shutdown detection -----------------------------------------------------------

  function isShuttingDown() {
    var facts = { uwsmStop: false, systemState: "", timerExecStarts: [] }
    return run(["pgrep", "-f", "uwsm stop"]).then(function(r) {
      facts.uwsmStop = r.code === 0
      if (facts.uwsmStop) return true
      return run(["systemctl", "is-system-running"]).then(function(r2) {
        facts.systemState = r2.out
        if (Model.shuttingDown(facts)) return true
        return run(["systemctl", "--user", "list-units", "--type=timer", "--plain", "--no-legend", "run-*"]).then(function(r3) {
          var names = r3.out.split("\n").map(function(l) { return l.trim().split(/\s+/)[0] }).filter(function(n) { return n })
          return each(names, function(name) {
            return run(["systemctl", "--user", "show", name.replace(/\.timer$/, ".service"), "-p", "ExecStart", "--value"])
              .then(function(r4) { facts.timerExecStarts.push(r4.out) })
          })
        }).then(function() { return Model.shuttingDown(facts) })
      })
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

  // The session an agent process `pid` is in (Claude, Codex, pi), or "".
  function sessionId(name, pid, cwd) {
    if (name === "claude") {
      try { return Promise.resolve(JSON.parse(readFile(home + "/.claude/sessions/" + pid + ".json")).sessionId || "") }
      catch (e) { return Promise.resolve("") }
    }
    if (name === "codex") {
      // Codex logs threads under a shared daemon: the thread last active in
      // this directory since this codex started
      var sql = "select id from threads where cwd = '" + cwd.replace(/'/g, "''") + "' and updated_at >= " + procStart(pid)
        + " order by updated_at desc limit 1"
      return run(["sqlite3", "-readonly", home + "/.codex/state_5.sqlite", sql]).then(function(r) { return r.out.trim() })
    }
    if (name === "pi") {
      // pi keeps one file per session in a folder named after the directory
      var dir = home + "/.pi/agent/sessions/--" + cwd.replace(/^\//, "").replace(/\//g, "-") + "--"
      return run(["find", dir, "-name", "*.jsonl", "-newermt", "@" + procStart(pid), "-printf", "%T@ %f\\n"]).then(function(r) {
        var newest = r.out.split("\n").filter(function(l) { return l }).sort(function(a, b) { return parseFloat(b) - parseFloat(a) })[0] || ""
        var m = /_([0-9a-f-]+)\.jsonl$/.exec(newest)
        return m ? m[1] : ""
      })
    }
    return Promise.resolve("")
  }

  // The program running inside terminal `pid`: { cwd, command } or null.
  function terminalProgram(pid, table, cwdOf) {
    var queue = [String(pid)]
    function next() {
      if (!queue.length) return Promise.resolve(null)
      var current = queue.shift()
      queue = queue.concat(table.children[current] || [])
      var name = table.name[current] || ""
      var cwd = cwdOf[current] || ""
      return sessionId(name, current, cwd).then(function(id) {
        var args = Model.agentName(name) ? [] : Model.parseCmdline(readFile("/proc/" + current + "/cmdline"))
        var program = Model.classifyProgram(name, cwd, id, args, settings.resumeAgents)
        return program ? program : next()
      })
    }
    return next()
  }

  function rememberOpen(clients) {
    var exe = {}
    Model.targets(clients, null).forEach(function(t) {
      if (!(t.class in exe)) exe[t.class] = Model.parseCmdline(readFile("/proc/" + t.pid + "/cmdline"))[0] || ""
    })
    root.openClasses = Object.keys(exe).sort()
    updateApps(exe)
  }

  property var lastExe: ({})

  // The panel's app list: open apps plus ignored ones (so a closed app can
  // be brought back), with names from the installed launchers.
  function updateApps(exe) {
    if (exe) lastExe = exe
    var classes = Object.keys(lastExe)
    settings.ignored.forEach(function(c) { if (classes.indexOf(c) === -1) classes.push(c) })
    var names = appNames
    root.apps = classes.map(function(c) { return { class: c, name: Model.appName(c, names, lastExe[c] || "") } })
      .sort(function(a, b) { return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1 })
  }

  // Name and StartupWMClass of every launcher, the user's own first.
  function loadAppNames() {
    var script = 'for f in "$HOME"/.local/share/applications/*.desktop "$HOME"/.local/share/flatpak/exports/share/applications/*.desktop '
      + '/var/lib/flatpak/exports/share/applications/*.desktop /usr/share/applications/*.desktop; do [ -f "$f" ] && printf "%s\\n" "$f"; done '
      + '| xargs -d "\\n" -r awk \'FNR==1{if(f)print f"\\t"n"\\t"w;f=FILENAME;n="";w="";s=""}/^\\[/{s=$0}'
      + 's=="[Desktop Entry]"&&/^Name=/&&n==""{n=substr($0,6)}s=="[Desktop Entry]"&&/^StartupWMClass=/{w=substr($0,16)}END{if(f)print f"\\t"n"\\t"w}\''
    return run(["sh", "-c", script]).then(function(r) {
      root.appNames = Model.appNames(Model.parseDesktopIndex(r.out))
      updateApps(null)
    })
  }

  function launcherUrls(ctx) {
    if (ctx.launcherUrls) return Promise.resolve(ctx.launcherUrls)
    return run(["grep", "-rhs", "--include=*.desktop", "^Exec=omarchy-launch-webapp", home + "/.local/share/applications"]).then(function(r) {
      ctx.launcherUrls = r.out.split("\n").map(Model.launcherUrl).filter(function(u) { return u })
      return ctx.launcherUrls
    })
  }

  function entryFor(t, clients, ctx) {
    var cmdline = readFile("/proc/" + t.pid + "/cmdline")
    if (cmdline === "") return Promise.resolve(null)
    var terminal = Model.TERMINALS.indexOf(t.class) !== -1
    var web = Model.isWebAppClass(t.class)
    var webUrl = ""
    var urls = web ? launcherUrls(ctx).then(function(list) { webUrl = Model.webAppUrl(t.class, list) }) : Promise.resolve()
    return urls.then(function() {
      return terminal ? terminalProgram(t.pid, ctx.table, ctx.cwdOf) : null
    }).then(function(program) {
      var kids = ctx.table.children[String(t.pid)]
      return Model.buildEntry({
        class: t.class,
        windows: Model.windowsOf(clients, t.pid, t.class),
        cmdline: cmdline,
        webUrl: webUrl,
        cwd: terminal && kids ? ctx.cwdOf[kids[0]] || "" : "",
        program: program,
        env: terminal || web ? {} : Model.envDiff(sessionEnv, readFile("/proc/" + t.pid + "/environ")),
        shell: Quickshell.env("SHELL") || "zsh"
      })
    })
  }

  function snapshot(clients) {
    rememberOpen(clients)
    var targets = Model.targets(clients, settings)
    var terminalPids = targets.filter(function(t) { return Model.TERMINALS.indexOf(t.class) !== -1 }).map(function(t) { return t.pid })
    var ctx = { table: { children: {}, name: {} }, cwdOf: {}, launcherUrls: null }
    var entries = []
    return (terminalPids.length ? processTable() : Promise.resolve(ctx.table)).then(function(table) {
      ctx.table = table
      var pids = []
      terminalPids.forEach(function(pid) {
        var queue = [String(pid)]
        while (queue.length && pids.length < 400) {
          var current = queue.shift()
          pids.push(current)
          queue = queue.concat(table.children[current] || [])
        }
      })
      return cwds(pids)
    }).then(function(cwdOf) {
      ctx.cwdOf = cwdOf
      return each(targets, function(t) {
        return entryFor(t, clients, ctx).then(function(entry) { if (entry) entries.push(entry) })
      })
    }).then(function() { return entries })
  }

  function writeState(entries) {
    var text = Model.serializeEntries(entries)
    root.lastSaveAt = Date.now()
    // Apps, not processes: three terminals are one app
    root.lastSaveApps = entries.map(function(e) { return e.class }).filter(function(c, i, all) { return all.indexOf(c) === i }).length
    if (text === stateText) return Promise.resolve()
    return run(["mkdir", "-p", stateDir]).then(function() {
      stateWriter.setText(text)
      stateText = text
      log("save: " + Model.summary(entries))
    })
  }

  function saveOnce() {
    if (ending) return Promise.resolve()
    return isShuttingDown().then(function(down) {
      if (down) return null
      return hyprJson(["clients", "-j"]).then(function(clients) {
        if (!clients || clients.length === 0) return null // never overwrite with an empty desktop
        return snapshot(clients).then(writeState)
      })
    })
  }

  function save() {
    if (saving) { saveAgain = true; return Promise.resolve() }
    saving = true
    return saveOnce().then(null, function(e) { log("save: failed: " + e) }).then(function() {
      saving = false
      if (saveAgain) { saveAgain = false; save() }
    })
  }

  // ---- Restore ------------------------------------------------------------------------

  function addresses(clients) { return (clients || []).map(function(c) { return c.address }) }

  function moveWindow(addr, ws) {
    return hypr(["dispatch", "hl.dsp.window.move({ workspace = \"" + ws + "\", follow = false, window = \"address:" + addr + "\" })"])
  }

  function rulesOff() { return hypr(["eval", Model.RULES_OFF_LUA]) }

  // Launches one saved app (unless its windows are open already) and sends
  // each new window to its saved workspace. `r` collects across apps.
  function restoreEntry(entry, i, r) {
    var cls = entry.class
    if (r.open[i]) {
      log("restore: " + cls + " already open, left alone")
      return Promise.resolve()
    }
    // A browser restoring its last session reopens its windows and web apps
    // by itself: take those over instead of opening duplicates
    var browser = /^(google-chrome|chromium|Chromium|brave-browser|chrome-.+)$/.test(cls)
    var known = []
    var placed = 0
    return hyprJson(["clients", "-j"]).then(function(clients) {
      known = browser ? r.claimed.slice() : addresses(clients)
      return browser ? sleep(1000) : null
    }).then(function() {
      return hyprJson(["clients", "-j"])
    }).then(function(clients) {
      var already = (clients || []).some(function(c) { return c.class === cls && known.indexOf(c.address) === -1 })
      if (!already) return hypr(["dispatch", Model.launchLua(entry, entry.workspaces[0])])
    }).then(function() {
      // Wait up to 20s for the app's windows
      var tick = 0
      return loop(function() {
        if (tick >= 40 || placed >= entry.workspaces.length) return false
        tick++
        return sleep(500).then(function() {
          return hyprJson(["clients", "-j"])
        }).then(function(clients) {
          var fresh = (clients || []).filter(function(c) { return c.class === cls && known.indexOf(c.address) === -1 })
          return each(fresh, function(c) {
            if (placed >= entry.workspaces.length) return null
            var n = placed++
            known.push(c.address)
            r.claimed.push(c.address)
            var spot = Model.placement(entry, c.address, n)
            if (spot) r.placements.push(spot)
            return moveWindow(c.address, entry.workspaces[n])
          })
        }).then(function() { return true })
      })
    }).then(function() {
      r.expected += entry.workspaces.length
      log("restore: " + cls + " " + placed + "/" + entry.workspaces.length + " windows -> " + entry.workspaces.join(" "))
    })
  }

  function restoreOnce() {
    return run(["cat", statePath]).then(function(read) {
      var entries
      try { entries = JSON.parse(read.out) } catch (e) { return null }
      entries = Model.restorable(entries, settings)
      if (!entries.length) return null
      restoredWriter.setText(read.out)
      var r = { placements: [], expected: 0, claimed: [], open: [] }
      return hyprJson(["clients", "-j"]).then(function(before) {
        r.claimed = addresses(before)
        r.open = Model.alreadyOpen(entries, before || [])
        return hypr(["eval", Model.rulesLua(Model.ruleSpecs(entries))])
      }).then(function() {
        log("restore: " + entries.length + " apps")
        return each(entries, function(entry, i) { return restoreEntry(entry, i, r) })
      }).then(function() {
        return settings.rearrangeLayout ? arrange(r.placements) : []
      }).then(function(off) {
        root.lastRestore = { placed: r.placements.length, expected: r.expected, off: off.length, layout: settings.rearrangeLayout }
        root.lastRestoreText = Model.restoreSummary(root.lastRestore)
      }).then(rulesOff, function(e) {
        return rulesOff().then(function() { throw e })
      }).then(function() { root.lastRestoreAt = Date.now() })
    })
  }

  function restore() {
    if (restoring) return Promise.resolve()
    restoring = true
    return restoreOnce().then(function() { restoring = false }, function(e) {
      restoring = false
      log("restore: failed: " + e)
    })
  }

  // Make window `a` the tiled window under the cursor on workspace `ws` (the
  // one dwindle splits next), by moving the split lines around it.
  function aim(a, ws) {
    return hypr(["cursorpos"]).then(function(r) {
      var cursor = r.out.replace(/,/g, " ").trim().split(/\s+/)
      var px = parseFloat(cursor[0]), py = parseFloat(cursor[1])
      return each(["x", "y", "x", "y"], function(axis) {
        return hyprJson(["clients", "-j"]).then(function(clients) {
          var plan = Model.aimPlan(clients || [], a, ws, axis, px, py)
          if (plan) return dispatch("hl.dsp.window.resize({ x = " + plan.w + ", y = " + plan.h + ", window = \"address:" + plan.addr + "\" })")
        })
      })
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

  // One build of workspace `ws`: park every window but the first as floating
  // (floating windows are not part of the tiling tree), tile them back one
  // split at a time, resize, and return the windows still off.
  function buildOnce(ws, wins, plan, st) {
    var on = []
    var shown = false
    return onScreen().then(function(names) {
      on = names
      shown = on.indexOf(ws) !== -1
      return hyprJson(["activewindow", "-j"])
    }).then(function(active) {
      // Dwindle splits the focused window whenever it sits on the workspace
      // being built; hand focus to one already on screen.
      if (shown || !active || !active.workspace || active.workspace.name !== ws) return null
      return hyprJson(["clients", "-j"]).then(function(clients) {
        var visible = (clients || []).filter(function(c) { return on.indexOf(c.workspace.name) !== -1 })
          .sort(function(a, b) { return a.focusHistoryID - b.focusHistoryID })[0]
        if (visible) return dispatch("hl.dsp.focus({ window = \"address:" + visible.address + "\" })")
      })
    }).then(function() {
      return each(plan.splits, function(split) {
        return dispatch("hl.dsp.window.float({ action = \"enable\", window = \"address:" + split.add + "\" })")
      })
    }).then(function() {
      return each(plan.splits, function(split) {
        var ready = shown
          // On screen, dwindle splits the focused window; it is visible
          // already, so focusing it changes nothing on screen
          ? dispatch("hl.dsp.focus({ window = \"address:" + split.base + "\" })").then(function() {
              return dispatch("hl.dsp.layout(\"preselect " + split.dir + "\")")
            })
          : aim(split.base, ws).then(function() {
              var m = split.dir === "r" ? 0.01 : 100
              return hypr(["eval", "hl.config({ dwindle = { split_width_multiplier = " + m + ", force_split = 2 } })"])
            })
        return ready.then(function() {
          return dispatch("hl.dsp.window.float({ action = \"disable\", window = \"address:" + split.add + "\" })")
        })
      })
    }).then(function() {
      return hypr(["eval", "hl.config({ dwindle = { split_width_multiplier = " + st.multiplier + ", force_split = " + st.force + " } })"])
    }).then(function() {
      // Two passes: each resize moves the splits the next window hangs off
      return each([0, 1], function() {
        return each(wins, function(w) {
          return dispatch("hl.dsp.window.resize({ x = " + w.w + ", y = " + w.h + ", window = \"address:" + w.addr + "\" })")
        })
      })
    }).then(function() {
      return hyprJson(["clients", "-j"])
    }).then(function(clients) {
      return Model.offWindows(clients || [], wins)
    })
  }

  // Apps still settling right after launch can knock a split off, so check
  // the result against the saved rectangles and rebuild when off (3 tries).
  function arrangeWorkspace(ws, tiled, st) {
    var wins = tiled.filter(function(p) { return p.ws === ws })
    if (wins.length < 2) return Promise.resolve([])
    var plan = Model.layoutPlan(wins)
    if (!plan) {
      log("arrange: " + ws + " is not a dwindle layout, left as launched")
      return Promise.resolve([])
    }
    var attempt = 0
    var off = []
    return loop(function() {
      attempt++
      return buildOnce(ws, wins, plan, st).then(function(result) {
        off = result
        if (!off.length) return false
        return hypr(["cursorpos"]).then(function(c) {
          log("arrange: " + ws + " attempt " + attempt + " off (cursor " + c.out.trim() + "): " + off.join("; "))
          if (attempt >= 3) return false
          return sleep(2000).then(function() { return true })
        })
      })
    }).then(function() {
      log("arrange: " + ws + " rebuilt (" + wins.length + " windows, attempt " + attempt + (off.length ? ", still off" : "") + ")")
      return off
    })
  }

  // Give focus back if that window is on screen (focusing a hidden one would show it)
  function refocus(focused) {
    if (!focused) return Promise.resolve()
    var on = []
    return onScreen().then(function(names) {
      on = names
      return hyprJson(["clients", "-j"])
    }).then(function(clients) {
      var still = (clients || []).some(function(c) { return c.address === focused && on.indexOf(c.workspace.name) !== -1 })
      if (still) return dispatch("hl.dsp.focus({ window = \"address:" + focused + "\" })")
    })
  }

  // Put every restored window back where it was, without ever focusing or
  // showing anything: floating ones at their exact position and size, tiled
  // ones rebuilt split by split on their (hidden) workspace, then resized.
  // On a workspace that is not on screen, dwindle splits the window closest
  // to the cursor, side by side or stacked depending on
  // split_width_multiplier. Resolves to the windows still off at the end.
  function arrange(placements) {
    var allOff = []
    if (!placements.length) return Promise.resolve(allOff)
    var st = { focused: "", multiplier: "", force: "" }
    var tiled = placements.filter(function(p) { return !p.floating })
    var workspaces = tiled.map(function(p) { return p.ws }).filter(function(w, i, all) { return all.indexOf(w) === i }).sort()
    return each(placements.filter(function(p) { return p.floating }), function(fl) {
      return dispatch("hl.dsp.window.float({ action = \"enable\", window = \"address:" + fl.addr + "\" })").then(function() {
        return dispatch("hl.dsp.window.resize({ x = " + fl.w + ", y = " + fl.h + ", window = \"address:" + fl.addr + "\" })")
      }).then(function() {
        return dispatch("hl.dsp.window.move({ x = " + fl.x + ", y = " + fl.y + ", window = \"address:" + fl.addr + "\" })")
      })
    }).then(function() {
      return hyprJson(["activewindow", "-j"])
    }).then(function(active) {
      st.focused = active && active.address ? active.address : ""
      return option("dwindle:split_width_multiplier")
    }).then(function(m) {
      st.multiplier = m
      return option("dwindle:force_split")
    }).then(function(f) {
      st.force = f
      return each(workspaces, function(ws) {
        return arrangeWorkspace(ws, tiled, st).then(function(off) { allOff = allOff.concat(off) })
      })
    }).then(function() {
      return refocus(st.focused)
    }).then(function() { return allOff })
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
    sessionEnv = readFile("/proc/" + Quickshell.processId + "/environ")
    loadAppNames()
    // A restore cut short by a shell restart left its window rules on
    return rulesOff().then(function() {
      return run(["cat", statePath])
    }).then(function(cat) {
      if (cat.code === 0) { stateText = cat.out; stateKnown = true }
      return run(["sh", "-c", '[ -e "$1" ] && echo no || { : >"$1"; echo yes; }', "_", markerPath])
    }).then(function(r) {
      var first = r.out.trim() === "yes"
      // let the startup config finish, as the old post-boot hook did
      if (first && settings.restoreOnStart) return sleep(3000).then(function() { return restore() })
    }).then(function() {
      watching = true
      return save()
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
      if (clients) rememberOpen(clients)
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
