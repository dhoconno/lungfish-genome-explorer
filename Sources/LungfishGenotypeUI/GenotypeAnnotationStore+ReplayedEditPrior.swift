import Foundation
import LungfishIO

extension GenotypeAnnotationStore {
    /// Makes sure the bundle holds the annotations.json that a replayed edit
    /// starts from. A call override and a manual haplotype replacement check
    /// their replay against the exact bytes of that file, and a bundle has none
    /// until its first edit, because opening it writes nothing. A genotype-only
    /// result has none when it leaves the workflow. When the file is missing, an
    /// edit that changes something publishes the sidecar the analyst sees first
    /// and then edits that file, and an edit that changes nothing gets false
    /// back so that it writes nothing.
    ///
    /// The record of that first edit therefore names, as its prior, the sidecar
    /// written just before it. For a genotype-only bundle that prior is the
    /// empty sidecar with the published file's generatedAt, and for a haplotyped
    /// bundle it also holds the built-in smart cohorts. The bundle as the
    /// workflow left it has no such file. The record embeds the prior's bytes
    /// in `replayPriorSidecarBase64`, so a replay with `lungfish-cli genotype
    /// replay-manual-haplotype-assignments` or `replay-call-overrides` starts
    /// from those bytes put back in place, as GenotypeManualHaplotypeFirstSaveTests
    /// shows for the post-save bundle.
    func preparePriorSidecarForReplay(changesSomething: Bool) throws -> Bool {
        let annotationURL = ONTGenotypeResultBundleData.annotationSidecarURL(forBundleAt: bundleURL)
        guard !FileManager.default.fileExists(atPath: annotationURL.path) else { return true }
        guard changesSomething else { return false }
        try publishViewedSidecar()
        return true
    }
}
