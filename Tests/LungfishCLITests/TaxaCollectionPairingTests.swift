// TaxaCollectionPairingTests.swift - A taxa-collection extraction of pairs is ingested as pairs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.0 lane PAIRING (walk WF-1, BIO-WALK.md section "WF-1"). The 2026-10-26 walk extracted HSV-1
// from the interleaved paired SRR12486983, whose mates carry byte-equal SRA names. The file of pairs
// came out of the app's in-place ingest recorded `single_end`, and the record the extraction had
// written for the plain file stayed beside the clumped file that replaced it. The ingest is a second
// process, `lungfish-cli fastq ingest <file>`, that the app starts once the extraction ends, so the
// extraction carries its layout to it in the metadata sidecar beside the file.
//
// The fixture is `Tests/Fixtures/kraken2/interleaved-sra-names/` (6 pairs, 4 on taxid 10298 and 2 on
// 10325). These runs skip clumpify, so none needs the managed tool. The run with the real clumpify is
// `TaxaCollectionPairingLiveConformanceTests`.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

/// A scratch project that holds a copy of the `interleaved-sra-names` result and runs the two commands
/// of the walk on it, `extract taxa-collection` and then `fastq ingest` on a file it wrote.
struct TaxaCollectionPairingWorkspace {
    let root: URL
    let result: URL
    let output: URL

    static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // LungfishCLITests
        .deletingLastPathComponent() // Tests
        .appendingPathComponent("Fixtures/kraken2/interleaved-sra-names", isDirectory: true)

    init() throws {
        root = try TestTempDirectory.make(prefix: "taxa-collection-pairing")
        let analyses = root.appendingPathComponent("Project.lungfish/Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
        result = analyses.appendingPathComponent("kraken2-sra-names", isDirectory: true)
        try FileManager.default.copyItem(at: Self.fixture, to: result)
        output = result.appendingPathComponent("extracted-sti-pathogens", isDirectory: true)
    }

    func cleanup() { TestTempDirectory.cleanup(root) }

    /// The files `extract taxa-collection --target <target>` wrote into the output folder.
    func extract(_ target: String) async throws -> [URL] {
        let command = try ExtractTaxaCollectionSubcommand.parse([
            "--result", result.path, "--collection-id", "sti-pathogens",
            "--collection-name", "Sexually Transmitted Infections", "--target", target,
            "--output-dir", output.path, "--format", "json",
        ])
        let outcome = try await command.extract(events: CLIEventEmitter(enabled: false, emit: { _ in }))
        return outcome.outputs.map { URL(fileURLWithPath: $0) }
    }

    /// The one file that `extract taxa-collection --target <target>` wrote.
    func extractedFile(_ target: String) async throws -> URL {
        let outputs = try await extract(target)
        return try XCTUnwrap(outputs.first, "no taxon gave a file")
    }

    /// `fastq ingest <file>` as the app starts it for a file the extraction wrote.
    func ingest(_ file: URL, _ options: [String]) async throws {
        let command = try FastqIngestSubcommand.parse([file.path, "--delete-originals", "--binning", "none", "--quiet"] + options)
        try await command.execute(emit: { _ in })
    }

    /// The record and metadata sidecars of `folder` whose file is not there. The folder's own record,
    /// `.lungfish-provenance.json`, belongs to the run and is not a file's sidecar.
    func sidecarsOfMissingFiles() throws -> [String] {
        let suffixes = [".lungfish-provenance.json", ".lungfish-meta.json"]
        return try FileManager.default.contentsOfDirectory(atPath: output.path).sorted().filter { name in
            suffixes.contains { suffix in
                name.hasSuffix(suffix) && name != suffix
                    && !FileManager.default.fileExists(atPath: output.appendingPathComponent(String(name.dropLast(suffix.count))).path)
            }
        }
    }
}

final class TaxaCollectionPairingTests: XCTestCase {
    private var workspace: TaxaCollectionPairingWorkspace!

    override func setUpWithError() throws {
        workspace = try TaxaCollectionPairingWorkspace()
    }

    override func tearDownWithError() throws {
        workspace.cleanup()
    }

    private func requireCompressor() async throws {
        let runner = NativeToolRunner.shared
        let hasBgzip = (try? await runner.toolPath(for: .bgzip)) != nil
        let hasPigz = (try? await runner.toolPath(for: .pigz)) != nil
        guard hasBgzip || hasPigz else {
            try ToolAvailability.skipOrFail("Neither managed bgzip nor pigz is available")
        }
    }

    // MARK: - The file of pairs alone (case 1)

    /// The extraction measured 4 pairs and no single read, so the file it wrote holds the layout beside it.
    func testTheExtractionRecordsInterleavedBesideAFileOfPairsAlone() async throws {
        let outputs = try await workspace.extract("10298,children,HSV-1")

        let file = try XCTUnwrap(outputs.first)
        XCTAssertEqual(outputs.map(\.lastPathComponent), ["HSV-1_taxid10298.fastq.gz"])
        let counts = try FASTQMixedLayoutHint.countPairsAndSingles(in: file)
        XCTAssertEqual(counts.pairs, 4, "8 reads, the 4 pairs of taxid 10298")
        XCTAssertEqual(counts.singles, 0)
        XCTAssertEqual(
            FASTQMetadataStore.load(for: file)?.ingestion?.pairingMode, .interleaved,
            "the layout the extraction measured travels beside the file, to the ingest that follows"
        )
    }

    /// The walk's defect. The ingest that follows recorded `single_end` for the 8 reads of 4 pairs.
    func testTheIngestThatFollowsKeepsAFileOfPairsInterleaved() async throws {
        let file = try await workspace.extractedFile("10298,children,HSV-1")

        try await workspace.ingest(file, ["--skip-clumpify"])

        let ingestion = try XCTUnwrap(FASTQMetadataStore.load(for: file)?.ingestion)
        XCTAssertEqual(ingestion.pairingMode, .interleaved, "the walk recorded single_end here")
        XCTAssertEqual(FASTQReadLayoutClassifier.metadataHints(for: file).pairingMode, .interleaved)
        let counts = try FASTQMixedLayoutHint.countPairsAndSingles(in: file)
        XCTAssertEqual(counts.pairs, 4)
        XCTAssertEqual(counts.singles, 0)
    }

    // MARK: - A mix of one pair and one single read (case 3)

    /// Taxid 10298 holds pair 1 and the single read 2, and 10325 holds pair 3.
    private func useOnePairAndOneSingleReadOnTaxid10298() throws {
        func record(_ name: String, _ bases: String) -> String { "@\(name)\n\(bases)\n+\n\(String(repeating: "I", count: bases.count))\n" }
        let fastq = [
            record("SRR12486983.1 1 length=20", "ACGTACGTACGTACGTACGT"), record("SRR12486983.1 1 length=20", "TGCATGCATGCATGCATGCA"),
            record("SRR12486983.2 2 length=20", "AACCGGTTAACCGGTTAACC"),
            record("SRR12486983.3 3 length=20", "ACACACACGTGTGTGTACAC"), record("SRR12486983.3 3 length=20", "TGTGTGTGCACACACATGTG"),
        ].joined()
        try fastq.write(to: workspace.result.appendingPathComponent("source.fastq"), atomically: true, encoding: .utf8)
        let kraken = [
            "C\tSRR12486983.1\t10298\t20|20\t10298:3 |:| 10298:3", "C\tSRR12486983.2\t10298\t20\t10298:3",
            "C\tSRR12486983.3\t10325\t20|20\t10325:3 |:| 10325:3",
        ].joined(separator: "\n") + "\n"
        try kraken.write(to: workspace.result.appendingPathComponent("classification.kraken"), atomically: true, encoding: .utf8)
        let report = [
            "  0.00\t0\t0\tU\t0\tunclassified", "100.00\t3\t0\tR\t1\troot", "100.00\t3\t0\tR1\t10239\t  Viruses",
            "100.00\t3\t0\tG\t10294\t      Simplexvirus", " 66.67\t2\t2\tS\t10298\t        Human alphaherpesvirus 1",
            " 33.33\t1\t1\tS\t10325\t        Macacine alphaherpesvirus 1",
        ].joined(separator: "\n") + "\n"
        try report.write(to: workspace.result.appendingPathComponent("classification.kreport"), atomically: true, encoding: .utf8)
    }

    /// A pin that passes at the base. A file that holds a pair and a single read stays `single_end`, so no
    /// positional tool pairs it, and its sidecar keeps the roles, 2 paired reads and 1 unpaired.
    func testAMixedFileStaysSingleEndWithItsRoles() async throws {
        try useOnePairAndOneSingleReadOnTaxid10298()
        let file = try await workspace.extractedFile("10298,children,HSV-1")

        func assertRoles(_ when: String) throws {
            let roles = try XCTUnwrap(FASTQMetadataStore.load(for: file)?.readClassification, when)
            XCTAssertEqual(roles.pairedReadCount, 2, when)
            XCTAssertEqual(roles.unpairedReadCount, 1, when)
            XCTAssertEqual(roles.mergedReadCount, 0, when)
        }
        try assertRoles("after the extraction")
        try await workspace.ingest(file, ["--skip-clumpify"])

        XCTAssertEqual(FASTQMetadataStore.load(for: file)?.ingestion?.pairingMode, .singleEnd)
        XCTAssertEqual(FASTQReadLayoutClassifier.metadataHints(for: file).pairingMode, .singleEnd)
        try assertRoles("after the ingest")
    }

    // MARK: - The records of a file the ingest replaces (case 2)

    /// An ingest that removes its original takes the original's own record and metadata with it, since
    /// both describe a file that is gone, and leaves the record of every file it did not touch. A clumped
    /// file replaces the plain one in the walk. A plain FASTQ stands in here, since it needs no clumpify.
    func testARemovedOriginalTakesItsOwnSidecarsWithIt() async throws {
        try await requireCompressor()
        let extracted = try await workspace.extractedFile("10298,children,HSV-1")
        let original = workspace.output.appendingPathComponent("reads.fastq")
        try String(contentsOf: workspace.result.appendingPathComponent("source.fastq"), encoding: .utf8)
            .write(to: original, atomically: true, encoding: .utf8)
        let ownRecord = ProvenanceRecorder.fileSidecarURL(for: original)
        try "{}".write(to: ownRecord, atomically: true, encoding: .utf8)
        try FASTQMetadataStore.write(PersistedFASTQMetadata(), for: original)

        try await workspace.ingest(original, [])

        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent("reads.fastq.gz").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownRecord.path), "the record of the removed original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: FASTQMetadataStore.metadataURL(for: original).path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: extracted).path),
            "the record of a file this run did not touch stays"
        )
        XCTAssertEqual(try workspace.sidecarsOfMissingFiles(), [])
    }

    // MARK: - A layout left beside the name the extraction writes (BIO review of PAIRING, should-fix 2)

    /// A run for the same taxon again, or a plain file that was deleted by hand, leaves the earlier file's
    /// metadata beside the name the extraction writes. That layout describes the earlier file, so the
    /// extraction replaces it with the layout it measured. The earlier file here was a file of pairs that left
    /// `interleaved`, and the new file holds a pair and a single read. `FASTQMetadataStore.write` refuses a
    /// file that is not there, so the earlier sidecar is encoded by hand.
    func testTheExtractionReplacesALayoutLeftBesideTheFileItWrites() async throws {
        try useOnePairAndOneSingleReadOnTaxid10298()
        try FileManager.default.createDirectory(at: workspace.output, withIntermediateDirectories: true)
        let beside = workspace.output.appendingPathComponent("HSV-1_taxid10298.fastq.gz")
        var earlier = PersistedFASTQMetadata()
        earlier.ingestion = IngestionMetadata(
            isCompressed: true, pairingMode: .interleaved, pairingSource: .detected,
            originalFilenames: [beside.lastPathComponent]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(earlier).write(to: FASTQMetadataStore.metadataURL(for: beside), options: .atomic)
        XCTAssertEqual(
            FASTQMetadataStore.load(for: beside)?.ingestion?.pairingMode, .interleaved,
            "the earlier file's layout is in place before the extraction"
        )

        let file = try await workspace.extractedFile("10298,children,HSV-1")

        XCTAssertEqual(file.lastPathComponent, beside.lastPathComponent)
        XCTAssertNil(
            FASTQMetadataStore.load(for: file)?.ingestion,
            "the new file holds a single read, so the earlier interleaved layout does not describe it"
        )
        XCTAssertEqual(FASTQMetadataStore.load(for: file)?.readClassification?.unpairedReadCount, 1)
    }
}
