# Ambrosia — Release & Notarization Checklist

Run through this list in order every time you cut a release build.

---

## 1. Pre-build checklist

- [ ] Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`.
- [ ] Run the pagination harness on at least one 500k-word book (`#if DEBUG` guard in `ReaderViewController`).
- [ ] Verify the app opens cleanly on a fresh macOS 14 VM (no Calibre library pre-configured).
- [ ] Run `Product → Clean Build Folder` (⇧⌘K) before archiving.

---

## 2. Archive

In Xcode:

1. Set the scheme destination to **Any Mac (Apple Silicon, Intel)**.
2. `Product → Archive`.
3. In Organizer, select the archive → **Distribute App → Developer ID → Export**.
   - Select **"Copy App"** (not Upload, unless you want Xcode to notarize automatically).
   - Export to a staging folder, e.g. `~/Desktop/AmbrosiaExport/`.

---

## 3. Create the DMG

```bash
# Install create-dmg if you haven't already:
brew install create-dmg

APP="$HOME/Desktop/AmbrosiaExport/Ambrosia.app"
OUT="$HOME/Desktop/Ambrosia.dmg"

create-dmg \
  --volname "Ambrosia" \
  --volicon "$APP/Contents/Resources/AppIcon.icns" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "Ambrosia.app" 175 190 \
  --hide-extension "Ambrosia.app" \
  --app-drop-link 425 190 \
  "$OUT" \
  "$(dirname "$APP")/"
```

---

## 4. Notarize

You need:
- An Apple Developer account enrolled in the Apple Developer Program.
- An **app-specific password** generated at [appleid.apple.com](https://appleid.apple.com).
- Your **Team ID** — visible at [developer.apple.com/account](https://developer.apple.com/account).

```bash
APPLE_ID="your@email.com"
TEAM_ID="XXXXXXXXXX"
APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"   # app-specific password
DMG="$HOME/Desktop/Ambrosia.dmg"

# Submit for notarization
xcrun notarytool submit "$DMG" \
  --apple-id "$APPLE_ID" \
  --team-id  "$TEAM_ID" \
  --password "$APP_PASSWORD" \
  --wait

# Staple the ticket so Gatekeeper works offline
xcrun stapler staple "$DMG"

# Verify
xcrun stapler validate "$DMG"
spctl --assess --verbose --type open --context context:primary-signature "$DMG"
```

If `notarytool submit` returns an error, fetch the full log:

```bash
xcrun notarytool log <submission-id> \
  --apple-id "$APPLE_ID" \
  --team-id  "$TEAM_ID" \
  --password "$APP_PASSWORD"
```

Common failures:
- **Hardened Runtime not enabled** → Xcode target → Signing & Capabilities → enable Hardened Runtime.
- **Missing entitlements** → Ambrosia needs no special entitlements (no network, no sandbox); leave the entitlements file empty except for `com.apple.security.cs.allow-jit` if WKWebView JIT compilation is needed.
- **Unsigned framework/dylib** → all SPM packages (SQLite.swift, ZIPFoundation) are source-only; no additional signing needed.

---

## 5. GitHub release

```bash
# Tag the release
git tag -a "v1.0.0" -m "Version 1.0.0"
git push origin "v1.0.0"
```

In the GitHub Releases UI:
1. Create a release from the new tag.
2. Attach `Ambrosia.dmg` (notarized, stapled).
3. Write release notes. Minimum content:
   - macOS version requirement (14.0+)
   - Calibre version tested against
   - Known limitations (paginated mode, custom column auto-detection)

---

## 6. Post-release smoke test

On a clean user account (or a second machine):

- [ ] Mount DMG → drag Ambrosia to Applications → open. Gatekeeper should pass silently.
- [ ] Open a Calibre library. Confirm book list loads.
- [ ] Open a book. Confirm EPUB renders with publisher CSS stripped.
- [ ] Change a preference (font size). Confirm the reader window reloads immediately.
- [ ] Close and reopen the book. Confirm scroll position is restored.

---

## Performance notes (from project plan)

- `mergedHTML()` is the bottleneck for 500k+ word books. If opening takes >2 s, enable lazy spine loading: load only the first 3 spine items on open, then load the rest in the background.
- `CalibreLibrary` SQLite queries run synchronously on the main thread and are typically <1 ms on a local SSD. No async queuing needed.
- Profile with **Instruments → Time Profiler** attached to a Debug build before profiling a Release build; the Release binary strips symbols needed for useful flame graphs.
