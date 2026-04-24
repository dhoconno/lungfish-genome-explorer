# BAM Primer Trim and `.lungfishprimers` Bundles — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a first-class BAM primer-trim operation (invoking `ivar trim`) that emits a sorted, indexed, provenance-tagged BAM, plus a new `.lungfishprimers` bundle type that treats a primer scheme as a first-class citizen of the project, including one canonical built-in bundle (`QIASeqDIRECT-SARS2.lungfishprimers`) shipped as both a user-visible asset and a test fixture.

**Architecture:** Primer scheme bundles are folder-bundles living in a new project-level `Primer Schemes/` folder, with a manifest declaring canonical and equivalent reference accessions. A `PrimerSchemeResolver` resolves a bundle's BED to a BAM's reference name at runtime, rewriting column 1 when an equivalent accession is used. The new BAM primer-trim operation is surfaced as a button in the BAM Inspector's Analysis section (sibling to "Call Variants…"), opening a dialog that mirrors `BAMVariantCallingDialog`'s four-file split. The existing variant calling dialog is upgraded to auto-confirm the iVar primer-trim checkbox when the selected BAM's provenance records a Lungfish-run trim.

**Tech Stack:** Swift 6.2, SPM, SwiftUI, Observation, `NativeToolRunner` actor, XCTest, XCUITest.

**Spec:** `docs/superpowers/specs/2026-04-24-bam-primer-trim-and-primer-scheme-bundles-design.md`

---

## Preconditions

- Spec 1 (repo rename) has merged to `main`. This plan assumes the working copy is at `/Users/dho/Documents/lungfish-genome-explorer`.
- Track 1 runs in a worktree: `.worktrees/track1-bam-primer-trim` off `main`.
- `swift build` and `swift test` both pass from the worktree before starting.

## Worktree smoke-test gate

Before beginning implementation, verify the JRE-dylib-in-worktree regression is actually fixed. If it is not, escalate before proceeding.

- [ ] **Step 1: Create the worktree**

```bash
cd /Users/dho/Documents/lungfish-genome-explorer
git worktree add .worktrees/track1-bam-primer-trim -b track1-bam-primer-trim main
```

- [ ] **Step 2: Verify `swift build` works in the worktree**

```bash
cd .worktrees/track1-bam-primer-trim
swift build 2>&1 | tail -3
```
Expected: `Build complete!`.

- [ ] **Step 3: Verify that launching a Java-backed tool from the worktree succeeds**

Not required for this plan's work (no task runs Java tools), but if the user expects to use this worktree to also launch the app, run a quick check:

```bash
find . -name "*.dylib" -path "*JRE*" 2>/dev/null | head -3
```
Expected: at least one JRE dylib listed. If empty, the worktree dylib restriction still applies; report back to the user rather than silently working around it.

No commit. Move on.

---

## File Structure

### New files in `Sources/LungfishIO/Bundles/`

- `PrimerSchemeBundle.swift` — `PrimerSchemeBundle` struct, manifest type, loading and validation.
- `PrimerSchemesFolder.swift` — `PrimerSchemesFolder` enum (parallel to `ReferenceSequenceFolder`), manages the project's `Primer Schemes/` folder.

### New files in `Sources/LungfishWorkflow/Primers/`

- `PrimerSchemeResolver.swift` — resolves a bundle's BED against a BAM reference name, returns the BED URL (rewritten to a temp file when an equivalent accession is used).
- `BAMPrimerTrimRequest.swift` — request struct for the trim operation (inputs).
- `BAMPrimerTrimResult.swift` — result struct (output BAM URL, provenance).
- `BAMPrimerTrimPipeline.swift` — runs `ivar trim` + `samtools sort` + `samtools index`, writes provenance sidecar.
- `BAMPrimerTrimProvenance.swift` — provenance record struct, encoder.

### New files in `Sources/LungfishApp/Views/BAM/`

- `BAMPrimerTrimDialog.swift` — SwiftUI dialog view.
- `BAMPrimerTrimDialogState.swift` — `@Observable @MainActor` state model.
- `BAMPrimerTrimDialogPresenter.swift` — presents the dialog as a sheet.
- `BAMPrimerTrimToolPanes.swift` — inner pane views.
- `BAMPrimerTrimCatalog.swift` — pack-gated picker-item catalog (parallel to `BAMVariantCallingCatalog`).
- `PrimerSchemePickerView.swift` — picker that lists built-in + project-local + filesystem schemes.

### New files in `Sources/LungfishApp/Views/ImportCenter/`

- `PrimerSchemeImportView.swift` — UI for importing a primer scheme.
- `PrimerSchemeImportViewModel.swift` — logic for BED + optional FASTA + attachments → bundle.

### New files in `Sources/LungfishApp/Services/`

- `BuiltInPrimerSchemeService.swift` — enumerates built-in bundles under `Resources/PrimerSchemes/`.

### New shipped asset

- `Resources/PrimerSchemes/QIASeqDIRECT-SARS2.lungfishprimers/` — the canonical built-in bundle (folder with `manifest.json`, `primers.bed`, `primers.fasta`, `PROVENANCE.md`).

### New supporting scripts

- `scripts/build-primer-bundle.swift` — one-shot CLI tool to build a `.lungfishprimers` bundle from a BED + optional FASTA + reference accessions; used to build the QIASeq canonical bundle.

### Modified files

- `Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift` — add `primerTrimSection` and `onPrimerTrimRequested` callback.
- `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift` — wire the callback to `BAMPrimerTrimDialogPresenter`.
- `Sources/LungfishWorkflow/Native/NativeToolRunner.swift` — if the runner needs a `trim` subcommand path distinct from `variants`, add it; otherwise, argv handles it transparently.
- `Sources/LungfishApp/Views/BAM/BAMVariantCallingDialogState.swift` — read provenance to auto-confirm `ivarPrimerTrimConfirmed`.
- `Sources/LungfishApp/Views/BAM/BAMVariantCallingToolPanes.swift` — render the auto-confirmed state with caption.
- `Sources/LungfishIO/Bundles/...` — wherever the project-folder creation logic lives, add `Primer Schemes/` to the created folders.
- `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift` — add the `Primer Schemes/` group.
- `Package.swift` — register `Resources/PrimerSchemes/` as an app resource.

### New test files

- `Tests/LungfishIOTests/Bundles/PrimerSchemeBundleTests.swift`
- `Tests/LungfishWorkflowTests/Primers/PrimerSchemeResolverTests.swift`
- `Tests/LungfishWorkflowTests/Primers/BAMPrimerTrimPipelineTests.swift`
- `Tests/LungfishAppTests/PrimerTrim/BAMPrimerTrimDialogStateTests.swift`
- `Tests/LungfishAppTests/PrimerTrim/BAMPrimerTrimCatalogTests.swift`
- `Tests/LungfishAppTests/PrimerTrim/BAMVariantCallingAutoConfirmTests.swift`
- `Tests/LungfishIntegrationTests/PrimerTrim/PrimerTrimIntegrationTests.swift`
- `Tests/LungfishIntegrationTests/PrimerTrim/PrimerTrimThenIVarTests.swift`
- `Tests/LungfishIntegrationTests/PrimerTrim/PrimerSchemeEquivalentAccessionTests.swift`
- `Tests/LungfishXCUITests/PrimerTrim/PrimerTrimXCUITests.swift`
- `Tests/LungfishXCUITests/PrimerTrim/VariantCallingAutoConfirmXCUITests.swift`
- `Tests/Fixtures/primerschemes/QIASeqDIRECT-SARS2.lungfishprimers/` — symlinked to `Resources/PrimerSchemes/QIASeqDIRECT-SARS2.lungfishprimers/` (or a copy if SPM requires it).

---

## Task 1: Bundle manifest type and loader

**Files:**
- Create: `Sources/LungfishIO/Bundles/PrimerSchemeBundle.swift`
- Test: `Tests/LungfishIOTests/Bundles/PrimerSchemeBundleTests.swift`
- Test resource: `Tests/LungfishIOTests/Resources/primerschemes/valid-simple.lungfishprimers/` (fixture, authored by hand)

- [ ] **Step 1: Write the failing test**

Create `Tests/LungfishIOTests/Bundles/PrimerSchemeBundleTests.swift`:

```swift
import XCTest
@testable import LungfishIO

final class PrimerSchemeBundleTests: XCTestCase {
    func testLoadValidBundleReturnsManifestWithCanonicalAndEquivalentAccessions() throws {
        let bundleURL = Bundle.module.url(
            forResource: "primerschemes/valid-simple.lungfishprimers",
            withExtension: nil
        )!

        let bundle = try PrimerSchemeBundle.load(from: bundleURL)

        XCTAssertEqual(bundle.manifest.name, "test-simple")
        XCTAssertEqual(bundle.manifest.displayName, "Test Simple Primer Set")
        XCTAssertEqual(bundle.manifest.canonicalAccession, "MN908947.3")
        XCTAssertEqual(bundle.manifest.equivalentAccessions, ["NC_045512.2"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.bedURL.path))
    }
}
```

Author the fixture at `Tests/LungfishIOTests/Resources/primerschemes/valid-simple.lungfishprimers/`:

`manifest.json`:
```json
{
  "schema_version": 1,
  "name": "test-simple",
  "display_name": "Test Simple Primer Set",
  "description": "Minimal fixture for PrimerSchemeBundle tests.",
  "reference_accessions": [
    { "accession": "MN908947.3", "canonical": true },
    { "accession": "NC_045512.2", "equivalent": true }
  ],
  "primer_count": 2,
  "amplicon_count": 1,
  "source": "test-fixture",
  "version": "0.1.0",
  "created": "2026-04-24T00:00:00Z"
}
```

`primers.bed`:
```
MN908947.3	30	54	test_amp_1_LEFT	60	+
MN908947.3	410	434	test_amp_1_RIGHT	60	-
```

`primers.fasta`:
```
>test_amp_1_LEFT
ACCTTCCCAGGTAACAAACCAACC
>test_amp_1_RIGHT
TAGGTAATAAACACCACGTGTTGG
```

`PROVENANCE.md`:
```markdown
# PROVENANCE

Test fixture. Not a real primer panel.
```

- [ ] **Step 2: Run test and confirm it fails (file doesn't exist)**

```bash
cd .worktrees/track1-bam-primer-trim
swift test --filter PrimerSchemeBundleTests
```
Expected: compilation error, `PrimerSchemeBundle` not found.

- [ ] **Step 3: Write `PrimerSchemeBundle.swift`**

```swift
import Foundation

public struct PrimerSchemeManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let name: String
    public let displayName: String
    public let description: String?
    public let organism: String?
    public let referenceAccessions: [ReferenceAccession]
    public let primerCount: Int
    public let ampliconCount: Int
    public let source: String?
    public let sourceURL: String?
    public let version: String?
    public let created: Date?
    public let imported: Date?
    public let attachments: [AttachmentEntry]?

    public var canonicalAccession: String {
        referenceAccessions.first(where: \.canonical)?.accession
            ?? referenceAccessions.first?.accession
            ?? ""
    }

    public var equivalentAccessions: [String] {
        referenceAccessions.filter { !$0.canonical }.map(\.accession)
    }

    public struct ReferenceAccession: Codable, Sendable, Equatable {
        public let accession: String
        public var canonical: Bool = false
        public var equivalent: Bool = false
    }

    public struct AttachmentEntry: Codable, Sendable, Equatable {
        public let path: String
        public let description: String?
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case name
        case displayName = "display_name"
        case description
        case organism
        case referenceAccessions = "reference_accessions"
        case primerCount = "primer_count"
        case ampliconCount = "amplicon_count"
        case source
        case sourceURL = "source_url"
        case version
        case created
        case imported
        case attachments
    }
}

public struct PrimerSchemeBundle: Sendable {
    public let url: URL
    public let manifest: PrimerSchemeManifest
    public let bedURL: URL
    public let fastaURL: URL?
    public let provenanceURL: URL

    public enum LoadError: Error, LocalizedError {
        case missingManifest
        case missingBED
        case missingProvenance
        case invalidManifest(underlying: Error)

        public var errorDescription: String? {
            switch self {
            case .missingManifest: return "Bundle is missing manifest.json."
            case .missingBED: return "Bundle is missing primers.bed."
            case .missingProvenance: return "Bundle is missing PROVENANCE.md."
            case .invalidManifest(let underlying):
                return "manifest.json is invalid: \(underlying.localizedDescription)"
            }
        }
    }

    public static func load(from url: URL) throws -> PrimerSchemeBundle {
        let fm = FileManager.default
        let manifestURL = url.appendingPathComponent("manifest.json")
        let bedURL = url.appendingPathComponent("primers.bed")
        let fastaURL = url.appendingPathComponent("primers.fasta")
        let provenanceURL = url.appendingPathComponent("PROVENANCE.md")

        guard fm.fileExists(atPath: manifestURL.path) else { throw LoadError.missingManifest }
        guard fm.fileExists(atPath: bedURL.path) else { throw LoadError.missingBED }
        guard fm.fileExists(atPath: provenanceURL.path) else { throw LoadError.missingProvenance }

        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest: PrimerSchemeManifest
        do {
            manifest = try decoder.decode(PrimerSchemeManifest.self, from: data)
        } catch {
            throw LoadError.invalidManifest(underlying: error)
        }

        return PrimerSchemeBundle(
            url: url,
            manifest: manifest,
            bedURL: bedURL,
            fastaURL: fm.fileExists(atPath: fastaURL.path) ? fastaURL : nil,
            provenanceURL: provenanceURL
        )
    }
}
```

- [ ] **Step 4: Register test resources**

Confirm `Package.swift` already has `.copy("Resources")` for `LungfishIOTests`. If so, nothing to change. If not, add it.

- [ ] **Step 5: Run test and confirm it passes**

```bash
swift test --filter PrimerSchemeBundleTests
```
Expected: PASS.

- [ ] **Step 6: Add tests for each failure mode**

Extend `PrimerSchemeBundleTests.swift` with three more tests:

```swift
func testLoadBundleMissingManifestThrows() {
    let tmp = try! TestWorkspace.makeEmptyBundle(name: "no-manifest.lungfishprimers")
    XCTAssertThrowsError(try PrimerSchemeBundle.load(from: tmp)) { error in
        guard case PrimerSchemeBundle.LoadError.missingManifest = error else {
            XCTFail("wrong error: \(error)"); return
        }
    }
}

func testLoadBundleMissingBEDThrows() {
    let tmp = try! TestWorkspace.makeBundleWithOnlyManifest()
    XCTAssertThrowsError(try PrimerSchemeBundle.load(from: tmp)) { error in
        guard case PrimerSchemeBundle.LoadError.missingBED = error else {
            XCTFail("wrong error: \(error)"); return
        }
    }
}

func testLoadBundleWithMalformedManifestThrows() {
    let tmp = try! TestWorkspace.makeBundleWithMalformedManifest()
    XCTAssertThrowsError(try PrimerSchemeBundle.load(from: tmp)) { error in
        guard case PrimerSchemeBundle.LoadError.invalidManifest = error else {
            XCTFail("wrong error: \(error)"); return
        }
    }
}
```

Create `Tests/LungfishIOTests/Support/TestWorkspace.swift` with the helper factory functions (small, self-contained).

- [ ] **Step 7: Run all PrimerSchemeBundleTests and confirm PASS**

```bash
swift test --filter PrimerSchemeBundleTests
```
Expected: all 4 tests PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/LungfishIO/Bundles/PrimerSchemeBundle.swift Tests/LungfishIOTests/Bundles/PrimerSchemeBundleTests.swift Tests/LungfishIOTests/Resources/primerschemes Tests/LungfishIOTests/Support/TestWorkspace.swift
git commit -m "$(cat <<'EOF'
feat(io): add PrimerSchemeBundle with manifest loader

Introduces the .lungfishprimers bundle type with a structured manifest that declares canonical and equivalent reference accessions. Bundle loading validates required files and returns a typed value with URLs for BED, optional FASTA, and provenance.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: PrimerSchemesFolder — project-level folder management

**Files:**
- Create: `Sources/LungfishIO/Bundles/PrimerSchemesFolder.swift`
- Test: `Tests/LungfishIOTests/Bundles/PrimerSchemesFolderTests.swift`

Parallels `ReferenceSequenceFolder.swift`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LungfishIO

final class PrimerSchemesFolderTests: XCTestCase {
    func testEnsureFolderCreatesPrimerSchemesDirectory() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let url = try PrimerSchemesFolder.ensureFolder(in: tmp)
        XCTAssertEqual(url.lastPathComponent, "Primer Schemes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testListReturnsBundlesSortedByName() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let folder = try PrimerSchemesFolder.ensureFolder(in: tmp)

        // Copy the fixture bundle twice with different names.
        let fixture = Bundle.module.url(
            forResource: "primerschemes/valid-simple.lungfishprimers",
            withExtension: nil
        )!
        try FileManager.default.copyItem(
            at: fixture,
            to: folder.appendingPathComponent("ZZZ.lungfishprimers", isDirectory: true)
        )
        try FileManager.default.copyItem(
            at: fixture,
            to: folder.appendingPathComponent("AAA.lungfishprimers", isDirectory: true)
        )

        let bundles = PrimerSchemesFolder.listBundles(in: tmp)
        XCTAssertEqual(bundles.count, 2)
        XCTAssertEqual(bundles.first?.url.lastPathComponent, "AAA.lungfishprimers")
        XCTAssertEqual(bundles.last?.url.lastPathComponent, "ZZZ.lungfishprimers")
    }
}
```

- [ ] **Step 2: Run and confirm failure**

```bash
swift test --filter PrimerSchemesFolderTests
```
Expected: compilation error, `PrimerSchemesFolder` not found.

- [ ] **Step 3: Write `PrimerSchemesFolder.swift`**

```swift
import Foundation
import os.log

private let logger = Logger(subsystem: LogSubsystem.io, category: "PrimerSchemesFolder")

public enum PrimerSchemesFolder {
    public static let folderName = "Primer Schemes"

    public static func ensureFolder(in projectURL: URL) throws -> URL {
        let folderURL = projectURL.appendingPathComponent(folderName, isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: folderURL.path) {
            try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
            logger.info("Created Primer Schemes folder at \(folderURL.path)")
        }
        return folderURL
    }

    public static func folderURL(in projectURL: URL) -> URL? {
        let folderURL = projectURL.appendingPathComponent(folderName, isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDir), isDir.boolValue {
            return folderURL
        }
        return nil
    }

    public static func listBundles(in projectURL: URL) -> [PrimerSchemeBundle] {
        guard let folder = folderURL(in: projectURL) else { return [] }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents
            .filter { $0.pathExtension == "lungfishprimers" }
            .compactMap { try? PrimerSchemeBundle.load(from: $0) }
            .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }
}
```

- [ ] **Step 4: Run and confirm PASS**

```bash
swift test --filter PrimerSchemesFolderTests
```

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishIO/Bundles/PrimerSchemesFolder.swift Tests/LungfishIOTests/Bundles/PrimerSchemesFolderTests.swift
git commit -m "feat(io): add PrimerSchemesFolder for project-local bundle management

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: PrimerSchemeResolver — reference-name resolution with on-the-fly BED rewrite

**Files:**
- Create: `Sources/LungfishWorkflow/Primers/PrimerSchemeResolver.swift`
- Test: `Tests/LungfishWorkflowTests/Primers/PrimerSchemeResolverTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class PrimerSchemeResolverTests: XCTestCase {
    func testCanonicalAccessionMatchReturnsOriginalBEDPath() throws {
        let bundleURL = testBundleURL()
        let bundle = try PrimerSchemeBundle.load(from: bundleURL)

        let resolved = try PrimerSchemeResolver.resolve(
            bundle: bundle,
            targetReferenceName: "MN908947.3"
        )

        XCTAssertEqual(resolved.bedURL, bundle.bedURL)
        XCTAssertFalse(resolved.isRewritten)
    }

    func testEquivalentAccessionMatchRewritesBEDColumnOne() throws {
        let bundleURL = testBundleURL()
        let bundle = try PrimerSchemeBundle.load(from: bundleURL)

        let resolved = try PrimerSchemeResolver.resolve(
            bundle: bundle,
            targetReferenceName: "NC_045512.2"
        )

        XCTAssertNotEqual(resolved.bedURL, bundle.bedURL)
        XCTAssertTrue(resolved.isRewritten)

        let content = try String(contentsOf: resolved.bedURL, encoding: .utf8)
        XCTAssertTrue(content.contains("NC_045512.2"))
        XCTAssertFalse(content.contains("MN908947.3"))

        // The rest of the BED record must be preserved verbatim.
        let lines = content.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            let cols = line.split(separator: "\t")
            XCTAssertEqual(cols.count, 6)
            XCTAssertEqual(String(cols[0]), "NC_045512.2")
        }
    }

    func testNoMatchThrowsUnknownAccession() throws {
        let bundleURL = testBundleURL()
        let bundle = try PrimerSchemeBundle.load(from: bundleURL)

        XCTAssertThrowsError(
            try PrimerSchemeResolver.resolve(
                bundle: bundle,
                targetReferenceName: "NOT_AN_ACCESSION"
            )
        ) { error in
            guard case PrimerSchemeResolver.ResolveError.unknownAccession = error else {
                XCTFail("wrong error: \(error)"); return
            }
        }
    }

    private func testBundleURL() -> URL {
        // Same fixture as Task 1.
        return Bundle.module.url(
            forResource: "primerschemes/valid-simple.lungfishprimers",
            withExtension: nil
        )!
    }
}
```

Add a `Tests/LungfishWorkflowTests/Resources/primerschemes/valid-simple.lungfishprimers/` (copy the fixture contents from Task 1 into this test target's Resources folder).

- [ ] **Step 2: Run and confirm failure**

```bash
swift test --filter PrimerSchemeResolverTests
```
Expected: compilation error, `PrimerSchemeResolver` not found.

- [ ] **Step 3: Write `PrimerSchemeResolver.swift`**

```swift
import Foundation
import LungfishIO

public enum PrimerSchemeResolver {
    public struct Resolved: Sendable {
        public let bedURL: URL
        public let isRewritten: Bool
    }

    public enum ResolveError: Error, LocalizedError {
        case unknownAccession(bundle: String, requested: String, known: [String])
        case ioFailure(underlying: Error)

        public var errorDescription: String? {
            switch self {
            case .unknownAccession(let bundle, let requested, let known):
                return "Primer scheme \(bundle) does not declare \(requested) as a reference (known: \(known.joined(separator: ", ")))."
            case .ioFailure(let underlying):
                return "Failed to rewrite primer BED: \(underlying.localizedDescription)"
            }
        }
    }

    public static func resolve(
        bundle: PrimerSchemeBundle,
        targetReferenceName: String
    ) throws -> Resolved {
        let canonical = bundle.manifest.canonicalAccession
        let equivalents = bundle.manifest.equivalentAccessions
        let known = [canonical] + equivalents

        if targetReferenceName == canonical {
            return Resolved(bedURL: bundle.bedURL, isRewritten: false)
        }

        if equivalents.contains(targetReferenceName) {
            do {
                let rewritten = try rewriteBED(
                    source: bundle.bedURL,
                    from: canonical,
                    to: targetReferenceName
                )
                return Resolved(bedURL: rewritten, isRewritten: true)
            } catch {
                throw ResolveError.ioFailure(underlying: error)
            }
        }

        throw ResolveError.unknownAccession(
            bundle: bundle.manifest.name,
            requested: targetReferenceName,
            known: known
        )
    }

    private static func rewriteBED(source: URL, from: String, to newName: String) throws -> URL {
        let input = try String(contentsOf: source, encoding: .utf8)
        let rewritten = input
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let tab = line.firstIndex(of: "\t") else { return String(line) }
                let col1 = String(line[..<tab])
                guard col1 == from else { return String(line) }
                return newName + line[tab...]
            }
            .joined(separator: "\n")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("primers-\(UUID().uuidString).bed")
        try rewritten.write(to: tmp, atomically: true, encoding: .utf8)
        return tmp
    }
}
```

- [ ] **Step 4: Run and confirm PASS**

```bash
swift test --filter PrimerSchemeResolverTests
```

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/Primers/PrimerSchemeResolver.swift Tests/LungfishWorkflowTests/Primers/PrimerSchemeResolverTests.swift Tests/LungfishWorkflowTests/Resources/primerschemes
git commit -m "feat(workflow): add PrimerSchemeResolver for reference-name matching

Canonical accession returns the bundle's BED unchanged. Equivalent accessions produce a temp BED with column 1 rewritten to the target reference name. Unknown accessions fail with a clear error enumerating the known list.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: BAM primer-trim request, result, and provenance types

**Files:**
- Create: `Sources/LungfishWorkflow/Primers/BAMPrimerTrimRequest.swift`
- Create: `Sources/LungfishWorkflow/Primers/BAMPrimerTrimResult.swift`
- Create: `Sources/LungfishWorkflow/Primers/BAMPrimerTrimProvenance.swift`
- Test: `Tests/LungfishWorkflowTests/Primers/BAMPrimerTrimProvenanceTests.swift`

- [ ] **Step 1: Write the failing test (provenance round-trip)**

```swift
import XCTest
@testable import LungfishWorkflow

final class BAMPrimerTrimProvenanceTests: XCTestCase {
    func testProvenanceEncodesToJSONAndRoundTrips() throws {
        let provenance = BAMPrimerTrimProvenance(
            operation: "primer-trim",
            primerScheme: .init(
                bundleName: "QIASeqDIRECT-SARS2",
                bundleSource: "built-in",
                bundleVersion: "1.0",
                canonicalAccession: "MN908947.3"
            ),
            sourceBAMRelativePath: "derivatives/alignment.bam",
            ivarVersion: "1.4.2",
            ivarTrimArgs: ["-q", "20", "-m", "30"],
            timestamp: Date(timeIntervalSince1970: 1714000000)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(provenance)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BAMPrimerTrimProvenance.self, from: data)

        XCTAssertEqual(decoded, provenance)
    }
}
```

- [ ] **Step 2: Run and confirm failure**

```bash
swift test --filter BAMPrimerTrimProvenanceTests
```

- [ ] **Step 3: Write the types**

`BAMPrimerTrimRequest.swift`:
```swift
import Foundation
import LungfishIO

public struct BAMPrimerTrimRequest: Sendable {
    public let sourceBAMURL: URL
    public let primerSchemeBundle: PrimerSchemeBundle
    public let outputBAMURL: URL
    public let minReadLength: Int
    public let minQuality: Int
    public let slidingWindow: Int
    public let primerOffset: Int

    public init(
        sourceBAMURL: URL,
        primerSchemeBundle: PrimerSchemeBundle,
        outputBAMURL: URL,
        minReadLength: Int = 30,
        minQuality: Int = 20,
        slidingWindow: Int = 4,
        primerOffset: Int = 0
    ) {
        self.sourceBAMURL = sourceBAMURL
        self.primerSchemeBundle = primerSchemeBundle
        self.outputBAMURL = outputBAMURL
        self.minReadLength = minReadLength
        self.minQuality = minQuality
        self.slidingWindow = slidingWindow
        self.primerOffset = primerOffset
    }
}
```

`BAMPrimerTrimResult.swift`:
```swift
import Foundation

public struct BAMPrimerTrimResult: Sendable {
    public let outputBAMURL: URL
    public let outputBAMIndexURL: URL
    public let provenanceURL: URL
    public let provenance: BAMPrimerTrimProvenance
}
```

`BAMPrimerTrimProvenance.swift`:
```swift
import Foundation

public struct BAMPrimerTrimProvenance: Codable, Sendable, Equatable {
    public let operation: String
    public let primerScheme: PrimerSchemeRef
    public let sourceBAMRelativePath: String
    public let ivarVersion: String
    public let ivarTrimArgs: [String]
    public let timestamp: Date

    public struct PrimerSchemeRef: Codable, Sendable, Equatable {
        public let bundleName: String
        public let bundleSource: String
        public let bundleVersion: String?
        public let canonicalAccession: String
    }

    enum CodingKeys: String, CodingKey {
        case operation
        case primerScheme = "primer_scheme"
        case sourceBAMRelativePath = "source_bam"
        case ivarVersion = "ivar_version"
        case ivarTrimArgs = "ivar_trim_args"
        case timestamp
    }

    public init(
        operation: String,
        primerScheme: PrimerSchemeRef,
        sourceBAMRelativePath: String,
        ivarVersion: String,
        ivarTrimArgs: [String],
        timestamp: Date
    ) {
        self.operation = operation
        self.primerScheme = primerScheme
        self.sourceBAMRelativePath = sourceBAMRelativePath
        self.ivarVersion = ivarVersion
        self.ivarTrimArgs = ivarTrimArgs
        self.timestamp = timestamp
    }
}

extension BAMPrimerTrimProvenance.PrimerSchemeRef {
    enum CodingKeys: String, CodingKey {
        case bundleName = "bundle_name"
        case bundleSource = "bundle_source"
        case bundleVersion = "bundle_version"
        case canonicalAccession = "canonical_accession"
    }
}
```

- [ ] **Step 4: Run and confirm PASS**

```bash
swift test --filter BAMPrimerTrimProvenanceTests
```

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/Primers/BAMPrimerTrim*.swift Tests/LungfishWorkflowTests/Primers/BAMPrimerTrimProvenanceTests.swift
git commit -m "feat(workflow): add request, result, and provenance types for BAM primer trim

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: BAMPrimerTrimPipeline — runs `ivar trim`, sorts, indexes, writes provenance

**Files:**
- Create: `Sources/LungfishWorkflow/Primers/BAMPrimerTrimPipeline.swift`
- Test: `Tests/LungfishWorkflowTests/Primers/BAMPrimerTrimPipelineTests.swift`

This task uses `NativeToolRunner` to invoke `ivar` (subcommand `trim`) and `samtools` (subcommands `sort` and `index`). It follows the pattern established by `ManagedMappingPipeline` which invokes `samtools sort` / `samtools index` via the same runner.

- [ ] **Step 1: Write a failing test that asserts argv construction**

```swift
import XCTest
@testable import LungfishWorkflow

final class BAMPrimerTrimPipelineTests: XCTestCase {
    func testBuildIvarTrimArgvIncludesAllExpectedFlags() throws {
        let argv = BAMPrimerTrimPipeline.buildIvarTrimArgv(
            bedPath: "/tmp/primers.bed",
            inputBAMPath: "/tmp/input.bam",
            outputPrefix: "/tmp/output",
            minReadLength: 30,
            minQuality: 20,
            slidingWindow: 4,
            primerOffset: 0
        )

        XCTAssertEqual(argv, [
            "trim",
            "-b", "/tmp/primers.bed",
            "-i", "/tmp/input.bam",
            "-p", "/tmp/output",
            "-q", "20",
            "-m", "30",
            "-s", "4",
            "-x", "0",
            "-e"
        ])
    }
}
```

`-e` tells iVar to include reads with no BED entry; the spec does not deviate from iVar's defaults here. (Confirm against iVar's documented flags when implementing; this argv is the plan's best-effort.)

- [ ] **Step 2: Run and confirm failure**

```bash
swift test --filter BAMPrimerTrimPipelineTests
```

- [ ] **Step 3: Write the pipeline's argv builder**

```swift
import Foundation
import LungfishIO

public struct BAMPrimerTrimPipeline {
    public static func buildIvarTrimArgv(
        bedPath: String,
        inputBAMPath: String,
        outputPrefix: String,
        minReadLength: Int,
        minQuality: Int,
        slidingWindow: Int,
        primerOffset: Int
    ) -> [String] {
        [
            "trim",
            "-b", bedPath,
            "-i", inputBAMPath,
            "-p", outputPrefix,
            "-q", "\(minQuality)",
            "-m", "\(minReadLength)",
            "-s", "\(slidingWindow)",
            "-x", "\(primerOffset)",
            "-e"
        ]
    }
}
```

- [ ] **Step 4: Confirm the argv test passes**

```bash
swift test --filter BAMPrimerTrimPipelineTests
```

- [ ] **Step 5: Extend the pipeline with `run` (using `NativeToolRunner`)**

Add the `run` method. Model it on `ManagedMappingPipeline.swift`'s `samtoolsSort` and `samtoolsIndex` invocations:

```swift
extension BAMPrimerTrimPipeline {
    public static func run(
        _ request: BAMPrimerTrimRequest,
        targetReferenceName: String,
        runner: NativeToolRunner,
        progress: @Sendable @escaping (Double, String) -> Void = { _, _ in }
    ) async throws -> BAMPrimerTrimResult {
        progress(0.0, "Resolving primer scheme")
        let resolved = try PrimerSchemeResolver.resolve(
            bundle: request.primerSchemeBundle,
            targetReferenceName: targetReferenceName
        )

        let workDir = request.outputBAMURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let trimmedPrefix = workDir.appendingPathComponent("trimmed.unsorted")
        let trimmedUnsortedBAM = trimmedPrefix.appendingPathExtension("bam")

        progress(0.1, "Running ivar trim")
        let ivarArgs = buildIvarTrimArgv(
            bedPath: resolved.bedURL.path,
            inputBAMPath: request.sourceBAMURL.path,
            outputPrefix: trimmedPrefix.path,
            minReadLength: request.minReadLength,
            minQuality: request.minQuality,
            slidingWindow: request.slidingWindow,
            primerOffset: request.primerOffset
        )

        try await runner.run(tool: .ivar, arguments: ivarArgs)

        progress(0.55, "Sorting BAM")
        try await runner.run(tool: .samtools, arguments: [
            "sort", "-o", request.outputBAMURL.path, trimmedUnsortedBAM.path
        ])

        progress(0.85, "Indexing BAM")
        try await runner.run(tool: .samtools, arguments: [
            "index", request.outputBAMURL.path
        ])

        try? FileManager.default.removeItem(at: trimmedUnsortedBAM)
        if resolved.isRewritten {
            try? FileManager.default.removeItem(at: resolved.bedURL)
        }

        let bamIndexURL = URL(fileURLWithPath: request.outputBAMURL.path + ".bai")
        let provenance = BAMPrimerTrimProvenance(
            operation: "primer-trim",
            primerScheme: .init(
                bundleName: request.primerSchemeBundle.manifest.name,
                bundleSource: request.primerSchemeBundle.manifest.source ?? "project-local",
                bundleVersion: request.primerSchemeBundle.manifest.version,
                canonicalAccession: request.primerSchemeBundle.manifest.canonicalAccession
            ),
            sourceBAMRelativePath: request.sourceBAMURL.lastPathComponent,
            ivarVersion: (try? await runner.toolVersion(tool: .ivar)) ?? "unknown",
            ivarTrimArgs: ivarArgs,
            timestamp: Date()
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let provenanceData = try encoder.encode(provenance)
        let provenanceURL = request.outputBAMURL
            .deletingPathExtension()
            .appendingPathExtension("primer-trim-provenance.json")
        try provenanceData.write(to: provenanceURL)

        progress(1.0, "Primer trim complete")

        return BAMPrimerTrimResult(
            outputBAMURL: request.outputBAMURL,
            outputBAMIndexURL: bamIndexURL,
            provenanceURL: provenanceURL,
            provenance: provenance
        )
    }
}
```

If `NativeToolRunner` does not already expose `toolVersion`, skip that call and hardcode `"unknown"` for this commit; extract a follow-up task if needed.

- [ ] **Step 6: Commit the pipeline (argv + run method)**

```bash
git add Sources/LungfishWorkflow/Primers/BAMPrimerTrimPipeline.swift Tests/LungfishWorkflowTests/Primers/BAMPrimerTrimPipelineTests.swift
git commit -m "feat(workflow): add BAMPrimerTrimPipeline invoking ivar trim + samtools sort/index

The pipeline resolves the primer bundle's BED to the BAM's reference name, runs ivar trim, sorts and indexes the output, and writes a provenance sidecar JSON documenting the primer scheme and iVar arguments used.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: BuiltInPrimerSchemeService — discovers bundles in app Resources

**Files:**
- Create: `Sources/LungfishApp/Services/BuiltInPrimerSchemeService.swift`
- Test: `Tests/LungfishAppTests/PrimerTrim/BuiltInPrimerSchemeServiceTests.swift`
- Create a fixture built-in bundle at `Sources/LungfishApp/Resources/PrimerSchemes/test-builtin.lungfishprimers/` for test discovery (this is a lightweight test-only stub; replaced by the real QIASeq bundle in Task 11).

- [ ] **Step 1: Register the Resources directory in Package.swift**

In `Package.swift`, under the `Lungfish` (or `LungfishApp`) target, ensure the target's `resources` array includes `.copy("Resources/PrimerSchemes")` (or the broader `.copy("Resources")` if that pattern exists).

- [ ] **Step 2: Write the failing test**

```swift
import XCTest
import LungfishIO
@testable import LungfishApp

final class BuiltInPrimerSchemeServiceTests: XCTestCase {
    func testListBuiltInSchemesReturnsBundledSchemes() throws {
        let schemes = BuiltInPrimerSchemeService.listBuiltInSchemes()
        XCTAssertFalse(schemes.isEmpty, "expected at least one built-in primer scheme")
        XCTAssertTrue(schemes.contains { $0.manifest.name == "test-builtin" })
    }
}
```

- [ ] **Step 3: Run and confirm failure**

```bash
swift test --filter BuiltInPrimerSchemeServiceTests
```

- [ ] **Step 4: Write the service**

```swift
import Foundation
import LungfishIO

public enum BuiltInPrimerSchemeService {
    public static func listBuiltInSchemes() -> [PrimerSchemeBundle] {
        guard let resourceURL = Bundle.main.resourceURL else { return [] }
        let folderURL = resourceURL.appendingPathComponent("PrimerSchemes", isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents
            .filter { $0.pathExtension == "lungfishprimers" }
            .compactMap { try? PrimerSchemeBundle.load(from: $0) }
            .sorted { $0.manifest.name < $1.manifest.name }
    }
}
```

For test contexts (`Bundle.module`), the service may need an optional `bundle:` parameter so tests can point to the test target's Resources folder. Overload:

```swift
public static func listBuiltInSchemes(in bundle: Bundle = .main) -> [PrimerSchemeBundle] {
    // same body but using `bundle.resourceURL`
}
```

Confirm the stub bundle `test-builtin.lungfishprimers` exists under the test target's resource path.

- [ ] **Step 5: Run and confirm PASS**

```bash
swift test --filter BuiltInPrimerSchemeServiceTests
```

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/Services/BuiltInPrimerSchemeService.swift Tests/LungfishAppTests/PrimerTrim/BuiltInPrimerSchemeServiceTests.swift Sources/LungfishApp/Resources/PrimerSchemes/test-builtin.lungfishprimers Package.swift
git commit -m "feat(app): add BuiltInPrimerSchemeService to enumerate shipped schemes

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: BAMPrimerTrimCatalog — pack-gated availability

**Files:**
- Create: `Sources/LungfishApp/Views/BAM/BAMPrimerTrimCatalog.swift`
- Test: `Tests/LungfishAppTests/PrimerTrim/BAMPrimerTrimCatalogTests.swift`

Mirrors `BAMVariantCallingCatalog`. Since the primer-trim operation is a single operation (no per-tool branch like LoFreq vs iVar vs Medaka), the catalog's list has one item.

- [ ] **Step 1: Write failing test**

```swift
import XCTest
@testable import LungfishApp

final class BAMPrimerTrimCatalogTests: XCTestCase {
    func testAvailabilityReadyWhenPackReady() async {
        let catalog = BAMPrimerTrimCatalog(
            statusProvider: FakePackStatusProvider(state: .ready)
        )
        let availability = await catalog.availability()
        XCTAssertEqual(availability, .available)
    }

    func testAvailabilityDisabledWhenPackNotReady() async {
        let catalog = BAMPrimerTrimCatalog(
            statusProvider: FakePackStatusProvider(state: .notInstalled)
        )
        let availability = await catalog.availability()
        if case .disabled(let reason) = availability {
            XCTAssertTrue(reason.contains("Variant Calling"))
        } else {
            XCTFail("expected disabled, got \(availability)")
        }
    }
}
```

Add `FakePackStatusProvider` as a test-scoped helper mirroring what `BAMVariantCallingCatalogTests` uses (or check whether an existing fake is shared).

- [ ] **Step 2: Run and confirm failure**

```bash
swift test --filter BAMPrimerTrimCatalogTests
```

- [ ] **Step 3: Write the catalog**

```swift
import Foundation
import LungfishWorkflow

struct BAMPrimerTrimCatalog: Sendable {
    private let statusProvider: any PluginPackStatusProviding

    init(statusProvider: any PluginPackStatusProviding = PluginPackStatusService.shared) {
        self.statusProvider = statusProvider
    }

    func availability() async -> DatasetOperationAvailability {
        guard let status = await statusProvider.status(forPackID: "variant-calling"),
              status.state == .ready else {
            return .disabled(reason: disabledReason())
        }
        return .available
    }

    private func disabledReason() -> String {
        guard let pack = PluginPack.builtInPack(id: "variant-calling") else {
            return "No tools available"
        }
        return "Requires \(pack.name) Pack"
    }
}
```

- [ ] **Step 4: Run and confirm PASS**

```bash
swift test --filter BAMPrimerTrimCatalogTests
```

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Views/BAM/BAMPrimerTrimCatalog.swift Tests/LungfishAppTests/PrimerTrim/BAMPrimerTrimCatalogTests.swift
git commit -m "feat(app): add BAMPrimerTrimCatalog pack-gating

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: BAMPrimerTrimDialogState — @Observable state model

**Files:**
- Create: `Sources/LungfishApp/Views/BAM/BAMPrimerTrimDialogState.swift`
- Test: `Tests/LungfishAppTests/PrimerTrim/BAMPrimerTrimDialogStateTests.swift`

- [ ] **Step 1: Write failing test**

```swift
import XCTest
import LungfishIO
@testable import LungfishApp

final class BAMPrimerTrimDialogStateTests: XCTestCase {
    @MainActor func testIsRunEnabledFalseWhenNoSchemeSelected() {
        let state = BAMPrimerTrimDialogState(
            bundle: TestBundles.sampleWithOneBAM(),
            availability: .available,
            builtInSchemes: [],
            projectSchemes: []
        )
        XCTAssertFalse(state.isRunEnabled)
    }

    @MainActor func testIsRunEnabledTrueWhenSchemeSelectedAndPackReady() throws {
        let scheme = try TestBundles.loadSampleScheme()
        let state = BAMPrimerTrimDialogState(
            bundle: TestBundles.sampleWithOneBAM(),
            availability: .available,
            builtInSchemes: [scheme],
            projectSchemes: []
        )
        state.selectScheme(id: scheme.manifest.name)
        XCTAssertTrue(state.isRunEnabled)
    }

    @MainActor func testIsRunEnabledFalseWhenPackUnavailable() throws {
        let scheme = try TestBundles.loadSampleScheme()
        let state = BAMPrimerTrimDialogState(
            bundle: TestBundles.sampleWithOneBAM(),
            availability: .disabled(reason: "Requires Variant Calling Pack"),
            builtInSchemes: [scheme],
            projectSchemes: []
        )
        state.selectScheme(id: scheme.manifest.name)
        XCTAssertFalse(state.isRunEnabled)
    }
}
```

- [ ] **Step 2: Run and confirm failure**

```bash
swift test --filter BAMPrimerTrimDialogStateTests
```

- [ ] **Step 3: Write `BAMPrimerTrimDialogState.swift`**

Modeled on `BAMVariantCallingDialogState.swift`. Key fields:

- `bundle: ReferenceBundle`
- `availability: DatasetOperationAvailability`
- `builtInSchemes: [PrimerSchemeBundle]`
- `projectSchemes: [PrimerSchemeBundle]`
- `selectedSchemeID: String?`
- `minReadLengthText`, `minQualityText`, `slidingWindowText`, `primerOffsetText` — advanced options
- Computed `isRunEnabled`, `readinessText`
- `prepareForRun()` produces a `BAMPrimerTrimRequest`

```swift
import Foundation
import Observation
import LungfishIO
import LungfishWorkflow

@MainActor
@Observable
final class BAMPrimerTrimDialogState {
    let bundle: ReferenceBundle
    let availability: DatasetOperationAvailability
    let builtInSchemes: [PrimerSchemeBundle]
    let projectSchemes: [PrimerSchemeBundle]

    var selectedSchemeID: String?
    var minReadLengthText: String = "30"
    var minQualityText: String = "20"
    var slidingWindowText: String = "4"
    var primerOffsetText: String = "0"

    private(set) var pendingRequest: BAMPrimerTrimRequest?

    init(
        bundle: ReferenceBundle,
        availability: DatasetOperationAvailability,
        builtInSchemes: [PrimerSchemeBundle],
        projectSchemes: [PrimerSchemeBundle]
    ) {
        self.bundle = bundle
        self.availability = availability
        self.builtInSchemes = builtInSchemes
        self.projectSchemes = projectSchemes
    }

    var allSchemes: [PrimerSchemeBundle] {
        builtInSchemes + projectSchemes
    }

    var selectedScheme: PrimerSchemeBundle? {
        allSchemes.first { $0.manifest.name == selectedSchemeID }
    }

    func selectScheme(id: String) {
        guard allSchemes.contains(where: { $0.manifest.name == id }) else { return }
        selectedSchemeID = id
    }

    var isRunEnabled: Bool {
        guard availability == .available else { return false }
        guard selectedScheme != nil else { return false }
        guard parsedInt(minReadLengthText) != nil else { return false }
        guard parsedInt(minQualityText) != nil else { return false }
        guard parsedInt(slidingWindowText) != nil else { return false }
        guard parsedInt(primerOffsetText) != nil else { return false }
        return true
    }

    var readinessText: String {
        if case .disabled(let reason) = availability { return reason }
        guard let scheme = selectedScheme else { return "Select a primer scheme." }
        return "Ready to trim using \(scheme.manifest.displayName)."
    }

    private func parsedInt(_ s: String) -> Int? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let value = Int(trimmed), value >= 0 else { return nil }
        return value
    }
}
```

- [ ] **Step 4: Run and confirm PASS**

```bash
swift test --filter BAMPrimerTrimDialogStateTests
```

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Views/BAM/BAMPrimerTrimDialogState.swift Tests/LungfishAppTests/PrimerTrim/BAMPrimerTrimDialogStateTests.swift
git commit -m "feat(app): add BAMPrimerTrimDialogState

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Dialog view, tool panes, and presenter

**Files:**
- Create: `Sources/LungfishApp/Views/BAM/BAMPrimerTrimDialog.swift`
- Create: `Sources/LungfishApp/Views/BAM/BAMPrimerTrimToolPanes.swift`
- Create: `Sources/LungfishApp/Views/BAM/BAMPrimerTrimDialogPresenter.swift`
- Create: `Sources/LungfishApp/Views/BAM/PrimerSchemePickerView.swift`

These are UI-only and testable via XCUI, not unit tests.

- [ ] **Step 1: Write `PrimerSchemePickerView.swift`**

```swift
import SwiftUI
import LungfishIO

struct PrimerSchemePickerView: View {
    let builtIn: [PrimerSchemeBundle]
    let projectLocal: [PrimerSchemeBundle]
    @Binding var selectedSchemeID: String?
    let onBrowse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !builtIn.isEmpty {
                Section {
                    ForEach(builtIn, id: \.manifest.name) { scheme in
                        schemeRow(scheme, badge: "Built-in")
                    }
                } header: {
                    Text("Built-in").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !projectLocal.isEmpty {
                Section {
                    ForEach(projectLocal, id: \.manifest.name) { scheme in
                        schemeRow(scheme, badge: nil)
                    }
                } header: {
                    Text("In this project").font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("Browse…", action: onBrowse)
        }
    }

    private func schemeRow(_ scheme: PrimerSchemeBundle, badge: String?) -> some View {
        HStack {
            Button(action: { selectedSchemeID = scheme.manifest.name }) {
                HStack {
                    Text(scheme.manifest.displayName)
                    if selectedSchemeID == scheme.manifest.name {
                        Image(systemName: "checkmark").foregroundStyle(.accentColor)
                    }
                    Spacer()
                    if let badge { Text(badge).font(.caption2).foregroundStyle(.secondary) }
                }
            }
            .buttonStyle(.plain)
        }
    }
}
```

- [ ] **Step 2: Write `BAMPrimerTrimToolPanes.swift`**

Modeled on `BAMVariantCallingToolPanes`. Sections: overview (dataset label + scheme picker), advanced options, readiness.

```swift
import SwiftUI
import Observation

struct BAMPrimerTrimToolPanes: View {
    @Bindable var state: BAMPrimerTrimDialogState
    let onBrowseScheme: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                overviewSection
                advancedOptionsSection
                readinessSection
            }
        }
    }

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Primer Scheme").font(.headline)
            PrimerSchemePickerView(
                builtIn: state.builtInSchemes,
                projectLocal: state.projectSchemes,
                selectedSchemeID: $state.selectedSchemeID,
                onBrowse: onBrowseScheme
            )
        }
    }

    private var advancedOptionsSection: some View {
        DisclosureGroup("Advanced Options") {
            VStack(alignment: .leading, spacing: 12) {
                labeledField("Minimum read length after trim", text: $state.minReadLengthText)
                labeledField("Minimum quality", text: $state.minQualityText)
                labeledField("Sliding window width", text: $state.slidingWindowText)
                labeledField("Primer offset", text: $state.primerOffsetText)
            }
        }
    }

    private var readinessSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Readiness").font(.headline)
            Text(state.readinessText).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func labeledField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("", text: text).textFieldStyle(.roundedBorder)
        }
    }
}
```

- [ ] **Step 3: Write `BAMPrimerTrimDialog.swift`**

```swift
import SwiftUI
import Observation

struct BAMPrimerTrimDialog: View {
    @Bindable var state: BAMPrimerTrimDialogState
    let onCancel: () -> Void
    let onRun: () -> Void
    let onBrowseScheme: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            BAMPrimerTrimToolPanes(state: state, onBrowseScheme: onBrowseScheme)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Run", action: onRun)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!state.isRunEnabled)
            }
            .padding()
        }
    }
}
```

- [ ] **Step 4: Write `BAMPrimerTrimDialogPresenter.swift`**

Modeled exactly on `BAMVariantCallingDialogPresenter`:

```swift
import AppKit
import SwiftUI
import LungfishIO

@MainActor
struct BAMPrimerTrimDialogPresenter {
    static func present(
        from window: NSWindow,
        bundle: ReferenceBundle,
        builtInSchemes: [PrimerSchemeBundle],
        projectSchemes: [PrimerSchemeBundle],
        availability: DatasetOperationAvailability,
        onRun: ((BAMPrimerTrimDialogState) -> Void)? = nil,
        onCancel: (() -> Void)? = nil,
        onBrowseScheme: (() -> Void)? = nil
    ) {
        let state = BAMPrimerTrimDialogState(
            bundle: bundle,
            availability: availability,
            builtInSchemes: builtInSchemes,
            projectSchemes: projectSchemes
        )

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        panel.title = "Primer-trim BAM"
        panel.isReleasedWhenClosed = false

        let dialog = BAMPrimerTrimDialog(
            state: state,
            onCancel: {
                window.endSheet(panel)
                onCancel?()
            },
            onRun: {
                window.endSheet(panel)
                onRun?(state)
            },
            onBrowseScheme: { onBrowseScheme?() }
        )

        let hostingController = NSHostingController(rootView: dialog)
        panel.contentViewController = hostingController
        panel.setContentSize(NSSize(width: 540, height: 480))
        window.beginSheet(panel)
    }
}
```

- [ ] **Step 5: Build**

```bash
swift build
```
Expected: `Build complete!`. No tests added in this task.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/Views/BAM/BAMPrimerTrimDialog.swift Sources/LungfishApp/Views/BAM/BAMPrimerTrimToolPanes.swift Sources/LungfishApp/Views/BAM/BAMPrimerTrimDialogPresenter.swift Sources/LungfishApp/Views/BAM/PrimerSchemePickerView.swift
git commit -m "feat(app): add BAMPrimerTrimDialog, tool panes, presenter, and scheme picker

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: Wire the primer-trim button into the Inspector's Analysis section

**Files:**
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`

- [ ] **Step 1: Add callback to the Inspector's view model**

In `ReadStyleSection.swift` around line 275 (near `onCallVariantsRequested`), add:

```swift
public var onPrimerTrimRequested: (() -> Void)?
```

- [ ] **Step 2: Add the section view**

After `variantCallingSection` (around line 2145), add `primerTrimSection`:

```swift
@ViewBuilder
private var primerTrimSection: some View {
    VStack(alignment: .leading, spacing: 8) {
        Text("Trim amplicon primers from the alignment before variant calling.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if viewModel.hasVariantCallableAlignmentTracks {
            Text("Required for iVar variant calling on amplicon-sequenced BAMs; recommended for any amplicon panel.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Primer trim is unavailable until this bundle includes an eligible alignment track.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Button("Primer-trim BAM…") {
            viewModel.onPrimerTrimRequested?()
        }
        .disabled(!viewModel.hasVariantCallableAlignmentTracks)
    }
}
```

- [ ] **Step 3: Register a new section enum case and render it in the dispatch**

Find the `Section` enum (around line 836; `case variantCalling` is nearby). Add:

```swift
case primerTrim
```

Find the switch that dispatches on section (around line 1675; where `case .variantCalling: variantCallingSection` appears). Add (above `.variantCalling`):

```swift
case .primerTrim:
    primerTrimSection
```

Find where the sections array is populated (search for the array that contains `.variantCalling`). Add `.primerTrim` immediately before `.variantCalling` so the UI reads top-down: primer-trim, then call variants.

- [ ] **Step 4: Wire the callback in `InspectorViewController.swift`**

Near line 1556 (and the duplicate at line 1595), add after `onCallVariantsRequested`:

```swift
viewModel.readStyleSectionViewModel.onPrimerTrimRequested = { [weak self] in
    self?.presentPrimerTrimDialog()
}
```

Then add a `presentPrimerTrimDialog()` method, modeled on the existing variant-calling presentation (around line 1639):

```swift
private func presentPrimerTrimDialog() {
    guard let window = view.window, let bundle else { return }
    Task { @MainActor in
        let builtIn = BuiltInPrimerSchemeService.listBuiltInSchemes()
        let projectLocal: [PrimerSchemeBundle]
        if let projectURL = AppDelegate.shared.currentProjectURL {
            projectLocal = PrimerSchemesFolder.listBundles(in: projectURL)
        } else {
            projectLocal = []
        }
        let availability = await BAMPrimerTrimCatalog().availability()

        BAMPrimerTrimDialogPresenter.present(
            from: window,
            bundle: bundle,
            builtInSchemes: builtIn,
            projectSchemes: projectLocal,
            availability: availability,
            onRun: { [weak self] state in
                self?.launchPrimerTrimOperation(state: state)
            },
            onBrowseScheme: { [weak self] in
                self?.presentPrimerSchemeBrowseSheet()
            }
        )
    }
}

private func launchPrimerTrimOperation(state: BAMPrimerTrimDialogState) {
    // Delegated to AppDelegate or a dedicated runner; stubbed here.
    AppDelegate.shared.runPrimerTrim(state: state)
}

private func presentPrimerSchemeBrowseSheet() {
    // Opens NSOpenPanel for .lungfishprimers directories; out of scope for this task.
}
```

(If `AppDelegate.shared.currentProjectURL` doesn't exist under that exact name, use whatever property the existing variant-calling presenter uses.)

- [ ] **Step 5: Build**

```bash
swift build 2>&1 | tail -5
```
Expected: `Build complete!`. If it fails, resolve the specific error (likely missing imports or wrong property names) before proceeding.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift Sources/LungfishApp/Views/Inspector/InspectorViewController.swift
git commit -m "feat(app): surface primer-trim as a button in Inspector Analysis section

Adds a \"Primer-trim BAM…\" button above \"Call Variants…\" in the BAM Inspector, wired through onPrimerTrimRequested to BAMPrimerTrimDialogPresenter. Disabled when no alignment track is available, matching the sibling button's behavior.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: Build and ship the canonical QIASeqDIRECT-SARS2 bundle

**Files:**
- Create: `scripts/build-primer-bundle.swift`
- Create: `Sources/LungfishApp/Resources/PrimerSchemes/QIASeqDIRECT-SARS2.lungfishprimers/`
  - `manifest.json`
  - `primers.bed`
  - `primers.fasta`
  - `PROVENANCE.md`
- Delete: `Sources/LungfishApp/Resources/PrimerSchemes/test-builtin.lungfishprimers/` (replaced)

This task has two parts: building the script, and using it to author the QIASeq bundle.

- [ ] **Step 1: Write `scripts/build-primer-bundle.swift`**

A standalone Swift script invoked as `swift scripts/build-primer-bundle.swift …`. Reads a BED, optionally a FASTA, a list of reference accessions (one canonical), and writes the bundle. Fetches each reference accession from NCBI and verifies byte-identical sequences when more than one is declared.

```swift
#!/usr/bin/env swift

import Foundation

struct Args {
    var name: String
    var displayName: String
    var description: String
    var organism: String
    var canonical: String
    var equivalents: [String]
    var bed: URL
    var fasta: URL?
    var output: URL
}

// ... argv parsing, NCBI fetch via eutils, SHA256 comparison, manifest emission ...
```

Because this script is a one-shot authoring tool and not part of the shipped app, a detailed implementation is scoped to the implementer; keep it under 300 lines and log clearly. The script must:

1. Validate that the BED's column 1 matches the declared canonical accession.
2. Fetch each declared reference accession via NCBI efetch (e.g., `https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=nuccore&id=<acc>&rettype=fasta`).
3. SHA256-hash the sequence body (excluding the header line).
4. Refuse to emit the bundle if any equivalent's hash differs from the canonical's.
5. Compute `primer_count` (rows in BED) and `amplicon_count` (distinct amplicon names, i.e., primer names with `_LEFT`/`_RIGHT` stripped).
6. Write the bundle directory with `manifest.json`, `primers.bed`, optional `primers.fasta`, and `PROVENANCE.md`.

- [ ] **Step 2: Obtain the QIASeq Direct SARS-CoV-2 primer BED**

Locate QIAGEN's published primer coordinates for the QIASeq Direct SARS-CoV-2 panel. Record the URL and retrieval date. Save the BED locally as `scripts/inputs/qiaseq-direct-sars2.bed`.

If QIAGEN also publishes primer sequences, save them as `scripts/inputs/qiaseq-direct-sars2.fasta`. If not, note this in the `PROVENANCE.md` and let the script derive sequences from the reference at the declared coordinates (and label `"derived": true` in the manifest if the script supports it; otherwise, omit the FASTA in this first pass and open a follow-up task).

If QIAGEN's licensing for the BED is unclear, the implementer escalates to the user before committing the BED to the repo. This is a licensing decision, not a technical one.

- [ ] **Step 3: Build the bundle**

```bash
swift scripts/build-primer-bundle.swift \
  --name QIASeqDIRECT-SARS2 \
  --display-name "QIASeq Direct SARS-CoV-2" \
  --description "QIAGEN QIASeq Direct SARS-CoV-2 amplicon panel." \
  --organism "Severe acute respiratory syndrome coronavirus 2" \
  --canonical MN908947.3 \
  --equivalent NC_045512.2 \
  --bed scripts/inputs/qiaseq-direct-sars2.bed \
  --fasta scripts/inputs/qiaseq-direct-sars2.fasta \
  --output Sources/LungfishApp/Resources/PrimerSchemes/QIASeqDIRECT-SARS2.lungfishprimers
```

Expected: the script prints "built QIASeqDIRECT-SARS2 (N primers, M amplicons), SHA256 match confirmed for MN908947.3 ≡ NC_045512.2" and emits the bundle directory.

- [ ] **Step 4: Write `PROVENANCE.md` by hand**

The script emits a stub; replace it with content covering:
- QIAGEN as the scheme designer.
- URL and retrieval date.
- A note that primer coordinates on a public reference are not themselves copyrightable, but users should verify against QIAGEN's current documentation before production use.
- If a panel PDF is bundled under `attachments/`, cite its license. Otherwise, link instead of bundling.

- [ ] **Step 5: Delete the test-builtin stub bundle**

```bash
rm -rf Sources/LungfishApp/Resources/PrimerSchemes/test-builtin.lungfishprimers
```

Update `BuiltInPrimerSchemeServiceTests` to expect `QIASeqDIRECT-SARS2` instead of `test-builtin`. Rerun the test:

```bash
swift test --filter BuiltInPrimerSchemeServiceTests
```
Expected: PASS.

- [ ] **Step 6: Add a bundle fixture symlink under Tests/Fixtures**

```bash
mkdir -p Tests/Fixtures/primerschemes
ln -s ../../Sources/LungfishApp/Resources/PrimerSchemes/QIASeqDIRECT-SARS2.lungfishprimers Tests/Fixtures/primerschemes/QIASeqDIRECT-SARS2.lungfishprimers
```

If SPM resource handling refuses the symlink when copying into the test bundle, copy the directory instead and document the duplication.

Extend `TestFixtures.swift` (`Tests/LungfishIntegrationTests/TestFixtures.swift`) with:

```swift
extension TestFixtures {
    static let qiaseqDirectSARS2: PrimerSchemeFixture = .init(
        bundlePath: "primerschemes/QIASeqDIRECT-SARS2.lungfishprimers"
    )
}

struct PrimerSchemeFixture {
    let bundlePath: String
}
```

- [ ] **Step 7: Commit**

```bash
git add scripts/build-primer-bundle.swift scripts/inputs/qiaseq-direct-sars2.bed scripts/inputs/qiaseq-direct-sars2.fasta Sources/LungfishApp/Resources/PrimerSchemes/QIASeqDIRECT-SARS2.lungfishprimers Tests/Fixtures/primerschemes Tests/LungfishIntegrationTests/TestFixtures.swift
git commit -m "feat(assets): ship canonical QIASeqDIRECT-SARS2.lungfishprimers bundle

Includes the QIAGEN QIASeq Direct SARS-CoV-2 primer coordinates (against MN908947.3, with NC_045512.2 declared as an equivalent accession), per-primer FASTA records, and a PROVENANCE.md citing QIAGEN's published coordinates. Built via scripts/build-primer-bundle.swift, which verifies that the two declared accessions carry byte-identical sequences.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 12: Integration test — primer-trim against fixture BAM

**Files:**
- Create: `Tests/LungfishIntegrationTests/PrimerTrim/PrimerTrimIntegrationTests.swift`

Uses the existing `sarscov2` fixture BAM + the new QIASeq bundle fixture.

- [ ] **Step 1: Write the integration test**

```swift
import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class PrimerTrimIntegrationTests: XCTestCase {
    func testPrimerTrimProducesSortedIndexedBAMWithProvenance() async throws {
        let sourceBAM = TestFixtures.sarscov2.mappedBAM
        let schemeBundleURL = TestFixtures.qiaseqDirectSARS2.bundleURL
        let scheme = try PrimerSchemeBundle.load(from: schemeBundleURL)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let outputBAM = tmp.appendingPathComponent("trimmed.bam")
        let request = BAMPrimerTrimRequest(
            sourceBAMURL: sourceBAM,
            primerSchemeBundle: scheme,
            outputBAMURL: outputBAM
        )

        let runner = NativeToolRunner.shared
        let result = try await BAMPrimerTrimPipeline.run(
            request,
            targetReferenceName: "MN908947.3",
            runner: runner
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputBAMURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputBAMIndexURL.path))

        // Provenance present and correct.
        let data = try Data(contentsOf: result.provenanceURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let provenance = try decoder.decode(BAMPrimerTrimProvenance.self, from: data)
        XCTAssertEqual(provenance.operation, "primer-trim")
        XCTAssertEqual(provenance.primerScheme.bundleName, "QIASeqDIRECT-SARS2")
        XCTAssertEqual(provenance.primerScheme.canonicalAccession, "MN908947.3")

        // Output BAM is coordinate-sorted: samtools view returns non-empty records.
        let viewOutput = try await runner.runCapturing(tool: .samtools, arguments: ["view", "-c", result.outputBAMURL.path])
        let count = Int(viewOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        XCTAssertGreaterThan(count, 0)
    }
}
```

- [ ] **Step 2: Run the test**

```bash
swift test --filter PrimerTrimIntegrationTests
```
Expected: PASS. If it fails due to `NativeToolRunner.runCapturing` not existing under that name, use the real method name or drop the samtools-view sanity-check (the output-file existence + provenance checks are the essential assertions).

- [ ] **Step 3: Commit**

```bash
git add Tests/LungfishIntegrationTests/PrimerTrim/PrimerTrimIntegrationTests.swift
git commit -m "test(integration): end-to-end primer-trim against sarscov2 fixture

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 13: Auto-confirm iVar primer-trim checkbox when BAM has Lungfish trim provenance

**Files:**
- Modify: `Sources/LungfishApp/Views/BAM/BAMVariantCallingDialogState.swift`
- Modify: `Sources/LungfishApp/Views/BAM/BAMVariantCallingToolPanes.swift`
- Test: `Tests/LungfishAppTests/PrimerTrim/BAMVariantCallingAutoConfirmTests.swift`

- [ ] **Step 1: Write failing test**

```swift
import XCTest
@testable import LungfishApp
@testable import LungfishIO

final class BAMVariantCallingAutoConfirmTests: XCTestCase {
    @MainActor func testIvarCheckboxAutoConfirmsWhenProvenanceIndicatesLungfishTrim() throws {
        // Construct a bundle whose selected alignment track has a Lungfish primer-trim provenance sidecar.
        let bundle = TestBundles.bundleWithPrimerTrimmedBAM(schemeName: "QIASeqDIRECT-SARS2")
        let state = BAMVariantCallingDialogState(bundle: bundle)
        state.selectCaller(.ivar)
        XCTAssertTrue(state.ivarPrimerTrimConfirmed, "expected auto-confirm")
        XCTAssertTrue(state.readinessText.contains("Primer-trimmed by Lungfish"))
    }

    @MainActor func testIvarCheckboxIsUserAttestedForNonLungfishTrim() throws {
        let bundle = TestBundles.bundleWithPlainBAM()
        let state = BAMVariantCallingDialogState(bundle: bundle)
        state.selectCaller(.ivar)
        XCTAssertFalse(state.ivarPrimerTrimConfirmed, "user must attest manually")
    }
}
```

- [ ] **Step 2: Run and confirm failure**

```bash
swift test --filter BAMVariantCallingAutoConfirmTests
```

- [ ] **Step 3: In `BAMVariantCallingDialogState`, read the selected alignment track's provenance sidecar and set `ivarPrimerTrimConfirmed = true` (and add an auto-confirm flag) when `operation == "primer-trim"`**

Add to the state:
```swift
private(set) var autoConfirmedPrimerTrim: BAMPrimerTrimProvenance?

init(bundle: ReferenceBundle, ...) {
    // ... existing ...
    self.autoConfirmedPrimerTrim = Self.readPrimerTrimProvenance(for: bundle, trackID: defaultAlignmentTrackID)
    self.ivarPrimerTrimConfirmed = self.autoConfirmedPrimerTrim != nil
}

private static func readPrimerTrimProvenance(for bundle: ReferenceBundle, trackID: String) -> BAMPrimerTrimProvenance? {
    // Read the JSON sidecar next to the BAM of the selected track.
    // Return nil if sidecar is absent or does not decode.
}
```

Also re-evaluate when `selectedAlignmentTrackID` changes (in its `didSet`).

Update `readinessText` to include "Primer-trimmed by Lungfish on <date>" when `autoConfirmedPrimerTrim != nil`.

- [ ] **Step 4: In `BAMVariantCallingToolPanes`, render the iVar section differently when `state.autoConfirmedPrimerTrim != nil`**

Replace the `Toggle(...)` with a disabled, pre-checked `Toggle` plus a caption:

```swift
if let auto = state.autoConfirmedPrimerTrim {
    Toggle("This BAM has already been primer-trimmed for iVar.", isOn: .constant(true))
        .disabled(true)
    Text("Primer-trimmed by Lungfish on \(formatted(auto.timestamp)) using \(auto.primerScheme.bundleName).")
        .font(.caption)
        .foregroundStyle(.secondary)
} else {
    Toggle("This BAM has already been primer-trimmed for iVar.", isOn: $state.ivarPrimerTrimConfirmed)
}
```

- [ ] **Step 5: Run and confirm PASS**

```bash
swift test --filter BAMVariantCallingAutoConfirmTests
```

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/Views/BAM/BAMVariantCallingDialogState.swift Sources/LungfishApp/Views/BAM/BAMVariantCallingToolPanes.swift Tests/LungfishAppTests/PrimerTrim/BAMVariantCallingAutoConfirmTests.swift
git commit -m "feat(app): auto-confirm iVar primer-trim when BAM has Lungfish trim provenance

When the selected BAM's sidecar records a Lungfish-run primer trim, the iVar checkbox is auto-checked and disabled with a caption documenting when and which scheme was used. User-attested trims still work as before for externally-trimmed BAMs.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 14: Import Center — primer-scheme import flow

**Files:**
- Create: `Sources/LungfishApp/Views/ImportCenter/PrimerSchemeImportView.swift`
- Create: `Sources/LungfishApp/Views/ImportCenter/PrimerSchemeImportViewModel.swift`
- Modify: `Sources/LungfishApp/Views/ImportCenter/ImportCenterView.swift` (add entry point)
- Modify: `Sources/LungfishApp/Views/ImportCenter/ImportCenterViewModel.swift`
- Test: `Tests/LungfishAppTests/PrimerTrim/PrimerSchemeImportTests.swift`

- [ ] **Step 1: Write the import view model and its failing tests**

The view model takes a BED path, an optional FASTA path, optional attachments, a declared canonical accession, optional equivalents, and a display name. It validates, writes the bundle, returns the bundle URL.

```swift
func testImportFromBEDOnlyProducesValidBundle() throws {
    let tmpProject = ...
    let viewModel = PrimerSchemeImportViewModel()
    let result = try viewModel.import(
        bedURL: inputBED,
        fastaURL: nil,
        attachments: [],
        name: "my-scheme",
        displayName: "My Scheme",
        canonicalAccession: "MN908947.3",
        equivalentAccessions: [],
        projectURL: tmpProject
    )
    let loaded = try PrimerSchemeBundle.load(from: result.bundleURL)
    XCTAssertEqual(loaded.manifest.canonicalAccession, "MN908947.3")
}
```

- [ ] **Step 2: Implement the view model**

```swift
@MainActor
final class PrimerSchemeImportViewModel {
    struct Result {
        let bundleURL: URL
    }

    func `import`(
        bedURL: URL,
        fastaURL: URL?,
        attachments: [URL],
        name: String,
        displayName: String,
        canonicalAccession: String,
        equivalentAccessions: [String],
        projectURL: URL
    ) throws -> Result {
        let safeName = name.replacingOccurrences(of: "/", with: "_")
        let folder = try PrimerSchemesFolder.ensureFolder(in: projectURL)
        let bundleURL = folder.appendingPathComponent("\(safeName).lungfishprimers", isDirectory: true)

        // Count primers and amplicons by parsing the BED once.
        let (primerCount, ampliconCount) = try parseCounts(bedURL: bedURL)

        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: bedURL, to: bundleURL.appendingPathComponent("primers.bed"))
        if let fastaURL {
            try FileManager.default.copyItem(at: fastaURL, to: bundleURL.appendingPathComponent("primers.fasta"))
        }

        let attachmentsDir = bundleURL.appendingPathComponent("attachments", isDirectory: true)
        if !attachments.isEmpty {
            try FileManager.default.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)
            for att in attachments {
                try FileManager.default.copyItem(at: att, to: attachmentsDir.appendingPathComponent(att.lastPathComponent))
            }
        }

        let manifest = PrimerSchemeManifest(
            schemaVersion: 1,
            name: safeName,
            displayName: displayName,
            description: nil,
            organism: nil,
            referenceAccessions: [.init(accession: canonicalAccession, canonical: true, equivalent: false)]
                + equivalentAccessions.map { .init(accession: $0, canonical: false, equivalent: true) },
            primerCount: primerCount,
            ampliconCount: ampliconCount,
            source: "imported",
            sourceURL: nil,
            version: nil,
            created: Date(),
            imported: Date(),
            attachments: attachments.map { .init(path: "attachments/\($0.lastPathComponent)", description: nil) }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: bundleURL.appendingPathComponent("manifest.json"))

        let provenance = """
            # PROVENANCE
            
            Imported via Lungfish Genome Explorer on \(Date()).
            BED source: \(bedURL.path)
            """
        try provenance.write(to: bundleURL.appendingPathComponent("PROVENANCE.md"), atomically: true, encoding: .utf8)

        return Result(bundleURL: bundleURL)
    }

    private func parseCounts(bedURL: URL) throws -> (primers: Int, amplicons: Int) {
        let content = try String(contentsOf: bedURL, encoding: .utf8)
        let lines = content.split(separator: "\n").filter { !$0.isEmpty && !$0.starts(with: "#") }
        let primerCount = lines.count
        let ampliconNames = Set(lines.compactMap { line -> String? in
            let cols = line.split(separator: "\t")
            guard cols.count >= 4 else { return nil }
            let name = String(cols[3])
            return name.replacingOccurrences(of: "_LEFT", with: "")
                       .replacingOccurrences(of: "_RIGHT", with: "")
        })
        return (primerCount, ampliconNames.count)
    }
}
```

- [ ] **Step 3: Add `PrimerSchemeImportView.swift`**

SwiftUI form that collects the inputs and drives the view model. Modeled on whatever existing import-center form the reference-sequence import uses; if there isn't one that's a close match, build the simplest possible form with file pickers and text fields.

- [ ] **Step 4: Register the entry in `ImportCenterView`**

Add a new case/button labeled "Import Primer Scheme…" that presents `PrimerSchemeImportView`.

- [ ] **Step 5: Run and confirm tests PASS**

```bash
swift test --filter PrimerSchemeImportTests
```

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/Views/ImportCenter/PrimerSchemeImport*.swift Sources/LungfishApp/Views/ImportCenter/ImportCenterView.swift Sources/LungfishApp/Views/ImportCenter/ImportCenterViewModel.swift Tests/LungfishAppTests/PrimerTrim/PrimerSchemeImportTests.swift
git commit -m "feat(import): add Primer Scheme import flow to Import Center

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 15: Sidebar — Primer Schemes group + inspector

**Files:**
- Modify: `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift`
- Create: `Sources/LungfishApp/Views/Sidebar/PrimerSchemeInspectorView.swift`
- Test: `Tests/LungfishAppTests/PrimerTrim/PrimerSchemeSidebarTests.swift`

- [ ] **Step 1: Write a failing test**

A sidebar test is necessarily more integration-like; follow the pattern of whatever sidebar tests already exist (e.g., `SidebarFilterTests`).

```swift
func testSidebarListsPrimerSchemeBundles() throws {
    let tmpProject = makeProjectWithPrimerBundle()
    let controller = SidebarViewController(projectURL: tmpProject)
    controller.loadProject()

    XCTAssertTrue(controller.containsSidebarItem(withTitle: "Primer Schemes"))
    XCTAssertTrue(controller.containsSidebarItem(withTitle: "QIASeqDIRECT-SARS2"))
}

func testBEDFileInsidePrimerSchemeBundleIsNotExposedAsIndependentItem() throws {
    let tmpProject = makeProjectWithPrimerBundle()
    let controller = SidebarViewController(projectURL: tmpProject)
    controller.loadProject()

    // The BED inside the bundle should NOT appear as a sidebar item.
    XCTAssertFalse(controller.containsSidebarItem(withTitle: "primers.bed"))
}
```

- [ ] **Step 2: Extend `SidebarViewController` with a `Primer Schemes` group**

Find the existing group-creation code (search for `Reference Sequences` or similar labels). Add a parallel section for `Primer Schemes/`, populated from `PrimerSchemesFolder.listBundles(in: projectURL)`. Ensure the scanner does not descend into `.lungfishprimers` bundles — treat them as opaque units in the sidebar.

- [ ] **Step 3: Build the inspector view**

```swift
struct PrimerSchemeInspectorView: View {
    let bundle: PrimerSchemeBundle

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(bundle.manifest.displayName).font(.title2)
            Text("\(bundle.manifest.primerCount) primers, \(bundle.manifest.ampliconCount) amplicons")
                .foregroundStyle(.secondary)
            if let source = bundle.manifest.source {
                Text("Source: \(source)").font(.caption)
            }
            Text("Reference: \(bundle.manifest.canonicalAccession)").font(.caption)
            if !bundle.manifest.equivalentAccessions.isEmpty {
                Text("Equivalent: \(bundle.manifest.equivalentAccessions.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // ...BED table, FASTA list, attachments...
        }
    }
}
```

- [ ] **Step 4: Run and confirm PASS**

```bash
swift test --filter PrimerSchemeSidebarTests
```

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift Sources/LungfishApp/Views/Sidebar/PrimerSchemeInspectorView.swift Tests/LungfishAppTests/PrimerTrim/PrimerSchemeSidebarTests.swift
git commit -m "feat(app): add Primer Schemes sidebar group and inspector

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 16: Integration test — primer-trim then iVar

**Files:**
- Create: `Tests/LungfishIntegrationTests/PrimerTrim/PrimerTrimThenIVarTests.swift`

- [ ] **Step 1: Write the test**

```swift
func testPrimerTrimThenIVarCallsVariantsWithoutAttestationWarning() async throws {
    let sourceBAM = TestFixtures.sarscov2.mappedBAM
    let scheme = try PrimerSchemeBundle.load(from: TestFixtures.qiaseqDirectSARS2.bundleURL)
    let tmp = makeTempDir()
    defer { try? FileManager.default.removeItem(at: tmp) }

    let trimOutput = tmp.appendingPathComponent("trimmed.bam")
    _ = try await BAMPrimerTrimPipeline.run(
        BAMPrimerTrimRequest(sourceBAMURL: sourceBAM, primerSchemeBundle: scheme, outputBAMURL: trimOutput),
        targetReferenceName: "MN908947.3",
        runner: .shared
    )

    // Place the trimmed BAM into a bundle and verify the variant-calling dialog state auto-confirms.
    let bundle = TestBundles.wrap(bam: trimOutput)
    let state = await MainActor.run { BAMVariantCallingDialogState(bundle: bundle) }
    await MainActor.run {
        state.selectCaller(.ivar)
        XCTAssertTrue(state.ivarPrimerTrimConfirmed)
        XCTAssertTrue(state.readinessText.contains("Primer-trimmed by Lungfish"))
    }
}
```

- [ ] **Step 2: Run and confirm PASS**

```bash
swift test --filter PrimerTrimThenIVarTests
```

- [ ] **Step 3: Commit**

```bash
git add Tests/LungfishIntegrationTests/PrimerTrim/PrimerTrimThenIVarTests.swift
git commit -m "test(integration): end-to-end primer-trim then iVar auto-confirm

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 17: Integration test — equivalent-accession BED rewrite

**Files:**
- Create: `Tests/LungfishIntegrationTests/PrimerTrim/PrimerSchemeEquivalentAccessionTests.swift`

- [ ] **Step 1: Write the test**

```swift
func testPrimerTrimWorksAgainstBAMWithEquivalentAccession() async throws {
    // Synthesize a BAM whose @SQ SN is NC_045512.2 (instead of the bundle's canonical MN908947.3).
    let bam = try await synthesizeBAMWithReferenceName("NC_045512.2", fromFixture: TestFixtures.sarscov2)

    let scheme = try PrimerSchemeBundle.load(from: TestFixtures.qiaseqDirectSARS2.bundleURL)
    let tmp = makeTempDir()
    defer { try? FileManager.default.removeItem(at: tmp) }

    let output = tmp.appendingPathComponent("trimmed.bam")
    let result = try await BAMPrimerTrimPipeline.run(
        BAMPrimerTrimRequest(sourceBAMURL: bam, primerSchemeBundle: scheme, outputBAMURL: output),
        targetReferenceName: "NC_045512.2",
        runner: .shared
    )

    XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputBAMURL.path))
    XCTAssertEqual(result.provenance.primerScheme.canonicalAccession, "MN908947.3")
}
```

If the synthesis helper is too heavyweight for this spec, substitute a smaller test that directly asserts `PrimerSchemeResolver.resolve(..., targetReferenceName: "NC_045512.2")` produces a rewritten BED whose first column is `NC_045512.2`. The resolver test in Task 3 already covers that case, so this integration test can be optional if the synthesis helper is nontrivial.

- [ ] **Step 2: Run and confirm PASS**

```bash
swift test --filter PrimerSchemeEquivalentAccessionTests
```

- [ ] **Step 3: Commit**

```bash
git add Tests/LungfishIntegrationTests/PrimerTrim/PrimerSchemeEquivalentAccessionTests.swift
git commit -m "test(integration): primer-trim works against BAM using equivalent accession

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 18: XCUI tests — primer-trim button opens dialog; auto-confirm visible

**Files:**
- Create: `Tests/LungfishXCUITests/PrimerTrim/PrimerTrimXCUITests.swift`
- Create: `Tests/LungfishXCUITests/PrimerTrim/VariantCallingAutoConfirmXCUITests.swift`

These tests launch the app via XCUI.

- [ ] **Step 1: Write `PrimerTrimXCUITests`**

```swift
final class PrimerTrimXCUITests: XCTestCase {
    func testInspectorExposesPrimerTrimButtonAndOpensDialog() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--open-fixture", "sarscov2-mapped-bundle"]
        app.launch()

        let primerTrimButton = app.buttons["Primer-trim BAM…"]
        XCTAssertTrue(primerTrimButton.waitForExistence(timeout: 10))
        primerTrimButton.click()

        XCTAssertTrue(app.windows["Primer-trim BAM"].waitForExistence(timeout: 5))

        // Select the built-in QIASeq scheme.
        let schemeRow = app.buttons["QIASeq Direct SARS-CoV-2"]
        XCTAssertTrue(schemeRow.waitForExistence(timeout: 5))
        schemeRow.click()

        let runButton = app.buttons["Run"]
        XCTAssertTrue(runButton.isEnabled)
    }
}
```

The `--open-fixture` launch arg assumes the app supports a test-mode fixture opener; if it doesn't, use whatever mechanism the existing XCUI tests use (e.g., simulating menu clicks).

- [ ] **Step 2: Write `VariantCallingAutoConfirmXCUITests`**

```swift
final class VariantCallingAutoConfirmXCUITests: XCTestCase {
    func testVariantCallingDialogAutoConfirmsTrimForLungfishTrimmedBAM() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--open-fixture", "sarscov2-primer-trimmed-bundle"]
        app.launch()

        app.buttons["Call Variants…"].click()
        XCTAssertTrue(app.windows["Call Variants"].waitForExistence(timeout: 5))

        app.buttons["iVar"].click()

        let toggle = app.checkBoxes["This BAM has already been primer-trimmed for iVar."]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertFalse(toggle.isEnabled)

        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Primer-trimmed by Lungfish'")).firstMatch.exists)
    }
}
```

- [ ] **Step 3: Add two XCUI fixture project snapshots to `Tests/Fixtures/xcui/`**

`sarscov2-mapped-bundle/` and `sarscov2-primer-trimmed-bundle/` — small project folders with a single pre-computed alignment bundle. These can be bootstrapped by a helper script that Track 2 also uses.

- [ ] **Step 4: Run XCUI tests**

```bash
xcodebuild -scheme Lungfish -destination 'platform=macOS,arch=arm64' test -only-testing:LungfishXCUITests/PrimerTrimXCUITests -only-testing:LungfishXCUITests/VariantCallingAutoConfirmXCUITests
```
Expected: both PASS.

- [ ] **Step 5: Commit**

```bash
git add Tests/LungfishXCUITests/PrimerTrim Tests/Fixtures/xcui
git commit -m "test(xcui): primer-trim dialog surfaces + auto-confirm behavior

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 19: Ensure `Primer Schemes/` folder is created when a project is created

**Files:**
- Modify: wherever project folder creation is centralized. Candidates based on repo structure: `AnalysesFolder.swift`, `ReferenceSequenceFolder.swift`, or a dedicated project-init code path in `Sources/LungfishIO/Bundles/`. The implementer finds this by:
  ```bash
  grep -rn "Reference Sequences\|Downloads\|createDirectory" Sources/LungfishIO/Bundles/ | grep -iE "project|init"
  ```

- [ ] **Step 1: Find the project-init code**

- [ ] **Step 2: Add `try PrimerSchemesFolder.ensureFolder(in: projectURL)` to it**

- [ ] **Step 3: Add a unit test covering that project creation ensures the primer-schemes folder exists**

- [ ] **Step 4: Run tests and commit**

```bash
git add Sources/LungfishIO Tests/LungfishIOTests
git commit -m "feat(io): create Primer Schemes folder on project init

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 20: Final verification and push

- [ ] **Step 1: Run the full test suite**

```bash
swift test 2>&1 | tail -20
```
Expected: all tests PASS. Flag any pre-existing failures as unrelated (cross-reference MEMORY notes on known flaky network-dependent tests like `testSRASearch`).

- [ ] **Step 2: Run XCUI tests**

```bash
xcodebuild -scheme Lungfish -destination 'platform=macOS,arch=arm64' test -only-testing:LungfishXCUITests
```

- [ ] **Step 3: Build the app once, launch, and smoke-test manually**

Launch the app from the worktree. Create a new project. Open the SARS-CoV-2 fixture reference and a mapped BAM. Verify: Inspector shows "Primer-trim BAM…" button, clicking opens the dialog, QIASeqDIRECT-SARS2 appears under Built-in. Close without running.

- [ ] **Step 4: Push and open PR**

```bash
git push -u origin track1-bam-primer-trim
gh pr create --title "feat: BAM primer-trim operation + .lungfishprimers bundles" --body "$(cat <<'EOF'
## Summary

- Adds a first-class BAM primer-trim operation, surfaced in the BAM Inspector's Analysis section alongside "Call Variants…".
- Introduces `.lungfishprimers` bundles as a new project-level type with both BED and FASTA as peer artifacts, plus arbitrary attachments.
- Supports equivalent reference accessions (e.g., MN908947.3 ≡ NC_045512.2) with byte-identical-sequence verification at bundle-build time and on-the-fly BED rewriting at use time.
- Ships the canonical `QIASeqDIRECT-SARS2.lungfishprimers` bundle as a built-in asset and a test fixture.
- Updates the variant calling dialog to auto-confirm the iVar primer-trim checkbox for Lungfish-trimmed BAMs.

Spec: `docs/superpowers/specs/2026-04-24-bam-primer-trim-and-primer-scheme-bundles-design.md`

## Test plan

- [ ] `swift test` passes.
- [ ] XCUI tests for primer-trim dialog and auto-confirm behavior pass.
- [ ] Manual smoke: import QIASeq bundle (built-in) → primer-trim a fixture BAM → call variants with iVar → confirm auto-attest.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## "Done" criteria

- Primer-trim BAM operation appears in the BAM Inspector's Analysis section as a "Primer-trim BAM…" button, gated on the `variant-calling` pack.
- `BAMPrimerTrimDialog` opens, allows scheme selection from built-in + project-local + filesystem, runs `ivar trim`, and emits a sorted, indexed BAM with provenance sidecar JSON.
- Output BAM sidecar records `{operation: primer-trim, primer_scheme, source_bam, ivar_version, ivar_trim_args, timestamp}`.
- BAM variant calling dialog auto-confirms the primer-trim checkbox when selecting a Lungfish-trimmed BAM, with a caption documenting scheme + date.
- `QIASeqDIRECT-SARS2.lungfishprimers` ships in `Sources/LungfishApp/Resources/PrimerSchemes/`, validates, is discoverable from the picker, and passes the end-to-end integration test.
- Import Center can import an arbitrary BED (+ optional FASTA + attachments) into a project-local `.lungfishprimers` bundle.
- `Primer Schemes/` group appears in the sidebar; `.lungfishprimers` bundles appear as opaque items; the inspector renders manifest + BED + FASTA + attachments.
- All unit, integration, and XCUI tests pass.
- A PR exists on GitHub titled `feat: BAM primer-trim operation + .lungfishprimers bundles`.
