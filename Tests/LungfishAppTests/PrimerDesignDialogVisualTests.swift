import AppKit
import SwiftUI
import XCTest
@testable import LungfishApp

@MainActor
final class PrimerDesignDialogVisualTests: XCTestCase {
  func testRenderDesignWorkflows() async throws {
    guard let outputPath = ProcessInfo.processInfo.environment["LUNGFISH_PRIMER_VIEWER_SNAPSHOT_DIR"] else {
      throw XCTSkip("Set LUNGFISH_PRIMER_VIEWER_SNAPSHOT_DIR for visual verification")
    }
    let output = URL(fileURLWithPath: outputPath, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let state = PrimerDesignDialogState()
    let fasta = root.appendingPathComponent("MHC class I — synthetic UI fixture.fasta")
    let sequence = String(repeating: "ACGT", count: 100)
    try Data(">Example record 1\n\(sequence)\n>Example record 2\n\(sequence)\n".utf8).write(to: fasta)
    state.addInputs([fasta])
    await state.inspectInputs()
    state.destinationURL = root.appendingPathComponent("MHC class I.lungfishprimeranalysis")
    state.chemistry = .hydrolysisProbe
    state.targetEnabled = true
    state.targetStart = "100"
    state.targetEnd = "200"
    for engine in PrimerDesignEngine.allCases {
      state.engine = engine
      let host = NSHostingView(rootView: PrimerDesignDialog(
        state: state, onRun: {}, onCancelRun: {}, onClose: {}, onOpenResult: { _ in }))
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 780),
                            styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      window.appearance = NSAppearance(named: .aqua)
      host.frame = NSRect(x: 0, y: 0, width: 1020, height: 780)
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(200))
      host.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      try png.write(to: output.appendingPathComponent("primer-design-\(engine.rawValue.lowercased()).png"))
      window.close()
    }
  }
}
