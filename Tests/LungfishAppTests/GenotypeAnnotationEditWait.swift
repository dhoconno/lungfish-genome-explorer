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
