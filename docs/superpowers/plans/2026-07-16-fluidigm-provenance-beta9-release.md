# Fluidigm Provenance and Beta 9 Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent ONT Fluidigm sample splitting from failing after successful materialization when the source is a FASTQ directory, then publish the GenBank/genotyping-view work and that fix as Lungfish `0.5.0-beta9`.

**Architecture:** The Fluidigm CLI will use canonical directory-aware provenance records for its source directory and directory outputs. This preserves an aggregate checksum and byte size in final bundle provenance; it does not relax the provenance validator. The existing `codex/mhc-genbank-annotations` worktree is the release candidate and already contains `main` at `v0.5.0-beta8`.

**Tech Stack:** Swift 6, XCTest, Xcode, SwiftPM, Sparkle, Apple codesigning/notarytool, GitHub CLI.

---

### Task 1: Reproduce and fix directory provenance

**Files:**
- Modify: `Tests/LungfishCLITests/FastqGenotypingCommandTests.swift:83-116`
- Modify: `Sources/LungfishCLI/Commands/FastqCommand.swift:2729-2812`

- [ ] **Step 1: Write the failing test**

Add `testONTFluidigmSamplesProvenanceDescribesDirectoryInputAndOutputs`. Create a temporary `barcode12/` input directory containing a FASTQ file, a barcode CSV, an output directory, and a `.lungfishfastq` child. Call the Fluidigm provenance-record factory and assert each directory descriptor has checksum and size evidence:

```swift
let inputDirectoryRecord = try XCTUnwrap(records.inputs.first { $0.path == inputDirectory.path })
let outputDirectoryRecord = try XCTUnwrap(records.outputs.first { $0.path == outputDirectory.path })
XCTAssertNotNil(inputDirectoryRecord.sha256)
XCTAssertGreaterThan(inputDirectoryRecord.sizeBytes ?? 0, 0)
XCTAssertNotNil(outputDirectoryRecord.sha256)
XCTAssertGreaterThan(outputDirectoryRecord.sizeBytes ?? 0, 0)
```

- [ ] **Step 2: Run the test red**

Run:

```bash
swift test --filter FastqGenotypingCommandTests/testONTFluidigmSamplesProvenanceDescribesDirectoryInputAndOutputs
```

Expected: compile failure because the Fluidigm provenance factory does not yet exist.

- [ ] **Step 3: Implement the minimum production change**

Replace the inline Fluidigm provenance lists and checksum-less `directoryOutputRecord` with this static factory:

```swift
static func provenanceRecords(
    inputURL: URL,
    barcodeURL: URL,
    outputDirectory: URL,
    manifestURL: URL,
    outputBundleURLs: [URL],
    outputPayloads: [URL]
) -> (inputs: [FileRecord], outputs: [FileRecord]) {
    let inputs = [
        ProvenanceRecorder.fileOrDirectoryRecord(url: inputURL, format: .fastq, role: .input),
        ProvenanceRecorder.fileRecord(url: barcodeURL, format: .text, role: .input),
    ]
    let outputs = [
        ProvenanceRecorder.fileOrDirectoryRecord(url: outputDirectory, format: .unknown, role: .output),
        ProvenanceRecorder.fileRecord(url: manifestURL, format: .json, role: .output),
    ] + outputBundleURLs.map {
        ProvenanceRecorder.fileOrDirectoryRecord(url: $0, format: .unknown, role: .output)
    } + outputPayloads.map {
        ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .output)
    }
    return (inputs, outputs)
}
```

Use the factory immediately before `CLIProvenanceSupport.recordSingleStepRun`.

- [ ] **Step 4: Run the test green and related suites**

Run:

```bash
swift test --filter FastqGenotypingCommandTests/testONTFluidigmSamplesProvenanceDescribesDirectoryInputAndOutputs
swift test --filter FastqGenotypingCommandTests
swift test --filter ONTFluidigmSampleMaterializerTests
```

Expected: all selected tests pass.

- [ ] **Step 5: Commit the fix**

```bash
git add Sources/LungfishCLI/Commands/FastqCommand.swift Tests/LungfishCLITests/FastqGenotypingCommandTests.swift
git commit -m "fix: record Fluidigm directory provenance"
```

### Task 2: Prepare beta 9 source and notes

**Files:**
- Modify: `Lungfish.xcodeproj/project.pbxproj:414,442,508,530`
- Modify: `Sources/LungfishApp/Resources/HelpBook/Lungfish.help/Contents/Info.plist:16`
- Create: `docs/release-notes/v0.5.0-beta9.md`

- [ ] **Step 1: Update active version identifiers**

Change every active `0.5.0-beta8` version to `0.5.0-beta9`. Retain beta8 only as `Previous release: v0.5.0-beta8` in the new notes.

- [ ] **Step 2: Write factual release notes**

Cover annotated GenBank MHC reference import/recovery; GenBank fields, filters, and annotations; selectable GenBank matrix columns; genotype-only Summary/list-over-detail selection details; matrix scrolling stability; and the Fluidigm directory-provenance fix.

- [ ] **Step 3: Verify release source**

Run:

```bash
rg -n "0\\.5\\.0-beta8" Lungfish.xcodeproj/project.pbxproj Sources/LungfishApp/Resources/HelpBook/Lungfish.help/Contents/Info.plist docs/release-notes/v0.5.0-beta9.md
git diff --check
swift test --filter ReleaseBuildConfigurationTests
```

Expected: beta8 appears only as historical release context; whitespace and release tests pass.

- [ ] **Step 4: Commit release preparation**

```bash
git add Lungfish.xcodeproj/project.pbxproj Sources/LungfishApp/Resources/HelpBook/Lungfish.help/Contents/Info.plist docs/release-notes/v0.5.0-beta9.md
git commit -m "release: 0.5.0-beta9"
```

### Task 3: Verify the integrated release candidate

**Files:** Verify only.

- [ ] **Step 1: Run feature and provenance regression suites**

```bash
swift test --filter FastqGenotypingCommandTests
swift test --filter ONTFluidigmSampleMaterializerTests
swift test --filter GenotypeResultDisplaySectionTests
swift test --filter GenotypeReferenceRecordStoreSnapshotTests
swift test --filter FullLengthONTMHCGenotypingPipelineTests
```

Expected: every selected suite exits zero.

- [ ] **Step 2: Compile Release**

```bash
xcodebuild -project Lungfish.xcodeproj -scheme Lungfish -configuration Release -destination 'platform=macOS' build
```

Expected: `** BUILD SUCCEEDED **`.

### Task 4: Tag, package, notarize, and publish beta 9

**Files:**
- Generated: `build/Release/Lungfish.xcarchive`
- Generated: `build/Release/Lungfish.app`
- Generated: `build/Release/Lungfish-0.5.0-beta9-arm64.dmg`
- Generated: `build/Release/release-metadata.txt`
- Generated: `build/Release/sparkle-appcast/appcast-beta.xml`

- [ ] **Step 1: Push and tag the exact release commit**

```bash
git push origin codex/mhc-genbank-annotations
git tag -a v0.5.0-beta9 -m "Lungfish v0.5.0-beta9"
git push origin v0.5.0-beta9
git describe --tags --exact-match HEAD
```

Expected: the final command prints `v0.5.0-beta9`.

- [ ] **Step 2: Preflight credentials without exposing secrets**

Resolve installed Developer ID identity, matching team ID, usable notarytool profile, Sparkle `generate_appcast`, and private EdDSA key from the release environment. Stop and report the exact missing prerequisite if any is unavailable.

- [ ] **Step 3: Run the established release pipeline**

Run `scripts/release/build-notarized-dmg.sh` with the resolved signing/notary/Sparkle inputs, `--github-release-tag v0.5.0-beta9`, `--sparkle-publish-release sparkle-beta`, and `--sparkle-bridge-publish-release sparkle-alpha`.

- [ ] **Step 4: Independently verify artifacts and publication**

```bash
codesign --verify --deep --strict --verbose=2 build/Release/Lungfish.app
xcrun stapler validate build/Release/Lungfish.app
xcrun stapler validate build/Release/Lungfish-0.5.0-beta9-arm64.dmg
scripts/smoke-test-release-tools.sh build/Release/Lungfish.app
gh release view v0.5.0-beta9 --json tagName,name,isPrerelease,assets,url
gh release view sparkle-beta --json tagName,assets,url
```

Expected: signatures/staples validate, smoke tests pass, the prerelease includes the DMG, and the beta feed contains `appcast-beta.xml`.

- [ ] **Step 5: Report evidence**

Read `build/Release/release-metadata.txt` and report the release URL, tag/commit, artifact paths, SHA-256, notarization results, Sparkle status, and final Git state.
