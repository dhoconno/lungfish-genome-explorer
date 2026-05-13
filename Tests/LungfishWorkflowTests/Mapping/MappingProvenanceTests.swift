import XCTest
import LungfishCore
@testable import LungfishWorkflow

final class MappingProvenanceTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapping-provenance-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testSaveAndLoadRoundTripPreservesCommandsAndPaths() throws {
        let inputFASTQ = try writeFASTQ(
            name: "reads.fastq",
            header: "@A00488:385:HKGCLDRXX:1:1101:1000:1000 1:N:0:1",
            sequenceLength: 151
        )
        let referenceFASTA = try writeText(
            name: "reference.fa",
            contents: """
            >chr1
            ACGTACGTACGT
            """
        )
        let sourceBundle = tempDir.appendingPathComponent("source.lungfishref", isDirectory: true)
        let viewerBundle = tempDir.appendingPathComponent("viewer.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceBundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: viewerBundle, withIntermediateDirectories: true)

        let request = MappingRunRequest(
            tool: .minimap2,
            modeID: MappingMode.minimap2MapONT.id,
            inputFASTQURLs: [inputFASTQ],
            referenceFASTAURL: referenceFASTA,
            sourceReferenceBundleURL: sourceBundle,
            outputDirectory: tempDir,
            sampleName: "sample",
            threads: 8,
            includeSecondary: false,
            includeSupplementary: false,
            minimumMappingQuality: 17,
            advancedArguments: ["--eqx"]
        )

        let result = MappingResult(
            mapper: .minimap2,
            modeID: request.modeID,
            sourceReferenceBundleURL: sourceBundle,
            viewerBundleURL: viewerBundle,
            bamURL: tempDir.appendingPathComponent("sample.sorted.bam"),
            baiURL: tempDir.appendingPathComponent("sample.sorted.bam.bai"),
            totalReads: 100,
            mappedReads: 91,
            unmappedReads: 9,
            wallClockSeconds: 12.5,
            contigs: []
        )
        try Data("bam".utf8).write(to: result.bamURL)
        try Data("bai".utf8).write(to: result.baiURL)
        let rawSAM = tempDir.appendingPathComponent("sample.raw.sam")
        let filteredBAM = tempDir.appendingPathComponent("sample.filtered.bam")
        try Data("sam".utf8).write(to: rawSAM)
        try Data("filtered".utf8).write(to: filteredBAM)

        let mapperCommand = try MappingProvenance.mapperInvocation(
            for: request,
            referenceLocator: ReferenceLocator(
                referenceURL: referenceFASTA,
                indexPrefixURL: tempDir.appendingPathComponent("index/reference-index")
            )
        )
        let normalizationInvocations = MappingProvenance.normalizationInvocations(
            rawAlignmentURL: tempDir.appendingPathComponent("sample.raw.sam"),
            outputDirectory: tempDir,
            sampleName: request.sampleName,
            threads: request.threads,
            minimumMappingQuality: request.minimumMappingQuality,
            includeSecondary: request.includeSecondary,
            includeSupplementary: request.includeSupplementary
        )

        let provenance = MappingProvenance.build(
            request: request,
            result: result,
            mapperInvocation: mapperCommand,
            normalizationInvocations: normalizationInvocations,
            mapperVersion: "2.0.0",
            samtoolsVersion: "1.21",
            inputFiles: [
                ProvenanceRecorder.fileRecord(url: inputFASTQ, format: .fastq, role: .input),
                ProvenanceRecorder.fileRecord(url: referenceFASTA, format: .fasta, role: .reference)
            ],
            outputFiles: [
                ProvenanceRecorder.fileRecord(url: result.bamURL, format: .bam, role: .output),
                ProvenanceRecorder.fileRecord(url: result.baiURL, role: .index)
            ],
            runtimeIdentity: [
                "mapper": "managed conda environment minimap2; executable minimap2",
                "samtools": "managed conda environment samtools; executable samtools"
            ],
            steps: [
                StepExecution(
                    toolName: "minimap2",
                    toolVersion: "2.0.0",
                    command: mapperCommand.argv,
                    inputs: [ProvenanceRecorder.fileRecord(url: inputFASTQ, format: .fastq, role: .input)],
                    outputs: [ProvenanceRecorder.fileRecord(url: rawSAM, format: .sam, role: .output)],
                    exitCode: 0,
                    wallTime: 1.0,
                    stderr: "mapper stderr"
                ),
                StepExecution(
                    toolName: "samtools",
                    toolVersion: "1.21",
                    command: normalizationInvocations[0].argv,
                    inputs: [ProvenanceRecorder.fileRecord(url: rawSAM, format: .sam, role: .input)],
                    outputs: [ProvenanceRecorder.fileRecord(url: filteredBAM, format: .bam, role: .output)],
                    exitCode: 0,
                    wallTime: 0.5,
                    stderr: ""
                ),
                StepExecution(
                    toolName: "samtools",
                    toolVersion: "1.21",
                    command: normalizationInvocations[1].argv,
                    inputs: [ProvenanceRecorder.fileRecord(url: filteredBAM, format: .bam, role: .input)],
                    outputs: [ProvenanceRecorder.fileRecord(url: result.bamURL, format: .bam, role: .output)],
                    exitCode: 0,
                    wallTime: 0.5
                )
            ],
            exitStatus: 0
        )

        try provenance.save(to: tempDir)
        let loaded = try XCTUnwrap(MappingProvenance.load(from: tempDir))

        XCTAssertEqual(loaded.mapper, provenance.mapper)
        XCTAssertEqual(loaded.modeID, provenance.modeID)
        XCTAssertEqual(loaded.sampleName, provenance.sampleName)
        XCTAssertEqual(loaded.pairedEnd, provenance.pairedEnd)
        XCTAssertEqual(loaded.threads, provenance.threads)
        XCTAssertEqual(loaded.minimumMappingQuality, provenance.minimumMappingQuality)
        XCTAssertEqual(loaded.includeSecondary, provenance.includeSecondary)
        XCTAssertEqual(loaded.includeSupplementary, provenance.includeSupplementary)
        XCTAssertEqual(loaded.advancedArguments, provenance.advancedArguments)
        XCTAssertEqual(loaded.inputFASTQPaths, provenance.inputFASTQPaths)
        XCTAssertEqual(loaded.referenceFASTAPath, provenance.referenceFASTAPath)
        XCTAssertEqual(loaded.sourceReferenceBundlePath, provenance.sourceReferenceBundlePath)
        XCTAssertEqual(loaded.viewerBundlePath, provenance.viewerBundlePath)
        XCTAssertEqual(loaded.mapperVersion, provenance.mapperVersion)
        XCTAssertEqual(loaded.samtoolsVersion, provenance.samtoolsVersion)
        XCTAssertEqual(loaded.wallClockSeconds, provenance.wallClockSeconds, accuracy: 0.000_001)
        XCTAssertEqual(loaded.mapperInvocation, provenance.mapperInvocation)
        XCTAssertEqual(loaded.normalizationInvocations, provenance.normalizationInvocations)
        XCTAssertEqual(loaded.recordedAt.timeIntervalSince1970, provenance.recordedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(loaded.readClassHints, ["Illumina short reads"])
        XCTAssertEqual(loaded.mapperInvocation.label, "minimap2")
        XCTAssertEqual(loaded.commandInvocations.map(\.label), ["minimap2", "samtools view", "samtools sort", "samtools index", "samtools flagstat"])
        XCTAssertTrue(loaded.viewerBundlePath?.hasSuffix("viewer.lungfishref") ?? false)
        XCTAssertTrue(loaded.sourceReferenceBundlePath?.hasSuffix("source.lungfishref") ?? false)
        XCTAssertEqual(loaded.schemaVersion, 3)
        XCTAssertEqual(loaded.workflowName, "lungfish map")
        XCTAssertEqual(loaded.inputFiles.count, 2)
        XCTAssertTrue(loaded.inputFiles.allSatisfy { $0.sha256 != nil && $0.sizeBytes != nil })
        XCTAssertTrue(loaded.outputFiles.contains { $0.path == result.bamURL.path && $0.sha256 != nil && $0.sizeBytes != nil })
        XCTAssertTrue(loaded.outputFiles.contains { $0.path == result.baiURL.path && $0.sha256 != nil && $0.sizeBytes != nil })
        XCTAssertEqual(loaded.runtimeIdentity["mapper"], "managed conda environment minimap2; executable minimap2")
        XCTAssertEqual(loaded.runtimeIdentity["samtools"], "managed conda environment samtools; executable samtools")
        XCTAssertEqual(loaded.steps.map(\.toolName), ["minimap2", "samtools", "samtools"])
        XCTAssertTrue(loaded.steps.allSatisfy { $0.exitCode == 0 })
        XCTAssertTrue(loaded.steps.allSatisfy { $0.wallTime != nil })
        XCTAssertEqual(loaded.steps.first?.stderr, "mapper stderr")
        XCTAssertEqual(loaded.exitStatus, 0)

        let rawData = try Data(contentsOf: tempDir.appendingPathComponent(MappingProvenance.filename))
        let rawJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: rawData) as? [String: Any])
        let parameters = try XCTUnwrap(rawJSON["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["extraArgs"] as? String, "--eqx")
        XCTAssertNil(parameters["advancedOptions"])
        let readGroup = try XCTUnwrap(parameters["readGroup"] as? [String: Any])
        XCTAssertEqual(readGroup["id"] as? String, "sample")
        XCTAssertEqual(readGroup["sm"] as? String, "sample")
        XCTAssertEqual(readGroup["lb"] as? String, "sample")
        XCTAssertEqual(readGroup["pl"] as? String, "ONT")
        XCTAssertEqual(readGroup["pu"] as? String, "sample")
    }

    func testRecorderFindsLegacyMappingProvenanceForSelectedAnalysisBundle() throws {
        let inputFASTQ = try writeFASTQ(
            name: "reads.fastq",
            header: "@read",
            sequenceLength: 50
        )
        let referenceFASTA = try writeText(
            name: "reference.fa",
            contents: ">chr1\nACGTACGT\n"
        )
        let viewerBundle = tempDir.appendingPathComponent("viewer.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: viewerBundle, withIntermediateDirectories: true)

        let request = MappingRunRequest(
            tool: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            inputFASTQURLs: [inputFASTQ],
            referenceFASTAURL: referenceFASTA,
            outputDirectory: tempDir,
            sampleName: "sample",
            pairedEnd: false,
            threads: 4
        )
        let result = MappingResult(
            mapper: .minimap2,
            modeID: request.modeID,
            viewerBundleURL: viewerBundle,
            bamURL: tempDir.appendingPathComponent("sample.sorted.bam"),
            baiURL: tempDir.appendingPathComponent("sample.sorted.bam.bai"),
            totalReads: 10,
            mappedReads: 9,
            unmappedReads: 1,
            wallClockSeconds: 1.0,
            contigs: []
        )
        try Data("bam".utf8).write(to: result.bamURL)
        try Data("bai".utf8).write(to: result.baiURL)

        let mapperCommand = try MappingProvenance.mapperInvocation(for: request)
        let normalizationInvocations = MappingProvenance.normalizationInvocations(
            rawAlignmentURL: tempDir.appendingPathComponent("sample.raw.sam"),
            outputDirectory: tempDir,
            sampleName: request.sampleName,
            threads: request.threads,
            minimumMappingQuality: request.minimumMappingQuality,
            includeSecondary: request.includeSecondary,
            includeSupplementary: request.includeSupplementary
        )
        let provenance = MappingProvenance.build(
            request: request,
            result: result,
            mapperInvocation: mapperCommand,
            normalizationInvocations: normalizationInvocations,
            mapperVersion: "2.28",
            samtoolsVersion: "1.21",
            outputFiles: [
                ProvenanceRecorder.fileRecord(url: result.bamURL, format: .bam, role: .output),
                ProvenanceRecorder.fileRecord(url: result.baiURL, role: .index),
                ProvenanceRecorder.fileRecord(url: viewerBundle, role: .output)
            ],
            exitStatus: 0
        )
        try provenance.save(to: tempDir)

        let resolved = ProvenanceRecorder.findProvenanceEnvelope(for: tempDir)

        XCTAssertEqual(resolved?.sidecarURL.lastPathComponent, MappingProvenance.filename)
        XCTAssertEqual(resolved?.envelope.workflowName, "lungfish map")
        XCTAssertEqual(resolved?.envelope.toolName, "minimap2")
        XCTAssertTrue(resolved?.envelope.outputs.contains { $0.path == result.bamURL.path } == true)

        let resolvedViewerBundle = ProvenanceRecorder.findProvenanceEnvelope(for: viewerBundle)

        XCTAssertEqual(resolvedViewerBundle?.sidecarURL.lastPathComponent, MappingProvenance.filename)
        XCTAssertTrue(resolvedViewerBundle?.envelope.outputs.contains { $0.path == viewerBundle.path } == true)

        let exporter = ProvenanceExporter(signingProvider: nil)
        for format in ProvenanceExportFormat.allCases {
            let exportDirectory = tempDir.appendingPathComponent("export-\(format.cliToken)", isDirectory: true)
            let bundle = try exporter.exportBundle(
                try XCTUnwrap(resolved?.envelope),
                format: format,
                to: exportDirectory,
                sourceSidecarURL: resolved?.sidecarURL,
                sourceRootURL: tempDir,
                exportArgv: [
                    "lungfish", "provenance", "export",
                    tempDir.path,
                    "--export-format", format.cliToken,
                    "--output", exportDirectory.path,
                ]
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.primaryArtifactURL.path), format.cliToken)
            XCTAssertTrue(bundle.copiedSidecarURLs.contains { $0.lastPathComponent == MappingProvenance.filename }, format.cliToken)
        }
    }

    func testProvenanceExporterExpandsMappingInputLineage() throws {
        let projectURL = tempDir.appendingPathComponent("SARS-CoV-2.lungfish", isDirectory: true)
        let importsURL = projectURL.appendingPathComponent("Imports", isDirectory: true)
        let analysesURL = projectURL.appendingPathComponent("Analyses", isDirectory: true)
        let downloadsURL = projectURL.appendingPathComponent("Downloads", isDirectory: true)
        try [importsURL, analysesURL, downloadsURL].forEach {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        }

        let importBundleURL = importsURL.appendingPathComponent("SRR36291587.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: importBundleURL, withIntermediateDirectories: true)
        let importedFASTQ = importBundleURL.appendingPathComponent("SRR36291587.fastq.gz")
        try Data("imported reads".utf8).write(to: importedFASTQ)
        try writeSyntheticEnvelope(
            to: importBundleURL,
            workflowName: "gui-sra-fastq-import",
            toolName: "ena-download",
            argv: ["curl", "https://example.org/SRR36291587_1.fastq.gz"],
            inputPath: "https://example.org/SRR36291587_1.fastq.gz",
            outputURL: importedFASTQ,
            inputFormat: .fastq,
            outputFormat: .fastq
        )

        let subsampleBundleURL = analysesURL.appendingPathComponent("SRR36291587-subsampleProportion.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: subsampleBundleURL, withIntermediateDirectories: true)
        let subsampledFASTQ = subsampleBundleURL.appendingPathComponent("subsampleProportion.fastq.gz")
        try Data("subsampled reads".utf8).write(to: subsampledFASTQ)
        try writeSyntheticEnvelope(
            to: subsampleBundleURL,
            workflowName: "lungfish fastq subsample",
            toolName: "seqkit",
            argv: ["lungfish", "fastq", "subsample", importedFASTQ.path, "--output", subsampledFASTQ.path],
            inputURL: importedFASTQ,
            outputURL: subsampledFASTQ,
            inputFormat: .fastq,
            outputFormat: .fastq
        )

        let trimmedBundleURL = analysesURL.appendingPathComponent("SRR36291587-subsampleProportion-fastpTrim.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: trimmedBundleURL, withIntermediateDirectories: true)
        let trimmedFASTQ = trimmedBundleURL.appendingPathComponent("fastpTrim.fastq.gz")
        try Data("trimmed reads".utf8).write(to: trimmedFASTQ)
        try writeSyntheticEnvelope(
            to: trimmedBundleURL,
            workflowName: "lungfish fastq trim",
            toolName: "fastp",
            argv: ["lungfish", "fastq", "trim", subsampledFASTQ.path, "--output", trimmedFASTQ.path],
            inputURL: subsampledFASTQ,
            outputURL: trimmedFASTQ,
            inputFormat: .fastq,
            outputFormat: .fastq
        )

        let referenceBundleURL = downloadsURL.appendingPathComponent("MN908947.lungfishref", isDirectory: true)
        let referenceGenomeDir = referenceBundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: referenceGenomeDir, withIntermediateDirectories: true)
        let referenceGenomeURL = referenceGenomeDir.appendingPathComponent("sequence.fa.gz")
        try Data(">MN908947\nACGT\n".utf8).write(to: referenceGenomeURL)
        let referenceManifest = BundleManifest(
            name: "MN908947",
            identifier: "org.ncbi.genbank.mn908947",
            source: SourceInfo(
                organism: "SARS-CoV-2",
                assembly: "MN908947",
                assemblyAccession: "MN908947.3",
                database: "NCBI",
                sourceURL: URL(string: "https://www.ncbi.nlm.nih.gov/nuccore/MN908947"),
                downloadDate: Date(timeIntervalSince1970: 2_000),
                notes: "Downloaded from NCBI GenBank and converted to Lungfish reference bundle"
            ),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                totalLength: 4,
                chromosomes: [
                    ChromosomeInfo(name: "MN908947", length: 4, offset: 0, lineBases: 4, lineWidth: 5)
                ]
            )
        )
        try referenceManifest.save(to: referenceBundleURL)

        let mappingURL = analysesURL.appendingPathComponent("minimap2-2026-05-12T19-36-10", isDirectory: true)
        try FileManager.default.createDirectory(at: mappingURL, withIntermediateDirectories: true)
        let stagedReferenceURL = mappingURL.appendingPathComponent("reference.fa")
        let bamURL = mappingURL.appendingPathComponent("SRR36291587.sorted.bam")
        let baiURL = mappingURL.appendingPathComponent("SRR36291587.sorted.bam.bai")
        try Data(">MN908947\nACGT\n".utf8).write(to: stagedReferenceURL)
        try Data("bam".utf8).write(to: bamURL)
        try Data("bai".utf8).write(to: baiURL)

        let request = MappingRunRequest(
            tool: .minimap2,
            modeID: MappingMode.minimap2MapONT.id,
            inputFASTQURLs: [trimmedFASTQ],
            referenceFASTAURL: stagedReferenceURL,
            sourceReferenceBundleURL: referenceBundleURL,
            outputDirectory: mappingURL,
            sampleName: "SRR36291587",
            threads: 4
        )
        let result = MappingResult(
            mapper: .minimap2,
            modeID: request.modeID,
            sourceReferenceBundleURL: referenceBundleURL,
            bamURL: bamURL,
            baiURL: baiURL,
            totalReads: 10,
            mappedReads: 9,
            unmappedReads: 1,
            wallClockSeconds: 3.5,
            contigs: []
        )
        let mapperInvocation = try MappingProvenance.mapperInvocation(for: request)
        let provenance = MappingProvenance.build(
            request: request,
            result: result,
            mapperInvocation: mapperInvocation,
            normalizationInvocations: [],
            mapperVersion: "2.28",
            samtoolsVersion: "1.21",
            inputFiles: [
                ProvenanceRecorder.fileRecord(url: trimmedFASTQ, format: .fastq, role: .input),
                ProvenanceRecorder.fileRecord(url: stagedReferenceURL, format: .fasta, role: .reference)
            ],
            outputFiles: [
                ProvenanceRecorder.fileRecord(url: bamURL, format: .bam, role: .output),
                ProvenanceRecorder.fileRecord(url: baiURL, role: .index)
            ],
            steps: [
                StepExecution(
                    toolName: "minimap2",
                    toolVersion: "2.28",
                    command: mapperInvocation.argv,
                    inputs: [
                        ProvenanceRecorder.fileRecord(url: trimmedFASTQ, format: .fastq, role: .input),
                        ProvenanceRecorder.fileRecord(url: stagedReferenceURL, format: .fasta, role: .reference)
                    ],
                    outputs: [ProvenanceRecorder.fileRecord(url: bamURL, format: .bam, role: .output)],
                    exitCode: 0,
                    wallTime: 3.5
                )
            ],
            exitStatus: 0
        )
        try provenance.save(to: mappingURL)

        let resolved = try XCTUnwrap(ProvenanceRecorder.findProvenanceEnvelope(for: mappingURL))
        let exportURL = tempDir.appendingPathComponent("export-json", isDirectory: true)
        let bundle = try ProvenanceExporter(signingProvider: nil).exportBundle(
            resolved.envelope,
            format: .json,
            to: exportURL,
            sourceSidecarURL: resolved.sidecarURL,
            sourceRootURL: mappingURL,
            exportArgv: ["lungfish", "provenance", "export", mappingURL.path, "--export-format", "json", "--output", exportURL.path]
        )

        let exported = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: try Data(contentsOf: bundle.primaryArtifactURL)
        )
        let exportedToolNames = exported.steps.map(\.toolName)
        XCTAssertTrue(exportedToolNames.contains("ena-download"))
        XCTAssertTrue(exportedToolNames.contains("seqkit"))
        XCTAssertTrue(exportedToolNames.contains("fastp"))
        XCTAssertTrue(exportedToolNames.contains("minimap2"))
        XCTAssertTrue(exported.steps.contains { step in
            step.inputs.contains { $0.path == "https://www.ncbi.nlm.nih.gov/nuccore/MN908947" }
        })

        let copiedArtifactNames = bundle.copiedSidecarURLs.map(\.lastPathComponent)
        XCTAssertTrue(copiedArtifactNames.contains(MappingProvenance.filename))
        XCTAssertGreaterThanOrEqual(
            copiedArtifactNames.filter { $0.hasSuffix(".lungfish-provenance.json") }.count,
            3
        )

        for format in ProvenanceExportFormat.allCases where format != .json {
            let formatExportURL = tempDir.appendingPathComponent("export-\(format.cliToken)", isDirectory: true)
            let formatBundle = try ProvenanceExporter(signingProvider: nil).exportBundle(
                resolved.envelope,
                format: format,
                to: formatExportURL,
                sourceSidecarURL: resolved.sidecarURL,
                sourceRootURL: mappingURL,
                exportArgv: ["lungfish", "provenance", "export", mappingURL.path, "--export-format", format.cliToken, "--output", formatExportURL.path]
            )
            let primaryText = try String(contentsOf: formatBundle.primaryArtifactURL, encoding: .utf8)
            XCTAssertTrue(primaryText.contains("ena-download"), format.cliToken)
            XCTAssertTrue(primaryText.contains("seqkit"), format.cliToken)
            XCTAssertTrue(primaryText.contains("fastp"), format.cliToken)
            XCTAssertTrue(primaryText.contains("minimap2"), format.cliToken)

            let formatCopiedArtifactNames = formatBundle.copiedSidecarURLs.map(\.lastPathComponent)
            XCTAssertTrue(formatCopiedArtifactNames.contains(MappingProvenance.filename), format.cliToken)
            XCTAssertGreaterThanOrEqual(
                formatCopiedArtifactNames.filter { $0.hasSuffix(".lungfish-provenance.json") }.count,
                3,
                format.cliToken
            )
        }
    }

    func testLoadReturnsNilWhenSidecarMissing() {
        XCTAssertNil(MappingProvenance.load(from: tempDir))
    }

    func testNormalizationInvocationsCaptureFilteringAndSortThreads() {
        let invocations = MappingProvenance.normalizationInvocations(
            rawAlignmentURL: tempDir.appendingPathComponent("reads.sam"),
            outputDirectory: tempDir,
            sampleName: "sample",
            threads: 8,
            minimumMappingQuality: 17,
            includeSecondary: false,
            includeSupplementary: false
        )

        XCTAssertEqual(invocations.map(\.label), ["samtools view", "samtools sort", "samtools index", "samtools flagstat"])
        XCTAssertEqual(invocations[0].argv, [
            "samtools", "view", "-b", "-o", tempDir.appendingPathComponent("reads.filtered.bam").path,
            "-q", "17", "-F", "2304",
            tempDir.appendingPathComponent("reads.sam").path
        ])
        XCTAssertEqual(invocations[1].argv, [
            "samtools", "sort", "-@", "4", "-o", tempDir.appendingPathComponent("reads.sorted.bam").path,
            tempDir.appendingPathComponent("reads.filtered.bam").path
        ])
    }

    func testSummaryAndProvenancePreserveResolvedReadGroupDefaults() throws {
        let request = MappingRunRequest(
            tool: .minimap2,
            modeID: MappingMode.minimap2MapONT.id,
            inputFASTQURLs: [tempDir.appendingPathComponent("reads.fastq")],
            referenceFASTAURL: tempDir.appendingPathComponent("reference.fa"),
            outputDirectory: tempDir,
            sampleName: "sample",
            pairedEnd: false,
            threads: 4
        )
        let result = MappingResult(
            mapper: .minimap2,
            modeID: request.modeID,
            bamURL: tempDir.appendingPathComponent("sample.sorted.bam"),
            baiURL: tempDir.appendingPathComponent("sample.sorted.bam.bai"),
            totalReads: 10,
            mappedReads: 9,
            unmappedReads: 1,
            wallClockSeconds: 1.0,
            contigs: []
        )
        let mapperCommand = try MappingProvenance.mapperInvocation(for: request)

        let provenance = MappingProvenance.build(
            request: request,
            result: result,
            mapperInvocation: mapperCommand,
            normalizationInvocations: [],
            mapperVersion: "2.26",
            samtoolsVersion: "1.21"
        )
        try provenance.save(to: tempDir)
        let loaded = try XCTUnwrap(MappingProvenance.load(from: tempDir))
        let summary = request.summaryParameters()

        XCTAssertEqual(loaded.readGroup.id, "sample")
        XCTAssertEqual(loaded.readGroup.sampleName, "sample")
        XCTAssertEqual(loaded.readGroup.library, "sample")
        XCTAssertEqual(loaded.readGroup.platform, "ONT")
        XCTAssertEqual(loaded.readGroup.platformUnit, "sample")
        XCTAssertEqual(summary["readGroup.id"], .string("sample"))
        XCTAssertEqual(summary["readGroup.sm"], .string("sample"))
        XCTAssertEqual(summary["readGroup.lb"], .string("sample"))
        XCTAssertEqual(summary["readGroup.pl"], .string("ONT"))
        XCTAssertEqual(summary["readGroup.pu"], .string("sample"))
        XCTAssertNil(summary["readGroupID"])
        XCTAssertEqual(loaded.parameters.readGroup.id, "sample")
        XCTAssertEqual(loaded.parameters.readGroup.sm, "sample")
        XCTAssertEqual(loaded.parameters.readGroup.lb, "sample")
        XCTAssertEqual(loaded.parameters.readGroup.pl, "ONT")
        XCTAssertEqual(loaded.parameters.readGroup.pu, "sample")

        let sidecarURL = tempDir.appendingPathComponent(MappingProvenance.filename)
        let sidecarData = try Data(contentsOf: sidecarURL)
        let sidecar = try XCTUnwrap(JSONSerialization.jsonObject(with: sidecarData) as? [String: Any])
        let parameters = try XCTUnwrap(sidecar["parameters"] as? [String: Any])
        let readGroup = try XCTUnwrap(parameters["readGroup"] as? [String: Any])
        XCTAssertEqual(readGroup["id"] as? String, "sample")
        XCTAssertEqual(readGroup["sm"] as? String, "sample")
        XCTAssertEqual(readGroup["lb"] as? String, "sample")
        XCTAssertEqual(readGroup["pl"] as? String, "ONT")
        XCTAssertEqual(readGroup["pu"] as? String, "sample")
    }

    func testMapperInvocationUsesProvidedReferenceLocator() throws {
        let request = MappingRunRequest(
            tool: .bwaMem2,
            modeID: MappingMode.defaultShortRead.id,
            inputFASTQURLs: [tempDir.appendingPathComponent("reads.fastq")],
            referenceFASTAURL: tempDir.appendingPathComponent("reference.fa"),
            outputDirectory: tempDir,
            sampleName: "sample",
            pairedEnd: false,
            threads: 8
        )
        let locator = ReferenceLocator(
            referenceURL: tempDir.appendingPathComponent("reference.fa"),
            indexPrefixURL: tempDir.appendingPathComponent("custom-index/reference-index")
        )

        let invocation = try MappingProvenance.mapperInvocation(for: request, referenceLocator: locator)

        XCTAssertEqual(invocation.label, "BWA-MEM2")
        XCTAssertTrue(invocation.argv.contains(locator.indexPrefixURL.path))
        XCTAssertEqual(invocation.argv.first, "bwa-mem2")
    }

    private func writeFASTQ(name: String, header: String, sequenceLength: Int) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        let sequence = String(repeating: "A", count: sequenceLength)
        let quality = String(repeating: "I", count: sequenceLength)
        let text = "\(header)\n\(sequence)\n+\n\(quality)\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeText(name: String, contents: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeSyntheticEnvelope(
        to directory: URL,
        workflowName: String,
        toolName: String,
        argv: [String],
        inputURL: URL? = nil,
        inputPath: String? = nil,
        outputURL: URL,
        inputFormat: FileFormat,
        outputFormat: FileFormat
    ) throws {
        let inputDescriptor: ProvenanceFileDescriptor
        if let inputURL {
            inputDescriptor = try ProvenanceFileDescriptor.file(url: inputURL, format: inputFormat, role: .input)
        } else {
            inputDescriptor = ProvenanceFileDescriptor(path: inputPath ?? "", format: inputFormat, role: .input)
        }
        let outputDescriptor = try ProvenanceFileDescriptor.file(url: outputURL, format: outputFormat, role: .output)
        let step = ProvenanceStep(
            toolName: toolName,
            toolVersion: "1.0.0",
            argv: argv,
            inputs: [inputDescriptor],
            outputs: [outputDescriptor],
            exitStatus: 0,
            wallTimeSeconds: 1
        )
        let envelope = ProvenanceEnvelope(
            createdAt: Date(timeIntervalSince1970: 1_000),
            workflowName: workflowName,
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: toolName,
            toolVersion: "1.0.0",
            tool: ProvenanceToolIdentity(name: toolName, version: "1.0.0", kind: "cli"),
            argv: argv,
            runtimeIdentity: ProvenanceRuntimeIdentity.fixture(),
            files: [inputDescriptor, outputDescriptor],
            output: outputDescriptor,
            outputs: [outputDescriptor],
            steps: [step],
            wallTimeSeconds: 1,
            exitStatus: 0
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: directory)
    }
}
