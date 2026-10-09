// OpenFileSnapshotDeviceTests.swift - Open-file snapshots survive device numbers with the top bit set
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

/// `storage dedupe` crashed on a Mac where some process held a file open on a device
/// whose number has the top bit set: proc_pidfdinfo reports the device as a uint32_t,
/// and converting it to the signed dev_t with `dev_t(_:)` trapped.
final class OpenFileSnapshotDeviceTests: XCTestCase {
    typealias Identity = APFSCloneSupport.OpenFileSnapshot.FileIdentity

    func testADeviceNumberWithTheTopBitSetIsKeptByBitPattern() {
        let identity = Identity(vnodeDevice: 0x8000_0001, inode: 7)
        XCTAssertEqual(identity.device, dev_t(bitPattern: 0x8000_0001))
        XCTAssertEqual(identity, Identity(device: dev_t(bitPattern: 0x8000_0001), inode: 7))
    }

    func testAnOrdinaryDeviceNumberIsUnchanged() {
        XCTAssertEqual(Identity(vnodeDevice: 16_777_229, inode: 7).device, 16_777_229)
    }

    func testASnapshotFindsAFileThisProcessHoldsOpen() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-file-snapshot-\(UUID().uuidString)")
        try Data("held".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let snapshot = APFSCloneSupport.OpenFileSnapshot.capture(excludingCurrentProcess: false)
        XCTAssertGreaterThan(snapshot.processesInspected, 0)
        XCTAssertTrue(snapshot.contains(url))
    }
}
