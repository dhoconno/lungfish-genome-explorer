// SidebarDeletionErrorClassificationTests.swift - "already deleted" error classification
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp

@MainActor
final class SidebarDeletionErrorClassificationTests: XCTestCase {
    func testCocoaFileNoSuchFileErrorIsTreatedAsAlreadyDeleted() {
        let error = CocoaError(.fileNoSuchFile)
        XCTAssertTrue(SidebarViewController.isAlreadyDeletedError(error))
    }

    func testCocoaErrorDomainCodeFourIsTreatedAsAlreadyDeleted() {
        // NSFileNoSuchFileError == 4 in NSCocoaErrorDomain.
        let error = NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: nil)
        XCTAssertTrue(SidebarViewController.isAlreadyDeletedError(error))
    }

    func testPOSIXNoSuchFileErrorIsTreatedAsAlreadyDeleted() {
        // ENOENT == 2 in NSPOSIXErrorDomain.
        let error = NSError(domain: NSPOSIXErrorDomain, code: 2, userInfo: nil)
        XCTAssertTrue(SidebarViewController.isAlreadyDeletedError(error))
    }

    func testPOSIXErrorEnoentIsTreatedAsAlreadyDeleted() {
        let error = POSIXError(.ENOENT)
        XCTAssertTrue(SidebarViewController.isAlreadyDeletedError(error))
    }

    func testUnderlyingNoSuchFileErrorIsTreatedAsAlreadyDeleted() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: 2, userInfo: nil)
        let wrapper = NSError(
            domain: NSCocoaErrorDomain,
            code: 512,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )
        XCTAssertTrue(SidebarViewController.isAlreadyDeletedError(wrapper))
    }

    func testPermissionsErrorIsNotTreatedAsAlreadyDeleted() {
        // NSFileWriteNoPermissionError == 513 in NSCocoaErrorDomain.
        let error = CocoaError(.fileWriteNoPermission)
        XCTAssertFalse(SidebarViewController.isAlreadyDeletedError(error))
    }

    func testGenericErrorIsNotTreatedAsAlreadyDeleted() {
        let error = NSError(domain: "com.example.unexpected", code: 42, userInfo: nil)
        XCTAssertFalse(SidebarViewController.isAlreadyDeletedError(error))
    }
}
