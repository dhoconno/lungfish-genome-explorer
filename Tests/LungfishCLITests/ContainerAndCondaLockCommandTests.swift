import ArgumentParser
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class ContainerAndCondaLockCommandTests: XCTestCase {
    func testBundleExportContainerHelpAndParse() throws {
        let help = BundleCommand.helpMessage()
        XCTAssertTrue(help.contains("export"))

        let parsed = try BundleCommand.parseAsRoot([
            "export",
            "/tmp/example.lungfishref",
            "--format", "container",
            "--output", "/tmp/example.oci.tar",
            "--plugin-pack", "read-mapping",
        ])

        XCTAssertTrue(parsed is BundleExportSubcommand)
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
