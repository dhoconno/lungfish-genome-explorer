import Foundation
import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class TwelveSReferenceBundleBuilderTests: XCTestCase {
    private static let recordSuffix = ".lungfish-provenance.json"

    private struct Inputs {
        let fastaURL: URL
        let midoriURL: URL
        let notesURL: URL
        let bundleURL: URL
    }

    private func makeInputs() throws -> Inputs {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwelveSReferenceBundleBuilderTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fastaURL = root.appendingPathComponent("amplicons_12s_deduplicated.fa")
        let midoriURL = root.appendingPathComponent("12s_reference.tsv")
        let notesURL = root.appendingPathComponent("build_db.log")
        let bundleURL = root.appendingPathComponent("MIDORI-12S.lungfish12sref", isDirectory: true)

        try """
        >human (Homo sapiens)|locus=12S|len=8|n_refs=3|n_species=2|also_matches=Heidelberg man (Homo heidelbergensis)|n_primer_pairs=1|primer_pairs=12S_vert
        ACGTACGT
        >rainbow trout (Oncorhynchus mykiss)|locus=12S|len=8|n_refs=2|n_species=1|also_matches=|n_primer_pairs=1|primer_pairs=12S_vert
        TTTTCCCC
        """.write(to: fastaURL, atomically: true, encoding: .utf8)
        try """
        seq_id\tcommon_name\tlatin_name\tgroup\ttaxid\tname_source\ttaxonomy
        AB1\thuman\tHomo sapiens\tMammal\t9606\tncbi_common\troot; Eukaryota; Chordata; Mammalia; Primates; Hominidae; Homo; Homo sapiens
        AB2\tHeidelberg man\tHomo heidelbergensis\tMammal\t1425170\tncbi_common\troot; Eukaryota; Chordata; Mammalia; Primates; Hominidae; Homo; Homo heidelbergensis
        AB3\trainbow trout\tOncorhynchus mykiss\tFish\t8022\tfishbase\troot; Eukaryota; Chordata; Actinopteri; Salmoniformes; Salmonidae; Oncorhynchus; Oncorhynchus mykiss
        """.write(to: midoriURL, atomically: true, encoding: .utf8)
        try "build log\n".write(to: notesURL, atomically: true, encoding: .utf8)
        return Inputs(fastaURL: fastaURL, midoriURL: midoriURL, notesURL: notesURL, bundleURL: bundleURL)
    }

    private func build(_ inputs: Inputs) async throws -> TwelveSReferenceBundleBuildResult {
        try await TwelveSReferenceBundleBuilder().build(
            TwelveSReferenceBundleBuildConfiguration(
                deduplicatedFASTA: inputs.fastaURL,
                midoriMetadataTSV: inputs.midoriURL,
                outputURL: inputs.bundleURL,
                name: "MIDORI 12S",
                sourceFiles: [inputs.notesURL],
                forceOverwrite: true,
                argv: [
                    "lungfish-cli", "fastq", "12s-reference-bundle",
                    "--dedup-fasta", inputs.fastaURL.path,
                    "--midori-metadata", inputs.midoriURL.path,
                    "--output", inputs.bundleURL.path,
                    "--name", "MIDORI 12S",
                    "--source-file", inputs.notesURL.path,
                    "--force",
                ]
            )
        )
    }

    /// Every regular file under `root`, hidden ones and the `provenance` folder
    /// included, as a path relative to `root`.
    private func relativeFilePaths(under root: URL) throws -> [String] {
        let rootPath = root.standardizedFileURL.path + "/"
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: root.standardizedFileURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ))
        var paths: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let path = url.standardizedFileURL.path
            paths.append(path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : path)
        }
        return paths.sorted()
    }

    func testBuildsReferenceBundleWithMetadataProvenanceAndResolvableReferenceIndex() async throws {
        let inputs = try makeInputs()
        let bundleURL = inputs.bundleURL
        let fastaURL = inputs.fastaURL
        let midoriURL = inputs.midoriURL

        let result = try await build(inputs)

        XCTAssertEqual(result.bundleURL, bundleURL.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.provenanceURL.path))

        let manifest = try TwelveSReferenceBundle.loadManifest(from: bundleURL)
        XCTAssertEqual(manifest.name, "MIDORI 12S")
        XCTAssertEqual(manifest.metrics.referenceCount, 2)
        XCTAssertEqual(manifest.metrics.taxidCount, 2)
        XCTAssertEqual(manifest.metrics.taxonGroupCount, 2)
        XCTAssertEqual(manifest.metrics.alternateMatchCount, 1)
        XCTAssertEqual(manifest.sourceFiles.map(\.role).sorted(), ["build_source", "deduplicated_fasta", "midori_metadata"])

        let referenceURL = try XCTUnwrap(TwelveSReferenceBundle.referenceFASTAURL(in: bundleURL))
        let metadataURL = try XCTUnwrap(TwelveSReferenceBundle.targetMetadataURL(in: bundleURL))
        let records = try TwelveSReferenceIndex.load(from: referenceURL, metadataURL: metadataURL).records
        let human = try XCTUnwrap(records.first { $0.target.scientificName == "Homo sapiens" })
        XCTAssertEqual(human.target.taxid, "9606")
        XCTAssertEqual(human.target.taxonGroup, "Mammal")
        XCTAssertEqual(human.target.taxonomy, "root; Eukaryota; Chordata; Mammalia; Primates; Hominidae; Homo; Homo sapiens")
        XCTAssertEqual(human.alternateMatches.first?.scientificName, "Homo heidelbergensis")

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: result.provenanceURL))
        XCTAssertEqual(provenance.workflowName, "lungfish fastq 12s-reference-bundle")
        XCTAssertTrue(provenance.argv.contains("--source-file"))
        XCTAssertTrue(provenance.files.contains { $0.path == fastaURL.path })
        XCTAssertTrue(provenance.files.contains { $0.path == midoriURL.path })
        XCTAssertTrue(provenance.outputs.contains { $0.path == bundleURL.path })
        // The metadata run is the first step and the bundle build the second.
        XCTAssertEqual(provenance.steps.count, 2)
        let bundleStep = try XCTUnwrap(provenance.steps.last)
        XCTAssertEqual(bundleStep.toolName, "lungfish fastq 12s-reference-bundle")
        XCTAssertEqual(bundleStep.exitStatus, 0)
        XCTAssertTrue(bundleStep.inputs.contains { $0.path == fastaURL.path })
        XCTAssertTrue(bundleStep.outputs.contains { $0.path == bundleURL.path })
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: bundleURL
                .appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)
                .appendingPathComponent(ProvenanceWriter.bundleRollupFilename)
                .path
        ))
    }

    // MARK: Walk F6, a record of a record

    /// The bundle writer used to record its own records. The metadata run wrote
    /// `target-metadata.tsv.lungfish-provenance.json` at the bundle root, the
    /// writer listed every visible file as an output, and the layout then wrote
    /// a record of that record under `provenance/`.
    func testBundleHoldsNoRecordOfARecordAndNoRootRecordOfItsMetadataTable() async throws {
        let inputs = try makeInputs()

        _ = try await build(inputs)

        let files = try relativeFilePaths(under: inputs.bundleURL)
        let recordsOfRecords = files.filter { $0.hasSuffix(Self.recordSuffix + Self.recordSuffix) }
        XCTAssertEqual(recordsOfRecords, [], "a record of a record: \(files)")
        XCTAssertFalse(
            files.contains("target-metadata.tsv" + Self.recordSuffix),
            "the metadata run is a step of the bundle record, so it writes no record of its own: \(files)"
        )
        // A bundle holds its own record, its roll-up and one record for each output.
        for expected in [
            ".lungfish-provenance.json",
            "provenance/bundle.lungfish-provenance.json",
            "provenance/12s-reference.json.lungfish-provenance.json",
            "provenance/reference.fa.lungfish-provenance.json",
            "provenance/target-metadata.tsv.lungfish-provenance.json",
        ] {
            XCTAssertTrue(files.contains(expected), "missing \(expected) in \(files)")
        }
    }

    func testNoRecordFileIsAnOutputOfTheBundleRecord() async throws {
        let inputs = try makeInputs()

        let result = try await build(inputs)

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: result.provenanceURL))
        let listed = provenance.outputs + provenance.steps.flatMap(\.outputs) + provenance.files.filter { $0.role == .output }
        XCTAssertEqual(listed.map(\.path).filter { $0.hasSuffix(Self.recordSuffix) }, [])
        // The reference manifest is a scientific output and stays listed.
        let manifestPath = inputs.bundleURL.standardizedFileURL.appendingPathComponent("12s-reference.json").path
        XCTAssertTrue(provenance.outputs.contains { $0.path == manifestPath }, "\(provenance.outputs.map(\.path))")
    }

    func testTheMetadataRunIsTheFirstStepOfTheBundleRecord() async throws {
        let inputs = try makeInputs()
        let bundleURL = inputs.bundleURL.standardizedFileURL

        let result = try await build(inputs)

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: result.provenanceURL))
        XCTAssertEqual(provenance.steps.map(\.toolName), [
            "lungfish fastq 12s-reference-metadata",
            "lungfish fastq 12s-reference-bundle",
        ])
        let metadataStep = try XCTUnwrap(provenance.steps.first { $0.toolName == "lungfish fastq 12s-reference-metadata" })
        let bundleStep = try XCTUnwrap(provenance.steps.first { $0.toolName == "lungfish fastq 12s-reference-bundle" })

        let referenceCopy = bundleURL.appendingPathComponent("reference.fa").path
        let metadataTable = bundleURL.appendingPathComponent("target-metadata.tsv").path
        XCTAssertEqual(metadataStep.argv, [
            "lungfish-cli", "fastq", "12s-reference-metadata",
            "--dedup-fasta", referenceCopy,
            "--midori-metadata", inputs.midoriURL.standardizedFileURL.path,
            "--output", metadataTable,
            "--force",
        ])
        XCTAssertEqual(metadataStep.exitStatus, 0)
        XCTAssertEqual(metadataStep.inputs.map(\.path), [referenceCopy, inputs.midoriURL.standardizedFileURL.path])
        XCTAssertTrue(metadataStep.inputs.allSatisfy { $0.checksumSHA256 != nil && $0.fileSize != nil })
        XCTAssertEqual(metadataStep.outputs.map(\.path), [metadataTable])
        XCTAssertNotNil(metadataStep.outputs.first?.checksumSHA256)
        XCTAssertNotNil(metadataStep.startedAt)
        XCTAssertNotNil(metadataStep.completedAt)
        XCTAssertEqual(bundleStep.dependsOn, [metadataStep.id], "the bundle build uses the table the metadata run wrote")

        // The table's own focused record names both steps.
        let focusedURL = bundleURL
            .appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)
            .appendingPathComponent("target-metadata.tsv" + Self.recordSuffix)
        let focused = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: focusedURL))
        XCTAssertEqual(focused.steps.map(\.toolName), [
            "lungfish fastq 12s-reference-metadata",
            "lungfish fastq 12s-reference-bundle",
        ])
    }

    func testAFailedBuildLeavesNoBundleAndNoRecord() async throws {
        let inputs = try makeInputs()
        try "seq_id\tcommon_name\n".write(to: inputs.midoriURL, atomically: true, encoding: .utf8)

        do {
            _ = try await build(inputs)
            XCTFail("a MIDORI table without the required columns must fail the build")
        } catch TwelveSReferenceMetadataBuildError.missingColumn {
            // expected
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: inputs.bundleURL.path))
    }
}
