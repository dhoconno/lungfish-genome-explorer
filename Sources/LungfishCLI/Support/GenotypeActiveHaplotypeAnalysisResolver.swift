import Foundation
import LungfishIO
import LungfishWorkflow

enum GenotypeActiveHaplotypeAnalysisResolver {
    static func activeAnalysis(
        for result: ONTGenotypeResultBundleData,
        bundleURL: URL? = nil,
        sidecar: GenotypeAnnotationSidecar?
    ) -> GenotypeHaplotypeAnalysis? {
        GenotypeHaplotypeAnalysisResolver.activeAnalysis(for: result, bundleURL: bundleURL, sidecar: sidecar)
    }

    static func activeDefinitionSet(
        for result: ONTGenotypeResultBundleData,
        bundleURL: URL? = nil,
        sidecar: GenotypeAnnotationSidecar?
    ) -> GenotypeHaplotypeDefinitionSet? {
        GenotypeHaplotypeAnalysisResolver.activeDefinitionSet(for: result, bundleURL: bundleURL, sidecar: sidecar)
    }

    static func activeDefinitionFileURL(
        for result: ONTGenotypeResultBundleData,
        bundleURL: URL? = nil,
        sidecar: GenotypeAnnotationSidecar?
    ) -> URL? {
        GenotypeHaplotypeAnalysisResolver.activeDefinitionFileURL(for: result, bundleURL: bundleURL, sidecar: sidecar)
    }
}
