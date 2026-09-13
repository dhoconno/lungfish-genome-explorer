import Foundation
import XCTest
import LungfishKit
@testable import LungfishApp

@MainActor
final class PrimerDesignOperationTests: XCTestCase {
  func testRegistersBeforeExecutionAndPreservesOriginAndResult() async throws {
    let center = OperationCenter()
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
    let gate = AsyncStream<Void>.makeStream()
    let output = URL(fileURLWithPath: "/tmp/progress.lungfishprimeranalysis")
    let handle = PrimerDesignOperation.start(center: center, title: "PrimalScheme",
      destination: output, routeContext: nil, operation: { progress in
        progress(0.25, "Preparing saved alignment")
        for await _ in gate.stream { break }
        return output
      }, onResultSaved: { _ in })
    for _ in 0..<100 {
      if center.items.first?.progress == 0.25 { break }
      try await Task.sleep(for: .milliseconds(2))
    }
    XCTAssertEqual(center.items.first?.state, .running)
    XCTAssertEqual(center.items.first?.progress, 0.25)
    XCTAssertEqual(center.items.first?.detail, "Preparing saved alignment")
    gate.continuation.finish()
    await handle.task.value
    XCTAssertEqual(center.items.first?.state, .completed)
  }

  func testFailureIsVisible() async {
    let center = OperationCenter()
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
    let output = URL(fileURLWithPath: "/tmp/busy.lungfishprimeranalysis")
    _ = center.start(title: "Existing writer", detail: "Running", targetBundleURL: output)
    let handle = PrimerDesignOperation.start(center: center, title: "Primer3",
      destination: output, routeContext: nil,
      operation: { _ in XCTFail("A locked destination must not execute"); return output },
      onResultSaved: { _ in XCTFail("A locked destination must not publish") })
    await handle.task.value
    XCTAssertEqual(center.items.first(where: { $0.id == handle.id })?.state, .failed)
  }

}
