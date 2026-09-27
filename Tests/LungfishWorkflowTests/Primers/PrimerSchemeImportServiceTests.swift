import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class PrimerSchemeImportServiceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimerSchemeImportServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testImportWritesLoadableBundleAndReproducibilityProvenance() throws {
        let bedURL = try writeSampleBED()
        let fastaURL = try writeSampleFASTA()
        let projectURL = tempDir.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let argv = [
            "lungfish", "primers", "import",
            "--bed", bedURL.path,
            "--fasta", fastaURL.path,
            "--output", "custom-panel.lungfishprimers",
            "--project", projectURL.path,
            "--reference-accession", "MN908947.3",
        ]
        let result = try PrimerSchemeImportService.importBundle(
            request: PrimerSchemeImportRequest(
                bedURL: bedURL,
                fastaURL: fastaURL,
                attachments: [],
                outputURL: URL(fileURLWithPath: "custom-panel.lungfishprimers"),
                projectURL: projectURL,
                displayName: "Custom Panel",
                canonicalAccession: "MN908947.3",
                equivalentAccessions: [],
                argv: argv,
                workflowName: "lungfish primers import",
                toolVersion: "test"
            )
        )

        XCTAssertEqual(
            result.bundleURL.deletingLastPathComponent().lastPathComponent,
            "Primer Schemes"
        )
        let bundle = try PrimerSchemeBundle.load(from: result.bundleURL)
        XCTAssertEqual(bundle.manifest.name, "custom-panel")
        XCTAssertEqual(bundle.manifest.displayName, "Custom Panel")
        XCTAssertEqual(bundle.manifest.primerCount, 4)
        XCTAssertEqual(bundle.manifest.ampliconCount, 2)
        XCTAssertNotNil(bundle.fastaURL)

        let provenanceURL = result.bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let provenance = try XCTUnwrap(ProvenanceRecorder.load(from: result.bundleURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: provenanceURL.path))
        XCTAssertEqual(provenance.name, "lungfish primers import")
        XCTAssertEqual(provenance.status.rawValue, RunStatus.completed.rawValue)
        XCTAssertEqual(provenance.steps.single?.toolName, "lungfish primers import")
        XCTAssertEqual(provenance.steps.single?.toolVersion, "test")
        XCTAssertEqual(provenance.steps.single?.command, argv)
        XCTAssertEqual(provenance.steps.single?.exitCode, 0)
        XCTAssertNotNil(provenance.steps.single?.wallTime)
        XCTAssertEqual(provenance.parameters["referenceAccession"]?.stringValue, "MN908947.3")
        XCTAssertEqual(provenance.parameters["fastaIncluded"]?.booleanValue, true)
        let step = try XCTUnwrap(provenance.steps.single)
        let recordsBEDInput = step.inputs.contains { record in
            record.path == bedURL.path && record.sha256 != nil && record.sizeBytes != nil
        }
        XCTAssertTrue(recordsBEDInput)
        let outputBEDPath = result.bundleURL.appendingPathComponent("primers.bed").path
        let recordsBEDOutput = step.outputs.contains { record in
            record.path == outputBEDPath && record.sha256 != nil && record.sizeBytes != nil
        }
        XCTAssertTrue(recordsBEDOutput)
    }

    func testAmpliconCountFoldsNumberedAndAltSparePrimersIntoTheirAmplicon() throws {
        let url = tempDir.appendingPathComponent("designed.bed")
        let content = """
            ref\t209\t232\td01afd1e_1_LEFT_1\t1\t+\tACT
            ref\t207\t232\td01afd1e_1_LEFT_2\t1\t+\tCCA
            ref\t600\t622\td01afd1e_1_RIGHT_1\t1\t-\tGGT
            ref\t650\t672\tnCoV-2019_2_LEFT\t2\t+\tGGT
            ref\t655\t677\tnCoV-2019_2_LEFT_alt1\t2\t+\tGGT
            ref\t900\t922\tnCoV-2019_2_RIGHT\t2\t-\tGGT
            ref\t950\t972\tQIAseq_3_LEFT\t1\t+\tGGT
            ref\t955\t977\tQIAseq_3-2_LEFT\t1\t+\tGGT
            ref\t1200\t1222\tQIAseq_3_RIGHT\t1\t-\tGGT
            ref\t1300\t1322\tqpcr_4_PROBE_1\t1\t+\tGGT
            """
        try content.write(to: url, atomically: true, encoding: .utf8)
        let counts = try PrimerSchemeImportService.parseCounts(bedURL: url)
        XCTAssertEqual(counts.primerCount, 10)
        XCTAssertEqual(counts.ampliconCount, 4)
    }

    private func writeSampleBED() throws -> URL {
        let url = tempDir.appendingPathComponent("primers.bed")
        let content = """
            MN908947.3\t27\t51\tPanel_1_LEFT\t1\t+
            MN908947.3\t254\t276\tPanel_1_RIGHT\t1\t-
            MN908947.3\t404\t426\tPanel_2_LEFT\t2\t+
            MN908947.3\t612\t634\tPanel_2_RIGHT\t2\t-
            """
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeSampleFASTA() throws -> URL {
        let url = tempDir.appendingPathComponent("primers.fasta")
        try ">Panel_1_LEFT\nACGT\n>Panel_1_RIGHT\nTGCA\n".write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
        return url
    }
}

private extension Array {
    var single: Element? {
        count == 1 ? self[0] : nil
    }
}
