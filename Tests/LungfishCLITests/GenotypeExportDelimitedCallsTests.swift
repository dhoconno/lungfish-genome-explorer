import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import XCTest
@testable import LungfishCLI

/// Finding SF2 of the Phase 2.3 design review. `genotype export` reports one
/// set of haplotype calls whatever the container format, so the H1 and H2
/// columns of its CSV and TSV matrix must equal the Effective H1 and H2 of
/// the workbook's Haplotype Calls sheet for the same bundle and sidecar.
final class GenotypeExportDelimitedCallsTests: XCTestCase {
    private let analysisTimestamp = "2026-09-12T00:00:00Z"

    // MARK: - Haplotyped MiSeq, identity-bound precedence

    /// An override stamped with the active analysis identity applies, one with
    /// no identity applies, one stamped for another analysis revision is stale
    /// and stays at the pipeline value, an explicit absent second haplotype is
    /// written as "-", and a manual assignment is ignored.
    func testTypedMiSeqDelimitedExportAppliesIdentityBoundOverridesLikeTheWorkbook() async throws {
        let scenario = miSeqScenario()
        let root = try temporaryDirectory(prefix: "genotype-delimited-miseq-typed")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(
            in: root,
            kind: GenotypeResultWorkflowKind.miSeqAmpliconMHCGenotype.rawValue,
            workflowKind: .miSeqAmpliconMHCGenotype,
            workflowMode: .haplotyped,
            analysis: scenario.analysis,
            sidecar: scenario.sidecar
        )
        try await assertDelimitedExports(of: bundle, equal: scenario.expected)
    }

    /// The legacy MiSeq shape, an `ont-barcode-genotype` manifest without
    /// workflow declarations whose analysis assay is the MiSeq exon 2 assay,
    /// takes the same identity-bound precedence as the typed manifest.
    func testLegacyMiSeqShapeDelimitedExportAppliesIdentityBoundOverridesLikeTheWorkbook() async throws {
        let scenario = miSeqScenario()
        let root = try temporaryDirectory(prefix: "genotype-delimited-miseq-legacy")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(
            in: root,
            kind: "ont-barcode-genotype",
            workflowKind: nil,
            workflowMode: nil,
            analysis: scenario.analysis,
            sidecar: scenario.sidecar
        )
        try await assertDelimitedExports(of: bundle, equal: scenario.expected)
    }

    // MARK: - ONT, legacy precedence

    /// The first stored override for a slot applies whatever identity it
    /// carries, and a manual assignment fills a slot no override names. A
    /// manual first haplotype on a one-haplotype call is repeated in H2, the
    /// homozygous convention every export follows.
    func testLegacyONTDelimitedExportAppliesOverridesAndManualAssignmentsLikeTheWorkbook() async throws {
        let scenario = ontScenario()
        let root = try temporaryDirectory(prefix: "genotype-delimited-ont-legacy")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(
            in: root,
            kind: "ont-barcode-genotype",
            workflowKind: nil,
            workflowMode: nil,
            analysis: scenario.analysis,
            sidecar: scenario.sidecar
        )
        try await assertDelimitedExports(of: bundle, equal: scenario.expected)
    }

    /// A typed full-length ONT manifest resolves under the same legacy
    /// precedence as the barcode shape.
    func testFullLengthONTDelimitedExportAppliesOverridesAndManualAssignmentsLikeTheWorkbook() async throws {
        let scenario = ontScenario()
        let root = try temporaryDirectory(prefix: "genotype-delimited-ont-full-length")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(
            in: root,
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            workflowKind: .fullLengthONTMHCGenotype,
            workflowMode: .haplotyped,
            analysis: scenario.analysis,
            sidecar: scenario.sidecar
        )
        try await assertDelimitedExports(of: bundle, equal: scenario.expected)
    }

    // MARK: - Genotype only

    /// A genotype-only result has no haplotype calls to resolve. Its table
    /// keeps allele names in H1 with H2 empty, as the user manual documents.
    func testGenotypeOnlyDelimitedExportKeepsAlleleNames() async throws {
        let root = try temporaryDirectory(prefix: "genotype-delimited-alleles")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(
            in: root,
            kind: GenotypeResultWorkflowKind.miSeqAmpliconMHCGenotype.rawValue,
            workflowKind: .miSeqAmpliconMHCGenotype,
            workflowMode: .genotypeOnly,
            analysis: nil,
            sidecar: .empty(generatedAt: analysisTimestamp),
            genotypes: ["Mafa-G_02:31:01:01|OR823640", "Mafa-DPA1_02:04|OR823641"]
        )
        let csv = root.appendingPathComponent("alleles.csv")
        _ = try await GenotypeExportSubcommand.parse([
            "--bundle", bundle.path,
            "--export-format", "csv",
            "--output", csv.path,
        ]).runReturningResolvedColumns(managedPythonResolver: {
            XCTFail("CSV must not resolve the XLSX runtime")
            throw CocoaError(.fileNoSuchFile)
        })
        XCTAssertEqual(
            try String(contentsOf: csv, encoding: .utf8),
            """
            Sample,MHC-DPA1 H1,MHC-DPA1 H2,MHC-G H1,MHC-G H2
            S1,Mafa-DPA1_02:04|OR823641,,Mafa-G_02:31:01:01|OR823640,
            S2,Mafa-DPA1_02:04|OR823641,,Mafa-G_02:31:01:01|OR823640,

            """
        )
    }

    // MARK: - Scenarios

    private struct Scenario {
        let analysis: GenotypeHaplotypeAnalysis
        let sidecar: GenotypeAnnotationSidecar
        let expected: [[String]]
    }

    /// Two samples at MHC-A and MHC-DR. The analysis is deterministic and
    /// persisted under revision `rev-current`, which the overrides name.
    private func miSeqScenario() -> Scenario {
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
        return Scenario(analysis: analysis, sidecar: sidecar, expected: [
            ["Sample", "MHC-A H1", "MHC-A H2", "MHC-DR H1", "MHC-DR H2"],
            ["S1", "M1A", "M2A", "M5", "M2"],
            ["S2", "M1A", "-", "M3", "M4"],
        ])
    }

    /// Two samples at MHC-A and MHC-B under an assay that is not the MiSeq
    /// exon 2 assay, so the legacy precedence applies.
    private func ontScenario() -> Scenario {
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
        return Scenario(analysis: analysis, sidecar: sidecar, expected: [
            ["Sample", "MHC-A H1", "MHC-A H2", "MHC-B H1", "MHC-B H2"],
            ["S1", "M6A", "M3A", "M1B", "M7B"],
            ["S2", "M8A", "M8A", "M3B", "M5B"],
        ])
    }

    // MARK: - Assertions

    /// Every mismatch of one bundle, thrown from the test method itself so the
    /// verdict reaches XCTest even when an issue recorded inside the export
    /// task does not.
    private struct DelimitedExportMismatch: Error, CustomStringConvertible {
        let details: [String]
        var description: String { details.joined(separator: "\n\n") }
    }

    /// Exports the bundle as CSV and as TSV, compares each file with the
    /// expected rows, and compares the cells with the workbook's Haplotype
    /// Calls for the same bundle and sidecar.
    private func assertDelimitedExports(
        of bundle: URL,
        equal expected: [[String]],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let workbook = try workbookCalls(of: bundle)
        var mismatches: [String] = []
        for (format, separator) in [("csv", ","), ("tsv", "\t")] {
            let output = bundle.deletingLastPathComponent().appendingPathComponent("matrix.\(format)")
            _ = try await GenotypeExportSubcommand.parse([
                "--bundle", bundle.path,
                "--export-format", format,
                "--output", output.path,
            ]).runReturningResolvedColumns(managedPythonResolver: {
                XCTFail("\(format) must not resolve the XLSX runtime")
                throw CocoaError(.fileNoSuchFile)
            })
            let text = try String(contentsOf: output, encoding: .utf8)
            let expectedText = expected.map { $0.joined(separator: separator) }.joined(separator: "\n") + "\n"
            XCTAssertEqual(text, expectedText, "\(format) matrix", file: file, line: line)
            if text != expectedText {
                mismatches.append("\(format) matrix\n\(text)is not\n\(expectedText)")
            }
            let cells = try delimitedCalls(in: text, separator: Character(separator))
            XCTAssertEqual(
                cells,
                workbook,
                "\(format) calls differ from the workbook's Haplotype Calls",
                file: file,
                line: line
            )
            if cells != workbook {
                mismatches.append("\(format) calls \(cells) differ from the workbook's Haplotype Calls \(workbook)")
            }
        }
        if !mismatches.isEmpty {
            throw DelimitedExportMismatch(details: mismatches)
        }
    }

    /// What the Haplotype Calls sheet reports for the bundle, keyed by sample
    /// then locus, as the effective H1 and H2 pair. The capture resolves the
    /// definition and analysis the way `genotype export --export-format xlsx`
    /// does, and the renderer writes these values verbatim.
    private func workbookCalls(of bundle: URL) throws -> [String: [String: [String]]] {
        let result = try ONTGenotypeResultBundle.loadResult(from: bundle)
        let sidecar = try ONTGenotypeResultBundleData
            .loadAnnotationSidecarSnapshot(forBundleAt: bundle).sidecar
        let snapshot = try GenotypeExcelSnapshotBuilder.capture(
            result: result,
            sidecar: sidecar,
            allProjection: nil,
            filteredProjection: nil,
            generatedAt: "2026-10-09T00:00:00Z"
        )
        var calls: [String: [String: [String]]] = [:]
        for call in snapshot.calls {
            calls[call.sampleID, default: [:]][call.locus] = [call.h1.effective, call.h2.effective]
        }
        return calls
    }

    /// The matrix cells keyed by sample then locus, as the H1 and H2 pair.
    private func delimitedCalls(in text: String, separator: Character) throws -> [String: [String: [String]]] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let header = try XCTUnwrap(lines.first)
            .split(separator: separator, omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(header.first, "Sample")
        let loci = stride(from: 1, to: header.count, by: 2).map { index in
            String(header[index].dropLast(" H1".count))
        }
        var calls: [String: [String: [String]]] = [:]
        for line in lines.dropFirst() {
            let fields = line.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(fields.count, header.count, String(line))
            var byLocus: [String: [String]] = [:]
            for (index, locus) in loci.enumerated() {
                byLocus[locus] = [fields[1 + 2 * index], fields[2 + 2 * index]]
            }
            calls[fields[0]] = byLocus
        }
        return calls
    }

    // MARK: - Fixtures

    private func locusCall(_ locus: String, _ first: String, _ second: String) -> GenotypeHaplotypeLocusCall {
        .init(
            locus: locus, sourceLocus: locus,
            haplotype1: first, haplotype2: second, status: .called,
            matchedHaplotypes: [], observedGenotypeCount: second == "-" ? 1 : 2,
            observedGenotypes: []
        )
    }

    private func override(
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

    /// A bundle on disk with two samples. The analysis, when given, is written
    /// under a definition set no registry resolves, so the persisted calls are
    /// the active analysis and the test controls the identity exactly.
    private func makeBundle(
        in root: URL,
        kind: String,
        workflowKind: GenotypeResultWorkflowKind?,
        workflowMode: GenotypeResultWorkflowMode?,
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
            kind: kind,
            workflowKind: workflowKind,
            workflowMode: workflowMode,
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

    private func temporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
