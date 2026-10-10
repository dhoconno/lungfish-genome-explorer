// ProvenanceExportPinAssessmentTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Pure checks on the export pin assessment. The first group uses hand-built steps for each
// status. The second reads the frozen provenance compatibility corpus and the golden records
// and compares every step with a literal expectation.

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class ProvenanceExportPinAssessmentTests: XCTestCase {
    private typealias Assessment = ProvenanceExportPinAssessment
    private typealias Hazard = ProvenanceExportPinAssessment.Hazard

    private func step(_ tool: String, _ version: String, environment: String, executable: String? = nil) -> ProvenanceStep {
        let exe = executable ?? tool
        return ProvenanceStep(
            toolName: tool,
            toolVersion: version,
            argv: ["<tool-root>/envs/\(environment)/bin/\(exe)", "--run"]
        )
    }

    private func composite(_ version: String, environment: String, executable: String, package: String? = nil) -> String {
        var note = "managed conda environment \(environment); executable \(executable)"
        if let package { note += "; package \(package)" }
        return "\(version) (\(note))"
    }

    private func assess(_ steps: ProvenanceStep...) -> [Assessment.StepAssessment] {
        Assessment.assess(steps: steps).steps
    }

    // MARK: Each status

    func testRecordedLockSpecIsPinnedToTheLock() {
        let spec = "bioconda::samtools=1.24=h36b3a25_1"
        let result = assess(step("samtools", composite("1.24", environment: "samtools", executable: "samtools", package: spec), environment: "samtools"))[0]
        XCTAssertEqual(result.status, .pinnedToLock)
        XCTAssertEqual(result.exportedSpec, spec)
        XCTAssertEqual(result.lockSpec, spec)
        XCTAssertEqual(result.lockEntryID, ManagedToolID(rawValue: "samtools"))
        XCTAssertEqual(result.hazards, [])
    }

    func testBBMapEnvironmentExportsWithoutABuild() {
        let result = assess(step("bbmap", composite("40.02", environment: "bbtools", executable: "bbmap.sh"), environment: "bbtools"))[0]
        XCTAssertEqual(result.status, .packageSpecUnavailable)
        XCTAssertEqual(result.exportedSpec, "bioconda::bbmap=40.02")
        XCTAssertEqual(result.lockSpec, "bioconda::bbmap=40.02=he046917_0")
        XCTAssertEqual(result.hazards, [.missingBuild])
    }

    func testPackToolThatRecordedItsSourcePackageIsNotPinned() {
        for (tool, version, environment) in [("lofreq", "2.1.5", "lofreq"), ("ivar", "1.4.4", "ivar"), ("medaka", "2.2.2", "medaka")] {
            let text = composite(version, environment: environment, executable: tool, package: tool)
            let result = assess(step(tool, text, environment: environment))[0]
            XCTAssertEqual(result.status, .packageSpecUnavailable, tool)
            XCTAssertEqual(result.exportedSpec, tool, tool)
            XCTAssertEqual(result.hazards, [.bareName, .recordedPackageNotCondaSpec], tool)
        }
    }

    func testBlastRecordedSourcePackageNameIsNotACondaPackage() {
        let text = composite("2.16.0", environment: "blast", executable: "blastn", package: "ncbi-blast")
        let result = assess(step("blastn", text, environment: "blast"))[0]
        XCTAssertEqual(result.status, .packageSpecUnavailable)
        XCTAssertEqual(result.exportedSpec, "ncbi-blast")
        XCTAssertEqual(result.hazards, [.bareName, .recordedPackageNotCondaSpec])
    }

    func testCondaForgeToolsAreExportedWithTheBiocondaChannel() {
        for (tool, version, spec) in [
            ("pigz", "2.8", "conda-forge::pigz=2.8=hfab5511_2"),
            ("mafft", "7.526", "conda-forge::mafft=7.526=h99b78c6_0"),
        ] {
            let result = assess(step(tool, composite(version, environment: tool, executable: tool), environment: tool))[0]
            XCTAssertEqual(result.status, .packageSpecUnavailable, tool)
            XCTAssertEqual(result.exportedSpec, "bioconda::\(tool)=\(version)", tool)
            XCTAssertEqual(result.lockSpec, spec, tool)
            XCTAssertEqual(result.hazards, [.wrongChannel, .missingBuild], tool)
        }
    }

    func testPackToolEnvironmentNameIsExportedAsThePackage() {
        let phasing = assess(step("whatshap", composite("2.3", environment: "phasing", executable: "whatshap"), environment: "phasing"))[0]
        XCTAssertEqual(phasing.status, .packageSpecUnavailable)
        XCTAssertEqual(phasing.exportedSpec, "bioconda::phasing=2.3")
        XCTAssertEqual(phasing.hazards, [.environmentNameAsPackage, .missingBuild])

        let gatk = assess(step("gatk", composite("4.6.2.0", environment: "gatk-core", executable: "gatk"), environment: "gatk-core"))[0]
        XCTAssertEqual(gatk.status, .packageSpecUnavailable)
        XCTAssertEqual(gatk.exportedSpec, "bioconda::gatk-core=4.6.2.0")
        XCTAssertEqual(gatk.hazards, [.environmentNameAsPackage, .missingBuild])
    }

    func testPythonRuntimeAndSourceBuildCannotBeExpressedAsACondaSpec() {
        let primal = assess(step("primalscheme3", composite("3.3.0+lge.5", environment: "primalscheme3", executable: "primalscheme3"), environment: "primalscheme3"))[0]
        XCTAssertEqual(primal.status, .unpinnableRuntime(.pythonRuntime))
        XCTAssertEqual(primal.exportedSpec, "bioconda::primalscheme3=3.3.0+lge.5")

        let bracken = assess(step("bracken", composite("1.0.0", environment: "bracken", executable: "bracken"), environment: "bracken"))[0]
        XCTAssertEqual(bracken.status, .unpinnableRuntime(.sourceBuild))
        XCTAssertEqual(bracken.exportedSpec, "bioconda::bracken=1.0.0")
        XCTAssertEqual(bracken.status.code, "unpinnableRuntime.sourceBuild")
    }

    func testUnknownVersionsAreReportedWithTheirReason() {
        let libmamba = "critical libmamba The given prefix does not exist: \"<root>/envs/bbmap\""
        let table: [(String, ToolVersionEvidence.Reason)] = [
            ("unknown", .legacySpelling("unknown")),
            ("unresolved", .legacySpelling("unresolved")),
            (libmamba, .recordedProbeError(libmamba)),
        ]
        for (version, reason) in table {
            let result = assess(step("samtools", version, environment: "samtools"))[0]
            XCTAssertEqual(result.status, .versionUnknown(reason), version)
            XCTAssertEqual(result.exportedSpec, "samtools", version)
            XCTAssertEqual(result.hazards, [.bareName], version)
        }
    }

    func testVersionThatDiffersFromTheLockIsReported() {
        let result = assess(step("kraken2", composite("2.1.3", environment: "kraken2", executable: "kraken2"), environment: "kraken2"))[0]
        XCTAssertEqual(result.status, .versionDiffersFromLock(recorded: "2.1.3", locked: "2.17.1"))
    }

    func testRecordedFullSpecThatIsNotTheLocksIsReported() {
        let text = composite("1.24", environment: "samtools", executable: "samtools", package: "bioconda::samtools=1.24=other_0")
        let result = assess(step("samtools", text, environment: "samtools"))[0]
        XCTAssertEqual(result.status, .recordedSpecDiffersFromLock)
        XCTAssertEqual(result.hazards, [])
    }

    func testEnvironmentsTheLockDoesNotHaveAreReported() {
        for name in ["bbmap", "lungfish-managed-tools", "gatk4", "whatshap"] {
            let result = assess(step("tool", "1.0", environment: name))[0]
            XCTAssertEqual(result.status, .environmentNotInLock(name), name)
            XCTAssertNil(result.lockEntryID)
            XCTAssertNil(result.lockSpec)
        }
    }

    func testMicromambaRunNamesTheEnvironment() {
        let micromamba = ProvenanceStep(
            toolName: "minimap2",
            toolVersion: "2.31",
            argv: ["micromamba", "run", "-n", "minimap2", "minimap2", "-a"]
        )
        let result = Assessment.assess(steps: [micromamba]).steps[0]
        XCTAssertEqual(result.environment, "minimap2")
        XCTAssertEqual(result.status, .packageSpecUnavailable)
        XCTAssertEqual(result.hazards, [.missingBuild])
    }

    func testStepsWithoutAManagedEnvironmentAreNotAssessed() {
        let steps = [
            ProvenanceStep(toolName: "lungfish-cli", toolVersion: "lungfish-cli 2026.10.10", argv: ["lungfish-cli", "fastq", "trim"]),
            ProvenanceStep(toolName: "gzip", toolVersion: "system", argv: ["/bin/sh", "-c", "gzip -c a > b"]),
            ProvenanceStep(toolName: "kraken2", toolVersion: "2.17.1", argv: ["kraken2", "--db", "x"]),
        ]
        let result = Assessment.assess(steps: steps)
        XCTAssertEqual(result.steps.map(\.status), [.noEnvironmentRecorded, .noEnvironmentRecorded, .noEnvironmentRecorded])
        XCTAssertEqual(result.steps.map(\.number), [1, 2, 3])
        XCTAssertTrue(result.unpinnedSteps.isEmpty)
        XCTAssertEqual(result.steps[1].evidence, .unknown(.legacySpelling("system")))
    }

    func testAnEmptyLockHasNoEnvironments() {
        let empty = ManagedToolLock(packID: "x", displayName: "x", version: "x", tools: [], managedData: [])
        let result = Assessment.assess(
            steps: [step("samtools", composite("1.24", environment: "samtools", executable: "samtools"), environment: "samtools")],
            lock: empty
        ).steps[0]
        XCTAssertEqual(result.status, .environmentNotInLock("samtools"))
    }
}

/// The assessment of every step of the frozen provenance compatibility corpus and of the golden
/// provenance records, as literal expectations. A change to the assessment, the lock or a record
/// shows up here as a reviewed diff. A row reads `<number> <tool> [<environment>] <status> <hazards>`.
final class ProvenanceExportPinAssessmentRecordTests: XCTestCase {
    private static let corpusExpectations: [String: [String]] = [
        "s1-db-receipt-kraken2-viral": [],
        "s2-analysis-kraken2-fixture": [],
        "s3-ncbi-fetch-alpha11": ["1 ncbi-efetch [-] noEnvironmentRecorded -"],
        "s4-mcm-mhcref-shipped": ["1 build_mcm_mhc_miseq_reference.py [-] noEnvironmentRecorded -"],
        "s4-msa-mafft-2026-05": ["1 mafft [-] noEnvironmentRecorded -"],
        "s1-cancelled-single-step": ["1 fastp [-] noEnvironmentRecorded -"],
        "s1-recorder-readsetplan": ["1 kraken2 [kraken2] versionDiffersFromLock missingBuild", "2 bracken [bracken] unpinnableRuntime.sourceBuild missingBuild"],
        "s1-canonical-envelope-run": ["1 gatk [gatk4] environmentNotInLock -", "2 whatshap [-] noEnvironmentRecorded -"],
        "s3-write-sidecar-bare-run": ["1 gatk [gatk4] environmentNotInLock -", "2 whatshap [-] noEnvironmentRecorded -"],
        "s3-gatk-container-bare-run": ["1 gatk-joint-genotype [-] noEnvironmentRecorded -", "2 gatk-joint-genotype [-] noEnvironmentRecorded -"],
    ]

    private static let goldenExpectations: [String: [String]] = [
        "classifiers/esviritu/lungfish-provenance.json": [
            "1 EsViritu [-] noEnvironmentRecorded -",
            "2 Lungfish EsViritu Result Sidecar [-] noEnvironmentRecorded -",
        ],
        "classifiers/kraken2/lungfish-provenance.json": [
            "1 lungfish-cli fastq materialize [-] noEnvironmentRecorded -",
            "2 kraken2 [-] noEnvironmentRecorded -",
            "3 lungfish-kraken2-index [-] noEnvironmentRecorded -",
            "4 gzip [-] noEnvironmentRecorded -",
            "5 Lungfish Classification Result Sidecar [-] noEnvironmentRecorded -",
        ],
        "genotype/bundle/lungfish-provenance.json": [
            "1 minimap2 [minimap2] versionUnknown.legacySpelling bareName",
            "2 samtools sort [samtools] versionUnknown.legacySpelling bareName",
            "3 minimap2 [minimap2] versionUnknown.legacySpelling bareName",
            "4 samtools sort [samtools] versionUnknown.legacySpelling bareName",
            "5 samtools merge [samtools] versionUnknown.legacySpelling bareName",
            "6 samtools index [samtools] versionUnknown.legacySpelling bareName",
            "7 pysam retained-read demux filter [pysam] versionUnknown.legacySpelling bareName",
            "8 Lungfish Provisional exon 2 artifact publisher [-] noEnvironmentRecorded -",
            "9 deterministic genotype haplotype assignment [-] noEnvironmentRecorded -",
            "10 openpyxl ONT genotype workbook report [openpyxl] packageSpecUnavailable wrongChannel,missingBuild",
        ],
        "genotype/bundle/provenance/bundle.lungfish-provenance.json": [
            "1 minimap2 [minimap2] versionUnknown.legacySpelling bareName",
            "2 samtools sort [samtools] versionUnknown.legacySpelling bareName",
            "3 minimap2 [minimap2] versionUnknown.legacySpelling bareName",
            "4 samtools sort [samtools] versionUnknown.legacySpelling bareName",
            "5 samtools merge [samtools] versionUnknown.legacySpelling bareName",
            "6 samtools index [samtools] versionUnknown.legacySpelling bareName",
            "7 pysam retained-read demux filter [pysam] versionUnknown.legacySpelling bareName",
            "8 Lungfish Provisional exon 2 artifact publisher [-] noEnvironmentRecorded -",
            "9 deterministic genotype haplotype assignment [-] noEnvironmentRecorded -",
            "10 openpyxl ONT genotype workbook report [openpyxl] packageSpecUnavailable wrongChannel,missingBuild",
        ],
        "genotype/bundle/retained-demux-genotyping-provenance.json": [
            "1 minimap2 [minimap2] versionUnknown.recordedAppVersion bareName",
            "2 samtools sort [samtools] versionUnknown.recordedAppVersion bareName",
            "3 minimap2 [minimap2] versionUnknown.recordedAppVersion bareName",
            "4 samtools sort [samtools] versionUnknown.recordedAppVersion bareName",
            "5 samtools merge [samtools] versionUnknown.recordedAppVersion bareName",
            "6 samtools index [samtools] versionUnknown.recordedAppVersion bareName",
            "7 pysam retained-read demux filter [pysam] versionUnknown.recordedAppVersion bareName",
            "8 Lungfish Provisional exon 2 artifact publisher [-] noEnvironmentRecorded -",
            "9 deterministic genotype haplotype assignment [-] noEnvironmentRecorded -",
            "10 openpyxl ONT genotype workbook report [openpyxl] versionUnknown.recordedAppVersion bareName",
        ],
        "mapping/lungfish-provenance.json": [
            "1 minimap2 [minimap2] packageSpecUnavailable missingBuild",
            "2 samtools [samtools] pinnedToLock -",
            "3 samtools [samtools] pinnedToLock -",
            "4 samtools [samtools] pinnedToLock -",
            "5 samtools [samtools] pinnedToLock -",
        ],
        "mapping/mapping-provenance.json": [
            "1 minimap2 [minimap2] packageSpecUnavailable missingBuild",
            "2 samtools [samtools] pinnedToLock -",
            "3 samtools [samtools] pinnedToLock -",
            "4 samtools [samtools] pinnedToLock -",
            "5 samtools [samtools] pinnedToLock -",
        ],
    ]
    private static func row(_ step: ProvenanceExportPinAssessment.StepAssessment) -> String {
        var code = step.status.code
        if case .versionUnknown(let reason) = step.status {
            switch reason {
            case .noProbe: code += ".noProbe"
            case .probeFailed: code += ".probeFailed"
            case .outputUnparseable: code += ".outputUnparseable"
            case .legacySpelling: code += ".legacySpelling"
            case .recordedProbeError: code += ".recordedProbeError"
            case .recordedAppVersion: code += ".recordedAppVersion"
            }
        }
        let hazards = step.hazards.isEmpty ? "-" : step.hazards.map(\.rawValue).joined(separator: ",")
        return "\(step.number) \(step.toolName) [\(step.environment ?? "-")] \(code) \(hazards)"
    }

    private static var goldenRoot: URL {
        ProvenanceCompatCorpus.repositoryRoot.appendingPathComponent("Tests/Fixtures/golden", isDirectory: true)
    }

    /// Every golden JSON file that decodes to a record with steps, by path under `Tests/Fixtures/golden`.
    private static func goldenAssessments() throws -> [String: [ProvenanceExportPinAssessment.StepAssessment]] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: goldenRoot, includingPropertiesForKeys: nil))
        var result: [String: [ProvenanceExportPinAssessment.StepAssessment]] = [:]
        for case let url as URL in enumerator where url.pathExtension == "json" {
            let relative = url.path.replacingOccurrences(of: goldenRoot.path + "/", with: "")
            guard !relative.hasPrefix("cli-help/"), !relative.hasPrefix("tools/"),
                  let envelope = try? ProvenanceEnvelopeReader.decode(Data(contentsOf: url)),
                  !envelope.steps.isEmpty else { continue }
            result[relative] = ProvenanceExportPinAssessment.assess(envelope).steps
        }
        return result
    }

    func testFrozenCorpusAssessmentsEqualTheCommittedExpectations() throws {
        XCTAssertEqual(Set(Self.corpusExpectations.keys), Set(ProvenanceCompatCorpus.caseIDs()))
        for (id, expected) in Self.corpusExpectations {
            let materialized = try ProvenanceCompatCorpus.materialize(id)
            defer { materialized.cleanup() }
            let envelope = try XCTUnwrap(try ProvenanceEnvelopeReader.load(fromSidecar: materialized.sidecar), id)
            XCTAssertEqual(ProvenanceExportPinAssessment.assess(envelope).steps.map(Self.row), expected, id)
        }
    }

    func testGoldenRecordAssessmentsEqualTheCommittedExpectations() throws {
        let assessments = try Self.goldenAssessments()
        for (path, expected) in Self.goldenExpectations {
            let steps = try XCTUnwrap(assessments[path], path)
            XCTAssertEqual(steps.map(Self.row), expected, path)
        }
    }

    func testGoldenRecordTotals() throws {
        let assessments = try Self.goldenAssessments()
        let steps = assessments.values.flatMap { $0 }
        XCTAssertEqual(assessments.count, 44)
        XCTAssertEqual(steps.count, 100)
        let counts = steps.reduce(into: [String: Int]()) { counts, step in
            let row = Self.row(step).split(separator: " ")
            counts[String(row[row.count - 2]), default: 0] += 1
        }
        XCTAssertEqual(counts, [
            "noEnvironmentRecorded": 52,
            "packageSpecUnavailable": 6,
            "pinnedToLock": 8,
            "versionUnknown.legacySpelling": 26,
            "versionUnknown.recordedAppVersion": 8
        ])
    }

    func testTheGenotypeRecordHasSevenUnknownVersionStepsAndAnUnpinnedWorkbookStep() throws {
        let steps = try XCTUnwrap(Self.goldenAssessments()["genotype/bundle/lungfish-provenance.json"])
        XCTAssertEqual(steps.count, 10)
        let unknown = steps.filter { $0.status.code == "versionUnknown" }
        XCTAssertEqual(unknown.count, 7)
        XCTAssertEqual(
            unknown.map(\.toolName),
            ["minimap2", "samtools sort", "minimap2", "samtools sort", "samtools merge", "samtools index", "pysam retained-read demux filter"]
        )
        XCTAssertTrue(unknown.allSatisfy { $0.evidence == .unknown(.legacySpelling("unknown")) })
        XCTAssertEqual(steps.filter(\.status.isUnpinned).count, 8)
    }

    func testTheMappingRecordPinsSamtoolsAndNotMinimap2() throws {
        let steps = try XCTUnwrap(Self.goldenAssessments()["mapping/lungfish-provenance.json"])
        XCTAssertEqual(steps.first?.exportedSpec, "bioconda::minimap2=2.31")
        XCTAssertEqual(steps.first?.lockSpec, "bioconda::minimap2=2.31=h6bd33b9_0")
        XCTAssertEqual(steps.dropFirst().map(\.status), Array(repeating: .pinnedToLock, count: 4))
    }
}
