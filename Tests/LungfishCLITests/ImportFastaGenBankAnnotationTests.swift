import ArgumentParser
import XCTest
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

final class ImportFastaGenBankAnnotationTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportFastaGenBankAnnotationTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testGenBankReferenceImportMaterializesAnnotationTrackGFF3AndProvenance() async throws {
        let inputURL = tempDir.appendingPathComponent("MN908947.3.gb")
        try Self.smallAnnotatedGenBank.write(to: inputURL, atomically: true, encoding: .utf8)

        let projectURL = tempDir.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let command = try ImportCommand.FASTASubcommand.parse([
            inputURL.path,
            "--output-dir", projectURL.path,
            "--name", "MN908947.3",
            "--quiet",
        ])
        try await command.run()

        let bundleURL = projectURL
            .appendingPathComponent(ReferenceSequenceFolder.folderName, isDirectory: true)
            .appendingPathComponent("MN908947.3.lungfishref", isDirectory: true)
        let manifest = try BundleManifest.load(from: bundleURL)
        XCTAssertTrue(manifest.warnings.isEmpty)

        let annotation: AnnotationTrackInfo = try XCTUnwrap(manifest.annotations.first)
        XCTAssertEqual(annotation.id, "imported_annotations")
        XCTAssertEqual(annotation.databasePath, "annotations/imported_annotations.db")
        XCTAssertEqual(annotation.path, "annotations/imported_annotations.gff3")
        XCTAssertEqual(annotation.featureCount, 3)

        let recordStore = try XCTUnwrap(manifest.recordStore)
        XCTAssertEqual(recordStore.recordCount, 1)
        let recordStoreURL = bundleURL.appendingPathComponent(recordStore.databasePath)
        XCTAssertEqual(try GenBankRecordDatabase(url: recordStoreURL).recordCount(), 1)

        let gffURL = bundleURL.appendingPathComponent(annotation.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: gffURL.path))

        let gff = try String(contentsOf: gffURL, encoding: .utf8)
        XCTAssertTrue(gff.contains("##gff-version 3"))
        XCTAssertTrue(gff.contains("\tgene\t"))
        XCTAssertTrue(gff.contains("\tCDS\t"))
        XCTAssertTrue(gff.contains("\tmat_peptide\t"))
        XCTAssertTrue(gff.contains("gene=S"))
        XCTAssertTrue(
            gff.contains("product=spike%20glycoprotein") || gff.contains("product=spike glycoprotein")
        )

        let provenanceURL = bundleURL.appendingPathComponent(".lungfish-provenance.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: provenanceURL.path))

        let provenance = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try Data(contentsOf: provenanceURL)
        ) as? [String: Any])
        XCTAssertEqual(provenance["name"] as? String, "lungfish import fasta")
        XCTAssertEqual(provenance["status"] as? String, "completed")

        let steps = try XCTUnwrap(provenance["steps"] as? [[String: Any]])
        let importStep: [String: Any] = try XCTUnwrap(steps.first)
        XCTAssertEqual(importStep["toolName"] as? String, "lungfish import fasta")
        XCTAssertEqual(importStep["exitCode"] as? Int, 0)

        let commandLine = try XCTUnwrap(importStep["command"] as? [String])
        XCTAssertEqual(commandLine.first, "lungfish-cli")
        XCTAssertTrue(commandLine.contains("import"))
        XCTAssertTrue(commandLine.contains("fasta"))
        XCTAssertTrue(commandLine.contains(inputURL.path))

        let outputs = try XCTUnwrap(importStep["outputs"] as? [[String: Any]])
        XCTAssertTrue(outputs.contains {
            ($0["path"] as? String)?.hasSuffix("annotations/imported_annotations.gff3") == true
        })
        let recordStoreOutput = try XCTUnwrap(outputs.first {
            ($0["path"] as? String) == recordStoreURL.path
        })
        XCTAssertEqual(
            recordStoreOutput["sha256"] as? String,
            try ProvenanceFileHasher.sha256(of: recordStoreURL)
        )
        XCTAssertEqual(
            (recordStoreOutput["sizeBytes"] as? NSNumber)?.uint64Value,
            try ProvenanceFileHasher.fileSize(of: recordStoreURL)
        )
        XCTAssertFalse(outputs.contains {
            ($0["path"] as? String)?.contains("/.tmp/") == true
        })
        XCTAssertFalse(outputs.contains {
            ($0["path"] as? String)?.contains("lungfish-cli-ref-import-") == true
        })
        XCTAssertFalse(outputs.contains {
            guard let path = $0["path"] as? String else { return false }
            return path.hasSuffix("genbank_records.sqlite") && path != recordStoreURL.path
        })
        XCTAssertTrue(outputs.allSatisfy {
            $0["sha256"] != nil && $0["sizeBytes"] != nil
        })
        let canonical = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: bundleURL))
        XCTAssertNil(canonical.options.explicit["warnings"])
        XCTAssertTrue(canonical.steps.allSatisfy { $0.stderr?.isEmpty != false })
    }

    func testCompressedGenBankReferenceImportMaterializesAnnotationTrackGFF3() async throws {
        let uncompressedURL = tempDir.appendingPathComponent("MN908947.3.gb")
        try Self.smallAnnotatedGenBank.write(to: uncompressedURL, atomically: true, encoding: .utf8)
        let inputURL = tempDir.appendingPathComponent("MN908947.3.gb.gz")
        try gzip(sourceURL: uncompressedURL, destinationURL: inputURL)

        let projectURL = tempDir.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let command = try ImportCommand.FASTASubcommand.parse([
            inputURL.path,
            "--output-dir", projectURL.path,
            "--name", "MN908947.3-compressed",
            "--quiet",
        ])
        try await command.run()

        let bundleURL = projectURL
            .appendingPathComponent(ReferenceSequenceFolder.folderName, isDirectory: true)
            .appendingPathComponent("MN908947.3-compressed.lungfishref", isDirectory: true)
        let manifest = try BundleManifest.load(from: bundleURL)
        let annotation = try XCTUnwrap(manifest.annotations.first)
        XCTAssertEqual(annotation.path, "annotations/imported_annotations.gff3")
        XCTAssertEqual(annotation.databasePath, "annotations/imported_annotations.db")
        XCTAssertEqual(annotation.featureCount, 3)
        let recordStore = try XCTUnwrap(manifest.recordStore)
        XCTAssertEqual(try GenBankRecordDatabase(
            url: bundleURL.appendingPathComponent(recordStore.databasePath)
        ).recordCount(), 1)

        let gff = try String(
            contentsOf: bundleURL.appendingPathComponent(annotation.path),
            encoding: .utf8
        )
        XCTAssertTrue(gff.contains("\tgene\t"))
        XCTAssertTrue(gff.contains("\tCDS\t"))
        XCTAssertTrue(gff.contains("\tmat_peptide\t"))
    }

    func testCompressedGenBankImportRecoversRecordsWhenOneAnnotationIsMalformed() async throws {
        let uncompressedURL = tempDir.appendingPathComponent("mixed.gb")
        try Self.mixedValidityGenBank.write(to: uncompressedURL, atomically: true, encoding: .utf8)
        let inputURL = tempDir.appendingPathComponent("mixed.gb.gz")
        try gzip(sourceURL: uncompressedURL, destinationURL: inputURL)
        let projectURL = tempDir.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let command = try ImportCommand.FASTASubcommand.parse([
            inputURL.path,
            "--output-dir", projectURL.path,
            "--name", "mixed",
            "--quiet",
        ])
        try await command.run()

        let bundleURL = projectURL
            .appendingPathComponent(ReferenceSequenceFolder.folderName, isDirectory: true)
            .appendingPathComponent("mixed.lungfishref", isDirectory: true)
        let manifest = try BundleManifest.load(from: bundleURL)
        XCTAssertEqual(manifest.genome?.chromosomes.map(\.name), ["record1", "record2"])
        let recordStore = try XCTUnwrap(manifest.recordStore)
        XCTAssertEqual(try GenBankRecordDatabase(
            url: bundleURL.appendingPathComponent(recordStore.databasePath)
        ).recordCount(), 2)
        XCTAssertEqual(manifest.annotations.first?.featureCount, 1)
        XCTAssertEqual(Set(manifest.warnings.map(\.code)), [
            "invalid_feature_location", "malformed_record_field",
        ])
        let recordWarning = try XCTUnwrap(manifest.warnings.first { $0.recordFieldKey == "DBLINK" })
        XCTAssertEqual(recordWarning.category, "genbank.record-field.recovery")
        XCTAssertEqual(recordWarning.recordIdentifier, "record1")
        XCTAssertNotNil(recordWarning.lineNumber)
        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: bundleURL))
        guard case .array(let warningParameters)? = provenance.options.explicit["warnings"] else {
            return XCTFail("Expected structured provenance warnings")
        }
        XCTAssertEqual(warningParameters.count, 2)
        let warningText = String(decoding: try JSONEncoder().encode(provenance), as: UTF8.self)
        XCTAssertTrue(warningText.contains("DBLINK"))
        XCTAssertTrue(warningText.contains("record1"))
        XCTAssertFalse(warningText.contains("lungfish-cli-ref-import-"))
    }

    private func gzip(sourceURL: URL, destinationURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", sourceURL.path]

        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        try data.write(to: destinationURL, options: .atomic)
    }

    private static let smallAnnotatedGenBank = """
    LOCUS       MN908947                 120 bp    RNA     linear   VRL 01-JAN-2024
    DEFINITION  Minimal SARS-CoV-2 annotation fixture.
    ACCESSION   MN908947
    VERSION     MN908947.3
    FEATURES             Location/Qualifiers
         source          1..120
                         /organism="Severe acute respiratory syndrome coronavirus 2"
                         /mol_type="genomic RNA"
         gene            10..90
                         /gene="S"
                         /locus_tag="fixture-gene-S"
         CDS             20..80
                         /gene="S"
                         /product="spike glycoprotein"
                         /protein_id="fixture-protein-S"
         mat_peptide     35..55
                         /gene="S"
                         /product="mature spike peptide"
    ORIGIN
            1 atgcatgcat gcatgcatgc atgcatgcat gcatgcatgc atgcatgcat gcatgcatgc
           61 atgcatgcat gcatgcatgc atgcatgcat gcatgcatgc atgcatgcat gcatgcatgc
    //
    """

    private static let mixedValidityGenBank = """
    LOCUS       record1                  12 bp    DNA     linear   UNK 01-JAN-2024
    DEFINITION  First synthetic record.
    ACCESSION   record1
    VERSION     record1.1
    DBLINK      INSDC: OMITTED
               malformed continuation indentation
    FEATURES             Location/Qualifiers
         gene            1..6
                         /gene="valid"
    ORIGIN
            1 atgcatgcatgc
    //
    LOCUS       record2                  12 bp    DNA     linear   UNK 01-JAN-2024
    DEFINITION  Second synthetic record.
    ACCESSION   record2
    VERSION     record2.1
    FEATURES             Location/Qualifiers
         CDS             invalid..location
                         /product="skipped"
    ORIGIN
            1 atgcatgcatgc
    //
    """
}
