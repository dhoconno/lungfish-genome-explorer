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
        // One step, the bundle build, as at 90d34c550. It lists the table it wrote.
        XCTAssertEqual(provenance.steps.count, 1)
        let bundleStep = try XCTUnwrap(provenance.steps.first)
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
            "the bundle step lists the table, so the table gets no record at the bundle root: \(files)"
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

    /// The metadata table gets no record and no step of its own. The bundle step lists
    /// it with its checksum, and a script exported from the bundle's record, or from
    /// the table's own focused record, replays the one command that made the bundle.
    /// Two steps would put `12s-reference-metadata` first, reading a file that
    /// `12s-reference-bundle` creates, and `set -e` would stop the script there.
    func testTheBundleRecordHasOneStepThatListsTheTableAndExportsAsOneCommand() async throws {
        let inputs = try makeInputs()
        let bundleURL = inputs.bundleURL.standardizedFileURL

        let result = try await build(inputs)

        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: result.provenanceURL))
        XCTAssertEqual(record.steps.map(\.toolName), ["lungfish fastq 12s-reference-bundle"])
        let bundleStep = try XCTUnwrap(record.steps.first)
        let tablePath = bundleURL.appendingPathComponent("target-metadata.tsv").path
        let table = try XCTUnwrap(bundleStep.outputs.first { $0.path == tablePath }, "\(bundleStep.outputs.map(\.path))")
        XCTAssertNotNil(table.checksumSHA256)
        XCTAssertNotNil(table.fileSize)

        let script = ProvenanceExporter().exportShell(record.legacyWorkflowRun(preferCanonicalSteps: true))
        XCTAssertTrue(script.contains("12s-reference-bundle"), script)
        XCTAssertFalse(script.contains("12s-reference-metadata"), script)

        // A 12S match export merges the table's focused record, which holds the same one step.
        let focusedURL = bundleURL
            .appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)
            .appendingPathComponent("target-metadata.tsv" + Self.recordSuffix)
        let focused = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: focusedURL))
        XCTAssertEqual(focused.steps.map(\.toolName), ["lungfish fastq 12s-reference-bundle"])
        let focusedScript = ProvenanceExporter().exportShell(focused.legacyWorkflowRun(preferCanonicalSteps: true))
        XCTAssertFalse(focusedScript.contains("12s-reference-metadata"), focusedScript)
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
