// BlastVerifySpeciesCladeTests.swift - `blast verify` judges a claim below a species at its species
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane BLAST-LINEAGE, BIO-BLAST-CLADE Q3. The CLI route builds its request from the same report-tree context as the
// app's Kraken 2 route (`BlastCommand.swift:185`, `ViewerViewController+Taxonomy.swift`). No test here touches the network.

import XCTest
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishTestSupport

final class BlastVerifySpeciesCladeTests: XCTestCase {
    func testTheCommandJudgesASubSpeciesClaimAtItsSpecies() async throws {
        let root = try TestTempDirectory.make(prefix: "blast-verify-species")
        defer { TestTempDirectory.cleanup(root) }
        let kreport = root.appendingPathComponent("classification.kreport")
        try """
          0.00\t0\t0\tU\t0\tunclassified
        100.00\t2\t0\tR\t1\troot
        100.00\t2\t0\tG\t10912\t  Rotavirus
        100.00\t2\t0\tS\t3432193\t    Rotavirus alphagastroenteritidis
        100.00\t2\t0\tS1\t28875\t      Rotavirus A
        100.00\t2\t2\tS2\t10941\t        Human rotavirus A

        """.write(to: kreport, atomically: true, encoding: .utf8)
        let kraken = root.appendingPathComponent("classification.kraken")
        try "C\ti1\t10941\t20|20\t0:16 |:| 10941:16\n".write(to: kraken, atomically: true, encoding: .utf8)
        let reads = root.appendingPathComponent("interleaved.fastq")
        let bases = String(repeating: "A", count: 20)
        let qualities = String(repeating: "I", count: 20)
        try "@i1/1\n\(bases)\n+\n\(qualities)\n@i1/2\n\(bases)\n+\n\(qualities)\n"
            .write(to: reads, atomically: true, encoding: .utf8)
        let command = try BlastCommand.VerifySubcommand.parse([
            "--kreport", kreport.path, "--kraken-output", kraken.path, "--source", reads.path, "--taxid", "10941",
        ])
        let readFiles = try await command.readSources(materializationDirectory: root.appendingPathComponent("scratch"))

        let request = try await command.verificationRequest(
            tree: try KreportParser.parse(url: kreport), readFiles: readFiles, service: BlastService()
        )

        XCTAssertEqual(request.acceptedTaxIds, [3432193, 28875, 10941], "the claim's parent and species are the same organism")
        XCTAssertEqual(request.relatedTaxIds, [10912], "only the genus stays a relative")
        XCTAssertEqual(request.taxId, 10941, "the claim stays the row's own taxon")
        XCTAssertEqual(request.sequences.map(\.id), ["i1"], "the sampled reads stay those of the claim")
    }
}
