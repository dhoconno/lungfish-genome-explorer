import ArgumentParser
import XCTest
@testable import LungfishCLI

final class ApplicationExportImportCommandTests: XCTestCase {
    func testImportCommandRegistersApplicationExportSubcommands() {
        let names = ImportCommand.configuration.subcommands.map { $0.configuration.commandName }

        XCTAssertTrue(names.contains("geneious"))
        XCTAssertTrue(names.contains("application-export"))
    }

    func testApplicationExportCommandParsesKindSourceProjectAndJSONFormat() throws {
        let command = try ImportCommand.ApplicationExportSubcommand.parse([
            "clc-workbench",
            "/tmp/CLC Export.zip",
            "--project", "/tmp/Project.lungfish",
            "--format", "json",
        ])

        XCTAssertEqual(command.kind, "clc-workbench")
        XCTAssertEqual(command.sourcePath, "/tmp/CLC Export.zip")
        XCTAssertEqual(command.projectPath, "/tmp/Project.lungfish")
        XCTAssertEqual(command.globalOptions.outputFormat, .json)
    }

    func testGeneiousCommandParsesSourceProjectAndJSONFormat() throws {
        let command = try ImportCommand.GeneiousSubcommand.parse([
            "/tmp/MCM_MHC_haplotypes-annotated.geneious",
            "--project", "/tmp/Project.lungfish",
            "--format", "json",
        ])

        XCTAssertEqual(command.sourcePath, "/tmp/MCM_MHC_haplotypes-annotated.geneious")
        XCTAssertEqual(command.projectPath, "/tmp/Project.lungfish")
        XCTAssertEqual(command.globalOptions.outputFormat, .json)
    }
}
