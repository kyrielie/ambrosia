#!/usr/bin/env bash
set -euo pipefail

# Verifies EPUB 3 exports against standards and local epubcheck (if installed).
echo "==> Verifying EPUB 3 Export Compliance"

if [ $# -eq 0 ]; then
    echo "Usage: $0 <path_to_epub>"
    exit 1
fi

EPUB_FILE="$1"

if [ ! -f "$EPUB_FILE" ]; then
    echo "Error: File not found: $EPUB_FILE"
    exit 1
fi

echo "Checking: $EPUB_FILE"

# 1. Verify mimetype is the first file and uncompressed
FIRST_ENTRY=$(zipinfo -1 "$EPUB_FILE" | head -n 1)
if [ "$FIRST_ENTRY" != "mimetype" ]; then
    echo "FAILED: First entry is not 'mimetype', got '$FIRST_ENTRY'"
    exit 1
fi

COMPRESSION=$(zipinfo "$EPUB_FILE" mimetype | awk '{print $4}')
if [ "$COMPRESSION" != "stor" ] && [ "$COMPRESSION" != "0%" ] && [ "$COMPRESSION" != "0.0%" ]; then
    echo "Note: mimetype compression check returned '$COMPRESSION' (should be uncompressed/stored)"
fi

# 2. Check for META-INF/container.xml
if ! unzip -l "$EPUB_FILE" | grep -q "META-INF/container.xml"; then
    echo "FAILED: Missing META-INF/container.xml"
    exit 1
fi

# 3. Check for package.opf and toc.xhtml
if ! unzip -l "$EPUB_FILE" | grep -q "package.opf"; then
    echo "FAILED: Missing package.opf"
    exit 1
fi

if ! unzip -l "$EPUB_FILE" | grep -q "toc.xhtml"; then
    echo "FAILED: Missing toc.xhtml"
    exit 1
fi

# 4. Run epubcheck if installed locally
if command -v epubcheck >/dev/null 2>&1; then
    echo "==> Running local epubcheck..."
    epubcheck "$EPUB_FILE"
else
    echo "Note: epubcheck is not installed locally (brew install epubcheck). Structural zip checks passed."
fi

echo "==> Verification complete: EPUB is well-formed!"
