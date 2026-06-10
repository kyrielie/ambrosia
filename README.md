# Ambrosia

Ambrosia is a developer-preview native macOS EPUB library reader for AO3-heavy Calibre libraries. It reads Calibre's `metadata.db`, renders EPUBs in a custom reader, and stores Ambrosia-only state in a separate per-library database.

The app is currently aimed at local development and testing. There are no packaged, notarized, or downloadable releases in this repository.

## Features

- Opens an existing Calibre library folder with `metadata.db`.
- Reads Calibre metadata read-only, including authors, tags, series, comments, custom columns, and EPUB file locations.
- Provides list and email-style library modes, search prefixes, filter rules, pagination, and optional Calibre full-text-search fallback.
- Extracts AO3 EPUB preface metadata into a per-library `ambrosia_meta.db`, including fandoms, relationships, characters, additional tags, categories, word counts, chapter counts, AO3 series, and extraction diagnostics.
- Supports system collections such as Read Later, Liked, Skipped, Finished, In Progress, Has Annotations, and Series or Merged.
- Groups collapsed series through cached AO3/Calibre series metadata and tracks merged or anthology-style works in `Series or Merged`.
- Renders EPUBs with a custom `WKWebView` reader in scroll or paginated mode.
- Stores highlights and point annotations in `ambrosia_meta.db`.
- Includes CSV export and reader/library preferences.
- Can import an external AO3 tag seed database for canonical tag and synonym expansion.

## Installation

Download Ambrosia.dmg.

Either use command to bypass Gatekeeper or right-click, open, allow. 
`sudo xattr -rd com.apple.quarantine /path/to/Ambrosia.app`

## Screenshots



## Requirements

- macOS 14.0 or newer.
- Xcode with Swift support.
- A Calibre library folder containing `metadata.db`.
- Swift packages resolved by the Xcode project:
  - SQLite.swift
  - ZIPFoundation
  - SwiftSoup

## Build

Open `Ambrosia.xcodeproj` in Xcode and build the `Ambrosia` scheme, or run:

```bash
rtk xcodebuild -scheme Ambrosia -destination 'platform=macOS' build
```

The repository uses Xcode/SPM package management. Do not hand-edit `Package.resolved`; add or update packages through Xcode.

## Library Setup

Ambrosia expects a Calibre library directory, not an individual EPUB folder. The selected folder must contain:

- `metadata.db`
- Calibre's normal author/book subfolders and EPUB files
- optionally `full-text-search.db` for FTS-backed plain-text search

On first open, Ambrosia records the library path and creates its own writable database under:

```text
~/Library/Application Support/Ambrosia/libraries/<library-hash>/ambrosia_meta.db
```

Calibre's `metadata.db` remains read-only.

## Usage Overview

1. Launch Ambrosia.
2. Choose a Calibre library folder.
3. Browse in list mode or email mode.
4. Search with plain text or prefixes such as `tag:`, `author:`, `title:`, and `series:`.
5. Open an EPUB in the reader.
6. Use reader preferences to switch typography, spacing, colors, window sizing, and scroll/paginated mode.
7. Add annotations or highlights from the reader.
8. Export visible library results to CSV when needed.

AO3 metadata extraction runs in the background after a library opens. The library remains usable while extraction proceeds.

## Data Model

Ambrosia separates storage ownership:

- Calibre `metadata.db`: read-only source of truth for book metadata and EPUB file paths.
- SwiftData store: reading state and reading goals.
- Ambrosia `ambrosia_meta.db`: per-library app-owned state, including collections, annotations, AO3 metadata, AO3 diagnostics, series cache, series placeholders, and tag synonym tables.
- UserDefaults: app preferences, selected library path, and lightweight configuration.

## Privacy

Ambrosia is a local macOS app. It reads local Calibre libraries and writes local Ambrosia support files. Current developer-preview functionality does not require cloud sync or network services. Future AO3 account features are not implemented.

## Roadmap

Implemented or partially implemented areas include AO3 metadata extraction, tag seed import, series cache/grouping, annotations, CSV export, preferences, list mode, email mode, and system collections.

Known unfinished areas include ranking UI, table-of-contents popup, AO3 login/kudos/bookmarks, saved searches, favourite authors, saved quotes, annotation export, standalone non-Calibre mode, and music integration.

See [projectplan3.md](/Users/ethanchan/Documents/Applications/ambrosia/projectplan3.md) and [ambrosia_architecture.md](/Users/ethanchan/Documents/Applications/ambrosia/ambrosia_architecture.md) for implementation details.

## Contributing

This is a work-in-progress app. Keep changes scoped, preserve Calibre read-only behavior, and verify with `xcodebuild` before claiming a clean build. Documentation-only changes should at least pass:

```bash
rtk git diff --check
```

## License

This project is licensed under the terms in [LICENSE](/Users/ethanchan/Documents/Applications/ambrosia/LICENSE).
