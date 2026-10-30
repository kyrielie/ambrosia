# Ambrosia

Ambrosia is a native macOS EPUB library reader for AO3-heavy Calibre libraries. It reads Calibre's `metadata.db`, renders EPUBs in a custom reader, and stores Ambrosia-only state in a separate per-library database. Designed for AO3 metadata first!

## Screenshots

<details open>
  <summary>📸 Click to collapse/expand screenshot gallery (6 Images)</summary>
  <br>
  <p align="center">
    <img src="./screenshots/rowview.png" width="48%" alt="Library List View">
    <img src="./screenshots/emailview.png" width="48%" alt="Email Split View">
    <img src="./screenshots/rowview2.png" width="48%" alt="Filtered List View">
    <img src="./screenshots/activity.png" width="48%" alt="Activity and Reading Goals">
    <img src="./screenshots/settings.png" width="48%" alt="Library Settings">
    <img src="./screenshots/settings2.png" width="48%" alt="Reader Settings">
  </p>
</details>

## Features

- Opens an existing Calibre library folder with `metadata.db`.
- Reads Calibre metadata read-only, including authors, tags, series, comments, custom columns, and EPUB file locations.
- Provides list, email-style, and activity library modes, search prefixes, filter rules, pagination, and optional full-text search through Calibre's own FTS index (`fulltext:`).
- Extracts AO3 EPUB preface metadata into a per-library `ambrosia_meta.db`, including fandoms, relationships, characters, additional tags, categories, word counts, chapter counts, AO3 series, and extraction diagnostics.
- Supports system collections (Read Later, Liked, Skipped, Finished, In Progress, Has Annotations, Series or Merged) as well as user-created, renameable collections.
- Groups collapsed series through cached AO3/Calibre series metadata and tracks merged or anthology-style works in Series or Merged.
- Renders EPUBs with a custom `WKWebView` reader in scroll or paginated mode, including a table-of-contents popup and continuous reading across an entire series in one window.
- Stores highlights and point annotations in `ambrosia_meta.db`.
- Tracks reading goals against a configurable period, and surfaces an activity feed of recent reading sessions, annotations, collection changes, and searches.
- Includes CSV export of library metadata and annotations, an optional local read-only RSS feed server, and reader/library preferences.
- Can import an external AO3 tag seed database for canonical tag and synonym expansion, with in-app validation feedback.
- Remembers recently opened Calibre libraries.

## Other cool swift native projects not made for AO3 but also support calibre

Let me know if there are any more! I just searched `site:github.com macOS swift native book epub calibre` in google. 

https://github.com/artemnovichkov/Octavo
https://github.com/PratikRai0101/Varq
https://github.com/Aletheie/Winston

> [!IMPORTANT]
> What ambrosia does differently:
> - Support macos 15 sequoia because I still haven't updated to 26+ 😭. I don't even know if ambrosia works on 26+...
> - Looks kinda worse tbh, not as well vibecoded.
> - Not support cover art because like 90% of fanfiction doesn't have it and I never spent the time adding it.

## Installation

### Homebrew

Install Ambrosia from the personal Yggdrasil tap:

```bash
brew tap kyrielie/yggdrasil
brew install --cask ambrosia
```

To update it after a tap update has been merged:

```bash
brew upgrade --cask ambrosia
```

The current builds are ad-hoc signed and not notarized. macOS may ask you to
approve opening Ambrosia the first time. See the [Yggdrasil tap](https://github.com/kyrielie/homebrew-yggdrasil)
for the cask and release details.

### Manual download

Download `Ambrosia.dmg` from the [latest release](https://github.com/kyrielie/ambrosia/releases/latest).

Either use command to bypass Gatekeeper or right-click, open, allow.
```zsh
sudo xattr -rd com.apple.quarantine /path/to/Ambrosia.app
```


## Requirements

- macOS 14.0 or newer.
- Xcode with Swift support.
- A Calibre library folder containing `metadata.db`.
- Swift packages resolved by the Xcode project:
  - SQLite.swift
  - ZIPFoundation
  - SwiftSoup
  - FlyingFox

## Build

Open `Ambrosia.xcodeproj` in Xcode and build the `Ambrosia` scheme, or run:

```bash
xcodebuild -scheme Ambrosia -destination 'platform=macOS' build
```

The repository uses Xcode/SPM package management. Do not hand-edit `Package.resolved`; add or update packages through Xcode.

## Testing

Run `./test.sh` from the repo root to lint and test locally, the same way `.github/workflows/swift.yml` does in CI. See `./test.sh --help` for options (`--no-lint`, `--lint-only`, `--filter PATTERN`, `--quiet`). Requires Xcode and, unless `--no-lint` is passed, SwiftLint (`brew install swiftlint`).

## Library Setup

Ambrosia expects a Calibre library directory, not an individual EPUB folder. (Will be supported later.) The selected folder must contain:

- `metadata.db`
- Calibre's normal author/book subfolders and EPUB files
- optionally `full-text-search.db` for `fulltext:` search (Calibre's FTS index, queried natively)

On first open, Ambrosia records the library path and creates its own writable database under:

```text
~/Library/Application Support/Ambrosia/libraries/<library-hash>/ambrosia_meta.db
```

Calibre's `metadata.db` remains read-only. Ambrosia also keeps a small local index of libraries you've opened, so recently used libraries are easy to reopen.

## Usage Quick Start

1. Launch Ambrosia.
2. Choose a Calibre library folder.
3. Browse in list mode, email mode, or the activity feed.
4. Search with plain text or prefixes such as `tag:`, `author:`, `title:`, and `series:`.
5. Open an EPUB in the reader — open a single book, or open an entire series to read continuously in one window, with a table-of-contents popup available in either case.
6. Use reader preferences to switch typography, spacing, colors, window sizing, paginated columns, and scroll/paginated mode.
7. Add annotations or highlights from the reader.
8. Organize books into system or custom collections, and set a reading goal for the current period.
9. Export visible library results to CSV when needed.

AO3 metadata extraction runs in the background after a library opens. The library remains usable while extraction proceeds.

## Data Model

Ambrosia separates storage ownership:

- Calibre `metadata.db`: read-only source of truth for book metadata and EPUB file paths.
- SwiftData store: reading state and reading goals.
- Ambrosia `ambrosia_meta.db`: per-library app-owned state, including collections, annotations, AO3 metadata, AO3 diagnostics, series cache, series placeholders, reading history, and tag synonym tables.
- UserDefaults: app preferences, selected library path, and lightweight configuration.


## Privacy

Ambrosia is a local macOS app. It reads local Calibre libraries and writes local Ambrosia support files. Current developer-preview functionality does not require cloud sync or network services. Future AO3 account features are not implemented.

## Contributing

This is a work-in-progress app. Keep changes scoped, preserve Calibre read-only behavior, and verify with `./test.sh` before claiming a clean build. Documentation-only changes should at least pass `./test.sh --lint-only`.

## License

This project is licensed under the GNU General Public License v3.0 only (GPL-3.0-only). See `LICENSE`. Third-party dependency licenses are listed in `THIRD_PARTY.md`.

#### Note to self

Use create-dmg to generate dmg.
