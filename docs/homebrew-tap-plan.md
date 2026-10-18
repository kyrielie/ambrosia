# Homebrew tap for Honeycrisp and Ambrosia

## Goal

Make it easy to install and update both native macOS apps on the maintainer's
own Macs through one personal Homebrew tap, while keeping their existing
GitHub repositories and release assets as the source of truth. This is a
personal convenience tap, not a request to meet Homebrew core's public-cask
distribution expectations.

Tap repository: `kyrielie/homebrew-yggdrasil`, addressed by Homebrew as
`kyrielie/yggdrasil`. It will contain one cask per macOS app:

- `Casks/honeycrisp.rb`
- `Casks/ambrosia.rb`

Expected user commands:

```sh
brew tap kyrielie/yggdrasil
brew install --cask kyrielie/yggdrasil/honeycrisp
brew install --cask kyrielie/yggdrasil/ambrosia
brew upgrade --cask honeycrisp ambrosia
```

Homebrew recommends a `homebrew-` repository name for GitHub taps and a README
that explains the tap. Third-party tap code is a trust boundary, so keep this
tap owner-controlled and link to both source repositories. See
[How to Create and Maintain a Tap](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap)
and [Tap Trust](https://docs.brew.sh/Tap-Trust).

## Current release state

Both projects currently build macOS DMGs from GitHub Actions and ad-hoc sign
them. Developer ID signing and notarization are **not requirements** for this
personal tap. Homebrew installation does not remove quarantine or bypass
Gatekeeper, so keep the current manual first-open steps documented. Do not add
automatic `xattr` removal to a cask install step.

The tap should still use versioned release assets and exact SHA-256 checksums.
Those make it easy to update the apps predictably and to tell when a release
asset changed, independent of code signing.

## Verified app details and release blockers

| App | Bundle identifier | Current deployment target | Current release workflow |
|---|---|---:|---|
| Honeycrisp | `com.noliaphyta.Honeycrisp` | macOS 13 | Manual workflow dispatch; builds an ad-hoc signed DMG |
| Ambrosia | `com.kyrielie.ambrosia` | macOS 15 in `project.yml` | Manual workflow dispatch; builds an arm64 ad-hoc signed DMG |

Ambrosia's README currently says macOS 14+, while `project.yml` sets the
effective target to macOS 15. Reconcile that discrepancy and build metadata
before publishing a cask. A cask's OS requirement must match the shipped app,
not the README alone.

Honeycrisp's project is configured as version `1.0`; Ambrosia's XcodeGen
configuration says `0.1.1`. Make the release tag, app `CFBundleShortVersionString`,
and cask `version` agree for each release. Keep the apps' versions independent.

## Cask design

Each cask should use the versioned DMG from its own repository's GitHub release:

```ruby
cask "honeycrisp" do
  version "1.0.0"
  sha256 "<sha256 of the release DMG>"

  url "https://github.com/kyrielie/honeycrisp/releases/download/v#{version}/Honeycrisp.dmg"
  name "Honeycrisp Reader"
  desc "Standalone macOS EPUB reader"
  homepage "https://github.com/kyrielie/honeycrisp"

  depends_on macos: ">= :ventura"

  app "Honeycrisp.app"
end
```

The Ambrosia cask follows the same pattern with its own release URL, checksum,
name, and minimum supported macOS version. The example version and asset names
must be finalized against actual tagged releases before use. Casks require a
version, SHA-256, URL, name, description, and homepage; `:no_check` is not
appropriate for versioned release assets. See the [Cask Cookbook](https://docs.brew.sh/Cask-Cookbook).

Add a `livecheck` stanza that reads stable version tags or the GitHub release
page. Avoid a `latest` URL, because a fixed release URL plus checksum makes
updates reviewable and reproducible. Do not set `auto_updates true` unless an
app updater is added and Homebrew should defer to it.

Use separate casks rather than a combined installer: users can choose either
app, update them independently, and report issues against the right project.
No formula is needed; both products are GUI applications distributed as
prebuilt `.app` bundles.

## Release automation

### In each app repository

Change the current manual-only release workflow to run for version tags such
as `v1.2.3` and optionally retain `workflow_dispatch` for recovery builds. The
workflow should:

1. Check that the tag matches the app's marketing version.
2. Build a Release `.app` with the correct architecture set.
3. Package the built app in a DMG. Code signing and notarization are not
   requirements for this personal tap.
4. Package the app in a DMG with an Applications shortcut.
5. Compute `shasum -a 256` and attach both the DMG and a checksum file to the
   GitHub release.

Honeycrisp currently builds its target directly; Ambrosia generates its Xcode
project from `project.yml` before building. Keep those product-specific build
steps in their own repositories. Publish versioned assets with consistent
names, for example `Honeycrisp-1.2.3.dmg` and `Ambrosia-0.2.0.dmg`, to avoid
ambiguous release URLs.

Decide whether to support Apple Silicon only or both Apple Silicon and Intel
before writing the casks. Current Ambrosia release automation explicitly
builds arm64. Do not claim Intel support in Homebrew until both apps have
verified Intel or universal builds. If architectures differ, use cask
architecture conditionals and matching per-architecture checksums only after
the release workflows produce those assets.

### In the tap repository

For each app release, automatically open a pull request that updates only that
app's cask version and SHA-256. Keep the update reviewable rather than pushing
directly to the tap's default branch. The source app's release workflow should
dispatch a `repository_dispatch` event to the tap after the DMG and release
metadata are published; the tap workflow downloads the named asset, computes
its SHA-256, updates the matching cask, and opens a pull request. Use a narrowly
scoped GitHub App installation token (preferred) or a fine-grained token
limited to the tap repository, stored as a secret in each source app repo.
The tap CI workflow should run Homebrew cask style/audit checks and verify:

- the release URL returns the expected asset;
- the asset checksum matches the cask;
- the DMG contains the expected `.app` name;
- the app bundle identifier and minimum OS version match the cask;
- the DMG's checksum and expected app bundle identifier validate. Code-sign
  checks are informational for this personal tap, not a release gate.

The tap should not rebuild either application. Keep build and signing secrets
in the application repositories; the tap only points at published artifacts.

## Uninstall and user data

Do not add a `zap` stanza initially. Honeycrisp history and preferences are
user data, and Ambrosia stores annotations, collections, reading state, and
per-library databases under Application Support. A normal cask uninstall
should remove the app while preserving those files. If a future `zap` stanza is
added, make it explicit, optional, and narrowly scoped; never include Calibre
books or `metadata.db`.

Honeycrisp's extracted reading files are temporary app-owned data. Its current
code change moves active extraction into Application Support and removes it
when the reader closes; confirm the final path and cleanup behavior before
considering any Homebrew cleanup rule for it.

## Rollout

1. **Release readiness:** reconcile Ambrosia's minimum macOS version, align tag
   and bundle versions, decide supported architectures, and confirm app names
   and bundle identifiers.
2. **Repeatable artifacts:** publish checksummed, versioned DMGs from both
   release pipelines. Keep existing ad-hoc signing and first-open guidance;
   signing/notarization can be added later if distribution expands.
3. **Personal tap prototype:** create `kyrielie/homebrew-yggdrasil`, add both casks
   with one real release each, and run `brew audit --cask --strict` plus
   install/uninstall checks on a clean macOS account.
4. **Release/update checks:** verify upgrades across two app versions, confirm
   user data survives uninstall, and test a missing or invalid release asset
   fails clearly.
5. **Personal instructions:** add installation commands to the tap README and
   optionally link it from both app READMEs. Document the first-open Gatekeeper
   step for the current ad-hoc signed builds.

## Decisions to record before implementation

- Is Honeycrisp's release version `1.0` or should it move to semantic
  versions such as `1.0.0`?
- Should Ambrosia support macOS 14 as its README says, or macOS 15 as its
  effective build target says?
- Are Intel Macs in scope for either app?
- Which GitHub App or fine-grained token will authorize release-triggered tap
  update pull requests?
