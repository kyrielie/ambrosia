#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""
Ambrosia Full-Text Semantic Search Ingestion CLI.

Extracts narrative paragraphs from Calibre EPUB files, computes UTF-16 code-unit
offsets for Apple WebKit DOM alignment, generates sentence embeddings via PyTorch/CUDA,
and serializes a lean, portable `ambrosia_semantic_passages.db` SQLite database.

Optimized for:
- Desktop GPUs (NVIDIA GTX 1060 / Pascal, RTX series, Apple Silicon MPS, or CPU)
- Memory-efficient batching (~150MB VRAM on BGE-small, ~1.4GB on Qwen3-0.6B)
- Lean database footprint: coordinates + 10-word anchor phrase + FP16 vector BLOBs
"""

from __future__ import annotations

import argparse
import html
import os
import re
import sqlite3
import struct
import sys
import time
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator, List, Optional, Tuple
import xml.etree.ElementTree as ET

# Optional imports for ML and UI progress
try:
    import torch
    import torch.nn.functional as F
    from transformers import AutoModel, AutoTokenizer
    HAS_TORCH = True
except ImportError:
    HAS_TORCH = False

try:
    from tqdm import tqdm
    HAS_TQDM = True
except ImportError:
    HAS_TQDM = False


def utf16_code_units(s: str) -> int:
    """Computes exact length of string in UTF-16 code units (for WebKit DOM alignment)."""
    return len(s.encode("utf-16-le")) // 2


@dataclass
class PassageChunk:
    book_id: int
    spine_index: int
    chunk_index: int
    start_offset: int  # UTF-16 code unit offset in chapter plain text
    end_offset: int    # UTF-16 code unit offset in chapter plain text
    text: str          # Extracted plain text (~400 words)
    anchor_phrase: str # First 8-12 words for snippet display & DOM range targeting


class HTMLTextExtractor:
    """Fast, dependency-free HTML-to-text converter preserving paragraph breaks."""

    _TAG_RE = re.compile(r"<[^>]+>")
    _BLOCK_BREAK_RE = re.compile(r"<\s*/?(?:p|div|h[1-6]|li|blockquote|section|article|br)[^>]*>", re.IGNORECASE)
    _SCRIPT_STYLE_RE = re.compile(r"<\s*(?:script|style|head)[^>]*>.*?<\s*/\s*(?:script|style|head)[^>]*>", re.DOTALL | re.IGNORECASE)
    _WHITESPACE_RE = re.compile(r"[ \t\r\f\v]+")
    _MULTI_NEWLINE_RE = re.compile(r"\n{3,}")

    @classmethod
    def extract_text(cls, raw_html: str) -> str:
        # 1. Strip script and style tags
        text = cls._SCRIPT_STYLE_RE.sub(" ", raw_html)
        # 2. Convert block boundaries and breaks into newlines
        text = cls._BLOCK_BREAK_RE.sub("\n\n", text)
        # 3. Strip remaining tags
        text = cls._TAG_RE.sub(" ", text)
        # 4. Decode HTML entities
        text = html.unescape(text)
        # 5. Clean horizontal whitespace
        lines = [cls._WHITESPACE_RE.sub(" ", line).strip() for line in text.split("\n")]
        cleaned = "\n".join(lines)
        # 6. Normalize paragraph breaks to \n\n
        cleaned = cls._MULTI_NEWLINE_RE.sub("\n\n", cleaned)
        return cleaned.strip()


class NarrativeChunker:
    """
    Paragraph-aware narrative chunker.
    Groups text into ~target_words bounded by paragraph breaks (\n\n) with overlap.
    Tracks character offsets strictly in UTF-16 code units.
    """

    def __init__(self, target_words: int = 400, overlap_words: int = 50):
        self.target_words = target_words
        self.overlap_words = overlap_words

    def chunk_chapter(self, chapter_text: str, book_id: int, spine_index: int) -> List[PassageChunk]:
        if not chapter_text.strip():
            return []

        # Split on paragraph boundaries
        paragraphs = [p for p in chapter_text.split("\n\n") if p.strip()]
        if not paragraphs:
            return []

        # Find starting character index of each paragraph in chapter_text
        para_positions: List[Tuple[int, int, str]] = []
        cursor = 0
        for p in paragraphs:
            start_pos = chapter_text.find(p, cursor)
            if start_pos == -1:
                start_pos = cursor
            end_pos = start_pos + len(p)
            para_positions.append((start_pos, end_pos, p))
            cursor = end_pos

        chunks: List[PassageChunk] = []
        p_idx = 0
        total_paras = len(para_positions)
        chunk_idx = 0

        while p_idx < total_paras:
            accum_paras: List[str] = []
            words_count = 0
            start_char_idx = para_positions[p_idx][0]
            end_char_idx = para_positions[p_idx][1]
            last_para_idx = p_idx

            while p_idx < total_paras:
                _, p_end, p_text = para_positions[p_idx]
                p_words = p_text.split()
                p_word_count = len(p_words)

                if words_count > 0 and (words_count + p_word_count) > (self.target_words + 50):
                    # Target reached
                    break

                accum_paras.append(p_text)
                words_count += p_word_count
                end_char_idx = p_end
                last_para_idx = p_idx
                p_idx += 1

                if words_count >= self.target_words:
                    break

            chunk_text = "\n\n".join(accum_paras)
            if not chunk_text.strip():
                p_idx += 1
                continue

            # Compute UTF-16 offsets
            prefix_text = chapter_text[:start_char_idx]
            body_text = chapter_text[:end_char_idx]
            u16_start = utf16_code_units(prefix_text)
            u16_end = utf16_code_units(body_text)

            # Generate anchor phrase: first 8-12 words
            words = chunk_text.split()
            anchor_words = words[:10]
            anchor_phrase = " ".join(anchor_words)

            chunks.append(PassageChunk(
                book_id=book_id,
                spine_index=spine_index,
                chunk_index=chunk_idx,
                start_offset=u16_start,
                end_offset=u16_end,
                text=chunk_text,
                anchor_phrase=anchor_phrase
            ))
            chunk_idx += 1

            # Determine next paragraph index based on overlap
            if p_idx < total_paras and self.overlap_words > 0:
                # Step back enough paragraphs to satisfy overlap_words
                overlap_accum = 0
                step_back = 0
                for back_i in range(last_para_idx, -1, -1):
                    _, _, back_text = para_positions[back_i]
                    overlap_accum += len(back_text.split())
                    step_back += 1
                    if overlap_accum >= self.overlap_words:
                        break
                p_idx = max(p_idx - step_back + 1, last_para_idx + 1)
            elif p_idx <= last_para_idx:
                p_idx = last_para_idx + 1

        return chunks


class EPUBReader:
    """Dependency-free EPUB reader extracting XHTML items in spine order."""

    NAMESPACES = {
        "n": "urn:oasis:names:tc:opendocument:xmlns:container",
        "opf": "http://www.idpf.org/2007/opf"
    }

    @classmethod
    def read_chapters(cls, epub_path: Path) -> List[Tuple[int, str]]:
        chapters: List[Tuple[int, str]] = []
        try:
            with zipfile.ZipFile(epub_path, "r") as zf:
                # 1. Parse META-INF/container.xml
                try:
                    container_xml = zf.read("META-INF/container.xml")
                except KeyError:
                    return []
                root = ET.fromstring(container_xml)
                rootfile = root.find(".//n:rootfile", cls.NAMESPACES)
                if rootfile is None or "full-path" not in rootfile.attrib:
                    return []
                opf_path = rootfile.attrib["full-path"]

                # 2. Parse OPF file
                try:
                    opf_xml = zf.read(opf_path)
                except KeyError:
                    return []
                opf_root = ET.fromstring(opf_xml)
                opf_dir = Path(opf_path).parent

                # 3. Read manifest items
                manifest_items: dict[str, str] = {}
                manifest = opf_root.find("opf:manifest", cls.NAMESPACES)
                if manifest is None:
                    manifest = opf_root.find("manifest")
                if manifest is not None:
                    for item in manifest:
                        item_id = item.attrib.get("id")
                        href = item.attrib.get("href")
                        if item_id and href:
                            manifest_items[item_id] = href

                # 4. Read spine order
                spine = opf_root.find("opf:spine", cls.NAMESPACES)
                if spine is None:
                    spine = opf_root.find("spine")
                if spine is None:
                    return []

                spine_index = 0
                for itemref in spine:
                    idref = itemref.attrib.get("idref")
                    if not idref or idref not in manifest_items:
                        continue
                    rel_href = manifest_items[idref]
                    # Normalize zip path
                    if str(opf_dir) == ".":
                        target_path = rel_href
                    else:
                        target_path = f"{opf_dir}/{rel_href}".replace("//", "/")
                    target_path = target_path.split("#")[0]  # strip fragment

                    try:
                        raw_bytes = zf.read(target_path)
                    except KeyError:
                        continue

                    raw_html = raw_bytes.decode("utf-8", errors="replace")
                    plain_text = HTMLTextExtractor.extract_text(raw_html)
                    if plain_text.strip():
                        chapters.append((spine_index, plain_text))
                    spine_index += 1

        except Exception as e:
            print(f"[Warning] Failed parsing EPUB {epub_path.name}: {e}", file=sys.stderr)
            return []

        return chapters


class PassageDatabaseWriter:
    """Manages creation and batched commits into ambrosia_semantic_passages.db."""

    def __init__(self, db_path: Path, model_id: str, dimension: int, overwrite: bool = False):
        self.db_path = db_path
        self.model_id = model_id
        self.dimension = dimension
        if overwrite and self.db_path.exists():
            print(f"[Database] Overwrite enabled: removing existing {self.db_path.name}")
            self.db_path.unlink()

        self.conn = sqlite3.connect(str(self.db_path))
        self.conn.execute("PRAGMA page_size = 16384;")
        self.conn.execute("PRAGMA journal_mode = WAL;")
        self.conn.execute("PRAGMA synchronous = NORMAL;")
        self.conn.execute("PRAGMA temp_store = MEMORY;")
        self._create_schema()

        cursor = self.conn.execute("SELECT COUNT(*) FROM passage_chunks;")
        row = cursor.fetchone()
        self.total_chunks = row[0] if row else 0

    def _create_schema(self):
        with self.conn:
            self.conn.executescript("""
            CREATE TABLE IF NOT EXISTS index_metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            ) WITHOUT ROWID;

            CREATE TABLE IF NOT EXISTS indexed_books (
                book_id INTEGER PRIMARY KEY,
                file_size INTEGER NOT NULL,
                mtime INTEGER NOT NULL,
                chunk_count INTEGER NOT NULL,
                indexed_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS passage_chunks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                book_id INTEGER NOT NULL,
                spine_index INTEGER NOT NULL,
                chunk_index INTEGER NOT NULL,
                start_offset INTEGER NOT NULL,
                end_offset INTEGER NOT NULL,
                anchor_phrase TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS passage_vectors (
                chunk_id INTEGER PRIMARY KEY,
                vector BLOB NOT NULL,
                FOREIGN KEY(chunk_id) REFERENCES passage_chunks(id) ON DELETE CASCADE
            );
            """)

            # Store metadata
            now_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            metadata = [
                ("schema_version", "1.0"),
                ("model_id", self.model_id),
                ("dimension", str(self.dimension)),
                ("precision", "FP16"),
                ("generated_at", now_iso),
                ("generator_tool", "ambrosia-embed-cli v1.1")
            ]
            self.conn.executemany("INSERT OR IGNORE INTO index_metadata (key, value) VALUES (?, ?);", metadata)

    def get_indexed_book_ids(self) -> set[int]:
        """Returns set of book_ids already fully indexed in this database."""
        cursor = self.conn.execute("SELECT book_id FROM indexed_books;")
        return {r[0] for r in cursor.fetchall()}

    def write_book_chunks_batch(self, batch_data: List[Tuple[int, int, int, List[PassageChunk], List[bytes]]]):
        """Writes multiple books and their vectors within a single atomic SQLite transaction."""
        if not batch_data:
            return

        now_ts = int(time.time())
        with self.conn:
            for book_id, file_size, mtime, chunks, vectors in batch_data:
                self.conn.execute(
                    "INSERT OR REPLACE INTO indexed_books VALUES (?, ?, ?, ?, ?);",
                    (book_id, file_size, mtime, len(chunks), now_ts)
                )

                for chunk, vec_blob in zip(chunks, vectors):
                    cursor = self.conn.execute(
                        """
                        INSERT INTO passage_chunks
                        (book_id, spine_index, chunk_index, start_offset, end_offset, anchor_phrase)
                        VALUES (?, ?, ?, ?, ?, ?);
                        """,
                        (chunk.book_id, chunk.spine_index, chunk.chunk_index,
                         chunk.start_offset, chunk.end_offset, chunk.anchor_phrase)
                    )
                    chunk_id = cursor.lastrowid
                    self.conn.execute(
                        "INSERT INTO passage_vectors (chunk_id, vector) VALUES (?, ?);",
                        (chunk_id, vec_blob)
                    )
                self.total_chunks += len(chunks)

    def write_book_chunks(self, book_id: int, file_size: int, mtime: int,
                          chunks: List[PassageChunk], vectors: List[bytes]):
        self.write_book_chunks_batch([(book_id, file_size, mtime, chunks, vectors)])

    def finalize(self):
        print("\nFinalizing database and building indexes...")
        with self.conn:
            self.conn.execute("CREATE INDEX IF NOT EXISTS idx_chunks_book_spine ON passage_chunks(book_id, spine_index);")
            self.conn.execute("UPDATE index_metadata SET value = ? WHERE key = 'chunk_count';", (str(self.total_chunks),))
            if not self.conn.execute("SELECT 1 FROM index_metadata WHERE key = 'chunk_count'").fetchone():
                self.conn.execute("INSERT INTO index_metadata VALUES ('chunk_count', ?);", (str(self.total_chunks),))

        self.conn.execute("PRAGMA wal_checkpoint(TRUNCATE);")
        self.conn.execute("PRAGMA optimize;")
        self.conn.close()
        db_size_mb = self.db_path.stat().st_size / (1024 * 1024)
        print(f"✓ Complete! Wrote {self.total_chunks:,} chunks to {self.db_path} ({db_size_mb:.2f} MB)")


class EmbeddingEngine:
    """Manages model acquisition and batched FP16 tensor encoding."""

    @staticmethod
    def last_token_pool(last_hidden_states: torch.Tensor, attention_mask: torch.Tensor) -> torch.Tensor:
        """Official pooling implementation for Qwen3 and decoder-based embedding models."""
        left_padding = (attention_mask[:, -1].sum() == attention_mask.shape[0])
        if left_padding:
            return last_hidden_states[:, -1]
        else:
            sequence_lengths = attention_mask.sum(dim=1) - 1
            batch_size = last_hidden_states.shape[0]
            return last_hidden_states[torch.arange(batch_size, device=last_hidden_states.device), sequence_lengths]

    def __init__(self, model_id: str, device: str = "auto", allow_cpu: bool = False, mock: bool = False):
        self.model_id = model_id
        self.mock = mock
        self.is_qwen = "qwen" in model_id.lower()

        if model_id != "Qwen/Qwen3-Embedding-0.6B":
            print(
                f"\n[WARNING] Model '{model_id}' specified. Ambrosia macOS client strictly expects\n"
                f"          'Qwen/Qwen3-Embedding-0.6B' (1024 dimensions). If dimensions do not match,\n"
                f"          Ambrosia will reject this database on import.\n",
                file=sys.stderr
            )

        if mock:
            self.dimension = 1024 if self.is_qwen else 384
            print(f"[Mode] Using mock embeddings (dimension: {self.dimension}, no GPU/model required for testing).")
            return

        if not HAS_TORCH:
            raise RuntimeError("PyTorch and transformers are required. Install with: pip install torch transformers")

        # Resolve device
        if device == "auto":
            if torch.cuda.is_available():
                self.device = torch.device("cuda")
            elif hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
                self.device = torch.device("mps")
            else:
                if not allow_cpu:
                    raise RuntimeError(
                        "\n=========================================================================\n"
                        "[CUDA NOT AVAILABLE ERROR]\n"
                        "PyTorch reports CUDA is NOT available on this machine.\n"
                        "Embedding narrative passages on CPU is 30x-50x slower and can take days or weeks.\n\n"
                        "To resolve on Linux/Windows with NVIDIA GPU:\n"
                        "  1. Verify NVIDIA drivers are active: run 'nvidia-smi'\n"
                        "  2. Reinstall PyTorch with explicit CUDA wheels in your environment:\n"
                        "     pip install --force-reinstall torch torchvision --index-url https://download.pytorch.org/whl/cu121\n"
                        "  3. If you intentionally want to test/run on CPU, pass '--allow-cpu'.\n"
                        "========================================================================="
                    )
                self.device = torch.device("cpu")
                print("[WARNING] Running on CPU (--allow-cpu enabled). Ingestion will be significantly slower.")
        elif device == "cuda":
            if not torch.cuda.is_available():
                raise RuntimeError(
                    "\n[CUDA NOT AVAILABLE ERROR] Explicit device 'cuda' requested, but torch.cuda.is_available() is False!\n"
                    "Please check your NVIDIA drivers or reinstall PyTorch with CUDA wheels:\n"
                    "  pip install --force-reinstall torch torchvision --index-url https://download.pytorch.org/whl/cu121"
                )
            self.device = torch.device("cuda")
        else:
            self.device = torch.device(device)

        if self.device.type == "cuda":
            gpu_name = torch.cuda.get_device_name(0)
            vram_gb = torch.cuda.get_device_properties(0).total_memory / (1024**3)
            print(f"[Device] CUDA Enabled: {gpu_name} ({vram_gb:.1f} GB VRAM)")
            torch.backends.cudnn.benchmark = True
            if "1060" in gpu_name or "Pascal" in gpu_name:
                print("[Optimization] NVIDIA Pascal (Compute Capability 6.1) detected: using FP32 math with FP16 output BLOBs.")
        elif self.device.type == "mps":
            print("[Device] Apple Silicon Metal (MPS) Enabled")
        elif self.device.type == "cpu":
            print("[Device] Running on CPU")

        print(f"[Model] Loading tokenizer and model: {model_id}...")
        padding_side = "left" if self.is_qwen else "right"
        self.tokenizer = AutoTokenizer.from_pretrained(model_id, padding_side=padding_side, trust_remote_code=True)
        self.model = AutoModel.from_pretrained(model_id, trust_remote_code=True).to(self.device)
        self.model.eval()

        # Determine embedding dimension
        dummy_inputs = self.tokenizer(["test"], return_tensors="pt", padding=True, truncation=True).to(self.device)
        with torch.inference_mode():
            dummy_out = self.model(**dummy_inputs)
            if self.is_qwen:
                emb = self.last_token_pool(dummy_out.last_hidden_state, dummy_inputs["attention_mask"])
            elif hasattr(dummy_out, "pooler_output") and dummy_out.pooler_output is not None:
                emb = dummy_out.pooler_output
            else:
                emb = dummy_out.last_hidden_state[:, 0]
            self.dimension = emb.shape[1]

        if self.dimension != 1024:
            print(
                f"[WARNING] Generated embedding dimension is {self.dimension}. Ambrosia client\n"
                f"          requires 1024 dimensions (Qwen3-Embedding-0.6B).",
                file=sys.stderr
            )

        print(f"[Model] Ready. Output dimension: {self.dimension} (FP16)")

    def encode_passages(self, texts: List[str], batch_size: int = 32) -> List[bytes]:
        if not texts:
            return []

        if self.mock:
            results = []
            for text in texts:
                val = float(hash(text) % 1000) / 1000.0
                floats = [val] * self.dimension
                results.append(struct.pack(f"<{self.dimension}e", *floats))
            return results

        results: List[bytes] = []
        max_tokens = 2048 if self.is_qwen else 512
        for i in range(0, len(texts), batch_size):
            batch_texts = texts[i:i + batch_size]
            encoded = self.tokenizer(
                batch_texts,
                padding=True,
                truncation=True,
                max_length=max_tokens,
                return_tensors="pt"
            ).to(self.device)

            with torch.inference_mode():
                outputs = self.model(**encoded)
                if self.is_qwen:
                    embeddings = self.last_token_pool(outputs.last_hidden_state, encoded["attention_mask"])
                elif hasattr(outputs, "pooler_output") and outputs.pooler_output is not None:
                    embeddings = outputs.pooler_output
                else:
                    embeddings = outputs.last_hidden_state[:, 0]

                embeddings = F.normalize(embeddings, p=2, dim=1)
                half_tensors = embeddings.to(torch.float16).cpu()
                for vec in half_tensors:
                    results.append(vec.numpy().tobytes())

        return results


def discover_calibre_books(library_path: Path) -> List[Tuple[int, Path]]:
    """Reads Calibre metadata.db and locates all EPUB file paths."""
    db_file = library_path / "metadata.db"
    if not db_file.exists():
        return []

    conn = sqlite3.connect(str(db_file))
    cursor = conn.cursor()
    query = """
    SELECT b.id, b.path, d.name
    FROM books b
    JOIN data d ON b.id = d.book
    WHERE d.format = 'EPUB'
    ORDER BY b.id;
    """
    books: List[Tuple[int, Path]] = []
    try:
        for book_id, rel_path, file_name in cursor.execute(query):
            epub_rel = Path(rel_path) / f"{file_name}.epub"
            full_path = library_path / epub_rel
            if full_path.exists():
                books.append((book_id, full_path))
    finally:
        conn.close()

    return books


def discover_direct_epubs(directory: Path) -> List[Tuple[int, Path]]:
    """Discovers EPUBs directly from a folder, extracting ID from (id) pattern or index."""
    books: List[Tuple[int, Path]] = []
    id_pattern = re.compile(r"\s*\((\d+)\)")

    seq_id = 1
    for p in sorted(directory.rglob("*.epub")):
        match = id_pattern.search(p.parent.name) or id_pattern.search(p.stem)
        if match:
            book_id = int(match.group(1))
        else:
            book_id = seq_id
            seq_id += 1
        books.append((book_id, p))
    return books


def main():
    parser = argparse.ArgumentParser(description="Ambrosia Full-Text Semantic Search Ingestion CLI")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--library", type=Path, help="Path to Calibre library directory (containing metadata.db)")
    group.add_argument("--epub-dir", type=Path, help="Path to directory containing EPUB files")
    group.add_argument("--epub", type=Path, help="Path to a single EPUB file")

    parser.add_argument("--output", type=Path, default=Path("ambrosia_semantic_passages.db"),
                        help="Output SQLite database path (default: ambrosia_semantic_passages.db)")
    parser.add_argument("--model", type=str, default="Qwen/Qwen3-Embedding-0.6B",
                        help="HuggingFace model ID (default: Qwen/Qwen3-Embedding-0.6B, 1024-dim required by Ambrosia)")
    parser.add_argument("--batch-size", type=int, default=32,
                        help="Batch size for embedding generation (default: 32)")
    parser.add_argument("--device", type=str, default="auto",
                        help="PyTorch device: auto, cuda, mps, cpu")
    parser.add_argument("--allow-cpu", action="store_true",
                        help="Permit fallback to CPU if CUDA is unavailable (significantly slower)")
    parser.add_argument("--overwrite", action="store_true",
                        help="Overwrite existing output database instead of resuming")
    parser.add_argument("--chunk-words", type=int, default=400,
                        help="Target chunk size in words (default: 400)")
    parser.add_argument("--chunk-overlap", type=int, default=50,
                        help="Overlap words between chunks (default: 50)")
    parser.add_argument("--max-books", type=int, default=None,
                        help="Limit processing to N books (for testing)")
    parser.add_argument("--mock-embeddings", action="store_true",
                        help="Generate mock deterministic embeddings without requiring PyTorch/CUDA")

    args = parser.parse_args()

    print("=======================================================")
    print(" Ambrosia Full-Text Semantic Search Ingestion CLI")
    print("=======================================================")

    # 1. Discover books
    if args.library:
        print(f"Scanning Calibre library: {args.library}")
        books = discover_calibre_books(args.library)
    elif args.epub_dir:
        print(f"Scanning EPUB directory: {args.epub_dir}")
        books = discover_direct_epubs(args.epub_dir)
    else:
        books = [(1, args.epub)]

    if not books:
        print("Error: No EPUB files found in the specified source.", file=sys.stderr)
        sys.exit(1)

    if args.max_books:
        books = books[:args.max_books]

    print(f"Found {len(books):,} books to index.")

    # 2. Initialize Embedder & Database
    embedder = EmbeddingEngine(
        model_id=args.model,
        device=args.device,
        allow_cpu=args.allow_cpu,
        mock=args.mock_embeddings
    )
    writer = PassageDatabaseWriter(
        db_path=args.output,
        model_id=args.model,
        dimension=embedder.dimension,
        overwrite=args.overwrite
    )
    chunker = NarrativeChunker(target_words=args.chunk_words, overlap_words=args.chunk_overlap)

    indexed_books = writer.get_indexed_book_ids()
    if indexed_books:
        print(f"Resuming: found {len(indexed_books):,} previously indexed books. Skipping them...")

    # 3. Continuous Pipelined Batch Ingestion Loop
    # Buffers chunks across books to keep GPU batches full (args.batch_size) and commits in atomic batches
    start_time = time.time()
    books_iter = tqdm(books, desc="Indexing Books", unit="book") if HAS_TQDM else books

    pending_book_data: List[Tuple[int, int, int, List[PassageChunk]]] = []
    pending_chunks: List[PassageChunk] = []
    processed_books_count = 0

    def flush_pending():
        nonlocal pending_book_data, pending_chunks
        if not pending_chunks:
            return

        all_texts = [c.text for c in pending_chunks]
        all_vectors = embedder.encode_passages(all_texts, batch_size=args.batch_size)

        vec_cursor = 0
        batch_to_write = []
        for b_id, f_sz, m_tm, b_chunks in pending_book_data:
            c_len = len(b_chunks)
            b_vecs = all_vectors[vec_cursor:vec_cursor + c_len]
            vec_cursor += c_len
            batch_to_write.append((b_id, f_sz, m_tm, b_chunks, b_vecs))

        writer.write_book_chunks_batch(batch_to_write)
        pending_book_data.clear()
        pending_chunks.clear()

    CHUNK_FLUSH_THRESHOLD = max(args.batch_size * 4, 128)

    for idx, (book_id, epub_path) in enumerate(books_iter):
        if book_id in indexed_books:
            continue

        if not HAS_TQDM and (processed_books_count % 25 == 0 or idx == len(books) - 1):
            print(f"Processing book {idx + 1}/{len(books)}: {epub_path.name}")

        chapters = EPUBReader.read_chapters(epub_path)
        if not chapters:
            continue

        book_chunks: List[PassageChunk] = []
        for spine_idx, chapter_text in chapters:
            c = chunker.chunk_chapter(chapter_text, book_id=book_id, spine_index=spine_idx)
            book_chunks.extend(c)

        if not book_chunks:
            continue

        stat = epub_path.stat()
        pending_book_data.append((book_id, stat.st_size, int(stat.st_mtime), book_chunks))
        pending_chunks.extend(book_chunks)
        processed_books_count += 1

        if len(pending_chunks) >= CHUNK_FLUSH_THRESHOLD:
            flush_pending()

    flush_pending()
    writer.finalize()
    elapsed = time.time() - start_time
    print(f"Total time elapsed: {elapsed:.2f} seconds ({writer.total_chunks / max(elapsed, 0.001):.1f} chunks/sec)")


if __name__ == "__main__":
    main()
