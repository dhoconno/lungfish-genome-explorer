import Darwin
import CryptoKit
import Foundation
import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class GenotypeWorkbookRevisionServiceTests: XCTestCase {
    func testExplicitWorkbookUpdateAcceptsWriterShapedSchemaV4UnnameableIdentity() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "schema-v4-update")
        try installCandidateArtifacts(in: fixture.bundleURL, schemaVersion: 4)
        try installMinimalUnifiedPivot(in: fixture.bundleURL)
        let beforeScientificArtifacts = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
        let evidenceURL = ONTGenotypeResultBundle.resolvedURL(
            for: beforeScientificArtifacts.primaryWorkbookPath,
            in: fixture.bundleURL
        )
        let evidenceReference = ONTMHCArtifactReference(
            path: beforeScientificArtifacts.primaryWorkbookPath,
            sha256: try ProvenanceFileHasher.sha256(of: evidenceURL),
            sizeBytes: Int64(try ProvenanceFileHasher.fileSize(of: evidenceURL))
        )
        let alignmentArtifacts = ONTGenotypeAlignmentArtifactManifest(
            genotypingEvidence: ONTMHCBAMArtifactPair(
                bam: evidenceReference,
                bai: evidenceReference
            ),
            reciprocalEvidence: nil
        )
        let provisionalArtifacts = ONTGenotypeProvisionalExon2ArtifactManifest(
            schemaVersion: 1,
            catalogJSON: evidenceReference,
            sequencesFASTA: evidenceReference
        )
        try ONTGenotypeResultBundle.writeManifest(
            ONTGenotypeResultBundleManifest(
                schemaVersion: beforeScientificArtifacts.schemaVersion,
                kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
                workflowKind: .fullLengthONTMHCGenotype,
                workflowMode: .genotypeOnly,
                outputName: beforeScientificArtifacts.outputName,
                analysisName: beforeScientificArtifacts.analysisName,
                primaryWorkbookPath: beforeScientificArtifacts.primaryWorkbookPath,
                currentWorkbookPath: beforeScientificArtifacts.currentWorkbookPath,
                workbookRevisions: beforeScientificArtifacts.workbookRevisions,
                longSummaryCSVPath: beforeScientificArtifacts.longSummaryCSVPath,
                sampleSummaryCSVPath: beforeScientificArtifacts.sampleSummaryCSVPath,
                statsJSONPath: beforeScientificArtifacts.statsJSONPath,
                provenancePath: beforeScientificArtifacts.provenancePath,
                mhcCandidateArtifacts: beforeScientificArtifacts.mhcCandidateArtifacts,
                mhcReferenceVisualizations: beforeScientificArtifacts.mhcReferenceVisualizations,
                referenceRecordStore: beforeScientificArtifacts.referenceRecordStore,
                alignmentArtifacts: alignmentArtifacts,
                provisionalExon2Artifacts: provisionalArtifacts
            ),
            to: fixture.bundleURL
        )
        let installedManifest = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
        let unnameableDocument = try JSONDecoder().decode(
            ONTMHCUnnameableClustersDocument.self,
            from: Data(contentsOf: ONTGenotypeResultBundle.resolvedURL(
                for: try XCTUnwrap(installedManifest.mhcCandidateArtifacts?.unnameableJSON?.path),
                in: fixture.bundleURL
            ))
        )
        XCTAssertEqual(unnameableDocument.clusters.first?.stableClusterID, "raw-cluster-u")
        XCTAssertEqual(unnameableDocument.clusters.first?.fastaRecordID, "canonical-cluster-u")

        let updatedManifest = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 7_200) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        XCTAssertEqual(updatedManifest.workflowKind, .fullLengthONTMHCGenotype)
        XCTAssertEqual(updatedManifest.workflowMode, .genotypeOnly)

        XCTAssertNotNil(updatedManifest.mhcCandidateArtifacts?.candidateJSON)
        XCTAssertNotNil(updatedManifest.mhcCandidateArtifacts?.unnameableJSON)
        XCTAssertEqual(updatedManifest.alignmentArtifacts, alignmentArtifacts)
        XCTAssertEqual(updatedManifest.provisionalExon2Artifacts, provisionalArtifacts)
        XCTAssertFalse((updatedManifest.workbookRevisions ?? []).isEmpty)
        let inspection = try inspectTwoSheetCandidateWorkbook(
            try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        )
        XCTAssertTrue(
            inspection["unmatchedIDs"]?.split(separator: "|").contains("raw-cluster-u") == true
        )
        XCTAssertEqual(inspection["unnameableSequence"], String(repeating: "N", count: 40))
    }

    func testExplicitWorkbookUpdateAcceptsCandidateArtifactManifestSchema2RawIdentityRefs() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "candidate-manifest-schema-2-update"
        )
        try installCandidateArtifacts(
            in: fixture.bundleURL,
            schemaVersion: 4,
            artifactManifestSchemaVersion: 2
        )
        try installMinimalUnifiedPivot(in: fixture.bundleURL)
        let before = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
        let rawFASTA = try XCTUnwrap(before.mhcCandidateArtifacts?.rawUnmatchedFASTA)
        let sourceIdentityMap = try XCTUnwrap(before.mhcCandidateArtifacts?.sourceIdentityMap)

        let updated = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 7_300) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)

        XCTAssertEqual(updated.mhcCandidateArtifacts?.schemaVersion, 2)
        XCTAssertEqual(updated.mhcCandidateArtifacts?.rawUnmatchedFASTA, rawFASTA)
        XCTAssertEqual(updated.mhcCandidateArtifacts?.sourceIdentityMap, sourceIdentityMap)
    }

    func testFullLengthMHCUpdateUsesSpeciesAgnosticBiologicalAlleleOrder() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "mamu-biological-order")
        try installCandidateArtifacts(in: fixture.bundleURL, schemaVersion: 2)

        var manifest = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
        let artifacts = try XCTUnwrap(manifest.mhcCandidateArtifacts)
        let candidateJSONURL = ONTGenotypeResultBundle.resolvedURL(
            for: try XCTUnwrap(artifacts.candidateJSON).path,
            in: fixture.bundleURL
        )
        var candidateJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: candidateJSONURL)) as? [String: Any]
        )
        var candidates = try XCTUnwrap(candidateJSON["candidates"] as? [[String: Any]])
        let candidateNames: [String: (name: String, locus: String, reference: String)] = [
            "cluster-1": ("Mamu-B02ps*001_5nt_nov", "Mamu-B02ps", "Mamu-B02ps*001"),
            "cluster-2": ("Mamu-B02ps*001_5nt_nov", "Mamu-B02ps", "Mamu-B02ps*001"),
            "cluster-3": ("Mamu-K*002_ext", "Mamu-K", "Mamu-K*002"),
            "cluster-4": ("Mamu-A2*003_ext", "Mamu-A2", "Mamu-A2*003"),
        ]
        for index in candidates.indices {
            let stableID = try XCTUnwrap(candidates[index]["stable_cluster_id"] as? String)
            let replacement = try XCTUnwrap(candidateNames[stableID])
            candidates[index]["provisional_name"] = replacement.name
            candidates[index]["locus"] = replacement.locus
            candidates[index]["closest_reference_name"] = replacement.reference
        }
        candidateJSON["candidates"] = candidates
        try JSONSerialization.data(
            withJSONObject: candidateJSON,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: candidateJSONURL, options: .atomic)

        let knownNames: [(id: String, name: String)] = [
            ("raw-01", "Mamu-DRB*001"),
            ("raw-02", "Mamu-K*001"),
            ("raw-03", "Mamu-J*001"),
            ("raw-04", "Mamu-AG*001"),
            ("raw-05", "Mamu-G*001"),
            ("raw-06", "Mamu-F*001"),
            ("raw-07", "Mamu-I*001"),
            ("raw-08", "Mamu-B16*001"),
            ("raw-09", "Mamu-B*010"),
            ("raw-10", "Mamu-B*002"),
            ("raw-11", "Mamu-A10*001"),
            ("raw-12", "Mamu-A2*010"),
            ("raw-13", "Mamu-A1*001"),
            ("raw-14", "Mamu-B*001:01N"),
            ("raw-15", "Mamu-B*001:01_ext"),
        ]
        let referenceArtifacts = try XCTUnwrap(manifest.mhcReferenceVisualizations)
        let referenceJSONURL = ONTGenotypeResultBundle.resolvedURL(
            for: referenceArtifacts.recordsJSON.path,
            in: fixture.bundleURL
        )
        let referenceSequence = "ATGGCTTAA"
        let referenceRecords = knownNames.enumerated().map { index, item in
            ONTMHCReferenceVisualizationRecord(
                rawReferenceID: item.id,
                sourceOrdinal: index,
                alleleName: item.name,
                locus: String(item.name.prefix { $0 != "*" }).split(separator: "-").last.map(String.init),
                sequence: referenceSequence,
                sequenceSHA256: sha256Hex(referenceSequence),
                recordFields: ["feature.allele": [item.name]],
                features: [],
                annotatedTranslation: "MA",
                genBankText: "LOCUS \(item.id)",
                fastaText: ">\(item.id)\n\(referenceSequence)\n",
                roles: [.init(role: .exactKnownCall, candidateStableClusterIDs: [])]
            )
        }
        try JSONEncoder().encode(
            ONTMHCReferenceVisualizationArtifact(schemaVersion: 1, records: referenceRecords)
        ).write(to: referenceJSONURL, options: .atomic)

        let longSummaryURL = ONTGenotypeResultBundle.resolvedURL(
            for: manifest.longSummaryCSVPath,
            in: fixture.bundleURL
        )
        let longRows = knownNames.enumerated().map { index, item in
            "sample-a,\(item.id),\(index + 1),\(index + 1),1000,100,10,1000,100,10"
        }
        try ([
            "sample,genotype,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_reads,overall_unique_retained_percent",
        ] + longRows).joined(separator: "\n").appending("\n").write(
            to: longSummaryURL,
            atomically: true,
            encoding: .utf8
        )

        let revisedCandidateArtifacts = ONTMHCCandidateArtifactManifest(
            schemaVersion: artifacts.schemaVersion,
            genotypingEvidence: artifacts.genotypingEvidence,
            reciprocalEvidence: artifacts.reciprocalEvidence,
            candidateJSON: try artifactReference(candidateJSONURL, relativeTo: fixture.bundleURL),
            candidateFASTA: artifacts.candidateFASTA,
            candidateGenBank: artifacts.candidateGenBank,
            unnameableJSON: artifacts.unnameableJSON,
            unnameableFASTA: artifacts.unnameableFASTA,
            unnameableGenBank: artifacts.unnameableGenBank
        )
        let revisedReferenceArtifacts = ONTMHCReferenceVisualizationArtifacts(
            schemaVersion: referenceArtifacts.schemaVersion,
            recordCount: referenceRecords.count,
            recordsJSON: try artifactReference(referenceJSONURL, relativeTo: fixture.bundleURL),
            genBank: referenceArtifacts.genBank,
            fasta: referenceArtifacts.fasta
        )
        manifest = ONTGenotypeResultBundleManifest(
            schemaVersion: manifest.schemaVersion,
            kind: manifest.kind,
            outputName: manifest.outputName,
            analysisName: manifest.analysisName,
            primaryWorkbookPath: manifest.primaryWorkbookPath,
            currentWorkbookPath: manifest.currentWorkbookPath,
            workbookRevisions: manifest.workbookRevisions,
            longSummaryCSVPath: manifest.longSummaryCSVPath,
            sampleSummaryCSVPath: manifest.sampleSummaryCSVPath,
            statsJSONPath: manifest.statsJSONPath,
            provenancePath: manifest.provenancePath,
            mhcCandidateArtifacts: revisedCandidateArtifacts,
            mhcReferenceVisualizations: revisedReferenceArtifacts,
            referenceRecordStore: manifest.referenceRecordStore
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: fixture.bundleURL)

        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        _ = try runPython(["-c", #"""
import sys
from openpyxl import load_workbook
path = sys.argv[1]
wb = load_workbook(path)
if "Unified Genotype Pivot" in wb.sheetnames:
    del wb["Unified Genotype Pivot"]
ws = wb.create_sheet("Unified Genotype Pivot")
ws.append(["Client ID", "", ""] + [""] * 9 + ["sample-a"])
ws.append(["MHC-A Haplotype 1", "", ""] + [""] * 9 + ["analyst-h1"])
ws.append(["Comments", "Subtotal", "# Obs."] + [""] * 9 + ["analyst-comment"])
ws.append([])
ws.append([
    "call_type", "call_id", "display_name", "stable_cluster_id", "locus", "classification",
    "support_class", "closest_reference", "match_class", "occurrence_count", "sample_count",
    "total_cluster_reads", "sample-a",
])
wb.save(path)
"""#, currentURL.path])

        _ = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 7_150) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)

        let inspection = try inspectBiologicallyOrderedTwoSheetWorkbook(currentURL)
        XCTAssertEqual(inspection["sheetNames"], "Unified Genotype Pivot|Unmatched Alleles")
        XCTAssertEqual(inspection["analystHaplotype"], "analyst-h1")
        XCTAssertEqual(inspection["analystComment"], "analyst-comment")
        let swiftOrderedDisplayNames = (
            knownNames.map { $0.name } + candidateNames.values.map { $0.name }
        ).sorted(by: MHCAlleleDisplayOrder.lessThan)
        XCTAssertEqual(
            inspection["unifiedDisplayNames"],
            swiftOrderedDisplayNames.joined(separator: "|"),
            "Explicit workbook refresh and Swift viewport ordering must remain identical"
        )
        XCTAssertEqual(inspection["unifiedDisplayNames"], [
            "Mamu-A1*001",
            "Mamu-A2*003_ext",
            "Mamu-A2*010",
            "Mamu-A10*001",
            "Mamu-B*001:01_ext",
            "Mamu-B*001:01N",
            "Mamu-B*002",
            "Mamu-B*010",
            "Mamu-B02ps*001_5nt_nov",
            "Mamu-B02ps*001_5nt_nov",
            "Mamu-B16*001",
            "Mamu-I*001",
            "Mamu-F*001",
            "Mamu-G*001",
            "Mamu-AG*001",
            "Mamu-J*001",
            "Mamu-K*001",
            "Mamu-K*002_ext",
            "Mamu-DRB*001",
        ].joined(separator: "|"))
        XCTAssertEqual(inspection["unmatchedNames"], [
            "Mamu-A2*003_ext",
            "Mamu-B02ps*001_5nt_nov",
            "Mamu-B02ps*001_5nt_nov",
            "Mamu-K*002_ext",
            "",
        ].joined(separator: "|"))
        XCTAssertEqual(
            inspection["unmatchedIDs"],
            "cluster-4|cluster-1|cluster-2|cluster-3|cluster-u",
            "Duplicate provisional names and the blank un-nameable row must remain distinct"
        )
    }

    func testExplicitUpdateWritesTwoSheetContractFromEmbeddedUnifiedHeaderAndNormalizedUnmatchedRows() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "two-sheet-update")
        try installCandidateArtifacts(in: fixture.bundleURL, schemaVersion: 2)
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        _ = try runPython(["-c", #"""
import sys
from openpyxl import load_workbook
path = sys.argv[1]
wb = load_workbook(path)
if "Unified Genotype Pivot" in wb.sheetnames:
    del wb["Unified Genotype Pivot"]
ws = wb.create_sheet("Unified Genotype Pivot")
ws.append(["Client ID", "", ""] + [""] * 9 + ["sample-a", "sample-b"])
ws.append(["Mapped Read Count", "stale-total", "stale-average"] + [""] * 9 + ["1", "2"])
ws.append(["MHC-A Haplotype 1", "", ""] + [""] * 9 + ["analyst-h1", ""])
ws.append(["MHC-DQA Haplotype 1", "", ""] + [""] * 9 + ["", "analyst-dqa"])
ws.append(["MHC-DQB Haplotype 1", "", ""] + [""] * 9 + ["", "analyst-dqb"])
ws.append(["MHC-DPA Haplotype 1", "", ""] + [""] * 9 + ["", "analyst-dpa"])
ws.append(["MHC-DPB Haplotype 1", "", ""] + [""] * 9 + ["", "analyst-dpb"])
ws.append(["Comments", "Subtotal", "# Obs."] + [""] * 9 + ["analyst-comment", ""])
ws.append([])
ws.append([
    "call_type", "call_id", "display_name", "stable_cluster_id", "locus", "classification",
    "support_class", "closest_reference", "match_class", "occurrence_count", "sample_count",
    "total_cluster_reads", "sample-a", "sample-b",
])
ws.append(["known-allele", "NHP00001", "Mafa-A1*001:01", "", "", "known", "", "Mafa-A1*001:01", "exact", 1, 1, 9, 9, ""])
wb.create_sheet("Legacy Sheet")
wb.save(path)
"""#, currentURL.path])

        let updated = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 7_100) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        ).applyHaplotypeOverrides([
            .init(sample: "sample-a", locus: "MHC-DQ", haplotype1: "DQ-H1", haplotype2: "DQ-H2", status: "called", notes: ""),
            .init(sample: "sample-a", locus: "MHC-DP", haplotype1: "DP-H1", haplotype2: "DP-H2", status: "called", notes: ""),
        ], annotationSidecarURL: nil, into: fixture.bundleURL)

        let inspection = try inspectTwoSheetCandidateWorkbook(currentURL)
        XCTAssertEqual(inspection["sheetNames"], "Unified Genotype Pivot|Unmatched Alleles")
        XCTAssertEqual(inspection["tableHeaderRow"], "22", "computed header and table are rebuilt from durable CSV inputs")
        XCTAssertEqual(inspection["analystHaplotype"], "analyst-h1")
        XCTAssertEqual(inspection["analystComment"], "analyst-comment")
        XCTAssertEqual(inspection["sampleADQAHaplotype1"], "DQ-H1")
        XCTAssertEqual(inspection["sampleADQBHaplotype1"], "DQ-H1")
        XCTAssertEqual(inspection["sampleADPAHaplotype1"], "DP-H1")
        XCTAssertEqual(inspection["sampleADPBHaplotype1"], "DP-H1")
        XCTAssertEqual(inspection["sampleBDQAHaplotype1"], "analyst-dqa")
        XCTAssertEqual(inspection["sampleBDPBHaplotype1"], "analyst-dpb")
        XCTAssertEqual(inspection["mappedTotal"], "303")
        XCTAssertEqual(inspection["mappedAverage"], "151.5")
        XCTAssertEqual(inspection["mappedTotalType"], "n")
        XCTAssertEqual(inspection["mappedAverageType"], "n")
        XCTAssertEqual(inspection["sampleAMappedType"], "n")
        XCTAssertEqual(inspection["sampleATotalReadType"], "n")
        XCTAssertEqual(inspection["sampleAUnmappedPercentType"], "n")
        XCTAssertEqual(inspection["knownDisplayName"], "Mafa-A1*001:01:01:01")
        XCTAssertEqual(inspection["knownClosestReference"], "Mafa-A1*001:01:01:01")
        XCTAssertEqual(inspection["knownSampleAReads"], "101")
        XCTAssertEqual(inspection["knownSampleBReads"], "202")
        XCTAssertEqual(inspection["knownTotalReads"], "303")
        XCTAssertEqual(inspection["candidateIDs"], "cluster-1|cluster-2|cluster-3|cluster-4")
        XCTAssertEqual(inspection["unmatchedIDs"], "cluster-1|cluster-2|cluster-3|cluster-4|cluster-u")
        XCTAssertEqual(inspection["candidateSequence"], String(repeating: "C", count: 33))
        XCTAssertEqual(inspection["legacySequenceColumns"], "false")
        XCTAssertEqual(inspection["candidateTranslation"], "AAAAAAAAAAA")
        XCTAssertEqual(inspection["candidateTranslationStatus"], "full-length")
        XCTAssertEqual(inspection["unnameableSequence"], String(repeating: "N", count: 40))
        XCTAssertEqual(inspection["unnameableTranslationStatus"], "incomplete/unresolved")

        let provenanceURL = ONTGenotypeResultBundle.resolvedURL(
            for: try XCTUnwrap(updated.workbookRevisions?.last?.provenancePath),
            in: fixture.bundleURL
        )
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: provenanceURL)
        )
        let pythonStep = try XCTUnwrap(envelope.steps.first { $0.toolName.contains("python openpyxl") })
        XCTAssertTrue(pythonStep.inputs.contains { $0.path.hasSuffix("candidate-alleles.gb") })
        XCTAssertTrue(pythonStep.inputs.contains { $0.path.hasSuffix("unnameable-clusters.gb") })
    }

    func testTwoSheetCurrentWorkbookRetainsAndAppliesSemanticReviews() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "two-sheet-reviews")
        try installCandidateArtifacts(in: fixture.bundleURL, schemaVersion: 2)
        try installMinimalUnifiedPivot(in: fixture.bundleURL)
        let annotationURL = fixture.bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "Mafa-A1",
                    genotype: "Mafa-A1*018:01:01:01_5nt_nov",
                    sample: "sample-a",
                    stableClusterID: "cluster-1"
                ),
                disposition: .falsePositive,
                author: "reviewer",
                timestamp: "2026-07-24T10:00:00Z"
            )
        ]
        try sidecar.encoded().write(to: annotationURL)

        _ = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 7_150) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        ).applyHaplotypeOverrides([], annotationSidecarURL: annotationURL, into: fixture.bundleURL)

        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        let output = try runPython(["-c", #"""
import json
import sys
from openpyxl import load_workbook

wb = load_workbook(sys.argv[1], data_only=False)
ws = wb["Unified Genotype Pivot"]
headers = {}
header_row = None
for row in range(1, ws.max_row + 1):
    values = {str(ws.cell(row, col).value): col for col in range(1, ws.max_column + 1) if ws.cell(row, col).value is not None}
    if "stable_cluster_id" in values:
        headers = values
        header_row = row
        break
target_row = next(
    row for row in range(header_row + 1, ws.max_row + 1)
    if ws.cell(row, headers["stable_cluster_id"]).value == "cluster-1"
)
cell = ws.cell(target_row, headers["sample-a"])
annotation_rows = []
if "Matrix Annotations" in wb.sheetnames:
    annotations = wb["Matrix Annotations"]
    annotation_rows = [
        "|".join("" if annotations.cell(row, col).value is None else str(annotations.cell(row, col).value)
                 for col in range(1, annotations.max_column + 1))
        for row in range(2, annotations.max_row + 1)
    ]
print(json.dumps({
    "sheet_names": wb.sheetnames,
    "value": str(cell.value),
    "italic": bool(cell.font.italic),
    "has_annotations": "Matrix Annotations" in wb.sheetnames,
    "has_audit": "Audit Log" in wb.sheetnames,
    "annotations": annotation_rows,
}))
"""#, currentURL.path])
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        )
        let diagnostic = String(describing: payload["annotations"])
        XCTAssertEqual(payload["value"] as? String, "[7]", diagnostic)
        XCTAssertEqual(payload["italic"] as? Bool, true, diagnostic)
        XCTAssertEqual(payload["has_annotations"] as? Bool, true)
        XCTAssertEqual(payload["has_audit"] as? Bool, true)
    }

    func testAnnotationOnlyUpdatePreservesAttestedProjectionWithUnrelatedLegacyCandidateLabel() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "annotation-only-legacy-candidate"
        )
        try installCandidateArtifacts(in: fixture.bundleURL, schemaVersion: 2)
        try installMinimalUnifiedPivot(in: fixture.bundleURL)
        let service = GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 7_160) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        )
        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: nil,
            into: fixture.bundleURL
        )

        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        var manifest = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
        let artifacts = try XCTUnwrap(manifest.mhcCandidateArtifacts)
        let candidateJSONURL = ONTGenotypeResultBundle.resolvedURL(
            for: try XCTUnwrap(artifacts.candidateJSON).path,
            in: fixture.bundleURL
        )
        var candidateJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: candidateJSONURL)) as? [String: Any]
        )
        var candidates = try XCTUnwrap(candidateJSON["candidates"] as? [[String: Any]])
        let legacyIndex = try XCTUnwrap(
            candidates.firstIndex { $0["stable_cluster_id"] as? String == "cluster-4" }
        )
        candidates[legacyIndex]["classification"] = "novel"
        candidates[legacyIndex]["provisional_name"] = "Mafa-B*002:01_0nt_nov"
        candidates[legacyIndex]["closest_reference_class"] = "genomicDNA"
        candidates[legacyIndex]["snp_count"] = 0
        candidates[legacyIndex]["deleted_bases"] = 0
        candidates[legacyIndex]["long_gap_bases"] = 0
        candidateJSON["candidates"] = candidates
        try JSONSerialization.data(
            withJSONObject: candidateJSON,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: candidateJSONURL, options: .atomic)

        _ = try runPython(["-c", #"""
import re
import sys
from openpyxl import load_workbook

path = sys.argv[1]
wb = load_workbook(path)
for sheet_name in ("Unified Genotype Pivot", "Unmatched Alleles"):
    ws = wb[sheet_name]
    header_row = None
    headers = {}
    for row in range(1, ws.max_row + 1):
        candidate_headers = {
            re.sub(r"[^a-z0-9]+", "_", str(ws.cell(row, col).value).lower()).strip("_"): col
            for col in range(1, ws.max_column + 1)
            if ws.cell(row, col).value is not None
        }
        if "stable_cluster_id" in candidate_headers:
            header_row = row
            headers = candidate_headers
            break
    for row in range(header_row + 1, ws.max_row + 1):
        if ws.cell(row, headers["stable_cluster_id"]).value != "cluster-4":
            continue
        name_header = (
            "display_name"
            if "display_name" in headers
            else "provisional_allele_name"
        )
        classification_header = (
            "classification"
            if "classification" in headers
            else "classification_or_reason"
        )
        ws.cell(row, headers[name_header]).value = "Mafa-B*002:01_0nt_nov"
        ws.cell(row, headers[classification_header]).value = "novel"
wb.save(path)
"""#, currentURL.path])

        let revisedArtifacts = ONTMHCCandidateArtifactManifest(
            schemaVersion: artifacts.schemaVersion,
            genotypingEvidence: artifacts.genotypingEvidence,
            reciprocalEvidence: artifacts.reciprocalEvidence,
            candidateJSON: try artifactReference(candidateJSONURL, relativeTo: fixture.bundleURL),
            candidateFASTA: artifacts.candidateFASTA,
            candidateGenBank: artifacts.candidateGenBank,
            unnameableJSON: artifacts.unnameableJSON,
            unnameableFASTA: artifacts.unnameableFASTA,
            unnameableGenBank: artifacts.unnameableGenBank,
            rawUnmatchedFASTA: artifacts.rawUnmatchedFASTA,
            sourceIdentityMap: artifacts.sourceIdentityMap
        )
        let currentPath = try XCTUnwrap(manifest.currentWorkbookPath)
        let currentSHA256 = try ProvenanceFileHasher.sha256(of: currentURL)
        let currentSizeBytes = Int64(try ProvenanceFileHasher.fileSize(of: currentURL))
        let revisedRevisions = manifest.workbookRevisions?.map { revision in
            guard revision.path == currentPath else { return revision }
            return ONTGenotypeWorkbookRevision(
                id: revision.id,
                role: revision.role,
                path: revision.path,
                label: revision.label,
                sourceFilename: revision.sourceFilename,
                createdAt: revision.createdAt,
                user: revision.user,
                predecessorID: revision.predecessorID,
                predecessorPath: revision.predecessorPath,
                sha256: currentSHA256,
                sizeBytes: currentSizeBytes,
                provenancePath: revision.provenancePath
            )
        }
        manifest = ONTGenotypeResultBundleManifest(
            schemaVersion: manifest.schemaVersion,
            kind: manifest.kind,
            outputName: manifest.outputName,
            analysisName: manifest.analysisName,
            primaryWorkbookPath: manifest.primaryWorkbookPath,
            currentWorkbookPath: manifest.currentWorkbookPath,
            workbookRevisions: revisedRevisions,
            longSummaryCSVPath: manifest.longSummaryCSVPath,
            sampleSummaryCSVPath: manifest.sampleSummaryCSVPath,
            statsJSONPath: manifest.statsJSONPath,
            provenancePath: manifest.provenancePath,
            deduplicatedUnmatchedClustersFASTAPath: manifest.deduplicatedUnmatchedClustersFASTAPath,
            haplotypeAnalysisPath: manifest.haplotypeAnalysisPath,
            haplotypeDefinitionSetID: manifest.haplotypeDefinitionSetID,
            haplotypeAssayID: manifest.haplotypeAssayID,
            presetID: manifest.presetID,
            presetVersion: manifest.presetVersion,
            createdAt: manifest.createdAt,
            activeHaplotypeAnalysisRevisionID: manifest.activeHaplotypeAnalysisRevisionID,
            haplotypeAnalysisRevisions: manifest.haplotypeAnalysisRevisions,
            mhcCandidateArtifacts: revisedArtifacts,
            mhcReferenceVisualizations: manifest.mhcReferenceVisualizations,
            referenceRecordStore: manifest.referenceRecordStore
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: fixture.bundleURL)

        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "Mafa-A1",
                    genotype: "Mafa-A1*018:01:01:01_5nt_nov",
                    sample: "sample-a",
                    stableClusterID: "cluster-1"
                ),
                disposition: .falsePositive,
                author: "reviewer",
                timestamp: "2026-07-24T10:00:00Z"
            )
        ]
        try sidecar.encoded().write(to: annotationURL)

        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL,
            annotationOnly: true
        )

        let output = try runPython(["-c", #"""
import json
import re
import sys
from openpyxl import load_workbook

wb = load_workbook(sys.argv[1], data_only=False)
payload = {}
for sheet_name in ("Unified Genotype Pivot", "Unmatched Alleles"):
    ws = wb[sheet_name]
    for row in range(1, ws.max_row + 1):
        headers = {
            re.sub(r"[^a-z0-9]+", "_", str(ws.cell(row, col).value).lower()).strip("_"): col
            for col in range(1, ws.max_column + 1)
            if ws.cell(row, col).value is not None
        }
        if "stable_cluster_id" not in headers:
            continue
        for data_row in range(row + 1, ws.max_row + 1):
            stable_id = ws.cell(data_row, headers["stable_cluster_id"]).value
            if stable_id == "cluster-1" and sheet_name == "Unified Genotype Pivot":
                cell = ws.cell(data_row, headers["sample_a"])
                payload["review_value"] = str(cell.value)
                payload["review_italic"] = bool(cell.font.italic)
            if stable_id == "cluster-4":
                name_header = (
                    "display_name"
                    if "display_name" in headers
                    else "provisional_allele_name"
                )
                payload[f"legacy_{sheet_name}"] = str(
                    ws.cell(data_row, headers[name_header]).value
                )
        break
payload["has_annotations"] = "Matrix Annotations" in wb.sheetnames
payload["has_audit"] = "Audit Log" in wb.sheetnames
payload["has_guide"] = "Interpretation Guide" in wb.sheetnames
print(json.dumps(payload))
"""#, currentURL.path])
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        )
        XCTAssertEqual(payload["review_value"] as? String, "[7]")
        XCTAssertEqual(payload["review_italic"] as? Bool, true)
        XCTAssertEqual(
            payload["legacy_Unified Genotype Pivot"] as? String,
            "Mafa-B*002:01_0nt_nov"
        )
        XCTAssertEqual(
            payload["legacy_Unmatched Alleles"] as? String,
            "Mafa-B*002:01_0nt_nov"
        )
        XCTAssertEqual(payload["has_annotations"] as? Bool, true)
        XCTAssertEqual(payload["has_audit"] as? Bool, true)
        XCTAssertEqual(payload["has_guide"] as? Bool, false)

        XCTAssertThrowsError(
            try service.applyHaplotypeOverrides(
                [
                    .init(
                        sample: "sample-a",
                        locus: "MHC-A",
                        haplotype1: "A-H1",
                        haplotype2: "",
                        status: "called",
                        notes: ""
                    ),
                ],
                annotationSidecarURL: annotationURL,
                into: fixture.bundleURL
            )
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains(
                    "Candidate cluster-4 has a prohibited or non-authoritative novel label."
                )
            )
        }

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                dateProvider: { Date(timeIntervalSince1970: 7_161) },
                userProvider: { "tester" },
                pythonExecutableURL: testPythonExecutableURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "after-stage-created" else { return }
                    var tamperedWorkbook = try Data(contentsOf: currentURL)
                    tamperedWorkbook.append(0)
                    try tamperedWorkbook.write(to: currentURL, options: .atomic)
                }
            ).applyHaplotypeOverrides(
                [],
                annotationSidecarURL: annotationURL,
                into: fixture.bundleURL,
                annotationOnly: true
            )
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains(
                    "current.xlsx to match its manifest attestation"
                )
            )
        }
    }

    func testTwoSheetRebuildPreservesUnrelatedNativeCommentAndFormatting() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "two-sheet-native-content")
        try installCandidateArtifacts(in: fixture.bundleURL, schemaVersion: 2)
        try installMinimalUnifiedPivot(in: fixture.bundleURL)
        let service = GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 7_175) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        )
        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: nil,
            into: fixture.bundleURL
        )

        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        _ = try runPython(["-c", #"""
import sys
from openpyxl import load_workbook
from openpyxl.comments import Comment
from openpyxl.styles import PatternFill

path = sys.argv[1]
wb = load_workbook(path)
ws = wb["Unified Genotype Pivot"]
header_row = next(
    row for row in range(1, ws.max_row + 1)
    if any(ws.cell(row, col).value == "stable_cluster_id" for col in range(1, ws.max_column + 1))
)
headers = {
    str(ws.cell(header_row, col).value): col
    for col in range(1, ws.max_column + 1)
    if ws.cell(header_row, col).value is not None
}
target_row = next(
    row for row in range(header_row + 1, ws.max_row + 1)
    if ws.cell(row, headers["stable_cluster_id"]).value == "cluster-1"
)
cell = ws.cell(target_row, headers["sample-a"])
cell.comment = Comment("Analyst-owned native note", "analyst")
cell.fill = PatternFill(fill_type="solid", fgColor="FF123456")
cell.font = cell.font.copy(bold=True)
wb.save(path)
"""#, currentURL.path])

        let annotationURL = fixture.bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "Mafa-A1",
                    genotype: "Mafa-A1*018:01:01:01_5nt_nov",
                    sample: "sample-a",
                    stableClusterID: "cluster-1"
                ),
                disposition: .falsePositive,
                author: "reviewer",
                timestamp: "2026-07-24T10:00:00Z"
            )
        ]
        try sidecar.encoded().write(to: annotationURL)
        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )

        let output = try runPython(["-c", #"""
import json
import sys
from openpyxl import load_workbook

wb = load_workbook(sys.argv[1], data_only=False)
ws = wb["Unified Genotype Pivot"]
header_row = next(
    row for row in range(1, ws.max_row + 1)
    if any(ws.cell(row, col).value == "stable_cluster_id" for col in range(1, ws.max_column + 1))
)
headers = {
    str(ws.cell(header_row, col).value): col
    for col in range(1, ws.max_column + 1)
    if ws.cell(header_row, col).value is not None
}
target_row = next(
    row for row in range(header_row + 1, ws.max_row + 1)
    if ws.cell(row, headers["stable_cluster_id"]).value == "cluster-1"
)
cell = ws.cell(target_row, headers["sample-a"])
print(json.dumps({
    "comment": "" if cell.comment is None else cell.comment.text,
    "author": "" if cell.comment is None else cell.comment.author,
    "fill": str(getattr(cell.fill.fgColor, "rgb", ""))[-6:],
    "bold": bool(cell.font.bold),
    "italic": bool(cell.font.italic),
}))
"""#, currentURL.path])
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        )
        XCTAssertEqual(payload["comment"] as? String, "Analyst-owned native note")
        XCTAssertEqual(payload["author"] as? String, "analyst")
        XCTAssertEqual(payload["fill"] as? String, "123456")
        XCTAssertEqual(payload["bold"] as? Bool, true)
        XCTAssertEqual(payload["italic"] as? Bool, true)
    }

    func testTwoSheetRepeatUpdateRetainsAuthoritativeCandidateTintAndOtherNativeStyle() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "two-sheet-repeat-tint")
        try installCandidateArtifacts(in: fixture.bundleURL, schemaVersion: 2)
        try installMinimalUnifiedPivot(in: fixture.bundleURL)
        let service = GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 7_180) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        )
        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: nil,
            into: fixture.bundleURL
        )

        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        let canonicalTint = try runPython(["-c", #"""
import sys
from copy import copy
from openpyxl import load_workbook
from openpyxl.comments import Comment
from openpyxl.styles import PatternFill

path = sys.argv[1]
wb = load_workbook(path)
ws = wb["Unified Genotype Pivot"]
header_row = next(
    row for row in range(1, ws.max_row + 1)
    if any(ws.cell(row, col).value == "stable_cluster_id" for col in range(1, ws.max_column + 1))
)
headers = {
    str(ws.cell(header_row, col).value): col
    for col in range(1, ws.max_column + 1)
    if ws.cell(header_row, col).value is not None
}
target_row = next(
    row for row in range(header_row + 1, ws.max_row + 1)
    if ws.cell(row, headers["stable_cluster_id"]).value == "cluster-1"
)
cell = ws.cell(target_row, headers["display_name"])
canonical = str(getattr(cell.fill.fgColor, "rgb", ""))[-6:]
cell.fill = PatternFill(fill_type="solid", fgColor="FFABCDEF")
font = copy(cell.font)
font.bold = True
cell.font = font
cell.comment = Comment("Native label note", "analyst")
wb.save(path)
print(canonical)
"""#, currentURL.path]).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(canonicalTint.isEmpty)
        XCTAssertNotEqual(canonicalTint, "ABCDEF")

        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: nil,
            into: fixture.bundleURL
        )

        let output = try runPython(["-c", #"""
import json
import sys
from openpyxl import load_workbook

wb = load_workbook(sys.argv[1], data_only=False)
ws = wb["Unified Genotype Pivot"]
header_row = next(
    row for row in range(1, ws.max_row + 1)
    if any(ws.cell(row, col).value == "stable_cluster_id" for col in range(1, ws.max_column + 1))
)
headers = {
    str(ws.cell(header_row, col).value): col
    for col in range(1, ws.max_column + 1)
    if ws.cell(header_row, col).value is not None
}
target_row = next(
    row for row in range(header_row + 1, ws.max_row + 1)
    if ws.cell(row, headers["stable_cluster_id"]).value == "cluster-1"
)
cell = ws.cell(target_row, headers["display_name"])
print(json.dumps({
    "fill": str(getattr(cell.fill.fgColor, "rgb", ""))[-6:],
    "bold": bool(cell.font.bold),
    "comment": "" if cell.comment is None else cell.comment.text,
}))
"""#, currentURL.path])
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        )
        XCTAssertEqual(payload["fill"] as? String, canonicalTint)
        XCTAssertEqual(payload["bold"] as? Bool, true)
        XCTAssertEqual(payload["comment"] as? String, "Native label note")
    }

    func testExplicitUpdateRetainsAllCandidateCategoriesAndUnnameableEvidenceWithNameOnlyTints() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "candidate-workbook")
        XCTAssertEqual(
            try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL).mhcReferenceVisualizations,
            fixture.manifest.mhcReferenceVisualizations
        )
        try installCandidateArtifacts(in: fixture.bundleURL)
        try installMinimalUnifiedPivot(in: fixture.bundleURL)
        let installedManifest = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
        let annotationURL = fixture.bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-20T00:00:00Z")
        sidecar.settings.mhcCandidateDisplay = ONTMHCCandidateDisplaySettings(
            showKnown: false,
            showSharedCandidates: false,
            showSingletonCandidates: false,
            tints: [
                .sharedNovel: AnnotationColor(red: 1, green: 0, blue: 0, alpha: 1),
                .singletonNovel: AnnotationColor(red: 0, green: 1, blue: 0, alpha: 0.5),
                .sharedExtension: AnnotationColor(red: 0, green: 0, blue: 1, alpha: 1),
                .singletonExtension: AnnotationColor(red: 1, green: 1, blue: 0, alpha: 0.25),
            ]
        )
        try sidecar.encoded().write(to: annotationURL)

        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        let before = try ProvenanceFileHasher.sha256(of: currentURL)
        let clock = IncrementingDateProvider(
            start: Date(timeIntervalSince1970: 7_000),
            increment: -1
        )
        let updated = try GenotypeWorkbookRevisionService(
            dateProvider: clock.now,
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        ).applyHaplotypeOverrides([], annotationSidecarURL: annotationURL, into: fixture.bundleURL)
        let after = try ProvenanceFileHasher.sha256(of: currentURL)

        XCTAssertNotEqual(before, after, "Only the explicit update action may rewrite current.xlsx")
        let inspection = try inspectTwoSheetCandidateWorkbook(currentURL)
        XCTAssertEqual(inspection["sheetNames"], "Unified Genotype Pivot|Unmatched Alleles")
        XCTAssertEqual(inspection["candidateIDs"], "cluster-1|cluster-2|cluster-3|cluster-4")
        XCTAssertEqual(inspection["candidateNameFills"], "FFFF0000|8000FF00|FF0000FF|40FFFF00")
        XCTAssertEqual(inspection["unmatchedIDs"], "cluster-1|cluster-2|cluster-3|cluster-4|cluster-u")
        XCTAssertEqual(updated.mhcCandidateArtifacts?.schemaVersion, 1)
        XCTAssertEqual(
            updated.mhcReferenceVisualizations,
            installedManifest.mhcReferenceVisualizations
        )
        let provenanceURL = ONTGenotypeResultBundle.resolvedURL(
            for: try XCTUnwrap(updated.workbookRevisions?.last?.provenancePath),
            in: fixture.bundleURL
        )
        let provenanceData = try Data(contentsOf: provenanceURL)
        let provenance = try XCTUnwrap(String(data: provenanceData, encoding: .utf8))
        let envelope = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: provenanceData)
        XCTAssertTrue(provenance.contains("mhcCandidateTints"))
        XCTAssertTrue(provenance.contains("mhcCandidateVisibilityFiltersApplied"))
        XCTAssertTrue(provenance.contains("openpyxl-runtime"))
        XCTAssertEqual(envelope.options.explicit["action"], .string("update-current-workbook"))
        XCTAssertTrue(provenanceURL.lastPathComponent.contains("update-current-workbook"))
        let pythonStep = try XCTUnwrap(envelope.steps.first(where: { $0.toolName.contains("python openpyxl") }))
        XCTAssertNotNil(pythonStep.startedAt)
        XCTAssertNotNil(pythonStep.completedAt)
        XCTAssertGreaterThanOrEqual(pythonStep.wallTimeSeconds ?? -1, 0)
        XCTAssertTrue(pythonStep.inputs.allSatisfy { $0.path.hasPrefix(fixture.bundleURL.path) })
        XCTAssertTrue(pythonStep.outputs.allSatisfy {
            ($0.originPath ?? $0.path).hasPrefix(fixture.bundleURL.path)
        })
        let durableReplayArgv = try XCTUnwrap(pythonStep.durableReplayArgv)
        XCTAssertTrue(pythonStep.argv.joined(separator: " ").contains(".staging"), "Actual argv should retain execution origin")
        XCTAssertFalse(durableReplayArgv.joined(separator: " ").contains(".staging"))
        XCTAssertFalse(pythonStep.reproducibleCommand.contains(".staging"))
        XCTAssertTrue(durableReplayArgv.dropFirst().allSatisfy {
            $0.isEmpty || $0.hasPrefix(fixture.bundleURL.path)
        })
        for filename in ["apply-current-workbook-overrides.py", "candidate-config.json", "haplotype-calls.json"] {
            let descriptor = try XCTUnwrap(pythonStep.inputs.first(where: { $0.path.hasSuffix(filename) }))
            XCTAssertTrue(FileManager.default.fileExists(atPath: descriptor.path))
            XCTAssertEqual(descriptor.checksumSHA256, try ProvenanceFileHasher.sha256(of: URL(fileURLWithPath: descriptor.path)))
        }
        XCTAssertEqual(envelope.steps.last?.toolName, "lungfish-internal atomic workbook bundle exchange")
        XCTAssertEqual(envelope.output?.path, fixture.bundleURL.path)
        XCTAssertTrue(envelope.outputs.allSatisfy { $0.path.hasPrefix(fixture.bundleURL.path) })
        let workflowWallTime = try XCTUnwrap(envelope.wallTimeSeconds)
        XCTAssertGreaterThanOrEqual(workflowWallTime, 0)
        XCTAssertLessThan(workflowWallTime, 30, "Injected and live clocks must never be mixed")
        let timedSteps = envelope.steps.filter {
            $0.startedAt != nil && $0.completedAt != nil && $0.wallTimeSeconds != nil
        }
        for step in timedSteps {
            let startedAt = try XCTUnwrap(step.startedAt)
            let completedAt = try XCTUnwrap(step.completedAt)
            let wallTime = try XCTUnwrap(step.wallTimeSeconds)
            XCTAssertGreaterThanOrEqual(wallTime, 0)
            XCTAssertEqual(
                wallTime,
                completedAt.timeIntervalSince(startedAt),
                accuracy: 0.000_001
            )
        }
        let timedStepTotal = timedSteps.compactMap(\.wallTimeSeconds).reduce(0, +)
        XCTAssertGreaterThanOrEqual(workflowWallTime, timedStepTotal)

    }

    func testCandidateUpdateRejectsMissingUnifiedPivotWithoutBundleMutation() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "candidate-fallback")
        try installCandidateArtifacts(in: fixture.bundleURL)
        let before = try bundleSnapshot(fixture.bundleURL)

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(pythonExecutableURL: testPythonExecutableURL)
                .applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
    }

    func testExplicitUpdateNormalizesCandidateOnlyArtifactTriplet() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "candidate-only")
        try installCandidateArtifacts(in: fixture.bundleURL, schemaVersion: 2)
        try retainCandidateArtifactCategory(.candidate, in: fixture.bundleURL)
        try installMinimalUnifiedPivot(in: fixture.bundleURL)

        _ = try GenotypeWorkbookRevisionService(pythonExecutableURL: testPythonExecutableURL)
            .applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)

        let inspection = try inspectTwoSheetCandidateWorkbook(
            try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        )
        XCTAssertEqual(inspection["candidateIDs"], "cluster-1|cluster-2|cluster-3|cluster-4")
        XCTAssertEqual(inspection["unmatchedIDs"], "cluster-1|cluster-2|cluster-3|cluster-4")
    }

    func testExplicitUpdateNormalizesUnnameableOnlyArtifactTriplet() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "unnameable-only")
        try installCandidateArtifacts(in: fixture.bundleURL, schemaVersion: 2)
        try retainCandidateArtifactCategory(.unnameable, in: fixture.bundleURL)
        try installMinimalUnifiedPivot(in: fixture.bundleURL)

        _ = try GenotypeWorkbookRevisionService(pythonExecutableURL: testPythonExecutableURL)
            .applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)

        let inspection = try inspectTwoSheetCandidateWorkbook(
            try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        )
        XCTAssertEqual(inspection["candidateIDs"], "")
        XCTAssertEqual(inspection["unmatchedIDs"], "cluster-u")
        XCTAssertEqual(inspection["unnameableTranslationStatus"], "incomplete/unresolved")
    }

    func testSchemaVersionTwoCandidateUpdateUsesCompactRowsAndHeaderNamedPivotColumns() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "candidate-v2")
        try installCandidateArtifacts(in: fixture.bundleURL, schemaVersion: 2)
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        _ = try runPython(["-c", #"""
import sys
from openpyxl import load_workbook
path = sys.argv[1]
wb = load_workbook(path)
ws = wb.create_sheet("Unified Genotype Pivot")
ws.append([
    "display_name", "sample-b", "classification", "stable_cluster_id", "call_type",
    "sample-a", "locus", "support_class", "closest_reference", "match_class",
    "occurrence_count", "sample_count", "total_cluster_reads", "call_id",
])
wb.save(path)
"""#, currentURL.path])

        _ = try GenotypeWorkbookRevisionService(pythonExecutableURL: testPythonExecutableURL)
            .applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)

        let inspection = try inspectTwoSheetCandidateWorkbook(currentURL)
        XCTAssertEqual(inspection["sheetNames"], "Unified Genotype Pivot|Unmatched Alleles")
        XCTAssertEqual(inspection["candidateIDs"], "cluster-1|cluster-2|cluster-3|cluster-4")
        XCTAssertEqual(inspection["unmatchedIDs"], "cluster-1|cluster-2|cluster-3|cluster-4|cluster-u")
    }

    func testBundleCloneAttemptsCopyOnWriteAndFallbackPublishesEquivalentWorkbook() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "clone-fallback")
        let before = try ProvenanceFileHasher.sha256(
            of: ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        )
        let attempted = expectation(description: "copy-on-write clone attempted")

        _ = try GenotypeWorkbookRevisionService(
            pythonExecutableURL: testPythonExecutableURL,
            bundleCloneAttemptObserver: { attempted.fulfill() },
            forceBundleCloneFallback: true
        ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)

        wait(for: [attempted], timeout: 0.1)
        XCTAssertNotEqual(
            try ProvenanceFileHasher.sha256(
                of: ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
            ),
            before
        )
        XCTAssertNoThrow(try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL))
    }

    func testBundleCloneFallbackRemovesPartialCloneAndCopiesWithoutCopyfile() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "partial-clone-fallback")
        let attempts = SendableFlagBox()

        _ = try GenotypeWorkbookRevisionService(
            pythonExecutableURL: testPythonExecutableURL,
            bundleCopyPrimitive: { _, destination, _ in
                attempts.set((attempts.value ?? 0) + 1)
                try? FileManager.default.createDirectory(
                    at: destination,
                    withIntermediateDirectories: false
                )
                try? Data("partial-clone".utf8).write(
                    to: destination.appendingPathComponent("partial.txt")
                )
                errno = ENOTSUP
                return -1
            }
        ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)

        XCTAssertEqual(attempts.value, 1, "copyfile is only the clone attempt; fallback is descriptor-based")
        XCTAssertNoThrow(try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.bundleURL.appendingPathComponent("partial.txt").path
            )
        )
    }

    func testDescriptorCloneRehydratesAppleDoubleMetadataWithoutCopyingCompanionBytes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "appledouble-clone")
        let rawDirectory = fixture.bundleURL.appendingPathComponent(
            "samples/CR1178/savont/strict-qv90-min3/raw",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rawDirectory, withIntermediateDirectories: true)
        let baseURL = rawDirectory.appendingPathComponent("final_asvs.fasta")
        let scientificBytes = Data(">cluster-1\nACGTACGT\n".utf8)
        try scientificBytes.write(to: baseURL)
        let attributeName = "com.lungfish.clone-test"
        let attributeValue = Data("required-metadata".utf8)
        let setStatus = attributeValue.withUnsafeBytes { bytes in
            Darwin.setxattr(
                baseURL.path,
                attributeName,
                bytes.baseAddress,
                bytes.count,
                0,
                0
            )
        }
        XCTAssertEqual(setStatus, 0)
        let appleDoubleURL = rawDirectory.appendingPathComponent("._final_asvs.fasta")
        try Data([0x00, 0x05, 0x16, 0x07, 0x00, 0x02, 0x00, 0x00, 0, 0, 0, 0]).write(
            to: appleDoubleURL
        )

        _ = try GenotypeWorkbookRevisionService(
            pythonExecutableURL: testPythonExecutableURL,
            forceBundleCloneFallback: true
        ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)

        let copiedBaseURL = fixture.bundleURL.appendingPathComponent(
            "samples/CR1178/savont/strict-qv90-min3/raw/final_asvs.fasta"
        )
        XCTAssertEqual(try Data(contentsOf: copiedBaseURL), scientificBytes)
        let attributeSize = Darwin.getxattr(copiedBaseURL.path, attributeName, nil, 0, 0, 0)
        XCTAssertEqual(attributeSize, attributeValue.count)
        var copiedAttribute = [UInt8](repeating: 0, count: max(0, attributeSize))
        let readSize = copiedAttribute.withUnsafeMutableBytes { bytes in
            Darwin.getxattr(
                copiedBaseURL.path,
                attributeName,
                bytes.baseAddress,
                bytes.count,
                0,
                0
            )
        }
        XCTAssertEqual(readSize, attributeValue.count)
        XCTAssertEqual(Data(copiedAttribute), attributeValue)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.bundleURL.appendingPathComponent(
                "samples/CR1178/savont/strict-qv90-min3/raw/._final_asvs.fasta"
            ).path
        ))
    }

    func testUnsupportedDirectorySwapPublishesThroughCrashSafeRotation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "rename-rotation")
        let before = try ProvenanceFileHasher.sha256(
            of: ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        )

        _ = try GenotypeWorkbookRevisionService(
            pythonExecutableURL: testPythonExecutableURL,
            forceBundleCloneFallback: true,
            directorySwapPrimitive: { _, _, _, _, _ in
                errno = ENOTSUP
                return -1
            }
        ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)

        XCTAssertNotEqual(
            try ProvenanceFileHasher.sha256(
                of: ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
            ),
            before
        )
        XCTAssertNoThrow(try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL))
        try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL).path
        ))

        let manifest = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
        let provenanceURL = ONTGenotypeResultBundle.resolvedURL(
            for: try XCTUnwrap(manifest.workbookRevisions?.last?.provenancePath),
            in: fixture.bundleURL
        )
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: provenanceURL)
        )
        XCTAssertEqual(
            envelope.steps.last?.toolName,
            "lungfish-internal ExFAT journaled three-rename workbook rotation v2"
        )
        XCTAssertEqual(
            envelope.steps.last?.argv.dropFirst().first,
            "exfat-journaled-three-rename-v2"
        )
    }

    func testRecoveryRestoresPriorGenerationAfterEveryInterruptedRotationStep() throws {
        for checkpoint in [
            "after-rotation-stage-to-temporary-hard-stop",
            "after-rotation-final-to-stage-hard-stop",
            "after-rotation-temporary-to-final-hard-stop",
        ] {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = try makeMCMWorkbookBundle(
                in: root,
                outputName: "rotation-crash-\(checkpoint)"
            )
            let before = try bundleSnapshot(fixture.bundleURL)

            XCTAssertThrowsError(
                try GenotypeWorkbookRevisionService(
                    pythonExecutableURL: testPythonExecutableURL,
                    publicationFailureInjector: { observed in
                        guard observed == checkpoint else { return }
                        throw NSError(domain: "SimulatedRotationSIGKILL", code: 9)
                    },
                    forceBundleCloneFallback: true,
                    directorySwapPrimitive: { _, _, _, _, _ in
                        errno = ENOTSUP
                        return -1
                    }
                ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
            )

            _ = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

            XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before, checkpoint)
            try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
            try assertNoRetiredWorkbookGeneration(in: root)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL).path
            ))
        }
    }

    func testImmutableMarkerCreateDoesNotDependOnRenameFlags() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "marker-rename-fallback")
        let before = try bundleSnapshot(fixture.bundleURL)
        let renameCalls = SendableFlagBox()

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "post-exchange" else { return }
                    throw NSError(domain: "InjectedPostExchangeFailure", code: 1)
                },
                forceBundleCloneFallback: true,
                directorySwapPrimitive: { _, _, _, _, _ in
                    errno = ENOTSUP
                    return -1
                },
                workbookAtomicRenamePrimitive: { source, destination, flags in
                    renameCalls.set((renameCalls.value ?? 0) + 1)
                    if flags != 0 {
                        errno = ENOTSUP
                        return -1
                    }
                    return Darwin.renameatx_np(AT_FDCWD, source, AT_FDCWD, destination, 0)
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )

        XCTAssertNil(
            renameCalls.value,
            "The ExFAT marker hint is created O_EXCL and never published by replacement rename"
        )
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
        try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL).path
        ))
    }


    func testManualSaveToRetiredGenerationAfterManifestCommitRollsBackAndPreservesEdit() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "manual-save-after-manifest")
        let currentPath = try XCTUnwrap(fixture.manifest.currentWorkbookPath)
        let currentURL = ONTGenotypeResultBundle.resolvedURL(for: currentPath, in: fixture.bundleURL)
        let manifestURL = ONTGenotypeResultBundle.manifestURL(in: fixture.bundleURL)
        let manifestBefore = try Data(contentsOf: manifestURL)
        let pythonURL = testPythonExecutableURL

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: pythonURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "after-revision-manifest-hard-stop" else { return }
                    let marker = try XCTUnwrap(
                        try JSONSerialization.jsonObject(
                            with: Data(contentsOf: ONTGenotypeWorkbookUpdateRecovery.markerURL(
                                for: fixture.bundleURL
                            ))
                        ) as? [String: Any]
                    )
                    let stagedOldURL = URL(
                        fileURLWithPath: try XCTUnwrap(marker["stagingBundlePath"] as? String),
                        isDirectory: true
                    ).appendingPathComponent(currentPath)
                    _ = try Self.runPythonStatic(["-c", #"""
import sys
from openpyxl import load_workbook
path = sys.argv[1]
wb = load_workbook(path)
wb[wb.sheetnames[0]]["Z93"] = "manual-save-after-manifest-survives"
wb.save(path)
"""#, stagedOldURL.path], executableURL: pythonURL)
                },
                forceBundleCloneFallback: true,
                directorySwapPrimitive: { _, _, _, _, _ in
                    errno = ENOTSUP
                    return -1
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        ) { error in
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("changed"))
        }

        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBefore)
        let value = try Self.runPythonStatic(["-c", #"""
import sys
from openpyxl import load_workbook
wb = load_workbook(sys.argv[1], data_only=False)
print(wb[wb.sheetnames[0]]["Z93"].value or "")
"""#, currentURL.path], executableURL: pythonURL)
        XCTAssertEqual(
            value.trimmingCharacters(in: .whitespacesAndNewlines),
            "manual-save-after-manifest-survives"
        )
        try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
        try assertNoRetiredWorkbookGeneration(in: root)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL).path
        ))
    }

    func testManualSaveDuringRotationIsDetectedAndPreservedAtBothOldGenerationBoundaries() throws {
        for (checkpoint, cell) in [
            ("after-rotation-stage-to-temporary-hard-stop", "Z96"),
            ("after-rotation-final-to-stage-hard-stop", "Z95"),
            ("after-rotation-temporary-to-final-hard-stop", "Z92"),
        ] {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = try makeMCMWorkbookBundle(in: root, outputName: "manual-\(cell)")
            let currentPath = try XCTUnwrap(fixture.manifest.currentWorkbookPath)
            let currentURL = ONTGenotypeResultBundle.resolvedURL(
                for: currentPath,
                in: fixture.bundleURL
            )
            let manifestURL = ONTGenotypeResultBundle.manifestURL(in: fixture.bundleURL)
            let manifestBefore = try Data(contentsOf: manifestURL)
            let pythonURL = testPythonExecutableURL
            let didEdit = SendableFlagBox()

            XCTAssertThrowsError(
                try GenotypeWorkbookRevisionService(
                    pythonExecutableURL: pythonURL,
                    publicationFailureInjector: { observed in
                        guard observed == checkpoint, didEdit.value == nil else { return }
                        didEdit.set(1)
                        let editURL: URL
                        if checkpoint != "after-rotation-stage-to-temporary-hard-stop" {
                            let marker = try XCTUnwrap(
                                try JSONSerialization.jsonObject(
                                    with: Data(contentsOf: ONTGenotypeWorkbookUpdateRecovery.markerURL(
                                        for: fixture.bundleURL
                                    ))
                                ) as? [String: Any]
                            )
                            editURL = URL(
                                fileURLWithPath: try XCTUnwrap(marker["stagingBundlePath"] as? String),
                                isDirectory: true
                            ).appendingPathComponent(currentPath)
                        } else {
                            editURL = currentURL
                        }
                        _ = try Self.runPythonStatic(["-c", #"""
import sys
from openpyxl import load_workbook
path, cell = sys.argv[1], sys.argv[2]
wb = load_workbook(path)
wb[wb.sheetnames[0]][cell] = "manual-rotation-survives"
wb.save(path)
"""#, editURL.path, cell], executableURL: pythonURL)
                    },
                    forceBundleCloneFallback: true,
                    directorySwapPrimitive: { _, _, _, _, _ in
                        errno = ENOTSUP
                        return -1
                    }
                ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
            ) { error in
                XCTAssertTrue(
                    error.localizedDescription.localizedCaseInsensitiveContains("changed"),
                    "\(checkpoint): \(error.localizedDescription)"
                )
            }

            XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBefore)
            let value = try Self.runPythonStatic(["-c", #"""
import sys
from openpyxl import load_workbook
wb = load_workbook(sys.argv[1], data_only=False)
print(wb[wb.sheetnames[0]][sys.argv[2]].value or "")
"""#, currentURL.path, cell], executableURL: pythonURL)
            XCTAssertEqual(value.trimmingCharacters(in: .whitespacesAndNewlines), "manual-rotation-survives")
            try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
        }
    }

    func testRecoveryKeepsCommittedGenerationAfterLaterManualWorkbookEdit() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "committed-manual-edit")
        let priorRevisionCount = fixture.manifest.workbookRevisions?.count ?? 0
        let pythonURL = testPythonExecutableURL

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: pythonURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "after-revision-manifest-hard-stop" else { return }
                    throw NSError(domain: "SimulatedSIGKILL", code: 9)
                },
                forceBundleCloneFallback: true,
                directorySwapPrimitive: { _, _, _, _, _ in
                    errno = ENOTSUP
                    return -1
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )
        let committedURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        _ = try Self.runPythonStatic(["-c", #"""
import sys
from openpyxl import load_workbook
path = sys.argv[1]
wb = load_workbook(path)
wb[wb.sheetnames[0]]["Z94"] = "committed-manual-edit-survives"
wb.save(path)
"""#, committedURL.path], executableURL: pythonURL)

        let loaded = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertGreaterThan(loaded.manifest.workbookRevisions?.count ?? 0, priorRevisionCount)
        let value = try Self.runPythonStatic(["-c", #"""
import sys
from openpyxl import load_workbook
wb = load_workbook(sys.argv[1], data_only=False)
print(wb[wb.sheetnames[0]]["Z94"].value or "")
"""#, committedURL.path], executableURL: pythonURL)
        XCTAssertEqual(value.trimmingCharacters(in: .whitespacesAndNewlines), "committed-manual-edit-survives")
        try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
    }

    func testRecoveryPreservesBothGenerationsWhenBothWorkbooksWereEdited() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "both-generations-edited")
        let pythonURL = testPythonExecutableURL

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: pythonURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "after-revision-manifest-hard-stop" else { return }
                    throw NSError(domain: "SimulatedSIGKILL", code: 9)
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )
        let markerURL = ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL)
        let marker = try markerObject(at: markerURL)
        let stagedOld = URL(
            fileURLWithPath: try XCTUnwrap(marker["stagingBundlePath"] as? String),
            isDirectory: true
        )
        let finalCurrent = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        let oldCurrent = stagedOld.appendingPathComponent(try XCTUnwrap(fixture.manifest.currentWorkbookPath))
        for (url, cell, value) in [
            (finalCurrent, "Z91", "edited-new-generation"),
            (oldCurrent, "Z90", "edited-old-generation"),
        ] {
            _ = try Self.runPythonStatic(["-c", #"""
import sys
from openpyxl import load_workbook
path, cell, value = sys.argv[1:4]
wb = load_workbook(path)
wb[wb.sheetnames[0]][cell] = value
wb.save(path)
"""#, url.path, cell, value], executableURL: pythonURL)
        }
        let finalBefore = try bundleSnapshot(fixture.bundleURL)
        let stagedBefore = try bundleSnapshot(stagedOld)

        XCTAssertThrowsError(try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)) { error in
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("ambiguous"))
        }
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), finalBefore)
        XCTAssertEqual(try bundleSnapshot(stagedOld), stagedBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testTornOrMissingMarkerRehydratesFromDetachedAttestation() throws {
        for markerMutation in ["torn", "missing"] {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = try makeMCMWorkbookBundle(in: root, outputName: "attestation-rehydrate-\(markerMutation)")
            let before = try bundleSnapshot(fixture.bundleURL)
            XCTAssertThrowsError(
                try GenotypeWorkbookRevisionService(
                    pythonExecutableURL: testPythonExecutableURL,
                    publicationFailureInjector: { checkpoint in
                        guard checkpoint == "after-transaction-marker-hard-stop" else { return }
                        throw NSError(domain: "SimulatedSIGKILL", code: 9)
                    }
                ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
            )
            let markerURL = ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL)
            if markerMutation == "torn" {
                try Data("{".utf8).write(to: markerURL)
            } else {
                try FileManager.default.removeItem(at: markerURL)
            }

            _ = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

            XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
            try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
        }
    }

    func testPartialMarkerWriteFailureRetainsWALAndPreparedGenerationForRecovery() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "partial-marker-write")
        let before = try bundleSnapshot(fixture.bundleURL)
        let attestationRoot = root.appendingPathComponent("attestations", isDirectory: true)

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                workbookAttestationRootURL: attestationRoot,
                workbookMarkerWriteFailureInjector: { checkpoint in
                    guard checkpoint == "after-marker-open-before-write" else { return }
                    throw NSError(domain: "InjectedMarkerWriteFailure", code: 1)
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )
        let markerURL = ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL)
        XCTAssertEqual(try Data(contentsOf: markerURL), Data())
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: attestationRoot.path)
                .filter { $0.hasSuffix(".json") }.count,
            1
        )
        let marker = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(atPath: root.path).first {
                $0.hasPrefix(".\(fixture.bundleURL.lastPathComponent).workbook-update-")
                    && $0.hasSuffix(".staging")
            }
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(marker).path))

        let lock = try ONTGenotypeBundlePublicationLock.acquire(
            for: fixture.bundleURL,
            blocking: true,
            createIfMissing: false
        )
        defer { lock.release() }
        try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
            for: fixture.bundleURL,
            attestationRootURL: attestationRoot
        )

        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
        try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
    }

    func testMultipleMarkerHintsAndMatchingAttestationsFailClosed() throws {
        for duplicateKind in ["marker", "attestation"] {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = try makeMCMWorkbookBundle(in: root, outputName: "multiple-authority-\(duplicateKind)")
            let attestationRoot = root.appendingPathComponent("attestations", isDirectory: true)
            XCTAssertThrowsError(
                try GenotypeWorkbookRevisionService(
                    pythonExecutableURL: testPythonExecutableURL,
                    publicationFailureInjector: { checkpoint in
                        guard checkpoint == "after-transaction-marker-hard-stop" else { return }
                        throw NSError(domain: "SimulatedSIGKILL", code: 9)
                    },
                    workbookAttestationRootURL: attestationRoot
                ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
            )
            let markerURL = ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL)
            if duplicateKind == "marker" {
                let duplicate = root.appendingPathComponent(
                    ".\(fixture.bundleURL.lastPathComponent).workbook-update-transaction-\(UUID().uuidString).json"
                )
                try FileManager.default.copyItem(at: markerURL, to: duplicate)
            } else {
                let attestation = try XCTUnwrap(
                    try FileManager.default.contentsOfDirectory(at: attestationRoot, includingPropertiesForKeys: nil)
                        .first { $0.pathExtension == "json" }
                )
                try FileManager.default.copyItem(
                    at: attestation,
                    to: attestationRoot.appendingPathComponent("duplicate.json")
                )
            }
            let finalBefore = try bundleSnapshot(fixture.bundleURL)
            if duplicateKind == "marker" {
                let lockURL = ONTGenotypeBundlePublicationLock.lockURL(for: fixture.bundleURL)
                try FileManager.default.removeItem(at: lockURL)
                XCTAssertThrowsError(try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)) {
                    error in
                    XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("multiple"))
                }
                XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), finalBefore)
            }
            let lock = try ONTGenotypeBundlePublicationLock.acquire(
                for: fixture.bundleURL,
                blocking: true,
                createIfMissing: duplicateKind == "marker"
            )

            XCTAssertThrowsError(
                try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                    for: fixture.bundleURL,
                    attestationRootURL: attestationRoot
                )
            ) { error in
                XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("multiple")
                    || error.localizedDescription.localizedCaseInsensitiveContains("matching"))
            }
            lock.release()
            XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), finalBefore)
        }
    }

    func testAutomaticFinalizationDetachesAndRemovesRetiredGeneration() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "retired-generation-cleanup")

        _ = try GenotypeWorkbookRevisionService(
            pythonExecutableURL: testPythonExecutableURL
        ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)

        XCTAssertNoThrow(try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL))
        XCTAssertTrue(try workbookCleanupArtifacts(in: root).isEmpty)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path).contains {
                $0.hasPrefix(".lungfish-workbook-generation-archive-")
            }
        )
    }

    func testWorkbookCleanupRecoversAfterEveryDurabilityBoundary() throws {
        let branches = [
            "committed",
            "prepared-discard",
            "rollback",
            "manual-save-winner",
        ]
        let checkpoints = [
            "after-workbook-cleanup-detach-hard-stop",
            "after-workbook-cleanup-state-durable-hard-stop",
            "after-workbook-cleanup-marker-removal-hard-stop",
        ]
        for branch in branches {
            for checkpoint in checkpoints {
                let root = try temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let fixture = try makeMCMWorkbookBundle(
                    in: root,
                    outputName: "cleanup-\(branch)-\(checkpoint)"
                )
                let attestationRoot = root.appendingPathComponent(
                    "attestations",
                    isDirectory: true
                )

                try interruptWorkbookCleanup(
                    branch: branch,
                    fixture: fixture,
                    attestationRoot: attestationRoot
                )

                XCTAssertNoThrow(
                    try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
                )
                XCTAssertFalse(
                    try FileManager.default.contentsOfDirectory(atPath: root.path).contains {
                        $0.hasPrefix(".lungfish-workbook-generation-archive-")
                    }
                )
                let lock = try ONTGenotypeBundlePublicationLock.acquire(
                    for: fixture.bundleURL,
                    blocking: true,
                    createIfMissing: false
                )
                defer { lock.release() }
                XCTAssertThrowsError(
                    try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                        for: fixture.bundleURL,
                        attestationRootURL: attestationRoot,
                        cleanupFailureInjector: { observed in
                            guard observed == checkpoint else { return }
                            throw NSError(
                                domain: "InjectedWorkbookCleanupCrash",
                                code: 9
                            )
                        }
                    ),
                    "\(branch) @ \(checkpoint)"
                )
                XCTAssertFalse(try workbookCleanupArtifacts(in: root).isEmpty)
                try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                    for: fixture.bundleURL,
                    attestationRootURL: attestationRoot
                )

                XCTAssertNoThrow(
                    try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL),
                    "\(branch) @ \(checkpoint)"
                )
                XCTAssertTrue(try workbookCleanupArtifacts(in: root).isEmpty)
                XCTAssertFalse(FileManager.default.fileExists(
                    atPath: ONTGenotypeWorkbookUpdateRecovery.markerURL(
                        for: fixture.bundleURL
                    ).path
                ))
                try assertNoRetiredWorkbookGeneration(in: root)
            }
        }
    }

    func testWorkbookCleanupTraversalFailureRecordsRetryWarning() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "cleanup-traversal")
        let attestationRoot = root.appendingPathComponent("attestations", isDirectory: true)
        try interruptCommittedWorkbookCleanup(
            fixture: fixture,
            attestationRoot: attestationRoot
        )
        let lock = try ONTGenotypeBundlePublicationLock.acquire(
            for: fixture.bundleURL,
            blocking: true,
            createIfMissing: false
        )
        defer { lock.release() }

        XCTAssertThrowsError(
            try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                for: fixture.bundleURL,
                attestationRootURL: attestationRoot,
                cleanupFailureInjector: { checkpoint in
                    guard checkpoint == "during-workbook-cleanup-traversal" else { return }
                    throw NSError(domain: "InjectedWorkbookCleanupTraversal", code: 5)
                }
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("cleanup-pending"))
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("retry"))
        }

        let artifacts = try workbookCleanupArtifacts(in: root)
        XCTAssertTrue(artifacts.contains { $0.lastPathComponent.contains("cleanup-state") })
        XCTAssertTrue(artifacts.contains { $0.lastPathComponent.contains("cleanup-warning") })
        let warningURL = try XCTUnwrap(
            artifacts.first { $0.lastPathComponent.contains("cleanup-warning") }
        )
        let warning = try JSONSerialization.jsonObject(
            with: Data(contentsOf: warningURL)
        ) as? [String: Any]
        XCTAssertEqual(warning?["retryState"] as? String, "cleanup-pending")
        XCTAssertTrue(
            (warning?["quarantinePath"] as? String)?.contains(
                ".lungfish-workbook-cleanup-pending-"
            ) == true
        )

        try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
            for: fixture.bundleURL,
            attestationRootURL: attestationRoot
        )
        XCTAssertNoThrow(try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL))
        XCTAssertFalse(
            try workbookCleanupArtifacts(in: root).contains {
                $0.lastPathComponent.contains("cleanup-state")
                    || $0.lastPathComponent.contains("cleanup-pending")
            }
        )
    }

    func testMarkerlessCleanupRetryRetainsQuarantineWhenSurvivorIsMissing() throws {
        let paused = try pausedCommittedWorkbookCleanup(
            outputName: "cleanup-missing-survivor"
        )
        defer {
            paused.lock.release()
            try? FileManager.default.removeItem(at: paused.root)
        }
        let held = paused.root.appendingPathComponent(
            "held-surviving-generation",
            isDirectory: true
        )
        let warningPathsBefore = Set(
            try workbookCleanupArtifacts(in: paused.root)
                .filter { $0.lastPathComponent.contains(".workbook-cleanup-warning-") }
                .map(\.lastPathComponent)
        )
        try FileManager.default.moveItem(at: paused.fixture.bundleURL, to: held)

        var reportedWarningURL: URL?
        var reportedQuarantinePath: String?
        XCTAssertThrowsError(
            try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                for: paused.fixture.bundleURL,
                attestationRootURL: paused.attestationRoot
            )
        ) { error in
            guard case let ONTGenotypeWorkbookUpdateRecoveryError
                .cleanupPendingWarning(
                    quarantinePath,
                    retryState,
                    warningPath,
                    reason
                ) = error else {
                return XCTFail(
                    "Expected structured cleanup warning, got \(error.localizedDescription)"
                )
            }
            XCTAssertEqual(
                URL(fileURLWithPath: quarantinePath).resolvingSymlinksInPath(),
                paused.quarantine.resolvingSymlinksInPath()
            )
            XCTAssertEqual(retryState, "cleanup-pending")
            XCTAssertTrue(
                reason.localizedCaseInsensitiveContains(
                    "surviving workbook generation"
                )
            )
            reportedWarningURL = URL(fileURLWithPath: warningPath)
            reportedQuarantinePath = quarantinePath
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: paused.quarantine.path))
        let warningURL = try XCTUnwrap(reportedWarningURL)
        let expectedWarningPrefix =
            ".\(paused.fixture.bundleURL.lastPathComponent).workbook-cleanup-warning-"
        XCTAssertTrue(warningURL.lastPathComponent.hasPrefix(expectedWarningPrefix))
        XCTAssertTrue(warningURL.lastPathComponent.hasSuffix(".json"))
        XCTAssertEqual(warningURL.deletingLastPathComponent(), paused.root)
        let warningPathsAfter = Set(
            try workbookCleanupArtifacts(in: paused.root)
                .filter { $0.lastPathComponent.contains(".workbook-cleanup-warning-") }
                .map(\.lastPathComponent)
        )
        XCTAssertEqual(
            warningPathsAfter.subtracting(warningPathsBefore),
            Set([warningURL.lastPathComponent])
        )
        let warning = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: warningURL)
            ) as? [String: Any]
        )
        XCTAssertEqual(warning["schemaVersion"] as? Int, 1)
        XCTAssertEqual(warning["finalBundlePath"] as? String, paused.fixture.bundleURL.path)
        XCTAssertEqual(
            warning["quarantinePath"] as? String,
            try XCTUnwrap(reportedQuarantinePath)
        )
        XCTAssertEqual(warning["retryState"] as? String, "cleanup-pending")
        XCTAssertTrue(
            (warning["reason"] as? String)?.localizedCaseInsensitiveContains(
                "surviving workbook generation"
            ) == true
        )
    }

    func testMarkerlessCleanupRetryRetainsQuarantineWhenSurvivorIsSubstituted() throws {
        let paused = try pausedCommittedWorkbookCleanup(
            outputName: "cleanup-substituted-survivor"
        )
        defer {
            paused.lock.release()
            try? FileManager.default.removeItem(at: paused.root)
        }
        let held = paused.root.appendingPathComponent(
            "held-surviving-generation",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: paused.fixture.bundleURL, to: held)
        try FileManager.default.copyItem(at: held, to: paused.fixture.bundleURL)

        XCTAssertThrowsError(
            try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                for: paused.fixture.bundleURL,
                attestationRootURL: paused.attestationRoot
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.localizedCaseInsensitiveContains(
                    "surviving workbook generation"
                )
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: paused.quarantine.path))
        XCTAssertFalse(try workbookCleanupArtifacts(in: paused.root).isEmpty)
    }

    func testMarkerlessCleanupRetryRetainsQuarantineWhenSurvivorIntegrityIsCorrupt() throws {
        for target in ["manifest", "workbook"] {
            let paused = try pausedCommittedWorkbookCleanup(
                outputName: "cleanup-corrupt-\(target)"
            )
            defer {
                paused.lock.release()
                try? FileManager.default.removeItem(at: paused.root)
            }
            let targetURL: URL
            if target == "manifest" {
                targetURL = ONTGenotypeResultBundle.manifestURL(
                    in: paused.fixture.bundleURL
                )
            } else {
                targetURL = try ONTGenotypeResultBundle.currentWorkbookURL(
                    for: paused.fixture.bundleURL
                )
            }
            try Data("corrupt-survivor".utf8).write(to: targetURL, options: .atomic)

            XCTAssertThrowsError(
                try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                    for: paused.fixture.bundleURL,
                    attestationRootURL: paused.attestationRoot
                )
            ) { error in
                XCTAssertTrue(
                    error.localizedDescription.localizedCaseInsensitiveContains(
                        "surviving workbook generation"
                    )
                )
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: paused.quarantine.path))
            XCTAssertFalse(try workbookCleanupArtifacts(in: paused.root).isEmpty)
        }
    }

    func testWorkbookCleanupRetryNeverDeletesSubstitutedQuarantineInode() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "cleanup-substitution")
        let attestationRoot = root.appendingPathComponent("attestations", isDirectory: true)
        let held = root.appendingPathComponent("held-retired-generation", isDirectory: true)
        let replacementSentinel = Data("replacement-must-survive".utf8)
        try interruptCommittedWorkbookCleanup(
            fixture: fixture,
            attestationRoot: attestationRoot
        )
        let lock = try ONTGenotypeBundlePublicationLock.acquire(
            for: fixture.bundleURL,
            blocking: true,
            createIfMissing: false
        )
        defer { lock.release() }

        XCTAssertThrowsError(
            try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                for: fixture.bundleURL,
                attestationRootURL: attestationRoot,
                cleanupFailureInjector: { checkpoint in
                    guard checkpoint == "during-workbook-cleanup-traversal" else { return }
                    let quarantine = try XCTUnwrap(
                        try FileManager.default.contentsOfDirectory(
                            at: root,
                            includingPropertiesForKeys: nil
                        ).first {
                            $0.lastPathComponent.hasPrefix(
                                ".lungfish-workbook-cleanup-pending-"
                            )
                        }
                    )
                    try FileManager.default.moveItem(at: quarantine, to: held)
                    try FileManager.default.createDirectory(
                        at: quarantine,
                        withIntermediateDirectories: false
                    )
                    try replacementSentinel.write(
                        to: quarantine.appendingPathComponent("replacement.txt")
                    )
                }
            )
        )

        let replacement = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            ).first {
                $0.lastPathComponent.hasPrefix(
                    ".lungfish-workbook-cleanup-pending-"
                )
            }
        )
        XCTAssertEqual(
            try Data(contentsOf: replacement.appendingPathComponent("replacement.txt")),
            replacementSentinel
        )
        XCTAssertNoThrow(try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL))

        XCTAssertThrowsError(
            try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                for: fixture.bundleURL,
                attestationRootURL: attestationRoot
            )
        )
        XCTAssertEqual(
            try Data(contentsOf: replacement.appendingPathComponent("replacement.txt")),
            replacementSentinel
        )
        XCTAssertFalse(try bundleSnapshot(held).isEmpty)
    }

    func testWorkbookCleanupNeverUnlinksSubstitutedRegularEntry() throws {
        let paused = try pausedCommittedWorkbookCleanup(
            outputName: "cleanup-regular-entry-substitution"
        )
        defer {
            paused.lock.release()
            try? FileManager.default.removeItem(at: paused.root)
        }
        let entry = paused.quarantine.appendingPathComponent("race-entry.txt")
        let held = paused.root.appendingPathComponent("held-original-entry.txt")
        let original = Data("original-retired-bytes".utf8)
        let replacement = Data("replacement-must-survive".utf8)
        try original.write(to: entry)
        let substituted = SendableFlagBox()

        XCTAssertThrowsError(
            try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                for: paused.fixture.bundleURL,
                attestationRootURL: paused.attestationRoot,
                cleanupFailureInjector: { checkpoint in
                    guard checkpoint.hasPrefix(
                        "before-workbook-cleanup-nondirectory-detach:"
                    ), checkpoint.hasSuffix("/race-entry.txt") else {
                        return
                    }
                    try FileManager.default.moveItem(at: entry, to: held)
                    try replacement.write(to: entry)
                    substituted.set(1)
                }
            )
        )

        XCTAssertEqual(substituted.value, 1)
        XCTAssertEqual(try Data(contentsOf: held), original)
        XCTAssertEqual(try Data(contentsOf: entry), replacement)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paused.quarantine.path))
    }

    func testMarkerlessCleanupDiscoveryUsesIdentityBoundActualBundleCasing() throws {
        let paused = try pausedCommittedWorkbookCleanup(
            outputName: "cleanup-case-discovery"
        )
        defer {
            paused.lock.release()
            try? FileManager.default.removeItem(at: paused.root)
        }
        let alternateName = paused.fixture.bundleURL.lastPathComponent.uppercased()
        guard alternateName != paused.fixture.bundleURL.lastPathComponent else {
            throw XCTSkip("Fixture name has no alternate casing")
        }
        let alternateURL = paused.fixture.bundleURL.deletingLastPathComponent()
            .appendingPathComponent(alternateName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: alternateURL.path) else {
            throw XCTSkip("Volume is case-sensitive")
        }

        try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
            for: alternateURL,
            attestationRootURL: paused.attestationRoot
        )

        XCTAssertNoThrow(
            try ONTGenotypeResultBundle.loadResult(from: paused.fixture.bundleURL)
        )
        XCTAssertFalse(
            try workbookCleanupArtifacts(in: paused.root).contains {
                $0.lastPathComponent.contains("cleanup-state")
                    || $0.lastPathComponent.contains("cleanup-pending")
            }
        )
    }

    func testCleanupReceiptsRemainPendingUntilQuarantineDeletionIsDurable() throws {
        let paused = try pausedCommittedWorkbookCleanup(
            outputName: "cleanup-receipt-disposition"
        )
        defer {
            paused.lock.release()
            try? FileManager.default.removeItem(at: paused.root)
        }
        func receipts() throws -> [[String: Any]] {
            try FileManager.default.contentsOfDirectory(
                at: paused.root,
                includingPropertiesForKeys: nil
            )
            .filter {
                $0.lastPathComponent.contains(".workbook-update-recovery-")
                    && $0.pathExtension == "json"
            }
            .map {
                try XCTUnwrap(
                    try JSONSerialization.jsonObject(
                        with: Data(contentsOf: $0)
                    ) as? [String: Any]
                )
            }
        }
        let pending = try receipts()
        XCTAssertTrue(pending.contains {
            $0["action"] as? String == "workbook-cleanup-authorized"
                && $0["exitStatus"] as? Int == 75
        })
        XCTAssertFalse(pending.contains {
            ($0["action"] as? String)?.hasPrefix("finished-") == true
                && $0["exitStatus"] as? Int == 0
        })

        try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
            for: paused.fixture.bundleURL,
            attestationRootURL: paused.attestationRoot
        )

        let completed = try receipts()
        XCTAssertTrue(completed.contains {
            $0["action"] as? String == "finished-committed-cleanup"
                && $0["exitStatus"] as? Int == 0
        })
        XCTAssertFalse(
            try workbookCleanupArtifacts(in: paused.root).contains {
                $0.lastPathComponent.contains("cleanup-state")
                    || $0.lastPathComponent.contains("cleanup-pending")
            }
        )
    }

    func testCleanupStateTransactionTamperingBeforeAuthorizedReceiptPreservesLiveAuthority() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(
            in: root,
            outputName: "cleanup-state-live-authority-tamper"
        )
        let attestationRoot = root.appendingPathComponent(
            "attestations",
            isDirectory: true
        )
        try interruptCommittedWorkbookCleanup(
            fixture: fixture,
            attestationRoot: attestationRoot
        )
        let lock = try ONTGenotypeBundlePublicationLock.acquire(
            for: fixture.bundleURL,
            blocking: true,
            createIfMissing: false
        )
        defer { lock.release() }
        XCTAssertThrowsError(
            try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                for: fixture.bundleURL,
                attestationRootURL: attestationRoot,
                cleanupFailureInjector: { checkpoint in
                    guard checkpoint
                        == "after-workbook-cleanup-state-durable-hard-stop" else {
                        return
                    }
                    throw NSError(
                        domain: "InjectedCleanupStateBeforeReceiptCrash",
                        code: 9
                    )
                }
            )
        )
        let stateURL = try workbookCleanupStateURL(in: root)
        let quarantine = try XCTUnwrap(
            try workbookCleanupArtifacts(in: root).first {
                $0.lastPathComponent.hasPrefix(
                    ".lungfish-workbook-cleanup-pending-"
                )
            }
        )
        let markerURL = ONTGenotypeWorkbookUpdateRecovery.markerURL(
            for: fixture.bundleURL
        )
        let attestationBefore = try Dictionary(
            uniqueKeysWithValues: FileManager.default.contentsOfDirectory(
                at: attestationRoot,
                includingPropertiesForKeys: nil
            ).map { ($0.lastPathComponent, try Data(contentsOf: $0)) }
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertFalse(
            try workbookRecoveryReceiptActions(in: root).contains(
                "workbook-cleanup-authorized"
            )
        )
        try mutateJSONObject(at: stateURL) { state in
            var transaction = try XCTUnwrap(
                state["transaction"] as? [String: Any]
            )
            transaction["toolVersion"] = "forged-cleanup-tool-version"
            state["transaction"] = transaction
        }
        let sentinelURL = quarantine.appendingPathComponent(
            "replacement-must-not-be-traversed.txt"
        )
        let sentinel = Data("unrelated replacement".utf8)
        try sentinel.write(to: sentinelURL)

        XCTAssertThrowsError(
            try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                for: fixture.bundleURL,
                attestationRootURL: attestationRoot
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.localizedCaseInsensitiveContains(
                    "cleanup state"
                )
                    || error.localizedDescription
                        .localizedCaseInsensitiveContains("authority"),
                error.localizedDescription
            )
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertEqual(
            try Dictionary(
                uniqueKeysWithValues: FileManager.default.contentsOfDirectory(
                    at: attestationRoot,
                    includingPropertiesForKeys: nil
                ).map { ($0.lastPathComponent, try Data(contentsOf: $0)) }
            ),
            attestationBefore
        )
        XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinel)
        XCTAssertFalse(
            try workbookRecoveryReceiptActions(in: root).contains(
                "workbook-cleanup-authorized"
            )
        )
    }

    func testPostReceiptCleanupStateRejectsEveryForgedDerivedAuthority() throws {
        let paused = try pausedCommittedWorkbookCleanup(
            outputName: "cleanup-state-derived-authority-tamper"
        )
        defer {
            paused.lock.release()
            try? FileManager.default.removeItem(at: paused.root)
        }
        let stateURL = try workbookCleanupStateURL(in: paused.root)
        let originalState = try Data(contentsOf: stateURL)
        typealias Mutation = (inout [String: Any]) throws -> Void
        let mutations: [(String, Mutation)] = [
            ("parent identity", { state in
                var identity = try XCTUnwrap(
                    state["parentIdentity"] as? [String: Any]
                )
                identity["inode"] = NSNumber(value: UInt64.max - 101)
                state["parentIdentity"] = identity
            }),
            ("source and quarantine identity", { state in
                let forged = NSNumber(value: UInt64.max - 102)
                var source = try XCTUnwrap(
                    state["sourceIdentity"] as? [String: Any]
                )
                var quarantine = try XCTUnwrap(
                    state["quarantineIdentity"] as? [String: Any]
                )
                source["inode"] = forged
                quarantine["inode"] = forged
                state["sourceIdentity"] = source
                state["quarantineIdentity"] = quarantine
            }),
            ("survivor identity", { state in
                var identity = try XCTUnwrap(
                    state["survivorIdentity"] as? [String: Any]
                )
                identity["device"] = NSNumber(value: UInt64.max - 103)
                state["survivorIdentity"] = identity
            }),
            ("survivor manifest descriptor", { state in
                var descriptor = try XCTUnwrap(
                    state["survivorManifest"] as? [String: Any]
                )
                descriptor["sha256"] = String(repeating: "a", count: 64)
                state["survivorManifest"] = descriptor
            }),
            ("survivor workbook descriptor", { state in
                var descriptor = try XCTUnwrap(
                    state["survivorCurrentWorkbook"] as? [String: Any]
                )
                descriptor["sizeBytes"] = NSNumber(value: -1)
                state["survivorCurrentWorkbook"] = descriptor
            }),
            ("terminal receipt disposition", { state in
                state["terminalReceiptAction"] = "forged-finished-cleanup"
                state["terminalReceiptDetail"] = "forged terminal detail"
            }),
        ]

        for (name, mutation) in mutations {
            try originalState.write(to: stateURL, options: .atomic)
            try mutateJSONObject(at: stateURL, mutation)
            XCTAssertThrowsError(
                try ONTGenotypeWorkbookUpdateRecovery.recoveryAuthorityExists(
                    for: paused.fixture.bundleURL
                ),
                name
            ) { error in
                XCTAssertTrue(
                    error.localizedDescription.localizedCaseInsensitiveContains(
                        "invalid workbook cleanup state"
                    ),
                    "\(name): \(error.localizedDescription)"
                )
            }
        }
        try originalState.write(to: stateURL, options: .atomic)
    }

    func testPostReceiptSemanticTamperingNeverTraversesCleanupQuarantine() throws {
        let paused = try pausedCommittedWorkbookCleanup(
            outputName: "cleanup-state-semantic-traversal-tamper"
        )
        defer {
            paused.lock.release()
            try? FileManager.default.removeItem(at: paused.root)
        }
        let stateURL = try workbookCleanupStateURL(in: paused.root)
        try mutateJSONObject(at: stateURL) { state in
            state["terminalReceiptAction"] = "forged-finished-cleanup"
        }
        let sentinelURL = paused.quarantine.appendingPathComponent(
            "replacement-must-not-be-traversed.txt"
        )
        let sentinel = Data("replacement survives semantic tamper".utf8)
        try sentinel.write(to: sentinelURL)
        let traversed = SendableFlagBox()

        XCTAssertThrowsError(
            try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                for: paused.fixture.bundleURL,
                attestationRootURL: paused.attestationRoot,
                cleanupFailureInjector: { checkpoint in
                    guard checkpoint == "during-workbook-cleanup-traversal" else {
                        return
                    }
                    traversed.set(1)
                    throw NSError(
                        domain: "UnexpectedCleanupTraversal",
                        code: 1
                    )
                }
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.localizedCaseInsensitiveContains(
                    "invalid workbook cleanup state"
                ),
                error.localizedDescription
            )
        }

        XCTAssertNil(traversed.value)
        XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinel)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: paused.quarantine.path)
        )
    }

    func testCleanupWarningPersistenceFailurePreservesOriginalStructuredCause() throws {
        let paused = try pausedCommittedWorkbookCleanup(
            outputName: "cleanup-warning-write-failure"
        )
        defer {
            paused.lock.release()
            try? FileManager.default.removeItem(at: paused.root)
        }
        let held = paused.root.appendingPathComponent(
            "held-missing-survivor",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: paused.fixture.bundleURL, to: held)

        XCTAssertThrowsError(
            try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                for: paused.fixture.bundleURL,
                attestationRootURL: paused.attestationRoot,
                cleanupFailureInjector: { checkpoint in
                    guard checkpoint == "before-workbook-cleanup-warning-write" else {
                        return
                    }
                    throw NSError(
                        domain: "InjectedWorkbookCleanupWarningWrite",
                        code: 17,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "injected warning persistence failure",
                        ]
                    )
                }
            )
        ) { error in
            guard case let ONTGenotypeWorkbookUpdateRecoveryError
                .cleanupPendingWarningPersistenceFailure(
                    quarantinePath,
                    retryState,
                    reason,
                    warningFailure
                ) = error else {
                return XCTFail("Expected combined cleanup warning failure: \(error)")
            }
            XCTAssertEqual(retryState, "cleanup-pending")
            XCTAssertEqual(
                URL(fileURLWithPath: quarantinePath)
                    .resolvingSymlinksInPath().path,
                paused.quarantine.resolvingSymlinksInPath().path
            )
            XCTAssertTrue(
                reason.localizedCaseInsensitiveContains(
                    "surviving workbook generation"
                )
            )
            XCTAssertEqual(warningFailure, "injected warning persistence failure")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: paused.quarantine.path))
    }

    func testDefaultBundleCopyPrimitiveReceivesRecursiveCloneNoFollowFlags() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "clone-flags")
        let observedFlags = SendableFlagBox()

        _ = try GenotypeWorkbookRevisionService(
            pythonExecutableURL: testPythonExecutableURL,
            bundleCopyPrimitive: { source, destination, copyFlags in
                observedFlags.set(copyFlags)
                return Darwin.copyfile(
                    source.path,
                    destination.path,
                    nil,
                    copyfile_flags_t(copyFlags)
                )
            }
        ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)

        let expected = UInt32(
            COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE | COPYFILE_NOFOLLOW | COPYFILE_EXCL
        )
        XCTAssertEqual(observedFlags.value, expected)
        XCTAssertNoThrow(try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL))
    }

    func testNestedBundleSymlinkIsRejectedBeforeCopyPrimitiveRuns() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "clone-symlink")
        let outside = root.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.bundleURL.appendingPathComponent("artifacts/nested-unsafe-link"),
            withDestinationURL: outside
        )
        let observedFlags = SendableFlagBox()

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                bundleCopyPrimitive: { _, _, flags in
                    observedFlags.set(flags)
                    return 1
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )

        XCTAssertNil(observedFlags.value)
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
    }

    func testMalformedCandidateArtifactFailsWithoutMutatingWorkbookOrManifest() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "candidate-rollback")
        try installCandidateArtifacts(in: fixture.bundleURL)
        let candidateJSONURL = fixture.bundleURL
            .appendingPathComponent("artifacts/mhc-candidates/candidate-alleles.json")
        try Data("{malformed".utf8).write(to: candidateJSONURL, options: .atomic)
        let before = try bundleSnapshot(fixture.bundleURL)

        let service = serviceThatFailsIfStagingBegins()
        XCTAssertThrowsError(
            try service.applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        ) { error in
            XCTAssertNotEqual((error as NSError).domain, "UnexpectedWorkbookUpdateStaging")
        }
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.bundleURL.appendingPathComponent("artifacts/workbooks/updates").path
        ))
    }

    func testCandidateGenBankIdentityMismatchFailsBeforeWorkbookReplacement() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "candidate-genbank-identity")
        try installCandidateArtifacts(in: fixture.bundleURL)
        let manifest = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
        let artifacts = try XCTUnwrap(manifest.mhcCandidateArtifacts)
        let candidateGenBankURL = ONTGenotypeResultBundle.resolvedURL(
            for: try XCTUnwrap(artifacts.candidateGenBank).path,
            in: fixture.bundleURL
        )
        var records = try GenBankReader(url: candidateGenBankURL).readAllSync()
        let first = try XCTUnwrap(records.first)
        records[0] = try normalizedCandidateGenBankRecord(
            stableID: "wrong-cluster-id",
            sequence: first.sequence.asString(),
            translation: "AAAAAAAAAAAAA",
            status: "full-length"
        )
        try GenBankWriter(url: candidateGenBankURL).write(records)
        let revisedArtifacts = ONTMHCCandidateArtifactManifest(
            schemaVersion: artifacts.schemaVersion,
            genotypingEvidence: artifacts.genotypingEvidence,
            reciprocalEvidence: artifacts.reciprocalEvidence,
            candidateJSON: artifacts.candidateJSON,
            candidateFASTA: artifacts.candidateFASTA,
            candidateGenBank: try artifactReference(candidateGenBankURL, relativeTo: fixture.bundleURL),
            unnameableJSON: artifacts.unnameableJSON,
            unnameableFASTA: artifacts.unnameableFASTA,
            unnameableGenBank: artifacts.unnameableGenBank
        )
        let revisedManifest = ONTGenotypeResultBundleManifest(
            schemaVersion: manifest.schemaVersion,
            kind: manifest.kind,
            outputName: manifest.outputName,
            analysisName: manifest.analysisName,
            primaryWorkbookPath: manifest.primaryWorkbookPath,
            currentWorkbookPath: manifest.currentWorkbookPath,
            workbookRevisions: manifest.workbookRevisions,
            longSummaryCSVPath: manifest.longSummaryCSVPath,
            sampleSummaryCSVPath: manifest.sampleSummaryCSVPath,
            statsJSONPath: manifest.statsJSONPath,
            provenancePath: manifest.provenancePath,
            mhcCandidateArtifacts: revisedArtifacts,
            mhcReferenceVisualizations: manifest.mhcReferenceVisualizations,
            referenceRecordStore: manifest.referenceRecordStore
        )
        try ONTGenotypeResultBundle.writeManifest(revisedManifest, to: fixture.bundleURL)
        let before = try bundleSnapshot(fixture.bundleURL)

        XCTAssertThrowsError(
            try serviceThatFailsIfStagingBegins()
                .applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        ) { error in
            XCTAssertNotEqual((error as NSError).domain, "UnexpectedWorkbookUpdateStaging")
            XCTAssertTrue(error.localizedDescription.contains("Invalid unmatched MHC artifact identity"))
        }
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
    }

    func testAmbiguousManagedCandidateMarkersFailClosedWithoutBundleMutation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "ambiguous-candidate-markers")
        try installCandidateArtifacts(in: fixture.bundleURL)
        try installMinimalUnifiedPivot(in: fixture.bundleURL)
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        _ = try runPython(["-c", #"""
import sys
from openpyxl import load_workbook
path = sys.argv[1]
wb = load_workbook(path)
wb["Full Sequencing Results 1"].append(["LGE MHC Candidate Alleles [BEGIN]"])
wb.save(path)
"""#, currentURL.path])
        XCTAssertNoThrow(
            try GenotypeWorkbookRevisionService(pythonExecutableURL: testPythonExecutableURL)
                .applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )
        let inspection = try inspectTwoSheetCandidateWorkbook(currentURL)
        XCTAssertEqual(inspection["sheetNames"], "Unified Genotype Pivot|Unmatched Alleles")
    }

    func testMalformedCandidateDoesNotCreateInitiallyAbsentCurrentWorkbookOrRevisionArtifacts() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "candidate-no-current")
        try installCandidateArtifacts(in: fixture.bundleURL)
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        try FileManager.default.removeItem(at: currentURL)
        try writeManifestWithoutCurrent(in: fixture.bundleURL)
        let candidateJSONURL = fixture.bundleURL.appendingPathComponent("artifacts/mhc-candidates/candidate-alleles.json")
        try Data("{malformed".utf8).write(to: candidateJSONURL, options: .atomic)
        let before = try bundleSnapshot(fixture.bundleURL)

        let service = serviceThatFailsIfStagingBegins()
        XCTAssertThrowsError(
            try service.applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        ) { error in
            XCTAssertNotEqual((error as NSError).domain, "UnexpectedWorkbookUpdateStaging")
        }
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: currentURL.path))
    }

    func testFinalProvenanceFailureAtomicallyRestoresEntireBundle() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "candidate-provenance-rollback")
        try installCandidateArtifacts(in: fixture.bundleURL)
        try installMinimalUnifiedPivot(in: fixture.bundleURL)
        let before = try bundleSnapshot(fixture.bundleURL)

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                publicationFailureInjector: { checkpoint in
                    if checkpoint == "before-final-provenance" {
                        throw NSError(domain: "InjectedFinalProvenanceFailure", code: 1)
                    }
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
    }

    func testPostExchangeFailureRestoresEntireBundleBeforeRevisionManifestPublication() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "post-exchange-rollback")
        let before = try bundleSnapshot(fixture.bundleURL)
        let originalRevisionCount = fixture.manifest.workbookRevisions?.count

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "post-exchange" else { return }
                    let visible = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
                    if visible.workbookRevisions?.count != originalRevisionCount {
                        throw NSError(domain: "RevisionManifestPublishedEarly", code: 1)
                    }
                    throw NSError(domain: "InjectedPostExchangeFailure", code: 1)
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        ) { error in
            XCTAssertEqual((error as NSError).domain, "InjectedPostExchangeFailure")
        }
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
    }

    func testFreshLoaderRecoversHardStopImmediatelyAfterWorkbookExchange() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "hard-stop-recovery")
        let before = try bundleSnapshot(fixture.bundleURL)

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "after-exchange-hard-stop" else { return }
                    throw NSError(domain: "SimulatedSIGKILL", code: 9)
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        ) { error in
            XCTAssertEqual((error as NSError).domain, "SimulatedSIGKILL")
        }
        let markerURL = ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
        let marker = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: Any]
        )
        XCTAssertEqual(marker["schemaVersion"] as? Int, 5)
        XCTAssertNotNil(marker["attestationID"] as? String)
        XCTAssertEqual(marker["phase"] as? String, "prepared")
        XCTAssertEqual(marker["workflowName"] as? String, "Genotype Workbook Update")
        XCTAssertFalse((marker["argv"] as? [String] ?? []).isEmpty)
        XCTAssertNotNil(marker["oldManifest"] as? [String: Any])
        XCTAssertNotNil(marker["newManifest"] as? [String: Any])
        XCTAssertNotNil(marker["oldCurrentWorkbook"] as? [String: Any])
        XCTAssertNotNil(marker["newCurrentWorkbook"] as? [String: Any])
        XCTAssertNotNil(marker["oldGenerationIdentity"] as? [String: Any])
        XCTAssertNotNil(marker["newGenerationIdentity"] as? [String: Any])
        XCTAssertNotNil(marker["transactionRootIdentity"] as? [String: Any])
        XCTAssertNotNil(marker["finalParentIdentity"] as? [String: Any])

        _ = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
        try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).contains {
            $0.contains("workbook-update-recovery") && $0.hasSuffix(".json")
        })
    }

    func testFreshLoaderDiscardsProvenUnpublishedStageAfterPreExchangeHardStop() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "pre-exchange-hard-stop")
        let before = try bundleSnapshot(fixture.bundleURL)

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "after-transaction-marker-hard-stop" else { return }
                    throw NSError(domain: "SimulatedSIGKILL", code: 9)
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )

        _ = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
        try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL).path
        ))
    }

    func testMarkerFallbackNeverOverwritesForeignConcurrentMarker() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "foreign-marker-race")
        let before = try bundleSnapshot(fixture.bundleURL)
        let foreignBytes = Data("foreign-marker-must-survive".utf8)

        let markerURL = ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL)
        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "before-transaction-marker-source-conflict-check" else {
                        return
                    }
                    try foreignBytes.write(to: markerURL, options: .withoutOverwriting)
                },
                forceBundleCloneFallback: true
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )

        XCTAssertEqual(try Data(contentsOf: markerURL), foreignBytes)
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
        try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
    }

    func testRotationFallbackNeverOverwritesForeignConcurrentDestination() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "foreign-rotation-race")
        let before = try bundleSnapshot(fixture.bundleURL)

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                forceBundleCloneFallback: true,
                directorySwapPrimitive: { _, _, _, _, _ in
                    errno = ENOTSUP
                    return -1
                },
                directoryMovePrimitive: { _, _, destinationParent, destinationName, flags in
                    guard flags == UInt32(RENAME_EXCL) else {
                        errno = EINVAL
                        return -1
                    }
                    _ = destinationName.withCString {
                        Darwin.mkdirat(destinationParent, $0, S_IRWXU)
                    }
                    let reservation = destinationName.withCString {
                        Darwin.openat(
                            destinationParent,
                            $0,
                            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                        )
                    }
                    if reservation >= 0 {
                        let sentinel = Darwin.openat(
                            reservation,
                            "foreign-sentinel.txt",
                            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                            S_IRUSR | S_IWUSR
                        )
                        if sentinel >= 0 {
                            _ = Darwin.write(sentinel, "survive", 7)
                            Darwin.close(sentinel)
                        }
                        Darwin.close(reservation)
                    }
                    errno = ENOTSUP
                    return -1
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )

        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
        let marker = try markerObject(
            at: ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL)
        )
        let rotation = URL(
            fileURLWithPath: try XCTUnwrap(marker["rotationTemporaryPath"] as? String),
            isDirectory: true
        )
        XCTAssertEqual(
            try Data(contentsOf: rotation.appendingPathComponent("foreign-sentinel.txt")),
            Data("survive".utf8)
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: try XCTUnwrap(marker["stagingBundlePath"] as? String)
        ))
    }

    func testRecoveryWithoutDetachedAttestationFailsClosedWithoutMutatingEitherGeneration() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let attestationRoot = root.appendingPathComponent("attestations", isDirectory: true)
        try FileManager.default.createDirectory(
            at: attestationRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        XCTAssertEqual(chmod(attestationRoot.path, 0o700), 0)
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "missing-detached-attestation")

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "after-exchange-hard-stop" else { return }
                    throw NSError(domain: "SimulatedSIGKILL", code: 9)
                },
                workbookAttestationRootURL: attestationRoot
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )
        let markerURL = ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL)
        let marker = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: Any]
        )
        let attestationID = try XCTUnwrap(marker["attestationID"] as? String)
        let attestationURL = attestationRoot.appendingPathComponent("\(attestationID).json")
        let stagingURL = URL(
            fileURLWithPath: try XCTUnwrap(marker["stagingBundlePath"] as? String),
            isDirectory: true
        )
        try FileManager.default.removeItem(at: attestationURL)
        let finalBefore = try bundleSnapshot(fixture.bundleURL)
        let stagingBefore = try bundleSnapshot(stagingURL)
        let markerBefore = try Data(contentsOf: markerURL)

        XCTAssertThrowsError(
            try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                for: fixture.bundleURL,
                attestationRootURL: attestationRoot
            )
        ) { error in
            XCTAssertTrue(error is ONTGenotypeWorkbookUpdateRecoveryError)
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("ambiguous"))
        }

        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), finalBefore)
        XCTAssertEqual(try bundleSnapshot(stagingURL), stagingBefore)
        XCTAssertEqual(try Data(contentsOf: markerURL), markerBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: attestationURL.path))
    }

    func testRecoveryRejectsSymlinkedDetachedAttestationWithoutMutatingEitherGeneration() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let attestationRoot = root.appendingPathComponent("attestations", isDirectory: true)
        try FileManager.default.createDirectory(
            at: attestationRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        XCTAssertEqual(chmod(attestationRoot.path, 0o700), 0)
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "symlinked-detached-attestation")

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "after-exchange-hard-stop" else { return }
                    throw NSError(domain: "SimulatedSIGKILL", code: 9)
                },
                workbookAttestationRootURL: attestationRoot
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )
        let markerURL = ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL)
        let marker = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: Any]
        )
        let attestationID = try XCTUnwrap(marker["attestationID"] as? String)
        let attestationURL = attestationRoot.appendingPathComponent("\(attestationID).json")
        let retainedURL = root.appendingPathComponent("retained-attestation.json")
        try FileManager.default.moveItem(at: attestationURL, to: retainedURL)
        try FileManager.default.createSymbolicLink(at: attestationURL, withDestinationURL: retainedURL)
        let stagingURL = URL(
            fileURLWithPath: try XCTUnwrap(marker["stagingBundlePath"] as? String),
            isDirectory: true
        )
        let finalBefore = try bundleSnapshot(fixture.bundleURL)
        let stagingBefore = try bundleSnapshot(stagingURL)
        let markerBefore = try Data(contentsOf: markerURL)

        XCTAssertThrowsError(
            try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                for: fixture.bundleURL,
                attestationRootURL: attestationRoot
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("ambiguous"))
        }

        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), finalBefore)
        XCTAssertEqual(try bundleSnapshot(stagingURL), stagingBefore)
        XCTAssertEqual(try Data(contentsOf: markerURL), markerBefore)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: attestationURL.path),
            retainedURL.path
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedURL.path))
    }

    func testAsyncLoaderFinishesCleanupAfterHardStopFollowingCommittedManifest() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "committed-hard-stop")
        let priorRevisionCount = fixture.manifest.workbookRevisions?.count ?? 0

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "after-revision-manifest-hard-stop" else { return }
                    throw NSError(domain: "SimulatedSIGKILL", code: 9)
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )
        let markerURL = ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))

        let loaded = try await ONTGenotypeResultBundle.loadResultAsync(from: fixture.bundleURL)

        XCTAssertGreaterThan(loaded.manifest.workbookRevisions?.count ?? 0, priorRevisionCount)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
        try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
    }

    func testLoaderAllowsExternalCurrentWorkbookEditWhenNoTransactionIsActive() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "workbook-integrity")
        _ = try GenotypeWorkbookRevisionService(pythonExecutableURL: testPythonExecutableURL)
            .applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        try Data("tampered-current-workbook".utf8).write(to: currentURL, options: .atomic)

        let loaded = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)
        XCTAssertEqual(loaded.artifacts.workbookURL, currentURL)
    }

    func testAmbiguousHardStopRecoveryPreservesBothGenerationsAndFailsClosed() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "ambiguous-hard-stop")

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "after-exchange-hard-stop" else { return }
                    throw NSError(domain: "SimulatedSIGKILL", code: 9)
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )
        let markerURL = ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL)
        let markerObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: Any]
        )
        let stagingPath = try XCTUnwrap(markerObject["stagingBundlePath"] as? String)
        let stagingURL = URL(fileURLWithPath: stagingPath, isDirectory: true)
        let stagingManifest = try ONTGenotypeResultBundle.loadManifest(from: stagingURL)
        let stagingCurrentURL = ONTGenotypeResultBundle.resolvedURL(
            for: try XCTUnwrap(stagingManifest.currentWorkbookPath),
            in: stagingURL
        )
        try Data("ambiguous-generation".utf8).write(to: stagingCurrentURL, options: .atomic)
        let finalBefore = try bundleSnapshot(fixture.bundleURL)
        let stagingBefore = try bundleSnapshot(stagingURL)

        XCTAssertThrowsError(try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL))

        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), finalBefore)
        XCTAssertEqual(try bundleSnapshot(stagingURL), stagingBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).contains {
            $0.contains("workbook-update-recovery") && $0.hasSuffix(".json")
        })
    }

    func testCraftedMarkerCannotRedirectRecoveryToByteIdenticalUnrelatedStage() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "crafted-marker-stage")
        let markerURL = try interruptWorkbookPublicationAfterExchange(fixture: fixture, root: root)
        var marker = try markerObject(at: markerURL)
        let genuineRoot = URL(
            fileURLWithPath: try XCTUnwrap(marker["transactionRootPath"] as? String),
            isDirectory: true
        )
        let genuineStage = URL(
            fileURLWithPath: try XCTUnwrap(marker["stagingBundlePath"] as? String),
            isDirectory: true
        )
        let rogueRoot = root.appendingPathComponent(
            ".\(fixture.bundleURL.lastPathComponent).workbook-update-crafted.staging",
            isDirectory: true
        )
        let rogueStage = rogueRoot.appendingPathComponent(fixture.bundleURL.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: rogueRoot, withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: genuineStage, to: rogueStage)
        let sentinel = rogueRoot.appendingPathComponent("unrelated-sentinel.txt")
        try Data("must-survive".utf8).write(to: sentinel)
        marker["transactionRootPath"] = rogueRoot.path
        marker["stagingBundlePath"] = rogueStage.path
        try writeMarkerObject(marker, to: markerURL)
        let finalBefore = try bundleSnapshot(fixture.bundleURL)
        let genuineBefore = try bundleSnapshot(genuineRoot)
        let rogueBefore = try bundleSnapshot(rogueRoot)

        XCTAssertThrowsError(try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL))

        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), finalBefore)
        XCTAssertEqual(try bundleSnapshot(genuineRoot), genuineBefore)
        XCTAssertEqual(try bundleSnapshot(rogueRoot), rogueBefore)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("must-survive".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testRecoveryRejectsTransactionRootInodeSubstitutionWithoutDeletingEitherTree() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "marker-inode-substitution")
        let markerURL = try interruptWorkbookPublicationAfterExchange(fixture: fixture, root: root)
        let marker = try markerObject(at: markerURL)
        let transactionRoot = URL(
            fileURLWithPath: try XCTUnwrap(marker["transactionRootPath"] as? String),
            isDirectory: true
        )
        let retainedRoot = root.appendingPathComponent("retained-genuine-transaction-root", isDirectory: true)
        try FileManager.default.moveItem(at: transactionRoot, to: retainedRoot)
        try FileManager.default.copyItem(at: retainedRoot, to: transactionRoot)
        let finalBefore = try bundleSnapshot(fixture.bundleURL)
        let retainedBefore = try bundleSnapshot(retainedRoot)
        let replacementBefore = try bundleSnapshot(transactionRoot)

        XCTAssertThrowsError(try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL))

        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), finalBefore)
        XCTAssertEqual(try bundleSnapshot(retainedRoot), retainedBefore)
        XCTAssertEqual(try bundleSnapshot(transactionRoot), replacementBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testRecoveryRejectsSymlinkedTransactionRootBeforeAnyGenerationSwap() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "marker-root-symlink")
        let markerURL = try interruptWorkbookPublicationAfterExchange(fixture: fixture, root: root)
        let marker = try markerObject(at: markerURL)
        let transactionRoot = URL(
            fileURLWithPath: try XCTUnwrap(marker["transactionRootPath"] as? String),
            isDirectory: true
        )
        let retainedRoot = root.appendingPathComponent("retained-symlink-target", isDirectory: true)
        try FileManager.default.moveItem(at: transactionRoot, to: retainedRoot)
        try FileManager.default.createSymbolicLink(at: transactionRoot, withDestinationURL: retainedRoot)
        let finalBefore = try bundleSnapshot(fixture.bundleURL)
        let retainedBefore = try bundleSnapshot(retainedRoot)

        XCTAssertThrowsError(try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL))

        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), finalBefore)
        XCTAssertEqual(try bundleSnapshot(retainedRoot), retainedBefore)
        var info = stat()
        XCTAssertEqual(Darwin.lstat(transactionRoot.path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFLNK)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testPreManifestFailureRestoresEntireBundleWithOldManifestStillVisible() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "pre-manifest-rollback")
        let before = try bundleSnapshot(fixture.bundleURL)
        let originalRevisionCount = fixture.manifest.workbookRevisions?.count

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "before-revision-manifest" else { return }
                    let visible = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
                    if visible.workbookRevisions?.count != originalRevisionCount {
                        throw NSError(domain: "RevisionManifestPublishedEarly", code: 1)
                    }
                    throw NSError(domain: "InjectedPreManifestFailure", code: 1)
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        ) { error in
            XCTAssertEqual((error as NSError).domain, "InjectedPreManifestFailure")
        }
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
    }

    func testRollbackFailureRetainsJournaledGenerationsAndNextRunRecoversPrior() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "rollback-failure-recovery")
        let beforeManifest = fixture.manifest
        let rollbackTimestamp = Date(timeIntervalSince1970: 6_500)

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                dateProvider: { rollbackTimestamp },
                pythonExecutableURL: testPythonExecutableURL,
                publicationFailureInjector: { checkpoint in
                    if checkpoint == "post-exchange" {
                        throw NSError(domain: "InjectedPublicationFailure", code: 1)
                    }
                    if checkpoint == "before-rollback-exchange" {
                        throw NSError(domain: "InjectedRollbackFailure", code: 1)
                    }
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.bundleURL.path))
        let receiptURL = root.appendingPathComponent(
            ".\(fixture.bundleURL.lastPathComponent).workbook-update-failure.json"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: receiptURL.path))
        let receiptProvenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(
            fromSidecar: ProvenanceRecorder.fileSidecarURL(for: receiptURL)
        ))
        XCTAssertEqual(receiptProvenance.createdAt, rollbackTimestamp)
        let markerURL = ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL)
        let marker = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: Any]
        )
        XCTAssertEqual(marker["phase"] as? String, "prepared", "The authenticated transaction marker is immutable")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: try XCTUnwrap(marker["stagingBundlePath"] as? String)
        ))

        _ = try GenotypeWorkbookRevisionService(pythonExecutableURL: testPythonExecutableURL)
            .applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL.path))
        let recovered = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
        XCTAssertGreaterThan(recovered.workbookRevisions?.count ?? 0, beforeManifest.workbookRevisions?.count ?? 0)
    }

    func testSymlinkUpdatesPathIsRejectedWithoutAnyBundleMutation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "candidate-unsafe-updates")
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let updatesURL = fixture.bundleURL.appendingPathComponent("artifacts/workbooks/updates", isDirectory: true)
        try FileManager.default.createDirectory(at: updatesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: updatesURL, withDestinationURL: outside)
        let before = try bundleSnapshot(fixture.bundleURL)

        let service = serviceThatFailsIfStagingBegins()
        XCTAssertThrowsError(
            try service.applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        ) { error in
            XCTAssertNotEqual((error as NSError).domain, "UnexpectedWorkbookUpdateStaging")
        }
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
    }

    func testAbsoluteSymlinkRevisionsPathIsRejectedBeforeExternalOrBundleMutation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "candidate-unsafe-revisions")
        let outside = root.appendingPathComponent("outside-revisions", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel.txt")
        try Data("unchanged".utf8).write(to: sentinel)
        let revisionsURL = fixture.bundleURL.appendingPathComponent(
            "artifacts/workbooks/revisions",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(at: revisionsURL, withDestinationURL: outside)
        let before = try bundleSnapshot(fixture.bundleURL)
        let outsideBefore = try Data(contentsOf: sentinel)

        let service = serviceThatFailsIfStagingBegins()
        XCTAssertThrowsError(
            try service.applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        ) { error in
            XCTAssertNotEqual((error as NSError).domain, "UnexpectedWorkbookUpdateStaging")
        }
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
        XCTAssertEqual(try Data(contentsOf: sentinel), outsideBefore)
        try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
    }

    func testRelativeSymlinkProvenancePathIsRejectedBeforeExternalOrBundleMutation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "candidate-unsafe-provenance")
        let outside = root.appendingPathComponent("outside-provenance", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel.txt")
        try Data("unchanged".utf8).write(to: sentinel)
        let provenanceURL = fixture.bundleURL.appendingPathComponent(
            "artifacts/workbooks/provenance",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: provenanceURL.path,
            withDestinationPath: "../../../outside-provenance"
        )
        let before = try bundleSnapshot(fixture.bundleURL)
        let outsideBefore = try Data(contentsOf: sentinel)

        let service = serviceThatFailsIfStagingBegins()
        XCTAssertThrowsError(
            try service.applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        ) { error in
            XCTAssertNotEqual((error as NSError).domain, "UnexpectedWorkbookUpdateStaging")
        }
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
        XCTAssertEqual(try Data(contentsOf: sentinel), outsideBefore)
        try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
    }

    func testIntermediateWorkbooksSymlinkIsRejectedBeforeHistoryOrProvenanceWrites() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "candidate-unsafe-workbooks")
        let workbooksURL = fixture.bundleURL.appendingPathComponent("artifacts/workbooks", isDirectory: true)
        let outside = root.appendingPathComponent("outside-workbooks", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: workbooksURL.appendingPathComponent("current.xlsx"),
            to: outside.appendingPathComponent("current.xlsx")
        )
        let sentinel = outside.appendingPathComponent("sentinel.txt")
        try Data("unchanged".utf8).write(to: sentinel)
        try FileManager.default.removeItem(at: workbooksURL)
        try FileManager.default.createSymbolicLink(at: workbooksURL, withDestinationURL: outside)
        let before = try bundleSnapshot(fixture.bundleURL)
        let outsideBefore = try bundleSnapshot(outside)

        let service = serviceThatFailsIfStagingBegins()
        XCTAssertThrowsError(
            try service.applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        ) { error in
            XCTAssertNotEqual((error as NSError).domain, "UnexpectedWorkbookUpdateStaging")
        }
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
        XCTAssertEqual(try bundleSnapshot(outside), outsideBefore)
        try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
    }

    func testFIFOAnywhereInSourceBundleIsRejectedBeforeStagingOrMutation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "candidate-unsafe-fifo")
        let fifoURL = fixture.bundleURL.appendingPathComponent("artifacts/unsafe.fifo")
        XCTAssertEqual(Darwin.mkfifo(fifoURL.path, S_IRUSR | S_IWUSR), 0)
        let before = try bundleSnapshot(fixture.bundleURL)

        let service = serviceThatFailsIfStagingBegins()
        XCTAssertThrowsError(
            try service.applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        ) { error in
            XCTAssertNotEqual((error as NSError).domain, "UnexpectedWorkbookUpdateStaging")
        }
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
        try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
    }

    func testCancellationDuringPythonLeavesEntireBundleUnchanged() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "candidate-cancelled")
        try installCandidateArtifacts(in: fixture.bundleURL)
        let fakePythonURL = root.appendingPathComponent("slow-python")
        try Data("#!/bin/sh\nsleep 30\n".utf8).write(to: fakePythonURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakePythonURL.path)
        let before = try bundleSnapshot(fixture.bundleURL)
        let service = GenotypeWorkbookRevisionService(pythonExecutableURL: fakePythonURL)

        let update = Task {
            try service.applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        }
        let stagePrefix = ".\(fixture.bundleURL.lastPathComponent).workbook-update-"
        var observedStage = false
        for _ in 0..<100 {
            let siblings = try FileManager.default.contentsOfDirectory(atPath: root.path)
            if siblings.contains(where: { $0.hasPrefix(stagePrefix) }) {
                observedStage = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(observedStage, "The test must cancel while the Python update transaction is staged")
        update.cancel()

        do {
            _ = try await update.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), before)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .contains(where: { $0.hasPrefix(stagePrefix) })
        )
    }

    func testManualExcelSaveAfterPythonConflictsAndSurvivesWithoutMetadataMutation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "manual-save-race")
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        let manifestURL = ONTGenotypeResultBundle.manifestURL(in: fixture.bundleURL)
        let manifestBefore = try Data(contentsOf: manifestURL)
        let provenanceURL = fixture.bundleURL.appendingPathComponent(
            "artifacts/workbooks/provenance", isDirectory: true
        )
        let provenanceBefore = try directorySnapshot(provenanceURL)
        let pythonURL = testPythonExecutableURL

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "after-python-before-source-conflict-check" else { return }
                    _ = try Self.runPythonStatic(["-c", #"""
import sys
from openpyxl import load_workbook
path = sys.argv[1]
wb = load_workbook(path)
wb[wb.sheetnames[0]]["Z99"] = "manual-save-survives"
wb.save(path)
"""#, currentURL.path], executableURL: pythonURL)
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        ) { error in
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("changed"))
        }

        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBefore)
        XCTAssertEqual(try directorySnapshot(provenanceURL), provenanceBefore)
        let manualValue = try Self.runPythonStatic(["-c", #"""
import sys
from openpyxl import load_workbook
wb = load_workbook(sys.argv[1], data_only=False)
print(wb[wb.sheetnames[0]]["Z99"].value or "")
"""#, currentURL.path], executableURL: pythonURL)
        XCTAssertEqual(manualValue.trimmingCharacters(in: .whitespacesAndNewlines), "manual-save-survives")
        try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
    }

    func testManualExcelSaveAtPreWALBoundaryConflictsAndSurvivesWithoutMetadataMutation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "manual-save-pre-wal-race")
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        let manifestURL = ONTGenotypeResultBundle.manifestURL(in: fixture.bundleURL)
        let manifestBefore = try Data(contentsOf: manifestURL)
        let provenanceURL = fixture.bundleURL.appendingPathComponent(
            "artifacts/workbooks/provenance", isDirectory: true
        )
        let provenanceBefore = try directorySnapshot(provenanceURL)
        let pythonURL = testPythonExecutableURL

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: pythonURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "before-transaction-marker-source-conflict-check" else { return }
                    _ = try Self.runPythonStatic(["-c", #"""
import sys
from openpyxl import load_workbook
path = sys.argv[1]
wb = load_workbook(path)
wb[wb.sheetnames[0]]["Z98"] = "manual-save-pre-wal-survives"
wb.save(path)
"""#, currentURL.path], executableURL: pythonURL)
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        ) { error in
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("changed"))
        }

        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBefore)
        XCTAssertEqual(try directorySnapshot(provenanceURL), provenanceBefore)
        let manualValue = try Self.runPythonStatic(["-c", #"""
import sys
from openpyxl import load_workbook
wb = load_workbook(sys.argv[1], data_only=False)
print(wb[wb.sheetnames[0]]["Z98"].value or "")
"""#, currentURL.path], executableURL: pythonURL)
        XCTAssertEqual(manualValue.trimmingCharacters(in: .whitespacesAndNewlines), "manual-save-pre-wal-survives")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL).path
        ))
        try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
        try assertNoRetiredWorkbookGeneration(in: root)
    }

    func testManualExcelSaveAtPreExchangeBoundaryConflictsAndSurvivesWithoutMetadataMutation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "manual-save-pre-exchange-race")
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        let manifestURL = ONTGenotypeResultBundle.manifestURL(in: fixture.bundleURL)
        let manifestBefore = try Data(contentsOf: manifestURL)
        let provenanceURL = fixture.bundleURL.appendingPathComponent(
            "artifacts/workbooks/provenance", isDirectory: true
        )
        let provenanceBefore = try directorySnapshot(provenanceURL)
        let pythonURL = testPythonExecutableURL

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: pythonURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "before-exchange-source-conflict-check" else { return }
                    _ = try Self.runPythonStatic(["-c", #"""
import sys
from openpyxl import load_workbook
path = sys.argv[1]
wb = load_workbook(path)
wb[wb.sheetnames[0]]["Z97"] = "manual-save-pre-exchange-survives"
wb.save(path)
"""#, currentURL.path], executableURL: pythonURL)
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        ) { error in
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("changed"))
        }

        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBefore)
        XCTAssertEqual(try directorySnapshot(provenanceURL), provenanceBefore)
        let manualValue = try Self.runPythonStatic(["-c", #"""
import sys
from openpyxl import load_workbook
wb = load_workbook(sys.argv[1], data_only=False)
print(wb[wb.sheetnames[0]]["Z97"].value or "")
"""#, currentURL.path], executableURL: pythonURL)
        XCTAssertEqual(manualValue.trimmingCharacters(in: .whitespacesAndNewlines), "manual-save-pre-exchange-survives")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL).path
        ))
        try assertNoWorkbookUpdateStage(for: fixture.bundleURL)
        try assertNoRetiredWorkbookGeneration(in: root)
    }

    func testReadOnlyBundleAndParentLoadWithoutCreatingAdjacentLock() throws {
        let root = try temporaryDirectory()
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "readonly-load")
        let lockURL = ONTGenotypeBundlePublicationLock.lockURL(for: fixture.bundleURL)
        try? FileManager.default.removeItem(at: lockURL)
        defer {
            try? chmodTreeWritable(root)
            try? FileManager.default.removeItem(at: root)
        }
        try chmodTreeReadOnly(fixture.bundleURL)
        XCTAssertEqual(chmod(root.path, S_IRUSR | S_IXUSR), 0)

        let loaded = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertEqual(loaded.bundleURL, fixture.bundleURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))
    }

    func testSidecarDisplayEditAloneDoesNotMutateCurrentWorkbook() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "sidecar-only")
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        let before = try ProvenanceFileHasher.sha256(of: currentURL)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-20T00:00:00Z")
        sidecar.settings.mhcCandidateDisplay.showSingletonCandidates = false
        try sidecar.encoded().write(
            to: fixture.bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename),
            options: .atomic
        )
        XCTAssertEqual(try ProvenanceFileHasher.sha256(of: currentURL), before)
    }

    func testConcurrentExplicitUpdateConflictsBeforeWorkbookMutation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "candidate-concurrent")
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        let before = try Data(contentsOf: currentURL)
        let lock = try DarwinFullLengthONTMHCRunLock.acquire(outputDirectoryURL: fixture.bundleURL)
        defer { lock.release() }

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(pythonExecutableURL: testPythonExecutableURL)
                .applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )
        XCTAssertEqual(try Data(contentsOf: currentURL), before)
    }

    func testExplicitUpdateRejectsSymlinkCurrentWorkbookWithoutMutatingTarget() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "candidate-symlink")
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        let outside = root.appendingPathComponent("outside.xlsx")
        try makeMinimalMCMWorkbook(at: outside)
        let outsideBefore = try Data(contentsOf: outside)
        try FileManager.default.removeItem(at: currentURL)
        try FileManager.default.createSymbolicLink(at: currentURL, withDestinationURL: outside)

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(pythonExecutableURL: testPythonExecutableURL)
                .applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )
        XCTAssertEqual(try Data(contentsOf: outside), outsideBefore)
    }

    func testWorkbookRevisionPreservesScientificArtifactManifestFields() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeBundle(in: root, outputName: "candidate-preservation", includeCurrent: true)
        let reference = ONTMHCArtifactReference(
            path: "artifacts/mhc-candidates/candidate-alleles.json",
            sha256: String(repeating: "a", count: 64),
            sizeBytes: 42
        )
        let candidateArtifacts = ONTMHCCandidateArtifactManifest(
            schemaVersion: 1,
            genotypingEvidence: nil,
            reciprocalEvidence: nil,
            candidateJSON: reference,
            candidateFASTA: reference,
            unnameableJSON: reference,
            unnameableFASTA: reference
        )
        let unmatchedClustersPath = "artifacts/candidates/deduplicated-unmatched-clusters.fasta"
        let manifest = ONTGenotypeResultBundleManifest(
            schemaVersion: fixture.manifest.schemaVersion,
            kind: fixture.manifest.kind,
            workflowKind: .fullLengthONTMHCGenotype,
            workflowMode: .genotypeOnly,
            outputName: fixture.manifest.outputName,
            analysisName: fixture.manifest.analysisName,
            primaryWorkbookPath: fixture.manifest.primaryWorkbookPath,
            currentWorkbookPath: fixture.manifest.currentWorkbookPath,
            workbookRevisions: fixture.manifest.workbookRevisions,
            longSummaryCSVPath: fixture.manifest.longSummaryCSVPath,
            sampleSummaryCSVPath: fixture.manifest.sampleSummaryCSVPath,
            statsJSONPath: fixture.manifest.statsJSONPath,
            provenancePath: fixture.manifest.provenancePath,
            deduplicatedUnmatchedClustersFASTAPath: unmatchedClustersPath,
            mhcCandidateArtifacts: candidateArtifacts,
            referenceRecordStore: fixture.manifest.referenceRecordStore
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: fixture.bundleURL)
        let replacement = root.appendingPathComponent("replacement.xlsx")
        try workbookData("replacement").write(to: replacement)

        let updated = try GenotypeWorkbookRevisionService()
            .importRevisedWorkbook(from: replacement, into: fixture.bundleURL)

        XCTAssertEqual(updated.mhcCandidateArtifacts, candidateArtifacts)
        XCTAssertEqual(updated.deduplicatedUnmatchedClustersFASTAPath, unmatchedClustersPath)
        XCTAssertEqual(updated.referenceRecordStore, fixture.manifest.referenceRecordStore)
        XCTAssertEqual(updated.workflowKind, .fullLengthONTMHCGenotype)
        XCTAssertEqual(updated.workflowMode, .genotypeOnly)
    }

    func testWorkbookRevisionPreservesMalformedWorkflowDeclarations() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeBundle(
            in: root,
            outputName: "malformed-workflow-preservation",
            includeCurrent: true
        )
        let manifestURL = ONTGenotypeResultBundle.manifestURL(in: fixture.bundleURL)
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        object["workflowKind"] = ["future": "mhc-workflow"]
        object["workflowMode"] = NSNull()
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: manifestURL, options: .atomic)
        let malformed = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
        let originalKind = malformed.workflowKindDeclaration.originalValue
        let originalMode = malformed.workflowModeDeclaration.originalValue
        XCTAssertNil(malformed.workflowKind)
        XCTAssertNil(malformed.workflowMode)
        XCTAssertNotNil(malformed.workflowKindDeclaration.issue)
        XCTAssertNotNil(malformed.workflowModeDeclaration.issue)

        let replacement = root.appendingPathComponent("replacement.xlsx")
        try workbookData("replacement").write(to: replacement)
        let updated = try GenotypeWorkbookRevisionService()
            .importRevisedWorkbook(from: replacement, into: fixture.bundleURL)

        XCTAssertEqual(updated.workflowKindDeclaration.originalValue, originalKind)
        XCTAssertEqual(updated.workflowModeDeclaration.originalValue, originalMode)
        XCTAssertNil(updated.workflowKind)
        XCTAssertNil(updated.workflowMode)
        XCTAssertNotNil(updated.workflowKindDeclaration.issue)
        XCTAssertNotNil(updated.workflowModeDeclaration.issue)
        let reencoded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(updated)) as? [String: Any]
        )
        XCTAssertEqual(
            (reencoded["workflowKind"] as? [String: String])?["future"],
            "mhc-workflow"
        )
        XCTAssertTrue(reencoded["workflowMode"] is NSNull)
    }

    func testApplyHaplotypeOverridesPatchesCurrentWorkbookAndRecordsSidecarProvenance() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "mcm")
        let annotationURL = fixture.bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-06-04T00:00:00Z")
        sidecar.callOverrides = [
            GenotypeAnnotationSidecar.CallOverride(
                sample: "DW472",
                locus: "MHC-DP",
                slot: .h1,
                originalCall: "M4DP",
                overrideCall: "M3DP",
                reasonTag: .analystJudgment,
                rationale: "Manual curation from review viewport.",
                author: "curator",
                timestamp: "2026-06-04T12:00:00Z"
            )
        ]
        sidecar.append(audit: GenotypeAnnotationSidecar.AuditEntry(
            action: "override",
            sample: "DW472",
            locus: "MHC-DP",
            slot: .h1,
            before: "M4DP",
            after: "M3DP",
            color: nil,
            reason: "analyst-judgment",
            rationale: "Manual curation from review viewport.",
            author: "curator",
            timestamp: "2026-06-04T12:00:00Z"
        ))
        try sidecar.encoded().write(to: annotationURL)

        let updatedManifest = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 5_000) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        ).applyHaplotypeOverrides(
            [
                GenotypeWorkbookHaplotypeCall(
                    sample: "DW472",
                    locus: "MHC-DP",
                    haplotype1: "M3DP",
                    haplotype2: "M7DP",
                    status: "called",
                    notes: "Manual override"
                ),
                GenotypeWorkbookHaplotypeCall(
                    sample: "DW472",
                    locus: "MHC-DRB",
                    haplotype1: "M2DR",
                    haplotype2: "M4DR",
                    status: "called",
                    notes: "DRB should not be written to current workbook calls"
                )
            ],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )

        let inspection = try inspectMCMWorkbook(try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL))
        XCTAssertEqual(inspection["abbreviatedDPHaplotype1"], "M3DP")
        XCTAssertEqual(inspection["abbreviatedDPHaplotype2"], "M7DP")
        XCTAssertEqual(inspection["fullDPAHaplotype1"], "M3DP")
        XCTAssertEqual(inspection["fullDPBHaplotype2"], "M7DP")
        XCTAssertEqual(inspection["customDPHaplotype1"], "M3DP")
        XCTAssertEqual(inspection["abbreviatedDRBHaplotype1"], "")
        XCTAssertEqual(inspection["abbreviatedDRBHaplotype2"], "")
        XCTAssertEqual(inspection["fullDRBHaplotype1"], "")
        XCTAssertEqual(inspection["fullDRBHaplotype2"], "")
        XCTAssertFalse(inspection["abbreviatedComments"]?.contains("DRB should not be written") == true)
        XCTAssertFalse(inspection["fullComments"]?.contains("DRB should not be written") == true)
        XCTAssertEqual(inspection["guideWorkbookUpdateSource"], "Lungfish.app Review viewport")
        XCTAssertEqual(inspection["guideUpdatedHaplotypeCalls"], "1")
        XCTAssertEqual(inspection["guideAuditEntries"], "1")
        XCTAssertEqual(inspection["hasOverridesSheet"], "true")
        XCTAssertEqual(inspection["hasAuditLogSheet"], "true")
        XCTAssertEqual(
            inspection["firstOverrideRow"],
            "DW472|MHC-DP|h1|M4DP|M3DP|analyst-judgment|Manual curation from review viewport.|curator|2026-06-04T12:00:00Z"
        )
        XCTAssertEqual(
            inspection["firstAuditRow"],
            "override|DW472|MHC-DP|h1|M4DP|M3DP|analyst-judgment|Manual curation from review viewport.|curator|2026-06-04T12:00:00Z"
        )
        XCTAssertTrue(updatedManifest.workbookRevisions?.contains { $0.role == .externalEditSnapshot } == true)
        let imported = try XCTUnwrap(updatedManifest.workbookRevisions?.last)
        let provenancePath = try XCTUnwrap(imported.provenancePath)
        let provenanceURL = ONTGenotypeResultBundle.resolvedURL(for: provenancePath, in: fixture.bundleURL)
        let provenance = try String(contentsOf: provenanceURL, encoding: .utf8)
        XCTAssertTrue(provenance.contains("annotations.json"))
        XCTAssertTrue(provenance.contains("update-current-workbook"))
    }

    func testApplyHaplotypeOverridesAttestsInputFingerprintAndSyncIntentInPublishedRevision() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "attested-update")
        try installCandidateArtifacts(in: fixture.bundleURL)
        try installMinimalUnifiedPivot(in: fixture.bundleURL)
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        sidecar.lastEditor = "attestation-reviewer"
        try sidecar.encoded().write(to: annotationURL)
        let calls: [GenotypeWorkbookHaplotypeCall] = []
        let immutableRequestDirectory = fixture.bundleURL
            .appendingPathComponent("artifacts/workbooks/updates/request-inputs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: immutableRequestDirectory,
            withIntermediateDirectories: true
        )
        let outerCallsURL = immutableRequestDirectory
            .appendingPathComponent("displayed-haplotype-calls.json")
        try ProvenanceJSON.encoder.encode(calls).write(to: outerCallsURL)
        let includedLoci = ["MHC-A"]
        let manifest = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
        let fingerprint = try GenotypeCurrentWorkbookInputFingerprint.make(
            calls: calls,
            includedLoci: includedLoci,
            annotationSidecar: sidecar,
            candidateArtifacts: manifest.mhcCandidateArtifacts
        )

        let updated = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 5_100) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        ).applyHaplotypeOverrides(
            calls,
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL,
            includedLoci: includedLoci,
            provenanceContext: GenotypeWorkbookRevisionProvenanceContext(
                toolName: "lungfish-cli fastq update-current-workbook",
                toolKind: "cli",
                argv: [
                    "lungfish-cli", "fastq", "update-current-workbook",
                    fixture.bundleURL.path,
                    "--calls-json", outerCallsURL.path,
                    "--annotations", annotationURL.path,
                    "--input-fingerprint", fingerprint.sha256,
                    "--input-fingerprint-schema", String(fingerprint.schemaVersion),
                    "--sync-intent", GenotypeCurrentWorkbookSyncIntent.updateAndView.rawValue,
                ],
                cliInputDescriptors: [
                    try ProvenanceFileDescriptor.file(
                        url: outerCallsURL,
                        format: .json,
                        role: .input
                    ),
                    try ProvenanceFileDescriptor.file(
                        url: annotationURL,
                        format: .json,
                        role: .input
                    ),
                ],
                inputFingerprint: fingerprint,
                syncIntent: .updateAndView
            )
        )

        let provenanceURL = ONTGenotypeResultBundle.resolvedURL(
            for: try XCTUnwrap(updated.workbookRevisions?.last?.provenancePath),
            in: fixture.bundleURL
        )
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: provenanceURL)
        )
        XCTAssertEqual(
            envelope.options.explicit["currentWorkbookInputFingerprint"],
            .string(fingerprint.sha256)
        )
        XCTAssertEqual(
            envelope.options.explicit["currentWorkbookInputFingerprintSchemaVersion"],
            .integer(fingerprint.schemaVersion)
        )
        XCTAssertEqual(
            envelope.options.explicit["currentWorkbookSyncIntent"],
            .string("update-and-view")
        )
        XCTAssertEqual(envelope.argv.filter { $0 == "--input-fingerprint" }.count, 1)
        XCTAssertEqual(envelope.argv.filter { $0 == "--input-fingerprint-schema" }.count, 1)
        XCTAssertEqual(envelope.argv.filter { $0 == "--sync-intent" }.count, 1)
        XCTAssertEqual(envelope.durableReplayArgv, envelope.argv)
        for flag in ["--calls-json", "--annotations"] {
            let flagIndex = try XCTUnwrap(envelope.argv.firstIndex(of: flag))
            let path = envelope.argv[envelope.argv.index(after: flagIndex)]
            let inputURL = URL(fileURLWithPath: path)
            let descriptor = try XCTUnwrap(
                envelope.files.first {
                    $0.path == inputURL.standardizedFileURL.path && $0.role == .input
                }
            )
            XCTAssertEqual(
                descriptor.fileSize,
                UInt64(try ProvenanceFileHasher.fileSize(of: inputURL))
            )
            XCTAssertEqual(
                descriptor.checksumSHA256,
                try ProvenanceFileHasher.sha256(of: inputURL)
            )
            let publicationStep = try XCTUnwrap(
                envelope.steps.first {
                    $0.toolName.contains("genotype workbook update-current-workbook")
                }
            )
            XCTAssertTrue(
                publicationStep.inputs.contains { $0 == descriptor },
                "\(flag) exact immutable input is absent from the publication step"
            )
        }
        XCTAssertNotNil(envelope.options.explicit["cliImmutableInputs"])
        XCTAssertNotNil(envelope.options.explicit["additionalInputs"])
    }

    func testApplyHaplotypeOverridesRejectsSameSizeCallsInputMutationBeforePublication() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "mutated-cli-input"
        )
        try installCandidateArtifacts(in: fixture.bundleURL)
        try installMinimalUnifiedPivot(in: fixture.bundleURL)
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        let sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-24T00:00:00Z"
        )
        try sidecar.encoded().write(to: annotationURL)
        let admittedCalls = [
            GenotypeWorkbookHaplotypeCall(
                sample: "sample-a",
                locus: "MHC-A",
                haplotype1: "A-H1",
                haplotype2: "A-H2",
                status: "called",
                notes: "review"
            ),
        ]
        let changedCalls = [
            GenotypeWorkbookHaplotypeCall(
                sample: "sample-b",
                locus: "MHC-A",
                haplotype1: "A-H1",
                haplotype2: "A-H2",
                status: "called",
                notes: "review"
            ),
        ]
        let retainedDirectory = root.appendingPathComponent(
            "retained-cli-inputs",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: retainedDirectory,
            withIntermediateDirectories: true
        )
        let callsURL = retainedDirectory.appendingPathComponent(
            "displayed-haplotype-calls.json"
        )
        let admittedData = try ProvenanceJSON.encoder.encode(admittedCalls)
        let changedData = try ProvenanceJSON.encoder.encode(changedCalls)
        XCTAssertEqual(admittedData.count, changedData.count)
        try admittedData.write(to: callsURL)
        let bundleBefore = try bundleSnapshot(fixture.bundleURL)
        let mutationCheckpoint = SendableFlagBox()
        let service = GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 5_125) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL,
            publicationFailureInjector: { checkpoint in
                guard checkpoint == "after-python-before-source-conflict-check" else {
                    return
                }
                mutationCheckpoint.set(1)
                let handle = try FileHandle(forWritingTo: callsURL)
                defer { try? handle.close() }
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: changedData)
                try handle.synchronize()
            }
        )
        let argv = [
            "lungfish-cli", "fastq", "update-current-workbook",
            fixture.bundleURL.path,
            "--calls-json", callsURL.path,
            "--annotations", annotationURL.path,
        ]

        XCTAssertThrowsError(
            try service.applyHaplotypeOverrides(
                admittedCalls,
                annotationSidecarURL: annotationURL,
                into: fixture.bundleURL,
                provenanceContext: GenotypeWorkbookRevisionProvenanceContext(
                    toolName: "lungfish-cli fastq update-current-workbook",
                    toolKind: "cli",
                    argv: argv,
                    cliInputDescriptors: [
                        try ProvenanceFileDescriptor.file(
                            url: callsURL,
                            format: .json,
                            role: .input
                        ),
                        try ProvenanceFileDescriptor.file(
                            url: annotationURL,
                            format: .json,
                            role: .input
                        ),
                    ]
                )
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("CLI provenance descriptor"),
                "Unexpected error: \(error)"
            )
        }

        XCTAssertEqual(mutationCheckpoint.value, 1)
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), bundleBefore)
        XCTAssertEqual(try Data(contentsOf: callsURL), changedData)
    }

    func testApplyHaplotypeOverridesRejectsMismatchedInputFingerprintWithoutBundleMutation() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "mismatched-attestation")
        try installCandidateArtifacts(in: fixture.bundleURL)
        try installMinimalUnifiedPivot(in: fixture.bundleURL)
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        sidecar.lastEditor = "immutable-reviewer"
        try sidecar.encoded().write(to: annotationURL)
        let calls: [GenotypeWorkbookHaplotypeCall] = []
        let includedLoci = ["MHC-A"]
        let manifestBefore = try Data(
            contentsOf: ONTGenotypeResultBundle.manifestURL(in: fixture.bundleURL)
        )
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        let currentBefore = try Data(contentsOf: currentURL)
        let bundleBefore = try bundleSnapshot(fixture.bundleURL)
        let mismatchedFingerprint = try GenotypeCurrentWorkbookInputFingerprint(
            schemaVersion: GenotypeCurrentWorkbookInputFingerprint.schemaVersion,
            sha256: String(repeating: "d", count: 64)
        )

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                dateProvider: { Date(timeIntervalSince1970: 5_150) },
                userProvider: { "tester" },
                pythonExecutableURL: testPythonExecutableURL
            ).applyHaplotypeOverrides(
                calls,
                annotationSidecarURL: annotationURL,
                into: fixture.bundleURL,
                includedLoci: includedLoci,
                provenanceContext: GenotypeWorkbookRevisionProvenanceContext(
                    toolName: "lungfish-cli fastq update-current-workbook",
                    toolKind: "cli",
                    argv: ["lungfish-cli", "fastq", "update-current-workbook"],
                    inputFingerprint: mismatchedFingerprint,
                    syncIntent: .automaticIdle
                )
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("input fingerprint"),
                "Unexpected error: \(error)"
            )
        }

        XCTAssertEqual(
            try Data(contentsOf: ONTGenotypeResultBundle.manifestURL(in: fixture.bundleURL)),
            manifestBefore
        )
        XCTAssertEqual(try Data(contentsOf: currentURL), currentBefore)
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), bundleBefore)
    }

    func testFullUpdateRejectsSemanticFingerprintOverrideWithoutBundleMutation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "full-update-semantic-override"
        )
        let bundleBefore = try bundleSnapshot(fixture.bundleURL)
        let divergentCalls = [
            GenotypeWorkbookHaplotypeCall(
                sample: "sample-a",
                locus: "MHC-B",
                haplotype1: "B-H1",
                haplotype2: "B-H2",
                status: "called",
                notes: ""
            ),
        ]

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService().applyHaplotypeOverrides(
                [],
                annotationSidecarURL: nil,
                into: fixture.bundleURL,
                fingerprintInputs: GenotypeWorkbookFingerprintInputs(
                    calls: divergentCalls,
                    includedLoci: ["MHC-B"]
                )
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("only valid for annotation-only"),
                "Unexpected error: \(error)"
            )
        }
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), bundleBefore)
    }

    func testAttestedAnnotationOnlyRejectsMissingSemanticInputsWithoutBundleMutation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "annotation-only-missing-semantic-inputs"
        )
        let bundleBefore = try bundleSnapshot(fixture.bundleURL)
        let fingerprint = try GenotypeCurrentWorkbookInputFingerprint(
            schemaVersion: GenotypeCurrentWorkbookInputFingerprint.schemaVersion,
            sha256: String(repeating: "e", count: 64)
        )

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService().applyHaplotypeOverrides(
                [],
                annotationSidecarURL: nil,
                into: fixture.bundleURL,
                annotationOnly: true,
                provenanceContext: GenotypeWorkbookRevisionProvenanceContext(
                    toolName: "test",
                    toolKind: "test",
                    argv: ["test"],
                    inputFingerprint: fingerprint,
                    syncIntent: .automaticIdle
                )
            )
        ) { error in
            XCTAssertTrue(
                String(describing: error).lowercased().contains(
                    "requires complete semantic fingerprint inputs"
                ),
                "Unexpected error: \(error)"
            )
        }
        XCTAssertEqual(try bundleSnapshot(fixture.bundleURL), bundleBefore)
    }

    func testAnnotationOnlyUpdateAttestsFullSemanticCallsAndRetainsTheirProvenance() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(
            in: root,
            outputName: "annotation-only-semantic-attestation"
        )
        try installCandidateArtifacts(in: fixture.bundleURL, schemaVersion: 2)
        try installMinimalUnifiedPivot(in: fixture.bundleURL)
        let service = GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 5_175) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        )
        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: nil,
            into: fixture.bundleURL
        )
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        let scientificBefore = try inspectTwoSheetCandidateWorkbook(currentURL)
        XCTAssertNotNil(scientificBefore["candidateIDs"])
        let displayedCalls = [
            GenotypeWorkbookHaplotypeCall(
                sample: "sample-a",
                locus: "MHC-A",
                haplotype1: "A-H1",
                haplotype2: "A-H2",
                status: "called",
                notes: "displayed effective call"
            ),
        ]
        let displayedLoci = ["MHC-A"]
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        sidecar.lastEditor = "annotation-only-reviewer"
        try sidecar.encoded().write(to: annotationURL)
        let manifest = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
        let expectedFingerprint = try GenotypeCurrentWorkbookInputFingerprint.make(
            calls: displayedCalls,
            includedLoci: displayedLoci,
            annotationSidecar: sidecar,
            candidateArtifacts: manifest.mhcCandidateArtifacts
        )
        let emptyCallsFingerprint = try GenotypeCurrentWorkbookInputFingerprint.make(
            calls: [],
            includedLoci: displayedLoci,
            annotationSidecar: sidecar,
            candidateArtifacts: manifest.mhcCandidateArtifacts
        )
        XCTAssertNotEqual(expectedFingerprint, emptyCallsFingerprint)

        let updated = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL,
            annotationOnly: true,
            fingerprintInputs: GenotypeWorkbookFingerprintInputs(
                calls: displayedCalls,
                includedLoci: displayedLoci
            ),
            provenanceContext: GenotypeWorkbookRevisionProvenanceContext(
                toolName: "lungfish-cli fastq update-current-workbook",
                toolKind: "cli",
                argv: [
                    "lungfish-cli", "fastq", "update-current-workbook",
                    fixture.bundleURL.path,
                    "--calls-json", "/displayed/calls.json",
                    "--included-locus", "MHC-A",
                    "--annotation-only",
                ],
                inputFingerprint: expectedFingerprint,
                syncIntent: .automaticIdle
            )
        )

        let scientificAfter = try inspectTwoSheetCandidateWorkbook(currentURL)
        for key in [
            "candidateIDs",
            "candidateSequence",
            "unmatchedIDs",
            "sampleADPBHaplotype1",
            "sampleBDQAHaplotype1",
        ] {
            XCTAssertEqual(scientificAfter[key], scientificBefore[key], key)
        }
        XCTAssertEqual(
            try GenotypeCurrentWorkbookInputFingerprint.recorded(
                in: updated,
                bundleURL: fixture.bundleURL
            ),
            expectedFingerprint
        )
        XCTAssertNotEqual(
            try GenotypeCurrentWorkbookInputFingerprint.recorded(
                in: updated,
                bundleURL: fixture.bundleURL
            ),
            emptyCallsFingerprint
        )
        let provenanceURL = ONTGenotypeResultBundle.resolvedURL(
            for: try XCTUnwrap(updated.workbookRevisions?.last?.provenancePath),
            in: fixture.bundleURL
        )
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: provenanceURL)
        )
        XCTAssertEqual(
            envelope.options.explicit["currentWorkbookInputFingerprint"],
            .string(expectedFingerprint.sha256)
        )
        let semanticCallsInput = try XCTUnwrap(
            envelope.files.first { $0.path.hasSuffix("fingerprint-haplotype-calls.json") }
        )
        let semanticCallsURL = URL(fileURLWithPath: semanticCallsInput.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: semanticCallsURL.path))
        XCTAssertEqual(
            semanticCallsInput.checksumSHA256,
            try ProvenanceFileHasher.sha256(of: semanticCallsURL)
        )
        XCTAssertEqual(
            semanticCallsInput.fileSize,
            UInt64(try ProvenanceFileHasher.fileSize(of: semanticCallsURL))
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                [GenotypeWorkbookHaplotypeCall].self,
                from: Data(contentsOf: semanticCallsURL)
            ),
            displayedCalls
        )
        let pythonStep = try XCTUnwrap(
            envelope.steps.first { $0.toolName.contains("python openpyxl") }
        )
        XCTAssertFalse(
            pythonStep.inputs.contains { $0.path.hasSuffix("fingerprint-haplotype-calls.json") }
        )
        XCTAssertFalse(
            pythonStep.argv.contains { $0.hasSuffix("fingerprint-haplotype-calls.json") }
        )
    }

    func testApplyHaplotypeOverridesLegacyProvenanceOmitsWorkbookAttestationOptions() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "legacy-update")

        let updated = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 5_200) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)

        let provenanceURL = ONTGenotypeResultBundle.resolvedURL(
            for: try XCTUnwrap(updated.workbookRevisions?.last?.provenancePath),
            in: fixture.bundleURL
        )
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: provenanceURL)
        )
        XCTAssertNil(envelope.options.explicit["currentWorkbookInputFingerprint"])
        XCTAssertNil(envelope.options.explicit["currentWorkbookInputFingerprintSchemaVersion"])
        XCTAssertNil(envelope.options.explicit["currentWorkbookSyncIntent"])
    }

    func testApplyHaplotypeOverridesWritesMatrixAnnotationsToCurrentWorkbook() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "matrix")
        let annotationURL = fixture.bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-06-30T00:00:00Z")
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-B",
            genotype: "Mamu-I*expected",
            sample: "AR3628"
        )
        sidecar.matrixStyles = [
            .init(
                target: target,
                style: .init(
                    fillColor: "#FFF2CC",
                    textColor: "#C00000",
                    borderColor: "#666666",
                    isBold: true,
                    isItalic: true
                ),
                author: "curator",
                timestamp: "2026-06-30T12:00:00Z"
            )
        ]
        sidecar.matrixComments = [
            .init(
                target: target,
                body: "Expected genotype missing from reads.",
                author: "curator",
                timestamp: "2026-06-30T12:00:00Z"
            )
        ]
        try sidecar.encoded().write(to: annotationURL)

        _ = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 6_000) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        ).applyHaplotypeOverrides([], annotationSidecarURL: annotationURL, into: fixture.bundleURL)

        let inspection = try inspectGenericMatrixWorkbook(try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL))
        XCTAssertEqual(inspection["hasMatrixAnnotationsSheet"], "true")
        XCTAssertEqual(
            inspection["matrixAnnotationStyleRow"],
            [
                "style", "cell", "MHC-B", "Mamu-I*expected", "AR3628", "", "",
                "not-applicable", "", "#FFF2CC", "#C00000", "#666666", "true", "true",
                "curator", "2026-06-30T12:00:00Z", "",
            ].joined(separator: "|")
        )
        XCTAssertEqual(
            inspection["matrixAnnotationCommentRow"],
            [
                "comment", "cell", "MHC-B", "Mamu-I*expected", "AR3628", "", "",
                "not-applicable", "", "", "", "", "", "", "curator",
                "2026-06-30T12:00:00Z", "Expected genotype missing from reads.",
            ].joined(separator: "|")
        )
        XCTAssertEqual(inspection["cellFillSuffix"], "FFF2CC")
        XCTAssertEqual(inspection["cellTextColorSuffix"], "C00000")
        XCTAssertEqual(inspection["cellBorderSuffix"], "666666")
        XCTAssertEqual(inspection["cellBold"], "true")
        XCTAssertEqual(inspection["cellItalic"], "true")
        XCTAssertTrue(inspection["cellComment"]?.contains("Expected genotype missing from reads.") == true)
        XCTAssertEqual(inspection["guideMatrixStyles"], "1")
        XCTAssertEqual(inspection["guideMatrixComments"], "1")
    }

    func testApplyHaplotypeOverridesFormatsReviewsUsingExactSemanticIdentity() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "semantic-reviews")
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        try installSemanticReviewMatrix(in: currentURL)

        let annotationURL = fixture.bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-I*collision",
                    sample: "Sample-FP",
                    stableClusterID: "cluster-a"
                ),
                disposition: .falsePositive,
                author: "reviewer",
                timestamp: "2026-07-24T10:00:00Z"
            ),
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-I*collision",
                    sample: "Sample-Zero",
                    stableClusterID: "cluster-a"
                ),
                disposition: .falseNegative,
                author: "reviewer",
                timestamp: "2026-07-24T10:01:00Z"
            ),
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-I*collision",
                    sample: "Sample-Absent",
                    stableClusterID: "cluster-a"
                ),
                disposition: .falseNegative,
                author: "reviewer",
                timestamp: "2026-07-24T10:02:00Z"
            ),
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-I*collision",
                    sample: "Sample-FP",
                    stableClusterID: "cluster-c"
                ),
                disposition: .falseNegative,
                author: "imported-reviewer",
                timestamp: "2026-07-24T10:03:00Z"
            ),
        ]
        try sidecar.encoded().write(to: annotationURL)

        _ = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 8_000) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        ).applyHaplotypeOverrides([], annotationSidecarURL: annotationURL, into: fixture.bundleURL)

        let inspection = try inspectSemanticReviewWorkbook(currentURL)
        XCTAssertEqual(inspection["falsePositiveValue"], "[42]")
        XCTAssertEqual(inspection["falsePositiveItalic"], "true")
        XCTAssertEqual(inspection["falsePositiveColor"], "767676")
        XCTAssertEqual(inspection["explicitZeroValue"], "0")
        XCTAssertEqual(inspection["explicitZeroType"], "n")
        XCTAssertEqual(inspection["explicitZeroBorders"], "thick|thick|thick|thick")
        XCTAssertEqual(inspection["absentValue"], "")
        XCTAssertEqual(inspection["absentType"], "n")
        XCTAssertEqual(inspection["absentBorders"], "thick|thick|thick|thick")
        XCTAssertEqual(inspection["otherLocusValue"], "42", "The colliding genotype at another locus must not be formatted")
        XCTAssertEqual(inspection["otherStableIDValue"], "42", "The colliding genotype at another stable ID must not be formatted")
        XCTAssertEqual(inspection["invalidReviewValue"], "42", "An ineligible false-negative import must not be formatted")
        XCTAssertEqual(inspection["invalidReviewBorders"], "|||")
        XCTAssertTrue(inspection["validReviewRow"]?.contains("|cluster-a|falsePositive|valid|") == true)
        XCTAssertTrue(inspection["invalidReviewRow"]?.contains("|cluster-c|falseNegative|invalid|") == true)
        XCTAssertTrue(inspection["invalidAuditRow"]?.contains("validateMatrixReview") == true)
        XCTAssertTrue(inspection["invalidAuditRow"]?.contains("|cluster-c|falseNegative|invalid|") == true)
    }

    func testClearingMatrixReviewsRestoresManagedPresentationAndRemovesStaleSheets() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "review-clear")
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        try installSemanticReviewMatrix(in: currentURL)
        let originalInspection = try inspectSemanticReviewWorkbook(currentURL)
        let annotationURL = fixture.bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-I*collision",
                    sample: "Sample-FP",
                    stableClusterID: "cluster-a"
                ),
                disposition: .falsePositive,
                author: "reviewer",
                timestamp: "2026-07-24T10:00:00Z"
            ),
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-I*collision",
                    sample: "Sample-Zero",
                    stableClusterID: "cluster-a"
                ),
                disposition: .falseNegative,
                author: "reviewer",
                timestamp: "2026-07-24T10:01:00Z"
            )
        ]
        try sidecar.encoded().write(to: annotationURL)
        let service = GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 8_025) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        )
        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )
        XCTAssertEqual(try inspectSemanticReviewWorkbook(currentURL)["falsePositiveValue"], "[42]")
        _ = try runPython(["-c", #"""
import sys
from copy import copy
from openpyxl import load_workbook
from openpyxl.styles import Side

path = sys.argv[1]
wb = load_workbook(path)
ws = wb["matrix"]
font = copy(ws["D7"].font)
font.bold = True
font.italic = False
ws["D7"].font = font
border = copy(ws["E7"].border)
border.left = Side(style="thin", color="FF123456")
ws["E7"].border = border
wb.save(path)
"""#, currentURL.path])

        sidecar.matrixReviews = []
        try sidecar.encoded().write(to: annotationURL)
        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )

        let inspection = try inspectSemanticReviewWorkbook(currentURL)
        XCTAssertEqual(inspection["falsePositiveValue"], "42")
        XCTAssertEqual(inspection["falsePositiveItalic"], "false")
        XCTAssertEqual(inspection["falsePositiveColor"], originalInspection["falsePositiveColor"])
        XCTAssertEqual(inspection["falsePositiveBold"], "true")
        XCTAssertEqual(inspection["explicitZeroBorders"], "thin|||")
        XCTAssertEqual(inspection["hasMatrixAnnotationsSheet"], "false")
        XCTAssertEqual(inspection["hasManagedReviewStateSheet"], "false")
    }

    func testDuplicateExactReviewTargetsFailClosedInEitherOrder() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: "Mamu-I*collision",
            sample: "Sample-FP",
            stableClusterID: "cluster-a"
        )
        for (index, dispositions) in [
            [
                GenotypeAnnotationSidecar.MatrixReviewDisposition.falseNegative,
                .falsePositive,
            ],
            [
                GenotypeAnnotationSidecar.MatrixReviewDisposition.falsePositive,
                .falseNegative,
            ],
        ].enumerated() {
            let fixture = try makeGenericMatrixWorkbookBundle(
                in: root,
                outputName: "duplicate-review-order-\(index)"
            )
            let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
            try installSemanticReviewMatrix(in: currentURL)
            let original = try inspectSemanticReviewWorkbook(currentURL)
            let annotationURL = fixture.bundleURL.appendingPathComponent(
                GenotypeAnnotationSidecar.filename
            )
            var sidecar = GenotypeAnnotationSidecar.empty(
                generatedAt: "2026-07-24T00:00:00Z"
            )
            sidecar.matrixReviews = dispositions.enumerated().map { offset, disposition in
                .init(
                    target: target,
                    disposition: disposition,
                    author: "import-\(offset)",
                    timestamp: offset == 0
                        ? "2026-07-24T10:00:00"
                        : "2026-07-24T10:01:00Z"
                )
            }
            try sidecar.encoded().write(to: annotationURL)

            _ = try GenotypeWorkbookRevisionService(
                dateProvider: { Date(timeIntervalSince1970: 8_035) },
                userProvider: { "tester" },
                pythonExecutableURL: testPythonExecutableURL
            ).applyHaplotypeOverrides(
                [],
                annotationSidecarURL: annotationURL,
                into: fixture.bundleURL
            )

            let inspection = try inspectSemanticReviewWorkbook(currentURL)
            XCTAssertEqual(inspection["falsePositiveValue"], "42")
            XCTAssertEqual(inspection["falsePositiveItalic"], "false")
            XCTAssertEqual(inspection["falsePositiveColor"], original["falsePositiveColor"])
            XCTAssertEqual(
                inspection["falsePositiveBorders"],
                original["falsePositiveBorders"]
            )
            XCTAssertEqual(inspection["conflictingReviewRows"], "2")
            XCTAssertEqual(inspection["conflictingAuditRows"], "2")
            XCTAssertTrue(
                inspection["conflictingReviewReasons"]?.contains(
                    "Conflicting duplicate review records target the same projection cell."
                ) == true
            )
        }
    }

    func testReviewBecomingInvalidRestoresPriorManagedPresentation() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "review-valid-invalid")
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        try installSemanticReviewMatrix(in: currentURL)
        let originalInspection = try inspectSemanticReviewWorkbook(currentURL)
        let annotationURL = fixture.bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: "Mamu-I*collision",
            sample: "Sample-FP",
            stableClusterID: "cluster-a"
        )
        sidecar.matrixReviews = [
            .init(
                target: target,
                disposition: .falsePositive,
                author: "reviewer",
                timestamp: "2026-07-24T10:00:00Z"
            )
        ]
        try sidecar.encoded().write(to: annotationURL)
        let service = GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 8_050) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        )
        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )

        sidecar.matrixReviews = [
            .init(
                target: target,
                disposition: .falseNegative,
                author: "imported-reviewer",
                timestamp: "2026-07-24T10:01:00Z"
            )
        ]
        try sidecar.encoded().write(to: annotationURL)
        _ = try service.applyHaplotypeOverrides(
            [],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )

        let inspection = try inspectSemanticReviewWorkbook(currentURL)
        XCTAssertEqual(inspection["falsePositiveValue"], "42")
        XCTAssertEqual(inspection["falsePositiveItalic"], "false")
        XCTAssertEqual(inspection["falsePositiveColor"], originalInspection["falsePositiveColor"])
        XCTAssertEqual(inspection["invalidReviewBorders"], "|||")
        XCTAssertTrue(inspection["invalidReviewRow"]?.contains("|cluster-a|falseNegative|invalid|") == true)
        XCTAssertEqual(inspection["hasManagedReviewStateSheet"], "false")
    }

    func testApplyHaplotypeOverridesComposesResolvedNativeNotesByScope() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "semantic-notes")
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        try installSemanticReviewMatrix(in: currentURL, withUnrelatedComments: true)

        let rowTarget = GenotypeAnnotationSidecar.MatrixTarget.row(
            locus: "MHC-A",
            genotype: "Mamu-I*collision",
            stableClusterID: "cluster-a"
        )
        let columnTarget = GenotypeAnnotationSidecar.MatrixTarget.column(sample: "Sample-FP")
        let cellTarget = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: "Mamu-I*collision",
            sample: "Sample-FP",
            stableClusterID: "cluster-a"
        )
        let annotationURL = fixture.bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        sidecar.matrixComments = [
            .init(
                target: cellTarget,
                body: "Superseded cell note.",
                author: "older",
                timestamp: "2026-07-24T09:00:00Z"
            ),
            .init(
                target: rowTarget,
                body: "Allele-level note.",
                author: "row-author",
                timestamp: "2026-07-24T10:00:00Z"
            ),
            .init(
                target: columnTarget,
                body: "Sample-level note.",
                author: "column-author",
                timestamp: "2026-07-24T10:01:00Z"
            ),
            .init(
                target: cellTarget,
                body: "Current cell note.",
                author: "cell-author",
                timestamp: "2026-07-24T10:02:00Z"
            ),
        ]
        try sidecar.encoded().write(to: annotationURL)

        _ = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 8_100) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        ).applyHaplotypeOverrides([], annotationSidecarURL: annotationURL, into: fixture.bundleURL)

        let inspection = try inspectSemanticReviewWorkbook(currentURL)
        let rowComment = try XCTUnwrap(inspection["rowComment"])
        let columnComment = try XCTUnwrap(inspection["columnComment"])
        let cellComment = try XCTUnwrap(inspection["cellComment"])
        XCTAssertTrue(rowComment.contains("Existing row note"))
        XCTAssertTrue(rowComment.contains("Allele Row"))
        XCTAssertTrue(rowComment.contains("Body: Allele-level note."))
        XCTAssertTrue(rowComment.contains("Author: row-author"))
        XCTAssertTrue(rowComment.contains("Timestamp: 2026-07-24T10:00:00Z"))
        XCTAssertTrue(columnComment.contains("Sample Column"))
        XCTAssertTrue(columnComment.contains("Body: Sample-level note."))
        XCTAssertTrue(cellComment.contains("Existing cell note"))
        XCTAssertFalse(cellComment.contains("Superseded cell note."))
        XCTAssertTrue(cellComment.contains("Current cell note."))
        let rowRange = try XCTUnwrap(cellComment.range(of: "Allele Row"))
        let columnRange = try XCTUnwrap(cellComment.range(of: "Sample Column"))
        let cellRange = try XCTUnwrap(cellComment.range(of: "\nCell\n"))
        XCTAssertLessThan(rowRange.lowerBound, columnRange.lowerBound)
        XCTAssertLessThan(columnRange.lowerBound, cellRange.lowerBound)
        XCTAssertEqual(inspection["resolvedCellCommentRows"], "1")
        XCTAssertTrue(inspection["commentIdentityRow"]?.contains("|cell|MHC-A|Mamu-I*collision|Sample-FP|cluster-a|") == true)
    }

    func testApplyHaplotypeOverridesProvenanceNamesFinalStoredSidecarAndWorkbook() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "semantic-provenance")
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        try installSemanticReviewMatrix(in: currentURL)
        let annotationURL = fixture.bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-I*collision",
                    sample: "Sample-FP",
                    stableClusterID: "cluster-a"
                ),
                disposition: .falsePositive,
                author: "reviewer",
                timestamp: "2026-07-24T10:00:00Z"
            )
        ]
        try sidecar.encoded().write(to: annotationURL)

        let updated = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 8_200) },
            userProvider: { "tester" },
            pythonExecutableURL: testPythonExecutableURL
        ).applyHaplotypeOverrides([], annotationSidecarURL: annotationURL, into: fixture.bundleURL)

        let provenanceURL = ONTGenotypeResultBundle.resolvedURL(
            for: try XCTUnwrap(updated.workbookRevisions?.last?.provenancePath),
            in: fixture.bundleURL
        )
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: provenanceURL)
        )
        let pythonStep = try XCTUnwrap(envelope.steps.first { $0.toolName.contains("python openpyxl") })
        let sidecarInput = try XCTUnwrap(pythonStep.inputs.first { $0.path == annotationURL.path })
        XCTAssertEqual(sidecarInput.checksumSHA256, try ProvenanceFileHasher.sha256(of: annotationURL))
        XCTAssertEqual(sidecarInput.fileSize, UInt64(try ProvenanceFileHasher.fileSize(of: annotationURL)))
        let workbookOutput = try XCTUnwrap(pythonStep.outputs.first { $0.path == currentURL.path })
        XCTAssertEqual(workbookOutput.checksumSHA256, try ProvenanceFileHasher.sha256(of: currentURL))
        XCTAssertEqual(workbookOutput.fileSize, UInt64(try ProvenanceFileHasher.fileSize(of: currentURL)))
        let durableReplayArgv = try XCTUnwrap(pythonStep.durableReplayArgv)
        XCTAssertTrue(durableReplayArgv.contains(annotationURL.path))
        XCTAssertTrue(durableReplayArgv.contains(currentURL.path))
        XCTAssertTrue(pythonStep.reproducibleCommand.contains(annotationURL.path))
        XCTAssertTrue(pythonStep.reproducibleCommand.contains(currentURL.path))
    }

    func testConcurrentAnnotationPublicationDuringWorkbookUpdateFailsClosedAndPreservesExactPair() throws {
        XCTAssertTrue(pythonCanImportOpenpyxl(), "The managed test runtime must provide openpyxl")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeGenericMatrixWorkbookBundle(in: root, outputName: "annotation-race")
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        try installSemanticReviewMatrix(in: currentURL)
        let workbookBefore = try Data(contentsOf: currentURL)
        let manifestBefore = try Data(contentsOf: ONTGenotypeResultBundle.manifestURL(in: fixture.bundleURL))
        let annotationURL = fixture.bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let annotationProvenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        var initial = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        initial.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-I*collision",
                    sample: "Sample-FP",
                    stableClusterID: "cluster-a"
                ),
                disposition: .falsePositive,
                author: "initial",
                timestamp: "2026-07-24T10:00:00Z"
            )
        ]
        try initial.encoded().write(to: annotationURL)
        let initialProvenance = Data("initial-provenance".utf8)
        try initialProvenance.write(to: annotationProvenanceURL)

        var concurrent = initial
        concurrent.matrixReviews = []
        concurrent.matrixComments = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-I*collision",
                    sample: "Sample-FP",
                    stableClusterID: "cluster-a"
                ),
                body: "Concurrent annotation edit",
                author: "other-writer",
                timestamp: "2026-07-24T10:01:00Z"
            )
        ]
        let concurrentData = try concurrent.encoded()
        let concurrentProvenance = Data("concurrent-provenance".utf8)

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                dateProvider: { Date(timeIntervalSince1970: 8_250) },
                userProvider: { "tester" },
                pythonExecutableURL: testPythonExecutableURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "after-python-before-source-conflict-check" else { return }
                    try concurrentData.write(to: annotationURL, options: .atomic)
                    try concurrentProvenance.write(to: annotationProvenanceURL, options: .atomic)
                }
            ).applyHaplotypeOverrides(
                [],
                annotationSidecarURL: annotationURL,
                into: fixture.bundleURL
            )
        )

        XCTAssertEqual(try Data(contentsOf: annotationURL), concurrentData)
        XCTAssertEqual(try Data(contentsOf: annotationProvenanceURL), concurrentProvenance)
        XCTAssertEqual(try Data(contentsOf: currentURL), workbookBefore)
        XCTAssertEqual(
            try Data(contentsOf: ONTGenotypeResultBundle.manifestURL(in: fixture.bundleURL)),
            manifestBefore
        )
    }

    func testImportRevisedWorkbookKeepsPrimaryAndSnapshotsPreviousCurrent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeBundle(in: root, outputName: "cohort", includeCurrent: true)
        let importedURL = root.appendingPathComponent("collaborator.xlsx")
        try workbookData("collaborator edit").write(to: importedURL)

        let updatedManifest = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 1_800) },
            userProvider: { "tester" }
        ).importRevisedWorkbook(from: importedURL, into: fixture.bundleURL, label: "Collaborator edit")

        let primaryWorkbookURL = try ONTGenotypeResultBundle.primaryWorkbookURL(for: fixture.bundleURL)
        let currentWorkbookURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        XCTAssertEqual(try Data(contentsOf: primaryWorkbookURL), workbookData("primary"))
        XCTAssertEqual(try Data(contentsOf: currentWorkbookURL), workbookData("collaborator edit"))
        XCTAssertEqual(updatedManifest.primaryWorkbookPath, fixture.manifest.primaryWorkbookPath)
        XCTAssertEqual(updatedManifest.currentWorkbookPath, "artifacts/workbooks/current.xlsx")
        XCTAssertEqual(updatedManifest.referenceRecordStore, fixture.manifest.referenceRecordStore)

        let snapshot = try XCTUnwrap(updatedManifest.workbookRevisions?.first { revision in
            revision.path.hasPrefix("artifacts/workbooks/revisions/")
        })
        XCTAssertEqual(
            try Data(contentsOf: ONTGenotypeResultBundle.resolvedURL(for: snapshot.path, in: fixture.bundleURL)),
            workbookData("current")
        )
        let imported = try XCTUnwrap(updatedManifest.workbookRevisions?.last)
        XCTAssertEqual(imported.role, .imported)
        XCTAssertEqual(imported.path, "artifacts/workbooks/current.xlsx")
        XCTAssertEqual(imported.sourceFilename, importedURL.lastPathComponent)
        XCTAssertNotNil(imported.provenancePath)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: ONTGenotypeResultBundle.resolvedURL(
                for: try XCTUnwrap(imported.provenancePath),
                in: fixture.bundleURL
            ).path
        ))
    }

    func testImportRevisedWorkbookPreservesActiveAIHaplotypeRevisionFields() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeBundle(in: root, outputName: "cohort", includeCurrent: true)
        let aiRevision = ONTGenotypeHaplotypeAnalysisRevision(
            id: "haprev-ai-0001",
            method: .aiRefinement,
            path: "artifacts/ai-haplotyping/revisions/haprev-ai-0001/haplotype-analysis.json",
            predecessorID: nil,
            predecessorPath: fixture.manifest.haplotypeAnalysisPath,
            createdAt: "2026-06-14T18:00:00Z",
            reviewState: .needsReview,
            sha256: String(repeating: "a", count: 64),
            sizeBytes: 123,
            provenancePath: "artifacts/ai-haplotyping/revisions/haprev-ai-0001/ai-haplotyping.lungfish-provenance.json",
            provider: "openai",
            model: "gpt-5-mini",
            promptTemplateID: "lungfish.ai-haplotyping.refinement",
            promptTemplateVersion: "2026-06-14.1",
            promptHash: "sha256:\(String(repeating: "b", count: 64))",
            evidenceSnapshotPath: "artifacts/ai-haplotyping/revisions/haprev-ai-0001/evidence-registry.json",
            validationReportPath: "artifacts/ai-haplotyping/revisions/haprev-ai-0001/validation-report.json"
        )
        let manifestWithAIRevision = ONTGenotypeResultBundleManifest(
            schemaVersion: fixture.manifest.schemaVersion,
            kind: fixture.manifest.kind,
            outputName: fixture.manifest.outputName,
            analysisName: fixture.manifest.analysisName,
            primaryWorkbookPath: fixture.manifest.primaryWorkbookPath,
            currentWorkbookPath: fixture.manifest.currentWorkbookPath,
            workbookRevisions: fixture.manifest.workbookRevisions,
            longSummaryCSVPath: fixture.manifest.longSummaryCSVPath,
            sampleSummaryCSVPath: fixture.manifest.sampleSummaryCSVPath,
            statsJSONPath: fixture.manifest.statsJSONPath,
            provenancePath: fixture.manifest.provenancePath,
            haplotypeAnalysisPath: aiRevision.path,
            haplotypeDefinitionSetID: fixture.manifest.haplotypeDefinitionSetID,
            haplotypeAssayID: fixture.manifest.haplotypeAssayID,
            createdAt: fixture.manifest.createdAt,
            activeHaplotypeAnalysisRevisionID: aiRevision.id,
            haplotypeAnalysisRevisions: [aiRevision]
        )
        try ONTGenotypeResultBundle.writeManifest(manifestWithAIRevision, to: fixture.bundleURL)
        let importedURL = root.appendingPathComponent("collaborator.xlsx")
        try workbookData("collaborator edit").write(to: importedURL)

        let updatedManifest = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 1_900) },
            userProvider: { "tester" }
        ).importRevisedWorkbook(from: importedURL, into: fixture.bundleURL, label: "Collaborator edit")
        let persistedManifest = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)

        for manifest in [updatedManifest, persistedManifest] {
            XCTAssertEqual(manifest.haplotypeAnalysisPath, aiRevision.path)
            XCTAssertEqual(manifest.activeHaplotypeAnalysisRevisionID, aiRevision.id)
            XCTAssertEqual(manifest.haplotypeAnalysisRevisions, [aiRevision])
        }
    }

    func testImportMigratesOldPrimaryOnlyBundleBeforeReplacingCurrent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeBundle(in: root, outputName: "legacy", includeCurrent: false)
        let importedURL = root.appendingPathComponent("reviewed.xlsx")
        try workbookData("reviewed").write(to: importedURL)

        let updatedManifest = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 2_400) },
            userProvider: { "tester" }
        ).importRevisedWorkbook(from: importedURL, into: fixture.bundleURL, label: "Reviewed")

        XCTAssertEqual(updatedManifest.primaryWorkbookPath, "legacy.xlsx")
        XCTAssertEqual(updatedManifest.currentWorkbookPath, "artifacts/workbooks/current.xlsx")
        XCTAssertEqual(
            try Data(contentsOf: ONTGenotypeResultBundle.primaryWorkbookURL(for: fixture.bundleURL)),
            workbookData("primary")
        )
        XCTAssertEqual(
            try Data(contentsOf: ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)),
            workbookData("reviewed")
        )
        XCTAssertTrue(updatedManifest.workbookRevisions?.contains { $0.role == .initialCurrentCopy } == true)
        XCTAssertTrue(updatedManifest.workbookRevisions?.contains { $0.role == .imported } == true)
    }

    func testImportRejectsNonXLSXWithoutChangingManifestOrCurrentWorkbook() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeBundle(in: root, outputName: "cohort", includeCurrent: true)
        let invalidURL = root.appendingPathComponent("not-a-workbook.txt")
        try Data("not a workbook".utf8).write(to: invalidURL)
        let originalManifest = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
        let originalCurrent = try Data(contentsOf: ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL))

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService().importRevisedWorkbook(
                from: invalidURL,
                into: fixture.bundleURL,
                label: "bad"
            )
        )

        XCTAssertEqual(try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL), originalManifest)
        XCTAssertEqual(
            try Data(contentsOf: ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)),
            originalCurrent
        )
    }

    func testApplyHaplotypeOverridesUsesInjectedPythonExecutable() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeBundle(in: root, outputName: "cohort", includeCurrent: true)
        let fakePythonURL = root.appendingPathComponent("fake-python")
        let invocationLogURL = root.appendingPathComponent("python-argv.txt")
        try """
        #!/bin/sh
        printf '%s\n' "$0" "$@" > "\(invocationLogURL.path)"
        echo "fake python used" >&2
        exit 73
        """.write(to: fakePythonURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakePythonURL.path
        )

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(pythonExecutableURL: fakePythonURL)
                .applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("fake python used"))
        }

        let invocation = try String(contentsOf: invocationLogURL, encoding: .utf8)
        XCTAssertTrue(invocation.hasPrefix(fakePythonURL.path))
        XCTAssertTrue(invocation.contains("apply-current-workbook-overrides.py"))
    }

    func testImportSnapshotsExternalEditBeforeManagedReplacement() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeBundle(in: root, outputName: "cohort", includeCurrent: true)
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        try workbookData("manual direct edit").write(to: currentURL)
        let importedURL = root.appendingPathComponent("replacement.xlsx")
        try workbookData("replacement").write(to: importedURL)

        let updatedManifest = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 3_600) },
            userProvider: { "tester" }
        ).importRevisedWorkbook(from: importedURL, into: fixture.bundleURL, label: "Replacement")

        let externalSnapshot = try XCTUnwrap(updatedManifest.workbookRevisions?.first { revision in
            revision.role == .externalEditSnapshot
                && revision.path.hasPrefix("artifacts/workbooks/revisions/")
        })
        XCTAssertEqual(
            try Data(contentsOf: ONTGenotypeResultBundle.resolvedURL(for: externalSnapshot.path, in: fixture.bundleURL)),
            workbookData("manual direct edit")
        )
        XCTAssertEqual(try Data(contentsOf: currentURL), workbookData("replacement"))
    }

    private func makeBundle(
        in root: URL,
        outputName: String,
        includeCurrent: Bool
    ) throws -> (bundleURL: URL, manifest: ONTGenotypeResultBundleManifest) {
        let bundleURL = root.appendingPathComponent("\(outputName).lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let primaryWorkbookURL = bundleURL.appendingPathComponent("\(outputName).xlsx")
        try workbookData("primary").write(to: primaryWorkbookURL)
        let artifacts = try writeMinimalNativeArtifacts(in: bundleURL, outputName: outputName)

        let currentWorkbookPath: String?
        let revisions: [ONTGenotypeWorkbookRevision]?
        if includeCurrent {
            let currentURL = bundleURL
                .appendingPathComponent("artifacts/workbooks", isDirectory: true)
                .appendingPathComponent("current.xlsx")
            try FileManager.default.createDirectory(
                at: currentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try workbookData("current").write(to: currentURL)
            currentWorkbookPath = "artifacts/workbooks/current.xlsx"
            revisions = [
                ONTGenotypeWorkbookRevision(
                    id: "initial-current-copy",
                    role: .initialCurrentCopy,
                    path: "artifacts/workbooks/current.xlsx",
                    label: "Initial editable workbook",
                    sourceFilename: primaryWorkbookURL.lastPathComponent,
                    createdAt: "2026-06-02T00:00:00Z",
                    user: "tester",
                    predecessorPath: primaryWorkbookURL.lastPathComponent,
                    sha256: try ProvenanceFileHasher.sha256(of: currentURL),
                    sizeBytes: Int64(try ProvenanceFileHasher.fileSize(of: currentURL)),
                    provenancePath: nil
                )
            ]
        } else {
            currentWorkbookPath = nil
            revisions = nil
        }

        let manifest = ONTGenotypeResultBundleManifest(
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            workflowKind: .fullLengthONTMHCGenotype,
            workflowMode: .genotypeOnly,
            outputName: outputName,
            analysisName: outputName,
            primaryWorkbookPath: primaryWorkbookURL.lastPathComponent,
            currentWorkbookPath: currentWorkbookPath,
            workbookRevisions: revisions,
            longSummaryCSVPath: artifacts.genotypeCSV.lastPathComponent,
            sampleSummaryCSVPath: artifacts.sampleCSV.lastPathComponent,
            statsJSONPath: artifacts.statsJSON.lastPathComponent,
            provenancePath: artifacts.provenance.lastPathComponent,
            referenceRecordStore: ONTGenotypeReferenceRecordStoreInfo(
                databasePath: "reference/records.sqlite",
                recordCount: 2,
                fieldCount: 4,
                sha256: String(repeating: "b", count: 64),
                sizeBytes: 512
            )
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)
        return (bundleURL, manifest)
    }

    private func writeMinimalNativeArtifacts(
        in bundleURL: URL,
        outputName: String
    ) throws -> (genotypeCSV: URL, sampleCSV: URL, statsJSON: URL, provenance: URL) {
        let genotypeCSVURL = bundleURL.appendingPathComponent("\(outputName).retained-demux-genotypes.csv")
        let sampleCSVURL = bundleURL.appendingPathComponent("\(outputName).retained-demux-samples.csv")
        let statsJSONURL = bundleURL.appendingPathComponent("\(outputName).retained-demux-stats.json")
        let provenanceURL = bundleURL.appendingPathComponent("retained-demux-genotyping-provenance.json")
        try Data("{}".utf8).write(to: provenanceURL)
        try """
        sample,genotype,passed_alignments,passed_unique_reads
        SampleA,allele1,1,1
        """.write(to: genotypeCSVURL, atomically: true, encoding: .utf8)
        try """
        sample,passed_alignments,passed_unique_reads
        SampleA,1,1
        """.write(to: sampleCSVURL, atomically: true, encoding: .utf8)
        try """
        {
          "totalInputReads": 1,
          "totalAlignments": 1,
          "passedAlignments": 1,
          "retainedUniqueReads": 1,
          "retainedUniquePercentOfTotalReads": 100.0,
          "assignedUniqueRetainedReads": 1,
          "unassignedUniqueRetainedReads": 0
        }
        """.write(to: statsJSONURL, atomically: true, encoding: .utf8)
        return (genotypeCSVURL, sampleCSVURL, statsJSONURL, provenanceURL)
    }

    private func makeMCMWorkbookBundle(
        in root: URL,
        outputName: String
    ) throws -> (bundleURL: URL, manifest: ONTGenotypeResultBundleManifest) {
        let bundleURL = root.appendingPathComponent("\(outputName).lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let primaryWorkbookURL = bundleURL.appendingPathComponent("\(outputName).xlsx")
        let currentURL = bundleURL
            .appendingPathComponent("artifacts/workbooks", isDirectory: true)
            .appendingPathComponent("current.xlsx")
        try FileManager.default.createDirectory(at: currentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeMinimalMCMWorkbook(at: primaryWorkbookURL)
        try FileManager.default.copyItem(at: primaryWorkbookURL, to: currentURL)
        let artifacts = try writeMinimalNativeArtifacts(in: bundleURL, outputName: outputName)
        let currentRevision = ONTGenotypeWorkbookRevision(
            id: "initial-current-copy",
            role: .initialCurrentCopy,
            path: "artifacts/workbooks/current.xlsx",
            label: "Initial editable workbook",
            sourceFilename: primaryWorkbookURL.lastPathComponent,
            createdAt: "2026-06-02T00:00:00Z",
            user: "tester",
            predecessorPath: primaryWorkbookURL.lastPathComponent,
            sha256: try ProvenanceFileHasher.sha256(of: currentURL),
            sizeBytes: Int64(try ProvenanceFileHasher.fileSize(of: currentURL)),
            provenancePath: nil
        )
        let referenceDirectoryURL = bundleURL.appendingPathComponent("artifacts/reference", isDirectory: true)
        try FileManager.default.createDirectory(at: referenceDirectoryURL, withIntermediateDirectories: true)
        let referenceVisualizationJSONURL = referenceDirectoryURL
            .appendingPathComponent("mhc-reference-visualizations.json")
        let referenceGenBankURL = referenceDirectoryURL.appendingPathComponent("mhc-reference-records.gb")
        let referenceFASTAURL = referenceDirectoryURL.appendingPathComponent("mhc-reference-records.fasta")
        let referenceVisualizationDocument = ONTMHCReferenceVisualizationArtifact(
            schemaVersion: 1,
            records: []
        )
        let referenceEncoder = JSONEncoder()
        referenceEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try referenceEncoder.encode(referenceVisualizationDocument).write(to: referenceVisualizationJSONURL)
        try Data().write(to: referenceGenBankURL)
        try Data().write(to: referenceFASTAURL)
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: outputName,
            analysisName: outputName,
            primaryWorkbookPath: primaryWorkbookURL.lastPathComponent,
            currentWorkbookPath: "artifacts/workbooks/current.xlsx",
            workbookRevisions: [currentRevision],
            longSummaryCSVPath: artifacts.genotypeCSV.lastPathComponent,
            sampleSummaryCSVPath: artifacts.sampleCSV.lastPathComponent,
            statsJSONPath: artifacts.statsJSON.lastPathComponent,
            provenancePath: artifacts.provenance.lastPathComponent,
            mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifacts(
                schemaVersion: 1,
                recordCount: 0,
                recordsJSON: try artifactReference(referenceVisualizationJSONURL, relativeTo: bundleURL),
                genBank: try artifactReference(referenceGenBankURL, relativeTo: bundleURL),
                fasta: try artifactReference(referenceFASTAURL, relativeTo: bundleURL)
            )
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)
        return (bundleURL, manifest)
    }

    private func makeGenericMatrixWorkbookBundle(
        in root: URL,
        outputName: String
    ) throws -> (bundleURL: URL, manifest: ONTGenotypeResultBundleManifest) {
        let bundleURL = root.appendingPathComponent("\(outputName).lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let primaryWorkbookURL = bundleURL.appendingPathComponent("\(outputName).xlsx")
        let currentURL = bundleURL
            .appendingPathComponent("artifacts/workbooks", isDirectory: true)
            .appendingPathComponent("current.xlsx")
        try FileManager.default.createDirectory(at: currentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeMinimalGenericMatrixWorkbook(at: primaryWorkbookURL)
        try FileManager.default.copyItem(at: primaryWorkbookURL, to: currentURL)
        let artifacts = try writeMinimalNativeArtifacts(in: bundleURL, outputName: outputName)
        let currentRevision = ONTGenotypeWorkbookRevision(
            id: "initial-current-copy",
            role: .initialCurrentCopy,
            path: "artifacts/workbooks/current.xlsx",
            label: "Initial editable workbook",
            sourceFilename: primaryWorkbookURL.lastPathComponent,
            createdAt: "2026-06-30T00:00:00Z",
            user: "tester",
            predecessorPath: primaryWorkbookURL.lastPathComponent,
            sha256: try ProvenanceFileHasher.sha256(of: currentURL),
            sizeBytes: Int64(try ProvenanceFileHasher.fileSize(of: currentURL)),
            provenancePath: nil
        )
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: outputName,
            analysisName: outputName,
            primaryWorkbookPath: primaryWorkbookURL.lastPathComponent,
            currentWorkbookPath: "artifacts/workbooks/current.xlsx",
            workbookRevisions: [currentRevision],
            longSummaryCSVPath: artifacts.genotypeCSV.lastPathComponent,
            sampleSummaryCSVPath: artifacts.sampleCSV.lastPathComponent,
            statsJSONPath: artifacts.statsJSON.lastPathComponent,
            provenancePath: artifacts.provenance.lastPathComponent
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)
        return (bundleURL, manifest)
    }

    private func makeMinimalGenericMatrixWorkbook(at url: URL) throws {
        let code = #"""
import sys
from openpyxl import Workbook
from openpyxl.styles import PatternFill

path = sys.argv[1]
wb = Workbook()
ws = wb.active
ws.title = "matrix"
ws.append(["Animal ID", None, None, "AR3628"])
ws.append(["GS ID", "Total", "Average", "AR3628"])
ws.append(["Filtered exact-match read count", None, None, 12])
ws.append([])
ws.append(["Comments", "Subtotal", "# Obs.", None])
ws.append(["Genotype", "Total", "# Obs.", "AR3628"])
ws.append(["Mamu-I*expected", 5, 1, 5])
wb.save(path)
"""#
        _ = try runPython(["-c", code, url.path])
    }

    private func installSemanticReviewMatrix(
        in url: URL,
        withUnrelatedComments: Bool = false
    ) throws {
        let code = #"""
import sys
from openpyxl import Workbook
from openpyxl.comments import Comment

path = sys.argv[1]
with_comments = sys.argv[2] == "true"
wb = Workbook()
ws = wb.active
ws.title = "matrix"
ws.append(["Animal ID", None, None, "Sample-FP", "Sample-Zero", "Sample-Absent"])
ws.append(["GS ID", "Total", "Average", "Sample-FP", "Sample-Zero", "Sample-Absent"])
ws.append(["Filtered exact-match read count", None, None, 84, 0, 0])
ws.append([])
ws.append(["Comments", "Subtotal", "# Obs.", None, None, None])
ws.append(["Genotype", "Locus", "Stable Cluster ID", "Sample-FP", "Sample-Zero", "Sample-Absent"])
ws.append(["Mamu-I*collision", "MHC-A", "cluster-a", 42, 0, None])
ws.append(["Mamu-I*collision", "MHC-B", "cluster-b", 42, None, None])
ws.append(["Mamu-I*collision", "MHC-A", "cluster-c", 42, None, None])
if with_comments:
    ws["A7"].comment = Comment("Existing row note", "existing-author")
    ws["D7"].comment = Comment("Existing cell note", "existing-author")
wb.save(path)
"""#
        _ = try runPython(["-c", code, url.path, withUnrelatedComments ? "true" : "false"])
    }

    private func makeMinimalMCMWorkbook(at url: URL) throws {
        let code = #"""
import sys
from openpyxl import Workbook
from openpyxl.styles import PatternFill

path = sys.argv[1]
wb = Workbook()
guide = wb.active
guide.title = "Interpretation Guide"
guide.append(["Field", "Interpretation"])
guide.append(["Haplotype min reads", "10"])

abbr = wb.create_sheet("Abbreviated Haplotypes")
headers = [
    "Client ID", "GS ID", "Mapped Read Count", "Haplotype 1", "Haplotype 2", None,
    "MHC-A Haplotype 1", "MHC-B Haplotype 1", "MHC-DRB Haplotype 1", "MHC-DQA/B Haplotype 1", "MHC-DPA/B Haplotype 1",
    None,
    "MHC-A Haplotype 2", "MHC-B Haplotype 2", "MHC-DRB Haplotype 2", "MHC-DQA/B Haplotype 2", "MHC-DPA/B Haplotype 2",
    "Comments",
]
abbr.append(headers)
abbr.append(["DW472", "DW472", 100, "M4", "M7", None, "M4A", "M4B", None, "M4DQ", "M4DP", None, "M7A", "M7B", None, "M7DQ", "M7DP", None])

full = wb.create_sheet("Full Sequencing Results 1")
full.cell(1, 1).value = "Client ID"
full.cell(1, 4).value = "DW472"
full.cell(2, 1).value = "GS ID"
full.cell(2, 4).value = "DW472"
full.cell(3, 1).value = "Mapped Read Count"
full.cell(3, 4).value = 100
for row, label in enumerate([
    "MHC-A Haplotype 1", "MHC-A Haplotype 2",
    "MHC-B Haplotype 1", "MHC-B Haplotype 2",
    "MHC-DRB Haplotype 1", "MHC-DRB Haplotype 2",
    "MHC-DQA Haplotype 1", "MHC-DQA Haplotype 2",
    "MHC-DQB Haplotype 1", "MHC-DQB Haplotype 2",
    "MHC-DPA Haplotype 1", "MHC-DPA Haplotype 2",
    "MHC-DPB Haplotype 1", "MHC-DPB Haplotype 2",
    "Comments",
], start=4):
    full.cell(row, 1).value = label
    full.cell(row, 4).value = "" if "DRB" in label else "old"

# Legacy start-only managed block followed by analyst-authored content. Updates
# must migrate only the generated rows and preserve everything after them.
full.append(["LGE MHC Candidate Alleles"])
full.append(["Provisional Name", "Stable Cluster ID", "Locus", "Classification", "Support Class", "sample-a"])
full.append(["Mafa-A1*001:01_1nt_nov", "legacy-cluster", "Mafa-A1", "novel", "singleton", 3])
full.append(["Analyst_A1_1nt_nov", "analyst-candidate-shaped", "Mafa-A1", "novel", "singleton", "=1+1"])
full.append(["Analyst Calculation", None, None, "=SUM(D1:D3)"])
full.cell(full.max_row, 1).fill = PatternFill(fill_type="solid", fgColor="FF123456")

legacy_headers = [
    "unmatched_sequence_id", "match_source", "closest_match_id", "closest_reference", "closest_reference_name",
    "match_class", "nucleotides_different", "snp_differences", "indel_bases", "aligned_bases", "score",
    "percent_identity", "query_coverage", "evalue", "bitscore",
]
stale = ["legacy", "legacy-blast", "Mafa-A1*018:01:01:01_0SNP", "stale-ref", "stale-ref-name", "exact", 99, 99, 99, 99, 99, 12.5, 9.5, "1e-20", 777]
for name in ["Unmatched Clusters", "Unmatched Shared Pivot", "MHC-like Unmatched Clusters", "MHC-like Unmatched Pivot"]:
    legacy = wb.create_sheet(name)
    legacy.append(legacy_headers)
    candidate_row = list(stale)
    candidate_row[0] = "cluster-1"
    legacy.append(candidate_row)
    unnameable_row = list(stale)
    unnameable_row[0] = "cluster-u"
    legacy.append(unnameable_row)

custom = wb.create_sheet("Custom Sort")
custom.append(headers)
custom.append(["MHC heterozygous  MCM animals"] + [None for _ in headers[1:]])
custom.append(["DW472", "DW472", 100, "M4", "M7", None, "M4A", "M4B", None, "M4DQ", "M4DP", None, "M7A", "M7B", None, "M7DQ", "M7DP", None])
wb.save(path)
"""#
        _ = try runPython(["-c", code, url.path])
    }

    private func inspectMCMWorkbook(_ url: URL) throws -> [String: String] {
        let code = #"""
import json
import sys
from openpyxl import load_workbook

wb = load_workbook(sys.argv[1], data_only=False)

def header_map(ws):
    values = {}
    for col in range(1, ws.max_column + 1):
        value = ws.cell(1, col).value
        if value:
            values[str(value)] = col
    return values

def sample_row(ws, sample):
    for row in range(1, ws.max_row + 1):
        if ws.cell(row, 1).value == sample:
            return row
    return None

def sample_col(ws, sample):
    for col in range(1, ws.max_column + 1):
        for row in range(1, min(ws.max_row, 4) + 1):
            if ws.cell(row, col).value == sample:
                return col
    return None

def row_for(ws, label):
    for row in range(1, ws.max_row + 1):
        if ws.cell(row, 1).value == label:
            return row
    return None

def guide_value(label):
    guide = wb["Interpretation Guide"]
    row = row_for(guide, label)
    return None if row is None else guide.cell(row, 2).value

abbr = wb["Abbreviated Haplotypes"]
custom = wb["Custom Sort"]
full = wb["Full Sequencing Results 1"]
abbr_headers = header_map(abbr)
custom_headers = header_map(custom)
abbr_row = sample_row(abbr, "DW472")
custom_row = sample_row(custom, "DW472")
full_col = sample_col(full, "DW472")

def text(value):
    return "" if value is None else str(value)

def row_values(sheet, row_index, col_count):
    if sheet not in wb.sheetnames or wb[sheet].max_row < row_index:
        return ""
    ws = wb[sheet]
    return "|".join(text(ws.cell(row_index, col).value) for col in range(1, col_count + 1))

payload = {
    "hasOverridesSheet": str("Overrides" in wb.sheetnames).lower(),
    "hasAuditLogSheet": str("Audit Log" in wb.sheetnames).lower(),
    "abbreviatedDPHaplotype1": text(abbr.cell(abbr_row, abbr_headers["MHC-DPA/B Haplotype 1"]).value),
    "abbreviatedDPHaplotype2": text(abbr.cell(abbr_row, abbr_headers["MHC-DPA/B Haplotype 2"]).value),
    "abbreviatedDRBHaplotype1": text(abbr.cell(abbr_row, abbr_headers["MHC-DRB Haplotype 1"]).value),
    "abbreviatedDRBHaplotype2": text(abbr.cell(abbr_row, abbr_headers["MHC-DRB Haplotype 2"]).value),
    "abbreviatedComments": text(abbr.cell(abbr_row, abbr_headers["Comments"]).value),
    "customDPHaplotype1": text(custom.cell(custom_row, custom_headers["MHC-DPA/B Haplotype 1"]).value),
    "fullDPAHaplotype1": text(full.cell(row_for(full, "MHC-DPA Haplotype 1"), full_col).value),
    "fullDPBHaplotype2": text(full.cell(row_for(full, "MHC-DPB Haplotype 2"), full_col).value),
    "fullDRBHaplotype1": text(full.cell(row_for(full, "MHC-DRB Haplotype 1"), full_col).value),
    "fullDRBHaplotype2": text(full.cell(row_for(full, "MHC-DRB Haplotype 2"), full_col).value),
    "fullComments": text(full.cell(row_for(full, "Comments"), full_col).value),
    "guideWorkbookUpdateSource": guide_value("Workbook update source"),
    "guideUpdatedHaplotypeCalls": text(guide_value("Workbook updated haplotype calls")),
    "guideAuditEntries": text(guide_value("Workbook update audit entries")),
    "firstOverrideRow": row_values("Overrides", 2, 9),
    "firstAuditRow": row_values("Audit Log", 2, 10),
}

legacy_fields = [
    "match_source", "closest_match_id", "closest_reference", "closest_reference_name", "match_class",
    "nucleotides_different", "snp_differences", "indel_bases", "aligned_bases", "score",
    "percent_identity", "query_coverage", "evalue", "bitscore",
]
candidate_legacy = []
unnameable_legacy = []
for name in ["Unmatched Clusters", "Unmatched Shared Pivot", "MHC-like Unmatched Clusters", "MHC-like Unmatched Pivot"]:
    if name not in wb.sheetnames:
        continue
    ws = wb[name]
    headers = [text(cell.value) for cell in ws[1]]
    candidate_legacy.append("|".join(text(ws.cell(2, headers.index(field) + 1).value) for field in legacy_fields))
    unnameable_legacy.append("|".join(text(ws.cell(3, headers.index(field) + 1).value) for field in legacy_fields))
payload["legacyCandidateRows"] = "||".join(candidate_legacy)
payload["legacyUnnameableRows"] = "||".join(unnameable_legacy)
print(json.dumps(payload))
"""#
        let output = try runPython(["-c", code, url.path])
        let data = Data(output.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: String])
    }

    private func inspectSemanticReviewWorkbook(_ url: URL) throws -> [String: String] {
        let code = #"""
import json
import sys
from openpyxl import load_workbook

wb = load_workbook(sys.argv[1], data_only=False)
ws = wb["matrix"]

def text(value):
    return "" if value is None else str(value)

def color_suffix(color):
    value = getattr(color, "rgb", None)
    return "" if not value else str(value)[-6:]

def borders(cell):
    return "|".join(text(getattr(getattr(cell.border, side), "style", None)) for side in ("left", "right", "top", "bottom"))

def table_rows(name):
    if name not in wb.sheetnames:
        return []
    sheet = wb[name]
    return [[text(sheet.cell(row, col).value) for col in range(1, sheet.max_column + 1)] for row in range(2, sheet.max_row + 1)]

annotations = table_rows("Matrix Annotations")
audits = table_rows("Audit Log")
valid_review = next(("|".join(row) for row in annotations if "cluster-a" in row and "falsePositive" in row), "")
invalid_review = next((
    "|".join(row) for row in annotations
    if "falseNegative" in row and "invalid" in row
), "")
invalid_audit = next(("|".join(row) for row in audits if "cluster-c" in row and "invalid" in row), "")
comment_identity = next(("|".join(row) for row in annotations if row and row[0] == "comment" and "cluster-a" in row), "")
resolved_cell_comments = sum(1 for row in annotations if row and row[0] == "comment" and "cluster-a" in row and "Sample-FP" in row)
def has_duplicate_review_conflict(row):
    return any(
        "Conflicting duplicate review records" in value
        for value in row
    )

payload = {
    "falsePositiveValue": text(ws["D7"].value),
    "falsePositiveItalic": str(bool(ws["D7"].font.italic)).lower(),
    "falsePositiveBold": str(bool(ws["D7"].font.bold)).lower(),
    "falsePositiveColor": color_suffix(ws["D7"].font.color),
    "falsePositiveBorders": borders(ws["D7"]),
    "explicitZeroValue": text(ws["E7"].value),
    "explicitZeroType": text(ws["E7"].data_type),
    "explicitZeroBorders": borders(ws["E7"]),
    "absentValue": text(ws["F7"].value),
    "absentType": text(ws["F7"].data_type),
    "absentBorders": borders(ws["F7"]),
    "otherLocusValue": text(ws["D8"].value),
    "otherStableIDValue": text(ws["D9"].value),
    "invalidReviewValue": text(ws["D9"].value),
    "invalidReviewBorders": borders(ws["D9"]),
    "rowComment": "" if ws["A7"].comment is None else ws["A7"].comment.text,
    "columnComment": "" if ws["D1"].comment is None else ws["D1"].comment.text,
    "cellComment": "" if ws["D7"].comment is None else ws["D7"].comment.text,
    "validReviewRow": valid_review,
    "invalidReviewRow": invalid_review,
    "invalidAuditRow": invalid_audit,
    "commentIdentityRow": comment_identity,
    "resolvedCellCommentRows": str(resolved_cell_comments),
    "conflictingReviewRows": str(sum(
        1 for row in annotations
        if "cluster-a" in row and "invalid" in row
        and has_duplicate_review_conflict(row)
    )),
    "conflictingAuditRows": str(sum(
        1 for row in audits
        if "cluster-a" in row and "invalid" in row
        and has_duplicate_review_conflict(row)
    )),
    "conflictingReviewReasons": "||".join(
        "|".join(row) for row in annotations
        if "cluster-a" in row and "invalid" in row
        and has_duplicate_review_conflict(row)
    ),
    "hasMatrixAnnotationsSheet": str("Matrix Annotations" in wb.sheetnames).lower(),
    "hasManagedReviewStateSheet": str("_LGE Matrix Review State" in wb.sheetnames).lower(),
}
print(json.dumps(payload))
"""#
        let output = try runPython(["-c", code, url.path])
        let object = try JSONSerialization.jsonObject(with: Data(output.utf8))
        return try XCTUnwrap(object as? [String: String])
    }

    private func inspectGenericMatrixWorkbook(_ url: URL) throws -> [String: String] {
        let code = #"""
import json
import sys
from openpyxl import load_workbook

wb = load_workbook(sys.argv[1], data_only=False)
ws = wb["matrix"]
cell = ws["D7"]

def text(value):
    return "" if value is None else str(value)

def color_suffix(color):
    value = getattr(color, "rgb", None)
    if not value:
        return ""
    return str(value)[-6:]

def row_values(sheet, row_index, col_count):
    if sheet not in wb.sheetnames or wb[sheet].max_row < row_index:
        return ""
    ws = wb[sheet]
    return "|".join(text(ws.cell(row_index, col).value) for col in range(1, col_count + 1))

def row_for(ws, label):
    for row in range(1, ws.max_row + 1):
        if ws.cell(row, 1).value == label:
            return row
    return None

def guide_value(label):
    guide = wb["Interpretation Guide"]
    row = row_for(guide, label)
    return "" if row is None else text(guide.cell(row, 2).value)

payload = {
    "hasMatrixAnnotationsSheet": str("Matrix Annotations" in wb.sheetnames).lower(),
    "matrixAnnotationStyleRow": row_values("Matrix Annotations", 2, 17),
    "matrixAnnotationCommentRow": row_values("Matrix Annotations", 3, 17),
    "cellFillSuffix": color_suffix(cell.fill.fgColor),
    "cellTextColorSuffix": color_suffix(cell.font.color),
    "cellBorderSuffix": color_suffix(cell.border.left.color),
    "cellBold": str(bool(cell.font.bold)).lower(),
    "cellItalic": str(bool(cell.font.italic)).lower(),
    "cellComment": "" if cell.comment is None else cell.comment.text,
    "guideMatrixStyles": guide_value("Workbook update matrix styles"),
    "guideMatrixComments": guide_value("Workbook update matrix comments"),
}
print(json.dumps(payload))
"""#
        let output = try runPython(["-c", code, url.path])
        let data = Data(output.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: String])
    }

    private enum RetainedCandidateArtifactCategory: Equatable {
        case candidate
        case unnameable
    }

    private func retainCandidateArtifactCategory(
        _ category: RetainedCandidateArtifactCategory,
        in bundleURL: URL
    ) throws {
        let manifest = try ONTGenotypeResultBundle.loadManifest(from: bundleURL)
        let artifacts = try XCTUnwrap(manifest.mhcCandidateArtifacts)
        let revisedArtifacts = ONTMHCCandidateArtifactManifest(
            schemaVersion: artifacts.schemaVersion,
            genotypingEvidence: artifacts.genotypingEvidence,
            reciprocalEvidence: artifacts.reciprocalEvidence,
            candidateJSON: category == .candidate ? artifacts.candidateJSON : nil,
            candidateFASTA: category == .candidate ? artifacts.candidateFASTA : nil,
            candidateGenBank: category == .candidate ? artifacts.candidateGenBank : nil,
            unnameableJSON: category == .unnameable ? artifacts.unnameableJSON : nil,
            unnameableFASTA: category == .unnameable ? artifacts.unnameableFASTA : nil,
            unnameableGenBank: category == .unnameable ? artifacts.unnameableGenBank : nil
        )
        let revisedManifest = ONTGenotypeResultBundleManifest(
            schemaVersion: manifest.schemaVersion,
            kind: manifest.kind,
            outputName: manifest.outputName,
            analysisName: manifest.analysisName,
            primaryWorkbookPath: manifest.primaryWorkbookPath,
            currentWorkbookPath: manifest.currentWorkbookPath,
            workbookRevisions: manifest.workbookRevisions,
            longSummaryCSVPath: manifest.longSummaryCSVPath,
            sampleSummaryCSVPath: manifest.sampleSummaryCSVPath,
            statsJSONPath: manifest.statsJSONPath,
            provenancePath: manifest.provenancePath,
            mhcCandidateArtifacts: revisedArtifacts,
            mhcReferenceVisualizations: manifest.mhcReferenceVisualizations,
            referenceRecordStore: manifest.referenceRecordStore
        )
        try ONTGenotypeResultBundle.writeManifest(revisedManifest, to: bundleURL)
    }

    private func installMinimalUnifiedPivot(in bundleURL: URL) throws {
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: bundleURL)
        _ = try runPython(["-c", #"""
import sys
from openpyxl import load_workbook
path = sys.argv[1]
wb = load_workbook(path)
ws = wb.create_sheet("Unified Genotype Pivot")
ws.append([
    "call_type", "call_id", "display_name", "stable_cluster_id", "locus", "classification",
    "support_class", "closest_reference", "match_class", "occurrence_count", "sample_count",
    "total_cluster_reads", "sample-a", "sample-b",
])
wb.save(path)
"""#, currentURL.path])
    }

    private func installCandidateArtifacts(
        in bundleURL: URL,
        schemaVersion: Int = 1,
        artifactManifestSchemaVersion: Int = 1
    ) throws {
        let directory = bundleURL.appendingPathComponent("artifacts/mhc-candidates", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let candidateFASTAURL = directory.appendingPathComponent("candidate-alleles.fasta")
        let unnameableFASTAURL = directory.appendingPathComponent("unnameable-clusters.fasta")
        let bases = Array("ACGT")
        let candidateSequences = Dictionary(uniqueKeysWithValues: (1...4).map {
            ("cluster-\($0)", String(
                repeating: bases[$0 % 4],
                count: schemaVersion >= 4 ? 33 : 39
            ))
        })
        let unnameableRawStableID = schemaVersion >= 4 ? "raw-cluster-u" : "cluster-u"
        let unnameableCanonicalFASTAID = schemaVersion >= 4 ? "canonical-cluster-u" : "cluster-u"
        let unnameableSequence = String(repeating: "N", count: 40)
        try candidateSequences.keys.sorted().map { ">\($0)\n" + candidateSequences[$0]! }
            .joined(separator: "\n").appending("\n")
            .write(to: candidateFASTAURL, atomically: true, encoding: .utf8)
        try ">\(unnameableCanonicalFASTAID)\n".appending(unnameableSequence).appending("\n")
            .write(to: unnameableFASTAURL, atomically: true, encoding: .utf8)
        let candidateFASTA = try artifactReference(candidateFASTAURL, relativeTo: bundleURL)
        let unnameableFASTA = try artifactReference(unnameableFASTAURL, relativeTo: bundleURL)
        let candidateGenBankURL = directory.appendingPathComponent("candidate-alleles.gb")
        let unnameableGenBankURL = directory.appendingPathComponent("unnameable-clusters.gb")
        try GenBankWriter(url: candidateGenBankURL).write(
            try candidateSequences.keys.sorted().map { stableID in
                let fullSequence = candidateSequences[stableID]!
                let isCroppedFixture = schemaVersion < 4 && stableID == "cluster-1"
                return try normalizedCandidateGenBankRecord(
                    stableID: stableID,
                    sequence: isCroppedFixture
                        ? String(fullSequence.dropFirst(3).dropLast(3))
                        : fullSequence,
                    translation: String(repeating: "A", count: isCroppedFixture ? 11 : 13),
                    status: "full-length",
                    fullSequence: isCroppedFixture ? fullSequence : nil,
                    trimStart: isCroppedFixture ? 4 : nil,
                    trimEnd: isCroppedFixture ? 36 : nil
                )
            }
        )
        try GenBankWriter(url: unnameableGenBankURL).write([
            try normalizedCandidateGenBankRecord(
                stableID: unnameableCanonicalFASTAID,
                sourceStableID: unnameableRawStableID,
                sequence: unnameableSequence,
                translation: nil,
                status: "incomplete/unresolved"
            ),
        ])
        let candidateGenBank = try artifactReference(candidateGenBankURL, relativeTo: bundleURL)
        let unnameableGenBank = try artifactReference(unnameableGenBankURL, relativeTo: bundleURL)
        let selected = ONTMHCEvidenceLocator(
            bamPath: "artifacts/alignments/unmatched-to-reference.bam",
            queryName: "candidate-query",
            referenceName: "reference-allele",
            readGroupID: nil,
            referenceStart: 10,
            cigar: "1000M"
        )
        let specs: [(String, String, ONTMHCCandidateClassification, ONTMHCCandidateSupportClass, Int)] = [
            ("cluster-1", "Mafa-A1*018:01:01:01_5nt_nov", .novel, .shared, 5),
            ("cluster-2", "Mafa-A1*018:01:01:01_5nt_nov", .novel, .singleton, 5),
            ("cluster-3", "Mafa-B*001:01_ext", .extension, .shared, 0),
            ("cluster-4", "Mafa-B*002:01_ext", .extension, .singleton, 0),
        ]
        let candidates = try specs.map { id, name, classification, support, snps in
            let selectedEvidence = ONTMHCEvidenceLocator(
                bamPath: selected.bamPath,
                queryName: id,
                referenceName: selected.referenceName,
                readGroupID: nil,
                referenceStart: selected.referenceStart,
                cigar: selected.cigar
            )
            let reciprocalSummary = try ONTMHCReciprocalQueryHitSummary(
                bamPath: selected.bamPath,
                queryName: id,
                alignmentCount: 3,
                targetAlignmentCounts: [selected.referenceName: 3],
                exactMatchTargetNames: [],
                closestMatchTargetNames: [selected.referenceName]
            )
            return ONTMHCCandidateRecord(
                stableClusterID: id,
                provisionalName: name,
                locus: name.hasPrefix("Mafa-A") ? "Mafa-A1" : "Mafa-B",
                classification: classification,
                supportClass: support,
                closestReferenceName: classification == .novel ? "Mafa-A1*018:01:01:01" : String(name.dropLast(4)),
                closestReferenceClass: classification == .novel ? .genomicDNA : .cDNA,
                snpCount: snps,
                insertedBases: 0,
                deletedBases: classification == .extension ? 200 : 0,
                longGapBases: classification == .extension ? 200 : 0,
                comparableBases: 1_000,
                shorterCoverage: 1,
                identity: 1,
                mappingQuality: 60,
                alignmentScore: 1_000,
                independentSampleCount: support == .shared ? 2 : 1,
                occurrenceCount: support == .shared ? 2 : 1,
                totalClusterReads: id == "cluster-1" ? 10 : (support == .shared ? 6 : 4),
                supportingSampleIDs: support == .shared ? ["sample-a", "sample-b"] : ["sample-a"],
                fastaRecordID: id,
                sequenceSHA256: sha256Hex(candidateSequences[id]!),
                reciprocalHitSummary: reciprocalSummary,
                selectedEvidence: selectedEvidence
            )
        }
        var observations: [ONTMHCCandidateObservation] = []
        for candidate in candidates {
            observations.append(candidateObservation(candidate.stableClusterID, sample: "sample-a", reads: candidate.stableClusterID == "cluster-1" ? 7 : 4, schemaVersion: schemaVersion))
            if candidate.supportClass == .shared {
                observations.append(candidateObservation(candidate.stableClusterID, sample: "sample-b", reads: candidate.stableClusterID == "cluster-1" ? 3 : 2, schemaVersion: schemaVersion))
            }
        }
        let candidateDocument = ONTMHCCandidateAllelesDocument(
            schemaVersion: schemaVersion,
            createdAt: "2026-07-20T00:00:00Z",
            thresholds: .defaults,
            inputs: [],
            evidence: [],
            sequenceFASTA: candidateFASTA,
            candidates: candidates.reversed(),
            observations: observations.reversed()
        )
        let unnameable: ONTMHCUnnameableRecord
        if schemaVersion >= 2 {
            unnameable = ONTMHCUnnameableRecord(
                stableClusterID: unnameableRawStableID,
                reason: .unresolvedLocus,
                failedMetrics: ["identity": 0.7],
                supportClass: .singleton,
                independentSampleCount: 1,
                occurrenceCount: 1,
                totalClusterReads: 4,
                supportingSampleIDs: ["sample-a"],
                fastaRecordID: unnameableCanonicalFASTAID,
                sequenceSHA256: sha256Hex(unnameableSequence),
                reciprocalHitSummary: try ONTMHCReciprocalQueryHitSummary(
                    bamPath: "artifacts/alignments/reciprocal.bam",
                    queryName: unnameableRawStableID,
                    alignmentCount: 3,
                    targetAlignmentCounts: ["ref-b": 1, "ref-a": 2],
                    exactMatchTargetNames: ["ref-a"],
                    closestMatchTargetNames: ["ref-a", "ref-b"]
                ),
                selectedEvidence: .init(
                    bamPath: "artifacts/alignments/reciprocal.bam",
                    queryName: unnameableRawStableID,
                    referenceName: "ref-a",
                    readGroupID: "sample-a",
                    referenceStart: 10,
                    cigar: "800M"
                )
            )
        } else {
            unnameable = ONTMHCUnnameableRecord(
                stableClusterID: "cluster-u",
                reason: .unresolvedLocus,
                failedMetrics: ["identity": 0.7],
                supportClass: .singleton,
                independentSampleCount: 1,
                occurrenceCount: 1,
                totalClusterReads: 4,
                supportingSampleIDs: ["sample-a"],
                fastaRecordID: "cluster-u",
                sequenceSHA256: sha256Hex(unnameableSequence),
                evidence: [
                    .init(bamPath: "artifacts/alignments/z.bam", queryName: "cluster-u-z", referenceName: "ref-z", readGroupID: "sample-z", referenceStart: 90, cigar: "900M"),
                    .init(bamPath: "artifacts/alignments/a.bam", queryName: "cluster-u-a", referenceName: "ref-a", readGroupID: "sample-a", referenceStart: 10, cigar: "800M"),
                ]
            )
        }
        let unnameableDocument = ONTMHCUnnameableClustersDocument(
            schemaVersion: schemaVersion,
            createdAt: "2026-07-20T00:00:00Z",
            thresholds: .defaults,
            sequenceFASTA: unnameableFASTA,
            clusters: [unnameable],
            observations: [
                candidateObservation(
                    unnameableRawStableID,
                    sample: "sample-a",
                    reads: 4,
                    schemaVersion: schemaVersion
                ),
            ]
        )
        let candidateJSONURL = directory.appendingPathComponent("candidate-alleles.json")
        let unnameableJSONURL = directory.appendingPathComponent("unnameable-clusters.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(candidateDocument).write(to: candidateJSONURL, options: .atomic)
        try encoder.encode(unnameableDocument).write(to: unnameableJSONURL, options: .atomic)
        let rawUnmatchedFASTA: ONTMHCArtifactReference?
        let sourceIdentityMap: ONTMHCArtifactReference?
        if artifactManifestSchemaVersion >= 2 {
            let rawUnmatchedFASTAURL = directory.appendingPathComponent("raw-unmatched.fasta")
            try ">raw-cluster\nACGT\n".write(
                to: rawUnmatchedFASTAURL,
                atomically: true,
                encoding: .utf8
            )
            let sourceIdentityMapURL = directory.appendingPathComponent("source-identity.json")
            try Data(#"{"schema_version":1,"records":[]}"#.utf8).write(
                to: sourceIdentityMapURL,
                options: .atomic
            )
            rawUnmatchedFASTA = try artifactReference(
                rawUnmatchedFASTAURL,
                relativeTo: bundleURL
            )
            sourceIdentityMap = try artifactReference(
                sourceIdentityMapURL,
                relativeTo: bundleURL
            )
        } else {
            rawUnmatchedFASTA = nil
            sourceIdentityMap = nil
        }
        let artifacts = ONTMHCCandidateArtifactManifest(
            schemaVersion: artifactManifestSchemaVersion,
            genotypingEvidence: nil,
            reciprocalEvidence: nil,
            candidateJSON: try artifactReference(candidateJSONURL, relativeTo: bundleURL),
            candidateFASTA: candidateFASTA,
            candidateGenBank: candidateGenBank,
            unnameableJSON: try artifactReference(unnameableJSONURL, relativeTo: bundleURL),
            unnameableFASTA: unnameableFASTA,
            unnameableGenBank: unnameableGenBank,
            rawUnmatchedFASTA: rawUnmatchedFASTA,
            sourceIdentityMap: sourceIdentityMap
        )
        let referenceDirectory = bundleURL.appendingPathComponent("artifacts/mhc-reference", isDirectory: true)
        try FileManager.default.createDirectory(at: referenceDirectory, withIntermediateDirectories: true)
        let referenceSequence = "ATGGCTTAA"
        let referenceRecord = ONTMHCReferenceVisualizationRecord(
            rawReferenceID: "NHP00001",
            sourceOrdinal: 0,
            alleleName: "Mafa-A1*001:01:01:01",
            locus: "Mafa-A1",
            sequence: referenceSequence,
            sequenceSHA256: sha256Hex(referenceSequence),
            recordFields: ["feature.allele": ["Mafa-A1*001:01:01:01"]],
            features: [],
            annotatedTranslation: "MA",
            genBankText: "LOCUS NHP00001",
            fastaText: ">NHP00001\n\(referenceSequence)\n",
            roles: [.init(role: .exactKnownCall, candidateStableClusterIDs: [])]
        )
        let referenceJSONURL = referenceDirectory.appendingPathComponent("records.json")
        try JSONEncoder().encode(
            ONTMHCReferenceVisualizationArtifact(schemaVersion: 1, records: [referenceRecord])
        ).write(to: referenceJSONURL, options: .atomic)
        let referenceGenBankURL = referenceDirectory.appendingPathComponent("records.gb")
        try Data("LOCUS NHP00001\n//\n".utf8).write(to: referenceGenBankURL)
        let referenceFASTAURL = referenceDirectory.appendingPathComponent("records.fasta")
        try Data(referenceRecord.fastaText.utf8).write(to: referenceFASTAURL)
        let referenceVisualizations = ONTMHCReferenceVisualizationArtifacts(
            schemaVersion: 1,
            recordCount: 1,
            recordsJSON: try artifactReference(referenceJSONURL, relativeTo: bundleURL),
            genBank: try artifactReference(referenceGenBankURL, relativeTo: bundleURL),
            fasta: try artifactReference(referenceFASTAURL, relativeTo: bundleURL)
        )
        let manifest = try ONTGenotypeResultBundle.loadManifest(from: bundleURL)
        try """
        sample,genotype,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_reads,overall_unique_retained_percent
        sample-a,NHP00001,101,101,1000,101,10.1,3000,303,10.1
        sample-b,NHP00001,202,202,2000,202,10.1,3000,303,10.1
        """.write(
            to: ONTGenotypeResultBundle.resolvedURL(for: manifest.longSummaryCSVPath, in: bundleURL),
            atomically: true,
            encoding: .utf8
        )
        try """
        sample,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_reads,sample_unique_retained_percent
        sample-a,101,101,1000,101,10.1
        sample-b,202,202,2000,202,10.1
        """.write(
            to: ONTGenotypeResultBundle.resolvedURL(for: manifest.sampleSummaryCSVPath, in: bundleURL),
            atomically: true,
            encoding: .utf8
        )
        let updated = ONTGenotypeResultBundleManifest(
            schemaVersion: manifest.schemaVersion,
            kind: manifest.kind,
            outputName: manifest.outputName,
            analysisName: manifest.analysisName,
            primaryWorkbookPath: manifest.primaryWorkbookPath,
            currentWorkbookPath: manifest.currentWorkbookPath,
            workbookRevisions: manifest.workbookRevisions,
            longSummaryCSVPath: manifest.longSummaryCSVPath,
            sampleSummaryCSVPath: manifest.sampleSummaryCSVPath,
            statsJSONPath: manifest.statsJSONPath,
            provenancePath: manifest.provenancePath,
            mhcCandidateArtifacts: artifacts,
            mhcReferenceVisualizations: referenceVisualizations,
            referenceRecordStore: manifest.referenceRecordStore
        )
        try ONTGenotypeResultBundle.writeManifest(updated, to: bundleURL)
    }

    private func artifactReference(_ url: URL, relativeTo bundleURL: URL) throws -> ONTMHCArtifactReference {
        ONTMHCArtifactReference(
            path: String(url.standardizedFileURL.path.dropFirst(bundleURL.standardizedFileURL.path.count + 1)),
            sha256: try ProvenanceFileHasher.sha256(of: url),
            sizeBytes: Int64(try ProvenanceFileHasher.fileSize(of: url))
        )
    }

    private func normalizedCandidateGenBankRecord(
        stableID: String,
        sourceStableID: String? = nil,
        sequence: String,
        translation: String?,
        status: String,
        fullSequence: String? = nil,
        trimStart: Int? = nil,
        trimEnd: Int? = nil
    ) throws -> GenBankRecord {
        var sourceQualifiers: [String: AnnotationQualifier] = [
            "stable_cluster_id": .init(sourceStableID ?? stableID),
            "sequence_sha256": .init(sha256Hex(fullSequence ?? sequence)),
            "translation_status": .init(status),
        ]
        if let fullSequence, let trimStart, let trimEnd {
            sourceQualifiers["original_sequence_length"] = .init(String(fullSequence.count))
            sourceQualifiers["trim_start"] = .init(String(trimStart))
            sourceQualifiers["trim_end"] = .init(String(trimEnd))
            sourceQualifiers["genbank_sequence_sha256"] = .init(sha256Hex(sequence))
            sourceQualifiers["trim_status"] = .init("trimmed-to-outer-lifted-CDS")
            sourceQualifiers["reference_readiness_status"] = .init("reference-ready")
        }
        var annotations = [
            SequenceAnnotation(
                type: .source,
                name: stableID,
                start: 0,
                end: sequence.count,
                strand: .forward,
                qualifiers: sourceQualifiers
            ),
        ]
        if let translation {
            annotations.append(SequenceAnnotation(
                type: .cds,
                name: stableID,
                start: 0,
                end: sequence.count,
                strand: .forward,
                qualifiers: ["translation": .init(translation)]
            ))
        }
        return GenBankRecord(
            sequence: try Sequence(name: stableID, alphabet: .dna, bases: sequence),
            annotations: annotations,
            locus: .init(name: stableID, length: sequence.count, moleculeType: .dna, topology: .linear),
            accession: stableID
        )
    }

    private func sha256Hex(_ sequence: String) -> String {
        SHA256.hash(data: Data(sequence.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func candidateObservation(
        _ cluster: String,
        sample: String,
        reads: Int,
        schemaVersion: Int = 1
    ) -> ONTMHCCandidateObservation {
        if schemaVersion == 2 {
            return ONTMHCCandidateObservation(
                stableClusterID: cluster,
                sampleID: sample,
                readGroupID: sample,
                sourceClusterIDs: ["source-\(cluster)-\(sample)"],
                sourceClusterReadCounts: ["source-\(cluster)-\(sample)": reads],
                aggregatedSampleReadCount: reads,
                genotypingHitSummaries: []
            )
        }
        return ONTMHCCandidateObservation(
            stableClusterID: cluster,
            sampleID: sample,
            readGroupID: sample,
            sourceClusterIDs: ["source-\(cluster)-\(sample)"],
            sourceClusterReadCounts: ["source-\(cluster)-\(sample)": reads],
            aggregatedSampleReadCount: reads,
            evidence: []
        )
    }

    private func inspectCandidateWorkbook(_ url: URL) throws -> [String: String] {
        let code = #"""
import json
import sys
from openpyxl import load_workbook

wb = load_workbook(sys.argv[1], data_only=False)

def text(value):
    return "" if value is None else str(value)

def argb(cell):
    value = getattr(cell.fill.fgColor, "rgb", None)
    return text(value) or "00000000"

candidate = wb["Candidate Alleles"]
unnameable = wb["Un-nameable Clusters"]
candidate_headers = {text(cell.value): cell.column for cell in candidate[1] if text(cell.value)}
unnameable_headers = {text(cell.value): cell.column for cell in unnameable[1] if text(cell.value)}
candidate_ids = [text(candidate.cell(row, 1).value) for row in range(2, candidate.max_row + 1)]
candidate_names = [text(candidate.cell(row, 2).value) for row in range(2, candidate.max_row + 1)]
unnameable_query_col = unnameable_headers.get("Selected Evidence Query Name") or unnameable_headers.get("Evidence Query Name")
payload = {
    "candidateIDs": "|".join(candidate_ids),
    "candidateNames": "|".join(candidate_names),
    "candidateNameFills": "|".join(argb(candidate.cell(row, 2)) for row in range(2, candidate.max_row + 1)),
    "candidateIDFills": "|".join(argb(candidate.cell(row, 1)) for row in range(2, candidate.max_row + 1)),
    "unnameableIDs": "|".join(text(unnameable.cell(row, 1).value) for row in range(2, unnameable.max_row + 1)),
    "unnameableQueries": "|".join(text(unnameable.cell(row, unnameable_query_col).value) for row in range(2, unnameable.max_row + 1)) if unnameable_query_col else "",
    "unnameableReciprocalAlignmentCounts": "|".join(text(unnameable.cell(row, unnameable_headers["Reciprocal Alignment Count"]).value) for row in range(2, unnameable.max_row + 1)) if "Reciprocal Alignment Count" in unnameable_headers else "",
    "unnameableExactTargets": "|".join(text(unnameable.cell(row, unnameable_headers["Exact Match Target Names"]).value) for row in range(2, unnameable.max_row + 1)) if "Exact Match Target Names" in unnameable_headers else "",
    "allText": "|".join(text(cell.value) for ws in wb.worksheets for row in ws.iter_rows() for cell in row),
}
if "Full Sequencing Results 1" in wb.sheetnames:
    ws = wb["Full Sequencing Results 1"]
    begin_label = "LGE MHC Candidate Alleles [BEGIN]"
    end_label = "LGE MHC Candidate Alleles [END]"
    marker = next((row for row in range(1, ws.max_row + 1) if text(ws.cell(row, 1).value) == begin_label), None)
    end = next((row for row in range((marker or 0) + 1, ws.max_row + 1) if text(ws.cell(row, 1).value) == end_label), None)
    rows = list(range(marker + 2, end)) if marker and end else []
    payload["editableCandidateCount"] = str(len(rows))
    payload["editableNameFills"] = "|".join(argb(ws.cell(row, 1)) for row in rows)
    analyst = next((row for row in range(1, ws.max_row + 1) if text(ws.cell(row, 1).value) == "Analyst Calculation"), None)
    payload["analystFormula"] = text(ws.cell(analyst, 4).value) if analyst else ""
    payload["analystFill"] = argb(ws.cell(analyst, 1)) if analyst else ""
    analyst_candidate = next((row for row in range(1, ws.max_row + 1) if text(ws.cell(row, 2).value) == "analyst-candidate-shaped"), None)
    payload["candidateShapedAnalystFormula"] = text(ws.cell(analyst_candidate, 6).value) if analyst_candidate else ""
    payload["managedBeginCount"] = str(sum(1 for row in range(1, ws.max_row + 1) if text(ws.cell(row, 1).value) == begin_label))
    payload["managedEndCount"] = str(sum(1 for row in range(1, ws.max_row + 1) if text(ws.cell(row, 1).value) == end_label))
else:
    payload["editableCandidateCount"] = "0"
    payload["editableNameFills"] = ""
    payload["analystFormula"] = ""
    payload["analystFill"] = ""
    payload["candidateShapedAnalystFormula"] = ""
    payload["managedBeginCount"] = "0"
    payload["managedEndCount"] = "0"
if "Unified Genotype Pivot" in wb.sheetnames:
    ws = wb["Unified Genotype Pivot"]
    headers = {text(cell.value): cell.column for cell in ws[1] if text(cell.value)}
    call_type_col = headers.get("call_type", 1)
    stable_id_col = headers.get("stable_cluster_id", 4)
    rows = [row for row in range(2, ws.max_row + 1) if text(ws.cell(row, call_type_col).value).startswith("candidate-")]
    payload["unifiedCandidateCount"] = str(len(rows))
    payload["unifiedCandidateIDs"] = "|".join(text(ws.cell(row, stable_id_col).value) for row in rows)
    payload["unifiedSampleAReads"] = "|".join(text(ws.cell(row, headers["Sample Reads: sample-a"]).value) for row in rows) if "Sample Reads: sample-a" in headers else ""
    payload["unifiedSampleBReads"] = "|".join(text(ws.cell(row, headers["Sample Reads: sample-b"]).value) for row in rows) if "Sample Reads: sample-b" in headers else ""
else:
    payload["unifiedCandidateCount"] = "0"
    payload["unifiedCandidateIDs"] = ""
    payload["unifiedSampleAReads"] = ""
    payload["unifiedSampleBReads"] = ""
legacy_fields = [
    "match_source", "closest_match_id", "closest_reference", "closest_reference_name", "match_class",
    "nucleotides_different", "snp_differences", "indel_bases", "aligned_bases", "score",
    "percent_identity", "query_coverage", "evalue", "bitscore",
]
candidate_legacy = []
unnameable_legacy = []
for name in ["Unmatched Clusters", "Unmatched Shared Pivot", "MHC-like Unmatched Clusters", "MHC-like Unmatched Pivot"]:
    if name not in wb.sheetnames:
        continue
    ws = wb[name]
    headers = [text(cell.value) for cell in ws[1]]
    candidate_legacy.append("|".join(text(ws.cell(2, headers.index(field) + 1).value) for field in legacy_fields))
    unnameable_legacy.append("|".join(text(ws.cell(3, headers.index(field) + 1).value) for field in legacy_fields))
payload["legacyCandidateRows"] = "||".join(candidate_legacy)
payload["legacyUnnameableRows"] = "||".join(unnameable_legacy)
print(json.dumps(payload))
"""#
        let output = try runPython(["-c", code, url.path])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: String])
    }

    private func inspectTwoSheetCandidateWorkbook(_ url: URL) throws -> [String: String] {
        let code = #"""
import json
import sys
from openpyxl import load_workbook

wb = load_workbook(sys.argv[1], data_only=False)

def text(value):
    return "" if value is None else str(value)

unified = wb["Unified Genotype Pivot"]
def row_for_label(label):
    return next((row for row in range(1, unified.max_row + 1) if text(unified.cell(row, 1).value) == label), None)

sample_a_col = next((column for column in range(1, unified.max_column + 1) if text(unified.cell(1, column).value) == "sample-a"), None)
sample_b_col = next((column for column in range(1, unified.max_column + 1) if text(unified.cell(1, column).value) == "sample-b"), None)
table_header_row = next(
    row for row in range(1, unified.max_row + 1)
    if any(text(unified.cell(row, column).value) == "call_type" for column in range(1, unified.max_column + 1))
)
headers = {
    text(unified.cell(table_header_row, column).value): column
    for column in range(1, unified.max_column + 1)
    if text(unified.cell(table_header_row, column).value)
}
candidate_rows = [
    row for row in range(table_header_row + 1, unified.max_row + 1)
    if text(unified.cell(row, headers["call_type"]).value).startswith("candidate-")
]
def argb(cell):
    value = getattr(cell.fill.fgColor, "rgb", None)
    return text(value) or "00000000"
unmatched = wb["Unmatched Alleles"]
unmatched_headers = {
    text(cell.value): cell.column for cell in unmatched[1] if text(cell.value)
}
unmatched_rows = {
    text(unmatched.cell(row, unmatched_headers["Stable Cluster ID"]).value): row
    for row in range(2, unmatched.max_row + 1)
}
candidate_row = unmatched_rows.get("cluster-1")
unnameable_row = unmatched_rows.get("raw-cluster-u") or unmatched_rows.get("cluster-u")
payload = {
    "sheetNames": "|".join(wb.sheetnames),
    "tableHeaderRow": str(table_header_row),
    "analystHaplotype": text(unified.cell(row_for_label("MHC-A Haplotype 1"), sample_a_col).value) if row_for_label("MHC-A Haplotype 1") and sample_a_col else "",
    "analystComment": text(unified.cell(row_for_label("Comments"), sample_a_col).value) if row_for_label("Comments") and sample_a_col else "",
    "mappedTotal": text(unified.cell(row_for_label("Mapped Read Count"), 2).value) if row_for_label("Mapped Read Count") else "",
    "mappedAverage": text(unified.cell(row_for_label("Mapped Read Count"), 3).value) if row_for_label("Mapped Read Count") else "",
    "mappedTotalType": text(unified.cell(row_for_label("Mapped Read Count"), 2).data_type) if row_for_label("Mapped Read Count") else "",
    "mappedAverageType": text(unified.cell(row_for_label("Mapped Read Count"), 3).data_type) if row_for_label("Mapped Read Count") else "",
    "sampleAMappedType": text(unified.cell(row_for_label("Mapped Read Count"), sample_a_col).data_type) if row_for_label("Mapped Read Count") and sample_a_col else "",
    "sampleATotalReadType": text(unified.cell(row_for_label("total_read_count"), sample_a_col).data_type) if row_for_label("total_read_count") and sample_a_col else "",
    "sampleAUnmappedPercentType": text(unified.cell(row_for_label("percent_reads_unmapped"), sample_a_col).data_type) if row_for_label("percent_reads_unmapped") and sample_a_col else "",
    "sampleADQAHaplotype1": text(unified.cell(row_for_label("MHC-DQA Haplotype 1"), sample_a_col).value) if row_for_label("MHC-DQA Haplotype 1") and sample_a_col else "",
    "sampleADQBHaplotype1": text(unified.cell(row_for_label("MHC-DQB Haplotype 1"), sample_a_col).value) if row_for_label("MHC-DQB Haplotype 1") and sample_a_col else "",
    "sampleADPAHaplotype1": text(unified.cell(row_for_label("MHC-DPA Haplotype 1"), sample_a_col).value) if row_for_label("MHC-DPA Haplotype 1") and sample_a_col else "",
    "sampleADPBHaplotype1": text(unified.cell(row_for_label("MHC-DPB Haplotype 1"), sample_a_col).value) if row_for_label("MHC-DPB Haplotype 1") and sample_a_col else "",
    "sampleBDQAHaplotype1": text(unified.cell(row_for_label("MHC-DQA Haplotype 1"), sample_b_col).value) if row_for_label("MHC-DQA Haplotype 1") and sample_b_col else "",
    "sampleBDPBHaplotype1": text(unified.cell(row_for_label("MHC-DPB Haplotype 1"), sample_b_col).value) if row_for_label("MHC-DPB Haplotype 1") and sample_b_col else "",
    "knownDisplayName": text(unified.cell(table_header_row + 1, headers["display_name"]).value),
    "knownClosestReference": text(unified.cell(table_header_row + 1, headers["closest_reference"]).value),
    "knownSampleAReads": text(unified.cell(table_header_row + 1, headers["sample-a"]).value) if "sample-a" in headers else "",
    "knownSampleBReads": text(unified.cell(table_header_row + 1, headers["sample-b"]).value) if "sample-b" in headers else "",
    "knownTotalReads": text(unified.cell(table_header_row + 1, headers["total_cluster_reads"]).value),
    "candidateIDs": "|".join(text(unified.cell(row, headers["stable_cluster_id"]).value) for row in candidate_rows),
    "candidateNameFills": "|".join(argb(unified.cell(row, headers["display_name"])) for row in candidate_rows),
    "unmatchedIDs": "|".join(text(unmatched.cell(row, unmatched_headers["Stable Cluster ID"]).value) for row in range(2, unmatched.max_row + 1)),
    "candidateSequence": text(unmatched.cell(candidate_row, unmatched_headers["Nucleotide Sequence"]).value) if candidate_row else "",
    "legacySequenceColumns": str(
        "Full-Length FASTA Sequence" in unmatched_headers
        or "UTR-Trimmed FASTA Sequence" in unmatched_headers
    ).lower(),
    "candidateTranslation": text(unmatched.cell(candidate_row, unmatched_headers["Putative Amino Acid Translation"]).value) if candidate_row else "",
    "candidateTranslationStatus": text(unmatched.cell(candidate_row, unmatched_headers["Translation Status"]).value) if candidate_row else "",
    "unnameableSequence": text(unmatched.cell(unnameable_row, unmatched_headers["Nucleotide Sequence"]).value) if unnameable_row else "",
    "unnameableTranslationStatus": text(unmatched.cell(unnameable_row, unmatched_headers["Translation Status"]).value) if unnameable_row else "",
}
print(json.dumps(payload))
"""#
        let output = try runPython(["-c", code, url.path])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: String])
    }

    private func inspectBiologicallyOrderedTwoSheetWorkbook(_ url: URL) throws -> [String: String] {
        let code = #"""
import json
import sys
from openpyxl import load_workbook

wb = load_workbook(sys.argv[1], data_only=False)

def text(value):
    return "" if value is None else str(value)

unified = wb["Unified Genotype Pivot"]
table_header_row = next(
    row for row in range(1, unified.max_row + 1)
    if any(text(unified.cell(row, column).value) == "call_type" for column in range(1, unified.max_column + 1))
)
headers = {
    text(unified.cell(table_header_row, column).value): column
    for column in range(1, unified.max_column + 1)
    if text(unified.cell(table_header_row, column).value)
}
data_rows = range(table_header_row + 1, unified.max_row + 1)
sample_a_col = next(
    column for column in range(1, unified.max_column + 1)
    if text(unified.cell(1, column).value) == "sample-a"
)
def row_for_label(label):
    return next(row for row in range(1, unified.max_row + 1) if text(unified.cell(row, 1).value) == label)

unmatched = wb["Unmatched Alleles"]
unmatched_headers = {text(cell.value): cell.column for cell in unmatched[1] if text(cell.value)}
payload = {
    "sheetNames": "|".join(wb.sheetnames),
    "analystHaplotype": text(unified.cell(row_for_label("MHC-A Haplotype 1"), sample_a_col).value),
    "analystComment": text(unified.cell(row_for_label("Comments"), sample_a_col).value),
    "unifiedDisplayNames": "|".join(text(unified.cell(row, headers["display_name"]).value) for row in data_rows),
    "unmatchedNames": "|".join(
        text(unmatched.cell(row, unmatched_headers["Provisional Allele Name"]).value)
        for row in range(2, unmatched.max_row + 1)
    ),
    "unmatchedIDs": "|".join(
        text(unmatched.cell(row, unmatched_headers["Stable Cluster ID"]).value)
        for row in range(2, unmatched.max_row + 1)
    ),
}
print(json.dumps(payload))
"""#
        let output = try runPython(["-c", code, url.path])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: String])
    }

    private func pythonCanImportOpenpyxl() -> Bool {
        (try? runPython(["-c", "import openpyxl"])) != nil
    }

    private var testPythonExecutableURL: URL? {
        let bundled = URL(fileURLWithPath: "/Users/dho/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3")
        return FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : nil
    }

    private func runPython(_ arguments: [String]) throws -> String {
        let process = Process()
        if let testPythonExecutableURL {
            process.executableURL = testPythonExecutableURL
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3"] + arguments
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "GenotypeWorkbookRevisionServiceTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: err]
            )
        }
        return out
    }

    private static func runPythonStatic(
        _ arguments: [String],
        executableURL: URL?
    ) throws -> String {
        let process = Process()
        if let executableURL {
            process.executableURL = executableURL
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3"] + arguments
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "GenotypeWorkbookRevisionServiceTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: errorText]
            )
        }
        return output
    }

    private func directorySnapshot(_ directoryURL: URL) throws -> [String: Data] {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [:] }
        var snapshot: [String: Data] = [:]
        let rootCount = directoryURL.pathComponents.count
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: directoryURL, includingPropertiesForKeys: nil))
        while let url = enumerator.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                continue
            }
            snapshot[url.pathComponents.dropFirst(rootCount).joined(separator: "/")] = try Data(contentsOf: url)
        }
        return snapshot
    }

    private func chmodTreeReadOnly(_ root: URL) throws {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var directories = [root]
        while let url = enumerator.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                directories.append(url)
            } else {
                XCTAssertEqual(chmod(url.path, S_IRUSR), 0)
            }
        }
        for directory in directories.reversed() {
            XCTAssertEqual(chmod(directory.path, S_IRUSR | S_IXUSR), 0)
        }
    }

    private func chmodTreeWritable(_ root: URL) throws {
        _ = chmod(root.path, S_IRWXU)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        while let url = enumerator.nextObject() as? URL {
            _ = chmod(url.path, S_IRWXU)
        }
    }

    private func workbookData(_ label: String) -> Data {
        var data = Data([0x50, 0x4b, 0x03, 0x04])
        data.append(Data(label.utf8))
        return data
    }

    private func bundleSnapshot(_ bundleURL: URL) throws -> [String: String] {
        var snapshot: [String: String] = [:]
        let rootPath = bundleURL.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw NSError(domain: "GenotypeWorkbookRevisionServiceTests", code: 2)
        }
        while let url = enumerator.nextObject() as? URL {
            let path = url.standardizedFileURL.path
            let relative = String(path.dropFirst(rootPath.count + 1))
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                snapshot[relative] = "directory"
            case S_IFREG:
                snapshot[relative] = "file:\(info.st_size):\(try ProvenanceFileHasher.sha256(of: url))"
            case S_IFLNK:
                snapshot[relative] = "symlink:\(try FileManager.default.destinationOfSymbolicLink(atPath: url.path))"
            default:
                snapshot[relative] = "special:\(info.st_mode & S_IFMT)"
            }
        }
        return snapshot
    }

    private func interruptWorkbookPublicationAfterExchange(
        fixture: (bundleURL: URL, manifest: ONTGenotypeResultBundleManifest),
        root: URL
    ) throws -> URL {
        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "after-exchange-hard-stop" else { return }
                    throw NSError(domain: "SimulatedSIGKILL", code: 9)
                }
            ).applyHaplotypeOverrides([], annotationSidecarURL: nil, into: fixture.bundleURL)
        )
        let markerURL = ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
        return markerURL
    }

    private func markerObject(at markerURL: URL) throws -> [String: Any] {
        try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: Any]
        )
    }

    private func writeMarkerObject(_ object: [String: Any], to markerURL: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: markerURL, options: .atomic)
    }

    private func writeManifestWithoutCurrent(in bundleURL: URL) throws {
        let manifest = try ONTGenotypeResultBundle.loadManifest(from: bundleURL)
        let updated = ONTGenotypeResultBundleManifest(
            schemaVersion: manifest.schemaVersion,
            kind: manifest.kind,
            outputName: manifest.outputName,
            analysisName: manifest.analysisName,
            primaryWorkbookPath: manifest.primaryWorkbookPath,
            currentWorkbookPath: nil,
            workbookRevisions: nil,
            longSummaryCSVPath: manifest.longSummaryCSVPath,
            sampleSummaryCSVPath: manifest.sampleSummaryCSVPath,
            statsJSONPath: manifest.statsJSONPath,
            provenancePath: manifest.provenancePath,
            mhcCandidateArtifacts: manifest.mhcCandidateArtifacts
        )
        try ONTGenotypeResultBundle.writeManifest(updated, to: bundleURL)
    }

    private func assertNoWorkbookUpdateStage(for bundleURL: URL) throws {
        let parent = bundleURL.deletingLastPathComponent()
        let prefix = ".\(bundleURL.lastPathComponent).workbook-update-"
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: parent.path)
                .contains(where: { $0.hasPrefix(prefix) && $0.hasSuffix(".staging") })
        )
    }

    private func workbookCleanupArtifacts(in parent: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil
        ).filter {
            let name = $0.lastPathComponent
            return name.hasPrefix(".lungfish-workbook-cleanup-pending-")
                || name.contains(".workbook-cleanup-state-")
                || name.contains(".workbook-cleanup-warning-")
        }
    }

    private func workbookCleanupStateURL(in parent: URL) throws -> URL {
        try XCTUnwrap(
            try workbookCleanupArtifacts(in: parent).first {
                $0.lastPathComponent.contains(".workbook-cleanup-state-")
            }
        )
    }

    private func workbookRecoveryReceiptActions(in parent: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.contains(".workbook-update-recovery-")
                && $0.pathExtension == "json"
        }.compactMap {
            let object = try JSONSerialization.jsonObject(
                with: Data(contentsOf: $0)
            ) as? [String: Any]
            return object?["action"] as? String
        }
    }

    private func mutateJSONObject(
        at url: URL,
        _ mutation: (inout [String: Any]) throws -> Void
    ) throws {
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: url)
            ) as? [String: Any]
        )
        try mutation(&object)
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: url, options: .atomic)
    }

    private func assertNoRetiredWorkbookGeneration(in parent: URL) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        XCTAssertFalse(
            names.contains {
                $0.hasPrefix(".lungfish-workbook-generation-archive-")
                    || $0.hasPrefix(".lungfish-workbook-cleanup-pending-")
                    || $0.contains(".workbook-cleanup-state-")
            }
        )
    }

    private func interruptCommittedWorkbookCleanup(
        fixture: (bundleURL: URL, manifest: ONTGenotypeResultBundleManifest),
        attestationRoot: URL
    ) throws {
        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: testPythonExecutableURL,
                publicationFailureInjector: { checkpoint in
                    guard checkpoint == "after-revision-manifest-hard-stop" else {
                        return
                    }
                    throw NSError(domain: "SimulatedCommittedWorkbookCrash", code: 9)
                },
                workbookAttestationRootURL: attestationRoot
            ).applyHaplotypeOverrides(
                [],
                annotationSidecarURL: nil,
                into: fixture.bundleURL
            )
        )
    }

    private func interruptWorkbookCleanup(
        branch: String,
        fixture: (bundleURL: URL, manifest: ONTGenotypeResultBundleManifest),
        attestationRoot: URL
    ) throws {
        let checkpoint: String
        switch branch {
        case "committed":
            checkpoint = "after-revision-manifest-hard-stop"
        case "prepared-discard":
            checkpoint = "after-transaction-marker-hard-stop"
        case "rollback":
            checkpoint = "after-exchange-hard-stop"
        case "manual-save-winner":
            checkpoint = "after-revision-manifest-hard-stop"
        default:
            XCTFail("Unknown workbook cleanup branch \(branch)")
            return
        }
        let currentPath = try XCTUnwrap(fixture.manifest.currentWorkbookPath)
        let pythonURL = testPythonExecutableURL
        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService(
                pythonExecutableURL: pythonURL,
                publicationFailureInjector: { observed in
                    guard observed == checkpoint else { return }
                    if branch == "manual-save-winner" {
                        let markerURL = ONTGenotypeWorkbookUpdateRecovery.markerURL(
                            for: fixture.bundleURL
                        )
                        let marker = try XCTUnwrap(
                            try JSONSerialization.jsonObject(
                                with: Data(contentsOf: markerURL)
                            ) as? [String: Any]
                        )
                        let staging = URL(
                            fileURLWithPath: try XCTUnwrap(
                                marker["stagingBundlePath"] as? String
                            ),
                            isDirectory: true
                        )
                        let workbook = staging.appendingPathComponent(currentPath)
                        _ = try Self.runPythonStatic(["-c", #"""
import sys
from openpyxl import load_workbook
path = sys.argv[1]
wb = load_workbook(path)
wb[wb.sheetnames[0]]["Z94"] = "manual-cleanup-winner"
wb.save(path)
"""#, workbook.path], executableURL: pythonURL)
                    }
                    throw NSError(
                        domain: "SimulatedWorkbookBranchCrash",
                        code: 9
                    )
                },
                workbookAttestationRootURL: attestationRoot
            ).applyHaplotypeOverrides(
                [],
                annotationSidecarURL: nil,
                into: fixture.bundleURL
            )
        )
    }

    private func pausedCommittedWorkbookCleanup(
        outputName: String
    ) throws -> (
        root: URL,
        fixture: (bundleURL: URL, manifest: ONTGenotypeResultBundleManifest),
        attestationRoot: URL,
        quarantine: URL,
        lock: ONTGenotypeBundlePublicationLock
    ) {
        let root = try temporaryDirectory()
        do {
            let fixture = try makeMCMWorkbookBundle(in: root, outputName: outputName)
            let attestationRoot = root.appendingPathComponent(
                "attestations",
                isDirectory: true
            )
            try interruptCommittedWorkbookCleanup(
                fixture: fixture,
                attestationRoot: attestationRoot
            )
            let lock = try ONTGenotypeBundlePublicationLock.acquire(
                for: fixture.bundleURL,
                blocking: true,
                createIfMissing: false
            )
            do {
                XCTAssertThrowsError(
                    try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(
                        for: fixture.bundleURL,
                        attestationRootURL: attestationRoot,
                        cleanupFailureInjector: { checkpoint in
                            guard checkpoint == "during-workbook-cleanup-traversal" else {
                                return
                            }
                            throw NSError(
                                domain: "InjectedWorkbookCleanupTraversal",
                                code: 5
                            )
                        }
                    )
                )
                let quarantine = try XCTUnwrap(
                    try FileManager.default.contentsOfDirectory(
                        at: root,
                        includingPropertiesForKeys: nil
                    ).first {
                        $0.lastPathComponent.hasPrefix(
                            ".lungfish-workbook-cleanup-pending-"
                        )
                    }
                )
                XCTAssertFalse(FileManager.default.fileExists(
                    atPath: ONTGenotypeWorkbookUpdateRecovery.markerURL(
                        for: fixture.bundleURL
                    ).path
                ))
                return (root, fixture, attestationRoot, quarantine, lock)
            } catch {
                lock.release()
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func serviceThatFailsIfStagingBegins() -> GenotypeWorkbookRevisionService {
        GenotypeWorkbookRevisionService(
            pythonExecutableURL: testPythonExecutableURL,
            publicationFailureInjector: { checkpoint in
                if checkpoint == "after-stage-created" {
                    throw NSError(domain: "UnexpectedWorkbookUpdateStaging", code: 1)
                }
            }
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeWorkbookRevisionServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class SendableFlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UInt32?

    var value: UInt32? { lock.withLock { stored } }
    func set(_ value: UInt32) { lock.withLock { stored = value } }
}

private final class IncrementingDateProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var nextDate: Date
    private let increment: TimeInterval

    init(start: Date, increment: TimeInterval) {
        self.nextDate = start
        self.increment = increment
    }

    func now() -> Date {
        lock.withLock {
            defer { nextDate = nextDate.addingTimeInterval(increment) }
            return nextDate
        }
    }
}
