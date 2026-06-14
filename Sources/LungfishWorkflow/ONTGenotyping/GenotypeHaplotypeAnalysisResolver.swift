import Foundation
import LungfishIO

public enum GenotypeHaplotypeAnalysisResolver {
    public static func resultByResolvingActiveAnalysis(
        for result: ONTGenotypeResultBundleData,
        bundleURL: URL? = nil,
        sidecar: GenotypeAnnotationSidecar?
    ) -> ONTGenotypeResultBundleData {
        guard let active = activeAnalysis(for: result, bundleURL: bundleURL, sidecar: sidecar),
              active != result.haplotypeAnalysis else {
            return result
        }
        return ONTGenotypeResultBundleData(
            bundleURL: result.bundleURL,
            manifest: result.manifest,
            artifacts: result.artifacts,
            stats: result.stats,
            calls: result.calls,
            samples: result.samples,
            haplotypeAnalysis: active
        )
    }

    public static func activeAnalysis(
        for result: ONTGenotypeResultBundleData,
        bundleURL: URL? = nil,
        sidecar: GenotypeAnnotationSidecar?
    ) -> GenotypeHaplotypeAnalysis? {
        if isPersistedRevisionAnalysis(result.haplotypeAnalysis) {
            return result.haplotypeAnalysis
        }
        guard let definitionSet = activeDefinitionSet(for: result, bundleURL: bundleURL, sidecar: sidecar) else {
            return result.haplotypeAnalysis
        }
        let settings = sidecar?.settings ?? .default
        let evaluator = GenotypeDropoutEvaluator(
            absolute: settings.dropoutAbsolute,
            sampleFraction: settings.dropoutSampleFraction,
            locusFraction: settings.dropoutLocusFraction,
            locusFractionOverrides: settings.locusFractionOverrides ?? [:]
        )
        return GenotypeHaplotypeAnalyzer.analyze(
            calls: result.calls,
            definitionSet: definitionSet,
            generatedAt: nil,
            dropoutFilter: evaluator
        )
    }

    public static func activeDefinitionSet(
        for result: ONTGenotypeResultBundleData,
        bundleURL: URL? = nil,
        sidecar: GenotypeAnnotationSidecar?
    ) -> GenotypeHaplotypeDefinitionSet? {
        let store = HaplotypeDefinitionStore(projectRoot: projectRoot(for: bundleURL ?? result.bundleURL))
        let registry = store.mergedRegistry()
        let candidates = [
            (sidecar?.settings.activeHaplotypeDefinitionSetID, sidecar?.settings.activeHaplotypeAssayID),
            (result.haplotypeAnalysis?.definitionSetID, result.haplotypeAnalysis?.assayID),
            (result.manifest.haplotypeDefinitionSetID, result.manifest.haplotypeAssayID),
        ]
        for candidate in candidates {
            guard let id = candidate.0?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty else { continue }
            if let definition = registry.definitionSet(id: id, assayID: candidate.1) {
                return definition
            }
        }
        return nil
    }

    public static func activeDefinitionFileURL(
        for result: ONTGenotypeResultBundleData,
        bundleURL: URL? = nil,
        sidecar: GenotypeAnnotationSidecar?
    ) -> URL? {
        guard let id = sidecar?.settings.activeHaplotypeDefinitionSetID else { return nil }
        let store = HaplotypeDefinitionStore(projectRoot: projectRoot(for: bundleURL ?? result.bundleURL))
        guard let url = store.definitionURL(for: id),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    private static func isPersistedRevisionAnalysis(_ analysis: GenotypeHaplotypeAnalysis?) -> Bool {
        guard let analysis else { return false }
        switch analysis.source {
        case .ai, .manual:
            return true
        case .legacy, .deterministic:
            return false
        }
    }

    private static func projectRoot(for bundleURL: URL) -> URL {
        bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
