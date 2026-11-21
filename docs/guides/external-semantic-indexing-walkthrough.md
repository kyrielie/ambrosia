# External Semantic Passage Indexing & Ingestion Guide

This guide explains how to export, package, and offload full-text semantic passage indexing from your macOS machine to an external GPU-accelerated server (such as a Linux or Windows desktop with an NVIDIA GeForce GTX 1060 or RTX card), run the embedding model, and import the resulting database back into Ambrosia.

---

## 1. Architecture & Design

Full-text semantic search lets you search for tropes, descriptions, and scene semantics (e.g. *"confrontation in the rain swords"*, *"reluctant tea ceremony confession"*) across your entire Calibre library, jumping directly to the exact paragraph in Ambrosia's built-in reader.

```
┌─────────────────────────────────┐               ┌────────────────────────────────────┐
│   macOS Machine (Ambrosia)      │               │   External GPU Machine (NVIDIA)    │
│                                 │               │                                    │
│ 1. Package task via             │ (USB / rsync) │ 2. Run `./run_embed.sh`            │
│    `pack_embed_task.sh`         ├──────────────►│    - Qwen/Qwen3-Embedding-0.6B     │
│    (Zero-SSD direct streaming)  │               │    - PyTorch CUDA 12.1             │
│                                 │               │    - 400-word paragraph chunks     │
│                                 │               │    - UTF-16 WebKit DOM offsets     │
│                                 │               │    - Checkpointed SQLite save      │
│                                 │               │                                    │
│ 4. Import & Instant Search      │ (USB / rsync) │ 3. Output:                         │
│    - Settings ▸ Data ▸ Import   │◄──────────────┤    `ambrosia_semantic_passages.db` │
│    - CoreML Query Embedder      │               │                                    │
│    - Instant Reader jump (⇧⌘F)  │               │                                    │
└─────────────────────────────────┘               └────────────────────────────────────┘
```

### Models & Invariant Requirements
* **Ingestion Model**: `Qwen/Qwen3-Embedding-0.6B` producing **1024-dimensional** FP16 vectors.
* **macOS Query Model**: Compiled CoreML model `Qwen3-Embedding-0.6B.mlmodelc` (installed in `~/Library/Application Support/Ambrosia/Models/`).
* **Hardware Profile**: Optimized for desktop GPUs such as NVIDIA GTX 1060 6GB (Pascal `sm_61`), RTX series, or Apple Silicon MPS. Uses FP32 compute with packed FP16 vector serialization to maximize Pascal throughput while maintaining a lean SQLite database footprint (~2.2 GB for 4.25M chunks).

---

## 2. Step 1: Exporting Code and Library Files from macOS

Ambrosia includes a zero-duplication packaging tool (`scripts/pack_embed_task.sh`) that bundles the CLI, runner scripts, and library files.

### Method A: Stream Code + Calibre EPUBs to External Drive (Recommended)
Streams EPUB files and `metadata.db` directly from your Calibre library into an archive on an external USB SSD or destination folder **without creating intermediate files in `/tmp` or consuming space on your Mac internal SSD**:

```bash
# Direct stream to external drive as .tar.gz:
./scripts/pack_embed_task.sh -o /Volumes/ExternalSSD/ ~/Calibre\ Library/

# Or stream directly as a .zip file for Windows:
./scripts/pack_embed_task.sh --format zip -o /Volumes/ExternalSSD/embed_task.zip ~/Calibre\ Library/
```

What gets packaged:
- `ambrosia_embed_cli.py` (CLI ingestion engine)
- `requirements.txt` (Pinned dependencies)
- `run_embed.sh` (Linux auto-virtualenv runner with CUDA 12.1 detection)
- `run_embed.bat` (Windows auto-virtualenv runner with CUDA 12.1 detection)
- `README.md` (Quick-start runner guide)
- `library/metadata.db` (Calibre metadata catalog)
- `library/**/*.epub` (Only EPUB files; covers, cache, and search DBs are excluded)

---

### Method B: Code-Only Package (If Library is Already on External Server)
If your Calibre library already resides on your external machine or network share (e.g. via Syncthing or SMB):

```bash
./scripts/pack_embed_task.sh --code-only -o ~/Desktop/
```
This produces a lightweight `ambrosia_embed_task.tar.gz` (~12 KB).

---

### Method C: One-Click CLI Command Copy from Ambrosia UI
In Ambrosia:
1. Open **Preferences** (`⌘,`) and navigate to the **Data** tab.
2. Under **Full-Text Semantic Search (Passages)**, click **Copy CLI Command**.
3. Ambrosia copies the ready-to-run command with your active library path:
   ```bash
   python3 scripts/ambrosia_embed_cli.py --library "/path/to/calibre/library" --model Qwen/Qwen3-Embedding-0.6B --batch-size 32
   ```

---

## 3. Step 2: Running the Embedding Model on External Hardware

### System Requirements
* **OS**: Linux (Ubuntu 20.04+, Debian, Fedora, Arch) or Windows 10/11 (native or WSL2).
* **GPU**: NVIDIA GPU with 6+ GB VRAM (GTX 1060 6GB, RTX 2060+, RTX 3060+, etc.).
* **NVIDIA Driver**: Modern GeForce / Data Center driver (run `nvidia-smi` to verify).
* **Python**: Python 3.10, 3.11, or 3.12.

---

### Option A: Running on Linux (Automated)

1. **Extract Archive**:
   ```bash
   tar -xzf ambrosia_embed_task.tar.gz
   cd ambrosia_embed_task
   ```

2. **Start a Persistent Terminal (`tmux`)**:
   Always run large indexing jobs in `tmux` or `screen` so the process continues uninterrupted if your SSH connection drops:
   ```bash
   tmux new -s ambrosia-embed
   ```

3. **Execute Runner**:
   If you bundled your library into the archive:
   ```bash
   ./run_embed.sh
   ```
   Or point to an external Calibre library path on the server:
   ```bash
   ./run_embed.sh --library /path/to/calibre/library
   ```

   **What `run_embed.sh` does automatically:**
   - Creates a dedicated virtual environment in `./venv`.
   - Checks `nvidia-smi` and installs PyTorch with CUDA 12.1 wheels (`https://download.pytorch.org/whl/cu121`).
   - Runs a pre-flight sanity check asserting `torch.cuda.is_available() == True`.
   - Launches `ambrosia_embed_cli.py` with `--model Qwen/Qwen3-Embedding-0.6B --batch-size 32`.

4. **Detach from Session**:
   Press `Ctrl+B`, then `D` to detach. To re-attach later: `tmux attach -t ambrosia-embed`.

---

### Option B: Running on Windows (Automated)

1. Extract `ambrosia_embed_task.zip`.
2. Open a Command Prompt or PowerShell in the extracted folder.
3. If library files are bundled, double-click `run_embed.bat`, or run:
   ```cmd
   run_embed.bat
   ```
   Or specify an external library folder:
   ```cmd
   run_embed.bat --library C:\Calibre\Library
   ```

---

### Option C: Manual CLI Execution & Advanced Flags

If you prefer to run the CLI directly inside your own Python environment:

```bash
# 1. Activate your virtualenv
source venv/bin/activate

# 2. Install PyTorch with CUDA 12.1
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu121
pip install transformers tqdm

# 3. Run the CLI
python3 ambrosia_embed_cli.py \
  --library /path/to/calibre/library \
  --model "Qwen/Qwen3-Embedding-0.6B" \
  --batch-size 32 \
  --output ambrosia_semantic_passages.db
```

#### CLI Command Reference

| Flag | Default | Description |
|:-----|:--------|:------------|
| `--library PATH` | *None* | Path to Calibre library folder (containing `metadata.db` and EPUBs) |
| `--epub-dir PATH` | *None* | Path to any directory of EPUBs (extracts book IDs from filenames) |
| `--epub PATH` | *None* | Path to a single EPUB file for testing |
| `--output PATH` | `ambrosia_semantic_passages.db` | Destination SQLite database file |
| `--model MODEL` | `Qwen/Qwen3-Embedding-0.6B` | Embedding model ID (1024-dim required by Ambrosia) |
| `--batch-size N` | `32` | Number of chunks per GPU forward pass (~2.2 GB VRAM on GTX 1060) |
| `--chunk-words N` | `400` | Target word count per paragraph-bounded chunk |
| `--chunk-overlap N`| `50` | Overlap word count between adjacent chunks |
| `--max-books N` | *None* | Limit processing to first N books (useful for dry runs) |
| `--overwrite` | *False* | Overwrites existing output database instead of resuming |
| `--allow-cpu` | *False* | Permits CPU fallback if CUDA is missing (not recommended for large libraries) |

---

## 4. Checkpoint Resumption & Interruption Safety

* The CLI automatically records completed books in the SQLite table `indexed_books`.
* If indexing is stopped (Ctrl+C, power outage, reboot), simply **re-run the exact same command**:
  ```text
  Resuming: found 12,450 previously indexed books. Skipping them...
  ```
* It will safely resume from the next unindexed book without duplicating work or corrupting database records.
* Use `--overwrite` only if you explicitly want to discard existing progress and rebuild from scratch.

---

## 5. Step 3: Transferring & Importing into Ambrosia on macOS

When indexing completes, the CLI outputs a single file:
```text
ambrosia_semantic_passages.db
```

### Option 1: Drop Directly into Calibre Library Folder (Automatic)
Copy `ambrosia_semantic_passages.db` directly into your active Calibre Library folder on macOS (alongside `metadata.db`).
Ambrosia will automatically discover and link it the next time you open the library or click **Refresh** in Preferences.

### Option 2: Import via Settings UI
1. Launch Ambrosia on macOS.
2. Open **Preferences** (`⌘,`) ▸ **Data** tab.
3. Under **Full-Text Semantic Search (Passages)**:
   - Click **Import Database…**
   - Select your transferred `ambrosia_semantic_passages.db`.
4. Ambrosia validates the database header (`model_id == Qwen/Qwen3-Embedding-0.6B`, `dimension == 1024`).
5. Status changes to **Active (Ready)**, displaying total indexed scenes, books, and file size.

---

## 6. Verification & In-Reader Search

1. Press **`⇧⌘F`** in Ambrosia to open the Full-Text Search window.
2. Click the segmented switch to select **Semantic (Passages)**.
3. Enter a scene or trope query (e.g. *"starlit rooftop conversation"*).
4. Results appear as typographic scene cards with match confidence percentages (e.g. `95% Match`).
5. Click **Jump to Scene ↗**: Ambrosia opens the book in the reader, scrolls directly to the paragraph, and highlights it with a 3.5s decaying glow.

---

## 7. Troubleshooting & FAQs

### Q: Why did the script report running on CPU?
* **Cause**: `pip install torch` from default PyPI wheels installs CPU-only binaries on Windows or unconfigured Linux setups.
* **Fix**: In your virtual environment, install PyTorch with the CUDA wheel index:
  ```bash
  pip install --force-reinstall torch torchvision --index-url https://download.pytorch.org/whl/cu121
  ```
  Verify with: `python3 -c "import torch; print(torch.cuda.is_available())"`. It should print `True`.

### Q: Why did Ambrosia reject my imported database with `dimensionMismatch`?
* **Cause**: The database was built with a model other than `Qwen/Qwen3-Embedding-0.6B` (such as `bge-small`, which produces 384 dimensions).
* **Fix**: Ensure `--model Qwen/Qwen3-Embedding-0.6B` is used. Ambrosia's CoreML query engine expects 1024 dimensions.

### Q: I encountered CUDA Out of Memory (OOM). What should I do?
* **Fix**: Reduce `--batch-size` to `16` or `8`:
  ```bash
  ./run_embed.sh --batch-size 16
  ```
  `Qwen/Qwen3-Embedding-0.6B` with `--batch-size 32` typically consumes ~2.2 GB VRAM, which easily fits within 6 GB on a GTX 1060.
