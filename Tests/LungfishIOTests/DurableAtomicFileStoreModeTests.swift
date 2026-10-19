// DurableAtomicFileStoreModeTests.swift - The mode a durable file is created with
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.23 M2 (RECORD-MODE, plan X10). The store created every file with S_IRUSR | S_IWUSR, so a record
// it published read 0600 where the files `DurableReplace` stages (0o666 under the umask) read 0644. The mode is now
// the caller's parameter, `recordMode` by default and `privateMode` for a marker, a state file or an attestation.

import Darwin
import Foundation
import LungfishCore
import XCTest
@testable import LungfishIO

final class DurableAtomicFileStoreModeTests: XCTestCase {
    private var scratch: URL!
    private var previousUmask: mode_t = 0o022

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-mode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        previousUmask = umask(0o022)
    }

    override func tearDownWithError() throws {
        umask(previousUmask)
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        try super.tearDownWithError()
    }

    private func mode(of url: URL) -> mode_t {
        var information = stat()
        XCTAssertEqual(lstat(url.path, &information), 0, "\(url.lastPathComponent) exists")
        return information.st_mode & 0o777
    }

    func testAFileTakesTheModeOfAnyNewFileUnderTheUmask() throws {
        let url = try DurableAtomicFileStore().create(Data("{}".utf8), named: "record.json", in: scratch)
        XCTAssertEqual(mode(of: url), 0o644)
    }

    func testTheUmaskDecidesTheDefaultMode() throws {
        umask(0o077)
        let url = try DurableAtomicFileStore().create(Data("{}".utf8), named: "record.json", in: scratch)
        XCTAssertEqual(mode(of: url), 0o600, "the files DurableReplace stages read the same under this umask")
    }

    func testACallerThatAsksForAPrivateModeKeepsItUnderAnOpenUmask() throws {
        umask(0o000)
        let url = try DurableAtomicFileStore().create(
            Data("{}".utf8), named: "state.json", in: scratch, mode: DurableAtomicFileStore.privateMode
        )
        XCTAssertEqual(mode(of: url), 0o600)
    }

    func testTheDescriptorRelativeFormsTakeTheSameModes() throws {
        let directory = try NoFollowFileSystem.openDirectoryHierarchy(scratch)
        defer { Darwin.close(directory) }
        let store = DurableAtomicFileStore()
        let record = try store.createWitnessed(
            Data("{}".utf8), named: "record.json", inOpenDirectory: directory, displayedAt: scratch
        )
        let state = try store.createWitnessed(
            Data("{}".utf8), named: "state.json", inOpenDirectory: directory, displayedAt: scratch,
            mode: DurableAtomicFileStore.privateMode
        )
        let marker = try store.create(
            Data("{}".utf8), named: "marker.json", inOpenDirectory: directory, displayedAt: scratch,
            mode: DurableAtomicFileStore.privateMode
        )
        defer {
            record.close()
            state.close()
        }
        XCTAssertEqual(mode(of: record.url), 0o644)
        XCTAssertEqual(mode(of: state.url), 0o600)
        XCTAssertEqual(mode(of: marker), 0o600)
    }
}
