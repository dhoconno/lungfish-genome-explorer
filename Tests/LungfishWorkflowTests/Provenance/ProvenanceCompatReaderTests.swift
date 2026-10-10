import Foundation
import Testing
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

/// Reads every frozen sidecar of the provenance compatibility corpus through the
/// production readers and compares what they say with reviewed expectations.
///
/// The corpus bytes are copied to a temporary project before any code reads them,
/// and the expectations are host-independent facts (see ProvenanceCompatFacts), so
/// the suite gives the same answer on every Mac. A write-side lane that changes
/// what a reader says about old bytes fails here.
@Suite("Provenance compatibility corpus readers")
struct ProvenanceCompatReaderTests {
    /// Whether the strict readers (`loadCanonical`, `decodeCanonical`) accept each case,
    /// pinned by hand from the bytes. A case missing from this table fails the suite.
    /// Bare runs and primitive records are rejected by design, so a sidecar of that shape
    /// in a folder read by a strict site is an error there.
    static let strictAcceptance: [String: Bool] = [
        "s1-db-receipt-kraken2-viral": true,
        "s2-analysis-kraken2-fixture": true,
        "s3-ncbi-fetch-alpha11": false,
        "s4-mcm-mhcref-shipped": false,
        "s4-msa-mafft-2026-05": false,
    ]

    @Test("the manifest is intact and every case has reviewed expected facts")
    func manifestIsIntactAndComplete() throws {
        try ProvenanceCompatCorpus.verifyManifest()
        let cases = try ProvenanceCompatCorpus.cases()
        #expect(!cases.isEmpty)
        for item in cases {
            #expect(
                ProvenanceCompatCorpus.expectedFactsData(for: item.id) != nil,
                "case \(item.id) has no expected facts"
            )
            #expect(Self.strictAcceptance[item.id] != nil, "case \(item.id) has no pinned strict acceptance")
        }
        #expect(Set(Self.strictAcceptance.keys).isSubset(of: Set(cases.map(\.id))))
    }

    @Test("facts equal the reviewed expected facts byte for byte", arguments: ProvenanceCompatCorpus.caseIDs())
    func factsEqualExpected(id: String) throws {
        let materialized = try ProvenanceCompatCorpus.materialize(id)
        defer { materialized.cleanup() }
        let facts = try ProvenanceCompatFacts.project(
            sidecar: materialized.sidecar,
            projectRoot: materialized.projectRoot
        )
        let expected = try #require(ProvenanceCompatCorpus.expectedFactsData(for: id), "case \(id) has no expected facts")
        #expect(String(decoding: try facts.canonicalJSON(), as: UTF8.self) == String(decoding: expected, as: UTF8.self))
    }

    @Test("strict acceptance is pinned per case", arguments: ProvenanceCompatCorpus.caseIDs())
    func strictAcceptanceIsPinned(id: String) throws {
        let pinned = try #require(Self.strictAcceptance[id] as Bool?, "case \(id) has no pinned strict acceptance")
        let materialized = try ProvenanceCompatCorpus.materialize(id)
        defer { materialized.cleanup() }

        let strict = try? ProvenanceEnvelopeReader.loadCanonical(fromSidecar: materialized.sidecar)
        #expect((strict != nil) == pinned)
        // The tolerant reader accepts every case, which is why the strict sites are the risk.
        #expect(try ProvenanceEnvelopeReader.load(fromSidecar: materialized.sidecar) != nil)

        let facts = try ProvenanceCompatFacts.project(
            sidecar: materialized.sidecar,
            projectRoot: materialized.projectRoot
        )
        #expect(facts.strictAccepts == pinned)
    }

    @Test("the finder and the lineage resolver return the case's own sidecar", arguments: ProvenanceCompatCorpus.caseIDs())
    func finderReturnsTheSameSidecar(id: String) throws {
        let materialized = try ProvenanceCompatCorpus.materialize(id)
        defer { materialized.cleanup() }
        let selection = try #require(materialized.selection, "case \(id) names no selection")

        let found = try #require(ProvenanceRecorder.findProvenanceEnvelope(for: selection))
        #expect(Self.sameFile(found.sidecarURL, materialized.sidecar))

        let direct = try ProvenanceCompatFacts.project(
            sidecar: materialized.sidecar,
            projectRoot: materialized.projectRoot
        )
        let viaFinder = try ProvenanceCompatFacts.project(
            envelope: found.envelope,
            sidecar: found.sidecarURL,
            projectRoot: materialized.projectRoot
        )
        #expect(viaFinder == direct)

        let lineage = ProvenanceLineageResolver().resolve(
            envelope: found.envelope,
            sidecarURL: found.sidecarURL,
            sourceRootURL: selection
        )
        #expect(lineage.count == 1)
        let last = try #require(lineage.last)
        #expect(last.sidecarURL.map { Self.sameFile($0, materialized.sidecar) } == true)
    }

    @Test("json and shell exports succeed and keep the source bytes", arguments: ProvenanceCompatCorpus.caseIDs())
    func exportsSucceed(id: String) throws {
        let materialized = try ProvenanceCompatCorpus.materialize(id)
        let exportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("provenance-compat-export-\(UUID().uuidString)", isDirectory: true)
        defer {
            materialized.cleanup()
            try? FileManager.default.removeItem(at: exportRoot)
        }
        let envelope = try #require(try ProvenanceEnvelopeReader.load(fromSidecar: materialized.sidecar))
        let sourceBytes = try Data(contentsOf: materialized.sidecar)
        let exporter = ProvenanceExporter(signingProvider: nil)

        let json = try exporter.exportBundle(
            envelope,
            format: .json,
            to: exportRoot.appendingPathComponent("json", isDirectory: true),
            sourceSidecarURL: materialized.sidecar,
            sourceRootURL: materialized.selection
        )
        #expect(json.primaryArtifactURL.lastPathComponent == "provenance.json")
        let exported = try ProvenanceEnvelopeReader.decodeCanonical(Data(contentsOf: json.primaryArtifactURL))
        #expect(exported.workflowName == envelope.workflowName)
        #expect(exported.toolName == envelope.toolName)
        #expect(exported.toolVersion == envelope.toolVersion)
        #expect(exported.argv == envelope.argv)
        #expect(exported.exitStatus == envelope.exitStatus)
        #expect(
            json.copiedSidecarURLs.contains { (try? Data(contentsOf: $0)) == sourceBytes },
            "the export keeps a byte-identical copy of the source sidecar"
        )

        let shell = try exporter.exportBundle(
            envelope,
            format: .shell,
            to: exportRoot.appendingPathComponent("shell", isDirectory: true),
            sourceSidecarURL: materialized.sidecar,
            sourceRootURL: materialized.selection
        )
        #expect(shell.primaryArtifactURL.lastPathComponent == "run.sh")
        let script = try String(contentsOf: shell.primaryArtifactURL, encoding: .utf8)
        #expect(!script.isEmpty)

        // The readers and exporters never write to the case; the corpus on disk is unchanged.
        try ProvenanceCompatCorpus.verifyManifest()
        #expect(try Data(contentsOf: materialized.sidecar) == sourceBytes)
    }

    @Test("the alpha.11 fetch record reads as the bytes say")
    func alpha11FetchRecordHandAsserts() throws {
        let materialized = try ProvenanceCompatCorpus.materialize("s3-ncbi-fetch-alpha11")
        defer { materialized.cleanup() }
        let envelope = try #require(try ProvenanceEnvelopeReader.load(fromSidecar: materialized.sidecar))

        #expect(envelope.workflowName == "ncbi-sequence-fetch")
        #expect(envelope.toolName == "ncbi-efetch")
        #expect(envelope.toolVersion == "NCBI E-utilities API")
        #expect(envelope.exitStatus == 0)
        #expect(Array(envelope.argv.prefix(9)) == [
            "lungfish", "fetch", "ncbi", "MN908947.3", "--db", "nucleotide",
            "--fetch-format", "gff3", "--save-to",
        ])
        #expect(Array(envelope.argv.suffix(2)) == ["--format", "text"])
        #expect(envelope.argv.count == 12)
        #expect(envelope.argv[9].hasSuffix("/MN908947.3.gff3"))

        let recordedOutput = try #require(envelope.outputs.first)
        #expect(recordedOutput.checksumSHA256 == "7edcb9f6c6de7ba570106926e5af55f7e45ed5f8b92b9a33664fb9ca2711ae32")
        #expect(recordedOutput.fileSize == 4040)
        #expect(recordedOutput.role == .output)
        #expect(recordedOutput.path == envelope.argv[9])

        // The payload that sits beside the sidecar in the repository is the file the record names.
        let payload = materialized.sidecar.deletingLastPathComponent().appendingPathComponent("MN908947.3.gff3")
        #expect(try ProvenanceFileHasher.sha256(of: payload) == recordedOutput.checksumSHA256)
        #expect(try ProvenanceFileHasher.fileSize(of: payload) == recordedOutput.fileSize)

        // A bare run is not an envelope, so the strict readers reject it.
        #expect(throws: (any Error).self) {
            try ProvenanceEnvelopeReader.loadCanonical(fromSidecar: materialized.sidecar)
        }
        // The legacy tool name `lungfish` is the executable the GUI import gate recognizes.
        #expect(envelope.argv.first == "lungfish")
        #expect(envelope.legacyWorkflowRun().status == .completed)
    }

    // MARK: Helpers

    private static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL.path == rhs.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
