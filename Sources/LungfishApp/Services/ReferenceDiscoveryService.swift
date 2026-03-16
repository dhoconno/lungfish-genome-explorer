// ReferenceDiscoveryService.swift - Reference sequence discovery for operation panels
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import os.log

private let logger = Logger(subsystem: "com.lungfish.browser", category: "ReferenceDiscoveryService")

/// Discovers and caches reference sequence candidates for a project.
///
/// Used by operation configuration panels (orient, contaminant filter, primer removal)
/// to populate reference dropdowns. Caches scan results and invalidates on project
/// directory changes.
///
/// Progress reported via `DispatchQueue.main.async { MainActor.assumeIsolated { } }`
/// pattern — never `Task { @MainActor in }`.
@MainActor
public final class ReferenceDiscoveryService {

    /// Cached candidates, grouped by source category.
    public private(set) var candidates: [ReferenceCandidate] = []

    /// Whether a scan is currently in progress.
    public private(set) var isScanning = false

    /// The project URL being scanned.
    public private(set) var projectURL: URL?

    /// Last-used reference per operation kind (persisted in UserDefaults).
    private var lastUsedReferences: [String: String] = [:]

    private static let lastUsedDefaultsKey = "ReferenceDiscoveryLastUsed"

    public init() {
        loadLastUsedFromDefaults()
    }

    // MARK: - Scanning

    /// Scans the project directory for reference candidates.
    ///
    /// Results replace the current cache. Safe to call multiple times;
    /// a new scan cancels any in-progress scan.
    public func scan(projectURL: URL) async {
        self.projectURL = projectURL
        isScanning = true
        candidates = []

        let results = await Task.detached {
            ReferenceSequenceScanner.scanAll(in: projectURL)
        }.value

        candidates = results
        isScanning = false

        logger.info("Reference scan complete: \(results.count) candidates in \(projectURL.lastPathComponent)")
    }

    /// Returns candidates filtered to a specific source category.
    public func candidates(for category: ReferenceCandidate.SourceCategory) -> [ReferenceCandidate] {
        candidates.filter { $0.sourceCategory == category }
    }

    /// Returns candidates grouped by source category, preserving sort order.
    public var groupedCandidates: [(category: ReferenceCandidate.SourceCategory, candidates: [ReferenceCandidate])] {
        var groups: [ReferenceCandidate.SourceCategory: [ReferenceCandidate]] = [:]
        for candidate in candidates {
            groups[candidate.sourceCategory, default: []].append(candidate)
        }
        return ReferenceCandidate.SourceCategory.allCases
            .compactMap { category in
                guard let items = groups[category], !items.isEmpty else { return nil }
                return (category, items)
            }
    }

    // MARK: - Last-Used Reference

    /// Records the last-used reference for an operation kind.
    public func recordLastUsed(_ candidate: ReferenceCandidate, for operationKind: String) {
        lastUsedReferences[operationKind] = candidate.id
        saveLastUsedToDefaults()
    }

    /// Returns the last-used reference for an operation kind, if still available.
    public func lastUsedCandidate(for operationKind: String) -> ReferenceCandidate? {
        guard let id = lastUsedReferences[operationKind] else { return nil }
        return candidates.first { $0.id == id }
    }

    // MARK: - Persistence

    private func loadLastUsedFromDefaults() {
        if let dict = UserDefaults.standard.dictionary(forKey: Self.lastUsedDefaultsKey) as? [String: String] {
            lastUsedReferences = dict
        }
    }

    private func saveLastUsedToDefaults() {
        UserDefaults.standard.set(lastUsedReferences, forKey: Self.lastUsedDefaultsKey)
    }
}
