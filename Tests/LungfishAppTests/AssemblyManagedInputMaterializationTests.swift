import XCTest
@testable import LungfishApp
import LungfishIO
import LungfishWorkflow

@MainActor
final class AssemblyManagedInputMaterializationTests: XCTestCase {
    func testManagedAssemblyRequestMaterializesVirtualDerivedFASTQBeforePipeline() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-assembly-virtual-derived-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rootBundleURL = tempDir.appendingPathComponent("root.lungfishfastq", isDirectory: true)
        let rootFASTQURL = rootBundleURL.appendingPathComponent("root.fastq")
        let derivedBundleURL = tempDir.appendingPathComponent("subset.lungfishfastq", isDirectory: true)
        let materializedURL = tempDir.appendingPathComponent("materialized.fastq")
        try FileManager.default.createDirectory(at: rootBundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: derivedBundleURL, withIntermediateDirectories: true)
        try "@read1\nACGT\n+\nIIII\n@read2\nTTTT\n+\nIIII\n".write(to: rootFASTQURL, atomically: true, encoding: .utf8)
        try "read1\n".write(
            to: derivedBundleURL.appendingPathComponent("read-ids.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "@read1\nACGT\n+\nIIII\n".write(to: materializedURL, atomically: true, encoding: .utf8)
        let operation = FASTQDerivativeOperation(kind: .subsampleCount, count: 1)
        let manifest = FASTQDerivedBundleManifest(
            name: "subset",
            parentBundleRelativePath: "../root.lungfishfastq",
            rootBundleRelativePath: "../root.lungfishfastq",
            rootFASTQFilename: rootFASTQURL.lastPathComponent,
            payload: .subset(readIDListFilename: "read-ids.txt"),
            lineage: [operation],
            operation: operation,
            cachedStatistics: .placeholder(readCount: 1, baseCount: 4),
            pairingMode: .singleEnd,
            sequenceFormat: .fastq
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: derivedBundleURL)
        let request = AssemblyRunRequest(
            tool: .spades,
            readType: .illuminaShortReads,
            inputURLs: [derivedBundleURL],
            projectName: "subset-demo",
            outputDirectory: tempDir.appendingPathComponent("assembly"),
            pairedEnd: false,
            threads: 2
        )
        var materializedBundles: [URL] = []

        let resolved = try await AssemblyRunner.materializedManagedAssemblyRequest(
            from: request,
            tempDirectory: tempDir,
            materialize: { bundleURL, _, _ in
                materializedBundles.append(bundleURL.standardizedFileURL)
                return materializedURL
            }
        )

        XCTAssertEqual(resolved.inputURLs, [materializedURL.standardizedFileURL])
        XCTAssertEqual(materializedBundles, [derivedBundleURL.standardizedFileURL])
        XCTAssertNotEqual(resolved.inputURLs, [rootFASTQURL.standardizedFileURL])
    }
}
