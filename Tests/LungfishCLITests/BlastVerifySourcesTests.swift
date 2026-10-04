// BlastVerifySourcesTests.swift - blast verify reads every --source, a bundle by the roles of its files
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 1.5 lane A3, defect D8. `lungfish-cli blast verify` read one source
// file. Its --source now repeats and takes a .lungfishfastq bundle, which it
// resolves through KrakenResultReadSources, as the app resolves a result's
// recorded inputs. No test here touches the network.

import XCTest
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

final class BlastVerifySourcesTests: XCTestCase {
    private var root: URL!

    private let mate1 = String(repeating: "A", count: 20)
    private let mate2 = String(repeating: "C", count: 20)
    private let merged = String(repeating: "AC", count: 15)

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "blast-verify-sources")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testSourceRepeats() throws {
        let command = try BlastCommand.VerifySubcommand.parse([
            "--kreport", "/tmp/classification.kreport",
            "--kraken-output", "/tmp/classification.kraken",
            "--source", "/tmp/sample_R1.fastq",
            "--source", "/tmp/sample_R2.fastq",
            "--source", "/tmp/merged.fastq",
            "--taxid", "100",
        ])
        XCTAssertEqual(command.sourcePaths, ["/tmp/sample_R1.fastq", "/tmp/sample_R2.fastq", "/tmp/merged.fastq"])
    }

    /// A merge derivative holds the pair u1, whose taxon k-mers sit on mate
    /// 2, and the merged read x1. Its mates share one name, so only the file
    /// says which is mate 2.
    func testABundleSourceIsReadByTheRolesOfItsFiles() async throws {
        let bundle = try ReadSetFixtures(in: root).mergeDerivative
        try fastq([("u1", mate1)]).write(to: bundle.appendingPathComponent("unmerged_R1.fastq"), atomically: true, encoding: .utf8)
        try fastq([("u1", mate2)]).write(to: bundle.appendingPathComponent("unmerged_R2.fastq"), atomically: true, encoding: .utf8)
        try fastq([("x1", merged), ("x2", mate1), ("x3", mate1)])
            .write(to: bundle.appendingPathComponent("merged.fastq"), atomically: true, encoding: .utf8)
        let (kreport, kraken) = try writeResult([
            "C\tu1\t100\t20|20\t0:16 |:| 100:16",
            "C\tx1\t100\t30|0\t100:26 |:| ",
            "C\tx2\t200\t30|0\t200:26 |:| ",
            "C\tx3\t200\t30|0\t200:26 |:| ",
        ])
        let command = try BlastCommand.VerifySubcommand.parse([
            "--kreport", kreport.path, "--kraken-output", kraken.path,
            "--source", bundle.path, "--taxid", "100", "--include-children",
        ])

        let readFiles = try await command.readSources(materializationDirectory: root.appendingPathComponent("scratch"))
        XCTAssertEqual(readFiles.files.map(\.url.lastPathComponent), ["unmerged_R1.fastq", "unmerged_R2.fastq", "merged.fastq"])
        let request = try await command.verificationRequest(
            tree: try KreportParser.parse(url: kreport), readFiles: readFiles, service: BlastService()
        )

        XCTAssertEqual(request.sequences.count, 2)
        XCTAssertEqual(sequence(of: "u1", in: request), mate2, "u1 is sent from the R2 file")
        XCTAssertEqual(request.sequenceMates["u1"], 2)
        XCTAssertEqual(sequence(of: "x1", in: request), merged, "x1 is read from the merged file")
    }

    /// One loose file, the form every command recorded before, builds the
    /// request the one-file form of BlastService builds.
    func testOneLooseFileIsReadAsBefore() async throws {
        let file = root.appendingPathComponent("interleaved.fastq")
        try fastq([("i1/1", mate1), ("i1/2", mate2), ("i2/1", mate2), ("i2/2", mate1)])
            .write(to: file, atomically: true, encoding: .utf8)
        let (kreport, kraken) = try writeResult([
            "C\ti1\t100\t20|20\t0:16 |:| 100:16",
            "C\ti2\t100\t20|20\t100:16 |:| 0:16",
        ])
        let command = try BlastCommand.VerifySubcommand.parse([
            "--kreport", kreport.path, "--kraken-output", kraken.path,
            "--source", file.path, "--taxid", "100",
        ])

        let readFiles = try await command.readSources(materializationDirectory: root.appendingPathComponent("scratch"))
        XCTAssertEqual(readFiles.blastReadSources, [BlastReadSource(url: file.standardizedFileURL)])
        let viaCommand = try await command.verificationRequest(
            tree: try KreportParser.parse(url: kreport), readFiles: readFiles, service: BlastService()
        )
        let oneFile = try await BlastService().buildVerificationRequest(
            taxonName: "Target virus",
            taxId: 100,
            targetTaxIds: [100],
            classificationOutputURL: kraken,
            sourceURL: file,
            readCount: 20,
            acceptedTaxonNames: ["Target virus"]
        )

        XCTAssertEqual(viaCommand.sequences.map(\.id), oneFile.sequences.map(\.id))
        XCTAssertEqual(viaCommand.sequences.map(\.sequence), oneFile.sequences.map(\.sequence))
        XCTAssertEqual(viaCommand.sequenceMates, oneFile.sequenceMates)
        XCTAssertEqual(viaCommand.sequenceMates, ["i1": 2, "i2": 1])
    }

    // MARK: - Helpers

    private func writeResult(_ lines: [String]) throws -> (kreport: URL, kraken: URL) {
        let kreport = root.appendingPathComponent("classification.kreport")
        try """
         0.00\t0\t0\tU\t0\tunclassified
        100.00\t4\t0\tR\t1\troot
         50.00\t2\t2\tS\t100\t  Target virus
         50.00\t2\t2\tS\t200\t  Other virus

        """.write(to: kreport, atomically: true, encoding: .utf8)
        let kraken = root.appendingPathComponent("classification.kraken")
        try (lines.joined(separator: "\n") + "\n").write(to: kraken, atomically: true, encoding: .utf8)
        return (kreport, kraken)
    }

    private func fastq(_ records: [(name: String, sequence: String)]) -> String {
        records.map { "@\($0.name)\n\($0.sequence)\n+\n\(String(repeating: "I", count: $0.sequence.count))\n" }.joined()
    }

    private func sequence(of id: String, in request: BlastVerificationRequest) -> String? {
        request.sequences.first { $0.id == id }?.sequence
    }
}
