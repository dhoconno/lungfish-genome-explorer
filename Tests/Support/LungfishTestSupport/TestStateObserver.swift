// TestStateObserver.swift - Names the test that leaves process state behind, then puts the state back
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest

/// One piece of process state that a test may leave behind. ``TestStateObserver`` reads it before and after each
/// case and after each class.
///
/// `snapshot` reads the state as a map from a key to a value string. `restore` puts back the keys that leaked as the
/// before map had them, and removes a key the before map lacks. `describe` turns a value string into the words of a
/// leak. All three run on the main thread. A check that needs LungfishKit or AppKit lives in the bundle that links
/// them (`Tests/LungfishAppTests/AppTestStateChecks.swift`), since this target imports no Kit module.
public struct TestStateCheck: Sendable {
    /// Which difference between two snapshots is a leak.
    public enum Comparison: Sendable {
        /// Only a key that is new at the end. A row or a window that ended during the test is fine.
        case newKeys
        /// A key that is new or whose value changed (defaults keys, variables, the current directory).
        case newOrChangedValues
    }

    public let name: String
    /// What one key is, in the singular, for the words of a leak, as in "active operation row".
    public let noun: String
    public let comparison: Comparison
    public let snapshot: @MainActor @Sendable () -> [String: String]
    public let restore: @MainActor @Sendable (_ keys: [String], _ before: [String: String]) -> Void
    public let describe: @MainActor @Sendable (_ key: String, _ value: String) -> String

    public init(
        name: String, noun: String, comparison: Comparison,
        snapshot: @escaping @MainActor @Sendable () -> [String: String],
        restore: @escaping @MainActor @Sendable (_ keys: [String], _ before: [String: String]) -> Void,
        describe: @escaping @MainActor @Sendable (_ key: String, _ value: String) -> String = { _, value in value }
    ) {
        self.name = name
        self.noun = noun
        self.comparison = comparison
        self.snapshot = snapshot
        self.restore = restore
        self.describe = describe
        self.domain = nil
    }

    /// A property-list domain read and compared as one dictionary, for a domain too large to turn into words each
    /// case. The xctest tool's domain on galah held 7,405 keys (2.8 MB) on 2026-10-28, which cost 25 ms a read as
    /// words. One dictionary compare costs far less, and only a changed domain is diffed key by key.
    struct Domain: Sendable {
        let read: @MainActor @Sendable () -> NSDictionary
        let restore: @MainActor @Sendable (_ keys: [String], _ before: NSDictionary) -> Void
    }

    let domain: Domain?

    init(name: String, noun: String, domain: Domain,
         describe: @escaping @MainActor @Sendable (_ key: String, _ value: String) -> String) {
        self.name = name
        self.noun = noun
        self.comparison = .newOrChangedValues
        self.snapshot = {
            domain.read().reduce(into: [String: String]()) { words, entry in words["\(entry.key)"] = "\(entry.value)" }
        }
        self.restore = { _, _ in }
        self.describe = describe
        self.domain = domain
    }
}

/// One check's state at one moment: words, or the raw dictionary of a domain check.
struct TestStateSnapshot: @unchecked Sendable {
    let words: [String: String]
    let domain: NSDictionary?
}

/// What one check found between two snapshots: the keys that leaked and the words after the test's name.
public struct TestStateLeak: Equatable, Sendable {
    public let check: String
    public let keys: [String]
    public let message: String

    public init(check: String, keys: [String], message: String) {
        self.check = check
        self.keys = keys
        self.message = message
    }
}

/// The permanent test-state observer (Phase 3.1 ruling QA-RELEASE-LOOP, section 4).
///
/// It snapshots each check at `testCaseWillStart` and compares at `testCaseDidFinish`, after `tearDown` and the
/// teardown blocks. Anything new or changed at the end is a leak of that test. It also compares a class suite's end
/// with its start, so the rows that a `class func setUp` made belong to the class. At `testBundleWillStart` a
/// `DatabaseStorageLocation` key already in the xctest tool's domain is one leak, present at bundle start.
///
/// A leak never fails the case, since an issue recorded after `testCaseDidFinish` would follow the case's passed
/// line that the gate parses. The observer appends one JSON line to the file that `LUNGFISH_TEST_LEAK_LEDGER`
/// names (the gate sets it for each attempt and turns each line into an error), or, outside a gate, prints
/// `error: test state leak: ...` to stderr. Then it restores the state, so the next test is neither failed nor
/// poisoned and the ledger names the test that leaked.
///
/// The C constructor of `LungfishTestObserverBootstrap` sends `install` when a bundle loads, so the observer is
/// signed up before the first case of every process, the one-class processes of the unit tier included.
@objc(LGETestStateObserver)
public final class TestStateObserver: NSObject, XCTestObservation, @unchecked Sendable {
    public static let shared = TestStateObserver()
    /// The variable that names the ledger file. The gate sets it for each attempt.
    public static let ledgerVariable = "LUNGFISH_TEST_LEAK_LEDGER"
    /// The persistent defaults domain of the xctest tool, where an exported storage root once left its key.
    public static let xctestDomain = "com.apple.dt.xctest.tool"

    private let lock = NSLock()
    private var checks: [TestStateCheck] = TestStateObserver.processChecks()
    private var caseSnapshots: [ObjectIdentifier: [String: TestStateSnapshot]] = [:]
    private var suiteSnapshots: [ObjectIdentifier: [String: TestStateSnapshot]] = [:]
    private var installed: Date?
    private var queued = false
    private var casesChecked = 0
    private var secondsChecking = 0.0
    private var leaksFound = 0
    private var callsOffMain = 0

    private func locked<T>(_ body: (TestStateObserver) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(self)
    }

    /// When the observer signed up with XCTest, nil before.
    public static var installedAt: Date? { shared.locked { $0.installed } }

    /// The names of the checks in force, in the order they run.
    public static var checkNames: [String] { shared.locked { $0.checks.map(\.name) } }

    /// Signs the observer up with XCTest once. On the main thread it signs up at once. Off it, it queues the sign-up
    /// on the main queue without waiting, since the main thread may be waiting for the caller
    /// (`TestDefaultsSuite.swift` gives the reasons).
    @objc public static func install() {
        let observer = shared
        if Thread.isMainThread {
            observer.signUpOnTheMainThread()
            return
        }
        let shouldQueue = observer.locked { observer -> Bool in
            guard observer.installed == nil, !observer.queued else { return false }
            observer.queued = true
            return true
        }
        if shouldQueue {
            DispatchQueue.main.async { observer.signUpOnTheMainThread() }
        }
    }

    /// Adds a check, which then runs for every later case. A bundle's own checks register from the bootstrap.
    public static func register(_ check: TestStateCheck) {
        shared.locked { observer in
            observer.checks.removeAll { $0.name == check.name }
            observer.checks.append(check)
        }
    }

    private func signUpOnTheMainThread() {
        guard locked({ $0.installed == nil }) else { return }
        XCTestObservationCenter.shared.addTestObserver(self)
        locked { $0.installed = Date() }
    }

    // MARK: - The pure diff

    /// The keys of `after` that are a leak against `before`, sorted.
    public static func leakedKeys(
        before: [String: String], after: [String: String], comparison: TestStateCheck.Comparison
    ) -> [String] {
        after.keys.filter { key in
            guard let old = before[key] else { return true }
            return comparison == .newOrChangedValues && old != after[key]
        }.sorted()
    }

    /// The words of one leak, as in `left 1 active operation row "MAFFT" (Alignment, running)`.
    public static func message(noun: String, entries: [String]) -> String {
        "left \(entries.count) \(noun)\(entries.count == 1 ? "" : "s") " + entries.joined(separator: ", ")
    }

    /// The full name the gate uses for a case, `Module.Class/testMethod`, from Darwin's `-[Module.Class testMethod]`.
    public static func canonicalName(_ name: String) -> String {
        guard name.hasPrefix("-["), name.hasSuffix("]") else { return name }
        let parts = name.dropFirst(2).dropLast().split(separator: " ", maxSplits: 1)
        return parts.count == 2 ? "\(parts[0])/\(parts[1])" : name
    }

    /// One ledger line, a JSON object with the test, the phase, the check, the keys and the words.
    public static func ledgerLine(test: String, phase: String, leak: TestStateLeak) -> String {
        let record: [String: Any] = ["test": test, "phase": phase, "check": leak.check, "keys": leak.keys,
                                     "message": leak.message]
        let data = (try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])) ?? Data()
        return (String(data: data, encoding: .utf8) ?? "{}") + "\n"
    }

    /// Writes one leak to the ledger the environment names, or to stderr outside a gate.
    public static func report(test: String, phase: String, leak: TestStateLeak) {
        shared.locked { $0.leaksFound += 1 }
        let line = ledgerLine(test: test, phase: phase, leak: leak)
        guard let path = ProcessInfo.processInfo.environment[ledgerVariable], !path.isEmpty else {
            FileHandle.standardError.write(Data("error: test state leak: \(test) \(leak.message)\n".utf8))
            return
        }
        let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else {
            FileHandle.standardError.write(Data("error: test state leak ledger \(path) did not open: \(line)".utf8))
            return
        }
        defer { close(descriptor) }
        let bytes = Array(line.utf8)
        _ = bytes.withUnsafeBufferPointer { write(descriptor, $0.baseAddress, $0.count) }
    }

    // MARK: - XCTestObservation

    public func testBundleWillStart(_ testBundle: Bundle) {
        let bundle = testBundle.bundleURL.deletingPathExtension().lastPathComponent
        guard onMain(bundle) else { return }
        let domain = UserDefaults.standard.persistentDomain(forName: Self.xctestDomain) ?? [:]
        guard let value = domain["DatabaseStorageLocation"] else { return }
        Self.report(test: bundle, phase: "bundle start", leak: TestStateLeak(
            check: "xctest defaults", keys: ["DatabaseStorageLocation"],
            message: "found xctest defaults key DatabaseStorageLocation=\(value) present at bundle start"))
    }

    public func testBundleDidFinish(_ testBundle: Bundle) {
        let (cases, seconds, leaks, offMain) = locked { ($0.casesChecked, $0.secondsChecking, $0.leaksFound, $0.callsOffMain) }
        let perCase = cases == 0 ? 0 : seconds * 1000 / Double(cases)
        print("TestStateObserver: \(cases) cases checked in \(String(format: "%.3f", seconds)) s "
            + "(\(String(format: "%.3f", perCase)) ms a case), \(leaks) leaks, \(offMain) observer off main")
        fflush(stdout)
    }

    public func testSuiteWillStart(_ testSuite: XCTestSuite) {
        guard let name = Self.className(of: testSuite), onMain(name) else { return }
        let snapshot = timed { MainActor.assumeIsolated { self.snapshotAll() } }
        locked { $0.suiteSnapshots[ObjectIdentifier(testSuite)] = snapshot }
    }

    public func testSuiteDidFinish(_ testSuite: XCTestSuite) {
        guard let name = Self.className(of: testSuite), onMain(name) else { return }
        guard let before = locked({ $0.suiteSnapshots.removeValue(forKey: ObjectIdentifier(testSuite)) }) else { return }
        timed { MainActor.assumeIsolated { self.compare(before, test: name, phase: "class") } }
    }

    public func testCaseWillStart(_ testCase: XCTestCase) {
        let name = Self.canonicalName(testCase.name)
        guard onMain(name) else { return }
        let snapshot = timed { MainActor.assumeIsolated { self.snapshotAll() } }
        locked { $0.caseSnapshots[ObjectIdentifier(testCase)] = snapshot }
    }

    public func testCaseDidFinish(_ testCase: XCTestCase) {
        let name = Self.canonicalName(testCase.name)
        guard onMain(name) else { return }
        guard let before = locked({ $0.caseSnapshots.removeValue(forKey: ObjectIdentifier(testCase)) }) else { return }
        timed { MainActor.assumeIsolated { self.compare(before, test: name, phase: "case") } }
        locked { $0.casesChecked += 1 }
    }

    // MARK: - Running the checks

    /// The module-qualified class of a class suite (one whose tests are all cases), nil for any other suite.
    private static func className(of suite: XCTestSuite) -> String? {
        guard let first = suite.tests.first as? XCTestCase, suite.tests.allSatisfy({ $0 is XCTestCase }) else {
            return nil
        }
        return String(reflecting: type(of: first))
    }

    /// Darwin XCTest calls observers on the main thread. A call off it is one ledger line and no check, since a
    /// sync hop to the main queue could deadlock.
    private func onMain(_ test: String) -> Bool {
        if Thread.isMainThread { return true }
        locked { $0.callsOffMain += 1 }
        Self.report(test: test, phase: "off main", leak: TestStateLeak(
            check: "observer off main", keys: [], message: "was observed off the main thread, so its checks were skipped"))
        return false
    }

    private func timed<T>(_ body: () -> T) -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = body()
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        locked { $0.secondsChecking += seconds }
        return value
    }

    @MainActor
    private func snapshotAll() -> [String: TestStateSnapshot] {
        var snapshot: [String: TestStateSnapshot] = [:]
        for check in locked({ $0.checks }) {
            if let domain = check.domain {
                snapshot[check.name] = TestStateSnapshot(words: [:], domain: domain.read())
            } else {
                snapshot[check.name] = TestStateSnapshot(words: check.snapshot(), domain: nil)
            }
        }
        return snapshot
    }

    @MainActor
    private func compare(_ before: [String: TestStateSnapshot], test: String, phase: String) {
        for check in locked({ $0.checks }) {
            guard let old = before[check.name] else { continue }
            let keys: [String], entries: [String]
            if let domain = check.domain, let oldDomain = old.domain {
                let newDomain = domain.read()
                guard !oldDomain.isEqual(newDomain) else { continue }
                keys = Self.changedKeys(before: oldDomain, after: newDomain)
                guard !keys.isEmpty else { continue }
                entries = keys.map { check.describe($0, newDomain[$0].map { "\($0)" } ?? "") }
                domain.restore(keys, oldDomain)
            } else {
                let new = check.snapshot()
                keys = Self.leakedKeys(before: old.words, after: new, comparison: check.comparison)
                guard !keys.isEmpty else { continue }
                entries = keys.map { check.describe($0, new[$0] ?? "") }
                check.restore(keys, old.words)
            }
            Self.report(test: test, phase: phase, leak: TestStateLeak(
                check: check.name, keys: keys, message: Self.message(noun: check.noun, entries: entries)))
        }
    }

    /// The keys of `after` that are new or hold another value than in `before`, sorted. A removed key is no leak.
    public static func changedKeys(before: NSDictionary, after: NSDictionary) -> [String] {
        after.allKeys.compactMap { $0 as? String }.filter { key in
            guard let old = before[key] as AnyObject?, let new = after[key] as AnyObject? else { return true }
            return !old.isEqual(new)
        }.sorted()
    }
}

// MARK: - The checks every bundle runs

extension TestStateObserver {
    /// The checks that read plain process state: the xctest tool's defaults domain, the `LUNGFISH_` variables and
    /// the current directory.
    static func processChecks() -> [TestStateCheck] {
        [defaultsDomainCheck(), environmentCheck(), currentDirectoryCheck()]
    }

    /// Every key of the xctest tool's persistent domain, `DatabaseStorageLocation` among them, read as one
    /// dictionary. The restore puts back each changed key's value and removes each new key.
    public static func defaultsDomainCheck() -> TestStateCheck {
        TestStateCheck(
            name: "xctest defaults", noun: "xctest defaults key",
            domain: TestStateCheck.Domain(
                read: { readDomain(xctestDomain) },
                restore: { keys, before in
                    for key in keys {
                        CFPreferencesSetValue(key as CFString, before[key] as CFPropertyList?, xctestDomain as CFString,
                                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                    }
                    CFPreferencesSynchronize(xctestDomain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                }),
            describe: { key, value in "\(key)=\(value)" })
    }

    /// The persistent domain of the current user on any host, as UserDefaults writes it, or an empty dictionary.
    static func readDomain(_ name: String) -> NSDictionary {
        let all = CFPreferencesCopyMultiple(nil, name as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return all as NSDictionary
    }

    /// The environment variables whose names start with `LUNGFISH_`.
    public static func environmentCheck() -> TestStateCheck {
        TestStateCheck(
            name: "LUNGFISH_ environment", noun: "LUNGFISH_ variable", comparison: .newOrChangedValues,
            snapshot: { ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("LUNGFISH_") } },
            restore: { keys, before in
                for key in keys {
                    if let value = before[key] { setenv(key, value, 1) } else { unsetenv(key) }
                }
            },
            describe: { key, value in "\(key)=\(value)" })
    }

    /// The process's current directory.
    public static func currentDirectoryCheck() -> TestStateCheck {
        TestStateCheck(
            name: "current directory", noun: "changed current directory", comparison: .newOrChangedValues,
            snapshot: { ["cwd": FileManager.default.currentDirectoryPath] },
            restore: { _, before in
                if let path = before["cwd"] { _ = FileManager.default.changeCurrentDirectoryPath(path) }
            },
            describe: { _, value in value })
    }
}
