import XCTest
@testable import LungfishApp
@testable import LungfishCore
import LungfishWorkflow

final class AppUITestMappingBackendTests: XCTestCase {
    func testWriteResultProducesLoadableMappingResultForEachMapper() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("mapping-backend-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempRoot) }
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let referenceURL = tempRoot.appendingPathComponent("ref.fasta")
        let referenceFASTA = """
            >chr1 test reference
            ACGTACGTACGTACGTACGTACGTACGT
            ACGTACGTACGTACGTACGT
            """
        try referenceFASTA.write(to: referenceURL, atomically: true, encoding: .utf8)
        let expectedContigLength: Int = {
            var total = 0
            for line in referenceFASTA.split(whereSeparator: { $0 == "\n" }).dropFirst() {
                total += line.count
            }
            return total
        }()

        let inputURL = tempRoot.appendingPathComponent("reads.fastq.gz")
        try Data().write(to: inputURL)

        for tool in MappingTool.allCases {
            let outputDirectory = tempRoot.appendingPathComponent("out-\(tool.rawValue)", isDirectory: true)
            let request = MappingRunRequest(
                tool: tool,
                modeID: tool == .bbmap ? MappingMode.bbmapStandard.id : MappingMode.defaultShortRead.id,
                inputFASTQURLs: [inputURL],
                referenceFASTAURL: referenceURL,
                projectURL: nil,
                outputDirectory: outputDirectory,
                sampleName: "sample",
                threads: 4
            )

            let written = try AppUITestMappingBackend.writeResult(for: request)
            XCTAssertEqual(written.mapper, tool)
            XCTAssertEqual(written.contigs.count, 1)
            XCTAssertEqual(written.contigs.first?.contigName, "chr1")
            XCTAssertEqual(written.contigs.first?.contigLength, expectedContigLength)
            XCTAssertNotNil(written.viewerBundleURL, "Deterministic mapping backend should synthesize a viewer bundle")
            if let viewerBundleURL = written.viewerBundleURL {
                XCTAssertTrue(FileManager.default.fileExists(atPath: viewerBundleURL.appendingPathComponent("manifest.json").path))
            }

            let loaded = try MappingResult.load(from: outputDirectory)
            XCTAssertEqual(loaded.mapper, tool)
            XCTAssertEqual(loaded.contigs.count, 1)
            XCTAssertEqual(loaded.contigs.first?.contigName, "chr1")
            XCTAssertEqual(loaded.totalReads, written.totalReads)
            XCTAssertEqual(loaded.mappedReads, written.mappedReads)

            let provenance = try XCTUnwrap(MappingProvenance.load(from: outputDirectory))
            XCTAssertEqual(provenance.mapper, tool)
            XCTAssertEqual(provenance.mapperVersion, "ui-test-deterministic")
            XCTAssertEqual(provenance.samtoolsVersion, "ui-test-deterministic")
            XCTAssertEqual(provenance.viewerBundlePath, written.viewerBundleURL?.standardizedFileURL.path)
            XCTAssertEqual(provenance.commandInvocations.first?.label, tool.displayName)
        }
    }

    func testWriteResultSynthesizesSingleSequenceViewerBundleForMultiContigReference() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("mapping-backend-multicontig-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempRoot) }
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let referenceURL = tempRoot.appendingPathComponent("ref.fasta")
        let referenceFASTA = """
            >chr1 primary
            ACGTACGTACGTACGT
            >chr2 secondary
            TTTTCCCCAAAAGGGG
            """
        try referenceFASTA.write(to: referenceURL, atomically: true, encoding: .utf8)

        let inputURL = tempRoot.appendingPathComponent("reads.fastq.gz")
        try Data().write(to: inputURL)

        let outputDirectory = tempRoot.appendingPathComponent("out-minimap2", isDirectory: true)
        let request = MappingRunRequest(
            tool: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            inputFASTQURLs: [inputURL],
            referenceFASTAURL: referenceURL,
            projectURL: nil,
            outputDirectory: outputDirectory,
            sampleName: "sample",
            threads: 4
        )

        let written = try AppUITestMappingBackend.writeResult(for: request)
        let viewerBundleURL = try XCTUnwrap(written.viewerBundleURL)
        let manifest = try BundleManifest.load(from: viewerBundleURL)

        XCTAssertEqual(written.contigs.map(\.contigName), ["chr1"])
        XCTAssertEqual(manifest.genome?.chromosomes.map(\.name), ["chr1"])
        // The viewer manifest stores no derivable summary (lane 12.37), and a reader builds it in memory.
        XCTAssertNil(manifest.browserSummary)
        let summary = manifest.withSynthesizedBrowserSummaryIfNeeded().browserSummary
        XCTAssertEqual(summary?.sequences.map(\.name), ["chr1"])
        XCTAssertEqual(summary?.aggregate.alignmentTrackCount, 0)
    }
}
