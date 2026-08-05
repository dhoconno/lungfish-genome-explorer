import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

@MainActor
final class SavontRuntimePreflightTests: XCTestCase {
    func testMissingManagedRuntimeKeepsRunDisabledAndExplainsInstallation() async throws {
        let provider = SavontRuntimeStatusProviderStub(
            status: try makePackStatus(
                state: .needsInstall,
                environmentExists: false,
                missingExecutables: ["savont"],
                smokeTestFailure: nil
            )
        )
        let state = makeSavontState(statusProvider: provider)

        XCTAssertFalse(state.isRunEnabled)
        XCTAssertEqual(state.readinessText, "Checking the managed Savont runtime…")

        await state.refreshSavontRuntimeReadiness()

        XCTAssertFalse(state.isRunEnabled)
        XCTAssertEqual(
            state.readinessText,
            "Install the Full-length MHC Genotyping pack in Plugin Manager to run Savont."
        )
        state.prepareForRun()
        XCTAssertNil(state.pendingLaunchRequest)
    }

    func testDamagedManagedRuntimeKeepsRunDisabledAndExplainsRepair() async throws {
        let provider = SavontRuntimeStatusProviderStub(
            status: try makePackStatus(
                state: .failed,
                environmentExists: true,
                missingExecutables: ["savont"],
                smokeTestFailure: nil
            )
        )
        let state = makeSavontState(statusProvider: provider)

        await state.refreshSavontRuntimeReadiness()

        XCTAssertFalse(state.isRunEnabled)
        XCTAssertEqual(
            state.readinessText,
            "Repair the Full-length MHC Genotyping pack in Plugin Manager to restore Savont."
        )
        state.prepareForRun()
        XCTAssertNil(state.pendingLaunchRequest)
    }

    func testMissingManagedBootstrapBlocksRunEvenWhenSavontExecutableLooksHealthy() async throws {
        let provider = SavontRuntimeStatusProviderStub(
            status: try makePackStatus(
                state: .needsInstall,
                environmentExists: true,
                missingExecutables: [],
                smokeTestFailure: nil
            )
        )
        let state = makeSavontState(statusProvider: provider)

        await state.refreshSavontRuntimeReadiness()

        XCTAssertFalse(state.isRunEnabled)
        XCTAssertEqual(
            state.readinessText,
            "Install the Full-length MHC Genotyping pack in Plugin Manager to run Savont."
        )
        state.prepareForRun()
        XCTAssertNil(state.pendingLaunchRequest)
    }

    func testHealthyManagedRuntimeEnablesRunAfterAsynchronousCheck() async throws {
        let provider = SavontRuntimeStatusProviderStub(
            status: try makePackStatus(
                state: .ready,
                environmentExists: true,
                missingExecutables: [],
                smokeTestFailure: nil
            )
        )
        let state = makeSavontState(statusProvider: provider)

        XCTAssertFalse(state.isRunEnabled)
        await state.refreshSavontRuntimeReadiness()

        XCTAssertTrue(state.isRunEnabled)
        XCTAssertEqual(state.readinessText, "Output is fixed for this tool.")
        state.prepareForRun()
        guard case .savont? = state.pendingLaunchRequest else {
            return XCTFail("Expected a Savont launch request after the managed runtime is ready")
        }
    }

    func testEditingSavontOptionsDoesNotRepeatRuntimeCheck() async throws {
        let provider = SavontRuntimeStatusProviderStub(
            status: try makePackStatus(
                state: .ready,
                environmentExists: true,
                missingExecutables: [],
                smokeTestFailure: nil
            )
        )
        let state = makeSavontState(statusProvider: provider)

        await state.refreshSavontRuntimeReadiness()
        state.savontThreads = 2
        state.savontQualityValueCutoff = 95
        state.savontMinimumClusterSize = 4

        XCTAssertTrue(state.isRunEnabled)
        let requestCount = await provider.currentStatusRequestCount()
        XCTAssertEqual(requestCount, 1)
    }

    private func makeSavontState(
        statusProvider: any PluginPackStatusProviding
    ) -> FASTQOperationDialogState {
        let state = FASTQOperationDialogState(
            initialCategory: .clustering,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/barcode12.fastq")],
            projectURL: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
            workflowLibrary: SavontEnabledWorkflowLibrary(),
            savontRuntimeStatusProvider: statusProvider
        )
        state.selectTool(.savont)
        return state
    }

    private func makePackStatus(
        state: PluginPackState,
        environmentExists: Bool,
        missingExecutables: [String],
        smokeTestFailure: String?
    ) throws -> PluginPackStatus {
        let pack = try XCTUnwrap(PluginPack.builtInPack(id: "full-length-mhc-genotyping"))
        let requirement = try XCTUnwrap(pack.toolRequirements.first { $0.id == "savont" })
        return PluginPackStatus(
            pack: pack,
            state: state,
            toolStatuses: [
                PackToolStatus(
                    requirement: requirement,
                    environmentExists: environmentExists,
                    missingExecutables: missingExecutables,
                    smokeTestFailure: smokeTestFailure,
                    storageUnavailablePath: nil
                ),
            ],
            failureMessage: nil
        )
    }
}

@MainActor
private final class SavontEnabledWorkflowLibrary: WorkflowLibraryEnabling {
    func isWorkflowEnabled(_ toolID: FASTQOperationToolID) -> Bool { true }
}

private actor SavontRuntimeStatusProviderStub: PluginPackStatusProviding {
    private let statusValue: PluginPackStatus?
    private(set) var statusRequestCount = 0

    init(status: PluginPackStatus?) {
        self.statusValue = status
    }

    func visibleStatuses() async -> [PluginPackStatus] {
        statusValue.map { [$0] } ?? []
    }

    func status(for pack: PluginPack) async -> PluginPackStatus {
        statusValue ?? PluginPackStatus(
            pack: pack,
            state: .needsInstall,
            toolStatuses: [],
            failureMessage: nil
        )
    }

    func status(forPackID packID: String) async -> PluginPackStatus? {
        statusRequestCount += 1
        return statusValue
    }

    func currentStatusRequestCount() -> Int {
        statusRequestCount
    }

    func invalidateVisibleStatusesCache() async {}

    func install(
        pack: PluginPack,
        reinstall: Bool,
        progress: (@Sendable (PluginPackInstallProgress) -> Void)?
    ) async throws {}
}
