import XCTest
import Darwin
import LungfishIO
import LungfishKit
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class GenotypeCurrentWorkbookSyncCoordinatorTests: XCTestCase {
    func testUpdateAndViewOpensValidatedIdentityWhenWorkbookPathIsSwappedAfterValidation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GenotypeCurrentWorkbookIdentityHandoff-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent(
            "identity-handoff.lungfishgenotype",
            isDirectory: true
        )
        let canonicalWorkbook = bundle.appendingPathComponent(
            "artifacts/workbooks/current.xlsx"
        )
        try FileManager.default.createDirectory(
            at: canonicalWorkbook.deletingLastPathComponent()
                .appendingPathComponent("updates", isDirectory: true),
            withIntermediateDirectories: true
        )
        let validatedBytes = Data("validated workbook identity".utf8)
        try validatedBytes.write(to: canonicalWorkbook)
        try Data("{}".utf8).write(
            to: ONTGenotypeResultBundle.manifestURL(in: bundle)
        )
        try GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-29T00:00:00Z"
        ).encoded().write(
            to: bundle.appendingPathComponent("annotations.json")
        )
        let unvalidatedWorkbook = root.appendingPathComponent(
            "unvalidated-replacement.xlsx"
        )
        try Data("must never be opened".utf8).write(to: unvalidatedWorkbook)

        let payload = try workbookUpdatePayloadJSON(for: bundle)
        let processRunner = IdentityHandoffCLIProcessRunner(
            result: .init(
                exitCode: 0,
                standardOutput: payload,
                standardError: "[100%] Updated current.xlsx\n"
            )
        )
        var didSwapPath = false
        let executionService = GenotypeCurrentWorkbookUpdateExecutionService(
            operationCenter: OperationCenter(),
            processRunner: processRunner,
            postPayloadValidationObserver: { validatedURL in
                XCTAssertEqual(
                    validatedURL.standardizedFileURL,
                    canonicalWorkbook.standardizedFileURL
                )
                try FileManager.default.removeItem(at: validatedURL)
                try FileManager.default.createSymbolicLink(
                    at: validatedURL,
                    withDestinationURL: unvalidatedWorkbook
                )
                didSwapPath = true
            }
        )
        var openedURLs: [URL] = []
        var openedBytes: [Data] = []
        let coordinator = GenotypeCurrentWorkbookSyncCoordinator(
            recordedFingerprintLoader: { _ in nil },
            currentWorkbookResolver: { _ in nil },
            updateRunner: { request, intent in
                try await executionService.run(
                    bundleURL: request.bundleURL,
                    calls: request.calls,
                    includedLoci: request.includedLoci,
                    annotationSidecarURL: request.annotationSidecarURL,
                    annotationSidecarData: request.annotationSidecarData,
                    annotationOnly: request.annotationOnly,
                    haplotypeProjectionMode: request.haplotypeProjectionMode,
                    inputFingerprint: request.fingerprint,
                    syncIntent: intent,
                    routeContext: request.routeContext
                )
            },
            workbookOpener: { url in
                openedURLs.append(url)
                if let data = try? Data(contentsOf: url) {
                    openedBytes.append(data)
                }
            },
            idleScheduler: TestIdleScheduler().schedule
        )

        let returnedURL = try await coordinator.synchronize(
            makeRequest(
                bundle: bundle,
                fingerprint: try makeFingerprint("a")
            ),
            intent: .updateAndView
        )

        XCTAssertTrue(didSwapPath)
        XCTAssertEqual(
            returnedURL.standardizedFileURL,
            canonicalWorkbook.standardizedFileURL
        )
        XCTAssertEqual(openedURLs.count, 1)
        XCTAssertNotEqual(
            openedURLs.first?.standardizedFileURL,
            canonicalWorkbook.standardizedFileURL
        )
        XCTAssertEqual(openedBytes, [validatedBytes])
        var openedInformation = stat()
        XCTAssertEqual(
            Darwin.lstat(try XCTUnwrap(openedURLs.first).path, &openedInformation),
            0
        )
        XCTAssertEqual(openedInformation.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(openedInformation.st_mode & S_IWUSR, 0)
    }

    func testImmutableWorkbookViewCleanupRemovesOnlyStaleOwnedDirectChildDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GenotypeCurrentWorkbookViewCleanup-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = GenotypeCurrentWorkbookOpenHandoff.directoryPrefix
        let stale = root.appendingPathComponent(
            "\(prefix)ABC123",
            isDirectory: true
        )
        let fresh = root.appendingPathComponent(
            "\(prefix)DEF456",
            isDirectory: true
        )
        let unrelated = root.appendingPathComponent(
            "unrelated.ABC123",
            isDirectory: true
        )
        let unownedLookalike = root.appendingPathComponent(
            "\(prefix)JKL012",
            isDirectory: true
        )
        for directory in [stale, fresh, unrelated, unownedLookalike] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
            try Data("view".utf8).write(
                to: directory.appendingPathComponent("current.xlsx")
            )
        }
        for directory in [stale, fresh] {
            try Data("Lungfish current workbook view v1\n".utf8).write(
                to: directory.appendingPathComponent(
                    GenotypeCurrentWorkbookOpenHandoff.ownershipMarkerName
                )
            )
        }
        let symlink = root.appendingPathComponent(
            "\(prefix)GHI789",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: stale
        )
        let now = Date()
        let oldDate = now.addingTimeInterval(-48 * 60 * 60)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: stale.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: fresh.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: unrelated.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: unownedLookalike.path
        )

        let removed =
            GenotypeCurrentWorkbookOpenHandoffRegistry.cleanupStaleViews(
                in: root,
                olderThan: now.addingTimeInterval(-24 * 60 * 60)
            )

        XCTAssertEqual(removed, [stale.standardizedFileURL])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: unownedLookalike.path)
        )
        var symlinkInformation = stat()
        XCTAssertEqual(Darwin.lstat(symlink.path, &symlinkInformation), 0)
        XCTAssertEqual(symlinkInformation.st_mode & S_IFMT, S_IFLNK)
    }

    func testChangedReviewableRowCatalogDescriptorMarksWorkbookDirtyAndRunsUpdate() async throws {
        let bundle = bundleURL("catalog-dirty")
        let original = try makeCatalogFingerprint(
            path: "artifacts/review/catalog.json",
            checksumCharacter: "a",
            size: 100,
            schemaVersion: 1
        )
        let changed = try makeCatalogFingerprint(
            path: "artifacts/review/catalog.json",
            checksumCharacter: "b",
            size: 100,
            schemaVersion: 1
        )
        let runner = ControlledRunner()
        runner.automaticallySucceed = true
        let coordinator = makeCoordinator(recorded: original, runner: runner)

        _ = try await coordinator.synchronize(
            makeRequest(bundle: bundle, fingerprint: changed),
            intent: .automaticIdle
        )

        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(runner.invocations.first?.request.fingerprint, changed)
        XCTAssertEqual(coordinator.phase(for: bundle), .current)
    }

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
        XCTAssertFalse(coordinator.testingHasRetainedRequest(for: bundle))
    }

    func testCleanUpdateAndViewRejectsIntermediateWorkbookDirectorySwapAfterResolution() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GenotypeCurrentWorkbookCleanIntermediateSwap-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent(
            "clean-swap.lungfishgenotype",
            isDirectory: true
        )
        try writeManifest(
            in: bundle,
            currentWorkbookPath: "artifacts/workbooks/current.xlsx"
        )
        let workbooks = bundle.appendingPathComponent(
            "artifacts/workbooks",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: workbooks,
            withIntermediateDirectories: true
        )
        let canonicalWorkbook = workbooks.appendingPathComponent("current.xlsx")
        try Data("validated workbook".utf8).write(to: canonicalWorkbook)
        let outsideWorkbooks = root.appendingPathComponent(
            "outside-workbooks",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outsideWorkbooks,
            withIntermediateDirectories: true
        )
        let maliciousWorkbook = outsideWorkbooks.appendingPathComponent(
            "current.xlsx"
        )
        try Data("must never open".utf8).write(to: maliciousWorkbook)

        let fingerprint = try makeFingerprint("a")
        var opened: [URL] = []
        var openedBytes: [Data] = []
        let coordinator = GenotypeCurrentWorkbookSyncCoordinator(
            recordedFingerprintLoader: { _ in fingerprint },
            updateRunner: { _, _ in
                XCTFail("A clean workbook must not run an update")
                return canonicalWorkbook
            },
            workbookOpener: { url in
                opened.append(url)
                if let bytes = try? Data(contentsOf: url) {
                    openedBytes.append(bytes)
                }
            },
            postWorkbookResolutionObserver: { resolvedURL in
                XCTAssertEqual(
                    resolvedURL.standardizedFileURL,
                    canonicalWorkbook.standardizedFileURL
                )
                try FileManager.default.removeItem(at: workbooks)
                try FileManager.default.createSymbolicLink(
                    at: workbooks,
                    withDestinationURL: outsideWorkbooks
                )
            },
            idleScheduler: TestIdleScheduler().schedule
        )

        do {
            _ = try await coordinator.synchronize(
                makeRequest(bundle: bundle, fingerprint: fingerprint),
                intent: .updateAndView
            )
            XCTFail("Expected the swapped intermediate directory to be rejected")
        } catch {
            // The canonical workbook was resolved before the directory swap,
            // but opening must fail rather than follow the new symlink.
        }

        XCTAssertTrue(opened.isEmpty)
        XCTAssertTrue(openedBytes.isEmpty)
    }

    func testCleanFingerprintWithInvalidWorkbookUpdatesBeforeOpening() async throws {
        let bundle = bundleURL("clean-invalid-workbook")
        let fingerprint = try makeFingerprint("a")
        let publishedWorkbook = bundle.appendingPathComponent(
            "artifacts/workbooks/current.xlsx"
        )
        let runner = ControlledRunner()
        var opened: [URL] = []
        let coordinator = GenotypeCurrentWorkbookSyncCoordinator(
            recordedFingerprintLoader: { _ in fingerprint },
            currentWorkbookResolver: { _ in nil },
            updateRunner: { request, intent in
                try await runner.run(request, intent: intent)
            },
            workbookOpener: { opened.append($0) },
            idleScheduler: TestIdleScheduler().schedule
        )
        let request = makeRequest(bundle: bundle, fingerprint: fingerprint)

        let waiter = Task {
            try await coordinator.synchronize(request, intent: .updateAndView)
        }
        try await waitUntil { runner.invocations.count == 1 }

        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(coordinator.phase(for: bundle), .updating)

        runner.succeedInvocation(at: 0, with: publishedWorkbook)
        _ = try await waiter.value

        XCTAssertEqual(opened, [publishedWorkbook.standardizedFileURL])
        XCTAssertEqual(runner.invocations.count, 1)
    }

    func testDefaultWorkbookValidationRejectsMissingDirectoryAndSymlink() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GenotypeCurrentWorkbookSyncCoordinatorValidation-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temp,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temp) }
        let missing = temp.appendingPathComponent("missing.xlsx")
        let directory = temp.appendingPathComponent("directory.xlsx", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let regular = temp.appendingPathComponent("regular.xlsx")
        try Data("workbook".utf8).write(to: regular)
        let symlink = temp.appendingPathComponent("symlink.xlsx")
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: regular
        )

        XCTAssertNil(
            GenotypeCurrentWorkbookSyncCoordinator
                .validatedCurrentWorkbookURL(at: missing)
        )
        XCTAssertNil(
            GenotypeCurrentWorkbookSyncCoordinator
                .validatedCurrentWorkbookURL(at: directory)
        )
        XCTAssertNil(
            GenotypeCurrentWorkbookSyncCoordinator
                .validatedCurrentWorkbookURL(at: symlink)
        )
        XCTAssertEqual(
            GenotypeCurrentWorkbookSyncCoordinator
                .validatedCurrentWorkbookURL(at: regular),
            regular.standardizedFileURL
        )
    }

    func testDefaultResolverRejectsAbsoluteTraversalAndIntermediateSymlinkPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GenotypeCurrentWorkbookResolverSafety-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let outsideWorkbook = root.appendingPathComponent("outside.xlsx")
        try Data("outside".utf8).write(to: outsideWorkbook)

        let absoluteBundle = root.appendingPathComponent(
            "absolute.lungfishgenotype",
            isDirectory: true
        )
        try writeManifest(
            in: absoluteBundle,
            currentWorkbookPath: outsideWorkbook.path
        )
        XCTAssertNil(
            GenotypeCurrentWorkbookSyncCoordinator
                .resolvedValidatedCurrentWorkbookURL(in: absoluteBundle)
        )

        let traversalBundle = root.appendingPathComponent(
            "traversal.lungfishgenotype",
            isDirectory: true
        )
        try writeManifest(
            in: traversalBundle,
            currentWorkbookPath: "../outside.xlsx"
        )
        XCTAssertNil(
            GenotypeCurrentWorkbookSyncCoordinator
                .resolvedValidatedCurrentWorkbookURL(in: traversalBundle)
        )

        let symlinkBundle = root.appendingPathComponent(
            "symlink.lungfishgenotype",
            isDirectory: true
        )
        try writeManifest(
            in: symlinkBundle,
            currentWorkbookPath: "artifacts/workbooks/current.xlsx"
        )
        let outsideArtifacts = root.appendingPathComponent(
            "outside-artifacts",
            isDirectory: true
        )
        let outsideWorkbooks = outsideArtifacts.appendingPathComponent(
            "workbooks",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outsideWorkbooks,
            withIntermediateDirectories: true
        )
        try Data("linked".utf8).write(
            to: outsideWorkbooks.appendingPathComponent("current.xlsx")
        )
        try FileManager.default.createSymbolicLink(
            at: symlinkBundle.appendingPathComponent("artifacts"),
            withDestinationURL: outsideArtifacts
        )
        XCTAssertNil(
            GenotypeCurrentWorkbookSyncCoordinator
                .resolvedValidatedCurrentWorkbookURL(in: symlinkBundle)
        )

        let validBundle = root.appendingPathComponent(
            "valid.lungfishgenotype",
            isDirectory: true
        )
        try writeManifest(
            in: validBundle,
            currentWorkbookPath: "artifacts/workbooks/current.xlsx"
        )
        let validWorkbook = validBundle.appendingPathComponent(
            "artifacts/workbooks/current.xlsx"
        )
        try FileManager.default.createDirectory(
            at: validWorkbook.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("valid".utf8).write(to: validWorkbook)
        XCTAssertEqual(
            GenotypeCurrentWorkbookSyncCoordinator
                .resolvedValidatedCurrentWorkbookURL(in: validBundle),
            validWorkbook.standardizedFileURL
        )
    }

    func testWorkbookResolutionCannotOverwriteNewerDirtyGeneration() async throws {
        let bundle = bundleURL("resolver-race")
        let recorded = try makeFingerprint("a")
        let newer = try makeFingerprint("b")
        let resolver = ControlledWorkbookResolver()
        let runner = ControlledRunner()
        var opened: [URL] = []
        let coordinator = GenotypeCurrentWorkbookSyncCoordinator(
            recordedFingerprintLoader: { _ in recorded },
            currentWorkbookResolver: { bundle in
                await resolver.resolve(bundle)
            },
            updateRunner: { request, intent in
                try await runner.run(request, intent: intent)
            },
            workbookOpener: { opened.append($0) },
            idleScheduler: TestIdleScheduler().schedule
        )
        let cleanRequest = makeRequest(bundle: bundle, fingerprint: recorded)
        let newerRequest = makeRequest(bundle: bundle, fingerprint: newer)
        let waiter = Task {
            try await coordinator.synchronize(
                cleanRequest,
                intent: .updateAndView
            )
        }
        try await waitUntil { resolver.callCount == 1 }

        coordinator.markDirty(newerRequest)
        resolver.finish(
            with: bundle.appendingPathComponent("stale-current.xlsx")
        )
        try await waitUntil { runner.invocations.count == 1 }

        XCTAssertEqual(runner.invocations.first?.request.fingerprint, newer)
        XCTAssertTrue(opened.isEmpty)

        runner.succeedInvocation(at: 0)
        _ = try await waiter.value
        XCTAssertEqual(opened.count, 1)
        XCTAssertFalse(coordinator.testingHasRetainedRequest(for: bundle))
    }

    func testCompletedNewerGenerationForcesFreshResolutionBeforeOldWaiterOpens() async throws {
        let bundle = bundleURL("resolver-completed-generation")
        let recorded = try makeFingerprint("a")
        let newer = try makeFingerprint("b")
        let resolver = ControlledWorkbookResolver()
        let runner = ControlledRunner()
        runner.automaticallySucceed = true
        var opened: [URL] = []
        let coordinator = GenotypeCurrentWorkbookSyncCoordinator(
            recordedFingerprintLoader: { _ in recorded },
            currentWorkbookResolver: { bundle in
                await resolver.resolve(bundle)
            },
            updateRunner: { request, intent in
                try await runner.run(request, intent: intent)
            },
            workbookOpener: { opened.append($0) },
            idleScheduler: TestIdleScheduler().schedule
        )
        let oldWaiter = Task {
            try await coordinator.synchronize(
                makeRequest(bundle: bundle, fingerprint: recorded),
                intent: .updateAndView
            )
        }
        try await waitUntil { resolver.callCount == 1 }

        let newerWorkbook = try await coordinator.synchronize(
            makeRequest(bundle: bundle, fingerprint: newer),
            intent: .bundleSwitch
        )
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertTrue(opened.isEmpty)

        resolver.finish(with: bundle.appendingPathComponent("stale-a.xlsx"))
        try await waitUntil { resolver.callCount == 2 }
        XCTAssertTrue(opened.isEmpty)

        resolver.finish(with: newerWorkbook)
        let resolvedForOldWaiter = try await oldWaiter.value

        XCTAssertEqual(resolvedForOldWaiter, newerWorkbook)
        XCTAssertEqual(opened, [newerWorkbook])
        XCTAssertEqual(coordinator.phase(for: bundle), .current)
    }

    func testFailedNewerGenerationNeverOpensStaleResolverResult() async throws {
        let bundle = bundleURL("resolver-failed-generation")
        let recorded = try makeFingerprint("a")
        let newer = try makeFingerprint("b")
        let resolver = ControlledWorkbookResolver()
        let runner = ControlledRunner()
        runner.failNext = TestError.expected
        var opened: [URL] = []
        let coordinator = GenotypeCurrentWorkbookSyncCoordinator(
            recordedFingerprintLoader: { _ in recorded },
            currentWorkbookResolver: { bundle in
                await resolver.resolve(bundle)
            },
            updateRunner: { request, intent in
                try await runner.run(request, intent: intent)
            },
            workbookOpener: { opened.append($0) },
            idleScheduler: TestIdleScheduler().schedule
        )
        let oldWaiter = Task {
            try await coordinator.synchronize(
                makeRequest(bundle: bundle, fingerprint: recorded),
                intent: .updateAndView
            )
        }
        try await waitUntil { resolver.callCount == 1 }

        do {
            _ = try await coordinator.synchronize(
                makeRequest(bundle: bundle, fingerprint: newer),
                intent: .bundleSwitch
            )
            XCTFail("Expected the newer generation update to fail")
        } catch TestError.expected {}
        guard case .failed = coordinator.phase(for: bundle) else {
            return XCTFail("Expected the newer generation to remain failed")
        }

        resolver.finish(with: bundle.appendingPathComponent("stale-a.xlsx"))
        do {
            _ = try await oldWaiter.value
            XCTFail("Expected the old waiter to observe the newer failure")
        } catch {}

        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(resolver.callCount, 1)
        guard case .failed = coordinator.phase(for: bundle) else {
            return XCTFail("Expected the newer generation to remain failed")
        }
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

    func testAnnotationOnlyRequestPreservesNonemptySemanticCallsForRunner() async throws {
        let bundle = bundleURL("annotation-semantic-calls")
        let fingerprint = try makeFingerprint("b")
        let calls = [
            GenotypeWorkbookHaplotypeCall(
                sample: "semantic-sample",
                locus: "MHC-DP",
                haplotype1: "DP1",
                haplotype2: "DP2",
                status: "reviewed",
                notes: "must survive annotation-only coordination"
            ),
        ]
        let runner = ControlledRunner()
        runner.automaticallySucceed = true
        let coordinator = makeCoordinator(recorded: nil, runner: runner)
        let request = GenotypeCurrentWorkbookSyncCoordinator.Request(
            bundleURL: bundle,
            calls: calls,
            includedLoci: ["MHC-DP"],
            annotationSidecarURL: bundle.appendingPathComponent("annotations.json"),
            annotationOnly: true,
            fingerprint: fingerprint,
            routeContext: nil
        )

        _ = try await coordinator.synchronize(request, intent: .automaticIdle)

        XCTAssertEqual(runner.invocations.first?.request.calls, calls)
        XCTAssertEqual(runner.invocations.first?.request.includedLoci, ["MHC-DP"])
        XCTAssertEqual(runner.invocations.first?.request.annotationOnly, true)
    }

    func testHaplotypedMiSeqEffectiveCallsAndFinalAnnotationPayloadReachNextPublication()
        async throws {
        let bundle = bundleURL("miseq-effective-call-publication")
        let finalAnnotationURL = bundle.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-08-04T00:00:00Z"
        )
        sidecar.callOverrides = [
            .init(
                sample: "Sample-A",
                locus: "MHC-A",
                slot: .h2,
                originalCall: "A2",
                overrideCall: "A2-review",
                reasonTag: .misCall,
                rationale: "Confirmed in synchronized Calls and Matrix views",
                author: "Analyst",
                timestamp: "2026-08-04T00:01:00Z"
            ),
        ]
        let annotationData = try sidecar.encoded()
        let effectiveCalls = [
            GenotypeWorkbookHaplotypeCall(
                sample: "Sample-A", locus: "MHC-A",
                haplotype1: "A1", haplotype2: "A2-review",
                status: "called", notes: ""
            ),
            GenotypeWorkbookHaplotypeCall(
                sample: "Sample-B", locus: "MHC-B",
                haplotype1: "D1", haplotype2: "D2",
                status: "called", notes: ""
            ),
        ]
        let runner = ControlledRunner()
        runner.automaticallySucceed = true
        let coordinator = makeCoordinator(recorded: nil, runner: runner)
        let request = GenotypeCurrentWorkbookSyncCoordinator.Request(
            bundleURL: bundle,
            calls: effectiveCalls,
            includedLoci: ["MHC-A", "MHC-B"],
            annotationSidecarURL: finalAnnotationURL,
            annotationSidecarData: annotationData,
            annotationOnly: false,
            haplotypeProjectionMode: .haplotyped,
            fingerprint: try makeFingerprint("a"),
            routeContext: nil
        )

        _ = try await coordinator.synchronize(
            request,
            intent: .automaticIdle
        )

        let admitted = try XCTUnwrap(runner.invocations.first?.request)
        XCTAssertEqual(admitted.calls, effectiveCalls)
        XCTAssertEqual(admitted.includedLoci, ["MHC-A", "MHC-B"])
        XCTAssertEqual(
            admitted.annotationSidecarURL,
            finalAnnotationURL.standardizedFileURL,
            "Publication provenance must identify the final stored sidecar, not staging."
        )
        XCTAssertEqual(admitted.annotationSidecarData, annotationData)
        XCTAssertEqual(admitted.haplotypeProjectionMode, .haplotyped)
        XCTAssertFalse(admitted.annotationOnly)
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
        try await waitUntil { runner.invocations.count == 1 }
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
        try await waitUntil { loader.callCount == 1 }
        loader.finish(with: nil)
        try await waitUntil { runner.invocations.count >= 1 }
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
        try await waitUntil { runner.invocations.count == 1 }
        let explicitWaiter = Task {
            try await coordinator.synchronize(middle, intent: .updateAndView)
        }
        let latestWaiter = Task {
            try await coordinator.synchronize(latest, intent: .bundleSwitch)
        }
        try await waitUntil {
            coordinator.phase(for: bundle) == .dirtyWhileUpdating
        }
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
        try await waitUntil { runner.invocations.count == 2 }

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
        try await waitUntil { runner.invocations.count == 1 }
        coordinator.markDirty(recordedRequest)

        XCTAssertEqual(coordinator.phase(for: bundle), .dirtyWhileUpdating)
        runner.succeedInvocation(at: 0)
        try await waitUntil { runner.invocations.count == 2 }
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
        try await waitUntil { runner.invocations.count == 2 }

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
        try await waitUntil { runner.invocations.count == 1 }

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

    func testRegisterCleanReloadHasNoTimerOrRunnerInvocation() async throws {
        let bundle = bundleURL("register-clean")
        let fingerprint = try makeFingerprint("6")
        let scheduler = TestIdleScheduler()
        let runner = ControlledRunner()
        let coordinator = makeCoordinator(
            recorded: fingerprint,
            runner: runner,
            scheduler: scheduler
        )

        await coordinator.register(
            makeRequest(bundle: bundle, fingerprint: fingerprint)
        )

        XCTAssertEqual(coordinator.phase(for: bundle), .current)
        XCTAssertTrue(scheduler.tokens.isEmpty)
        XCTAssertTrue(runner.invocations.isEmpty)
        XCTAssertFalse(coordinator.testingHasRetainedRequest(for: bundle))
    }

    func testRegisterDirtyReloadSchedulesOneIdleWithoutRunningImmediately() async throws {
        let bundle = bundleURL("register-dirty")
        let scheduler = TestIdleScheduler()
        let runner = ControlledRunner()
        let coordinator = makeCoordinator(
            recorded: try makeFingerprint("6"),
            runner: runner,
            scheduler: scheduler
        )

        await coordinator.register(
            makeRequest(bundle: bundle, fingerprint: try makeFingerprint("7"))
        )

        XCTAssertEqual(coordinator.phase(for: bundle), .dirty)
        XCTAssertEqual(scheduler.tokens.filter { !$0.cancelled }.count, 1)
        XCTAssertEqual(
            scheduler.delays,
            [GenotypeCurrentWorkbookSyncCoordinator.idleDelayNanoseconds]
        )
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testUnauthorizedDirtyRegistrationDoesNotArmIdleUpdate() async throws {
        let bundle = bundleURL("unauthorized-register")
        let scheduler = TestIdleScheduler()
        let runner = ControlledRunner()
        let coordinator = makeCoordinator(
            recorded: nil,
            runner: runner,
            scheduler: scheduler
        )
        let request = makeRequest(
            bundle: bundle,
            fingerprint: try makeFingerprint("7"),
            mayUpdate: false
        )

        await coordinator.register(request)

        XCTAssertEqual(coordinator.phase(for: bundle), .dirty)
        XCTAssertTrue(scheduler.delays.isEmpty)
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testUnauthorizedDirtySynchronizeFailsWithoutRunnerOrOpen() async throws {
        let bundle = bundleURL("unauthorized-sync")
        let runner = ControlledRunner()
        var opened: [URL] = []
        let coordinator = makeCoordinator(
            recorded: nil,
            runner: runner,
            opened: { opened.append($0) }
        )
        let request = makeRequest(
            bundle: bundle,
            fingerprint: try makeFingerprint("8"),
            mayUpdate: false
        )

        do {
            _ = try await coordinator.synchronize(request, intent: .updateAndView)
            XCTFail("Expected unauthorized dirty synchronization to fail")
        } catch {
            XCTAssertEqual(
                (error as NSError).localizedDescription,
                "This current workbook is out of date and cannot be updated in the active project session."
            )
        }

        XCTAssertTrue(runner.invocations.isEmpty)
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(coordinator.phase(for: bundle), .dirty)
    }

    func testUnauthorizedVerifiedCurrentRequestMayOpenWithoutRunner() async throws {
        let bundle = bundleURL("unauthorized-clean-open")
        let workbook = bundle.appendingPathComponent("current.xlsx")
        let fingerprint = try makeFingerprint("9")
        let runner = ControlledRunner()
        var opened: [URL] = []
        let coordinator = makeCoordinator(
            recorded: fingerprint,
            runner: runner,
            workbookURL: workbook,
            opened: { opened.append($0) }
        )
        let request = makeRequest(
            bundle: bundle,
            fingerprint: fingerprint,
            mayUpdate: false
        )

        let resolved = try await coordinator.synchronize(
            request,
            intent: .updateAndView
        )

        XCTAssertEqual(resolved, workbook.standardizedFileURL)
        XCTAssertTrue(runner.invocations.isEmpty)
        XCTAssertEqual(opened, [workbook.standardizedFileURL])
    }

    func testIdleRevalidatesAuthorizationAfterDirtyRegistration() async throws {
        let bundle = bundleURL("fresh-authorization-idle")
        let scheduler = TestIdleScheduler()
        let runner = ControlledRunner()
        runner.automaticallySucceed = true
        let authorization = WorkbookAuthorizationGate()
        let coordinator = makeCoordinator(
            recorded: nil,
            runner: runner,
            scheduler: scheduler
        )
        let request = makeRequest(
            bundle: bundle,
            fingerprint: try makeFingerprint("a"),
            authorizationRevalidator: { authorization.isAllowed }
        )

        await coordinator.register(request)
        XCTAssertEqual(scheduler.tokens.filter { !$0.cancelled }.count, 1)

        authorization.isAllowed = false
        await scheduler.tokens[0].fire()

        XCTAssertTrue(runner.invocations.isEmpty)
        XCTAssertEqual(coordinator.phase(for: bundle), .dirty)
    }

    func testFollowUpRevalidatesAuthorizationImmediatelyBeforeRunnerAdmission()
        async throws {
        let bundle = bundleURL("fresh-authorization-follow-up")
        let runner = ControlledRunner()
        let authorization = WorkbookAuthorizationGate()
        let coordinator = makeCoordinator(recorded: nil, runner: runner)
        let first = makeRequest(
            bundle: bundle,
            fingerprint: try makeFingerprint("b"),
            authorizationRevalidator: { authorization.isAllowed }
        )
        let followUp = makeRequest(
            bundle: bundle,
            fingerprint: try makeFingerprint("c"),
            authorizationRevalidator: { authorization.isAllowed }
        )

        let waiter = Task {
            try await coordinator.synchronize(first, intent: .automaticIdle)
        }
        try await waitUntil { runner.invocations.count == 1 }
        coordinator.markDirty(followUp)
        authorization.isAllowed = false
        runner.succeedInvocation(at: 0)

        do {
            _ = try await waiter.value
            XCTFail("Expected the denied follow-up to fail closed")
        } catch {
            XCTAssertEqual(
                (error as NSError).localizedDescription,
                "This current workbook is out of date and cannot be updated in the active project session."
            )
        }
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(coordinator.phase(for: bundle), .dirty)
    }

    func testUpdatingObserverAuthorizationRevocationPreventsRunnerAdmission()
        async throws {
        let bundle = bundleURL("observer-revokes-authorization")
        let runner = ControlledRunner()
        runner.automaticallySucceed = true
        let authorization = WorkbookAuthorizationGate()
        let coordinator = makeCoordinator(recorded: nil, runner: runner)
        let observer = ObserverOwner()
        let observation = coordinator.observe(observer) {
            owner,
            _,
            phase in
            owner.phases.append(phase)
            if phase == .updating {
                authorization.isAllowed = false
            }
        }
        let request = makeRequest(
            bundle: bundle,
            fingerprint: try makeFingerprint("d"),
            authorizationRevalidator: { authorization.isAllowed }
        )

        do {
            _ = try await coordinator.synchronize(
                request,
                intent: .automaticIdle
            )
            XCTFail("Expected observer revocation to deny publication")
        } catch {
            XCTAssertEqual(
                (error as NSError).localizedDescription,
                "This current workbook is out of date and cannot be updated in the active project session."
            )
        }

        XCTAssertTrue(runner.invocations.isEmpty)
        XCTAssertEqual(coordinator.phase(for: bundle), .dirty)
        withExtendedLifetime(observation) {}
    }

    func testUpdatingObserverNewerDeniedRequestSupersedesRunnerAdmission()
        async throws {
        let bundle = bundleURL("observer-supersedes-admission")
        let runner = ControlledRunner()
        runner.automaticallySucceed = true
        let newerAuthorization = WorkbookAuthorizationGate()
        newerAuthorization.isAllowed = false
        let coordinator = makeCoordinator(recorded: nil, runner: runner)
        let original = makeRequest(
            bundle: bundle,
            fingerprint: try makeFingerprint("e"),
            authorizationRevalidator: { true }
        )
        let newer = makeRequest(
            bundle: bundle,
            fingerprint: try makeFingerprint("f"),
            authorizationRevalidator: { newerAuthorization.isAllowed }
        )
        let observer = ObserverOwner()
        var installedNewerRequest = false
        let observation = coordinator.observe(observer) {
            owner,
            _,
            phase in
            owner.phases.append(phase)
            guard phase == .updating, !installedNewerRequest else {
                return
            }
            installedNewerRequest = true
            coordinator.markDirty(newer)
        }

        do {
            _ = try await coordinator.synchronize(
                original,
                intent: .automaticIdle
            )
            XCTFail("Expected the newer denied request to fail closed")
        } catch {
            XCTAssertEqual(
                (error as NSError).localizedDescription,
                "This current workbook is out of date and cannot be updated in the active project session."
            )
        }

        XCTAssertTrue(runner.invocations.isEmpty)
        XCTAssertEqual(coordinator.phase(for: bundle), .dirty)
        XCTAssertTrue(coordinator.testingHasRetainedRequest(for: bundle))

        newerAuthorization.isAllowed = true
        _ = try await coordinator.synchronize(newer, intent: .bundleSwitch)

        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(
            runner.invocations.first?.request.fingerprint,
            newer.fingerprint
        )
        withExtendedLifetime(observation) {}
    }

    func testUpdatingObserverNewerAuthorizedRequestIsOnlyRunnerAdmission()
        async throws {
        let bundle = bundleURL("observer-authorized-supersession")
        let runner = ControlledRunner()
        runner.automaticallySucceed = true
        let coordinator = makeCoordinator(recorded: nil, runner: runner)
        let original = makeRequest(
            bundle: bundle,
            fingerprint: try makeFingerprint("1")
        )
        let newer = makeRequest(
            bundle: bundle,
            fingerprint: try makeFingerprint("2")
        )
        let observer = ObserverOwner()
        var installedNewerRequest = false
        let observation = coordinator.observe(observer) {
            owner,
            _,
            phase in
            owner.phases.append(phase)
            guard phase == .updating, !installedNewerRequest else {
                return
            }
            installedNewerRequest = true
            coordinator.markDirty(newer)
        }

        _ = try await coordinator.synchronize(
            original,
            intent: .automaticIdle
        )

        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(
            runner.invocations.first?.request.fingerprint,
            newer.fingerprint
        )
        XCTAssertEqual(coordinator.phase(for: bundle), .current)
        XCTAssertFalse(coordinator.testingHasRetainedRequest(for: bundle))
        withExtendedLifetime(observation) {}
    }

    func testStaleRegistrationLoaderCannotOverwriteNewerDirtyRequest() async throws {
        let bundle = bundleURL("register-race")
        let recorded = try makeFingerprint("8")
        let newer = try makeFingerprint("9")
        let loader = ControlledFingerprintLoader()
        let scheduler = TestIdleScheduler()
        let runner = ControlledRunner()
        runner.automaticallySucceed = true
        let coordinator = GenotypeCurrentWorkbookSyncCoordinator(
            recordedFingerprintLoader: { bundle in
                await loader.load(bundle)
            },
            currentWorkbookResolver: { bundle in
                bundle.appendingPathComponent("artifacts/workbooks/current.xlsx")
            },
            updateRunner: { request, intent in
                try await runner.run(request, intent: intent)
            },
            workbookOpener: { _ in },
            idleScheduler: scheduler.schedule
        )
        let registration = Task {
            await coordinator.register(
                makeRequest(bundle: bundle, fingerprint: recorded)
            )
        }
        try await waitUntil { loader.callCount == 1 }

        coordinator.markDirty(
            makeRequest(bundle: bundle, fingerprint: newer)
        )
        loader.finish(with: recorded)
        await registration.value

        XCTAssertEqual(coordinator.phase(for: bundle), .dirty)
        XCTAssertEqual(scheduler.tokens.filter { !$0.cancelled }.count, 1)
        await scheduler.tokens.last?.fire()
        try await waitUntil { runner.invocations.count == 1 }
        XCTAssertEqual(runner.invocations.first?.request.fingerprint, newer)
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

    func testTerminalCurrentAndFailedStatesReleaseRequestPayload() async throws {
        let bundle = bundleURL("terminal-retention")
        let first = makeRequest(
            bundle: bundle,
            fingerprint: try makeFingerprint("a")
        )
        let second = makeRequest(
            bundle: bundle,
            fingerprint: try makeFingerprint("b")
        )
        let runner = ControlledRunner()
        runner.automaticallySucceed = true
        let coordinator = makeCoordinator(recorded: nil, runner: runner)

        _ = try await coordinator.synchronize(first, intent: .automaticIdle)
        XCTAssertFalse(coordinator.testingHasRetainedRequest(for: bundle))

        coordinator.markDirty(first)
        XCTAssertEqual(coordinator.phase(for: bundle), .current)
        XCTAssertFalse(coordinator.testingHasRetainedRequest(for: bundle))

        runner.automaticallySucceed = false
        runner.failNext = TestError.expected
        do {
            _ = try await coordinator.synchronize(second, intent: .automaticIdle)
            XCTFail("Expected failure")
        } catch TestError.expected {}

        guard case .failed = coordinator.phase(for: bundle) else {
            return XCTFail("Expected failed terminal phase")
        }
        XCTAssertFalse(coordinator.testingHasRetainedRequest(for: bundle))
    }

    /// R3-R3ML-3: a markDirty/register call that lands *while* the update runner is
    /// actively executing (after admission, before completion) installs a newer
    /// latestRequest and bumps state.generation -- the .dirtyWhileUpdating path exists
    /// specifically to track this. If the in-flight update then fails, that edit must
    /// not be silently discarded: the coordinator should surface .dirty with the newer
    /// request retained (so a future synchronize/markDirty picks it back up), not
    /// .failed with latestRequest cleared to nil.
    func testFailureDuringSupersedingEditRetriesRatherThanDiscardingNewerRequest() async throws {
        let bundle = bundleURL("supersede-during-failure")
        let original = try makeFingerprint("a")
        let superseding = try makeFingerprint("b")
        let runner = ControlledRunner()
        let coordinator = makeCoordinator(recorded: nil, runner: runner)
        let originalRequest = makeRequest(bundle: bundle, fingerprint: original)
        let supersedingRequest = makeRequest(bundle: bundle, fingerprint: superseding)

        let waiter = Task {
            try await coordinator.synchronize(originalRequest, intent: .automaticIdle)
        }
        try await waitUntil { runner.invocations.count == 1 }
        XCTAssertEqual(coordinator.phase(for: bundle), .updating)

        // A user edit arrives while the update is in flight -- this must bump
        // state.generation and install `supersedingRequest` as latestRequest via the
        // .dirtyWhileUpdating path (markDirty when state.operation != nil).
        coordinator.markDirty(supersedingRequest)

        // Now the in-flight update (for the *original*, now-stale generation) fails.
        runner.failInvocation(at: 0, with: TestError.expected)

        do {
            _ = try await waiter.value
            XCTFail("Expected the original waiter to observe a failure")
        } catch {}

        // The superseding edit must not be discarded: the coordinator should be
        // .dirty (retryable) with the superseding request retained, not .failed with
        // the request cleared to nil.
        XCTAssertEqual(coordinator.phase(for: bundle), .dirty)
        XCTAssertTrue(coordinator.testingHasRetainedRequest(for: bundle))
        XCTAssertEqual(
            coordinator.testingRetainedRequestFingerprint(for: bundle),
            superseding
        )

        // The retained edit can still be picked up and successfully applied later.
        runner.automaticallySucceed = true
        _ = try await coordinator.synchronize(supersedingRequest, intent: .automaticIdle)
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

    func testObserverSnapshotAllowsSelfCancellationAdditionAndNestedTransition() async throws {
        let bundle = bundleURL("observer-reentrant")
        let currentFingerprint = try makeFingerprint("a")
        let dirtyFingerprint = try makeFingerprint("b")
        let runner = ControlledRunner()
        let coordinator = makeCoordinator(
            recorded: currentFingerprint,
            runner: runner
        )
        let currentRequest = makeRequest(
            bundle: bundle,
            fingerprint: currentFingerprint
        )
        _ = try await coordinator.synchronize(
            currentRequest,
            intent: .automaticIdle
        )
        let firstOwner = ObserverOwner()
        let addedOwner = ObserverOwner()
        var firstObservation:
            GenotypeCurrentWorkbookSyncCoordinator.Observation?
        var addedObservation:
            GenotypeCurrentWorkbookSyncCoordinator.Observation?
        firstObservation = coordinator.observe(firstOwner) {
            owner, _, phase in
            owner.phases.append(phase)
            guard phase == .dirty else {
                return
            }
            firstObservation?.cancel()
            addedObservation = coordinator.observe(addedOwner) {
                addedOwner, _, addedPhase in
                addedOwner.phases.append(addedPhase)
            }
            coordinator.markDirty(currentRequest)
        }

        coordinator.markDirty(
            makeRequest(bundle: bundle, fingerprint: dirtyFingerprint)
        )

        XCTAssertEqual(firstOwner.phases, [.dirty])
        XCTAssertEqual(addedOwner.phases, [.current])
        withExtendedLifetime((firstObservation, addedObservation)) {}
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

    private func writeManifest(
        in bundleURL: URL,
        currentWorkbookPath: String
    ) throws {
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: bundleURL.deletingPathExtension().lastPathComponent,
            analysisName: "sync-coordinator-test",
            primaryWorkbookPath: "primary.xlsx",
            currentWorkbookPath: currentWorkbookPath,
            longSummaryCSVPath: "long.csv",
            sampleSummaryCSVPath: "samples.csv",
            statsJSONPath: "stats.json",
            provenancePath: "provenance.json"
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)
    }

    private func workbookUpdatePayloadJSON(for bundleURL: URL) throws -> String {
        let object: [String: Any] = [
            "bundlePath": bundleURL.standardizedFileURL.path,
            "currentWorkbookPath": bundleURL
                .appendingPathComponent("artifacts/workbooks/current.xlsx")
                .standardizedFileURL.path,
            "manifestPath": ONTGenotypeResultBundle
                .manifestURL(in: bundleURL)
                .standardizedFileURL.path,
            "cleanupPending": false,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func makeRequest(
        bundle: URL,
        fingerprint: GenotypeCurrentWorkbookInputFingerprint,
        mayUpdate: Bool = true,
        authorizationRevalidator:
            (@MainActor @Sendable () -> Bool)? = nil
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
            calls: displayed,
            includedLoci: ["MHC-A"],
            annotationSidecarURL: bundle.appendingPathComponent("annotations.json"),
            annotationOnly: false,
            fingerprint: fingerprint,
            routeContext: OperationRouteContext(projectURL: nil, windowStateScopeID: nil),
            mayUpdate: mayUpdate,
            authorizationRevalidator: authorizationRevalidator
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

    private func makeCatalogFingerprint(
        path: String,
        checksumCharacter: Character,
        size: Int64,
        schemaVersion: Int
    ) throws -> GenotypeCurrentWorkbookInputFingerprint {
        try GenotypeCurrentWorkbookInputFingerprint.make(
            calls: [],
            includedLoci: [],
            annotationSidecar: nil,
            candidateArtifacts: nil,
            reviewableRowCatalog: ONTMHCArtifactReference(
                path: path,
                sha256: String(repeating: checksumCharacter, count: 64),
                sizeBytes: size
            ),
            reviewableRowCatalogSchemaVersion: schemaVersion
        )
    }

    private func bundleURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(name).lungfishgenotype", isDirectory: true)
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<1_000 {
            if predicate() {
                return
            }
            await Task.yield()
        }
        throw TestError.timedOut
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

    func failInvocation(at index: Int, with error: Error) {
        guard let continuation = continuations.removeValue(forKey: index) else {
            XCTFail("No suspended invocation at index \(index)")
            return
        }
        activeCount -= 1
        continuation.resume(throwing: error)
    }

    private func defaultWorkbookURL(
        for request: GenotypeCurrentWorkbookSyncCoordinator.Request
    ) -> URL {
        request.bundleURL.appendingPathComponent("artifacts/workbooks/current.xlsx")
    }
}

@MainActor
private final class IdentityHandoffCLIProcessRunner:
    LocalWorkflowCLIProcessRunning {
    let result: LocalWorkflowCLIProcessResult

    init(result: LocalWorkflowCLIProcessResult) {
        self.result = result
    }

    func runLungfishCLI(
        arguments: [String],
        workingDirectory: URL,
        outputHandler:
            (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?
    ) async throws -> LocalWorkflowCLIProcessResult {
        if let outputHandler {
            for line in result.standardError.split(whereSeparator: \.isNewline) {
                outputHandler(.standardError(String(line)))
            }
            for line in result.standardOutput.split(whereSeparator: \.isNewline) {
                outputHandler(.standardOutput(String(line)))
            }
        }
        return LocalWorkflowCLIProcessResult(
            exitCode: result.exitCode,
            standardOutput: result.standardOutput,
            standardError: result.standardError,
            didStreamOutput: outputHandler != nil
        )
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
private final class ControlledWorkbookResolver {
    private(set) var callCount = 0
    private var continuation: CheckedContinuation<URL?, Never>?

    func resolve(_ bundleURL: URL) async -> URL? {
        callCount += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func finish(with workbookURL: URL?) {
        continuation?.resume(returning: workbookURL)
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

@MainActor
private final class WorkbookAuthorizationGate {
    var isAllowed = true
}

private enum TestError: Error {
    case expected
    case timedOut
}
