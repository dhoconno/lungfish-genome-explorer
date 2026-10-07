// AnnotationOutputReplacementTests.swift - bam annotate-best and annotate-cds-best refuse before they replace anything
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.1 lane L6, item 1. With `--replace` the two services deleted the
// earlier output bundle before their own refusals ran, and an input that sat
// inside that bundle went with it. Every refusal now runs first, and a
// refused run leaves every file as it was.

import XCTest
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

final class AnnotationOutputReplacementTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationOutputReplacementTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - An input inside the output

    func testAMappingResultInsideTheOutputIsRefusedBeforeAnythingIsDeleted() async throws {
        for kind in ServiceKind.allCases {
            let source = try Self.makeSourceBundle(in: root.appendingPathComponent("\(kind)-source", isDirectory: true))
            let output = try Self.makeEarlierOutput(at: root.appendingPathComponent("\(kind)-Out.lungfishref", isDirectory: true))
            let mapping = try Self.makeMappingResult(in: output.appendingPathComponent("mapping", isDirectory: true))
            let runner = ProbeSamtoolsRunner(stdout: Self.sam, exitCode: 0, probe: nil)

            do {
                try await kind.run(source: source, mapping: mapping.directory, output: output, replace: true, runner: runner)
                XCTFail("\(kind): a mapping result inside the output must refuse the run")
            } catch {
                XCTAssertEqual(
                    error as? OutputReplacementRefusal,
                    .inputInsideOutput(input: mapping.directory.standardizedFileURL.path, output: output.standardizedFileURL.path),
                    "\(kind): \(error)"
                )
                XCTAssertFalse(error.localizedDescription.contains("\n"), "\(kind): the reason is one line")
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: mapping.bam.path), "\(kind): the mapped BAM survives")
            XCTAssertTrue(FileManager.default.fileExists(atPath: mapping.directory.appendingPathComponent("mapping-result.json").path), "\(kind): the mapping sidecar survives")
            XCTAssertTrue(FileManager.default.fileExists(atPath: Self.marker(in: output).path), "\(kind): the earlier output survives")
            let commands = await runner.commands
            XCTAssertEqual(commands, [], "\(kind): samtools never runs")
        }
    }

    func testAnOutputInsideTheSourceBundleIsRefused() async throws {
        for kind in ServiceKind.allCases {
            let source = try Self.makeSourceBundle(in: root.appendingPathComponent("\(kind)-nested", isDirectory: true))
            let mapping = try Self.makeMappingResult(in: root.appendingPathComponent("\(kind)-nested-mapping", isDirectory: true))
            let output = source.appendingPathComponent("Inner.lungfishref", isDirectory: true)
            let runner = ProbeSamtoolsRunner(stdout: Self.sam, exitCode: 0, probe: nil)

            do {
                try await kind.run(source: source, mapping: mapping.directory, output: output, replace: true, runner: runner)
                XCTFail("\(kind): an output inside the source bundle must refuse the run")
            } catch {
                XCTAssertEqual(
                    error as? OutputReplacementRefusal,
                    .outputInsideInput(output: output.standardizedFileURL.path, input: source.standardizedFileURL.path),
                    "\(kind): \(error)"
                )
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "\(kind): nothing is written inside the source")
            let commands = await runner.commands
            XCTAssertEqual(commands, [], "\(kind): samtools never runs")
        }
    }

    func testTheSourceNamedThroughASymlinkIsTheSameBundleAndIsKept() async throws {
        for kind in ServiceKind.allCases {
            let real = root.appendingPathComponent("\(kind)-real", isDirectory: true)
            let source = try Self.makeSourceBundle(in: real)
            let link = root.appendingPathComponent("\(kind)-link", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
            let output = link.appendingPathComponent(source.lastPathComponent, isDirectory: true)
            let mapping = try Self.makeMappingResult(in: root.appendingPathComponent("\(kind)-link-mapping", isDirectory: true))
            let runner = ProbeSamtoolsRunner(stdout: Self.sam, exitCode: 0, probe: nil)

            do {
                try await kind.run(source: source, mapping: mapping.directory, output: output, replace: true, runner: runner)
                XCTFail("\(kind): replacing the source through a symlink must refuse the run")
            } catch {
                XCTAssertTrue(kind.isSourceAndOutputMatch(error), "\(kind): \(error)")
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("manifest.json").path), "\(kind): the source survives")
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("alignments/source.bam").path), "\(kind): the source survives whole")
            let commands = await runner.commands
            XCTAssertEqual(commands, [], "\(kind): samtools never runs")
        }
    }

    // MARK: - Refusals after the delete

    /// samtools failing is a refusal of the run. The earlier output must still
    /// be in place while samtools runs, so a failed run deletes nothing.
    func testTheEarlierOutputIsInPlaceWhileSamtoolsRunsAndAfterItFails() async throws {
        for kind in ServiceKind.allCases {
            let source = try Self.makeSourceBundle(in: root.appendingPathComponent("\(kind)-fail-source", isDirectory: true))
            let mapping = try Self.makeMappingResult(in: root.appendingPathComponent("\(kind)-fail-mapping", isDirectory: true))
            let output = try Self.makeEarlierOutput(at: root.appendingPathComponent("\(kind)-Earlier.lungfishref", isDirectory: true))
            let runner = ProbeSamtoolsRunner(stdout: "", exitCode: 1, probe: Self.marker(in: output))

            do {
                try await kind.run(source: source, mapping: mapping.directory, output: output, replace: true, runner: runner)
                XCTFail("\(kind): a failed samtools must fail the run")
            } catch {
                XCTAssertTrue(kind.isSamtoolsFailure(error), "\(kind): \(error)")
            }
            let seen = await runner.probeExistedAtRun
            XCTAssertEqual(seen, [true], "\(kind): the earlier output is untouched while samtools runs")
            XCTAssertTrue(FileManager.default.fileExists(atPath: Self.marker(in: output).path), "\(kind): the earlier output survives")
        }
    }

    func testReplaceStillReplacesTheEarlierOutput() async throws {
        for kind in ServiceKind.allCases {
            let source = try Self.makeSourceBundle(in: root.appendingPathComponent("\(kind)-ok-source", isDirectory: true))
            let mapping = try Self.makeMappingResult(in: root.appendingPathComponent("\(kind)-ok-mapping", isDirectory: true))
            let output = try Self.makeEarlierOutput(at: root.appendingPathComponent("\(kind)-Replaced.lungfishref", isDirectory: true))
            let runner = ProbeSamtoolsRunner(stdout: Self.sam, exitCode: 0, probe: nil)

            try await kind.run(source: source, mapping: mapping.directory, output: output, replace: true, runner: runner)

            XCTAssertFalse(FileManager.default.fileExists(atPath: Self.marker(in: output).path), "\(kind): the earlier output is replaced")
            let manifest = try BundleManifest.load(from: output)
            XCTAssertEqual(manifest.annotations.map(\.id), ["replace-track"], "\(kind)")
        }
    }

    // MARK: - Fixtures

    enum ServiceKind: String, CaseIterable, CustomStringConvertible {
        case best = "annotate-best"
        case cdsBest = "annotate-cds-best"

        var description: String { rawValue }

        func run(source: URL, mapping: URL, output: URL, replace: Bool, runner: ProbeSamtoolsRunner) async throws {
            switch self {
            case .best:
                _ = try await BestMappedReadsAnnotationService(samtoolsRunner: runner, trackIDProvider: { _ in "replace-track" })
                    .convertBestMappedReads(request: BestMappedReadsAnnotationRequest(
                        sourceBundleURL: source,
                        mappingResultURL: mapping,
                        outputBundleURL: output,
                        outputTrackName: "Replace",
                        replaceExisting: replace
                    ))
            case .cdsBest:
                _ = try await CDSBestAnnotationService(samtoolsRunner: runner, trackIDProvider: { _ in "replace-track" })
                    .convertBestCDS(request: CDSBestAnnotationRequest(
                        sourceBundleURL: source,
                        mappingResultURL: mapping,
                        outputBundleURL: output,
                        outputTrackName: "Replace",
                        replaceExisting: replace
                    ))
            }
        }

        func isSourceAndOutputMatch(_ error: Error) -> Bool {
            switch (self, error) {
            case (.best, BestMappedReadsAnnotationServiceError.sourceAndOutputBundleMatch): return true
            case (.cdsBest, CDSBestAnnotationServiceError.sourceAndOutputBundleMatch): return true
            default: return false
            }
        }

        func isSamtoolsFailure(_ error: Error) -> Bool {
            switch (self, error) {
            case (.best, BestMappedReadsAnnotationServiceError.samtoolsFailed): return true
            case (.cdsBest, CDSBestAnnotationServiceError.samtoolsFailed): return true
            default: return false
            }
        }
    }

    /// One read the best-read rule keeps and one spliced read the CDS rule keeps.
    static let sam = """
    @HD\tVN:1.6\tSO:coordinate
    @SQ\tSN:chr1\tLN:1000
    read-1\t0\tchr1\t101\t60\t20M\t*\t0\t0\tAAAAAAAAAAAAAAAAAAAA\tIIIIIIIIIIIIIIIIIIII\tNM:i:0
    cds-1\t0\tchr1\t301\t60\t10M20N10M\t*\t0\t0\tCCCCCCCCCCCCCCCCCCCC\tIIIIIIIIIIIIIIIIIIII\tNM:i:0
    """

    static func makeSourceBundle(in directory: URL) throws -> URL {
        let bundle = directory.appendingPathComponent("Source.lungfishref", isDirectory: true)
        let alignments = bundle.appendingPathComponent("alignments", isDirectory: true)
        try FileManager.default.createDirectory(at: alignments, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: alignments.appendingPathComponent("source.bam").path, contents: Data("bam".utf8))
        FileManager.default.createFile(atPath: alignments.appendingPathComponent("source.bam.bai").path, contents: Data("bai".utf8))
        try BundleManifest(
            name: "Replace Fixture",
            identifier: "replace-fixture.\(UUID().uuidString)",
            source: SourceInfo(organism: "Fixture organism", assembly: "Fixture assembly", database: "Fixture database"),
            genome: nil,
            alignments: [
                AlignmentTrackInfo(
                    id: "aln-source",
                    name: "Source BAM",
                    format: .bam,
                    sourcePath: "alignments/source.bam",
                    indexPath: "alignments/source.bam.bai"
                ),
            ]
        ).save(to: bundle)
        return bundle
    }

    /// An earlier output bundle with a marker file that only it holds.
    static func makeEarlierOutput(at bundle: URL) throws -> URL {
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try BundleManifest(
            name: "Earlier Output",
            identifier: "earlier-output.\(UUID().uuidString)",
            source: SourceInfo(organism: "Fixture organism", assembly: "Fixture assembly", database: "Fixture database"),
            genome: nil
        ).save(to: bundle)
        try Data("earlier".utf8).write(to: marker(in: bundle))
        return bundle
    }

    static func marker(in bundle: URL) -> URL {
        bundle.appendingPathComponent("earlier-marker.txt")
    }

    static func makeMappingResult(in directory: URL) throws -> (directory: URL, bam: URL) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bam = directory.appendingPathComponent("mapped.sorted.bam")
        let bai = directory.appendingPathComponent("mapped.sorted.bam.bai")
        FileManager.default.createFile(atPath: bam.path, contents: Data("bam".utf8))
        FileManager.default.createFile(atPath: bai.path, contents: Data("bai".utf8))
        try MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            bamURL: bam,
            baiURL: bai,
            totalReads: 2,
            mappedReads: 2,
            unmappedReads: 0,
            wallClockSeconds: 1.0,
            contigs: []
        ).save(to: directory)
        return (directory, bam)
    }
}

/// A samtools stand-in that records each call and, when given a probe path,
/// whether that path existed at the moment samtools ran.
actor ProbeSamtoolsRunner: AlignmentSamtoolsRunning {
    private let stdout: String
    private let exitCode: Int32
    private let probe: URL?
    private(set) var commands: [[String]] = []
    private(set) var probeExistedAtRun: [Bool] = []

    init(stdout: String, exitCode: Int32, probe: URL?) {
        self.stdout = stdout
        self.exitCode = exitCode
        self.probe = probe
    }

    func runSamtools(arguments: [String], timeout: TimeInterval) async throws -> NativeToolResult {
        commands.append(arguments)
        if let probe {
            probeExistedAtRun.append(FileManager.default.fileExists(atPath: probe.path))
        }
        return NativeToolResult(exitCode: exitCode, stdout: stdout, stderr: exitCode == 0 ? "" : "injected samtools failure")
    }

    func samtoolsVersion() async -> String {
        "1.23"
    }
}
