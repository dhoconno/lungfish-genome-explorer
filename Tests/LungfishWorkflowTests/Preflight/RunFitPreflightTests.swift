// RunFitPreflightTests.swift - A run that cannot fit this Mac is refused before it starts, in words that name the Linux route
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
import LungfishTestSupport

/// Lane RS-PREFLIGHT of Phase 5.1. A run whose peak memory is over what this Mac has, or whose free disk is over what the
/// run's volume holds, is refused before it starts, in words that say what the run needs, what this Mac has and where the
/// run can go instead. The caller passes every figure and the Linux route, so the tests set the host and the volume with
/// stand-ins. None of them needs a managed tool, a network or a figure that belongs to one kind of run.
final class RunFitPreflightTests: XCTestCase {

    private static let gib: Int64 = 1_073_741_824
    private static let mac16 = RunFitHostFacts(physicalMemoryBytes: 16 * gib)
    private static let folder = URL(fileURLWithPath: "/Volumes/Work/Project.lungfish", isDirectory: true)
    private static let route = "Write the plan with lungfish-cli quant --plan, copy the plan folder there and run it."
    private static let memoryBasis = "the decoy-aware Salmon index of one human sample, measured on an idle Mac"
    private static let diskBasis = "five times the size of the reads, as the CHTC runs measured"

    private func need(memory: Int64, disk: Int64) -> RunFitNeed {
        RunFitNeed(
            peakMemoryBytes: memory, memoryBasis: Self.memoryBasis,
            freeDiskBytes: disk, diskBasis: Self.diskBasis, diskFolder: Self.folder
        )
    }

    private func free(_ bytes: Int64?) -> RunFitPreflight.FreeSpaceReader {
        return { _ in bytes }
    }

    /// Row 1: a need over the host's memory is refused, and the words hold both sizes and the Linux route.
    func testMemoryNeedOverTheHostIsRefusedWithBothSizesAndTheLinuxRoute() throws {
        let run = need(memory: 24 * Self.gib, disk: 3_000_000_000)
        let roomy = free(500_000_000_000)
        XCTAssertEqual(
            RunFitPreflight.verdict(need: run, host: Self.mac16, freeSpace: roomy),
            .tooLittleMemory(needBytes: 24 * Self.gib, haveBytes: 16 * Self.gib)
        )
        XCTAssertThrowsError(
            try RunFitPreflight.require(need: run, host: Self.mac16, linuxRoute: Self.route, freeSpace: roomy)
        ) { error in
            guard let refusal = error as? RunFitError,
                  case .insufficientMemory(let needBytes, let haveBytes, let basis, let route) = refusal else {
                return XCTFail("expected the memory refusal, got \(error)")
            }
            XCTAssertEqual(needBytes, 24 * Self.gib)
            XCTAssertEqual(haveBytes, 16 * Self.gib)
            XCTAssertEqual(basis, Self.memoryBasis)
            XCTAssertEqual(route, Self.route)
            let words = refusal.errorDescription ?? ""
            XCTAssertEqual(error.localizedDescription, words, "the app and the command line show these words")
            let needText = ByteCountFormatter.string(fromByteCount: 24 * Self.gib, countStyle: .memory)
            let haveText = ByteCountFormatter.string(fromByteCount: 16 * Self.gib, countStyle: .memory)
            XCTAssertTrue(words.contains("needs about \(needText) of memory"), words)
            XCTAssertTrue(words.contains("this Mac has \(haveText)"), words)
            XCTAssertTrue(words.contains(Self.memoryBasis), "the figure says where it came from: \(words)")
            XCTAssertTrue(words.contains("Run it on a Linux machine with at least 24 GB of memory"), words)
            XCTAssertTrue(words.contains(Self.route), words)
        }
    }

    /// The folders a reader was asked about.
    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [URL] = []

        func add(_ folder: URL) {
            lock.lock()
            defer { lock.unlock() }
            items.append(folder)
        }

        var all: [URL] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    /// Row 2: free disk under the need is refused with both sizes, the folder and the Linux route.
    func testFreeDiskUnderTheNeedIsRefusedWithBothSizesTheFolderAndTheLinuxRoute() throws {
        let run = need(memory: 8 * Self.gib, disk: 3_000_000_000)
        let asked = Asked()
        let reader: RunFitPreflight.FreeSpaceReader = { asking in
            asked.add(asking)
            return 1_200_000_000
        }
        XCTAssertEqual(
            RunFitPreflight.verdict(need: run, host: Self.mac16, freeSpace: reader),
            .tooLittleDisk(needBytes: 3_000_000_000, freeBytes: 1_200_000_000)
        )
        XCTAssertThrowsError(
            try RunFitPreflight.require(need: run, host: Self.mac16, linuxRoute: Self.route, freeSpace: reader)
        ) { error in
            guard let refusal = error as? RunFitError,
                  case .insufficientDisk(let needBytes, let freeBytes, let diskFolder, let basis, let route) = refusal else {
                return XCTFail("expected the disk refusal, got \(error)")
            }
            XCTAssertEqual(needBytes, 3_000_000_000)
            XCTAssertEqual(freeBytes, 1_200_000_000)
            XCTAssertEqual(diskFolder, Self.folder)
            XCTAssertEqual(basis, Self.diskBasis)
            XCTAssertEqual(route, Self.route)
            let words = refusal.errorDescription ?? ""
            XCTAssertEqual(error.localizedDescription, words)
            let needText = ByteCountFormatter.string(fromByteCount: 3_000_000_000, countStyle: .file)
            let freeText = ByteCountFormatter.string(fromByteCount: 1_200_000_000, countStyle: .file)
            XCTAssertTrue(words.contains("needs about \(needText) of free disk"), words)
            XCTAssertTrue(words.contains("has \(freeText) free"), words)
            XCTAssertTrue(words.contains(Self.folder.path), "the words name the folder: \(words)")
            XCTAssertTrue(words.contains(Self.diskBasis), "the figure says where it came from: \(words)")
            XCTAssertTrue(words.contains("Run it on a Linux machine with at least 3 GB of free disk"), words)
            XCTAssertTrue(words.contains(Self.route), words)
        }
        XCTAssertEqual(asked.all, [Self.folder, Self.folder], "each check asked about the folder the need names, once")
    }

    /// A need equal to what the host has passes, for memory and for disk, and one byte more is refused.
    func testANeedEqualToWhatTheHostHasPasses() throws {
        let exact = need(memory: 16 * Self.gib, disk: 3_000_000_000)
        XCTAssertEqual(RunFitPreflight.verdict(need: exact, host: Self.mac16, freeSpace: free(3_000_000_000)), .enough)
        XCTAssertNoThrow(
            try RunFitPreflight.require(need: exact, host: Self.mac16, linuxRoute: Self.route, freeSpace: free(3_000_000_000))
        )
        XCTAssertEqual(
            RunFitPreflight.verdict(need: exact, host: Self.mac16, freeSpace: free(2_999_999_999)),
            .tooLittleDisk(needBytes: 3_000_000_000, freeBytes: 2_999_999_999)
        )
        let over = need(memory: 16 * Self.gib + 1, disk: 0)
        XCTAssertEqual(
            RunFitPreflight.verdict(need: over, host: Self.mac16, freeSpace: free(nil)),
            .tooLittleMemory(needBytes: 16 * Self.gib + 1, haveBytes: 16 * Self.gib)
        )
    }

    /// Row 2: a product past Int64.max never wraps into a small need. A wrapped 2^63 reads as a negative number, which
    /// counts as zero and would pass.
    func testAProductPastInt64MaxNeverWraps() throws {
        XCTAssertEqual(RunFitNeed.bytes(5, times: 3), 15)
        XCTAssertEqual(RunFitNeed.bytes(5, times: 3, plus: 7), 22)
        XCTAssertEqual(RunFitNeed.bytes(Int64.max / 2 + 1, times: 2), Int64.max)
        XCTAssertEqual(RunFitNeed.bytes(Int64.max, times: 5), Int64.max)
        XCTAssertEqual(RunFitNeed.bytes(Int64.max, times: 1, plus: 1), Int64.max, "a sum past Int64.max saturates too")
        XCTAssertEqual(RunFitNeed.bytes(-5, times: 3, plus: -2), 0, "a negative term counts as zero")
        XCTAssertEqual(RunFitNeed.bytes(5, times: -3, plus: 4), 4)

        let roomy = free(500_000_000_000)
        let hugeDisk = need(memory: 0, disk: RunFitNeed.bytes(Int64.max / 2 + 1, times: 2))
        XCTAssertEqual(
            RunFitPreflight.verdict(need: hugeDisk, host: Self.mac16, freeSpace: roomy),
            .tooLittleDisk(needBytes: Int64.max, freeBytes: 500_000_000_000)
        )
        XCTAssertThrowsError(
            try RunFitPreflight.require(need: hugeDisk, host: Self.mac16, linuxRoute: Self.route, freeSpace: roomy)
        ) { error in
            let words = (error as? RunFitError)?.errorDescription ?? ""
            XCTAssertTrue(words.contains("Run it on a Linux machine with at least"), words)
        }
        let hugeMemory = need(memory: RunFitNeed.bytes(Int64.max, times: 5), disk: 0)
        XCTAssertEqual(
            RunFitPreflight.verdict(need: hugeMemory, host: Self.mac16, freeSpace: roomy),
            .tooLittleMemory(needBytes: Int64.max, haveBytes: 16 * Self.gib)
        )
    }

    /// A volume that does not answer lets the run go ahead with one log line that names the folder.
    func testAVolumeThatDoesNotAnswerGoesAheadWithOneLogLine() throws {
        let run = need(memory: 8 * Self.gib, disk: 3_000_000_000)
        let verdict = RunFitPreflight.verdict(need: run, host: Self.mac16, freeSpace: free(nil))
        guard case .unreadable(let logLine) = verdict else {
            return XCTFail("expected the unreadable verdict, got \(verdict)")
        }
        XCTAssertTrue(logLine.contains(Self.folder.path), logLine)
        XCTAssertFalse(logLine.contains("\n"), "one log line")
        XCTAssertNoThrow(
            try RunFitPreflight.require(need: run, host: Self.mac16, linuxRoute: Self.route, freeSpace: free(nil))
        )
    }

    /// Memory is checked first, since no one can free it, and a memory refusal reads no volume.
    func testAMemoryRefusalComesFirstAndReadsNoVolume() throws {
        let asked = Asked()
        let run = need(memory: 24 * Self.gib, disk: 3_000_000_000)
        let verdict = RunFitPreflight.verdict(need: run, host: Self.mac16, freeSpace: { asking in
            asked.add(asking)
            return 1
        })
        XCTAssertEqual(verdict, .tooLittleMemory(needBytes: 24 * Self.gib, haveBytes: 16 * Self.gib))
        XCTAssertTrue(asked.all.isEmpty, "the volume was not read")
    }

    /// A need of no disk, or a negative one, passes without reading the volume.
    func testANeedOfNoDiskReadsNoVolume() throws {
        let asked = Asked()
        for disk in [Int64(0), -5] {
            let run = need(memory: 8 * Self.gib, disk: disk)
            let verdict = RunFitPreflight.verdict(need: run, host: Self.mac16, freeSpace: { asking in
                asked.add(asking)
                return nil
            })
            XCTAssertEqual(verdict, .enough, "\(disk) bytes of disk ask nothing of the volume")
        }
        let negativeMemory = need(memory: -1, disk: 0)
        XCTAssertEqual(RunFitPreflight.verdict(need: negativeMemory, host: Self.mac16, freeSpace: free(nil)), .enough)
        XCTAssertTrue(asked.all.isEmpty)
    }

    /// The Linux machine's figure is whole gigabytes, rounded up. Memory counts 1,073,741,824 bytes a GB, as a Mac's About
    /// window does, and disk counts 1,000,000,000 bytes, as the Finder does. A blank basis adds no brackets.
    func testTheLinuxMachineFigureRoundsUpToWholeGigabytes() throws {
        let memory = RunFitError.insufficientMemory(
            needBytes: 24 * Self.gib + 1, haveBytes: 16 * Self.gib, basis: "", linuxRoute: Self.route
        ).errorDescription ?? ""
        XCTAssertTrue(memory.contains("Run it on a Linux machine with at least 25 GB of memory."), memory)
        XCTAssertFalse(memory.contains("("), memory)
        // C4's node run: 422,847,301 bytes of reads need 2,114,236,505 bytes free, which is 3 GB on a Linux machine.
        let disk = RunFitError.insufficientDisk(
            needBytes: 2_114_236_505, freeBytes: 1, folder: Self.folder, basis: "  ", linuxRoute: Self.route
        ).errorDescription ?? ""
        XCTAssertTrue(disk.contains("Run it on a Linux machine with at least 3 GB of free disk."), disk)
        XCTAssertFalse(disk.contains("("), disk)
    }

    /// The route is the caller's, ends the words, and ends them with one full stop.
    func testTheWordsEndOnTheRouteTheCallerPasses() throws {
        let run = need(memory: 24 * Self.gib, disk: 0)
        for route in ["Plan it with lungfish-cli quant --plan and run the plan there", "Use the Linux plan sheet."] {
            XCTAssertThrowsError(
                try RunFitPreflight.require(need: run, host: Self.mac16, linuxRoute: route, freeSpace: free(nil))
            ) { error in
                let words = (error as? RunFitError)?.errorDescription ?? ""
                let sentence = route.hasSuffix(".") ? route : route + "."
                XCTAssertTrue(words.hasSuffix(sentence), words)
                XCTAssertFalse(words.contains(".."), words)
            }
        }
    }

    /// A figure that reads the same as the need reads "just under", so no sentence says "needs 16 GB and has 16 GB".
    func testAFigureThatReadsLikeTheNeedReadsJustUnder() throws {
        let memory = need(memory: 16 * Self.gib + 1, disk: 0)
        XCTAssertThrowsError(
            try RunFitPreflight.require(need: memory, host: Self.mac16, linuxRoute: Self.route, freeSpace: free(nil))
        ) { error in
            let words = (error as? RunFitError)?.errorDescription ?? ""
            let text = ByteCountFormatter.string(fromByteCount: 16 * Self.gib, countStyle: .memory)
            XCTAssertTrue(words.contains("this Mac has just under \(text)"), words)
        }
        let disk = need(memory: 0, disk: 3_000_000_000)
        XCTAssertThrowsError(
            try RunFitPreflight.require(need: disk, host: Self.mac16, linuxRoute: Self.route, freeSpace: free(2_999_999_999))
        ) { error in
            let words = (error as? RunFitError)?.errorDescription ?? ""
            let text = ByteCountFormatter.string(fromByteCount: 3_000_000_000, countStyle: .file)
            XCTAssertTrue(words.contains("has just under \(text) free"), words)
        }
    }

    /// The Mac's reader finds the volume of a folder that does not exist yet, as the folder of a run that has not started,
    /// and creates nothing.
    func testTheMacReaderFindsTheVolumeOfAFolderThatDoesNotExistYet() throws {
        let root = try TestTempDirectory.make(prefix: "run-fit-preflight")
        defer { TestTempDirectory.cleanup(root) }
        let notYet = root.appendingPathComponent("cache/index/human", isDirectory: true)
        let answer = RunFitPreflight.volumeFreeSpace(notYet)
        XCTAssertNotNil(answer, "the volume of the nearest folder that exists answers")
        XCTAssertGreaterThan(answer ?? 0, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: notYet.path), "the check creates nothing")
    }

    /// The Mac's reader asks the volume on every call. A URL answers from the values it kept of an earlier read, so a caller
    /// that holds one folder URL across two checks must not get the first check's figure.
    func testTheMacReaderIgnoresValuesAURLKeptFromAnEarlierRead() throws {
        let root = try TestTempDirectory.make(prefix: "run-fit-preflight-fresh")
        defer { TestTempDirectory.cleanup(root) }
        var held = root
        held.setTemporaryResourceValue(Int64(1), forKey: .volumeAvailableCapacityForImportantUsageKey)
        XCTAssertNotEqual(RunFitPreflight.volumeFreeSpace(held), 1, "the reader asked the volume and not the URL")
    }
}
