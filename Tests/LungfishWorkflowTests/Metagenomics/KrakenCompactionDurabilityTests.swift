// KrakenCompactionDurabilityTests.swift - A gzip that dies mid-write leaves nothing under the name a reader trusts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane S62, M2 (SWIFT checks 4 and 5, inventory rows D1 and D2). Two private copies of `gzipCopy`
// wrote the gzip copy of the per-read Kraken2 output under its final name and never synced it, so a crash or a
// kill mid-write left a cut `.kraken.gz` that a reader trusts. Each test starts a copy on a large input, waits
// until gzip has written output, freezes gzip with SIGSTOP and looks at the folder, which is the state a crash
// leaves, then kills gzip. The final name must not exist while gzip runs or after it died, and no part file
// stays. The class name holds `Durability`, so `exfat-tests.sh --simulate` runs it with the ExFAT rename path.

import Darwin
import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishIO
@testable import LungfishWorkflow

/// The names a compaction writes besides the raw output and its index.
private func isGzipOutput(_ name: String) -> Bool {
    name != "classification.kraken" && !name.contains(".idx.sqlite")
}

/// The gzip processes that are children of this test process.
private func gzipChildren() -> [Int32] {
    ProcessTreeTerminator.descendantProcessIDs(of: getpid()).filter { pid in
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        return String(cString: path) == "/usr/bin/gzip"
    }
}

/// Whether a file `isOutput` accepts in `folder` holds bytes.
private func hasOutputBytes(in folder: URL, isOutput: (String) -> Bool) -> Bool {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return names.contains { name in
        guard isOutput(name) else { return false }
        let attributes = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
        return ((attributes?[.size] as? NSNumber)?.intValue ?? 0) > 1024
    }
}

final class KrakenCompactionDurabilityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "kraken-compaction-durability")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Fixtures

    /// About 24 MB of Kraken2 output whose last column is random digits, so gzip needs most of a second for it
    /// and the index builder reads classified rows only.
    private func makeLargeRaw(in folderName: String) throws -> URL {
        let folder = root.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let raw = folder.appendingPathComponent("classification.kraken")
        FileManager.default.createFile(atPath: raw.path, contents: nil)
        let handle = try FileHandle(forWritingTo: raw)
        defer { try? handle.close() }
        var digits = [UInt8](repeating: 0, count: 4_000)
        for line in 0..<6_000 {
            digits.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
            for index in digits.indices { digits[index] = 48 + digits[index] % 10 }
            var bytes = Array("C\tread-\(line)\t562\t4000\t".utf8)
            bytes.append(contentsOf: digits)
            bytes.append(10)
            try handle.write(contentsOf: Data(bytes))
        }
        return raw
    }

    private func makeFolder(_ name: String) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func entries(of folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    // MARK: - Killing gzip mid-write

    private struct MidWrite {
        /// Whether the final name existed while gzip was frozen mid-write.
        let finalNameExisted: Bool
        /// The names in the folder at that moment, hidden part files included.
        let entriesWhileFrozen: [String]
        /// Whether the copy under test reported success after gzip was killed.
        let succeeded: Bool
    }

    /// Starts `work`, waits until gzip has written bytes into `folder` (names `isOutput` accepts), freezes gzip,
    /// records what the folder holds, kills gzip and returns whether `work` still reported success.
    private func killGzipMidWrite(
        folder: URL,
        destination: URL,
        isOutput: @escaping @Sendable (String) -> Bool = { _ in true },
        work: @escaping @Sendable () async -> Bool
    ) async throws -> MidWrite {
        let task = Task.detached { await work() }
        let deadline = Date().addingTimeInterval(120)
        var gzip: Int32?
        while Date() < deadline {
            if hasOutputBytes(in: folder, isOutput: isOutput) {
                gzip = gzipChildren().first
                break
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        guard let gzip else {
            _ = await task.value
            throw XCTSkip("gzip finished or never wrote before the test could freeze it")
        }
        kill(gzip, SIGSTOP)
        let existed = FileManager.default.fileExists(atPath: destination.path)
        let names = try entries(of: folder)
        kill(gzip, SIGKILL)
        let succeeded = await task.value
        return MidWrite(finalNameExisted: existed, entriesWhileFrozen: names, succeeded: succeeded)
    }

    // MARK: - The copy in LungfishIO

    func testAGzipKilledMidWriteLeavesNothingUnderTheFinalNameOfTheIOCopy() async throws {
        let raw = try makeLargeRaw(in: "io copy input")
        let output = try makeFolder("io copy output")
        let destination = output.appendingPathComponent("classification.kraken.gz")

        let midWrite = try await killGzipMidWrite(folder: output, destination: destination) {
            do {
                try KrakenOutputCompactor.gzipCopy(source: raw, destination: destination)
                return true
            } catch {
                return false
            }
        }

        XCTAssertFalse(midWrite.finalNameExisted, "the final name stays empty while gzip writes: \(midWrite.entriesWhileFrozen)")
        XCTAssertFalse(midWrite.succeeded, "a killed gzip is a failed copy")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "a cut copy is never named")
        XCTAssertEqual(try entries(of: output), [], "no part file stays")
    }

    func testAFailedCopyKeepsTheOlderGzipCopyUnderTheName() async throws {
        let raw = try makeLargeRaw(in: "io keeps input")
        let output = try makeFolder("io keeps output")
        let destination = output.appendingPathComponent("classification.kraken.gz")
        let older = Data("an older gzip copy".utf8)
        try older.write(to: destination)

        let midWrite = try await killGzipMidWrite(folder: output, destination: destination) {
            do {
                try KrakenOutputCompactor.gzipCopy(source: raw, destination: destination)
                return true
            } catch {
                return false
            }
        }

        XCTAssertFalse(midWrite.succeeded)
        XCTAssertEqual(try Data(contentsOf: destination), older, "the older copy stays until a whole one replaces it")
        XCTAssertEqual(try entries(of: output), ["classification.kraken.gz"], "no part file stays")
    }

    // MARK: - The copy of the classify route

    func testAGzipKilledMidWriteLeavesNothingUnderTheFinalNameOfTheClassifyRoute() async throws {
        let raw = try makeLargeRaw(in: "classify route")
        let folder = raw.deletingLastPathComponent()
        let destination = raw.appendingPathExtension("gz")
        let recorder = ProvenanceRecorder(signingProvider: nil)
        let runID = await recorder.beginRun(name: "Kraken2 compaction durability")

        let midWrite = try await killGzipMidWrite(folder: folder, destination: destination, isOutput: isGzipOutput) {
            let compaction = await ClassificationPipeline().compactKrakenOutputIfPossible(
                rawURL: raw, provenanceRecorder: recorder, runID: runID, dependsOn: []
            )
            return compaction != nil
        }

        XCTAssertFalse(midWrite.finalNameExisted, "the final name stays empty while gzip writes: \(midWrite.entriesWhileFrozen)")
        XCTAssertFalse(midWrite.succeeded, "a killed gzip is no compaction")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "a cut copy is never named")
        XCTAssertTrue(FileManager.default.fileExists(atPath: raw.path), "the raw output stays when the compaction fails")
        XCTAssertEqual(try entries(of: folder).filter { $0.hasPrefix(".") }, [], "no part file stays")
    }

    // MARK: - What compact returns

    func testCompactNamesEveryFileItWroteTheGzipCopyAndTheIndex() throws {
        let folder = try makeFolder("compact result")
        let raw = folder.appendingPathComponent("classification.kraken")
        try Data("C\tread-1\t562\t4\t0:4\nU\tread-2\t0\t4\t0:4\n".utf8).write(to: raw)
        let explicit = try makeFolder("compact elsewhere").appendingPathComponent("per-read.kraken.gz")

        let beside = try KrakenOutputCompactor.compact(rawURL: raw, removeRawOnSuccess: false)
        let elsewhere = try KrakenOutputCompactor.compact(rawURL: raw, compressedURL: explicit, removeRawOnSuccess: false)

        XCTAssertEqual(beside.compressedURL, raw.appendingPathExtension("gz"))
        XCTAssertEqual(beside.indexURL, KrakenIndexDatabase.indexURL(for: beside.compressedURL))
        XCTAssertEqual(beside.writtenFiles, [beside.compressedURL, beside.indexURL])
        XCTAssertEqual(elsewhere.writtenFiles.map(\.lastPathComponent), ["per-read.kraken.gz", "per-read.kraken.gz.idx.sqlite"])
        for written in beside.writtenFiles + elsewhere.writtenFiles {
            XCTAssertTrue(FileManager.default.fileExists(atPath: written.path), written.lastPathComponent)
        }
    }

    // MARK: - compact, which build-db and the importers call

    func testAGzipKilledMidWriteLeavesNothingUnderTheFinalNameOfCompact() async throws {
        let raw = try makeLargeRaw(in: "compact route")
        let folder = raw.deletingLastPathComponent()
        let destination = raw.appendingPathExtension("gz")

        let midWrite = try await killGzipMidWrite(folder: folder, destination: destination, isOutput: isGzipOutput) {
            do {
                _ = try KrakenOutputCompactor.compact(rawURL: raw, includeUnclassifiedInIndex: false, removeRawOnSuccess: false)
                return true
            } catch {
                return false
            }
        }

        XCTAssertFalse(midWrite.finalNameExisted, "the final name stays empty while gzip writes: \(midWrite.entriesWhileFrozen)")
        XCTAssertFalse(midWrite.succeeded, "a killed gzip fails the compaction")
        XCTAssertEqual(try entries(of: folder), ["classification.kraken"], "neither copy, no index and no part file stays")
    }
}
