import ArgumentParser
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class ContainerAndCondaLockCommandTests: XCTestCase {
    func testBundleExportContainerHelpAndParse() throws {
        let help = BundleCommand.helpMessage()
        XCTAssertTrue(help.contains("export"))

        // Parsed from the real root so the program-wide `--format` (text, json,
        // tsv) cannot shadow the export option, which is why it is spelled
        // `--export-format`.
        let parsed = try LungfishCLI.parseAsRoot([
            "bundle",
            "export",
            "/tmp/example.lungfishref",
            "--export-format", "container",
            "--output", "/tmp/example.oci.tar",
            "--plugin-pack", "read-mapping",
        ])

        XCTAssertTrue(parsed is BundleExportSubcommand)
        XCTAssertEqual((parsed as? BundleExportSubcommand)?.format, .container)

        let exportHelp = BundleExportSubcommand.helpMessage()
        XCTAssertTrue(exportHelp.contains("--export-format"))
        XCTAssertTrue(exportHelp.contains("container"))
        XCTAssertFalse(exportHelp.contains("--format container"))
    }

    func testCondaLockAndInstallFromLockfileParse() throws {
        let help = CondaCommand.helpMessage()
        XCTAssertTrue(help.contains("lock"))
        XCTAssertTrue(help.contains("--from-lockfile"))

        let installHelp = CondaCommand.InstallSubcommand.helpMessage()
        XCTAssertTrue(installHelp.contains("--from-lockfile"))
        XCTAssertTrue(installHelp.contains("--conda-root"))

        let lock = try CondaCommand.parseAsRoot([
            "lock",
            "--pack", "read-mapping",
            "--output", "/tmp/read-mapping-lock.yml",
        ])
        XCTAssertTrue(lock is CondaCommand.LockSubcommand)

        let install = try CondaCommand.parseAsRoot([
            "install",
            "--from-lockfile", "/tmp/read-mapping-lock.yml",
            "--conda-root", "/tmp/custom-conda-root",
        ])
        XCTAssertTrue(install is CondaCommand.InstallSubcommand)
    }
}
