// hypr-session model: the pure rules of saving and restoring a session. No
// I/O, so it runs under node for the unit tests (tests/model.test.js) as well
// as inside QML (Service.qml does the reading, spawning and waiting).
//
// An "entry" is one saved app: { cmd: [argv], class, workspaces: [names],
// geometry: [{at, size, floating}], env? }. The state file is a JSON array of
// entries, the same format the old bash script wrote.

var TERMINALS = ["foot", "Alacritty", "com.mitchellh.ghostty", "kitty"]
var BROWSERS = ["google-chrome", "chromium", "Chromium", "brave-browser"]
var PLAIN_PROGRAMS = ["nvim", "vim", "btop", "htop", "lazygit", "lazydocker", "yazi"]
// Programs whose terminal comes back as a plain shell in their folder: not
// relaunched, and the agents running inside them are not resumed either.
var SHELL_ONLY = ["herdr"]
var LAYOUT_TOLERANCE = 6
var OFF_TOLERANCE = 12

// Variables that change on every login or belong to the launcher, not the
// app. PATH too: a saved one goes stale, the session's own is the right one.
var ENV_SKIP = /^(_|PATH|PWD|OLDPWD|SHLVL|INVOCATION_ID|JOURNAL_STREAM|SYSTEMD_EXEC_PID|MANAGERPID|MANAGERPIDFDID|DESKTOP_STARTUP_ID|XDG_ACTIVATION_TOKEN|HYPRLAND_INSTANCE_SIGNATURE|HYPRLAND_CMD|DBUS_SESSION_BUS_ADDRESS|XDG_SESSION_ID|XDG_VTNR|HL_EXEC_RULE_TOKEN|GIO_LAUNCHED_DESKTOP_FILE|GIO_LAUNCHED_DESKTOP_FILE_PID|CHROME_DESKTOP|CHROME_WRAPPER|ELECTRON_[A-Z_]*|VSCODE_[A-Z_]*|NODE_OPTIONS)=/

// ---- Settings ---------------------------------------------------------------

function defaultSettings() {
  return { restoreOnStart: true, autoSave: true, rearrangeLayout: true, resumeAgents: true, ignored: [] }
}

function parseSettings(text) {
  var out = defaultSettings()
  var raw
  try { raw = JSON.parse(text) } catch (e) { return out }
  if (!raw || typeof raw !== "object") return out
  ;["restoreOnStart", "autoSave", "rearrangeLayout", "resumeAgents"].forEach(function(key) {
    if (typeof raw[key] === "boolean") out[key] = raw[key]
  })
  if (Array.isArray(raw.ignored)) {
    raw.ignored.forEach(function(name) {
      if (typeof name === "string" && name !== "" && out.ignored.indexOf(name) === -1) out.ignored.push(name)
    })
  }
  return out
}

function serializeSettings(settings) { return JSON.stringify(settings, null, 2) + "\n" }

function isIgnored(settings, cls) { return settings.ignored.indexOf(cls) !== -1 }

function withIgnored(settings, cls, ignored) {
  var next = JSON.parse(JSON.stringify(settings))
  next.ignored = next.ignored.filter(function(name) { return name !== cls })
  if (ignored && cls) next.ignored.push(cls)
  return next
}

// ---- Shell helpers ------------------------------------------------------------

function shQuote(text) {
  text = String(text)
  return /^[A-Za-z0-9_@%+=:,.\/-]+$/.test(text) ? text : "'" + text.replace(/'/g, "'\\''") + "'"
}

function regexEscape(text) { return String(text).replace(/[\][\\.*^$+?(){}|]/g, "\\$&") }

// ---- Web apps ---------------------------------------------------------------

function isWebAppClass(cls) { return /^chrome-.+-(Default|Profile [0-9]+)$/.test(cls) }

// Chrome names a web app window after its URL: https://discord.com/channels/@me
// becomes chrome-discord.com__channels_@me-Default.
function webAppKey(url) {
  var key = String(url).replace(/^[^:]*:\/\//, "")
  if (key.indexOf("/") === -1) key += "/"
  var slash = key.indexOf("/")
  return key.slice(0, slash) + "_" + ("/" + key.slice(slash + 1)).replace(/\//g, "_")
}

// The URL of an omarchy-launch-webapp launcher (.desktop file text), if it is one.
function launcherUrl(desktopText) {
  var lines = String(desktopText).split("\n")
  for (var i = 0; i < lines.length; i++) {
    var m = /^Exec=omarchy-launch-webapp "?([^" ]+)"?/.exec(lines[i])
    if (m) return m[1]
  }
  return ""
}

// Prefer the exact URL from the installed launchers; otherwise reverse the name.
function webAppUrl(cls, launcherUrls) {
  var id = cls.replace(/^chrome-/, "").replace(/-(Default|Profile [0-9]+)$/, "")
  for (var i = 0; i < launcherUrls.length; i++) {
    if (webAppKey(launcherUrls[i]) === id) return launcherUrls[i]
  }
  var split = id.indexOf("__")
  var host = split === -1 ? id : id.slice(0, split)
  var rest = split === -1 ? id : id.slice(split + 2)
  return "https://" + host + "/" + rest.replace(/_/g, "/")
}

// ---- Processes --------------------------------------------------------------

// Chromium-based apps rewrite their argv into one space-separated string.
function parseCmdline(raw) {
  var args = String(raw).split("\u0000").filter(function(a) { return a !== "" })
  if (args.length === 1) args = args[0].split(" ").filter(function(a) { return a !== "" })
  return args.filter(function(a) { return a.indexOf("--app=") !== 0 })
}

// Variables process `appEnv` was started with that the session itself does
// not have. Both are raw /proc/<pid>/environ texts.
function envDiff(sessionEnv, appEnv) {
  var have = {}
  String(sessionEnv).split("\u0000").forEach(function(line) { have[line] = true })
  var out = {}
  String(appEnv).split("\u0000").forEach(function(line) {
    if (line === "" || have[line] || ENV_SKIP.test(line)) return
    var eq = line.indexOf("=")
    if (eq > 0) out[line.slice(0, eq)] = line.slice(eq + 1)
  })
  return out
}

// What a terminal's child process means for the saved command: the cwd it ran
// in and the shell command that reopens it (null for "just the folder").
// `id` is the session id looked up by the service (Claude, Codex, pi).
function classifyProgram(name, cwd, id, cmdlineArgs, resumeAgents) {
  var agent = null
  if (name === "claude") agent = "claude" + (id ? " --resume " + id : "")
  else if (name === "codex") agent = "codex" + (id ? " resume " + id : "")
  else if (name === "pi") agent = "pi" + (id ? " --session " + id : "")
  if (agent !== null) return { cwd: cwd, command: resumeAgents ? agent : null }
  if (SHELL_ONLY.indexOf(name) !== -1) return { cwd: cwd, command: null }
  if (PLAIN_PROGRAMS.indexOf(name) !== -1) {
    return { cwd: cwd, command: cmdlineArgs.map(shQuote).join(" ") }
  }
  return null
}

// The command that finds the session a Codex or pi process is in: the one
// last active in its directory since `since` (when the process started, in
// seconds). null without a start time, so it never picks another session.
function sessionLookup(name, cwd, since, home) {
  if (!since) return null
  if (name === "codex") {
    // Codex logs threads under a shared daemon
    return ["sqlite3", "-readonly", home + "/.codex/state_5.sqlite", "select id from threads where cwd = '"
      + String(cwd).replace(/'/g, "''") + "' and updated_at >= " + since + " order by updated_at desc limit 1"]
  }
  if (name === "pi") {
    // pi keeps one file per session in a folder named after the directory
    var dir = home + "/.pi/agent/sessions/--" + String(cwd).replace(/^\//, "").replace(/\//g, "-") + "--"
    return ["find", dir, "-name", "*.jsonl", "-newermt", "@" + since, "-printf", "%T@ %f\\n"]
  }
  return null
}

function agentName(name) { return name === "claude" || name === "codex" || name === "pi" }

// ---- Snapshot ---------------------------------------------------------------

function byPlace(a, b) {
  return (a.workspace.id - b.workspace.id) || (a.at[0] - b.at[0]) || (a.at[1] - b.at[1])
}

// Unique [pid, class] pairs of the open windows, in saving order. Web apps
// share the browser's process, so grouping by process alone would fold them.
function targets(clients, settings) {
  var seen = {}
  var out = []
  clients.filter(function(c) { return c.pid > 0 }).sort(byPlace).forEach(function(c) {
    var key = c.pid + "\t" + c.class
    if (seen[key] || (settings && isIgnored(settings, c.class))) return
    seen[key] = true
    out.push({ pid: c.pid, class: c.class })
  })
  return out
}

function windowsOf(clients, pid, cls) {
  return clients.filter(function(c) { return c.pid === pid && c.class === cls }).sort(byPlace)
}

// Builds the entry for one target. `o`: { class, windows, cmdline (raw),
// webUrl, cwd (terminal), program ({cwd, command}|null), env (object), shell }
function buildEntry(o) {
  var cls = o.class
  var workspaces = o.windows.map(function(w) { return w.workspace.name })
  var geometry = o.windows.map(function(w) { return { at: w.at, size: w.size, floating: w.floating } })

  if (isWebAppClass(cls)) {
    return { cmd: ["omarchy-launch-webapp", o.webUrl], class: cls, workspaces: workspaces, geometry: geometry }
  }

  var cmd = parseCmdline(o.cmdline)
  if (cmd.length === 0) return null

  if (BROWSERS.indexOf(cls) !== -1 && cmd.indexOf("--restore-last-session") === -1) cmd.push("--restore-last-session")

  var terminal = TERMINALS.indexOf(cls) !== -1
  if (terminal) {
    var cwd = o.cwd || ""
    if (o.program && o.program.cwd) cwd = o.program.cwd
    if (cwd) {
      var flag = (cls === "kitty" ? "--directory=" : "--working-directory=") + cwd
      var rest = cmd.slice(1).filter(function(a) { return !(a.indexOf("--working-directory") === 0 || a.indexOf("--directory") === 0) })
      cmd = cmd.slice(0, 1).concat([flag], rest)
    }
    if (o.program && o.program.command) {
      var shell = o.shell || "zsh"
      var own = cmd.slice(1).filter(function(a) { return a.indexOf("--") === 0 && a.indexOf("=") !== -1 })
      cmd = cmd.slice(0, 1).concat(own, cls === "foot" || cls === "kitty" ? [] : ["-e"],
        [shell, "-ic", o.program.command + "; exec " + shell])
    }
  }

  var entry = { cmd: cmd, class: cls, workspaces: workspaces, geometry: geometry }
  // Terminals start a fresh shell and program: their env is not carried over
  if (!terminal && o.env && Object.keys(o.env).length > 0) entry.env = o.env
  return entry
}

// Entries to carry over from the previous save: apps that closed their window
// but keep running (tray apps). `remembered`: { class: {entry, pid, cmdline} };
// `alive`: { pid: raw cmdline } read by the service. The cmdline must match
// (the pid may have been reused), no window may be left on that pid (a web
// app closed inside a browser that still has windows), and never terminals.
function keepRunning(remembered, entries, clients, settings, alive) {
  var present = {}
  entries.forEach(function(e) { present[e.class] = true })
  var kept = []
  Object.keys(remembered).forEach(function(cls) {
    var r = remembered[cls]
    if (present[cls] || TERMINALS.indexOf(cls) !== -1 || isIgnored(settings, cls)) return
    if (!r.cmdline || alive[r.pid] !== r.cmdline) return
    if (clients.some(function(c) { return c.pid === r.pid })) return
    kept.push(r.entry)
  })
  return kept
}

function serializeEntries(entries) { return JSON.stringify(entries, null, 2) + "\n" }

function summary(entries) {
  return entries.map(function(e) { return e.class + "@" + e.workspaces.join(",") }).join(" ")
}

// ---- Restore ----------------------------------------------------------------

function restorable(entries, settings) {
  return entries.filter(function(e) { return e && e.cmd && e.cmd.length > 0 && !isIgnored(settings, e.class) })
}

// Which entries already have their windows open (a restore over a live
// desktop, e.g. "Restaurar agora"): open windows of a class are handed out to
// that class's entries in order, and an entry fully covered is skipped.
function alreadyOpen(entries, clients) {
  var left = {}
  clients.forEach(function(c) { left[c.class] = (left[c.class] || 0) + 1 })
  return entries.map(function(e) {
    var n = e.workspaces.length
    if ((left[e.class] || 0) < n) return false
    left[e.class] -= n
    return true
  })
}

// The command line for an entry, with its saved environment in front.
function launchCommand(entry) {
  var env = entry.env ? Object.keys(entry.env).map(function(k) { return k + "=" + entry.env[k] }) : []
  var words = (env.length ? ["env"].concat(env) : []).concat(entry.cmd)
  return words.map(shQuote).join(" ")
}

// Classes whose windows all sat on one workspace: a temporary window rule
// sends them there before they show up (apps that hand their window to an
// instance already running ignore the launch workspace).
function ruleSpecs(entries) {
  var byClass = {}
  entries.forEach(function(e) {
    var set = byClass[e.class] || (byClass[e.class] = [])
    e.workspaces.forEach(function(ws) { if (set.indexOf(ws) === -1) set.push(ws) })
  })
  return Object.keys(byClass).sort().filter(function(cls) { return byClass[cls].length === 1 })
    .map(function(cls) { return { class: cls, workspace: byClass[cls][0] } })
}

var RULES_OFF_LUA = "for _, r in ipairs(_G.hypr_session_rules or {}) do r:set_enabled(false) end; _G.hypr_session_rules = {}"

// Rules live in Hyprland, not in the shell: a restore cut short (shell
// restart, crash) leaves them on, so every new set starts by switching
// the old ones off.
function rulesLua(specs) {
  var lua = RULES_OFF_LUA
  specs.forEach(function(s, i) {
    lua += "; table.insert(_G.hypr_session_rules, hl.window_rule({ name = \"hypr-session-" + (i + 1)
      + "\", match = { class = [==[^(" + regexEscape(s.class) + ")$]==] }, workspace = [==[" + s.workspace + " silent]==] }))"
  })
  return lua
}

function launchLua(entry, workspace) {
  return "hl.dsp.exec_cmd([==[" + launchCommand(entry) + "]==], { workspace = \"" + workspace + " silent\" })"
}

// Where saved window `n` of an entry should end up, once it has opened as `addr`.
function placement(entry, addr, n) {
  var g = entry.geometry && entry.geometry[n]
  if (!g) return null
  return { addr: addr, ws: entry.workspaces[n], x: g.at[0], y: g.at[1], w: g.size[0], h: g.size[1], floating: g.floating }
}

// ---- Layout -----------------------------------------------------------------

// Tiled rectangles are split recursively by a full-height or full-width cut,
// which is exactly how dwindle divides a workspace. Returns
// { first: addr, splits: [{ base, dir: "r"|"d", add }] } meaning: split `base`
// right/down and move `add` in. null when the rectangles are not a clean
// dwindle tree.
function layoutPlan(wins) {
  function cut(ws) {
    var axes = [["r", "x", "w"], ["d", "y", "h"]]
    for (var a = 0; a < axes.length; a++) {
      var d = axes[a][0], pos = axes[a][1], size = axes[a][2]
      var edges = []
      ws.forEach(function(w) { if (edges.indexOf(w[pos] + w[size]) === -1) edges.push(w[pos] + w[size]) })
      edges.sort(function(x, y) { return x - y })
      for (var e = 0; e < edges.length; e++) {
        var edge = edges[e]
        var first = ws.filter(function(w) { return w[pos] + w[size] <= edge + LAYOUT_TOLERANCE })
        var rest = ws.filter(function(w) { return w[pos] >= edge - LAYOUT_TOLERANCE && first.indexOf(w) === -1 })
        if (first.length && rest.length && first.length + rest.length === ws.length) return { dir: d, first: first, rest: rest }
      }
    }
    return null
  }
  function tree(ws) {
    if (ws.length === 1) return ws[0].addr
    var found = cut(ws)
    if (!found) return null
    var a = tree(found.first), b = tree(found.rest)
    return a === null || b === null ? null : [found.dir, a, b]
  }
  function leaf(t) { return typeof t === "string" ? t : leaf(t[1]) }
  function steps(t, base, out) {
    if (typeof t === "string") return
    out.push({ base: base, dir: t[0], add: leaf(t[2]) })
    steps(t[1], base, out)
    steps(t[2], leaf(t[2]), out)
  }
  if (!wins.length) return null
  var t = tree(wins)
  if (t === null) return null
  var splits = []
  steps(t, leaf(t), splits)
  return { first: leaf(t), splits: splits }
}

// The resize that makes window `addr` the tiled window under the cursor on
// workspace `ws` (the one dwindle splits next), for one axis ("x" or "y").
// Dwindle's resize moves a window's right edge, or its left edge when it
// touches the right side of the workspace (same for bottom/top), so each edge
// is moved by whichever window owns it: the window itself or its neighbour.
// Returns { addr, w, h } for hl.dsp.window.resize, or null.
function aimPlan(clients, addr, ws, axis, px, py) {
  var t = clients.filter(function(c) { return c.workspace.name === ws && !c.floating }).map(function(c) {
    return { x1: c.at[0], y1: c.at[1], x2: c.at[0] + c.size[0], y2: c.at[1] + c.size[1], w: c.size[0], h: c.size[1], addr: c.address }
  })
  var me = t.filter(function(b) { return b.addr === addr })[0]
  if (!me) return null
  var area = {
    x1: Math.min.apply(null, t.map(function(b) { return b.x1 })), y1: Math.min.apply(null, t.map(function(b) { return b.y1 })),
    x2: Math.max.apply(null, t.map(function(b) { return b.x2 })), y2: Math.max.apply(null, t.map(function(b) { return b.y2 }))
  }
  var m = 20
  var cx = Math.min(Math.max(px, area.x1 + m), area.x2 - m)
  var cy = Math.min(Math.max(py, area.y1 + m), area.y2 - m)
  var k = axis === "x"
    ? { lo: "x1", hi: "x2", c: cx, crossLo: "y1", crossHi: "y2", len: "w", other: "h" }
    : { lo: "y1", hi: "y2", c: cy, crossLo: "x1", crossHi: "x2", len: "h", other: "w" }
  var atEnd = area[k.hi] - me[k.hi] < 3
  var who = null, d = 0
  if (k.c > me[k.hi]) {
    if (atEnd) return null
    who = me
    d = k.c + m - me[k.hi]
  } else if (k.c < me[k.lo]) {
    d = k.c - m - me[k.lo]
    if (atEnd) who = me
    else {
      who = t.filter(function(b) {
        return b.addr !== addr && Math.abs(me[k.lo] - b[k.hi]) < 16 && b[k.crossLo] < me[k.crossHi] && b[k.crossHi] > me[k.crossLo]
      })[0]
      if (!who) return null
    }
  } else return null
  var length = who[k.len] + d, other = who[k.other]
  return axis === "x" ? { addr: who.addr, w: length, h: other } : { addr: who.addr, w: other, h: length }
}

// The saved windows (placements) that do not sit where they should, as text.
function offWindows(clients, wins) {
  var off = []
  wins.forEach(function(s) {
    var c = clients.filter(function(x) { return x.address === s.addr })[0]
    var delta = c ? Math.max(Math.abs(c.at[0] - s.x), Math.abs(c.at[1] - s.y), Math.abs(c.size[0] - s.w), Math.abs(c.size[1] - s.h)) : Infinity
    if (delta > OFF_TOLERANCE) {
      off.push(s.addr + " want " + s.x + "," + s.y + " " + s.w + "x" + s.h + " got "
        + (c ? c.at[0] + "," + c.at[1] + " " + c.size[0] + "x" + c.size[1] : "gone"))
    }
  })
  return off
}

// ---- Shutdown detection -----------------------------------------------------

// Omarchy's shutdown, reboot and logout close every window before the session
// ends. `facts`: { uwsmStop, systemState, timerExecStarts: [text] }
function shuttingDown(facts) {
  if (facts.uwsmStop) return true
  if (String(facts.systemState).trim() === "stopping") return true
  return (facts.timerExecStarts || []).some(function(text) { return /systemctl (poweroff|reboot)/.test(text) })
}

// ---- Log --------------------------------------------------------------------

function logLine(now, message) {
  function pad(n) { return (n < 10 ? "0" : "") + n }
  return now.getFullYear() + "-" + pad(now.getMonth() + 1) + "-" + pad(now.getDate()) + " "
    + pad(now.getHours()) + ":" + pad(now.getMinutes()) + ":" + pad(now.getSeconds()) + " " + message + "\n"
}

// ---- Debounce ---------------------------------------------------------------

// Seconds to wait after a Hyprland event before saving; null when the event
// does not matter. Closes wait longer: at shutdown all windows close and the
// session ends before the save fires, so the saved state stays intact.
function eventDelay(rawEvent) {
  var name = String(rawEvent).split(">>")[0]
  if (name === "openwindow" || name === "movewindowv2") return 1
  if (name === "closewindow") return 5
  return null
}

// ---- Panel text -----------------------------------------------------------------

// Lines of "<path>\t<Name>\t<StartupWMClass>" (see Service.qml) into entries.
function parseDesktopIndex(text) {
  return String(text).split("\n").map(function(line) { return line.split("\t") })
    .filter(function(f) { return f.length === 3 })
    .map(function(f) {
      return { base: f[0].replace(/^.*\//, "").replace(/\.desktop$/, ""), name: f[1], wmClass: f[2] }
    })
}

// Lowercased window class or desktop file name -> display name. Entries come
// in priority order (the user's own launchers first), the first one wins.
function appNames(entries) {
  var names = {}
  entries.forEach(function(e) {
    if (!e.name) return
    ;[e.wmClass, e.base].forEach(function(key) {
      if (key && !(key.toLowerCase() in names)) names[key.toLowerCase()] = e.name
    })
  })
  return names
}

function appName(cls, names, exe) {
  var known = names[String(cls).toLowerCase()]
  if (known) return known
  if (exe) return String(exe).replace(/^.*\//, "")
  var parts = String(cls).split(".")
  return parts[parts.length - 1] || String(cls)
}

// The strings below come from the plugin's catalogs (i18n/<code>.json) in the
// language picked under Omarchy's Setup > Language. `tr` is a
// Commons.Translations: t(key) for a string, tn(key, count) for a plural one.
// Holes are %1..%9, filled here because node has no QString.arg().
function fill(text, args) {
  return String(text).replace(/%([1-9])/g, function(hole, n) { return args[n - 1] === undefined ? hole : String(args[n - 1]) })
}

function appCount(count, tr) { return fill(tr.tn("apps.count", count), [count]) }

function relativeTime(ms, now, tr) {
  if (!ms) return ""
  var seconds = Math.max(0, (now - ms) / 1000)
  if (seconds < 60) return tr.t("time.now")
  if (seconds < 3600) return fill(tr.t("time.minutesAgo"), [Math.floor(seconds / 60)])
  if (seconds < 86400) return fill(tr.t("time.hoursAgo"), [Math.floor(seconds / 3600)])
  function pad(n) { return (n < 10 ? "0" : "") + n }
  var d = new Date(ms)
  return fill(tr.t("time.date"), [pad(d.getDate()), pad(d.getMonth() + 1), pad(d.getHours()), pad(d.getMinutes())])
}

// `r`: { placed, expected, off, layout } from the last restore.
function restoreSummary(r, tr) {
  if (!r.expected) return tr.t("restore.nothing")
  if (r.placed < r.expected) return fill(tr.t("restore.partial"), [r.placed, r.expected])
  if (r.off > 0) return fill(tr.tn("restore.misplaced", r.off), [r.off])
  return r.layout ? tr.t("restore.allPlaced") : fill(tr.tn("restore.reopened", r.placed), [r.placed])
}

// The glyph for the bar and the panel: a bookmark, the session picks up where
// you left off. A single solid shape like the stock bar icons, and the same
// one in every state; the state shows in its opacity and the tooltip.
var ICON_SESSION = "\uDB80\uDCC0" // nf-md bookmark, U+F00C0

function restoreProblem(r) { return !!r && r.expected > 0 && (r.placed < r.expected || r.off > 0) }

function sessionIcon(state) { return ICON_SESSION }

// ---- Calm before a launch ---------------------------------------------------

// Cumulative "some" stall time (microseconds) from the cpu, io and memory PSI
// texts, in that order; null for a missing or unreadable file.
function pressureTotals(texts) {
  var names = ["cpu", "io", "memory"]
  var out = {}
  names.forEach(function(name, i) {
    var m = /^some .*\btotal=(\d+)/m.exec(texts[i] || "")
    out[name] = m ? Number(m[1]) : null
  })
  return out
}

// The stalled fraction of each resource between two samples `ms` apart.
function pressureLoad(before, after, ms) {
  var out = {}
  ;["cpu", "io", "memory"].forEach(function(name) {
    var a = before[name]
    var b = after[name]
    out[name] = a === null || b === null || !(ms > 0) ? null : (b - a) / (ms * 1000)
  })
  return out
}

var CALM_LIMITS = { cpu: 0.30, io: 0.20, memory: 0.10 }

// Calm when every measured resource is below its limit (missing counts as calm).
function calm(load) {
  return Object.keys(CALM_LIMITS).every(function(name) { return load[name] === null || load[name] < CALM_LIMITS[name] })
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    TERMINALS: TERMINALS, BROWSERS: BROWSERS, RULES_OFF_LUA: RULES_OFF_LUA,
    defaultSettings: defaultSettings, parseSettings: parseSettings, serializeSettings: serializeSettings,
    isIgnored: isIgnored, withIgnored: withIgnored, shQuote: shQuote, regexEscape: regexEscape,
    isWebAppClass: isWebAppClass, webAppKey: webAppKey, launcherUrl: launcherUrl, webAppUrl: webAppUrl,
    parseCmdline: parseCmdline, envDiff: envDiff, classifyProgram: classifyProgram, agentName: agentName, sessionLookup: sessionLookup,
    targets: targets, keepRunning: keepRunning, windowsOf: windowsOf, buildEntry: buildEntry, serializeEntries: serializeEntries, summary: summary,
    restorable: restorable, alreadyOpen: alreadyOpen, launchCommand: launchCommand, ruleSpecs: ruleSpecs, rulesLua: rulesLua, launchLua: launchLua,
    placement: placement, layoutPlan: layoutPlan, aimPlan: aimPlan, offWindows: offWindows,
    parseDesktopIndex: parseDesktopIndex, appNames: appNames, appName: appName,
    relativeTime: relativeTime, fill: fill, appCount: appCount, sessionIcon: sessionIcon, restoreProblem: restoreProblem, restoreSummary: restoreSummary,
    shuttingDown: shuttingDown, logLine: logLine, eventDelay: eventDelay,
    pressureTotals: pressureTotals, pressureLoad: pressureLoad, calm: calm
  }
}
