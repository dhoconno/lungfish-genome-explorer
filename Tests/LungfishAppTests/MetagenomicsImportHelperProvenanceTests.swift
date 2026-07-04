import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

final class MetagenomicsImportHelperProvenanceTests: XCTestCase {
    func testHelperBuildsCanonicalKraken2ProvenanceCommand() {
        let input = URL(fileURLWithPath: "/project/imports/sample.kreport")
        let output = URL(fileURLWithPath: "/project/Imports", isDirectory: true)
        let secondary = URL(fileURLWithPath: "/project/imports/sample.kraken")

        let command = MetagenomicsImportHelper.canonicalProvenanceCommand(
            kind: .kraken2,
            inputURL: input,
            outputDirectory: output,
            secondaryInputURL: secondary,
            preferredName: "Sample Kraken",
            fetchReferences: true
        )

        XCTAssertEqual(command, [
            "lungfish-cli",
            "import",
            "kraken2",
            input.path,
            "--output-dir",
            output.path,
            "--output",
            secondary.path,
            "--name",
            "Sample Kraken",
        ])
    }

    func testHelperBuildsCanonicalNaoMgsProvenanceCommand() {
        let input = URL(fileURLWithPath: "/project/naomgs/virus_hits_final.tsv")
        let output = URL(fileURLWithPath: "/project/Analyses", isDirectory: true)

        let command = MetagenomicsImportHelper.canonicalProvenanceCommand(
            kind: .naomgs,
            inputURL: input,
            outputDirectory: output,
            secondaryInputURL: nil,
            preferredName: "SAMPLE_A",
            fetchReferences: false
        )

        XCTAssertEqual(command, [
            "lungfish-cli",
            "import",
            "nao-mgs",
            input.path,
            "--output-dir",
            output.path,
            "--sample-name",
            "SAMPLE_A",
            "--no-fetch-references",
        ])
    }

    func testHelperBuildsCanonicalNvdProvenanceCommand() {
        let input = URL(fileURLWithPath: "/project/nvd-run", isDirectory: true)
        let output = URL(fileURLWithPath: "/project/Imports", isDirectory: true)

        let command = MetagenomicsImportHelper.canonicalProvenanceCommand(
            kind: .nvd,
            inputURL: input,
            outputDirectory: output,
            secondaryInputURL: nil,
            preferredName: "nvd-beta",
            fetchReferences: true
        )

        XCTAssertEqual(command, [
            "lungfish-cli",
            "import",
            "nvd",
            input.path,
            "--output-dir",
            output.path,
            "--name",
            "nvd-beta",
        ])
    }

    func testHelperDoesNotUsePrivateHelperArgumentsAsProvenanceCommand() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/App/MetagenomicsImportHelper.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("provenanceCommand: arguments"))
        XCTAssertTrue(source.contains("provenanceCommand: provenanceCommand"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
