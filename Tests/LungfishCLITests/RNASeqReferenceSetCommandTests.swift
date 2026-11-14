// RNASeqReferenceSetCommandTests.swift - The `rnaseq` group and its leaf `reference-set` (Phase 5.1 lane RS-REFSET)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishTestSupport
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

    /// `--storage-root` also names where gffread is found, as `tools --storage-root` does, so a set built under a
    /// root never takes gffread, or the version in its id, from the configured root. The root holds a stand-in
    /// gffread that prints 0.12.9 and writes one record a transcript id of the exon lines, and notes each run.
    func testTheStorageRootNamesWhereGffreadIsFound() async throws {
        let base = try TestTempDirectory.make(prefix: "refset-cli-root")
        let savedStorageRoot = ProcessInfo.processInfo.environment["LUNGFISH_STORAGE_ROOT"]
        await NativeToolRunner.shared.clearCache()
        defer {
            if let savedStorageRoot { setenv("LUNGFISH_STORAGE_ROOT", savedStorageRoot, 1) } else { unsetenv("LUNGFISH_STORAGE_ROOT") }
            TestTempDirectory.cleanup(base)
        }
        let root = base.appendingPathComponent("root", isDirectory: true)
        let bin = root.appendingPathComponent("conda/envs/gffread/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let marker = base.appendingPathComponent("gffread-runs.txt")
        let script = """
            #!/bin/sh
            if [ "$1" = "--version" ]; then echo 0.12.9; exit 0; fi
            echo "$5" >> '\(marker.path)'
            awk -F '\\t' '$3 == "exon" && match($9, /transcript_id "[^"]+"/) { id = substr($9, RSTART + 15, RLENGTH - 16); if (!(id in seen)) { seen[id] = 1; printf(">%s\\nACGT\\n", id) } }' "$5" > "$2"

            """
        let gffread = bin.appendingPathComponent("gffread")
        try Data(script.utf8).write(to: gffread)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gffread.path)
        let genome = base.appendingPathComponent("genome.fa")
        try Data(">chr1\n\(String(repeating: "ACGTACGTAC", count: 4))\n".utf8).write(to: genome)
        let annotation = base.appendingPathComponent("genes.gtf")
        try Data("chr1\tt\texon\t1\t20\t.\t+\t.\tgene_id \"G1\"; transcript_id \"T1\";\n".utf8).write(to: annotation)

        let parsed = try LungfishCLI.parseAsRoot([
            "rnaseq", "reference-set", "--genome", genome.path, "--annotation", annotation.path, "--species", "S",
            "--assembly", "A", "--annotation-source", "X", "--annotation-release", "1", "--storage-root", root.path, "--quiet",
        ])
        let command = try XCTUnwrap(parsed as? RNASeqCommand.ReferenceSetSubcommand)
        do {
            try await command.run()
        } catch {
            XCTFail("the build under --storage-root failed: \(error)")
        }
        await NativeToolRunner.shared.clearCache()
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "gffread must come from the --storage-root, not the configured root")
        let sets = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("rnaseq-reference-sets").path)) ?? []
        XCTAssertEqual(sets.filter { $0.hasSuffix(".lungfishrefset") }.count, 1, "\(sets)")
    }
}
