import Foundation
@testable import LungfishGenotypeUI

/// Waits until every annotation edit the UI started has published (2.11 S35 M2a).
///
/// An edit the controller starts publishes after the call that started it returns, so a test
/// awaits this before it asserts on what the edit saved, and before its cleanup removes the
/// bundle the edit writes to. An edit left running past its test fails once the bundle is gone,
/// and its alert would then run modal with no window and hold every later test.
@MainActor
func waitForAnnotationEdits() async {
    await GenotypeAnnotationPublicationChain.waitForEveryEdit()
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
