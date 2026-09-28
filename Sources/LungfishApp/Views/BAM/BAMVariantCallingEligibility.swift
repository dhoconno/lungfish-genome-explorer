import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

enum BAMVariantCallingEligibility {
    static func eligibleAlignmentTracks(in bundle: ReferenceBundle) -> [AlignmentTrackInfo] {
        bundle.alignmentTrackIds.compactMap { trackID in
            guard let track = bundle.alignmentTrack(id: trackID),
                  track.format == .bam,
                  (try? bundle.resolveAlignmentPath(track)) != nil,
                  (try? bundle.resolveAlignmentIndexPath(track)) != nil else {
                return nil
            }
            return track
        }
    }

    static func defaultTrackID(
        in eligibleAlignmentTracks: [AlignmentTrackInfo],
        preferredAlignmentTrackID: String?
    ) -> String {
        if let preferredAlignmentTrackID,
           eligibleAlignmentTracks.contains(where: { $0.id == preferredAlignmentTrackID }) {
            return preferredAlignmentTrackID
        }
        // After Mark Duplicates the bundle holds "<name> [unmarked]" first and
        // "<name> [dup-marked]" after it. Variant callers skip reads flagged
        // as duplicates, so the marked copy is the one to call from.
        guard let first = eligibleAlignmentTracks.first else { return "" }
        return duplicateMarkedCounterpart(of: first, in: eligibleAlignmentTracks)?.id ?? first.id
    }

    /// The "[dup-marked]" track Mark Duplicates made from `track` when
    /// `track` is its "[unmarked]" source, else nil.
    static func duplicateMarkedCounterpart(
        of track: AlignmentTrackInfo,
        in tracks: [AlignmentTrackInfo]
    ) -> AlignmentTrackInfo? {
        let unmarkedSuffix = AlignmentDuplicateService.unmarkedTrackNameSuffix
        let markedSuffix = AlignmentDuplicateService.markedTrackNameSuffix
        let name = track.name.trimmingCharacters(in: .whitespaces)
        guard name.hasSuffix(unmarkedSuffix) else { return nil }
        let baseName = name.dropLast(unmarkedSuffix.count).trimmingCharacters(in: .whitespaces)
        let markedTracks = tracks.filter {
            $0.id != track.id && $0.name.trimmingCharacters(in: .whitespaces).hasSuffix(markedSuffix)
        }
        if let exact = markedTracks.first(where: {
            $0.name.trimmingCharacters(in: .whitespaces)
                .dropLast(markedSuffix.count)
                .trimmingCharacters(in: .whitespaces) == baseName
        }) {
            return exact
        }
        // A renamed pair still sits side by side: one unmarked source with
        // one marked copy.
        let unmarkedCount = tracks.filter { $0.name.trimmingCharacters(in: .whitespaces).hasSuffix(unmarkedSuffix) }.count
        return unmarkedCount == 1 && markedTracks.count == 1 ? markedTracks[0] : nil
    }
}
