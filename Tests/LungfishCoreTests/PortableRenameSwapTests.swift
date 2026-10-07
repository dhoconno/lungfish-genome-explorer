// PortableRenameSwapTests.swift - Swaps and exclusive renames on volumes without RENAME_SWAP or RENAME_EXCL
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import XCTest
@testable import LungfishCore

/// ExFAT, FAT and SMB volumes answer `ENOTSUP` to `RENAME_SWAP` and
/// `RENAME_EXCL`. These tests inject that answer so the fallbacks run on APFS.
final class PortableRenameSwapTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PortableRenameSwapTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Swap

    func testSwapUsesTheKernelWhenTheVolumeSupportsIt() throws {
        try XCTSkipIf(PortableRename.Operations.processSimulatesUnsupportedFlags, "asserts the APFS kernel path")
        let (staging, final) = try makeDirectoryPair()

        let mechanism = try PortableRename.swap(staging, final)

        XCTAssertEqual(mechanism, .nativeSwap)
        try assertSwapped(staging: staging, final: final)
    }

    func testSwapOfDirectoriesFallsBackWhenTheVolumeRejectsRenameSwap() throws {
        let (staging, final) = try makeDirectoryPair()

        let mechanism = try PortableRename.swap(staging, final, operations: Self.unsupportedFlags())

        XCTAssertEqual(mechanism, .rotationFallback)
        try assertSwapped(staging: staging, final: final)
        XCTAssertEqual(try visibleAndHiddenNames(), [".staging", "final"], "no tombstone is left behind")
    }

    func testSwapOfRegularFilesFallsBackWhenTheVolumeRejectsRenameSwap() throws {
        let staging = root.appendingPathComponent(".catalog.staging")
        let final = root.appendingPathComponent("catalog.json")
        try Data("new".utf8).write(to: staging)
        try Data("old".utf8).write(to: final)

        let mechanism = try PortableRename.swap(staging, final, operations: Self.unsupportedFlags())

        XCTAssertEqual(mechanism, .rotationFallback)
        XCTAssertEqual(try String(contentsOf: final, encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: staging, encoding: .utf8), "old")
    }

    func testTheRawEntryPointFallsBackForRenameSwapToo() throws {
        let (staging, final) = try makeDirectoryPair()

        let status = staging.path.withCString { first in
            final.path.withCString { second in
                PortableRename.renameatxNPReporting(
                    AT_FDCWD, first, AT_FDCWD, second, UInt32(RENAME_SWAP),
                    operations: Self.unsupportedFlags()
                )
            }
        }

        XCTAssertEqual(status, .init(status: 0, mechanism: .rotationFallback))
        try assertSwapped(staging: staging, final: final)
    }

    func testAFailedFallbackSwapPutsBothEntriesBack() throws {
        let (staging, final) = try makeDirectoryPair()
        var operations = Self.unsupportedFlags()
        let renames = LockedCounter()
        // The second ordinary rename moves the staging entry onto the final
        // name. Failing it leaves the old entry parked under the tombstone.
        operations.ordinaryRename = { fromParent, from, toParent, to in
            if renames.increment() == 2 {
                errno = EIO
                return -1
            }
            return Darwin.renameat(fromParent, from, toParent, to)
        }

        XCTAssertThrowsError(try PortableRename.swap(staging, final, operations: operations)) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EIO)
        }

        XCTAssertEqual(try marker(in: final), "old")
        XCTAssertEqual(try marker(in: staging), "new")
        XCTAssertEqual(try visibleAndHiddenNames(), [".staging", "final"])
    }

    // MARK: - Self-heal

    func testRecoveryRestoresAnEntryLeftUnderASwapTombstone() throws {
        let tombstone = root.appendingPathComponent(".final.lungfish-swap-\(UUID().uuidString)", isDirectory: true)
        try makeDirectory(tombstone, marker: "old")

        let restored = PortableRename.recoverInterruptedSwaps(underProject: root)

        let final = root.appendingPathComponent("final", isDirectory: true)
        XCTAssertEqual(restored.map(\.lastPathComponent), ["final"])
        XCTAssertEqual(try marker(in: final), "old")
        XCTAssertEqual(try visibleAndHiddenNames(), ["final"])
    }

    func testRecoveryLeavesATombstoneAloneWhenTheRealEntryExists() throws {
        let final = root.appendingPathComponent("final", isDirectory: true)
        try makeDirectory(final, marker: "new")
        let tombstone = root.appendingPathComponent(".final.lungfish-swap-\(UUID().uuidString)", isDirectory: true)
        try makeDirectory(tombstone, marker: "old")

        XCTAssertEqual(PortableRename.recoverInterruptedSwaps(underProject: root), [])

        XCTAssertEqual(try marker(in: final), "new")
        XCTAssertEqual(try marker(in: tombstone), "old", "a retired generation is never deleted automatically")
    }

    func testRecoveryWalksAProjectTree() throws {
        let bundle = root.appendingPathComponent("Analyses/run.lungfishref/artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let tombstone = bundle.appendingPathComponent(".alignments.lungfish-swap-\(UUID().uuidString)", isDirectory: true)
        try makeDirectory(tombstone, marker: "old")

        let restored = PortableRename.recoverInterruptedSwaps(underProject: root)

        XCTAssertEqual(restored.map(\.lastPathComponent), ["alignments"])
        XCTAssertEqual(try marker(in: bundle.appendingPathComponent("alignments")), "old")
    }

    func testSwapRecoversAnInterruptedSwapOfTheSameEntryFirst() throws {
        let staging = root.appendingPathComponent(".staging", isDirectory: true)
        try makeDirectory(staging, marker: "new")
        let tombstone = root.appendingPathComponent(".final.lungfish-swap-\(UUID().uuidString)", isDirectory: true)
        try makeDirectory(tombstone, marker: "old")
        let final = root.appendingPathComponent("final", isDirectory: true)

        _ = try PortableRename.swap(staging, final, operations: Self.unsupportedFlags())

        try assertSwapped(staging: staging, final: final)
    }

    // MARK: - Exclusive

    func testExclusiveFallsBackAndRefusesToReplace() throws {
        let source = root.appendingPathComponent(".source", isDirectory: true)
        try makeDirectory(source, marker: "new")
        let destination = root.appendingPathComponent("destination", isDirectory: true)

        XCTAssertEqual(
            try PortableRename.exclusive(source, to: destination, operations: Self.unsupportedFlags()),
            .reservationFallback
        )
        XCTAssertEqual(try marker(in: destination), "new")

        try makeDirectory(source, marker: "second")
        XCTAssertThrowsError(
            try PortableRename.exclusive(source, to: destination, operations: Self.unsupportedFlags())
        ) { error in
            let code = (error as? POSIXError)?.code
            XCTAssertTrue(code == .EEXIST || code == .ENOTEMPTY, "unexpected \(String(describing: code))")
        }
        XCTAssertEqual(try marker(in: destination), "new")
    }

    func testExclusiveFallbackMovesLinksAndFIFOsAndRefusesToReplace() throws {
        let link = root.appendingPathComponent(".link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "target-a")
        let destination = root.appendingPathComponent("published-link")

        XCTAssertEqual(
            try PortableRename.exclusive(link, to: destination, operations: Self.unsupportedFlags()),
            .reservationFallback
        )
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), "target-a")

        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "target-b")
        XCTAssertThrowsError(try PortableRename.exclusive(link, to: destination, operations: Self.unsupportedFlags()))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), "target-a")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "target-b")

        let fifo = root.appendingPathComponent(".fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let movedFIFO = root.appendingPathComponent("moved-fifo")
        XCTAssertEqual(
            try PortableRename.exclusive(fifo, to: movedFIFO, operations: Self.unsupportedFlags()),
            .reservationFallback
        )
        var information = stat()
        XCTAssertEqual(lstat(movedFIFO.path, &information), 0)
        XCTAssertEqual(information.st_mode & S_IFMT, S_IFIFO)
    }

    // MARK: - Simulation switch

    func testTheSimulationSwitchForcesEveryFlaggedRenameOntoItsFallback() throws {
        let operations = PortableRename.Operations.forEnvironment(
            ["LUNGFISH_SIMULATE_UNSUPPORTED_RENAME_FLAGS": "1"]
        )
        let (staging, final) = try makeDirectoryPair()

        XCTAssertEqual(try PortableRename.swap(staging, final, operations: operations), .rotationFallback)
        XCTAssertEqual(
            try PortableRename.swap(staging, final, operations: .forEnvironment([:])),
            .nativeSwap
        )
    }

    // MARK: - Real ExFAT

    /// Run with `scripts/testing/exfat-tests.sh`.
    func testSwapAndExclusiveRenameOnExFAT() throws {
        guard let volume = ProcessInfo.processInfo.environment["LUNGFISH_EXFAT_TEST_ROOT"], !volume.isEmpty else {
            throw XCTSkip("Set LUNGFISH_EXFAT_TEST_ROOT to an ExFAT volume root to run this test.")
        }
        let directory = URL(fileURLWithPath: volume, isDirectory: true)
            .appendingPathComponent("portable-rename-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let staging = directory.appendingPathComponent(".staging", isDirectory: true)
        let final = directory.appendingPathComponent("final", isDirectory: true)
        try makeDirectory(staging, marker: "new")

        XCTAssertEqual(try PortableRename.exclusive(staging, to: final), .reservationFallback)
        try makeDirectory(staging, marker: "newer")
        XCTAssertEqual(try PortableRename.swap(staging, final), .rotationFallback)

        XCTAssertEqual(try marker(in: final), "newer")
        XCTAssertEqual(try marker(in: staging), "new")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix("._") }
        XCTAssertEqual(names.sorted(), [".staging", "final"])
    }

    // MARK: - Helpers

    private static func unsupportedFlags() -> PortableRename.Operations {
        PortableRename.Operations(nativeRename: { _, _, _, _, _ in
            errno = ENOTSUP
            return -1
        })
    }

    private func makeDirectoryPair() throws -> (staging: URL, final: URL) {
        let staging = root.appendingPathComponent(".staging", isDirectory: true)
        let final = root.appendingPathComponent("final", isDirectory: true)
        try makeDirectory(staging, marker: "new")
        try makeDirectory(final, marker: "old")
        return (staging, final)
    }

    private func makeDirectory(_ url: URL, marker: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: url.appendingPathComponent("marker"))
    }

    private func marker(in directory: URL) throws -> String {
        try String(contentsOf: directory.appendingPathComponent("marker"), encoding: .utf8)
    }

    private func assertSwapped(staging: URL, final: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try marker(in: final), "new", file: file, line: line)
        XCTAssertEqual(try marker(in: staging), "old", file: file, line: line)
    }

    private func visibleAndHiddenNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
