# hypr-session

Omarchy plugin that saves your Hyprland session and restores it after a reboot, without anything flashing on screen.

## What comes back

- Every app on its workspace, special ones included (like the scratchpad).
- The exact layout: each window's size and split, plus floating windows.
- Terminals in the same folder, running what they ran: Claude Code, Codex and pi resume the same conversation; nvim, vim, btop, htop, lazygit, lazydocker and yazi reopen. A terminal running herdr comes back as a plain shell in its folder.
- Chrome with the tabs of the last session, and web apps as web apps.

## Install

```sh
omarchy plugin add https://github.com/viniciosrab/hypr-session.git --enable
omarchy bar put vinicios.hypr-session --section right   # bar icon (optional)
```

That's it. From then on the session saves itself and comes back on the next boot.

The restore waits for the PC to settle between apps (10s at most each), so a boot with heavy apps doesn't freeze it.

Requires Hyprland 0.56 or newer. `sqlite3` is only needed to resume Codex.

## Panel

Click the bar icon to see when the session was last saved and restored, and to save or restore right away.

| Option (all on by default) | When off |
|---|---|
| Restaurar ao iniciar (restore on start) | Nothing reopens on boot. The session is still saved. |
| Salvar automaticamente (save automatically) | The saved session stays frozen as it is. |
| Remontar layout (rebuild layout) | Apps return to the right workspace, without redoing the layout. |
| Retomar agentes nos terminais (resume agents) | Claude, Codex and pi return to their folder without reopening the conversation. |

Under **Não salvar estes apps** (don't save these apps), tick the apps that should not be saved or reopened.

## From the terminal

```sh
omarchy-shell hypr-session save | restore | status
omarchy-shell hypr-session set autoSave false
omarchy-shell hypr-session ignore <class>      # or unignore
```

## Files

- `~/.local/state/hypr-session.json`: the saved session
- `~/.local/state/hypr-session.log`: what was saved and restored, useful when something doesn't come back right

## Coming from the script version

Delete `~/.local/bin/hypr-session` and `~/.config/omarchy/hooks/post-boot.d/restore-session` before installing, or the session is restored twice. Your saved session still works.

## Limitations

- A Codex or pi that was opened but never used comes back without a conversation.
- Two Codex instances in the same folder may come back in the same conversation.
- Only the dwindle layout is rebuilt.
- An app that closed into the tray (like Discord) stays saved only if its window was seen since the shell started.
- If the shell restarts in the middle of a restore, it doesn't start over on its own. Use **Restaurar agora** (restore now).
