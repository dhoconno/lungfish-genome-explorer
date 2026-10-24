// AXProcessProbeAvailabilityTests.swift - The AX probe reads the lock of the login session
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ApplicationServices
import CoreGraphics
import XCTest
import LungfishTestSupport

/// `AXProcessProbe.isAvailable` gates the out-of-process accessibility tests.
/// A trusted process in a locked login session gets no answer from the AX
/// server for its own windows, so the probe must report such a session as
/// unavailable and the gated tests skip instead of failing.
@MainActor
final class AXProcessProbeAvailabilityTests: XCTestCase {

    private static let lockedText =
        "the login session is locked (CGSSessionScreenIsLocked), so the out-of-process AX check does not run"
    private static let untrustedText = "process is not trusted for accessibility"

    /// A trusted process in a locked session is unavailable, whether the
    /// dictionary holds the lock as a Bool or as the number the system writes.
    /// `isAvailable` and `unavailableReason` give one answer.
    func testATrustedProcessInALockedSessionIsUnavailable() {
        XCTAssertEqual(
            AXProcessProbe.unavailableReason(trusted: true, session: ["CGSSessionScreenIsLocked": true]),
            Self.lockedText)
        XCTAssertEqual(
            AXProcessProbe.unavailableReason(trusted: true, session: ["CGSSessionScreenIsLocked": 1]),
            Self.lockedText)
        let reason: String? = AXProcessProbe.unavailableReason
        XCTAssertEqual(AXProcessProbe.isAvailable, reason == nil)
    }

    /// An unlocked session, a dictionary without the key and no dictionary at
    /// all leave a trusted process available. A missing dictionary is an
    /// unknown state and is not read as a lock.
    func testATrustedProcessInAnUnlockedOrUnknownSessionIsAvailable() {
        XCTAssertNil(AXProcessProbe.unavailableReason(trusted: true, session: [:]))
        XCTAssertNil(AXProcessProbe.unavailableReason(trusted: true, session: ["CGSSessionScreenIsLocked": 0]))
        XCTAssertNil(AXProcessProbe.unavailableReason(trusted: true, session: ["CGSSessionScreenIsLocked": false]))
        XCTAssertNil(AXProcessProbe.unavailableReason(trusted: true, session: nil))
    }

    /// Trust is checked first, so an untrusted process reports missing trust
    /// in every session.
    func testAnUntrustedProcessIsUnavailableWhetherOrNotTheSessionIsLocked() {
        XCTAssertEqual(AXProcessProbe.unavailableReason(trusted: false, session: [:]), Self.untrustedText)
        XCTAssertEqual(
            AXProcessProbe.unavailableReason(trusted: false, session: ["CGSSessionScreenIsLocked": true]),
            Self.untrustedText)
    }

    /// Reads the lock the way the probe does and checks that `isAvailable`
    /// follows trust and the lock. Written against the live session, so it
    /// fails at the base on a trusted process in a locked session.
    func testTheLiveLockStateReachesIsAvailable() throws {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        try XCTSkipUnless(session != nil, "no session dictionary in this process, the lock cannot be read")
        let locked = (session?["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue == true
        XCTAssertEqual(
            AXProcessProbe.isAvailable, AXIsProcessTrusted() && !locked,
            "isAvailable must follow trust and the lock (trusted \(AXIsProcessTrusted()), locked \(locked))")
    }
}
