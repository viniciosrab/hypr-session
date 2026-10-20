# hypr-session — audit improvements

Fixes from the 2026-10-19 audit: a smoother restore at boot, leftover window rules, a private session file, apps in the tray, the log trim race and agent resume without a start time. Branch `fix/audit-improvements`.

## Specs

- S1 Restore spreads the boot load: before launching each app, wait until CPU, IO and memory pressure (from /proc/pressure, measured over a short window) are low, at most 10s per app, and log when it waited.
- S2 Window rules left on by an interrupted restore are switched off: on every plugin start, and before a restore sets new rules.
- S3 The saved session and the restored copy are readable only by the user (mode 600); `PATH` is not saved as launch env.
- S4 An app that closes its window but keeps running (tray, e.g. Discord) stays in the saved session until its process exits; brief open/close no longer rewrites the session. Not for terminals, nor when the process still has other windows.
- S5 Log writes run one at a time, in order, and the trim (past 1000 lines, oldest 500 go; also at start) never drops a line written meanwhile.
- S6 Codex and pi never resume a conversation when their process start time is unknown; they reopen without one.
- Out of scope (user agreed, L2): replacing the 0.5s window polling with events.

## Tasks

- T1 S2 rules off at start and before new rules — inline — commit: 96f2be7 (unit + norestore/restore green)
- T2 S3 private state files, drop PATH — inline — commit: af32916 (unit + save/restore green)
- T3 S5 serialized log, shell trim — inline — commit: 5e14d35 (norestore trim step green)
- T4 S6 agent lookup guard in Model — inline — commit: b0b1eee (unit green)
- T5 S4 keep tray apps — gentle-ai-worker — commit: c5363fc (unit + save green, validate 0)
- T6 S1 calm wait before launches + README — gentle-ai-worker — commit: e58975e (unit + restore green; integration RED observed by parent)

## Log

- L1 (user, verbatim): "Faça uma auditoria no plugin do Amart, faça uma auditoria para ver se tem alguma coisa que a gente possa melhorar, ou enfim, faça uma auditoria geral do plugin para ver se a gente possa melhorar nele, ou enfim, faça você que é o engenheiro. A questão de desempenho, também não sei se é referente ao plugin, quando o PC reinicia, que ele está restaurando a janela, o PC meio que fica lento e fica lento, dá umas travadas."
- L2 (user, verbatim): "e 1a5?" then "go" on the recommendation: items 1-4 plus 5a (log) and 5b (Codex), skip 5c (event-driven polling).
- L3 Evidence: boot load is mostly the restored apps (VS Code 8.6 GB, Chrome 4.3 GB, herdr reviving 13 pi sessions with ~26 npm MCP servers); plugin restore is sequential, 26s for 6 apps. Discord flips in/out of the saved session every few seconds (opened from tray, closed back).
- L4 Evidence: tests/run.sh `ui` already failed on main (Panel.qml:176 `Color.urgent` undefined; unqualified `Color` does not resolve). Fixed in a975909 "fix(panel): qualify Color" (own commit, outside the specs).
- L5 Live check (shell restarted, marker present): no relaunch, state + restored files 600, PATH gone from saved env, saves resume. Discord already in the tray before the restart is not kept (in-memory only); documented in README Limitations. The calm wait (S1) only runs on a real boot restore: not observed live yet.
