// AppMemoryGuardTests.swift - At its memory share the app cancels its work and says why
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
import LungfishKit

/// The guard reads the footprint through an injected reader and acts through injected actions, so these tests set a
/// footprint over the share, allocate nothing and touch no shared `OperationCenter`, except the one test of the
/// live reader of running operations, which begins two rows of its own and completes them.
@MainActor
final class AppMemoryGuardTests: XCTestCase {
    private let sixteenGB: UInt64 = 16 << 30

    @MainActor
    private final class Recorder {
        var operations: [AppMemoryGuard.RunningOperation] = []
        var loadsInFlight = 0
        var cancelled: [(UUID, String)] = []
        var loadCancels = 0
        var presented: [String] = []

        var actions: AppMemoryGuard.Actions {
            AppMemoryGuard.Actions(
                runningOperations: { self.operations },
                cancelOperation: { id, words in self.cancelled.append((id, words)) },
                cancelLoads: {
                    self.loadCancels += 1
                    defer { self.loadsInFlight = 0 }
                    return self.loadsInFlight
                },
                present: { self.presented.append($0) }
            )
        }
    }

    private final class Footprint: @unchecked Sendable {
        var value: UInt64?
        init(_ value: UInt64?) { self.value = value }
    }

    private func makeGuard(_ footprint: Footprint, _ recorder: Recorder) -> AppMemoryGuard {
        AppMemoryGuard(
            share: ProcessMemoryShare(physicalMemoryBytes: sixteenGB),
            readFootprint: { footprint.value },
            actions: recorder.actions
        )
    }

    func testAtTheShareTheAppCancelsOperationsAndTheLoadAndNamesThem() {
        let recorder = Recorder()
        let importID = UUID()
        let classifyID = UUID()
        recorder.operations = [
            .init(id: importID, title: "Import FASTQ"),
            .init(id: classifyID, title: "EsViritu Detection"),
        ]
        recorder.loadsInFlight = 1
        let memoryGuard = makeGuard(Footprint(9 << 30), recorder)
        memoryGuard.check()

        let words = "LGE stopped Import FASTQ, EsViritu Detection and the load in the viewer because LGE was using "
            + "9 GB of memory, half or more of the 16 GB on this Mac. It stops there so the Mac does not run out of "
            + "memory. Close windows you do not need, then run it again on fewer or smaller files, or on a Mac with "
            + "more memory."
        XCTAssertEqual(recorder.cancelled.map(\.0), [importID, classifyID])
        XCTAssertEqual(recorder.cancelled.map(\.1), [words, words])
        XCTAssertEqual(recorder.loadCancels, 1)
        XCTAssertEqual(recorder.presented, [words])
    }

    func testOneOperationAndNoLoad() {
        let recorder = Recorder()
        recorder.operations = [.init(id: UUID(), title: "Import FASTQ")]
        makeGuard(Footprint(8 << 30), recorder).check()
        XCTAssertEqual(recorder.presented.count, 1)
        XCTAssertTrue(
            recorder.presented[0].hasPrefix("LGE stopped Import FASTQ because LGE was using 8 GB of memory"),
            recorder.presented[0]
        )
    }

    func testNothingToStopStillSaysWhy() {
        let recorder = Recorder()
        makeGuard(Footprint(10 << 30), recorder).check()
        XCTAssertEqual(
            recorder.presented,
            ["LGE was using 10 GB of memory, half or more of the 16 GB on this Mac, and no operation or load was "
                + "running for it to stop. Close windows you do not need, or quit and reopen LGE, so the Mac does "
                + "not run out of memory."]
        )
    }

    /// It speaks once while the footprint stays high and again only after it fell below 90% of the share.
    func testItFiresOnceAndArmsAgainBelowNinetyPercent() {
        let recorder = Recorder()
        let footprint = Footprint(9 << 30)
        let memoryGuard = makeGuard(footprint, recorder)
        memoryGuard.check()
        memoryGuard.check()
        XCTAssertEqual(recorder.presented.count, 1)
        footprint.value = (8 << 30) * 95 / 100
        memoryGuard.check()
        footprint.value = 9 << 30
        memoryGuard.check()
        XCTAssertEqual(recorder.presented.count, 1)
        footprint.value = (8 << 30) * 85 / 100
        memoryGuard.check()
        footprint.value = 9 << 30
        memoryGuard.check()
        XCTAssertEqual(recorder.presented.count, 2)
    }

    func testUnderTheShareNothingHappens() {
        let recorder = Recorder()
        recorder.operations = [.init(id: UUID(), title: "Import FASTQ")]
        makeGuard(Footprint((8 << 30) - 1), recorder).check()
        makeGuard(Footprint(nil), recorder).check()
        XCTAssertTrue(recorder.cancelled.isEmpty)
        XCTAssertEqual(recorder.loadCancels, 0)
        XCTAssertTrue(recorder.presented.isEmpty)
    }

    /// `OperationCenter.cancel(id:)` returns at once for a row with no cancel callback, so the live reader leaves such
    /// a row out and the words never say LGE stopped something that keeps running (MEM-WORDS review SF1).
    func testLiveReaderNamesOnlyRowsThatHaveACancelCallback() {
        let center = OperationCenter.shared
        let stoppable = center.begin(
            title: "MEMTEST stoppable", detail: "Running", operationType: .download, cliCommand: nil, onCancel: {}
        ).rowID
        let fixed = center.begin(
            title: "MEMTEST fixed", detail: "Running", operationType: .download, cliCommand: nil
        ).rowID
        defer {
            center.complete(id: stoppable, detail: "Done")
            center.complete(id: fixed, detail: "Done")
        }
        let titles = AppMemoryGuard.Actions.live.runningOperations().map(\.title)
        XCTAssertTrue(titles.contains("MEMTEST stoppable"), "\(titles)")
        XCTAssertFalse(titles.contains("MEMTEST fixed"), "\(titles)")
    }
}
