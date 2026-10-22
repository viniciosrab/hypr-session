// Unit tests for the pure session model. Run with: node --test tests/
const test = require("node:test")
const assert = require("node:assert/strict")
const M = require("../Model.js")

function win(address, pid, cls, ws, x, y, w, h, floating) {
  return { address, pid, class: cls, workspace: { id: Number(ws) || 0, name: String(ws) }, at: [x, y], size: [w, h], floating: !!floating }
}
function rect(addr, x, y, w, h) { return { addr, x, y, w, h } }

test("settings default to everything on, tolerate junk, and keep unique ignored classes", () => {
  assert.deepEqual(M.parseSettings("not json"), M.defaultSettings())
  assert.deepEqual(M.parseSettings(JSON.stringify({ autoSave: false, resumeAgents: "no", ignored: ["a", "a", 3, ""] })),
    { restoreOnStart: true, autoSave: false, rearrangeLayout: true, resumeAgents: true, ignored: ["a"] })
  const s = M.withIgnored(M.defaultSettings(), "foo", true)
  assert.deepEqual(s.ignored, ["foo"])
  assert.deepEqual(M.withIgnored(s, "foo", false).ignored, [])
  assert.equal(M.isIgnored(s, "foo"), true)
})

test("web app key and url follow Chrome's window class naming", () => {
  assert.equal(M.webAppKey("https://discord.com/channels/@me"), "discord.com__channels_@me")
  assert.equal(M.webAppKey("https://web.whatsapp.com"), "web.whatsapp.com__")
  assert.equal(M.webAppUrl("chrome-discord.com__channels_@me-Default", ["https://x.com", "https://discord.com/channels/@me"]), "https://discord.com/channels/@me")
  assert.equal(M.webAppUrl("chrome-example.com__a_b-Profile 2", []), "https://example.com/a/b")
  assert.equal(M.isWebAppClass("chrome-discord.com__channels_@me-Default"), true)
  assert.equal(M.isWebAppClass("google-chrome"), false)
  assert.equal(M.launcherUrl('[Desktop Entry]\nExec=omarchy-launch-webapp "https://a.com/x" --foo\n'), "https://a.com/x")
  assert.equal(M.launcherUrl("Exec=firefox\n"), "")
})

test("cmdline: splits NULs, unfolds Chromium's single string, drops --app=", () => {
  assert.deepEqual(M.parseCmdline("foot\0--x=1\0"), ["foot", "--x=1"])
  assert.deepEqual(M.parseCmdline("/opt/chrome --a --app=https://x --b\0"), ["/opt/chrome", "--a", "--b"])
})

test("env diff keeps only the app's own variables and skips volatile ones", () => {
  const session = "A=1\0B=2\0"
  const app = "A=1\0B=2\0QT_STYLE=kvantum\0PWD=/x\0ELECTRON_RUN=1\0NOEQ\0"
  assert.deepEqual(M.envDiff(session, app), { QT_STYLE: "kvantum" })
  assert.deepEqual(M.envDiff("A=1\0", "A=1\0PATH=/old/bin\0"), {}, "PATH goes stale, the session's own is used")
})

test("program classification: agents resume, plain TUIs restart, shells are ignored", () => {
  assert.deepEqual(M.classifyProgram("claude", "/p", "abc", [], true), { cwd: "/p", command: "claude --resume abc" })
  assert.deepEqual(M.classifyProgram("claude", "/p", "", [], true), { cwd: "/p", command: "claude" })
  assert.deepEqual(M.classifyProgram("codex", "/p", "t1", [], true), { cwd: "/p", command: "codex resume t1" })
  assert.deepEqual(M.classifyProgram("pi", "/p", "s1", [], true), { cwd: "/p", command: "pi --session s1" })
  assert.deepEqual(M.classifyProgram("claude", "/p", "abc", [], false), { cwd: "/p", command: null }, "agents off keeps only the folder")
  assert.deepEqual(M.classifyProgram("nvim", "/p", "", ["nvim", "my file.txt"], false), { cwd: "/p", command: "nvim 'my file.txt'" })
  assert.equal(M.classifyProgram("zsh", "/p", "", ["zsh"], true), null)
  assert.deepEqual(M.classifyProgram("herdr", "/p", "", ["herdr"], true), { cwd: "/p", command: null },
    "herdr is not reopened: its folder comes back with a plain shell, and its own agents are not resumed")
})

test("targets: one per pid and class, in workspace/position order, ignoring listed classes", () => {
  const clients = [
    win("0x2", 20, "foot", 3, 0, 0, 10, 10), win("0x1", 10, "google-chrome", 1, 0, 0, 10, 10),
    win("0x3", 10, "chrome-a-Default", 1, 5, 0, 10, 10), win("0x4", 10, "google-chrome", 1, 9, 0, 10, 10),
    win("0x5", 0, "nopid", 1, 0, 0, 1, 1)
  ]
  assert.deepEqual(M.targets(clients).map(t => t.class), ["google-chrome", "chrome-a-Default", "foot"])
  assert.deepEqual(M.targets(clients, { ignored: ["foot"] }).map(t => t.class), ["google-chrome", "chrome-a-Default"])
})

test("entry: web apps launch through omarchy-launch-webapp", () => {
  const w = [win("0x1", 10, "chrome-a.com__-Default", 2, 0, 0, 100, 100)]
  const e = M.buildEntry({ class: "chrome-a.com__-Default", windows: w, cmdline: "chrome\0", webUrl: "https://a.com/" })
  assert.deepEqual(e.cmd, ["omarchy-launch-webapp", "https://a.com/"])
  assert.deepEqual(e.workspaces, ["2"])
})

test("entry: browsers reopen their last session once", () => {
  const w = [win("0x1", 10, "google-chrome", 1, 0, 0, 100, 100)]
  const e = M.buildEntry({ class: "google-chrome", windows: w, cmdline: "/opt/chrome\0--lang=pt-BR\0", env: { A: "1" } })
  assert.deepEqual(e.cmd, ["/opt/chrome", "--lang=pt-BR", "--restore-last-session"])
  assert.deepEqual(e.env, { A: "1" })
  const again = M.buildEntry({ class: "google-chrome", windows: w, cmdline: "/opt/chrome\0--restore-last-session\0" })
  assert.deepEqual(again.cmd, ["/opt/chrome", "--restore-last-session"])
  assert.equal("env" in again, false)
})

test("entry: terminals reopen in the folder running the program, env is not carried", () => {
  const w = [win("0x1", 10, "foot", 3, 0, 0, 100, 100)]
  const plain = M.buildEntry({ class: "foot", windows: w, cmdline: "foot\0", cwd: "/home/v", env: { A: "1" } })
  assert.deepEqual(plain.cmd, ["foot", "--working-directory=/home/v"])
  assert.equal("env" in plain, false)

  const agent = M.buildEntry({ class: "foot", windows: w, cmdline: "foot\0--working-directory=/old\0--font=mono\0", cwd: "/home/v",
    program: { cwd: "/proj", command: "claude --resume abc" }, shell: "/usr/bin/zsh" })
  assert.deepEqual(agent.cmd, ["foot", "--working-directory=/proj", "--font=mono", "/usr/bin/zsh", "-ic", "claude --resume abc; exec /usr/bin/zsh"])

  const ghostty = M.buildEntry({ class: "com.mitchellh.ghostty", windows: w, cmdline: "ghostty\0", program: { cwd: "/p", command: "nvim" }, shell: "zsh" })
  assert.deepEqual(ghostty.cmd, ["ghostty", "--working-directory=/p", "-e", "zsh", "-ic", "nvim; exec zsh"])

  const kitty = M.buildEntry({ class: "kitty", windows: w, cmdline: "kitty\0", program: { cwd: "/p", command: null }, shell: "zsh" })
  assert.deepEqual(kitty.cmd, ["kitty", "--directory=/p"])
})

test("entry: an app with no readable cmdline is skipped; geometry keeps floating", () => {
  const w = [win("0x1", 10, "x", 1, 1, 2, 3, 4, true)]
  assert.equal(M.buildEntry({ class: "x", windows: w, cmdline: "" }), null)
  const e = M.buildEntry({ class: "x", windows: w, cmdline: "x\0" })
  assert.deepEqual(e.geometry, [{ at: [1, 2], size: [3, 4], floating: true }])
})

test("launch command carries the saved env and quotes arguments", () => {
  assert.equal(M.launchCommand({ cmd: ["app", "a b"], env: { K: "v w" } }), "env 'K=v w' app 'a b'")
  assert.equal(M.launchCommand({ cmd: ["app"] }), "app")
})

test("window rules: only classes that sat on a single workspace get one", () => {
  const entries = [
    { class: "b", workspaces: ["2"] }, { class: "a", workspaces: ["1", "1"] },
    { class: "c", workspaces: ["1", "2"] }, { class: "a", workspaces: ["1"] }
  ]
  assert.deepEqual(M.ruleSpecs(entries), [{ class: "a", workspace: "1" }, { class: "b", workspace: "2" }])
  const lua = M.rulesLua([{ class: "chrome-a.b-Default", workspace: "special:x" }])
  assert.match(lua, /class = \[==\[\^\(chrome-a\\\.b-Default\)\$\]==\]/)
  assert.match(lua, /workspace = \[==\[special:x silent\]==\]/)
  assert.ok(lua.startsWith(M.RULES_OFF_LUA + "; "), "rules left by an interrupted restore are switched off first")
})

test("restorable drops ignored and empty entries", () => {
  const entries = [{ class: "a", cmd: ["a"] }, { class: "b", cmd: ["b"] }, { class: "c", cmd: [] }]
  assert.deepEqual(M.restorable(entries, { ignored: ["b"] }).map(e => e.class), ["a"])
})

test("placement pairs the nth saved window with the opened address", () => {
  const entry = { workspaces: ["1", "2"], geometry: [{ at: [1, 2], size: [3, 4], floating: false }] }
  assert.deepEqual(M.placement(entry, "0xa", 0), { addr: "0xa", ws: "1", x: 1, y: 2, w: 3, h: 4, floating: false })
  assert.equal(M.placement(entry, "0xb", 1), null)
})

test("layout plan: side by side, then the right half stacked", () => {
  const plan = M.layoutPlan([rect("a", 0, 0, 500, 1000), rect("b", 500, 0, 500, 500), rect("c", 500, 500, 500, 500)])
  assert.deepEqual(plan, { first: "a", splits: [{ base: "a", dir: "r", add: "b" }, { base: "b", dir: "d", add: "c" }] })
})

test("layout plan: top row then bottom split", () => {
  const plan = M.layoutPlan([rect("a", 0, 0, 1000, 500), rect("b", 0, 500, 500, 500), rect("c", 500, 500, 500, 500)])
  assert.deepEqual(plan, { first: "a", splits: [{ base: "a", dir: "d", add: "b" }, { base: "b", dir: "r", add: "c" }] })
})

test("layout plan tolerates a few pixels of gap and refuses a non-dwindle layout", () => {
  assert.ok(M.layoutPlan([rect("a", 0, 0, 495, 1000), rect("b", 500, 0, 500, 1000)]))
  const pinwheel = [rect("a", 0, 0, 600, 400), rect("b", 600, 0, 400, 600), rect("c", 400, 600, 600, 400), rect("d", 0, 400, 400, 600)]
  assert.equal(M.layoutPlan(pinwheel), null)
  assert.equal(M.layoutPlan([]), null)
})

test("aim: pull the neighbour's edge back, or push the window's own edge forward", () => {
  const clients = [win("a", 1, "x", "5", 0, 0, 500, 1000), win("b", 1, "x", "5", 500, 0, 500, 1000), win("f", 1, "x", "5", 0, 0, 50, 50, true)]
  // cursor in the left half, aiming at b (at the end): b's left edge moves left
  assert.deepEqual(M.aimPlan(clients, "b", "5", "x", 100, 500), { addr: "b", w: 500 + (100 - 20 - 500), h: 1000 })
  // cursor in the right half, aiming at a (not at the end): a's right edge moves right
  assert.deepEqual(M.aimPlan(clients, "a", "5", "x", 800, 500), { addr: "a", w: 500 + (800 + 20 - 500), h: 1000 })
  // already under the cursor, or nothing to move
  assert.equal(M.aimPlan(clients, "a", "5", "x", 100, 500), null)
  assert.equal(M.aimPlan(clients, "b", "5", "x", 800, 500), null)
  assert.equal(M.aimPlan(clients, "zz", "5", "x", 100, 500), null)
  // y axis swaps width and height
  assert.deepEqual(M.aimPlan(clients, "a", "5", "y", 100, 990), null)
})

test("off windows report anything past the tolerance, or missing", () => {
  const clients = [win("a", 1, "x", "1", 0, 0, 500, 500), win("b", 1, "x", "1", 500, 0, 500, 500)]
  const want = [rect("a", 0, 0, 500, 500), rect("b", 520, 0, 480, 500), rect("c", 0, 0, 1, 1)]
  const off = M.offWindows(clients, want)
  assert.equal(off.length, 2)
  assert.match(off[0], /^b want 520,0 480x500 got 500,0 500x500$/)
  assert.match(off[1], /^c want .* got gone$/)
  assert.deepEqual(M.offWindows(clients, [rect("a", 8, 8, 505, 495)]), [])
})

test("shutdown detection: uwsm stop, systemd stopping, or a queued poweroff/reboot timer", () => {
  assert.equal(M.shuttingDown({ uwsmStop: true, systemState: "running", timerExecStarts: [] }), true)
  assert.equal(M.shuttingDown({ uwsmStop: false, systemState: "stopping\n", timerExecStarts: [] }), true)
  assert.equal(M.shuttingDown({ uwsmStop: false, systemState: "running", timerExecStarts: ["{ path=/usr/bin/systemctl ; argv[]=systemctl reboot }"] }), true)
  assert.equal(M.shuttingDown({ uwsmStop: false, systemState: "running", timerExecStarts: ["something else"] }), false)
})

test("log line format", () => {
  assert.equal(M.logLine(new Date(2026, 0, 2, 3, 4, 5), "save: x"), "2026-01-02 03:04:05 save: x\n")
})

test("event debounce: opens and moves 1s, closes 5s, the rest ignored", () => {
  assert.equal(M.eventDelay("openwindow>>0x1,1,foot,foot"), 1)
  assert.equal(M.eventDelay("movewindowv2>>0x1,1,name"), 1)
  assert.equal(M.eventDelay("closewindow>>0x1"), 5)
  assert.equal(M.eventDelay("workspace>>2"), null)
})

test("the saved state from the old script still restores unchanged", () => {
  const fs = require("node:fs"), path = require("node:path")
  const file = path.join(process.env.HOME, ".local/state/hypr-session.json")
  if (!fs.existsSync(file)) return
  const entries = JSON.parse(fs.readFileSync(file, "utf8"))
  const kept = M.restorable(entries, M.defaultSettings())
  assert.equal(kept.length, entries.length)
  for (const e of kept) assert.ok(M.launchCommand(e).length > 0)
})

test("restoring over a live desktop skips apps whose windows are already open", () => {
  const entries = [
    { class: "foot", workspaces: ["1", "2"] }, { class: "foot", workspaces: ["3"] },
    { class: "code", workspaces: ["1"] }, { class: "chrome", workspaces: ["2"] }
  ]
  const open = [win("0x1", 1, "foot", 1, 0, 0, 1, 1), win("0x2", 1, "foot", 1, 0, 0, 1, 1), win("0x3", 2, "code", 1, 0, 0, 1, 1)]
  assert.deepEqual(M.alreadyOpen(entries, open), [true, false, true, false])
  assert.deepEqual(M.alreadyOpen(entries, []), [false, false, false, false], "an empty desktop restores everything")
})

test("app names come from desktop entries, by window class or file name, user entries first", () => {
  const names = M.appNames([
    { base: "audiorelay", name: "AudioRelay", wmClass: "com-azefsw-audioconnect-desktop-app-MainKt" },
    { base: "com.microsoft.VSCode", name: "Visual Studio Code", wmClass: "Code" },
    { base: "foot", name: "Foot (mine)", wmClass: "" },
    { base: "foot", name: "Foot", wmClass: "" }
  ])
  assert.equal(M.appName("com-azefsw-audioconnect-desktop-app-MainKt", names, ""), "AudioRelay")
  assert.equal(M.appName("com.microsoft.VSCode", names, ""), "Visual Studio Code")
  assert.equal(M.appName("code", names, ""), "Visual Studio Code", "class match ignores case")
  assert.equal(M.appName("foot", names, ""), "Foot (mine)", "the first entry wins")
  assert.equal(M.appName("some-tool", names, "/opt/x/bin/SomeTool"), "SomeTool", "falls back to the program name")
  assert.equal(M.appName("org.example.Thing", names, ""), "Thing", "then to the last part of the class")
})

test("desktop index lines parse into entries", () => {
  assert.deepEqual(M.parseDesktopIndex("/a/b/foot.desktop\tFoot\t\n/x/y.desktop\t\tY\nbad\n"),
    [{ base: "foot", name: "Foot", wmClass: "" }, { base: "y", name: "", wmClass: "Y" }])
})

// A stand-in for Commons.Translations over the plugin's own catalogs: the
// language's string, then English's, with plural forms picked by count.
function translator(code) {
  const english = require("../i18n/en.json")
  const strings = { ...english, ...(code === "en" ? {} : require(`../i18n/${code}.json`)) }
  const one = code === "pt-BR" ? (n) => n <= 1 : (n) => n === 1
  return {
    t: (key) => { const v = strings[key]; return typeof v === "object" ? v.other : v },
    tn: (key, count) => { const v = strings[key]; return typeof v === "object" ? (one(count) ? v.one : v.other) : v },
  }
}

test("every language carries the same strings as English, with the same holes", () => {
  const english = require("../i18n/en.json")
  const holes = (v) => JSON.stringify(v).match(/%[0-9]/g)?.sort() ?? []
  for (const file of require("node:fs").readdirSync(`${__dirname}/../i18n`)) {
    const catalog = require(`../i18n/${file}`)
    assert.deepEqual(Object.keys(catalog).sort(), Object.keys(english).sort(), file)
    for (const key of Object.keys(english))
      if (typeof english[key] === "string") assert.deepEqual(holes(catalog[key]), holes(english[key]), `${file} ${key}`)
  }
})

test("relative time reads naturally in the system language", () => {
  const now = new Date(2026, 0, 2, 12, 0, 0).getTime()
  const en = translator("en")
  assert.equal(M.relativeTime(now - 20 * 1000, now, en), "now")
  assert.equal(M.relativeTime(now - 60 * 1000, now, en), "1 min ago")
  assert.equal(M.relativeTime(now - 3 * 3600 * 1000, now, en), "3 h ago")
  assert.equal(M.relativeTime(now - 30 * 3600 * 1000, now, en), "on 01/01 at 06:00")
  assert.equal(M.relativeTime(now - 40 * 86400 * 1000, now, en), "on 11/23 at 12:00", "month first in English")
  assert.equal(M.relativeTime(0, now, en), "")
  const pt = translator("pt-BR")
  assert.equal(M.relativeTime(now - 20 * 1000, now, pt), "agora")
  assert.equal(M.relativeTime(now - 60 * 1000, now, pt), "há 1 min")
  assert.equal(M.relativeTime(now - 59 * 60 * 1000, now, pt), "há 59 min")
  assert.equal(M.relativeTime(now - 3 * 3600 * 1000, now, pt), "há 3 h")
  assert.equal(M.relativeTime(now - 30 * 3600 * 1000, now, pt), "em 01/01 às 06:00")
  assert.equal(M.relativeTime(now - 40 * 86400 * 1000, now, pt), "em 23/11 às 12:00", "day first in Portuguese")
})

test("restore result in one short phrase, in the system language", () => {
  const en = translator("en")
  assert.equal(M.restoreSummary({ placed: 4, expected: 4, off: 0, layout: true }, en), "everything in place")
  assert.equal(M.restoreSummary({ placed: 4, expected: 4, off: 0, layout: false }, en), "4 windows reopened")
  assert.equal(M.restoreSummary({ placed: 1, expected: 1, off: 0, layout: false }, en), "1 window reopened")
  assert.equal(M.restoreSummary({ placed: 3, expected: 4, off: 0, layout: true }, en), "3 of 4 windows came back")
  assert.equal(M.restoreSummary({ placed: 4, expected: 4, off: 1, layout: true }, en), "1 window out of place")
  assert.equal(M.restoreSummary({ placed: 4, expected: 4, off: 2, layout: true }, en), "2 windows out of place")
  assert.equal(M.restoreSummary({ placed: 0, expected: 0, off: 0, layout: true }, en), "nothing to reopen")
  const pt = translator("pt-BR")
  assert.equal(M.restoreSummary({ placed: 4, expected: 4, off: 0, layout: true }, pt), "tudo no lugar")
  assert.equal(M.restoreSummary({ placed: 4, expected: 4, off: 0, layout: false }, pt), "4 janelas reabertas")
  assert.equal(M.restoreSummary({ placed: 1, expected: 1, off: 0, layout: false }, pt), "1 janela reaberta")
  assert.equal(M.restoreSummary({ placed: 3, expected: 4, off: 0, layout: true }, pt), "3 de 4 janelas voltaram")
  assert.equal(M.restoreSummary({ placed: 4, expected: 4, off: 1, layout: true }, pt), "1 janela fora do lugar")
  assert.equal(M.restoreSummary({ placed: 4, expected: 4, off: 2, layout: true }, pt), "2 janelas fora do lugar")
  assert.equal(M.restoreSummary({ placed: 0, expected: 0, off: 0, layout: true }, pt), "nada a reabrir")
})

test("an app count takes the plural the language wants", () => {
  assert.equal(M.appCount(1, translator("en")), "1 app")
  assert.equal(M.appCount(6, translator("en")), "6 apps")
  assert.equal(M.appCount(6, translator("pt-BR")), "6 apps")
})

test("the bar icon is the bookmark in every state", () => {
  for (const state of [{}, { restoring: true }, { lastRestore: { placed: 1, expected: 2, off: 0, layout: true } }])
    assert.equal(M.sessionIcon(state), "\u{F00C0}")
  assert.equal(M.restoreProblem({ placed: 1, expected: 2, off: 0 }), true)
  assert.equal(M.restoreProblem({ placed: 2, expected: 2, off: 0 }), false)
  assert.equal(M.restoreProblem(null), false)
})

test("agent session lookup: Codex and pi search since the process started, never without that time", () => {
  assert.deepEqual(M.sessionLookup("codex", "/p/it's", 1700, "/h"), ["sqlite3", "-readonly", "/h/.codex/state_5.sqlite",
    "select id from threads where cwd = '/p/it''s' and updated_at >= 1700 order by updated_at desc limit 1"])
  assert.deepEqual(M.sessionLookup("pi", "/home/u/proj", 1700, "/h"), ["find", "/h/.pi/agent/sessions/--home-u-proj--",
    "-name", "*.jsonl", "-newermt", "@1700", "-printf", "%T@ %f\\n"])
  assert.equal(M.sessionLookup("codex", "/p", 0, "/h"), null, "unknown start: no resume rather than another session's")
  assert.equal(M.sessionLookup("pi", "/p", 0, "/h"), null)
  assert.equal(M.sessionLookup("nvim", "/p", 1700, "/h"), null)
})

test("an app that closed its window but keeps running stays in the session", () => {
  const entry = { cmd: ["discord"], class: "discord", workspaces: ["3"], geometry: [] }
  const remembered = { discord: { entry, pid: 50, cmdline: "discord\0" } }
  const settings = M.defaultSettings()
  const other = [win("0x1", 7, "fakeapp", 1, 0, 0, 10, 10)]
  const alive = { 50: "discord\0" }
  assert.deepEqual(M.keepRunning(remembered, [], other, settings, alive), [entry], "alive, no windows: kept")
  assert.deepEqual(M.keepRunning(remembered, [], other, settings, {}), [], "process gone: dropped")
  assert.deepEqual(M.keepRunning(remembered, [], other, settings, { 50: "other\0" }), [], "pid reused by another program: dropped")
  assert.deepEqual(M.keepRunning(remembered, [], [win("0x2", 50, "chrome-x-Default", 1, 0, 0, 10, 10)], settings, alive), [],
    "the process still has another window (web app inside a browser): dropped")
  assert.deepEqual(M.keepRunning(remembered, [{ class: "discord" }], other, settings, alive), [], "already in the new snapshot: not duplicated")
  assert.deepEqual(M.keepRunning(remembered, [], other, M.withIgnored(settings, "discord", true), alive), [], "ignored: never kept")
})

test("a closed terminal is never kept, even when its process lives", () => {
  const entry = { cmd: ["foot"], class: "foot", workspaces: ["1"], geometry: [] }
  const remembered = { foot: { entry, pid: 60, cmdline: "foot\0" } }
  assert.deepEqual(M.keepRunning(remembered, [], [], M.defaultSettings(), { 60: "foot\0" }), [])
})

test("pressureTotals reads the some total of each PSI file and tolerates missing ones", () => {
  const psi = "some avg10=0.00 avg60=0.00 avg300=0.00 total=114050548\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=999\n"
  assert.deepEqual(M.pressureTotals([psi, "", null]), { cpu: 114050548, io: null, memory: null })
  assert.deepEqual(M.pressureTotals(["junk", psi, psi]), { cpu: null, io: 114050548, memory: 114050548 })
})

test("pressureLoad is the stalled fraction between two samples", () => {
  const load = M.pressureLoad({ cpu: 1000, io: 0, memory: null }, { cpu: 251000, io: 100000, memory: 5 }, 500)
  assert.deepEqual(load, { cpu: 0.5, io: 0.2, memory: null })
  assert.equal(M.pressureLoad({ cpu: 5, io: 0, memory: 0 }, { cpu: 5, io: 0, memory: 0 }, 0).cpu, null)
})

test("calm needs cpu < 0.30, io < 0.20 and memory < 0.10; a missing file is calm", () => {
  assert.equal(M.calm({ cpu: 0.29, io: 0.19, memory: 0.09 }), true)
  assert.equal(M.calm({ cpu: 0.30, io: 0, memory: 0 }), false)
  assert.equal(M.calm({ cpu: 0, io: 0.20, memory: 0 }), false)
  assert.equal(M.calm({ cpu: 0, io: 0, memory: 0.10 }), false)
  assert.equal(M.calm({ cpu: null, io: null, memory: null }), true)
})
