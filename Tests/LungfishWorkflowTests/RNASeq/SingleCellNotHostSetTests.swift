// SingleCellNotHostSetTests.swift - The import reads the set's not-host records as `rnaseq reference-set` wrote them (Phase 5.2 lane RS-NOTHOST)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `rnaseq reference-set` keeps each extra's FASTA as given, so GSE183579's set holds `extras/NC_045512.2.fa.gz`
// (`work/gse183579/lge/RS-REFSET/gse183579-deposit/reference-set.json`). The pass takes each record's length from that
// file to check a BAM's header, so it reads a gzip FASTA and a plain one alike.

import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

final class SingleCellNotHostSetTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "nothost-set") }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    /// gzip of `>NC_045512.2 Severe acute respiratory syndrome coronavirus 2\nACGTACGTAC\nGTA\n`, 13 bases on two lines.
    static let gzipFASTA = "H4sIAAAAAAAC/7Pzc443MDE1NTTSM1IITi1LLUpVSEwuLUlVKEotLsgsSizJL6pUKK7MSynKz01VSM4vys9LLMssKi1WMOJydHYPgWAuIMEFAHRtV4ZMAAAA"

    /// A set folder of one virus extra at `extraPath`, with a genes table of one host gene and the virus's two genes.
    static func writeSet(at folder: URL, extraPath: String, extraBytes: Data) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder.appendingPathComponent("extras"), withIntermediateDirectories: true)
        try fm.createDirectory(at: folder.appendingPathComponent("derived"), withIntermediateDirectories: true)
        try extraBytes.write(to: folder.appendingPathComponent(extraPath))
        let genes = "gene_id\tname\tbiotype\tcontig\tlength\tnot_host\tmask\tunreliable\n"
            + "ENSMMUG1\tACTB\tprotein_coding\t1\t1800\tfalse\n"
            + "gene-GU280_gp01\tORF1ab\tprotein_coding\tNC_045512.2\t21290\ttrue\n"
            + "gene-GU280_gp10\tN\tprotein_coding\tNC_045512.2\t1260\ttrue\n"
        try Data(genes.utf8).write(to: folder.appendingPathComponent("derived/genes.tsv"))
        let file = { (path: String) in "{\"path\": \"\(path)\", \"sha256\": \"\(String(repeating: "0", count: 64))\", \"size\": 1, \"tool\": \"lungfish\", \"version\": \"test\"}" }
        let manifest = """
            {"schemaVersion": 1, "id": "test-set", "name": "Test set", "species": "Macaca mulatta",
             "assembly": {"name": "Mmul_10"}, "annotation": {"source": "Ensembl", "release": "100", "path": "annotation/a.gtf.gz", "sha256": "0"},
             "genome": {"path": "genome/g.fa.gz", "sha256": "0"},
             "extras": [{"name": "NC_045512.2", "kind": "virus", "path": "\(extraPath)", "sha256": "0", "records": ["NC_045512.2"], "notHost": true}],
             "layout": {"kind": "deposit", "study": "GSE183579"}, "mitochondrialContigs": ["MT"], "masks": [],
             "derived": {"transcripts": \(file("derived/transcripts.fa")), "genes": \(file("derived/genes.tsv")), "transcriptGenes": \(file("derived/transcripts.tsv"))},
             "derivation": {"exonsAdded": [], "keptWithoutExon": [], "droppedFeatures": [], "renamedTranscripts": [],
              "genesWithoutFeatures": {"path": "derived/genes-without-features.tsv", "sha256": "0", "count": 0}}}
            """
        try Data(manifest.utf8).write(to: folder.appendingPathComponent(ReferenceSetManifest.filename))
    }

    func testTheSetsRecordLengthsAreReadFromAGzipFASTAAndAPlainOne() throws {
        let plain = Data(">NC_045512.2 Severe acute respiratory syndrome coronavirus 2\nACGTACGTAC\nGTA\n".utf8)
        let cases: [(String, Data)] = [
            ("extras/NC_045512.2.fa.gz", try XCTUnwrap(Data(base64Encoded: Self.gzipFASTA))),
            ("extras/NC_045512.2.fa", plain),
        ]
        for (path, bytes) in cases {
            let folder = root.appendingPathComponent(path.hasSuffix(".gz") ? "gzip.lungfishrefset" : "plain.lungfishrefset")
            try Self.writeSet(at: folder, extraPath: path, extraBytes: bytes)
            let set = try SingleCellNotHostPass.readSet(folder)
            XCTAssertEqual(set.records, [.init(name: "NC_045512.2", length: 13)], path)
            XCTAssertEqual(set.extras.map(\.name), ["NC_045512.2"], path)
            XCTAssertEqual(set.notHostFeatures, ["gene-GU280_gp01", "gene-GU280_gp10"], path)
            XCTAssertEqual(set.geneIDs, ["ENSMMUG1", "gene-GU280_gp01", "gene-GU280_gp10"], path)
        }
    }

    // MARK: - The pass through NativeToolRunner, with a stand-in samtools

    /// A STARsolo run folder of the set's three genes: 2 cells in `filtered/`, 4 barcodes in `raw/`.
    static func writeSoloFolder(at folder: URL) throws {
        let features = "ENSMMUG1\tACTB\tGene Expression\ngene-GU280_gp01\tORF1ab\tGene Expression\ngene-GU280_gp10\tN\tGene Expression\n"
        let header = "%%MatrixMarket matrix coordinate integer general\n%\n"
        let files: [String: String] = [
            "filtered/features.tsv": features, "filtered/barcodes.tsv": "AAAA\nCCCC\n",
            "filtered/matrix.mtx": header + "3 2 3\n1 1 50\n2 1 2\n1 2 30\n",
            "raw/features.tsv": features, "raw/barcodes.tsv": "AAAA\nCCCC\nGGGG\nTTTT\n",
            "raw/matrix.mtx": header + "3 4 5\n1 1 50\n2 1 2\n1 2 30\n1 3 1\n3 4 1\n",
        ]
        for (path, text) in files {
            let url = folder.appendingPathComponent("Solo.out/Gene/\(path)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
    }

    /// samtools's three calls of the pass: the version, the header at `length` and two UMIs of AAAA and one of GGGG.
    static func samtoolsScript(length: Int) -> String {
        let tags = "NH:i:1\tnM:i:0"
        let lines = [("AAAA", "U1", 1), ("AAAA", "U1", 3), ("AAAA", "U2", 2), ("GGGG", "U3", 1)].map { cb, ub, pos in
            "r\(cb)\(ub)\(pos)\t0\tNC_045512.2\t\(pos)\t255\t5M\t*\t0\t0\t*\t*\t\(tags)\tCB:Z:\(cb)\tUB:Z:\(ub)"
        }
        return """
            #!/bin/sh
            case "$*" in
              *version*) echo "samtools 1.20"; exit 0 ;;
              "view -H "*) printf '@HD\\tVN:1.4\\tSO:coordinate\\n@SQ\\tSN:1\\tLN:5000\\n@SQ\\tSN:NC_045512.2\\tLN:\(length)\\n' ;;
              "view "*" NC_045512.2") printf '\(lines.joined(separator: "\\n"))\\n' ;;
              *) echo "unexpected: $*" >&2; exit 2 ;;
            esac
            """
    }

    func testThePassCountsABAMThroughTheRunnerAndRefusesARecordOfAnotherLength() async throws {
        let set = root.appendingPathComponent("set.lungfishrefset")
        try Self.writeSet(at: set, extraPath: "extras/NC_045512.2.fa.gz", extraBytes: try XCTUnwrap(Data(base64Encoded: Self.gzipFASTA)))
        let solo = root.appendingPathComponent("GSM1", isDirectory: true)
        try Self.writeSoloFolder(at: solo)
        let bam = root.appendingPathComponent("GSM1.NC_045512.2.bam")
        try Data().write(to: bam)
        try Data().write(to: URL(fileURLWithPath: bam.path + ".bai"))
        let folder = try SingleCellFolderReader.read(folder: solo)
        // The runner resolves the managed samtools under the test process's app identity, as ManagedMappingPipelineTests
        // places its stub, so the stand-in goes where the runner looks.
        let home = root.appendingPathComponent("home", isDirectory: true)
        let samtools = CoreToolLocator.managedExecutableURL(
            environment: "samtools", executableName: "samtools", homeDirectory: home, appIdentity: .current)
        XCTAssertTrue(samtools.path.hasPrefix(home.path), "the stand-in stays under the test's home: \(samtools.path)")
        try FileManager.default.createDirectory(at: samtools.deletingLastPathComponent(), withIntermediateDirectories: true)
        let install = { (script: String) throws in
            try Data(script.utf8).write(to: samtools)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: samtools.path)
        }
        let runner = NativeToolRunner(toolsDirectory: nil, homeDirectory: home)

        try install(Self.samtoolsScript(length: 13))
        let (result, facts) = try await SingleCellNotHostPass.run(
            [folder], set: try SingleCellNotHostPass.readSet(set), bams: [folder.sample: bam], runner: runner)
        let sample = try XCTUnwrap(result.samples.first)
        XCTAssertEqual(sample.barcodes.map(\.barcode), ["AAAA", "CCCC", "GGGG"], "both cells and the barcode outside them with a UMI")
        XCTAssertEqual(sample.barcodes.map { $0.genome.first?.umis }, [2, 0, 1])
        XCTAssertEqual(sample.barcodes.map(\.rawUMIs), [52, 30, 1])
        XCTAssertEqual(sample.pool.words, "not computed: 4 barcodes, too few for an ambient pool")
        XCTAssertEqual(sample.calls.map(\.flag), ["not computed: 4 barcodes, too few for an ambient pool", "not computed: 4 barcodes, too few for an ambient pool"])
        XCTAssertEqual(facts["samtoolsVersion"]?.stringValue, "1.20")
        XCTAssertEqual(facts["notHostReferenceSet"]?.stringValue, "test-set")

        try install(Self.samtoolsScript(length: 29903))
        let other = NativeToolRunner(toolsDirectory: nil, homeDirectory: home)
        do {
            _ = try await SingleCellNotHostPass.run(
                [folder], set: try SingleCellNotHostPass.readSet(set), bams: [folder.sample: bam], runner: other)
            XCTFail("a BAM whose header holds the record at another length is refused")
        } catch let error as SingleCellNotHostError {
            XCTAssertTrue(error.errorDescription?.contains("NC_045512.2") == true, error.errorDescription ?? "")
        }
    }

    // MARK: - What the record names

    /// Installs `script` as the managed samtools under this test's own home and returns a runner that resolves it. A
    /// fresh runner follows each install, as the test above makes one for its second script.
    private func installStandIn(_ script: String) throws -> NativeToolRunner {
        let home = root.appendingPathComponent("home", isDirectory: true)
        let samtools = CoreToolLocator.managedExecutableURL(
            environment: "samtools", executableName: "samtools", homeDirectory: home, appIdentity: .current)
        XCTAssertTrue(samtools.path.hasPrefix(home.path), "the stand-in stays under the test's home: \(samtools.path)")
        try FileManager.default.createDirectory(at: samtools.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: samtools)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: samtools.path)
        return NativeToolRunner(toolsDirectory: nil, homeDirectory: home)
    }

    /// The strings of an array fact, empty when the key is absent or holds another kind.
    static func strings(_ value: ParameterValue?) -> [String] {
        guard case .array(let items)? = value else { return [] }
        return items.compactMap(\.stringValue)
    }

    /// BIO-NOTHOST-BARCODE item 9, route 2: the BAM is hashed anew at each import, so the record of a second import
    /// names the BAM that was replaced, not the first one.
    func testAReplacedBAMGivesANewSHA256InTheNextImportsRecord() async throws {
        let set = root.appendingPathComponent("set.lungfishrefset")
        try Self.writeSet(at: set, extraPath: "extras/NC_045512.2.fa.gz", extraBytes: try XCTUnwrap(Data(base64Encoded: Self.gzipFASTA)))
        let solo = root.appendingPathComponent("GSM1", isDirectory: true)
        try Self.writeSoloFolder(at: solo)
        let bam = root.appendingPathComponent("GSM1.NC_045512.2.bam")
        try Data().write(to: URL(fileURLWithPath: bam.path + ".bai"))
        let folder = try SingleCellFolderReader.read(folder: solo)
        let runner = try installStandIn(Self.samtoolsScript(length: 13))

        var records: [String] = []
        var digests: [String] = []
        for contents in ["one", "two"] {
            // The same length, so only the bytes tell the two BAMs apart.
            try Data(contents.utf8).write(to: bam)
            let (sha, size) = try SingleCellFolderReader.hashFile(bam)
            XCTAssertEqual(Int(size), contents.utf8.count)
            let (_, facts) = try await SingleCellNotHostPass.run(
                [folder], set: try SingleCellNotHostPass.readSet(set), bams: [folder.sample: bam], runner: runner)
            let record = try XCTUnwrap(Self.strings(facts["notHostBAMs"]).first, "the record names the BAM")
            XCTAssertTrue(record.contains("sha256 \(sha)"), "the record names the sha256 of the BAM as it was: \(record)")
            records.append(record)
            digests.append(sha)
        }
        XCTAssertEqual(records.count, 2)
        XCTAssertNotEqual(digests.first, digests.last, "the two BAMs differ")
        XCTAssertNotEqual(records.first, records.last, "a BAM replaced between two imports is named by its new sha256")
    }
}
