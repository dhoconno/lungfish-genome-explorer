# Notarized Release Strategy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reproducible Apple Silicon Lungfish release pipeline that signs, notarizes, and packages the app plus embedded CLI into a distributable DMG.

**Architecture:** Keep the Xcode archive as the canonical GUI artifact, embed `lungfish-cli` into the archived app, verify the packaged native tools, notarize the app, then create and notarize a signed DMG. Persist all outputs under `build/Release` with a metadata manifest for repeatability.

**Tech Stack:** Xcode build system, SwiftPM, POSIX shell, `codesign`, `xcrun notarytool`, `stapler`, `hdiutil`, Swift Testing.

---

## File Map

- Create: `scripts/release/build-notarized-dmg.sh`
  Responsibility: perform the clean archive, CLI embedding, signing, notarization, DMG creation, and metadata capture.
- Modify: `Tests/LungfishAppTests/ReleaseBuildConfigurationTests.swift`
  Responsibility: lock in the release script and agent requirements.
- Modify: `.codex/agents/release-agent.md`
  Responsibility: teach future agents the exact release workflow.
- Create: `docs/superpowers/specs/2026-04-14-notarized-release-strategy-design.md`
  Responsibility: design record.
- Create: `docs/superpowers/plans/2026-04-14-notarized-release-strategy.md`
  Responsibility: implementation handoff.

## Task 1: Lock The Pipeline In Tests

**Files:**
- Modify: `Tests/LungfishAppTests/ReleaseBuildConfigurationTests.swift`

- [ ] **Step 1: Add a failing test for the notarized DMG release script**

```swift
@Test("Notarized DMG release script archives signs notarizes and staples")
func notarizedDMGReleaseScriptArchivesSignsNotarizesAndStaples() throws {
    let script = try String(
        contentsOf: Self.repositoryRoot()
            .appendingPathComponent("scripts/release/build-notarized-dmg.sh"),
        encoding: .utf8
    )

    #expect(script.contains("xcodebuild -project Lungfish.xcodeproj"))
    #expect(script.contains("--product lungfish-cli"))
    #expect(script.contains("Contents/MacOS/lungfish-cli"))
    #expect(script.contains("notarytool submit"))
    #expect(script.contains("stapler staple"))
    #expect(script.contains("hdiutil create"))
}
```

- [ ] **Step 2: Add a failing test for the repo release agent**

```swift
@Test("Release agent is tracked in repo")
func releaseAgentIsTrackedInRepo() throws {
    let agent = try String(
        contentsOf: Self.repositoryRoot()
            .appendingPathComponent(".codex/agents/release-agent.md"),
        encoding: .utf8
    )

    #expect(agent.contains("scripts/release/build-notarized-dmg.sh"))
    #expect(agent.contains("notarytool"))
    #expect(agent.contains(".dmg"))
}
```

- [ ] **Step 3: Run the targeted tests and confirm failure before implementation**

Run: `swift test --filter ReleaseBuildConfigurationTests`
Expected: FAIL because `scripts/release/build-notarized-dmg.sh` does not exist and the release agent still references the older export flow.

## Task 2: Implement The Release Script

**Files:**
- Create: `scripts/release/build-notarized-dmg.sh`

- [ ] **Step 1: Create the release script with explicit inputs**

```bash
#!/bin/bash
set -euo pipefail

# Parse:
# --signing-identity
# --team-id
# --notary-profile
```

- [ ] **Step 2: Archive the app and build the CLI**

```bash
xcodebuild -project Lungfish.xcodeproj \
  -scheme Lungfish \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE_PATH" \
  ARCHS=arm64 \
  EXCLUDED_ARCHS=x86_64 \
  ONLY_ACTIVE_ARCH=YES \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  archive

xcrun swift build \
  --package-path "$PROJECT_ROOT" \
  --product lungfish-cli \
  --configuration release \
  --arch arm64 \
  --scratch-path "$SCRATCH_PATH"
```

- [ ] **Step 3: Embed, sign, notarize, and staple**

```bash
install -m 755 "$CLI_SOURCE" "$CLI_DEST"
codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp \
  --entitlements "${PROJECT_ROOT}/lungfish-cli.entitlements" "$CLI_DEST"
codesign --force --deep --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
scripts/smoke-test-release-tools.sh "$APP_PATH"
xcrun notarytool submit "$APP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_PATH"
```

- [ ] **Step 4: Build, sign, notarize, and staple the DMG**

```bash
hdiutil create -volname "Lungfish" -srcfolder "$DMG_STAGING_DIR" -format UDZO "$DMG_PATH"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"
```

- [ ] **Step 5: Write metadata**

```bash
cat >"$METADATA_PATH" <<EOF
version=${VERSION}
git_commit=${COMMIT_SHA}
DMG_PATH=${DMG_PATH}
dmg_sha256=${DMG_SHA}
EOF
```

## Task 3: Update The Repo Agent

**Files:**
- Modify: `.codex/agents/release-agent.md`

- [ ] **Step 1: Replace the export-only workflow with the new release script**

```markdown
Run:
`scripts/release/build-notarized-dmg.sh --signing-identity ... --team-id ... --notary-profile ...`
```

- [ ] **Step 2: Require reporting of the archive app, stapled app, final DMG, and metadata file**

```markdown
- Include absolute paths for:
  - the archived app
  - the copied release app
  - the final DMG
  - `build/Release/release-metadata.txt`
```

## Task 4: Verify The Pipeline

**Files:**
- No source edits required unless verification fails

- [ ] **Step 1: Re-run the release configuration tests**

Run: `swift test --filter ReleaseBuildConfigurationTests`
Expected: PASS

- [ ] **Step 2: Attempt the real release build**

Run:
`scripts/release/build-notarized-dmg.sh --signing-identity "Developer ID Application: <name> (<team>)" --team-id <team> --notary-profile <profile>`

Expected:
- archive succeeds
- bundled tool smoke test succeeds
- app notarization succeeds
- DMG notarization succeeds
- final artifact exists at `build/Release/Lungfish-<version>-arm64.dmg`

- [ ] **Step 3: Record actual blockers if signing or notarization cannot complete**

Run:
`codesign --verify --deep --strict --verbose=2 build/Release/Lungfish.xcarchive/Products/Applications/Lungfish.app`

Expected:
- either a clean verification result or a precise blocker to report
