// ViewerExtractionOperationTests.swift - begin() site in ViewerViewController+Extraction
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Building a bundle from an extracted sequence registers its row through a
// static begin helper on SequenceViewerView (R4). Since 2.11 A48 M2 a viewer
// with a reference bundle launches `lungfish-cli extract sequence --bundle`
// with the argv the site hands the helper, and the row records that argv, so
// a parse test replaces the gap pin of `region-bundle-extraction`.
// RegionBundleExtractionParityReplayTests replays the command. A viewer with
// no reference bundle stages its sequence and launches the same leaf on that
// FASTA since 2.12 lane 12.12 (A48-GAP), and its row records that argv. A reporter that refuses
// every begin proves the launch closure sits behind the `.started` case.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishKit
import LungfishKitTestSupport
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class ViewerExtractionOperationTests: XCTestCase {
    private let sourceBundle = URL(fileURLWithPath: "/tmp/lane 1a2f/Project.lungfish/Ref.lungfishref", isDirectory: true)
    private let outputBundle = URL(
        fileURLWithPath: "/tmp/lane 1a2f/Project.lungfish/Extractions/-Region 1.lungfishref", isDirectory: true
    )

    private func featureArguments() -> [String] {
        let annotation = SequenceAnnotation(
            type: .cds, name: "-cds, A", chromosome: "NC_045512.2",
            intervals: [AnnotationInterval(start: 99, end: 150), AnnotationInterval(start: 160, end: 200)], strand: .reverse
        )
        return SequenceExtractionPipeline.cliArguments(
            source: .annotation(annotation),
            flank5Prime: 5,
            flank3Prime: 0,
            reverseComplement: true,
            concatenateExons: true,
            sourceBundleURL: sourceBundle,
            bundleName: "-Region 1",
            sampleFilter: ["S.1 a", "b,2"],
            outputBundleURL: outputBundle
        )
    }

    func testExtractionBundleRecordsTheCommandItsLaunchRuns() throws {
        let reporter = RecordingOperationReporter()
        let routeContext = OperationRouteContext(
            projectURL: URL(fileURLWithPath: "/tmp/lane 1a2f/Project.lungfish", isDirectory: true),
            windowStateScopeID: UUID()
        )
        var launchedID: UUID?
        let arguments = featureArguments()

        SequenceViewerView.beginExtractionBundleOperation(
            sourceName: "-cds, A",
            arguments: arguments,
            routeContext: routeContext,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "Extracting -cds, A")
        XCTAssertEqual(item.initialDetail, "Preparing...")
        XCTAssertEqual(item.operationType, .bundleBuild)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        XCTAssertEqual(
            item.cliCommand,
            OperationCenter.buildCLICommand(subcommand: "extract sequence", args: Array(arguments.dropFirst(2))),
            "the row records the argv the launch runs"
        )
        let command = try RecordedCLICommand.parse(item.cliCommand, as: ExtractSequenceSubcommand.self)
        XCTAssertEqual(command.input, sourceBundle.path)
        XCTAssertEqual(command.region, "NC_045512.2:100-150,161-200", "the feature's parts, 1-based and inclusive")
        XCTAssertTrue(command.bundle)
        XCTAssertEqual(command.featureName, "-cds, A", "a hyphen-leading name stays a value")
        XCTAssertEqual(command.featureType, "CDS")
        XCTAssertEqual(command.strand, "-")
        XCTAssertTrue(command.reverseComplement)
        XCTAssertTrue(command.concatenateExons)
        XCTAssertEqual(command.flank5, 5)
        XCTAssertNil(command.flank3)
        XCTAssertEqual(command.name, "-Region 1")
        XCTAssertEqual(command.samples, ["S.1 a", "b,2"], "each sample is one word, so a name may hold a comma")
        XCTAssertFalse(command.noSamples)
        XCTAssertEqual(command.output, outputBundle.path)
        XCTAssertTrue(command.nextFreeName, "a run that overlaps another of the same name replaces nothing (Fix 6)")
        XCTAssertEqual(command.globalOptions.outputFormat, .json, "the runner reads the command's events")
    }

    func testARunThatHidesEverySampleRecordsNoSamples() throws {
        let reporter = RecordingOperationReporter()
        let arguments = SequenceExtractionPipeline.cliArguments(
            source: .region(chromosome: "chr1", start: 9, end: 40),
            flank5Prime: 0, flank3Prime: 0, reverseComplement: false, concatenateExons: false,
            sourceBundleURL: sourceBundle, bundleName: nil, sampleFilter: [], outputBundleURL: outputBundle
        )

        SequenceViewerView.beginExtractionBundleOperation(
            sourceName: "chr1:10-40", arguments: arguments, routeContext: nil, reporter: reporter
        ) { _ in }

        let command = try RecordedCLICommand.parse(reporter.items.first?.cliCommand, as: ExtractSequenceSubcommand.self)
        XCTAssertEqual(command.region, "chr1:10-40")
        XCTAssertNil(command.featureName)
        XCTAssertNil(command.name)
        XCTAssertTrue(command.noSamples)
        XCTAssertEqual(command.samples, [])
    }

    /// A viewer with no reference bundle records `extract sequence` on the FASTA it staged (2.12 lane
    /// 12.12, A48-GAP), with the name the person gave, a blank one included, and the document it shows.
    func testAViewerWithNoReferenceBundleRecordsTheCommandOnItsStagedFASTA() throws {
        let reporter = RecordingOperationReporter()
        let staged = URL(fileURLWithPath: "/tmp/lane 1a2f/Project.lungfish/.tmp/extract-sequence-input-1/sequence.fa")
        let document = URL(fileURLWithPath: "/tmp/lane 1a2f/Project.lungfish/Downloads/-virus.gb")
        let annotation = SequenceAnnotation(
            type: .cds, name: "-cds, A", chromosome: nil,
            intervals: [AnnotationInterval(start: 2, end: 6), AnnotationInterval(start: 10, end: 14)], strand: .reverse
        )
        let arguments = SequenceExtractionPipeline.cliFASTAArguments(
            source: .annotation(annotation), flank5Prime: 2, flank3Prime: 0, reverseComplement: false,
            concatenateExons: true, inputURL: staged, sequenceName: "NC_TEST", sourceDocumentURL: document,
            bundleName: "  ", outputBundleURL: outputBundle
        )

        SequenceViewerView.beginExtractionBundleOperation(
            sourceName: "-cds, A", arguments: arguments, routeContext: nil, reporter: reporter
        ) { _ in }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.title, "Extracting -cds, A")
        XCTAssertEqual(item.initialDetail, "Preparing...")
        XCTAssertEqual(item.cliCommand, OperationCenter.buildCLICommand(subcommand: "extract sequence", args: Array(arguments.dropFirst(2))))
        let command = try RecordedCLICommand.parse(item.cliCommand, as: ExtractSequenceSubcommand.self)
        XCTAssertEqual(command.input, staged.path)
        XCTAssertEqual(command.region, "NC_TEST:3-6,11-14", "a feature that names no sequence takes the viewer's")
        XCTAssertFalse(command.bundle)
        XCTAssertEqual(command.featureName, "-cds, A")
        XCTAssertEqual(command.strand, "-")
        XCTAssertTrue(command.concatenateExons)
        XCTAssertEqual(command.flank5, 2)
        XCTAssertEqual(command.name, "  ", "a blank name is recorded as given, as the in-process route did")
        XCTAssertEqual(command.sourceDocument, document.path)
        XCTAssertEqual(command.output, outputBundle.path)
        XCTAssertTrue(command.nextFreeName)
        XCTAssertEqual(command.globalOptions.outputFormat, .json)

        let empty = SequenceExtractionPipeline.cliFASTAArguments(
            source: .region(chromosome: "NC_TEST", start: 9, end: 40), flank5Prime: 0, flank3Prime: 0,
            reverseComplement: false, concatenateExons: false, inputURL: staged, sequenceName: "NC_TEST",
            sourceDocumentURL: nil, bundleName: "", outputBundleURL: outputBundle
        )
        let emptyCommand = try ExtractSequenceSubcommand.parse(Array(empty.dropFirst(2)))
        XCTAssertNil(emptyCommand.name, "an empty name, which no option carries, goes as none")
        XCTAssertNil(emptyCommand.sourceDocument)
        XCTAssertEqual(emptyCommand.region, "NC_TEST:10-40")
    }

    /// The staged FASTA holds the viewer's sequence under its name, 70 bases a line, in a folder of its
    /// own under the project's `.tmp/` that stays, and nothing else.
    func testTheStagedInputIsAFASTAUnderTheProjectTmpThatStays() async throws {
        let root = try TestTempDirectory.make(prefix: "staged-sequence-input")
        defer { TestTempDirectory.cleanup(root) }
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let bases = String(repeating: "ACGT", count: 40)

        let url = try await StagedSequenceInput.writeFASTA(
            [.init(name: "NC_TEST", bases: bases)], fileName: "sequence.fa", prefix: "extract-sequence-input-", projectURL: project
        )

        let folder = url.deletingLastPathComponent()
        XCTAssertEqual(folder.deletingLastPathComponent().standardizedFileURL.path, project.appendingPathComponent(".tmp").standardizedFileURL.path)
        XCTAssertTrue(folder.lastPathComponent.hasPrefix("extract-sequence-input-"))
        let expected = ">NC_TEST\n" + String(bases.prefix(70)) + "\n" + String(bases.dropFirst(70).prefix(70)) + "\n"
            + String(bases.dropFirst(140)) + "\n"
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), expected)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertFalse(names.contains { $0.contains(DurableReplace.stageInfix) }, "\(names)")
        let sequences = try await FASTAReader(url: url).readAll()
        XCTAssertEqual(sequences.map(\.name), ["NC_TEST"])
    }

    /// A run that failed and published nothing writes no record, so nothing names its staged folder and
    /// the folder goes. A run that published keeps it, because the record names it (2.12 review of lane
    /// 12.12, Fix 2).
    func testAStagedInputGoesWhenTheRunPublishedNothingAndStaysWhenItPublished() async throws {
        let root = try TestTempDirectory.make(prefix: "staged-sequence-discard")
        defer { TestTempDirectory.cleanup(root) }
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let output = project.appendingPathComponent("Extractions/Region 1.lungfishref", isDirectory: true)
        let fileManager = FileManager.default

        let failed = try await StagedSequenceInput.writeFASTA(
            [.init(name: "NC_TEST", bases: "ACGTACGT")], fileName: "sequence.fa", prefix: "extract-sequence-input-", projectURL: project
        ).deletingLastPathComponent()
        XCTAssertTrue(fileManager.fileExists(atPath: failed.appendingPathComponent("sequence.fa").path))
        XCTAssertFalse(fileManager.fileExists(atPath: output.path))
        XCTAssertTrue(StagedSequenceInput.discard(failed, unlessPublishedAt: output), "nothing published, so the folder goes")
        XCTAssertFalse(fileManager.fileExists(atPath: failed.path), "the folder is gone")

        let published = try await StagedSequenceInput.writeFASTA(
            [.init(name: "NC_TEST", bases: "ACGTACGT")], fileName: "sequence.fa", prefix: "extract-sequence-input-", projectURL: project
        ).deletingLastPathComponent()
        try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
        XCTAssertFalse(StagedSequenceInput.discard(published, unlessPublishedAt: output), "a bundle is published, so the folder stays")
        XCTAssertTrue(fileManager.fileExists(atPath: published.appendingPathComponent("sequence.fa").path), "the staged FASTA stays")
    }

    /// A write that fails leaves no folder (M839 of 2.12, Phase 2.13). `writeFASTA` makes its kept folder before
    /// the write, so a write that threw left an empty folder under `.tmp/` that no row or record accounted for.
    func testAStagedInputWhoseWriteFailsLeavesNoFolderUnderTmp() async throws {
        let root = try TestTempDirectory.make(prefix: "staged-sequence-failed-write")
        defer { TestTempDirectory.cleanup(root) }
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        do {
            _ = try await StagedSequenceInput.writeFASTA(
                [.init(name: "NC_TEST", bases: "ACGTACGT")], fileName: "inside/sequence.fa",
                prefix: "extract-sequence-input-", projectURL: project
            )
            XCTFail("a name that is not one path component cannot be written")
        } catch {
            // The write failed, which is the case under test.
        }

        let temp = project.appendingPathComponent(".tmp", isDirectory: true)
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? [])
            .filter { $0.hasPrefix("extract-sequence-input-") }
        XCTAssertEqual(left, [], "a failed write removes the folder it made")
    }

    /// The catch of `launchExtractionBundle` (2.12 review of lane 12.12, Fix 2, wiring gap of M839). A run that
    /// fails and published nothing removes its staged folder. A run the runner acknowledged as cancelled keeps
    /// it, and so does a failure after the bundle was published, because their records name it. The runner is
    /// the one seam, replaced here by a closure that throws, and the launch returns the task that ends the row.
    func testTheCatchOfALaunchRemovesTheStagedFolderOnlyForAFailureThatPublishedNothing() async throws {
        _ = NSApplication.shared // The failure alert reads NSApp.keyWindow.
        let root = try TestTempDirectory.make(prefix: "launch-extraction-catch")
        defer { TestTempDirectory.cleanup(root) }
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let output = project.appendingPathComponent("Extractions/Region 1.lungfishref", isDirectory: true)
        let fileManager = FileManager.default
        struct LaunchFailure: Error {}

        func stage() async throws -> URL {
            try await StagedSequenceInput.writeFASTA(
                [.init(name: "NC_TEST", bases: "ACGTACGT")], fileName: "sequence.fa",
                prefix: "extract-sequence-input-", projectURL: project
            ).deletingLastPathComponent()
        }
        func launch(_ staged: URL, throwing error: any Error) async {
            await SequenceViewerView.launchExtractionBundle(
                arguments: ["extract", "sequence"], outputBundleURL: output, itemId: UUID(), stagedInput: staged,
                launch: { _, _ in throw error }
            ).value
        }

        let failed = try await stage()
        await launch(failed, throwing: LaunchFailure())
        XCTAssertFalse(fileManager.fileExists(atPath: failed.path), "a failure that published nothing removes the staged folder")

        let cancelled = try await stage()
        await launch(cancelled, throwing: CancellationError())
        XCTAssertTrue(fileManager.fileExists(atPath: cancelled.path), "a cancel keeps the folder its record names")

        let published = try await stage()
        try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
        await launch(published, throwing: LaunchFailure())
        XCTAssertTrue(fileManager.fileExists(atPath: published.path), "a failure after the bundle was published keeps the folder")
    }

    func testExtractionBundleLaunchesNothingWhenTheBeginIsRefused() throws {
        // The row requests no lock, so no real center refuses it. A reporter
        // that refuses every begin proves the launch closure sits behind the
        // `.started` case.
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        var launched = false

        let result = SequenceViewerView.beginExtractionBundleOperation(
            sourceName: "NC_045512.2:100-200",
            arguments: featureArguments(),
            routeContext: nil,
            reporter: reporter
        ) { _ in launched = true }

        guard case .refused = result else { return XCTFail("The refusal must be reported") }
        XCTAssertFalse(launched, "a refused row must launch nothing")
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
    }
}
