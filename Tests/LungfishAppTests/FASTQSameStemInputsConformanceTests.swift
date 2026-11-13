// FASTQSameStemInputsConformanceTests.swift - Two datasets with the same name never lose one's reads with no words
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Trust session lane STEM-FOLDERS (PROBE-STEM, review FIX-GROUP-BIO section 6 item 3). Two datasets with one name,
// `a/reads.lungfishfastq` and `b/reads.lungfishfastq`, are each given a folder under the run (`reads`, `reads-2`,
// `FASTQOperationPlanner+InputFolders.swift`). This runs the dialog's request through `FASTQOperationExecutionService`
// and the built `lungfish-cli` with the real tools, as the window does, in both Output Strategies, and holds that the
// run completes with both reads in the result, in different bundles. `FASTQSameStemInputsTests` is its stand-in, which
// needs no tool.
//
// It skips when cutadapt, seqkit or the built CLI is missing, and fails then under LUNGFISH_REQUIRE_TOOLS=1.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

final class FASTQSameStemInputsConformanceTests: XCTestCase {
    private var root: URL!
    private var cli: URL!

    override func setUpWithError() throws {
        guard let built = CLISIGTERMHarness.cliBinaryURL(for: Self.self) else {
            try ToolAvailability.skipOrFail("no lungfish-cli is built beside the test bundle")
        }
        cli = built
        // The projects live in a folder whose path has one spelling. Under the temporary folder the importer lists an
        // rRNA result as `/private/var/...` while its sidecar reads back as `/var/...`, and the plain-text match refuses
        // it (row RIBO-OUTPUT-PATH-SPELLING), whichever of the two spellings the test gives.
        let caches = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        root = caches.appendingPathComponent("lungfish-tests/same-stem-inputs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let root { TestTempDirectory.cleanup(root) }
    }

    private static let (s1, s1RC) = ("GTATCGTCGT", "ACGACGATAC")

    /// A bundle `<folder>/reads.lungfishfastq` in `project` of one 60-base read named `<folder>-read`: S1 at the 5' end,
    /// random bases from `seed`, S1's reverse complement at the 3' end.
    private func makePool(in folder: String, seed: UInt64, project: URL) throws -> URL {
        var state = seed
        var read = Self.s1
        while read.count < 60 - Self.s1RC.count {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            read += ["A", "C", "G", "T"][Int((state >> 33) % 4)]
        }
        read += Self.s1RC
        let bundle = project.appendingPathComponent("\(folder)/reads.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let text = "@\(folder)-read\n\(read)\n+\n\(String(repeating: "I", count: 60))\n"
        try text.write(to: bundle.appendingPathComponent("reads.fastq"), atomically: true, encoding: .utf8)
        return bundle
    }

    /// The bundles under `folder` that hold each read id, by path relative to `folder`. Hidden folders are skipped.
    /// A `.fastq.gz` result (demultiplex, length filter) is read through `GzipInputStream`.
    private func readHolders(under folder: URL) -> [String: [String]] {
        var holders: [String: [String]] = [:]
        guard let walk = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return holders }
        for case let file as URL in walk {
            let name = file.lastPathComponent.lowercased()
            let text: String?
            if name.hasSuffix(".fastq") {
                text = try? String(contentsOf: file, encoding: .utf8)
            } else if name.hasSuffix(".fastq.gz") {
                text = try? GzipInputStream(url: file).readAllSync()
            } else {
                continue
            }
            guard let text else { continue }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let place = String(file.deletingLastPathComponent().path.dropFirst(folder.path.count + 1))
            for index in stride(from: 0, to: lines.count, by: 4) where lines[index].hasPrefix("@") {
                let id = String(lines[index].dropFirst().split(separator: " ").first ?? "")
                holders[id, default: []].append(place)
            }
        }
        return holders
    }

    private func sheet(in project: URL) throws -> URL {
        let sheet = project.appendingPathComponent("sheet.csv")
        try "id,sequence\nS1,\(Self.s1)\n".write(to: sheet, atomically: true, encoding: .utf8)
        return sheet
    }

    private func demultiplex(_ pools: [URL], sheet: URL, mode: FASTQOperationOutputMode) -> FASTQOperationLaunchRequest {
        .derivative(
            request: .demultiplex(
                kitID: "sheet", customCSVPath: sheet.path, location: "bothends", symmetryMode: nil,
                maxDistanceFrom5Prime: 0, maxDistanceFrom3Prime: 0, errorRate: 0.15, engine: .cutadapt,
                trimBarcodes: true, sampleAssignments: nil, kitOverride: nil
            ),
            inputURLs: pools, outputMode: mode
        )
    }

    /// Runs `request` on `a/reads` and `b/reads` as the window does (a demultiplex or a grouped run writes into a new
    /// run folder in Analyses, a per-input run into Analyses) and holds the rule: both reads are in the result and
    /// share no bundle, or the run fails with words and leaves no read in Analyses.
    private func assertNoSilentLoss(
        _ makeRequest: ([URL], URL) -> FASTQOperationLaunchRequest, label: String, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let project = root.appendingPathComponent("\(label).lungfish", isDirectory: true)
        let analyses = project.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
        let pools = [try makePool(in: "a", seed: 7, project: project), try makePool(in: "b", seed: 8, project: project)]
        let request = makeRequest(pools, try sheet(in: project))
        let runsInOwnFolder = request.outputMode == .groupedResult || request.isDemultiplexRequest
        let working = runsInOwnFolder ? analyses.appendingPathComponent("run", isDirectory: true) : analyses
        let cli = try XCTUnwrap(cli)
        let service = FASTQOperationExecutionService(
            commandRunner: LungfishCLIProcessRunner(cliURLProvider: { cli }),
            directImporter: BundleFASTQOperationImporter(destinationDirectory: analyses)
        )
        var failure: Error?
        var result: FASTQOperationExecutionResult?
        do { result = try await service.execute(request: request, workingDirectory: working) } catch { failure = error }

        let holders = readHolders(under: analyses)
        let words = failure.map { $0.localizedDescription } ?? "none"
        print("SAME-STEM \(label) completed=\(result != nil) commands=\(result?.executedInvocations.count ?? -1) "
              + "reads=\(holders.sorted { $0.key < $1.key }) error=\(words)")
        XCTAssertNil(failure, "\(label): two datasets with one name complete, error: \(words)", file: file, line: line)
        if failure != nil {
            XCTAssertFalse(words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(label): a failed run says why", file: file, line: line)
            XCTAssertEqual(holders, [:], "\(label): a failed run leaves no read that looks like a result", file: file, line: line)
        } else {
            let (first, second) = (holders["a-read"] ?? [], holders["b-read"] ?? [])
            XCTAssertFalse(first.isEmpty, "\(label): the first dataset's read is in the result: \(holders)", file: file, line: line)
            XCTAssertFalse(second.isEmpty, "\(label): the second dataset's read is in the result: \(holders)", file: file, line: line)
            XCTAssertTrue(Set(first).isDisjoint(with: second), "\(label): the datasets share a bundle: \(holders)", file: file, line: line)
        }
    }

    func testAPerInputDemultiplexOfTwoDatasetsWithOneNameLosesNoReadWithNoWords() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.cutadapt) else {
            try ToolAvailability.skipOrFail("managed cutadapt is not installed")
        }
        try await assertNoSilentLoss({ pools, sheet in self.demultiplex(pools, sheet: sheet, mode: .perInput) }, label: "demux-per-input")
    }

    func testAGroupedDemultiplexOfTwoDatasetsWithOneNameLosesNoReadWithNoWords() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.cutadapt) else {
            try ToolAvailability.skipOrFail("managed cutadapt is not installed")
        }
        try await assertNoSilentLoss({ pools, sheet in self.demultiplex(pools, sheet: sheet, mode: .groupedResult) }, label: "demux-grouped")
    }

    func testAPerInputLengthFilterOfTwoDatasetsWithOneNameLosesNoReadWithNoWords() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.seqkit) else {
            try ToolAvailability.skipOrFail("managed seqkit is not installed")
        }
        try await assertNoSilentLoss({ pools, _ in
            .derivative(request: .lengthFilter(min: 1, max: nil), inputURLs: pools, outputMode: .perInput)
        }, label: "length-per-input")
    }

    func testAGroupedLengthFilterOfTwoDatasetsWithOneNameLosesNoReadWithNoWords() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.seqkit) else {
            try ToolAvailability.skipOrFail("managed seqkit is not installed")
        }
        try await assertNoSilentLoss({ pools, _ in
            .derivative(request: .lengthFilter(min: 1, max: nil), inputURLs: pools, outputMode: .groupedResult)
        }, label: "length-grouped")
    }

    /// Remove Ribosomal RNA is Per Input only (`FASTQOperationToolID.supportsConfigurableOutput`), writes a folder, and
    /// `lungfish-cli fastq deacon-ribo` names its file after the dataset and writes into a folder that holds files.
    func testARibosomalRNAFilterOfTwoDatasetsWithOneNameLosesNoReadWithNoWords() async throws {
        _ = try await ToolAvailability.require("deacon", environment: "deacon")
        let databaseID = DeaconRibokmersDatabaseInstaller.databaseID
        _ = try await ToolAvailability.requireDatabase(
            { try? await DatabaseRegistry.shared.requiredDatabasePath(for: databaseID) },
            name: databaseID
        )
        try await assertNoSilentLoss({ pools, _ in
            .derivative(request: .ribosomalRNAFilter(retention: .nonRRNA, ensure: .none), inputURLs: pools, outputMode: .perInput)
        }, label: "ribo-per-input")
    }
}
