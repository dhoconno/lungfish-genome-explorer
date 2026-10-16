import Foundation
import XCTest
@testable import LungfishGenotypeUI

/// Waits until every annotation edit the UI started has published (2.11 S35 M2a).
///
/// An edit the controller starts publishes after the call that started it returns, so a test
/// awaits this before it asserts on what the edit saved, and before its cleanup removes the
/// bundle the edit writes to. An edit left running past its test fails once the bundle is gone,
/// and its alert would then run modal with no window and hold every later test. The wait gives
/// up after 60 seconds and fails the test, so an edit that never ends cannot hang the unit tier
/// (2.11 S35 review fix 8).
@MainActor
func waitForAnnotationEdits(file: StaticString = #filePath, line: UInt = #line) async {
    await GenotypeResultViewController.waitForAnnotationEditsToSave(timeout: .seconds(60))
    XCTAssertFalse(
        GenotypeResultViewController.isSavingAnnotationEdits,
        "an annotation edit did not end within 60 s",
        file: file,
        line: line
    )
}

/// Holds an edit open until a test releases it, so the test can look at what holds while the edit
/// publishes. The edit awaits `wait()` and the test calls `release()` (2.11 S35 review fix 7).
@MainActor
final class AnnotationEditHold {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

/// Waits up to `timeout` seconds until `condition` holds, sleeping between checks. An async test
/// runs as a job on the main queue, so a run loop spun inside it never runs the SwiftUI updates
/// queued behind that job. Sleeping ends the job and lets them run.
@MainActor
func waitUntilMainQueueRuns(timeout: TimeInterval = 10, _ condition: () -> Bool) async {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !condition(), Date() < deadline {
        try? await Task.sleep(for: .milliseconds(20))
    }
}
