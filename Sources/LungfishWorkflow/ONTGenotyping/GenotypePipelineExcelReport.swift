import Foundation
import LungfishCore
import LungfishIO

/// Initial reports consume explicit scientific producer state before the success
/// manifest is published. Published-bundle loading/recovery is not part of capture.
enum GenotypePipelineExcelReport {
    static func write(
        physicalDirectory: URL, finalDirectory: URL, manifest: ONTGenotypeResultBundleManifest,
        analysis: GenotypeHaplotypeAnalysis?, definition: GenotypeHaplotypeDefinitionSet?,
        candidates: ONTMHCCandidateAllelesDocument? = nil,
        unnameable: ONTMHCUnnameableClustersDocument? = nil,
        catalog: GenotypeReviewableRowCatalog? = nil,
        python: URL, argv: [String], condaRoot: URL
    ) async throws -> GenotypeExcelExportService.ExportResult {
        func physical(_ path: String) -> URL { ONTGenotypeResultBundle.resolvedURL(for: path, in: physicalDirectory) }
        func final(_ path: String) -> URL { ONTGenotypeResultBundle.resolvedURL(for: path, in: finalDirectory) }
        // This writer-only overload uses the supplied manifest and does not run
        // published-bundle recovery or consult an on-disk success manifest.
        let loaded = try ONTGenotypeResultBundle.loadResult(from: physicalDirectory, manifest: manifest)
        func relocated(_ url: URL?) -> URL? {
            guard let url else { return nil }
            let prefix = physicalDirectory.standardizedFileURL.path + "/"
            guard url.path.hasPrefix(prefix) else { return url }
            return finalDirectory.appendingPathComponent(String(url.path.dropFirst(prefix.count)))
        }
        let result = ONTGenotypeResultBundleData(bundleURL: finalDirectory, manifest: manifest,
            artifacts: .init(workbookURL: final(manifest.primaryWorkbookPath),
                primaryWorkbookURL: final(manifest.primaryWorkbookPath),
                longSummaryCSVURL: final(manifest.longSummaryCSVPath), sampleSummaryCSVURL: final(manifest.sampleSummaryCSVPath),
                statsJSONURL: final(manifest.statsJSONPath), provenanceURL: final(manifest.provenancePath),
                haplotypeAnalysisURL: manifest.haplotypeAnalysisPath.map(final)),
            stats: loaded.stats, calls: loaded.calls, samples: loaded.samples,
            haplotypeAnalysis: analysis, mhcCandidates: candidates ?? loaded.mhcCandidates,
            mhcUnnameableClusters: unnameable ?? loaded.mhcUnnameableClusters,
            mhcCandidateSequencesByStableClusterID: loaded.mhcCandidateSequencesByStableClusterID,
            mhcCandidateGenBankArtifactURLs: .init(candidateAlleles: relocated(loaded.mhcCandidateGenBankArtifactURLs.candidateAlleles),
                unnameableClusters: relocated(loaded.mhcCandidateGenBankArtifactURLs.unnameableClusters),
                candidateFASTA: relocated(loaded.mhcCandidateGenBankArtifactURLs.candidateFASTA),
                unnameableFASTA: relocated(loaded.mhcCandidateGenBankArtifactURLs.unnameableFASTA),
                candidateEMBL: relocated(loaded.mhcCandidateGenBankArtifactURLs.candidateEMBL),
                unnameableEMBL: relocated(loaded.mhcCandidateGenBankArtifactURLs.unnameableEMBL)),
            mhcAlignmentArtifactURLs: .init(genotypingBAM: relocated(loaded.mhcAlignmentArtifactURLs.genotypingBAM),
                genotypingBAI: relocated(loaded.mhcAlignmentArtifactURLs.genotypingBAI),
                reciprocalBAM: relocated(loaded.mhcAlignmentArtifactURLs.reciprocalBAM),
                reciprocalBAI: relocated(loaded.mhcAlignmentArtifactURLs.reciprocalBAI)),
            mhcReferenceVisualizations: loaded.mhcReferenceVisualizations, integrityWarnings: loaded.integrityWarnings,
            referenceMetadata: loaded.referenceMetadata,
            provisionalExon2SequencesByGenotype: loaded.provisionalExon2SequencesByGenotype,
            provisionalExon2ArtifactURLs: .init(catalogJSON: relocated(loaded.provisionalExon2ArtifactURLs.catalogJSON),
                sequencesFASTA: relocated(loaded.provisionalExon2ArtifactURLs.sequencesFASTA)),
            reviewableRowCatalog: catalog ?? loaded.reviewableRowCatalog)
        let witnessedPaths = [manifest.longSummaryCSVPath, manifest.sampleSummaryCSVPath, manifest.statsJSONPath]
            + [manifest.haplotypeAnalysisPath].compactMap { $0 }
            + (definition == nil ? [] : ["artifacts/haplotyping/haplotype-definition.json"])
        let witnesses = try witnessedPaths.map { path in
            GenotypeExcelExportService.InputWitness(path: physical(path).path, data: try Data(contentsOf: physical(path)))
        }
        let generatedAt = ISO8601DateFormatter().string(from: Date())
        let snapshot = try GenotypeExcelSnapshotBuilder.capture(result: result, sidecar: .empty(generatedAt: generatedAt),
            allProjection: nil, filteredProjection: nil, generatedAt: generatedAt,
            authority: .init(analysis: analysis, definitionSet: definition, locusDisplayOrder: manifest.genotypeLocusDisplayOrder), filter: .unfiltered)
        let exported = try await GenotypeExcelExportService(pythonExecutableURL: python).export(snapshot: snapshot,
            outputURL: physical(manifest.primaryWorkbookPath), provenance: .init(
                workflowName: "genotype.pipeline.excel", toolVersion: WorkflowRun.currentAppVersion, argv: argv,
                options: ["filter": "unfiltered", "output": final(manifest.primaryWorkbookPath).path],
                defaults: ["filter": "unfiltered", "filteredEvidenceRowPolicy": GenotypeExcelSnapshotBuilder.filteredEvidenceRowPolicy],
                runtimeContext: ["condaEnvironment": "openpyxl", "condaPrefix": condaRoot.path],
                inputs: witnesses))
        if physicalDirectory.standardizedFileURL != finalDirectory.standardizedFileURL {
            try GenotypeExcelExportService.relocateReports(in: physicalDirectory, from: physicalDirectory, to: finalDirectory)
        }
        return exported
    }
}
