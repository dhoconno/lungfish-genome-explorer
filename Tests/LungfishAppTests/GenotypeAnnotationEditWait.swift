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
