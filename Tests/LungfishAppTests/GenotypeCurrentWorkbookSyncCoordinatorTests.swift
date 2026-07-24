import XCTest
import LungfishKit
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class GenotypeCurrentWorkbookSyncCoordinatorTests: XCTestCase {
    func testCleanFingerprintAvoidsRunnerAndOnlyUpdateAndViewOpensResolvedWorkbook() async throws {
        let bundle = bundleURL("clean")
        let workbook = bundle.appendingPathComponent("custom/current.xlsx")
        let fingerprint = try makeFingerprint("a")
        let runner = ControlledRunner()
        var opened: [URL] = []
        let coordinator = makeCoordinator(
            recorded: fingerprint,
            runner: runner,
            workbookURL: workbook,
            opened: { opened.append($0) }
        )
        let request = makeRequest(bundle: bundle, fingerprint: fingerprint)

        _ = try await coordinator.synchronize(request, intent: .automaticIdle)
        _ = try await coordinator.synchronize(request, intent: .bundleSwitch)
        let resolved = try await coordinator.synchronize(request, intent: .updateAndView)

        XCTAssertEqual(resolved, workbook.standardizedFileURL)
        XCTAssertEqual(runner.invocations.count, 0)
        XCTAssertEqual(opened, [workbook.standardizedFileURL])
        XCTAssertEqual(coordinator.phase(for: bundle), .current)
    }

    func testDirtyRequestRunsOnceRecordsIntentAndAutomaticNeverOpens() async throws {
        let bundle = bundleURL("dirty")
        let fingerprint = try makeFingerprint("b")
        let runner = ControlledRunner()
        runner.automaticallySucceed = true
        var opened: [URL] = []
        let coordinator = makeCoordinator(
            recorded: nil,
            runner: runner,
            opened: { opened.append($0) }
        )

        _ = try await coordinator.synchronize(
            makeRequest(bundle: bundle, fingerprint: fingerprint),
            intent: .automaticIdle
        )

        XCTAssertEqual(runner.invocations.map(\.intent), [.automaticIdle])
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(coordinator.phase(for: bundle), .current)
    }

    func testJoiningAutomaticUpdateRunsOnceAndUpdateAndViewOpensExactlyOnce() async throws {
        let bundle = bundleURL("join")
        let fingerprint = try makeFingerprint("c")
        let workbook = bundle.appendingPathComponent("artifacts/workbooks/current.xlsx")
        let runner = ControlledRunner()
        var opened: [URL] = []
        let coordinator = makeCoordinator(
            recorded: nil,
            runner: runner,
            opened: { opened.append($0) }
        )
        let request = makeRequest(bundle: bundle, fingerprint: fingerprint)

        let automatic = Task { try await coordinator.synchronize(request, intent: .automaticIdle) }
        await waitUntil { runner.invocations.count == 1 }
        let explicit = Task { try await coordinator.synchronize(request, intent: .updateAndView) }
        await Task.yield()

        XCTAssertEqual(runner.invocations.count, 1)
        runner.succeedInvocation(at: 0, with: workbook)
        _ = try await automatic.value
        _ = try await explicit.value

        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(opened, [workbook.standardizedFileURL])
    }

    func testConcurrentRequestsWaitingForFingerprintLoadStillInstallOneUpdateTask() async throws {
        let bundle = bundleURL("loader-join")
        let fingerprint = try makeFingerprint("9")
        let runner = ControlledRunner()
        let loader = ControlledFingerprintLoader()
        let coordinator = GenotypeCurrentWorkbookSyncCoordinator(
            recordedFingerprintLoader: { bundle in
                await loader.load(bundle)
            },
            updateRunner: { request, intent in
                try await runner.run(request, intent: intent)
            },
            workbookOpener: { _ in },
            idleScheduler: TestIdleScheduler().schedule
        )
        let request = makeRequest(bundle: bundle, fingerprint: fingerprint)

        let first = Task {
            try await coordinator.synchronize(request, intent: .automaticIdle)
        }
        let second = Task {
            try await coordinator.synchronize(request, intent: .bundleSwitch)
        }
        await waitUntil { loader.callCount == 1 }
        loader.finish(with: nil)
        await waitUntil { runner.invocations.count >= 1 }
        for _ in 0..<20 {
            await Task.yield()
        }

        let invocationCount = runner.invocations.count
        XCTAssertEqual(invocationCount, 1)
        for index in 0..<invocationCount {
            runner.succeedInvocation(at: index)
        }
        _ = try await first.value
        _ = try await second.value
    }

    func testNewerRequestsDuringUpdateCoalesceToOneLatestFollowUpAndSerializeRunner() async throws {
        let bundle = bundleURL("follow-up")
        let first = makeRequest(bundle: bundle, fingerprint: try makeFingerprint("d"))
        let middle = makeRequest(bundle: bundle, fingerprint: try makeFingerprint("e"))
        let latest = makeRequest(bundle: bundle, fingerprint: try makeFingerprint("f"))
        let runner = ControlledRunner()
        var opened: [URL] = []
        let coordinator = makeCoordinator(
            recorded: nil,
            runner: runner,
            opened: { opened.append($0) }
        )

        let firstWaiter = Task {
            try await coordinator.synchronize(first, intent: .automaticIdle)
        }
        await waitUntil { runner.invocations.count == 1 }
        let explicitWaiter = Task {
            try await coordinator.synchronize(middle, intent: .updateAndView)
        }
        let latestWaiter = Task {
            try await coordinator.synchronize(latest, intent: .bundleSwitch)
        }
        await waitUntil { coordinator.phase(for: bundle) == .dirtyWhileUpdating }
        var coalescedLatest = latest
        for character: Character in ["0", "1", "2", "3", "4", "5"] {
            coalescedLatest = makeRequest(
                bundle: bundle,
                fingerprint: try makeFingerprint(character)
            )
            coordinator.markDirty(coalescedLatest)
        }

        XCTAssertEqual(runner.invocations.count, 1)
        runner.succeedInvocation(at: 0)
        await waitUntil { runner.invocations.count == 2 }

        XCTAssertEqual(
            runner.invocations[1].request.fingerprint,
            coalescedLatest.fingerprint
        )
        XCTAssertEqual(runner.maximumConcurrency, 1)
        XCTAssertFalse(firstWaiter.isCancelled)
        XCTAssertTrue(opened.isEmpty)

        runner.succeedInvocation(at: 1)
        _ = try await firstWaiter.value
        _ = try await explicitWaiter.value
        _ = try await latestWaiter.value

        XCTAssertEqual(runner.invocations.count, 2)
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(coordinator.phase(for: bundle), .current)
    }

    func testRecordedFingerprintMarkedDirtyDuringNewerPublicationRunsSerializedFollowUp() async throws {
        let bundle = bundleURL("recorded-follow-up")
        let recorded = try makeFingerprint("a")
        let publishing = try makeFingerprint("b")
        let runner = ControlledRunner()
        var opened: [URL] = []
        let coordinator = makeCoordinator(
            recorded: recorded,
            runner: runner,
            opened: { opened.append($0) }
        )
        let publishingRequest = makeRequest(
            bundle: bundle,
            fingerprint: publishing
        )
        let recordedRequest = makeRequest(bundle: bundle, fingerprint: recorded)

        let waiter = Task {
            try await coordinator.synchronize(
                publishingRequest,
                intent: .updateAndView
            )
        }
        await waitUntil { runner.invocations.count == 1 }
        coordinator.markDirty(recordedRequest)

        XCTAssertEqual(coordinator.phase(for: bundle), .dirtyWhileUpdating)
        runner.succeedInvocation(at: 0)
        await waitUntil { runner.invocations.count == 2 }
        guard runner.invocations.count == 2 else {
            _ = try await waiter.value
            return
        }

        XCTAssertEqual(runner.invocations[1].request.fingerprint, recorded)
        XCTAssertEqual(runner.maximumConcurrency, 1)
        XCTAssertTrue(opened.isEmpty)

        runner.succeedInvocation(at: 1)
        _ = try await waiter.value

        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(coordinator.phase(for: bundle), .current)
    }

    func testPublishedFingerprintSupersedesOlderRecordedFingerprint() async throws {
        let bundle = bundleURL("published-authority")
        let recorded = try makeFingerprint("c")
        let published = try makeFingerprint("d")
        let runner = ControlledRunner()
        runner.automaticallySucceed = true
        let coordinator = makeCoordinator(recorded: recorded, runner: runner)

        _ = try await coordinator.synchronize(
            makeRequest(bundle: bundle, fingerprint: published),
            intent: .automaticIdle
        )
        _ = try await coordinator.synchronize(
            makeRequest(bundle: bundle, fingerprint: recorded),
            intent: .automaticIdle
        )

        XCTAssertEqual(
            runner.invocations.map(\.request.fingerprint),
            [published, recorded]
        )
        XCTAssertEqual(coordinator.phase(for: bundle), .current)
    }

    func testDifferentBundlesUpdateIndependently() async throws {
        let firstBundle = bundleURL("bundle-one")
        let secondBundle = bundleURL("bundle-two")
        let runner = ControlledRunner()
        let coordinator = makeCoordinator(recorded: nil, runner: runner)

        let first = Task {
            try await coordinator.synchronize(
                makeRequest(bundle: firstBundle, fingerprint: try makeFingerprint("1")),
                intent: .automaticIdle
            )
        }
        let second = Task {
            try await coordinator.synchronize(
                makeRequest(bundle: secondBundle, fingerprint: try makeFingerprint("2")),
                intent: .automaticIdle
            )
        }
        await waitUntil { runner.invocations.count == 2 }

        XCTAssertEqual(runner.activeCount, 2)
        runner.succeedInvocation(at: 0)
        runner.succeedInvocation(at: 1)
        _ = try await first.value
        _ = try await second.value
    }

    func testRepeatedDirtyNotificationsResetExactlyNinetySecondIdleAndStaleTokenNoOps() async throws {
        let bundle = bundleURL("idle")
        let scheduler = TestIdleScheduler()
        let runner = ControlledRunner()
        runner.automaticallySucceed = true
        let coordinator = makeCoordinator(
            recorded: nil,
            runner: runner,
            scheduler: scheduler
        )
        let first = makeRequest(bundle: bundle, fingerprint: try makeFingerprint("3"))
        let latest = makeRequest(bundle: bundle, fingerprint: try makeFingerprint("4"))

        coordinator.markDirty(first)
        coordinator.markDirty(latest)

        XCTAssertEqual(
            scheduler.delays,
            [
                GenotypeCurrentWorkbookSyncCoordinator.idleDelayNanoseconds,
                GenotypeCurrentWorkbookSyncCoordinator.idleDelayNanoseconds,
            ]
        )
        XCTAssertEqual(
            GenotypeCurrentWorkbookSyncCoordinator.idleDelayNanoseconds,
            90_000_000_000
        )
        XCTAssertEqual(scheduler.tokens.filter { !$0.cancelled }.count, 1)

        await scheduler.tokens[0].fire()
        XCTAssertEqual(runner.invocations.count, 0)
        await scheduler.tokens[1].fire()
        await waitUntil { runner.invocations.count == 1 }

        XCTAssertEqual(runner.invocations[0].request.fingerprint, latest.fingerprint)
        XCTAssertEqual(runner.invocations[0].intent, .automaticIdle)
    }

    func testBundleSwitchCancelsIdleAndSynchronizesDirtyRequestImmediately() async throws {
        let bundle = bundleURL("switch")
        let scheduler = TestIdleScheduler()
        let runner = ControlledRunner()
        runner.automaticallySucceed = true
        let coordinator = makeCoordinator(
            recorded: nil,
            runner: runner,
            scheduler: scheduler
        )
        let request = makeRequest(bundle: bundle, fingerprint: try makeFingerprint("5"))
        coordinator.markDirty(request)

        _ = try await coordinator.synchronize(request, intent: .bundleSwitch)

        XCTAssertTrue(scheduler.tokens[0].cancelled)
        XCTAssertEqual(runner.invocations.map(\.intent), [.bundleSwitch])
    }

    func testFailureDoesNotOpenOrSpinAndExplicitRetryPublishesFingerprintAsCurrent() async throws {
        let bundle = bundleURL("retry")
        let fingerprint = try makeFingerprint("6")
        let different = try makeFingerprint("7")
        let scheduler = TestIdleScheduler()
        let runner = ControlledRunner()
        runner.failNext = TestError.expected
        var opened: [URL] = []
        let coordinator = makeCoordinator(
            recorded: nil,
            runner: runner,
            opened: { opened.append($0) },
            scheduler: scheduler
        )
        let request = makeRequest(bundle: bundle, fingerprint: fingerprint)

        do {
            _ = try await coordinator.synchronize(request, intent: .updateAndView)
            XCTFail("Expected failure")
        } catch TestError.expected {}

        guard case .failed(let message) = coordinator.phase(for: bundle) else {
            return XCTFail("Expected failed phase")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(scheduler.tokens.filter { !$0.cancelled }.count, 0)

        runner.automaticallySucceed = true
        _ = try await coordinator.synchronize(request, intent: .updateAndView)
        _ = try await coordinator.synchronize(request, intent: .automaticIdle)

        XCTAssertEqual(runner.invocations.count, 2)
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(coordinator.phase(for: bundle), .current)

        _ = try await coordinator.synchronize(
            makeRequest(bundle: bundle, fingerprint: different),
            intent: .automaticIdle
        )
        XCTAssertEqual(runner.invocations.count, 3)
    }

    func testCancellationLeavesFailedRetryableState() async throws {
        let bundle = bundleURL("cancelled")
        let runner = ControlledRunner()
        runner.failNext = CancellationError()
        let coordinator = makeCoordinator(recorded: nil, runner: runner)
        let request = makeRequest(
            bundle: bundle,
            fingerprint: try makeFingerprint("a")
        )

        do {
            _ = try await coordinator.synchronize(request, intent: .automaticIdle)
            XCTFail("Expected cancellation")
        } catch is CancellationError {}

        XCTAssertEqual(
            coordinator.phase(for: bundle),
            .failed("The current workbook update was cancelled.")
        )
        runner.automaticallySucceed = true
        _ = try await coordinator.synchronize(request, intent: .bundleSwitch)

        XCTAssertEqual(runner.invocations.count, 2)
        XCTAssertEqual(coordinator.phase(for: bundle), .current)
    }

    func testObserverReceivesOnlyPhaseTransitionsAndDoesNotRetainOwner() async throws {
        let bundle = bundleURL("observer")
        let runner = ControlledRunner()
        runner.automaticallySucceed = true
        let coordinator = makeCoordinator(recorded: nil, runner: runner)
        var owner: ObserverOwner? = ObserverOwner()
        let weakOwner = WeakReference(owner)
        let observation = coordinator.observe(owner!) { owner, _, phase in
            owner.phases.append(phase)
        }

        _ = try await coordinator.synchronize(
            makeRequest(bundle: bundle, fingerprint: try makeFingerprint("8")),
            intent: .automaticIdle
        )

        XCTAssertEqual(owner?.phases, [.dirty, .updating, .current])
        owner = nil
        XCTAssertNil(weakOwner.value)
        withExtendedLifetime(observation) {}
    }

    private func makeCoordinator(
        recorded: GenotypeCurrentWorkbookInputFingerprint?,
        runner: ControlledRunner,
        workbookURL: URL? = nil,
        opened: @escaping @MainActor (URL) -> Void = { _ in },
        scheduler: TestIdleScheduler = TestIdleScheduler()
    ) -> GenotypeCurrentWorkbookSyncCoordinator {
        GenotypeCurrentWorkbookSyncCoordinator(
            recordedFingerprintLoader: { _ in recorded },
            currentWorkbookResolver: { bundle in
                workbookURL ?? bundle.appendingPathComponent("artifacts/workbooks/current.xlsx")
            },
            updateRunner: { request, intent in
                try await runner.run(request, intent: intent)
            },
            workbookOpener: opened,
            idleScheduler: scheduler.schedule
        )
    }

    private func makeRequest(
        bundle: URL,
        fingerprint: GenotypeCurrentWorkbookInputFingerprint
    ) -> GenotypeCurrentWorkbookSyncCoordinator.Request {
        let displayed = [
            GenotypeWorkbookHaplotypeCall(
                sample: "LF2888",
                locus: "MHC-A",
                haplotype1: "A1",
                haplotype2: "A2",
                status: "called",
                notes: ""
            ),
        ]
        return .init(
            bundleURL: bundle,
            displayedCalls: displayed,
            effectiveCalls: displayed,
            includedLoci: ["MHC-A"],
            annotationSidecarURL: bundle.appendingPathComponent("annotations.json"),
            annotationOnly: false,
            fingerprint: fingerprint,
            routeContext: OperationRouteContext(projectURL: nil, windowStateScopeID: nil)
        )
    }

    private func makeFingerprint(
        _ character: Character
    ) throws -> GenotypeCurrentWorkbookInputFingerprint {
        try GenotypeCurrentWorkbookInputFingerprint(
            schemaVersion: GenotypeCurrentWorkbookInputFingerprint.schemaVersion,
            sha256: String(repeating: character, count: 64)
        )
    }

    private func bundleURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(name).lungfishgenotype", isDirectory: true)
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if predicate() {
                return
            }
            await Task.yield()
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }
}

@MainActor
private final class ControlledRunner {
    struct Invocation {
        let request: GenotypeCurrentWorkbookSyncCoordinator.Request
        let intent: GenotypeCurrentWorkbookSyncIntent
    }

    var automaticallySucceed = false
    var failNext: Error?
    private(set) var invocations: [Invocation] = []
    private(set) var activeCount = 0
    private(set) var maximumConcurrency = 0
    private var continuations: [Int: CheckedContinuation<URL, Error>] = [:]

    func run(
        _ request: GenotypeCurrentWorkbookSyncCoordinator.Request,
        intent: GenotypeCurrentWorkbookSyncIntent
    ) async throws -> URL {
        let index = invocations.count
        invocations.append(.init(request: request, intent: intent))
        activeCount += 1
        maximumConcurrency = max(maximumConcurrency, activeCount)
        if let failNext {
            self.failNext = nil
            activeCount -= 1
            throw failNext
        }
        if automaticallySucceed {
            activeCount -= 1
            return defaultWorkbookURL(for: request)
        }
        return try await withCheckedThrowingContinuation { continuation in
            continuations[index] = continuation
        }
    }

    func succeedInvocation(at index: Int, with url: URL? = nil) {
        guard let continuation = continuations.removeValue(forKey: index) else {
            XCTFail("No suspended invocation at index \(index)")
            return
        }
        activeCount -= 1
        continuation.resume(returning: url ?? defaultWorkbookURL(for: invocations[index].request))
    }

    private func defaultWorkbookURL(
        for request: GenotypeCurrentWorkbookSyncCoordinator.Request
    ) -> URL {
        request.bundleURL.appendingPathComponent("artifacts/workbooks/current.xlsx")
    }
}

@MainActor
private final class ControlledFingerprintLoader {
    private(set) var callCount = 0
    private var continuation:
        CheckedContinuation<GenotypeCurrentWorkbookInputFingerprint?, Never>?

    func load(_ bundleURL: URL) async -> GenotypeCurrentWorkbookInputFingerprint? {
        callCount += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func finish(with fingerprint: GenotypeCurrentWorkbookInputFingerprint?) {
        continuation?.resume(returning: fingerprint)
        continuation = nil
    }
}

@MainActor
private final class TestIdleScheduler {
    private(set) var delays: [UInt64] = []
    private(set) var tokens: [Token] = []

    func schedule(
        delay: UInt64,
        action: @escaping @MainActor @Sendable () async -> Void
    ) -> GenotypeCurrentWorkbookSyncCoordinator.IdleCancellation {
        delays.append(delay)
        let token = Token(action: action)
        tokens.append(token)
        return token
    }

    final class Token: GenotypeCurrentWorkbookSyncCoordinator.IdleCancellation {
        private let action: @MainActor @Sendable () async -> Void
        private(set) var cancelled = false

        init(action: @escaping @MainActor @Sendable () async -> Void) {
            self.action = action
        }

        func cancel() {
            cancelled = true
        }

        func fire() async {
            await action()
        }
    }
}

@MainActor
private final class ObserverOwner {
    var phases: [GenotypeCurrentWorkbookSyncCoordinator.Phase] = []
}

private final class WeakReference<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}

private enum TestError: Error {
    case expected
}
