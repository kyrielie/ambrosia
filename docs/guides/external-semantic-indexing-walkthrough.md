# External Semantic Indexing Guide & Walkthrough

This guide explains how to offload the compute-heavy full-text embedding generation for large libraries (e.g. 20+ GB) from your Mac to an external GPU-accelerated server (such as a Linux desktop with an NVIDIA GTX 1060), and import the resulting database into Ambrosia.

---

## Architecture Overview

```
┌─────────────────────────────────┐               ┌────────────────────────────────┐
│   macOS Machine (M1 Pro 16GB)   │               │   Linux Server (GTX 1060 6GB)  │
│                                 │               │                                │
│ 1. Export `full-text-search.db` ├──────────────►│ 2. Run `ambrosia_embed_cli.py` │
│    or Calibre Library folder    │ (rsync / USB) │    - 400-word paragraph chunks │
│                                 │               │    - Qwen3-0.6B FP16 on CUDA   │
│                                 │               │    - Checkpointed SQLite save  │
│                                 │               │                                │
│ 4. Import into Ambrosia         │◄──────────────┤ 3. Outputs:                    │
│    - One-click DB link          │ (rsync / USB) │    `ambrosia_semantic_         │
│    - Single-query search (~25ms)│               │     passages.db`               │
└─────────────────────────────────┘               └────────────────────────────────┘
```

---

## Step 1: Exporting Your Data from macOS

You have two options for what data to transfer from your Mac to the Linux machine:

### Option A: The Fast Route — Export `full-text-search.db` (Recommended)
If you already use Calibre's Full-Text Search (or have indexed it via Ambrosia):
1. In your Calibre Library folder on macOS, locate the file named:
   ```text
   full-text-search.db
   ```
2. This SQLite file already contains all extracted plain text across your entire library in the `books_text` table.
3. Because it strips out covers, CSS, and zip overhead, `full-text-search.db` is usually **only 500 MB to 1.5 GB** for a 20 GB library, making file transfer almost instantaneous.

### Option B: The Complete Route — Transfer the Calibre Library
If you have not built `full-text-search.db`:
* Copy your Calibre Library folder (containing `metadata.db` and the author/book `.epub` files) to your Linux box using `rsync` or an external USB SSD:
  ```bash
  rsync -avP --include="*/" --include="metadata.db" --include="*.epub" --exclude="*" \
    "/Users/yourname/Calibre Library/" user@linux-server:/home/user/calibre-library/
  ```

---

## Step 2: Preparing the External Linux Server

### 1. Requirements
* Linux (Ubuntu/Debian, Fedora, Arch) or Windows WSL2
* Python 3.10+
* NVIDIA GPU with CUDA drivers installed (`nvidia-smi` should report your GTX 1060)

### 2. Set Up Python Environment
On your Linux server, create a dedicated virtual environment:
```bash
# Create directory and virtual environment
mkdir -p ~/ambrosia-indexing
cd ~/ambrosia-indexing
python3 -m venv venv
source venv/bin/activate

# Install PyTorch with CUDA acceleration (CUDA 12.1 / 11.8)
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu121

# Install required dependencies
pip install transformers sentencepiece tqdm
```

### 3. Verify CUDA Availability
Verify that PyTorch can see your GTX 1060:
```bash
python3 -c "import torch; print('CUDA Available:', torch.cuda.is_available(), '| Device:', torch.cuda.get_device_name(0))"
```
*Expected output:* `CUDA Available: True | Device: NVIDIA GeForce GTX 1060 6GB`

---

## Step 3: Running the Ingestion Script

Copy [`scripts/ambrosia_embed_cli.py`](~/Documents/Applications/ambrosia/scripts/ambrosia_embed_cli.py) to your Linux machine in `~/ambrosia-indexing/`.

### 1. Start a Persistent Terminal Session (`tmux` or `screen`)
Because indexing a 20 GB library can take several days or weeks, always run inside `tmux` so it continues running when you disconnect:
```bash
# Start a new tmux session
tmux new -s ambrosia-embed
source ~/ambrosia-indexing/venv/bin/activate
```

### 2. Run the Indexing Command

#### If using `full-text-search.db` (Option A):
```bash
python3 ambrosia_embed_cli.py \
  --fts-db /path/to/full-text-search.db \
  --model "Qwen/Qwen3-Embedding-0.6B" \
  --mrl-dim 512 \
  --batch-size 64 \
  --output ambrosia_semantic_passages.db
```

#### If using the Calibre Library Directory (Option B):
```bash
python3 ambrosia_embed_cli.py \
  --library-path /path/to/calibre-library/ \
  --model "Qwen/Qwen3-Embedding-0.6B" \
  --mrl-dim 512 \
  --batch-size 64 \
  --output ambrosia_semantic_passages.db
```

### 3. Key Command Flags
* `--mrl-dim 512`: Uses Matryoshka Representation Learning to truncate the 1024-dim Qwen vector to 512 dimensions. This **halves the database size** with virtually identical retrieval accuracy.
* `--batch-size 64`: Optimized for 6 GB VRAM on a GTX 1060. If you encounter CUDA Out of Memory (OOM), reduce to `--batch-size 32`.
* `--target-words 400` & `--overlap-words 50`: The default paragraph-aligned windowing for narrative prose.

### 4. Checkpointing & Resumption
The script commits batches atomically to SQLite. If the process is stopped (or the server restarts), simply run the identical command again:
```text
Found 14,250 previously indexed books. Resuming from checkpoint...
```
It will automatically skip previously indexed books without duplicating work.

---

## Step 4: Transferring the Database Back to macOS

When indexing completes, the script outputs a single file:
```text
ambrosia_semantic_passages.db
```
Transfer this file to your Mac via `rsync`, `scp`, or an external drive:
```bash
scp user@linux-server:~/ambrosia-indexing/ambrosia_semantic_passages.db \
  ~/Downloads/
```

---

## Step 5: Importing into Ambrosia on macOS

1. Launch Ambrosia on your MacBook.
2. Open **Preferences** (`⌘,`) and navigate to the **Data** tab.
3. Under **Full-Text Semantic Search**:
   * Click **Import Generated Database…**
   * Select your transferred `ambrosia_semantic_passages.db`.
4. Ambrosia validates the database header:
   * It inspects `model_id` (`Qwen/Qwen3-Embedding-0.6B`) and `dimension` (`512`).
   * If you have not yet downloaded the lightweight query model, Ambrosia prompts:
     > *"This index was generated with Qwen3-Embedding-0.6B. Download the query model (620 MB) to enable searching?"*
   * Click **Download**. Ambrosia downloads the CoreML weights into `Application Support/Ambrosia/Models/`.
5. Once complete, full-text semantic search is active across your entire library with instant passage jumping (`⇧⌘F`).
