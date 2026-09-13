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

        let availableSections = try PrimerAnalysisViewerSnapshot.load(from: bundleURL).availableSections
        for section in availableSections {
            for width in [CGFloat(1100), CGFloat(650)] {
                let model = PrimerAnalysisViewerModel()
                await model.load(from: bundleURL)
                guard case .loaded(let snapshot) = model.state else { return XCTFail("Visual fixture did not load") }
                let target = try XCTUnwrap(snapshot.designReview.first)
                let primer = try XCTUnwrap(target.primers.first)
                let host = NSHostingView(rootView: PrimerAnalysisViewerView(
                    bundleURL: bundleURL, model: model, selectedSection: section,
                    selection: .selecting(primer: primer, in: target)))
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
        let labels = ["Synthetic alignment A", "Synthetic alignment B"]
        var inputs: [PrimerAnalysisInput] = []
        var artifacts: [PrimerAnalysisSourceArtifact] = []
        for (index, label) in labels.enumerated() {
            let source = root.appendingPathComponent("input-\(index).txt")
            try Data("Opaque example input \(index)\n".utf8).write(to: source)
            let path = "inputs/input-\(index).txt"
            inputs.append(.init(id: UUID(), label: label, artifactPaths: [path]))
            artifacts.append(.init(sourceURL: source, relativePath: path, role: "input", format: "text"))
        }
        let nativeFiles: [(String, String, String)] = [
            ("reference.fasta", ">target_A\n" + String(repeating: "ACGT", count: 250) + "\n>target_B\n" + String(repeating: "ACGT", count: 200) + "\n", "fasta"),
            ("primer.bed", "target_A\t50\t70\tfirst_1_LEFT_1\t1\t+\tACGTACGTACGTACGTACGT\n" + "target_A\t430\t450\tfirst_1_RIGHT_1\t1\t-\tACGTACGTACGTACGTACGT\n" + "target_A\t350\t370\tsecond_2_LEFT_1\t2\t+\tACGTACGTACGTACGTACGT\n" + "target_A\t780\t800\tsecond_2_RIGHT_1\t2\t-\tACGTACGTACGTACGTACGT\n", "bed"),
            ("amplicon.bed", "target_A\t50\t450\tfirst_1\t1\n" + "target_A\t350\t800\tsecond_2\t2\n", "bed")
        ]
        for (name, contents, format) in nativeFiles {
            let source = root.appendingPathComponent(name)
            try Data(contents.utf8).write(to: source)
            artifacts.append(.init(sourceURL: source, relativePath: "native/" + name, role: "nativeOutput", format: format))
        }
        let destination = root.appendingPathComponent("Synthetic scheme review.lungfishprimeranalysis")
        return try PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)).write(.init(
            analysisID: UUID(), runID: UUID(), grouping: .combined, inputs: inputs,
            results: [.init(id: UUID(), label: "Combined example", inputIDs: inputs.map(\.id), artifactPaths: nativeFiles.map { "native/" + $0.0 })],
            artifacts: artifacts, destinationURL: destination,
            invocation: .init(argv: CommandLine.arguments, callerVersion: "visual-test",
                              explicitOptions: [:], runtimeIdentity: .init())
        )).url
    }
}
