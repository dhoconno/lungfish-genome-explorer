// TaxonomyExtractionDestinationPinTests.swift - The four destinations of a classifier extraction at the base
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A66 M1, freeze first (QA 1). One Kraken2 selection, taxon 20 of the single-end
// fixture, goes to each destination of the extraction sheet through `ClassifierReadResolver`, and
// the row that destination registers is read back. The file and bundle destinations write the
// selection's reads as plain FASTQ and record a runnable `lungfish-cli extract reads` command. The
// clipboard destination hands the same bytes to the pasteboard as one string and refuses a selection
// over its cap. The share destination writes the same bytes into a folder of the project's scratch.
// Since Phase 2.12 lane 12.11 the clipboard and share rows record the `lungfish-cli extract reads`
// command that writes the selection into the scratch file the app copies. The resolver calls here
// are the in-process engine those rows ran before, the side A of the lane's parity class.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class TaxonomyExtractionDestinationPinTests: XCTestCase {
    private var root: URL!
    private var fixtures: TaxaCollectionFixtures!
    private let routeContext = OperationRouteContext(
        projectURL: URL(fileURLWithPath: "/tmp/lane a66/Project.lungfish"),
        windowStateScopeID: UUID()
    )

    /// The reads of taxon 20 in the single-end fixture, as the resolver writes them.
    private static let expectedFASTQ = ReadSetFixtures.fastq(["b1", "b2"])

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "extraction-destination-pin")
        fixtures = try TaxaCollectionFixtures(in: root)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    private var selections: [ClassifierRowSelector] {
        [ClassifierRowSelector(sampleId: nil, accessions: [], taxIds: [TaxaCollectionFixtures.speciesB])]
    }

    private func context() -> TaxonomyReadExtractionAction.Context {
        TaxonomyReadExtractionAction.Context(
            tool: .kraken2,
            resultPath: fixtures.singleEnd,
            selections: selections,
            suggestedName: "my-extract",
            routeContext: routeContext
        )
    }

    private func extract(_ destination: ExtractionDestination) async throws -> ExtractionOutcome {
        try await ClassifierReadResolver().resolveAndExtract(
            tool: .kraken2,
            resultPath: fixtures.singleEnd,
            selections: selections,
            options: ExtractionOptions(format: .fastq),
            destination: destination
        )
    }

    /// The row the sheet registers for `destination`, with the scratch file of its copy route, which a
    /// clipboard or share destination has (Phase 2.12 lane 12.11).
    private func recordedRow(
        _ destination: ExtractionDestination
    ) throws -> (item: RecordingOperationReporter.Item, scratchFile: URL?) {
        let reporter = RecordingOperationReporter()
        let options = ExtractionOptions(format: .fastq)
        let route = try ClassifierExtractionCopyRoute.make(destination: destination, context: context(), options: options)
        let built = TaxonomyReadExtractionAction.buildCLIString(
            context: context(), options: options, destination: destination, scratchFile: route?.scratchFile
        )
        TaxonomyReadExtractionAction.beginExtractionOperation(context: context(), cliCommand: built, reporter: reporter) { _ in }
        return (try XCTUnwrap(reporter.items.first), route?.scratchFile)
    }

    /// The clipboard or share row's command: the selection's `extract reads` into the route's scratch file,
    /// with the events the row shows.
    private func assertTheRowRunsTheCommandIntoItsScratchFile(
        _ destination: ExtractionDestination, under folder: URL, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let (item, scratchFile) = try recordedRow(destination)
        let scratch = try XCTUnwrap(scratchFile, "a clipboard or share row has a scratch file", file: file, line: line)
        XCTAssertTrue(scratch.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/"), scratch.path, file: file, line: line)
        let command = try RecordedCLICommand.parse(item.cliCommand, as: ExtractReadsSubcommand.self)
        XCTAssertTrue(command.byClassifier, file: file, line: line)
        XCTAssertEqual(command.classifierTaxonsRaw, ["20"], file: file, line: line)
        XCTAssertEqual(command.classifierFormat, "fastq", file: file, line: line)
        XCTAssertEqual(command.output, scratch.path, file: file, line: line)
        XCTAssertEqual(command.globalOptions.outputFormat, .json, file: file, line: line)
        try? FileManager.default.removeItem(at: scratch.deletingLastPathComponent())
    }

    private func text(of url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    // MARK: - File

    func testTheFileDestinationWritesPlainFASTQAndRecordsARunnableCommand() async throws {
        let output = root.appendingPathComponent("out", isDirectory: true).appendingPathComponent("my extract.fastq")
        let destination = ExtractionDestination.file(output)

        guard case .file(let url, let count) = try await extract(destination) else { return XCTFail("a file outcome") }
        XCTAssertEqual(url.standardizedFileURL.path, output.standardizedFileURL.path)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(try text(of: url), Self.expectedFASTQ)

        let (item, _) = try recordedRow(destination)
        let command = try RecordedCLICommand.parse(item.cliCommand, as: ExtractReadsSubcommand.self)
        XCTAssertTrue(command.byClassifier)
        XCTAssertEqual(command.classifierTool, "kraken2")
        XCTAssertEqual(command.classifierResult, fixtures.singleEnd.path)
        XCTAssertEqual(command.classifierTaxonsRaw, ["20"])
        XCTAssertEqual(command.classifierFormat, "fastq")
        XCTAssertEqual(command.output, output.path)
        XCTAssertFalse(command.createBundle)
    }

    // MARK: - Bundle

    func testTheBundleDestinationWritesTheSameFASTQIntoTheExtractionsFolderAndRecordsARunnableCommand() async throws {
        let destination = ExtractionDestination.bundle(
            projectRoot: fixtures.projectURL,
            displayName: "my-extract",
            metadata: ExtractionMetadata(sourceDescription: "my-extract", toolName: "Kraken2")
        )

        guard case .bundle(let bundle, let count) = try await extract(destination) else { return XCTFail("a bundle outcome") }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(bundle.deletingLastPathComponent().lastPathComponent, ClassifierReadResolver.extractionsFolderName)
        let payload = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil).first { $0.pathExtension == "fastq" },
            "the bundle holds one FASTQ payload"
        )
        XCTAssertEqual(try text(of: payload), Self.expectedFASTQ)

        let (item, _) = try recordedRow(destination)
        let command = try RecordedCLICommand.parse(item.cliCommand, as: ExtractReadsSubcommand.self)
        XCTAssertTrue(command.createBundle)
        XCTAssertEqual(command.bundleName, "my-extract")
        XCTAssertEqual(command.classifierTaxonsRaw, ["20"])
        XCTAssertEqual(
            command.output,
            fixtures.projectURL.appendingPathComponent("Extractions/my-extract.fastq").path,
            "the command writes where the app creates bundles"
        )
    }

    // MARK: - Clipboard

    func testTheClipboardDestinationHandsTheSameBytesToThePasteboardAndRecordsItsCommand() async throws {
        let destination = ExtractionDestination.clipboard(format: .fastq, cap: TaxonomyReadExtractionAction.clipboardReadCap)

        guard case .clipboard(let payload, let byteCount, let count) = try await extract(destination) else {
            return XCTFail("a clipboard outcome")
        }
        // What the clipboard parse test asserts: the payload is the FASTQ text of the selection.
        XCTAssertEqual(payload, Self.expectedFASTQ)
        XCTAssertEqual(byteCount, payload.utf8.count)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(payload.split(separator: "\n").count, 4 * count, "four lines a read")
        XCTAssertEqual(TaxonomyReadExtractionAction.clipboardReadCap, 10_000)

        // The row records the command that writes the selection into a scratch folder of the project's .tmp.
        try assertTheRowRunsTheCommandIntoItsScratchFile(destination, under: ProjectTempDirectory.tempRoot(for: fixtures.projectURL))
    }

    func testTheClipboardCapIsInclusiveAndARefusalNamesTheSelectionAndTheCap() async throws {
        guard case .clipboard(_, _, let count) = try await extract(.clipboard(format: .fastq, cap: 2)) else {
            return XCTFail("a selection at the cap is copied")
        }
        XCTAssertEqual(count, 2)
        do {
            _ = try await extract(.clipboard(format: .fastq, cap: 1))
            XCTFail("a selection over the cap is refused")
        } catch ClassifierExtractionError.clipboardCapExceeded(let requested, let cap) {
            XCTAssertEqual(requested, 2)
            XCTAssertEqual(cap, 1)
        }
    }

    /// The refusal is words a person reads in the sheet (Phase 2.12 lane 12.11 M1, UX inv 47).
    func testTheCapRefusalTellsThePersonTheCountTheCapAndTheOtherDestinations() async throws {
        do {
            _ = try await extract(.clipboard(format: .fastq, cap: 1))
            XCTFail("a selection over the cap is refused")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Selection contains 2 reads, which exceeds the clipboard cap of 1. Choose Save to File, Save as Bundle, or Share instead."
            )
        }
    }

    // MARK: - Share

    func testTheShareDestinationWritesTheSameBytesBelowTheScratchFolderAndRecordsItsCommand() async throws {
        let scratch = fixtures.projectURL.appendingPathComponent(".lungfish/.tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let destination = ExtractionDestination.share(tempDirectory: scratch)

        guard case .share(let url, let count) = try await extract(destination) else { return XCTFail("a share outcome") }
        XCTAssertEqual(count, 2)
        XCTAssertTrue(url.standardizedFileURL.path.hasPrefix(scratch.standardizedFileURL.path + "/shares/"), url.path)
        XCTAssertEqual(try text(of: url), Self.expectedFASTQ)

        // The row records the command that writes the selection into a new folder below the share root.
        try assertTheRowRunsTheCommandIntoItsScratchFile(destination, under: scratch.appendingPathComponent("shares", isDirectory: true))
    }
}
