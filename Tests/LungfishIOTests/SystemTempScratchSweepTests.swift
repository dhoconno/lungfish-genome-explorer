// SystemTempScratchSweepTests.swift - The sweep claims only LGE scratch whose creator is gone
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane S32 M2 item 2 (2.10 P1, SC6). One test for each refusal: a foreign owner, a
// symbolic link, a live creator, no marker, another prefix and a folder a record names. Every sweep
// runs on a folder under a TestTempDirectory root, never the real system temp folder.

import Darwin
import Foundation
import LungfishCore
import LungfishTestSupport
@testable import LungfishIO
import XCTest

final class SystemTempScratchSweepTests: XCTestCase {
    private var root: URL!
    /// Stands in for the system temp folder.
    private var systemTemp: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "system-temp-scratch-sweep").resolvingSymlinksInPath()
        systemTemp = root.appendingPathComponent("T", isDirectory: true)
        try FileManager.default.createDirectory(at: systemTemp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testScratchWhoseCreatorIsGoneIsRemoved() throws {
        let gone = try makeScratch("taxtriage-", creator: Self.goneCreator())
        let otherBoot = try makeScratch("nfcore-work-", creator: Self.creatorOnAnotherBoot())

        let outcome = SystemTempScratchSweep.sweep(root: systemTemp)

        XCTAssertEqual(Set(outcome.removed.map(\.lastPathComponent)), [gone.lastPathComponent, otherBoot.lastPathComponent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path), "a reused PID with another start time is gone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: otherBoot.path), "a creator from another boot is gone")
        XCTAssertTrue(outcome.refused.isEmpty, "\(outcome.refused)")
    }

    /// S32 review fix 4. The common production path, a creator whose PID no longer exists, which the
    /// default inspector answers with nil.
    func testScratchWhoseCreatorHasNoProcessIsRemoved() throws {
        let scratch = try makeScratch("variants-", creator: Self.goneCreator())

        let outcome = SystemTempScratchSweep.sweep(root: systemTemp, processInspector: { _ in nil })

        XCTAssertEqual(outcome.removed.map(\.lastPathComponent), [scratch.lastPathComponent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))
    }

    /// S32 review fix 4. A regular file with an LGE name and a UUID is no scratch folder.
    func testAFileWithAScratchNameStays() throws {
        let file = systemTemp.appendingPathComponent("taxtriage-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)

        let outcome = SystemTempScratchSweep.sweep(root: systemTemp)

        assertStays(file, outcome, .notADirectory)
    }

    /// S32 review fix 5. The marker goes last, so a removal that fails part way leaves a folder the next
    /// launch still claims. The pin can also pass in directory order, so it guards the order and is no
    /// reliable red.
    func testARemovalThatFailsLeavesTheMarkerForTheNextLaunch() throws {
        let scratch = try makeScratch("nfcore-work-", creator: Self.goneCreator())
        let locked = scratch.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: locked.appendingPathComponent("task.out"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }

        let first = SystemTempScratchSweep.sweep(root: systemTemp, processInspector: { _ in nil })

        XCTAssertEqual(first.refused[scratch.lastPathComponent], .removalFailed)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: scratch.appendingPathComponent(OwnedWorkDirectoryMarker.fileName).path),
            "the marker stays until the rest is gone"
        )

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        let second = SystemTempScratchSweep.sweep(root: systemTemp, processInspector: { _ in nil })

        XCTAssertEqual(second.removed.map(\.lastPathComponent), [scratch.lastPathComponent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))
    }

    func testAFolderSomeoneElseOwnsStays() throws {
        let scratch = try makeScratch("taxtriage-", creator: Self.goneCreator())

        let outcome = SystemTempScratchSweep.sweep(root: systemTemp, userID: getuid() + 1)

        assertStays(scratch, outcome, .foreignOwner)
    }

    func testASymbolicLinkStaysAndSoDoesItsTarget() throws {
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let target = try makeScratch("taxtriage-", creator: Self.goneCreator(), in: elsewhere)
        let link = systemTemp.appendingPathComponent("taxtriage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let outcome = SystemTempScratchSweep.sweep(root: systemTemp)

        assertStays(link, outcome, .symbolicLink)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent(OwnedWorkDirectoryMarker.fileName).path))
    }

    /// S32 review fix 5. Bracken's scratch holds a link to the user's Kraken2 database when the database path has
    /// whitespace. The sweep removes each entry with `removeItem`, which removes a link and never follows it.
    func testASymbolicLinkInsideARemovedFolderLosesOnlyTheLink() throws {
        let outside = try TestTempDirectory.make(prefix: "sweep-link-target")
        defer { TestTempDirectory.cleanup(outside) }
        let database = outside.appendingPathComponent("kraken db", isDirectory: true)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        let hash = database.appendingPathComponent("hash.k2d")
        try Data("db".utf8).write(to: hash)
        let scratch = try makeScratch("lungfish-bracken-", creator: Self.goneCreator())
        try FileManager.default.createSymbolicLink(at: scratch.appendingPathComponent("db"), withDestinationURL: database)

        let outcome = SystemTempScratchSweep.sweep(root: systemTemp, processInspector: { _ in nil })

        XCTAssertEqual(outcome.removed.map(\.lastPathComponent), [scratch.lastPathComponent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path), "the folder and the link in it are gone")
        XCTAssertEqual(try Data(contentsOf: hash), Data("db".utf8), "the sweep never follows a link out of the folder")
    }

    func testScratchWhoseCreatorIsAliveStays() throws {
        let scratch = try SystemTempScratchSweep.createMarkedDirectory(prefix: "nfcore-run-", in: systemTemp, toolVersion: "test")

        let outcome = SystemTempScratchSweep.sweep(root: systemTemp)

        assertStays(scratch, outcome, .liveCreator)
    }

    func testACreatorThatCannotBeReadStays() throws {
        let scratch = try makeScratch("taxtriage-", creator: Self.goneCreator())

        let outcome = SystemTempScratchSweep.sweep(root: systemTemp, processInspector: { _ in throw POSIXError(.EPERM) })

        assertStays(scratch, outcome, .creatorUnknown)
    }

    func testAFolderWithNoMarkerOrAnotherRootsMarkerStays() throws {
        let unmarked = systemTemp.appendingPathComponent("taxtriage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: unmarked, withIntermediateDirectories: false)
        let otherRoot = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let moved = try makeScratch("taxtriage-", creator: Self.goneCreator(), in: otherRoot)
        let movedHere = systemTemp.appendingPathComponent(moved.lastPathComponent, isDirectory: true)
        try FileManager.default.moveItem(at: moved, to: movedHere)

        let outcome = SystemTempScratchSweep.sweep(root: systemTemp)

        assertStays(unmarked, outcome, .noMarker)
        assertStays(movedHere, outcome, .noMarker)
    }

    func testAnotherPrefixStays() throws {
        let foreign = try makeScratch("foreign-", creator: Self.goneCreator())
        let noUUID = systemTemp.appendingPathComponent("taxtriage-scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: noUUID, withIntermediateDirectories: false)

        let outcome = SystemTempScratchSweep.sweep(root: systemTemp)

        assertStays(foreign, outcome, .otherPrefix)
        assertStays(noUUID, outcome, .otherPrefix)
    }

    /// S32 review fix 3. No site in `Sources` makes `classify-` or `map-` scratch, so the list leaves them.
    func testPrefixesNoSiteProducesStay() throws {
        let classify = try makeScratch("classify-", creator: Self.goneCreator())
        let map = try makeScratch("map-", creator: Self.goneCreator())

        let outcome = SystemTempScratchSweep.sweep(root: systemTemp)

        assertStays(classify, outcome, .otherPrefix)
        assertStays(map, outcome, .otherPrefix)
    }

    func testAFolderARecordNamesStays() throws {
        let named = try makeScratch("taxtriage-", creator: Self.goneCreator())
        let recordedFile = named.appendingPathComponent("output/report.tsv")
        let holdsRecord = try makeScratch("taxtriage-", creator: Self.goneCreator())
        try Data("{}".utf8).write(to: holdsRecord.appendingPathComponent(".lungfish-provenance.json"))
        let holdsRunRecord = try makeScratch("nfcore-run-", creator: Self.goneCreator())
        try Data("{}".utf8).write(to: holdsRunRecord.appendingPathComponent(AnalysisRunRecord.fileName))

        let outcome = SystemTempScratchSweep.sweep(root: systemTemp, recordedPaths: [recordedFile])

        assertStays(named, outcome, .namedByRecord)
        assertStays(holdsRecord, outcome, .namedByRecord)
        assertStays(holdsRunRecord, outcome, .namedByRecord)
    }

    func testScratchKeptForDebuggingStays() throws {
        let kept = try makeScratch("nfcore-run-", creator: Self.goneCreator(), keepIntermediates: true)

        let outcome = SystemTempScratchSweep.sweep(root: systemTemp)

        assertStays(kept, outcome, .keptForDebugging)
    }

    func testTheSweepTouchesNothingBelowItsRootsChildren() throws {
        let holder = systemTemp.appendingPathComponent("not-lge", isDirectory: true)
        try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: false)
        let nested = try makeScratch("taxtriage-", creator: Self.goneCreator(), in: holder)

        let outcome = SystemTempScratchSweep.sweep(root: systemTemp)

        XCTAssertTrue(outcome.removed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }

    /// S32 review fix 7. `createMarkedDirectory(at:prefix:toolName:toolVersion:)` marks a folder at a path its caller
    /// planned. The sweep claims a name only when it is an LGE prefix from `prefixes` followed by a UUID, so the
    /// function refuses any other name, since the folder it made would stay for ever.
    func testMarkingAFolderAtAPlannedPathRefusesANameTheSweepNeverClaims() throws {
        let refused = [
            "bracken-\(UUID().uuidString)", // no LGE prefix
            "lungfish-bracken-not-a-uuid", // no UUID tail
            "taxtriage-\(UUID().uuidString)", // a name the sweep claims, but not the prefix the caller named
        ]
        for name in refused {
            XCTAssertThrowsError(
                try SystemTempScratchSweep.createMarkedDirectory(
                    at: systemTemp.appendingPathComponent(name, isDirectory: true),
                    prefix: "lungfish-bracken-",
                    toolName: "Test",
                    toolVersion: "1"
                ),
                name
            )
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: systemTemp.path), [], "a refused name leaves no folder")

        let planned = systemTemp.appendingPathComponent("lungfish-bracken-\(UUID().uuidString)", isDirectory: true)
        try SystemTempScratchSweep.createMarkedDirectory(at: planned, prefix: "lungfish-bracken-", toolName: "Test", toolVersion: "1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: planned.appendingPathComponent(OwnedWorkDirectoryMarker.fileName).path))
        let mode = try FileManager.default.attributesOfItem(atPath: planned.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700, "the folder is the user's alone")
        let outcome = SystemTempScratchSweep.sweep(root: systemTemp, processInspector: { _ in nil })
        XCTAssertEqual(outcome.removed.map(\.lastPathComponent), [planned.lastPathComponent], "the sweep claims a name that fits")
    }

    /// S32 review fix 7. A marker that cannot be written must not leave the bare `0700` folder behind. A blank tool
    /// name is a request the marker store refuses, after the folder is made.
    func testAMarkerThatCannotBeWrittenLeavesNoFolderBehind() throws {
        let planned = systemTemp.appendingPathComponent("lungfish-bracken-\(UUID().uuidString)", isDirectory: true)

        XCTAssertThrowsError(
            try SystemTempScratchSweep.createMarkedDirectory(at: planned, prefix: "lungfish-bracken-", toolName: " ", toolVersion: "1")
        )

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: systemTemp.path),
            [],
            "the folder made for the marker is removed again"
        )
    }

    // MARK: - Helpers

    /// A marked folder whose marker names `creator`, made as `ProjectTempDirectory` makes one.
    private func makeScratch(
        _ prefix: String,
        creator: OwnedProcessIdentity,
        in parent: URL? = nil,
        keepIntermediates: Bool = false
    ) throws -> URL {
        let parent = parent ?? systemTemp!
        return try OwnedWorkDirectoryMarkerStore.createDirectory(
            OwnedWorkDirectoryCreationRequest(
                projectURL: parent,
                parentDirectoryURL: parent,
                prefix: prefix,
                runID: UUID(),
                processIdentity: creator,
                state: .active,
                lockRelativePath: nil,
                keepIntermediates: keepIntermediates,
                toolName: "ProjectTempDirectory",
                toolVersion: "test"
            )
        )
    }

    /// This process's PID with another start time, as a PID the system reused.
    private static func goneCreator() throws -> OwnedProcessIdentity {
        let current = try OwnedProcessIdentity.current()
        return OwnedProcessIdentity(
            processIdentifier: current.processIdentifier,
            processStartTime: current.processStartTime &+ 1,
            bootSessionID: current.bootSessionID
        )
    }

    private static func creatorOnAnotherBoot() throws -> OwnedProcessIdentity {
        let current = try OwnedProcessIdentity.current()
        return OwnedProcessIdentity(
            processIdentifier: current.processIdentifier,
            processStartTime: current.processStartTime,
            bootSessionID: UUID().uuidString
        )
    }

    private func assertStays(
        _ folder: URL,
        _ outcome: SystemTempScratchSweep.Outcome,
        _ refusal: SystemTempScratchSweep.Refusal,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var info = stat()
        XCTAssertEqual(lstat(folder.path, &info), 0, "\(folder.lastPathComponent) stays", file: file, line: line)
        XCTAssertEqual(outcome.refused[folder.lastPathComponent], refusal, file: file, line: line)
        XCTAssertFalse(outcome.removed.map(\.lastPathComponent).contains(folder.lastPathComponent), file: file, line: line)
    }
}
