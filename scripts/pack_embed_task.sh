#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Pack the Ambrosia Full-Text Semantic Search ingestion task for transfer
# to an external machine (e.g. desktop with NVIDIA GTX 1060).
#
# Direct-Stream Archiving: Streams EPUB files directly into the destination
# archive without staging or duplicating files on the local Mac SSD.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

FORMAT="tar.gz"
OUTPUT=""
CODE_ONLY=0
LIBRARY_DIR=""

show_help() {
  cat << 'EOF'
Usage: ./scripts/pack_embed_task.sh [OPTIONS] [/path/to/calibre/library]

Packages the embedding CLI, runner scripts, and optional library files into a
portable archive ready for transfer to an external GPU machine.

Storage Protection:
  Streams EPUB files directly into the target archive without copying or
  duplicating files in /tmp or on your Mac internal drive. You can specify
  an external USB drive or secondary volume for --output.

Options:
  -o, --output PATH   Destination archive file or directory (e.g. /Volumes/ExternalDrive/)
  --code-only         Pack only scripts, runners, and requirements (~50 KB)
  --format FORMAT     Archive format: tar.gz (default) or zip
  -h, --help          Show this help message

Examples:
  # Pack code-only to Desktop:
  ./scripts/pack_embed_task.sh --code-only -o ~/Desktop/

  # Pack code + Calibre EPUBs directly onto an external USB drive (0 bytes Mac SSD used):
  ./scripts/pack_embed_task.sh -o /Volumes/USB/ ~/Calibre\ Library/

  # Pack as zip directly to a specific filename:
  ./scripts/pack_embed_task.sh --format zip -o /Volumes/USB/embed_task.zip ~/Calibre\ Library/
EOF
}

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --code-only)
      CODE_ONLY=1
      shift
      ;;
    --format)
      FORMAT="$2"
      shift 2
      ;;
    -o|--output)
      OUTPUT="$2"
      shift 2
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      show_help
      exit 1
      ;;
    *)
      LIBRARY_DIR="$1"
      shift
      ;;
  esac
done

# Resolve format extension
EXT="tar.gz"
if [ "$FORMAT" = "zip" ]; then
  EXT="zip"
fi

# Resolve output destination
if [ -z "$OUTPUT" ]; then
  OUTPUT="$REPO_ROOT/ambrosia_embed_task.$EXT"
elif [ -d "$OUTPUT" ]; then
  OUTPUT="${OUTPUT%/}/ambrosia_embed_task.$EXT"
fi

OUTPUT_DIR="$(dirname "$OUTPUT")"
if [ ! -d "$OUTPUT_DIR" ]; then
  echo "Error: Output directory does not exist: $OUTPUT_DIR" >&2
  exit 1
fi

echo "======================================================="
echo " Ambrosia Embedding Task Packager"
echo "======================================================="
echo "Destination: $OUTPUT"
echo "Free space on destination volume: $(df -h "$OUTPUT_DIR" | awk 'NR==2 {print $4}')"
echo

# Prepare a tiny staging directory for runner scripts (< 100 KB)
STAGE_DIR="$(mktemp -d /tmp/ambrosia_pack_meta_XXXXXX)"
cleanup() {
  rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

# 1. Generate run_embed.sh (Linux / macOS auto-venv runner)
cat << 'RUNNER_EOF' > "$STAGE_DIR/run_embed.sh"
#!/usr/bin/env bash
# Auto-virtualenv runner for Ambrosia Embedding Ingestion with NVIDIA CUDA support
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Ambrosia Full-Text Semantic Search Runner ==="

if [ ! -d "venv" ]; then
  echo "Creating virtual environment in ./venv ..."
  python3 -m venv venv
fi

# Activate virtualenv
source venv/bin/activate

echo "Ensuring required packages are installed with CUDA support..."
pip install --upgrade pip >/dev/null 2>&1 || true

# If nvidia-smi exists or CUDA requested, install PyTorch with CUDA 12.1 index
if command -v nvidia-smi >/dev/null 2>&1; then
  echo "[CUDA Detection] NVIDIA GPU detected via nvidia-smi:"
  nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader || true
  echo "Installing/verifying PyTorch with CUDA 12.1..."
  pip install torch torchvision --index-url https://download.pytorch.org/whl/cu121
else
  echo "[Warning] nvidia-smi not found. Attempting CUDA PyTorch installation..."
  pip install torch torchvision --extra-index-url https://download.pytorch.org/whl/cu121 || pip install torch
fi

pip install -r requirements.txt

# Pre-flight sanity check
echo "Checking CUDA availability in PyTorch..."
python3 -c "import torch; print(f'PyTorch: {torch.__version__} | CUDA Available: {torch.cuda.is_available()}'); exit(0 if torch.cuda.is_available() else 1)" || {
  echo ""
  echo "========================================================================="
  echo " [ERROR] PyTorch reports CUDA is NOT available on this machine!"
  echo " Running on CPU would take days/weeks and is blocked by default."
  echo " To fix:"
  echo "   1. Ensure NVIDIA display drivers are installed (run: nvidia-smi)"
  echo "   2. In your venv, run:"
  echo "      pip install --force-reinstall torch torchvision --index-url https://download.pytorch.org/whl/cu121"
  echo " (Or pass --allow-cpu if you intentionally wish to run on CPU)"
  echo "========================================================================="
  echo ""
  if [[ ! " $* " =~ " --allow-cpu " ]]; then
    exit 1
  fi
}

# If a local library/ folder exists, default to it
LIB_ARG=()
if [ $# -eq 0 ]; then
  if [ -d "library" ] && [ -f "library/metadata.db" ]; then
    LIB_ARG=("--library" "library")
  else
    echo "Usage: ./run_embed.sh --library /path/to/calibre/library"
    echo "Or run: python3 ambrosia_embed_cli.py --help"
    exit 1
  fi
fi

echo "Starting embedding process with Qwen3-Embedding-0.6B..."
python3 ambrosia_embed_cli.py "${LIB_ARG[@]}" --model "Qwen/Qwen3-Embedding-0.6B" --batch-size 32 "$@"

echo "=== Embedding Complete! ==="
echo "Copy ambrosia_semantic_passages.db back to your Mac and link in Ambrosia Preferences."
RUNNER_EOF
chmod +x "$STAGE_DIR/run_embed.sh"

# 2. Generate run_embed.bat (Windows auto-venv runner)
cat << 'BAT_EOF' > "$STAGE_DIR/run_embed.bat"
@echo off
rem Auto-virtualenv runner for Ambrosia Embedding Ingestion on Windows / NVIDIA CUDA
cd /d "%~dp0"

echo === Ambrosia Full-Text Semantic Search Runner (Windows) ===

if not exist venv (
  echo Creating virtual environment in .\venv ...
  python -m venv venv
)

call venv\Scripts\activate.bat

echo Ensuring required packages are installed with CUDA support...
python -m pip install --upgrade pip
python -m pip install torch torchvision --index-url https://download.pytorch.org/whl/cu121
python -m pip install -r requirements.txt

python -c "import torch; print('PyTorch: ' + torch.__version__ + ' | CUDA Available: ' + str(torch.cuda.is_available())); exit(0 if torch.cuda.is_available() else 1)"
if errorlevel 1 (
  echo.
  echo =========================================================================
  echo  [ERROR] PyTorch reports CUDA is NOT available on this machine!
  echo  Running on CPU would take days/weeks and is blocked by default.
  echo  To fix:
  echo    1. Ensure latest NVIDIA GeForce drivers are installed.
  echo    2. In your venv, run:
  echo       pip install --force-reinstall torch torchvision --index-url https://download.pytorch.org/whl/cu121
  echo  (Or pass --allow-cpu to proceed on CPU)
  echo =========================================================================
  echo.
)

if "%~1"=="" (
  if exist "library\metadata.db" (
    echo Using packaged library folder...
    python ambrosia_embed_cli.py --library library --model Qwen/Qwen3-Embedding-0.6B --batch-size 32
    goto :done
  ) else (
    echo Usage: run_embed.bat --library C:\path\to\calibre\library
    echo Or run: python ambrosia_embed_cli.py --help
    pause
    exit /b 1
  )
)

python ambrosia_embed_cli.py --model Qwen/Qwen3-Embedding-0.6B --batch-size 32 %*

:done
echo === Embedding Complete! ===
echo Copy ambrosia_semantic_passages.db back to your Mac.
pause
BAT_EOF

# 3. Generate README.md
cat << 'README_EOF' > "$STAGE_DIR/README.md"
# Ambrosia Full-Text Semantic Search — Headless Ingestion Task

This package generates `ambrosia_semantic_passages.db` on your external GPU machine
(NVIDIA GTX 1060 / CUDA / Linux / Windows) using `Qwen/Qwen3-Embedding-0.6B`.

## Quick Start

### On Linux:
```bash
# 1. Run with packaged library (if bundled)
./run_embed.sh

# Or point to an external Calibre library path:
./run_embed.sh --library /path/to/calibre/library
```

### On Windows (NVIDIA CUDA):
Double-click `run_embed.bat`, or in Command Prompt:
```cmd
run_embed.bat --library C:\path\to\calibre\library
```

### Resumption:
If interrupted, rerun the exact same command! The script records processed books in `indexed_books`
and will skip already-indexed books without duplicating work.

## After Ingestion Completes:
Copy the generated `ambrosia_semantic_passages.db` back to your Mac Calibre Library folder, or in Ambrosia:
**Preferences ▸ Data ▸ Full-Text Semantic Search ▸ Import Database…**
README_EOF

# 4. Stream directly into archive using Python
# (Reads EPUBs directly from source and writes straight to target archive without staging on Mac SSD)
python3 - << ARCHIVE_PY
import os
import sys
import tarfile
import zipfile
from pathlib import Path

repo_root = Path("$REPO_ROOT")
stage_dir = Path("$STAGE_DIR")
output_path = Path("$OUTPUT")
format_type = "$FORMAT"
code_only = bool(int("$CODE_ONLY"))
library_dir_str = "$LIBRARY_DIR"

if output_path.exists():
    output_path.unlink()

print(f"Creating {format_type.upper()} archive...")

# Collect code items
code_files = [
    (repo_root / "scripts/ambrosia_embed_cli.py", "ambrosia_embed_task/ambrosia_embed_cli.py"),
    (repo_root / "scripts/requirements-embed.txt", "ambrosia_embed_task/requirements.txt"),
    (stage_dir / "run_embed.sh", "ambrosia_embed_task/run_embed.sh"),
    (stage_dir / "run_embed.bat", "ambrosia_embed_task/run_embed.bat"),
    (stage_dir / "README.md", "ambrosia_embed_task/README.md"),
]

# Collect library items if requested
library_files = []
if not code_only and library_dir_str:
    lib_path = Path(library_dir_str).resolve()
    if not lib_path.exists() or not lib_path.is_dir():
        print(f"Error: Library directory not found: {lib_path}", file=sys.stderr)
        sys.exit(1)
    meta_db = lib_path / "metadata.db"
    if not meta_db.exists():
        print(f"Error: metadata.db not found in {lib_path}", file=sys.stderr)
        sys.exit(1)
    
    library_files.append((meta_db, "ambrosia_embed_task/library/metadata.db"))
    print(f"Scanning library for EPUB files in {lib_path}...")
    for epub in lib_path.rglob("*.epub"):
        rel = epub.relative_to(lib_path)
        library_files.append((epub, f"ambrosia_embed_task/library/{rel}"))
    print(f"Found {len(library_files) - 1:,} EPUBs to stream directly into archive.")

total_files = len(code_files) + len(library_files)
all_items = code_files + library_files

if format_type == "zip":
    with zipfile.ZipFile(output_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for idx, (src_file, arc_name) in enumerate(all_items):
            if idx > 0 and idx % 500 == 0:
                print(f"  Streaming: {idx:,} / {total_files:,} files...")
            zf.write(src_file, arcname=arc_name)
else:
    # tar.gz stream directly
    with tarfile.open(output_path, "w:gz") as tar:
        for idx, (src_file, arc_name) in enumerate(all_items):
            if idx > 0 and idx % 500 == 0:
                print(f"  Streaming: {idx:,} / {total_files:,} files...")
            tar.add(src_file, arcname=arc_name)

print("✓ Direct streaming complete!")
ARCHIVE_PY

echo "======================================================="
echo "✓ Successfully created archive: $OUTPUT"
du -sh "$OUTPUT"
echo "======================================================="
