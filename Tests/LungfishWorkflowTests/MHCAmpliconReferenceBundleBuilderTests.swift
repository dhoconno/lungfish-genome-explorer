import Foundation
import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class MHCAmpliconReferenceBundleBuilderTests: XCTestCase {
    func testBuildsMHCReferenceBundleWithEmbeddedHaplotypeDefinitionAndProvenance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MHCAmpliconReferenceBundleBuilderTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fastaURL = root.appendingPathComponent("MCM_MHC.fa")
        let definitionURL = root.appendingPathComponent("mcm-mhc.lungfishhaplotypedef.json")
        let bundleURL = root.appendingPathComponent("MCM-MHC.lungfishmhcref", isDirectory: true)
        try ">M1\nACGT\n>M2\nTTTT\n".write(to: fastaURL, atomically: true, encoding: .utf8)
        let definition = Self.definition(id: "mcm-mhc")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(definition).write(to: definitionURL)

        let result = try await MHCAmpliconReferenceBundleBuilder().build(
            MHCAmpliconReferenceBundleBuildConfiguration(
                referenceFASTA: fastaURL,
                haplotypeDefinitionURLs: [definitionURL],
                outputURL: bundleURL,
                name: "MCM MHC",
                defaultHaplotypeDefinitionID: definition.id,
                forceOverwrite: true,
                argv: [
                    "lungfish-cli", "fastq", "mhc-reference-bundle",
                    "--reference-fasta", fastaURL.path,
                    "--haplotype-definition", definitionURL.path,
                    "--output", bundleURL.path,
                    "--default-haplotype-definition", definition.id,
                    "--force",
                ]
            )
        )

        XCTAssertEqual(result.bundleURL, bundleURL.standardizedFileURL)
        let manifest = try MHCAmpliconReferenceBundle.loadManifest(from: bundleURL)
        XCTAssertEqual(manifest.schemaVersion, 2)
        XCTAssertEqual(manifest.name, "MCM MHC")
        XCTAssertEqual(manifest.metrics.referenceCount, 2)
        XCTAssertEqual(manifest.metrics.haplotypeDefinitionCount, 1)
        XCTAssertEqual(manifest.defaultHaplotypeDefinitionID, definition.id)
        XCTAssertEqual(try MHCAmpliconReferenceBundle.defaultHaplotypeDefinition(in: bundleURL)?.id, definition.id)
        let embeddedReferenceURL = try XCTUnwrap(MHCAmpliconReferenceBundle.referenceBundleURL(in: bundleURL))
        let embeddedManifest = try BundleManifest.load(from: embeddedReferenceURL)
        XCTAssertEqual(embeddedManifest.genome?.chromosomes.map(\.name), ["M1", "M2"])
        XCTAssertTrue(manifest.referenceFastaPath.hasPrefix("reference/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(
            MHCAmpliconReferenceBundle.referenceFASTAURL(in: bundleURL)
        ).path))

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: result.provenanceURL))
        XCTAssertEqual(provenance.workflowName, "lungfish fastq mhc-reference-bundle")
        XCTAssertTrue(provenance.files.contains { $0.path == fastaURL.path })
        XCTAssertTrue(provenance.files.contains { $0.path == definitionURL.path })
        XCTAssertTrue(provenance.outputs.contains { $0.path == bundleURL.path })
        XCTAssertFalse(provenance.files.contains { $0.path.contains(".staging-") })
        XCTAssertFalse(provenance.steps.flatMap(\.outputs).contains { $0.path.contains(".staging-") })
        XCTAssertEqual(provenance.steps.count, 1)
        XCTAssertEqual(provenance.steps.first?.exitStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: bundleURL
                .appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)
                .appendingPathComponent(ProvenanceWriter.bundleRollupFilename)
                .path
        ))
    }

    func testBuildsAnnotatedReferenceFromGenBankAndRetainsRecoverableWarning() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MHCAmpliconReferenceBundleBuilderTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let genBankURL = root.appendingPathComponent("MCM_MHC.gb")
        let definitionURL = root.appendingPathComponent("mcm-mhc.lungfishhaplotypedef.json")
        let bundleURL = root.appendingPathComponent("MCM-MHC.lungfishmhcref", isDirectory: true)
        try """
        LOCUS       MHCREF1                12 bp    DNA     linear   UNK 01-JAN-2024
        DEFINITION  MHC annotated reference.
        ACCESSION   MHCREF1
        VERSION     MHCREF1.1
        FEATURES             Location/Qualifiers
             gene            1..6
                             /gene="MHC-A"
             CDS             bad..location
                             /product="unrecoverable feature"
        ORIGIN
                1 atgcatgcatgc
        //
        LOCUS       MHCREF2                 4 bp    DNA     linear   UNK 01-JAN-2024
        DEFINITION  Second MHC reference.
        ACCESSION   MHCREF2
        VERSION     MHCREF2.1
        FEATURES             Location/Qualifiers
             source          1..4
                             /organism="Test organism"
        ORIGIN
                1 acgt
        //
        """.write(to: genBankURL, atomically: true, encoding: .utf8)
        try JSONEncoder().encode(Self.definition(id: "mcm-mhc")).write(to: definitionURL)

        let result = try await MHCAmpliconReferenceBundleBuilder().build(
            MHCAmpliconReferenceBundleBuildConfiguration(
                referenceFASTA: genBankURL,
                haplotypeDefinitionURLs: [definitionURL],
                outputURL: bundleURL,
                argv: [
                    "lungfish-cli", "fastq", "mhc-reference-bundle",
                    "--reference-fasta", genBankURL.path,
                    "--haplotype-definition", definitionURL.path,
                    "--output", bundleURL.path,
                ]
            )
        )

        let manifest = try MHCAmpliconReferenceBundle.loadManifest(from: bundleURL)
        XCTAssertEqual(result.warnings, manifest.warnings)
        XCTAssertEqual(manifest.warnings.count, 1)
        XCTAssertEqual(manifest.warnings.first?.category, "genbank.feature.recovery")
        XCTAssertEqual(manifest.warnings.first?.code, "invalid_feature_location")
        XCTAssertEqual(manifest.warnings.first?.featureType, "CDS")
        XCTAssertNotNil(manifest.warnings.first?.lineNumber)
        let embeddedReferenceURL = try XCTUnwrap(MHCAmpliconReferenceBundle.referenceBundleURL(in: bundleURL))
        let embeddedManifest = try BundleManifest.load(from: embeddedReferenceURL)
        XCTAssertEqual(embeddedManifest.annotations.count, 1)
        XCTAssertEqual(embeddedManifest.annotations.first?.featureCount, 1)
        XCTAssertEqual(embeddedManifest.recordStore?.recordCount, 2)
        XCTAssertEqual(embeddedManifest.warnings.map(\.code), ["invalid_feature_location"])
        let recordStorePath = try XCTUnwrap(embeddedManifest.recordStore?.databasePath)
        let recordStoreURL = embeddedReferenceURL.appendingPathComponent(recordStorePath)
        XCTAssertEqual(try GenBankRecordDatabase(url: recordStoreURL).recordCount(), 2)
        let annotationDatabasePath = try XCTUnwrap(embeddedManifest.annotations.first?.databasePath)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: embeddedReferenceURL.appendingPathComponent(annotationDatabasePath).path
        ))

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: result.provenanceURL))
        XCTAssertTrue(provenance.files.contains { $0.path == genBankURL.path })
        XCTAssertTrue(provenance.stderr?.contains("Invalid GenBank location") == true)
        XCTAssertFalse(provenance.files.contains { $0.path.contains(".staging-") })
        XCTAssertFalse(provenance.steps.flatMap(\.outputs).contains { $0.path.contains(".staging-") })
        let publishedStorePath = bundleURL
            .appendingPathComponent(try XCTUnwrap(manifest.referenceBundlePath))
            .appendingPathComponent(recordStorePath).path
        let storeOutput = try XCTUnwrap(provenance.steps.flatMap(\.outputs).first { $0.path == publishedStorePath })
        XCTAssertEqual(storeOutput.checksumSHA256, try ProvenanceFileHasher.sha256(of: recordStoreURL))
        XCTAssertEqual(storeOutput.fileSize, try ProvenanceFileHasher.fileSize(of: recordStoreURL))
        XCTAssertFalse(provenance.files.contains { $0.path.contains(".reference-preparation") })
    }

    func testBuildDoesNotPublishBundleBeforeProvenanceIsReady() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MHCAmpliconReferenceBundleBuilderTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fastaURL = root.appendingPathComponent("MCM_MHC.fa")
        let definitionURL = root.appendingPathComponent("mcm-mhc.lungfishhaplotypedef.json")
        let bundleURL = root.appendingPathComponent("MCM-MHC.lungfishmhcref", isDirectory: true)
        try ">M1\nACGT\n".write(to: fastaURL, atomically: true, encoding: .utf8)
        try JSONEncoder().encode(Self.definition(id: "mcm-mhc")).write(to: definitionURL)
        let visibility = BundleVisibilityRecorder(bundleURL: bundleURL)

        _ = try await MHCAmpliconReferenceBundleBuilder().build(
            MHCAmpliconReferenceBundleBuildConfiguration(
                referenceFASTA: fastaURL,
                haplotypeDefinitionURLs: [definitionURL],
                outputURL: bundleURL
            ),
            progressHandler: { _, message in
                visibility.recordIfCopyingReference(message: message)
            }
        )

        let snapshot = visibility.snapshot()
        XCTAssertTrue(snapshot.sawCopyingReference)
        XCTAssertFalse(
            snapshot.bundleExistedWhileCopyingReference,
            "The final .lungfishmhcref path should not appear until bundle contents and provenance are complete."
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.path))
    }

    private static func definition(id: String) -> GenotypeHaplotypeDefinitionSet {
        GenotypeHaplotypeDefinitionSet(
            id: id,
            assayID: "MHC-exon2-miSeq",
            displayName: "MCM MHC",
            speciesName: "Mauritian cynomolgus macaque",
            speciesCode: "MCM",
            prefix: "MHC",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-B",
                    sourceLocus: "MHC-B",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(name: "M1", diagnosticAlleles: ["M1"])
                    ]
                )
            ]
        )
    }
}

private final class BundleVisibilityRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let bundleURL: URL
    private var sawCopyingReference = false
    private var bundleExistedWhileCopyingReference = false

    init(bundleURL: URL) {
        self.bundleURL = bundleURL
    }

    func recordIfCopyingReference(message: String) {
        guard message == "Copying MHC reference FASTA." else { return }
        lock.withLock {
            sawCopyingReference = true
            bundleExistedWhileCopyingReference = FileManager.default.fileExists(atPath: bundleURL.path)
        }
    }

    func snapshot() -> (sawCopyingReference: Bool, bundleExistedWhileCopyingReference: Bool) {
        lock.withLock {
            (
                sawCopyingReference: sawCopyingReference,
                bundleExistedWhileCopyingReference: bundleExistedWhileCopyingReference
            )
        }
    }
}
