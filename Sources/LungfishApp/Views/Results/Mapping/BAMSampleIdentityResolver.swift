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
        let samples = canonicalByNormalizedValue.values.sorted().map { canonicalID in
            SampleIdentity(
                canonicalID: canonicalID,
                aliases: aliases[canonicalID] ?? [],
                alignmentTrackIDs: trackSampleIDs.compactMap { trackID, sampleID in
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
            unmatchedReadGroupIDs: unmatched
        )
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
