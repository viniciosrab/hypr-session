# hypr-session

Omarchy plugin that saves your Hyprland session and restores it after a reboot, without anything flashing on screen.

## What comes back

- Every app on its workspace, special ones included (like the scratchpad).
- The exact layout: each window's size and split, plus floating windows.
- Terminals in the same folder, running what they ran: Claude Code, Codex and pi resume the same conversation; nvim, vim, btop, htop, lazygit, lazydocker and yazi reopen. A terminal running herdr comes back as a plain shell in its folder.
- Chrome with the tabs of the last session, and web apps as web apps.
- Flatpak apps through `flatpak run`, and AppImages from their image file.

## Install

```sh
omarchy plugin add https://github.com/viniciosrab/hypr-session.git --enable
omarchy bar put vinicios.hypr-session --section right   # bar icon (optional)
```

That's it. From then on the session saves itself and comes back on the next boot.

The restore waits for the PC to settle between apps (10s at most each), so a boot with heavy apps doesn't freeze it.

Requires Hyprland 0.56 or newer. `sqlite3` is only needed to resume Codex.

## Panel

Click the bar icon to see when the session was last saved and restored, and to save or restore right away. The switch next to the status turns automatic saving on or off; while it's off, the saved session stays frozen as it is.

| On restore (all on by default) | When off |
|---|---|
| Reopen apps on startup | Nothing reopens on boot. The session is still saved. |
| Rebuild the window layout | Apps return to the right workspace, without redoing the layout. |
| Resume Claude, Codex and pi | They return to their folder without reopening the conversation. |

Open **Saved apps** and switch off the apps that should not be saved or reopened.

## Remember the Super + P size

Pseudotile a window with Super + P and resize it: its app remembers that size as soon as you resize it, not only when the window closes, and the app's next tiled window opens pseudotiled at it, on any workspace, even while the first one is still open. Floating windows are left alone.

After a reboot, a window that was pseudotiled when the session was saved comes back pseudotiled at the size it had, and keeps updating its app's size like before. The session is saved as soon as Super + P flips a window or its size changes, not only when a window opens or closes.

Each app keeps two sizes, kept across restarts: one for when it is alone on its workspace and one for when it sits beside another tiled window. Sized alone, it comes back at that size when it opens alone; sized beside another window, it comes back at that size when it opens beside one. With no size for where it opens, it tiles as usual. Closing the app's window after turning pseudotile off forgets the size for where it was. The windows being followed survive a shell restart (`omarchy-restart-shell`), so a window pseudotiled before it keeps updating its app's size after it.

The app's main window (one with the same initial title as the window the size came from) opens at that size straight away, through a window rule the plugin keeps in Hyprland. Its other tiled windows open full size and shrink to it right after, and so does a window an app shows again from its tray icon (Hyprland does not apply window rules to a window shown again).

The **Remember the Super + P size** switch in the panel turns it on or off (on by default), or from the terminal: `omarchy-shell hypr-session set rememberPseudoSize false`.

Hyprland doesn't tell anyone that a window is pseudotiled, so Super + P has to tell the plugin which window it flipped. Put this in `~/.config/hypr/bindings.lua`; with the shell down, Super + P still pseudotiles as before:

```lua
-- Super + P: pseudotile at once, then tell hypr-session which window flipped
local function pseudo_window()
  local w = hl.get_active_window()
  hl.dispatch(hl.dsp.window.pseudo())
  if w then hl.dispatch(hl.dsp.exec_cmd("omarchy-shell -q hypr-session pseudo " .. w.address)) end
end
o.bind_commands[pseudo_window] = "hyprctl dispatch 'hl.dsp.window.pseudo()'"
hl.unbind("SUPER + P")
o.bind("SUPER + P", "Pseudo window", pseudo_window)
```

## Language

The panel, the tooltip and `status` follow the language picked under Omarchy's **Setup > Language**, and switch along with it without a restart. English and Brazilian Portuguese ship today; any other language shows English. To add one, copy `i18n/en.json` to `i18n/<code>.json` (the code Omarchy uses, like `de` or `es-MX`) and translate the values.

## From the terminal

```sh
omarchy-shell hypr-session save | restore | status
omarchy-shell hypr-session set autoSave false
omarchy-shell hypr-session ignore <class>      # or unignore
omarchy-shell hypr-session pseudo <address>    # Super + P flipped this window (see above)
```

## Files

- `~/.local/state/hypr-session.json`: the saved session
- `~/.local/state/hypr-session.sizes.json`: the Super + P sizes of each app, alone and beside another window
- `~/.local/state/hypr-session.pseudo.json`: the pseudotiled windows being followed, so a shell restart keeps following them
- `~/.local/state/hypr-session.log`: what was saved and restored, useful when something doesn't come back right

## Coming from the script version

Delete `~/.local/bin/hypr-session` and `~/.config/omarchy/hooks/post-boot.d/restore-session` before installing, or the session is restored twice. Your saved session still works.

## Limitations

- A Codex or pi that was opened but never used comes back without a conversation.
- Two Codex instances in the same folder may come back in the same conversation.
- Only the dwindle layout is rebuilt.
- An app that closed into the tray (like Discord) stays saved only if its window was seen since the shell started.
- If the shell restarts in the middle of a restore, it doesn't start over on its own. Use **Restore now**.
- The Super + P size is one per app, not per window.
- A Super + P size changed less than about a second before closing the window may be missed.
- If the tile shrank (another window opened next to it), the remembered size is the shrunken one.
- A size remembered before this version has no main window yet: the app's windows still shrink after they open until one of them is resized pseudotiled.
- Removing the plugin leaves its Super + P rules in Hyprland until the next config reload.
