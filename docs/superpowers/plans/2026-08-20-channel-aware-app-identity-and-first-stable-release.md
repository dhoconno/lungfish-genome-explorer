# Channel-Aware App Identity and First Stable Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Preview and Stable Lungfish builds unmistakable channel-specific names, then publish the current verified Preview baseline as the first independently verified Stable CalVer release.

**Architecture:** A small bundle-backed `LungfishAppIdentity` in `LungfishCore` is the sole runtime naming authority. The release builder stamps and verifies the channel, full name, short name, and Sparkle feed before signing while preserving `Lungfish.app` and `com.lungfish.browser`; the Stable release is a new CalVer build and artifact, not a relabeled Preview DMG.

**Tech Stack:** Swift 6, AppKit/SwiftUI, XCTest/Swift Testing, Bash, Python `unittest`, Xcode archive tooling, Sparkle 2.9.6, GitHub CLI, Apple Developer ID signing/notarization.

**Spec:** `docs/superpowers/specs/2026-08-20-channel-aware-app-identity-and-first-stable-release-design.md`

## Global Constraints

- Preview full/short names are exactly `Lungfish Genome Explorer Preview` and `Lungfish Preview`; Stable full/short names are exactly `Lungfish Genome Explorer` and `Lungfish`.
- Shipped bundles carry `LungfishReleaseChannel=preview|stable`; ordinary source builds use Stable identity and Debug identity remains unchanged.
- Both channels retain `Lungfish.app`, executable `Lungfish`, bundle identifier `com.lungfish.browser`, preferences, document associations, and one suffix-free CalVer sequence.
- Scientific provenance, generated-file attribution, user agents, CLI descriptions, and Help Book product identity remain channel-neutral.
- Preview copy says: `Preview builds are under rapid iterative development. Features may be incomplete, change quickly, or require additional feedback.`
- The first Stable version is the next collision-free CalVer at execution time (`2026.8.4` if no newer August tag/release appears), rebuilt with `--channel stable` from committed source.
- First Stable notes aggregate from `v0.5.0-beta29`, list published previews `v2026.8.1` and `v2026.8.3`, and describe `v2026.8.2` only as an unpublished preparation tag.
- No GitHub, tag, Sparkle, or release mutation occurs until source, tests, isolated dependency receipt, signing, notarization, and collision preflights pass.
- No CI workflow is manually dispatched; the full Stable GitHub release triggers the heavy board via the `released` event.

---

### Task 1: Bundle-backed channel identity

**Files:**
- Create: `Sources/LungfishCore/AppIdentity.swift`
- Create: `Tests/LungfishCoreTests/AppIdentityTests.swift`

**Interfaces:**
- Consumes: bundle Info.plist keys `CFBundleDisplayName`, `CFBundleName`, and `LungfishReleaseChannel`.
- Produces: `public struct LungfishAppIdentity: Equatable, Sendable`, `public enum LungfishReleaseChannel: String, Sendable`, `static func from(infoDictionary:)`, `static var current`, `fullName`, `shortName`, `releaseChannel`, `isPreview`, and `previewCaveat`.

- [ ] **Step 1: Write failing identity tests**

```swift
import Testing
@testable import LungfishCore

@Suite("Lungfish app identity")
struct AppIdentityTests {
    @Test("Preview bundle values remain Preview")
    func previewIdentity() {
        let identity = LungfishAppIdentity.from(infoDictionary: [
            "CFBundleDisplayName": "Lungfish Genome Explorer Preview",
            "CFBundleName": "Lungfish Preview",
            "LungfishReleaseChannel": "preview",
        ])
        #expect(identity.fullName == "Lungfish Genome Explorer Preview")
        #expect(identity.shortName == "Lungfish Preview")
        #expect(identity.releaseChannel == .preview)
        #expect(identity.previewCaveat == "Preview builds are under rapid iterative development. Features may be incomplete, change quickly, or require additional feedback.")
    }

    @Test("Missing or malformed bundle values fall back to Stable")
    func stableFallback() {
        let identity = LungfishAppIdentity.from(infoDictionary: [:])
        #expect(identity.fullName == "Lungfish Genome Explorer")
        #expect(identity.shortName == "Lungfish")
        #expect(identity.releaseChannel == .stable)
        #expect(identity.previewCaveat == nil)
    }
}
```

- [ ] **Step 2: Run the focused test and confirm the missing-type failure**

Run: `swift test --filter AppIdentityTests`

Expected: compilation fails because `LungfishAppIdentity` does not exist.

- [ ] **Step 3: Implement the minimal identity type**

```swift
import Foundation

public enum LungfishReleaseChannel: String, Sendable {
    case preview
    case stable
}

public struct LungfishAppIdentity: Equatable, Sendable {
    public static let previewCaveatText = "Preview builds are under rapid iterative development. Features may be incomplete, change quickly, or require additional feedback."

    public let fullName: String
    public let shortName: String
    public let releaseChannel: LungfishReleaseChannel

    public var isPreview: Bool { releaseChannel == .preview }
    public var previewCaveat: String? { isPreview ? Self.previewCaveatText : nil }

    public static var current: Self { from(infoDictionary: Bundle.main.infoDictionary) }

    public static func from(infoDictionary: [String: Any]?) -> Self {
        guard infoDictionary?["LungfishReleaseChannel"] as? String == LungfishReleaseChannel.preview.rawValue else {
            return .init(fullName: "Lungfish Genome Explorer", shortName: "Lungfish", releaseChannel: .stable)
        }
        return .init(
            fullName: infoDictionary?["CFBundleDisplayName"] as? String ?? "Lungfish Genome Explorer Preview",
            shortName: infoDictionary?["CFBundleName"] as? String ?? "Lungfish Preview",
            releaseChannel: .preview
        )
    }
}
```

Use the final public enum name consistently in tests and implementation; do not create both `ReleaseChannel` and `LungfishReleaseChannel`.

- [ ] **Step 4: Run focused Core tests**

Run: `swift test --filter AppIdentityTests`

Expected: all identity tests pass.

- [ ] **Step 5: Commit the identity unit**

```bash
git add Sources/LungfishCore/AppIdentity.swift Tests/LungfishCoreTests/AppIdentityTests.swift
git commit -m "feat: add bundle-backed app channel identity"
```

### Task 2: Channel-aware application chrome

**Files:**
- Modify: `Sources/LungfishApp/App/MainMenu.swift`
- Modify: `Sources/LungfishApp/App/AboutWindowController.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Modify: `Sources/LungfishApp/App/ThirdPartyLicensesWindowController.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainWindowController.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+MultiDocument.swift`
- Modify: `Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift`
- Modify: `Tests/LungfishAppTests/AppShellAccessibilityTests.swift`
- Modify: `Tests/LungfishAppTests/ImportCenterMenuTests.swift`
- Modify: `Tests/LungfishAppTests/MainWindowSessionRoutingTests.swift`
- Create: `Tests/LungfishAppTests/AppIdentityPresentationTests.swift`

**Interfaces:**
- Consumes: `LungfishAppIdentity.current` and injectable `LungfishAppIdentity` values from Task 1.
- Produces: menu and window titles derived from `fullName`/`shortName`; Preview About copy derived from `previewCaveat`.

- [ ] **Step 1: Add failing Preview presentation tests**

Create a Preview identity from a dictionary and assert:

```swift
let preview = LungfishAppIdentity.from(infoDictionary: [
    "CFBundleDisplayName": "Lungfish Genome Explorer Preview",
    "CFBundleName": "Lungfish Preview",
    "LungfishReleaseChannel": "preview",
])
let menu = MainMenu.createMainMenu(
    appIdentity: preview
)
#expect(menu.items.first?.title == "Lungfish Preview")
#expect(menu.items.first?.submenu?.items.contains(where: { $0.title == "About Lungfish Genome Explorer Preview" }) == true)
#expect(menu.items.first?.submenu?.items.contains(where: { $0.title == "Quit Lungfish Genome Explorer Preview" }) == true)
```

Also instantiate `AboutWindowController(appIdentity: preview)` and assert its
title, product label, and caveat label contain the exact approved Preview copy.

- [ ] **Step 2: Run the focused App tests and confirm missing injection points**

Run: `swift test --filter AppIdentityPresentationTests`

Expected: compilation fails because `appIdentity` injection and the Preview
presentation accessors do not exist.

- [ ] **Step 3: Route application menu text through the identity**

Keep the public `createMainMenu` signature source-compatible. Add an internal
overload parameter `appIdentity: LungfishAppIdentity = .current`, create the
application menu item with `appIdentity.shortName`, and construct these strings:

```swift
"About \(appIdentity.fullName)"
"Hide \(appIdentity.fullName)"
"Quit \(appIdentity.fullName)"
```

Keep the Help Book menu title channel-neutral so it continues matching the
registered Help Book.

- [ ] **Step 4: Route About and window chrome through the identity**

Add `appIdentity: LungfishAppIdentity = .current` injection where practical and
replace only app-owned chrome strings. Use:

```swift
window.title = "About \(appIdentity.fullName)"
let nameLabel = NSTextField(labelWithString: appIdentity.fullName)
if let caveat = appIdentity.previewCaveat {
    let caveatLabel = NSTextField(wrappingLabelWithString: caveat)
    // Secondary centered text in the About content stack.
}
```

Use `LungfishAppIdentity.current.fullName` for main/project/welcome/license
window titles. Do not replace provenance, workflow, generated-file, User-Agent,
CLI, or Help Book product strings.

- [ ] **Step 5: Update Stable expectations and add Preview assertions**

Keep existing Stable test expectations unchanged where `Bundle.main` lacks a
Preview key. Add explicit Preview coverage through injected identities and add
an assertion that provenance fixtures still use the channel-neutral string
`Lungfish Genome Explorer`.

- [ ] **Step 6: Run focused application tests**

Run:

```bash
swift test --filter AppIdentityPresentationTests
swift test --filter AppShellAccessibilityTests
swift test --filter ImportCenterMenuTests
swift test --filter MainWindowSessionRoutingTests
```

Expected: all selected tests pass.

- [ ] **Step 7: Commit application presentation**

```bash
git add Sources/LungfishApp Tests/LungfishAppTests
git commit -m "feat: show release channel in app identity"
```

### Task 3: Stamp and verify release-channel bundle names

**Files:**
- Modify: `Lungfish-Info.plist`
- Modify: `scripts/release/build-notarized-dmg.sh`
- Modify: `scripts/build-app.sh`
- Modify: `scripts/tests/test_sparkle_release_packaging.py`
- Modify: `Tests/LungfishAppTests/ReleaseBuildConfigurationTests.swift`
- Modify: `Tests/LungfishAppTests/AppDebugLaunchConfigurationTests.swift`
- Modify: `docs/release/sparkle-updates.md`
- Modify: `.codex/skills/releasing-lungfish/SKILL.md`
- Modify: `.codex/agents/release-agent.md`
- Modify: `agents/definitions/codex/release-agent.md`
- Modify: `SKILLS.md`

**Interfaces:**
- Consumes: `CHANNEL=preview|stable` already resolved by the release script.
- Produces: `APP_DISPLAY_NAME`, `APP_SHORT_NAME`, and verified Info.plist keys before signing; documentation and skill gates describing visible channel identity.

- [ ] **Step 1: Add failing packaging assertions**

In `test_sparkle_release_packaging.py`, assert that channel resolution assigns:

```python
self.assertIn('APP_DISPLAY_NAME="Lungfish Genome Explorer Preview"', self.release_script)
self.assertIn('APP_SHORT_NAME="Lungfish Preview"', self.release_script)
self.assertIn('APP_DISPLAY_NAME="Lungfish Genome Explorer"', self.release_script)
self.assertIn('APP_SHORT_NAME="Lungfish"', self.release_script)
self.assertIn('plutil -replace CFBundleDisplayName', self.release_script)
self.assertIn('plutil -replace CFBundleName', self.release_script)
self.assertIn('plutil -replace LungfishReleaseChannel', self.release_script)
```

Also assert configuration precedes outer app codesigning and DMG staging, and
that wrapper paths remain literal `Lungfish.app`.

- [ ] **Step 2: Run the packaging tests and confirm failure**

Run: `python3 -m unittest scripts.tests.test_sparkle_release_packaging -v`

Expected: new channel-name assertions fail against the current script.

- [ ] **Step 3: Add source defaults and local-build channel metadata**

Set the shared plist defaults to Stable:

```xml
<key>CFBundleName</key>
<string>Lungfish</string>
<key>CFBundleDisplayName</key>
<string>Lungfish Genome Explorer</string>
<key>LungfishReleaseChannel</key>
<string>stable</string>
```

Have `scripts/build-app.sh` explicitly write `LungfishReleaseChannel=stable` for
ordinary release builds and remove it or write a non-shipping `development`
value for Debug without changing the existing Debug display names.

- [ ] **Step 4: Stamp and verify names in the release builder**

During existing channel resolution, assign exact channel names. Extend
`configure_sparkle_info_plist` before signing:

```bash
/usr/bin/plutil -replace CFBundleDisplayName -string "$APP_DISPLAY_NAME" "$info_plist"
/usr/bin/plutil -replace CFBundleName -string "$APP_SHORT_NAME" "$info_plist"
/usr/bin/plutil -replace LungfishReleaseChannel -string "$CHANNEL" "$info_plist"
```

Read back all three keys with `PlistBuddy` and fail if any value differs. Do not
change `APP_PATH`, `RELEASE_APP_PATH`, DMG staging name, DMG filename, volume
name, executable name, or bundle identifier.

- [ ] **Step 5: Update release documentation and mirrored agent instructions**

Change the channel documentation from “exactly two places” to the three-part
identity: baked feed, GitHub prerelease state, and visible bundle metadata.
Document manual DMG switching, same-wrapper replacement, public Preview access,
and the exact rapid-development caveat. Add a release gate requiring all bundle
identity values to be independently checked. Keep both release-agent mirrors
byte-identical.

- [ ] **Step 6: Run focused packaging, configuration, and skill validation**

Run:

```bash
python3 -m unittest scripts.tests.test_sparkle_release_packaging -v
swift test --filter ReleaseBuildConfigurationTests
swift test --filter AppDebugLaunchConfigurationTests
python3 .codex/skills/releasing-lungfish/scripts/validate.py --repo-root "$PWD"
bash -n scripts/release/build-notarized-dmg.sh scripts/build-app.sh
cmp -s .codex/agents/release-agent.md agents/definitions/codex/release-agent.md
git diff --check
```

Expected: every command succeeds and the agent mirrors match.

- [ ] **Step 7: Commit packaging and documentation**

```bash
git add Lungfish-Info.plist scripts docs/release .codex/skills .codex/agents agents/definitions SKILLS.md Tests/LungfishAppTests
git commit -m "release: brand bundles by update channel"
```

### Task 4: Prepare the first Stable CalVer source identity

**Files:**
- Modify: `Sources/LungfishCore/AppVersion.swift`
- Modify: `Lungfish.xcodeproj/project.pbxproj`
- Modify: `Sources/LungfishApp/Resources/HelpBook/Lungfish.help/Contents/Info.plist`
- Modify: `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json`
- Modify: version expectations located by the repository version-preparation verifier
- Create: `docs/release-notes/<next-version>.md`
- Modify: `docs/release/NEXT-RELEASE-HANDOFF.md` if it exists and names the previous candidate

**Interfaces:**
- Consumes: live remote CalVer ledger, `v0.5.0-beta29..HEAD` diff, notes for 2026.8.1–2026.8.3, and the current dependency manifest/Package.resolved.
- Produces: one harmonized candidate version and complete first-Stable aggregate notes.

- [ ] **Step 1: Fetch and compute the collision-free candidate**

Run read-only remote checks:

```bash
git fetch origin --tags --prune
git ls-remote --tags origin 'refs/tags/v2026.8.*'
gh release list --limit 100 --json tagName,isDraft,isPrerelease,publishedAt
```

Capture 2026-08-20 once. Select one plus the highest August 2026 CalVer patch
across tags or releases. Expect `2026.8.4`; if a collision exists, recompute and
use the resulting version consistently.

- [ ] **Step 2: Update every active version surface**

Use the repository's preparation helpers or targeted patches to update
`LungfishAppVersion.short`, all four Xcode `MARKETING_VERSION` values, Help Book
version, the managed-tools manifest top-level app version, and exact tests. Do
not change dependency set `2026.2`, dependency pins, or
`CURRENT_PROJECT_VERSION=1`.

- [ ] **Step 3: Write aggregate Stable release notes**

Start with exactly:

```text
# Lungfish <version>

Channel: Stable

Previous versioned release: v2026.8.3

Stable baseline: None (bootstrap aggregation baseline: v0.5.0-beta29)

Dependency set: 2026.2
```

Include `## Included preview releases`, list v2026.8.1 and v2026.8.3 with their
status, describe v2026.8.2 separately as an unpublished prep tag, identify this
as a fresh Stable rebuild of the v2026.8.3-tested baseline, explain both app
names and manual channel switching, quote the exact Preview caveat, aggregate
the actual product changes from beta29, and reproduce the complete dependency
identity tables from the current authorities.

- [ ] **Step 4: Verify version and notes consistency**

Run:

```bash
python3 .codex/skills/releasing-lungfish/scripts/validate.py --repo-root "$PWD"
python3 -m unittest scripts.tests.test_nightly_prerelease_release scripts.tests.test_releasing_lungfish_skill scripts.tests.test_sparkle_release_packaging -v
swift test --filter AppVersionTests
swift test --filter ReleaseBuildConfigurationTests
git diff --check
```

Run the prepared-release verifier with the chosen version and previous tag
`v2026.8.3`; require every active version surface and Stable note audit field to
match.

- [ ] **Step 5: Commit Stable release preparation**

```bash
git add Sources Lungfish.xcodeproj Tests docs/release-notes docs/release/NEXT-RELEASE-HANDOFF.md
git commit -m "release: prepare Lungfish <version> stable"
```

### Task 5: Complete local release gates and publish source identity

**Files:**
- Read/verify: repository, test logs, isolated dependency receipt
- Create locally: release verification logs under `build/Release/logs/`

**Interfaces:**
- Consumes: clean committed candidate source from Task 4.
- Produces: pushed `main`, immutable annotated tag, passing Fast gate, and all pre-build evidence.

- [ ] **Step 1: Verify repository scope and cleanliness**

Run `git status --short --branch`, `git worktree list --porcelain`, branch
ancestry checks, `git diff --check`, and `git log --oneline v0.5.0-beta29..HEAD`.
Preserve unrelated work and stop for any dirty or ambiguous release path.

- [ ] **Step 2: Run focused and complete local test suites once**

Run the release Python tests, identity/App tests, and the complete `swift test`
suite with durable logs. Treat any failure as a blocker and diagnose it before
publication; do not repeatedly rerun the complete suite to hide flakes.

- [ ] **Step 3: Verify isolated dependency provenance**

Follow `docs/release/dependency-sweep.md` against the isolated verification
root. Require a nonsynthesized receipt whose app version is the candidate,
dependency set is `2026.2`, canonical manifest hash matches current source, all
required environments are installed with exact pins, and pipeline/micromamba
identities match. Advisory optional updates do not replace these gates.

- [ ] **Step 4: Preflight release credentials and both feed floors**

Verify GitHub auth, Developer ID Team ID `29G3WN2GSA`, notary profile
`LungfishNotary`, Sparkle generator/key access, and selected Stable live appcast.
Also inspect Preview live state to prove it will remain unchanged. Require the
candidate `git rev-list --count HEAD` build number to exceed every relevant
installed/update floor.

- [ ] **Step 5: Push source, recheck collision, tag, and await Fast gate**

Push `main`, then immediately require both `git ls-remote` and
`gh release view` to show no candidate collision. Create an annotated
`v<version>` tag, atomically push `main` and the tag, prove the peeled tag equals
HEAD/origin main, and wait for the resulting push Fast gate to succeed.

### Task 6: Build and publish the first Stable artifact

**Files:**
- Create locally: `build/Release/Lungfish.xcarchive`
- Create locally: `build/Release/Lungfish.app`
- Create locally: `build/Release/Lungfish-<version>-arm64.dmg`
- Create locally: release metadata, notarization logs, and Stable appcast work files
- Mutate remotely: versioned GitHub Stable release and `sparkle-stable` feed container

**Interfaces:**
- Consumes: tagged/pushed source, Developer ID, notary profile, Sparkle signing key, and committed notes.
- Produces: signed/notarized Stable DMG, full GitHub release, and signed Stable appcast item.

- [ ] **Step 1: Resolve signing material without printing secrets**

Resolve the exact valid Developer ID identity from Keychain, set Team ID
`29G3WN2GSA`, verify `LungfishNotary`, locate Sparkle `generate_appcast`, and
capture the public EdDSA key into a shell variable from `generate_keys -p`.
Never print or persist private key material.

- [ ] **Step 2: Run the canonical Stable builder**

Run the committed builder with:

```bash
bash scripts/release/build-notarized-dmg.sh \
  --channel stable \
  --signing-identity "$release_signing_identity" \
  --team-id 29G3WN2GSA \
  --notary-profile LungfishNotary \
  --github-release-tag "v${release_version}" \
  --sparkle-public-ed-key "$sparkle_public_ed_key" \
  --sparkle-generate-appcast "$sparkle_generate_appcast"
```

Do not supply Preview bridge or pruning flags. Do not use an old archive or DMG.
Unset the public-key shell variable after the build command returns.

- [ ] **Step 3: Stop safely on partial publication**

If the build fails before remote mutation, fix source under a new CalVer rather
than moving the tag. If GitHub or Sparkle mutation partially succeeds, inspect
tag/release/asset/feed identities and resume only with the builder's audited
`--recover-existing-release` path and the exact matching local DMG digest.

### Task 7: Independently verify Stable and preserve Preview

**Files:**
- Read/verify: local archive/app/DMG/metadata/notary logs
- Read/verify: GitHub versioned release, `sparkle-stable`, `sparkle-beta`, and automatic CI

**Interfaces:**
- Consumes: Task 6 publication.
- Produces: evidence that the Stable release is installable, correctly branded, channel-isolated, and fully validated.

- [ ] **Step 1: Verify the local artifact and mounted DMG**

Require exact version/build, `CFBundleDisplayName=Lungfish Genome Explorer`,
`CFBundleName=Lungfish`, `LungfishReleaseChannel=stable`, Stable `SUFeedURL`,
44-character public key presence, `Lungfish.app` wrapper,
`com.lungfish.browser`, arm64 main/CLI, portability scans, full smoke tests,
strict codesign, accepted app/DMG notarization, staples, Gatekeeper acceptance,
DMG size, and SHA-256.

- [ ] **Step 2: Verify GitHub and Stable Sparkle publication**

Require annotated tag/local/remote/release target identity; full non-draft,
non-prerelease versioned release; exact release-note bytes; sole DMG asset whose
size/digest match locally; mutable `sparkle-stable` container at the same commit;
and a signed appcast item whose version, monotonically greater build, URL,
length, signature, and notes link all match.

- [ ] **Step 3: Verify Preview isolation**

Re-fetch `sparkle-beta/appcast-beta.xml` and the `v2026.8.3` prerelease. Require
their commit, appcast item, DMG digest, and Preview feed state to remain
unchanged; Stable publication must not move Preview users onto Stable.

- [ ] **Step 4: Wait for automatic Stable CI**

Find the workflow run whose event is `release`/`released` for the Stable tag.
Require the heavy build-smoke and toolset-conformance jobs, plus every required
job on that board, to finish successfully. Never dispatch a workflow manually.

- [ ] **Step 5: Final repository and evidence report**

Require clean `main` synchronized with `origin/main`, preserve unrelated
worktrees/branches, and report channel, URL, version/tag/commit, absolute DMG and
archive/app paths, SHA-256, signing/notarization/staple results, Stable appcast,
unchanged Preview feed, local tests, dependency receipt, automatic CI, and any
retained warnings.
