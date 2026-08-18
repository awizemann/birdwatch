#!/usr/bin/env bash

# --- Xcode toolchain guard: build with a real Xcode.app (not the Command Line Tools), resolved via
#     DEVELOPER_DIR (no sudo). Survives an Xcode swap that left `xcode-select` on CommandLineTools. ---
if [ -z "${DEVELOPER_DIR:-}" ]; then
  case "$(xcode-select -p 2>/dev/null)" in
    */Xcode*.app/Contents/Developer) : ;;
    *) for _xc in /Applications/Xcode.app /Applications/Xcode-*.app; do
         [ -x "$_xc/Contents/Developer/usr/bin/xcodebuild" ] && { export DEVELOPER_DIR="$_xc"; break; }
       done ;;
  esac
fi
#
# Birdwatch release pipeline — local, manual, repeatable.
#
# Usage:
#   ./scripts/release.sh 0.1.0              # full release: build, sign, notarize,
#                                           # GitHub release, tag main, publish appcast
#   ./scripts/release.sh 0.1.0 --draft      # everything builds + notarizes, but the
#                                           # GitHub release is created as draft, main
#                                           # is NOT tagged and the appcast is NOT
#                                           # published. Promote manually.
#
# Release notes:
#   `releases/v<VERSION>/RELEASE_NOTES.md` MUST exist before running. The script
#   uses it as the GitHub release body. Write the notes ahead of time, commit
#   them, then run release.
#
# Prerequisites (one-time setup):
#   1. Developer ID Application cert installed in login Keychain:
#        security find-identity -v -p codesigning | grep "Developer ID Application"
#   2. Signing team — Birdwatch does not hardcode a Team ID (open source):
#        export DEVELOPMENT_TEAM=XXXXXXXXXX
#      Optionally override the identity:  export SIGNING_IDENTITY="Developer ID Application"
#   3. Notarization credentials (pick ONE):
#      A) App Store Connect API key (preferred — no 2FA / app-specific password):
#           put AuthKey_<KEYID>.p8 in ~/.appstoreconnect/private_keys/ and export
#           NOTARY_KEY_ID=<KEYID> NOTARY_ISSUER_ID=<issuer uuid>
#      B) notarytool keychain profile:
#           xcrun notarytool store-credentials "birdwatch-notary" \
#             --key ~/.private/AuthKey_XXXX.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
#         Override the name with BIRDWATCH_NOTARY_PROFILE=<profile>.
#   4. gh CLI authed:
#        gh auth status
#
# Sparkle auto-update:
#   After the GitHub release, scripts/appcast.sh signs the zip with the EdDSA
#   key in your login Keychain, regenerates appcast.xml, and publishes it to
#   gh-pages (https://awizemann.github.io/birdwatch/appcast.xml — the app's
#   SUFeedURL). One-time prereq: run Sparkle's bundled `generate_keys` tool
#   (stores the private key in your Keychain; paste the printed public key into
#   Birdwatch/Resources/Info.plist → SUPublicEDKey). This script refuses to ship
#   while that key is still the placeholder.
#

set -euo pipefail

# ---------- arg parsing ----------
VERSION=""
DRAFT=0
for arg in "$@"; do
  case "$arg" in
    --draft) DRAFT=1 ;;
    -h|--help) sed -n '2,52p' "$0"; exit 0 ;;
    -*) printf '[ERR] unknown flag: %s\n' "$arg" >&2; exit 1 ;;
    *) [[ -z "$VERSION" ]] && VERSION="$arg" || { printf '[ERR] unexpected arg: %s\n' "$arg" >&2; exit 1; } ;;
  esac
done
[[ -n "$VERSION" ]] || { printf 'usage: ./scripts/release.sh <marketing-version> [--draft]\n' >&2; exit 1; }

# ---------- config ----------
# Birdwatch is open source and deliberately does NOT hardcode a Team ID.
TEAM_ID="${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM to your Apple Developer Team ID (see 'security find-identity -v -p codesigning')}"
export DEVELOPMENT_TEAM="$TEAM_ID"
# swift-stats write key for api.swiftstats.co (Memophant vendor "swift-stats").
# Append-only and scoped to one project, but it is still not committed: it is
# baked into Info.plist (BWStatsWriteKey) via the BW_STATS_WRITE_KEY build
# setting at archive time. A release without it would silently ship with
# analytics off, so it is required here.
STATS_WRITE_KEY="${BW_STATS_WRITE_KEY:?set BW_STATS_WRITE_KEY to the swift-stats write key (Memophant → vendors → swift-stats)}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application}"
BUNDLE_ID="com.wizemann.birdwatch"
SCHEME="Birdwatch"
PROJECT="Birdwatch.xcodeproj"
NOTARY_PROFILE="${BIRDWATCH_NOTARY_PROFILE:-birdwatch-notary}"
GH_REPO="awizemann/birdwatch"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/Birdwatch.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTIONS_TEMPLATE="$REPO_ROOT/scripts/ExportOptions.plist.template"
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
MERGE_BASE_PLIST="$REPO_ROOT/Birdwatch/Resources/Info.plist"
RELEASE_DIR="$REPO_ROOT/releases/v${VERSION}"
ZIP_NAME="Birdwatch-v${VERSION}-Universal.zip"
ZIP_PATH="$RELEASE_DIR/$ZIP_NAME"

# ---------- helpers ----------
log()  { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[WARN] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERR] %s\033[0m\n' "$*" >&2; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

# ---------- preflight ----------
log "Preflight checks"
require_cmd xcodebuild
require_cmd xcrun
require_cmd ditto
require_cmd gh
require_cmd xcodegen
require_cmd python3

cd "$REPO_ROOT"

# Git must be clean and on main. Allow the release dir to exist (RELEASE_NOTES.md
# pre-written) — git status abbreviates a fully-untracked dir to its trailing
# slash, so we whitelist all three observable forms:
#   "?? releases/v<VER>"             (no trailing slash — rare, manual git add path)
#   "?? releases/v<VER>/"            (porcelain abbreviation when the dir is fully untracked)
#   "?? releases/v<VER>/RELEASE_NOTES.md"  (the file is the only thing untracked)
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$BRANCH" == "main" ]] || die "must be on 'main' (currently '$BRANCH')"

DIRTY="$(git status --porcelain | grep -vE "^\?\? releases/v${VERSION}(/(RELEASE_NOTES\.md)?)?$" || true)"
[[ -z "$DIRTY" ]] || die "git working tree must be clean (excluding releases/v${VERSION}/RELEASE_NOTES.md). Run 'git status'."

# Release notes must exist.
NOTES_PATH="$RELEASE_DIR/RELEASE_NOTES.md"
[[ -f "$NOTES_PATH" ]] || die "missing release notes at $NOTES_PATH. Write them first, commit, then re-run."

# Tag must not already exist.
if git rev-parse "v${VERSION}" >/dev/null 2>&1; then
  die "tag 'v${VERSION}' already exists. Bump the version or delete the tag."
fi

# Sparkle trust anchor must be real. Shipping the placeholder would produce an
# app that can never validate an update signature — and the mistake is only
# discoverable to users, months later, when the first update fails.
[[ -f "$MERGE_BASE_PLIST" ]] || die "missing Info.plist merge base at $MERGE_BASE_PLIST"
ED_KEY="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$MERGE_BASE_PLIST" 2>/dev/null || true)"
if [[ -z "$ED_KEY" || "$ED_KEY" == "REPLACE_WITH_PUBLIC_ED_KEY" ]]; then
  die "SUPublicEDKey in $MERGE_BASE_PLIST is still the placeholder — refusing to ship an app that can't verify updates.

Recovery (one-time):
  1. Resolve Sparkle's tools:  xcodebuild -resolvePackageDependencies -project ${PROJECT} -scheme ${SCHEME} -derivedDataPath build/DerivedData
  2. Run:                      build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
  3. Paste the printed public key into $MERGE_BASE_PLIST (SUPublicEDKey), commit, re-run this script."
fi

# Codesign identity present.
security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY" \
  || die "no '$SIGNING_IDENTITY' identity in login Keychain. See header for setup."

# Notary credential valid — either the ASC API key env path or a keychain profile.
# Preserves Birdwatch's dual auth (the API key path is the one that actually works here).
NOTARY_KEYFILE=""
if [[ -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" ]]; then
  NOTARY_KEYFILE="$HOME/.appstoreconnect/private_keys/AuthKey_${NOTARY_KEY_ID}.p8"
  [[ -f "$NOTARY_KEYFILE" ]] \
    || die "NOTARY_KEY_ID=$NOTARY_KEY_ID is set but $NOTARY_KEYFILE is missing.
  Put the App Store Connect .p8 there, or unset NOTARY_KEY_ID/NOTARY_ISSUER_ID to use the keychain profile '$NOTARY_PROFILE'."
  xcrun notarytool history --key "$NOTARY_KEYFILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" \
      --output-format plist >/dev/null 2>&1 \
    || die "the App Store Connect API key ($NOTARY_KEY_ID) was rejected by notarytool. Check NOTARY_ISSUER_ID and that the key still has the Developer role."
  log "Notarization auth: App Store Connect API key ($NOTARY_KEY_ID)"
else
  # No listing API for stored profiles; test by making a real (cheap) call.
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format plist >/dev/null 2>&1 \
    || die "notarytool profile '$NOTARY_PROFILE' missing or invalid, and NOTARY_KEY_ID/NOTARY_ISSUER_ID are unset. See header for setup."
  log "Notarization auth: keychain profile '$NOTARY_PROFILE'"
fi

# gh authed.
gh auth status >/dev/null 2>&1 || die "'gh' is not authenticated. Run 'gh auth login'."

# `gh` always prefers $GITHUB_TOKEN over its keyring, and an env-var token
# without Releases: Write 403s at the very END — after the build, notarize, tag
# and push already succeeded. Warn loudly upfront and verify write access before
# any of that work happens.
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  warn "GITHUB_TOKEN is set in your environment."
  warn "  gh CLI will use this token instead of its keyring credentials."
  warn "  If the env-var token lacks 'repo' (classic) or 'Contents: Write' (fine-grained),"
  warn "  the release will 403 AFTER the build/notarize cycle."
  warn "  Recovery: 'unset GITHUB_TOKEN' to fall back to the keyring, or rotate the token."
fi

# Confirm the active token can actually write releases on $GH_REPO. The cheapest
# proxy is the authed user's push permission — true means it can create releases.
log "Checking gh has write access to ${GH_REPO}"
PUSH_OK="$(gh api "/repos/${GH_REPO}" --jq '.permissions.push' 2>/dev/null || echo "false")"
if [[ "$PUSH_OK" != "true" ]]; then
  die "gh's active token has no write access to ${GH_REPO}. Releases would 403 at the end of the build.

Recovery:
  1. If GITHUB_TOKEN is set in your shell:  unset GITHUB_TOKEN
  2. (re-)auth gh with 'repo' scope:        gh auth login
  3. Confirm scopes:                        gh auth status
  4. Re-run:                                ./scripts/release.sh ${VERSION}"
fi

log "Preflight OK"

# ---------- bump MARKETING_VERSION in project.yml ----------
# Birdwatch's project.yml uses UNQUOTED scalars (`MARKETING_VERSION: 0.1.0`),
# but accept quoted forms too so a future reformat doesn't silently no-op.
# subn() lets us tell "regex didn't match" (real error) from "already correct".
log "Setting project.yml MARKETING_VERSION to $VERSION"
python3 - "$REPO_ROOT/project.yml" "$VERSION" <<'PY'
import re, sys, pathlib
path = pathlib.Path(sys.argv[1])
version = sys.argv[2]
text = path.read_text()
new, n = re.subn(
    r'''(^[ \t]*MARKETING_VERSION:[ \t]*)(["']?)[^"'\s#]+\2''',
    lambda m: f'{m.group(1)}{m.group(2)}{version}{m.group(2)}',
    text,
    flags=re.M,
)
if n == 0:
    raise SystemExit("MARKETING_VERSION line not found in project.yml")
if new != text:
    path.write_text(new)
PY

# Sparkle compares CFBundleVersion (sparkle:version) to decide whether an update
# is newer, so it MUST increase every release. Bump CURRENT_PROJECT_VERSION.
log "Incrementing project.yml CURRENT_PROJECT_VERSION"
python3 - "$REPO_ROOT/project.yml" <<'PY'
import re, sys, pathlib
path = pathlib.Path(sys.argv[1])
text = path.read_text()
new, n = re.subn(
    r'''(^[ \t]*CURRENT_PROJECT_VERSION:[ \t]*)(["']?)(\d+)\2''',
    lambda m: f'{m.group(1)}{m.group(2)}{int(m.group(3)) + 1}{m.group(2)}',
    text,
    flags=re.M,
)
if n == 0:
    raise SystemExit("CURRENT_PROJECT_VERSION line not found in project.yml")
path.write_text(new)
PY

log "Regenerating $PROJECT"
# Regenerate WITHOUT the team id in the environment: xcodegen would otherwise
# bake the literal team into the committed .xcodeproj (project.yml carries
# `${DEVELOPMENT_TEAM}` on purpose — this is an open-source repo). The team is
# passed to xcodebuild explicitly at archive time instead.
env -u DEVELOPMENT_TEAM xcodegen generate >/dev/null

# Stage the version bump (committed alongside the release notes below).
git add project.yml

# ---------- archive ----------
log "Cleaning build directory"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

log "Archiving (Release, universal)"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  BW_STATS_WRITE_KEY="$STATS_WRITE_KEY" \
  CODE_SIGN_STYLE=Manual \
  archive

# ---------- export ----------
# Plists can't read the environment, so render the team-id-templated
# ExportOptions into build/ rather than hardcoding a Team ID in the repo.
log "Rendering ExportOptions.plist (teamID=$TEAM_ID)"
[[ -f "$EXPORT_OPTIONS_TEMPLATE" ]] || die "missing $EXPORT_OPTIONS_TEMPLATE"
sed "s/__TEAM_ID__/${TEAM_ID}/g" "$EXPORT_OPTIONS_TEMPLATE" > "$EXPORT_OPTIONS"
if grep -q '__TEAM_ID__' "$EXPORT_OPTIONS"; then
  die "ExportOptions template did not render (placeholder still present)"
fi

log "Exporting (.app)"
mkdir -p "$EXPORT_DIR"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS"

APP_PATH="$EXPORT_DIR/${SCHEME}.app"
[[ -d "$APP_PATH" ]] || die "exported .app not found at $APP_PATH"

# Guard the merge-base Info.plist + GENERATE_INFOPLIST_FILE merge (a lightly-
# documented Xcode behavior, §13). If a future Xcode drops the merge, either the
# GENERATED keys (versions, bundle id) or the MERGE-BASE keys (Sparkle) vanish
# silently — shipping an app that can't self-update. Verify at the BUILT PRODUCT.
PLIST="$APP_PATH/Contents/Info.plist"
for key in CFBundleIdentifier CFBundleName CFBundleVersion CFBundleShortVersionString \
           CFBundleIconFile SUFeedURL SUPublicEDKey LSMinimumSystemVersion BWStatsWriteKey; do
  /usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" >/dev/null 2>&1 \
    || die "built Info.plist missing '$key' — the merge-base plist merge may have broken (see project.yml INFOPLIST_FILE + GENERATE_INFOPLIST_FILE)."
done
# An iconless app is a real regression (Dock, Sparkle's update dialog, Finder) —
# fail loudly rather than ship it.
[[ -f "$APP_PATH/Contents/Resources/AppIcon.icns" ]] || die "AppIcon.icns missing from the built app."
# The key must have been EXPANDED, not left as the literal "$(BW_STATS_WRITE_KEY)".
BUILT_STATS_KEY="$(/usr/libexec/PlistBuddy -c "Print :BWStatsWriteKey" "$PLIST")"
[[ "$BUILT_STATS_KEY" == "$STATS_WRITE_KEY" ]] \
  || die "built Info.plist BWStatsWriteKey was not expanded from the build setting — analytics would ship disabled."
# The privacy manifest declares the analytics data types; a resource-bundling
# regression must not ship silently.
[[ -f "$APP_PATH/Contents/Resources/PrivacyInfo.xcprivacy" ]] \
  || die "built app is missing PrivacyInfo.xcprivacy"
BUILT_SHORT="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")"
[[ "$BUILT_SHORT" == "$VERSION" ]] \
  || die "built CFBundleShortVersionString is '$BUILT_SHORT', expected '$VERSION' — the project.yml bump didn't reach the build."

# ---------- notarize ----------
log "Zipping for notarization"
NOTARIZE_ZIP="$BUILD_DIR/Birdwatch-notarize.zip"
ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"

log "Submitting to notarytool (this can take a few minutes)"
if [[ -n "$NOTARY_KEYFILE" ]]; then
  xcrun notarytool submit "$NOTARIZE_ZIP" \
    --key "$NOTARY_KEYFILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" \
    --wait
else
  xcrun notarytool submit "$NOTARIZE_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
fi

log "Stapling ticket to .app"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH" >/dev/null

# ---------- final zip ----------
# Zipped AFTER stapling — the notarization zip predates the ticket.
log "Packaging $ZIP_NAME"
mkdir -p "$RELEASE_DIR"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

# Gatekeeper's actual verdict, not ours.
log "spctl --assess (should print 'accepted')"
spctl --assess --type execute --verbose=2 "$APP_PATH" 2>&1 | sed 's/^/    /'

# ---------- commit + tag ----------
log "Staging version bump + release notes"
git add "$NOTES_PATH"
# Skip the release commit when there's nothing to stage — happens when the
# release notes + version bump were committed ahead of running the script (the
# prep flow). Tagging the existing tip is the right move.
if git diff --cached --quiet; then
  log "Nothing to commit (notes + version already on main) — tagging tip"
else
  git commit -m "release: v${VERSION}

$(head -1 "$NOTES_PATH" | sed 's/^# //')

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
fi

if [[ "$DRAFT" -eq 1 ]]; then
  warn "draft mode — skipping tag + push of main"
else
  log "Tagging v${VERSION}"
  git tag -a "v${VERSION}" -m "Birdwatch v${VERSION}"
  log "Pushing main + tag"
  git push origin main
  git push origin "v${VERSION}"
fi

# ---------- gh release ----------
RELEASE_FLAGS=(--title "Birdwatch v${VERSION}" --notes-file "$NOTES_PATH")
if [[ "$DRAFT" -eq 1 ]]; then
  RELEASE_FLAGS+=(--draft)
fi

log "Creating GitHub release"
if [[ "$DRAFT" -eq 1 ]]; then
  # Draft releases don't need a tag yet — gh creates a placeholder.
  gh release create "v${VERSION}" "$ZIP_PATH" "${RELEASE_FLAGS[@]}" || die "gh release create failed"
else
  gh release create "v${VERSION}" "$ZIP_PATH" "${RELEASE_FLAGS[@]}" --target main \
    || die "gh release create failed"
fi

# ---------- sparkle appcast ----------
# Publish only for live releases — the appcast enclosure points at the now-live
# release asset. For drafts, publish manually after promoting (the asset URL
# isn't final until the release is published).
if [[ "$DRAFT" -eq 0 ]]; then
  log "Publishing Sparkle appcast"
  "$REPO_ROOT/scripts/appcast.sh" "$VERSION" \
    || die "appcast publish failed — but the release is already LIVE + tagged. Fix the cause and re-run: ./scripts/appcast.sh ${VERSION}
  Likely causes: missing Sparkle EdDSA key in the Keychain (run generate_keys), or a diverged/dirty .gh-pages-worktree (git -C .gh-pages-worktree reset --hard origin/gh-pages). appcast.sh is safely re-runnable."
else
  warn "draft mode — skipping appcast. After promoting the release: ./scripts/appcast.sh ${VERSION}"
fi

log "Done."
log "Artifact: $ZIP_PATH"
if [[ "$DRAFT" -eq 1 ]]; then
  log "Draft release created. Promote at: https://github.com/${GH_REPO}/releases"
else
  log "Live: https://github.com/${GH_REPO}/releases/tag/v${VERSION}"
fi
