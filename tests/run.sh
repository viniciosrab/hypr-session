#!/usr/bin/env bash
# Runs the node unit tests, then each tests/integration/*.qml inside real
# Quickshell against the installed Omarchy UI modules, so a host API change
# fails here instead of in the bar. hyprctl is faked (tests/bin) and HOME is a
# scratch directory: nothing touches the live compositor, the running shell,
# or your saved session.
set -euo pipefail

source_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
omarchy_shell=${OMARCHY_SHELL_DIR:-/usr/share/omarchy/shell}

echo "# unit"
node --test "$source_root/tests/"

[[ -n ${WAYLAND_DISPLAY:-} ]] || { echo "run.sh: integration tests need a Wayland session" >&2; exit 1; }

test_root=$(mktemp -d)
sleeper=
cleanup() { [[ -n $sleeper ]] && kill "$sleeper" 2>/dev/null || true; rm -rf -- "$test_root"; }
trap cleanup EXIT

# A real process for the saver to read /proc/<pid>/cmdline from
sh -c 'exec sleep 600' &
sleeper=$!

failed=0
for test in "$source_root"/tests/integration/${ONLY:-*}.qml; do
  name=$(basename -- "$test" .qml)
  work="$test_root/$name"
  mkdir -p "$work/app/plugin" "$work/app/host" "$work/fake" "$work/home/.local/state/omarchy/settings"
  cp -- "$source_root"/*.qml "$source_root"/*.js "$source_root"/manifest.json "$work/app/plugin/"
  cp -r -- "$omarchy_shell/Commons" "$omarchy_shell/Ui" "$work/app/"
  cp -- "$omarchy_shell/services/PluginShellApi.qml" "$work/app/host/"
  cp -- "$test" "$work/app/shell.qml"
  echo '[]' >"$work/fake/clients.json"

  env -u HYPR_SESSION_FILE XDG_STATE_HOME="$work/home/.local/state" HOME="$work/home" PATH="$source_root/tests/bin:$PATH" FAKE_HYPR="$work/fake" FAKE_PID="$sleeper" \
    HYPR_SESSION_MARKER="$work/marker" timeout 90s qs --no-color -p "$work/app" >"$work/output" 2>&1 || true

  if grep -q SESSION_PASS "$work/output" \
    && ! grep -E 'ReferenceError|TypeError|Cannot assign|Unable to assign|is not a type|Cannot read property|Binding loop' "$work/output"; then
    grep -E 'ok  - ' "$work/output" | sed 's/.*ok  - /  ok  - /'
    echo "PASS $name"
  else
    cat -- "$work/output"
    echo "FAIL $name"
    failed=1
  fi
done
exit "$failed"
