import Foundation
import XCTest
import LungfishWorkflow
@testable import LungfishApp

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Double, String)] = []

    func record(progress: Double, message: String) {
        lock.lock()
        values.append((progress, message))
        lock.unlock()
    }

    func snapshot() -> [(Double, String)] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@MainActor
final class ReferenceImportHelperTests: XCTestCase {
    func testRunIfRequestedSupportsInjectedImportAction() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reference-import-helper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let inputURL = root.appendingPathComponent("input.fasta")
        try Data(">seq\nAACCGGTT\n".utf8).write(to: inputURL)

        let bundleURL = root.appendingPathComponent("Ref.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let observedProgress = ProgressRecorder()
        let exitCode = ReferenceImportHelper.runIfRequested(
            arguments: [
                "Lungfish",
                "--reference-import-helper",
                "--input-file", inputURL.path,
                "--output-dir", root.path,
                "--name", "Ref",
            ],
            importAction: { sourceURL, outputDirectory, preferredName, progress in
                XCTAssertEqual(sourceURL, inputURL)
                XCTAssertEqual(outputDirectory, root)
                XCTAssertEqual(preferredName, "Ref")
                progress?(0.5, "Halfway there")
                return ReferenceBundleImportResult(bundleURL: bundleURL, bundleName: "Ref")
            },
            progressHandler: { progress, message in
                observedProgress.record(progress: progress, message: message)
            }
        )

        let snapshot = observedProgress.snapshot()
        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.0, 0.5)
        XCTAssertEqual(snapshot.first?.1, "Halfway there")
    }
}
