// WorkflowPlatformPinTests.swift - Pins the LungfishWorkflow import platform and its link to LungfishIO (R15)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
import LungfishIO
import LungfishTestSupport

/// The four-case platform the FASTQ import pipeline, recipes and
/// `lungfish-cli import fastq --platform` use. Before the R15 reconciliation it
/// was a second public enum named `SequencingPlatform`.
private typealias WorkflowPlatform = LungfishWorkflow.IngestionPlatform

/// Pins the import platform's spellings, ingestion defaults, header detection
/// and its mapping onto `LungfishIO.SequencingPlatform`, the platform FASTQ
/// sidecars record.
///
/// These expectations record what the code does today, not a scientific
/// ruling. They were written before the R15 reconciliation and must pass
/// unchanged after it. Update an expectation only with a ruling from the owner.
final class WorkflowPlatformPinTests: XCTestCase {

    // MARK: - Cases, spellings and ingestion defaults

    private struct DefaultsRow {
        let platform: WorkflowPlatform
        let rawValue: String
        let displayName: String
        let defaultPairing: IngestionMetadata.PairingMode
        let defaultOptimizeStorage: Bool
        let defaultQualityBinning: QualityBinningScheme
        let defaultCompressionLevel: CompressionLevel
    }

    private let defaultsRows: [DefaultsRow] = [
        DefaultsRow(
            platform: .illumina, rawValue: "illumina", displayName: "Illumina",
            defaultPairing: .interleaved, defaultOptimizeStorage: true,
            defaultQualityBinning: .none, defaultCompressionLevel: .balanced
        ),
        DefaultsRow(
            platform: .ont, rawValue: "ont", displayName: "Oxford Nanopore",
            defaultPairing: .singleEnd, defaultOptimizeStorage: false,
            defaultQualityBinning: .none, defaultCompressionLevel: .balanced
        ),
        DefaultsRow(
            platform: .pacbio, rawValue: "pacbio", displayName: "PacBio",
            defaultPairing: .singleEnd, defaultOptimizeStorage: false,
            defaultQualityBinning: .none, defaultCompressionLevel: .balanced
        ),
        DefaultsRow(
            platform: .ultima, rawValue: "ultima", displayName: "Ultima Genomics",
            defaultPairing: .interleaved, defaultOptimizeStorage: true,
            defaultQualityBinning: .none, defaultCompressionLevel: .balanced
        ),
    ]

    func testCaseListAndOrder() {
        XCTAssertEqual(WorkflowPlatform.allCases, defaultsRows.map(\.platform))
    }

    func testSpellingsAndIngestionDefaultsPerPlatform() {
        for row in defaultsRows {
            let platform = row.platform
            XCTAssertEqual(platform.rawValue, row.rawValue)
            XCTAssertEqual(WorkflowPlatform(rawValue: row.rawValue), platform)
            XCTAssertEqual(platform.displayName, row.displayName, row.rawValue)
            XCTAssertEqual(platform.defaultPairing, row.defaultPairing, row.rawValue)
            XCTAssertEqual(platform.defaultOptimizeStorage, row.defaultOptimizeStorage, row.rawValue)
            XCTAssertEqual(platform.defaultQualityBinning, row.defaultQualityBinning, row.rawValue)
            XCTAssertEqual(platform.defaultCompressionLevel, row.defaultCompressionLevel, row.rawValue)
            XCTAssertEqual(platform.defaultCompressionLevel.rawValue, "balanced", row.rawValue)
            XCTAssertEqual(platform.defaultCompressionLevel.zlValue, 4, row.rawValue)
        }
    }

    func testCanonicalSpellingsAreNotImportSpellings() {
        // The CLI lowercases --platform and then needs one of these exact values.
        XCTAssertNil(WorkflowPlatform(rawValue: "oxfordNanopore"))
        XCTAssertNil(WorkflowPlatform(rawValue: "nanopore"))
        XCTAssertNil(WorkflowPlatform(rawValue: "element"))
        XCTAssertNil(WorkflowPlatform(rawValue: "mgi"))
        XCTAssertNil(WorkflowPlatform(rawValue: "unknown"))
        XCTAssertNil(WorkflowPlatform(rawValue: "ONT"))
    }

    func testEachCaseEncodesAsItsRawValueString() throws {
        for row in defaultsRows {
            let encoded = try JSONEncoder().encode(row.platform)
            XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"\(row.rawValue)\"")
            XCTAssertEqual(
                try JSONDecoder().decode(WorkflowPlatform.self, from: Data("\"\(row.rawValue)\"".utf8)),
                row.platform
            )
        }
    }

    // MARK: - Import configuration resolution

    private struct ResolvedImport: Equatable {
        let optimizeStorage: Bool
        let clumpingTool: ClumpingTool
        let qualityBinning: QualityBinningScheme
        let compressionLevel: CompressionLevel
    }

    private func resolved(_ config: FASTQBatchImporter.ImportConfig) -> ResolvedImport {
        ResolvedImport(
            optimizeStorage: config.optimizeStorage,
            clumpingTool: config.clumpingTool,
            qualityBinning: config.qualityBinning,
            compressionLevel: config.compressionLevel
        )
    }

    func testImportConfigResolutionPerPlatform() {
        let project = URL(fileURLWithPath: "/tmp/pin.lungfish")
        let shortRead = ResolvedImport(optimizeStorage: true, clumpingTool: .auto, qualityBinning: .none, compressionLevel: .balanced)
        let longRead = ResolvedImport(optimizeStorage: false, clumpingTool: .none, qualityBinning: .none, compressionLevel: .balanced)
        let expectedDefaults: [WorkflowPlatform: ResolvedImport] = [
            .illumina: shortRead, .ont: longRead, .pacbio: longRead, .ultima: shortRead,
        ]
        for platform in WorkflowPlatform.allCases {
            let label = platform.rawValue
            XCTAssertEqual(
                resolved(.init(projectDirectory: project, platform: platform)),
                expectedDefaults[platform], label
            )

            // Clumping stays off for long-read platforms even when asked for.
            let supportsClumping = platform == .illumina || platform == .ultima
            let forced = resolved(.init(projectDirectory: project, platform: platform, optimizeStorage: true))
            XCTAssertEqual(forced.optimizeStorage, supportsClumping, label)
            XCTAssertEqual(forced.clumpingTool, supportsClumping ? .auto : .none, label)

            let bbtools = resolved(.init(projectDirectory: project, platform: platform, clumpingTool: .bbtools))
            XCTAssertEqual(bbtools.optimizeStorage, supportsClumping, label)
            XCTAssertEqual(bbtools.clumpingTool, supportsClumping ? .bbtools : .none, label)

            let off = resolved(.init(projectDirectory: project, platform: platform, optimizeStorage: false))
            XCTAssertEqual(off.optimizeStorage, false, label)
            XCTAssertEqual(off.clumpingTool, .none, label)

            // A recipe's binning beats the platform default, an explicit choice beats both.
            let recipe = Recipe(id: "pin", name: "Pin", platforms: [platform], qualityBinning: .illumina4, steps: [])
            XCTAssertEqual(
                FASTQBatchImporter.ImportConfig(projectDirectory: project, platform: platform, newRecipe: recipe).qualityBinning,
                .illumina4, label
            )
            XCTAssertEqual(
                FASTQBatchImporter.ImportConfig(
                    projectDirectory: project, platform: platform, newRecipe: recipe, qualityBinning: QualityBinningScheme.none
                ).qualityBinning,
                QualityBinningScheme.none, label
            )
        }
        // No default platform: an import names one, or asks for auto.
        XCTAssertEqual(FASTQBatchImporter.ImportConfig(projectDirectory: project, platform: .illumina).sequencingPlatform, .illumina)
        let auto = FASTQBatchImporter.ImportConfig(projectDirectory: project, platform: .auto)
        XCTAssertEqual(auto.platformRequest, .auto)
        XCTAssertEqual(auto.sequencingPlatform, .unknown)
        // Element and MGI keep the short-read storage defaults, Unknown takes the long-read ones.
        XCTAssertEqual(resolved(.init(projectDirectory: project, platform: .given(.element))), shortRead)
        XCTAssertEqual(resolved(.init(projectDirectory: project, platform: .given(.mgi))), shortRead)
        XCTAssertEqual(resolved(.init(projectDirectory: project, platform: .given(.unknown))), longRead)
    }

    // MARK: - Mapping onto LungfishIO.SequencingPlatform

    func testSidecarPlatformAndReadTypeForEachImportPlatform() throws {
        let expected: [(WorkflowPlatform, LungfishIO.SequencingPlatform, FASTQAssemblyReadType?)] = [
            (.illumina, .illumina, .illuminaShortReads),
            (.ont, .oxfordNanopore, .ontReads),
            (.pacbio, .pacbio, nil),
            (.ultima, .ultima, nil),
        ]
        XCTAssertEqual(expected.map(\.0), WorkflowPlatform.allCases)
        for (platform, canonical, readType) in expected {
            XCTAssertEqual(FASTQBatchImporter.persistedSequencingPlatform(for: platform), canonical, platform.rawValue)
            XCTAssertEqual(FASTQBatchImporter.persistedAssemblyReadType(for: platform), readType, platform.rawValue)
        }

        let root = try TestTempDirectory.make(prefix: "workflow-platform-sidecar-pin")
        defer { TestTempDirectory.cleanup(root) }
        let expectedSidecar: [(WorkflowPlatform, String, String?)] = [
            (.illumina, "illumina", "illuminaShortReads"),
            (.ont, "oxfordNanopore", "ontReads"),
            (.pacbio, "pacbio", nil),
            (.ultima, "ultima", nil),
        ]
        for (platform, platformSpelling, readTypeSpelling) in expectedSidecar {
            let fastqURL = root.appendingPathComponent("\(platform.rawValue).fastq")
            try "@r1\nACGT\n+\nIIII\n".write(to: fastqURL, atomically: true, encoding: .utf8)
            var metadata = PersistedFASTQMetadata()
            FASTQBatchImporter.applyConfirmedPlatformMetadata(to: &metadata, platform: platform)
            FASTQMetadataStore.save(metadata, for: fastqURL)
            let sidecar = try Data(contentsOf: FASTQMetadataStore.metadataURL(for: fastqURL))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sidecar) as? [String: Any])
            XCTAssertEqual(object["sequencingPlatform"] as? String, platformSpelling, platform.rawValue)
            XCTAssertEqual(object["assemblyReadType"] as? String, readTypeSpelling, platform.rawValue)
        }

        // A confirmed PacBio import keeps a HiFi read type the user already confirmed.
        var hifi = PersistedFASTQMetadata(assemblyReadType: .pacBioHiFi)
        FASTQBatchImporter.applyConfirmedPlatformMetadata(to: &hifi, platform: .pacbio)
        XCTAssertEqual(hifi.sequencingPlatform, .pacbio)
        XCTAssertEqual(hifi.assemblyReadType, .pacBioHiFi)
    }

    func testAssemblyReadTypeForEachImportPlatform() {
        let expected: [(WorkflowPlatform, AssemblyReadType?)] = [
            (.illumina, .illuminaShortReads),
            (.ont, .ontReads),
            (.pacbio, nil),
            (.ultima, nil),
        ]
        XCTAssertEqual(expected.map(\.0), WorkflowPlatform.allCases)
        for (platform, readType) in expected {
            XCTAssertEqual(AssemblyReadType.detect(fromWorkflowPlatform: platform), readType, platform.rawValue)
        }
    }

    func testBAMInputIsAcceptedForONTAndUnknownOnly() async {
        let pair = SamplePair(sampleName: "reads", r1: URL(fileURLWithPath: "/tmp/reads.bam"), r2: nil)
        for platform in LungfishIO.SequencingPlatform.allCases {
            let accepted = platform == .oxfordNanopore || platform == .unknown
            do {
                try ONTBAMImportMaterializer.checkPlatform(platform, for: pair)
                XCTAssertTrue(accepted, "A \(platform.rawValue) BAM import must be rejected")
            } catch {
                XCTAssertFalse(accepted, platform.rawValue)
                let expected = platform == .pacbio ? "PacBio BAM import is not supported" : "only for Oxford Nanopore"
                XCTAssertTrue(error.localizedDescription.contains(expected), platform.rawValue)
            }
        }
    }

    // MARK: - Header detection

    /// One detector. The import detector this table once compared is gone,
    /// and `lungfish-cli import fastq`, the app and every consumer call
    /// `PlatformInference` (pinned in LungfishIOTests/PlatformInferenceTests).
    /// Each row gives the platform one header alone names.
    private static let headerDetections: [(label: String, header: String, io: LungfishIO.SequencingPlatform?)] = [
        (
            "MinKNOW header with every key",
            "@0a1b2c3d-4e5f-6789-abcd-ef0123456789 runid=8a9b0c1d2e3f405162738495a6b7c8d9e0f1a2b3 sampleid=s1 read=12 ch=34 start_time=2023-05-01T10:20:30Z flow_cell_id=FAW12345 protocol_group_id=run1 sample_id=s1 barcode=barcode01 basecall_model_version_id=dna_r10.4.1_e8.2_400bps_sup@v4.2.0",
            .oxfordNanopore
        ),
        (
            "Guppy header with start_time and flow_cell_id",
            "@0a1b2c3d-4e5f-6789-abcd-ef0123456789 runid=8a9b0c1d read=12 ch=34 start_time=2019-05-01T10:20:30Z flow_cell_id=FAK12345",
            .oxfordNanopore
        ),
        ("ONT header with runid only", "@d3ef25a0-5d5c-4a5f-8c3b-12345abcdef runid=abc123 sampleid=sample1", .oxfordNanopore),
        ("basecall_gpu key only", "@read1 basecall_gpu=Tesla_V100", .oxfordNanopore),
        ("start_time without flow_cell_id", "@read1 start_time=2019-05-01T10:20:30Z", nil),
        (
            "dorado SAM tags in the header",
            "@0a1b2c3d-4e5f-6789-abcd-ef0123456789\tqs:f:12.5\tdu:f:3.2\tns:i:16000\tch:i:123\tst:Z:2023-05-01T10:20:30.000+00:00\tRG:Z:8a9b0c1d_dna_r10.4.1_e8.2_400bps_sup@v4.2.0",
            .oxfordNanopore
        ),
        ("PacBio Sequel CCS", "@m64011_190830_220126/101/ccs", .pacbio),
        ("PacBio Revio CCS", "@m84011_220902_175841_s1/12345/ccs", .pacbio),
        ("PacBio by-strand CCS", "@m64011_190830_220126/101/ccs/fwd", .pacbio),
        ("PacBio subread", "@m54006_160504_020705/4194370/0_3920", .pacbio),
        ("zmw anywhere in the header", "@read_zmw_123", nil),
        ("Illumina CASAVA 1.8 with comment", "@A00488:61:HMLGNDSXX:4:1101:1234:5678 1:N:0:ACGTACGT", .illumina),
        ("Illumina CASAVA 1.8 without @", "A00488:61:HMLGNDSXX:4:1101:1234:5678", .illumina),
        ("Illumina MiSeq flow cell with a dash", "@M00123:45:000000000-ABCDE:1:1101:15589:1333 1:N:0:1", .illumina),
        ("Illumina pre-1.8", "@HWUSI-EAS100R:6:73:941:1973#0/1", .illumina),
        ("SRA spot name", "@SRR12345678.1 1 length=150", nil),
        ("SRA spot with original Illumina name", "@SRR6750055.1 A00123:8:H5YNKDSXX:1:1101:1000:1000 length=151", .illumina),
        ("seven non-numeric colon fields", "@a:b:c:d:e:f:g", nil),
        ("seven numeric colon fields", "@sample:1:2:3:4:5:6", .illumina),
        ("MGI DNBSEQ", "@V350012345L1C001R00100000001/1", .mgi),
        ("generic read name", "@read1 some random format", nil),
        ("empty", "", nil),
        ("bare @", "@", nil),
    ]

    func testHeaderDetectionUsesTheSharedDetector() {
        for row in Self.headerDetections {
            XCTAssertEqual(LungfishIO.SequencingPlatform.detect(fromHeader: row.header), row.io, row.label)
            XCTAssertEqual(PlatformInference.infer(fromHeader: row.header).isActionable, row.io != nil, row.label)
        }
    }

    // MARK: - Recipes

    func testRecipesSpellPlatformsWithTheImportSpelling() throws {
        let json = """
        {"formatVersion":1,"id":"pin","name":"Pin","platforms":["illumina","ont","pacbio","ultima"],"requiredInput":"any","steps":[]}
        """
        let decoded = try JSONDecoder().decode(Recipe.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.platforms, [.illumina, .ont, .pacbio, .ultima])

        let recipe = Recipe(id: "pin", name: "Pin", platforms: WorkflowPlatform.allCases, steps: [])
        let encoded = try JSONEncoder().encode(recipe)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["platforms"] as? [String], ["illumina", "ont", "pacbio", "ultima"])

        // The canonical LungfishIO spellings are not recipe platforms.
        for spelling in ["oxfordNanopore", "ONT", "element", "mgi", "unknown"] {
            let rejected = """
            {"formatVersion":1,"id":"pin","name":"Pin","platforms":["\(spelling)"],"requiredInput":"any","steps":[]}
            """
            XCTAssertThrowsError(try JSONDecoder().decode(Recipe.self, from: Data(rejected.utf8)), spelling)
        }

        XCTAssertEqual(Recipe(id: "pin", name: "Pin", steps: []).platforms, [.illumina])
    }

    func testBuiltInRecipesListIllumina() {
        let ids = ["illumina-amplicon-merge", "vsp2-target-enrichment", "wastewater-metagenomics"]
        let builtins = RecipeRegistryV2.builtinRecipes()
        for id in ids {
            let recipe = builtins.first { $0.id == id }
            XCTAssertNotNil(recipe, id)
            XCTAssertEqual(recipe?.platforms.map(\.rawValue), ["illumina"], id)
        }
    }

    // MARK: - Demultiplex plans

    func testDemultiplexStepSpellsSourcePlatformCanonically() throws {
        for platform in LungfishIO.SequencingPlatform.allCases {
            let step = DemultiplexStep(label: "Pin", barcodeKitID: "kit", sourcePlatform: platform)
            let encoded = try JSONEncoder().encode(step)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertEqual(object["sourcePlatform"] as? String, platform.rawValue)

            object["sourcePlatform"] = platform.rawValue
            let reencoded = try JSONSerialization.data(withJSONObject: object)
            XCTAssertEqual(try JSONDecoder().decode(DemultiplexStep.self, from: reencoded).sourcePlatform, platform)
        }

        let unset = try JSONEncoder().encode(DemultiplexStep(label: "Pin", barcodeKitID: "kit"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: unset) as? [String: Any])
        XCTAssertNil(object["sourcePlatform"])

        object["sourcePlatform"] = "ont"
        let importSpelling = try JSONSerialization.data(withJSONObject: object)
        // Tolerant platform decoding: an unrecognised spelling reads as unknown.
        XCTAssertEqual(try JSONDecoder().decode(DemultiplexStep.self, from: importSpelling).sourcePlatform, .unknown)
    }

    // MARK: - End to end

    func testONTImportRecordsBothSpellings() async throws {
        let root = try TestTempDirectory.make(prefix: "workflow-platform-pin-import")
        defer { TestTempDirectory.cleanup(root) }
        let sourceDir = root.appendingPathComponent("source", isDirectory: true)
        let projectURL = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let reads = sourceDir.appendingPathComponent("Nano.fastq.gz")
        try "@0a1b2c3d-4e5f-6789-abcd-ef0123456789 runid=abc123 read=1 ch=1\nACGTACGT\n+\nIIIIIIII\n"
            .write(to: reads, atomically: true, encoding: .utf8)

        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: projectURL,
            platform: .ont,
            recipe: nil,
            qualityBinning: QualityBinningScheme.none,
            threads: 1
        )
        let result = await FASTQBatchImporter.runBatchImport(
            pairs: [SamplePair(sampleName: "Nano", r1: reads, r2: nil)],
            config: config,
            log: nil
        )
        XCTAssertEqual(result.completed, 1, "Import should succeed. Errors: \(result.errors)")

        let bundleURL = projectURL
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent("Nano.lungfishfastq", isDirectory: true)
        let provenanceURL = bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let provenanceData = PortablePath.resolveJSON(try Data(contentsOf: provenanceURL), forFileAt: provenanceURL)
        let envelope = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: provenanceData)

        // Provenance and the replay command carry the import spelling. The
        // default is auto, which infers the platform, never Illumina.
        XCTAssertEqual(envelope.options.explicit["platform"], .string("ont"))
        XCTAssertEqual(envelope.options.explicit["platformSource"], .string("given"))
        XCTAssertEqual(envelope.options.defaults["platform"], .string("auto"))
        XCTAssertEqual(envelope.options.defaults["optimizeStorage"], .boolean(false))
        XCTAssertEqual(envelope.options.defaults["clumpingTool"], .string("none"))
        XCTAssertEqual(envelope.options.defaults["compressionLevel"], .string("balanced"))
        XCTAssertEqual(envelope.options.defaults["qualityBinning"], .string("none"))
        let flag = try XCTUnwrap(envelope.argv.firstIndex(of: "--platform"))
        XCTAssertEqual(envelope.argv[flag + 1], "ont")

        // The FASTQ sidecar carries the canonical LungfishIO spelling.
        let fastqURL = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL))
        let sidecar = try Data(contentsOf: FASTQMetadataStore.metadataURL(for: fastqURL))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sidecar) as? [String: Any])
        XCTAssertEqual(object["sequencingPlatform"] as? String, "oxfordNanopore")
        XCTAssertEqual(object["assemblyReadType"] as? String, "ontReads")
    }
}
