import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class ONTBarcodeDemuxGenotypingPipelineTests: XCTestCase {
    func testRequestDefaultsAnalysisNameToOutputBasenameAndAvoidsDuplicateWorkbookSuffix() {
        let request = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURL: URL(fileURLWithPath: "/data/barcode08.lungfishfastq"),
            referenceSourceURL: URL(fileURLWithPath: "/data/reference.lungfishref"),
            barcodeDefinitionsURL: URL(fileURLWithPath: "/data/fluidigm_barcode8.txt"),
            outputDirectory: URL(fileURLWithPath: "/tmp/out", isDirectory: true),
            outputName: "barcode08-mhc",
            comparisonWorkbookURL: URL(fileURLWithPath: "/data/pbaa.xlsx")
        )

        XCTAssertEqual(request.analysisName, "barcode08-mhc")
        XCTAssertEqual(request.workbookURL.lastPathComponent, "barcode08-mhc_vs_Illumina-31262.xlsx")
    }

    func testRequestArgvRecordsRerunnableCLIArguments() {
        let request = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURL: URL(fileURLWithPath: "/data/barcode08.lungfishfastq"),
            referenceSourceURL: URL(fileURLWithPath: "/data/reference.lungfishref"),
            barcodeDefinitionsURL: URL(fileURLWithPath: "/data/fluidigm_barcode8.txt"),
            outputDirectory: URL(fileURLWithPath: "/tmp/out", isDirectory: true),
            outputName: "barcode08-mhc",
            demuxManifestURL: URL(fileURLWithPath: "/data/barcode08.lungfishfastq/demux-manifest.json"),
            analysisName: "ONT08",
            comparisonWorkbookURL: URL(fileURLWithPath: "/data/pbaa.xlsx"),
            comparisonName: "Illumina-31262",
            threads: 14,
            sortThreads: 4,
            minSupport: 2,
            haplotypeAssayID: "MHC-exon2-miSeq",
            haplotypeDefinitionSetID: "MHC-exon2-miSeq.rhesus-macaques",
            extraArguments: ["-N", "50"]
        )

        XCTAssertEqual(request.reportCSVURL.lastPathComponent, "barcode08-mhc.retained-demux-genotypes.csv")
        XCTAssertEqual(request.sampleSummaryCSVURL.lastPathComponent, "barcode08-mhc.retained-demux-samples.csv")
        XCTAssertEqual(request.workbookURL.lastPathComponent, "barcode08-mhc_ONT08_vs_Illumina-31262.xlsx")
        XCTAssertEqual(request.retainedBAMURL.lastPathComponent, "barcode08-mhc.retained.demuxed.bam")
        XCTAssertTrue(request.argv.contains("genotype"))
        XCTAssertEqual(try testValue(after: "--mode", in: request.argv), "ont-barcode-demux")
        XCTAssertEqual(try testValue(after: "--read-type", in: request.argv), "ont")
        XCTAssertTrue(request.argv.contains("--analysis-name"))
        XCTAssertTrue(request.argv.contains("ONT08"))
        XCTAssertTrue(request.argv.contains("--comparison-workbook"))
        XCTAssertTrue(request.argv.contains("/data/pbaa.xlsx"))
        XCTAssertTrue(request.argv.contains("--comparison-name"))
        XCTAssertTrue(request.argv.contains("Illumina-31262"))
        XCTAssertEqual(try testValue(after: "--haplotype-assay", in: request.argv), "MHC-exon2-miSeq")
        XCTAssertEqual(
            try testValue(after: "--haplotype-definition", in: request.argv),
            "MHC-exon2-miSeq.rhesus-macaques"
        )
        XCTAssertFalse(request.argv.contains("--require-both-end-softclips"))
        XCTAssertFalse(request.argv.contains("--require-full-reference-span"))
        XCTAssertFalse(request.argv.contains("--allow-indels"))
        XCTAssertFalse(request.argv.contains("--max-mismatches"))
        XCTAssertFalse(request.argv.contains("--demux-retained-reads-only"))
        XCTAssertTrue(request.argv.contains("--extra-args"))
        XCTAssertTrue(request.argv.contains("-N 50"))
    }

    func testRequestDefinesSaneWorkbookNameWithoutComparison() {
        let request = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURL: URL(fileURLWithPath: "/data/barcode08.lungfishfastq"),
            referenceSourceURL: URL(fileURLWithPath: "/data/reference.lungfishref"),
            barcodeDefinitionsURL: URL(fileURLWithPath: "/data/fluidigm_barcode8.txt"),
            outputDirectory: URL(fileURLWithPath: "/tmp/out", isDirectory: true),
            outputName: "barcode08 mhc retained",
            analysisName: "ONT 08"
        )

        XCTAssertEqual(request.outputName, "barcode08-mhc-retained")
        XCTAssertEqual(request.analysisName, "ONT08")
        XCTAssertEqual(request.workbookURL.lastPathComponent, "barcode08-mhc-retained_ONT08.xlsx")
        XCTAssertFalse(request.argv.contains("--comparison-workbook"))
    }

    func testRunWritesCompleteCanonicalProvenanceEnvelope() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let condaRoot = root.appendingPathComponent("conda", isDirectory: true)
        let bundledMicromamba = try makeFakeONTGenotypingCondaRoot(at: condaRoot)

        let inputFASTQ = root.appendingPathComponent("barcode08.fastq")
        let barcodeDefinitions = root.appendingPathComponent("barcodes.csv")
        let demuxManifest = root.appendingPathComponent("demux-manifest.json")
        let outputDirectory = root.appendingPathComponent("barcode08.lungfishgenotype", isDirectory: true)
        // Definitions are now project-scoped `.lungfishmhcref` bundles (no compiled-in
        // built-ins), so the assay-scoped definition the provenance envelope records is
        // resolved from a bundle whose reference FASTA also drives mapping.
        let referenceBundle = try makeMHCReferenceBundle(
            root: root,
            definition: Self.mhcDefinition(
                id: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
                assayID: "MHC-exon2-miSeq"
            )
        )
        try "@r0\nACGT\n+\nIIII\n".write(to: inputFASTQ, atomically: true, encoding: .utf8)
        try "sample,barcode\nDW472,ACGT\n".write(to: barcodeDefinitions, atomically: true, encoding: .utf8)
        try #"{"sampleTotals":{"DW472":1},"totalInputReads":1}"#.write(to: demuxManifest, atomically: true, encoding: .utf8)

        let request = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURL: inputFASTQ,
            referenceSourceURL: referenceBundle,
            barcodeDefinitionsURL: barcodeDefinitions,
            outputDirectory: outputDirectory,
            outputName: "barcode08-mhc",
            demuxManifestURL: demuxManifest,
            analysisName: nil,
            threads: 2,
            sortThreads: 1,
            minSupport: 1,
            haplotypeAssayID: "MHC-exon2-miSeq",
            haplotypeDefinitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            extraArguments: ["-N", "5"]
        )

        let result = try await ONTBarcodeDemuxGenotypingPipeline(
            condaManager: CondaManager(
                rootPrefix: condaRoot,
                bundledMicromambaProvider: { bundledMicromamba },
                bundledMicromambaVersionProvider: { "test-micromamba" }
            )
        ).run(request)

        XCTAssertEqual(result.provenanceURL.lastPathComponent, ProvenanceRecorder.provenanceFilename)

        let provenance = try jsonObject(at: request.provenanceURL)
        XCTAssertEqual(provenance["toolName"] as? String, "lungfish fastq genotype")
        XCTAssertEqual(provenance["workflowName"] as? String, "ONT Barcode Demux Genotyping")
        XCTAssertNotNil(provenance["toolVersion"] as? String)
        XCTAssertNotNil(provenance["workflowVersion"] as? String)
        XCTAssertEqual(provenance["argv"] as? [String], request.argv)
        XCTAssertEqual(provenance["durableReplayArgv"] as? [String], request.argv)

        let options = try XCTUnwrap(provenance["options"] as? [String: Any])
        XCTAssertEqual(options["inputFASTQ"] as? String, inputFASTQ.standardizedFileURL.path)
        XCTAssertEqual(options["outputDirectory"] as? String, outputDirectory.standardizedFileURL.path)
        XCTAssertEqual(options["threads"] as? Int, 2)
        XCTAssertEqual(options["sortThreads"] as? Int, 1)
        XCTAssertEqual(options["minSupport"] as? Int, 1)
        XCTAssertEqual(options["mappingPreset"] as? String, "map-ont")
        XCTAssertEqual(options["haplotypeAssayID"] as? String, "MHC-exon2-miSeq")
        XCTAssertEqual(options["haplotypeDefinitionSetID"] as? String, "MHC-exon2-miSeq.mauritian-cynomolgus-macaques")
        XCTAssertNotNil(options["haplotypeDefinitionSHA256"] as? String)
        XCTAssertEqual(options["extraArguments"] as? [String], ["-N", "5"])
        let defaults = try XCTUnwrap(provenance["resolvedDefaults"] as? [String: Any])
        XCTAssertEqual(defaults["sortThreads"] as? Int, 4)
        XCTAssertEqual(defaults["minSupport"] as? Int, 1)
        let runtime = try XCTUnwrap(provenance["runtimeIdentity"] as? [String: Any])
        XCTAssertEqual(runtime["condaRoot"] as? String, condaRoot.standardizedFileURL.path)

        let inputs = try XCTUnwrap(provenance["inputs"] as? [[String: Any]])
        XCTAssertTrue(inputs.contains { record in
            record["path"] as? String == inputFASTQ.standardizedFileURL.path
                && record["sha256"] as? String != nil
                && record["sizeBytes"] as? Int != nil
        }, "\(inputs)")
        XCTAssertTrue(inputs.contains { record in
            record["path"] as? String == barcodeDefinitions.standardizedFileURL.path
                && record["sha256"] as? String != nil
                && record["sizeBytes"] as? Int != nil
        }, "\(inputs)")

        let output = try XCTUnwrap(provenance["output"] as? [String: Any])
        XCTAssertEqual(output["path"] as? String, outputDirectory.standardizedFileURL.path)
        XCTAssertEqual(output["role"] as? String, "output")
        let outputs = try XCTUnwrap(provenance["outputs"] as? [[String: Any]])
        XCTAssertTrue(outputs.contains { record in
            record["path"] as? String == result.workbookURL.path
                && record["sha256"] as? String != nil
                && record["sizeBytes"] as? Int != nil
        }, "\(outputs)")
        XCTAssertFalse(outputs.contains { ($0["path"] as? String)?.hasSuffix(".bam") == true }, "\(outputs)")
        XCTAssertFalse(outputs.contains { ($0["path"] as? String)?.hasSuffix(".bam.bai") == true }, "\(outputs)")
        XCTAssertTrue(inputs.contains { record in
            record["role"] as? String == "haplotype-definition"
                && record["sha256"] as? String != nil
                && record["sizeBytes"] as? Int != nil
        }, "\(inputs)")
        let files = try XCTUnwrap(provenance["files"] as? [[String: Any]])
        XCTAssertTrue(files.contains { $0["path"] as? String == inputFASTQ.standardizedFileURL.path })
        XCTAssertTrue(files.contains { $0["path"] as? String == result.workbookURL.path })
        XCTAssertEqual(provenance["exitStatus"] as? Int, 0)
        XCTAssertNotNil(provenance["wallTimeSeconds"] as? Double)

        let steps = try XCTUnwrap(provenance["steps"] as? [[String: Any]])
        XCTAssertFalse(steps.isEmpty)
        XCTAssertTrue(steps.allSatisfy { $0["exitStatus"] as? Int == 0 })
        XCTAssertTrue(steps.allSatisfy { $0["wallTimeSeconds"] as? Double != nil }, "\(steps)")

        let canonicalEnvelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: outputDirectory))
        XCTAssertEqual(canonicalEnvelope.workflowName, "ONT Barcode Demux Genotyping")
        XCTAssertEqual(canonicalEnvelope.toolName, "lungfish fastq genotype")
        XCTAssertEqual(canonicalEnvelope.argv, request.argv)
        XCTAssertEqual(canonicalEnvelope.durableReplayArgv, request.argv)
        XCTAssertEqual(canonicalEnvelope.options.explicit["inputFASTQ"], .string(inputFASTQ.standardizedFileURL.path))
        XCTAssertEqual(canonicalEnvelope.options.explicit["outputDirectory"], .string(outputDirectory.standardizedFileURL.path))
        XCTAssertEqual(canonicalEnvelope.options.explicit["threads"], .integer(2))
        XCTAssertEqual(canonicalEnvelope.options.explicit["haplotypeAssayID"], .string("MHC-exon2-miSeq"))
        XCTAssertEqual(
            canonicalEnvelope.options.explicit["haplotypeDefinitionSetID"],
            .string("MHC-exon2-miSeq.mauritian-cynomolgus-macaques")
        )
        XCTAssertNotNil(canonicalEnvelope.options.explicit["haplotypeDefinitionSHA256"])
        XCTAssertEqual(canonicalEnvelope.options.resolvedDefaults["sortThreads"], .integer(4))
        XCTAssertEqual(canonicalEnvelope.options.resolvedDefaults["minSupport"], .integer(1))
        XCTAssertEqual(canonicalEnvelope.output?.path, outputDirectory.standardizedFileURL.path)
        XCTAssertEqual(canonicalEnvelope.output?.role, .output)
        XCTAssertTrue(canonicalEnvelope.files.contains { descriptor in
            descriptor.path == inputFASTQ.standardizedFileURL.path
                && descriptor.checksumSHA256 != nil
                && descriptor.fileSize != nil
        }, "\(canonicalEnvelope.files)")
        XCTAssertTrue(canonicalEnvelope.outputs.contains { descriptor in
            descriptor.path == result.workbookURL.path
                && descriptor.checksumSHA256 != nil
                && descriptor.fileSize != nil
        }, "\(canonicalEnvelope.outputs)")
        XCTAssertFalse(canonicalEnvelope.outputs.contains { $0.path.hasSuffix(".bam") }, "\(canonicalEnvelope.outputs)")
        XCTAssertFalse(canonicalEnvelope.outputs.contains { $0.path.hasSuffix(".bam.bai") }, "\(canonicalEnvelope.outputs)")
        XCTAssertTrue(canonicalEnvelope.steps.contains { step in
            step.outputs.contains { descriptor in
                descriptor.path == request.mappingBAMURL.path
                    && descriptor.checksumSHA256 != nil
                    && descriptor.fileSize != nil
            }
        }, "\(canonicalEnvelope.steps)")
        XCTAssertTrue(canonicalEnvelope.steps.contains { step in
            step.outputs.contains { descriptor in
                descriptor.path == request.retainedBAMURL.path
                    && descriptor.checksumSHA256 != nil
                    && descriptor.fileSize != nil
            }
        }, "\(canonicalEnvelope.steps)")
        for url in [
            request.mappingBAMURL,
            request.mappingBAIURL,
            request.retainedBAMURL,
            request.retainedBAIURL,
        ] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: url.path),
                "Regenerable ONT genotyping BAM intermediate should be removed: \(url.path)"
            )
        }
        XCTAssertTrue(canonicalEnvelope.files.contains { descriptor in
            descriptor.path.hasSuffix("haplotype-definition.json")
                && descriptor.checksumSHA256 != nil
                && descriptor.fileSize != nil
        }, "\(canonicalEnvelope.files)")
        XCTAssertEqual(canonicalEnvelope.exitStatus, 0)
        XCTAssertNotNil(canonicalEnvelope.wallTimeSeconds)
        XCTAssertFalse(canonicalEnvelope.steps.isEmpty)
        XCTAssertTrue(canonicalEnvelope.steps.allSatisfy { $0.exitStatus == 0 })
        XCTAssertTrue(canonicalEnvelope.steps.allSatisfy { $0.wallTimeSeconds != nil }, "\(canonicalEnvelope.steps)")
    }

    func testAutoModeWithBarcodesAndMultipleInputsUsesONTPresetAndAllInputs() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let condaRoot = root.appendingPathComponent("conda", isDirectory: true)
        let bundledMicromamba = try makeFakeONTGenotypingCondaRoot(at: condaRoot)

        let firstFASTQ = root.appendingPathComponent("barcode10.fastq")
        let secondFASTQ = root.appendingPathComponent("barcode11.fastq")
        let referenceFASTA = root.appendingPathComponent("reference.fa")
        let barcodeDefinitions = root.appendingPathComponent("barcodes.csv")
        let demuxManifest = root.appendingPathComponent("demux-manifest.json")
        let outputDirectory = root.appendingPathComponent("combined-mhc.lungfishgenotype", isDirectory: true)
        try "@r0\nACGT\n+\nIIII\n".write(to: firstFASTQ, atomically: true, encoding: .utf8)
        try "@r1\nACGT\n+\nIIII\n".write(to: secondFASTQ, atomically: true, encoding: .utf8)
        try ">allele1\nACGT\n".write(to: referenceFASTA, atomically: true, encoding: .utf8)
        try "sample,barcode\nDW472,ACGT\n".write(to: barcodeDefinitions, atomically: true, encoding: .utf8)
        try #"{"sampleTotals":{"DW472":2},"totalInputReads":2}"#.write(to: demuxManifest, atomically: true, encoding: .utf8)

        let request = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURLs: [firstFASTQ, secondFASTQ],
            referenceSourceURL: referenceFASTA,
            barcodeDefinitionsURL: barcodeDefinitions,
            outputDirectory: outputDirectory,
            outputName: "combined-mhc",
            demuxManifestURL: demuxManifest,
            threads: 2,
            sortThreads: 1
        )

        let result = try await ONTBarcodeDemuxGenotypingPipeline(
            condaManager: CondaManager(
                rootPrefix: condaRoot,
                bundledMicromambaProvider: { bundledMicromamba },
                bundledMicromambaVersionProvider: { "test-micromamba" }
            )
        ).run(request)

        let provenance = try jsonObject(at: request.provenanceURL)
        let options = try XCTUnwrap(provenance["options"] as? [String: Any])
        XCTAssertEqual(options["resolvedMode"] as? String, AmpliconGenotypingMode.ontBarcodeDemux.rawValue)
        XCTAssertEqual(options["resolvedReadType"] as? String, AmpliconGenotypingReadType.ont.rawValue)
        XCTAssertEqual(options["mappingPreset"] as? String, "map-ont")
        XCTAssertEqual(options["inputFASTQs"] as? [String], [
            firstFASTQ.standardizedFileURL.path,
            secondFASTQ.standardizedFileURL.path,
        ])
        XCTAssertEqual(provenance["mappingInputFileCount"] as? Int, 2)

        let canonicalEnvelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: outputDirectory))
        XCTAssertEqual(canonicalEnvelope.options.explicit["resolvedMode"], .string("ont-barcode-demux"))
        XCTAssertEqual(canonicalEnvelope.options.explicit["resolvedReadType"], .string("ont"))
        XCTAssertEqual(canonicalEnvelope.options.explicit["mappingPreset"], .string("map-ont"))
        XCTAssertTrue(canonicalEnvelope.files.contains { $0.path == firstFASTQ.standardizedFileURL.path })
        XCTAssertTrue(canonicalEnvelope.files.contains { $0.path == secondFASTQ.standardizedFileURL.path })
        XCTAssertEqual(result.provenanceURL.lastPathComponent, ProvenanceRecorder.provenanceFilename)
    }

    func testRunIlluminaModeConsumesPreparedSampleBundlesWithoutMergingReads() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let condaRoot = root.appendingPathComponent("conda", isDirectory: true)
        let bundledMicromamba = try makeFakeONTGenotypingCondaRoot(at: condaRoot)
        let referenceFASTA = root.appendingPathComponent("reference.fa")
        let outputDirectory = root.appendingPathComponent("miseq-mhc.lungfishgenotype", isDirectory: true)
        try ">allele1\nACGTACGT\n".write(to: referenceFASTA, atomically: true, encoding: .utf8)

        let sampleA = try makeMergedFASTQBundle(
            root: root,
            name: "DW001",
            sequence: "ACGTACGT"
        )
        let sampleB = try makeMergedFASTQBundle(
            root: root,
            name: "DW002",
            sequence: "ACGTACGT"
        )

        let request = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURLs: [sampleA.bundleURL, sampleB.bundleURL],
            referenceSourceURL: referenceFASTA,
            outputDirectory: outputDirectory,
            outputName: "miseq-mhc",
            analysisName: "MiSeqMHC",
            threads: 2,
            sortThreads: 1,
            minSupport: 1,
            mode: .illuminaPaired,
            readType: .illumina
        )

        let result = try await ONTBarcodeDemuxGenotypingPipeline(
            condaManager: CondaManager(
                rootPrefix: condaRoot,
                bundledMicromambaProvider: { bundledMicromamba },
                bundledMicromambaVersionProvider: { "test-micromamba" }
            )
        ).run(request)

        XCTAssertEqual(result.provenanceURL.lastPathComponent, ProvenanceRecorder.provenanceFilename)
        XCTAssertTrue(request.argv.contains("genotype"))
        XCTAssertEqual(try testValue(after: "--mode", in: request.argv), "illumina-paired")
        XCTAssertEqual(try testValue(after: "--read-type", in: request.argv), "illumina")
        XCTAssertFalse(request.argv.contains("--barcodes"))

        let provenance = try jsonObject(at: request.provenanceURL)
        XCTAssertEqual(provenance["toolName"] as? String, "lungfish fastq genotype")
        XCTAssertEqual(provenance["workflowName"] as? String, "Illumina Paired Amplicon Genotyping")
        let options = try XCTUnwrap(provenance["options"] as? [String: Any])
        XCTAssertEqual(options["resolvedMode"] as? String, "illumina-paired")
        XCTAssertEqual(options["resolvedReadType"] as? String, "illumina")
        XCTAssertEqual(options["mappingPreset"] as? String, "sr")
        XCTAssertEqual(options["requireBothEndSoftclips"] as? Bool, false)
        XCTAssertEqual(options["demuxRetainedReadsOnly"] as? Bool, false)
        XCTAssertTrue(options["illuminaMergeResults"] is NSNull)

        let inputs = try XCTUnwrap(provenance["inputs"] as? [[String: Any]])
        XCTAssertTrue(inputs.contains { $0["path"] as? String == sampleA.fastqURL.standardizedFileURL.path && $0["sha256"] as? String != nil }, "\(inputs)")
        XCTAssertTrue(inputs.contains { $0["path"] as? String == sampleB.fastqURL.standardizedFileURL.path && $0["sha256"] as? String != nil }, "\(inputs)")
        XCTAssertFalse(inputs.contains { ($0["path"] as? String)?.hasSuffix("merge-illumina-pairs.py") == true }, "\(inputs)")
        XCTAssertFalse(inputs.contains { ($0["path"] as? String)?.contains("illumina-merged") == true }, "\(inputs)")
        XCTAssertTrue(inputs.contains { ($0["path"] as? String)?.hasSuffix("illumina-sample-manifest.json") == true }, "\(inputs)")

        let canonicalEnvelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: outputDirectory))
        XCTAssertEqual(canonicalEnvelope.workflowName, "Illumina Paired Amplicon Genotyping")
        XCTAssertEqual(canonicalEnvelope.toolName, "lungfish fastq genotype")
        XCTAssertEqual(canonicalEnvelope.options.explicit["resolvedMode"], .string("illumina-paired"))
        XCTAssertEqual(canonicalEnvelope.options.explicit["resolvedReadType"], .string("illumina"))
        XCTAssertEqual(canonicalEnvelope.options.explicit["illuminaMergeResults"], .null)
        XCTAssertTrue(canonicalEnvelope.files.contains { $0.path == sampleB.fastqURL.standardizedFileURL.path && $0.checksumSHA256 != nil })
        XCTAssertFalse(canonicalEnvelope.files.contains { $0.path.hasSuffix("merge-illumina-pairs.py") })
    }

    func testResolveIlluminaSampleInputsDisambiguatesCollidingSanitizedSampleIDs() async throws {
        let tmp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bundleA = try makeIlluminaFastqBundle(named: "Sample 1", reads: ["rA1", "rA2"], in: tmp)
        let bundleB = try makeIlluminaFastqBundle(named: "Sample_1", reads: ["rB1"], in: tmp)
        let staging = tmp.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let samples = try await ONTBarcodeDemuxGenotypingPipeline
            .resolveIlluminaSampleInputsForTesting(from: [bundleA, bundleB], stagingDirectory: staging)

        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(Set(samples.map(\.sampleID)).count, 2, "Sanitized sample IDs must be unique")
        XCTAssertEqual(Set(samples.map(\.prefixedFASTQURL)).count, 2, "Prefixed FASTQ destinations must be unique")
        XCTAssertEqual(samples.map(\.readCount).reduce(0, +), 3)  // no overwrite: 2 + 1
    }

    func testResolveIlluminaSampleInputsDisambiguatesCollidingStagedFilenames() async throws {
        let tmp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // "Sample-1" and "Sample--1" sanitize to DISTINCT sample IDs (sampleID(from:)
        // collapses runs of "_" but leaves "-" untouched, so the double hyphen
        // survives), yet safeFilenameStem collapses runs of "-" so both yield the
        // identical staged stem "Sample-1". Without independent filename
        // disambiguation the second staged FASTQ overwrites the first and its reads
        // never reach minimap2.
        let bundleA = try makeIlluminaFastqBundle(named: "Sample-1", reads: ["rA1", "rA2"], in: tmp)
        let bundleB = try makeIlluminaFastqBundle(named: "Sample--1", reads: ["rB1"], in: tmp)
        let staging = tmp.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let samples = try await ONTBarcodeDemuxGenotypingPipeline
            .resolveIlluminaSampleInputsForTesting(from: [bundleA, bundleB], stagingDirectory: staging)

        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(Set(samples.map(\.sampleID)).count, 2, "Sanitized sample IDs must be unique")
        XCTAssertEqual(Set(samples.map(\.prefixedFASTQURL)).count, 2, "Staged FASTQ filenames must be unique")
        XCTAssertEqual(samples.map(\.readCount).reduce(0, +), 3)  // no overwrite: 2 + 1
    }

    func testRunRejectsInvalidHaplotypeDefinitionBeforeCreatingOutputs() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let inputFASTQ = root.appendingPathComponent("barcode08.fastq")
        let referenceFASTA = root.appendingPathComponent("reference.fa")
        let barcodeDefinitions = root.appendingPathComponent("barcodes.csv")
        let outputDirectory = root.appendingPathComponent("barcode08.lungfishgenotype", isDirectory: true)
        try "@r0\nACGT\n+\nIIII\n".write(to: inputFASTQ, atomically: true, encoding: .utf8)
        try ">allele1\nACGT\n".write(to: referenceFASTA, atomically: true, encoding: .utf8)
        try "sample,barcode\nDW472,ACGT\n".write(to: barcodeDefinitions, atomically: true, encoding: .utf8)

        let request = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURL: inputFASTQ,
            referenceSourceURL: referenceFASTA,
            barcodeDefinitionsURL: barcodeDefinitions,
            outputDirectory: outputDirectory,
            outputName: "barcode08-mhc",
            haplotypeAssayID: "unsupported-assay",
            haplotypeDefinitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
        )

        do {
            _ = try await ONTBarcodeDemuxGenotypingPipeline().run(request)
            XCTFail("Expected invalid assay-scoped haplotype definition to fail during preflight")
        } catch ONTBarcodeDemuxGenotypingError.invalidHaplotypeDefinitionForAssay(let definitionID, let assayID) {
            XCTAssertEqual(definitionID, "MHC-exon2-miSeq.mauritian-cynomolgus-macaques")
            XCTAssertEqual(assayID, "unsupported-assay")
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputDirectory.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testResolveInputFASTQURLsUsesOriginalPathWhenBundleChunksAreMissing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ont-barcode-demux-resolve-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let bundle = root.appendingPathComponent("barcode08.lungfishfastq", isDirectory: true)
        let chunks = bundle.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunks, withIntermediateDirectories: true)
        let original0 = root.appendingPathComponent("original-0.fastq.gz")
        let original1 = root.appendingPathComponent("original-1.fastq.gz")
        try Data("@r0\nACGT\n+\nIIII\n".utf8).write(to: original0)
        try Data("@r1\nTGCA\n+\nIIII\n".utf8).write(to: original1)
        let copied1 = chunks.appendingPathComponent("copied-1.fastq.gz")
        try Data("@r1\nTGCA\n+\nIIII\n".utf8).write(to: copied1)

        let manifest = FASTQSourceFileManifest(files: [
            .init(
                filename: "chunks/missing-0.fastq.gz",
                originalPath: original0.path,
                sizeBytes: 18,
                isSymlink: false
            ),
            .init(
                filename: "chunks/copied-1.fastq.gz",
                originalPath: original1.path,
                sizeBytes: 18,
                isSymlink: false
            ),
        ])
        try manifest.save(to: bundle)

        let resolved = try ONTBarcodeDemuxGenotypingPipeline.resolveInputFASTQURLs(for: bundle)

        XCTAssertEqual(resolved, [original0.standardizedFileURL, copied1.standardizedFileURL])
    }

    func testResolveInputFASTQURLsAcceptsRawFastqPassDirectoryAndSkipsAppleDoubleFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ont-barcode-demux-fastq-pass-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let fastq0 = root.appendingPathComponent("FBC_pass_barcode08_0.fastq.gz")
        let fastq1 = root.appendingPathComponent("FBC_pass_barcode08_1.fastq.gz")
        let appleDouble = root.appendingPathComponent("._FBC_pass_barcode08_1.fastq.gz")
        try Data("@r0\nACGT\n+\nIIII\n".utf8).write(to: fastq0)
        try Data("@r1\nTGCA\n+\nIIII\n".utf8).write(to: fastq1)
        try Data("not a fastq\n".utf8).write(to: appleDouble)

        let resolved = try ONTBarcodeDemuxGenotypingPipeline.resolveInputFASTQURLs(for: root)

        XCTAssertEqual(resolved, [fastq0.standardizedFileURL, fastq1.standardizedFileURL])
    }

    func testReportWorkbookUsesRunBasenameAndFiltersZeroAlleleRows() throws {
        try XCTSkipIf(!pythonCanImportOpenpyxl(), "openpyxl is required for workbook report verification")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let scriptURL = root.appendingPathComponent("write-report.py")
        let templateURL = root.appendingPathComponent("template.xlsx")
        let genotypesCSV = root.appendingPathComponent("genotypes.csv")
        let samplesCSV = root.appendingPathComponent("samples.csv")
        let statsJSON = root.appendingPathComponent("stats.json")
        let referenceFASTA = root.appendingPathComponent("reference.fa")
        let barcodesCSV = root.appendingPathComponent("barcodes.csv")
        let outputXLSX = root.appendingPathComponent("barcode08-mhc_vs_Illumina-31262.xlsx")
        let provenanceJSON = root.appendingPathComponent("report-provenance.json")

        try ONTBarcodeDemuxGenotypingPipeline.writeReportScript(to: scriptURL)
        try makeMinimalComparisonWorkbook(at: templateURL)
        try """
        sample,genotype,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_reads,overall_unique_retained_percent
        DW472,Mafa_F_01_w_06,7,7,100,7,7.0,100,7,7.0
        unassigned,Mafa_F_01_w_06,3,3,,3,,100,10,10.0
        """.write(to: genotypesCSV, atomically: true, encoding: .utf8)
        try """
        sample,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_percent
        DW472,7,7,100,7.0,100,7.0
        DW473,0,0,100,0.0,100,7.0
        unassigned,3,3,,100.0,100,10.0
        """.write(to: samplesCSV, atomically: true, encoding: .utf8)
        try #"{"passedAlignments":7}"#.write(to: statsJSON, atomically: true, encoding: .utf8)
        try ">Mafa_F_01_w_06\nACGT\n>Mafa_F_02\nACGT\n".write(to: referenceFASTA, atomically: true, encoding: .utf8)
        try "sample,barcode\nDW472,ACGT\nDW473,TGCA\n".write(to: barcodesCSV, atomically: true, encoding: .utf8)

        _ = try runPython([
            scriptURL.path,
            "--genotypes-csv", genotypesCSV.path,
            "--samples-csv", samplesCSV.path,
            "--stats-json", statsJSON.path,
            "--reference-fasta", referenceFASTA.path,
            "--barcode-definitions", barcodesCSV.path,
            "--output-xlsx", outputXLSX.path,
            "--provenance-json", provenanceJSON.path,
            "--analysis-name", "barcode08-mhc",
            "--run-name", "barcode08-mhc",
            "--comparison-workbook", templateURL.path,
            "--comparison-name", "Illumina-31262",
        ])

        let inspection = try inspectWorkbook(outputXLSX)
        XCTAssertEqual(inspection["sheetnames"] as? [String], [
            "barcode08-mhc",
            "Illumina-31262",
            "barcode08-mhc Long Summary",
            "barcode08-mhc Sample Summary",
            "Illumina-31262 Audit",
            "Run Stats",
        ])
        XCTAssertEqual(inspection["readCountLabel"] as? String, "Filtered exact-match read count")
        XCTAssertEqual(inspection["hasTotalReadCountRow"] as? Bool, false)
        XCTAssertEqual(inspection["hasPercentRetainedRow"] as? Bool, false)
        XCTAssertEqual(inspection["haplotypeSampleCellsAreBlank"] as? Bool, true)
        XCTAssertEqual(inspection["commentsSampleCellsAreBlank"] as? Bool, true)
        XCTAssertEqual(inspection["hasKeptAllele"] as? Bool, true)
        XCTAssertEqual(inspection["hasZeroAllele"] as? Bool, false)
        XCTAssertEqual(inspection["hasEmptyLocusHeader"] as? Bool, false)
        XCTAssertEqual(inspection["analysisSampleColumns"] as? [String], ["DW472"])
        XCTAssertEqual(inspection["keptAlleleDW472Count"] as? Int, 7)
        XCTAssertEqual(inspection["readCountTotal"] as? Int, 7)
        XCTAssertEqual(inspection["readCountAverage"] as? Double, 7.0)
        XCTAssertEqual(inspection["keptAlleleSubtotal"] as? Int, 7)
        XCTAssertEqual(inspection["keptAlleleObservedSamples"] as? Int, 1)
        XCTAssertEqual(inspection["formulaCellsInAnalysisSummary"] as? [String], [])
        XCTAssertEqual(inspection["containsUnassignedInWorkbook"] as? Bool, false)
    }

    func testReportWorkbookPopulatesExplicitHaplotypeAnalysis() throws {
        try XCTSkipIf(!pythonCanImportOpenpyxl(), "openpyxl is required for workbook report verification")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let scriptURL = root.appendingPathComponent("write-report.py")
        let genotypesCSV = root.appendingPathComponent("genotypes.csv")
        let samplesCSV = root.appendingPathComponent("samples.csv")
        let statsJSON = root.appendingPathComponent("stats.json")
        let referenceFASTA = root.appendingPathComponent("reference.fa")
        let barcodesCSV = root.appendingPathComponent("barcodes.csv")
        let haplotypesJSON = root.appendingPathComponent("haplotypes.json")
        let outputXLSX = root.appendingPathComponent("barcode08-mhc.xlsx")
        let provenanceJSON = root.appendingPathComponent("report-provenance.json")

        try ONTBarcodeDemuxGenotypingPipeline.writeReportScript(to: scriptURL)
        try """
        sample,genotype,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_reads,overall_unique_retained_percent
        DW472,01_Mafa_A1_063g|A1_063_01,42,42,100,42,42.0,100,42,42.0
        """.write(to: genotypesCSV, atomically: true, encoding: .utf8)
        try """
        sample,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_percent
        DW472,42,42,100,42.0,100,42.0
        """.write(to: samplesCSV, atomically: true, encoding: .utf8)
        try #"{"passedAlignments":42}"#.write(to: statsJSON, atomically: true, encoding: .utf8)
        try ">01_Mafa_A1_063g|A1_063_01\nACGT\n".write(to: referenceFASTA, atomically: true, encoding: .utf8)
        try "sample,barcode\nDW472,ACGT\n".write(to: barcodesCSV, atomically: true, encoding: .utf8)
        try """
        {
          "schemaVersion": 1,
          "assayID": "MHC-exon2-miSeq",
          "definitionSetID": "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
          "definitionSetName": "Mauritian cynomolgus macaques",
          "speciesName": "Mauritian cynomolgus macaques",
          "samples": [
            {
              "sample": "DW472",
              "calls": [
                {
                  "locus": "MHC-A",
                  "sourceLocus": "Mafa-A",
                  "haplotype1": "M1A",
                  "haplotype2": "-",
                  "status": "called",
                  "matchedHaplotypes": [{"name": "M1A", "diagnosticAlleles": ["A1_063"], "observedDiagnosticAlleles": ["A1_063"]}],
                  "observedGenotypeCount": 1,
                  "observedGenotypes": ["01_Mafa_A1_063g|A1_063_01"],
                  "notes": ""
                },
                {
                  "locus": "MHC-DQ",
                  "sourceLocus": "Mafa-DQ",
                  "haplotype1": "M1DQ",
                  "haplotype2": "M2DQ",
                  "status": "called",
                  "matchedHaplotypes": [{"name": "M1DQ", "diagnosticAlleles": ["DQA1_01", "DQB1_01"], "observedDiagnosticAlleles": ["DQA1_01", "DQB1_01"]}],
                  "observedGenotypeCount": 2,
                  "observedGenotypes": ["14_M1_DQA1_01_04", "15_M1_DQB1_01_01"],
                  "notes": ""
                }
              ]
            }
          ]
        }
        """.write(to: haplotypesJSON, atomically: true, encoding: .utf8)

        _ = try runPython([
            scriptURL.path,
            "--genotypes-csv", genotypesCSV.path,
            "--samples-csv", samplesCSV.path,
            "--stats-json", statsJSON.path,
            "--reference-fasta", referenceFASTA.path,
            "--barcode-definitions", barcodesCSV.path,
            "--output-xlsx", outputXLSX.path,
            "--provenance-json", provenanceJSON.path,
            "--analysis-name", "barcode08-mhc",
            "--run-name", "barcode08-mhc",
            "--haplotype-analysis-json", haplotypesJSON.path,
        ])

        let inspection = try inspectHaplotypeWorkbook(outputXLSX)
        XCTAssertTrue((inspection["sheetnames"] as? [String])?.contains("Haplotype Calls") ?? false)
        XCTAssertEqual(inspection["mhcAHaplotype1"] as? String, "M1A")
        XCTAssertEqual(inspection["mhcAHaplotype2"] as? String, "-")
        XCTAssertEqual(inspection["mhcDQHaplotype1"] as? String, "M1DQ")
        XCTAssertEqual(inspection["mhcDQHaplotype2"] as? String, "M2DQ")
        XCTAssertEqual(inspection["haplotypeSheetRows"] as? Int, 3)
        XCTAssertEqual(inspection["provenanceIncludesHaplotypes"] as? Bool, true)
    }

    private func pythonCanImportOpenpyxl() -> Bool {
        (try? runPython(["-c", "import openpyxl"])) != nil
    }

    private func makeMinimalComparisonWorkbook(at url: URL) throws {
        let code = #"""
import sys
from openpyxl import Workbook
from openpyxl.styles import Font

path = sys.argv[1]
wb = Workbook()
ws = wb.active
ws.title = "31262_MiSeq255_Kenyon20_pivot"
values = {
    (1, 1): "Animal ID", (1, 4): "Animal A", (1, 5): "Animal B",
    (2, 1): "GS ID", (2, 2): "Total", (2, 3): "Average", (2, 4): "DW472", (2, 5): "DW473",
    (3, 1): "Mapped Read Count", (3, 2): "=SUM(D3:E3)", (3, 3): "=AVERAGE(D3:E3)", (3, 4): 10, (3, 5): 20,
    (4, 1): "total_read_count", (4, 4): 100, (4, 5): 100,
    (5, 1): "percent_reads_unmapped", (5, 4): 90, (5, 5): 80,
    (6, 1): "MHC-A Haplotype 1", (6, 4): "M1A", (6, 5): "M2A",
    (7, 1): "MHC-A Haplotype 2", (7, 4): "M1A", (7, 5): "M2A",
    (8, 1): "MHC-B Haplotype 1", (9, 1): "MHC-B Haplotype 2",
    (10, 1): "MHC-DRB Haplotype 1", (11, 1): "MHC-DRB Haplotype 2",
    (12, 1): "MHC-DQA Haplotype 1", (13, 1): "MHC-DQA Haplotype 2",
    (14, 1): "MHC-DQB Haplotype 1", (15, 1): "MHC-DQB Haplotype 2",
    (16, 1): "MHC-DPA Haplotype 1", (17, 1): "MHC-DPA Haplotype 2",
    (18, 1): "MHC-DPB Haplotype 1", (19, 1): "MHC-DPB Haplotype 2",
    (20, 1): "Comments", (20, 2): "Subtotal", (20, 3): "# Obs.", (20, 4): "template comment",
    (21, 1): "Mafa-F alleles",
    (22, 1): "01_M1_F_01_w_06", (22, 2): "=SUM(D22:E22)", (22, 3): "=COUNT(D22:E22)",
    (23, 1): "01_M2_F_02", (23, 2): "=SUM(D23:E23)", (23, 3): "=COUNT(D23:E23)",
    (24, 1): "Mafa-G alleles",
    (25, 1): "02_M1_G_01", (25, 2): "=SUM(D25:E25)", (25, 3): "=COUNT(D25:E25)",
}
for (row, col), value in values.items():
    ws.cell(row, col).value = value
for row in [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,24]:
    ws.cell(row, 1).font = Font(bold=True)
wb.save(path)
"""#
        _ = try runPython(["-c", code, url.path])
    }

    private func inspectWorkbook(_ url: URL) throws -> [String: Any] {
        let code = #"""
import json
import sys
from openpyxl import load_workbook

wb = load_workbook(sys.argv[1], data_only=False)
ws = wb[wb.sheetnames[0]]

def row_for(label):
    for row in range(1, ws.max_row + 1):
        if ws.cell(row, 1).value == label:
            return row
    return None

kept = row_for("01_M1_F_01_w_06")
hap = row_for("MHC-A Haplotype 1")
comments = row_for("Comments")
payload = {
    "sheetnames": wb.sheetnames,
    "readCountLabel": ws.cell(3, 1).value,
    "hasTotalReadCountRow": row_for("total_read_count") is not None,
    "hasPercentRetainedRow": row_for("percent_reads_retained_after_filtering") is not None,
    "haplotypeSampleCellsAreBlank": all(ws.cell(hap, col).value is None for col in range(4, 6)) if hap else False,
    "commentsSampleCellsAreBlank": all(ws.cell(comments, col).value is None for col in range(4, 6)) if comments else False,
    "hasKeptAllele": kept is not None,
    "hasZeroAllele": row_for("01_M2_F_02") is not None,
    "hasEmptyLocusHeader": row_for("Mafa-G alleles") is not None,
    "analysisSampleColumns": [
        ws.cell(2, col).value
        for col in range(4, ws.max_column + 1)
        if ws.cell(2, col).value is not None
    ],
    "keptAlleleDW472Count": ws.cell(kept, 4).value if kept else None,
    "readCountTotal": ws.cell(3, 2).value,
    "readCountAverage": ws.cell(3, 3).value,
    "keptAlleleSubtotal": ws.cell(kept, 2).value if kept else None,
    "keptAlleleObservedSamples": ws.cell(kept, 3).value if kept else None,
    "formulaCellsInAnalysisSummary": [
        f"{cell.coordinate}:{cell.value}"
        for row in ws.iter_rows()
        for cell in row
        if isinstance(cell.value, str) and cell.value.startswith("=")
    ],
    "containsUnassignedInWorkbook": any(
        str(cell.value).strip().lower() == "unassigned"
        for sheet in wb.worksheets
        for row in sheet.iter_rows()
        for cell in row
        if cell.value is not None
    ),
}
print(json.dumps(payload))
"""#
        let output = try runPython(["-c", code, url.path])
        let data = Data(output.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    private func inspectHaplotypeWorkbook(_ url: URL) throws -> [String: Any] {
        let code = #"""
import json
import os
import sys
from openpyxl import load_workbook

path = sys.argv[1]
provenance = os.path.join(os.path.dirname(path), "report-provenance.json")
wb = load_workbook(path, data_only=False)
ws = wb[wb.sheetnames[0]]

def row_for(label):
    for row in range(1, ws.max_row + 1):
        if ws.cell(row, 1).value == label:
            return row
    return None

with open(provenance) as handle:
    provenance_payload = json.load(handle)

hap1 = row_for("MHC-A Haplotype 1")
hap2 = row_for("MHC-A Haplotype 2")
dq_hap1 = row_for("MHC-DQ Haplotype 1")
dq_hap2 = row_for("MHC-DQ Haplotype 2")
payload = {
    "sheetnames": wb.sheetnames,
    "mhcAHaplotype1": ws.cell(hap1, 4).value if hap1 else None,
    "mhcAHaplotype2": ws.cell(hap2, 4).value if hap2 else None,
    "mhcDQHaplotype1": ws.cell(dq_hap1, 4).value if dq_hap1 else None,
    "mhcDQHaplotype2": ws.cell(dq_hap2, 4).value if dq_hap2 else None,
    "haplotypeSheetRows": wb["Haplotype Calls"].max_row if "Haplotype Calls" in wb.sheetnames else 0,
    "provenanceIncludesHaplotypes": any(item.get("role") == "analysis" for item in provenance_payload.get("inputs", [])),
}
print(json.dumps(payload))
"""#
        let output = try runPython(["-c", code, url.path])
        let data = Data(output.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    private func runPython(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3"] + arguments
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
                domain: "ONTBarcodeDemuxGenotypingPipelineTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: err]
            )
        }
        return out
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    private func testValue(after flag: String, in arguments: [String]) throws -> String {
        let index = try XCTUnwrap(arguments.firstIndex(of: flag), "Missing flag \(flag)")
        return try XCTUnwrap(arguments[safe: arguments.index(after: index)])
    }

    private func makePairedFASTQBundle(
        root: URL,
        name: String,
        r1Sequence: String,
        r2Sequence: String
    ) throws -> (bundleURL: URL, r1URL: URL, r2URL: URL) {
        let bundleURL = root.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let r1URL = bundleURL.appendingPathComponent("\(name)_R1.fastq")
        let r2URL = bundleURL.appendingPathComponent("\(name)_R2.fastq")
        try "@\(name):1:1:1:1:1:1 1:N:0:1\n\(r1Sequence)\n+\n\(String(repeating: "I", count: r1Sequence.count))\n"
            .write(to: r1URL, atomically: true, encoding: .utf8)
        try "@\(name):1:1:1:1:1:1 2:N:0:1\n\(r2Sequence)\n+\n\(String(repeating: "I", count: r2Sequence.count))\n"
            .write(to: r2URL, atomically: true, encoding: .utf8)
        let classification = ReadClassification(
            pairedR1File: r1URL.lastPathComponent,
            pairedR1Count: 1,
            pairedR2File: r2URL.lastPathComponent,
            pairedR2Count: 1
        )
        try ReadManifest(classification: classification, sourceOperation: "synthetic-test").save(to: bundleURL)
        return (bundleURL, r1URL, r2URL)
    }

    private func makeMergedFASTQBundle(
        root: URL,
        name: String,
        sequence: String
    ) throws -> (bundleURL: URL, fastqURL: URL) {
        let bundleURL = root.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let fastqURL = bundleURL.appendingPathComponent("\(name).fastq")
        try "@\(name):1:1:1:1:1:1\n\(sequence)\n+\n\(String(repeating: "I", count: sequence.count))\n"
            .write(to: fastqURL, atomically: true, encoding: .utf8)
        return (bundleURL, fastqURL)
    }

    private func makeIlluminaFastqBundle(
        named name: String,
        reads: [String],
        in root: URL
    ) throws -> URL {
        let bundleURL = root.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let fastqURL = bundleURL.appendingPathComponent("reads.fastq")
        let records = reads.map { readID in
            "@\(readID)\nACGTACGT\n+\n\(String(repeating: "I", count: 8))\n"
        }
        try records.joined().write(to: fastqURL, atomically: true, encoding: .utf8)
        return bundleURL
    }

    /// A minimal assay-scoped definition set used to populate project `.lungfishmhcref`
    /// bundles. Built-in (compiled-in) definitions were removed, so tests that need a
    /// resolvable definition build one of these and write it into a bundle.
    private static func mhcDefinition(id: String, assayID: String) -> GenotypeHaplotypeDefinitionSet {
        GenotypeHaplotypeDefinitionSet(
            id: id,
            assayID: assayID,
            displayName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaque",
            speciesCode: "MCM",
            prefix: "Mafa",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-A",
                    sourceLocus: "Mafa-A",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(name: "M1A", diagnosticAlleles: ["A1_063"])
                    ]
                )
            ]
        )
    }

    /// Builds a project-scoped `.lungfishmhcref` reference bundle containing `definition`
    /// and a tiny reference FASTA, returning the bundle URL. The pipeline resolves the
    /// haplotype definition directly from this bundle and maps reads against its FASTA.
    private func makeMHCReferenceBundle(
        root: URL,
        definition: GenotypeHaplotypeDefinitionSet,
        name: String = "MCM MHC"
    ) throws -> URL {
        let bundleURL = root.appendingPathComponent("MCM-MHC.lungfishmhcref", isDirectory: true)
        let definitionRelativePath = "haplotypes/\(definition.id).lungfishhaplotypedef.json"
        let definitionURL = bundleURL.appendingPathComponent(definitionRelativePath)
        try FileManager.default.createDirectory(
            at: definitionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try ">allele1\nACGT\n".write(
            to: bundleURL.appendingPathComponent("reference.fa"),
            atomically: true,
            encoding: .utf8
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(definition).write(to: definitionURL, options: .atomic)
        try MHCAmpliconReferenceBundle.writeManifest(
            MHCAmpliconReferenceBundleManifest(
                name: name,
                referenceFastaPath: "reference.fa",
                haplotypeDefinitionPaths: [definitionRelativePath],
                defaultHaplotypeDefinitionID: definition.id,
                metrics: MHCAmpliconReferenceBundleMetrics(referenceCount: 1, haplotypeDefinitionCount: 1),
                createdAt: "2026-05-30T00:00:00Z"
            ),
            to: bundleURL
        )
        return bundleURL.standardizedFileURL
    }

    private func makeFakeONTGenotypingCondaRoot(at root: URL) throws -> URL {
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let micromambaScript = #"""
            #!/bin/sh
            set -eu
            if [ "${1:-}" = "--version" ] || [ "${1:-}" = "-v" ]; then
              echo "test-micromamba"
              exit 0
            fi
            if [ "${1:-}" != "run" ]; then
              echo "unsupported micromamba invocation: $*" >&2
              exit 2
            fi
            shift
            if [ "${1:-}" != "-n" ]; then
              echo "missing environment" >&2
              exit 2
            fi
            env_name="$2"
            shift 2
            tool="$1"
            shift
            exec "$MAMBA_ROOT_PREFIX/envs/$env_name/bin/$tool" "$@"
            """#
        let bundledMicromamba = root.deletingLastPathComponent().appendingPathComponent("bundled-micromamba")
        try writeExecutable(micromambaScript, to: bundledMicromamba)
        try writeExecutable(micromambaScript, to: bin.appendingPathComponent("micromamba"))

        let minimap2Bin = root.appendingPathComponent("envs/minimap2/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: minimap2Bin, withIntermediateDirectories: true)
        try writeExecutable(
            #"""
            #!/bin/sh
            printf '@HD\tVN:1.6\n'
            """#,
            to: minimap2Bin.appendingPathComponent("minimap2")
        )

        let samtoolsBin = root.appendingPathComponent("envs/samtools/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: samtoolsBin, withIntermediateDirectories: true)
        try writeExecutable(
            #"""
            #!/bin/sh
            set -eu
            command="$1"
            shift
            if [ "$command" = "sort" ]; then
              output=""
              while [ "$#" -gt 0 ]; do
                case "$1" in
                  -o)
                    output="$2"
                    shift 2
                    ;;
                  *)
                    shift
                    ;;
                esac
              done
              cat >/dev/null
              printf 'BAM' > "$output"
              exit 0
            fi
            if [ "$command" = "index" ]; then
              printf 'BAI' > "$1.bai"
              exit 0
            fi
            echo "unsupported samtools command: $command" >&2
            exit 2
            """#,
            to: samtoolsBin.appendingPathComponent("samtools")
        )

        let fakePython = #"""
        #!/usr/bin/env python3
        import json
        import os
        import sys
        import time

        def option(name, default=None):
            if name not in sys.argv:
                return default
            index = sys.argv.index(name)
            return sys.argv[index + 1]

        script = os.path.basename(sys.argv[1]) if len(sys.argv) > 1 else ""
        started = time.time()
        if script == "filter-demux-retained-bam.py":
            output_dir = option("--output-dir")
            prefix = option("--prefix")
            os.makedirs(output_dir, exist_ok=True)
            outputs = {
                "bam": os.path.join(output_dir, f"{prefix}.retained.demuxed.bam"),
                "bai": os.path.join(output_dir, f"{prefix}.retained.demuxed.bam.bai"),
                "genotypes": os.path.join(output_dir, f"{prefix}.retained_demux_genotypes.csv"),
                "samples": os.path.join(output_dir, f"{prefix}.retained_demux_samples.csv"),
                "stats": os.path.join(output_dir, f"{prefix}.retained_demux_stats.json"),
                "provenance": os.path.join(output_dir, "retained-demux-genotyping-provenance.json"),
            }
            with open(outputs["bam"], "w") as handle:
                handle.write("retained bam\n")
            with open(outputs["bai"], "w") as handle:
                handle.write("retained bai\n")
            with open(outputs["genotypes"], "w") as handle:
                handle.write("sample,genotype,passed_alignments,passed_unique_reads\nDW472,allele1,1,1\n")
            with open(outputs["samples"], "w") as handle:
                handle.write("sample,passed_alignments,passed_unique_reads\nDW472,1,1\n")
            stats = {
                "totalInputReads": 1,
                "totalAlignments": 1,
                "passedAlignments": 1,
                "retainedQueryNamesBeforeDemux": 1,
                "retainedUniqueReads": 1,
                "retainedUniquePercentOfTotalReads": 100.0,
                "assignedUniqueRetainedReads": 1,
                "unassignedUniqueRetainedReads": 0,
            }
            with open(outputs["stats"], "w") as handle:
                json.dump(stats, handle)
            with open(outputs["provenance"], "w") as handle:
                json.dump({"argv": sys.argv, "exitStatus": 0}, handle)
            print(json.dumps(stats))
            sys.exit(0)

        if script == "write-retained-demux-workbook.py":
            output_xlsx = option("--output-xlsx")
            provenance_json = option("--provenance-json")
            os.makedirs(os.path.dirname(output_xlsx), exist_ok=True)
            with open(output_xlsx, "w") as handle:
                handle.write("workbook\n")
            with open(provenance_json, "w") as handle:
                json.dump({"argv": sys.argv, "exitStatus": 0}, handle)
            print(json.dumps({
                "outputXLSX": output_xlsx,
                "provenanceJSON": provenance_json,
                "openpyxlVersion": "test-openpyxl",
                "sheetNames": ["barcode08-mhc"],
                "auditRows": 0,
            }))
            sys.exit(0)

        print(f"unsupported fake python script: {script}", file=sys.stderr)
        sys.exit(2)
        """#
        for environment in ["pysam", "openpyxl"] {
            let pythonBin = root.appendingPathComponent("envs/\(environment)/bin", isDirectory: true)
            try FileManager.default.createDirectory(at: pythonBin, withIntermediateDirectories: true)
            try writeExecutable(fakePython, to: pythonBin.appendingPathComponent("python"))
        }
        return bundledMicromamba
    }

    private func writeExecutable(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ONTBarcodeDemuxGenotypingPipelineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
