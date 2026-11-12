// DemultiplexIDTUDKitRefusalRouteTests.swift - The kit id the CLI takes is refused before any read is assigned
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Trust session lane PROBES-A, row IDT-UD-SEQUENCES. `lungfish-cli fastq demultiplex --kit idt-ud-indexes` looks the
// kit up with `BarcodeKitRegistry.kit(byID:)`, then calls `preflight` and `run` (`FastqCommand.swift`,
// `FastqDemultiplexSubcommand.run`). LungfishWorkflowTests cannot import LungfishCLI, so this test drives the same two
// calls on the same configuration and shows that cutadapt never starts and nothing is written. The by-hand run of the
// built `lungfish-cli` is in the lane report.

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class DemultiplexIDTUDKitRefusalRouteTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "demux-idt-ud-refusal")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    private func makeManagedTool(root: URL, environment: String, executable: String, script: String) throws {
        let directory = root.appendingPathComponent(".lungfish/conda/envs/\(environment)/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(executable)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func assertRefusal(_ error: Error, kit: BarcodeKitDefinition, stage: String) throws {
        guard let refusal = error as? DemultiplexError, case .kitSequencesUnderCheck(let kitName) = refusal else {
            return XCTFail("\(stage) threw \(error) and not kitSequencesUnderCheck")
        }
        XCTAssertEqual(kitName, kit.displayName, "\(stage) names the kit")
        let words = refusal.errorDescription ?? ""
        XCTAssertTrue(words.contains("IDT for Illumina UD Indexes (96 pairs)"), "\(stage) names the kit in its words, got: \(words)")
        XCTAssertTrue(words.contains("Custom Definition"), "\(stage) gives the way out, got: \(words)")
        XCTAssertTrue(words.contains("--kit"), "\(stage) gives the way out on the command line too, got: \(words)")
    }

    /// The words for a definition that holds the table's own pairs (BIO-PROBES-A Q1 fix item c).
    private func assertDefinitionRefusal(_ error: Error, stage: String) {
        let words = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        XCTAssertTrue(words.contains("This definition holds"), "\(stage) says what the file holds, got: \(words)")
        XCTAssertTrue(words.contains("IDT for Illumina UD Indexes (96 pairs)"), "\(stage) names the kit, got: \(words)")
        XCTAssertTrue(words.contains("nothing was run"), "\(stage) says nothing was run, got: \(words)")
        XCTAssertTrue(words.contains("Custom Definition") && words.contains("--kit"), "\(stage) gives the way out, got: \(words)")
    }

    func testTheCLIKitIdIsRefusedWithWordsBeforeCutadaptStartsAndBeforeAnythingIsWritten() async throws {
        let kitID = "idt-ud-indexes"
        // The CLI lists every built-in id in --kit and resolves the argument with BarcodeKitRegistry.kit(byID:).
        XCTAssertTrue(BarcodeKitRegistry.builtinKits().map(\.id).contains(kitID), "--kit offers the id")
        let kit = try XCTUnwrap(BarcodeKitRegistry.kit(byID: kitID), "--kit resolves the id to the kit")

        let runnerRoot = root.appendingPathComponent("managed-tools", isDirectory: true)
        let marker = root.appendingPathComponent("cutadapt-was-called")
        try makeManagedTool(root: runnerRoot, environment: "cutadapt", executable: "cutadapt", script: """
            #!/bin/sh
            : > '\(marker.path)'
            exit 9
            """)
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let input = project.appendingPathComponent("reads.fastq")
        // Three reads that start with the first pair of the table (A01, i7 GAACATAC) and end with its i5 read back.
        let insert = "ACGTTGCAGGATCCATTGACCGTAGGCTAAGCTTGCATGCAAGTCCGGTTAACCGGT"
        let read = "GAACATAC" + insert + "CTACAGTT"
        try (1...3).map { "@r\($0)\n\(read)\n+\n\(String(repeating: "I", count: read.count))\n" }.joined()
            .write(to: input, atomically: true, encoding: .utf8)
        let output = project.appendingPathComponent("demux-out", isDirectory: true)
        // The configuration FastqDemultiplexSubcommand builds from its defaults.
        let config = DemultiplexConfig(
            inputURL: input,
            barcodeKit: kit,
            outputDirectory: output,
            barcodeLocation: .bothEnds,
            errorRate: 0.15,
            minimumOverlap: 3,
            trimBarcodes: true,
            threads: 4
        )
        let pipeline = DemultiplexingPipeline(
            runner: NativeToolRunner(toolsDirectory: nil, homeDirectory: runnerRoot, appIdentity: .preview)
        )

        do {
            try await pipeline.preflight(config: config)
            XCTFail("the preflight must refuse the kit")
        } catch {
            try assertRefusal(error, kit: kit, stage: "preflight")
        }
        do {
            _ = try await pipeline.run(config: config, progress: { _, _ in })
            XCTFail("the run must refuse the kit")
        } catch {
            try assertRefusal(error, kit: kit, stage: "run")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "cutadapt never started, so no read was assigned")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "the refusal came before the run made its output folder")
    }

    // MARK: - The routes the id refusal did not reach (FIX-IDT, BIO-PROBES-A Q1)

    /// A definition as the Demux tab's Demultiplex button wrote it in builds 2026.11.3 to 2026.11.7, with two pairs of the table.
    private static let planLikeText = """
        # kit: idt-ud-indexes
        id,sequence,secondary_sequence,sample_name
        S1,GAACATAC,AACTGTAG,S1
        S9,GCTACTCT,AACTGTAG,S9
        """

    /// The same layout typed from an index sheet, with pairs that are in no row of the table.
    private static let typedText = """
        # kit: idt-ud-indexes
        id,sequence,secondary_sequence,sample_name
        S1,CCGCGGTT,AGCGCTAG,S1
        S2,TTATAACC,GATATCGA,S2
        """

    private func makeProject(reads: String) throws -> (input: URL, output: URL) {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let input = project.appendingPathComponent("reads.fastq")
        try reads.write(to: input, atomically: true, encoding: .utf8)
        return (input, project.appendingPathComponent("demux-out", isDirectory: true))
    }

    private func config(_ input: URL, _ output: URL, kit: BarcodeKitDefinition) -> DemultiplexConfig {
        DemultiplexConfig(
            inputURL: input, barcodeKit: kit, outputDirectory: output, barcodeLocation: .bothEnds,
            errorRate: 0.15, minimumOverlap: 3, trimBarcodes: true, threads: 4
        )
    }

    /// Reads of the table's first pair, whose names carry no index.
    private var tablePairReads: String {
        let read = "GAACATAC" + "ACGTTGCAGGATCCATTGACCGTAGGCTAAGCTTGCATGCAAGTCCGGTTAACCGGT" + "CTACAGTT"
        return (1...3).map { "@r\($0)\n\(read)\n+\n\(String(repeating: "I", count: read.count))\n" }.joined()
    }

    func testDetectRefusesTheKitIdWithTheRunsWordsBeforeItReadsAnyRead() async throws {
        let kit = try XCTUnwrap(BarcodeKitRegistry.kit(byID: "idt-ud-indexes"))
        let (input, _) = try makeProject(reads: tablePairReads)
        do {
            _ = try await DemultiplexingPipeline().scout(inputURL: input, kit: kit, progress: { _, _ in })
            XCTFail("Detect must refuse the kit")
        } catch {
            try assertRefusal(error, kit: kit, stage: "scout")
        }
    }

    func testAPlanFileHoldingTheTablePairsIsRefusedByPreflightAndRunBeforeAnythingIsWritten() async throws {
        let kit = try BarcodeKitRegistry.loadCustomKit(text: Self.planLikeText, name: "reads demux plan 0123456789ab")
        XCTAssertEqual(kit.sourceKitID, "idt-ud-indexes", "the file keeps the IDT line")
        let (input, output) = try makeProject(reads: tablePairReads)
        let marker = root.appendingPathComponent("cutadapt-was-called")
        let runnerRoot = root.appendingPathComponent("managed-tools", isDirectory: true)
        try makeManagedTool(root: runnerRoot, environment: "cutadapt", executable: "cutadapt", script: "#!/bin/sh\n: > '\(marker.path)'\nexit 9\n")
        let pipeline = DemultiplexingPipeline(
            runner: NativeToolRunner(toolsDirectory: nil, homeDirectory: runnerRoot, appIdentity: .preview)
        )
        do {
            try await pipeline.preflight(config: config(input, output, kit: kit))
            XCTFail("the preflight must refuse a definition that holds the table's pairs")
        } catch {
            assertDefinitionRefusal(error, stage: "preflight")
        }
        do {
            _ = try await pipeline.run(config: config(input, output, kit: kit), progress: { _, _ in })
            XCTFail("the run must refuse a definition that holds the table's pairs")
        } catch {
            assertDefinitionRefusal(error, stage: "run")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "cutadapt never started, so no read was assigned")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "the refusal came before the run made its output folder")
    }

    func testDetectRefusesAPlanFileHoldingTheTablePairs() async throws {
        let kit = try BarcodeKitRegistry.loadCustomKit(text: Self.planLikeText, name: "reads demux plan 0123456789ab")
        let (input, _) = try makeProject(reads: tablePairReads)
        do {
            _ = try await DemultiplexingPipeline().scout(inputURL: input, kit: kit, progress: { _, _ in })
            XCTFail("Detect must refuse a definition that holds the table's pairs")
        } catch {
            assertDefinitionRefusal(error, stage: "scout")
        }
    }

    /// The way out the words offer. A typed definition keeps its `# kit:` line, passes the check, and the route probe
    /// counts its own rows in the read names and not the table's.
    func testATypedIDTDefinitionPassesAndItsRouteProbeReadsItsOwnRows() async throws {
        let kit = try BarcodeKitRegistry.loadCustomKit(text: Self.typedText, name: "typed idt sheet")
        XCTAssertEqual(
            DemultiplexSearchRouteOwner.probeKit(kit).barcodes.map(\.i7Sequence), ["CCGCGGTT", "TTATAACC"],
            "the probe counts the definition's rows and not the table of the IDT kit"
        )
        let names = Array(repeating: "CCGCGGTT+AGCGCTAG", count: 60) + Array(repeating: "TTATAACC+GATATCGA", count: 60)
        let reads = names.enumerated().map { "@r\($0.offset) 1:N:0:\($0.element)\nGATTACAGATTACAGATTACA\n+\nIIIIIIIIIIIIIIIIIIIII\n" }.joined()
        let (input, output) = try makeProject(reads: reads)
        let route = try await DemultiplexingPipeline().preflight(config: config(input, output, kit: kit))
        XCTAssertTrue(route.isHeaderIndex, "the names carry both typed barcodes, so the run splits by them")
    }
}
