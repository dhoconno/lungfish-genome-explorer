import ArgumentParser
import XCTest
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishIO

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

        let annotation: AnnotationTrackInfo = try XCTUnwrap(manifest.annotations.first)
        XCTAssertEqual(annotation.id, "imported_annotations")
        XCTAssertEqual(annotation.databasePath, "annotations/imported_annotations.db")
        XCTAssertEqual(annotation.path, "annotations/imported_annotations.gff3")
        XCTAssertEqual(annotation.featureCount, 3)

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
        XCTAssertEqual(commandLine.first, "lungfish")
        XCTAssertTrue(commandLine.contains("import"))
        XCTAssertTrue(commandLine.contains("fasta"))
        XCTAssertTrue(commandLine.contains(inputURL.path))

        let outputs = try XCTUnwrap(importStep["outputs"] as? [[String: Any]])
        XCTAssertTrue(outputs.contains {
            ($0["path"] as? String)?.hasSuffix("annotations/imported_annotations.gff3") == true
        })
        XCTAssertFalse(outputs.contains {
            ($0["path"] as? String)?.contains("/.tmp/") == true
        })
        XCTAssertTrue(outputs.allSatisfy {
            $0["sha256"] != nil && $0["sizeBytes"] != nil
        })
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
}
