#!/usr/bin/env python3
"""
scripts/modernize_epubs.py
Decoupled EPUB 3 normalizer and modernizer for Ambrosia-exported libraries.

Converts legacy AO3/Calibre EPUB 2 files into standards-compliant EPUB 3.0 packages
adhering to the `epub-otwarchive` specification (tcyrus) without modifying author
written content (preserving Invariant 1).

Usage:
    python3 scripts/modernize_epubs.py /path/to/exported_epubs
    python3 scripts/modernize_epubs.py /path/to/exported_epubs --output /path/to/modernized
    python3 scripts/modernize_epubs.py /path/to/book.epub --in-place
"""

import argparse
import concurrent.futures
import datetime
import os
import re
import shutil
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path


NAMESPACES = {
    "container": "urn:oasis:names:tc:opendocument:xmlns:container",
    "opf": "http://www.idpf.org/2007/opf",
    "dc": "http://purl.org/dc/elements/1.1/",
    "xhtml": "http://www.w3.org/1999/xhtml",
    "epub": "http://www.idpf.org/2007/ops",
    "ncx": "http://www.daisy.org/z3986/2005/ncx/",
}

for prefix, uri in NAMESPACES.items():
    ET.register_namespace(prefix if prefix != "opf" else "", uri)


def find_opf_path(archive: zipfile.ZipFile) -> str:
    """Finds full path to OPF file from META-INF/container.xml."""
    try:
        container_xml = archive.read("META-INF/container.xml")
        root = ET.fromstring(container_xml)
        for rootfile in root.findall(".//{urn:oasis:names:tc:opendocument:xmlns:container}rootfile"):
            full_path = rootfile.get("full-path")
            if full_path:
                return full_path
    except Exception:
        pass
    # Fallback to search
    for name in archive.namelist():
        if name.endswith(".opf"):
            return name
    raise ValueError("No OPF file found in container")


def modernize_epub(source_path: Path, dest_path: Path) -> bool:
    """
    Normalizes a single EPUB into an EPUB 3 container at dest_path.
    Returns True if modernized, False if skipped.
    """
    temp_dir = Path(tempfile.mkdtemp(prefix="ambrosia_norm_"))
    try:
        with zipfile.ZipFile(source_path, "r") as src_zip:
            opf_path = find_opf_path(src_zip)
            opf_dir = os.path.dirname(opf_path)
            opf_content = src_zip.read(opf_path).decode("utf-8", errors="replace")

            # Check if already modernized EPUB 3
            if 'version="3.0"' in opf_content and "properties=\"nav\"" in opf_content:
                # Already modern EPUB 3: direct copy
                dest_path.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source_path, dest_path)
                return True

            # Extract archive contents to temporary staging directory
            src_zip.extractall(temp_dir)

            # Modernize OPF XML
            opf_tree = ET.fromstring(opf_content)
            opf_tree.set("version", "3.0")

            metadata_el = opf_tree.find(".//{http://www.idpf.org/2007/opf}metadata")
            if metadata_el is not None:
                # Add modified date
                mod_elem = metadata_el.find(".//{http://www.idpf.org/2007/opf}meta[@property='dcterms:modified']")
                now_str = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                if mod_elem is None:
                    mod_elem = ET.SubElement(metadata_el, "{http://www.idpf.org/2007/opf}meta")
                    mod_elem.set("property", "dcterms:modified")
                mod_elem.text = now_str

            # Check manifest for navigation document
            manifest_el = opf_tree.find(".//{http://www.idpf.org/2007/opf}manifest")
            has_nav = False
            if manifest_el is not None:
                for item in manifest_el.findall(".//{http://www.idpf.org/2007/opf}item"):
                    if "nav" in (item.get("properties") or "").split():
                        has_nav = True
                        break

            # If no EPUB 3 nav document, synthesize one alongside toc.ncx
            if not has_nav and manifest_el is not None:
                nav_filename = "nav.xhtml"
                nav_rel_path = f"{opf_dir}/{nav_filename}" if opf_dir else nav_filename
                nav_fs_path = temp_dir / nav_rel_path

                # Parse spine items for nav entries
                title_el = opf_tree.find(".//{http://purl.org/dc/elements/1.1/}title")
                doc_title = title_el.text if title_el is not None and title_el.text else source_path.stem

                nav_html = f"""<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head>
    <meta charset="utf-8"/>
    <title>{doc_title}</title>
</head>
<body epub:type="frontmatter">
    <nav id="toc" epub:type="toc" role="doc-toc">
        <h2>Table of Contents</h2>
        <ol>
"""
                spine_el = opf_tree.find(".//{http://www.idpf.org/2007/opf}spine")
                id_to_href = {}
                for item in manifest_el.findall(".//{http://www.idpf.org/2007/opf}item"):
                    id_to_href[item.get("id")] = item.get("href")

                if spine_el is not None:
                    idx = 1
                    for itemref in spine_el.findall(".//{http://www.idpf.org/2007/opf}itemref"):
                        idref = itemref.get("idref")
                        href = id_to_href.get(idref)
                        if href and not href.endswith(".ncx"):
                            nav_html += f'            <li><a href="{href}">Part {idx}</a></li>\n'
                            idx += 1

                nav_html += """        </ol>
    </nav>
</body>
</html>
"""
                nav_fs_path.write_text(nav_html, encoding="utf-8")

                # Add to manifest
                nav_item = ET.SubElement(manifest_el, "{http://www.idpf.org/2007/opf}item")
                nav_item.set("id", "nav")
                nav_item.set("href", nav_filename)
                nav_item.set("media-type", "application/xhtml+xml")
                nav_item.set("properties", "nav")

            # Write updated OPF back to disk
            updated_opf = ET.tostring(opf_tree, encoding="utf-8", xml_declaration=True)
            (temp_dir / opf_path).write_bytes(updated_opf)

        # Repackage EPUB container
        dest_path.parent.mkdir(parents=True, exist_ok=True)
        staging_output = temp_dir.parent / f"staged_{dest_path.name}"

        with zipfile.ZipFile(staging_output, "w") as out_zip:
            # 1. mimetype MUST be entry #1, uncompressed (ZIP_STORED)
            mimetype_path = temp_dir / "mimetype"
            if mimetype_path.exists():
                out_zip.write(mimetype_path, "mimetype", compress_type=zipfile.ZIP_STORED)
            else:
                out_zip.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)

            # 2. Add remaining entries compressed with ZIP_DEFLATED
            for root_dir, _, files in os.walk(temp_dir):
                for filename in files:
                    file_path = Path(root_dir) / filename
                    rel_path = file_path.relative_to(temp_dir).as_posix()
                    if rel_path == "mimetype":
                        continue
                    out_zip.write(file_path, rel_path, compress_type=zipfile.ZIP_DEFLATED)

        if dest_path.exists():
            dest_path.unlink()
        shutil.move(str(staging_output), str(dest_path))
        return True

    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)


def collect_epubs(input_path: Path, recursive: bool = True) -> list[Path]:
    """Collects all .epub files under input_path."""
    if input_path.is_file():
        return [input_path] if input_path.suffix.lower() == ".epub" else []
    pattern = "**/*.epub" if recursive else "*.epub"
    return sorted(list(input_path.glob(pattern)))


def main():
    parser = argparse.ArgumentParser(
        description="Decoupled EPUB 3 Modernizer for Ambrosia Exported Libraries",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("input", type=Path, help="Path to exported folder of EPUBs or a single EPUB file")
    parser.add_argument("--output", "-o", type=Path, help="Target destination folder (default: <input>_modernized)")
    parser.add_argument("--in-place", action="store_true", help="Modernize files in-place replacing originals")
    parser.add_argument("--workers", "-w", type=int, default=os.cpu_count() or 4, help="Parallel worker threads")
    parser.add_argument("--non-recursive", action="store_true", help="Do not search subdirectories recursively")
    parser.add_argument("--dry-run", action="store_true", help="Scan and list files without processing")

    args = parser.parse_args()

    input_path = args.input.resolve()
    if not input_path.exists():
        print(f"Error: Input path '{input_path}' does not exist.", file=sys.stderr)
        sys.exit(1)

    epubs = collect_epubs(input_path, recursive=not args.non_recursive)
    total_count = len(epubs)

    if total_count == 0:
        print(f"No .epub files found at '{input_path}'.")
        sys.exit(0)

    if args.dry_run:
        print(f"Dry-run scan: Found {total_count} EPUB file(s):")
        for ep in epubs[:20]:
            print(f"  - {ep.name}")
        if total_count > 20:
            print(f"  ... and {total_count - 20} more.")
        sys.exit(0)

    if args.in_place:
        output_base = input_path if input_path.is_dir() else input_path.parent
    elif args.output:
        output_base = args.output.resolve()
    else:
        output_base = input_path.parent / f"{input_path.name}_modernized"

    print(f"==> Modernizing {total_count} EPUB(s)")
    print(f"    Source:      {input_path}")
    print(f"    Destination: {output_base}")
    print(f"    Concurrency: {args.workers} workers\n")

    start_time = time.time()
    success_count = 0
    failure_count = 0

    def process_task(epub_file: Path) -> tuple[bool, str, str]:
        if input_path.is_file():
            target_dest = output_base / epub_file.name if output_base.is_dir() else output_base
        else:
            rel = epub_file.relative_to(input_path)
            target_dest = output_base / rel

        try:
            ok = modernize_epub(epub_file, target_dest)
            return (ok, epub_file.name, "")
        except Exception as err:
            return (False, epub_file.name, str(err))

    with concurrent.futures.ProcessPoolExecutor(max_workers=args.workers) as executor:
        futures = {executor.submit(process_task, ep): ep for ep in epubs}
        processed = 0

        for future in concurrent.futures.as_completed(futures):
            processed += 1
            ok, name, err = future.result()
            if ok:
                success_count += 1
            else:
                failure_count += 1
                if err:
                    print(f"  [FAIL] {name}: {err}")

            if processed % 25 == 0 or processed == total_count:
                pct = (processed / total_count) * 100.0
                print(f"[{processed}/{total_count}] ({pct:.1f}%) processed...", end="\r", flush=True)

    elapsed = time.time() - start_time
    print(f"\n\n==> Done in {elapsed:.2f}s!")
    print(f"    Successfully modernized: {success_count}")
    if failure_count > 0:
        print(f"    Failed:                  {failure_count}")


if __name__ == "__main__":
    main()
