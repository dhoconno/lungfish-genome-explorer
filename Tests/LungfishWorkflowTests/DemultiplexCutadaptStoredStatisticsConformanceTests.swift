// DemultiplexCutadaptStoredStatisticsConformanceTests.swift - The cutadapt route stores the statistics it counted
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
import LungfishIO
import LungfishTestSupport

/// The cutadapt route measured a bundle kept for a chained step with `seqkit stats -T`, which counts reads and
/// lengths only, and stored median 0, N50 0, mean Q 0, Q20 0, Q30 0, GC 0 and empty histograms as the bundle's
/// statistics (Phase 3.0 lane DEMUX-STATS, walk WF-8b). Each test checks every stored field against a fresh
/// `FASTQStatisticsCollector` pass over the reads the bundle holds, as `DemultiplexStoredStatisticsTests` does for
/// the Swift routes.
///
/// A real-tool suite. Its name puts it in the conformance tier, and it skips when managed cutadapt or seqkit is
/// missing, or fails under LUNGFISH_REQUIRE_TOOLS=1.
final class DemultiplexCutadaptStoredStatisticsConformanceTests: XCTestCase {

    private var root: URL!

    /// The cutadapt route writes only inside a project.
    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "demux-cutadapt-stored-statistics")
            .appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root.deletingLastPathComponent())
    }

    private static let barcode01 = "ACGGTCTAGCATGTCA"
    private static let barcode02 = "TGCATCCGGATAACGT"

    /// A run kept for a chained step moves cutadapt's output into each bundle and measures that file.
    func testABundleKeptForAChainedStepStoresTheCountedStatisticsOfItsReads() async throws {
        try await requireManagedTools([.cutadapt, .seqkit])
        let rootBundle = try writeRootBundle()
        let result = try await DemultiplexingPipeline().run(
            config: try config(rootBundle: rootBundle, output: "chained", captureTrimsForChaining: true),
            progress: { _, _ in }
        )

        XCTAssertEqual(result.outputBundleURLs.count, 2, "one bundle for each barcode")
        try await assertEveryBundleStoresItsCountedStatistics(result, rootBundle: rootBundle)
    }

    /// A virtual run rebuilds each bundle's reads from the root and measures them, and keeps doing so.
    func testAVirtualBundleStoresTheCountedStatisticsOfItsReads() async throws {
        try await requireManagedTools([.cutadapt, .seqkit])
        let rootBundle = try writeRootBundle()
        let result = try await DemultiplexingPipeline().run(
            config: try config(rootBundle: rootBundle, output: "virtual", captureTrimsForChaining: false),
            progress: { _, _ in }
        )

        XCTAssertEqual(result.outputBundleURLs.count, 2, "one bundle for each barcode")
        try await assertEveryBundleStoresItsCountedStatistics(result, rootBundle: rootBundle)
    }

    private func assertEveryBundleStoresItsCountedStatistics(
        _ result: DemultiplexResult,
        rootBundle: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let bundles = result.outputBundleURLs + [result.unassignedBundleURL].compactMap { $0 }
        for bundle in bundles {
            let manifest = try XCTUnwrap(
                FASTQBundle.loadDerivedManifest(in: bundle),
                "\(bundle.lastPathComponent) has a derived manifest", file: file, line: line
            )
            let measured = try await DemultiplexStoredStatisticsTests.measure(
                readsListedIn: bundle,
                from: [rootBundle.appendingPathComponent("reads.fastq")]
            )
            DemultiplexStoredStatisticsAssertions.assertStored(
                manifest.cachedStatistics, equals: measured, bundle.lastPathComponent, file: file, line: line
            )
        }
    }

    /// Barcodes are kept on the reads (`trimBarcodes: false`), so the reads a bundle holds are its listed root reads.
    private func config(rootBundle: URL, output: String, captureTrimsForChaining: Bool) throws -> DemultiplexConfig {
        let kitCSV = root.appendingPathComponent("\(output)-kit.csv")
        try "id,sequence\nBC01,\(Self.barcode01)\nBC02,\(Self.barcode02)\n"
            .write(to: kitCSV, atomically: true, encoding: .utf8)
        return DemultiplexConfig(
            inputURL: rootBundle.appendingPathComponent("reads.fastq"),
            sourceBundleURL: rootBundle,
            barcodeKit: try BarcodeKitRegistry.loadCustomKit(from: kitCSV, name: "kit"),
            outputDirectory: root.appendingPathComponent(output, isDirectory: true),
            barcodeLocation: .fivePrime,
            trimBarcodes: false,
            threads: 2,
            rootBundleURL: rootBundle,
            rootFASTQFilename: "reads.fastq",
            inputSequenceFormat: .fastq,
            captureTrimsForChaining: captureTrimsForChaining
        )
    }

    /// Four BC01 reads, three BC02 reads and three reads with no barcode.
    private func writeRootBundle() throws -> URL {
        typealias Fixture = DemultiplexStoredStatisticsTests
        var reads: [(id: String, sequence: String)] = []
        for (index, insert) in [80, 91, 102, 113].enumerated() {
            reads.append(("bc01-\(index)", Self.barcode01 + Fixture.bases(insert, seed: 100 + index)))
        }
        for (index, insert) in [85, 96, 107].enumerated() {
            reads.append(("bc02-\(index)", Self.barcode02 + Fixture.bases(insert, seed: 110 + index)))
        }
        for (index, length) in [94, 105, 116].enumerated() {
            reads.append(("none-\(index)", Fixture.bases(length, seed: 120 + index)))
        }
        let bundle = root.appendingPathComponent("root.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Fixture.fastq(reads).write(
            to: bundle.appendingPathComponent("reads.fastq"), atomically: true, encoding: .utf8
        )
        return bundle
    }

    private func requireManagedTools(_ tools: [NativeTool]) async throws {
        for tool in tools {
            guard (try? await NativeToolRunner.shared.toolPath(for: tool)) != nil else {
                try ToolAvailability.skipOrFail("Managed \(tool.rawValue) is not available")
                throw XCTSkip("unreachable")
            }
        }
    }
}
