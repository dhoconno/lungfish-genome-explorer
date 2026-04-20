# Assembly Result Contig Viewport Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the stub assembly result browser with a classifier-style contig viewport backed by indexed FASTA access and CLI-driven FASTA export, bundle creation, and BLAST sequence handoff.

**Architecture:** Split the work into five isolated layers: a workflow-level contig catalog, a new `lungfish extract contigs` CLI surface, an app-side CLI orchestration layer for copy/export/bundle actions, a rebuilt assembly viewport shell with shared pane-layout behavior, and final viewer integration for BLAST and export. Keep sequence materialization in the CLI, keep per-contig browsing in the app, and reuse the existing shared split-view foundation instead of inventing an assembly-only layout system.

**Tech Stack:** Swift, AppKit, ArgumentParser, LungfishWorkflow, LungfishIO indexed FASTA readers, LungfishCore bundle metadata, XCTest, `swift test`

---

## File Structure

### Workflow Layer

- Create: `Sources/LungfishWorkflow/Assembly/AssemblyContigCatalog.swift`
  - Owns indexed FASTA discovery, contig record generation, random-access sequence fetch, and selection-summary math.
- Create: `Sources/LungfishWorkflow/Assembly/AssemblySubsetBundleMetadata.swift`
  - Owns manifest metadata groups for derived selected-contig `.lungfishref` bundles.

### CLI Layer

- Create: `Sources/LungfishCLI/Commands/ExtractContigsCommand.swift`
  - Implements `lungfish extract contigs`.
- Modify: `Sources/LungfishCLI/Commands/ExtractCommand.swift`
  - Registers the new subcommand under `extract`.

### App Layer

- Modify: `Sources/LungfishApp/App/LungfishCLIRunner.swift`
  - Adds a generic subprocess runner with stdout/stderr capture for assembly-contig actions.
- Create: `Sources/LungfishApp/Views/Results/Assembly/AssemblyContigMaterializationAction.swift`
  - Owns copy FASTA, export FASTA, create bundle, and BLAST-request preparation through `lungfish-cli`.
- Create: `Sources/LungfishApp/Views/Results/Assembly/AssemblyActionBar.swift`
  - Bottom action surface for BLAST, copy, export, bundle, and utility actions.
- Create: `Sources/LungfishApp/Views/Results/Assembly/AssemblyContigTableView.swift`
  - Filterable contig table built on the classifier table vocabulary.
- Create: `Sources/LungfishApp/Views/Results/Assembly/AssemblyContigDetailPane.swift`
  - Single-selection and multi-selection detail presentation.
- Modify: `Sources/LungfishApp/Views/Results/Assembly/AssemblyResultViewController.swift`
  - Replaces the stub with the production shell, shared split-layout behavior, and action wiring.
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+Assembly.swift`
  - Wires BLAST verification for assembly contigs and ensures the rebuilt viewport is hosted correctly.

### Test Layer

- Create: `Tests/LungfishWorkflowTests/Assembly/AssemblyContigCatalogTests.swift`
- Create: `Tests/LungfishWorkflowTests/Assembly/AssemblySubsetBundleMetadataTests.swift`
- Create: `Tests/LungfishCLITests/ExtractContigsCommandTests.swift`
- Create: `Tests/LungfishAppTests/AssemblyViewportTestSupport.swift`
- Create: `Tests/LungfishAppTests/AssemblyContigMaterializationActionTests.swift`
- Create: `Tests/LungfishAppTests/AssemblyResultViewControllerTests.swift`
- Create: `Tests/LungfishAppTests/AssemblyViewerIntegrationTests.swift`

This split keeps data loading, CLI behavior, AppKit orchestration, and view state independently testable.

### Task 1: Add The Indexed Assembly Contig Catalog

**Files:**
- Create: `Sources/LungfishWorkflow/Assembly/AssemblyContigCatalog.swift`
- Create: `Tests/LungfishWorkflowTests/Assembly/AssemblyContigCatalogTests.swift`

- [ ] **Step 1: Write the failing workflow tests for contig rows, sequence fetch, and multi-selection summary**

```swift
import XCTest
@testable import LungfishWorkflow
@testable import LungfishIO

final class AssemblyContigCatalogTests: XCTestCase {
    func testRecordsAreRankedByLengthAndComputeGCAndAssemblyShare() async throws {
        let fixture = try makeAssemblyFixture(
            """
            >contig_b long desc
            ATGCGCGC
            >contig_a short desc
            ATAT
            """
        )

        let catalog = try await AssemblyContigCatalog(result: fixture.result)
        let records = try await catalog.records()

        XCTAssertEqual(records.map(\.name), ["contig_b", "contig_a"])
        XCTAssertEqual(records.map(\.rank), [1, 2])
        XCTAssertEqual(records.map(\.lengthBP), [8, 4])
        XCTAssertEqual(records[0].header, "contig_b long desc")
        XCTAssertEqual(records[0].gcPercent, 75.0, accuracy: 0.01)
        XCTAssertEqual(records[0].shareOfAssemblyPercent, 66.666, accuracy: 0.01)
    }

    func testSequenceFASTAUsesIndexedLookupAndPreservesHeader() async throws {
        let fixture = try makeAssemblyFixture(
            """
            >contig_7 annotated header
            AACCGGTT
            """
        )

        let catalog = try await AssemblyContigCatalog(result: fixture.result)
        let fasta = try await catalog.sequenceFASTA(for: "contig_7", lineWidth: 4)

        XCTAssertEqual(fasta, ">contig_7 annotated header\nAACC\nGGTT\n")
    }

    func testSelectionSummaryUsesLengthWeightedGC() async throws {
        let fixture = try makeAssemblyFixture(
            """
            >high_gc
            GCGCGC
            >low_gc
            ATATATAT
            """
        )

        let catalog = try await AssemblyContigCatalog(result: fixture.result)
        let summary = try await catalog.selectionSummary(for: ["high_gc", "low_gc"])

        XCTAssertEqual(summary.selectedContigCount, 2)
        XCTAssertEqual(summary.totalSelectedBP, 14)
        XCTAssertEqual(summary.longestContigBP, 8)
        XCTAssertEqual(summary.shortestContigBP, 6)
        XCTAssertEqual(summary.lengthWeightedGCPercent, 42.857, accuracy: 0.01)
    }
}
```

- [ ] **Step 2: Run the workflow tests to verify the catalog does not exist yet**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-browser/.worktrees/assembly-xcui-pilot --filter AssemblyContigCatalogTests
```

Expected: FAIL with compile errors because `AssemblyContigCatalog`, `AssemblyContigRecord`, and `AssemblyContigSelectionSummary` do not exist.

- [ ] **Step 3: Implement the catalog types and indexed FASTA-backed loader**

```swift
import Foundation
import LungfishCore
import LungfishIO

public struct AssemblyContigRecord: Sendable, Equatable {
    public let rank: Int
    public let name: String
    public let header: String
    public let lengthBP: Int
    public let gcPercent: Double
    public let shareOfAssemblyPercent: Double
}

public struct AssemblyContigSelectionSummary: Sendable, Equatable {
    public let selectedContigCount: Int
    public let totalSelectedBP: Int
    public let longestContigBP: Int
    public let shortestContigBP: Int
    public let lengthWeightedGCPercent: Double
}

public actor AssemblyContigCatalog {
    private let result: AssemblyResult
    private let plainReader: IndexedFASTAReader?
    private let bgzipReader: BgzipIndexedFASTAReader?
    private let entries: [FASTAIndex.Entry]
    private var cachedRecords: [AssemblyContigRecord]?
    private var cachedHeaders: [String: String] = [:]

    public init(result: AssemblyResult) async throws {
        self.result = result

        if result.contigsPath.pathExtension == "gz" {
            let reader = try await BgzipIndexedFASTAReader(url: result.contigsPath)
            self.bgzipReader = reader
            self.plainReader = nil
            self.entries = reader.fastaIndex.entries
        } else {
            let reader = try IndexedFASTAReader(url: result.contigsPath)
            self.plainReader = reader
            self.bgzipReader = nil
            self.entries = reader.index.entries
        }

        self.cachedHeaders = try Self.loadHeaders(from: result.contigsPath, fallbackNames: entries.map(\.name))
    }

    public func records() async throws -> [AssemblyContigRecord] {
        if let cachedRecords { return cachedRecords }

        let totalLength = max(1, result.statistics.totalLengthBP)
        let sortedEntries = entries.sorted { lhs, rhs in
            if lhs.length == rhs.length { return lhs.name < rhs.name }
            return lhs.length > rhs.length
        }

        let built = try await sortedEntries.enumerated().map { index, entry in
            let sequence = try await fetchBases(name: entry.name, length: entry.length)
            let header = cachedHeaders[entry.name] ?? entry.name
            return AssemblyContigRecord(
                rank: index + 1,
                name: entry.name,
                header: header,
                lengthBP: entry.length,
                gcPercent: Self.gcPercent(for: sequence),
                shareOfAssemblyPercent: (Double(entry.length) / Double(totalLength)) * 100.0
            )
        }

        cachedRecords = built
        return built
    }

    public func sequenceFASTA(for name: String, lineWidth: Int = 70) async throws -> String {
        let records = try await records()
        guard let record = records.first(where: { $0.name == name }) else {
            throw FASTAError.invalidIndex("Sequence '\(name)' not found in index")
        }
        let sequence = try await fetchBases(name: record.name, length: record.lengthBP)
        return Self.formatFASTA(header: record.header, sequence: sequence, lineWidth: lineWidth)
    }

    public func sequenceFASTAs(for names: [String], lineWidth: Int = 70) async throws -> [String] {
        try await names.map { try await sequenceFASTA(for: $0, lineWidth: lineWidth) }
    }

    public func selectionSummary(for names: [String]) async throws -> AssemblyContigSelectionSummary {
        let recordMap = Dictionary(uniqueKeysWithValues: try await records().map { ($0.name, $0) })
        let selected = names.compactMap { recordMap[$0] }
        let totalBP = selected.reduce(0) { $0 + $1.lengthBP }
        let weightedGCNumerator = selected.reduce(0.0) { partial, record in
            partial + (record.gcPercent * Double(record.lengthBP))
        }

        return AssemblyContigSelectionSummary(
            selectedContigCount: selected.count,
            totalSelectedBP: totalBP,
            longestContigBP: selected.map(\.lengthBP).max() ?? 0,
            shortestContigBP: selected.map(\.lengthBP).min() ?? 0,
            lengthWeightedGCPercent: totalBP == 0 ? 0 : weightedGCNumerator / Double(totalBP)
        )
    }

    private func fetchBases(name: String, length: Int) async throws -> String {
        let region = GenomicRegion(chromosome: name, start: 0, end: length)
        if let bgzipReader {
            return try await bgzipReader.fetch(region: region)
        }
        guard let plainReader else {
            throw FASTAError.invalidIndex("No indexed FASTA reader available")
        }
        return try await plainReader.fetch(region: region)
    }

    private static func gcPercent(for sequence: String) -> Double {
        guard !sequence.isEmpty else { return 0 }
        let gcCount = sequence.uppercased().reduce(0) { partial, character in
            partial + (character == "G" || character == "C" ? 1 : 0)
        }
        return (Double(gcCount) / Double(sequence.count)) * 100.0
    }

    private static func formatFASTA(header: String, sequence: String, lineWidth: Int) -> String {
        let width = max(1, lineWidth)
        let lines = stride(from: 0, to: sequence.count, by: width).map { start -> String in
            let lower = sequence.index(sequence.startIndex, offsetBy: start)
            let upper = sequence.index(lower, offsetBy: min(width, sequence.count - start))
            return String(sequence[lower..<upper])
        }
        return ">\(header)\n" + lines.joined(separator: "\n") + "\n"
    }

    private static func loadHeaders(from url: URL, fallbackNames: [String]) throws -> [String: String] {
        guard url.pathExtension != "gz" else {
            return Dictionary(uniqueKeysWithValues: fallbackNames.map { ($0, $0) })
        }

        let text = try String(contentsOf: url, encoding: .utf8)
        var headers: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) where line.hasPrefix(">") {
            let raw = String(line.dropFirst())
            let name = raw.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? raw
            headers[name] = raw
        }
        return headers
    }
}
```

- [ ] **Step 4: Add the fixture helper inside the test file so the catalog tests can build deterministic indexed FASTA inputs**

```swift
private func makeAssemblyFixture(_ fasta: String) throws -> (result: AssemblyResult, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("assembly-contig-catalog-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let contigsURL = directory.appendingPathComponent("contigs.fasta")
    try fasta.write(to: contigsURL, atomically: true, encoding: .utf8)
    try FASTAIndexBuilder.buildAndWrite(for: contigsURL)

    let stats = try AssemblyStatisticsCalculator.compute(from: contigsURL)
    let result = AssemblyResult(
        tool: .spades,
        readType: .illuminaShortReads,
        contigsPath: contigsURL,
        graphPath: nil,
        logPath: nil,
        assemblerVersion: "test",
        commandLine: "spades.py -o \(directory.path)",
        outputDirectory: directory,
        statistics: stats,
        wallTimeSeconds: 12
    )

    return (result, directory)
}
```

- [ ] **Step 5: Re-run the workflow tests**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-browser/.worktrees/assembly-xcui-pilot --filter AssemblyContigCatalogTests
```

Expected: PASS with all three `AssemblyContigCatalogTests` green.

- [ ] **Step 6: Commit the workflow catalog tranche**

```bash
git add Sources/LungfishWorkflow/Assembly/AssemblyContigCatalog.swift Tests/LungfishWorkflowTests/Assembly/AssemblyContigCatalogTests.swift
git commit -m "feat: add indexed assembly contig catalog"
```

### Task 2: Add `lungfish extract contigs` And Derived-Subset Bundle Metadata

**Files:**
- Create: `Sources/LungfishWorkflow/Assembly/AssemblySubsetBundleMetadata.swift`
- Create: `Sources/LungfishCLI/Commands/ExtractContigsCommand.swift`
- Modify: `Sources/LungfishCLI/Commands/ExtractCommand.swift`
- Create: `Tests/LungfishWorkflowTests/Assembly/AssemblySubsetBundleMetadataTests.swift`
- Create: `Tests/LungfishCLITests/ExtractContigsCommandTests.swift`

- [ ] **Step 1: Write the failing CLI and metadata tests**

```swift
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class ExtractContigsCommandTests: XCTestCase {
    func testParsingBundleModeRequiresProjectRootAndSelection() throws {
        XCTAssertThrowsError(
            try ExtractContigsSubcommand.parse([
                "--assembly", "/tmp/run",
                "--bundle"
            ])
        )
    }

    func testRunWritesSelectedContigsInRequestedOrder() async throws {
        let fixture = try makeAssemblyFixture(
            """
            >first
            AAAA
            >second
            CCCC
            """
        )
        let outputURL = fixture.directory.appendingPathComponent("selected.fa")
        var command = try ExtractContigsSubcommand.parse([
            "--assembly", fixture.directory.path,
            "--contig", "second",
            "--contig", "first",
            "--output", outputURL.path
        ])

        try await command.run()

        let written = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(written.hasPrefix(">second"))
        XCTAssertTrue(written.contains(">first"))
    }
}
```

```swift
import XCTest
@testable import LungfishWorkflow
@testable import LungfishCore

final class AssemblySubsetBundleMetadataTests: XCTestCase {
    func testMetadataIncludesAssemblySourceAndSelection() {
        let sourceResult = AssemblyResult(
            tool: .spades,
            readType: .illuminaShortReads,
            contigsPath: URL(fileURLWithPath: "/tmp/analysis/contigs.fasta"),
            graphPath: nil,
            logPath: nil,
            assemblerVersion: "4.0.0",
            commandLine: "spades.py -o /tmp/analysis",
            outputDirectory: URL(fileURLWithPath: "/tmp/analysis", isDirectory: true),
            statistics: AssemblyStatisticsCalculator.computeFromLengths([800, 400]),
            wallTimeSeconds: 42
        )

        let metadata = AssemblySubsetBundleMetadata.makeGroups(
            sourceResult: sourceResult,
            selectedContigs: ["contig_7", "contig_9"],
            bundleName: "SelectedContigs",
            createdAt: Date(timeIntervalSince1970: 1_713_571_200)
        )

        XCTAssertEqual(metadata.first?.name, "Derived From Assembly")
        XCTAssertTrue(metadata.flatMap(\.items).contains { $0.label == "Assembler" && $0.value == "SPAdes" })
        XCTAssertTrue(metadata.flatMap(\.items).contains { $0.label == "Selected Contigs" && $0.value == "contig_7, contig_9" })
    }
}
```

- [ ] **Step 2: Run the new tests to confirm the command surface is missing**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-browser/.worktrees/assembly-xcui-pilot --filter ExtractContigsCommandTests
swift test --package-path /Users/dho/Documents/lungfish-genome-browser/.worktrees/assembly-xcui-pilot --filter AssemblySubsetBundleMetadataTests
```

Expected: FAIL because `ExtractContigsSubcommand` and `AssemblySubsetBundleMetadata` do not exist.

- [ ] **Step 3: Implement metadata groups for selected-contig derived bundles**

```swift
import Foundation
import LungfishCore

public enum AssemblySubsetBundleMetadata {
    public static func makeGroups(
        sourceResult: AssemblyResult,
        selectedContigs: [String],
        bundleName: String,
        createdAt: Date
    ) -> [MetadataGroup] {
        let formatter = ISO8601DateFormatter()

        return [
            MetadataGroup(name: "Derived From Assembly", items: [
                MetadataItem(label: "Bundle Name", value: bundleName),
                MetadataItem(label: "Assembler", value: sourceResult.tool.displayName),
                MetadataItem(label: "Read Type", value: sourceResult.readType.displayName),
                MetadataItem(label: "Source Analysis", value: sourceResult.outputDirectory.lastPathComponent),
                MetadataItem(label: "Source Contigs FASTA", value: sourceResult.contigsPath.lastPathComponent),
                MetadataItem(label: "Selected Contigs", value: selectedContigs.joined(separator: ", ")),
                MetadataItem(label: "Selection Timestamp", value: formatter.string(from: createdAt))
            ])
        ]
    }
}
```

- [ ] **Step 4: Implement `ExtractContigsSubcommand` and register it under `extract`**

```swift
struct ExtractContigsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "contigs",
        abstract: "Extract selected contigs from an assembly result"
    )

    @Option(name: .customLong("assembly")) var assemblyPath: String?
    @Option(name: .customLong("contigs")) var contigsPath: String?
    @Option(name: .customLong("contig")) var selectedContigs: [String] = []
    @Option(name: .customLong("contig-file")) var contigFile: String?
    @Option(name: .shortAndLong) var output: String?
    @Flag(name: .customLong("bundle")) var createBundle = false
    @Option(name: .customLong("bundle-name")) var bundleName: String?
    @Option(name: .customLong("project-root")) var projectRoot: String?
    @Option(name: .customLong("line-width")) var lineWidth: Int = 70
    @OptionGroup var globalOptions: GlobalOptions

    mutating func validate() throws {
        let hasAssembly = assemblyPath != nil || contigsPath != nil
        guard hasAssembly else { throw ValidationError("One of --assembly or --contigs is required") }

        let allSelections = try resolvedSelectionNames()
        guard !allSelections.isEmpty else { throw ValidationError("At least one --contig or --contig-file entry is required") }

        if createBundle {
            guard projectRoot != nil else { throw ValidationError("--project-root is required with --bundle") }
        } else {
            guard output != nil else { throw ValidationError("--output is required when not using --bundle") }
        }
    }

    mutating func run() async throws {
        let source = try resolvedAssemblyResult()
        let selected = try resolvedSelectionNames()
        let catalog = try await AssemblyContigCatalog(result: source)
        let fastas = try await catalog.sequenceFASTAs(for: selected, lineWidth: lineWidth)
        let fastaText = fastas.joined()

        if createBundle {
            let tempFASTA = try writeTemporarySelectionFASTA(fastaText)
            let destination = URL(fileURLWithPath: projectRoot!, isDirectory: true)
            let name = bundleName ?? selected.first ?? "selected_contigs"
            let configuration = BuildConfiguration(
                name: name,
                identifier: "org.lungfish.assembly-subset.\(UUID().uuidString)",
                fastaURL: tempFASTA,
                outputDirectory: destination,
                source: SourceInfo(
                    organism: name,
                    assembly: source.outputDirectory.lastPathComponent,
                    database: source.tool.displayName,
                    notes: "Derived subset of \(selected.count) assembly contigs"
                ),
                metadata: AssemblySubsetBundleMetadata.makeGroups(
                    sourceResult: source,
                    selectedContigs: selected,
                    bundleName: name,
                    createdAt: Date()
                )
            )

            let bundleURL = try await NativeBundleBuilder().build(configuration: configuration)
            print(bundleURL.path)
            return
        }

        try fastaText.write(to: URL(fileURLWithPath: output!), atomically: true, encoding: .utf8)
    }

    private func resolvedSelectionNames() throws -> [String] {
        var names = selectedContigs
        if let contigFile {
            let fileContents = try String(contentsOfFile: contigFile, encoding: .utf8)
            names += fileContents
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return names.filter { !$0.isEmpty }
    }

    private func resolvedAssemblyResult() throws -> AssemblyResult {
        if let assemblyPath {
            let url = URL(fileURLWithPath: assemblyPath)
            return try AssemblyResult.load(from: url)
        }

        let url = URL(fileURLWithPath: contigsPath!)
        let stats = try AssemblyStatisticsCalculator.compute(from: url)
        return AssemblyResult(
            tool: .spades,
            readType: .illuminaShortReads,
            contigsPath: url,
            graphPath: nil,
            logPath: nil,
            assemblerVersion: nil,
            commandLine: "lungfish extract contigs",
            outputDirectory: url.deletingLastPathComponent(),
            statistics: stats,
            wallTimeSeconds: 0
        )
    }

    private func writeTemporarySelectionFASTA(_ fastaText: String) throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("assembly-selected-\(UUID().uuidString).fa")
        try fastaText.write(to: tempURL, atomically: true, encoding: .utf8)
        return tempURL
    }
}
```

```swift
static let configuration = CommandConfiguration(
    commandName: "extract",
    abstract: "Extract subsequences or reads from genomic files",
    subcommands: [
        ExtractSequenceSubcommand.self,
        ExtractReadsSubcommand.self,
        ExtractContigsSubcommand.self,
    ],
    defaultSubcommand: ExtractSequenceSubcommand.self
)
```

- [ ] **Step 5: Re-run the CLI and metadata tests**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-browser/.worktrees/assembly-xcui-pilot --filter ExtractContigsCommandTests
swift test --package-path /Users/dho/Documents/lungfish-genome-browser/.worktrees/assembly-xcui-pilot --filter AssemblySubsetBundleMetadataTests
```

Expected: PASS with the new subcommand and bundle-metadata tests green.

- [ ] **Step 6: Commit the CLI tranche**

```bash
git add Sources/LungfishWorkflow/Assembly/AssemblySubsetBundleMetadata.swift Sources/LungfishCLI/Commands/ExtractContigsCommand.swift Sources/LungfishCLI/Commands/ExtractCommand.swift Tests/LungfishWorkflowTests/Assembly/AssemblySubsetBundleMetadataTests.swift Tests/LungfishCLITests/ExtractContigsCommandTests.swift
git commit -m "feat: add assembly contig extraction command"
```

### Task 3: Add App-Side CLI Orchestration For Copy, Export, Bundle, And BLAST

**Files:**
- Modify: `Sources/LungfishApp/App/LungfishCLIRunner.swift`
- Create: `Sources/LungfishApp/Views/Results/Assembly/AssemblyContigMaterializationAction.swift`
- Create: `Tests/LungfishAppTests/AssemblyViewportTestSupport.swift`
- Create: `Tests/LungfishAppTests/AssemblyContigMaterializationActionTests.swift`

- [ ] **Step 1: Write the failing app tests for CLI-backed materialization actions**

```swift
import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

@MainActor
final class AssemblyContigMaterializationActionTests: XCTestCase {
    func testCopyFastaWritesCliStdoutToPasteboard() async throws {
        let action = AssemblyContigMaterializationAction()
        let pasteboard = RecordingPasteboard()
        action.pasteboard = pasteboard
        action.runner = { _ in .init(stdout: ">contig_1\nACGT\n", stderr: "", status: 0) }

        try await action.copyFASTA(
            result: makeAssemblyResult(),
            selectedContigs: ["contig_1"]
        )

        XCTAssertEqual(pasteboard.lastString, ">contig_1\nACGT\n")
    }

    func testBuildBlastRequestUsesCliStdoutAndSourceLabel() async throws {
        let action = AssemblyContigMaterializationAction()
        action.runner = { _ in .init(stdout: ">contig_7\nAACCGG\n", stderr: "", status: 0) }

        let request = try await action.buildBlastRequest(
            result: makeAssemblyResult(),
            selectedContigs: ["contig_7"]
        )

        XCTAssertEqual(request.readCount, 1)
        XCTAssertEqual(request.sourceLabel, "contig contig_7")
        XCTAssertEqual(request.sequences, [">contig_7\nAACCGG\n"])
    }

    func testCreateBundleReturnsBundleURLPrintedByCli() async throws {
        let action = AssemblyContigMaterializationAction()
        action.runner = { _ in .init(stdout: "/tmp/SelectedContigs.lungfishref\n", stderr: "", status: 0) }

        let bundleURL = try await action.createBundle(
            result: makeAssemblyResult(),
            selectedContigs: ["contig_1", "contig_2"],
            suggestedName: "SelectedContigs"
        )

        XCTAssertEqual(bundleURL?.path, "/tmp/SelectedContigs.lungfishref")
    }
}
```

```swift
import AppKit
@testable import LungfishApp
@testable import LungfishWorkflow

@MainActor
final class RecordingPasteboard: PasteboardWriting {
    private(set) var lastString: String?
    func setString(_ string: String) { lastString = string }
}

func makeAssemblyResult() -> AssemblyResult {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("assembly-viewport-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let fastaURL = tempDir.appendingPathComponent("contigs.fasta")
    try? """
    >contig_7 annotated header
    AACCGGTT
    >contig_9
    ATATAT
    """.write(to: fastaURL, atomically: true, encoding: .utf8)
    try? FASTAIndexBuilder.buildAndWrite(for: fastaURL)

    return AssemblyResult(
        tool: .spades,
        readType: .illuminaShortReads,
        contigsPath: fastaURL,
        graphPath: nil,
        logPath: tempDir.appendingPathComponent("spades.log"),
        assemblerVersion: "4.0.0",
        commandLine: "spades.py -o \(tempDir.path)",
        outputDirectory: tempDir,
        statistics: (try? AssemblyStatisticsCalculator.compute(from: fastaURL)) ?? AssemblyStatisticsCalculator.computeFromLengths([8, 6]),
        wallTimeSeconds: 15
    )
}
```

- [ ] **Step 2: Run the app tests to verify the action service does not exist**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-browser/.worktrees/assembly-xcui-pilot --filter AssemblyContigMaterializationActionTests
```

Expected: FAIL because `AssemblyContigMaterializationAction` and the generic CLI runner result type do not exist.

- [ ] **Step 3: Extend `LungfishCLIRunner` with a reusable stdout-capturing subprocess API**

```swift
enum LungfishCLIRunner {
    struct Output: Sendable, Equatable {
        let stdout: String
        let stderr: String
        let status: Int32
    }

    static func run(arguments: [String]) throws -> Output {
        guard let cliURL = findCLI() else {
            throw RunError.cliNotFound
        }

        let process = Process()
        process.executableURL = cliURL
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw RunError.launchFailed(error.localizedDescription)
        }

        process.waitUntilExit()
        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            throw RunError.nonZeroExit(status: process.terminationStatus, stderr: stderr)
        }

        return Output(stdout: stdout, stderr: stderr, status: process.terminationStatus)
    }
}
```

- [ ] **Step 4: Implement the assembly materialization orchestrator around the new CLI command**

```swift
import AppKit
import Foundation

@MainActor
final class AssemblyContigMaterializationAction {
    typealias Runner = @Sendable ([String]) throws -> LungfishCLIRunner.Output

    var pasteboard: PasteboardWriting = DefaultPasteboard()
    var runner: Runner = { try LungfishCLIRunner.run(arguments: $0) }

    func copyFASTA(result: AssemblyResult, selectedContigs: [String]) async throws {
        let output = try runner(cliArguments(result: result, selectedContigs: selectedContigs))
        pasteboard.setString(output.stdout)
    }

    func exportFASTA(result: AssemblyResult, selectedContigs: [String], outputURL: URL) async throws {
        _ = try runner(
            cliArguments(result: result, selectedContigs: selectedContigs)
            + ["--output", outputURL.path]
        )
    }

    func createBundle(
        result: AssemblyResult,
        selectedContigs: [String],
        suggestedName: String
    ) async throws -> URL? {
        let projectRoot = result.outputDirectory.deletingLastPathComponent()
        let output = try runner(
            cliArguments(result: result, selectedContigs: selectedContigs)
            + ["--bundle", "--bundle-name", suggestedName, "--project-root", projectRoot.path]
        )
        let trimmed = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed)
    }

    func buildBlastRequest(result: AssemblyResult, selectedContigs: [String]) async throws -> BlastRequest {
        let output = try runner(cliArguments(result: result, selectedContigs: selectedContigs))
        let label = selectedContigs.count == 1 ? "contig \(selectedContigs[0])" : "\(selectedContigs.count) contigs"
        let sequences = output.stdout
            .split(separator: ">", omittingEmptySubsequences: true)
            .map { ">\($0)" }
        return BlastRequest(taxId: nil, sequences: sequences, readCount: selectedContigs.count, sourceLabel: label)
    }

    private func cliArguments(result: AssemblyResult, selectedContigs: [String]) -> [String] {
        ["extract", "contigs", "--assembly", result.outputDirectory.path]
            + selectedContigs.flatMap { ["--contig", $0] }
    }
}
```

- [ ] **Step 5: Re-run the app tests**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-browser/.worktrees/assembly-xcui-pilot --filter AssemblyContigMaterializationActionTests
```

Expected: PASS with the CLI-backed action tests green.

- [ ] **Step 6: Commit the orchestration tranche**

```bash
git add Sources/LungfishApp/App/LungfishCLIRunner.swift Sources/LungfishApp/Views/Results/Assembly/AssemblyContigMaterializationAction.swift Tests/LungfishAppTests/AssemblyViewportTestSupport.swift Tests/LungfishAppTests/AssemblyContigMaterializationActionTests.swift
git commit -m "feat: add assembly contig materialization action"
```

### Task 4: Rebuild The Assembly Viewport Shell, Table, Detail Pane, And Layout Modes

**Files:**
- Create: `Sources/LungfishApp/Views/Results/Assembly/AssemblySummaryStrip.swift`
- Create: `Sources/LungfishApp/Views/Results/Assembly/AssemblyActionBar.swift`
- Create: `Sources/LungfishApp/Views/Results/Assembly/AssemblyContigTableView.swift`
- Create: `Sources/LungfishApp/Views/Results/Assembly/AssemblyContigDetailPane.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/BatchTableView.swift`
- Modify: `Sources/LungfishApp/Views/Results/Assembly/AssemblyResultViewController.swift`
- Create: `Tests/LungfishAppTests/AssemblyResultViewControllerTests.swift`

- [ ] **Step 1: Write the failing controller tests for layout mode, summary-strip values, quick copy, and selection-driven detail**

```swift
import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

@MainActor
final class AssemblyResultViewControllerTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: MetagenomicsPanelLayout.defaultsKey)
        UserDefaults.standard.removeObject(forKey: MetagenomicsPanelLayout.legacyTableOnLeftKey)
        super.tearDown()
    }

    func testUsesStackedLayoutWhenClassifierPreferenceIsStacked() async throws {
        UserDefaults.standard.set(MetagenomicsPanelLayout.stacked.rawValue, forKey: MetagenomicsPanelLayout.defaultsKey)

        let vc = AssemblyResultViewController()
        _ = vc.view
        try await vc.configureForTesting(result: makeAssemblyResult())

        XCTAssertFalse(vc.testSplitView.isVertical)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[0] === vc.testTableContainer)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[1] === vc.testDetailContainer)
    }

    func testSingleSelectionShowsContigOverviewAndSequence() async throws {
        let vc = AssemblyResultViewController()
        _ = vc.view
        try await vc.configureForTesting(result: makeAssemblyResult())

        vc.testSelectContig(named: "contig_7")

        XCTAssertEqual(vc.testDetailPane.currentHeaderText, "contig_7 annotated header")
        XCTAssertTrue(vc.testDetailPane.currentSequenceText.contains("AACCGGTT"))
    }

    func testMultiSelectionShowsSelectionSummaryInsteadOfConcatenatedSequence() async throws {
        let vc = AssemblyResultViewController()
        _ = vc.view
        try await vc.configureForTesting(result: makeAssemblyResult())

        vc.testSelectContigs(named: ["contig_7", "contig_9"])

        XCTAssertEqual(vc.testDetailPane.currentSummaryTitle, "2 contigs selected")
        XCTAssertFalse(vc.testDetailPane.currentSequenceText.contains(">contig_7"))
    }

    func testSummaryStripShowsAssemblyMetricsAndSupportsQuickCopy() async throws {
        let pasteboard = RecordingPasteboard()
        let vc = AssemblyResultViewController()
        _ = vc.view
        try await vc.configureForTesting(result: makeAssemblyResult(), scalarPasteboard: pasteboard)

        XCTAssertEqual(vc.testSummaryStrip.value(for: "assembly-result-summary-assembler"), "SPAdes")
        XCTAssertEqual(vc.testSummaryStrip.value(for: "assembly-result-summary-read-type"), "Illumina Short Reads")
        XCTAssertEqual(vc.testSummaryStrip.value(for: "assembly-result-summary-contigs"), "2")
        XCTAssertEqual(vc.testSummaryStrip.value(for: "assembly-result-summary-n50"), "8 bp")
        XCTAssertEqual(vc.testSummaryStrip.value(for: "assembly-result-summary-global-gc"), "28.6%")

        vc.testCopySummaryValue(identifier: "assembly-result-summary-assembler")
        XCTAssertEqual(pasteboard.lastString, "SPAdes")
    }

    func testAccessibilityIdentifiersAndContextMenuAreStable() async throws {
        let vc = AssemblyResultViewController()
        _ = vc.view
        try await vc.configureForTesting(result: makeAssemblyResult())

        XCTAssertEqual(vc.view.accessibilityIdentifier(), "assembly-result-view")
        XCTAssertEqual(vc.testSummaryStrip.accessibilityIdentifier(), "assembly-result-summary-strip")
        XCTAssertEqual(vc.testContigTableView.testSearchField.accessibilityIdentifier(), "assembly-result-search")
        XCTAssertEqual(vc.testContigTableView.testTableView.accessibilityIdentifier(), "assembly-result-contig-table")
        XCTAssertEqual(vc.testDetailPane.accessibilityIdentifier(), "assembly-result-detail")
        XCTAssertEqual(vc.testActionBar.accessibilityIdentifier(), "assembly-result-action-bar")
        XCTAssertEqual(vc.testContextMenuTitles, ["BLAST Selected", "Copy FASTA", "Export FASTA…", "Create Bundle…"])
    }

    func testCommandCopyUsesVisibleTableAndDetailValues() async throws {
        let pasteboard = RecordingPasteboard()
        let vc = AssemblyResultViewController()
        _ = vc.view
        try await vc.configureForTesting(result: makeAssemblyResult(), scalarPasteboard: pasteboard)

        vc.testSelectContig(named: "contig_7")
        vc.testCopyVisibleDetailValue(identifier: "assembly-result-detail-length")
        XCTAssertEqual(pasteboard.lastString, "8 bp")

        vc.testCopyVisibleTableValue(row: 0, columnID: "name")
        XCTAssertEqual(pasteboard.lastString, "contig_7")
    }
}
```

- [ ] **Step 2: Run the controller tests to confirm the current viewport is still a stub**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-browser/.worktrees/assembly-xcui-pilot --filter AssemblyResultViewControllerTests
```

Expected: FAIL because the controller has no split-view layout, no detail pane, and no test accessors.

- [ ] **Step 3: Add the focused view files for the summary strip, action bar, table, detail pane, and shared table accessibility hooks**

```swift
@MainActor
class BatchTableView<Row>: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var searchAccessibilityIdentifier: String? { nil }
    var searchAccessibilityLabel: String? { nil }
    var tableAccessibilityIdentifier: String? { nil }
    var tableAccessibilityLabel: String? { nil }
    var tableContextMenu: NSMenu? {
        didSet { tableView?.menu = tableContextMenu }
    }

    private func setupTableView() {
        let sf = NSSearchField()
        sf.placeholderString = searchPlaceholder
        if let searchAccessibilityIdentifier {
            sf.setAccessibilityIdentifier(searchAccessibilityIdentifier)
        }
        if let searchAccessibilityLabel {
            sf.setAccessibilityLabel(searchAccessibilityLabel)
        }
        addSubview(sf)
        self.searchField = sf

        let tv = NSTableView()
        if let tableAccessibilityIdentifier {
            tv.setAccessibilityIdentifier(tableAccessibilityIdentifier)
        }
        if let tableAccessibilityLabel {
            tv.setAccessibilityLabel(tableAccessibilityLabel)
        }
        tv.menu = tableContextMenu
        self.tableView = tv
    }

    #if DEBUG
    var testSearchField: NSSearchField { searchField }
    var testTableView: NSTableView { tableView }
    #endif
}
```

```swift
import AppKit
import LungfishWorkflow

@MainActor
final class AssemblyQuickCopyTextField: NSTextField {
    var pasteboard: PasteboardWriting = DefaultPasteboard()
    var copiedValue: (() -> String)?

    convenience init(labelWithString string: String) {
        self.init(frame: .zero)
        self.stringValue = string
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBezeled = false
        isEditable = false
        drawsBackground = false
        lineBreakMode = .byTruncatingMiddle
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), let value = copiedValue?(), !value.isEmpty else {
            super.mouseDown(with: event)
            return
        }
        pasteboard.setString(value)
    }

    func copyCurrentValue() {
        guard let value = copiedValue?(), !value.isEmpty else { return }
        pasteboard.setString(value)
    }
}

@MainActor
final class AssemblySummaryStrip: NSView {
    private var valueFields: [String: AssemblyQuickCopyTextField] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("assembly-result-summary-strip")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(result: AssemblyResult, pasteboard: PasteboardWriting) {
        var fields: [(String, String, String)] = [
            ("assembly-result-summary-assembler", "Assembler", result.tool.displayName),
            ("assembly-result-summary-read-type", "Read Type", result.readType.displayName),
            ("assembly-result-summary-contigs", "Contigs", "\(result.statistics.contigCount)"),
            ("assembly-result-summary-total-bp", "Total Assembled bp", "\(result.statistics.totalLengthBP)"),
            ("assembly-result-summary-n50", "N50", "\(result.statistics.n50) bp"),
            ("assembly-result-summary-l50", "L50", "\(result.statistics.l50)"),
            ("assembly-result-summary-longest", "Longest Contig", "\(result.statistics.largestContigBP) bp"),
            ("assembly-result-summary-global-gc", "Global GC", String(format: "%.1f%%", result.statistics.gcPercent)),
        ]
        if let assemblerVersion = result.assemblerVersion {
            fields.append(("assembly-result-summary-version", "Assembler Version", assemblerVersion))
        }
        if result.wallTimeSeconds > 0 {
            fields.append(("assembly-result-summary-wall-time", "Wall Time", String(format: "%.1fs", result.wallTimeSeconds)))
        }

        if subviews.isEmpty {
            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.spacing = 12
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: 44),
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
                stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])

            for (identifier, title, value) in fields {
                let valueField = AssemblyQuickCopyTextField(labelWithString: value)
                valueField.copiedValue = { valueField.stringValue }
                valueField.pasteboard = pasteboard
                valueField.setAccessibilityIdentifier(identifier)
                valueField.setAccessibilityLabel(title)
                valueFields[identifier] = valueField

                let titleField = NSTextField(labelWithString: title)
                titleField.textColor = .secondaryLabelColor
                titleField.font = .systemFont(ofSize: 11, weight: .medium)

                let column = NSStackView(views: [titleField, valueField])
                column.orientation = .vertical
                column.spacing = 2
                stack.addArrangedSubview(column)
            }
        }

        for (identifier, _, value) in fields {
            valueFields[identifier]?.stringValue = value
            valueFields[identifier]?.pasteboard = pasteboard
        }
    }

    #if DEBUG
    func value(for identifier: String) -> String { valueFields[identifier]?.stringValue ?? "" }
    func copyValue(for identifier: String) { valueFields[identifier]?.copyCurrentValue() }
    #endif
}
```

```swift
@MainActor
final class AssemblyActionBar: NSView {
    let blastButton = NSButton(title: "BLAST Selected", target: nil, action: nil)
    let copyButton = NSButton(title: "Copy FASTA", target: nil, action: nil)
    let exportButton = NSButton(title: "Export FASTA", target: nil, action: nil)
    let bundleButton = NSButton(title: "Create Bundle", target: nil, action: nil)
    let infoLabel = NSTextField(labelWithString: "")

    var onBlast: (() -> Void)?
    var onCopy: (() -> Void)?
    var onExport: (() -> Void)?
    var onBundle: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("assembly-result-action-bar")
        let stack = NSStackView(views: [blastButton, copyButton, exportButton, bundleButton, infoLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        blastButton.target = self
        blastButton.action = #selector(blastTapped)
        blastButton.setAccessibilityIdentifier("assembly-result-action-blast")
        blastButton.setAccessibilityLabel("BLAST selected contigs")
        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        copyButton.setAccessibilityIdentifier("assembly-result-action-copy-fasta")
        copyButton.setAccessibilityLabel("Copy selected contigs as FASTA")
        exportButton.target = self
        exportButton.action = #selector(exportTapped)
        exportButton.setAccessibilityIdentifier("assembly-result-action-export-fasta")
        exportButton.setAccessibilityLabel("Export selected contigs as FASTA")
        bundleButton.target = self
        bundleButton.action = #selector(bundleTapped)
        bundleButton.setAccessibilityIdentifier("assembly-result-action-create-bundle")
        bundleButton.setAccessibilityLabel("Create bundle from selected contigs")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func blastTapped() { onBlast?() }
    @objc private func copyTapped() { onCopy?() }
    @objc private func exportTapped() { onExport?() }
    @objc private func bundleTapped() { onBundle?() }
}
```

```swift
@MainActor
final class AssemblyContigDetailPane: NSView {
    private let titleLabel = AssemblyQuickCopyTextField(labelWithString: "")
    private let lengthLabel = AssemblyQuickCopyTextField(labelWithString: "")
    private let gcLabel = AssemblyQuickCopyTextField(labelWithString: "")
    private let rankLabel = AssemblyQuickCopyTextField(labelWithString: "")
    private let shareLabel = AssemblyQuickCopyTextField(labelWithString: "")
    private let sequenceView = NSTextView()
    private let contextLabel = NSTextField(wrappingLabelWithString: "")
    private let artifactsLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("assembly-result-detail")
        sequenceView.isEditable = false
        sequenceView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = sequenceView

        lengthLabel.setAccessibilityIdentifier("assembly-result-detail-length")
        gcLabel.setAccessibilityIdentifier("assembly-result-detail-gc")
        rankLabel.setAccessibilityIdentifier("assembly-result-detail-rank")
        shareLabel.setAccessibilityIdentifier("assembly-result-detail-share")

        let metrics = NSStackView(views: [lengthLabel, gcLabel, rankLabel, shareLabel])
        metrics.orientation = .horizontal
        metrics.spacing = 12

        let stack = NSStackView(views: [titleLabel, metrics, scrollView, contextLabel, artifactsLabel])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showEmptyState(contigCount: Int) {
        titleLabel.stringValue = "Select a contig"
        lengthLabel.stringValue = ""
        gcLabel.stringValue = ""
        rankLabel.stringValue = ""
        shareLabel.stringValue = ""
        sequenceView.string = ""
        contextLabel.stringValue = "\(contigCount) contigs available"
        artifactsLabel.stringValue = "Use the table to inspect sequence and assembly context."
    }

    func showSingleSelection(record: AssemblyContigRecord, fasta: String, result: AssemblyResult) {
        titleLabel.stringValue = record.header
        lengthLabel.stringValue = "\(record.lengthBP) bp"
        gcLabel.stringValue = String(format: "%.1f%%", record.gcPercent)
        rankLabel.stringValue = "#\(record.rank)"
        shareLabel.stringValue = String(format: "%.2f%% of assembly", record.shareOfAssemblyPercent)
        sequenceView.string = fasta
        contextLabel.stringValue = """
        Assembler: \(result.tool.displayName)
        Read Type: \(result.readType.displayName)
        Version: \(result.assemblerVersion ?? "unknown")
        """
        artifactsLabel.stringValue = """
        Contigs FASTA: \(result.contigsPath.lastPathComponent)
        Graph: \(result.graphPath?.lastPathComponent ?? "missing")
        Log: \(result.logPath?.lastPathComponent ?? "missing")
        """
    }

    func showMultiSelection(summary: AssemblyContigSelectionSummary) {
        titleLabel.stringValue = "\(summary.selectedContigCount) contigs selected"
        lengthLabel.stringValue = "\(summary.totalSelectedBP) bp total"
        gcLabel.stringValue = String(format: "%.1f%% weighted GC", summary.lengthWeightedGCPercent)
        rankLabel.stringValue = "Longest: \(summary.longestContigBP) bp"
        shareLabel.stringValue = "Shortest: \(summary.shortestContigBP) bp"
        sequenceView.string = ""
        contextLabel.stringValue = "Selection summary for the current filtered ordering."
        artifactsLabel.stringValue = "Use Copy FASTA, Export FASTA, or Create Bundle to materialize the full selection."
    }

    func configureQuickCopy(pasteboard: PasteboardWriting) {
        [titleLabel, lengthLabel, gcLabel, rankLabel, shareLabel].forEach { field in
            field.pasteboard = pasteboard
            field.copiedValue = { field.stringValue }
        }
    }

    #if DEBUG
    func copyValue(identifier: String) {
        switch identifier {
        case "assembly-result-detail-length": lengthLabel.copyCurrentValue()
        case "assembly-result-detail-gc": gcLabel.copyCurrentValue()
        case "assembly-result-detail-rank": rankLabel.copyCurrentValue()
        case "assembly-result-detail-share": shareLabel.copyCurrentValue()
        default: titleLabel.copyCurrentValue()
        }
    }
    var currentHeaderText: String { titleLabel.stringValue }
    var currentSequenceText: String { sequenceView.string }
    var currentSummaryTitle: String { titleLabel.stringValue }
    #endif
}
```

```swift
@MainActor
final class AssemblyContigTableView: BatchTableView<AssemblyContigRecord> {
    var scalarPasteboard: PasteboardWriting = DefaultPasteboard()

    override var columnSpecs: [BatchColumnSpec] {
        [
            .init(identifier: .init("rank"), title: "#", width: 44, minWidth: 34, defaultAscending: true),
            .init(identifier: .init("name"), title: "Contig", width: 220, minWidth: 140, defaultAscending: true),
            .init(identifier: .init("length"), title: "Length (bp)", width: 110, minWidth: 90, defaultAscending: false),
            .init(identifier: .init("gc"), title: "GC %", width: 90, minWidth: 70, defaultAscending: false),
            .init(identifier: .init("share"), title: "Share of Assembly (%)", width: 150, minWidth: 120, defaultAscending: false),
        ]
    }

    override var searchPlaceholder: String { "Filter contigs by name or header…" }
    override var searchAccessibilityIdentifier: String? { "assembly-result-search" }
    override var searchAccessibilityLabel: String? { "Filter assembly contigs" }
    override var tableAccessibilityIdentifier: String? { "assembly-result-contig-table" }
    override var tableAccessibilityLabel: String? { "Assembly contig table" }

    override var columnTypeHints: [String: Bool] {
        ["rank": true, "length": true, "gc": true, "share": true]
    }

    override func cellContent(
        for column: NSUserInterfaceItemIdentifier,
        row: AssemblyContigRecord
    ) -> (text: String, alignment: NSTextAlignment, font: NSFont?) {
        switch column.rawValue {
        case "rank": return ("\(row.rank)", .right, nil)
        case "name": return (row.name, .left, nil)
        case "length": return ("\(row.lengthBP)", .right, nil)
        case "gc": return (String(format: "%.1f", row.gcPercent), .right, nil)
        case "share": return (String(format: "%.2f", row.shareOfAssemblyPercent), .right, nil)
        default: return ("", .left, nil)
        }
    }

    override func rowMatchesFilter(_ row: AssemblyContigRecord, filterText: String) -> Bool {
        let query = filterText.lowercased()
        return row.name.lowercased().contains(query) || row.header.lowercased().contains(query)
    }

    override func compareRows(
        _ lhs: AssemblyContigRecord,
        _ rhs: AssemblyContigRecord,
        by key: String,
        ascending: Bool
    ) -> Bool {
        let ordered: Bool
        switch key {
        case "rank": ordered = lhs.rank < rhs.rank
        case "name": ordered = lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        case "length": ordered = lhs.lengthBP < rhs.lengthBP
        case "gc": ordered = lhs.gcPercent < rhs.gcPercent
        case "share": ordered = lhs.shareOfAssemblyPercent < rhs.shareOfAssemblyPercent
        default: ordered = lhs.rank < rhs.rank
        }
        return ascending ? ordered : !ordered
    }

    override func columnValue(for columnId: String, row: AssemblyContigRecord) -> String {
        switch columnId {
        case "name": return row.name
        case "length": return "\(row.lengthBP)"
        case "gc": return String(format: "%.1f", row.gcPercent)
        case "share": return String(format: "%.2f", row.shareOfAssemblyPercent)
        default: return "\(row.rank)"
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.mouseDown(with: event)
            return
        }

        let localPoint = convert(event.locationInWindow, from: nil)
        let tablePoint = tableView.convert(localPoint, from: self)
        let row = tableView.row(at: tablePoint)
        let column = tableView.column(at: tablePoint)
        guard row >= 0, column >= 0, row < displayedRows.count else {
            super.mouseDown(with: event)
            return
        }

        let record = displayedRows[row]
        let columnID = tableView.tableColumns[column].identifier.rawValue
        scalarPasteboard.setString(columnValue(for: columnID, row: record))
    }
}
```

- [ ] **Step 4: Replace the stub controller with the summary strip, split-shell, stable accessibility IDs, context menu, and selection-driven detail updates**

```swift
@MainActor
public final class AssemblyResultViewController: NSViewController, NSSplitViewDelegate {
    private let summaryStrip = AssemblySummaryStrip()
    private let splitView = TrackedDividerSplitView()
    private let splitCoordinator = TwoPaneTrackedSplitCoordinator()
    private let tableContainer = SplitPaneFillContainerView()
    private let detailContainer = SplitPaneFillContainerView()
    private let contigTableView = AssemblyContigTableView()
    private let detailPane = AssemblyContigDetailPane()
    private let actionBar = AssemblyActionBar()
    private var contigCatalog: AssemblyContigCatalog?
    private var records: [AssemblyContigRecord] = []
    private var selectedRecords: [AssemblyContigRecord] = []
    private let materializationAction = AssemblyContigMaterializationAction()
    private var scalarPasteboard: PasteboardWriting = DefaultPasteboard()

    public func configure(result: AssemblyResult) {
        currentResult = result
        Task { @MainActor in
            contigCatalog = try await AssemblyContigCatalog(result: result)
            records = try await contigCatalog?.records() ?? []
            contigTableView.configure(rows: records)
            summaryStrip.configure(result: result, pasteboard: scalarPasteboard)
            detailPane.configureQuickCopy(pasteboard: scalarPasteboard)
            detailPane.showEmptyState(contigCount: records.count)
            actionBar.infoLabel.stringValue = "\(records.count) contigs"
            applyLayoutPreference()
        }
    }

    public override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setAccessibilityIdentifier("assembly-result-view")
        view = root
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        contigTableView.tableContextMenu = buildContextMenu()
        view.addSubview(summaryStrip)
        view.addSubview(splitView)
        view.addSubview(actionBar)
        tableContainer.addSubview(contigTableView)
        detailContainer.addSubview(detailPane)
        tableContainer.fillSubview = contigTableView
        detailContainer.fillSubview = detailPane
        splitView.addArrangedSubview(tableContainer)
        splitView.addArrangedSubview(detailContainer)

        actionBar.onBlast = { [weak self] in self?.blastSelectedContigs() }
        actionBar.onCopy = { [weak self] in self?.copySelectedContigs() }
        actionBar.onExport = { [weak self] in self?.exportSelectedContigs() }
        actionBar.onBundle = { [weak self] in self?.createBundleFromSelection() }

        NSLayoutConstraint.activate([
            summaryStrip.topAnchor.constraint(equalTo: view.topAnchor),
            summaryStrip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            summaryStrip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: summaryStrip.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            actionBar.topAnchor.constraint(equalTo: splitView.bottomAnchor),
            actionBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            actionBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            actionBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        [
            ("BLAST Selected", #selector(blastSelectedContigs)),
            ("Copy FASTA", #selector(copySelectedContigs)),
            ("Export FASTA…", #selector(exportSelectedContigs)),
            ("Create Bundle…", #selector(createBundleFromSelection)),
        ].forEach { title, action in
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func copySelectedContigs() {
        Task { @MainActor in
            guard let result = currentResult, !selectedContigNames.isEmpty else { return }
            try await materializationAction.copyFASTA(result: result, selectedContigs: selectedContigNames)
        }
    }

    @objc private func exportSelectedContigs() {
        Task { @MainActor in
            guard let result = currentResult, !selectedContigNames.isEmpty else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(selectedContigNames.first ?? "selected_contigs").fasta"
            guard panel.runModal() == .OK, let outputURL = panel.url else { return }
            try await materializationAction.exportFASTA(
                result: result,
                selectedContigs: selectedContigNames,
                outputURL: outputURL
            )
        }
    }

    @objc private func createBundleFromSelection() {
        Task { @MainActor in
            guard let result = currentResult, !selectedContigNames.isEmpty else { return }
            _ = try await materializationAction.createBundle(
                result: result,
                selectedContigs: selectedContigNames,
                suggestedName: selectedContigNames.first ?? "SelectedContigs"
            )
        }
    }

    private func applyLayoutPreference() {
        let layout = MetagenomicsPanelLayout.current()
        splitCoordinator.applyLayoutPreference(
            to: splitView,
            desiredIsVertical: layout != .stacked,
            desiredFirstPane: layout == .detailLeading ? detailContainer : tableContainer,
            desiredSecondPane: layout == .detailLeading ? tableContainer : detailContainer,
            defaultLeadingFraction: layout == .detailLeading ? 0.45 : 0.55,
            minimumExtents: (leading: 320, trailing: 320),
            isViewInWindow: view.window != nil
        )
    }

    private var selectedContigNames: [String] { selectedRecords.map(\.name) }

    private func refreshDetailPane() {
        guard let result = currentResult else { return }

        if selectedRecords.isEmpty {
            detailPane.showEmptyState(contigCount: records.count)
        } else if selectedRecords.count == 1, let record = selectedRecords.first {
            Task { @MainActor in
                guard let contigCatalog else { return }
                let fasta = try await contigCatalog.sequenceFASTA(for: record.name)
                detailPane.showSingleSelection(record: record, fasta: fasta, result: result)
            }
        } else {
            Task { @MainActor in
                guard let contigCatalog else { return }
                let summary = try await contigCatalog.selectionSummary(for: selectedContigNames)
                detailPane.showMultiSelection(summary: summary)
            }
        }
    }

    #if DEBUG
    var testSummaryStrip: AssemblySummaryStrip { summaryStrip }
    var testSplitView: TrackedDividerSplitView { splitView }
    var testTableContainer: NSView { tableContainer }
    var testDetailContainer: NSView { detailContainer }
    var testContigTableView: AssemblyContigTableView { contigTableView }
    var testDetailPane: AssemblyContigDetailPane { detailPane }
    var testActionBar: AssemblyActionBar { actionBar }
    var testContextMenuTitles: [String] { contigTableView.testTableView.menu?.items.map(\.title) ?? [] }

    func configureForTesting(
        result: AssemblyResult,
        scalarPasteboard: PasteboardWriting = DefaultPasteboard()
    ) async throws {
        currentResult = result
        self.scalarPasteboard = scalarPasteboard
        contigCatalog = try await AssemblyContigCatalog(result: result)
        records = try await contigCatalog?.records() ?? []
        contigTableView.configure(rows: records)
        contigTableView.scalarPasteboard = scalarPasteboard
        summaryStrip.configure(result: result, pasteboard: scalarPasteboard)
        detailPane.configureQuickCopy(pasteboard: scalarPasteboard)
        detailPane.showEmptyState(contigCount: records.count)
        applyLayoutPreference()
    }

    func testSelectContig(named name: String) {
        selectedRecords = records.filter { $0.name == name }
        refreshDetailPane()
    }

    func testSelectContigs(named names: [String]) {
        let selected = Set(names)
        selectedRecords = records.filter { selected.contains($0.name) }
        refreshDetailPane()
    }

    func testTriggerBlast() {
        blastSelectedContigs()
    }

    func testCopySummaryValue(identifier: String) {
        summaryStrip.copyValue(for: identifier)
    }

    func testCopyVisibleDetailValue(identifier: String) {
        detailPane.copyValue(identifier: identifier)
    }

    func testCopyVisibleTableValue(row: Int, columnID: String) {
        let record = records[row]
        contigTableView.scalarPasteboard.setString(contigTableView.columnValue(for: columnID, row: record))
    }
    #endif
}
```

- [ ] **Step 5: Re-run the viewport controller tests**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-browser/.worktrees/assembly-xcui-pilot --filter AssemblyResultViewControllerTests
```

Expected: PASS with stacked layout, single-selection detail, and multi-selection summary behavior verified.

- [ ] **Step 6: Commit the viewport-shell tranche**

```bash
git add Sources/LungfishApp/Views/Metagenomics/BatchTableView.swift Sources/LungfishApp/Views/Results/Assembly/AssemblySummaryStrip.swift Sources/LungfishApp/Views/Results/Assembly/AssemblyActionBar.swift Sources/LungfishApp/Views/Results/Assembly/AssemblyContigTableView.swift Sources/LungfishApp/Views/Results/Assembly/AssemblyContigDetailPane.swift Sources/LungfishApp/Views/Results/Assembly/AssemblyResultViewController.swift Tests/LungfishAppTests/AssemblyResultViewControllerTests.swift
git commit -m "feat: rebuild assembly result viewport"
```

### Task 5: Wire Viewer Integration, Real BLAST Sequences, And Final Regression Coverage

**Files:**
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+Assembly.swift`
- Modify: `Sources/LungfishApp/Views/Results/Assembly/AssemblyResultViewController.swift`
- Create: `Tests/LungfishAppTests/AssemblyViewerIntegrationTests.swift`

- [ ] **Step 1: Write the failing integration tests for BLAST callback payloads and viewer hosting**

```swift
@MainActor
final class AssemblyViewerIntegrationTests: XCTestCase {
    func testBlastCallbackReceivesRealFastaPayload() async throws {
        let vc = AssemblyResultViewController()
        _ = vc.view
        try await vc.configureForTesting(result: makeAssemblyResult())

        let exp = expectation(description: "blast callback")
        vc.onBlastVerification = { request in
            XCTAssertEqual(request.readCount, 1)
            XCTAssertEqual(request.sourceLabel, "contig contig_7")
            XCTAssertEqual(request.sequences, [">contig_7 annotated header\nAACCGGTT\n"])
            exp.fulfill()
        }

        vc.testSelectContig(named: "contig_7")
        vc.testTriggerBlast()

        await fulfillment(of: [exp], timeout: 1.0)
    }

    func testViewerDisplayAssemblyResultHostsAssemblyController() {
        let viewer = ViewerViewController()
        _ = viewer.view

        viewer.displayAssemblyResult(makeAssemblyResult())

        XCTAssertNotNil(viewer.assemblyResultController)
        XCTAssertTrue(viewer.assemblyResultController?.view.superview === viewer.view)
    }
}
```

- [ ] **Step 2: Run the focused integration tests**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-browser/.worktrees/assembly-xcui-pilot --filter AssemblyViewerIntegrationTests
```

Expected: FAIL because the current viewer extension does not wire assembly BLAST and the controller still exposes stub callbacks.

- [ ] **Step 3: Wire the controller callback and convert FASTA payloads into a direct BLAST verification request**

```swift
extension ViewerViewController {
    public func displayAssemblyResult(_ result: AssemblyResult) {
        hideQuickLookPreview()
        hideFASTQDatasetView()
        hideVCFDatasetView()
        hideFASTACollectionView()
        hideTaxonomyView()
        hideEsVirituView()
        hideTaxTriageView()
        hideNaoMgsView()
        hideNvdView()
        hideAssemblyView()
        clearBundleDisplay()
        hideCollectionBackButton()
        contentMode = .genomics

        let controller = AssemblyResultViewController()
        addChild(controller)
        let assemblyView = controller.view
        controller.configure(result: result)
        controller.onBlastVerification = { request in
            let tuples = request.sequences.compactMap { fasta -> (String, String)? in
                let lines = fasta.split(separator: "\n", omittingEmptySubsequences: true)
                guard let header = lines.first else { return nil }
                let id = header.dropFirst().split(separator: " ").first.map(String.init) ?? "contig"
                let sequence = lines.dropFirst().joined()
                return (id, sequence)
            }

            let verificationRequest = BlastVerificationRequest(
                taxonName: request.sourceLabel,
                taxId: 0,
                sequences: tuples,
                entrezQuery: nil
            )

            Task.detached {
                _ = try await BlastService.shared.verify(request: verificationRequest)
            }
        }
        assemblyView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(assemblyView)
        NSLayoutConstraint.activate([
            assemblyView.topAnchor.constraint(equalTo: view.topAnchor),
            assemblyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            assemblyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            assemblyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        assemblyResultController = controller
    }
}
```

```swift
@objc private func blastSelectedContigs() {
    Task { @MainActor in
        guard
            let result = currentResult,
            !selectedContigNames.isEmpty
        else { return }

        let request = try await materializationAction.buildBlastRequest(
            result: result,
            selectedContigs: selectedContigNames
        )
        onBlastVerification?(request)
    }
}
```

- [ ] **Step 4: Run the new integration tests and the full assembly viewport suite**

Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-browser/.worktrees/assembly-xcui-pilot --filter AssemblyViewerIntegrationTests
swift test --package-path /Users/dho/Documents/lungfish-genome-browser/.worktrees/assembly-xcui-pilot --filter AssemblyResultViewControllerTests
swift test --package-path /Users/dho/Documents/lungfish-genome-browser/.worktrees/assembly-xcui-pilot --filter AssemblyContigMaterializationActionTests
swift test --package-path /Users/dho/Documents/lungfish-genome-browser/.worktrees/assembly-xcui-pilot --filter ExtractContigsCommandTests
swift test --package-path /Users/dho/Documents/lungfish-genome-browser/.worktrees/assembly-xcui-pilot --filter AssemblyContigCatalogTests
```

Expected: PASS across the new workflow, CLI, and app-level test tranches.

- [ ] **Step 5: Commit the final integration tranche**

```bash
git add Sources/LungfishApp/Views/Viewer/ViewerViewController+Assembly.swift Sources/LungfishApp/Views/Results/Assembly/AssemblyResultViewController.swift Tests/LungfishAppTests/AssemblyViewerIntegrationTests.swift
git commit -m "feat: wire assembly contig blast and viewer integration"
```

## Self-Review Checklist

Spec coverage:

- classifier-style multi-part shell: Task 4
- shared movable layout modes: Task 4
- truthful contig columns and summaries: Tasks 1 and 4
- assembly-level summary strip fields and quick-copy affordance: Task 4
- CLI-backed FASTA export, copy, and bundle creation: Tasks 2 and 3
- derived-subset `.lungfishref` semantics: Task 2
- BLAST with real FASTA payloads: Tasks 3 and 5
- accessibility- and automation-ready shell structure: Task 4

Placeholder scan:

- no `TODO`, `TBD`, or “similar to” references remain
- every task includes concrete files, test commands, and code snippets

Type consistency:

- workflow catalog types are introduced in Task 1 and reused consistently in Tasks 2-5
- CLI subcommand name is consistently `ExtractContigsSubcommand`
- app action class is consistently `AssemblyContigMaterializationAction`
