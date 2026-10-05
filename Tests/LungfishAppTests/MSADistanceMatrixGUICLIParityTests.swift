// MSADistanceMatrixGUICLIParityTests.swift - The Distances pane shows exactly what lungfish-cli msa distance writes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishAlignmentUI
import LungfishIO
import LungfishKit
import LungfishTestSupport

/// Owner requirement: for every valid model, gap policy and order, the matrix
/// the pane computes is byte-identical to the TSV the CLI writes when it runs
/// with the arguments the GUI export records.
@MainActor
final class MSADistanceMatrixGUICLIParityTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "lungfish-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = nil
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    private func bundle(_ fasta: String, name: String) throws -> URL {
        let source = temporaryDirectory.appendingPathComponent("\(name).fa")
        try fasta.write(to: source, atomically: true, encoding: .utf8)
        let bundleURL = temporaryDirectory.appendingPathComponent("\(name).lungfishmsa")
        _ = try MultipleSequenceAlignmentBundle.importAlignment(from: source, to: bundleURL)
        return bundleURL
    }

    private func controller(_ bundleURL: URL) async throws -> MultipleSequenceAlignmentViewController {
        let controller = MultipleSequenceAlignmentViewController()
        controller.gutterWidthDefaults = defaults
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 700)
        try await controller.displayBundle(at: bundleURL)
        controller.showDistanceMatrix()
        return controller
    }

    /// Runs `msa distance` in process with the exact argv the GUI export builds.
    private func cliTSV(bundleURL: URL, options: MSADistanceOptions, tag: String) throws -> String {
        let outputURL = temporaryDirectory.appendingPathComponent("\(tag).tsv")
        let arguments = MSADistanceMatrixExportCoordinator.arguments(
            bundleURL: bundleURL,
            options: options,
            outputURL: outputURL
        )
        XCTAssertEqual(Array(arguments.prefix(2)), ["msa", "distance"])
        try MSACommand.DistanceSubcommand.parse(Array(arguments.dropFirst(2))).executeForTesting { _ in }
        return try String(contentsOf: outputURL, encoding: .utf8)
    }

    private func assertParity(
        bundleURL: URL,
        alphabet: MSASequenceAlphabet,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let controller = try await controller(bundleURL)
        let model = controller.bottomPane.distancePane.model
        XCTAssertEqual(model.alphabet, alphabet, file: file, line: line)
        var combinations = 0
        for distanceModel in MSADistanceModel.models(for: alphabet) {
            for gaps in MSAGapPolicy.allCases {
                for order in MSADistanceOrder.allCases {
                    model.model = distanceModel
                    model.gaps = gaps
                    model.order = order
                    let wanted = MSADistanceOptions(model: distanceModel, gaps: gaps, order: order, alphabet: alphabet)
                    await LungfishTestSupport.waitUntil(timeout: .seconds(20)) { model.status == .ready && model.matrix?.options == wanted }
                    XCTAssertEqual(model.status, .ready, "status for \(wanted)", file: file, line: line)
                    let gui = try XCTUnwrap(controller.bottomPane.distancePane.matrixTSV, "\(wanted)", file: file, line: line)
                    let tag = "\(distanceModel.rawValue)-\(gaps.rawValue)-\(order.rawValue)"
                    let cli = try cliTSV(bundleURL: bundleURL, options: model.options, tag: tag)
                    XCTAssertEqual(gui, cli, "GUI and CLI differ for \(tag)", file: file, line: line)
                    combinations += 1
                }
            }
        }
        XCTAssertEqual(
            combinations,
            MSADistanceModel.models(for: alphabet).count * MSAGapPolicy.allCases.count * MSADistanceOrder.allCases.count,
            file: file,
            line: line
        )
    }

    /// The export the pane, View > Distance Matrix and File > Export share
    /// records a command that parses back to the on-screen options.
    func testExportCoordinatorRunRecordsAParsableCommandWithTheOnScreenOptions() async throws {
        let bundleURL = try bundle(">a\nACGT\n>b\nACGA\n", name: "export")
        let outputURL = temporaryDirectory.appendingPathComponent("export-k2p.tsv")
        let options = MSADistanceOptions(model: .k2p, gaps: .complete, order: .averageLinkage, alphabet: .nucleotide)
        XCTAssertEqual(
            MSADistanceMatrixExportCoordinator.suggestedFileName(bundleURL: bundleURL, options: options),
            "export-k2p.tsv"
        )
        let operationID = try XCTUnwrap(MSADistanceMatrixExportCoordinator.run(
            bundleURL: bundleURL,
            options: options,
            outputURL: outputURL,
            windowStateScope: nil,
            runner: CLIMSAActionRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true"))
        ))
        let row = try XCTUnwrap(OperationCenter.shared.items.first { $0.id == operationID })
        let command = try XCTUnwrap(row.cliCommand)
        let parsed = try RecordedCLICommand.parse(command, as: MSACommand.DistanceSubcommand.self)
        XCTAssertEqual(parsed.bundlePath, bundleURL.path)
        XCTAssertEqual(parsed.model, "k2p")
        XCTAssertEqual(parsed.gaps, "complete")
        XCTAssertEqual(parsed.order, "average-linkage")
        XCTAssertEqual(parsed.outputPath, outputURL.path)
        // The stand-in CLI reports no output, so the row ends as failed. Wait
        // for that before the next test so no runner outlives this one.
        await LungfishTestSupport.waitUntil(timeout: .seconds(20)) { OperationCenter.shared.items.first { $0.id == operationID }?.finishedAt != nil }
    }

    func testNucleotidePaneMatchesCLIForEveryModelGapPolicyAndOrder() async throws {
        let bundleURL = try bundle(
            """
            >dup
            ACGTACGTACGTAC-TACGT
            >dup
            ACGTTCGNACGTAC-TACGA
            >gappy
            ACG-ACGTTCGTACCTAC--
            >far
            TCGTACGAACGAACCTTCGT
            >ambiguous
            ACGTRCGTACNNACCTACGT

            """,
            name: "nucleotide"
        )
        try await assertParity(bundleURL: bundleURL, alphabet: .nucleotide)
    }

    func testProteinPaneMatchesCLIWithPoisson() async throws {
        let bundleURL = try bundle(
            """
            >p1
            MKVLEWQRSTAE-LK
            >p2
            MKILEWQRSXAE-LK
            >p3
            MRVLDWQKSTAEGLK
            >p4
            MKVLEW--STVEGIK

            """,
            name: "protein"
        )
        try await assertParity(bundleURL: bundleURL, alphabet: .protein)
    }
}
