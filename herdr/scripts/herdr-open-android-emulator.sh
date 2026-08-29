#!/usr/bin/env bash
# Open/focus an Android emulator window from either a serial (emulator-5554) or
# an AVD name (wet-sendi-19). Used by herdr-open-mentioned.py.
set -euo pipefail

id=${1:-}
[ -n "$id" ] || { echo "usage: herdr-open-android-emulator.sh emulator-5554|AVD_NAME" >&2; exit 2; }
log=${HERDR_OPEN_EMULATOR_LOG:-$HOME/.cache/herdr-open-emulator.log}
mkdir -p "$(dirname "$log")"
echo "$(date '+%F %T') open $id" >>"$log"

export PATH="$HOME/Library/Android/sdk/emulator:$HOME/Library/Android/sdk/platform-tools:/opt/homebrew/bin:/usr/local/bin:$PATH"

serial=""
avd=""
port=""
pid=""

if [[ "$id" =~ ^emulator-([0-9]+)$ ]]; then
  serial="$id"
  port="${BASH_REMATCH[1]}"
  # adb can tell us the AVD name for a running emulator.
  avd=$(adb -s "$serial" emu avd name 2>/dev/null | tr -d '\r' | awk 'NF && $0 != "OK" { print; exit }' || true)
  # Fall back to the qemu process args. This also works when adb is wedged.
  pid=$(pgrep -fl "qemu-system.* -port $port( |$)" 2>/dev/null | awk 'NR==1 {print $1}' || true)
  if [ -z "$avd" ]; then
    avd=$(pgrep -fl "qemu-system.* -port $port( |$)" 2>/dev/null | sed -nE 's/.* -avd ([^ ]+).*/\1/p' | head -1 || true)
  fi
else
  avd="$id"
  pid=$(pgrep -fl "qemu-system.* -avd ${avd//./\\.}( |$)" 2>/dev/null | awk 'NR==1 {print $1}' || true)
  port=$(pgrep -fl "qemu-system.* -avd ${avd//./\\.}( |$)" 2>/dev/null | sed -nE 's/.* -port ([0-9]+).*/\1/p' | head -1 || true)
  [ -n "$port" ] && serial="emulator-$port"
fi

# If the AVD is known but not already running, boot it.
if [ -n "$avd" ] && ! pgrep -fl "qemu-system.* -avd ${avd//./\\.}( |$)" >/dev/null 2>&1; then
  nohup emulator -avd "$avd" >>"$log" 2>&1 &
  sleep 2
  pid=$(pgrep -fl "qemu-system.* -avd ${avd//./\\.}( |$)" 2>/dev/null | awk 'NR==1 {print $1}' || true)
fi

# Bring the emulator image/window to the front. Target by unix pid; there are
# many qemu-system-aarch64 processes, and `process "qemu-system-aarch64"` only
# sees one of them.
if [ -n "$pid" ]; then
  /usr/bin/osascript >>"$log" 2>&1 <<OSA || true
set targetPid to $pid
set needleAvd to "$avd"
set needlePort to "$port"
tell application "System Events"
  if exists (first process whose unix id is targetPid) then
    tell (first process whose unix id is targetPid)
      set frontmost to true
      repeat with w in windows
        set windowName to name of w
        if (needleAvd is not "" and windowName contains needleAvd) or (needlePort is not "" and windowName contains needlePort) then
          perform action "AXRaise" of w
          return
        end if
      end repeat
      if (count of windows) > 0 then perform action "AXRaise" of window 1
    end tell
  end if
end tell
OSA
fi

echo "$(date '+%F %T') opened avd=${avd:-} serial=${serial:-} port=${port:-} pid=${pid:-}" >>"$log"
printf '%s\n' "opened ${avd:-$serial}"
