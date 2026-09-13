import Darwin
import Foundation
import XCTest
@testable import LungfishApp

final class PrimerAnalysisExportDestinationTests: XCTestCase {
  func testCreatesUniqueNativeDestinationsWithinOriginatingProject() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try PrimerAnalysisExportDestination(projectURL: root, name: "MHC DP / primers")
    let second = try PrimerAnalysisExportDestination(projectURL: root, name: "MHC DP / primers")
    XCTAssertEqual(first.url.pathExtension, "lungfishref")
    XCTAssertEqual(first.url.deletingLastPathComponent().lastPathComponent, "Analyses")
    XCTAssertNotEqual(first.url, second.url)
    try first.validateBeforePublication()
    try FileManager.default.createDirectory(at: first.url, withIntermediateDirectories: false)
    XCTAssertThrowsError(try first.validateBeforePublication())
  }

  func testRejectsLinkedAnalysesAndChangedParentBeforePublication() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    let parent = root.appendingPathComponent("Analyses")
    try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
    XCTAssertThrowsError(try PrimerAnalysisExportDestination(projectURL: root, name: "Extract"))
    try FileManager.default.removeItem(at: parent)
    let destination = try PrimerAnalysisExportDestination(projectURL: root, name: "Extract")
    try FileManager.default.moveItem(at: parent, to: root.appendingPathComponent("OriginalAnalyses"))
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    XCTAssertThrowsError(try destination.validateBeforePublication())
  }

  private func temporaryRoot() throws -> URL {
    let pointer = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
    defer { free(pointer) }
    let root = URL(fileURLWithPath: String(cString: pointer)).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return root
  }
}
