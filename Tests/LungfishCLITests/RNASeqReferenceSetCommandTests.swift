// RNASeqReferenceSetCommandTests.swift - The `rnaseq` group and its leaf `reference-set` (Phase 5.1 lane RS-REFSET)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class RNASeqReferenceSetCommandTests: XCTestCase {
    static let base = [
        "rnaseq", "reference-set", "--genome", "/inputs/genome.fa.gz", "--annotation", "/inputs/genes.gtf.gz",
        "--storage-root", "/tmp/lge-root",
    ]

    func leaf(_ extra: [String]) throws -> RNASeqCommand.ReferenceSetSubcommand {
        let parsed = try LungfishCLI.parseAsRoot(Self.base + extra)
        return try XCTUnwrap(parsed as? RNASeqCommand.ReferenceSetSubcommand, "\(type(of: parsed))")
    }

    func testTheGroupRegistersTheLeafAndItsRequestNamesEveryInput() throws {
        let command = try leaf([
            "--species", "Macaca mulatta", "--assembly", "Mmul_10", "--annotation-source", "Ensembl",
            "--annotation-release", "100", "--extra", "virus,NC_045512.2,/inputs/virus.fa",
            "--extra", "spike-in,ERCC92,/inputs/ERCC92.fa", "--mitochondrial-contig", "MT",
        ])
        XCTAssertEqual(command.storageRoot, "/tmp/lge-root")
        let request = try command.makeRequest()
        XCTAssertEqual(request.genome.path, "/inputs/genome.fa.gz")
        XCTAssertEqual(request.annotation.path, "/inputs/genes.gtf.gz")
        XCTAssertEqual(request.species, "Macaca mulatta")
        XCTAssertEqual(request.extras.map(\.name), ["NC_045512.2", "ERCC92"], "extras keep the order given")
        XCTAssertEqual(request.extras.map(\.kind), [.virus, .spikeIn])
        XCTAssertEqual(request.mitochondrialContigs, ["MT"])
        XCTAssertEqual(request.layout, .lge, "LGE's layout is the default")
    }

    func testTheDepositLayoutNeedsItsStudyAndCarriesIt() throws {
        let named = ["--species", "Macaca mulatta", "--assembly", "Mmul_10", "--annotation-source", "Ensembl", "--annotation-release", "100"]
        XCTAssertThrowsError(try leaf(named + ["--layout", "deposit"]))
        let command = try leaf(named + ["--layout", "deposit", "--study", "GSE183579", "--extra", "virus,NC_045512.2,/v.fa,/v.gtf"])
        let request = try command.makeRequest()
        XCTAssertEqual(request.layout, .deposit(study: "GSE183579"))
        XCTAssertEqual(request.extras.first?.annotation?.path, "/v.gtf")
    }

    func testANamedDefaultFillsTheSetAndCarriesItsChecksums() throws {
        let request = try leaf(["--default", "rhesus/ensembl-100"]).makeRequest()
        XCTAssertEqual(request.species, "Macaca mulatta")
        XCTAssertEqual(request.assemblyName, "Mmul_10")
        XCTAssertEqual(request.annotationSource, "Ensembl")
        XCTAssertEqual(request.annotationRelease, "100")
        XCTAssertEqual(request.expected?.genomeSHA256, "679dd90651c50366858152b62989c26d587340711e60622458815d19b272fd3a")
        XCTAssertEqual(request.expected?.annotationSHA256, "73ba46e5b962e55d1307b0ceea8aedef33e1aed5b7e29840fc9da28d15e5c7a9")
        XCTAssertThrowsError(try leaf(["--default", "rhesus/ensembl-999"]).makeRequest()) { error in
            XCTAssertTrue("\(error)".contains("rhesus/ensembl-100"), "the refusal lists the named sets: \(error)")
        }
    }

    func testAnExtraOfAnUnknownKindIsRefused() throws {
        let named = ["--species", "S", "--assembly", "A", "--annotation-source", "X", "--annotation-release", "1"]
        XCTAssertThrowsError(try leaf(named + ["--extra", "plasmid,P1,/p.fa"]).makeRequest())
    }

    func testTheGroupIsCanonicalAndTheLeafTakesItsPolicy() {
        XCTAssertTrue(ScientificProvenancePolicy.canonicalCLICommandNames.contains("rnaseq"))
        XCTAssertEqual(ScientificProvenancePolicy.cliCommand(path: ["rnaseq", "reference-set"])?.id, "cli.rnaseq")
    }
}
