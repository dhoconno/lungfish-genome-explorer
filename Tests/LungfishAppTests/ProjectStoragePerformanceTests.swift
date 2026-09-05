import AppKit
import CryptoKit
import Darwin
import Foundation
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishApp

@MainActor
final class ProjectStoragePerformanceTests: XCTestCase {
    func testProjectOpenDoesNotInvokeAutomaticStorageCleanup()
        async throws
    {
        let context = try makeOpenFixture()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let delegate = makeAppDelegateWithTemporaryState()
        let calls = LockedCounter()
        delegate.projectStorageAutomaticCleanupRunner = { _ in
            calls.increment()
            return .init(
                state: .noEligibleEntries,
                scannedEntryCount: 0,
                selectedEntryCount: 0,
                warnings: [],
                summaryURL: nil,
                provenanceURL: nil
            )
        }
        let controller = MainWindowController(
            projectSession: ProjectSession()
        )
        defer { controller.close() }

        delegate.openProject(context.fixture.projectURL, in: controller)
        await delegate.testingWaitForProjectOpen(in: controller)
        XCTAssertEqual(calls.value, 0)
        await oneMainRunLoopTurn()
        XCTAssertEqual(calls.value, 0)
    }

    func testProjectOpenLeavesStorageFixtureUnchanged() async throws {
        let context = try makeOpenFixture()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let before = try StorageFixtureSnapshot.capture(
            root: context.fixture.projectURL
        )
        let delegate = makeAppDelegateWithTemporaryState()
        let controller = MainWindowController(
            projectSession: ProjectSession()
        )
        defer { controller.close() }

        delegate.openProject(context.fixture.projectURL, in: controller)
        await delegate.testingWaitForProjectOpen(in: controller)
        await oneMainRunLoopTurn()

        let after = try StorageFixtureSnapshot.capture(
            root: context.fixture.projectURL
        )
        let beforePaths = Set(before.entries.map(\.relativePath))
        let afterPaths = Set(after.entries.map(\.relativePath))
        XCTAssertTrue(
            afterPaths == beforePaths,
            "Added: \(Array(afterPaths.subtracting(beforePaths).sorted().prefix(20))); "
                + "removed: \(Array(beforePaths.subtracting(afterPaths).sorted().prefix(20)))"
        )
        let beforeByPath = Dictionary(
            uniqueKeysWithValues: before.entries.map {
                ($0.relativePath, $0)
            }
        )
        let changed = after.entries.compactMap { entry in
            beforeByPath[entry.relativePath] == entry
                ? nil
                : entry.relativePath
        }
        XCTAssertTrue(
            changed.isEmpty,
            "Project open changed fixture entries: "
                + "\(Array(changed.prefix(20)))"
        )
    }

    func testDefaultScanAuthorityAndCleanupPreparationWorkersRunOffMainThread()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProjectStorageWorkerTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try DocumentManager.shared.createProject(
            at: root.appendingPathComponent(
                "Workers.lungfish",
                isDirectory: true
            ),
            name: "Workers"
        )
        let candidate = try makeSmallOwnedCandidate(
            projectURL: project.url
        )
        let projectIdentity = try FileSystemObjectIdentity.noFollow(
            project.url
        )
        let observations = WorkerPhaseRecorder()
        let cleanupBarrier = BlockingWorkerBarrier()
        let cancellation = AsyncSignal()
        let executorGuard = LockedFlag()
        let operations = ProjectStorageCoordinator.Operations.production(
            workerObserver: { phase in
                observations.record(
                    phase: phase,
                    isMainThread: Darwin.pthread_main_np() != 0
                )
                if phase == .cleanupPreparation {
                    cleanupBarrier.reachAndBlock()
                }
            },
            cancellationPropagationObserver: {
                cancellation.signal()
            },
            beforeExecutorGuard: {
                executorGuard.set()
                throw StorageScanFailure.expected
            }
        )
        let session = ProjectSession()
        try session.openProject(at: project.url)
        let controller = MainWindowController(projectSession: session)
        defer { controller.close() }
        let coordinator = ProjectStorageCoordinator(
            presentingWindow: try XCTUnwrap(controller.window),
            controller: controller,
            projectURL: project.url,
            projectIdentity: projectIdentity,
            generation: 0,
            generationProvider: { 0 },
            operations: operations,
            completion: {}
        )

        XCTAssertTrue(coordinator.present())
        while coordinator.viewModel.state == .scanning {
            await Task.yield()
        }
        XCTAssertEqual(coordinator.viewModel.state, .ready)
        let selected = try XCTUnwrap(
            coordinator.viewModel.entries.first {
                $0.classification.isRemovable
            }
        )
        XCTAssertEqual(
            selected.identity,
            try FileSystemObjectIdentity.noFollow(candidate)
        )
        XCTAssertTrue(
            coordinator.viewModel.canCleanup,
            coordinator.viewModel.cleanupDisabledReason ?? "disabled"
        )
        let before = try StorageFixtureSnapshot.capture(root: project.url)

        coordinator.viewModel.beginCleanup()
        guard await cleanupBarrier.waitUntilReached(timeout: 5) else {
            return XCTFail(
                "Cleanup preparation did not reach its barrier; "
                    + "state=\(coordinator.viewModel.state), "
                    + "observations=\(observations.snapshot)"
            )
        }
        XCTAssertTrue(coordinator.viewModel.handleEscapeKey())
        guard await cancellation.wait(timeout: 5) else {
            cleanupBarrier.release()
            return XCTFail(
                "Cancellation did not propagate to the detached worker"
            )
        }
        cleanupBarrier.release()
        while coordinator.viewModel.state == .cleaning {
            await Task.yield()
        }

        let snapshot = observations.snapshot
        for phase in [
            ProjectStorageWorkerPhase
                .authorityCanonicalizationAndIdentity,
            .scanTraversal,
            .cleanupPreparation,
        ] {
            let phaseObservations = snapshot.filter {
                $0.phase == phase
            }
            XCTAssertFalse(
                phaseObservations.isEmpty,
                "No observation for \(phase)"
            )
            XCTAssertTrue(
                phaseObservations.allSatisfy { !$0.isMainThread },
                "\(phase) ran on the main thread"
            )
        }
        XCTAssertFalse(executorGuard.value)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: candidate.path)
        )
        XCTAssertEqual(
            try StorageFixtureSnapshot.capture(root: project.url),
            before
        )
        let cleanupCollection = project.url
            .appendingPathComponent(
                ProjectOperationHistoryWriter.historyDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent(
                "storage-cleanups",
                isDirectory: true
            )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: cleanupCollection.path
            )
        )
        XCTAssertFalse(
            try containsQuarantinePath(projectURL: project.url)
        )
        coordinator.invalidate()

        let authorityBarrier = BlockingWorkerBarrier()
        let authorityCancellation = AsyncSignal()
        let authorityOperations =
            ProjectStorageCoordinator.Operations.production(
                workerObserver: { phase in
                    if phase
                        == .authorityCanonicalizationAndIdentity {
                        authorityBarrier.reachAndBlock()
                    }
                },
                cancellationPropagationObserver: {
                    authorityCancellation.signal()
                }
            )
        let authoritySession = ProjectSession()
        try authoritySession.openProject(at: project.url)
        let authorityController = MainWindowController(
            projectSession: authoritySession
        )
        defer { authorityController.close() }
        let authorityCoordinator = ProjectStorageCoordinator(
            presentingWindow: try XCTUnwrap(authorityController.window),
            controller: authorityController,
            projectURL: project.url,
            projectIdentity: projectIdentity,
            generation: 0,
            generationProvider: { 0 },
            operations: authorityOperations,
            completion: {}
        )
        XCTAssertTrue(authorityCoordinator.present())
        guard await authorityBarrier.waitUntilReached(timeout: 5) else {
            return XCTFail("Authority worker did not reach its barrier")
        }
        XCTAssertTrue(
            authorityCoordinator.viewModel.handleEscapeKey()
        )
        guard await authorityCancellation.wait(timeout: 5) else {
            authorityBarrier.release()
            return XCTFail(
                "Authority-worker cancellation did not propagate"
            )
        }
        authorityBarrier.release()
        while authorityCoordinator.viewModel.state == .scanning {
            await Task.yield()
        }
        XCTAssertEqual(
            try StorageFixtureSnapshot.capture(root: project.url),
            before
        )
        authorityCoordinator.invalidate()
    }

    func testProgressRelayBoundsMainActorDeliveryCountWithInjectedClock()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProjectStorageRelayTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try DocumentManager.shared.createProject(
            at: root.appendingPathComponent(
                "Relay.lungfish",
                isDirectory: true
            ),
            name: "Relay"
        )
        let projectIdentity = try FileSystemObjectIdentity.noFollow(
            project.url
        )
        let clock = VirtualStorageClock()
        let events = MainActorCommitEventRecorder()
        let operations = ProjectStorageCoordinator.Operations(
            scan: { _, progress in
                for index in 0...100 {
                    progress(
                        .init(
                            visitedFileSystemObjects: UInt64(index),
                            classifiedEntries: UInt64(index),
                            logicalBytes: UInt64(index),
                            allocatedBytes: UInt64(index),
                            currentRelativePath: "item-\(index)"
                        )
                    )
                }
                return .init(
                    projectIdentity: projectIdentity,
                    entries: []
                )
            },
            instrumentation: .init(record: events.record),
            progressUptime: clock.next
        )
        let session = ProjectSession()
        try session.openProject(at: project.url)
        let controller = MainWindowController(projectSession: session)
        defer { controller.close() }
        let coordinator = ProjectStorageCoordinator(
            presentingWindow: try XCTUnwrap(controller.window),
            controller: controller,
            projectURL: project.url,
            projectIdentity: projectIdentity,
            generation: 0,
            generationProvider: { 0 },
            operations: operations,
            completion: {}
        )

        XCTAssertTrue(coordinator.present())
        while coordinator.viewModel.state == .scanning {
            await Task.yield()
        }

        let commits = events.snapshot.filter {
            guard case .counted(
                .mainActorCommits,
                1,
                intervalID: _
            ) = $0 else {
                return false
            }
            return true
        }.count
        XCTAssertGreaterThanOrEqual(commits, 2)
        XCTAssertLessThanOrEqual(
            commits,
            12,
            "At most the first progress delivery, ten 100 ms "
                + "deliveries, and one terminal commit are allowed"
        )
        XCTAssertEqual(coordinator.viewModel.state, .ready)
        coordinator.invalidate()
    }

    func testLargePreviewMaximumMainThreadStallIsUnder100Milliseconds()
        async throws
    {
        guard let mode = ProcessInfo.processInfo.environment[
            "LUNGFISH_RUN_STORAGE_PERF"
        ] else {
            throw XCTSkip(
                "storage-perf-disabled: LUNGFISH_RUN_STORAGE_PERF is absent"
            )
        }
        guard mode == "timing" else {
            throw StorageTimingConfigurationError.invalidMode(mode)
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProjectStorageTimingTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try DocumentManager.shared.createProject(
            at: root.appendingPathComponent(
                "Timing.lungfish",
                isDirectory: true
            ),
            name: "Timing"
        )
        let fixture = try ProjectStorageLargeTreeFixture.createBaseTree(
            profile: .releaseRepresentative,
            at: project.url
        )
        do {
            try fixture.installHardLinkOverlay()
        } catch let error as ProjectStorageHardLinkUnavailableError {
            throw XCTSkip(
                "storage-perf-incomplete: link errno=\(error.code) "
                    + "(\(hardLinkSymbol(error.code)))"
            )
        }

        let preflight = try await measureHeartbeat(
            duration: 2,
            terminalOperation: {}
        )
        guard preflight.maximumDelayNanoseconds < 20_000_000 else {
            throw XCTSkip(
                "storage-perf-inconclusive: idle-preflight-max-ns="
                    + "\(preflight.maximumDelayNanoseconds)"
            )
        }

        let projectIdentity = try FileSystemObjectIdentity.noFollow(
            project.url
        )
        var maximumDelay: UInt64 = 0
        for trial in 1...5 {
            let heartbeat = MainQueueHeartbeat(cadenceNanoseconds: 10_000_000)
            try await armHeartbeatOrSkip(heartbeat)
            let session = ProjectSession()
            try session.openProject(at: project.url)
            let controller = MainWindowController(projectSession: session)
            let coordinator = ProjectStorageCoordinator(
                presentingWindow: try XCTUnwrap(controller.window),
                controller: controller,
                projectURL: project.url,
                projectIdentity: projectIdentity,
                generation: 0,
                generationProvider: { 0 },
                operations: .production(),
                completion: {}
            )
            XCTAssertTrue(coordinator.present())
            let render = coordinator.viewModel.onChange
            coordinator.viewModel.onChange = { [weak coordinator] in
                render?()
                if coordinator?.viewModel.state == .ready {
                    heartbeat.markTerminal()
                }
            }
            while coordinator.viewModel.state == .scanning {
                await Task.yield()
            }
            XCTAssertEqual(coordinator.viewModel.state, .ready)
            let measurement = try await drainHeartbeatOrSkip(heartbeat)
            maximumDelay = max(
                maximumDelay,
                measurement.maximumDelayNanoseconds
            )
            print(
                "storage-perf-timing: trial=\(trial) "
                    + "terminal-watermark="
                    + "\(measurement.terminalDeadlineWatermark) "
                    + "samples=\(measurement.sampleCount) "
                    + "max-delay-ns="
                    + "\(measurement.maximumDelayNanoseconds)"
            )
            coordinator.invalidate()
            controller.close()
        }
        XCTAssertLessThan(maximumDelay, 100_000_000)
    }

    func testLargePreviewEmitsBalancedMainActorCommitInstrumentation()
        async throws
    {
        for scenario in StorageScanScenario.allCases {
            try await assertMainActorReconciliation(scenario)
        }
    }

    private func assertMainActorReconciliation(
        _ scenario: StorageScanScenario
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProjectStoragePerformanceTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try DocumentManager.shared.createProject(
            at: root.appendingPathComponent(
                "Performance.lungfish",
                isDirectory: true
            ),
            name: "Performance"
        )
        let session = ProjectSession()
        try session.openProject(at: project.url)
        let controller = MainWindowController(projectSession: session)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let identity = try FileSystemObjectIdentity.noFollow(project.url)
        let events = MainActorCommitEventRecorder()
        let operations = ProjectStorageCoordinator.Operations(
            scan: { _, progress in
                switch scenario {
                case .success:
                    for index in 1...256 {
                        progress(
                            .init(
                                visitedFileSystemObjects: UInt64(index),
                                classifiedEntries: UInt64(index),
                                logicalBytes: UInt64(index),
                                allocatedBytes: UInt64(index),
                                currentRelativePath: "item-\(index)"
                            )
                        )
                    }
                    return .init(projectIdentity: identity, entries: [])
                case .cancelled:
                    throw CancellationError()
                case .failure:
                    throw StorageScanFailure.expected
                }
            },
            instrumentation: .init(record: events.record),
            progressUptime: { 10 }
        )
        let coordinator = ProjectStorageCoordinator(
            presentingWindow: window,
            controller: controller,
            projectURL: project.url,
            projectIdentity: identity,
            generation: 0,
            generationProvider: { 0 },
            operations: operations,
            completion: {}
        )

        XCTAssertTrue(coordinator.present())
        while coordinator.viewModel.state == .scanning {
            await Task.yield()
        }

        let snapshot = events.snapshot
        let began = snapshot.compactMap { event -> UUID? in
            guard case .began(let interval) = event,
                  interval.phase == .mainActorCommit else {
                return nil
            }
            return interval.id
        }
        let ended = snapshot.compactMap { event -> UUID? in
            guard case .ended(let interval, _) = event,
                  interval.phase == .mainActorCommit else {
                return nil
            }
            return interval.id
        }
        XCTAssertFalse(began.isEmpty, "\(scenario)")
        XCTAssertEqual(Set(began), Set(ended))
        XCTAssertEqual(began.count, ended.count)
        for intervalID in began {
            XCTAssertEqual(
                snapshot.filter {
                    guard case .ended(let interval, _) = $0 else {
                        return false
                    }
                    return interval.id == intervalID
                }.count,
                1
            )
        }
        let terminalOutcome: ProjectStorageInstrumentation.Outcome = {
            switch scenario {
            case .success: .success
            case .cancelled: .cancelled
            case .failure: .failure
            }
        }()
        XCTAssertEqual(
            snapshot.filter {
                guard case .ended(_, let outcome) = $0 else {
                    return false
                }
                return outcome == terminalOutcome
            }.count,
            scenario == .success ? began.count : 1
        )
        XCTAssertEqual(
            snapshot.filter {
                guard case .counted(
                    .mainActorCommits,
                    1,
                    intervalID: _
                ) = $0 else {
                    return false
                }
                return true
            }.count,
            began.count
        )
        coordinator.invalidate()
    }

    private func makeOpenFixture() throws -> (
        root: URL,
        fixture: ProjectStorageLargeTreeFixture
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProjectStorageOpenTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let projectURL = root.appendingPathComponent(
            "Open.lungfish",
            isDirectory: true
        )
        _ = try DocumentManager.shared.createProject(
            at: projectURL,
            name: "Open"
        )
        return (
            root,
            try ProjectStorageLargeTreeFixture.createBaseTree(
                profile: .ciSemantic,
                at: projectURL
            )
        )
    }

    private func oneMainRunLoopTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private func makeSmallOwnedCandidate(projectURL: URL) throws -> URL {
        let temporary = projectURL.appendingPathComponent(
            ".tmp",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true
        )
        let candidate = temporary.appendingPathComponent(
            "candidate",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: candidate,
            withIntermediateDirectories: false
        )
        try OwnedWorkDirectoryMarkerStore.bindExistingDirectory(
            candidate,
            request: .init(
                projectURL: projectURL,
                parentDirectoryURL: temporary,
                prefix: "unused-",
                runID: UUID(),
                processIdentity: .init(
                    processIdentifier: 1,
                    processStartTime: 1,
                    bootSessionID: "storage-task9-worker"
                ),
                state: .completed,
                lockRelativePath: nil,
                keepIntermediates: false,
                toolName: "storage-task9-worker",
                toolVersion: "1"
            )
        )
        try Data("worker-payload".utf8).write(
            to: candidate.appendingPathComponent("payload.bin")
        )
        return candidate
    }

    private func containsQuarantinePath(projectURL: URL) throws -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: projectURL,
            includingPropertiesForKeys: nil
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        while let url = enumerator.nextObject() as? URL {
            if url.lastPathComponent.contains("quarantine") {
                return true
            }
        }
        return false
    }

    private func hardLinkSymbol(_ code: Int32) -> String {
        if code == EXDEV { return "EXDEV" }
        if code == EOPNOTSUPP { return "EOPNOTSUPP" }
        return "ENOTSUP"
    }

    private func measureHeartbeat(
        duration: TimeInterval,
        terminalOperation: @MainActor () -> Void
    ) async throws -> MainQueueHeartbeat.Measurement {
        let heartbeat = MainQueueHeartbeat(
            cadenceNanoseconds: 10_000_000
        )
        try await armHeartbeatOrSkip(heartbeat)
        try await Task.sleep(
            for: .milliseconds(Int(duration * 1_000))
        )
        terminalOperation()
        heartbeat.markTerminal()
        return try await drainHeartbeatOrSkip(heartbeat)
    }

    private func armHeartbeatOrSkip(
        _ heartbeat: MainQueueHeartbeat
    ) async throws {
        heartbeat.start()
        guard await heartbeat.waitUntilArmed(timeout: 5) else {
            heartbeat.stop()
            _ = await heartbeat.waitUntilJoined(timeout: 5)
            throw XCTSkip(
                "storage-perf-inconclusive: heartbeat-arm"
            )
        }
    }

    private func drainHeartbeatOrSkip(
        _ heartbeat: MainQueueHeartbeat
    ) async throws -> MainQueueHeartbeat.Measurement {
        guard await heartbeat.waitUntilDrained(timeout: 5) else {
            heartbeat.stop()
            _ = await heartbeat.waitUntilJoined(timeout: 5)
            throw XCTSkip(
                "storage-perf-inconclusive: heartbeat-drain"
            )
        }
        heartbeat.stop()
        guard await heartbeat.waitUntilJoined(timeout: 5) else {
            throw XCTSkip(
                "storage-perf-inconclusive: heartbeat-join"
            )
        }
        guard let measurement = heartbeat.measurement,
              measurement.sampleCount > 0 else {
            throw XCTSkip(
                "storage-perf-inconclusive: heartbeat-zero-samples"
            )
        }
        return measurement
    }
}

private enum StorageTimingConfigurationError: Error {
    case invalidMode(String)
}

private enum StorageScanScenario: CaseIterable, Sendable {
    case success
    case cancelled
    case failure
}

private enum StorageScanFailure: Error, Sendable {
    case expected
}

private final class WorkerPhaseRecorder: @unchecked Sendable {
    struct Observation: Sendable, Equatable {
        let phase: ProjectStorageWorkerPhase
        let isMainThread: Bool
    }

    private let lock = NSLock()
    private var observations: [Observation] = []

    var snapshot: [Observation] {
        lock.withLock { observations }
    }

    func record(
        phase: ProjectStorageWorkerPhase,
        isMainThread: Bool
    ) {
        lock.withLock {
            observations.append(
                .init(phase: phase, isMainThread: isMainThread)
            )
        }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.withLock { storage }
    }

    func set() {
        lock.withLock { storage = true }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

private final class VirtualStorageClock: @unchecked Sendable {
    private let lock = NSLock()
    private var tick = 0

    func next() -> TimeInterval {
        lock.withLock {
            defer { tick += 1 }
            return TimeInterval(tick) / 100
        }
    }
}

private final class AsyncSignal: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func signal() {
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [semaphore] in
                continuation.resume(
                    returning:
                        semaphore.wait(
                            timeout: .now() + timeout
                        ) == .success
                )
            }
        }
    }
}

private final class BlockingWorkerBarrier: @unchecked Sendable {
    private let reached = DispatchSemaphore(value: 0)
    private let releaseSemaphore = DispatchSemaphore(value: 0)

    func reachAndBlock() {
        reached.signal()
        releaseSemaphore.wait()
    }

    func waitUntilReached(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [reached] in
                continuation.resume(
                    returning:
                        reached.wait(
                            timeout: .now() + timeout
                        ) == .success
                )
            }
        }
    }

    func release() {
        releaseSemaphore.signal()
    }
}

private final class MainQueueHeartbeat: @unchecked Sendable {
    struct Measurement: Sendable, Equatable {
        let terminalDeadlineWatermark: UInt64
        let sampleCount: Int
        let maximumDelayNanoseconds: UInt64
    }

    private enum WaitKind: Sendable {
        case armed
        case drained
        case joined
    }

    private let cadenceNanoseconds: UInt64
    private let condition = NSCondition()
    private var source: DispatchSourceTimer?
    private var firstDeadline: UInt64 = 0
    private var nextSequence: UInt64 = 1
    private var delays: [UInt64: UInt64] = [:]
    private var terminalTime: UInt64?
    private var terminalWatermark: UInt64?
    private var executionCount: UInt64 = 0
    private var watermarkDrainExecutionCount: UInt64?
    private var armed = false
    private var postDrainExecution = false
    private var joined = false

    init(cadenceNanoseconds: UInt64) {
        self.cadenceNanoseconds = cadenceNanoseconds
    }

    var measurement: Measurement? {
        condition.withLock {
            guard let terminalWatermark,
                  terminalWatermark > 0 else {
                return nil
            }
            let measured = delays
                .filter { $0.key <= terminalWatermark }
                .map(\.value)
            guard measured.count == Int(terminalWatermark) else {
                return nil
            }
            return .init(
                terminalDeadlineWatermark: terminalWatermark,
                sampleCount: measured.count,
                maximumDelayNanoseconds: measured.max() ?? 0
            )
        }
    }

    func start() {
        condition.lock()
        precondition(source == nil)
        firstDeadline =
            DispatchTime.now().uptimeNanoseconds + cadenceNanoseconds
        let timer = DispatchSource.makeTimerSource(queue: .main)
        source = timer
        condition.unlock()

        timer.setEventHandler { [weak self] in
            self?.recordExecution()
        }
        timer.setCancelHandler { [weak self] in
            guard let self else { return }
            condition.withLock {
                joined = true
                condition.broadcast()
            }
        }
        timer.schedule(
            deadline: DispatchTime(uptimeNanoseconds: firstDeadline),
            repeating: .nanoseconds(Int(cadenceNanoseconds)),
            leeway: .nanoseconds(0)
        )
        timer.activate()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            condition.withLock {
                armed = true
                condition.broadcast()
            }
        }
    }

    func markTerminal() {
        let now = DispatchTime.now().uptimeNanoseconds
        condition.withLock {
            terminalTime = now
            if now < firstDeadline {
                terminalWatermark = 0
            } else {
                terminalWatermark =
                    ((now - firstDeadline) / cadenceNanoseconds) + 1
            }
            recordWatermarkDrainIfComplete()
            condition.broadcast()
        }
    }

    func stop() {
        condition.withLock {
            source?.cancel()
        }
    }

    func waitUntilArmed(timeout: TimeInterval) async -> Bool {
        await wait(kind: .armed, timeout: timeout)
    }

    func waitUntilDrained(timeout: TimeInterval) async -> Bool {
        await wait(kind: .drained, timeout: timeout)
    }

    func waitUntilJoined(timeout: TimeInterval) async -> Bool {
        await wait(kind: .joined, timeout: timeout)
    }

    private func recordExecution() {
        let actual = DispatchTime.now().uptimeNanoseconds
        condition.withLock {
            executionCount += 1
            if actual >= firstDeadline {
                let dueSequence =
                    ((actual - firstDeadline) / cadenceNanoseconds) + 1
                if nextSequence <= dueSequence {
                    for sequence in nextSequence...dueSequence {
                        let deadline =
                            firstDeadline
                            + (sequence - 1) * cadenceNanoseconds
                        delays[sequence] = actual - deadline
                    }
                    nextSequence = dueSequence + 1
                }
            }
            if let drainExecution = watermarkDrainExecutionCount,
               executionCount > drainExecution,
               let terminalTime,
               actual > terminalTime {
                postDrainExecution = true
            }
            recordWatermarkDrainIfComplete()
            condition.broadcast()
        }
    }

    private func recordWatermarkDrainIfComplete() {
        guard watermarkDrainExecutionCount == nil,
              let terminalWatermark,
              terminalWatermark > 0,
              delays.count >= Int(terminalWatermark) else {
            return
        }
        watermarkDrainExecutionCount = executionCount
    }

    private func wait(
        kind: WaitKind,
        timeout: TimeInterval
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                continuation.resume(
                    returning: waitSynchronously(
                        kind: kind,
                        timeout: timeout
                    )
                )
            }
        }
    }

    private func waitSynchronously(
        kind: WaitKind,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while !isSatisfied(kind) {
            guard condition.wait(until: deadline) else {
                return isSatisfied(kind)
            }
        }
        return true
    }

    private func isSatisfied(_ kind: WaitKind) -> Bool {
        switch kind {
        case .armed:
            return armed
        case .drained:
            guard let terminalWatermark,
                  terminalWatermark > 0 else {
                return false
            }
            return delays.count >= Int(terminalWatermark)
                && postDrainExecution
        case .joined:
            return joined
        }
    }
}

private struct StorageFixtureSnapshot: Equatable {
    struct Extent: Equatable {
        let offset: Int64
        let length: Int64
        let sha256: String
    }

    struct Entry: Equatable {
        let relativePath: String
        let fileType: mode_t
        let device: UInt64
        let inode: UInt64
        let linkCount: UInt64
        let logicalSize: Int64
        let allocatedSize: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64
        let sha256: String?
        let allocatedExtents: [Extent]
    }

    let entries: [Entry]

    static func capture(root: URL) throws -> Self {
        let canonicalRoot =
            root.standardizedFileURL.resolvingSymlinksInPath()
        var urls: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: canonicalRoot,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        while let url = enumerator.nextObject() as? URL {
            urls.append(url)
        }
        let entries = try urls.compactMap { url -> Entry? in
            let normalizedPath =
                url.standardizedFileURL.resolvingSymlinksInPath().path
            let relativePath = String(
                normalizedPath.dropFirst(canonicalRoot.path.count + 1)
            )
            guard relativePath == ".tmp"
                    || relativePath.hasPrefix(".tmp/")
                    || relativePath
                        == ProjectOperationHistoryWriter
                            .historyDirectoryName
                    || relativePath.hasPrefix(
                        ProjectOperationHistoryWriter
                            .historyDirectoryName + "/"
                    )
                    || relativePath == "survivor"
                    || relativePath.hasPrefix("survivor/") else {
                return nil
            }
            var information = stat()
            guard Darwin.lstat(url.path, &information) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            let type = information.st_mode & S_IFMT
            let allocated = Int64(information.st_blocks) * 512
            let isRegular = type == S_IFREG
            let isSparse =
                isRegular && allocated < Int64(information.st_size)
            let extents = isSparse
                ? try allocatedExtentSnapshots(
                    url: url,
                    logicalSize: Int64(information.st_size)
                )
                : []
            return Entry(
                relativePath: relativePath,
                fileType: type,
                device: UInt64(information.st_dev),
                inode: UInt64(information.st_ino),
                linkCount: UInt64(information.st_nlink),
                logicalSize: Int64(information.st_size),
                allocatedSize: allocated,
                modificationSeconds:
                    Int64(information.st_mtimespec.tv_sec),
                modificationNanoseconds:
                    Int64(information.st_mtimespec.tv_nsec),
                changeSeconds:
                    Int64(information.st_ctimespec.tv_sec),
                changeNanoseconds:
                    Int64(information.st_ctimespec.tv_nsec),
                sha256: isRegular && !isSparse
                    ? try sha256(url: url)
                    : nil,
                allocatedExtents: extents
            )
        }.sorted { $0.relativePath < $1.relativePath }
        return Self(entries: entries)
    }

    private static func allocatedExtentSnapshots(
        url: URL,
        logicalSize: Int64
    ) throws -> [Extent] {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        var offset: off_t = 0
        var extents: [Extent] = []
        while offset < logicalSize {
            errno = 0
            let dataOffset = Darwin.lseek(descriptor, offset, SEEK_DATA)
            if dataOffset < 0 {
                if errno == ENXIO { break }
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            let holeOffset = Darwin.lseek(
                descriptor,
                dataOffset,
                SEEK_HOLE
            )
            guard holeOffset >= dataOffset else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            let end = min(holeOffset, logicalSize)
            extents.append(
                .init(
                    offset: dataOffset,
                    length: end - dataOffset,
                    sha256: try sha256(
                        descriptor: descriptor,
                        offset: dataOffset,
                        length: end - dataOffset
                    )
                )
            )
            offset = end
        }
        return extents
    }

    private static func sha256(url: URL) throws -> String {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return try sha256(
            descriptor: descriptor,
            offset: 0,
            length: Int64(information.st_size)
        )
    }

    private static func sha256(
        descriptor: Int32,
        offset: Int64,
        length: Int64
    ) throws -> String {
        var digest = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var consumed: Int64 = 0
        while consumed < length {
            let requested = min(
                buffer.count,
                Int(length - consumed)
            )
            let count = Darwin.pread(
                descriptor,
                &buffer,
                requested,
                offset + consumed
            )
            guard count > 0 else {
                throw POSIXError(
                    .init(rawValue: count < 0 ? errno : EIO) ?? .EIO
                )
            }
            digest.update(data: Data(buffer[0..<count]))
            consumed += Int64(count)
        }
        return digest.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }
}

private final class MainActorCommitEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ProjectStorageInstrumentation.Event] = []

    var snapshot: [ProjectStorageInstrumentation.Event] {
        lock.withLock { events }
    }

    func record(_ event: ProjectStorageInstrumentation.Event) {
        lock.withLock { events.append(event) }
    }
}
