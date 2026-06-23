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
        let evaluator = hasRunHaplotypeDropoutMetrics(result)
            ? runHaplotypeDropoutEvaluator(for: result)
            : sidecarHaplotypeDropoutEvaluator(sidecar: sidecar)
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
        return bundleDefinitionSnapshot(for: bundleURL ?? result.bundleURL)
    }

    public static func activeDefinitionFileURL(
        for result: ONTGenotypeResultBundleData,
        bundleURL: URL? = nil,
        sidecar: GenotypeAnnotationSidecar?
    ) -> URL? {
        guard let id = sidecar?.settings.activeHaplotypeDefinitionSetID else {
            return bundleDefinitionSnapshotURL(for: bundleURL ?? result.bundleURL)
        }
        let store = HaplotypeDefinitionStore(projectRoot: projectRoot(for: bundleURL ?? result.bundleURL))
        guard let url = store.definitionURL(for: id),
              FileManager.default.fileExists(atPath: url.path) else {
            return bundleDefinitionSnapshotURL(for: bundleURL ?? result.bundleURL)
        }
        return url
    }

    public static func bundleDefinitionSnapshot(
        for bundleURL: URL
    ) -> GenotypeHaplotypeDefinitionSet? {
        guard let url = bundleDefinitionSnapshotURL(for: bundleURL),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(GenotypeHaplotypeDefinitionSet.self, from: data)
    }

    public static func bundleDefinitionSnapshotURL(for bundleURL: URL) -> URL? {
        let candidates = [
            bundleURL
                .appendingPathComponent(".amplicon-genotyping", isDirectory: true)
                .appendingPathComponent("inputs", isDirectory: true)
                .appendingPathComponent("haplotype-definition.json"),
            bundleURL
                .appendingPathComponent(".ont-barcode-genotyping", isDirectory: true)
                .appendingPathComponent("inputs", isDirectory: true)
                .appendingPathComponent("haplotype-definition.json"),
            bundleURL
                .appendingPathComponent(".full-length-ont-mhc", isDirectory: true)
                .appendingPathComponent("inputs", isDirectory: true)
                .appendingPathComponent("haplotype-definition.json"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func runHaplotypeDropoutEvaluator(
        for result: ONTGenotypeResultBundleData
    ) -> GenotypeDropoutEvaluator? {
        let metrics = result.stats.rawMetrics
        let absolute = intMetric(metrics["minSupport"]).flatMap { $0 > 1 ? $0 : nil }
        let sampleFraction = percentMetric(metrics["haplotypeMinSamplePercent"])
        let locusFraction = percentMetric(metrics["haplotypeMinLocusPercent"])
        let overrides = locusPercentOverridesMetric(metrics["haplotypeMinLocusPercentOverrides"])
        guard absolute != nil || sampleFraction != nil || locusFraction != nil || !overrides.isEmpty else {
            return nil
        }
        return GenotypeDropoutEvaluator(
            absolute: absolute,
            sampleFraction: sampleFraction,
            locusFraction: locusFraction,
            locusFractionOverrides: overrides
        )
    }

    private static func hasRunHaplotypeDropoutMetrics(_ result: ONTGenotypeResultBundleData) -> Bool {
        let metrics = result.stats.rawMetrics
        return metrics["minSupport"] != nil
            || metrics["haplotypeMinSamplePercent"] != nil
            || metrics["haplotypeMinLocusPercent"] != nil
            || metrics["haplotypeMinLocusPercentOverrides"] != nil
    }

    private static func sidecarHaplotypeDropoutEvaluator(
        sidecar: GenotypeAnnotationSidecar?
    ) -> GenotypeDropoutEvaluator? {
        let settings = sidecar?.settings ?? .default
        return GenotypeDropoutEvaluator(
            absolute: settings.dropoutAbsolute,
            sampleFraction: settings.dropoutSampleFraction,
            locusFraction: settings.dropoutLocusFraction,
            locusFractionOverrides: settings.locusFractionOverrides ?? [:]
        )
    }

    private static func intMetric(_ value: String?) -> Int? {
        guard let number = doubleMetric(value) else { return nil }
        return Int(number)
    }

    private static func percentMetric(_ value: String?) -> Double? {
        guard let number = doubleMetric(value), number > 0 else { return nil }
        return number > 1 ? number / 100.0 : number
    }

    private static func doubleMetric(_ value: String?) -> Double? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return Double(value)
    }

    private static func locusPercentOverridesMetric(_ value: String?) -> [String: Double] {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value != "[]" else {
            return [:]
        }
        if let data = value.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: Double].self, from: data) {
            return decoded.compactMapValues { percentMetric(String($0)) }
        }
        return [:]
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
