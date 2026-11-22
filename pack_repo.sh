#!/usr/bin/env bash
# Pack a trimmed copy of the Ambrosia repo for upload to Claude.
# Run from the repo root.
set -euo pipefail

OUT="${1:-repo.zip}"

# Always start from a clean archive. `zip -r` on an existing file only adds
# or updates entries -- it never removes ones whose source file is gone, so
# without this rm, anything deleted from the tree since the last pack run
# lingers in $OUT forever. See make-claude-zip.sh's `rm -f "$OUT"` (Nectar)
# for the same fix.
rm -f "$OUT" "${OUT}.zip"

# Exclude images, binary archives/documents/databases/executables,
# build artifacts, and IDE/OS caches. Ambrosia's pack script is strictly
# for text/source context (Swift, docs, SQL fixtures, templates, configs).
# Note: docs/ao3_epub_html_reference.md is deliberately preserved per CLAUDE.md.
zip -r "$OUT" . \
  -x '*.png' -x '*.jpg' -x '*.jpeg' -x '*.gif' -x '*.webp' -x '*.ico' -x '*.icns' -x '*.tiff' -x '*.tif' -x '*.bmp' -x '*.heic' -x '*.avif' \
  -x 'screenshots/*' -x '*/screenshots/*' \
  -x '*.zip' -x '*.tar' -x '*.tar.gz' -x '*.tgz' -x '*.gz' -x '*.bz2' -x '*.xz' -x '*.7z' -x '*.rar' -x '*.dmg' -x '*.pkg' -x '*.ipa' \
  -x '*.xlsx' -x '*.xls' -x '*.pdf' -x '*.docx' -x '*.doc' -x '*.pptx' -x '*.ppt' -x '*.pages' -x '*.numbers' -x '*.key' \
  -x '*.db' -x '*.db-shm' -x '*.db-wal' -x '*.sqlite' -x '*.sqlite3' -x '*.sqlite-shm' -x '*.sqlite-wal' \
  -x '*.pyc' -x '*.pyo' -x '*.pyd' -x '*__pycache__/*' \
  -x '*.o' -x '*.a' -x '*.dylib' -x '*.so' -x '*.dylib.*' -x '*.class' -x '*.jar' -x '*.car' \
  -x '*.ttf' -x '*.otf' -x '*.woff' -x '*.woff2' -x '*.eot' \
  -x '*.mp3' -x '*.m4a' -x '*.wav' -x '*.flac' -x '*.aac' -x '*.ogg' -x '*.mp4' -x '*.mov' -x '*.avi' -x '*.mkv' -x '*.webm' \
  -x '_site/*' -x '*/_site/*' \
  -x '.build/*' -x '*/.build/*' \
  -x 'build/*' -x '*/build/*' \
  -x 'DerivedData/*' -x '*/DerivedData/*' \
  -x '.swiftpm/*' -x '*/.swiftpm/*' \
  -x 'node_modules/*' -x '*/node_modules/*' \
  -x '.pytest_cache/*' -x '*/.pytest_cache/*' \
  -x '.serena/*' -x '*/.serena/*' \
  -x 'finished/*' \
  -x '.git/*' -x '*/.git/*' -x '.git' \
  -x '*.DS_Store' -x '*/.DS_Store' \
  -x '*.xcuserstate' \
  -x '*.xcuserdatad/*' -x '*/xcuserdata/*' -x '*.xcodeproj/xcuserdata/*' -x '*.xcodeproj/project.xcworkspace/xcuserdata/*' \
  -x '*.xcresult/*' -x '*/.xcresult/*' -x '*.xcresult' \
  -x '*repomix*.xml' -x '*dump*.xml' -x '*dump*.txt' \
  -x 'testresults.txt' -x '*.log' -x 'crash.txt'

# Optional additional exclusions -- uncomment the block below and re-run if
# you don't want AGENTS.md / the scratch architecture docs included:
#
# zip -d "$OUT" 'AGENTS.md' 'ambrosia_architecture.md' 'docs/plans/finished/ambrosia_formatting_prompt_future.md'

echo "Wrote $OUT"
du -sh "$OUT"
echo

echo "Contents check (verifying no binary/image/leaked files):"
LEAKS=$(unzip -Z1 "$OUT" | grep -iE '\.(png|jpe?g|gif|webp|ico|icns|tiff?|bmp|heic|avif|xlsx?|xls|pdf|docx?|pptx?|zip|tar|gz|tgz|bz2|xz|7z|rar|dmg|pkg|ipa|db|db-shm|db-wal|sqlite|sqlite3|sqlite-shm|sqlite-wal|pyc|pyo|pyd|class|jar|car|o|a|dylib|so|ttf|otf|woff|woff2|eot|mp3|m4a|wav|flac|aac|ogg|mp4|mov|avi|mkv|webm|xcuserstate)$' || true)
DIR_LEAKS=$(unzip -Z1 "$OUT" | grep -E '(^|/)screenshots(/|$)|\.git(/|$)|\.git$|xcuserdata(/|$)|\.xcuserstate$|DerivedData(/|$)|_site(/|$)|\.DS_Store$|__pycache__(/|$)|\.pytest_cache(/|$)|\.serena(/|$)' || true)

if [ -n "$LEAKS" ] || [ -n "$DIR_LEAKS" ]; then
  echo "WARNING: Unwanted files detected in $OUT:"
  [ -n "$LEAKS" ] && echo "$LEAKS"
  [ -n "$DIR_LEAKS" ] && echo "$DIR_LEAKS"
  exit 1
else
  echo "  (clean - no images, binary files, or unwanted artifacts found)"
fi
