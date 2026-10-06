// DemultiplexMateAssignmentTests.swift - Both mates of a fragment follow the fragment's barcode call
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Both demultiplex engines called each record of an interleaved file on its
// own, so the mates of one fragment landed in different bundles: a pair
// with an inline barcode on read 1 only had read 2 in unassigned, and a
// pair whose mates carried different barcodes was split between them (A9,
// D6). Virtual bundles then made it worse. With Casava names both mates
// share a read ID, so a split pair materialized in both bundles, and read 2
// took read 1's barcode trim. With /1 /2 names the listed IDs never matched
// the root, so every count was 0 and every bundle materialized to nothing.
//
// The fixture holds seven pairs of 2x60 reads with 8-base inline barcodes
// (BC01 ACGTTGCA, BC02 TTGGCCAA), named the Casava way or with /1 /2:
// two pairs with BC01 on both mates, two with BC01 on read 1 only, one with
// BC02 on read 2 only, one with BC01 and BC02, and one with neither. The
// inserts repeat GATTACA, which holds neither barcode in either orientation.

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class DemultiplexMateAssignmentTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "demultiplex-mate-assignment")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Fixture

    enum Naming { case casava, slash }

    private static let bc01 = "ACGTTGCA"
    private static let bc02 = "TTGGCCAA"

    /// `length` bases of GATTACA repeated, starting at `offset`.
    private static func insert(_ offset: Int, _ length: Int) -> String {
        let unit = Array("GATTACA")
        return String((0..<length).map { unit[($0 + offset) % unit.count] })
    }

    private struct Fragment {
        let name: String
        let mate1: String
        let mate2: String?
    }

    private static let pairs: [Fragment] = [
        Fragment(name: "agree_0", mate1: bc01 + insert(0, 52), mate2: bc01 + insert(1, 52)),
        Fragment(name: "r1only_0", mate1: bc01 + insert(2, 52), mate2: insert(3, 60)),
        Fragment(name: "clash_0", mate1: bc01 + insert(4, 52), mate2: bc02 + insert(5, 52)),
        Fragment(name: "r2only_0", mate1: insert(6, 60), mate2: bc02 + insert(0, 52)),
        Fragment(name: "agree_1", mate1: bc01 + insert(1, 52), mate2: bc01 + insert(2, 52)),
        Fragment(name: "none_0", mate1: insert(3, 60), mate2: insert(4, 60)),
        Fragment(name: "r1only_1", mate1: bc01 + insert(5, 52), mate2: insert(6, 60)),
    ]

    private static func header(_ name: String, mate: Int, _ naming: Naming) -> String {
        switch naming {
        case .casava: return "\(name) \(mate):N:0:1"
        case .slash: return "\(name)/\(mate)"
        }
    }

    private static func fastq(_ fragments: [Fragment], _ naming: Naming) -> String {
        func record(_ header: String, _ sequence: String) -> String {
            "@\(header)\n\(sequence)\n+\n\(String(repeating: "I", count: sequence.count))\n"
        }
        return fragments.map { fragment in
            guard let mate2 = fragment.mate2 else { return record(fragment.name, fragment.mate1) }
            return record(header(fragment.name, mate: 1, naming), fragment.mate1)
                + record(header(fragment.name, mate: 2, naming), mate2)
        }.joined()
    }

    private func kit() throws -> BarcodeKitDefinition {
        let csv = root.appendingPathComponent("kit.csv")
        try "id,sequence\nBC01,\(Self.bc01)\nBC02,\(Self.bc02)\n".write(to: csv, atomically: true, encoding: .utf8)
        return try BarcodeKitRegistry.loadCustomKit(from: csv, name: "kit")
    }

    private func requireTools() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.cutadapt),
              await NativeToolRunner.shared.isToolAvailable(.seqkit) else {
            try ToolAvailability.skipOrFail("managed cutadapt or seqkit is not installed")
        }
    }

    /// One record of a bundle: its fragment, its mate (0 for a single read) and its length.
    private struct Placed: Equatable, CustomStringConvertible {
        let fragment: String
        let mate: Int
        let length: Int
        var description: String { "\(fragment)/\(mate):\(length)" }
    }

    private func placed(in fastq: URL) async throws -> [Placed] {
        var records: [Placed] = []
        for try await record in FASTQReader(validateSequence: false).records(from: fastq) {
            var fragment = record.identifier
            var mate = 0
            if fragment.hasSuffix("/1") || fragment.hasSuffix("/2") {
                mate = fragment.hasSuffix("/1") ? 1 : 2
                fragment = String(fragment.dropLast(2))
            } else if let description = record.description {
                mate = description.hasPrefix("1:") ? 1 : description.hasPrefix("2:") ? 2 : 0
            }
            records.append(Placed(fragment: fragment, mate: mate, length: record.length))
        }
        return records
    }

    private func p(_ fragment: String, _ mate: Int, _ length: Int) -> Placed {
        Placed(fragment: fragment, mate: mate, length: length)
    }

    /// Reads of a bundle: its FASTQ when it holds one, else its reads materialized.
    private func placed(inBundle bundle: URL) async throws -> [Placed] {
        if FASTQBundle.loadDerivedManifest(in: bundle) == nil {
            return try await placed(in: try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle)))
        }
        let materialized = try await FASTQCLIMaterializer(runner: .shared).materialize(
            bundleURL: bundle,
            tempDirectory: root.appendingPathComponent("materialized-\(UUID().uuidString)", isDirectory: true),
            progress: { _ in }
        )
        return try await placed(in: materialized)
    }

    /// The reads every bundle of a fixture run holds once both mates follow the fragment's call.
    private static let expectedBC01 = [
        ("agree_0", 1, 52), ("agree_0", 2, 52), ("r1only_0", 1, 52), ("r1only_0", 2, 60),
        ("agree_1", 1, 52), ("agree_1", 2, 52), ("r1only_1", 1, 52), ("r1only_1", 2, 60),
    ]
    private static let expectedBC02 = [("r2only_0", 1, 60), ("r2only_0", 2, 52)]
    private static let expectedUnassigned = [("clash_0", 1, 60), ("clash_0", 2, 60), ("none_0", 1, 60), ("none_0", 2, 60)]

    private func expected(_ rows: [(String, Int, Int)]) -> [Placed] {
        rows.map { p($0.0, $0.1, $0.2) }
    }

    private func project() throws -> URL {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("Imports"), withIntermediateDirectories: true)
        return project
    }

    private func bundle(_ result: DemultiplexResult, _ id: String) throws -> URL {
        if id == "unassigned" { return try XCTUnwrap(result.unassignedBundleURL) }
        return try XCTUnwrap(result.outputBundleURLs.first { $0.lastPathComponent == "\(id).lungfishfastq" }, "a \(id) bundle")
    }

    // MARK: - cutadapt, physical

    func testAPhysicalRunPlacesBothMatesOfEveryFragmentByItsCall() async throws {
        try await requireTools()
        let project = try project()
        let input = project.appendingPathComponent("pairs.fastq")
        try Self.fastq(Self.pairs, .casava).write(to: input, atomically: true, encoding: .utf8)

        let result = try await DemultiplexingPipeline().run(
            config: DemultiplexConfig(
                inputURL: input,
                barcodeKit: try kit(),
                outputDirectory: project.appendingPathComponent("Analyses/demux", isDirectory: true),
                barcodeLocation: .fivePrime,
                errorRate: 0.0,
                minimumOverlap: 8,
                trimBarcodes: true,
                threads: 2
            ),
            progress: { _, _ in }
        )

        let bc01 = try await placed(inBundle: try bundle(result, "BC01"))
        XCTAssertEqual(bc01, expected(Self.expectedBC01), "BC01 holds both mates of its pairs, read 2 of a read-1 barcode untrimmed")
        let bc02 = try await placed(inBundle: try bundle(result, "BC02"))
        XCTAssertEqual(bc02, expected(Self.expectedBC02))
        let unassigned = try await placed(inBundle: try bundle(result, "unassigned"))
        XCTAssertEqual(unassigned, expected(Self.expectedUnassigned), "a pair whose mates disagree goes to unassigned whole")
        XCTAssertEqual(result.manifest.inputReadCount, 14)
        XCTAssertEqual(result.manifest.barcodes.map(\.readCount), [8, 2])
        XCTAssertEqual(result.manifest.unassigned.readCount, 4)
    }

    // MARK: - cutadapt, virtual

    private func runVirtual(_ naming: Naming) async throws -> DemultiplexResult {
        let project = try project()
        let rootBundle = project.appendingPathComponent("Imports/pairs.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: rootBundle, withIntermediateDirectories: true)
        let reads = rootBundle.appendingPathComponent("reads.fastq")
        try Self.fastq(Self.pairs, naming).write(to: reads, atomically: true, encoding: .utf8)
        return try await DemultiplexingPipeline().run(
            config: DemultiplexConfig(
                inputURL: reads,
                sourceBundleURL: rootBundle,
                barcodeKit: try kit(),
                outputDirectory: project.appendingPathComponent("Analyses/demux", isDirectory: true),
                barcodeLocation: .fivePrime,
                errorRate: 0.0,
                minimumOverlap: 8,
                trimBarcodes: true,
                threads: 2,
                rootBundleURL: rootBundle,
                rootFASTQFilename: "reads.fastq",
                inputSequenceFormat: .fastq
            ),
            progress: { _, _ in }
        )
    }

    private func assertVirtualRunPlacesWholePairs(_ naming: Naming, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await requireTools()
        let result = try await runVirtual(naming)
        XCTAssertEqual(result.manifest.inputReadCount, 14, "every record counted once", file: file, line: line)
        XCTAssertEqual(result.manifest.barcodes.map(\.barcodeID), ["BC01", "BC02"], file: file, line: line)
        XCTAssertEqual(result.manifest.barcodes.map(\.readCount), [8, 2], file: file, line: line)
        XCTAssertEqual(result.manifest.unassigned.readCount, 4, file: file, line: line)
        for (id, rows) in [("BC01", Self.expectedBC01), ("BC02", Self.expectedBC02), ("unassigned", Self.expectedUnassigned)] {
            let bundleURL = try bundle(result, id)
            let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: bundleURL), file: file, line: line)
            XCTAssertEqual(manifest.cachedStatistics.readCount, rows.count, "\(id): the cached count", file: file, line: line)
            XCTAssertEqual(
                manifest.cachedStatistics.baseCount, Int64(rows.map(\.2).reduce(0, +)),
                "\(id): the cached bases are the bases it materializes to", file: file, line: line
            )
            let materialized = try await placed(inBundle: bundleURL)
            XCTAssertEqual(materialized, expected(rows), "\(id): its reads, each mate trimmed by its own barcode", file: file, line: line)
            let preview = try await placed(in: bundleURL.appendingPathComponent("preview.fastq"))
            XCTAssertEqual(preview, expected(rows), "\(id): the preview holds both mates of each pair", file: file, line: line)
        }
    }

    func testAVirtualRunOfCasavaNamedPairsPlacesAndMaterializesWholePairs() async throws {
        try await assertVirtualRunPlacesWholePairs(.casava)
    }

    func testAVirtualRunOfSlashNamedPairsPlacesAndMaterializesWholePairs() async throws {
        try await assertVirtualRunPlacesWholePairs(.slash)
    }

    // MARK: - A file of pairs and single reads

    func testAMixedFileKeepsTheCallOfItsSingleReadsAndPlacesPairsWhole() async throws {
        try await requireTools()
        let project = try project()
        let input = project.appendingPathComponent("mixed.fastq")
        let singles = [
            Fragment(name: "merged_0", mate1: Self.bc01 + Self.insert(0, 80), mate2: nil),
            Fragment(name: "merged_1", mate1: Self.insert(1, 88), mate2: nil),
        ]
        let pairs = Self.pairs.filter { ["r1only_0", "clash_0"].contains($0.name) }
        try Self.fastq(singles + pairs, .casava).write(to: input, atomically: true, encoding: .utf8)

        let result = try await DemultiplexingPipeline().run(
            config: DemultiplexConfig(
                inputURL: input,
                barcodeKit: try kit(),
                outputDirectory: project.appendingPathComponent("Analyses/demux-mixed", isDirectory: true),
                barcodeLocation: .fivePrime,
                errorRate: 0.0,
                minimumOverlap: 8,
                trimBarcodes: true,
                threads: 2
            ),
            progress: { _, _ in }
        )

        let bc01 = try await placed(inBundle: try bundle(result, "BC01"))
        XCTAssertEqual(bc01, [p("merged_0", 0, 80), p("r1only_0", 1, 52), p("r1only_0", 2, 60)])
        XCTAssertNil(result.outputBundleURLs.first { $0.lastPathComponent == "BC02.lungfishfastq" }, "no mate is left in BC02")
        let unassigned = try await placed(inBundle: try bundle(result, "unassigned"))
        XCTAssertEqual(unassigned, [p("merged_1", 0, 88), p("clash_0", 1, 60), p("clash_0", 2, 60)])
    }

    // MARK: - The exact-bare engine

    func testTheExactBareEnginePlacesBothMatesOfEveryFragmentByItsCall() async throws {
        let project = try project()
        let input = project.appendingPathComponent("pairs.fastq")
        try Self.fastq(Self.pairs, .casava).write(to: input, atomically: true, encoding: .utf8)

        let result = try await DemultiplexingPipeline().run(
            config: DemultiplexConfig(
                inputURL: input,
                barcodeKit: try kit(),
                outputDirectory: project.appendingPathComponent("Analyses/demux-exact", isDirectory: true),
                trimBarcodes: false,
                threads: 1,
                engine: .exactBareBarcode
            ),
            progress: { _, _ in }
        )

        // The exact-bare engine keeps every read whole.
        func whole(_ rows: [(String, Int, Int)]) -> [Placed] { rows.map { p($0.0, $0.1, 60) } }
        let bc01 = try await placed(inBundle: try bundle(result, "BC01"))
        XCTAssertEqual(bc01, whole(Self.expectedBC01))
        let bc02 = try await placed(inBundle: try bundle(result, "BC02"))
        XCTAssertEqual(bc02, whole(Self.expectedBC02))
        let unassigned = try await placed(inBundle: try bundle(result, "unassigned"))
        XCTAssertEqual(unassigned, whole(Self.expectedUnassigned))
        XCTAssertEqual(result.manifest.barcodes.map(\.readCount), [8, 2])
        XCTAssertEqual(result.manifest.unassigned.readCount, 4)
    }
}
