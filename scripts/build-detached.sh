#!/usr/bin/env bash
# build-detached.sh — build a local copy of Birdwatch and launch it for dogfooding.
#
# No arguments. Just run it:
#
#     ./scripts/build-detached.sh
#
# Every run:
#   1. BUILDS into an ISOLATED DerivedData (/tmp/<App>-build-detached) so this build can never
#      corrupt — or be corrupted/evicted by — whatever else is building at the same time (Xcode,
#      or a copy an agent is compiling while you work).
#   2. INSTALLS a decoupled, visually-distinct copy at ~/Applications/<App>-dev.app that shows up
#      as "<App> Dev" in the Dock / Cmd-Tab, so you can tell your dogfood copy apart from any copy
#      an agent is running. It gets its OWN bundle id (DEV_BUNDLE_ID, via the command-line build
#      setting BW_BUNDLE_ID_SUFFIX — release builds keep com.wizemann.birdwatch), so it does not
#      share UserDefaults/onboarding state or LaunchServices identity with an installed release,
#      and Sparkle refuses to install a release update over it (bundle-id mismatch).
#      TCC CONSEQUENCE: privacy grants are per bundle id, so the dev copy needs its OWN Full Disk
#      Access grant (System Settings → Privacy & Security → Full Disk Access → add
#      ~/Applications/<App>-dev.app). The release's grant no longer covers it — and because the
#      copy is ad-hoc signed, a rebuild can invalidate the grant; re-toggle it if FDA reads fail.
#   3. STOPS only the copy THIS script launched before — identified strictly by that exact
#      ~/Applications/<App>-dev.app install path. A copy running from any OTHER path (e.g. an
#      agent's test build out of its own DerivedData) is never matched and keeps running.
#   4. LAUNCHES the fresh copy with `open -n` (a new instance, so it coexists with any other).
#
# The build is only swapped in on success: if it fails, your currently-running copy is left alone.
# Output goes to a temp log; the terminal shows a concise progress line + errors only on failure.
#
# Build-correctness this encapsulates (so nobody re-learns it per project):
#   * ISOLATED DerivedData — never the shared one a GUI Xcode or another agent build is using.
#   * -workspace when one is set (some projects need it for SwiftPM trait resolution), else -project.
#   * Toolchain: DEVELOPER_DIR if exported, else BUILD_DETACHED_XCODE_APP, else xcode-select's
#     Xcode; optional `xcodegen` regen (XCODEGEN) from project.yml.
#   * SPM checkout auto-repair after an interrupted build (one wipe-and-retry).
#
# Optional env overrides (not needed for normal use):
#   BUILD_DETACHED_CONFIG   Release | Debug   (default: Release)
#   BUILD_DETACHED_DERIVED  isolated DerivedData path
#   BUILD_DETACHED_APP      decoupled install path
#   BUILD_DETACHED_XCODE_APP  pin an Xcode.app (only used when DEVELOPER_DIR is not exported)
set -euo pipefail

# ============================ CONFIG (edit per project) ============================
# WORKSPACE/PROJECT: set exactly one (workspace wins).  SCHEME: xcodebuild scheme.
# APP_PRODUCT: built .app / process name.  DISPLAY_NAME: Dock name for the dev copy.
# BUNDLE_ID: the RELEASE bundle id (used only to gracefully quit a running release copy).
# DEV_BUNDLE_ID_SUFFIX → DEV_BUNDLE_ID: the id the dogfood copy is built with.
# XCODE_APP: "" = DEVELOPER_DIR / xcode-select's Xcode.  XCODEGEN: 1 = regen from project.yml first.
# CHECK_ICLOUD: 1 = warn if iCloud entitlement missing.
WORKSPACE=""
PROJECT="Birdwatch.xcodeproj"
SCHEME="Birdwatch"
APP_PRODUCT="Birdwatch"
DISPLAY_NAME="Birdwatch Dev"
BUNDLE_ID="com.wizemann.birdwatch"
DEV_BUNDLE_ID_SUFFIX=".dev"
DEV_BUNDLE_ID="${BUNDLE_ID}${DEV_BUNDLE_ID_SUFFIX}"
XCODE_APP="${BUILD_DETACHED_XCODE_APP:-}"
XCODEGEN=1
CHECK_ICLOUD=0
# ===================================================================================

CONFIG="${BUILD_DETACHED_CONFIG:-Release}"
DERIVED="${BUILD_DETACHED_DERIVED:-/tmp/${APP_PRODUCT}-build-detached}"
SPM="${BUILD_DETACHED_SPM:-/tmp/${APP_PRODUCT}-build-detached-spm}"
INSTALL_PATH="${BUILD_DETACHED_APP:-$HOME/Applications/${APP_PRODUCT}-dev.app}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXEC_DIR="$INSTALL_PATH/Contents/MacOS"    # the unique fingerprint of OUR running copy
BUILD_LOG="$(mktemp -t "${APP_PRODUCT}-build-detached")"
trap '[ "${KEEP_LOG:-0}" = 1 ] || rm -f "$BUILD_LOG"' EXIT   # kept on failure for inspection
say() { printf '%s\n' "$*" >&2; }

# Pick a real Xcode.app — NEVER the Command Line Tools (which can't run xcodebuild). We resolve it
# via DEVELOPER_DIR (no sudo), so a build keeps working even after an Xcode swap leaves
# `xcode-select` pointing at /Library/Developer/CommandLineTools. Preference: a caller-exported
# DEVELOPER_DIR → BUILD_DETACHED_XCODE_APP (XCODE_APP) → xcode-select's choice if it's a full
# Xcode → the first Xcode.app found in /Applications. No Xcode is hardcoded: this builds with
# whatever toolchain the rest of the machine uses unless told otherwise.
if [ -z "${DEVELOPER_DIR:-}" ]; then
  if [ -n "$XCODE_APP" ]; then
    [ -d "$XCODE_APP" ] || { say "!! BUILD_DETACHED_XCODE_APP=$XCODE_APP does not exist"; exit 1; }
    export DEVELOPER_DIR="$XCODE_APP"
  else
    case "$(xcode-select -p 2>/dev/null)" in
      */Xcode*.app/Contents/Developer) : ;;                  # already a full Xcode — leave it
      *)                                                      # CLT or unset → find a real Xcode.app
        for _x in /Applications/Xcode.app /Applications/Xcode-*.app; do
          [ -x "$_x/Contents/Developer/usr/bin/xcodebuild" ] && { export DEVELOPER_DIR="$_x"; break; }
        done ;;
    esac
  fi
fi
# Fail early with an actionable message rather than a cryptic xcode-select error.
if ! xcodebuild -version >/dev/null 2>&1; then
  say "!! No usable Xcode found (xcode-select -p = $(xcode-select -p 2>/dev/null))."
  say "   Point the CLI at your Xcode once:  sudo xcode-select -s /Applications/Xcode.app"
  say "   …or export DEVELOPER_DIR (or BUILD_DETACHED_XCODE_APP=/Applications/Xcode.app) before running."
  exit 1
fi

# ---- the one correct xcodebuild invocation for this project (action passed last) ----
xcb() {
  local action="$1"; shift
  local container=(-project "$PROJECT")
  [ -n "$WORKSPACE" ] && container=(-workspace "$WORKSPACE")
  # env -u BW_STATS_WRITE_KEY: xcodebuild expands $(BW_STATS_WRITE_KEY) in Info.plist from the
  # environment, so a key exported in this shell would bake the real write key into a dogfood
  # build and send its analytics under the release appId. Dev builds always ship with it empty.
  ( cd "$REPO_ROOT" && env -u BW_STATS_WRITE_KEY xcodebuild \
      "${container[@]}" \
      -scheme "$SCHEME" \
      -configuration "$CONFIG" \
      -destination 'platform=macOS' \
      -derivedDataPath "$DERIVED" \
      -clonedSourcePackagesDirPath "$SPM" \
      "$@" \
      "$action" )
}

# ---- build with a concise live progress line (phase + elapsed), NOT the raw xcodebuild
#      firehose. Everything still goes to $BUILD_LOG so real errors can be shown if it fails.
#      One-shot SPM-corruption recovery: an interrupted build can leave checkout dirs without
#      their Package.swift, so every rebuild then fails "Could not resolve package dependencies".
build() {
  local rc=0 attempt
  for attempt in 1 2; do
    : > "$BUILD_LOG"
    ( xcb build "$@" >"$BUILD_LOG" 2>&1 ) &
    local bpid=$!
    trap 'kill "$bpid" 2>/dev/null' INT TERM
    render_progress "$bpid"
    rc=0; wait "$bpid" || rc=$?
    trap - INT TERM
    [ "$rc" -eq 0 ] && return 0
    if [ "$attempt" -eq 1 ] && grep -qE "Could not resolve package dependencies|doesn't exist in file system|cannot be accessed" "$BUILD_LOG"; then
      say "==> SPM checkout looks corrupt (interrupted build) — resetting $SPM and retrying once…"
      rm -rf "$SPM"; continue
    fi
    return "$rc"
  done
  return "$rc"
}

# best-effort current phase, inferred from the tail of the build log
_phase() {
  case "$(tail -n 50 "$BUILD_LOG" 2>/dev/null)" in
    *"CodeSign "*|*"Signing Identity"*)            echo "signing" ;;
    *"Ld "*)                                       echo "linking" ;;
    *"SwiftCompile"*|*"CompileC "*|*"Compiling"*)  echo "compiling" ;;
    *"Resolve Package"*|*"Fetching"*|*"Cloning"*|*"Resolved source"*) echo "resolving packages" ;;
    *)                                             echo "preparing" ;;
  esac
}

# live single-line progress while $1 (the xcodebuild child) runs; falls back to one line per
# phase change when stderr is not a terminal (e.g. output captured by an agent).
render_progress() {
  local bpid="$1" start i=0; start="$(date +%s)"
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  if [ -t 2 ]; then
    while kill -0 "$bpid" 2>/dev/null; do
      local el=$(( $(date +%s) - start ))
      printf '\r\033[K    %s  %02d:%02d  %s' "${frames[i % 10]}" $((el / 60)) $((el % 60)) "$(_phase)" >&2
      i=$((i + 1)); sleep 0.25
    done
    printf '\r\033[K' >&2
  else
    local last=""
    while kill -0 "$bpid" 2>/dev/null; do
      local p; p="$(_phase)"
      [ "$p" != "$last" ] && { printf '    → %s\n' "$p" >&2; last="$p"; }
      sleep 1
    done
  fi
}

# ---- enforce a SINGLE instance: quit every running copy of this app before we launch the fresh
#      one, so you never end up with multiple builds open — no matter how the others were launched
#      (a previous run, a double-click, or Xcode's Run). The ONE exception: a copy running from a
#      /tmp (or /var/folders) isolated build is an agent's detached test copy, which we deliberately
#      leave alone. We identify the app by its own executable (…/Contents/MacOS/<APP_PRODUCT>) and
#      quit by PID, waiting for exit BEFORE clobbering the bundle so the on-disk store isn't torn.
quit_running_copies() {
  local pid cmd victims=() has_tmp=0
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    cmd="$(ps -p "$pid" -o command= 2>/dev/null)"
    case "$cmd" in *"/Contents/MacOS/$APP_PRODUCT"*) ;; *) continue ;; esac          # this app's executable
    case "$cmd" in *"/tmp/"*|*"/var/folders/"*) has_tmp=1; continue ;; esac          # spare agent /tmp builds
    victims+=("$pid")
  done < <(pgrep -x "$APP_PRODUCT" 2>/dev/null)
  [ ${#victims[@]} -gt 0 ] || return 0
  say "==> quitting ${#victims[@]} running copy(ies) of $APP_PRODUCT before launch (agent /tmp test builds left alone)…"
  # Graceful FIRST: an Apple Event "quit" runs the app's normal termination so it FLUSHES
  # UserDefaults and leaves cfprefsd's domain view coherent. A force-kill (below) skips that —
  # the write reaches the plist but the daemon serves an empty domain, so the next launch reads
  # defaults (this is why scan/auto-file settings appeared to "reset"). Target by bundle id (no
  # "locate app" prompt), but ONLY when no /tmp agent copy is running, since an id-quit hits every
  # instance. If a /tmp copy is up, skip straight to the PID-scoped kill that spares it.
  # Both ids: the previous dev copy runs as DEV_BUNDLE_ID, an installed release as BUNDLE_ID.
  # Only ids LaunchServices reports as RUNNING (lsappinfo) are ever handed to AppleScript: naming
  # an app id that isn't running/registered can make AppleScript resolve it — and, for an id it
  # can't find, raise a "Where is …?" chooser. lsappinfo prints nothing when no process matches.
  if [ "$has_tmp" = 0 ] && [ -n "${BUNDLE_ID:-}" ]; then
    local _id
    for _id in "$DEV_BUNDLE_ID" "$BUNDLE_ID"; do
      [ -n "$(lsappinfo find "bundleid=$_id" 2>/dev/null)" ] || continue
      osascript -e "tell application id \"$_id\" to quit" >/dev/null 2>&1 || true
    done
    for _ in $(seq 1 12); do
      local alive=0; for pid in "${victims[@]}"; do kill -0 "$pid" 2>/dev/null && alive=1; done
      [ "$alive" = 0 ] && return 0; sleep 0.5
    done
  fi
  kill "${victims[@]}" 2>/dev/null || true                                          # SIGTERM fallback
  for _ in $(seq 1 16); do
    local alive=0; for pid in "${victims[@]}"; do kill -0 "$pid" 2>/dev/null && alive=1; done
    [ "$alive" = 0 ] && return 0; sleep 0.5
  done
  say "   still running after 8s — SIGKILL…"
  for pid in "${victims[@]}"; do kill -9 "$pid" 2>/dev/null || true; done; sleep 1
}

# ---- make sure the installed copy carries the distinct Dock name ----
# Happy path: the build baked CFBundleDisplayName in via INFOPLIST_KEY_… (GENERATE_INFOPLIST_FILE),
# so this is a no-op. Fallback (e.g. a project with a literal Info.plist): stamp it and re-sign,
# preserving entitlements so iCloud/CloudKit still work.
ensure_display_name() {
  local plist="$INSTALL_PATH/Contents/Info.plist" cur=""
  cur="$(plutil -extract CFBundleDisplayName raw "$plist" 2>/dev/null || true)"
  [ "$cur" = "$DISPLAY_NAME" ] && return 0
  say "==> stamping display name \"$DISPLAY_NAME\" (build did not bake it in) and re-signing…"
  plutil -replace CFBundleDisplayName -string "$DISPLAY_NAME" "$plist"
  local id; id="$(codesign -dvv "$INSTALL_PATH" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
  codesign --force --preserve-metadata=entitlements,requirements,flags --sign "${id:--}" "$INSTALL_PATH" 2>/dev/null \
    || codesign --force --preserve-metadata=entitlements,requirements,flags --sign - "$INSTALL_PATH"
}

# ---- xcodegen-managed projects (XCODEGEN=1): regenerate the .xcodeproj from project.yml when the
#      spec is newer (or the project is missing), so we build the current definition. No-op otherwise.
regen_xcodeproj() {
  [ "${XCODEGEN:-0}" = 1 ] || return 0
  local gen_dir="$REPO_ROOT/$(dirname "${WORKSPACE:-$PROJECT}")"
  local spec="$gen_dir/project.yml"
  [ -f "$spec" ] || return 0
  command -v xcodegen >/dev/null 2>&1 || { say "!! XCODEGEN=1 but xcodegen not found — building the existing project"; return 0; }
  local target="$REPO_ROOT/$PROJECT"
  if [ ! -d "$target" ] || [ "$spec" -nt "$target" ]; then
    say "==> xcodegen: regenerating $(basename "$PROJECT") from project.yml…"
    # Without DEVELOPMENT_TEAM: project.yml carries ${DEVELOPMENT_TEAM}, and xcodegen would bake a
    # literal team id into the committed .xcodeproj (same rule as release.sh).
    ( cd "$gen_dir" && env -u DEVELOPMENT_TEAM xcodegen generate ) >/dev/null 2>&1 || say "!! xcodegen generate failed — building the existing project"
  fi
}

# ================================== run ==================================
regen_xcodeproj
say "==> building $SCHEME ($CONFIG) → isolated DerivedData $DERIVED"
# ENABLE_HARDENED_RUNTIME=NO → the dogfood copy is ad-hoc signed (no DEVELOPMENT_TEAM needed to
# build Birdwatch locally). Hardened runtime enforces library validation, and an ad-hoc-signed app
# may not load an ad-hoc-signed embedded framework — Sparkle.framework fails with "mapping process
# and mapped file (non-platform) have different Team IDs" and the app dies at dyld time. Release
# builds keep hardened runtime ON (project.yml); notarization requires it.
# ONLY_ACTIVE_ARCH=YES → build just this Mac's slice (not a universal binary); it's a local
# dogfood copy, so half the compile for the same runtime behavior.
_t0="$(date +%s)"
# BW_BUNDLE_ID_SUFFIX=.dev → the distinct dev identity described in the header. The app target's
# PRODUCT_BUNDLE_IDENTIFIER is com.wizemann.birdwatch$(BW_BUNDLE_ID_SUFFIX) (project.yml), so this
# changes only the app — not SwiftPM resource bundles, which a plain PRODUCT_BUNDLE_IDENTIFIER=
# override would restamp too. release.sh never sets it and asserts the built id.
if ! build -allowProvisioningUpdates ONLY_ACTIVE_ARCH=YES ENABLE_HARDENED_RUNTIME=NO "BW_BUNDLE_ID_SUFFIX=$DEV_BUNDLE_ID_SUFFIX" "INFOPLIST_KEY_CFBundleDisplayName=$DISPLAY_NAME" ${EXTRA_XCODEBUILD_ARGS[@]+"${EXTRA_XCODEBUILD_ARGS[@]}"}; then
  KEEP_LOG=1
  say "!! BUILD FAILED — your currently-running copy (if any) was left untouched. Errors:"
  grep -E "error:|fatal error:" "$BUILD_LOG" | grep -v "GeneratedModuleMaps" | head -8 >&2 || true
  say "   full build log kept at: $BUILD_LOG"
  exit 1
fi
_dt=$(( $(date +%s) - _t0 ))
say "==> build OK in $((_dt / 60))m$((_dt % 60))s"

BUILT="$DERIVED/Build/Products/$CONFIG/$APP_PRODUCT.app"
[ -d "$BUILT" ] || { say "!! build succeeded but $BUILT is missing"; exit 1; }

if [ "$CHECK_ICLOUD" = 1 ] && ! codesign -d --entitlements - "$BUILT" 2>/dev/null | grep -q 'icloud-container-identifiers'; then
  say "!! WARNING: built app has no iCloud entitlements — CloudKit + bookmarks will fail at runtime."
fi

# Swap in only on a good build: quit every running copy, install the new one decoupled, make it distinct.
quit_running_copies
rm -rf "$INSTALL_PATH"
mkdir -p "$(dirname "$INSTALL_PATH")"
cp -R "$BUILT" "$INSTALL_PATH"
ensure_display_name

open -n "$INSTALL_PATH"
say "==> launched \"$DISPLAY_NAME\" → $INSTALL_PATH  (decoupled; safe from the next build)"
