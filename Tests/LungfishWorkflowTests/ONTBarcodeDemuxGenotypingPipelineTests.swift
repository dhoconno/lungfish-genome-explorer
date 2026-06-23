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

    func testHaplotypeDropoutEvaluatorUsesMinSupportWithoutPercentThresholds() throws {
        let request = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURL: URL(fileURLWithPath: "/data/barcode08.lungfishfastq"),
            referenceSourceURL: URL(fileURLWithPath: "/data/reference.lungfishref"),
            barcodeDefinitionsURL: URL(fileURLWithPath: "/data/fluidigm_barcode8.txt"),
            outputDirectory: URL(fileURLWithPath: "/tmp/out", isDirectory: true),
            minSupport: 10
        )

        let evaluator = try XCTUnwrap(request.haplotypeDropoutEvaluator)
        XCTAssertEqual(evaluator.absolute, 10)
        XCTAssertNil(evaluator.sampleFraction)
        XCTAssertNil(evaluator.locusFraction)
        XCTAssertEqual(evaluator.locusFractionOverrides, [:])
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
            haplotypeSpeciesCode: "MCM",
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
        XCTAssertEqual(options["haplotypeSpeciesCode"] as? String, "MCM")
        XCTAssertEqual(options["haplotypeDefinitionSetID"] as? String, "MHC-exon2-miSeq.mauritian-cynomolgus-macaques")
        XCTAssertNotNil(options["haplotypeDefinitionSHA256"] as? String)
        XCTAssertEqual(options["requireFullReferenceSpan"] as? Bool, true)
        XCTAssertEqual(options["diagnosticPositionFilter"] as? Bool, false)
        XCTAssertEqual(options["diagnosticPositionStrictLoci"] as? [String], [])
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

    func testRunCreatesSeparateCurrentWorkbookAndManifestKeepsPrimaryImmutable() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let condaRoot = root.appendingPathComponent("conda", isDirectory: true)
        let bundledMicromamba = try makeFakeONTGenotypingCondaRoot(at: condaRoot)

        let inputFASTQ = root.appendingPathComponent("barcode08.fastq")
        let referenceFASTA = root.appendingPathComponent("reference.fa")
        let barcodeDefinitions = root.appendingPathComponent("barcodes.csv")
        let demuxManifest = root.appendingPathComponent("demux-manifest.json")
        let outputDirectory = root.appendingPathComponent("barcode08.lungfishgenotype", isDirectory: true)
        try "@r0\nACGT\n+\nIIII\n".write(to: inputFASTQ, atomically: true, encoding: .utf8)
        try ">allele1\nACGT\n".write(to: referenceFASTA, atomically: true, encoding: .utf8)
        try "sample,barcode\nDW472,ACGT\n".write(to: barcodeDefinitions, atomically: true, encoding: .utf8)
        try #"{"sampleTotals":{"DW472":1},"totalInputReads":1}"#.write(to: demuxManifest, atomically: true, encoding: .utf8)

        let request = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURL: inputFASTQ,
            referenceSourceURL: referenceFASTA,
            barcodeDefinitionsURL: barcodeDefinitions,
            outputDirectory: outputDirectory,
            outputName: "barcode08-mhc",
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

        let manifest = try ONTGenotypeResultBundle.loadManifest(from: outputDirectory)
        let primaryWorkbookURL = try ONTGenotypeResultBundle.primaryWorkbookURL(for: outputDirectory)
        let currentWorkbookURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: outputDirectory)

        XCTAssertEqual(manifest.primaryWorkbookPath, request.workbookURL.lastPathComponent)
        XCTAssertEqual(manifest.currentWorkbookPath, "artifacts/workbooks/current.xlsx")
        XCTAssertNotEqual(primaryWorkbookURL, currentWorkbookURL)
        XCTAssertEqual(try Data(contentsOf: primaryWorkbookURL), try Data(contentsOf: currentWorkbookURL))
        XCTAssertEqual(result.workbookURL, currentWorkbookURL)
        XCTAssertEqual(manifest.workbookRevisions?.first?.role, .initialCurrentCopy)
        XCTAssertEqual(manifest.workbookRevisions?.first?.path, "artifacts/workbooks/current.xlsx")

        let loaded = try ONTGenotypeResultBundle.loadResult(from: outputDirectory)
        XCTAssertEqual(loaded.artifacts.primaryWorkbookURL, primaryWorkbookURL)
        XCTAssertEqual(loaded.artifacts.workbookURL, currentWorkbookURL)
    }

    func testRunSynthesizesDemuxManifestForImportedONTBarcodeBundleWithoutPriorDemuxOutput() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let condaRoot = root.appendingPathComponent("conda", isDirectory: true)
        let bundledMicromamba = try makeFakeONTGenotypingCondaRoot(at: condaRoot)

        let inputBundle = root.appendingPathComponent("barcode11.lungfishfastq", isDirectory: true)
        let chunksDirectory = inputBundle.appendingPathComponent("chunks", isDirectory: true)
        let firstChunk = chunksDirectory.appendingPathComponent("chunk-0.fastq")
        let secondChunk = chunksDirectory.appendingPathComponent("chunk-1.fastq")
        let referenceFASTA = root.appendingPathComponent("reference.fa")
        let barcodeDefinitions = root.appendingPathComponent("barcodes.csv")
        let outputDirectory = root.appendingPathComponent("barcode11-mhc.lungfishgenotype", isDirectory: true)

        try FileManager.default.createDirectory(at: chunksDirectory, withIntermediateDirectories: true)
        try "@r0\nACGT\n+\nIIII\n".write(to: firstChunk, atomically: true, encoding: .utf8)
        try "@r1\nTGCA\n+\nIIII\n".write(to: secondChunk, atomically: true, encoding: .utf8)
        try ">allele1\nACGT\n".write(to: referenceFASTA, atomically: true, encoding: .utf8)
        try "sample,barcode\nDW472,ACGT\n".write(to: barcodeDefinitions, atomically: true, encoding: .utf8)
        try FASTQSourceFileManifest(files: [
            .init(filename: "chunks/chunk-0.fastq", originalPath: firstChunk.path, sizeBytes: 18, isSymlink: false),
            .init(filename: "chunks/chunk-1.fastq", originalPath: secondChunk.path, sizeBytes: 18, isSymlink: false),
        ]).save(to: inputBundle)

        let request = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURL: inputBundle,
            referenceSourceURL: referenceFASTA,
            barcodeDefinitionsURL: barcodeDefinitions,
            outputDirectory: outputDirectory,
            outputName: "barcode11-mhc",
            threads: 2,
            sortThreads: 1
        )

        _ = try await ONTBarcodeDemuxGenotypingPipeline(
            condaManager: CondaManager(
                rootPrefix: condaRoot,
                bundledMicromambaProvider: { bundledMicromamba },
                bundledMicromambaVersionProvider: { "test-micromamba" }
            )
        ).run(request)

        let manifestURL = outputDirectory
            .appendingPathComponent(".amplicon-genotyping", isDirectory: true)
            .appendingPathComponent("inputs", isDirectory: true)
            .appendingPathComponent("demux-manifest.json")
        let manifest = try jsonObject(at: manifestURL)
        XCTAssertEqual(manifest["inputReadCount"] as? Int, 2)
        let barcodes = try XCTUnwrap(manifest["barcodes"] as? [[String: Any]])
        XCTAssertEqual(barcodes.map { $0["barcodeID"] as? String }, ["DW472"])
        XCTAssertNil(barcodes.first?["readCount"] as? Int)
        XCTAssertEqual(manifest["manifestSource"] as? String, "synthesized-from-fastq-inputs")
    }

    func testRunCreatesDecoratedCurrentWorkbookForMCMHaplotypingAndRecordsProvenance() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let condaRoot = root.appendingPathComponent("conda", isDirectory: true)
        let bundledMicromamba = try makeFakeONTGenotypingCondaRoot(at: condaRoot)

        let inputFASTQ = root.appendingPathComponent("barcode08.fastq")
        let barcodeDefinitions = root.appendingPathComponent("barcodes.csv")
        let demuxManifest = root.appendingPathComponent("demux-manifest.json")
        let outputDirectory = root.appendingPathComponent("barcode08.lungfishgenotype", isDirectory: true)
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
            threads: 2,
            sortThreads: 1,
            minSupport: 1,
            haplotypeDropoutLocusFraction: 0.05,
            haplotypeAssayID: "MHC-exon2-miSeq",
            haplotypeDefinitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            presetID: MCMHaplotypingPreset.mcmMHCmiseq.id,
            presetVersion: MCMHaplotypingPreset.mcmMHCmiseq.version
        )

        _ = try await ONTBarcodeDemuxGenotypingPipeline(
            condaManager: CondaManager(
                rootPrefix: condaRoot,
                bundledMicromambaProvider: { bundledMicromamba },
                bundledMicromambaVersionProvider: { "test-micromamba" }
            )
        ).run(request)

        let manifest = try ONTGenotypeResultBundle.loadManifest(from: outputDirectory)
        let primaryWorkbookURL = try ONTGenotypeResultBundle.primaryWorkbookURL(for: outputDirectory)
        let currentWorkbookURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: outputDirectory)

        XCTAssertEqual(manifest.primaryWorkbookPath, request.workbookURL.lastPathComponent)
        XCTAssertEqual(manifest.currentWorkbookPath, "artifacts/workbooks/current.xlsx")
        XCTAssertNotEqual(try Data(contentsOf: primaryWorkbookURL), try Data(contentsOf: currentWorkbookURL))
        XCTAssertEqual(manifest.workbookRevisions?.first?.role, .initialCurrentCopy)
        XCTAssertEqual(manifest.workbookRevisions?.first?.label, "Initial decorated MCM current workbook")
        XCTAssertEqual(manifest.workbookRevisions?.first?.path, "artifacts/workbooks/current.xlsx")
        XCTAssertEqual(
            manifest.workbookRevisions?.first?.provenancePath,
            "artifacts/workbooks/current-workbook-provenance.json"
        )

        let currentSidecar = try jsonObject(at: request.currentWorkbookProvenanceURL)
        let currentArgv = try XCTUnwrap(currentSidecar["argv"] as? [String])
        XCTAssertTrue(currentArgv.contains("--client-current-workbook"))
        XCTAssertEqual(currentSidecar["outputWorkbook"] as? String, currentWorkbookURL.path)
        let currentHaplotypeAnalysisPath = try testValue(after: "--haplotype-analysis-json", in: currentArgv)
        XCTAssertNotEqual(currentHaplotypeAnalysisPath, request.haplotypeAnalysisURL.path)
        XCTAssertTrue(currentHaplotypeAnalysisPath.hasSuffix(".current-haplotype-analysis.json"))
        let rawAnalysis = try jsonObject(at: request.haplotypeAnalysisURL)
        let currentAnalysis = try jsonObject(at: URL(fileURLWithPath: currentHaplotypeAnalysisPath))
        XCTAssertEqual(rawAnalysis["samples"] as? NSArray, currentAnalysis["samples"] as? NSArray)
        XCTAssertEqual(
            firstHaplotypeCall(in: currentAnalysis, sample: "DW472", locus: "MHC-A")?["haplotype1"] as? String,
            "M1A"
        )
        XCTAssertEqual(
            firstHaplotypeCall(in: rawAnalysis, sample: "DW472", locus: "MHC-DQ")?["haplotype1"] as? String,
            "M1DQ"
        )
        XCTAssertEqual(
            firstHaplotypeCall(in: currentAnalysis, sample: "DW472", locus: "MHC-DQ")?["haplotype1"] as? String,
            "M1DQ"
        )
        let promptSnapshotURL = request.specialistPromptSnapshotURL
        XCTAssertEqual(
            try String(contentsOf: promptSnapshotURL, encoding: .utf8),
            try MCMHaplotypingPreset.mcmMHCmiseq.bundledSpecialistPromptMarkdown()
        )

        let legacyProvenance = try jsonObject(at: request.provenanceURL)
        let legacyOutputs = try XCTUnwrap(legacyProvenance["outputs"] as? [[String: Any]])
        XCTAssertTrue(legacyOutputs.contains { record in
            record["path"] as? String == request.currentWorkbookProvenanceURL.path
                && record["role"] as? String == "current-report-provenance"
        }, "\(legacyOutputs)")
        XCTAssertTrue(legacyOutputs.contains { record in
            record["path"] as? String == promptSnapshotURL.path
                && record["role"] as? String == "specialist-prompt"
        }, "\(legacyOutputs)")
        let legacySteps = try XCTUnwrap(legacyProvenance["steps"] as? [[String: Any]])
        XCTAssertTrue(legacySteps.contains { step in
            step["toolName"] as? String == "openpyxl MCM current workbook report"
                && ((step["argv"] as? [String])?.contains("--client-current-workbook") ?? false)
        }, "\(legacySteps)")
        XCTAssertTrue(legacySteps.contains { step in
            step["toolName"] as? String == "MCM specialist prompt snapshot"
                && step["output"] as? String == promptSnapshotURL.path
        }, "\(legacySteps)")

        let canonicalEnvelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: outputDirectory))
        XCTAssertTrue(canonicalEnvelope.outputs.contains { $0.path == request.currentWorkbookProvenanceURL.path })
        XCTAssertTrue(canonicalEnvelope.outputs.contains { $0.path == promptSnapshotURL.path })
        XCTAssertTrue(canonicalEnvelope.steps.contains { step in
            step.toolName == "openpyxl MCM current workbook report"
                && step.argv.contains("--client-current-workbook")
        }, "\(canonicalEnvelope.steps)")
        XCTAssertTrue(canonicalEnvelope.steps.contains { step in
            step.toolName == "MCM specialist prompt snapshot"
                && step.outputs.contains { $0.path == promptSnapshotURL.path }
        }, "\(canonicalEnvelope.steps)")
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
        XCTAssertEqual(Array(request.argv.prefix(3)), ["lungfish", "fastq", "genotype-cohort"])
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

    func testIlluminaCohortMapsEachSampleWithSeparateMinimap2Invocation() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let condaRoot = root.appendingPathComponent("conda", isDirectory: true)
        let bundledMicromamba = try makeFakeONTGenotypingCondaRoot(at: condaRoot)
        let referenceFASTA = root.appendingPathComponent("reference.fa")
        let outputDirectory = root.appendingPathComponent("miseq-cohort.lungfishgenotype", isDirectory: true)
        let minimap2Log = root.appendingPathComponent("minimap2-invocations.log")
        try ">allele1\nACGTACGT\n".write(to: referenceFASTA, atomically: true, encoding: .utf8)

        let samples = try ["DW001", "DW002", "DW003"].map { name in
            try makeMergedFASTQBundle(root: root, name: name, sequence: "ACGTACGT")
        }
        setenv("LUNGFISH_FAKE_MINIMAP2_LOG", minimap2Log.path, 1)
        defer { unsetenv("LUNGFISH_FAKE_MINIMAP2_LOG") }

        let request = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURLs: samples.map(\.bundleURL),
            referenceSourceURL: referenceFASTA,
            outputDirectory: outputDirectory,
            outputName: "miseq-cohort",
            analysisName: "MiSeqCohort",
            threads: 2,
            sortThreads: 1,
            minSupport: 1,
            mode: .illuminaPaired,
            readType: .illumina
        )

        _ = try await ONTBarcodeDemuxGenotypingPipeline(
            condaManager: CondaManager(
                rootPrefix: condaRoot,
                bundledMicromambaProvider: { bundledMicromamba },
                bundledMicromambaVersionProvider: { "test-micromamba" }
            )
        ).run(request)

        let minimap2Invocations = try String(contentsOf: minimap2Log, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        XCTAssertEqual(minimap2Invocations.count, 3)
        XCTAssertTrue(minimap2Invocations.allSatisfy { $0.hasSuffix(" -") }, "\(minimap2Invocations)")
        XCTAssertFalse(minimap2Invocations.contains { $0.contains(".sample-prefixed.fastq") }, "\(minimap2Invocations)")
        XCTAssertTrue(try samplePrefixedFASTQFiles(in: outputDirectory).isEmpty)

        let provenance = try jsonObject(at: request.provenanceURL)
        let steps = try XCTUnwrap(provenance["steps"] as? [[String: Any]])
        XCTAssertEqual(steps.filter { $0["toolName"] as? String == "minimap2" }.count, 3)

        let canonicalEnvelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: outputDirectory))
        XCTAssertEqual(canonicalEnvelope.steps.filter { $0.toolName == "minimap2" }.count, 3)
    }

    func testONTSampleBundleCohortUsesONTPresetAndCountWeightedSampleManifest() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let condaRoot = root.appendingPathComponent("conda", isDirectory: true)
        let bundledMicromamba = try makeFakeONTGenotypingCondaRoot(at: condaRoot)
        let referenceFASTA = root.appendingPathComponent("reference.fa")
        let outputDirectory = root.appendingPathComponent("ont-cohort.lungfishgenotype", isDirectory: true)
        let minimap2Log = root.appendingPathComponent("minimap2-invocations.log")
        try ">allele1\nACGTACGT\n".write(to: referenceFASTA, atomically: true, encoding: .utf8)

        let sampleA = try makeCountedFASTQBundle(
            root: root,
            name: "LF2871",
            records: [("u000001;size=7", "ACGTACGT")]
        )
        let sampleB = try makeCountedFASTQBundle(
            root: root,
            name: "LF2872",
            records: [("u000001;size=3", "ACGTACGT")]
        )
        setenv("LUNGFISH_FAKE_MINIMAP2_LOG", minimap2Log.path, 1)
        defer { unsetenv("LUNGFISH_FAKE_MINIMAP2_LOG") }

        let request = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURLs: [sampleA.bundleURL, sampleB.bundleURL],
            referenceSourceURL: referenceFASTA,
            outputDirectory: outputDirectory,
            outputName: "ont-cohort",
            analysisName: "ONTCohort",
            threads: 2,
            sortThreads: 1,
            minSupport: 1,
            mode: .ontSampleBundles,
            readType: .ont
        )

        _ = try await ONTBarcodeDemuxGenotypingPipeline(
            condaManager: CondaManager(
                rootPrefix: condaRoot,
                bundledMicromambaProvider: { bundledMicromamba },
                bundledMicromambaVersionProvider: { "test-micromamba" }
            )
        ).run(request)

        let minimap2Invocations = try String(contentsOf: minimap2Log, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        XCTAssertEqual(minimap2Invocations.count, 1)
        XCTAssertTrue(minimap2Invocations.allSatisfy { $0.contains("-x map-ont") }, "\(minimap2Invocations)")
        XCTAssertFalse(minimap2Invocations.contains { $0.contains("-x sr") }, "\(minimap2Invocations)")
        XCTAssertTrue(minimap2Invocations[0].hasSuffix(" -"), "\(minimap2Invocations)")
        XCTAssertFalse(minimap2Invocations[0].contains(".sample-prefixed.fastq"), "\(minimap2Invocations)")
        XCTAssertTrue(try samplePrefixedFASTQFiles(in: outputDirectory).isEmpty)

        let sampleManifestURL = outputDirectory
            .appendingPathComponent(".amplicon-genotyping", isDirectory: true)
            .appendingPathComponent("inputs", isDirectory: true)
            .appendingPathComponent("ont-sample-bundle-manifest.json")
        let sampleManifest = try jsonObject(at: sampleManifestURL)
        XCTAssertEqual(sampleManifest["mode"] as? String, "ont-sample-bundles")
        XCTAssertEqual(sampleManifest["inputReadCount"] as? Int, 10)
        let samples = try XCTUnwrap(sampleManifest["samples"] as? [[String: Any]])
        XCTAssertEqual(samples.map { $0["sample"] as? String }, ["LF2871", "LF2872"])
        XCTAssertEqual(samples.map { $0["readCount"] as? Int }, [7, 3])
        let filterScriptURL = outputDirectory
            .appendingPathComponent(".amplicon-genotyping", isDirectory: true)
            .appendingPathComponent("filter-demux-retained-bam.py")
        let filterScript = try String(contentsOf: filterScriptURL, encoding: .utf8)
        XCTAssertTrue(filterScript.contains("def sequence_for_barcode_assignment(read):"))
        XCTAssertTrue(filterScript.contains("is_reverse = read.is_reverse"))
        XCTAssertTrue(filterScript.contains("except AttributeError:"))

        let provenance = try jsonObject(at: request.provenanceURL)
        let options = try XCTUnwrap(provenance["options"] as? [String: Any])
        XCTAssertEqual(options["resolvedMode"] as? String, "ont-sample-bundles")
        XCTAssertEqual(options["resolvedReadType"] as? String, "ont")
        XCTAssertEqual(options["mappingPreset"] as? String, "map-ont")
        XCTAssertEqual(options["requireBothEndSoftclips"] as? Bool, true)
        let sampleBundlePreparation = try XCTUnwrap(options["sampleBundleInputPreparation"] as? [String: Any])
        XCTAssertEqual(sampleBundlePreparation["mappingInputTransport"] as? String, "stdin-sample-prefixed-fastq")
        XCTAssertEqual(sampleManifest["requiresBothEndSoftclips"] as? Bool, true)

        let canonicalEnvelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: outputDirectory))
        XCTAssertEqual(canonicalEnvelope.workflowName, "ONT Sample Bundle Amplicon Genotyping")
        XCTAssertEqual(canonicalEnvelope.options.explicit["resolvedMode"], .string("ont-sample-bundles"))
        XCTAssertEqual(canonicalEnvelope.steps.filter { $0.toolName == "minimap2" }.count, 1)
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

    func testResolveSampleInputsExpandsSelectedFASTQFolder() async throws {
        let tmp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let demultiplexedFolder = tmp.appendingPathComponent("Demultiplexed ONT", isDirectory: true)
        let staging = tmp.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: demultiplexedFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let firstFASTQ = demultiplexedFolder.appendingPathComponent("LF2871.fastq")
        let secondFASTQ = demultiplexedFolder.appendingPathComponent("LF2872.fastq")
        try "@r1\nACGT\n+\nIIII\n".write(to: firstFASTQ, atomically: true, encoding: .utf8)
        try "@r2\nTGCA\n+\nIIII\n".write(to: secondFASTQ, atomically: true, encoding: .utf8)

        let samples = try await ONTBarcodeDemuxGenotypingPipeline
            .resolveIlluminaSampleInputsForTesting(from: [demultiplexedFolder], stagingDirectory: staging)

        XCTAssertEqual(samples.map(\.sourceURL), [
            firstFASTQ.standardizedFileURL,
            secondFASTQ.standardizedFileURL,
        ])
        XCTAssertEqual(samples.map(\.sampleID), ["LF2871", "LF2872"])
        XCTAssertEqual(samples.map(\.readCount), [1, 1])
    }

    func testResolveSampleInputsPrefersImportedBundleCachedReadCounts() async throws {
        let tmp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let staging = tmp.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let bundle = try makeCountedFASTQBundleWithCachedStatistics(
            root: tmp,
            name: "LF2871",
            records: [("u000001", "ACGTACGT")],
            cachedReadCount: 42
        )

        let samples = try await ONTBarcodeDemuxGenotypingPipeline
            .resolveIlluminaSampleInputsForTesting(from: [bundle.bundleURL], stagingDirectory: staging)

        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].sampleID, "LF2871")
        XCTAssertEqual(samples[0].readCount, 42)
    }

    func testResolveSampleInputsPrefersParentRecipeManifestReadCountOverCachedInsertCount() async throws {
        let tmp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let outputFolder = tmp.appendingPathComponent("ont-fluidigm-samples", isDirectory: true)
        let staging = tmp.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let bundle = try makeCountedFASTQBundleWithCachedStatistics(
            root: outputFolder,
            name: "LF2871",
            records: [("u000001", "ACGTACGT")],
            cachedReadCount: 1
        )
        try """
        {
          "inputReadCount": 100,
          "samples": [
            {
              "sample": "LF2871",
              "bundle": "LF2871.lungfishfastq",
              "readCount": 42,
              "extractedReadCount": 1
            }
          ]
        }
        """.write(
            to: outputFolder.appendingPathComponent(ONTFluidigmAmpliconMaterializer.manifestFilename),
            atomically: true,
            encoding: .utf8
        )

        let samples = try await ONTBarcodeDemuxGenotypingPipeline
            .resolveIlluminaSampleInputsForTesting(from: [bundle.bundleURL], stagingDirectory: staging)

        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].sampleID, "LF2871")
        XCTAssertEqual(samples[0].readCount, 42)
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

    func testRetainedDemuxGenotypeCSVIncludesRowsBelowHaplotypeMinSupport() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let scriptURL = root.appendingPathComponent("filter-demux-retained-bam.py")
        let fakePysamURL = root.appendingPathComponent("pysam.py")
        let referenceFASTA = root.appendingPathComponent("reference.fa")
        let barcodesCSV = root.appendingPathComponent("barcodes.csv")
        let demuxManifest = root.appendingPathComponent("demux-manifest.json")
        let outputDirectory = root.appendingPathComponent("out", isDirectory: true)

        try ONTBarcodeDemuxGenotypingPipeline.writeFilterScript(to: scriptURL)
        try """
        __version__ = "fake"

        class Header:
            def to_dict(self):
                return {"HD": {"VN": "1.6"}}

        class Read:
            def __init__(self, query_name, reference_name):
                self.query_name = query_name
                self.reference_name = reference_name
                self.reference_start = 0
                self.reference_end = 4
                self.query_sequence = "TTACGTAA"
                self.cigartuples = [(4, 2), (0, 4), (4, 2)]
                self.is_unmapped = False
                self.tags = {}

            def get_tag(self, tag):
                if tag == "MD":
                    return "4"
                raise KeyError(tag)

            def set_tag(self, tag, value, value_type=None):
                self.tags[tag] = value

        READS = [
            Read("good-1", "MHC-A-good"),
            Read("good-2", "MHC-A-good"),
            Read("good-3", "MHC-A-good"),
            Read("spurious-1", "MHC-A-lowunique"),
            Read("spurious-1", "MHC-A-lowunique"),
            Read("spurious-1", "MHC-A-lowunique"),
            Read("spurious-1", "MHC-A-lowunique"),
        ]

        class AlignmentFile:
            def __init__(self, path, mode, header=None):
                self.path = path
                self.mode = mode
                self.header = header or Header()
                if "w" in mode:
                    open(path, "w").close()

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def fetch(self, until_eof=True):
                return list(READS)

            def write(self, read):
                with open(self.path, "a") as handle:
                    handle.write(read.query_name + "\\n")

        def index(path):
            with open(path + ".bai", "w") as handle:
                handle.write("index\\n")
        """.write(to: fakePysamURL, atomically: true, encoding: .utf8)
        try """
        >MHC-A-good
        ACGT
        >MHC-A-lowunique
        ACGT
        """.write(to: referenceFASTA, atomically: true, encoding: .utf8)
        try "sample,barcode\nDW472,ACGT\n".write(to: barcodesCSV, atomically: true, encoding: .utf8)
        try #"{"inputReadCount":10,"barcodes":[{"barcodeID":"DW472","readCount":10}]}"#
            .write(to: demuxManifest, atomically: true, encoding: .utf8)

        _ = try runPython([
            scriptURL.path,
            "--input-bam", root.appendingPathComponent("input.bam").path,
            "--reference-fasta", referenceFASTA.path,
            "--barcodes", barcodesCSV.path,
            "--demux-manifest", demuxManifest.path,
            "--output-dir", outputDirectory.path,
            "--prefix", "barcode10",
            "--require-both-end-softclips",
            "--max-mismatches", "0",
            "--min-support", "3",
        ], environment: ["PYTHONPATH": root.path])

        let genotypesCSV = outputDirectory.appendingPathComponent("barcode10.retained_demux_genotypes.csv")
        let csv = try String(contentsOf: genotypesCSV, encoding: .utf8)
        XCTAssertTrue(csv.contains("DW472,MHC-A-good,3,3"), csv)
        XCTAssertTrue(csv.contains("DW472,MHC-A-lowunique,4,1"), csv)
    }

    func testRetainedDemuxGenotypeCSVIncludesRowsBelowHaplotypePercentThresholds() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let scriptURL = root.appendingPathComponent("filter-demux-retained-bam.py")
        let fakePysamURL = root.appendingPathComponent("pysam.py")
        let referenceFASTA = root.appendingPathComponent("reference.fa")
        let barcodesCSV = root.appendingPathComponent("barcodes.csv")
        let demuxManifest = root.appendingPathComponent("demux-manifest.json")
        let outputDirectory = root.appendingPathComponent("out", isDirectory: true)

        try ONTBarcodeDemuxGenotypingPipeline.writeFilterScript(to: scriptURL)
        try """
        __version__ = "fake"

        class Header:
            def to_dict(self):
                return {"HD": {"VN": "1.6"}}

        class Read:
            def __init__(self, query_name, reference_name):
                self.query_name = query_name
                self.reference_name = reference_name
                self.reference_start = 0
                self.reference_end = 4
                self.query_sequence = "TTACGTAA"
                self.cigartuples = [(4, 2), (0, 4), (4, 2)]
                self.is_unmapped = False
                self.tags = {}

            def get_tag(self, tag):
                if tag == "MD":
                    return "4"
                raise KeyError(tag)

            def set_tag(self, tag, value, value_type=None):
                self.tags[tag] = value

        READS = (
            [Read(f"a-good-{i}", "02_M1_G_good") for i in range(100)]
            + [Read("a-sample-low", "02_M1_G_sample_low")]
            + [Read(f"dqa-good-{i}", "14_M1_DQA1_good") for i in range(90)]
            + [Read(f"dqa-bleed-{i}", "14_M1_DQA1_bleed") for i in range(9)]
        )

        class AlignmentFile:
            def __init__(self, path, mode, header=None):
                self.path = path
                self.mode = mode
                self.header = header or Header()
                if "w" in mode:
                    open(path, "w").close()

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def fetch(self, until_eof=True):
                return list(READS)

            def write(self, read):
                with open(self.path, "a") as handle:
                    handle.write(read.query_name + "\\n")

        def index(path):
            with open(path + ".bai", "w") as handle:
                handle.write("index\\n")
        """.write(to: fakePysamURL, atomically: true, encoding: .utf8)
        try """
        >02_M1_G_good
        ACGT
        >02_M1_G_sample_low
        ACGT
        >14_M1_DQA1_good
        ACGT
        >14_M1_DQA1_bleed
        ACGT
        """.write(to: referenceFASTA, atomically: true, encoding: .utf8)
        try "sample,barcode\nDW472,ACGT\n".write(to: barcodesCSV, atomically: true, encoding: .utf8)
        try #"{"inputReadCount":200,"barcodes":[{"barcodeID":"DW472","readCount":200}]}"#
            .write(to: demuxManifest, atomically: true, encoding: .utf8)

        _ = try runPython([
            scriptURL.path,
            "--input-bam", root.appendingPathComponent("input.bam").path,
            "--reference-fasta", referenceFASTA.path,
            "--barcodes", barcodesCSV.path,
            "--demux-manifest", demuxManifest.path,
            "--output-dir", outputDirectory.path,
            "--prefix", "barcode10",
            "--require-both-end-softclips",
            "--max-mismatches", "0",
            "--min-support", "1",
            "--haplotype-min-sample-percent", "1",
            "--haplotype-min-locus-percent", "0",
            "--haplotype-min-locus-percent-override", "MHC-DQ=10",
        ], environment: ["PYTHONPATH": root.path])

        let genotypesCSV = outputDirectory.appendingPathComponent("barcode10.retained_demux_genotypes.csv")
        let csv = try String(contentsOf: genotypesCSV, encoding: .utf8)
        XCTAssertTrue(csv.contains("DW472,02_M1_G_good,100,100"), csv)
        XCTAssertTrue(csv.contains("DW472,14_M1_DQA1_good,90,90"), csv)
        XCTAssertTrue(csv.contains("DW472,02_M1_G_sample_low,1,1"), csv)
        XCTAssertTrue(csv.contains("DW472,14_M1_DQA1_bleed,9,9"), csv)
    }

    func testRetainedDemuxFilterUsesSizeHeaderCountsForQueryPrefixSamples() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let scriptURL = root.appendingPathComponent("filter-demux-retained-bam.py")
        let fakePysamURL = root.appendingPathComponent("pysam.py")
        let referenceFASTA = root.appendingPathComponent("reference.fa")
        let sampleManifest = root.appendingPathComponent("sample-manifest.json")
        let outputDirectory = root.appendingPathComponent("out", isDirectory: true)

        try ONTBarcodeDemuxGenotypingPipeline.writeFilterScript(to: scriptURL)
        try """
        __version__ = "fake"

        class Header:
            def to_dict(self):
                return {"HD": {"VN": "1.6"}}

        class Read:
            def __init__(self, query_name, reference_name):
                self.query_name = query_name
                self.reference_name = reference_name
                self.reference_start = 0
                self.reference_end = 4
                self.query_sequence = "TTACGTAA"
                self.cigartuples = [(4, 2), (0, 4), (4, 2)]
                self.is_unmapped = False
                self.tags = {}

            def get_tag(self, tag):
                if tag == "MD":
                    return "4"
                raise KeyError(tag)

            def set_tag(self, tag, value, value_type=None):
                self.tags[tag] = value

        READS = [
            Read("LF2871|u000001;size=7", "MHC-A-good"),
            Read("LF2871|u000002;size=3", "MHC-A-low"),
        ]

        class AlignmentFile:
            def __init__(self, path, mode, header=None):
                self.path = path
                self.mode = mode
                self.header = header or Header()
                if "w" in mode:
                    open(path, "w").close()

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def fetch(self, until_eof=True):
                return list(READS)

            def write(self, read):
                with open(self.path, "a") as handle:
                    handle.write(read.query_name + "\\n")

        def index(path):
            with open(path + ".bai", "w") as handle:
                handle.write("index\\n")
        """.write(to: fakePysamURL, atomically: true, encoding: .utf8)
        try """
        >MHC-A-good
        ACGT
        >MHC-A-low
        ACGT
        """.write(to: referenceFASTA, atomically: true, encoding: .utf8)
        try #"{"inputReadCount":10,"samples":[{"sample":"LF2871","readCount":10}]}"#
            .write(to: sampleManifest, atomically: true, encoding: .utf8)

        _ = try runPython([
            scriptURL.path,
            "--input-bam", root.appendingPathComponent("input.bam").path,
            "--reference-fasta", referenceFASTA.path,
            "--demux-manifest", sampleManifest.path,
            "--sample-manifest", sampleManifest.path,
            "--assignment-mode", "query-prefix",
            "--output-dir", outputDirectory.path,
            "--prefix", "ont-cohort",
            "--max-mismatches", "0",
            "--min-support", "1",
        ], environment: ["PYTHONPATH": root.path])

        let genotypesCSV = outputDirectory.appendingPathComponent("ont-cohort.retained_demux_genotypes.csv")
        let csv = try String(contentsOf: genotypesCSV, encoding: .utf8)
        XCTAssertTrue(csv.contains("LF2871,MHC-A-good,7,7,10,10,100.000000,10,10,100.000000"), csv)
        XCTAssertTrue(csv.contains("LF2871,MHC-A-low,3,3,10,10,100.000000,10,10,100.000000"), csv)

        let sampleCSV = outputDirectory.appendingPathComponent("ont-cohort.retained_demux_samples.csv")
        let sampleText = try String(contentsOf: sampleCSV, encoding: .utf8)
        XCTAssertTrue(sampleText.contains("LF2871,10,10,10,100.000000,10,100.000000"), sampleText)

        let stats = try jsonObject(at: outputDirectory.appendingPathComponent("ont-cohort.retained_demux_stats.json"))
        XCTAssertEqual(stats["retainedUniqueReads"] as? Int, 10)
        XCTAssertEqual(stats["assignedUniqueRetainedReads"] as? Int, 10)
    }

    func testRetainedDemuxFilterRequiresFullReferenceExactSubstitutionMatch() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let scriptURL = root.appendingPathComponent("filter-demux-retained-bam.py")
        let fakePysamURL = root.appendingPathComponent("pysam.py")
        let referenceFASTA = root.appendingPathComponent("reference.fa")
        let sampleManifest = root.appendingPathComponent("sample-manifest.json")
        let outputDirectory = root.appendingPathComponent("out", isDirectory: true)

        try ONTBarcodeDemuxGenotypingPipeline.writeFilterScript(to: scriptURL)
        try """
        __version__ = "fake"

        class Header:
            def to_dict(self):
                return {"HD": {"VN": "1.6"}}

        class Read:
            def __init__(self, query_name, reference_name, start, end, md, pairs):
                self.query_name = query_name
                self.reference_name = reference_name
                self.reference_start = start
                self.reference_end = end
                self.query_sequence = "TTACGTAA"
                self.cigartuples = [(0, max(0, end - start))]
                self.is_unmapped = False
                self.tags = {}
                self.md = md
                self.pairs = pairs

            def get_tag(self, tag):
                if tag == "MD":
                    return self.md
                raise KeyError(tag)

            def set_tag(self, tag, value, value_type=None):
                self.tags[tag] = value

            def get_aligned_pairs(self, matches_only=False):
                return list(self.pairs)

        READS = [
            # Exact full-reference alignments are retained and indels remain allowed elsewhere by CIGAR/MD semantics.
            Read("LF2871|exact;size=13", "MHC-A-ref1|source_loci=MHC-A", 0, 6, "6", [(0, 0), (1, 1), (2, 2), (3, 3), (4, 4), (5, 5)]),
            # Any substitution mismatch is rejected, even when it is not diagnostic for the reference set.
            Read("LF2871|non_diag;size=5", "MHC-A-ref1|source_loci=MHC-A", 0, 6, "1C4", [(0, 0), (1, 1), (2, 2), (3, 3), (4, 4), (5, 5)]),
            # Mismatch at a diagnostic position is also rejected by the same exact-read rule.
            Read("LF2871|diag_mismatch;size=7", "MHC-A-ref1|source_loci=MHC-A", 0, 6, "4T1", [(0, 0), (1, 1), (2, 2), (3, 3), (4, 4), (5, 5)]),
            # Clipped relative to the reference is rejected even if diagnostic positions would be covered.
            Read("LF2871|clipped;size=3", "MHC-A-ref1|source_loci=MHC-A", 2, 5, "3", [(0, 2), (1, 3), (2, 4)]),
            # MHC-E follows the same strict rule as the other loci.
            Read("LF2871|mhce_mismatch;size=11", "MHC-E-ref1|source_loci=MHC-E", 0, 6, "1C4", [(0, 0), (1, 1), (2, 2), (3, 3), (4, 4), (5, 5)]),
        ]

        class AlignmentFile:
            def __init__(self, path, mode, header=None):
                self.path = path
                self.mode = mode
                self.header = header or Header()
                if "w" in mode:
                    open(path, "w").close()

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def fetch(self, until_eof=True):
                return list(READS)

            def write(self, read):
                with open(self.path, "a") as handle:
                    handle.write(read.query_name + "\\n")

        def index(path):
            with open(path + ".bai", "w") as handle:
                handle.write("index\\n")
        """.write(to: fakePysamURL, atomically: true, encoding: .utf8)
        try """
        >MHC-A-ref1|source_loci=MHC-A
        ACGTAC
        >MHC-A-ref2|source_loci=MHC-A
        ACGTTC
        >MHC-E-ref1|source_loci=MHC-E
        ACGTAC
        >MHC-E-ref2|source_loci=MHC-E
        ACGTTC
        """.write(to: referenceFASTA, atomically: true, encoding: .utf8)
        try #"{"inputReadCount":39,"samples":[{"sample":"LF2871","readCount":39}]}"#
            .write(to: sampleManifest, atomically: true, encoding: .utf8)

        _ = try runPython([
            scriptURL.path,
            "--input-bam", root.appendingPathComponent("input.bam").path,
            "--reference-fasta", referenceFASTA.path,
            "--demux-manifest", sampleManifest.path,
            "--sample-manifest", sampleManifest.path,
            "--assignment-mode", "query-prefix",
            "--output-dir", outputDirectory.path,
            "--prefix", "ont-cohort",
            "--max-mismatches", "0",
            "--min-support", "1",
        ], environment: ["PYTHONPATH": root.path])

        let genotypesCSV = outputDirectory.appendingPathComponent("ont-cohort.retained_demux_genotypes.csv")
        let csv = try String(contentsOf: genotypesCSV, encoding: .utf8)
        XCTAssertTrue(csv.contains("LF2871,MHC-A-ref1|source_loci=MHC-A,13,13"), csv)
        XCTAssertFalse(csv.contains("MHC-E-ref1"), csv)

        let stats = try jsonObject(at: outputDirectory.appendingPathComponent("ont-cohort.retained_demux_stats.json"))
        XCTAssertEqual(stats["diagnosticPositionFilter"] as? Bool, false)
        XCTAssertEqual(stats["requireFullReferenceSpan"] as? Bool, true)
        XCTAssertEqual(stats["diagnosticPositionStrictLoci"] as? [String], [])
        XCTAssertEqual(stats["retainedUniqueReads"] as? Int, 13)
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

    func testReportScriptWritesMCMClientCurrentWorkbook() throws {
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
        let definitionJSON = root.appendingPathComponent("haplotype-definition.json")
        let primaryWorkbook = root.appendingPathComponent("primary.xlsx")
        let currentWorkbook = root.appendingPathComponent("current.xlsx")
        let provenanceJSON = root.appendingPathComponent("current-workbook-provenance.json")

        try ONTBarcodeDemuxGenotypingPipeline.writeReportScript(to: scriptURL)
        try Data("primary workbook placeholder\n".utf8).write(to: primaryWorkbook)
        try """
        sample,genotype,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_reads,overall_unique_retained_percent
        \u{FEFF}DW472,02_M1_G_02_07_2mis_156bp,42,42,100,42,42.0,100,42,42.0
        \u{FEFF}DW472,02_M2_G_02_06_156bp,21,21,100,42,42.0,100,42,42.0
        \u{FEFF}DW472,"MCM_MHC_MiSeq_0068|source_loci=MHC-A1|haplotypes=M1,M2,M3|alleles=Mafa-A1_063:01:01:01,Mafa-A1_063:02:01:01|evidence_classes=primary_expressed",13,13,100,42,42.0,100,42,42.0
        \u{FEFF}DW472,02_M4M7_G_02_04_156bp,11,11,100,42,42.0,100,42,42.0
        \u{FEFF}DW472,04_M1_AG_05_3mis_156bp,18,18,100,42,42.0,100,42,42.0
        \u{FEFF}DW472,05_M1M2M3_A1_063g,16,16,100,42,42.0,100,42,42.0
        \u{FEFF}DW472,12_M1_B_046_01_01,11,11,100,42,42.0,100,42,42.0
        \u{FEFF}DW472,12_M2_B_019_03,10,10,100,42,42.0,100,42,42.0
        \u{FEFF}DW472,14_M1_DQA1_24_03,9,9,100,42,42.0,100,42,42.0
        \u{FEFF}DW472,14_M2_DQB1_06g:14_M_DQB1_06_01_01,8,8,100,42,42.0,100,42,42.0
        \u{FEFF}DW472,15_M1_DPA1_07_02,7,7,100,42,42.0,100,42,42.0
        \u{FEFF}DW472,15_M2_DPB1_20_01,6,6,100,42,42.0,100,42,42.0
        DW473,04_M4_AG_02_w_01_156bp,40,40,100,40,40.0,100,40,40.0
        DW473,12_M4_B_027_02,30,30,100,40,40.0,100,40,40.0
        """.write(to: genotypesCSV, atomically: true, encoding: .utf8)
        try """
        sample,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_percent
        \u{FEFF}DW472,84,42,100,42,42.0,100,42.0
        DW473,70,40,100,40,40.0,100,40.0
        """.write(to: samplesCSV, atomically: true, encoding: .utf8)
        try """
        {
          "passedAlignments": 84,
          "totalInputReads": 100,
          "minSupport": 10,
          "haplotypeMinSamplePercent": 1,
          "haplotypeMinLocusPercent": 1,
          "haplotypeMinLocusPercentOverrides": ["MHC-DP=10", "MHC-DQ=10"]
        }
        """.write(to: statsJSON, atomically: true, encoding: .utf8)
        try """
        >02_M1_G_02_07_2mis_156bp
        ACGT
        >02_M2_G_02_06_156bp
        ACGT
        >MCM_MHC_MiSeq_0068|source_loci=MHC-A1|haplotypes=M1,M2,M3|alleles=Mafa-A1_063:01:01:01,Mafa-A1_063:02:01:01|evidence_classes=primary_expressed
        ACGT
        >02_M4M7_G_02_04_156bp
        ACGT
        >04_M1_AG_05_3mis_156bp
        ACGT
        >05_M1M2M3_A1_063g
        ACGT
        >12_M1_B_046_01_01
        ACGT
        >12_M2_B_019_03
        ACGT
        >14_M1_DQA1_24_03
        ACGT
        >14_M2_DQB1_06g:14_M_DQB1_06_01_01
        ACGT
        >15_M1_DPA1_07_02
        ACGT
        >15_M2_DPB1_20_01
        ACGT
        >04_M4_AG_02_w_01_156bp
        ACGT
        >12_M4_B_027_02
        ACGT
        """.write(to: referenceFASTA, atomically: true, encoding: .utf8)
        try "sample,barcode\nDW472,ACGT\nDW473,TGCA\n".write(to: barcodesCSV, atomically: true, encoding: .utf8)
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
                {"locus": "MHC-A", "sourceLocus": "Mafa-A", "haplotype1": "M1A", "haplotype2": "M2A", "status": "called", "matchedHaplotypes": [], "observedGenotypeCount": 4, "observedGenotypes": ["02_M1_G_02_07_2mis_156bp", "02_M2_G_02_06_156bp", "04_M1_AG_05_3mis_156bp", "05_M1M2M3_A1_063g"], "notes": ""},
                {"locus": "MHC-B", "sourceLocus": "Mafa-B", "haplotype1": "M1B", "haplotype2": "M2B", "status": "called", "matchedHaplotypes": [], "observedGenotypeCount": 2, "observedGenotypes": ["12_M1_B_046_01_01", "12_M2_B_019_03"], "notes": ""},
                {"locus": "MHC-DRB", "sourceLocus": "Mafa-DRB", "haplotype1": "M1DR", "haplotype2": "M2DR", "status": "called", "matchedHaplotypes": [], "observedGenotypeCount": 0, "observedGenotypes": [], "notes": ""},
                {"locus": "MHC-DQ", "sourceLocus": "Mafa-DQ", "haplotype1": "M1DQ", "haplotype2": "M2DQ", "status": "called", "matchedHaplotypes": [], "observedGenotypeCount": 2, "observedGenotypes": ["14_M1_DQA1_24_03", "14_M2_DQB1_06g:14_M_DQB1_06_01_01"], "notes": ""},
                {"locus": "MHC-DP", "sourceLocus": "Mafa-DP", "haplotype1": "M1DP", "haplotype2": "M2DP", "status": "called", "matchedHaplotypes": [], "observedGenotypeCount": 2, "observedGenotypes": ["15_M1_DPA1_07_02", "15_M2_DPB1_20_01"], "notes": ""}
              ]
            },
            {
              "sample": "DW473",
              "calls": [
                {"locus": "MHC-A", "sourceLocus": "Mafa-A", "haplotype1": "M4A", "haplotype2": "-", "status": "called", "matchedHaplotypes": [], "observedGenotypeCount": 1, "observedGenotypes": ["04_M4_AG_02_w_01_156bp"], "notes": ""},
                {"locus": "MHC-B", "sourceLocus": "Mafa-B", "haplotype1": "M4B", "haplotype2": "-", "status": "called", "matchedHaplotypes": [], "observedGenotypeCount": 1, "observedGenotypes": ["12_M4_B_027_02"], "notes": ""},
                {"locus": "MHC-DRB", "sourceLocus": "Mafa-DRB", "haplotype1": "M4DR", "haplotype2": "-", "status": "called", "matchedHaplotypes": [], "observedGenotypeCount": 0, "observedGenotypes": [], "notes": ""},
                {"locus": "MHC-DQ", "sourceLocus": "Mafa-DQ", "haplotype1": "M4DQ", "haplotype2": "-", "status": "called", "matchedHaplotypes": [], "observedGenotypeCount": 0, "observedGenotypes": [], "notes": ""},
                {"locus": "MHC-DP", "sourceLocus": "Mafa-DP", "haplotype1": "M4DP", "haplotype2": "-", "status": "called", "matchedHaplotypes": [], "observedGenotypeCount": 0, "observedGenotypes": [], "notes": ""}
              ]
            }
          ]
        }
        """.write(to: haplotypesJSON, atomically: true, encoding: .utf8)
        try """
        {
          "id": "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
          "assayID": "MHC-exon2-miSeq",
          "displayName": "Mauritian cynomolgus macaques",
          "speciesName": "Mauritian cynomolgus macaque",
          "speciesCode": "MCM",
          "prefix": "Mafa",
            "locusDefinitions": [
            {"locus": "MHC-A", "sourceLocus": "Mafa-A", "haplotypes": [
              {"name": "M1A", "diagnosticAlleles": ["02_M1_G_02_07_2mis_156bp", "04_M1_AG_05_3mis_156bp"], "colorTokenIndex": 1},
              {"name": "M2A", "diagnosticAlleles": ["02_M2_G_02_06_156bp"], "colorTokenIndex": 2}
            ]},
            {"locus": "MHC-B", "sourceLocus": "Mafa-B", "haplotypes": [
              {"name": "M1B", "diagnosticAlleles": ["12_M1_B_046_01_01"], "colorTokenIndex": 1},
              {"name": "M2B", "diagnosticAlleles": ["12_M2_B_019_03"], "colorTokenIndex": 2}
            ]},
            {"locus": "MHC-DQ", "sourceLocus": "Mafa-DQ", "haplotypes": [
              {"name": "M1DQ", "diagnosticAlleles": ["14_M1_DQA1_24_03"], "colorTokenIndex": 1},
              {"name": "M2DQ", "diagnosticAlleles": ["14_M2_DQB1_06g:14_M_DQB1_06_01_01"], "colorTokenIndex": 2}
            ]},
            {"locus": "MHC-DP", "sourceLocus": "Mafa-DP", "haplotypes": [
              {"name": "M1DP", "diagnosticAlleles": ["15_M1_DPA1_07_02"], "colorTokenIndex": 1},
              {"name": "M2DP", "diagnosticAlleles": ["15_M2_DPB1_20_01"], "colorTokenIndex": 2}
            ]}
          ]
        }
        """.write(to: definitionJSON, atomically: true, encoding: .utf8)

        _ = try runPython([
            scriptURL.path,
            "--client-current-workbook",
            "--genotypes-csv", genotypesCSV.path,
            "--samples-csv", samplesCSV.path,
            "--stats-json", statsJSON.path,
            "--reference-fasta", referenceFASTA.path,
            "--barcode-definitions", barcodesCSV.path,
            "--output-xlsx", currentWorkbook.path,
            "--provenance-json", provenanceJSON.path,
            "--analysis-name", "barcode08-mhc",
            "--run-name", "barcode08-mhc",
            "--haplotype-analysis-json", haplotypesJSON.path,
            "--haplotype-definition-json", definitionJSON.path,
            "--primary-workbook", primaryWorkbook.path,
        ])

        let inspection = try inspectMCMClientCurrentWorkbook(currentWorkbook, provenanceJSON: provenanceJSON)
        XCTAssertEqual(inspection["sheetnames"] as? [String], [
            "Interpretation Guide",
            "MHC Alleles Per MHC Haplotype",
            "Abbreviated Haplotypes",
            "Full Sequencing Results 1",
            "Custom Sort",
        ])
        XCTAssertEqual(inspection["abbreviatedHaplotype1"] as? String, "M1")
        XCTAssertEqual(inspection["abbreviatedHaplotype2"] as? String, "M2")
        XCTAssertEqual(inspection["abbreviatedHomozygoteHaplotype1"] as? String, "M4")
        XCTAssertEqual(inspection["abbreviatedHomozygoteHaplotype2"] as? String, "M4")
        XCTAssertEqual(inspection["mhcAHaplotype1"] as? String, "M1A")
        XCTAssertEqual(inspection["mhcAHaplotype2"] as? String, "M2A")
        XCTAssertEqual(inspection["fullHomozygoteAHaplotype1"] as? String, "M4A")
        XCTAssertEqual(inspection["fullHomozygoteAHaplotype2"] as? String, "M4A")
        XCTAssertEqual(inspection["definitionIncludesM1A"] as? Bool, true)
        XCTAssertEqual(inspection["definitionIncludesM1G"] as? Bool, true)
        XCTAssertEqual(inspection["m2Fill"] as? String, "00000000")
        XCTAssertTrue((inspection["m2FontColor"] as? String)?.hasSuffix("FF0000") ?? false)
        XCTAssertEqual(inspection["m2GenotypeFill"] as? String, "00000000")
        XCTAssertTrue((inspection["m2GenotypeFontColor"] as? String)?.hasSuffix("FF0000") ?? false)
        XCTAssertEqual(inspection["m2GenotypeRowBold"] as? Bool, true)
        XCTAssertEqual(inspection["m2AlleleNameFontName"] as? String, "Calibri")
        XCTAssertEqual(inspection["m2AlleleNameFontSize"] as? Double, 11.0)
        XCTAssertTrue((inspection["m2AlleleNameFontColor"] as? String)?.hasSuffix("FF0000") ?? false)
        XCTAssertEqual(inspection["m2AlleleNameBold"] as? Bool, false)
        XCTAssertEqual(inspection["sharedAlleleNameFontName"] as? String, "Calibri")
        XCTAssertEqual(inspection["sharedAlleleNameFontSize"] as? Double, 11.0)
        XCTAssertFalse((inspection["sharedAlleleNameFontColor"] as? String)?.hasSuffix("00B050") ?? false)
        XCTAssertFalse((inspection["sharedAlleleNameFontColor"] as? String)?.hasSuffix("7030A0") ?? false)
        XCTAssertEqual(inspection["sharedAlleleNameBold"] as? Bool, false)
        XCTAssertEqual(inspection["fullHasGenericGenotypeHeader"] as? Bool, false)
        XCTAssertLessThan(inspection["fullMafaGHeaderRow"] as? Int ?? 0, inspection["fullMafaAGHeaderRow"] as? Int ?? 0)
        XCTAssertLessThan(inspection["fullMafaAGHeaderRow"] as? Int ?? 0, inspection["fullMafaAMajorHeaderRow"] as? Int ?? 0)
        XCTAssertLessThan(inspection["fullMafaAMajorHeaderRow"] as? Int ?? 0, inspection["fullMafaBHeaderRow"] as? Int ?? 0)
        XCTAssertEqual(inspection["fullDQAHaplotype1"] as? String, "M1DQ")
        XCTAssertEqual(inspection["fullDQBHaplotype1"] as? String, "M1DQ")
        XCTAssertEqual(inspection["fullDPAHaplotype1"] as? String, "M1DP")
        XCTAssertEqual(inspection["fullDPBHaplotype1"] as? String, "M1DP")
        XCTAssertEqual(inspection["fullCollapsedDQRowExists"] as? Bool, false)
        XCTAssertEqual(inspection["fullCollapsedDPRowExists"] as? Bool, false)
        XCTAssertEqual(inspection["abbreviatedReadCountHeader"] as? String, "Mapped Read Count")
        XCTAssertEqual(inspection["metadataCompactLabel"] as? String, "Mafa-A1*063:01:01:01/Mafa-A1*063:02:01:01")
        XCTAssertEqual(inspection["metadataLabelSection"] as? String, "Mafa-A major alleles")
        XCTAssertEqual(inspection["metadataLabelHasMiSeqComment"] as? Bool, true)
        XCTAssertEqual(inspection["metadataLabelHasPrimaryBadge"] as? Bool, true)
        XCTAssertEqual(inspection["customSortFirstSection"] as? String, "MHC homozygous MCM animals")
        XCTAssertEqual(inspection["customSortFirstSectionSampleID"] as? String, "DW473")
        XCTAssertEqual(inspection["customSortHomozygoteSampleID"] as? String, "DW473")
        XCTAssertEqual(inspection["customSortHomozygoteHaplotype1"] as? String, "M4")
        XCTAssertEqual(inspection["customSortHomozygoteHaplotype2"] as? String, "M4")
        XCTAssertEqual(inspection["containsBOM"] as? Bool, false)
        XCTAssertEqual(inspection["abbreviatedA2FontName"] as? String, "Calibri")
        XCTAssertEqual(inspection["abbreviatedA2FontSize"] as? Double, 11.0)
        XCTAssertEqual(inspection["abbreviatedA2FontBold"] as? Bool, true)
        XCTAssertEqual(inspection["customSortSectionFontName"] as? String, "Arial")
        XCTAssertEqual(inspection["customSortSectionFontSize"] as? Double, 14.0)
        XCTAssertEqual(inspection["customSortA1FontSize"] as? Double, 12.0)
        XCTAssertEqual(inspection["fullA1FontSize"] as? Double, 11.0)
        XCTAssertEqual(inspection["customSortAutoFilter"] as? String, "")
        XCTAssertEqual(inspection["abbreviatedAutoFilter"] as? String, "")
        XCTAssertEqual(inspection["guideAssay"] as? String, "MHC-exon2-miSeq")
        XCTAssertEqual(inspection["guideDefinition"] as? String, "MHC-exon2-miSeq.mauritian-cynomolgus-macaques")
        XCTAssertEqual(inspection["guideMinReads"] as? String, "10")
        XCTAssertEqual(inspection["guideMinSamplePercent"] as? String, "1%")
        XCTAssertEqual(inspection["guideMinLocusPercent"] as? String, "1%")
        XCTAssertEqual(inspection["guideLocusOverrides"] as? String, "MHC-DP=10%; MHC-DQ=10%")
        XCTAssertEqual(inspection["provenanceMode"] as? String, "mcm-client-current")
        XCTAssertTrue((inspection["provenanceOutputWorkbook"] as? String)?.hasSuffix("current.xlsx") ?? false)
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

    private func inspectMCMClientCurrentWorkbook(_ url: URL, provenanceJSON: URL) throws -> [String: Any] {
        let code = #"""
import json
import sys
from openpyxl import load_workbook

workbook_path = sys.argv[1]
provenance_path = sys.argv[2]
wb = load_workbook(workbook_path, data_only=False)

def row_for(ws, label):
    for row in range(1, ws.max_row + 1):
        if ws.cell(row, 1).value == label:
            return row
    return None

def header_map(ws):
    values = {}
    for col in range(1, ws.max_column + 1):
        value = ws.cell(1, col).value
        if value is not None:
            values[str(value)] = col
    return values

def sample_row(ws, sample):
    for row in range(1, ws.max_row + 1):
        for col in range(1, ws.max_column + 1):
            if ws.cell(row, col).value == sample:
                return row
    return None

def sample_col(ws, sample):
    for col in range(1, ws.max_column + 1):
        for row in range(1, min(ws.max_row, 4) + 1):
            if ws.cell(row, col).value == sample:
                return col
    return None

def first_nonempty_after_header(ws):
    for row in range(2, ws.max_row + 1):
        value = ws.cell(row, 1).value
        if value not in (None, ""):
            return row
    return None

def fill_rgb(cell):
    value = cell.fill.fgColor.rgb
    if isinstance(value, str):
        return value
    return None

def font_color(cell):
    color = cell.font.color
    if color is None:
        return None
    if color.type == "rgb":
        return color.rgb
    if color.type == "theme":
        return f"theme:{color.theme}:{color.tint}"
    return str(color.type)

def autofilter_ref(ws):
    return ws.auto_filter.ref or ""

def guide_value(label):
    guide = wb["Interpretation Guide"]
    for row in range(1, guide.max_row + 1):
        if guide.cell(row, 1).value == label:
            value = guide.cell(row, 2).value
            return None if value is None else str(value)
    return None

def section_for(row):
    if not row:
        return None
    sections = {
        "Mafa-F alleles",
        "Mafa-G alleles",
        "Mafa-AG alleles",
        "Mafa-A major alleles",
        "Mafa-A minor alleles",
        "Mafa-70 alleles",
        "Mafa-E alleles",
        "Mafa-B alleles",
        "Mafa-DRB alleles",
        "Mafa-DQA/DQB alleles",
        "Mafa-DPA/DPB alleles",
    }
    for candidate in range(row - 1, 0, -1):
        value = full.cell(candidate, 1).value
        if value in sections:
            return value
    return None

abbr = wb["Abbreviated Haplotypes"]
abbr_headers = header_map(abbr)
abbr_row = sample_row(abbr, "DW472")
abbr_homo_row = sample_row(abbr, "DW473")
custom = wb["Custom Sort"]
custom_row = sample_row(custom, "DW472")
custom_homo_row = sample_row(custom, "DW473")
custom_section_row = first_nonempty_after_header(custom)
full = wb["Full Sequencing Results 1"]
full_col = sample_col(full, "DW472")
full_homo_col = sample_col(full, "DW473")
row_m2_genotype = row_for(full, "02_M2_G_02_06_156bp")
row_shared_genotype = row_for(full, "02_M4M7_G_02_04_156bp")
row_metadata_genotype = row_for(full, "Mafa-A1*063:01:01:01/Mafa-A1*063:02:01:01")
definition = wb["MHC Alleles Per MHC Haplotype"]
definition_values = [
    cell.value
    for row in definition.iter_rows()
    for cell in row
    if cell.value is not None
]
with open(provenance_path) as handle:
    provenance = json.load(handle)

m2_cell = abbr.cell(abbr_row, abbr_headers["Haplotype 2"]) if abbr_row else None
metadata_cell = full.cell(row_metadata_genotype, 1) if row_metadata_genotype else None
payload = {
    "sheetnames": wb.sheetnames,
    "abbreviatedHaplotype1": abbr.cell(abbr_row, abbr_headers["Haplotype 1"]).value if abbr_row else None,
    "abbreviatedHaplotype2": abbr.cell(abbr_row, abbr_headers["Haplotype 2"]).value if abbr_row else None,
    "abbreviatedHomozygoteHaplotype1": abbr.cell(abbr_homo_row, abbr_headers["Haplotype 1"]).value if abbr_homo_row else None,
    "abbreviatedHomozygoteHaplotype2": abbr.cell(abbr_homo_row, abbr_headers["Haplotype 2"]).value if abbr_homo_row else None,
    "abbreviatedReadCountHeader": abbr.cell(1, 3).value,
    "abbreviatedA2FontName": abbr.cell(abbr_row, 1).font.name if abbr_row else None,
    "abbreviatedA2FontSize": abbr.cell(abbr_row, 1).font.sz if abbr_row else None,
    "abbreviatedA2FontBold": abbr.cell(abbr_row, 1).font.bold if abbr_row else None,
    "abbreviatedAutoFilter": autofilter_ref(abbr),
    "guideAssay": guide_value("Haplotype assay"),
    "guideDefinition": guide_value("Haplotype definition"),
    "guideMinReads": guide_value("Haplotype min reads"),
    "guideMinSamplePercent": guide_value("Haplotype min sample percent"),
    "guideMinLocusPercent": guide_value("Haplotype min locus percent"),
    "guideLocusOverrides": guide_value("Haplotype locus percent overrides"),
    "customSortFirstSection": custom.cell(custom_section_row, 1).value if custom_section_row else None,
    "customSortSampleID": custom.cell(custom_row, 1).value if custom_row else None,
    "customSortFirstSectionSampleID": custom.cell(custom_section_row + 1, 1).value if custom_section_row else None,
    "customSortHomozygoteSampleID": custom.cell(custom_homo_row, 1).value if custom_homo_row else None,
    "customSortSectionFontName": custom.cell(custom_section_row, 1).font.name if custom_section_row else None,
    "customSortSectionFontSize": custom.cell(custom_section_row, 1).font.sz if custom_section_row else None,
    "customSortA1FontSize": custom.cell(1, 1).font.sz,
    "customSortAutoFilter": autofilter_ref(custom),
    "customSortHomozygoteHaplotype1": custom.cell(custom_homo_row, abbr_headers["Haplotype 1"]).value if custom_homo_row else None,
    "customSortHomozygoteHaplotype2": custom.cell(custom_homo_row, abbr_headers["Haplotype 2"]).value if custom_homo_row else None,
    "mhcAHaplotype1": full.cell(row_for(full, "MHC-A Haplotype 1"), full_col).value if full_col else None,
    "mhcAHaplotype2": full.cell(row_for(full, "MHC-A Haplotype 2"), full_col).value if full_col else None,
    "fullHomozygoteAHaplotype1": full.cell(row_for(full, "MHC-A Haplotype 1"), full_homo_col).value if full_homo_col else None,
    "fullHomozygoteAHaplotype2": full.cell(row_for(full, "MHC-A Haplotype 2"), full_homo_col).value if full_homo_col else None,
    "fullDQAHaplotype1": full.cell(row_for(full, "MHC-DQA Haplotype 1"), full_col).value if full_col and row_for(full, "MHC-DQA Haplotype 1") else None,
    "fullDQBHaplotype1": full.cell(row_for(full, "MHC-DQB Haplotype 1"), full_col).value if full_col and row_for(full, "MHC-DQB Haplotype 1") else None,
    "fullDPAHaplotype1": full.cell(row_for(full, "MHC-DPA Haplotype 1"), full_col).value if full_col and row_for(full, "MHC-DPA Haplotype 1") else None,
    "fullDPBHaplotype1": full.cell(row_for(full, "MHC-DPB Haplotype 1"), full_col).value if full_col and row_for(full, "MHC-DPB Haplotype 1") else None,
    "fullCollapsedDQRowExists": row_for(full, "MHC-DQ Haplotype 1") is not None,
    "fullCollapsedDPRowExists": row_for(full, "MHC-DP Haplotype 1") is not None,
    "fullHasGenericGenotypeHeader": row_for(full, "Genotype") is not None,
    "fullMafaGHeaderRow": row_for(full, "Mafa-G alleles"),
    "fullMafaAGHeaderRow": row_for(full, "Mafa-AG alleles"),
    "fullMafaAMajorHeaderRow": row_for(full, "Mafa-A major alleles"),
    "fullMafaBHeaderRow": row_for(full, "Mafa-B alleles"),
    "m2GenotypeFill": fill_rgb(full.cell(row_m2_genotype, full_col)) if row_m2_genotype and full_col else None,
    "m2GenotypeFontColor": font_color(full.cell(row_m2_genotype, full_col)) if row_m2_genotype and full_col else None,
    "m2GenotypeRowBold": full.cell(row_m2_genotype, full_col).font.bold if row_m2_genotype and full_col else None,
    "m2AlleleNameFontName": full.cell(row_m2_genotype, 1).font.name if row_m2_genotype else None,
    "m2AlleleNameFontSize": full.cell(row_m2_genotype, 1).font.sz if row_m2_genotype else None,
    "m2AlleleNameFontColor": font_color(full.cell(row_m2_genotype, 1)) if row_m2_genotype else None,
    "m2AlleleNameBold": full.cell(row_m2_genotype, 1).font.bold if row_m2_genotype else None,
    "sharedAlleleNameFontName": full.cell(row_shared_genotype, 1).font.name if row_shared_genotype else None,
    "sharedAlleleNameFontSize": full.cell(row_shared_genotype, 1).font.sz if row_shared_genotype else None,
    "sharedAlleleNameFontColor": font_color(full.cell(row_shared_genotype, 1)) if row_shared_genotype else None,
    "sharedAlleleNameBold": full.cell(row_shared_genotype, 1).font.bold if row_shared_genotype else None,
    "fullA1FontSize": full.cell(1, 1).font.sz,
    "metadataCompactLabel": metadata_cell.value if metadata_cell else None,
    "metadataLabelSection": section_for(row_metadata_genotype),
    "metadataLabelHasMiSeqComment": bool(metadata_cell and metadata_cell.comment and "MCM_MHC_MiSeq_0068" in metadata_cell.comment.text),
    "metadataLabelHasPrimaryBadge": bool(metadata_cell and metadata_cell.comment and "primary_expressed" in metadata_cell.comment.text),
    "definitionIncludesM1A": "M1A" in definition_values,
    "definitionIncludesM1G": any("02_M1_G_02_07_2mis_156bp" in str(value) for value in definition_values),
    "m2Fill": fill_rgb(m2_cell) if m2_cell is not None else None,
    "m2FontColor": font_color(m2_cell) if m2_cell is not None else None,
    "containsBOM": any(
        isinstance(cell.value, str) and "\ufeff" in cell.value
        for sheet in wb.worksheets
        for row in sheet.iter_rows()
        for cell in row
    ),
    "provenanceMode": provenance.get("mode"),
    "provenanceOutputWorkbook": provenance.get("outputWorkbook"),
}
print(json.dumps(payload))
"""#
        let output = try runPython(["-c", code, url.path, provenanceJSON.path])
        let data = Data(output.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    private func runPython(_ arguments: [String], environment: [String: String] = [:]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3"] + arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
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

    private func firstHaplotypeCall(
        in analysis: [String: Any],
        sample expectedSample: String,
        locus expectedLocus: String
    ) -> [String: Any]? {
        guard let samples = analysis["samples"] as? [[String: Any]],
              let sample = samples.first(where: { $0["sample"] as? String == expectedSample }),
              let calls = sample["calls"] as? [[String: Any]] else {
            return nil
        }
        return calls.first { $0["locus"] as? String == expectedLocus }
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

    private func makeCountedFASTQBundle(
        root: URL,
        name: String,
        records: [(identifier: String, sequence: String)]
    ) throws -> (bundleURL: URL, fastqURL: URL) {
        let bundleURL = root.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let fastqURL = bundleURL.appendingPathComponent("deduplicated-amplicons.fastq")
        let text = records.map { record in
            "@\(record.identifier)\n\(record.sequence)\n+\n\(String(repeating: "I", count: record.sequence.count))\n"
        }.joined()
        try text.write(to: fastqURL, atomically: true, encoding: .utf8)
        return (bundleURL, fastqURL)
    }

    private func makeCountedFASTQBundleWithCachedStatistics(
        root: URL,
        name: String,
        records: [(identifier: String, sequence: String)],
        cachedReadCount: Int
    ) throws -> (bundleURL: URL, fastqURL: URL) {
        let output = try makeCountedFASTQBundle(root: root, name: name, records: records)
        let operation = FASTQDerivativeOperation(kind: .demultiplex, createdAt: Date())
        let manifest = FASTQDerivedBundleManifest(
            name: name,
            parentBundleRelativePath: ".",
            rootBundleRelativePath: ".",
            rootFASTQFilename: output.fastqURL.lastPathComponent,
            payload: .full(fastqFilename: output.fastqURL.lastPathComponent),
            lineage: [operation],
            operation: operation,
            cachedStatistics: .placeholder(readCount: cachedReadCount, baseCount: Int64(cachedReadCount * 8)),
            pairingMode: nil
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: output.bundleURL)
        return output
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

    private func samplePrefixedFASTQFiles(in root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return enumerator.compactMap { item -> URL? in
            guard let url = item as? URL else { return nil }
            return url.lastPathComponent.hasSuffix(".sample-prefixed.fastq") ? url : nil
        }
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
                ),
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-DQ",
                    sourceLocus: "Mafa-DQ",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(
                            name: "M1DQ",
                            diagnosticAlleles: ["14_M1_DQA1_24_03", "14_M1_DQB1_18_01_01"],
                            minimumMatches: 2
                        )
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
            set -eu
            if [ -n "${LUNGFISH_FAKE_MINIMAP2_LOG:-}" ]; then
              printf '%s\n' "$*" >> "$LUNGFISH_FAKE_MINIMAP2_LOG"
            fi
            preset=""
            query_count=0
            seen_reference=0
            uses_stdin=0
            while [ "$#" -gt 0 ]; do
              case "$1" in
                -x)
                  preset="$2"
                  shift 2
                  ;;
                -t|-R)
                  shift 2
                  ;;
                -a|--MD)
                  shift
                  ;;
                -)
                  query_count=$((query_count + 1))
                  uses_stdin=1
                  shift
                  ;;
                -*)
                  shift
                  ;;
                *)
                  if [ "$seen_reference" -eq 0 ]; then
                    seen_reference=1
                  else
                    query_count=$((query_count + 1))
                    if [ "$1" = "-" ]; then
                      uses_stdin=1
                    fi
                  fi
                  shift
                  ;;
              esac
            done
            if [ "$preset" = "sr" ] && [ "$query_count" -gt 1 ]; then
              echo "fake minimap2 refuses multiple short-read query files: $query_count" >&2
              exit 42
            fi
            if [ "$uses_stdin" -eq 1 ]; then
              cat >/dev/null
            fi
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
            if [ "$command" = "merge" ]; then
              output=""
              while [ "$#" -gt 0 ]; do
                case "$1" in
                  -f)
                    shift
                    ;;
                  *)
                    if [ -z "$output" ]; then
                      output="$1"
                    fi
                    shift
                    ;;
                esac
              done
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
                handle.write("sample,genotype,passed_alignments,passed_unique_reads\n")
                handle.write("DW472,A1_063_01,1,1\n")
                handle.write("DW472,14_M1_DQA1_24_03,100,100\n")
                handle.write("DW472,14_M1_DQB1_18_01_01,100,100\n")
                handle.write("DW472,14_M2M6_DQB1_06g:14_M_DQB1_06_01_01,4,4\n")
                handle.write("DW472,14_M4_DQB1_06_08,4,4\n")
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
            is_client_current = "--client-current-workbook" in sys.argv
            os.makedirs(os.path.dirname(output_xlsx), exist_ok=True)
            with open(output_xlsx, "w") as handle:
                handle.write("client current workbook\n" if is_client_current else "workbook\n")
            with open(provenance_json, "w") as handle:
                json.dump({
                    "argv": sys.argv,
                    "exitStatus": 0,
                    "mode": "mcm-client-current" if is_client_current else "standard-report",
                    "outputWorkbook": output_xlsx,
                }, handle)
            print(json.dumps({
                "outputXLSX": output_xlsx,
                "provenanceJSON": provenance_json,
                "openpyxlVersion": "test-openpyxl",
                "sheetNames": [
                    "Interpretation Guide",
                    "MHC Alleles Per MHC Haplotype",
                    "Abbreviated Haplotypes",
                    "Full Sequencing Results 1",
                    "Custom Sort",
                ] if is_client_current else ["barcode08-mhc"],
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
