import Foundation
import XCTest
@testable import LungfishWorkflow

final class LocalWorkflowReplayReservationTests: XCTestCase {
    func testReservationCreatesOneDirectoryAndNeverMergesASecondWriter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("repeat-reservation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundle = root.appendingPathComponent("attempt.lungfishrun")
        try LocalWorkflowReplayReservation.reserveDirectory(at: bundle)
        let sentinel = bundle.appendingPathComponent("foreign.txt")
        try "retained writer bytes".write(to: sentinel, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try LocalWorkflowReplayReservation.reserveDirectory(at: bundle))
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "retained writer bytes")
    }

    func testExistingSymlinkReservationNeverTouchesItsDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("repeat-reservation-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let foreign = root.appendingPathComponent("foreign")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        let sentinel = foreign.appendingPathComponent("sentinel.txt")
        try "foreign bytes".write(to: sentinel, atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent("attempt.lungfishrun")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: foreign)
        XCTAssertThrowsError(try LocalWorkflowReplayReservation.reserveDirectory(at: link))
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "foreign bytes")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), foreign.path)
    }
}
