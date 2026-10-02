import Foundation
import XCTest
import LungfishKit
import LungfishWorkflow
@testable import LungfishApp
import LungfishTestSupport

@MainActor
final class PrimerDesignOperationTests: XCTestCase {
  func testRegistersBeforeExecutionAndPreservesOriginAndResult() async throws {
    let center = OperationCenter()
    center.failureReportStore = .temporaryForTesting()
    let project = URL(fileURLWithPath: "/tmp/primer-origin")
    let output = project.appendingPathComponent("Analyses/Test.lungfishprimeranalysis")
    let route = OperationRouteContext(projectURL: project, windowStateScopeID: UUID())
    var saved: URL?
    let handle = PrimerDesignOperation.start(center: center, title: "Primer3 · Test",
      destination: output, routeContext: route, operation: { progress in
        progress(0.4, "Designing candidates")
        await Task.yield()
        return output
      }, onResultSaved: { saved = $0 })
    XCTAssertEqual(center.items.first?.state, .running)
    XCTAssertEqual(center.items.first?.routeContext, route)
    XCTAssertEqual(center.items.first?.targetBundleURL, output)
    await handle.task.value
    XCTAssertEqual(center.items.first?.state, .completed)
    XCTAssertEqual(center.items.first?.outputURLs, [output])
    XCTAssertEqual(saved, output)
  }

  func testProgressIsVisibleBeforeWorkerCompletes() async throws {
    let center = OperationCenter()
    center.failureReportStore = .temporaryForTesting()
    let gate = AsyncStream<Void>.makeStream()
    let output = URL(fileURLWithPath: "/tmp/progress.lungfishprimeranalysis")
    let handle = PrimerDesignOperation.start(center: center, title: "PrimalScheme",
      destination: output, routeContext: nil, operation: { progress in
        progress(0.25, "Preparing saved alignment")
        for await _ in gate.stream { break }
        return output
      }, onResultSaved: { _ in })
    await waitUntil { center.items.first?.progress == 0.25 }
    XCTAssertEqual(center.items.first?.state, .running)
    XCTAssertEqual(center.items.first?.progress, 0.25)
    XCTAssertEqual(center.items.first?.detail, "Preparing saved alignment")
    gate.continuation.finish()
    await handle.task.value
    XCTAssertEqual(center.items.first?.state, .completed)
  }

  func testNativeLogsAndExecutedCommandAreVisibleBeforeWorkerCompletes() async throws {
    let center = OperationCenter()
    center.failureReportStore = .temporaryForTesting()
    let gate = AsyncStream<Void>.makeStream()
    let output = URL(fileURLWithPath: "/tmp/streaming.lungfishprimeranalysis")
    let handle = PrimerDesignOperation.start(center: center, title: "Native workflow",
      destination: output, routeContext: nil, operation: { _ in
        NativeProcessObservation.onEvent?(.started(argv: ["/path with spaces/python", "adapter.py"]))
        NativeProcessObservation.onEvent?(.output(stream: .stdout, line: "Live native output"))
        NativeProcessObservation.onEvent?(.output(stream: .stderr, line: "Native progress on stderr"))
        for await _ in gate.stream { break }
        return output
      }, onResultSaved: { _ in })
    await waitUntil { center.items.first?.logEntries.contains(where: { $0.message == "Native progress on stderr" }) == true }
    XCTAssertEqual(center.items.first?.state, .running)
    XCTAssertEqual(center.items.first?.cliCommand, ["/path with spaces/python", "adapter.py"].map(shellEscape).joined(separator: " "))
    XCTAssertTrue(center.items.first?.logEntries.contains(where: { $0.message == "Live native output" }) == true)
    XCTAssertTrue(center.items.first?.logEntries.contains(where: { $0.message == "Native progress on stderr" && $0.level == .info }) == true)
    gate.continuation.finish()
    await handle.task.value
    XCTAssertEqual(center.items.first?.state, .completed)
  }

  func testFailureIsVisible() async {
    let center = OperationCenter()
    center.failureReportStore = .temporaryForTesting()
    let handle = PrimerDesignOperation.start(center: center, title: "PrimalScheme",
      destination: URL(fileURLWithPath: "/tmp/failed.lungfishprimeranalysis"), routeContext: nil,
      operation: { _ in throw NSError(domain: "design", code: 1, userInfo: [NSLocalizedDescriptionKey: "Design failed"]) },
      onResultSaved: { _ in XCTFail("Failed operation must not publish a result") })
    await handle.task.value
    XCTAssertEqual(center.items.first?.state, .failed)
    XCTAssertEqual(center.items.first?.errorMessage, "Design failed")
  }

  func testCancellationDrainsWorkerAndSuppressesResult() async {
    let center = OperationCenter()
    center.failureReportStore = .temporaryForTesting()
    let handle = PrimerDesignOperation.start(center: center, title: "PrimalScheme",
      destination: URL(fileURLWithPath: "/tmp/cancelled.lungfishprimeranalysis"), routeContext: nil,
      operation: { _ in
        try await Task.sleep(nanoseconds: 10_000_000_000)
        return URL(fileURLWithPath: "/tmp/unexpected")
      }, onResultSaved: { _ in XCTFail("Cancelled operation must not publish a result") })
    center.cancel(id: handle.id)
    XCTAssertEqual(center.items.first?.state, .cancelling)
    await handle.task.value
    XCTAssertEqual(center.items.first?.state, .cancelled)
    XCTAssertTrue(center.items.first?.outputURLs.isEmpty == true)
  }
  func testCancellationWinsEvenWhenWorkerReturnsOutput() async {
    let center = OperationCenter()
    center.failureReportStore = .temporaryForTesting()
    let output = URL(fileURLWithPath: "/tmp/race.lungfishprimeranalysis")
    let handle = PrimerDesignOperation.start(center: center, title: "Primer3",
      destination: output, routeContext: nil,
      operation: { _ in
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        return output
      }, onResultSaved: { _ in XCTFail("Late success must not publish after cancellation") })
    center.cancel(id: handle.id)
    await handle.task.value
    XCTAssertEqual(center.items.first?.state, .cancelled)
    XCTAssertTrue(center.items.first?.outputURLs.isEmpty == true)
  }

  func testBusyDestinationPreventsExecution() async {
    let center = OperationCenter()
    center.failureReportStore = .temporaryForTesting()
    let output = URL(fileURLWithPath: "/tmp/busy.lungfishprimeranalysis")
    _ = center.begin(
        title: "Existing writer",
        detail: "Running",
        operationType: .download,
        targetBundleURL: output,
        cliCommand: nil
    )
    let handle = PrimerDesignOperation.start(center: center, title: "Primer3",
      destination: output, routeContext: nil,
      operation: { _ in XCTFail("A locked destination must not execute"); return output },
      onResultSaved: { _ in XCTFail("A locked destination must not publish") })
    await handle.task.value
    XCTAssertEqual(center.items.first(where: { $0.id == handle.id })?.state, .failed)
  }

}
