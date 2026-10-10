import LungfishIO

extension GenotypeResultViewController {
    /// Reads matrix annotations saved at a full-length call's pre-N9
    /// pseudo-locus at the call's current locus. The stored sidecar keeps its
    /// targets as saved, and every edit writes at the current locus.
    var matrixTargetLocusAlias: GenotypeMatrixTargetLocusAlias {
        GenotypeMatrixTargetLocusAlias(calls: result?.calls ?? [])
    }
}
