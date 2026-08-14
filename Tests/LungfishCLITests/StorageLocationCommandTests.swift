import ArgumentParser
import XCTest
import Darwin
@testable import LungfishCLI
@testable import LungfishWorkflow

final class StorageLocationCommandTests: XCTestCase {
    func testProvisionToolsStatusReportsConfiguredStorageRoot() async throws {
        let orchestrator = ToolProvisioningOrchestrator()
        let expectedOutputDirectory = await orchestrator.getOutputDirectory()

        let output = try await captureStandardOutput {
            var command = try ProvisionToolsCommand.parse(["--status"])
            try await command.run()
        }

        XCTAssertTrue(output.contains(expectedOutputDirectory.path), "Expected status output to mention \(expectedOutputDirectory.path), got: \(output)")
    }

    func testCondaHelpMentionsConfiguredStorageRoot() throws {
        let root = URL(fileURLWithPath: "/Volumes/Lungfish SSD/custom-storage-root", isDirectory: true)
        let originalOverride = CondaCommand.storageRootOverride
        CondaCommand.storageRootOverride = root
        defer { CondaCommand.storageRootOverride = originalOverride }

        let help = CondaCommand.helpMessage()

        XCTAssertTrue(help.contains(root.path), "Expected conda help to mention \(root.path), got: \(help)")
        XCTAssertFalse(help.contains("Application Support/Lungfish/conda"))
    }

    func testCondaPackInstallSurfacesStorageUnavailableError() async throws {
        let root = URL(fileURLWithPath: "/Volumes/Lungfish SSD/conda", isDirectory: true)
        let originalOverride = CondaCommand.packStatusServiceOverride
        CondaCommand.packStatusServiceOverride = StorageUnavailablePackStatusService(root: root)
        defer { CondaCommand.packStatusServiceOverride = originalOverride }

        guard let packID = CondaCommand.visiblePacksForTesting().first?.id else {
            throw XCTSkip("No visible CLI packs available")
        }

        let command = try CondaCommand.InstallSubcommand.parse(["--pack", packID])

        do {
            try await command.run()
            XCTFail("Expected storage unavailable error")
        } catch let error as ArgumentParser.ValidationError {
            XCTAssertTrue(error.description.contains("Storage location unavailable"))
            XCTAssertTrue(error.description.contains(root.path))
        }
    }

    func testCondaPackInstallSurfacesAuthoritativeVerificationFailure() async throws {
        let originalOverride = CondaCommand.packStatusServiceOverride
        CondaCommand.packStatusServiceOverride = VerificationFailedPackStatusService()
        defer { CondaCommand.packStatusServiceOverride = originalOverride }
        let packID = try XCTUnwrap(CondaCommand.visiblePacksForTesting().first?.id)
        let command = try CondaCommand.InstallSubcommand.parse(["--pack", packID])

        do {
            try await command.run()
            XCTFail("Expected authoritative verification failure")
        } catch let code as ExitCode {
            XCTAssertEqual(code.rawValue, CLIExitCode.dependency.rawValue)
        }
    }

    private func captureStandardOutput(_ operation: () async throws -> Void) async throws -> String {
        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

        do {
            try await operation()
            fflush(stdout)
        } catch {
            fflush(stdout)
            dup2(originalStdout, STDOUT_FILENO)
            close(originalStdout)
            pipe.fileHandleForWriting.closeFile()
            throw error
        }

        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        pipe.fileHandleForWriting.closeFile()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private actor StorageUnavailablePackStatusService: PluginPackStatusProviding {
    let root: URL

    init(root: URL) {
        self.root = root
    }

    func visibleStatuses() async -> [PluginPackStatus] { [] }

    func status(for pack: PluginPack) async -> PluginPackStatus {
        PluginPackStatus(pack: pack, state: .failed, toolStatuses: [], failureMessage: nil)
    }

    func invalidateVisibleStatusesCache() async {}

    func install(
        pack: PluginPack,
        reinstall: Bool,
        progress: (@Sendable (PluginPackInstallProgress) -> Void)?
    ) async throws {
        throw PluginPackStatusServiceError.storageUnavailable(root)
    }
}

private actor VerificationFailedPackStatusService: PluginPackStatusProviding {
    func visibleStatuses() async -> [PluginPackStatus] { [] }

    func status(for pack: PluginPack) async -> PluginPackStatus {
        PluginPackStatus(pack: pack, state: .needsInstall, toolStatuses: [], failureMessage: "Bracken metadata missing")
    }

    func invalidateVisibleStatusesCache() async {}

    func install(
        pack: PluginPack,
        reinstall: Bool,
        progress: (@Sendable (PluginPackInstallProgress) -> Void)?
    ) async throws {
        throw PluginPackStatusServiceError.verificationFailed(
            requirementID: "bracken",
            reason: "Managed Bracken source metadata is missing or does not match version 3.1"
        )
    }
}
