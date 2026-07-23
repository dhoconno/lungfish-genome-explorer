# Full-Length MHC BAM Inspector Artifacts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose the validated full-length MHC genotyping and reciprocal BAM/BAI pairs in both Lungfish artifact lists without loading alignment contents.

**Architecture:** Extend the LungfishIO candidate-artifact projection with a small immutable URL value type populated only after the existing manifest integrity checks succeed. Pass that projection through `ONTGenotypeResultBundleData`, then render the four optional URLs with the existing Inspector and viewport artifact-row components.

**Tech Stack:** Swift 6, AppKit/SwiftUI, XCTest, Swift Package Manager, macOS application build scripts.

---

## File Map

- Modify `Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift`: define the validated alignment URL projection and populate it at the bundle-loader integrity boundary.
- Modify `Sources/LungfishApp/Views/Inspector/InspectorViewController+PublicAPI.swift`: append validated BAM/BAI rows to the document Inspector.
- Modify `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`: append the same rows to the viewport Artifacts lens.
- Modify `Tests/LungfishIOTests/ONTGenotypeResultBundleTests.swift`: prove valid manifests expose URLs and invalid manifests withhold them.
- Modify `Tests/LungfishAppTests/GenotypeSampleMetadataImportTests.swift`: prove Inspector artifact rows include all four files and omit absent files.
- Modify `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`: prove the viewport lens includes all four files and omits absent files.

### Task 1: Add the validated alignment URL projection

**Files:**
- Modify: `Tests/LungfishIOTests/ONTGenotypeResultBundleTests.swift`
- Modify: `Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift`

- [ ] **Step 1: Add a failing valid-manifest assertion**

In the existing candidate-artifact bundle-loading test whose fixture declares
`genotyping-evidence.bam(.bai)` and `unmatched-to-reference.bam(.bai)`, assert:

```swift
XCTAssertEqual(
    result.mhcAlignmentArtifactURLs.genotypingBAM,
    bundleURL.appendingPathComponent("artifacts/alignments/genotyping-evidence.bam").standardizedFileURL
)
XCTAssertEqual(
    result.mhcAlignmentArtifactURLs.genotypingBAI,
    bundleURL.appendingPathComponent("artifacts/alignments/genotyping-evidence.bam.bai").standardizedFileURL
)
XCTAssertEqual(
    result.mhcAlignmentArtifactURLs.reciprocalBAM,
    bundleURL.appendingPathComponent("artifacts/alignments/unmatched-to-reference.bam").standardizedFileURL
)
XCTAssertEqual(
    result.mhcAlignmentArtifactURLs.reciprocalBAI,
    bundleURL.appendingPathComponent("artifacts/alignments/unmatched-to-reference.bam.bai").standardizedFileURL
)
```

In an existing checksum-failure test, also assert:

```swift
XCTAssertEqual(result.mhcAlignmentArtifactURLs, .empty)
```

- [ ] **Step 2: Run the focused loader tests and confirm they fail**

Run:

```bash
swift test --filter ONTGenotypeResultBundleTests
```

Expected: compilation fails because `mhcAlignmentArtifactURLs` is not defined.

- [ ] **Step 3: Implement the minimal URL projection**

Add the public value type:

```swift
public struct ONTMHCAlignmentArtifactURLs: Codable, Equatable, Sendable {
    public static let empty = ONTMHCAlignmentArtifactURLs(
        genotypingBAM: nil,
        genotypingBAI: nil,
        reciprocalBAM: nil,
        reciprocalBAI: nil
    )

    public let genotypingBAM: URL?
    public let genotypingBAI: URL?
    public let reciprocalBAM: URL?
    public let reciprocalBAI: URL?

    public init(
        genotypingBAM: URL?,
        genotypingBAI: URL?,
        reciprocalBAM: URL?,
        reciprocalBAI: URL?
    ) {
        self.genotypingBAM = genotypingBAM?.standardizedFileURL
        self.genotypingBAI = genotypingBAI?.standardizedFileURL
        self.reciprocalBAM = reciprocalBAM?.standardizedFileURL
        self.reciprocalBAI = reciprocalBAI?.standardizedFileURL
    }
}
```

Add `mhcAlignmentArtifactURLs` to `ONTGenotypeResultBundleData`, with `.empty`
as the default for source and decoding compatibility. Carry it through
`MHCCandidateProjection`. After the existing BAM/BAI checksum loop succeeds,
resolve the four declared references with `normalizedValidatedArtifactURL` and
return them in the projection. Every absent or caught-integrity-failure
projection returns `.empty`.

- [ ] **Step 4: Run the focused loader tests and confirm they pass**

Run:

```bash
swift test --filter ONTGenotypeResultBundleTests
```

Expected: all selected tests pass.

- [ ] **Step 5: Commit the loader projection**

```bash
git add Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift \
  Tests/LungfishIOTests/ONTGenotypeResultBundleTests.swift
git commit -m "feat: expose validated MHC alignment artifacts"
```

### Task 2: Render BAM/BAI rows in both artifact surfaces

**Files:**
- Modify: `Tests/LungfishAppTests/GenotypeSampleMetadataImportTests.swift`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController+PublicAPI.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`

- [ ] **Step 1: Add failing Inspector and viewport regression tests**

Construct `ONTMHCAlignmentArtifactURLs` with four bundle-relative resolved URLs.
Pass it through the existing result fixture helpers and assert the Inspector rows
and viewport text contain:

```swift
[
    "Genotyping Evidence BAM",
    "Genotyping Evidence BAI",
    "Reciprocal Evidence BAM",
    "Reciprocal Evidence BAI",
]
```

Also extend the existing absent-artifact tests to assert none of those labels is
present when the projection is `.empty`.

- [ ] **Step 2: Run focused UI tests and confirm they fail**

Run:

```bash
swift test --filter GenotypeSampleMetadataImportTests
swift test --filter GenotypeResultViewportTests
```

Expected: the new row/text assertions fail because neither artifact builder
renders the projected URLs.

- [ ] **Step 3: Add the four optional rows to both builders**

In `updateGenotypeResultDocument(_:)`, append optional
`GenotypeResultArtifactRow` values using `result.mhcAlignmentArtifactURLs`.
In `rebuildArtifactLens()`, append matching `artifactRow(label:url:)` values.
Use the exact labels from Step 1 and do not open or parse any alignment file.

- [ ] **Step 4: Run focused UI tests and confirm they pass**

Run:

```bash
swift test --filter GenotypeSampleMetadataImportTests
swift test --filter GenotypeResultViewportTests
```

Expected: all selected tests pass.

- [ ] **Step 5: Commit the artifact surfaces**

```bash
git add Sources/LungfishApp/Views/Inspector/InspectorViewController+PublicAPI.swift \
  Sources/LungfishGenotypeUI/GenotypeResultViewController.swift \
  Tests/LungfishAppTests/GenotypeSampleMetadataImportTests.swift \
  Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
git commit -m "feat: show MHC BAM artifacts in Inspector"
```

### Task 3: Verify and publish the debug build

**Files:**
- No source changes expected.

- [ ] **Step 1: Run formatting and repository checks**

Run:

```bash
git diff --check
git status --short
```

Expected: no whitespace errors and only intentional changes, if any.

- [ ] **Step 2: Run the relevant module suites**

Run:

```bash
swift test --filter 'LungfishIOTests|LungfishAppTests|LungfishGenotypeUITests'
```

Expected: all selected tests pass with zero failures.

- [ ] **Step 3: Build Lungfish Debug**

Run:

```bash
./scripts/build-app.sh --configuration debug --log-dir build/logs
```

Expected: build succeeds and creates `build/Debug/Lungfish.app`.

- [ ] **Step 4: Verify identity and signature**

Run:

```bash
/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' build/Debug/Lungfish.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' build/Debug/Lungfish.app/Contents/Info.plist
codesign --verify --deep --strict build/Debug/Lungfish.app
```

Expected: display name is `Lungfish Debug`, identifier is
`com.lungfish.browser.debug`, and signature verification succeeds.

- [ ] **Step 5: Relaunch only the verified debug app**

Quit existing Lungfish processes, launch the exact worktree build, and open:

```text
/Volumes/iWES_WNPRC/32355/32355.lungfish/Analyses/Full-length ONT MHC genotyping results/2026-07-22-structural-ext-debug-v4.lungfishgenotype
```

Verify one Lungfish process is running from the worktree debug app and that the
Inspector lists both BAM/BAI pairs without selecting or parsing an allele-detail
alignment.
