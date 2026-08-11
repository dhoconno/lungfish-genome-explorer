// BAMSampleIdentityResolver.swift - Persisted BAM sample identity resolution
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishIO
import LungfishKit

/// Builds the explicit sample identity index used by BAM-bearing viewports.
///
/// Read-group `SM` values are the only source of canonical identities.  Track
/// identifiers and aliases are included only when their mapping is persisted
/// by the owning result; paths and filenames never participate in resolution.
struct BAMSampleIdentityResolver {
    struct Resolution {
        let identityIndex: SampleIdentityIndex
        let identities: [SampleIdentity]
        let unmatchedReadGroupIDs: Set<String>
    }

    static func resolve(
        readGroups: [AlignmentMetadataDatabase.ReadGroupRecord],
        trackIDs: [String],
        explicitResultSampleID: String? = nil,
        aliases: [String: [String]] = [:],
        trackSampleIDs: [String: String] = [:]
    ) throws -> Resolution {
        var readGroupsBySample: [String: [String]] = [:]
        var canonicalByNormalizedValue: [String: String] = [:]
        var unmatched = Set<String>()

        for group in readGroups {
            guard let sample = nonEmpty(group.sample) else {
                unmatched.insert(group.id)
                continue
            }
            let key = normalized(sample)
            // The first persisted spelling is kept as the canonical value;
            // the identity index handles case-insensitive comparison.
            let canonical = canonicalByNormalizedValue[key] ?? sample
            canonicalByNormalizedValue[key] = canonical
            readGroupsBySample[canonical, default: []].append(group.id)
        }

        if readGroupsBySample.isEmpty, let fallback = nonEmpty(explicitResultSampleID) {
            canonicalByNormalizedValue[normalized(fallback)] = fallback
            readGroupsBySample[fallback] = []
        }

        let knownTrackIDs = Set(trackIDs)
        let singleResolvedSample = canonicalByNormalizedValue.count == 1
        let samples = canonicalByNormalizedValue.values.sorted().map { canonicalID in
            SampleIdentity(
                canonicalID: canonicalID,
                aliases: aliases[canonicalID] ?? [],
                alignmentTrackIDs: singleResolvedSample
                    ? knownTrackIDs.sorted()
                    : trackSampleIDs.compactMap { trackID, sampleID in
                        knownTrackIDs.contains(trackID) && normalized(sampleID) == normalized(canonicalID)
                            ? trackID : nil
                    },
                readGroupIDs: readGroupsBySample[canonicalID] ?? []
            )
        }
        let fallback = readGroups.isEmpty ? explicitResultSampleID : nil
        return Resolution(
            identityIndex: try SampleIdentityIndex(
                samples: samples,
                explicitOneSampleFallbackCanonicalID: fallback
            ),
            identities: samples,
            unmatchedReadGroupIDs: unmatched
        )
    }

    /// Merges identities from independent alignment tracks. The persisted SM
    /// spelling first encountered is retained for display, while grouping uses
    /// the same trim/case-fold key as `SampleIdentityIndex`. Explicit aliases
    /// are accepted only through `aliases`; alternate SM spellings are not
    /// promoted to aliases because they already resolve through the canonical
    /// normalized identity and were not authored as alias metadata.
    static func merge(
        _ identities: [SampleIdentity],
        aliases: [String: [String]] = [:]
    ) -> [SampleIdentity] {
        var mergedByKey: [String: SampleIdentity] = [:]
        for identity in identities {
            let key = normalized(identity.canonicalID)
            guard !key.isEmpty else { continue }
            if let current = mergedByKey[key] {
                mergedByKey[key] = SampleIdentity(
                    canonicalID: current.canonicalID,
                    aliases: Array(Set(current.aliases).union(identity.aliases)).sorted(),
                    alignmentTrackIDs: Array(Set(current.alignmentTrackIDs).union(identity.alignmentTrackIDs)).sorted(),
                    readGroupIDs: Array(Set(current.readGroupIDs).union(identity.readGroupIDs)).sorted()
                )
            } else {
                mergedByKey[key] = identity
            }
        }

        return mergedByKey.values.map { identity in
            let explicitAliases = aliases.first { normalized($0.key) == normalized(identity.canonicalID) }?.value ?? []
            return SampleIdentity(
                canonicalID: identity.canonicalID,
                aliases: Array(Set(identity.aliases).union(explicitAliases)).sorted(),
                alignmentTrackIDs: identity.alignmentTrackIDs,
                readGroupIDs: identity.readGroupIDs
            )
        }.sorted { $0.canonicalID.localizedCaseInsensitiveCompare($1.canonicalID) == .orderedAscending }
    }

    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
