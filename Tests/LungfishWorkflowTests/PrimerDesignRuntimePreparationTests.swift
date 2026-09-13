import Foundation
import XCTest
@testable import LungfishWorkflow

final class PrimerDesignRuntimePreparationTests: XCTestCase {
    func testReadySelectedEngineDoesNotInstallMissingOtherEngine() async throws {
        let provider = RuntimeStatusFixture(selectedReady: true)
        try await PrimerDesignManagedRuntime.prepare(toolID: "primalscheme3", statusProvider: provider)
        let installs = await provider.installs
        XCTAssertEqual(installs, [])
    }

    func testStaleRuntimeUsesNormalPackRepairAndRechecksReadiness() async throws {
        let provider = RuntimeStatusFixture(selectedReady: false)
        try await PrimerDesignManagedRuntime.prepare(toolID: "primalscheme3", statusProvider: provider)
        let installs = await provider.installs
        XCTAssertEqual(installs, [false], "Selected-tool install repairs the stale requirement")
        let checks = await provider.checks
        XCTAssertGreaterThanOrEqual(checks, 2)
    }

    func testRepairFailureAndUnhealthyResultCannotBecomeReady() async {
        for mode in [RuntimeStatusFixture.Mode.fail, .remainUnhealthy] {
            let provider = RuntimeStatusFixture(selectedReady: false, mode: mode)
            do {
                try await PrimerDesignManagedRuntime.prepare(toolID: "primalscheme3", statusProvider: provider)
                XCTFail("An unsuccessful repair must prevent scientific execution")
            } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
    }

    func testMissingRequirementAndUnavailableStorageDoNotAttemptInstall() async {
        for mode in [RuntimeStatusFixture.Mode.missing, .storageUnavailable] {
            let provider = RuntimeStatusFixture(selectedReady: false, mode: mode)
            do {
                try await PrimerDesignManagedRuntime.prepare(toolID: "primalscheme3", statusProvider: provider)
                XCTFail("Expected readiness failure")
            } catch { }
            let installs = await provider.installs
            XCTAssertTrue(installs.isEmpty)
        }
    }

    func testRepairCancellationPropagates() async {
        let provider = RuntimeStatusFixture(selectedReady: false, mode: .cancel)
        do {
            try await PrimerDesignManagedRuntime.prepare(toolID: "primalscheme3", statusProvider: provider)
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testWaitingForEnvironmentCanBeCancelledWithoutReleasingActiveRun() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let held = try CondaEnvironmentMutationLock.acquire(root: root, environment: "primalscheme3")
        defer { held.release() }
        let waiting = AsyncStream<Void>.makeStream()
        let cancelled = expectation(description: "Cancelled while the other operation still owns its environment")
        let task = Task {
            defer { waiting.continuation.finish() }
            do {
                let lock = try await CondaEnvironmentMutationLock.acquireCancellable(root: root, environment: "primalscheme3", waitMessageWriter: { _ in waiting.continuation.yield(()) })
                lock.release()
                XCTFail("Waiting acquisition should have been cancelled")
            } catch {
                XCTAssertTrue(error is CancellationError)
                cancelled.fulfill()
            }
        }
        for await _ in waiting.stream { break }
        task.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        held.release()
        await task.value
        let subsequent = try await CondaEnvironmentMutationLock.acquireCancellable(root: root, environment: "primalscheme3")
        subsequent.release()
    }
}

private actor RuntimeStatusFixture: PluginPackStatusProviding {
    enum Mode { case repair, fail, remainUnhealthy, missing, storageUnavailable, cancel }
    var selectedReady: Bool
    let mode: Mode
    var installs: [Bool] = []
    var checks = 0
    init(selectedReady: Bool, mode: Mode = .repair) { self.selectedReady = selectedReady; self.mode = mode }
    func visibleStatuses() async -> [PluginPackStatus] { [] }
    func invalidateVisibleStatusesCache() async { }
    func status(for pack: PluginPack) async -> PluginPackStatus {
        checks += 1
        let statuses = pack.toolRequirements.filter { mode != .missing || $0.id != "primalscheme3" }.map { requirement in
            let ready = requirement.id == "primalscheme3" && selectedReady
            return PackToolStatus(requirement: requirement, environmentExists: true, missingExecutables: [],
                smokeTestFailure: ready ? nil : "Installed runtime does not match the required version",
                storageUnavailablePath: mode == .storageUnavailable ? "/unavailable" : nil)
        }
        return PluginPackStatus(pack: pack, state: .needsInstall, toolStatuses: statuses, failureMessage: nil)
    }
    func install(pack: PluginPack, requirementIDs: Set<String>, progress: (@Sendable (PluginPackInstallProgress) -> Void)?) async throws {
        XCTAssertEqual(requirementIDs, ["primalscheme3"])
        try await install(pack: pack, reinstall: false, progress: progress)
    }
    func install(pack: PluginPack, reinstall: Bool, progress: (@Sendable (PluginPackInstallProgress) -> Void)?) async throws {
        installs.append(reinstall)
        if mode == .cancel { throw CancellationError() }
        if mode == .fail { throw CocoaError(.fileWriteNoPermission) }
        if mode == .repair { selectedReady = true }
    }
}
