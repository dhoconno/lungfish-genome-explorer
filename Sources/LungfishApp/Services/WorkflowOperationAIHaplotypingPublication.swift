import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishKit

struct WorkflowOperationAIHaplotypingPublication: Sendable {
    let revision: ONTGenotypeHaplotypeAnalysisRevision
    let analysis: GenotypeHaplotypeAnalysis
    let provenanceURL: URL
}
