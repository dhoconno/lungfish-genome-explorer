import CryptoKit
import Foundation
import Observation
import LungfishCore
import LungfishIO
import LungfishWorkflow

struct CallOverrideMutation: Equatable, Sendable {
    let target: GenotypeEffectiveHaplotypeKey
    let baseline: String
    let after: String
    let reason: GenotypeAnnotationSidecar.OverrideReasonTag
    let rationale: String

    init(
        target: GenotypeEffectiveHaplotypeKey,
        baseline: String,
        after: String,
        reason: GenotypeAnnotationSidecar.OverrideReasonTag,
        rationale: String
    ) {
        self.target = target
        self.baseline = baseline
        self.after = after
        self.reason = reason
        self.rationale = rationale
    }
}
