// ExactBareHeaderIndexMemoryTests.swift - The split by the index in the read names holds no state for each record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// DEMUXSPLIT-S3-GROUP, its memory half (ruling BIOQA-ROWS-MEMORY items 9 to 11). The probe measured about 557 B of
// footprint for each record in the lungfish-cli child that runs the split, so 20 M pairs (40 M records) need about 22 GB.
// The run may keep a bounded amount of state however many records it reads. Its `read-ids.txt` files stay what they were:
// one name a line, in the order of the input, in every output mode. No tool runs.

import XCTest
import CryptoKit
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// The reads of these tests: names of 37 characters, each carrying the i7 and i5 of one of the plate's eight samples, or
/// (one name in ten) a pair that no sample has, on 150 bases with quality `I`.
private enum HeaderIndexReads {
    static let count = 200_000
    static let plate: [(id: String, i7: String, i5: String)] = [
        ("S01", "ATTACTCG", "TATAGCCT"), ("S02", "TCCGGAGA", "ATAGAGGC"), ("S03", "CGCTCATT", "CCTATCCT"),
        ("S04", "GAGATTCC", "GGCTCTGA"), ("S05", "ATTCAGAA", "AGGCGAAG"), ("S06", "GAATTCGT", "TAATCTTA"),
        ("S07", "CTGAAGCT", "CAGGACGT"), ("S08", "TAATGCGC", "GTACTGAC"),
    ]
    static let foreign = ["AAAAAAAA+CCCCCCCC", "GGGGGGGG+TTTTTTTT", "CCCCCCCC+AAAAAAAA"]

    static var kit: BarcodeKitDefinition {
        BarcodeKitDefinition(
            id: "plate", displayName: "Plate", platform: .illumina, isDualIndexed: true, pairingMode: .fixedDual,
            barcodes: plate.map { BarcodeEntry(id: $0.id, i7Sequence: $0.i7, i5Sequence: $0.i5) }
        )
    }

    /// 1,000 calls in a shuffled order: sample k (0 to 7) 25 × (k + 1) times, and 100 names of no sample (nil).
    private static let cycle: [Int?] = {
        var entries: [Int?] = []
        for sample in 0..<plate.count { entries += Array<Int?>(repeating: sample, count: 25 * (sample + 1)) }
        entries += Array<Int?>(repeating: nil, count: 100)
        var generator = DemuxFloorSeededGenerator(seed: 5)
        entries.shuffle(using: &generator)
        return entries
    }()

    private static let sequences: [String] = {
        var generator = DemuxFloorSeededGenerator(seed: 11)
        return (0..<64).map { _ in DemuxFloorFixtures.randomBases(150, using: &generator) }
    }()

    /// The read ID of record `index`, 37 characters, unique.
    static func name(_ index: Int) -> String {
        "A00123:45:H7KLMDSX5:1:1101:\(1000 + index / 90_000):\(10_000 + index % 90_000)"
    }

    /// The sample record `index` belongs to, or "unassigned".
    static func owner(_ index: Int) -> String {
        cycle[index % 1_000].map { plate[$0].id } ?? "unassigned"
    }

    static func record(_ index: Int) -> String {
        let indexes = cycle[index % 1_000].map { "\(plate[$0].i7)+\(plate[$0].i5)" } ?? foreign[index % foreign.count]
        return "@\(name(index)) 1:N:0:\(indexes)\n\(sequences[index % sequences.count])\n+\n\(String(repeating: "I", count: 150))\n"
    }

    /// Writes records `range` in blocks, so that the writing leaves no large allocation behind.
    static func write(_ range: Range<Int>, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var block = ""
        for index in range {
            block += record(index)
            if (index + 1) % 5_000 == 0 || index == range.upperBound - 1 {
                try handle.write(contentsOf: Data(block.utf8))
                block = ""
            }
        }
    }

    /// The `read-ids.txt` of each sample over `range`: every name of the sample in input order, a line each.
    static func readIDs(of range: Range<Int>) -> [String: Data] {
        var bytes: [String: Data] = [:]
        for index in range {
            bytes[owner(index), default: Data()].append(contentsOf: name(index).utf8)
            bytes[owner(index), default: Data()].append(0x0A)
        }
        return bytes
    }
}

/// The footprint of this process, read every 2 ms, and its highest value.
private final class PeakFootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private var running = true
    private let finished = DispatchSemaphore(value: 0)

    func start() {
        let thread = Thread { [self] in
            while true {
                lock.lock()
                let go = running
                lock.unlock()
                guard go else { break }
                if let now = try? ProcessMemorySampler.currentResidentFootprint() {
                    lock.lock()
                    peak = max(peak, now)
                    lock.unlock()
                }
                Thread.sleep(forTimeInterval: 0.002)
            }
            finished.signal()
        }
        thread.start()
    }

    func stop() -> UInt64 {
        lock.lock()
        running = false
        lock.unlock()
        finished.wait()
        lock.lock()
        defer { lock.unlock() }
        return peak
    }
}

final class ExactBareHeaderIndexMemoryTests: XCTestCase {
    private var root: URL!

    private enum OutputMode: String, CaseIterable {
        case physical, virtual
    }

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "demux-header-memory")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    private func config(input: URL, output: URL, mode: OutputMode, rootFASTQFilename: String, threads: Int = 1) -> DemultiplexConfig {
        DemultiplexConfig(
            inputURL: input, barcodeKit: HeaderIndexReads.kit, outputDirectory: output, errorRate: 0.15, threads: threads,
            engine: .headerIndex, rootBundleURL: mode == .virtual ? input : nil,
            rootFASTQFilename: mode == .virtual ? rootFASTQFilename : nil
        )
    }

    /// Checks the counts of `range` and that each sample's `read-ids.txt` holds the bytes the base wrote for it.
    private func assertReadIDs(_ result: DemultiplexResult, output: URL, range: Range<Int>, label: String) throws {
        let expected = HeaderIndexReads.readIDs(of: range)
        var bundles: [String: String] = [:]
        for barcode in result.manifest.barcodes where barcode.readCount > 0 { bundles[barcode.barcodeID] = barcode.bundleRelativePath }
        if let path = result.manifest.unassigned.bundleRelativePath { bundles["unassigned"] = path }
        XCTAssertEqual(Set(bundles.keys), Set(expected.keys), "\(label): the samples that hold reads")
        XCTAssertEqual(result.manifest.inputReadCount, range.count, "\(label): reads read")
        for (id, data) in expected.sorted(by: { $0.key < $1.key }) {
            guard let path = bundles[id] else { continue }
            let url = output.appendingPathComponent(path, isDirectory: true).appendingPathComponent("read-ids.txt")
            let actual = try Data(contentsOf: url)
            let digest = SHA256.hash(data: actual).map { String(format: "%02x", $0) }.joined()
            print("DEMUXSPLIT-MEM \(label) \(id) read-ids.txt \(actual.count) bytes sha256 \(digest)")
            XCTAssertTrue(actual == data, "\(label) \(id): read-ids.txt is \(actual.count) B, and the base wrote \(data.count) B")
        }
    }

    /// 200,000 records split into eight samples and an unassigned share by the index in each name, in a physical output and
    /// in a virtual one (the input is the root of the output). The footprint may rise 64 B a record and 32 MB.
    private func assertSplitKeepsNoStateForEachRecord(_ mode: OutputMode) async throws {
        let workspace = root.appendingPathComponent("\(mode.rawValue).lungfish/workspace", isDirectory: true)
        let bundle = workspace.appendingPathComponent("input.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try HeaderIndexReads.write(0..<HeaderIndexReads.count, to: bundle.appendingPathComponent("reads.fastq"))
        let output = workspace.appendingPathComponent("demux-out", isDirectory: true)
        let run = config(input: bundle, output: output, mode: mode, rootFASTQFilename: "reads.fastq")

        let baseline = try ProcessMemorySampler.currentResidentFootprint()
        let sampler = PeakFootprintSampler()
        sampler.start()
        let result = try await DemultiplexingPipeline().run(config: run, progress: { _, _ in })
        let peak = sampler.stop()

        let rise = peak > baseline ? peak - baseline : 0
        let allowed = UInt64(64 * HeaderIndexReads.count + 32 * 1_048_576)
        print("DEMUXSPLIT-MEM \(mode.rawValue) footprint rose \(rise) B (\(rise / UInt64(HeaderIndexReads.count)) B a record), allowed \(allowed) B")
        XCTAssertLessThanOrEqual(
            rise, allowed,
            "\(mode.rawValue): the footprint rose \(rise) B, \(rise / UInt64(HeaderIndexReads.count)) B a record, over \(allowed) B"
        )
        try assertReadIDs(result, output: output, range: 0..<HeaderIndexReads.count, label: mode.rawValue)
    }

    func testPhysicalOutputKeepsNoStateForEachRecord() async throws {
        try await assertSplitKeepsNoStateForEachRecord(.physical)
    }

    func testVirtualOutputKeepsNoStateForEachRecord() async throws {
        try await assertSplitKeepsNoStateForEachRecord(.virtual)
    }

    /// A bundle of two files is two shards. Each sample's `read-ids.txt` lists the first file's names and then the second's.
    func testTwoFileBundleListsEachFilesNamesInFileOrder() async throws {
        for mode in OutputMode.allCases {
            let workspace = root.appendingPathComponent("two-\(mode.rawValue).lungfish/workspace", isDirectory: true)
            let bundle = workspace.appendingPathComponent("pool.\(FASTQBundle.directoryExtension)", isDirectory: true)
            let chunks = bundle.appendingPathComponent("chunks", isDirectory: true)
            try HeaderIndexReads.write(0..<1_500, to: chunks.appendingPathComponent("a.fastq"))
            try HeaderIndexReads.write(1_500..<3_000, to: chunks.appendingPathComponent("b.fastq"))
            let files = ["a", "b"].map {
                "{\"filename\": \"chunks/\($0).fastq\", \"originalPath\": \"/tmp/\($0).fastq\", \"sizeBytes\": 1, \"isSymlink\": false}"
            }
            try "{\"version\": 1, \"files\": [\(files.joined(separator: ", "))]}"
                .write(to: bundle.appendingPathComponent("source-files.json"), atomically: true, encoding: .utf8)
            let output = workspace.appendingPathComponent("demux-out", isDirectory: true)
            let result = try await DemultiplexingPipeline().run(
                config: config(input: bundle, output: output, mode: mode, rootFASTQFilename: "chunks/a.fastq", threads: 2),
                progress: { _, _ in }
            )
            try assertReadIDs(result, output: output, range: 0..<3_000, label: "two files, \(mode.rawValue)")
            let left = ((try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? []).filter { $0.hasPrefix(".exact-bare") }
            XCTAssertEqual(left, [], "two files, \(mode.rawValue): the run leaves no scratch folder in the output")
        }
    }

    private func isNoReadNameIndex(_ error: Error) -> Bool {
        if case DemultiplexError.noReadNameIndex = error { return true }
        return false
    }

    /// A split by the names that finds no index of the kit in any name stops in words, after the pass has written the IDs
    /// of the unassigned reads into the scratch folder (DEMUXSPLIT-MEM review SF2). The failed run leaves no scratch folder.
    /// `run` writes into a staging folder that a failed run removes whole, so its output holds no scratch folder even
    /// where the pass would leave one. The second half runs the pass on an output folder of its own, which only the pass's
    /// own removal of the scratch folder can clear.
    func testAFailedRunLeavesNoScratchFolder() async throws {
        let workspace = root.appendingPathComponent("failed.lungfish/workspace", isDirectory: true)
        let bundle = workspace.appendingPathComponent("input.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let records = (0..<2_000).map { "@r\($0) 1:N:0:\(HeaderIndexReads.foreign[$0 % 3])\nACGTACGTAC\n+\nIIIIIIIIII\n" }
        try records.joined().write(to: bundle.appendingPathComponent("reads.fastq"), atomically: true, encoding: .utf8)

        let output = workspace.appendingPathComponent("demux-out", isDirectory: true)
        do {
            _ = try await DemultiplexingPipeline().run(
                config: config(input: bundle, output: output, mode: .physical, rootFASTQFilename: "reads.fastq"),
                progress: { _, _ in }
            )
            XCTFail("the run found no index of the kit in any name and still returned")
        } catch {
            XCTAssertTrue(isNoReadNameIndex(error), "the run threw \(error), not noReadNameIndex")
        }
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? []).filter { $0.hasPrefix(".exact-bare") }
        XCTAssertEqual(left, [], "the failed run leaves no scratch folder in the output")

        let pipeline = DemultiplexingPipeline()
        let own = workspace.appendingPathComponent("own-out", isDirectory: true)
        do {
            _ = try await pipeline.runExactBareBarcodeDemux(
                config: config(input: bundle, output: own, mode: .physical, rootFASTQFilename: "reads.fastq"),
                inputFASTQ: pipeline.resolveInputFASTQ(bundle), runClock: ProvenanceRunClock(), byReadNames: true,
                progress: { _, _ in }
            )
            XCTFail("the pass found no index of the kit in any name and still returned")
        } catch {
            XCTAssertTrue(isNoReadNameIndex(error), "the pass threw \(error), not noReadNameIndex")
        }
        let ownLeft = try FileManager.default.contentsOfDirectory(atPath: own.path).filter { $0.hasPrefix(".exact-bare") }
        XCTAssertEqual(ownLeft, [], "the failed pass leaves no scratch folder in its output")
    }
}
