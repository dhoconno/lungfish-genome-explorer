// FASTQSameStemInputsTests.swift - Two datasets with one name are given two output folders
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Trust session lane PROBE-STEM (review FIX-GROUP-BIO, section 6 item 3). A run of several datasets writes each one's
// output under `<run>/<dataset stem>`, and `a/reads.lungfishfastq` and `b/reads.lungfishfastq` (or `s.fastq` and
// `s.fastq.gz`) were both given `<run>/reads`. `lungfish-cli fastq deacon-ribo` writes into a folder that holds files
// and names its file after the dataset, so the second command met the first one's output and the run failed
// (`FASTQSameStemInputsConformanceTests` runs the real tools). The planner now gives a later dataset with a name
// an earlier one holds `<stem>-2`, `-3` and so on, and leaves every other folder where it was.
//
// This is the stand-in and needs no tool: it reads the plans and the command the Operations row begins with.

import Darwin
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
@testable import LungfishIO
import LungfishKit
import LungfishKitTestSupport
@testable import LungfishOperations
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class FASTQSameStemInputsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        // The physical path (/private/var, not /var), so the paths the tests compare agree.
        let made = try TestTempDirectory.make(prefix: "same-stem-inputs")
        let physical = try XCTUnwrap(realpath(made.path, nil))
        defer { free(physical) }
        root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// A reads bundle `<folder>/<name>.lungfishfastq` of one read in the project.
    private func makeBundle(_ name: String, in folder: String) throws -> URL {
        let parent = root.appendingPathComponent("Project.lungfish/\(folder)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let bundle = try FASTQOperationTestHelper.makeBundle(named: name, in: parent)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: bundle.fastqURL, readCount: 1, readLength: 60, idPrefix: folder)
        return bundle.bundleURL
    }

    private var runFolder: URL {
        root.appendingPathComponent("Project.lungfish/Analyses/run", isDirectory: true)
    }

    private func demultiplex(_ inputs: [URL], mode: FASTQOperationOutputMode) -> FASTQOperationLaunchRequest {
        .derivative(
            request: .demultiplex(
                kitID: "illumina-nextera", customCSVPath: nil, location: "bothends", symmetryMode: nil,
                maxDistanceFrom5Prime: 0, maxDistanceFrom3Prime: 0, errorRate: 0.15, engine: .cutadapt,
                trimBarcodes: true, sampleAssignments: nil, kitOverride: nil
            ),
            inputURLs: inputs,
            outputMode: mode
        )
    }

    /// The folder under the run that each plan writes into, by name.
    private func planFolders(_ request: FASTQOperationLaunchRequest, base: URL? = nil) -> [String] {
        let base = base ?? runFolder
        return FASTQOperationPlanner().makeExecutionPlans(
            originalRequest: request, resolvedRequest: request, baseOutputDirectory: base
        ).map { plan in
            String(plan.outputTarget.path.dropFirst(base.path.count + 1)).split(separator: "/").first.map(String.init) ?? ""
        }
    }

    // MARK: - The plans

    /// Two datasets named `reads` in two folders are two folders under the run, in both Output Strategies.
    func testTwoDatasetsWithOneNameAreGivenTwoFolders() throws {
        let inputs = [try makeBundle("reads", in: "a"), try makeBundle("reads", in: "b")]
        let ribo = FASTQDerivativeRequest.ribosomalRNAFilter(retention: .nonRRNA, ensure: .none)
        for mode in [FASTQOperationOutputMode.perInput, .groupedResult] {
            XCTAssertEqual(planFolders(demultiplex(inputs, mode: mode)), ["reads", "reads-2"], "demultiplex, \(mode)")
            XCTAssertEqual(
                planFolders(.derivative(request: .lengthFilter(min: 1, max: nil), inputURLs: inputs, outputMode: mode)),
                ["reads", "reads-2"], "length filter, \(mode)"
            )
            XCTAssertEqual(
                planFolders(.derivative(request: ribo, inputURLs: inputs, outputMode: mode)),
                ["reads", "reads-2"], "ribosomal RNA filter, \(mode)"
            )
        }
    }

    /// `s.fastq` and `s.fastq.gz` share the stem `s` (`sanitizedStem` drops `.gz` first).
    func testAPlainAndACompressedFileWithOneStemAreGivenTwoFolders() {
        let folder = root.appendingPathComponent("Project.lungfish/Imports", isDirectory: true)
        let inputs = [folder.appendingPathComponent("s.fastq"), folder.appendingPathComponent("s.fastq.gz")]
        let request = FASTQOperationLaunchRequest.derivative(
            request: .lengthFilter(min: 1, max: nil), inputURLs: inputs, outputMode: .perInput
        )
        XCTAssertEqual(planFolders(request), ["s", "s-2"])
    }

    /// A later dataset takes the next number that no dataset's own name holds, so `reads-2` keeps its folder.
    func testANumberedNameAnotherDatasetHoldsIsNotTaken() throws {
        let inputs = [
            try makeBundle("reads", in: "a"), try makeBundle("reads", in: "b"),
            try makeBundle("reads-2", in: "c"), try makeBundle("reads", in: "d"),
        ]
        XCTAssertEqual(planFolders(demultiplex(inputs, mode: .groupedResult)), ["reads", "reads-3", "reads-2", "reads-4"])
    }

    /// Names that differ only in case are one folder on a Mac disk that folds case, and on ExFAT.
    func testNamesThatDifferOnlyInCaseAreGivenTwoFolders() throws {
        let inputs = [try makeBundle("Reads", in: "a"), try makeBundle("reads", in: "b")]
        XCTAssertEqual(planFolders(demultiplex(inputs, mode: .perInput)), ["Reads", "reads-2"])
    }

    /// Datasets with different names keep the folders they always had, and one dataset still writes the run folder.
    func testDatasetsWithDifferentNamesKeepTheirFolders() throws {
        let inputs = [try makeBundle("poolA", in: "a"), try makeBundle("poolB", in: "b"), try makeBundle("poolC", in: "a")]
        XCTAssertEqual(planFolders(demultiplex(inputs, mode: .groupedResult)), ["poolA", "poolB", "poolC"])
        let one = demultiplex([try makeBundle("reads", in: "e")], mode: .groupedResult)
        let plans = FASTQOperationPlanner().makeExecutionPlans(
            originalRequest: one, resolvedRequest: one, baseOutputDirectory: runFolder
        )
        XCTAssertEqual(plans.map(\.outputTarget.path), [runFolder.path])
    }

    // MARK: - The Operations row

    /// The row begins with a script of one command for each dataset, and each line names the folder its plan writes.
    func testTheLaunchCommandNamesTheFolderEachDatasetIsGiven() throws {
        let inputs = [try makeBundle("reads", in: "a"), try makeBundle("reads", in: "b")]
        let request = demultiplex(inputs, mode: .groupedResult)
        let reporter = RecordingOperationReporter()
        _ = try MainSplitViewController.beginFASTQLaunchRequestOperation(
            title: "FASTQ: \(request.operationDisplayTitle)",
            request: request,
            executionService: FASTQOperationExecutionService(),
            routeContext: nil,
            outputTargetPath: runFolder.path,
            reporter: reporter
        ) { _ in }.requireStarted()
        let script = try XCTUnwrap(reporter.items.first?.cliCommand)
        let commands = try RecordedCLICommand.parseScript(script).compactMap { $0 as? FastqDemultiplexSubcommand }
        XCTAssertEqual(commands.map(\.input), inputs.map(\.path), script)
        XCTAssertEqual(
            commands.map(\.output),
            [runFolder.appendingPathComponent("reads").path, runFolder.appendingPathComponent("reads-2").path],
            script
        )
    }
}
