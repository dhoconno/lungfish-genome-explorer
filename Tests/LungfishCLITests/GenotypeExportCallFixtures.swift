import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishTestSupport

/// Fixtures shared by the delimited and the LabKey export tests, so every
/// genotype export is held to the same overrides, the same manual
/// assignments and the same workbook resolution (finding SF2).
enum GenotypeExportCallFixtures {
    static let analysisTimestamp = "2026-09-12T00:00:00Z"

    struct Scenario {
        let analysis: GenotypeHaplotypeAnalysis
        let sidecar: GenotypeAnnotationSidecar
        /// The effective H1 and H2 pair per sample and locus, what the
        /// workbook's Haplotype Calls sheet reports.
        let expectedCalls: [String: [String: [String]]]
    }

    /// The manifest a scenario is exported under.
    struct ManifestShape {
        let kind: String
        let workflowKind: GenotypeResultWorkflowKind?
        let workflowMode: GenotypeResultWorkflowMode?

        static let typedMiSeqHaplotyped = ManifestShape(
            kind: GenotypeResultWorkflowKind.miSeqAmpliconMHCGenotype.rawValue,
            workflowKind: .miSeqAmpliconMHCGenotype,
            workflowMode: .haplotyped
        )
        /// An `ont-barcode-genotype` manifest without workflow declarations.
        /// With the MiSeq exon 2 assay it is the legacy MiSeq shape, with any
        /// other assay it is a legacy ONT result.
        static let legacyBarcode = ManifestShape(
            kind: "ont-barcode-genotype",
            workflowKind: nil,
            workflowMode: nil
        )
        static let typedFullLengthONTHaplotyped = ManifestShape(
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            workflowKind: .fullLengthONTMHCGenotype,
            workflowMode: .haplotyped
        )
        static let typedMiSeqGenotypeOnly = ManifestShape(
            kind: GenotypeResultWorkflowKind.miSeqAmpliconMHCGenotype.rawValue,
            workflowKind: .miSeqAmpliconMHCGenotype,
            workflowMode: .genotypeOnly
        )
    }

    // MARK: - Scenarios

    /// Two samples at MHC-A and MHC-DR under the MiSeq exon 2 assay, so the
    /// identity-bound precedence applies. The analysis is deterministic and
    /// persisted under revision `rev-current`. An override stamped with that
    /// identity applies, one with no identity applies, one stamped
    /// `rev-previous` is stale and stays at the pipeline value, an explicit
    /// absent second haplotype is "-", and a manual assignment is ignored.
    static func miSeqScenario() -> Scenario {
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "fixture-definition",
            definitionSetName: "Fixture",
            speciesName: "Fixture",
            generatedAt: analysisTimestamp,
            analysisRevisionID: "rev-current",
            source: .deterministic,
            samples: [
                .init(sample: "S1", calls: [
                    locusCall("MHC-A", "M1A", "M3A"),
                    locusCall("MHC-DR", "M1", "M2"),
                ]),
                .init(sample: "S2", calls: [
                    locusCall("MHC-A", "M1A", "-"),
                    locusCall("MHC-DR", "M3", "M4"),
                ]),
            ]
        )
        let current = GenotypeAnnotationSidecar.CallOverrideAnalysisIdentity(
            assayID: analysis.assayID,
            analysisRevisionID: "rev-current",
            definitionSetID: analysis.definitionSetID
        )
        let previous = GenotypeAnnotationSidecar.CallOverrideAnalysisIdentity(
            assayID: analysis.assayID,
            analysisRevisionID: "rev-previous",
            definitionSetID: analysis.definitionSetID
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: analysisTimestamp)
        sidecar.callOverrides = [
            override("S1", "MHC-A", .h2, from: "M3A", to: "M2A", identity: current),
            override("S2", "MHC-DR", .h1, from: "M3", to: "M9", identity: previous),
            override("S2", "MHC-A", .h2, from: "-", to: "-", identity: nil),
            override("S1", "MHC-DR", .h1, from: "M1", to: "M5", identity: nil),
        ]
        sidecar.manualHaplotypeAssignments = [
            .init(sample: "S1", locus: "MHC-DR", slot: .h2, label: "M8",
                  colorTokenIndex: 1, diagnosticAlleles: [], notes: "ignored for MiSeq"),
        ]
        return Scenario(analysis: analysis, sidecar: sidecar, expectedCalls: [
            "S1": ["MHC-A": ["M1A", "M2A"], "MHC-DR": ["M5", "M2"]],
            "S2": ["MHC-A": ["M1A", "-"], "MHC-DR": ["M3", "M4"]],
        ])
    }

    /// Two samples at MHC-A and MHC-B under an assay that is not the MiSeq
    /// exon 2 assay, so the legacy precedence applies. The first stored
    /// override for a slot applies whatever identity it carries, and a manual
    /// assignment fills a slot no override names. A manual first haplotype on
    /// a one-haplotype call is repeated in H2, the homozygous convention
    /// every export follows.
    static func ontScenario() -> Scenario {
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-ONT-fixture",
            definitionSetID: "fixture-definition",
            definitionSetName: "Fixture",
            speciesName: "Fixture",
            generatedAt: analysisTimestamp,
            samples: [
                .init(sample: "S1", calls: [
                    locusCall("MHC-A", "M1A", "M3A"),
                    locusCall("MHC-B", "M1B", "M2B"),
                ]),
                .init(sample: "S2", calls: [
                    locusCall("MHC-A", "M4A", "-"),
                    locusCall("MHC-B", "M3B", "M5B"),
                ]),
            ]
        )
        let mismatched = GenotypeAnnotationSidecar.CallOverrideAnalysisIdentity(
            assayID: analysis.assayID,
            analysisRevisionID: "rev-previous",
            definitionSetID: analysis.definitionSetID
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: analysisTimestamp)
        sidecar.callOverrides = [
            override("S1", "MHC-A", .h1, from: "M1A", to: "M6A", identity: mismatched),
        ]
        sidecar.manualHaplotypeAssignments = [
            .init(sample: "S1", locus: "MHC-B", slot: .h2, label: "M7B",
                  colorTokenIndex: 2, diagnosticAlleles: [], notes: ""),
            .init(sample: "S2", locus: "MHC-A", slot: .h1, label: "M8A",
                  colorTokenIndex: 3, diagnosticAlleles: [], notes: ""),
        ]
        return Scenario(analysis: analysis, sidecar: sidecar, expectedCalls: [
            "S1": ["MHC-A": ["M6A", "M3A"], "MHC-B": ["M1B", "M7B"]],
            "S2": ["MHC-A": ["M8A", "M8A"], "MHC-B": ["M3B", "M5B"]],
        ])
    }

    // MARK: - The workbook's view of a bundle

    /// What the Haplotype Calls sheet reports for the bundle on disk. The
    /// capture resolves the definition and analysis the way `genotype export
    /// --export-format xlsx` does, and the renderer writes these values
    /// verbatim.
    static func workbookCalls(of bundle: URL) throws -> [GenotypeWorkbookPresentation.Call] {
        let result = try ONTGenotypeResultBundle.loadResult(from: bundle)
        let sidecar = try ONTGenotypeResultBundleData
            .loadAnnotationSidecarSnapshot(forBundleAt: bundle).sidecar
        return try GenotypeExcelSnapshotBuilder.capture(
            result: result,
            sidecar: sidecar,
            allProjection: nil,
            filteredProjection: nil,
            generatedAt: "2026-10-09T00:00:00Z"
        ).calls
    }

    /// The effective H1 and H2 pair per sample and locus.
    static func effectivePairs(_ calls: [GenotypeWorkbookPresentation.Call]) -> [String: [String: [String]]] {
        var pairs: [String: [String: [String]]] = [:]
        for call in calls {
            pairs[call.sampleID, default: [:]][call.locus] = [call.h1.effective, call.h2.effective]
        }
        return pairs
    }

    // MARK: - Bundle on disk

    /// A bundle with two samples. The analysis, when given, is written under
    /// a definition set no registry resolves, so the persisted calls are the
    /// active analysis and the scenario controls the identity exactly.
    static func makeBundle(
        in root: URL,
        shape: ManifestShape,
        analysis: GenotypeHaplotypeAnalysis?,
        sidecar: GenotypeAnnotationSidecar,
        genotypes: [String] = ["01_M1A_A1_063", "02_M3A_A2_010"]
    ) throws -> URL {
        let bundle = root.appendingPathComponent("fixture.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let workbook = bundle.appendingPathComponent("source.xlsx")
        let calls = bundle.appendingPathComponent("calls.csv")
        let samples = bundle.appendingPathComponent("samples.csv")
        let stats = bundle.appendingPathComponent("stats.json")
        let provenance = bundle.appendingPathComponent("provenance.json")
        let analysisURL = bundle.appendingPathComponent("haplotypes.json")
        try Data("not a workbook and never an XLSX input".utf8).write(to: workbook)
        try Data("{}".utf8).write(to: provenance)
        var callRows = [
            "sample,genotype,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_reads,overall_unique_retained_percent",
        ]
        for sample in ["S1", "S2"] {
            for genotype in genotypes {
                callRows.append("\(sample),\(genotype),40,40,100,80,80.0,1000,160,16.0")
            }
        }
        try callRows.joined(separator: "\n").write(to: calls, atomically: true, encoding: .utf8)
        try """
        sample,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_percent
        S1,80,80,100,80.0,1000,16.0
        S2,80,80,100,80.0,1000,16.0
        """.write(to: samples, atomically: true, encoding: .utf8)
        try Data(#"{"totalInputReads":1000,"totalAlignments":160,"passedAlignments":160,"retainedUniqueReads":160,"retainedUniquePercentOfTotalReads":16.0,"assignedUniqueRetainedReads":160,"unassignedUniqueRetainedReads":0}"#.utf8).write(to: stats)
        if let analysis {
            try JSONEncoder().encode(analysis).write(to: analysisURL)
        }
        let manifest = ONTGenotypeResultBundleManifest(
            kind: shape.kind,
            workflowKind: shape.workflowKind,
            workflowMode: shape.workflowMode,
            outputName: "fixture",
            analysisName: "Fixture",
            primaryWorkbookPath: workbook.lastPathComponent,
            longSummaryCSVPath: calls.lastPathComponent,
            sampleSummaryCSVPath: samples.lastPathComponent,
            statsJSONPath: stats.lastPathComponent,
            provenancePath: provenance.lastPathComponent,
            haplotypeAnalysisPath: analysis == nil ? nil : analysisURL.lastPathComponent,
            haplotypeDefinitionSetID: analysis?.definitionSetID,
            createdAt: analysisTimestamp
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundle)
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(sidecar, forBundleAt: bundle)
        return bundle
    }

    // MARK: - Pieces

    private static func locusCall(_ locus: String, _ first: String, _ second: String) -> GenotypeHaplotypeLocusCall {
        .init(
            locus: locus, sourceLocus: locus,
            haplotype1: first, haplotype2: second, status: .called,
            matchedHaplotypes: [], observedGenotypeCount: second == "-" ? 1 : 2,
            observedGenotypes: []
        )
    }

    private static func override(
        _ sample: String,
        _ locus: String,
        _ slot: HaplotypeSlot,
        from original: String,
        to replacement: String,
        identity: GenotypeAnnotationSidecar.CallOverrideAnalysisIdentity?
    ) -> GenotypeAnnotationSidecar.CallOverride {
        .init(
            sample: sample, locus: locus, slot: slot,
            originalCall: original, overrideCall: replacement,
            reasonTag: .analystJudgment, rationale: "fixture", author: "analyst",
            timestamp: "2026-09-13T00:00:00Z",
            analysisIdentity: identity, operationID: nil
        )
    }
}
