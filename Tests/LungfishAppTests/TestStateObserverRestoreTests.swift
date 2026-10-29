// TestStateObserverRestoreTests.swift - The defaults check puts the shared domain back only inside a gate
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishTestSupport

/// Review LOOP-QA SF-1. Every xctest process of the user shares the xctest tool's defaults domain, so a key that
/// changed during a case may be another process's. Outside a gate the observer reports the key and puts nothing back.
/// Inside a gate, which the full tier starts only when no other xctest process runs, it restores and the ledger names
/// the key. Each case feeds the shared observer a probe case that writes a key, in the style of
/// `TestStateObserverNamingTests`.
final class TestStateObserverRestoreTests: XCTestCase {
    private static var domain: CFString { TestStateObserver.xctestDomain as CFString }

    private static func write(_ key: String, _ value: String?) {
        CFPreferencesSetValue(key as CFString, value as CFPropertyList?, domain, kCFPreferencesCurrentUser,
                              kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private static func read(_ key: String) -> String? {
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            as? String
    }

    /// The unit tier's parallel workers switch the defaults check off, so these cases have nothing to observe there.
    private func skipWhenTheDefaultsCheckIsOff() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["LUNGFISH_TEST_STATE_DOMAIN"] == "off",
                      "the defaults check is off in this process (a parallel attempt of the unit tier)")
    }

    /// Runs a probe case through the shared observer with the ledger variable naming `ledger`, or unset, and writes
    /// `key` while the probe runs. The variable gets its value back before this returns.
    @MainActor
    private func observeAProbe(writing key: String, ledger: URL?) {
        let variable = TestStateObserver.ledgerVariable
        let gateLedger = ProcessInfo.processInfo.environment[variable]
        if let ledger { setenv(variable, ledger.path, 1) } else { unsetenv(variable) }
        defer { if let gateLedger { setenv(variable, gateLedger, 1) } else { unsetenv(variable) } }
        let probe = TestStateObserverRestoreTests(selector: #selector(testInsideAGateTheDefaultsCheckRestores))
        TestStateObserver.shared.testCaseWillStart(probe)
        Self.write(key, "written during the probe")
        TestStateObserver.shared.testCaseDidFinish(probe)
    }

    @MainActor @objc
    func testOutsideAGateTheDefaultsCheckReportsAndPutsNothingBack() throws {
        try skipWhenTheDefaultsCheckIsOff()
        let key = "LGEObserverRestoreProbe-\(UUID().uuidString)"
        defer { Self.write(key, nil) }
        observeAProbe(writing: key, ledger: nil)
        XCTAssertEqual(Self.read(key), "written during the probe",
                       "outside a gate the key may be another process's, so the observer leaves it")
    }

    @MainActor @objc
    func testInsideAGateTheDefaultsCheckRestores() throws {
        try skipWhenTheDefaultsCheckIsOff()
        let key = "LGEObserverRestoreProbe-\(UUID().uuidString)"
        let ledger = FileManager.default.temporaryDirectory
            .appendingPathComponent("observer-restore-\(UUID().uuidString).jsonl")
        defer {
            Self.write(key, nil)
            try? FileManager.default.removeItem(at: ledger)
        }
        observeAProbe(writing: key, ledger: ledger)
        XCTAssertNil(Self.read(key), "inside a gate the observer removes the key the probe added")
        let lines = try String(contentsOf: ledger, encoding: .utf8).split(separator: "\n")
        let keys = lines.flatMap { line -> [String] in
            let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            return record?["keys"] as? [String] ?? []
        }
        XCTAssertTrue(keys.contains(key), "the ledger names the probe's key: \(lines)")
    }
}
