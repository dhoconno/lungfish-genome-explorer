import Foundation
import XCTest
import LungfishKit
@testable import LungfishApp

@MainActor
final class PrimerAnalysisExportPublicationTests: XCTestCase {
  func testCancellationBeforeCommitDoesNotPublish() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    fixture.center.cancel(id: fixture.id)
    XCTAssertThrowsError(try PrimerAnalysisExportPublication.commit(stagedURL: fixture.staged,
      destinationURL: fixture.output, center: fixture.center, operationID: fixture.id, validate: {})) {
      XCTAssertTrue($0 is CancellationError)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.staged.path))
    fixture.center.acknowledgeCancellation(id: fixture.id)
    XCTAssertEqual(fixture.center.items.first?.state, .cancelled)
    XCTAssertTrue(fixture.center.items.first?.outputURLs.isEmpty == true)
  }

  func testCommitCompletesOperationBeforeAnotherCancellationCanBeAccepted() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try PrimerAnalysisExportPublication.commit(stagedURL: fixture.staged,
      destinationURL: fixture.output, center: fixture.center, operationID: fixture.id, validate: {})
    fixture.center.cancel(id: fixture.id)
    XCTAssertEqual(fixture.center.items.first?.state, .completed)
    XCTAssertEqual(fixture.center.items.first?.outputURLs, [fixture.output])
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.output.appendingPathComponent("sentinel").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staged.path))
  }

  func testProjectGuardFailurePreservesUnpublishedStaging() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    enum Changed: Error { case project }
    XCTAssertThrowsError(try PrimerAnalysisExportPublication.commit(stagedURL: fixture.staged,
      destinationURL: fixture.output, center: fixture.center, operationID: fixture.id,
      validate: { throw Changed.project }))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.staged.path))
    XCTAssertEqual(fixture.center.items.first?.state, .running)
    fixture.center.fail(id: fixture.id, detail: "Project guard rejected publication")
  }

  private func makeFixture() throws -> (root: URL, staged: URL, output: URL, center: OperationCenter, id: UUID) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let staged = root.appendingPathComponent("staging")
    let output = root.appendingPathComponent("published.lungfishref")
    try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
    try Data("publication transaction fixture".utf8).write(to: staged.appendingPathComponent("sentinel"))
    let center = OperationCenter()
    let id = center.start(title: "Primer extract", detail: "Prepared", targetBundleURL: output)
    center.setCancelCallback(for: id) {}
    return (root, staged, output, center, id)
  }
}
