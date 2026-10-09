import CryptoKit
import Foundation
import Observation
import LungfishCore
import LungfishIO
import LungfishWorkflow

struct CallOverrideMutationResult: Equatable, Sendable {
    let didChange: Bool
    let changedKeys: Set<GenotypeEffectiveHaplotypeKey>
}
