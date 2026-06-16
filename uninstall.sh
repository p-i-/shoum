#!/bin/bash
# Shoum — uninstaller. Requires an explicit mode so you never half-uninstall by
# accident (e.g. think it's gone while the ~2 GB model store quietly remains).
#
#   ./uninstall.sh --keep-models   Remove the app, config, logs and permission
#                                  grants, but KEEP the ~2 GB model store so a
#                                  later reinstall is cheap (no re-download).
#   ./uninstall.sh --full          Remove EVERYTHING, including the ~2 GB model
#                                  store. A reinstall re-downloads + re-converts
#                                  the model (several minutes).
#
# Run with no arguments to print this help and do nothing.
set -uo pipefail

APP="/Applications/Shoum.app"
SUPPORT="$HOME/Library/Application Support/Shoum"
LOGS="$HOME/Library/Logs/Shoum"
TMP="/tmp/shoum"
BUNDLE_ID="org.pipad.shoum"

usage() {
    cat <<EOF
Shoum uninstaller — choose a mode (there is no default, on purpose):

  ./uninstall.sh --keep-models   Remove app + config + logs + permission grants,
                                 KEEP the ~2 GB model store (cheap reinstall).
  ./uninstall.sh --full          Remove EVERYTHING incl. the ~2 GB model store.

Nothing is removed unless you pass one of the modes above.
EOF
}

MODE=""
for a in "$@"; do
    case "$a" in
        --full)        MODE="full" ;;
        --keep-models) MODE="keep" ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "unknown option: $a"; echo; usage; exit 1 ;;
    esac
done
[ -z "$MODE" ] && { usage; exit 0; }

say() { printf '\n=== %s ===\n' "$*"; }

say "Stop any running instance"
pkill -x Shoum 2>/dev/null && echo "stopped Shoum" || echo "not running"

say "Remove the app"
if [ -e "$APP" ]; then rm -rf "$APP" && echo "removed $APP"; else echo "no app at $APP"; fi

say "Remove user data"
if [ -d "$SUPPORT" ]; then
    if [ "$MODE" = "full" ]; then
        rm -rf "$SUPPORT" && echo "removed $SUPPORT (including the ~2 GB model store)"
    else
        rm -f "$SUPPORT/config.yaml" "$SUPPORT/prompt.txt" "$SUPPORT/server.log"
        echo "removed config/prompt/server.log; KEPT model store: $SUPPORT/models"
    fi
else
    echo "no data dir at $SUPPORT"
fi
rm -rf "$LOGS" "$TMP" 2>/dev/null && echo "removed logs + /tmp scratch" || true

say "Reset permissions + preferences"
tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null && echo "reset Accessibility" || true
tccutil reset Microphone    "$BUNDLE_ID" 2>/dev/null && echo "reset Microphone"    || true
defaults delete "$BUNDLE_ID" 2>/dev/null && echo "cleared UserDefaults" || true

say "Done"
echo "Shoum uninstalled ($MODE)."
echo "If you enabled 'Start at login', remove it in System Settings → General → Login Items"
echo "(the login-item registration is the one thing this script can't revoke without the app)."
