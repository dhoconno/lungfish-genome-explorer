import AppKit
import LungfishCore
import LungfishIO
import LungfishKit

struct GenotypeVisibleSampleAlleleDetail {
    let rowID: GenotypeCandidateMatrixRowID
    let stableClusterID: String?
    let sharedCall: ONTGenotypeSharedCall
    let support: ONTGenotypeSampleSupport
    let fraction: Double?
    let semantics: GenotypeVisibleSampleAlleleSemantics
}
