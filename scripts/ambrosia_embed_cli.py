#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""
Ambrosia External Semantic Embedding CLI (ambrosia_embed_cli.py)
----------------------------------------------------------------
Extracts, chunks, and generates vector embeddings for an entire Calibre/Ambrosia
library on an external GPU-accelerated server (CUDA/Linux/Windows).

Outputs a cross-platform SQLite database (ambrosia_semantic_passages.db) that
can be copied directly back to your macOS machine running Ambrosia.
"""

import argparse
import os
import re
import sys
import time
import sqlite3
import struct
from datetime import datetime
from typing import List, Tuple, Optional, Dict, Any

try:
    import torch
    from transformers import AutoTokenizer, AutoModel
    from tqdm import tqdm
except ImportError:
    print(
        "ERROR: Required Python packages missing.\n"
        "Please install them in your virtual environment:\n"
        "  pip install torch transformers sentencepiece tqdm",
        file=sys.stderr,
    )
    sys.exit(1)


# ---------------------------------------------------------------------------
# 1. Text Extraction & Paragraph Chunker
# ---------------------------------------------------------------------------

class NarrativeChunker:
    """
    Chunks long-form narrative prose into ~400-word blocks snapped to
    paragraph boundaries with 50-word overlaps.
    """
    def __init__(self, target_words: int = 400, overlap_words: int = 50):
        self.target_words = target_words
        self.overlap_words = overlap_words

    def chunk(self, text: str) -> List[Tuple[str, int, int]]:
        """
        Returns a list of tuples: (chunk_text, start_char_offset, end_char_offset)
        """
        if not text or not text.strip():
            return []

        # Find paragraphs and their character ranges
        para_matches = list(re.finditer(r"(?:[^\r\n]+(?:\r?\n(?!\r?\n))*)+", text))
        if not para_matches:
            return []

        chunks = []
        current_paras = []
        current_word_count = 0
        current_start_char = para_matches[0].start()

        for m in para_matches:
            p_text = m.group(0).strip()
            if not p_text:
                continue

            words = p_text.split()
            w_count = len(words)

            if current_word_count + w_count > self.target_words and current_paras:
                # Flush current chunk
                chunk_str = "\n\n".join(p[0] for p in current_paras)
                chunk_end_char = current_paras[-1][2]
                chunks.append((chunk_str, current_start_char, chunk_end_char))

                # Build trailing overlap
                overlap_paras = []
                overlap_count = 0
                for prev_text, p_start, p_end, p_w in reversed(current_paras):
                    overlap_paras.insert(0, (prev_text, p_start, p_end, p_w))
                    overlap_count += p_w
                    if overlap_count >= self.overlap_words:
                        break

                current_paras = overlap_paras
                current_word_count = overlap_count
                current_start_char = current_paras[0][1] if current_paras else m.start()

            current_paras.append((p_text, m.start(), m.end(), w_count))
            current_word_count += w_count

        if current_paras:
            chunk_str = "\n\n".join(p[0] for p in current_paras)
            chunk_end_char = current_paras[-1][2]
            chunks.append((chunk_str, current_start_char, chunk_end_char))

        return chunks


# ---------------------------------------------------------------------------
# 2. Database Manager (SQLite Schema & Checkpoint Resumption)
# ---------------------------------------------------------------------------

class SemanticDatabase:
    def __init__(self, db_path: str, model_id: str, dimension: int):
        self.db_path = db_path
        self.model_id = model_id
        self.dimension = dimension
        self.conn = sqlite3.connect(db_path)
        self.conn.execute("PRAGMA journal_mode = WAL;")
        self.conn.execute("PRAGMA synchronous = NORMAL;")
        self._init_schema()

    def _init_schema(self):
        with self.conn:
            self.conn.executescript("""
            CREATE TABLE IF NOT EXISTS index_metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS passage_chunks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                book_id INTEGER NOT NULL,
                spine_index INTEGER NOT NULL DEFAULT 0,
                chunk_index INTEGER NOT NULL,
                start_offset INTEGER NOT NULL,
                end_offset INTEGER NOT NULL,
                chunk_text TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_chunks_book ON passage_chunks(book_id);

            CREATE TABLE IF NOT EXISTS passage_vectors (
                chunk_id INTEGER PRIMARY KEY,
                vector BLOB NOT NULL,
                FOREIGN KEY(chunk_id) REFERENCES passage_chunks(id) ON DELETE CASCADE
            );
            """)

            # Store metadata
            metadata_entries = [
                ("schema_version", "1.0"),
                ("model_id", self.model_id),
                ("dimension", str(self.dimension)),
                ("quantization", "FP16"),
                ("created_at", datetime.utcnow().isoformat() + "Z"),
                ("generator", "ambrosia-embed-cli v1.0 (CUDA)")
            ]
            self.conn.executemany(
                "INSERT OR REPLACE INTO index_metadata (key, value) VALUES (?, ?);",
                metadata_entries
            )

    def get_already_indexed_book_ids(self) -> set:
        cursor = self.conn.cursor()
        cursor.execute("SELECT DISTINCT book_id FROM passage_chunks")
        return set(row[0] for row in cursor.fetchall())

    def insert_batch(self, chunk_records: List[Dict[str, Any]], embeddings: List[List[float]]):
        """
        Inserts chunks and their FP16-packed binary vectors atomically.
        """
        cursor = self.conn.cursor()
        with self.conn:
            for rec, vec in zip(chunk_records, embeddings):
                cursor.execute(
                    """
                    INSERT INTO passage_chunks
                    (book_id, spine_index, chunk_index, start_offset, end_offset, chunk_text)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    (rec["book_id"], rec["spine_index"], rec["chunk_index"],
                     rec["start_offset"], rec["end_offset"], rec["chunk_text"])
                )
                chunk_id = cursor.lastrowid

                # Pack float vector into binary FP16 format (2 bytes per float)
                # 'e' format is IEEE 754 half-precision float (FP16)
                fp16_bytes = struct.pack(f"{len(vec)}e", *vec)

                cursor.execute(
                    "INSERT INTO passage_vectors (chunk_id, vector) VALUES (?, ?)",
                    (chunk_id, fp16_bytes)
                )

    def close(self):
        self.conn.close()


# ---------------------------------------------------------------------------
# 3. Model Runner (PyTorch & CUDA Batch Inference)
# ---------------------------------------------------------------------------

class EmbeddingPipeline:
    def __init__(self, model_id: str, device: str = "cuda", mrl_dim: Optional[int] = None):
        self.model_id = model_id
        self.device = torch.device(device if torch.cuda.is_available() and device == "cuda" else "cpu")
        self.mrl_dim = mrl_dim

        print(f"Loading model '{model_id}' onto {self.device}...")
        self.tokenizer = AutoTokenizer.from_pretrained(model_id, trust_remote_code=True)
        self.model = AutoModel.from_pretrained(
            model_id,
            torch_dtype=torch.float16 if self.device.type == "cuda" else torch.float32,
            trust_remote_code=True
        ).to(self.device)
        self.model.eval()

    @torch.no_grad()
    def embed_texts(self, texts: List[str]) -> List[List[float]]:
        inputs = self.tokenizer(
            texts,
            padding=True,
            truncation=True,
            max_length=2048,
            return_tensors="pt"
        ).to(self.device)

        outputs = self.model(**inputs)

        # Handle different pooling strategies (default: mean pooling or last token)
        if hasattr(outputs, "last_hidden_state"):
            embeddings = outputs.last_hidden_state[:, 0]  # CLS / first token
        else:
            embeddings = outputs[0][:, 0]

        # Truncate dimensions if Matryoshka Representation Learning (MRL) is requested
        if self.mrl_dim and self.mrl_dim < embeddings.shape[-1]:
            embeddings = embeddings[:, :self.mrl_dim]

        # L2 Unit normalize
        norm = torch.norm(embeddings, p=2, dim=-1, keepdim=True).clamp(min=1e-9)
        normalized = (embeddings / norm).cpu().float().numpy()

        return normalized.tolist()


# ---------------------------------------------------------------------------
# 4. Library Extractors
# ---------------------------------------------------------------------------

def iter_books_from_fts_db(fts_db_path: str):
    """
    Yields (book_id, searchable_text) directly from Calibre's full-text-search.db
    """
    conn = sqlite3.connect(fts_db_path)
    cursor = conn.cursor()
    cursor.execute("SELECT id, book, searchable_text FROM books_text WHERE searchable_text IS NOT NULL AND length(searchable_text) > 0")
    for row in cursor:
        yield row[1], row[2]
    conn.close()


def iter_books_from_calibre_dir(library_path: str):
    """
    Fallback: Reads Calibre's metadata.db, finds EPUB files, and extracts plain text.
    """
    meta_db = os.path.join(library_path, "metadata.db")
    if not os.path.exists(meta_db):
        raise FileNotFoundError(f"metadata.db not found in {library_path}")

    conn = sqlite3.connect(meta_db)
    cursor = conn.cursor()
    cursor.execute("SELECT b.id, b.path, d.name, d.format FROM books b JOIN data d ON d.book = b.id WHERE d.format = 'EPUB'")
    rows = cursor.fetchall()
    conn.close()

    for book_id, rel_path, file_name, fmt in rows:
        epub_path = os.path.join(library_path, rel_path, f"{file_name}.epub")
        if not os.path.exists(epub_path):
            continue
        try:
            import zipfile
            text_parts = []
            with zipfile.ZipFile(epub_path, "r") as zf:
                for name in zf.namelist():
                    if name.lower().endswith((".html", ".xhtml", ".htm")):
                        raw_html = zf.read(name).decode("utf-8", errors="ignore")
                        # Basic HTML tag stripping
                        plain = re.sub(r"<[^>]+>", " ", raw_html)
                        plain = re.sub(r"\s+", " ", plain).strip()
                        if plain:
                            text_parts.append(plain)
            if text_parts:
                yield book_id, "\n\n".join(text_parts)
        except Exception as e:
            print(f"Warning: Failed to extract book {book_id} ({epub_path}): {e}", file=sys.stderr)


# ---------------------------------------------------------------------------
# 5. Main CLI Driver
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Ambrosia External Semantic Embedding CLI (Headless Ingestion)"
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--fts-db", type=str, help="Path to Calibre full-text-search.db")
    group.add_argument("--library-path", type=str, help="Path to Calibre Library folder")

    parser.add_argument(
        "--output", "-o",
        type=str,
        default="ambrosia_semantic_passages.db",
        help="Output SQLite database path (default: ambrosia_semantic_passages.db)"
    )
    parser.add_argument(
        "--model", "-m",
        type=str,
        default="Qwen/Qwen3-Embedding-0.6B",
        help="Hugging Face embedding model (default: Qwen/Qwen3-Embedding-0.6B)"
    )
    parser.add_argument(
        "--mrl-dim",
        type=int,
        default=512,
        help="Truncated dimension for Matryoshka models (default: 512, set 0 for full 1024)"
    )
    parser.add_argument(
        "--batch-size", "-b",
        type=int,
        default=64,
        help="Batch size for GPU embedding inference (default: 64)"
    )
    parser.add_argument(
        "--target-words",
        type=int,
        default=400,
        help="Target word count per chunk (default: 400)"
    )
    parser.add_argument(
        "--overlap-words",
        type=int,
        default=50,
        help="Overlap word count between adjacent chunks (default: 50)"
    )
    parser.add_argument(
        "--device",
        type=str,
        default="cuda",
        help="Device to run on (cuda or cpu, default: cuda)"
    )

    args = parser.parse_args()
    mrl_dim = None if args.mrl_dim <= 0 else args.mrl_dim

    print("=" * 70)
    print(" Ambrosia External Semantic Embedding Engine ")
    print("=" * 70)
    print(f"Target Model      : {args.model}")
    print(f"Dimension         : {mrl_dim or 'Native'}")
    print(f"Device            : {args.device}")
    print(f"Batch Size        : {args.batch_size}")
    print(f"Chunk Target      : ~{args.target_words} words (overlap: {args.overlap_words} words)")
    print(f"Output Database   : {args.output}")
    print("-" * 70)

    # Initialize model
    pipeline = EmbeddingPipeline(model_id=args.model, device=args.device, mrl_dim=mrl_dim)
    actual_dim = mrl_dim or pipeline.model.config.hidden_size

    # Initialize database
    db = SemanticDatabase(args.output, model_id=args.model, dimension=actual_dim)
    indexed_books = db.get_already_indexed_book_ids()
    print(f"Found {len(indexed_books)} previously indexed books. Resuming from checkpoint...")

    # Initialize chunker
    chunker = NarrativeChunker(target_words=args.target_words, overlap_words=args.overlap_words)

    # Select book iterator
    if args.fts_db:
        book_iter = iter_books_from_fts_db(args.fts_db)
    else:
        book_iter = iter_books_from_calibre_dir(args.library_path)

    batch_chunks = []
    batch_records = []
    total_chunks_indexed = 0
    books_processed = 0

    start_time = time.time()

    for book_id, text in book_iter:
        if book_id in indexed_books:
            continue

        raw_chunks = chunker.chunk(text)
        if not raw_chunks:
            continue

        for idx, (chunk_str, start_off, end_off) in enumerate(raw_chunks):
            batch_chunks.append(chunk_str)
            batch_records.append({
                "book_id": book_id,
                "spine_index": 0,
                "chunk_index": idx,
                "start_offset": start_off,
                "end_offset": end_off,
                "chunk_text": chunk_str
            })

            if len(batch_chunks) >= args.batch_size:
                vectors = pipeline.embed_texts(batch_chunks)
                db.insert_batch(batch_records, vectors)
                total_chunks_indexed += len(batch_chunks)
                batch_chunks.clear()
                batch_records.clear()

        indexed_books.add(book_id)
        books_processed += 1

        if books_processed % 25 == 0:
            elapsed = time.time() - start_time
            rate = total_chunks_indexed / max(1.0, elapsed)
            print(f"Progress: {books_processed} books | {total_chunks_indexed} chunks indexed ({rate:.1f} chunks/sec)")

    # Flush remaining batch
    if batch_chunks:
        vectors = pipeline.embed_texts(batch_chunks)
        db.insert_batch(batch_records, vectors)
        total_chunks_indexed += len(batch_chunks)

    db.close()
    elapsed = time.time() - start_time
    print("=" * 70)
    print(f"Indexing Complete! Processed {books_processed} books into {total_chunks_indexed} chunks.")
    print(f"Total time: {elapsed/3600:.2f} hours. Output saved to: {args.output}")
    print("You can now copy this database to your macOS machine and import it into Ambrosia.")
    print("=" * 70)


if __name__ == "__main__":
    main()
