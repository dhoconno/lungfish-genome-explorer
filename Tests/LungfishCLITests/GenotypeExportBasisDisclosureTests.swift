import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishTestSupport
import XCTest
@testable import LungfishCLI

/// Decision D3 of the Phase 2.3 follow-up. When a bundle declares candidate
/// artifacts that the loader rejected, its locus percents and haplotype calls
/// count known alleles only, and every genotype export says so once on
/// standard error. A bundle whose candidate artifacts loaded, or that
/// declares none, prints nothing.
final class GenotypeExportBasisDisclosureTests: XCTestCase {
    private static let disclosure =
        "Candidate files failed validation, so candidate alleles are hidden and locus percents and "
        + "haplotype calls count known-allele reads only. These values can differ from the run's own workbook."

    private static var managedPythonURL: URL? {
        let root = FileManager.default.homeDirectoryForCurrentUser
        return [".lungfish", ".lungfish-debug"]
            .map { root.appendingPathComponent("\($0)/conda/envs/openpyxl/bin/python") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: The one line

    func testLineIsTheSharedDisclosureOnlyForARejectedCandidateBasis() throws {
        let root = try TestTempDirectory.make(prefix: "basis-disclosure-line")
        defer { TestTempDirectory.cleanup(root) }
        let rejected = try ONTGenotypeResultBundle.loadResult(from: makeBundle(in: root, rejectedCandidates: true))
        XCTAssertEqual(GenotypeExportBasisDisclosure.line(for: rejected), Self.disclosure)
        XCTAssertEqual(GenotypeExportBasisDisclosure.line(for: rejected), GenotypeLocusDenominator.rejectedCandidateArtifactsDisclosure)

        let validatedRoot = try TestTempDirectory.make(prefix: "basis-disclosure-line-normal")
        defer { TestTempDirectory.cleanup(validatedRoot) }
        let validated = try ONTGenotypeResultBundle.loadResult(from: makeBundle(in: validatedRoot, rejectedCandidates: false))
        XCTAssertNil(GenotypeExportBasisDisclosure.line(for: validated))
        XCTAssertNil(GenotypeExportBasisDisclosure.line(for: nil), "an export with no loadable result has nothing to say")
    }

    // MARK: export, csv and tsv

    func testDelimitedExportSaysOnStderrThatTheBasisIsKnownAllelesOnly() async throws {
        let root = try TestTempDirectory.make(prefix: "basis-disclosure-csv")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try makeBundle(in: root, rejectedCandidates: true)
        let output = root.appendingPathComponent("matrix.csv")

        let stderr = try await capturingStandardError(in: root) {
            _ = try await GenotypeExportSubcommand.parse([
                "--bundle", bundle.path, "--export-format", "csv", "--output", output.path,
            ]).runReturningResolvedColumns(managedPythonResolver: {
                XCTFail("CSV must not resolve the XLSX runtime")
                throw CocoaError(.fileNoSuchFile)
            })
        }

        XCTAssertEqual(occurrences(of: Self.disclosure, in: stderr), 1, stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testDelimitedExportOfAValidatedBundleSaysNothing() async throws {
        let root = try TestTempDirectory.make(prefix: "basis-disclosure-csv-normal")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try makeBundle(in: root, rejectedCandidates: false)
        let output = root.appendingPathComponent("matrix.tsv")

        let stderr = try await capturingStandardError(in: root) {
            _ = try await GenotypeExportSubcommand.parse([
                "--bundle", bundle.path, "--export-format", "tsv", "--output", output.path,
            ]).runReturningResolvedColumns(managedPythonResolver: {
                XCTFail("TSV must not resolve the XLSX runtime")
                throw CocoaError(.fileNoSuchFile)
            })
        }

        XCTAssertEqual(occurrences(of: Self.disclosure, in: stderr), 0, stderr)
        XCTAssertFalse(stderr.contains("known-allele"), stderr)
    }

    // MARK: export-labkey

    func testLabKeyExportSaysOnStderrThatTheBasisIsKnownAllelesOnly() async throws {
        let root = try TestTempDirectory.make(prefix: "basis-disclosure-labkey")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try makeBundle(in: root, rejectedCandidates: true)
        let outputDir = root.appendingPathComponent("labkey", isDirectory: true)

        let stderr = try await capturingStandardError(in: root) {
            try await GenotypeExportLabKeySubcommand.parse([
                "--bundle", bundle.path, "--output-dir", outputDir.path,
            ]).run()
        }

        XCTAssertEqual(occurrences(of: Self.disclosure, in: stderr), 1, stderr)
    }

    func testLabKeyExportOfAValidatedBundleSaysNothing() async throws {
        let root = try TestTempDirectory.make(prefix: "basis-disclosure-labkey-normal")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try makeBundle(in: root, rejectedCandidates: false)
        let outputDir = root.appendingPathComponent("labkey", isDirectory: true)

        let stderr = try await capturingStandardError(in: root) {
            try await GenotypeExportLabKeySubcommand.parse([
                "--bundle", bundle.path, "--output-dir", outputDir.path,
            ]).run()
        }

        XCTAssertEqual(occurrences(of: Self.disclosure, in: stderr), 0, stderr)
    }

    // MARK: export-xlsx and export-pivot-xlsx

    func testXlsxExportSaysOnStderrThatTheBasisIsKnownAllelesOnly() async throws {
        guard let python = Self.managedPythonURL else {
            throw XCTSkip("The managed openpyxl Python is not installed on this Mac.")
        }
        let root = try TestTempDirectory.make(prefix: "basis-disclosure-xlsx")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try makeBundle(in: root, rejectedCandidates: true)
        let output = root.appendingPathComponent("workbook.xlsx")

        let stderr = try await capturingStandardError(in: root) {
            try await GenotypeExportXlsxSubcommand.parse([
                "--bundle", bundle.path, "--output", output.path,
            ]).run(managedPythonResolver: { python })
        }

        XCTAssertEqual(occurrences(of: Self.disclosure, in: stderr), 1, stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testPivotXlsxExportSaysOnStderrThatTheBasisIsKnownAllelesOnly() async throws {
        guard let python = Self.managedPythonURL else {
            throw XCTSkip("The managed openpyxl Python is not installed on this Mac.")
        }
        let root = try TestTempDirectory.make(prefix: "basis-disclosure-pivot")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try makeBundle(in: root, rejectedCandidates: true)
        let output = root.appendingPathComponent("pivot.xlsx")

        let stderr = try await capturingStandardError(in: root) {
            try await GenotypeExportPivotXlsxSubcommand.parse([
                "--bundle", bundle.path, "--output", output.path,
            ]).run(managedPythonResolver: { python })
        }

        XCTAssertEqual(occurrences(of: Self.disclosure, in: stderr), 1, stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    // MARK: Fixture

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// A full-length haplotyped bundle of two animals. With `rejectedCandidates`
    /// the manifest declares a candidate JSON and FASTA pair whose files are
    /// present with other bytes than the declared digests, so the loader
    /// rejects them with a checksum warning and loads no candidate document.
    private func makeBundle(in root: URL, rejectedCandidates: Bool) throws -> URL {
        let bundle = root.appendingPathComponent("fixture.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let workbook = bundle.appendingPathComponent("fixture.xlsx")
        let calls = bundle.appendingPathComponent("fixture.calls.csv")
        let samples = bundle.appendingPathComponent("fixture.samples.csv")
        let stats = bundle.appendingPathComponent("fixture.stats.json")
        let provenance = bundle.appendingPathComponent("fixture.provenance.json")
        let analysisURL = bundle.appendingPathComponent("fixture.haplotype-analysis.json")
        try Data("not a workbook".utf8).write(to: workbook)
        try Data("{}".utf8).write(to: provenance)
        try """
        sample,genotype,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_reads,overall_unique_retained_percent
        S1,A_marker|source_loci=MHC-A|haplotype_groups=MHC-A,150,150,200,155,77.5,1000,175,17.5
        S1,B_marker|source_loci=MHC-A|haplotype_groups=MHC-A,5,5,200,155,77.5,1000,175,17.5
        S2,A_marker|source_loci=MHC-A|haplotype_groups=MHC-A,20,20,80,20,25.0,1000,175,17.5
        """.write(to: calls, atomically: true, encoding: .utf8)
        try """
        sample,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_percent
        S1,155,155,200,77.5,1000,17.5
        S2,20,20,80,25.0,1000,17.5
        """.write(to: samples, atomically: true, encoding: .utf8)
        try Data(#"{"totalInputReads":1000,"totalAlignments":175,"passedAlignments":175,"retainedUniqueReads":175,"retainedUniquePercentOfTotalReads":17.5,"assignedUniqueRetainedReads":175,"unassignedUniqueRetainedReads":0}"#.utf8).write(to: stats)
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "basis-disclosure-assay",
            definitionSetID: "basis-disclosure-definitions",
            definitionSetName: "Basis disclosure",
            speciesName: "Test species",
            generatedAt: "2026-10-09T00:00:00Z",
            samples: [
                .init(sample: "S1", calls: [
                    .init(
                        locus: "MHC-A", sourceLocus: "MHC-A",
                        haplotype1: "M-A", haplotype2: "M-B", status: .called,
                        matchedHaplotypes: [], observedGenotypeCount: 2,
                        observedGenotypes: ["A_marker", "B_marker"]
                    ),
                ]),
                .init(sample: "S2", calls: [
                    .init(
                        locus: "MHC-A", sourceLocus: "MHC-A",
                        haplotype1: "M-A", haplotype2: "-", status: .called,
                        matchedHaplotypes: [], observedGenotypeCount: 1,
                        observedGenotypes: ["A_marker"]
                    ),
                ]),
            ]
        )
        try JSONEncoder().encode(analysis).write(to: analysisURL)

        var declaration: ONTMHCCandidateArtifactManifest?
        if rejectedCandidates {
            func declared(_ name: String, _ content: String) throws -> ONTMHCArtifactReference {
                let data = Data(content.utf8)
                try data.write(to: bundle.appendingPathComponent(name))
                return ONTMHCArtifactReference(
                    path: name, sha256: String(repeating: "0", count: 64), sizeBytes: Int64(data.count)
                )
            }
            declaration = ONTMHCCandidateArtifactManifest(
                schemaVersion: 2,
                genotypingEvidence: nil,
                reciprocalEvidence: nil,
                candidateJSON: try declared("candidate-alleles.json", "{}"),
                candidateFASTA: try declared("candidate_alleles.fasta", ">novel\nACGT\n"),
                unnameableJSON: nil,
                unnameableFASTA: nil
            )
        }
        let manifest = ONTGenotypeResultBundleManifest(
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            workflowKind: .fullLengthONTMHCGenotype,
            workflowMode: .haplotyped,
            outputName: "fixture",
            analysisName: "Fixture",
            primaryWorkbookPath: workbook.lastPathComponent,
            longSummaryCSVPath: calls.lastPathComponent,
            sampleSummaryCSVPath: samples.lastPathComponent,
            statsJSONPath: stats.lastPathComponent,
            provenancePath: provenance.lastPathComponent,
            haplotypeAnalysisPath: analysisURL.lastPathComponent,
            haplotypeDefinitionSetID: analysis.definitionSetID,
            haplotypeAssayID: analysis.assayID,
            mhcCandidateArtifacts: declaration
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundle)
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(
            .empty(generatedAt: "2026-10-09T00:00:00Z"),
            forBundleAt: bundle
        )

        let loaded = try ONTGenotypeResultBundle.loadResult(from: bundle)
        XCTAssertNil(loaded.mhcCandidates)
        XCTAssertEqual(
            loaded.integrityWarnings.map(\.code),
            rejectedCandidates ? [.candidateArtifactChecksumMismatch] : []
        )
        return bundle
    }

    /// Runs `operation` with standard error written to a file, and returns
    /// what it received.
    private func capturingStandardError(
        in root: URL,
        _ operation: () async throws -> Void
    ) async throws -> String {
        let errURL = root.appendingPathComponent("stderr-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let errFile = try FileHandle(forWritingTo: errURL)
        fflush(stderr)
        let savedErr = dup(STDERR_FILENO)
        dup2(errFile.fileDescriptor, STDERR_FILENO)
        var thrown: Error?
        do {
            try await operation()
        } catch {
            thrown = error
        }
        fflush(stderr)
        dup2(savedErr, STDERR_FILENO)
        close(savedErr)
        try errFile.close()
        if let thrown {
            throw thrown
        }
        return try String(contentsOf: errURL, encoding: .utf8)
    }
}
