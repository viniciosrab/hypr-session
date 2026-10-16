# hypr-session — native Omarchy shell plugin

Convert hypr-session from a bash script + post-boot hook into one native Omarchy shell plugin (`vinicios.hypr-session`, kinds `service` + `bar-widget`). The plugin is the implementation; no separate script remains.

## Specs

- S1 (user, verbatim): "Mas eu quero converter o script no plugin. Eu não quero que eu tenha dois. Tipo, eu instalei o plugin, daí o plugin chama o script. Se for assim, eu uso o script direto, né?" — `bin/hypr-session`, `hooks/post-boot.d/restore-session` and `install.sh` are removed; only system tools (hyprctl, sqlite3, ps, find, pgrep, systemctl) are spawned.
- S2 Behavior parity with README "O que volta" / "Como funciona": workspaces incl. special; dwindle layout rebuilt silently + floating; terminals reopen in same dir running claude --resume / codex resume / pi --session / herdr, nvim, vim, btop, htop, lazygit, lazydocker, yazi; Chrome --restore-last-session; web apps; launch env carried; save on open/move (1s) and close (5s) debounce and every 15s, rewrite only on change; never save an empty desktop; stop saving on shutdown/reboot/logout; temporary per-app window rules during restore; layout verified, up to 3 attempts.
- S3 Same state files/format: `~/.local/state/hypr-session.json` (or `$HYPR_SESSION_FILE`), `.restored.json`, `.log`. An existing state file restores unchanged.
- S4 Restore runs once per Hyprland instance (marker with HYPRLAND_INSTANCE_SIGNATURE in $XDG_RUNTIME_DIR), ~2s after the shell loads; shell restarts never relaunch apps.
- S5 (user, verbatim): "A gente precisa do mínimo das configurações de interface... sem sobre engenharia, só um enxuto necessário." Bar icon (tooltip: last save time) + small panel: last save (time, app count), last restore result, [Salvar agora] [Restaurar agora], toggles: Restaurar ao iniciar, Salvar automaticamente, Remontar layout, Retomar agentes nos terminais (all default on), and an ignored-apps list (pick from open apps). Settings persist in `~/.local/state/omarchy/settings/hypr-session.json`, independent of the bar icon.
- S6 IPC target `hypr-session`: save, restore, status, plus setters for the options.
- S7 Tests: node unit tests for Model.js; Quickshell integration test with fake hyprctl; `omarchy plugin validate .` passes.
- S8 README (Portuguese): plugin install, panel, options, IPC, files, limitations, migration.

## Tasks

- T1 S2,S3 Model.js (layout plan, aim plan, entry building, webapp URL, rules, settings) + node tests — inline — commit: pending
- T2 S1-S4,S6 Service.qml + manifest.json (coroutine runner, save, watch, restore, arrange, IPC, once-per-instance) — inline — commit: pending
- T3 S5 BarWidget.qml + Panel.qml + settings persistence — inline — commit: pending
- T4 S7 integration test (fake hyprctl) + validate — inline — commit: pending
- T5 S1,S8 remove script/hook/installer, rewrite README — inline — commit: pending
- T6 Live cutover (stop old watcher, remove links, enable plugin) — needs user consent — commit: n/a

## Log

- L1 (user, verbatim): "Tem como a gente converter esse nosso script aqui em um plugin nativo do Omarchi, e como que a gente poderia fazer? Para abstrair esse script, no caso, o Marshall já usa, tem plugins nativos. ?"
- L2 (user, verbatim): "Mas eu quero converter o script no plugin. Eu não quero que eu tenha dois. Tipo, eu instalei o plugin, daí o plugin chama o script. Se for assim, eu uso o script direto, né? Idiota."
- L3 (user, verbatim): "Vamos começar, para iniciar esta tá ótimo, depois a gente vai ajustando."
- L4 Evidence: Qt 6.11 QML: no async/await (SyntaxError), generators + Promise work; FileView reads /proc with NULs; Omarchy runs post-boot via `sleep 2 && omarchy-hook post-boot`.
