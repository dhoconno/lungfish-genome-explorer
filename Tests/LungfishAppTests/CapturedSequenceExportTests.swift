import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class CapturedSequenceExportTests: XCTestCase {
    func testGenBankAnnotationsStayWithTheirSelectedSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CapturedGenBank-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = try ["first", "second"].map { name in
            let url = root.appendingPathComponent("project.lungfish/\(name)")
            return SequenceExportSourceResolver.Source(metadata: .init(kind: .nativeProjectSequence,
                url: url, documentID: UUID(), nativeSequenceID: UUID(), projectURL: url.deletingLastPathComponent()),
                document: .init(name: name, url: url,
                    sequences: [try LungfishCore.Sequence(name: name, alphabet: .dna, bases: "ACGT")],
                    annotations: [SequenceAnnotation(type: .gene, name: name + "-feature", start: 0, end: 2,
                        qualifiers: ["gene": AnnotationQualifier(name + "-feature")])]))
        }
        let output = root.appendingPathComponent("result.gb")
        _ = try await makeAppDelegateWithTemporaryState().performSequenceExport(
            sources: sources, outputURL: output, format: .genbank, compression: .none)
        let records = try GenBankReader(url: output).readAllRecoveringAnnotationsSync().records
        XCTAssertEqual(records.count, 2)
        for (record, name) in zip(records, ["first", "second"]) {
            XCTAssertEqual(record.annotations.count, 1)
            XCTAssertEqual(record.annotations.map(\.name), [name + "-feature"])
        }
    }

    func testMixedCapturedAndFilesystemExportPreservesOrderAndRetainedReplay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CapturedExport-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("disk.fa")
        try ">disk\nTTTT\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let displayURL = root.appendingPathComponent("project.lungfish/native-display")
        let native = try LungfishCore.Sequence(name: "native", alphabet: .dna, bases: "ACGT")
        let sources: [SequenceExportSourceResolver.Source] = [
            .init(metadata: .init(kind: .nativeProjectSequence, url: displayURL, documentID: UUID(),
                nativeSequenceID: UUID(), projectURL: displayURL.deletingLastPathComponent()),
                document: .init(name: "native", url: displayURL, sequences: [native], annotations: [])),
            .init(metadata: .init(kind: .filesystem, url: sourceURL, documentID: nil,
                nativeSequenceID: nil, projectURL: nil), document: nil)
        ]
        let output = root.appendingPathComponent("result.fa")
        let count = try await makeAppDelegateWithTemporaryState().performSequenceExport(
            sources: sources, outputURL: output, format: .fasta, compression: .none)
        XCTAssertEqual(count, 2)
        let text = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(">native\nACGT\n>disk\nTTTT"), text)
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: output)
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any])
        let replay = try XCTUnwrap(receipt["durableReplayArgv"] as? [String])
        XCTAssertEqual(replay.first, "/bin/cp")
        if replay.first == "/bin/cp", replay.count == 3 {
            XCTAssertTrue(FileManager.default.fileExists(atPath: replay[1]))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: replay[1])), try Data(contentsOf: output))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: displayURL.path))
    }

    // MARK: - PERF-06: annotation export must never load the genome

    /// "Export annotations" from a `.lungfishref` bundle used to call
    /// `loadSequencesForExport`, which decompressed and parsed the whole
    /// genome only to discard the sequences. `loadAnnotationsForExport`
    /// reads just the manifest and the annotation databases it names. This
    /// proves that by pointing the manifest's genome at a path that does not
    /// exist: if annotation export ever touched the genome again, this would
    /// throw instead of returning the fixture's annotations.
    func testLoadAnnotationsForExportNeverOpensTheGenome() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PERF06-AnnotationExport-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bundleURL = root.appendingPathComponent("fixture.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("annotations"),
            withIntermediateDirectories: true
        )

        // Build a real annotation database with one record.
        let bedURL = root.appendingPathComponent("genes.bed")
        try "chr1\t10\t20\tgene-a\t0\t+\t10\t20\t0,0,0\t1\t10\t0\tgene\ttag=value\n"
            .write(to: bedURL, atomically: true, encoding: .utf8)
        let databaseRelativePath = "annotations/genes.db"
        let databaseURL = bundleURL.appendingPathComponent(databaseRelativePath)
        _ = try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: databaseURL)

        // The genome path in the manifest points at a file that does not
        // exist. Nothing but a regression that re-adds a genome read could
        // ever observe this path; `loadAnnotationsForExport` must not.
        let manifest = BundleManifest(
            name: "PERF-06 Fixture",
            identifier: "org.lungfish.perf06-fixture",
            source: SourceInfo(organism: "Test organism", assembly: "fixture"),
            genome: GenomeInfo(
                path: "genome/does-not-exist.fa.gz",
                indexPath: "genome/does-not-exist.fa.gz.fai",
                totalLength: 3_000_000_000,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 3_000_000_000, offset: 0, lineBases: 80, lineWidth: 81)
                ]
            ),
            annotations: [
                AnnotationTrackInfo(
                    id: "genes", name: "Genes",
                    path: "annotations/does-not-exist.bb",
                    databasePath: databaseRelativePath
                )
            ],
            recordStore: nil
        )
        try manifest.save(to: bundleURL)

        let delegate = makeAppDelegateWithTemporaryState()
        let annotations = try delegate.loadAnnotationsForExport(bundleURL: bundleURL)

        XCTAssertEqual(annotations.count, 1)
        XCTAssertEqual(annotations.first?.name, "gene-a")
    }
}
