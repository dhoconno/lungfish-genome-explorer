# Bundle Alignment BAM Filtering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Inspector-driven BAM filtering for any bundle-associated alignment track, producing sibling derived alignment tracks with explicit provenance and support for active duplicate removal.

**Architecture:** Keep BAM filtering bundle-centric. Build one shared `AlignmentFilterService` in `LungfishApp` that resolves a source `AlignmentTrackInfo`, optionally runs duplicate preprocessing, executes `samtools view/sort/index`, imports the output back into the same bundle as a new alignment track, and writes derivation provenance. Reuse that same bundle-track workflow for mapping viewer bundles, which are copied `.lungfishref` bundles nested inside mapping analysis directories.

**Tech Stack:** Swift, SwiftPM/XCTest, LungfishApp services, LungfishCore bundle manifests, LungfishIO alignment metadata DB, LungfishWorkflow native tool execution via `samtools`

---

## File Structure

### New Files

- `Sources/LungfishApp/Services/AlignmentFilterModels.swift`
  - Request/result/provenance types for derived BAM filtering.
- `Sources/LungfishApp/Services/AlignmentFilterCommandBuilder.swift`
  - Pure command-building logic for `samtools view` flags, expressions, and human-readable summaries.
- `Sources/LungfishApp/Services/AlignmentMarkdupPipeline.swift`
  - Shared duplicate-marking helper extracted from `AlignmentDuplicateService` so BAM filtering can actively remove duplicates without duplicating shell orchestration.
- `Sources/LungfishApp/Services/AlignmentFilterService.swift`
  - Bundle-track derivation workflow: preflight, optional duplicate preprocessing, filter, sort, index, import, provenance.
- `Tests/LungfishAppTests/AlignmentFilterCommandBuilderTests.swift`
  - Pure tests for filter flags, expressions, summaries, and validation requirements.
- `Tests/LungfishAppTests/AlignmentFilterServiceTests.swift`
  - Service tests for duplicate preprocessing, missing-tag failures, sidecar writing, and import integration.
- `Tests/LungfishAppTests/AlignmentFilterInspectorStateTests.swift`
  - View-model tests for Inspector filter state, output naming, and request construction.

### Modified Files

- `Sources/LungfishApp/Services/AlignmentDuplicateService.swift`
  - Reuse shared markdup helper instead of keeping duplicate pipeline logic private.
- `Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift`
  - Add BAM filtering state, Inspector controls, workflow callback, derived-track metadata rows, and richer provenance display.
- `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
  - Wire Inspector BAM filtering actions, launch `AlignmentFilterService`, refresh normal bundles and mapping viewer bundles after success.
- `Sources/LungfishApp/Views/Results/Mapping/MappingResultViewController.swift`
  - Add explicit embedded viewer-bundle reload hook after a derived track is added.
- `Sources/LungfishApp/Views/Viewer/ViewerViewController+Mapping.swift`
  - Expose a small public helper to reload the mapping result’s embedded viewer bundle.
- `Tests/LungfishAppTests/AlignmentDuplicateServiceTests.swift`
  - Cover the extracted markdup helper behavior at the service boundary.
- `Tests/LungfishAppTests/InspectorMappingModeTests.swift`
  - Cover BAM filtering workflow availability for mapping viewer bundles.
- `Tests/LungfishAppTests/MappingResultViewControllerTests.swift`
  - Cover viewer-bundle reload after bundle-backed BAM changes.

## Task 1: Add Pure BAM Filter Models and Command Builder

**Files:**
- Create: `Sources/LungfishApp/Services/AlignmentFilterModels.swift`
- Create: `Sources/LungfishApp/Services/AlignmentFilterCommandBuilder.swift`
- Test: `Tests/LungfishAppTests/AlignmentFilterCommandBuilderTests.swift`

- [x] **Step 1: Write the failing command-builder tests**

```swift
import XCTest
@testable import LungfishApp

final class AlignmentFilterCommandBuilderTests: XCTestCase {
    func testMappedPrimaryDuplicateExcludedExactMatchBuildsFlagsAndExpression() throws {
        let request = AlignmentFilterRequest(
            sourceTrackID: "track-1",
            sourceTrackName: "Example",
            outputTrackName: "Example [filtered exact-match]",
            minimumMAPQ: 20,
            mappedOnly: true,
            primaryOnly: true,
            properPairsOnly: false,
            bothMatesMapped: false,
            duplicateMode: .excludeMarked,
            identityFilter: .exactMatchesOnly,
            regions: []
        )

        let plan = try AlignmentFilterCommandBuilder.build(
            request: request,
            inputBAMURL: URL(fileURLWithPath: "/tmp/in.bam"),
            outputBAMURL: URL(fileURLWithPath: "/tmp/out.filtered.bam")
        )

        XCTAssertEqual(plan.requiredTags, ["NM"])
        XCTAssertTrue(plan.arguments.contains("-q"))
        XCTAssertTrue(plan.arguments.contains("20"))
        XCTAssertTrue(plan.arguments.contains("-F"))
        XCTAssertTrue(plan.arguments.contains("3332"))
        XCTAssertTrue(plan.arguments.contains("-e"))
        XCTAssertTrue(plan.arguments.contains("exists([NM]) && [NM] == 0"))
        XCTAssertEqual(plan.summary, "MAPQ ≥ 20; mapped only; primary only; duplicate-marked reads excluded; exact matches only")
    }

    func testMinimumIdentityBuildsNMExpressionFromAlignedQueryBases() throws {
        let request = AlignmentFilterRequest(
            sourceTrackID: "track-1",
            sourceTrackName: "Example",
            outputTrackName: "Example [filtered id99]",
            minimumMAPQ: 0,
            mappedOnly: true,
            primaryOnly: false,
            properPairsOnly: false,
            bothMatesMapped: false,
            duplicateMode: .keepAll,
            identityFilter: .minimumPercent(99.0),
            regions: []
        )

        let plan = try AlignmentFilterCommandBuilder.build(
            request: request,
            inputBAMURL: URL(fileURLWithPath: "/tmp/in.bam"),
            outputBAMURL: URL(fileURLWithPath: "/tmp/out.filtered.bam")
        )

        XCTAssertEqual(plan.requiredTags, ["NM"])
        XCTAssertTrue(plan.arguments.contains("-e"))
        XCTAssertTrue(
            plan.arguments.contains("exists([NM]) && qlen > sclen && (((qlen-sclen)-[NM])/(qlen-sclen)) >= 0.99")
        )
        XCTAssertEqual(plan.summary, "mapped only; identity ≥ 99.0%")
    }
}
```

- [x] **Step 2: Run the tests to verify they fail**

Run:

```bash
swift test --filter AlignmentFilterCommandBuilderTests
```

Expected: FAIL with errors such as `cannot find 'AlignmentFilterRequest' in scope`.

- [x] **Step 3: Add the filter request/provenance model types**

```swift
import Foundation

public enum AlignmentFilterDuplicateMode: String, Codable, Sendable, CaseIterable {
    case keepAll
    case excludeMarked
    case remove
}

public enum AlignmentFilterIdentityFilter: Sendable, Equatable, Codable {
    case none
    case exactMatchesOnly
    case minimumPercent(Double)
}

public struct AlignmentFilterRequest: Sendable, Equatable, Codable {
    public let sourceTrackID: String
    public let sourceTrackName: String
    public let outputTrackName: String
    public let minimumMAPQ: Int
    public let mappedOnly: Bool
    public let primaryOnly: Bool
    public let properPairsOnly: Bool
    public let bothMatesMapped: Bool
    public let duplicateMode: AlignmentFilterDuplicateMode
    public let identityFilter: AlignmentFilterIdentityFilter
    public let regions: [String]
}

public struct AlignmentFilterCommandPlan: Sendable, Equatable {
    public let arguments: [String]
    public let requiredTags: [String]
    public let summary: String
}

public enum AlignmentFilterError: Error, LocalizedError, Sendable, Equatable {
    case invalidPercentIdentity(String)
    case conflictingIdentityFilters
    case duplicateRemovalUnavailable(String)
    case missingRequiredTags([String])

    public var errorDescription: String? {
        switch self {
        case .invalidPercentIdentity(let value):
            return "Percent identity must be a number between 0 and 100, got '\(value)'."
        case .conflictingIdentityFilters:
            return "Choose either exact matches or minimum percent identity, not both."
        case .duplicateRemovalUnavailable(let reason):
            return reason
        case .missingRequiredTags(let tags):
            return "The source BAM is missing required alignment tags: \(tags.joined(separator: ", "))."
        }
    }
}
```

- [x] **Step 4: Implement the pure command builder**

```swift
import Foundation

enum AlignmentFilterCommandBuilder {
    static func build(
        request: AlignmentFilterRequest,
        inputBAMURL: URL,
        outputBAMURL: URL
    ) throws -> AlignmentFilterCommandPlan {
        var arguments = ["view", "-b", "-o", outputBAMURL.path]
        var summaryParts: [String] = []
        var excludedFlags = 0
        var requiredFlags = 0
        var requiredTags: [String] = []

        if request.minimumMAPQ > 0 {
            arguments += ["-q", String(request.minimumMAPQ)]
            summaryParts.append("MAPQ ≥ \(request.minimumMAPQ)")
        }
        if request.mappedOnly {
            excludedFlags |= 0x4
            summaryParts.append("mapped only")
        }
        if request.primaryOnly {
            excludedFlags |= 0x100
            excludedFlags |= 0x800
            summaryParts.append("primary only")
        }
        if request.properPairsOnly {
            requiredFlags |= 0x2
            summaryParts.append("proper pairs only")
        }
        if request.bothMatesMapped {
            requiredFlags |= 0x1
            excludedFlags |= 0x4
            excludedFlags |= 0x8
            summaryParts.append("both mates mapped")
        }

        switch request.duplicateMode {
        case .keepAll:
            break
        case .excludeMarked, .remove:
            excludedFlags |= 0x400
            summaryParts.append(request.duplicateMode == .remove ? "duplicates removed" : "duplicate-marked reads excluded")
        }

        if requiredFlags > 0 {
            arguments += ["-f", String(requiredFlags)]
        }
        if excludedFlags > 0 {
            arguments += ["-F", String(excludedFlags)]
        }

        switch request.identityFilter {
        case .none:
            break
        case .exactMatchesOnly:
            requiredTags = ["NM"]
            arguments += ["-e", "exists([NM]) && [NM] == 0"]
            summaryParts.append("exact matches only")
        case .minimumPercent(let percent):
            let threshold = percent / 100.0
            requiredTags = ["NM"]
            arguments += ["-e", "exists([NM]) && qlen > sclen && (((qlen-sclen)-[NM])/(qlen-sclen)) >= \(String(format: "%.2f", threshold))"]
            summaryParts.append(String(format: "identity ≥ %.1f%%", percent))
        }

        arguments.append(inputBAMURL.path)
        arguments.append(contentsOf: request.regions)

        return AlignmentFilterCommandPlan(
            arguments: arguments,
            requiredTags: requiredTags,
            summary: summaryParts.joined(separator: "; ")
        )
    }
}
```

- [x] **Step 5: Run the tests to verify they pass**

Run:

```bash
swift test --filter AlignmentFilterCommandBuilderTests
```

Expected: PASS with `Executed 2 tests`.

- [x] **Step 6: Commit**

```bash
git add \
  Sources/LungfishApp/Services/AlignmentFilterModels.swift \
  Sources/LungfishApp/Services/AlignmentFilterCommandBuilder.swift \
  Tests/LungfishAppTests/AlignmentFilterCommandBuilderTests.swift
git commit -m "feat: add BAM filter command builder"
```

## Task 2: Build the Shared Filter Service and Extract the Markdup Helper

**Files:**
- Create: `Sources/LungfishApp/Services/AlignmentMarkdupPipeline.swift`
- Create: `Sources/LungfishApp/Services/AlignmentFilterService.swift`
- Modify: `Sources/LungfishApp/Services/AlignmentDuplicateService.swift`
- Test: `Tests/LungfishAppTests/AlignmentFilterServiceTests.swift`
- Test: `Tests/LungfishAppTests/AlignmentDuplicateServiceTests.swift`

- [x] **Step 1: Write the failing service tests**

```swift
import XCTest
@testable import LungfishApp
@testable import LungfishCore

final class AlignmentFilterServiceTests: XCTestCase {
    func testCreateFilteredTrackFailsWhenNMIsRequiredButMissing() async throws {
        let service = AlignmentFilterService(
            samtoolsRunner: RecordingSamtoolsRunner(sampleViewOutput: "read1\t0\tchr1\t1\t60\t10M\t*\t0\t0\tACGT\tFFFF\n"),
            markdupPipeline: RecordingMarkdupPipeline(),
            bamImporter: { _, _, _, _ in
                XCTFail("Import should not be called when preflight fails")
                throw CancellationError()
            }
        )

        do {
            try await service.validateRequiredTags(
                requiredTags: ["NM"],
                bamURL: URL(fileURLWithPath: "/tmp/source.bam")
            )
            XCTFail("Expected missingRequiredTags error")
        } catch {
            XCTAssertEqual(error as? AlignmentFilterError, .missingRequiredTags(["NM"]))
        }
    }

    func testCreateFilteredTrackRunsDuplicatePreprocessingBeforeView() async throws {
        let runner = RecordingSamtoolsRunner(sampleViewOutput: "read1\t0\tchr1\t1\t60\t10M\t*\t0\t0\tACGT\tFFFF\tNM:i:0\n")
        let markdup = RecordingMarkdupPipeline()
        let service = AlignmentFilterService(
            samtoolsRunner: runner,
            markdupPipeline: markdup,
            bamImporter: { _, _, _, _ in
                BAMImportService.ImportResult(
                    trackInfo: AlignmentTrackInfo(
                        id: "derived",
                        name: "Derived",
                        sourcePath: "alignments/derived.bam",
                        indexPath: "alignments/derived.bam.bai"
                    ),
                    mappedReads: 10,
                    unmappedReads: 0,
                    sampleNames: [],
                    indexWasCreated: false,
                    wasSorted: false
                )
            }
        )

        let request = AlignmentFilterRequest(
            sourceTrackID: "track-1",
            sourceTrackName: "Example",
            outputTrackName: "Example [deduplicated filtered]",
            minimumMAPQ: 0,
            mappedOnly: true,
            primaryOnly: false,
            properPairsOnly: false,
            bothMatesMapped: false,
            duplicateMode: .remove,
            identityFilter: .none,
            regions: []
        )

        _ = try await service.runPipelineForTesting(
            request: request,
            sourceBAMURL: URL(fileURLWithPath: "/tmp/source.bam"),
            bundleURL: URL(fileURLWithPath: "/tmp/example.lungfishref"),
            outputRoot: URL(fileURLWithPath: "/tmp/example.lungfishref/alignments/filtered")
        )

        XCTAssertEqual(markdup.invocationCount, 1)
        XCTAssertTrue(runner.recordedCommands.contains { $0.first == "view" })
    }
}
```

- [x] **Step 2: Run the tests to verify they fail**

Run:

```bash
swift test --filter AlignmentFilterServiceTests
```

Expected: FAIL with errors such as `cannot find 'AlignmentFilterService' in scope`.

- [x] **Step 3: Extract the shared markdup helper and switch duplicate workflows to it**

```swift
import Foundation
import LungfishWorkflow

protocol AlignmentSamtoolsRunning: Sendable {
    func run(arguments: [String], timeout: TimeInterval) async throws -> (stdout: String, stderr: String, exitCode: Int32)
}

struct NativeSamtoolsRunner: AlignmentSamtoolsRunning {
    private let runner: NativeToolRunner

    init(runner: NativeToolRunner = .shared) {
        self.runner = runner
    }

    func run(arguments: [String], timeout: TimeInterval) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let result = try await runner.run(.samtools, arguments: arguments, timeout: timeout)
        return (result.stdout, result.stderr, result.exitCode)
    }
}

protocol AlignmentMarkdupRunning: Sendable {
    func run(
        inputURL: URL,
        outputURL: URL,
        removeDuplicates: Bool,
        referenceFastaPath: String?,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) async throws
}

struct AlignmentMarkdupPipeline: AlignmentMarkdupRunning {
    private let runner: NativeToolRunner

    init(runner: NativeToolRunner = .shared) {
        self.runner = runner
    }

    func run(
        inputURL: URL,
        outputURL: URL,
        removeDuplicates: Bool,
        referenceFastaPath: String?,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) async throws {
        let tempDir = outputURL.deletingLastPathComponent().appendingPathComponent(".markdup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let nameSortedURL = tempDir.appendingPathComponent("name.sorted.bam")
        let fixmateURL = tempDir.appendingPathComponent("fixmate.bam")
        let coordSortedURL = tempDir.appendingPathComponent("coord.sorted.bam")

        var sortNameArgs = ["sort", "-n", "-o", nameSortedURL.path]
        if let referenceFastaPath { sortNameArgs += ["--reference", referenceFastaPath] }
        sortNameArgs.append(inputURL.path)
        _ = try await NativeSamtoolsRunner(runner: runner).run(arguments: sortNameArgs, timeout: 3600)

        var fixmateArgs = ["fixmate", "-m"]
        if let referenceFastaPath { fixmateArgs += ["--reference", referenceFastaPath] }
        fixmateArgs += [nameSortedURL.path, fixmateURL.path]
        _ = try await NativeSamtoolsRunner(runner: runner).run(arguments: fixmateArgs, timeout: 3600)

        var sortCoordArgs = ["sort", "-o", coordSortedURL.path]
        if let referenceFastaPath { sortCoordArgs += ["--reference", referenceFastaPath] }
        sortCoordArgs.append(fixmateURL.path)
        _ = try await NativeSamtoolsRunner(runner: runner).run(arguments: sortCoordArgs, timeout: 3600)

        var markdupArgs = ["markdup"]
        if removeDuplicates { markdupArgs.append("-r") }
        markdupArgs += [coordSortedURL.path, outputURL.path]
        _ = try await NativeSamtoolsRunner(runner: runner).run(arguments: markdupArgs, timeout: 3600)

        _ = try await NativeSamtoolsRunner(runner: runner).run(arguments: ["index", outputURL.path], timeout: 600)
    }
}
```

```swift
// AlignmentDuplicateService.swift
private static func runMarkdupPipeline(
    inputURL: URL,
    outputURL: URL,
    removeDuplicates: Bool,
    referenceFastaPath: String?,
    progressHandler: (@Sendable (Double, String) -> Void)?
) async throws {
    try await AlignmentMarkdupPipeline().run(
        inputURL: inputURL,
        outputURL: outputURL,
        removeDuplicates: removeDuplicates,
        referenceFastaPath: referenceFastaPath,
        progressHandler: progressHandler
    )
}
```

- [x] **Step 4: Implement the filter service with sidecar/provenance writing**

```swift
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

final class AlignmentFilterService: @unchecked Sendable {
    typealias BAMImporter = @Sendable (URL, URL, String?, (@Sendable (Double, String) -> Void)?) async throws -> BAMImportService.ImportResult

    private let samtoolsRunner: AlignmentSamtoolsRunning
    private let markdupPipeline: AlignmentMarkdupRunning
    private let bamImporter: BAMImporter

    init(
        samtoolsRunner: AlignmentSamtoolsRunning = NativeSamtoolsRunner(),
        markdupPipeline: AlignmentMarkdupRunning = AlignmentMarkdupPipeline(),
        bamImporter: @escaping BAMImporter = BAMImportService.importBAM
    ) {
        self.samtoolsRunner = samtoolsRunner
        self.markdupPipeline = markdupPipeline
        self.bamImporter = bamImporter
    }

    func validateRequiredTags(requiredTags: [String], bamURL: URL) async throws {
        guard !requiredTags.isEmpty else { return }
        let result = try await samtoolsRunner.run(arguments: ["view", bamURL.path], timeout: 60)
        let hasNM = result.stdout.contains("\tNM:i:")
        if requiredTags.contains("NM"), !hasNM {
            throw AlignmentFilterError.missingRequiredTags(["NM"])
        }
    }

    func runPipelineForTesting(
        request: AlignmentFilterRequest,
        sourceBAMURL: URL,
        bundleURL: URL,
        outputRoot: URL
    ) async throws -> BAMImportService.ImportResult {
        try await validateRequiredTags(
            requiredTags: try AlignmentFilterCommandBuilder.build(
                request: request,
                inputBAMURL: sourceBAMURL,
                outputBAMURL: outputRoot.appendingPathComponent("unused.bam")
            ).requiredTags,
            bamURL: sourceBAMURL
        )

        let filteredInputURL: URL
        if request.duplicateMode == .remove {
            let markdupURL = outputRoot.appendingPathComponent("\(request.sourceTrackID).markdup.bam")
            try await markdupPipeline.run(
                inputURL: sourceBAMURL,
                outputURL: markdupURL,
                removeDuplicates: false,
                referenceFastaPath: nil,
                progressHandler: nil
            )
            filteredInputURL = markdupURL
        } else {
            filteredInputURL = sourceBAMURL
        }

        let outputBAMURL = outputRoot.appendingPathComponent("\(request.sourceTrackID).filtered.bam")
        let sortedBAMURL = outputRoot.appendingPathComponent("\(request.sourceTrackID).filtered.sorted.bam")
        let plan = try AlignmentFilterCommandBuilder.build(
            request: request,
            inputBAMURL: filteredInputURL,
            outputBAMURL: outputBAMURL
        )

        _ = try await samtoolsRunner.run(arguments: plan.arguments, timeout: 3600)
        _ = try await samtoolsRunner.run(arguments: ["sort", "-o", sortedBAMURL.path, outputBAMURL.path], timeout: 3600)
        _ = try await samtoolsRunner.run(arguments: ["index", sortedBAMURL.path], timeout: 600)

        let importResult = try await bamImporter(sortedBAMURL, bundleURL, request.outputTrackName, nil)
        return importResult
    }
}
```

- [x] **Step 5: Run the targeted tests**

Run:

```bash
swift test --filter 'AlignmentFilterServiceTests|AlignmentDuplicateServiceTests'
```

Expected: PASS with the new service tests green and duplicate-service tests still green.

- [x] **Step 6: Commit**

```bash
git add \
  Sources/LungfishApp/Services/AlignmentMarkdupPipeline.swift \
  Sources/LungfishApp/Services/AlignmentFilterService.swift \
  Sources/LungfishApp/Services/AlignmentDuplicateService.swift \
  Tests/LungfishAppTests/AlignmentFilterServiceTests.swift \
  Tests/LungfishAppTests/AlignmentDuplicateServiceTests.swift
git commit -m "feat: add shared BAM filtering service"
```

## Task 3: Add Inspector State, Controls, and Derived-Track Metadata Display

**Files:**
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift`
- Test: `Tests/LungfishAppTests/AlignmentFilterInspectorStateTests.swift`

- [x] **Step 1: Write the failing Inspector state tests**

```swift
import XCTest
@testable import LungfishApp
@testable import LungfishCore

@MainActor
final class AlignmentFilterInspectorStateTests: XCTestCase {
    func testConfigureAlignmentFilterTracksSeedsDefaultTrackAndOutputName() {
        let vm = ReadStyleSectionViewModel()
        let tracks = [
            AlignmentTrackInfo(id: "a", name: "Sample A", sourcePath: "alignments/a.bam", indexPath: "alignments/a.bam.bai"),
            AlignmentTrackInfo(id: "b", name: "Sample B", sourcePath: "alignments/b.bam", indexPath: "alignments/b.bam.bai")
        ]

        vm.configureAlignmentFilterTracks(tracks)

        XCTAssertEqual(vm.selectedAlignmentFilterTrackID, "a")
        XCTAssertEqual(vm.alignmentFilterOutputTrackName, "Sample A [filtered]")
    }

    func testMakeAlignmentFilterRequestRejectsInvalidPercentIdentityText() {
        let vm = ReadStyleSectionViewModel()
        vm.configureAlignmentFilterTracks([
            AlignmentTrackInfo(id: "a", name: "Sample A", sourcePath: "alignments/a.bam", indexPath: "alignments/a.bam.bai")
        ])
        vm.alignmentFilterMinimumIdentityText = "abc"

        XCTAssertThrowsError(try vm.makeAlignmentFilterRequest()) { error in
            XCTAssertEqual(error as? AlignmentFilterError, .invalidPercentIdentity("abc"))
        }
    }
}
```

- [x] **Step 2: Run the tests to verify they fail**

Run:

```bash
swift test --filter AlignmentFilterInspectorStateTests
```

Expected: FAIL with errors such as `value of type 'ReadStyleSectionViewModel' has no member 'configureAlignmentFilterTracks'`.

- [x] **Step 3: Add filter state and request-construction helpers to the Inspector view model**

```swift
public final class ReadStyleSectionViewModel {
    public var alignmentFilterTrackOptions: [AlignmentTrackInfo] = []
    public var selectedAlignmentFilterTrackID: String = ""
    public var alignmentFilterMappedOnly: Bool = true
    public var alignmentFilterPrimaryOnly: Bool = false
    public var alignmentFilterProperPairsOnly: Bool = false
    public var alignmentFilterBothMatesMapped: Bool = false
    public var alignmentFilterMinimumMAPQ: Double = 0
    public var alignmentFilterDuplicateMode: AlignmentFilterDuplicateMode = .keepAll
    public var alignmentFilterExactMatchesOnly: Bool = false
    public var alignmentFilterMinimumIdentityText: String = ""
    public var alignmentFilterOutputTrackName: String = ""
    public var isAlignmentFilterWorkflowRunning: Bool = false
    public var onCreateFilteredAlignmentRequested: (() -> Void)?

    public func configureAlignmentFilterTracks(_ tracks: [AlignmentTrackInfo]) {
        alignmentFilterTrackOptions = tracks
        if selectedAlignmentFilterTrackID.isEmpty || !tracks.contains(where: { $0.id == selectedAlignmentFilterTrackID }) {
            selectedAlignmentFilterTrackID = tracks.first?.id ?? ""
        }
        refreshAlignmentFilterOutputName()
    }

    public func refreshAlignmentFilterOutputName() {
        guard let track = alignmentFilterTrackOptions.first(where: { $0.id == selectedAlignmentFilterTrackID }) else {
            alignmentFilterOutputTrackName = ""
            return
        }
        let suffix = alignmentFilterDuplicateMode == .remove ? "[deduplicated filtered]" : "[filtered]"
        alignmentFilterOutputTrackName = "\(track.name) \(suffix)"
    }

    public func makeAlignmentFilterRequest() throws -> AlignmentFilterRequest {
        guard let track = alignmentFilterTrackOptions.first(where: { $0.id == selectedAlignmentFilterTrackID }) else {
            throw AlignmentFilterError.duplicateRemovalUnavailable("Choose a source alignment track before running BAM filtering.")
        }

        let identityFilter: AlignmentFilterIdentityFilter
        if alignmentFilterExactMatchesOnly && !alignmentFilterMinimumIdentityText.isEmpty {
            throw AlignmentFilterError.conflictingIdentityFilters
        } else if alignmentFilterExactMatchesOnly {
            identityFilter = .exactMatchesOnly
        } else if alignmentFilterMinimumIdentityText.isEmpty {
            identityFilter = .none
        } else if let percent = Double(alignmentFilterMinimumIdentityText), (0 ... 100).contains(percent) {
            identityFilter = .minimumPercent(percent)
        } else {
            throw AlignmentFilterError.invalidPercentIdentity(alignmentFilterMinimumIdentityText)
        }

        return AlignmentFilterRequest(
            sourceTrackID: track.id,
            sourceTrackName: track.name,
            outputTrackName: alignmentFilterOutputTrackName,
            minimumMAPQ: Int(alignmentFilterMinimumMAPQ.rounded()),
            mappedOnly: alignmentFilterMappedOnly,
            primaryOnly: alignmentFilterPrimaryOnly,
            properPairsOnly: alignmentFilterProperPairsOnly,
            bothMatesMapped: alignmentFilterBothMatesMapped,
            duplicateMode: alignmentFilterDuplicateMode,
            identityFilter: identityFilter,
            regions: []
        )
    }
}
```

- [x] **Step 4: Add the Inspector controls plus richer derived-track metadata/provenance display**

```swift
Divider()

Text("Derived BAM")
    .font(.caption)
    .foregroundStyle(.secondary)

Picker("Source Track", selection: $viewModel.selectedAlignmentFilterTrackID) {
    ForEach(viewModel.alignmentFilterTrackOptions) { track in
        Text(track.name).tag(track.id)
    }
}
.onChange(of: viewModel.selectedAlignmentFilterTrackID) { _, _ in
    viewModel.refreshAlignmentFilterOutputName()
}

Toggle("Mapped reads only", isOn: $viewModel.alignmentFilterMappedOnly)
Toggle("Primary alignments only", isOn: $viewModel.alignmentFilterPrimaryOnly)
Toggle("Proper pairs only", isOn: $viewModel.alignmentFilterProperPairsOnly)
Toggle("Both mates mapped", isOn: $viewModel.alignmentFilterBothMatesMapped)

HStack {
    Text("Minimum MAPQ")
    Spacer()
    Text("\(Int(viewModel.alignmentFilterMinimumMAPQ))")
        .foregroundStyle(.secondary)
        .monospacedDigit()
}
Slider(value: $viewModel.alignmentFilterMinimumMAPQ, in: 0...60, step: 1)

Picker("Duplicates", selection: $viewModel.alignmentFilterDuplicateMode) {
    Text("Keep all").tag(AlignmentFilterDuplicateMode.keepAll)
    Text("Exclude marked").tag(AlignmentFilterDuplicateMode.excludeMarked)
    Text("Remove duplicates").tag(AlignmentFilterDuplicateMode.remove)
}
.onChange(of: viewModel.alignmentFilterDuplicateMode) { _, _ in
    viewModel.refreshAlignmentFilterOutputName()
}

Toggle("Exact matches only", isOn: $viewModel.alignmentFilterExactMatchesOnly)
TextField("Minimum percent identity", text: $viewModel.alignmentFilterMinimumIdentityText)

TextField("Output Track Name", text: $viewModel.alignmentFilterOutputTrackName)

Button("Create Filtered BAM Track") {
    viewModel.onCreateFilteredAlignmentRequested?()
}
.disabled(viewModel.isAlignmentFilterWorkflowRunning || !viewModel.hasAlignmentTracks)
```

```swift
public struct ProvenanceEntry: Identifiable {
    public let stepOrder: Int
    public let tool: String
    public let subcommand: String?
    public let version: String?
    public let command: String
    public let timestamp: String?
    public let duration: TimeInterval?
}

// In loadStatistics(from:)
provenanceList.append(ProvenanceEntry(
    stepOrder: prov.stepOrder,
    tool: prov.tool,
    subcommand: prov.subcommand,
    version: prov.version,
    command: prov.command,
    timestamp: prov.timestamp,
    duration: prov.duration
))
```

```swift
@State private var isTrackMetadataExpanded = false
@State private var expandedProvenanceCommands = Set<Int>()

if !viewModel.fileInfo.isEmpty {
    Divider()
    DisclosureGroup(isExpanded: $isTrackMetadataExpanded) {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(viewModel.fileInfo.filter { $0.key.hasPrefix("derived_") || $0.key == "file_name" }, id: \.key) { entry in
                inlineField(entry.key, value: entry.value)
            }
        }
        .padding(.top, 4)
    } label: {
        Label("Track Metadata", systemImage: "info.circle")
            .font(.headline)
    }
}
```

- [x] **Step 5: Run the targeted tests**

Run:

```bash
swift test --filter AlignmentFilterInspectorStateTests
```

Expected: PASS with the new Inspector-state tests green.

- [x] **Step 6: Commit**

```bash
git add \
  Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift \
  Tests/LungfishAppTests/AlignmentFilterInspectorStateTests.swift
git commit -m "feat: add Inspector BAM filter controls"
```

## Task 4: Wire the Workflow Through Inspector Actions and Refresh Mapping Viewer Bundles

**Files:**
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
- Modify: `Sources/LungfishApp/Views/Results/Mapping/MappingResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+Mapping.swift`
- Test: `Tests/LungfishAppTests/InspectorMappingModeTests.swift`
- Test: `Tests/LungfishAppTests/MappingResultViewControllerTests.swift`

- [x] **Step 1: Write the failing mapping-wiring tests**

```swift
@MainActor
final class InspectorMappingModeTests: XCTestCase {
    func testMappingAlignmentSectionWiresCreateFilteredBAMAction() throws {
        let vc = InspectorViewController()
        _ = vc.view
        let bundle = try makeReferenceBundle()

        vc.updateMappingAlignmentSection(from: bundle, applySettings: { _ in })

        XCTAssertNotNil(vc.readStyleSectionViewModel.onCreateFilteredAlignmentRequested)
    }
}
```

```swift
@MainActor
final class MappingResultViewControllerTests: XCTestCase {
    func testReloadViewerBundleReloadsEmbeddedBundleWhenViewerBundleExists() throws {
        let vc = MappingResultViewController()
        _ = vc.view
        let bundleURL = try makeReferenceBundleWithAnnotationDatabase()

        vc.configureForTesting(result: makeMappingResult(viewerBundleURL: bundleURL))

        XCTAssertNoThrow(try vc.reloadViewerBundleForInspectorChanges())
    }
}
```

- [x] **Step 2: Run the tests to verify they fail**

Run:

```bash
swift test --filter 'InspectorMappingModeTests|MappingResultViewControllerTests'
```

Expected: FAIL with errors such as `value of type 'ReadStyleSectionViewModel' has no member 'onCreateFilteredAlignmentRequested'` or `no member 'reloadViewerBundleForInspectorChanges'`.

- [x] **Step 3: Implement Inspector workflow launch, success reloads, and mapping viewer-bundle refresh**

```swift
// InspectorViewController.swift
private var mappingAlignmentSettingsApplier: (([AnyHashable: Any]) -> Void)?

func updateMappingAlignmentSection(
    from bundle: ReferenceBundle,
    applySettings: @escaping ([AnyHashable: Any]) -> Void
) {
    mappingAlignmentSettingsApplier = applySettings
    viewModel.readStyleSectionViewModel.loadStatistics(from: bundle)
    viewModel.readStyleSectionViewModel.configureAlignmentFilterTracks(
        bundle.alignmentTrackIds.compactMap { bundle.alignmentTrack(id: $0) }
    )
    viewModel.readStyleSectionViewModel.onCreateFilteredAlignmentRequested = { [weak self] in
        self?.runCreateFilteredAlignmentWorkflow()
    }
    applySettings(makeReadDisplaySettingsPayload(from: viewModel.readStyleSectionViewModel))
}

private func runCreateFilteredAlignmentWorkflow() {
    guard let bundle = viewModel.selectionSectionViewModel.referenceBundle else {
        presentSimpleAlert(title: "No Bundle Loaded", message: "Load a .lungfishref bundle before creating a filtered BAM track.")
        return
    }
    guard let split = parent as? MainSplitViewController else { return }

    let request: AlignmentFilterRequest
    do {
        request = try viewModel.readStyleSectionViewModel.makeAlignmentFilterRequest()
    } catch {
        presentSimpleAlert(title: "BAM Filter Not Ready", message: error.localizedDescription)
        return
    }

    viewModel.readStyleSectionViewModel.isAlignmentFilterWorkflowRunning = true
    split.activityIndicator.show(message: "Creating filtered BAM track...", style: .indeterminate)

    Task(priority: .userInitiated) { [weak self] in
        do {
            _ = try await AlignmentFilterService().createFilteredTrack(
                bundle: bundle,
                request: request,
                progress: { _, _ in }
            )

            DispatchQueue.main.async { [weak self] in
                guard let self, let split = self.parent as? MainSplitViewController else { return }
                MainActor.assumeIsolated {
                    self.viewModel.readStyleSectionViewModel.isAlignmentFilterWorkflowRunning = false
                    split.activityIndicator.hide()
                    if self.viewModel.contentMode == .mapping {
                        try? split.viewerController.reloadMappingViewerBundleIfDisplayed()
                        if let reloadedBundle = try? ReferenceBundle(url: bundle.url) {
                            self.updateMappingAlignmentSection(
                                from: reloadedBundle,
                                applySettings: self.mappingAlignmentSettingsApplier ?? { _ in }
                            )
                        }
                    } else {
                        try? split.viewerController.displayBundle(at: bundle.url)
                    }
                }
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                guard let self, let split = self.parent as? MainSplitViewController else { return }
                MainActor.assumeIsolated {
                    self.viewModel.readStyleSectionViewModel.isAlignmentFilterWorkflowRunning = false
                    split.activityIndicator.hide()
                    self.presentSimpleAlert(title: "BAM Filtering Failed", message: error.localizedDescription)
                }
            }
        }
    }
}
```

```swift
// MappingResultViewController.swift
@MainActor
func reloadViewerBundleForInspectorChanges() throws {
    guard let viewerBundleURL = currentResult?.viewerBundleURL else { return }
    loadedViewerBundleURL = nil
    try loadViewerBundleIfNeeded(from: viewerBundleURL)
    refreshSelection()
}
```

```swift
// ViewerViewController+Mapping.swift
public func reloadMappingViewerBundleIfDisplayed() throws {
    try mappingResultController?.reloadViewerBundleForInspectorChanges()
}
```

- [x] **Step 4: Run the targeted tests**

Run:

```bash
swift test --filter 'InspectorMappingModeTests|MappingResultViewControllerTests'
```

Expected: PASS with both test classes green.

- [x] **Step 5: Commit**

```bash
git add \
  Sources/LungfishApp/Views/Inspector/InspectorViewController.swift \
  Sources/LungfishApp/Views/Results/Mapping/MappingResultViewController.swift \
  Sources/LungfishApp/Views/Viewer/ViewerViewController+Mapping.swift \
  Tests/LungfishAppTests/InspectorMappingModeTests.swift \
  Tests/LungfishAppTests/MappingResultViewControllerTests.swift
git commit -m "feat: wire Inspector BAM filtering workflow"
```

## Task 5: Run Full Verification and Refresh the Spec/Plan References

**Files:**
- Modify: `docs/superpowers/plans/2026-04-22-bam-filtering-implementation.md` (check off completed steps during execution)

- [x] **Step 1: Run the focused app test suite**

Run:

```bash
swift test --filter 'AlignmentFilterCommandBuilderTests|AlignmentFilterServiceTests|AlignmentFilterInspectorStateTests|AlignmentDuplicateServiceTests|InspectorMappingModeTests|MappingResultViewControllerTests'
```

Expected: PASS with all new and touched test classes green.

- [x] **Step 2: Run a broader alignment-related regression sweep**

Run:

```bash
swift test --filter 'BAMImportServiceTests|AlignmentDuplicateServiceTests|InspectorMappingModeTests|MappingResultViewControllerTests'
```

Expected: PASS with no regressions in BAM import, duplicate workflows, or mapping viewer bundle behavior.

- [ ] **Step 3: Manually verify one normal bundle and one mapping viewer bundle**

Run:

```bash
swift test --filter BAMImportServiceTests
```

Expected: PASS, then launch the app locally and verify:

- a regular `.lungfishref` bundle with an imported BAM can create a sibling filtered track from the Inspector
- a mapping result generated from a source bundle can create a sibling filtered track inside its copied viewer bundle
- the source track remains present after derivation
- the derived track shows source/filter metadata and provenance in the Inspector

- [ ] **Step 4: Commit final integration changes**

```bash
git add -A
git commit -m "feat: add bundle alignment BAM filtering workflow"
```
