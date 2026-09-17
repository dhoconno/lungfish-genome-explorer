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
    let state = PrimerDesignDialogState(projectURL: root)
    let fasta = root.appendingPathComponent("MHC class I — synthetic UI fixture.fasta")
    let sequence = String(repeating: "ACGT", count: 100)
    try Data(">Example record 1\n\(sequence)\n>Example record 2\n\(sequence)\n".utf8).write(to: fasta)
    state.addInputs([fasta])
    await state.inspectInputs()
    state.analysisName = "Primer analysis"
    state.chemistry = .hydrolysisProbe
    state.targetEnabled = true
    state.targetStart = "100"
    state.targetEnd = "200"
    for (variant, engine) in [PrimerDesignEngine.primer3, .primalScheme, .primalScheme, .primalScheme].enumerated() {
      state.engine = engine
      state.advancedExpanded = variant == 2
      state.grouping = variant == 2 ? .combined : .independent
      if variant >= 2 {
        state.ampliconSize = "200"
        state.ampliconSizeMinimum = "150"
        state.ampliconSizeMaximum = "250"
      }
      let height: CGFloat = variant == 2 ? 1240 : 780
      let host = NSHostingView(rootView: PrimerDesignDialog(
        state: state, onRun: {}, onClose: {}))
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: height),
                            styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      window.appearance = NSAppearance(named: .aqua)
      host.frame = NSRect(x: 0, y: 0, width: 1020, height: height)
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(200))
      host.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      let suffix = variant == 2 ? "-advanced-panel" : variant == 3 ? "-custom-bounds" : ""
      try png.write(to: output.appendingPathComponent("primer-design-\(engine.rawValue.lowercased())\(suffix).png"))
      window.close()
    }

    // Recovery controls are rendered as explicit opt-ins for review.
    state.engine = .primalScheme
    state.grouping = .combined
    state.advancedExpanded = true
    state.legacySalvageEnabled = true
    state.gapCompletionParentPath = ""
    state.gapExpansionEnabled = false
    let recoveryHost = NSHostingView(rootView: PrimerDesignDialog(state: state, onRun: {}, onClose: {}))
    let recoveryWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 1500), styleMask: [.borderless], backing: .buffered, defer: false)
    recoveryWindow.isReleasedWhenClosed = false
    recoveryWindow.contentView = recoveryHost
    recoveryHost.frame = NSRect(x: 0, y: 0, width: 1020, height: 1500)
    recoveryHost.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(200))
    let recoveryBitmap = try XCTUnwrap(recoveryHost.bitmapImageRepForCachingDisplay(in: recoveryHost.bounds))
    recoveryHost.cacheDisplay(in: recoveryHost.bounds, to: recoveryBitmap)
    try XCTUnwrap(recoveryBitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("primer-design-primalscheme-salvage.png"))
    // Capture valid modes separately so the review image never implies that
    // salvage and parent follow-up may be combined.
    state.legacySalvageEnabled = false
    state.gapCompletionParentPath = "/tmp/parent-native-output"
    state.gapExpansionEnabled = true
    recoveryHost.layoutSubtreeIfNeeded()
    let followupBitmap = try XCTUnwrap(recoveryHost.bitmapImageRepForCachingDisplay(in: recoveryHost.bounds))
    recoveryHost.cacheDisplay(in: recoveryHost.bounds, to: followupBitmap)
    try XCTUnwrap(followupBitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("primer-design-primalscheme-followup.png"))
    recoveryWindow.close()
  }
}
