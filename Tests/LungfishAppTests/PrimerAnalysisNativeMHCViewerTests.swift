import AppKit
import SwiftUI
import XCTest
@testable import LungfishApp

/// Manual fixture verification of actual engine outputs; no fixtures are downloaded by this test.
@MainActor
final class PrimerAnalysisNativeMHCViewerTests: XCTestCase {
  func testNativeInspectorFiltersPreserveScientificFilesAndRestorePerWindow() async throws {
    guard let path = ProcessInfo.processInfo.environment["LUNGFISH_PRIMER_BINDING_BUNDLE"] else {
      throw XCTSkip("Set LUNGFISH_PRIMER_BINDING_BUNDLE for native MHC filter verification")
    }
    let url = URL(fileURLWithPath: path)
    let snapshot = try PrimerAnalysisViewerSnapshot.load(from: url)
    let savedPaths = snapshot.bundle.manifest.artifacts.filter {
      $0.relativePath.hasSuffix(".bed") || $0.relativePath.hasSuffix(".csv") || $0.role.contains("Provenance")
    }.map(\.relativePath) + ["manifest.json", snapshot.bundle.manifest.provenance.relativePath]
    let savedBytes = try savedPaths.map { try Data(contentsOf: url.appendingPathComponent($0)) }
    let preferences = PrimerAnalysisDisplayPreferences()
    let session = PrimerAnalysisDisplaySession(preferences: preferences)
    session.configure(snapshot)
    XCTAssertTrue(session.isAvailable)
    XCTAssertGreaterThan(session.totalCount, 0)
    session.computeCompatibility()
    // Invalidation must reject a pending calculation even when the same analysis is reopened.
    session.invalidate()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertFalse(session.compatibilityReady)
    XCTAssertTrue(session.compatibilitySummaries.isEmpty)
    session.configure(snapshot)
    XCTAssertTrue(session.isComputingCompatibility)
    for _ in 0..<200 where !session.compatibilityReady && session.compatibilityError == nil {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(session.compatibilityReady, session.compatibilityError ?? "Calculation timed out")
    XCTAssertEqual(session.compatibilitySummaries.count,
      snapshot.inspectableBindingContexts.reduce(0) { $0 + $1.primers.count })
    XCTAssertTrue(session.compatibilitySummaries.values.allSatisfy {
      $0.matchingRows <= $0.assessableRows && $0.assessableRows <= $0.totalRows
    })
    let target = try XCTUnwrap(snapshot.designReview.first { !$0.primers.isEmpty })
    let primer = try XCTUnwrap(target.primers.first)
    session.setPrimerShown(primer.id, shown: false)
    session.settings.filterByCompatibility = true
    session.settings.minimumCompatibilityPercent = 60
    XCTAssertFalse(session.isVisible(primer, in: target))
    let restored = PrimerAnalysisDisplaySession(preferences: preferences)
    restored.configure(snapshot)
    XCTAssertEqual(restored.settings, session.settings)
    let anotherWindow = PrimerAnalysisDisplaySession(preferences: PrimerAnalysisDisplayPreferences())
    anotherWindow.configure(snapshot)
    XCTAssertEqual(anotherWindow.visibleCount, anotherWindow.totalCount)
    restored.cancel()

    if let output = ProcessInfo.processInfo.environment["LUNGFISH_PRIMER_VIEWER_SNAPSHOT_DIR"] {
      let model = PrimerAnalysisViewerModel()
      await model.load(from: url)
      let inspector = InspectorViewController()
      inspector.beginPrimerAnalysisDocument(at: url, displaySession: session)
      inspector.updatePrimerAnalysisDocument(snapshot)
      XCTAssertTrue(inspector.viewModel.availableTabs.contains(.view))
      inspector.viewModel.selectedTab = .view
      let selection = PrimerReviewSelection(targetID: target.id, primerID: nil, ampliconID: target.intervals.first?.id)
      let host = NSHostingView(rootView: HStack(spacing: 0) {
        PrimerAnalysisViewerView(bundleURL: url, model: model, selectedSection: .results,
          selection: selection, displaySession: session)
        Divider()
        InspectorView(viewModel: inspector.viewModel).frame(width: 360)
      })
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 1000),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      window.appearance = NSAppearance(named: .aqua)
      host.frame = window.contentLayoutRect
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(500))
      host.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let outputURL = URL(fileURLWithPath: output, isDirectory: true)
      try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        .write(to: outputURL.appendingPathComponent("native-mhc-inspector-filtered.png"))
      window.close()
    }

    session.settings.hiddenPrimerIDs = Set(snapshot.designReview.flatMap { $0.primers.map(\.id) })
    XCTAssertEqual(session.visibleCount, 0)
    for context in snapshot.inspectableBindingContexts {
      let displayed = session.visibility.filtering(context, targets: snapshot.designReview)
      XCTAssertTrue(displayed.primers.isEmpty)
      XCTAssertTrue(displayed.annotations.isEmpty)
      XCTAssertEqual(displayed.rows.count, context.rows.count)
      XCTAssertEqual(displayed.alignedFASTA, context.alignedFASTA)
    }
    XCTAssertTrue(snapshot.availableSections.contains(.binding))
    session.reset()
    XCTAssertEqual(session.visibleCount, session.totalCount)
    XCTAssertEqual(try savedPaths.map { try Data(contentsOf: url.appendingPathComponent($0)) }, savedBytes)
  }

  func testLoadAndRenderNativeMHCAnalyses() async throws {
    guard let rootPath = ProcessInfo.processInfo.environment["LUNGFISH_MHC_PRIMER_VALIDATION_DIR"] else {
      throw XCTSkip("Set LUNGFISH_MHC_PRIMER_VALIDATION_DIR to inspect retained human/macaque CLI outputs")
    }
    let root = URL(fileURLWithPath: rootPath, isDirectory: true)
    let urls = try Self.analysisURLs(in: root)
    XCTAssertFalse(urls.isEmpty, "No native analysis bundles found")
    var rendered: Set<String> = []
    for url in urls.sorted(by: { $0.path < $1.path }) {
      let snapshot = try PrimerAnalysisViewerSnapshot.load(from: url)
      let engine = snapshot.primer3Results == nil ? "primalscheme3" : "primer3"
      if engine == "primalscheme3" {
        XCTAssertFalse(snapshot.primalSchemeResults.isEmpty, url.path)
        for scheme in snapshot.primalSchemeResults {
          let bed = try String(contentsOf: url.appendingPathComponent(scheme.id), encoding: .utf8)
          let native = bed.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("#") }
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
          XCTAssertEqual(scheme.primers.map(\.name), native.map { $0[3] }, "Keep every selected native variant, in native order")
          XCTAssertEqual(scheme.primers.map(\.sequence), native.map { $0[6] }, "Do not substitute a consensus or first-ranked oligo")
        }
        for target in snapshot.designReview where !target.intervals.isEmpty {
          XCTAssertTrue(target.intervals.allSatisfy { !$0.primerIDs.isEmpty }, url.path + " " + target.label)
          XCTAssertTrue(target.primers.allSatisfy { $0.ampliconIDs.count == 1 }, url.path + " " + target.label)
          XCTAssertTrue(target.primers.allSatisfy { !$0.sequence.isEmpty })
        }
        for context in snapshot.bindingContexts {
          let known = Set(snapshot.designReview.flatMap(\.primers).map(\.id))
          XCTAssertTrue(context.primers.allSatisfy { known.contains($0.reviewPrimerID) }, url.path)
        }
      }
      guard let outputPath = ProcessInfo.processInfo.environment["LUNGFISH_PRIMER_VIEWER_SNAPSHOT_DIR"],
        rendered.insert(engine).inserted else { continue }
      let model = PrimerAnalysisViewerModel()
      await model.load(from: url)
      let selectedTarget = snapshot.designReview.first { !$0.primers.isEmpty }
      let selection = selectedTarget.flatMap { target in
        target.primers.first.map { PrimerReviewSelection.selecting(primer: $0, in: target) }
      }
      let host = NSHostingView(rootView: PrimerAnalysisViewerView(bundleURL: url, model: model,
        selectedSection: .results, selection: selection))
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                            styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      defer { window.close() }
      window.contentView = host
      window.appearance = NSAppearance(named: .aqua)
      host.frame = NSRect(x: 0, y: 0, width: 1100, height: 800)
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(300))
      host.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      let output = URL(fileURLWithPath: outputPath, isDirectory: true)
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
      try png.write(to: output.appendingPathComponent("native-mhc-\(engine)-results.png"))
    }
  }

  private static func analysisURLs(in root: URL) throws -> [URL] {
    let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root,
      includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))
    var urls: [URL] = []
    for case let url as URL in enumerator where url.pathExtension == "lungfishprimeranalysis" {
      urls.append(url)
      enumerator.skipDescendants()
    }
    return urls
  }

}
