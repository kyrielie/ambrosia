#!/usr/bin/env bash
# ==============================================================================
# scripts/release-local.sh — Build, Package, and Publish Ambrosia from Local Machine
#
# Builds Ambrosia in Release configuration on Apple Silicon macOS, ad-hoc
# signs the .app bundle, packages an unsigned DMG with /Applications symlink,
# generates SHA-256 checksum, publishes the GitHub Release via gh CLI, and
# dispatches the cask update event to kyrielie/homebrew-yggdrasil.
#
# Usage:
#   ./scripts/release-local.sh <version> [--skip-tests] [--dry-run]
#
# Example:
#   ./scripts/release-local.sh 0.2.0
#   ./scripts/release-local.sh v0.2.0 --dry-run
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="Ambrosia"
EXPECTED_USER="kyrielie"
EXPECTED_EMAIL="83477979+kyrielie@users.noreply.github.com"
TAP_REPO="kyrielie/homebrew-yggdrasil"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info()  { echo -e "${BLUE}==>${NC} $1"; }
log_ok()    { echo -e "    ${GREEN}[✓]${NC} $1"; }
log_warn()  { echo -e "    ${YELLOW}[!]${NC} $1"; }
log_err()   { echo -e "    ${RED}[✗]${NC} $1" >&2; }

# Parse arguments
VERSION=""
SKIP_TESTS=0
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --skip-tests)
      SKIP_TESTS=1
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    -h|--help)
      echo "Usage: $0 <version> [--skip-tests] [--dry-run]"
      echo ""
      echo "Arguments:"
      echo "  <version>       Semantic version to release (e.g. 0.2.0 or v0.2.0)"
      echo "  --skip-tests    Skip pre-flight test suite and SwiftLint"
      echo "  --dry-run       Build DMG and checksum locally without pushing commit or publishing release"
      exit 0
      ;;
    *)
      if [ -z "$VERSION" ]; then
        VERSION="${arg#v}"
      else
        log_err "Unknown argument: $arg"
        exit 1
      fi
      ;;
  esac
done

if [ -z "$VERSION" ]; then
  log_err "Release version required (e.g. 0.2.0 or v0.2.0)."
  echo "Usage: $0 <version> [--skip-tests] [--dry-run]" >&2
  exit 1
fi

TAG="v${VERSION}"

echo "======================================================================"
echo " Ambrosia Local Release Pipeline: ${TAG}"
echo "======================================================================"

# ------------------------------------------------------------------------------
# 1. Identity & Auth Checks
# ------------------------------------------------------------------------------
log_info "Verifying GitHub CLI authentication and Git attribution..."

CURRENT_GH_USER=$(gh api user --jq '.login' 2>/dev/null || echo "")
if [ "$CURRENT_GH_USER" != "$EXPECTED_USER" ]; then
  log_warn "Active gh account is '$CURRENT_GH_USER' (expected '$EXPECTED_USER'). Switching..."
  gh auth switch --user "$EXPECTED_USER"
  gh auth setup-git
  log_ok "Switched gh active account to '$EXPECTED_USER'."
else
  log_ok "gh CLI authenticated as '$EXPECTED_USER'."
fi

git config user.name "$EXPECTED_USER"
git config user.email "$EXPECTED_EMAIL"
log_ok "Git author config aligned to $EXPECTED_USER <$EXPECTED_EMAIL>."

# ------------------------------------------------------------------------------
# 2. Pre-flight Tests & Linting
# ------------------------------------------------------------------------------
if [ "$SKIP_TESTS" -eq 1 ]; then
  log_warn "Skipping pre-flight tests (--skip-tests specified)."
else
  log_info "Running XcodeGen project generation and test suite (./test.sh -q)..."
  xcodegen generate >/dev/null
  if ! ./test.sh -q; then
    log_err "Tests or SwiftLint failed. Aborting release."
    exit 1
  fi
  log_ok "All tests and SwiftLint passed."
fi

# ------------------------------------------------------------------------------
# 3. Version Bump & Git Synchronization
# ------------------------------------------------------------------------------
log_info "Updating MARKETING_VERSION to ${VERSION}..."

sed -i.bak -E "s/MARKETING_VERSION:.*/MARKETING_VERSION: ${VERSION}/" project.yml
rm -f project.yml.bak

if [ -f "Ambrosia/Resources/Info.plist" ]; then
  plutil -replace CFBundleShortVersionString -string "${VERSION}" Ambrosia/Resources/Info.plist
fi

xcodegen generate >/dev/null
log_ok "project.yml, Info.plist, and Ambrosia.xcodeproj updated to ${VERSION}."

if [ "$DRY_RUN" -eq 0 ]; then
  if [ -n "$(git status --porcelain project.yml Ambrosia/Resources/Info.plist Ambrosia.xcodeproj)" ]; then
    log_info "Committing version bump to ${VERSION}..."
    git add project.yml Ambrosia/Resources/Info.plist
    git add -f Ambrosia.xcodeproj/project.pbxproj
    git commit -m "chore(release): bump version to ${VERSION}"
    git push origin main
    log_ok "Pushed release commit to origin/main."
  else
    log_ok "Working copy version already matches ${VERSION}."
  fi
else
  log_warn "Dry run mode: skipping git commit and push."
fi

# ------------------------------------------------------------------------------
# 4. Release Build (Universal: ARM64 + x86_64)
# ------------------------------------------------------------------------------
BUILD_DIR="${TMPDIR:-/tmp}/ambrosia-release-build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

log_info "Building Ambrosia in Release configuration (Universal: ARM64 + x86_64)..."
xcodebuild \
  -project Ambrosia.xcodeproj \
  -scheme Ambrosia \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$BUILD_DIR" \
  MARKETING_VERSION="${VERSION}" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build >/dev/null

APP_PATH=$(find "$BUILD_DIR/Build/Products/Release" -maxdepth 1 -name "*.app" -print -quit)
if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
  log_err "Could not find built .app in $BUILD_DIR/Build/Products/Release."
  exit 1
fi
log_ok "Built application: $APP_PATH"

log_info "Verifying Universal binary architectures (lipo)..."
BINARY_ARCHS=$(lipo -archs "$APP_PATH/Contents/MacOS/Ambrosia")
log_ok "Architectures: $BINARY_ARCHS"

# ------------------------------------------------------------------------------
# 5. Ad-Hoc Code Signing
# ------------------------------------------------------------------------------
log_info "Applying ad-hoc code signature..."
codesign --force --deep --sign - "$APP_PATH"
codesign --verify --verbose "$APP_PATH"
log_ok "Ad-hoc signing verified."

# ------------------------------------------------------------------------------
# 6. Package DMG & Checksum
# ------------------------------------------------------------------------------
STAGING_DIR="${TMPDIR:-/tmp}/ambrosia-dmg-staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

DIST_DIR="$REPO_ROOT/dist"
mkdir -p "$DIST_DIR"

DMG_PATH="$DIST_DIR/${APP_NAME}.dmg"
SHA_PATH="$DIST_DIR/${APP_NAME}.dmg.sha256"
rm -f "$DMG_PATH" "$SHA_PATH"

log_info "Creating compressed DMG at $DMG_PATH..."
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null
log_ok "DMG created: $(du -sh "$DMG_PATH" | cut -f1)"

log_info "Computing SHA-256 checksum..."
cd "$DIST_DIR"
shasum -a 256 "${APP_NAME}.dmg" > "${APP_NAME}.dmg.sha256"
SHA_VAL=$(awk '{print $1}' "${APP_NAME}.dmg.sha256")
log_ok "SHA-256: $SHA_VAL"
cd "$REPO_ROOT"

# Cleanup temporary build dirs
rm -rf "$BUILD_DIR" "$STAGING_DIR"

# ------------------------------------------------------------------------------
# 7. GitHub Release Publishing & Homebrew Cask Dispatch
# ------------------------------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
  log_ok "Dry run complete! Release assets available at:"
  echo "    DMG:    $DMG_PATH"
  echo "    SHA256: $SHA_PATH"
  exit 0
fi

log_info "Publishing GitHub Release ${TAG}..."
if gh release view "$TAG" >/dev/null 2>&1; then
  log_info "Release $TAG exists. Uploading assets with --clobber..."
  gh release upload "$TAG" "$DMG_PATH" "$SHA_PATH" --clobber
  log_ok "Assets uploaded to existing release $TAG."
else
  log_info "Creating new release $TAG..."
  gh release create "$TAG" "$DMG_PATH" "$SHA_PATH" \
    --title "$TAG" \
    --generate-notes
  log_ok "Created GitHub Release $TAG."
fi

log_info "Dispatching cask update event to ${TAP_REPO}..."
if gh api "repos/${TAP_REPO}/dispatches" \
  --field event_type="app-release" \
  --field client_payload[app]="ambrosia" \
  --field client_payload[version]="${VERSION}" \
  --field client_payload[asset_name]="${APP_NAME}.dmg" \
  --field client_payload[asset_url]="https://github.com/kyrielie/ambrosia/releases/download/${TAG}/${APP_NAME}.dmg" >/dev/null 2>&1; then
  log_ok "Successfully dispatched app-release to ${TAP_REPO}."
else
  log_warn "Failed to dispatch repository event to ${TAP_REPO}. You can trigger it manually if needed."
fi

echo "======================================================================"
echo -e "${GREEN} Release ${TAG} published successfully!${NC}"
echo " Release URL: https://github.com/kyrielie/ambrosia/releases/tag/${TAG}"
echo " Asset:       $DMG_PATH"
echo " SHA-256:     $SHA_VAL"
echo "======================================================================"
