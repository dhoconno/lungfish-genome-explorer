// HostDefaultsRestorer.swift - Puts back the keys a test's product code wrote to the test host's own defaults
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The keys of the test host's own defaults domain (`com.apple.dt.xctest.tool`, where `UserDefaults.standard`
/// writes in a test) that one test owns, as the test found them.
///
/// Use it when product code writes to `UserDefaults.standard` and the test cannot reach a seam to give it a suite
/// from `makeTestDefaultsSuite(prefix:)`. A `MainSplitViewController` makes the result views, and each saves its
/// column layout under `org.lungfish.metadata-column-layout.<table>:<result path>`. The test makes the restorer in
/// `setUp` and calls `restore()` at the end of `tearDown`, after it closed its windows, so it leaves no key behind
/// and ``TestStateObserver`` finds nothing (Phase 3.1 ruling QA-RELEASE-LOOP, section 5).
///
/// It touches only the keys `owns` accepts, a fragment of the test's own folder or the names of the keys its path
/// writes, since the domain is shared by every xctest process of the user, and another process's key is not this
/// test's to remove. CFPreferences may be called from any thread, so the restorer needs no actor.
public final class HostDefaultsRestorer: @unchecked Sendable {
    public static let domain = TestStateObserver.xctestDomain
    private let owns: @Sendable (String) -> Bool
    private let before: NSDictionary

    /// Owns every key whose name contains `fragment`, as a layout key holds the path of the result it shows.
    public convenience init(keysContaining fragment: String) {
        self.init(owns: { $0.contains(fragment) })
    }

    /// Owns the keys named.
    public convenience init(keys: Set<String>) {
        self.init(owns: { keys.contains($0) })
    }

    public init(owns: @escaping @Sendable (String) -> Bool) {
        self.owns = owns
        self.before = TestStateObserver.readDomain(Self.domain)
    }

    /// Removes each owned key the test added, puts back each owned key it changed or removed, and returns the keys
    /// it put back, sorted.
    @discardableResult
    public func restore() -> [String] {
        let after = TestStateObserver.readDomain(Self.domain)
        let removed = before.allKeys.compactMap { $0 as? String }.filter { after[$0] == nil }
        let keys = (TestStateObserver.changedKeys(before: before, after: after) + removed).filter(owns).sorted()
        guard !keys.isEmpty else { return [] }
        for key in keys {
            CFPreferencesSetValue(key as CFString, before[key] as CFPropertyList?, Self.domain as CFString,
                                  kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        CFPreferencesSynchronize(Self.domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return keys
    }
}
