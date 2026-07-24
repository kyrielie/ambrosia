#!/usr/bin/env bash
# Pack a trimmed copy of the Ambrosia repo for upload to Claude.
# Run from the repo root.
set -euo pipefail

OUT="${1:-repo.zip}"

zip -r "$OUT" . \
  -x '*/node_modules/*' \
  -x '*.DS_Store' \
  -x '*/.DS_Store' \
  -x '*__pycache__/*' \
  -x '.serena/*' -x '*/.serena/*' \
  -x '.pytest_cache/*' -x '*/.pytest_cache/*' \
  -x 'finished/*' \
  -x '*repomix*.xml' \
  -x '*ao3_tag_seeds.db' \
  -x '*ao3_tag_seeds.db-shm' \
  -x '*ao3_tag_seeds.db-wal' \
  -x 'screenshots/*'

# Optional additional exclusions -- uncomment the block below and re-run if
# you don't want AGENTS.md / the scratch architecture docs included:
#
# zip -d "$OUT" 'AGENTS.md' 'ambrosia_architecture.md' 'ambrosia_formatting_prompt_future.md'

echo "Wrote $OUT"
du -sh "$OUT"
echo
echo "Contents check (should be empty except intended exclusions):"
unzip -l "$OUT" | grep -E 'finished/|\.serena/|\.pytest_cache/|__pycache__|\.DS_Store|repomix|ao3_tag_seeds\.db|screenshots/' || echo "  (clean)"
echo
echo ".git present:"
unzip -l "$OUT" | grep -c '\.git/' || true
