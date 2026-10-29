// TestStateObserverTests.swift - The test-state observer's diff, words, ledger line and installation
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishTestSupport

/// Phase 3.1 ruling QA-RELEASE-LOOP, section 4. The bootstrap target's constructor signs the observer up when the
/// bundle loads, so even a process that runs this one class has it before its first case.
final class TestStateObserverInstallTests: XCTestCase {
    func testTheObserverIsInstalledBeforeTheFirstCase() {
        XCTAssertNotNil(TestStateObserver.installedAt, "the bootstrap constructor did not install the observer")
        XCTAssertEqual(Array(TestStateObserver.checkNames.prefix(3)),
                       ["xctest defaults", "LUNGFISH_ environment", "current directory"])
    }
}

/// The observer's pure diff fed with snapshots, and the restore of the environment check.
final class TestStateObserverDiffTests: XCTestCase {
    func testOnlyANewRowOrWindowIsALeakAndOneThatEndedIsNot() {
        let before = ["row-a": "\"Import\" (Import, running)", "row-b": "\"Sort\" (BAM, running)"]
        let after = ["row-b": "\"Sort\" (BAM, cancelling)", "row-c": "\"MAFFT\" (Alignment, running)"]
        XCTAssertEqual(TestStateObserver.leakedKeys(before: before, after: after, comparison: .newKeys), ["row-c"])
    }

    func testANewOrChangedValueIsALeakAndARemovedOneIsNot() {
        let before = ["LUNGFISH_A": "1", "LUNGFISH_B": "2", "LUNGFISH_C": "3"]
        let after = ["LUNGFISH_A": "1", "LUNGFISH_B": "20", "LUNGFISH_D": "4"]
        XCTAssertEqual(TestStateObserver.leakedKeys(before: before, after: after, comparison: .newOrChangedValues),
                       ["LUNGFISH_B", "LUNGFISH_D"])
        XCTAssertEqual(TestStateObserver.leakedKeys(before: after, after: after, comparison: .newOrChangedValues), [])
    }

    func testADomainDiffNamesEachNewOrChangedKeyAndNoRemovedOne() {
        let before: NSDictionary = ["kept": "1", "changed": ["a": 1], "removed": true]
        let after: NSDictionary = ["kept": "1", "changed": ["a": 2], "DatabaseStorageLocation": "/Volumes/x"]
        XCTAssertEqual(TestStateObserver.changedKeys(before: before, after: after), ["DatabaseStorageLocation", "changed"])
        XCTAssertEqual(TestStateObserver.changedKeys(before: after, after: after.copy() as! NSDictionary), [])
    }

    func testTheWordsGiveTheCountTheNounAndEachValue() {
        XCTAssertEqual(TestStateObserver.message(noun: "active operation row", entries: ["\"MAFFT\" (Alignment, running)"]),
                       "left 1 active operation row \"MAFFT\" (Alignment, running)")
        XCTAssertEqual(TestStateObserver.message(noun: "LUNGFISH_ variable", entries: ["LUNGFISH_A=1", "LUNGFISH_B=2"]),
                       "left 2 LUNGFISH_ variables LUNGFISH_A=1, LUNGFISH_B=2")
    }

    func testTheLedgerLineNamesTheLeakingTestInTheGatesForm() throws {
        XCTAssertEqual(TestStateObserver.canonicalName("-[LungfishAppTests.MAFFTTests testAlign]"),
                       "LungfishAppTests.MAFFTTests/testAlign")
        XCTAssertEqual(TestStateObserver.canonicalName("LungfishAppTests.MAFFTTests"), "LungfishAppTests.MAFFTTests")
        let leak = TestStateLeak(check: "operation rows", keys: ["row-c"],
                                 message: "left 1 active operation row \"MAFFT\" (Alignment, running)")
        let line = TestStateObserver.ledgerLine(test: "LungfishAppTests.MAFFTTests/testAlign", phase: "case", leak: leak)
        XCTAssertTrue(line.hasSuffix("\n"))
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1, "one JSON object a line")
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(record["test"] as? String, "LungfishAppTests.MAFFTTests/testAlign")
        XCTAssertEqual(record["phase"] as? String, "case")
        XCTAssertEqual(record["check"] as? String, "operation rows")
        XCTAssertEqual(record["keys"] as? [String], ["row-c"])
        XCTAssertEqual(record["message"] as? String, leak.message)
    }

    @MainActor
    func testTheEnvironmentCheckFindsANewVariableAndRestoresItsAbsence() {
        let check = TestStateObserver.environmentCheck()
        let name = "LUNGFISH_TEST_STATE_OBSERVER_PROBE"
        let before = check.snapshot()
        setenv(name, "set by the test", 1)
        let after = check.snapshot()
        let keys = TestStateObserver.leakedKeys(before: before, after: after, comparison: check.comparison)
        check.restore(keys, before)
        XCTAssertEqual(keys, [name])
        XCTAssertEqual(check.describe(name, after[name] ?? ""), "\(name)=set by the test")
        XCTAssertNil(ProcessInfo.processInfo.environment[name], "the restore put back the variable's absence")
    }

    @MainActor
    func testTheDefaultsCheckKeepsAValueItCanRestoreExactly() {
        let check = TestStateObserver.defaultsDomainCheck()
        let value = check.snapshot()
        XCTAssertEqual(TestStateObserver.leakedKeys(before: value, after: check.snapshot(), comparison: check.comparison),
                       [], "two reads of an unchanged domain are equal")
        XCTAssertNil(value["DatabaseStorageLocation"], "no exported storage root left its key in the domain")
    }
}
