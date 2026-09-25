#!/bin/bash
# Link hypr-session and its Omarchy post-boot hook into place.
set -e

repo=$(cd "$(dirname "$0")" && pwd)

# Existing files are kept outside the hook folders: Omarchy runs every file
# in a hook folder, a backup left there would run too.
backup="${XDG_STATE_HOME:-$HOME/.local/state}/hypr-session-backup"

link() {
  mkdir -p "$(dirname "$2")"
  if [[ -e $2 && ! -L $2 ]] && ! cmp -s "$1" "$2"; then
    mkdir -p "$backup"
    mv "$2" "$backup/$(basename "$2").$(date +%s)"
  fi
  ln -sfn "$1" "$2"
  echo "$2 -> $1"
}

link "$repo/bin/hypr-session" "$HOME/.local/bin/hypr-session"
link "$repo/hooks/post-boot.d/restore-session" "$HOME/.config/omarchy/hooks/post-boot.d/restore-session"
