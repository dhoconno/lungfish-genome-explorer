import Foundation
import XCTest
@testable import LungfishIO

final class ONTGenotypeResultBundleTests: XCTestCase {
    func testWritesAndLoadsPrimaryWorkbookManifest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ONTGenotypeResultBundleTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("barcode08-mhc.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let workbookURL = bundleURL.appendingPathComponent("barcode08-mhc_vs_Illumina-31262.xlsx")
        try Data("workbook".utf8).write(to: workbookURL)

        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "barcode08-mhc",
            analysisName: "barcode08-mhc",
            primaryWorkbookPath: workbookURL.lastPathComponent,
            longSummaryCSVPath: "barcode08-mhc.retained-demux-genotypes.csv",
            sampleSummaryCSVPath: "barcode08-mhc.retained-demux-samples.csv",
            statsJSONPath: "barcode08-mhc.retained-demux-stats.json",
            provenancePath: "retained-demux-genotyping-provenance.json"
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)

        XCTAssertTrue(ONTGenotypeResultBundle.isBundleURL(bundleURL))
        XCTAssertEqual(try ONTGenotypeResultBundle.loadManifest(from: bundleURL), manifest)
        XCTAssertEqual(
            try ONTGenotypeResultBundle.primaryWorkbookURL(for: bundleURL),
            workbookURL.standardizedFileURL
        )
    }

    func testLoadsCurrentWorkbookWhenManifestHasEditableWorkbookPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ONTGenotypeResultBundleTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("cohort.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let generatedWorkbookURL = bundleURL.appendingPathComponent("cohort.xlsx")
        let currentWorkbookURL = bundleURL
            .appendingPathComponent("artifacts/workbooks", isDirectory: true)
            .appendingPathComponent("current.xlsx")
        try FileManager.default.createDirectory(
            at: currentWorkbookURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("generated".utf8).write(to: generatedWorkbookURL)
        try Data("current".utf8).write(to: currentWorkbookURL)
        let artifacts = try writeMinimalNativeArtifacts(in: bundleURL, outputName: "cohort")

        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "cohort",
            analysisName: "cohort",
            primaryWorkbookPath: generatedWorkbookURL.lastPathComponent,
            currentWorkbookPath: "artifacts/workbooks/current.xlsx",
            longSummaryCSVPath: artifacts.genotypeCSV.lastPathComponent,
            sampleSummaryCSVPath: artifacts.sampleCSV.lastPathComponent,
            statsJSONPath: artifacts.statsJSON.lastPathComponent,
            provenancePath: artifacts.provenance.lastPathComponent
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)

        let result = try ONTGenotypeResultBundle.loadResult(from: bundleURL)

        XCTAssertEqual(
            try ONTGenotypeResultBundle.primaryWorkbookURL(for: bundleURL),
            generatedWorkbookURL.standardizedFileURL
        )
        XCTAssertEqual(
            try ONTGenotypeResultBundle.currentWorkbookURL(for: bundleURL),
            currentWorkbookURL.standardizedFileURL
        )
        XCTAssertEqual(result.artifacts.primaryWorkbookURL, generatedWorkbookURL.standardizedFileURL)
        XCTAssertEqual(result.artifacts.workbookURL, currentWorkbookURL.standardizedFileURL)
    }

    func testCurrentWorkbookURLFallsBackToPrimaryWorkbookForOldBundles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ONTGenotypeResultBundleTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("legacy.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let workbookURL = bundleURL.appendingPathComponent("legacy.xlsx")
        try Data("legacy".utf8).write(to: workbookURL)
        let artifacts = try writeMinimalNativeArtifacts(in: bundleURL, outputName: "legacy")

        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "legacy",
            analysisName: "legacy",
            primaryWorkbookPath: workbookURL.lastPathComponent,
            longSummaryCSVPath: artifacts.genotypeCSV.lastPathComponent,
            sampleSummaryCSVPath: artifacts.sampleCSV.lastPathComponent,
            statsJSONPath: artifacts.statsJSON.lastPathComponent,
            provenancePath: artifacts.provenance.lastPathComponent
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)

        let result = try ONTGenotypeResultBundle.loadResult(from: bundleURL)

        XCTAssertEqual(
            try ONTGenotypeResultBundle.primaryWorkbookURL(for: bundleURL),
            workbookURL.standardizedFileURL
        )
        XCTAssertEqual(
            try ONTGenotypeResultBundle.currentWorkbookURL(for: bundleURL),
            workbookURL.standardizedFileURL
        )
        XCTAssertEqual(result.artifacts.primaryWorkbookURL, workbookURL.standardizedFileURL)
        XCTAssertEqual(result.artifacts.workbookURL, workbookURL.standardizedFileURL)
    }

    func testLoadsNativeResultSummariesFromBundleArtifacts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ONTGenotypeResultBundleTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("barcode08-mhc.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let workbookURL = bundleURL.appendingPathComponent("barcode08-mhc_vs_Illumina-31262.xlsx")
        let genotypeCSVURL = bundleURL.appendingPathComponent("barcode08-mhc.retained-demux-genotypes.csv")
        let sampleCSVURL = bundleURL.appendingPathComponent("barcode08-mhc.retained-demux-samples.csv")
        let statsJSONURL = bundleURL.appendingPathComponent("barcode08-mhc.retained-demux-stats.json")
        let provenanceURL = bundleURL.appendingPathComponent("retained-demux-genotyping-provenance.json")

        try Data("workbook".utf8).write(to: workbookURL)
        try Data("{}".utf8).write(to: provenanceURL)
        try """
        sample,genotype,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_reads,overall_unique_retained_percent
        AnimalA,01_M1_A_01,42,39,100,46,46.0,1000,60,6.0
        AnimalA,02_M2_B_01,4,4,100,46,46.0,1000,60,6.0
        AnimalB,13_M3_DRB1_10,12,4,90,4,4.444444,1000,60,6.0
        unassigned,noise_reference,7,7,,7,,1000,60,6.0
        """.write(to: genotypeCSVURL, atomically: true, encoding: .utf8)
        try """
        sample,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_percent
        AnimalA,46,43,100,46.0,1000,6.0
        AnimalB,12,4,90,4.444444,1000,6.0
        AnimalC,0,0,80,0.0,1000,6.0
        unassigned,7,7,,,
        """.write(to: sampleCSVURL, atomically: true, encoding: .utf8)
        try """
        {
          "totalInputReads": 1000,
          "totalAlignments": 120,
          "passedAlignments": 65,
          "retainedUniqueReads": 60,
          "retainedUniquePercentOfTotalReads": 6.0,
          "assignedUniqueRetainedReads": 53,
          "unassignedUniqueRetainedReads": 7
        }
        """.write(to: statsJSONURL, atomically: true, encoding: .utf8)

        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "barcode08-mhc",
            analysisName: "barcode08-mhc",
            primaryWorkbookPath: workbookURL.lastPathComponent,
            longSummaryCSVPath: genotypeCSVURL.lastPathComponent,
            sampleSummaryCSVPath: sampleCSVURL.lastPathComponent,
            statsJSONPath: statsJSONURL.lastPathComponent,
            provenancePath: provenanceURL.lastPathComponent,
            createdAt: "2026-05-21T21:00:00Z"
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)

        let result = try ONTGenotypeResultBundle.loadResult(from: bundleURL)

        XCTAssertEqual(result.bundleURL, bundleURL.standardizedFileURL)
        XCTAssertEqual(result.artifacts.workbookURL, workbookURL.standardizedFileURL)
        XCTAssertEqual(result.stats.totalInputReads, 1000)
        XCTAssertEqual(result.stats.retainedUniqueReads, 60)
        XCTAssertEqual(result.calls.count, 3, "Unassigned genotype rows should not be treated as sample calls")
        XCTAssertEqual(result.samples.map(\.sample), ["AnimalA", "AnimalB", "AnimalC"])
        XCTAssertEqual(result.samples[0].topCall?.genotype, "01_M1_A_01")
        XCTAssertEqual(result.samples[0].callCount, 2)
        XCTAssertEqual(result.samples[0].qcStatus, .ok)
        XCTAssertEqual(result.samples[1].qcStatus, .lowSupport)
        XCTAssertEqual(result.samples[2].qcStatus, .review)
        XCTAssertEqual(result.calls[0].haplotypeTokens, ["M1"])
        XCTAssertEqual(result.calls[0].locusToken, "A")
        XCTAssertEqual(result.calls[0].locusGroup, "MHC-A")
    }

    func testLoadResultIgnoresRepeatedCSVHeaderRowsInSampleSummary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ONTGenotypeResultBundleTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("barcode08-mhc.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let workbookURL = bundleURL.appendingPathComponent("barcode08-mhc.xlsx")
        let genotypeCSVURL = bundleURL.appendingPathComponent("barcode08-mhc.retained-demux-genotypes.csv")
        let sampleCSVURL = bundleURL.appendingPathComponent("barcode08-mhc.retained-demux-samples.csv")
        let statsJSONURL = bundleURL.appendingPathComponent("barcode08-mhc.retained-demux-stats.json")
        let provenanceURL = bundleURL.appendingPathComponent("retained-demux-genotyping-provenance.json")

        try Data("workbook".utf8).write(to: workbookURL)
        try Data("{}".utf8).write(to: provenanceURL)
        try """
        sample,genotype,passed_alignments,passed_unique_reads
        AnimalA,01_M1_A_01,42,39
        """.write(to: genotypeCSVURL, atomically: true, encoding: .utf8)
        try """
        sample,passed_alignments,passed_unique_reads
        AnimalA,42,39
        sample,passed_alignments,passed_unique_reads
        AnimalB,12,12
        """.write(to: sampleCSVURL, atomically: true, encoding: .utf8)
        try Data("{}".utf8).write(to: statsJSONURL)

        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "barcode08-mhc",
            analysisName: "barcode08-mhc",
            primaryWorkbookPath: workbookURL.lastPathComponent,
            longSummaryCSVPath: genotypeCSVURL.lastPathComponent,
            sampleSummaryCSVPath: sampleCSVURL.lastPathComponent,
            statsJSONPath: statsJSONURL.lastPathComponent,
            provenancePath: provenanceURL.lastPathComponent
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)

        let result = try ONTGenotypeResultBundle.loadResult(from: bundleURL)

        XCTAssertEqual(result.samples.map(\.sample), ["AnimalA", "AnimalB"])
        XCTAssertFalse(result.sampleNames.contains("sample"))
    }

    func testSummarizesSharedCallsByInferredLocus() {
        let dqb1Primary = ONTGenotypeCall(
            sample: "LF2874",
            genotype: "13_Mafa_DQB1_06g1|DQB1_06_01_01,_DQB1_06_01_02,_DQB1_06_02,_DQB1_06_34",
            passedAlignments: 2_945,
            passedUniqueReads: 2_945,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        let dqb1Shared = ONTGenotypeCall(
            sample: "LF2875",
            genotype: "13_Mafa_DQB1_06g1|DQB1_06_01_01,_DQB1_06_01_02,_DQB1_06_02,_DQB1_06_34",
            passedAlignments: 1_200,
            passedUniqueReads: 1_200,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        let bCall = ONTGenotypeCall(
            sample: "LF2874",
            genotype: "03_Mafa_B_075_01",
            passedAlignments: 148,
            passedUniqueReads: 148,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        let result = ONTGenotypeResultBundleData(
            bundleURL: URL(fileURLWithPath: "/tmp/example.lungfishgenotype"),
            manifest: ONTGenotypeResultBundleManifest(
                outputName: "example",
                analysisName: "Example",
                primaryWorkbookPath: "example.xlsx",
                longSummaryCSVPath: "example.retained-demux-genotypes.csv",
                sampleSummaryCSVPath: "example.retained-demux-samples.csv",
                statsJSONPath: "example.retained-demux-stats.json",
                provenancePath: "retained-demux-genotyping-provenance.json"
            ),
            artifacts: ONTGenotypeResultArtifacts(
                workbookURL: URL(fileURLWithPath: "/tmp/example.xlsx"),
                longSummaryCSVURL: URL(fileURLWithPath: "/tmp/example.retained-demux-genotypes.csv"),
                sampleSummaryCSVURL: URL(fileURLWithPath: "/tmp/example.retained-demux-samples.csv"),
                statsJSONURL: URL(fileURLWithPath: "/tmp/example.retained-demux-stats.json"),
                provenanceURL: URL(fileURLWithPath: "/tmp/retained-demux-genotyping-provenance.json")
            ),
            stats: ONTGenotypeRunStats(),
            calls: [dqb1Primary, dqb1Shared, bCall],
            samples: []
        )

        XCTAssertEqual(dqb1Primary.locusToken, "DQB1")
        XCTAssertEqual(dqb1Primary.locusGroup, "MHC-DQB1")
        XCTAssertEqual(bCall.locusToken, "B")
        XCTAssertEqual(bCall.locusGroup, "MHC-B")
        XCTAssertEqual(result.locusSummaries.map(\.locus), ["MHC-B", "MHC-DQB1"])
        XCTAssertEqual(result.locusSummaries.first { $0.locus == "MHC-DQB1" }?.sharedCalls.first?.sampleCount, 2)
        XCTAssertEqual(result.locusSummaries.first { $0.locus == "MHC-DQB1" }?.sharedCalls.first?.totalUniqueReads, 4_145)
    }

    func testSeparatesAGFromClassicalAInLocusSummaries() {
        let classicalA = ONTGenotypeCall(
            sample: "DW472",
            genotype: "01_Mafa_A1_063g|A1_063_01,_A1_063_02",
            passedAlignments: 148,
            passedUniqueReads: 148,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        let ag = ONTGenotypeCall(
            sample: "DW472",
            genotype: "18_Mafa_AG_05_AG_06g|AG_05_02_01,_AG_06_04",
            passedAlignments: 204,
            passedUniqueReads: 204,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        let result = ONTGenotypeResultBundleData(
            bundleURL: URL(fileURLWithPath: "/tmp/example.lungfishgenotype"),
            manifest: ONTGenotypeResultBundleManifest(
                outputName: "example",
                analysisName: "Example",
                primaryWorkbookPath: "example.xlsx",
                longSummaryCSVPath: "example.retained-demux-genotypes.csv",
                sampleSummaryCSVPath: "example.retained-demux-samples.csv",
                statsJSONPath: "example.retained-demux-stats.json",
                provenancePath: "retained-demux-genotyping-provenance.json"
            ),
            artifacts: ONTGenotypeResultArtifacts(
                workbookURL: URL(fileURLWithPath: "/tmp/example.xlsx"),
                longSummaryCSVURL: URL(fileURLWithPath: "/tmp/example.retained-demux-genotypes.csv"),
                sampleSummaryCSVURL: URL(fileURLWithPath: "/tmp/example.retained-demux-samples.csv"),
                statsJSONURL: URL(fileURLWithPath: "/tmp/example.retained-demux-stats.json"),
                provenanceURL: URL(fileURLWithPath: "/tmp/retained-demux-genotyping-provenance.json")
            ),
            stats: ONTGenotypeRunStats(),
            calls: [classicalA, ag],
            samples: []
        )

        XCTAssertEqual(classicalA.locusGroup, "MHC-A")
        XCTAssertEqual(ag.locusGroup, "MHC-AG")
        XCTAssertEqual(result.locusSummaries.map(\.locus), ["MHC-A", "MHC-AG"])
    }

    func testKIRLocusParsingDoesNotDefaultToMHC() {
        let kir = ONTGenotypeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_KIR3DL01_001_01",
            passedAlignments: 84,
            passedUniqueReads: 84,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )

        XCTAssertEqual(kir.locusToken, "KIR3DL01")
        XCTAssertEqual(kir.locusGroup, "KIR-KIR3DL01")
    }

    func testAnchorSummariesGroupExplicitHaplotypeTokensAcrossLoci() {
        let a = ONTGenotypeCall(
            sample: "AnimalA",
            genotype: "01_M1_A_01",
            passedAlignments: 40,
            passedUniqueReads: 40,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        let b = ONTGenotypeCall(
            sample: "AnimalA",
            genotype: "02_M1_B_01",
            passedAlignments: 30,
            passedUniqueReads: 30,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        let unanchored = ONTGenotypeCall(
            sample: "AnimalB",
            genotype: "13_Mafa_DQB1_06g1|DQB1_06_01_01",
            passedAlignments: 20,
            passedUniqueReads: 20,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        let result = ONTGenotypeResultBundleData(
            bundleURL: URL(fileURLWithPath: "/tmp/example.lungfishgenotype"),
            manifest: ONTGenotypeResultBundleManifest(
                outputName: "example",
                analysisName: "Example",
                primaryWorkbookPath: "example.xlsx",
                longSummaryCSVPath: "example.retained-demux-genotypes.csv",
                sampleSummaryCSVPath: "example.retained-demux-samples.csv",
                statsJSONPath: "example.retained-demux-stats.json",
                provenancePath: "retained-demux-genotyping-provenance.json"
            ),
            artifacts: ONTGenotypeResultArtifacts(
                workbookURL: URL(fileURLWithPath: "/tmp/example.xlsx"),
                longSummaryCSVURL: URL(fileURLWithPath: "/tmp/example.retained-demux-genotypes.csv"),
                sampleSummaryCSVURL: URL(fileURLWithPath: "/tmp/example.retained-demux-samples.csv"),
                statsJSONURL: URL(fileURLWithPath: "/tmp/example.retained-demux-stats.json"),
                provenanceURL: URL(fileURLWithPath: "/tmp/retained-demux-genotyping-provenance.json")
            ),
            stats: ONTGenotypeRunStats(),
            calls: [a, b, unanchored],
            samples: []
        )

        let anchors = result.anchorSummaries()
        let m1 = anchors.first { $0.label == "M1" }
        let noToken = anchors.first { $0.label == "Unanchored" }

        XCTAssertEqual(m1?.source, .labelToken)
        XCTAssertEqual(m1?.loci, ["MHC-A", "MHC-B"])
        XCTAssertEqual(m1?.sampleCount, 1)
        XCTAssertEqual(m1?.totalUniqueReads, 70)
        XCTAssertEqual(m1?.sharedCalls.map(\.genotype).sorted(), ["01_M1_A_01", "02_M1_B_01"])
        XCTAssertEqual(noToken?.source, .unanchored)
        XCTAssertTrue(m1?.caveat.localizedCaseInsensitiveContains("not phased") ?? false)
    }

    func testFiltersSharedCallsByViewedLocusSupportPercent() {
        let highSupport = ONTGenotypeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            passedAlignments: 990,
            passedUniqueReads: 990,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: 1_000,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        let lowSupport = ONTGenotypeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_002_01",
            passedAlignments: 9,
            passedUniqueReads: 9,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: 1_000,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        let result = makeResult(calls: [highSupport, lowSupport])

        let filtered = result.locusSummaries(
            minimumSupportPercent: 1.0,
            denominator: .viewedLocus
        )

        XCTAssertEqual(filtered.flatMap(\.sharedCalls).map(\.genotype), ["01_Mafa_A1_001_01"])
        XCTAssertEqual(filtered.first?.sharedCalls.first?.sampleCount, 1)
        XCTAssertEqual(filtered.first?.sharedCalls.first?.totalUniqueReads, 990)
    }

    func testComputesSameLocusCoOccurrenceForSelectedGenotype() throws {
        let selectedA = makeCall(sample: "A", genotype: "13_Mafa_DQB1_01", uniqueReads: 50)
        let selectedB = makeCall(sample: "B", genotype: "13_Mafa_DQB1_01", uniqueReads: 50)
        let companionA = makeCall(sample: "A", genotype: "13_Mafa_DQB1_02", uniqueReads: 30)
        let companionC = makeCall(sample: "C", genotype: "13_Mafa_DQB1_02", uniqueReads: 30)
        let otherLocus = makeCall(sample: "A", genotype: "03_Mafa_B_001_01", uniqueReads: 30)
        let result = makeResult(calls: [selectedA, selectedB, companionA, companionC, otherLocus])

        let coOccurrences = result.sameLocusCoOccurrences(
            for: "13_Mafa_DQB1_01",
            minimumSupportPercent: 0,
            denominator: .viewedLocus
        )

        XCTAssertEqual(coOccurrences.map(\.candidateGenotype), ["13_Mafa_DQB1_02"])
        let first = try XCTUnwrap(coOccurrences.first)
        XCTAssertEqual(first.selectedSampleCount, 2)
        XCTAssertEqual(first.candidateSampleCount, 2)
        XCTAssertEqual(first.sharedSampleCount, 1)
        XCTAssertEqual(first.probabilityCandidateGivenSelected, 0.5, accuracy: 0.0001)
        XCTAssertEqual(first.probabilitySelectedGivenCandidate, 0.5, accuracy: 0.0001)
        XCTAssertEqual(first.jaccard, 1.0 / 3.0, accuracy: 0.0001)
    }

    func testSupportFilteringScalesForRetainedDemuxSizedBundles() {
        var calls: [ONTGenotypeCall] = []
        for sampleIndex in 0..<52 {
            let sample = "LF\(2800 + sampleIndex)"
            for genotypeIndex in 0..<120 {
                let locus = genotypeIndex.isMultiple(of: 2) ? "A1" : "DQB1"
                calls.append(ONTGenotypeCall(
                    sample: sample,
                    genotype: String(format: "%02d_Mafa_%@_%03d_01", genotypeIndex % 20, locus, genotypeIndex),
                    passedAlignments: genotypeIndex.isMultiple(of: 17) ? 1 : 100,
                    passedUniqueReads: genotypeIndex.isMultiple(of: 17) ? 1 : 100,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedReads: 12_000,
                    sampleUniqueRetainedPercent: nil,
                    overallInputReads: nil,
                    overallUniqueRetainedReads: nil,
                    overallUniqueRetainedPercent: nil
                ))
            }
        }
        let result = makeResult(calls: calls)

        let start = Date()
        let summaries = result.locusSummaries(
            minimumSupportPercent: 1.0,
            denominator: .viewedLocus
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertFalse(summaries.isEmpty)
        XCTAssertLessThan(elapsed, 1.5, "Support filtering should use indexed denominators, not rescan every row for every call")
    }

    func testLoadsRetainedDemuxCSVsWithQuotedAliasesAndBlankOptionalFields() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ONTGenotypeResultBundleTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("barcode05-mhc.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let workbookURL = bundleURL.appendingPathComponent("barcode05-mhc.xlsx")
        let genotypeCSVURL = bundleURL.appendingPathComponent("barcode05-mhc.retained-demux-genotypes.csv")
        let sampleCSVURL = bundleURL.appendingPathComponent("barcode05-mhc.retained-demux-samples.csv")
        let statsJSONURL = bundleURL.appendingPathComponent("barcode05-mhc.retained-demux-stats.json")
        let provenanceURL = bundleURL.appendingPathComponent("retained-demux-genotyping-provenance.json")

        try Data("workbook".utf8).write(to: workbookURL)
        try Data("{}".utf8).write(to: provenanceURL)
        try """
        sample,genotype,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_reads,overall_unique_retained_percent\r
        LF2823,"13_Mafa_DQB1_06g1|DQB1_06_01_01,_DQB1_06_01_02,_DQB1_06_02,_DQB1_06_34",821,821,,3545,,11197546,260534,2.326706\r
        LF2823,13_Mafa_DQB1_06_08,387,387,,3545,,11197546,260534,2.326706\r
        LF2824,15_Mafa_DPB1_20_01,330,330,,6057,,11197546,260534,2.326706\r
        unassigned,noise_reference,7,7,,7,,11197546,260534,2.326706\r
        """.write(to: genotypeCSVURL, atomically: true, encoding: .utf8)
        try """
        sample,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_percent\r
        LF2823,3576,3545,,,11197546,2.326706\r
        LF2824,6093,6057,,,11197546,2.326706\r
        unassigned,7,7,,,\r
        """.write(to: sampleCSVURL, atomically: true, encoding: .utf8)
        try """
        {
          "totalInputReads": 11197546,
          "retainedUniqueReads": 260534,
          "assignedUniqueRetainedReads": 258326,
          "unassignedUniqueRetainedReads": 2208
        }
        """.write(to: statsJSONURL, atomically: true, encoding: .utf8)

        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "barcode05-mhc",
            analysisName: "barcode05-mhc",
            primaryWorkbookPath: workbookURL.lastPathComponent,
            longSummaryCSVPath: genotypeCSVURL.lastPathComponent,
            sampleSummaryCSVPath: sampleCSVURL.lastPathComponent,
            statsJSONPath: statsJSONURL.lastPathComponent,
            provenancePath: provenanceURL.lastPathComponent
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)

        let result = try ONTGenotypeResultBundle.loadResult(from: bundleURL)

        XCTAssertEqual(result.calls.count, 3)
        XCTAssertEqual(result.samples.map(\.sample), ["LF2823", "LF2824"])
        let firstSample = try XCTUnwrap(result.samples.first)
        XCTAssertEqual(firstSample.passedAlignments, 3576)
        XCTAssertEqual(firstSample.passedUniqueReads, 3545)
        XCTAssertEqual(
            firstSample.topCall?.genotype,
            "13_Mafa_DQB1_06g1|DQB1_06_01_01,_DQB1_06_01_02,_DQB1_06_02,_DQB1_06_34"
        )
    }

    func testLoadsOptionalHaplotypeAnalysisArtifactFromManifest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ONTGenotypeResultBundleTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("barcode08-mhc.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let workbookURL = bundleURL.appendingPathComponent("barcode08-mhc.xlsx")
        let genotypeCSVURL = bundleURL.appendingPathComponent("barcode08-mhc.retained-demux-genotypes.csv")
        let sampleCSVURL = bundleURL.appendingPathComponent("barcode08-mhc.retained-demux-samples.csv")
        let statsJSONURL = bundleURL.appendingPathComponent("barcode08-mhc.retained-demux-stats.json")
        let provenanceURL = bundleURL.appendingPathComponent("retained-demux-genotyping-provenance.json")
        let haplotypeURL = bundleURL.appendingPathComponent("barcode08-mhc.haplotype-analysis.json")

        try Data("workbook".utf8).write(to: workbookURL)
        try Data("{}".utf8).write(to: provenanceURL)
        try Data("{}".utf8).write(to: statsJSONURL)
        try """
        sample,genotype,passed_alignments,passed_unique_reads
        DW472,05_M1M2M3_A1_063g,100,100
        """.write(to: genotypeCSVURL, atomically: true, encoding: .utf8)
        try """
        sample,passed_alignments,passed_unique_reads
        DW472,100,100
        """.write(to: sampleCSVURL, atomically: true, encoding: .utf8)
        try """
        {
          "schemaVersion": 1,
          "assayID": "MHC-exon2-miSeq",
          "definitionSetID": "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
          "definitionSetName": "Mauritian cynomolgus macaques",
          "speciesName": "Mauritian cynomolgus macaques",
          "generatedAt": "2026-05-22T19:45:00Z",
          "samples": [
            {
              "sample": "DW472",
              "calls": [
                {
                  "locus": "MHC-A",
                  "sourceLocus": "Mafa-A",
                  "haplotype1": "A1_063",
                  "haplotype2": "-",
                  "status": "specialCase",
                  "matchedHaplotypes": [],
                  "observedGenotypeCount": 1,
                  "observedGenotypes": ["05_M1M2M3_A1_063g"],
                  "notes": "Notebook-compatible MCM MHC-A special case"
                }
              ]
            }
          ]
        }
        """.write(to: haplotypeURL, atomically: true, encoding: .utf8)

        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "barcode08-mhc",
            analysisName: "barcode08-mhc",
            primaryWorkbookPath: workbookURL.lastPathComponent,
            longSummaryCSVPath: genotypeCSVURL.lastPathComponent,
            sampleSummaryCSVPath: sampleCSVURL.lastPathComponent,
            statsJSONPath: statsJSONURL.lastPathComponent,
            provenancePath: provenanceURL.lastPathComponent,
            haplotypeAnalysisPath: haplotypeURL.lastPathComponent,
            haplotypeDefinitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            haplotypeAssayID: "MHC-exon2-miSeq"
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)

        let result = try ONTGenotypeResultBundle.loadResult(from: bundleURL)

        XCTAssertEqual(result.manifest.haplotypeDefinitionSetID, "MHC-exon2-miSeq.mauritian-cynomolgus-macaques")
        XCTAssertEqual(result.manifest.haplotypeAssayID, "MHC-exon2-miSeq")
        XCTAssertEqual(result.artifacts.haplotypeAnalysisURL, haplotypeURL.standardizedFileURL)
        XCTAssertEqual(result.haplotypeAnalysis?.definitionSetName, "Mauritian cynomolgus macaques")
        XCTAssertEqual(result.haplotypeAnalysis?.samples.first?.calls.first?.haplotype1, "A1_063")
    }

    private func makeCall(
        sample: String,
        genotype: String,
        uniqueReads: Int
    ) -> ONTGenotypeCall {
        ONTGenotypeCall(
            sample: sample,
            genotype: genotype,
            passedAlignments: uniqueReads,
            passedUniqueReads: uniqueReads,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: 100,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
    }

    private func makeResult(calls: [ONTGenotypeCall]) -> ONTGenotypeResultBundleData {
        ONTGenotypeResultBundleData(
            bundleURL: URL(fileURLWithPath: "/tmp/example.lungfishgenotype"),
            manifest: ONTGenotypeResultBundleManifest(
                outputName: "example",
                analysisName: "Example",
                primaryWorkbookPath: "example.xlsx",
                longSummaryCSVPath: "example.retained-demux-genotypes.csv",
                sampleSummaryCSVPath: "example.retained-demux-samples.csv",
                statsJSONPath: "example.retained-demux-stats.json",
                provenancePath: "retained-demux-genotyping-provenance.json"
            ),
            artifacts: ONTGenotypeResultArtifacts(
                workbookURL: URL(fileURLWithPath: "/tmp/example.xlsx"),
                longSummaryCSVURL: URL(fileURLWithPath: "/tmp/example.retained-demux-genotypes.csv"),
                sampleSummaryCSVURL: URL(fileURLWithPath: "/tmp/example.retained-demux-samples.csv"),
                statsJSONURL: URL(fileURLWithPath: "/tmp/example.retained-demux-stats.json"),
                provenanceURL: URL(fileURLWithPath: "/tmp/retained-demux-genotyping-provenance.json")
            ),
            stats: ONTGenotypeRunStats(),
            calls: calls,
            samples: []
        )
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
}
