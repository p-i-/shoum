#!/bin/bash
# In-place upgrade of the INSTALLED /Applications/Shoum.app for app-code-only
# changes (Swift edits — no whisper/engine/model change).
#
# Why this exists, and why NOT install.sh:
#   The installed app is a self-contained *static* build. Its heavy parts — the
#   whisper-server binary, the CoreML encoder, the model — never change when we
#   only touch Swift. Re-running install.sh rebuilds all of that (minutes) and
#   refuses unless you first delete the app. This script instead rebuilds just
#   the Swift app and swaps its binary (+ Info.plist) into the installed bundle,
#   leaving the bundle's whisper-server Resource untouched.
#
#   IMPORTANT: do NOT copy the whole build/Shoum.app over the installed one. The
#   dev build has no whisper-server in Resources, and that Resource's presence is
#   the ONLY signal that puts the app in "installed" mode (see Config.isInstalled
#   / ARCHITECTURE.md). Lose it and the app silently flips to dev path resolution.
#
# The gotcha it handles automatically (ARCHITECTURE.md invariant 11):
#   Ad-hoc signing (`codesign --sign -`) mints a NEW code hash every build, and
#   macOS binds the Accessibility (TCC) grant to that hash. After a swap the old
#   grant is STALE: the System Settings checkbox still reads "on", but
#   AXIsProcessTrusted() returns false and toggling it does nothing. So we reset
#   that one grant and the app re-prompts clean on relaunch. (A stable self-signed
#   signing identity would eliminate this entirely — a planned follow-up.)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="/Applications/Shoum.app"
BUILT="$SCRIPT_DIR/build/Shoum.app"

[ -d "$APP" ] || { echo "ERROR: $APP is not installed — run ./install.sh first."; exit 1; }
[ -f "$APP/Contents/Resources/whisper-server" ] || {
    echo "ERROR: $APP has no whisper-server Resource — not a proper installed bundle."; exit 1; }

# 1. Build the static (self-contained) app. Reuses whisper.cpp/build-install/*.a.
echo "▶ Building static app…"
"$SCRIPT_DIR/build.sh" --static

# 2. Quit the running app so its binary isn't busy / the new code takes effect.
echo "▶ Quitting running app…"
osascript -e 'quit app "Shoum"' 2>/dev/null || true
sleep 1

# 3. Swap ONLY the binary + Info.plist (keep the bundle's whisper-server Resource).
#    Info.plist carries the fresh git stamp so the About pane matches the code.
echo "▶ Swapping binary + Info.plist…"
cp "$BUILT/Contents/MacOS/Shoum" "$APP/Contents/MacOS/Shoum"
cp "$BUILT/Contents/Info.plist" "$APP/Contents/Info.plist"

# 4. Re-sign the installed bundle with the SAME identity build.sh used — the
#    stable cert when present (so the bundle's designated requirement is the
#    constant the Accessibility grant binds to), else ad-hoc. Signing only
#    build/Shoum.app isn't enough: the swap copies the binary into the installed
#    bundle, which must be re-sealed here. (Nested whisper-server keeps its seal.)
SHOUM_KC="$HOME/Library/Keychains/shoum-signing.keychain-db"
if [ -f "$SHOUM_KC" ]; then security unlock-keychain -p shoum "$SHOUM_KC" 2>/dev/null || true; fi
SIGN_ID="-"; STABLE_SIGN=""
if security find-identity -p codesigning 2>/dev/null | grep -q "Shoum Local Signing"; then
    SIGN_ID="Shoum Local Signing"; STABLE_SIGN=1
fi
echo "▶ Re-signing with: $([ "$SIGN_ID" = "-" ] && echo 'ad-hoc' || echo "$SIGN_ID")…"
codesign --force --sign "$SIGN_ID" --entitlements "$SCRIPT_DIR/Shoum/Shoum.entitlements" "$APP"
codesign --verify "$APP" && echo "  signature valid"

# 5. Accessibility grant. Ad-hoc signing changes the code hash, so the grant is
#    stale — reset it for a clean re-prompt. The stable identity keeps the
#    designated requirement constant, so the grant persists: leave it alone.
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")"
if [ -n "$STABLE_SIGN" ]; then
    echo "▶ Stable signing identity in use — Accessibility grant persists (no reset)."
else
    echo "▶ Ad-hoc signing — resetting stale Accessibility grant for $BUNDLE_ID…"
    tccutil reset Accessibility "$BUNDLE_ID" >/dev/null && echo "  reset"
fi

# 6. Relaunch — fires a fresh Accessibility prompt after the mic check.
echo "▶ Relaunching…"
open "$APP"

STAMP="$(/usr/libexec/PlistBuddy -c 'Print ShoumGitCommit' "$APP/Contents/Info.plist" 2>/dev/null || echo '?')"
if [ -n "$STABLE_SIGN" ]; then
cat <<EOF

✅ Upgraded installed app → $STAMP  (stable signing)

The Accessibility grant carries over — the hotkey should arm without a re-grant.
(Only the FIRST upgrade after installing the signing identity needs one more grant,
since the identity changed from ad-hoc; after that it persists.)
      tail -f ~/Library/Logs/Shoum/shoum.log    # watch for "hotkey armed LIVE"
EOF
else
cat <<EOF

✅ Upgraded installed app → $STAMP

⚠️  Re-grant Accessibility (ad-hoc hash changed, so the old grant was cleared):
      System Settings → Privacy & Security → Accessibility → enable Shoum
      open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

   The app polls and arms the hotkey LIVE once granted — no second relaunch:
      tail -f ~/Library/Logs/Shoum/shoum.log    # watch for "hotkey armed LIVE"

   (Tip: run tools/make-signing-cert.sh once to stop needing this every upgrade.)
EOF
fi
