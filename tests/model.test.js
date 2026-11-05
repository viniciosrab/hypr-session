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
    { restoreOnStart: true, autoSave: false, rearrangeLayout: true, resumeAgents: true, rememberPseudoSize: true, ignored: ["a"] })
  assert.equal(M.parseSettings(JSON.stringify({ rememberPseudoSize: false })).rememberPseudoSize, false)
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

const FLATPAK_INFO = "[Application]\nname=app.borys.FigmaLinuxNext\nruntime=runtime/org.freedesktop.Platform/x86_64/24.08\n\n"
  + "[Instance]\ninstance-id=123\nbranch=master\narch=x86_64\n\n[Context]\nshared=network;\n"

test("flatpak info: the app id, branch and arch of a sandboxed process", () => {
  assert.deepEqual(M.flatpakInfo(FLATPAK_INFO), { id: "app.borys.FigmaLinuxNext", branch: "master", arch: "x86_64" })
  assert.deepEqual(M.flatpakInfo("[Application]\nname=org.x.App\n"), { id: "org.x.App", branch: "", arch: "" })
  assert.equal(M.flatpakInfo(""), null, "not in a flatpak")
  assert.equal(M.flatpakInfo("[Runtime]\nname=org.freedesktop.Platform\n"), null, "a bare runtime is no app to relaunch")
})

test("entry: a flatpak app relaunches through flatpak run, without its sandbox env", () => {
  const w = [win("0x1", 10, "figma-linux-next", 4, 0, 0, 1920, 1080)]
  const e = M.buildEntry({ class: "figma-linux-next", windows: w, cmdline: "/app/main/electron\0",
    flatpak: { id: "app.borys.FigmaLinuxNext", branch: "master", arch: "x86_64" },
    env: { LD_PRELOAD: "/app/lib/libzypak-preload-host.so" } })
  assert.deepEqual(e.cmd, ["flatpak", "run", "--branch=master", "--arch=x86_64", "app.borys.FigmaLinuxNext"])
  assert.equal("env" in e, false, "the env holds paths that only exist inside the sandbox")
  assert.deepEqual(e.workspaces, ["4"])
  assert.deepEqual(e.geometry, [{ at: [0, 0], size: [1920, 1080], floating: false }])
  const bare = M.buildEntry({ class: "zapzap", windows: w, cmdline: "/usr/bin/python\0/app/bin/zapzap\0", flatpak: { id: "com.rtosta.zapzap", branch: "", arch: "" } })
  assert.deepEqual(bare.cmd, ["flatpak", "run", "com.rtosta.zapzap"])
})

test("appimage path: only for the process running from the mounted image", () => {
  const env = "APPIMAGE=/home/v/Apps/Tool.AppImage\0APPDIR=/tmp/.mount_Tool4x\0HOME=/home/v\0"
  assert.equal(M.appImagePath(env, "/tmp/.mount_Tool4x/usr/bin/tool\0--flag\0"), "/home/v/Apps/Tool.AppImage")
  assert.equal(M.appImagePath(env, "/usr/bin/chrome\0"), "", "a program started from inside an AppImage only inherits its env")
  assert.equal(M.appImagePath("HOME=/home/v\0", "/usr/bin/x\0"), "")
})

test("entry: an AppImage relaunches its image, keeping its own arguments", () => {
  const w = [win("0x1", 10, "tool", 5, 0, 0, 100, 100)]
  const e = M.buildEntry({ class: "tool", windows: w, cmdline: "/tmp/.mount_Tool4x/usr/bin/tool\0--no-sandbox\0/tmp/.mount_Tool4x/resources/app\0",
    appImage: "/home/v/Apps/Tool.AppImage", env: { LD_LIBRARY_PATH: "/tmp/.mount_Tool4x/usr/lib" } })
  assert.deepEqual(e.cmd, ["/home/v/Apps/Tool.AppImage", "--no-sandbox"])
  assert.equal("env" in e, false, "the env points into the mount, which is gone after exit")
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
  assert.equal(M.appName("zapzap-window", M.appNames([{ base: "com.rtosta.zapzap", name: "ZapZap", wmClass: "" }]), "com.rtosta.zapzap"),
    "ZapZap", "a flatpak id finds its launcher")
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

test("restoreProblem flags a restore that left windows out or misplaced", () => {
  assert.equal(M.restoreProblem({ placed: 1, expected: 2, off: 0 }), true)
  assert.equal(M.restoreProblem({ placed: 2, expected: 2, off: 1 }), true)
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

function client(address, cls, w, h, extra) {
  return Object.assign({ address, class: cls, size: [w, h], floating: false, fullscreen: 0 }, extra || {})
}

test("window addresses normalize to lowercase 0x hex, junk to empty", () => {
  assert.equal(M.windowAddress("55D0c"), "0x55d0c")
  assert.equal(M.windowAddress("0x55d0c"), "0x55d0c")
  assert.equal(M.windowAddress(" 0X1f "), "0x1f")
  assert.equal(M.windowAddress("address:0x1"), "")
  assert.equal(M.windowAddress(undefined), "")
})

test("pseudo sizes file: keeps positive [w, h] per class, drops the rest", () => {
  assert.deepEqual(M.parsePseudoSizes("not json"), {})
  assert.deepEqual(M.parsePseudoSizes("[1, 2]"), {})
  assert.deepEqual(M.parsePseudoSizes(JSON.stringify({ foot: [800.4, 600], bad: [0, 5], short: [1], text: ["1", 2], "": [1, 1] })), { foot: [800, 600] })
  assert.equal(M.serializePseudoSizes({ foot: [800, 600] }), '{\n  "foot": [\n    800,\n    600\n  ]\n}\n')
})

test("Super + P flips a window, the plugin's own opens start pseudotiled", () => {
  let t = M.pseudoFlipped({}, "0x1")
  assert.deepEqual(t, { "0x1": { pseudo: true, class: "", size: null } })
  assert.equal(M.anyPseudo(t), true)
  t = M.pseudoFlipped(t, "0x1")
  assert.equal(t["0x1"].pseudo, false)
  assert.equal(M.anyPseudo(t), false)
  const o = M.pseudoOpened({}, "0x2", "foot", [700, 500])
  assert.deepEqual(o, { "0x2": { pseudo: true, class: "foot", size: [700, 500] } })
})

test("a pseudotiled window follows its tiled size and leaves it to its app when it closes", () => {
  let t = M.pseudoFlipped({}, "0x1")
  let r = M.pseudoTrack(t, {}, [client("0x1", "foot", 900, 700), client("0x9", "other", 10, 10)])
  assert.deepEqual(r.tracked, { "0x1": { pseudo: true, class: "foot", size: [900, 700] } })
  assert.equal(r.changed, false)
  // Floating or fullscreen, the size on screen is not its pseudo size
  r = M.pseudoTrack(r.tracked, {}, [client("0x1", "foot", 1900, 1000, { fullscreen: 1 })])
  assert.deepEqual(r.tracked["0x1"].size, [900, 700])
  r = M.pseudoTrack(r.tracked, {}, [client("0x1", "foot", 400, 300, { floating: true })])
  assert.deepEqual(r.tracked["0x1"].size, [900, 700])
  r = M.pseudoTrack(r.tracked, { kitty: [1, 1] }, [])
  assert.deepEqual(r, { tracked: {}, sizes: { kitty: [1, 1], foot: [900, 700] }, changed: true })
})

test("a window closed no longer pseudotiled makes its app forget the size", () => {
  let t = M.pseudoFlipped(M.pseudoOpened({}, "0x1", "foot", [800, 600]), "0x1")
  let r = M.pseudoTrack(t, { foot: [800, 600] }, [client("0x1", "foot", 1900, 1000)])
  assert.equal(r.tracked["0x1"].pseudo, false)
  r = M.pseudoTrack(r.tracked, r.sizes, [])
  assert.deepEqual(r.sizes, {})
  assert.equal(r.changed, true)
})

test("closing with the same size or an untracked window changes nothing", () => {
  const t = M.pseudoOpened({}, "0x1", "foot", [800, 600])
  const r = M.pseudoTrack(t, { foot: [800, 600] }, [])
  assert.deepEqual(r.sizes, { foot: [800, 600] })
  assert.equal(r.changed, false)
  // Flipped and closed before any poll saw its class: nothing to remember
  const u = M.pseudoTrack(M.pseudoFlipped({}, "0x5"), { foot: [800, 600] }, [])
  assert.deepEqual(u, { tracked: {}, sizes: { foot: [800, 600] }, changed: false })
})

test("a new window opens at its app's size only when on, known and tiled", () => {
  const sizes = { foot: [800, 600] }
  const on = M.defaultSettings()
  const off = M.parseSettings(JSON.stringify({ rememberPseudoSize: false }))
  assert.deepEqual(M.pseudoOpenSize(sizes, client("0x1", "foot", 1, 1), on), [800, 600])
  assert.equal(M.pseudoOpenSize(sizes, client("0x1", "foot", 1, 1), off), null)
  assert.equal(M.pseudoOpenSize(sizes, client("0x1", "kitty", 1, 1), on), null)
  assert.equal(M.pseudoOpenSize(sizes, client("0x1", "foot", 1, 1, { floating: true }), on), null)
  assert.equal(M.pseudoOpenSize(sizes, null, on), null)
})

test("pseudo sizes file: a size may carry the initial title of its app's main window", () => {
  assert.deepEqual(M.parsePseudoSizes(JSON.stringify({ foot: [800, 600, "foot"], empty: [3, 2, ""], num: [3, 2, 7], long: [1, 1, "a", "b"] })),
    { foot: [800, 600, "foot"], empty: [3, 2], num: [3, 2] })
  assert.deepEqual(M.pseudoOpenSize({ foot: [800, 600, "foot"] }, client("0x1", "foot", 1, 1), M.defaultSettings()), [800, 600])
})

test("a remembered size keeps the initial title of the window it came from", () => {
  let r = M.pseudoTrack(M.pseudoFlipped({}, "0x1"), {}, [client("0x1", "foot", 900, 700, { initialTitle: "foot" })])
  assert.deepEqual(r.tracked["0x1"], { pseudo: true, class: "foot", size: [900, 700], title: "foot" })
  r = M.pseudoTrack(r.tracked, {}, [])
  assert.deepEqual(r.sizes, { foot: [900, 700, "foot"] })
  assert.equal(r.changed, true)
  assert.deepEqual(M.pseudoOpened({}, "0x2", "foot", [7, 5], "foot"), { "0x2": { pseudo: true, class: "foot", size: [7, 5], title: "foot" } })
  // A window the plugin opened keeps its app's main title, whatever its own
  r = M.pseudoTrack(M.pseudoOpened({}, "0x3", "foot", [7, 5], "foot"), {}, [client("0x3", "foot", 7, 5, { initialTitle: "other" })])
  assert.equal(r.tracked["0x3"].title, "foot")
})

test("each app with a titled size gets a rule opening its main window pseudotiled at it", () => {
  assert.equal(M.PSEUDO_RULES_OFF_LUA,
    "for _, r in ipairs(_G.hypr_session_pseudo_rules or {}) do r:set_enabled(false) end; _G.hypr_session_pseudo_rules = {}")
  // The rule's size counts the border on both sides: the window itself ends at [w, h]
  const lua = M.pseudoRulesLua({ foot: [800, 600, "foot"], kitty: [700, 500], "a.b": [300, 200, "Tab (1) ]==] x"] }, 2)
  assert.equal(lua, M.PSEUDO_RULES_OFF_LUA
    + '; table.insert(_G.hypr_session_pseudo_rules, hl.window_rule({ name = "hypr-session-pseudo-1", match = { class = [==[^(a\\.b)$]==], initial_title = [==[^(Tab \\(1\\) \\]==\\] x)$]==] }, pseudo = true, size = "304 204" }))'
    + '; table.insert(_G.hypr_session_pseudo_rules, hl.window_rule({ name = "hypr-session-pseudo-2", match = { class = [==[^(foot)$]==], initial_title = [==[^(foot)$]==] }, pseudo = true, size = "804 604" }))')
  assert.equal(M.pseudoRulesLua({ kitty: [700, 500] }, 1), M.PSEUDO_RULES_OFF_LUA)
})

test("a tiled window matching its app's rule opened pseudotiled already", () => {
  const rules = { foot: [800, 600, "foot"], kitty: [700, 500] }
  assert.equal(M.pseudoRuleOpened(rules, client("0x1", "foot", 800, 600, { initialTitle: "foot" })), true)
  assert.equal(M.pseudoRuleOpened(rules, client("0x1", "foot", 1, 1, { initialTitle: "other" })), false)
  assert.equal(M.pseudoRuleOpened(rules, client("0x1", "foot", 1, 1, { initialTitle: "foot", floating: true })), false)
  assert.equal(M.pseudoRuleOpened(rules, client("0x1", "kitty", 1, 1, { initialTitle: "kitty" })), false)
  assert.equal(M.pseudoRuleOpened(rules, null), false)
  // A hidden window shown again (an app reopened from the tray) maps without
  // its rules: full tile size, so it still needs pseudotiling
  assert.equal(M.pseudoRuleOpened(rules, client("0x1", "foot", 945, 558, { initialTitle: "foot" })), false)
})

test("openwindow event data gives the address and class", () => {
  assert.deepEqual(M.openWindowEvent("55d0c,2,foot,~/src, a title"), { address: "0x55d0c", class: "foot" })
  assert.equal(M.openWindowEvent("zz,2,foot,t"), null)
  assert.equal(M.openWindowEvent("55d0c"), null)
})
