#!/bin/bash
#
# One command per release: bump the version, package, commit, tag, push, create the Release.
#
#   scripts/release.sh 1.0.0
#   scripts/release.sh 1.0.0 "what changed, in one line"
#   scripts/release.sh 1.0.0 "…" --yes        # skip the confirmation
#
# Signing is decided here, not assumed: with a "Developer ID Application" certificate in the
# keychain and a notarytool profile, the build is signed and notarized and opens without a
# Gatekeeper warning. Without them it is ad-hoc signed, and the script says so loudly — macOS
# then makes the user confirm the app before the first launch, and asks for the Accessibility
# grant again after every update, because the grant is tied to the signature.
#
# The version lives in MenuHider/Resources/Info.plist and is written exactly once, here, so the
# plist, the tag and the Release can never disagree.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${PROJECT_DIR}"

REMOTE="origin"
BRANCH="master"
PLIST="MenuHider/Resources/Info.plist"
APP="build/Build/Products/Release/MenuHider.app"
PROFILE="${NOTARY_PROFILE:-notary-profile}"

# Signing overrides live in local.mk, which the Makefile reads too and git ignores.
# shellcheck source=/dev/null
[ -f local.mk ] && . ./local.mk
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
TEAM="${TEAM:-}"

VERSION="${1:-}"
NOTE="${2:-}"
ASSUME_YES=""
for arg in "$@"; do
    [ "$arg" = "--yes" ] && ASSUME_YES=1
done
[ "$NOTE" = "--yes" ] && NOTE=""

die() { echo "❌ $*" >&2; exit 1; }

# ── Arguments
[ -n "$VERSION" ] || die "usage: scripts/release.sh <version> [note] [--yes]
   for example: scripts/release.sh 1.0.0 \"two hidden zones, one switch\""
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "the version must be x.y.z, got «${VERSION}»"

TAG="v${VERSION}"

# ── Preconditions: each one is cheaper to stop on now than to fix after publishing
xcodebuild -version >/dev/null 2>&1 || die "xcodebuild cannot find Xcode. Point the toolchain at it:
   sudo xcode-select -s /Applications/Xcode.app
   (or run with DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer)"
git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository"
[ -z "$(git status --porcelain)" ] || die "the working tree is dirty. Commit or stash first —
   the release commit should contain the version bump and nothing else"
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$CURRENT_BRANCH" = "$BRANCH" ] || die "on branch $CURRENT_BRANCH, releases are cut from $BRANCH"
git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null && die "tag ${TAG} already exists"
git ls-remote --exit-code --tags "$REMOTE" "refs/tags/${TAG}" >/dev/null 2>&1 \
    && die "the remote already has tag ${TAG}"

CURRENT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
CURRENT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")"

# ── Signing: notarized only when the tooling is actually there
SIGNING="ad-hoc"
if [ -n "$TEAM" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY" \
    && xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    SIGNING="notarized"
fi

echo "About to release ${TAG} (currently ${CURRENT_VERSION} build ${CURRENT_BUILD})"
echo "  · write ${VERSION} (build $((CURRENT_BUILD + 1))) into $PLIST"
echo "  · build MenuHider.app — ${SIGNING}"
if [ "$SIGNING" = "ad-hoc" ]; then
    echo "    no Developer ID certificate plus notarytool profile, so this build is NOT notarized:"
    echo "    users confirm it once in System Settings, and updating asks for Accessibility again"
    echo "    (to sign properly: put SIGN_IDENTITY and TEAM in local.mk and run"
    echo "     xcrun notarytool store-credentials $PROFILE --apple-id … --team-id … --password …)"
fi
echo "  · package dist/MenuHider-${VERSION}.zip"
echo "  · commit «Release ${VERSION}», tag ${TAG}"
echo "  · push ${BRANCH} and ${TAG} to ${REMOTE}"
echo "  · create the GitHub Release with the zip attached"

if [ -z "$ASSUME_YES" ]; then
    printf "Continue? [y/N] "
    read -r reply || die "nobody answered (not a terminal?) — re-run with --yes to release unattended"
    [ "$reply" = "y" ] || [ "$reply" = "Y" ] || { echo "cancelled"; exit 0; }
fi

# ── Version (the one write)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((CURRENT_BUILD + 1))" "$PLIST"
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")" = "$VERSION" ] \
    || die "the version did not stick, check $PLIST"
echo "✅ version → ${VERSION}"

# ── Build
xcodegen generate --use-cache
if [ "$SIGNING" = "notarized" ]; then
    xcodebuild -project menu-hider.xcodeproj -scheme MenuHider -configuration Release -derivedDataPath build \
        CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
        ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS=--timestamp \
        CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO build | tail -3   # no get-task-allow: Apple rejects it
    codesign --verify --deep --strict "$APP"
else
    xcodebuild -project menu-hider.xcodeproj -scheme MenuHider -configuration Release -derivedDataPath build \
        CODE_SIGN_IDENTITY="-" build | tail -3
fi
[ -d "$APP" ] || die "the build produced no $APP"

# ── Package
ZIP="dist/MenuHider-${VERSION}.zip"
mkdir -p dist
ditto -c -k --keepParent "$APP" "$ZIP"
if [ "$SIGNING" = "notarized" ]; then
    # notarytool exits 0 even when Apple rejects the archive, so check the verdict ourselves.
    xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait 2>&1 | tee dist/notarize.log
    grep -q 'status: Accepted' dist/notarize.log || die "notarization failed, see dist/notarize.log"
    xcrun stapler staple "$APP"
    ditto -c -k --keepParent "$APP" "$ZIP"   # re-zip so the download carries the stapled ticket
    spctl -a -vv -t exec "$APP"
fi
[ -f "$ZIP" ] || die "no $ZIP"
echo "✅ packaged $ZIP"
shasum -a 256 "$ZIP"

# ── Installer image
# The zip stays: the in-app updater downloads and unpacks it, and it takes the asset named
# MenuHider-<version>.zip. The image is for people who arrive at the Releases page.
#
# create-dmg writes the window size, the icon positions and the Applications drop link into the
# image's .DS_Store, which is what makes it open as a drag-and-drop diagram. Bare hdiutil gives a
# folder that works but explains nothing.
command -v create-dmg >/dev/null 2>&1 || die "create-dmg is missing — install it with
   brew install create-dmg
   (the zip above is packaged and usable; only the installer image needs it)"
DMG="dist/MenuHider-${VERSION}.dmg"
rm -f "$DMG"   # create-dmg refuses to overwrite
create-dmg \
    --volname "MenuHider" \
    --window-pos 200 120 \
    --window-size 600 420 \
    --icon-size 128 \
    --icon "MenuHider.app" 150 210 \
    --hide-extension "MenuHider.app" \
    --app-drop-link 450 210 \
    --no-internet-enable \
    "$DMG" "$APP" >/dev/null || die "create-dmg failed"
[ -f "$DMG" ] || die "no $DMG"
if [ "$SIGNING" = "notarized" ]; then
    # The image needs its own ticket: Gatekeeper assesses the image the user opens, and the app's
    # ticket inside it cannot be stapled to the image afterwards.
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait 2>&1 | tee dist/notarize-dmg.log
    grep -q 'status: Accepted' dist/notarize-dmg.log || die "DMG notarization failed, see dist/notarize-dmg.log"
    xcrun stapler staple "$DMG"
fi
echo "✅ packaged $DMG"
shasum -a 256 "$DMG"

# ── Commit + tag
# --allow-empty: the version may already be the target one (bumped by hand, or a release that
# was packaged but never published). `git commit` would then exit non-zero with "nothing to
# commit" and, under set -e, stop the release in its tracks — an empty commit keeps the tag
# pointing at a commit that says «Release X» instead.
git add "$PLIST"
git commit -q --allow-empty -m "Release ${VERSION}" -m "${NOTE}"
git tag -a "${TAG}" -m "MenuHider ${VERSION}"
echo "✅ committed and tagged ${TAG}"

# ── Push
git push "$REMOTE" "$BRANCH"
git push "$REMOTE" "${TAG}"
echo "✅ pushed"

# ── GitHub Release
NOTES="${NOTE:-MenuHider ${VERSION}}"
if [ "$SIGNING" = "ad-hoc" ]; then
    NOTES="${NOTES}

**This build is not notarized** (it is ad-hoc signed). On first launch macOS asks you to confirm
it — open it from Finder with a right click → *Open*, or allow it in *System Settings → Privacy &
Security*. It also asks for the Accessibility permission again after each update."
fi

if ! gh release create "${TAG}" "$ZIP" "$DMG" --title "MenuHider ${VERSION}" --notes "$NOTES"; then
    cat >&2 <<'MSG'

❌ The Release was not created.

   The usual cause is that the active gh account is not the repository owner: creating a Release
   as a collaborator hits GitHub's workflow permission requirement, and reports a vague 404.
   Check the account first:

       gh auth status          # is the active account the owner?
       gh auth switch -u SkyCTing

   The tag and the commit are already pushed, so finishing by hand is one command:

       gh release create <tag> <zip path> --title "MenuHider <version>" --notes "…"
MSG
    exit 1
fi

echo ""
echo "🎉 released ${TAG}"
gh release view "${TAG}" --json url -q .url 2>/dev/null || true
