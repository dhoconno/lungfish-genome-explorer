import AppKit
import Darwin
import SwiftUI
import XCTest
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp

/// Opt-in rendering of the real view; no user's application window is opened.
@MainActor
final class PrimerAnalysisViewerVisualTests: XCTestCase {
    func testRenderSavedAnalysisSections() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment["LUNGFISH_PRIMER_VIEWER_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set LUNGFISH_PRIMER_VIEWER_SNAPSHOT_DIR for visual verification")
        }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(physical) }
        let root = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundleURL = try makeFixture(in: root)

        for section in PrimerAnalysisViewerView.Section.allCases {
            for width in [CGFloat(1100), CGFloat(650)] {
                let model = PrimerAnalysisViewerModel()
                await model.load(from: bundleURL)
                guard case .loaded = model.state else { return XCTFail("Visual fixture did not load") }
                let host = NSHostingView(rootView: PrimerAnalysisViewerView(
                    bundleURL: bundleURL, model: model, selectedSection: section))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 800),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.appearance = NSAppearance(named: .aqua)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 800)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(200))
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let suffix = width == 650 ? "-narrow" : ""
                try png.write(to: output.appendingPathComponent("primer-analysis-\(section.rawValue.lowercased())\(suffix).png"))
                window.close()
            }
        }
    }

    private func makeFixture(in root: URL) throws -> URL {
        let labels = ["MHC class I", "MHC class II DP", "MHC class II DQ", "MHC class II DRB"]
        var inputs: [PrimerAnalysisInput] = []
        var artifacts: [PrimerAnalysisSourceArtifact] = []
        for (index, label) in labels.enumerated() {
            let source = root.appendingPathComponent("input-\(index).txt")
            try Data("Opaque example input \(index)\n".utf8).write(to: source)
            let path = "inputs/input-\(index).txt"
            inputs.append(.init(id: UUID(), label: label, artifactPaths: [path]))
            artifacts.append(.init(sourceURL: source, relativePath: path, role: "input", format: "text"))
        }
        let source = root.appendingPathComponent("result.txt")
        try Data("Opaque example result; no biological design\n".utf8).write(to: source)
        artifacts.append(.init(sourceURL: source, relativePath: "native/result.txt", role: "nativeOutput", format: "text"))
        let destination = root.appendingPathComponent("MHC example results.lungfishprimeranalysis")
        return try PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)).write(.init(
            analysisID: UUID(), runID: UUID(), grouping: .combined, inputs: inputs,
            results: [.init(id: UUID(), label: "Combined example", inputIDs: inputs.map(\.id), artifactPaths: ["native/result.txt"])],
            artifacts: artifacts, destinationURL: destination,
            invocation: .init(argv: CommandLine.arguments, callerVersion: "visual-test",
                              explicitOptions: [:], runtimeIdentity: .init())
        )).url
    }
}
