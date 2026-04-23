import Foundation
import LungfishCore
import LungfishIO

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
        in bundle: ReferenceBundle,
        preferredAlignmentTrackID: String?
    ) -> String {
        let eligible = eligibleAlignmentTracks(in: bundle)
        if let preferredAlignmentTrackID,
           eligible.contains(where: { $0.id == preferredAlignmentTrackID }) {
            return preferredAlignmentTrackID
        }
        return eligible.first?.id ?? ""
    }
}
