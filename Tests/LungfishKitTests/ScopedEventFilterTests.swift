// ScopedEventFilterTests.swift - The window-or-application rule (R9)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishCore
import LungfishKit
import LungfishKitTestSupport

@MainActor
final class ScopedEventFilterTests: XCTestCase {
    private let windowName = Notification.Name.showInspectorRequested
    private let applicationName = Notification.Name.appSettingsChanged

    func testFixtureNamesHaveTheExpectedClassification() {
        XCTAssertEqual(ScopedEventFilter.classification(of: windowName), .window)
        XCTAssertEqual(ScopedEventFilter.classification(of: applicationName), .application)
    }

    func testWindowEventWithThisWindowsScopeIsAccepted() {
        let scope = WindowStateScope()
        let notification = Notification(
            name: windowName,
            object: nil,
            userInfo: [NotificationUserInfoKey.windowStateScope: scope]
        )

        XCTAssertTrue(ScopedEventFilter.accept(notification, for: scope))
    }

    func testWindowEventWithAnotherWindowsScopeIsDropped() {
        let notification = Notification(
            name: windowName,
            object: nil,
            userInfo: [NotificationUserInfoKey.windowStateScope: WindowStateScope()]
        )

        XCTAssertFalse(ScopedEventFilter.accept(notification, for: WindowStateScope()))
    }

    func testUnscopedWindowEventIsDropped() {
        let notification = Notification(
            name: windowName,
            object: nil,
            userInfo: [NotificationUserInfoKey.inspectorTab: "document"]
        )

        XCTAssertFalse(ScopedEventFilter.accept(notification, for: WindowStateScope()))
        XCTAssertFalse(ScopedEventFilter.accept(Notification(name: windowName), for: WindowStateScope()))
    }

    func testObserverWithoutAScopeAcceptsNoWindowEvent() {
        let notification = Notification(
            name: windowName,
            object: nil,
            userInfo: [NotificationUserInfoKey.windowStateScope: WindowStateScope()]
        )

        XCTAssertFalse(ScopedEventFilter.accept(notification, for: nil))
    }

    func testApplicationEventIsAcceptedWithOrWithoutAScope() {
        let unscoped = Notification(name: applicationName)
        let otherWindow = Notification(
            name: applicationName,
            object: nil,
            userInfo: [NotificationUserInfoKey.windowStateScope: WindowStateScope()]
        )

        XCTAssertTrue(ScopedEventFilter.accept(unscoped, for: WindowStateScope()))
        XCTAssertTrue(ScopedEventFilter.accept(unscoped, for: nil))
        XCTAssertTrue(ScopedEventFilter.accept(otherWindow, for: WindowStateScope()))
    }

    func testUnclassifiedNameIsTreatedAsAWindowEvent() {
        let name = Notification.Name("ScopedEventFilterTests.unclassified")
        XCTAssertNil(ScopedEventFilter.classification(of: name))
        let scope = WindowStateScope()

        XCTAssertFalse(ScopedEventFilter.accept(Notification(name: name), for: scope))
        XCTAssertTrue(ScopedEventFilter.accept(
            Notification(name: name, object: nil, userInfo: [NotificationUserInfoKey.windowStateScope: scope]),
            for: scope
        ))
    }

    func testScopedUserInfoAttachesTheScopeAndKeepsThePayload() {
        let scope = WindowStateScope()
        let userInfo = ScopedEventFilter.scopedUserInfo(
            [NotificationUserInfoKey.inspectorTab: "document"],
            scope: scope
        )

        XCTAssertEqual(userInfo?[NotificationUserInfoKey.windowStateScope] as? WindowStateScope, scope)
        XCTAssertEqual(userInfo?[NotificationUserInfoKey.inspectorTab] as? String, "document")
        XCTAssertEqual(userInfo?.count, 2)
    }

    func testScopedUserInfoWithoutAScopeLeavesThePayloadUnchanged() {
        let userInfo = ScopedEventFilter.scopedUserInfo(
            [NotificationUserInfoKey.inspectorTab: "document"],
            scope: nil
        )

        XCTAssertNil(userInfo?[NotificationUserInfoKey.windowStateScope])
        XCTAssertEqual(userInfo?.count, 1)
        XCTAssertNil(ScopedEventFilter.scopedUserInfo(nil, scope: nil))
    }

    func testScopedUserInfoWithoutAPayloadCarriesOnlyTheScope() {
        let scope = WindowStateScope()
        let userInfo = ScopedEventFilter.scopedUserInfo(scope: scope)

        XCTAssertEqual(userInfo?[NotificationUserInfoKey.windowStateScope] as? WindowStateScope, scope)
        XCTAssertEqual(userInfo?.count, 1)
    }

    func testHostingWindowScopeIsTheScopeOfTheWindowThatShowsTheView() {
        let owner = ScopeOwningWindowController()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        owner.host(view)

        XCTAssertEqual(ScopedEventFilter.hostingWindowScope(of: view), owner.windowStateScope)
    }

    func testHostingWindowScopeFollowsAChildWindowToItsParent() {
        let owner = ScopeOwningWindowController()
        let child = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        child.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        child.contentView?.addSubview(view)
        owner.window?.addChildWindow(child, ordered: .above)
        defer { owner.window?.removeChildWindow(child) }

        XCTAssertEqual(ScopedEventFilter.hostingWindowScope(of: view), owner.windowStateScope)
    }

    func testHostingWindowScopeIsNilOutsideAProjectWindow() {
        let detached = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertNil(ScopedEventFilter.hostingWindowScope(of: detached))
        XCTAssertNil(ScopedEventFilter.hostingWindowScope(of: nil))

        let plainWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        plainWindow.isReleasedWhenClosed = false
        let hosted = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        plainWindow.contentView?.addSubview(hosted)
        XCTAssertNil(ScopedEventFilter.hostingWindowScope(of: hosted))
    }
}
