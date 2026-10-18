# Third-party software

Ambrosia is licensed GPL-3.0-only (see `LICENSE`).

## Swift package dependencies

Pinned in `Ambrosia.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`. License type read from the `LICENSE` file at each pinned revision.

| Package | Version | Revision | License |
| --- | --- | --- | --- |
| FlyingFox | 0.27.0 | d06fd45653bcab9803af31d66440f552c9dd9c93 | MIT |
| SQLite.swift | 0.16.0 | 964c300fb0736699ce945c9edb56ecd62eba27a3 | MIT |
| SwiftSoup | 2.13.6 | ead56133a693d0184d8c2db1a6d6394410cacfd6 | MIT |
| ZIPFoundation | 0.9.20 | 22787ffb59de99e5dc1fbfe80b19c97a904ad48d | MIT |

MIT is generally regarded as compatible with GPL-3.0 when combined into one work. Keep each package's copyright and permission notice with any redistribution. This file is not legal advice.

## Calibre-derived code

Present: the full-text tokenizer port in `Ambrosia/Database/CalibreFTS/C/calibre_tokenizer.c` (plus `CalibreTokenizer.swift`), derived from Calibre `src/calibre/db/sqlite_extension.cpp`, Copyright (C) 2021 Kovid Goyal, GPL v3. The UTF-8 decoder table in that file is Calibre's copy of Bjoern Hoehrmann's DFA decoder (https://bjoern.hoehrmann.de/utf-8/decoder/dfa/), which carries a permissive license; the exact license text was not read for this change, so confirm it before release.
