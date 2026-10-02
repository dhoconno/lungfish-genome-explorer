// PrimerDesignOperationOperationTests.swift - The primer design row's lock, command and refusal
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The primer design row locks the analysis bundle it writes (R4). A held lock
// must refuse the row and launch no worker. The run has no recorded
// lungfish-cli command yet, because the app has no builder from the dialog's
// settings to `lungfish-cli primers design`. Its tests pin today's values, the
// nil command at begin and the native tool argv that arrives through
// `setCommand`, so a command added later fails here and prompts a parse test.

import XCTest
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class PrimerDesignOperationOperationTests: XCTestCase {
    private let destination = URL(
        fileURLWithPath: "/tmp/lane 1a2/Project.lungfish/Analyses/Primer3 Test.lungfishprimeranalysis",
        isDirectory: true
    )

    private func centerHoldingBundleLock() throws -> OperationCenter {
        let center = OperationCenter()
        _ = try XCTUnwrap(center.begin(
            title: "Existing writer",
            detail: "Running",
            operationType: .workflow,
            targetBundleURL: destination,
            cliCommand: "lungfish-cli primers design primer3"
        ).startedID)
        return center
    }

    // MARK: - begin helper

    func testRefusedByAHeldBundleLockLaunchesNothing() throws {
        let center = try centerHoldingBundleLock()
        var launched = false

        let result = PrimerDesignOperation.beginPrimerDesignOperation(
            title: "Primer3 · Test",
            destination: destination,
            routeContext: nil,
            reporter: center
        ) { _ in launched = true }

        guard case .refused(let refusal) = result else {
            return XCTFail("a held destination lock must refuse the primer design row")
        }
        XCTAssertFalse(launched, "a refused row must launch no worker")
        XCTAssertEqual(refusal.blockingOperationTitle, "Existing writer")
    }

    func testRecordsItsTypeAndLockWithNoCommandAsAParityGap() throws {
        let reporter = RecordingOperationReporter()
        let routeContext = OperationRouteContext(projectURL: nil, windowStateScopeID: UUID())
        var launchedID: UUID?

        PrimerDesignOperation.beginPrimerDesignOperation(
            title: "Primer3 · Test",
            destination: destination,
            routeContext: routeContext,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "Primer3 · Test")
        XCTAssertEqual(item.initialDetail, "Preparing primer design…")
        XCTAssertEqual(item.operationType, .workflow)
        XCTAssertEqual(item.targetBundleURL, destination)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        // CLI parity gap. The app has no builder from the dialog's settings to
        // `lungfish-cli primers design primer3|primalscheme3|olivar|varvamp`, so
        // the row records no command when it starts. When one exists, record
        // it and replace this pin with a parse test.
        XCTAssertNil(item.cliCommand)
        XCTAssertThrowsError(try RecordedCLICommand.parse(item.cliCommand))
    }

    // MARK: - start

    func testTheNativeToolArgvReplacesTheCommandAndDoesNotParseAsALungfishCommand() async throws {
        let reporter = RecordingOperationReporter()
        let gate = AsyncStream<Void>.makeStream()
        let argv = ["/path with spaces/primer3_core", "--format_output", "/tmp/lane 1a2/primer3 input.txt"]
        let output = destination
        let handle = PrimerDesignOperation.start(
            center: reporter,
            title: "Primer3 · Test",
            destination: output,
            routeContext: nil,
            operation: { _ in
                NativeProcessObservation.onEvent?(.started(argv: argv))
                for await _ in gate.stream { break }
                return output
            },
            onResultSaved: { _ in }
        )

        XCTAssertNil(reporter.item(handle.id)?.cliCommand, "the row starts with no command")
        await waitUntil { reporter.item(handle.id)?.cliCommand != nil }
        let command = try XCTUnwrap(reporter.item(handle.id)?.cliCommand)
        // CLI parity gap. The native argv is what the row records today, and it
        // is not a lungfish-cli command.
        XCTAssertEqual(command, argv.map(shellEscape).joined(separator: " "))
        XCTAssertThrowsError(try RecordedCLICommand.parse(command)) { error in
            guard case RecordedCLICommand.ParseError.notALungfishCLICommand = error else {
                return XCTFail("expected a command that is not lungfish-cli, got \(error)")
            }
        }
        gate.continuation.finish()
        await handle.task.value
        XCTAssertEqual(reporter.item(handle.id)?.state, .completed)
        XCTAssertEqual(reporter.item(handle.id)?.outputURLs, [destination])
    }

    func testARefusedStartRunsNoWorkerAndHandsBackTheRefusedRow() async throws {
        let reporter = RecordingOperationReporter(lockHeldBy: "Existing writer")
        let output = destination
        let handle = PrimerDesignOperation.start(
            center: reporter,
            title: "Primer3 · Test",
            destination: output,
            routeContext: nil,
            operation: { _ in
                XCTFail("a refused row must not run the design")
                return output
            },
            onResultSaved: { _ in XCTFail("a refused row must not publish a result") }
        )

        await handle.task.value

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(handle.id, item.id)
        XCTAssertEqual(item.state, .refused)
        XCTAssertFalse(item.hasCancelCallback)
        XCTAssertTrue(item.logs.isEmpty)
    }
}
