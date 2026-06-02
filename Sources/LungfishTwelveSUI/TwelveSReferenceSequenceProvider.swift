// TwelveSReferenceSequenceProvider.swift — lazy targetID → reference sequence lookup
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// A reference sequence for a single 12S target, surfaced in the Inspector
/// Detail tab so analysts can select/copy the bases that define a matched
/// species.
public struct TwelveSReferenceSequence: Equatable, Sendable {
    public let targetID: String
    public let sequence: String

    public init(targetID: String, sequence: String) {
        self.targetID = targetID
        self.sequence = sequence
    }
}

/// Resolves per-target reference sequences from a bundle's reference FASTA.
///
/// `TwelveSAmpliconTarget` does not carry sequence bases; they live in the
/// bundle's reference FASTA keyed by header. This provider reads that FASTA
/// once (lazily, on first lookup) and caches a `targetID → sequence` map.
///
/// It is safe to call ``sequences(forTargetIDs:)`` off the main actor: the
/// lazy load is guarded by an internal lock. A missing or unreadable FASTA
/// yields an empty map (no error surfaced to the UI).
public final class TwelveSReferenceSequenceProvider: @unchecked Sendable {
    private let referenceURL: URL
    private let lock = NSLock()
    private var cachedMap: [String: String]?

    public init(referenceURL: URL) {
        self.referenceURL = referenceURL
    }

    /// Returns the reference sequences for `targetIDs`, in the requested order,
    /// omitting any target not present in the reference FASTA.
    public func sequences(forTargetIDs targetIDs: [String]) -> [TwelveSReferenceSequence] {
        let map = loadedMap()
        return targetIDs.compactMap { id in
            map[id].map { TwelveSReferenceSequence(targetID: id, sequence: $0) }
        }
    }

    private func loadedMap() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let cachedMap { return cachedMap }
        let map = Self.readMap(from: referenceURL)
        cachedMap = map
        return map
    }

    private static func readMap(from url: URL) -> [String: String] {
        guard let reader = try? FASTAReader(url: url),
              let sequences = try? reader.readAllSync() else {
            return [:]
        }
        var map: [String: String] = [:]
        for sequence in sequences {
            // FASTA `name` excludes the leading '>'; the target ID is the first
            // whitespace-delimited token (anything after is a description).
            let targetID = sequence.name.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
                ?? sequence.name
            if map[targetID] == nil {
                map[targetID] = sequence.asString()
            }
        }
        return map
    }
}
