import XCTest
import LungfishIO
import LungfishWorkflow
@testable import LungfishCLI

final class PrimerCommandTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimerCommandTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testImportParsesBEDFASTAAndOutputOptions() throws {
        let command = try PrimerCommand.ImportSubcommand.parse([
            "--bed", "/tmp/panel.bed",
            "--fasta", "/tmp/panel.fasta",
            "--output", "panel.lungfishprimers",
            "--project", "/tmp/project.lungfish",
            "--reference-accession", "MN908947.3",
            "--display-name", "Panel",
            "--equivalent-accession", "NC_045512.2",
        ])

        XCTAssertEqual(command.bedPath, "/tmp/panel.bed")
        XCTAssertEqual(command.fastaPath, "/tmp/panel.fasta")
        XCTAssertEqual(command.outputPath, "panel.lungfishprimers")
        XCTAssertEqual(command.projectPath, "/tmp/project.lungfish")
        XCTAssertEqual(command.referenceAccession, "MN908947.3")
        XCTAssertEqual(command.displayName, "Panel")
        XCTAssertEqual(command.equivalentAccessions, ["NC_045512.2"])
    }

    func testImportCommandCreatesBundleEndToEnd() throws {
        let bedURL = try writeSampleBED()
        let fastaURL = try writeSampleFASTA()
        let projectURL = tempDir.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let command = try PrimerCommand.ImportSubcommand.parse([
            "--bed", bedURL.path,
            "--fasta", fastaURL.path,
            "--output", "panel.lungfishprimers",
            "--project", projectURL.path,
            "--reference-accession", "MN908947.3",
            "--display-name", "Panel",
        ])

        let result = try command.executeForTesting(argv: [
            "lungfish", "primers", "import",
            "--bed", bedURL.path,
            "--fasta", fastaURL.path,
            "--output", "panel.lungfishprimers",
            "--project", projectURL.path,
            "--reference-accession", "MN908947.3",
            "--display-name", "Panel",
        ])

        XCTAssertEqual(
            result.bundleURL.deletingLastPathComponent().lastPathComponent,
            "Primer Schemes"
        )
        let bundle = try PrimerSchemeBundle.load(from: result.bundleURL)
        XCTAssertEqual(bundle.manifest.displayName, "Panel")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: result.bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename).path
        ))
    }

    private func writeSampleBED() throws -> URL {
        let url = tempDir.appendingPathComponent("primers.bed")
        let content = """
            MN908947.3\t27\t51\tPanel_1_LEFT\t1\t+
            MN908947.3\t254\t276\tPanel_1_RIGHT\t1\t-
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
