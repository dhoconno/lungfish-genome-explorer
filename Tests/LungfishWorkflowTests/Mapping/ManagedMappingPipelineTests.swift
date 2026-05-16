import XCTest
@testable import LungfishIO
@testable import LungfishCore
@testable import LungfishWorkflow

final class ManagedMappingPipelineTests: XCTestCase {

    func testPrepareExecutionStagesSAMSafeFASTAInputsBeforeMapping() async throws {
        let fixture = try MappingFASTQFixture()
        defer { fixture.cleanup() }

        let overlongIdentifier = "02_Mafa_A2_05g1|" + Array(repeating: "A2_05_01", count: 40).joined(separator: ",_")
        let fastaURL = try fixture.writeFASTA(
            name: "queries.fasta",
            records: [
                (identifier: overlongIdentifier, sequenceLength: 80),
            ]
        )
        let request = MappingRunRequest(
            tool: .minimap2,
            modeID: MappingMode.minimap2Asm5.id,
            inputFASTQURLs: [fastaURL],
            referenceFASTAURL: fixture.referenceURL,
            outputDirectory: fixture.root.appendingPathComponent("out"),
            sampleName: "sample",
            pairedEnd: false,
            threads: 4
        )
        let pipeline = ManagedMappingPipeline()

        let prepared = try await pipeline.prepareExecutionForTesting(request: request)
        defer {
            for url in prepared.cleanupURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let stagedURL = try XCTUnwrap(prepared.request.inputFASTQURLs.first)
        XCTAssertNotEqual(stagedURL.standardizedFileURL, fastaURL.standardizedFileURL)
        let stagedText = try String(contentsOf: stagedURL, encoding: .utf8)
        let stagedHeader = try XCTUnwrap(stagedText.split(separator: "\n").first)
        XCTAssertTrue(stagedHeader.hasPrefix(">"))
        XCTAssertLessThanOrEqual(stagedHeader.dropFirst().utf8.count, MappingFASTAInputStager.maximumSAMQueryNameLength)
    }

    func testMapperPreflightChecksToolInRequestedEnvironment() async throws {
        let fixture = try MappingFASTQFixture()
        defer { fixture.cleanup() }
        let condaRoot = fixture.root.appendingPathComponent("conda", isDirectory: true)
        let wrongEnvTool = condaRoot.appendingPathComponent("envs/wrong-env/bin/minimap2")
        try FileManager.default.createDirectory(at: wrongEnvTool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: wrongEnvTool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrongEnvTool.path)
        let condaManager = CondaManager(rootPrefix: condaRoot)
        let pipeline = ManagedMappingPipeline(condaManager: condaManager)
        let readsURL = try fixture.writeFASTQ(
            name: "reads.fastq",
            header: "@A00488:385:HKGCLDRXX:1:1101:1000:1000 1:N:0:1",
            sequenceLength: 151
        )
        let request = MappingRunRequest(
            tool: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            inputFASTQURLs: [readsURL],
            referenceFASTAURL: fixture.referenceURL,
            outputDirectory: fixture.root.appendingPathComponent("out"),
            sampleName: "sample",
            pairedEnd: false,
            threads: 4
        )

        do {
            try await pipeline.validateInputsForTesting(request: request)
            XCTFail("Expected minimap2 preflight to require the minimap2 environment, not any environment")
        } catch ManagedMappingPipelineError.mapperNotInstalled(let tool) {
            XCTAssertEqual(tool, "minimap2")
        } catch {
            XCTFail("Expected mapperNotInstalled, got \(error)")
        }
    }

    func testBuildsBwaMem2CommandForShortReads() throws {
        let request = makeRequest(tool: .bwaMem2)

        let command = try ManagedMappingPipeline.buildCommand(for: request)

        XCTAssertEqual(command.executable, "bwa-mem2")
        XCTAssertEqual(command.environment, "bwa-mem2")
        XCTAssertEqual(Array(command.arguments.prefix(2)), ["mem", "-t"])
        XCTAssertNil(command.nativeTool)
    }

    func testBuildsMinimap2SpliceCommand() throws {
        let request = makeRequest(tool: .minimap2, modeID: MappingMode.minimap2Splice.id)

        let command = try ManagedMappingPipeline.buildCommand(for: request)

        XCTAssertEqual(command.executable, "minimap2")
        XCTAssertEqual(command.environment, "minimap2")
        XCTAssertTrue(command.arguments.contains("-x"))
        let presetIndex = try XCTUnwrap(command.arguments.firstIndex(of: "-x"))
        XCTAssertEqual(command.arguments[presetIndex + 1], "splice")
        XCTAssertTrue(command.arguments.contains("@RG\\tID:sample\\tSM:sample\\tLB:sample\\tPL:CDNA\\tPU:sample"))
    }

    func testBuildsMinimap2CommandWithExpandedReadGroupFields() throws {
        let request = makeRequest(
            tool: .minimap2,
            readGroup: MappingReadGroup(
                id: "rg-1",
                sampleName: "lungfish-42",
                library: "capture-lib",
                platform: "ILLUMINA",
                platformUnit: "flowcell.lane1"
            )
        )

        let command = try ManagedMappingPipeline.buildCommand(for: request)

        XCTAssertTrue(
            command.arguments.contains("@RG\\tID:rg-1\\tSM:lungfish-42\\tLB:capture-lib\\tPL:ILLUMINA\\tPU:flowcell.lane1")
        )
    }

    func testBuildsBowtie2CommandWithResolvedReadGroupDefaults() throws {
        let request = makeRequest(tool: .bowtie2)

        let command = try ManagedMappingPipeline.buildCommand(for: request)

        XCTAssertArgumentPair(command.arguments, "--rg-id", "sample")
        XCTAssertArgumentPair(command.arguments, "--rg", "SM:sample")
        XCTAssertArgumentPair(command.arguments, "--rg", "LB:sample")
        XCTAssertArgumentPair(command.arguments, "--rg", "PL:ILLUMINA")
        XCTAssertArgumentPair(command.arguments, "--rg", "PU:sample")
    }

    func testBuildsBowtie2CommandWithIndexPrefix() throws {
        let request = makeRequest(tool: .bowtie2)

        let command = try ManagedMappingPipeline.buildCommand(for: request)

        XCTAssertEqual(command.executable, "bowtie2")
        XCTAssertEqual(command.environment, "bowtie2")
        XCTAssertTrue(command.arguments.contains("-x"))
        XCTAssertNil(command.nativeTool)
    }

    func testBuildsBBMapCommandAsNativeTool() throws {
        let request = makeRequest(tool: .bbmap)

        let command = try ManagedMappingPipeline.buildCommand(for: request)

        XCTAssertEqual(command.executable, "bbmap.sh")
        XCTAssertTrue(command.arguments.contains("ref=/tmp/reference.fa"))
        XCTAssertEqual(command.nativeTool, .bbmap)
        XCTAssertNil(command.environment)
    }

    func testBuildsBBMapCommandWithAdvancedOptions() throws {
        let request = makeRequest(tool: .bbmap, advancedArguments: ["minid=0.97", "local=t"])

        let command = try ManagedMappingPipeline.buildCommand(for: request)

        XCTAssertTrue(command.arguments.contains("minid=0.97"))
        XCTAssertTrue(command.arguments.contains("local=t"))
    }

    func testBuildsBBMapCommandWithResolvedReadGroupDefaults() throws {
        let request = makeRequest(tool: .bbmap)

        let command = try ManagedMappingPipeline.buildCommand(for: request)

        XCTAssertTrue(command.arguments.contains("rgid=sample"))
        XCTAssertTrue(command.arguments.contains("rgsm=sample"))
        XCTAssertTrue(command.arguments.contains("rglb=sample"))
        XCTAssertTrue(command.arguments.contains("rgpl=ILLUMINA"))
        XCTAssertTrue(command.arguments.contains("rgpu=sample"))
    }

    func testAdvancedBwaOptionsPrecedePositionalInputs() throws {
        let request = makeRequest(tool: .bwaMem2, advancedArguments: ["-k", "19"])

        let command = try ManagedMappingPipeline.buildCommand(for: request)

        let advancedIndex = try XCTUnwrap(command.arguments.firstIndex(of: "-k"))
        let indexPrefixIndex = try XCTUnwrap(command.arguments.firstIndex(of: "/tmp/mapping-output/.mapping-index/reference-index"))
        XCTAssertLessThan(advancedIndex, indexPrefixIndex)
    }

    func testBuildsBBMapPacBioCommandAsNativeTool() throws {
        let request = makeRequest(tool: .bbmap, modeID: MappingMode.bbmapPacBio.id)

        let command = try ManagedMappingPipeline.buildCommand(for: request)

        XCTAssertEqual(command.executable, "mapPacBio.sh")
        XCTAssertEqual(command.nativeTool, .mapPacBio)
        XCTAssertNil(command.environment)
    }

    func testNormalizeAlignmentConvertsSAMToSortedIndexedBAM() async throws {
        let fixture = try SamtoolsFixture()
        defer { fixture.cleanup() }

        let rawSAM = fixture.tempRoot.appendingPathComponent("sample.sam")
        try Data("sam".utf8).write(to: rawSAM)

        let pipeline = ManagedMappingPipeline(
            condaManager: .shared,
            nativeToolRunner: fixture.runner
        )

        let result = try await pipeline.normalizeAlignment(
            rawAlignmentURL: rawSAM,
            outputDirectory: fixture.tempRoot
        )

        XCTAssertEqual(result.bamURL.lastPathComponent, "sample.sorted.bam")
        XCTAssertEqual(Array(try fixture.recordedSubcommands().prefix(3)), ["view", "sort", "index"])
        XCTAssertEqual(result.steps.map { $0.command.dropFirst().first }, ["view", "sort", "index", "flagstat"])
        XCTAssertTrue(result.steps.allSatisfy { $0.exitCode == 0 })
        XCTAssertTrue(result.steps.allSatisfy { $0.wallTime != nil })
        XCTAssertTrue(result.steps[0].inputs.contains { $0.path == rawSAM.path && $0.sha256 != nil && $0.sizeBytes != nil })
        XCTAssertTrue(result.steps[1].outputs.contains { $0.path == result.bamURL.path && $0.sha256 != nil && $0.sizeBytes != nil })
        XCTAssertTrue(result.steps[2].outputs.contains { $0.path == result.baiURL.path && $0.sha256 != nil && $0.sizeBytes != nil })
    }

    func testNormalizeAlignmentPreservesCallerOwnedRawSAMByDefault() async throws {
        let fixture = try SamtoolsFixture()
        defer { fixture.cleanup() }

        let rawSAM = fixture.tempRoot.appendingPathComponent("sample.raw.sam")
        try Data("sam".utf8).write(to: rawSAM)

        let pipeline = ManagedMappingPipeline(
            condaManager: .shared,
            nativeToolRunner: fixture.runner
        )

        _ = try await pipeline.normalizeAlignment(
            rawAlignmentURL: rawSAM,
            outputDirectory: fixture.tempRoot
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: rawSAM.path),
            "Public normalization should not delete caller-owned SAM inputs by default"
        )
    }

    func testNormalizeAlignmentRemovesRawSAMWhenCleanupIsEnabled() async throws {
        let fixture = try SamtoolsFixture()
        defer { fixture.cleanup() }

        let rawSAM = fixture.tempRoot.appendingPathComponent("sample.raw.sam")
        try Data("sam".utf8).write(to: rawSAM)

        let pipeline = ManagedMappingPipeline(
            condaManager: .shared,
            nativeToolRunner: fixture.runner
        )

        _ = try await pipeline.normalizeAlignment(
            rawAlignmentURL: rawSAM,
            outputDirectory: fixture.tempRoot,
            removeIntermediateRawSAMOnSuccess: true
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: rawSAM.path),
            "Cleanup-enabled normalization should remove the owned raw SAM after success"
        )
    }

    func testNormalizeAlignmentRetainsRawSAMWhenSortFailsEvenIfCleanupIsEnabled() async throws {
        let fixture = try SamtoolsFixture(failingSubcommand: "sort")
        defer { fixture.cleanup() }

        let rawSAM = fixture.tempRoot.appendingPathComponent("sample.raw.sam")
        try Data("sam".utf8).write(to: rawSAM)

        let pipeline = ManagedMappingPipeline(
            condaManager: .shared,
            nativeToolRunner: fixture.runner
        )

        await XCTAssertThrowsErrorAsync(
            try await pipeline.normalizeAlignment(
                rawAlignmentURL: rawSAM,
                outputDirectory: fixture.tempRoot,
                removeIntermediateRawSAMOnSuccess: true
            )
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: rawSAM.path),
            "Failed normalization should keep the raw SAM for debugging"
        )
    }

    func testNormalizeAlignmentSortsUnsortedBAM() async throws {
        let fixture = try SamtoolsFixture()
        defer { fixture.cleanup() }

        let rawBAM = fixture.tempRoot.appendingPathComponent("sample.unsorted.bam")
        try Data("bam".utf8).write(to: rawBAM)

        let pipeline = ManagedMappingPipeline(
            condaManager: .shared,
            nativeToolRunner: fixture.runner
        )

        let result = try await pipeline.normalizeAlignment(
            rawAlignmentURL: rawBAM,
            outputDirectory: fixture.tempRoot
        )

        XCTAssertEqual(result.bamURL.lastPathComponent, "sample.sorted.bam")
        XCTAssertEqual(Array(try fixture.recordedSubcommands().prefix(2)), ["sort", "index"])
    }

    func testNormalizeAlignmentIndexesAlreadySortedBAM() async throws {
        let fixture = try SamtoolsFixture()
        defer { fixture.cleanup() }

        let sortedBAM = fixture.tempRoot.appendingPathComponent("sample.sorted.bam")
        try Data("bam".utf8).write(to: sortedBAM)

        let pipeline = ManagedMappingPipeline(
            condaManager: .shared,
            nativeToolRunner: fixture.runner
        )

        let result = try await pipeline.normalizeAlignment(
            rawAlignmentURL: sortedBAM,
            outputDirectory: fixture.tempRoot
        )

        XCTAssertEqual(result.bamURL.lastPathComponent, "sample.sorted.bam")
        XCTAssertEqual(Array(try fixture.recordedSubcommands().prefix(1)), ["index"])
    }

    func testValidateCompatibilityRejectsMixedReadClasses() throws {
        let fixture = try MappingFASTQFixture()
        defer { fixture.cleanup() }

        let illuminaFASTQ = try fixture.writeFASTQ(
            name: "illumina.fastq",
            header: "@A00488:385:HKGCLDRXX:1:1101:1000:1000 1:N:0:1",
            sequenceLength: 151
        )
        let ontFASTQ = try fixture.writeFASTQ(
            name: "ont.fastq",
            header: "@0d4c6f0e-1234-5678-9abc-def012345678 runid=test flow_cell_id=FLO-MIN106 start_time=2026-04-19T00:00:00Z",
            sequenceLength: 1_200
        )

        let request = MappingRunRequest(
            tool: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            inputFASTQURLs: [illuminaFASTQ, ontFASTQ],
            referenceFASTAURL: fixture.referenceURL,
            outputDirectory: fixture.root.appendingPathComponent("out"),
            sampleName: "sample",
            pairedEnd: false,
            threads: 4
        )

        XCTAssertThrowsError(try ManagedMappingPipeline.validateCompatibility(for: request)) { error in
            guard case .incompatibleSelection(let message) = error as? ManagedMappingPipelineError else {
                return XCTFail("Expected incompatibleSelection error, got \(error)")
            }
            XCTAssertEqual(message, "Selected FASTQ inputs mix incompatible read classes. Select one read class per mapping run.")
        }
    }

    func testValidateCompatibilityRejectsMixedClassifiedAndUnclassifiedFASTQInputs() throws {
        let fixture = try MappingFASTQFixture()
        defer { fixture.cleanup() }

        let knownFASTQ = try fixture.writeFASTQ(
            name: "known.fastq",
            header: "@2891_MCP53H_1",
            sequenceLength: 1_200
        )
        let unknownFASTQ = try fixture.writeFASTQ(
            name: "unknown.fastq",
            header: "@2891_MCP53H_2",
            sequenceLength: 1_100
        )
        let knownBundleURL = try fixture.wrapInBundle(
            fastqURL: knownFASTQ,
            bundleName: "known-ont"
        )
        let unknownBundleURL = try fixture.wrapInBundle(
            fastqURL: unknownFASTQ,
            bundleName: "unknown"
        )
        let knownPrimaryURL = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: knownBundleURL))
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(assemblyReadType: .ontReads),
            for: knownPrimaryURL
        )

        let request = MappingRunRequest(
            tool: .minimap2,
            modeID: MappingMode.minimap2MapONT.id,
            inputFASTQURLs: [knownBundleURL, unknownBundleURL],
            referenceFASTAURL: fixture.referenceURL,
            outputDirectory: fixture.root.appendingPathComponent("out"),
            sampleName: "sample",
            pairedEnd: false,
            threads: 4
        )

        XCTAssertThrowsError(try ManagedMappingPipeline.validateCompatibility(for: request)) { error in
            guard case .incompatibleSelection(let message) = error as? ManagedMappingPipelineError else {
                return XCTFail("Expected incompatibleSelection error, got \(error)")
            }
            XCTAssertEqual(
                message,
                "Selected FASTQ inputs mix classified and unclassified read types. Re-import or edit the read type metadata so every selected FASTQ has the same read type."
            )
        }
    }

    func testValidateCompatibilityRejectsBBMapStandardReadsLongerThan500Bases() throws {
        let fixture = try MappingFASTQFixture()
        defer { fixture.cleanup() }

        let ontFASTQ = try fixture.writeFASTQ(
            name: "ont.fastq",
            header: "@0d4c6f0e-1234-5678-9abc-def012345678 runid=test flow_cell_id=FLO-MIN106 start_time=2026-04-19T00:00:00Z",
            sequenceLength: 700
        )

        let request = MappingRunRequest(
            tool: .bbmap,
            modeID: MappingMode.bbmapStandard.id,
            inputFASTQURLs: [ontFASTQ],
            referenceFASTAURL: fixture.referenceURL,
            outputDirectory: fixture.root.appendingPathComponent("out"),
            sampleName: "sample",
            pairedEnd: false,
            threads: 4
        )

        XCTAssertThrowsError(try ManagedMappingPipeline.validateCompatibility(for: request)) { error in
            guard case .incompatibleSelection(let message) = error as? ManagedMappingPipelineError else {
                return XCTFail("Expected incompatibleSelection error, got \(error)")
            }
            XCTAssertEqual(message, "Standard BBMap mode supports reads up to 500 bases. Switch to PacBio mode or choose another mapper.")
        }
    }

    func testValidateCompatibilityAcceptsBundleBackedIlluminaInputsForOtherMappers() throws {
        let fixture = try MappingFASTQFixture()
        defer { fixture.cleanup() }

        let illuminaFASTQ = try fixture.writeFASTQ(
            name: "illumina.fastq",
            header: "@A00488:385:HKGCLDRXX:1:1101:1000:1000 1:N:0:1",
            sequenceLength: 151
        )
        let bundleURL = try fixture.wrapInBundle(
            fastqURL: illuminaFASTQ,
            bundleName: "illumina"
        )

        let requests: [MappingRunRequest] = [
            MappingRunRequest(
                tool: .bwaMem2,
                modeID: MappingMode.defaultShortRead.id,
                inputFASTQURLs: [bundleURL],
                referenceFASTAURL: fixture.referenceURL,
                outputDirectory: fixture.root.appendingPathComponent("bwa-out"),
                sampleName: "sample",
                pairedEnd: false,
                threads: 4
            ),
            MappingRunRequest(
                tool: .bowtie2,
                modeID: MappingMode.defaultShortRead.id,
                inputFASTQURLs: [bundleURL],
                referenceFASTAURL: fixture.referenceURL,
                outputDirectory: fixture.root.appendingPathComponent("bowtie-out"),
                sampleName: "sample",
                pairedEnd: false,
                threads: 4
            ),
            MappingRunRequest(
                tool: .bbmap,
                modeID: MappingMode.bbmapStandard.id,
                inputFASTQURLs: [bundleURL],
                referenceFASTAURL: fixture.referenceURL,
                outputDirectory: fixture.root.appendingPathComponent("bbmap-out"),
                sampleName: "sample",
                pairedEnd: false,
                threads: 4
            )
        ]

        for request in requests {
            XCTAssertNoThrow(
                try ManagedMappingPipeline.validateCompatibility(for: request),
                "\(request.tool.displayName) should accept an Illumina .lungfishfastq bundle"
            )
        }
    }

    func testValidateCompatibilityAcceptsFASTAInputsForAllMappers() throws {
        let fixture = try MappingFASTQFixture()
        defer { fixture.cleanup() }

        let fastaURL = try fixture.writeFASTA(
            name: "reference-sequences.fasta",
            identifier: "haplotype-1",
            sequenceLength: 400
        )

        let requests: [MappingRunRequest] = [
            MappingRunRequest(
                tool: .minimap2,
                modeID: MappingMode.defaultShortRead.id,
                inputFASTQURLs: [fastaURL],
                referenceFASTAURL: fixture.referenceURL,
                outputDirectory: fixture.root.appendingPathComponent("minimap2-out"),
                sampleName: "sample",
                pairedEnd: false,
                threads: 4
            ),
            MappingRunRequest(
                tool: .bwaMem2,
                modeID: MappingMode.defaultShortRead.id,
                inputFASTQURLs: [fastaURL],
                referenceFASTAURL: fixture.referenceURL,
                outputDirectory: fixture.root.appendingPathComponent("bwa-out"),
                sampleName: "sample",
                pairedEnd: false,
                threads: 4
            ),
            MappingRunRequest(
                tool: .bowtie2,
                modeID: MappingMode.defaultShortRead.id,
                inputFASTQURLs: [fastaURL],
                referenceFASTAURL: fixture.referenceURL,
                outputDirectory: fixture.root.appendingPathComponent("bowtie-out"),
                sampleName: "sample",
                pairedEnd: false,
                threads: 4
            ),
            MappingRunRequest(
                tool: .bbmap,
                modeID: MappingMode.bbmapStandard.id,
                inputFASTQURLs: [fastaURL],
                referenceFASTAURL: fixture.referenceURL,
                outputDirectory: fixture.root.appendingPathComponent("bbmap-out"),
                sampleName: "sample",
                pairedEnd: false,
                threads: 4
            ),
        ]

        for request in requests {
            XCTAssertNoThrow(
                try ManagedMappingPipeline.validateCompatibility(for: request),
                "\(request.tool.displayName) should accept FASTA-backed sequence inputs"
            )
        }
    }

    func testStageMapperCompatibleReferenceUsesBundleContigNamesAndConvertsRNA() async throws {
        let fixture = try MappingFASTQFixture()
        defer { fixture.cleanup() }

        let bundleURL = try fixture.writeReferenceBundle(
            name: "RNA Virus.lungfishref",
            fastaText: ">NC_045512 Severe acute respiratory syndrome coronavirus 2 isolate Wuhan-Hu-1\nAACUGu\n",
            chromosomes: [
                ChromosomeInfo(name: "NC_045512", length: 6, offset: 0, lineBases: 6, lineWidth: 7)
            ]
        )
        let referenceURL = bundleURL.appendingPathComponent("genome/sequence.fa")

        let staged = try await MappingReferenceStager.stageMapperCompatibleReferenceIfNeeded(
            referenceURL: referenceURL,
            sourceReferenceBundleURL: bundleURL,
            projectURL: fixture.root
        )
        defer {
            for url in staged.cleanupURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }

        XCTAssertNotEqual(staged.referenceURL.standardizedFileURL, referenceURL.standardizedFileURL)
        XCTAssertEqual(staged.cleanupURLs.count, 1)
        XCTAssertEqual(
            try String(contentsOf: staged.referenceURL, encoding: .utf8),
            ">NC_045512\nAACTGt\n"
        )
    }

    func testStageMapperCompatibleReferenceUsesFirstHeaderTokenForStandaloneFASTA() async throws {
        let fixture = try MappingFASTQFixture()
        defer { fixture.cleanup() }

        let referenceURL = fixture.root.appendingPathComponent("standalone.fa")
        try ">chr1 description text\nACUu\n".write(to: referenceURL, atomically: true, encoding: .utf8)

        let staged = try await MappingReferenceStager.stageMapperCompatibleReferenceIfNeeded(
            referenceURL: referenceURL,
            sourceReferenceBundleURL: nil,
            projectURL: fixture.root
        )
        defer {
            for url in staged.cleanupURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }

        XCTAssertNotEqual(staged.referenceURL.standardizedFileURL, referenceURL.standardizedFileURL)
        XCTAssertEqual(
            try String(contentsOf: staged.referenceURL, encoding: .utf8),
            ">chr1\nACTt\n"
        )
    }

    func testStageSAMSafeFASTAInputsShortensOverlongIdentifiersAtRuntime() async throws {
        let fixture = try MappingFASTQFixture()
        defer { fixture.cleanup() }

        let overlongIdentifier = "02_Mafa_A2_05g1|" + Array(repeating: "A2_05_01", count: 40).joined(separator: ",_")
        let fastaURL = try fixture.writeFASTA(
            name: "queries.fasta",
            records: [
                (identifier: overlongIdentifier, sequenceLength: 80),
                (identifier: "short-id", sequenceLength: 40),
            ]
        )

        let staged = try await MappingFASTAInputStager.stageSAMSafeFASTAInputsIfNeeded(
            inputURLs: [fastaURL],
            projectURL: fixture.root
        )
        defer {
            for url in staged.cleanupURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }

        XCTAssertEqual(staged.inputURLs.count, 1)
        XCTAssertNotEqual(staged.inputURLs[0].standardizedFileURL, fastaURL.standardizedFileURL)
        XCTAssertEqual(staged.cleanupURLs.count, 1)

        let stagedHeaders = try String(contentsOf: staged.inputURLs[0], encoding: .utf8)
            .split(separator: "\n")
            .filter { $0.hasPrefix(">") }
            .map { String($0.dropFirst()) }

        XCTAssertEqual(stagedHeaders.count, 2)
        XCTAssertTrue(stagedHeaders.allSatisfy { $0.utf8.count <= MappingFASTAInputStager.maximumSAMQueryNameLength })
        XCTAssertNotEqual(stagedHeaders[0], overlongIdentifier)
        XCTAssertEqual(stagedHeaders[1], "short-id")
    }

    func testStageSAMSafeFASTAInputsLeavesSafeIdentifiersUntouched() async throws {
        let fixture = try MappingFASTQFixture()
        defer { fixture.cleanup() }

        let fastaURL = try fixture.writeFASTA(
            name: "safe-queries.fasta",
            records: [
                (identifier: "contig-1", sequenceLength: 80),
                (identifier: "contig-2", sequenceLength: 40),
            ]
        )

        let staged = try await MappingFASTAInputStager.stageSAMSafeFASTAInputsIfNeeded(
            inputURLs: [fastaURL],
            projectURL: fixture.root
        )

        XCTAssertEqual(staged.inputURLs.map(\.standardizedFileURL), [fastaURL.standardizedFileURL])
        XCTAssertTrue(staged.cleanupURLs.isEmpty)
    }

    func testStreamingCondaStdoutTimeoutThrowsCondaTimeout() async throws {
        let fixture = try StreamingCondaFixture()
        defer { fixture.cleanup() }
        let pipeline = ManagedMappingPipeline(condaManager: fixture.condaManager)
        let stdoutURL = fixture.root.appendingPathComponent("timed-out.sam")

        do {
            _ = try await pipeline.runCondaToolStreamingStdoutForTesting(
                executable: "mapper",
                arguments: ["sleep"],
                environment: "mapper",
                workingDirectory: fixture.root,
                stdoutURL: stdoutURL,
                timeout: 0.2
            )
            XCTFail("Expected timeout")
        } catch CondaError.timeout(let tool, let seconds) {
            XCTAssertEqual(tool, "mapper")
            XCTAssertEqual(seconds, 0.2, accuracy: 0.001)
        } catch {
            XCTFail("Expected CondaError.timeout, got \(error)")
        }
    }

    func testStreamingCondaStdoutCapturesFastExitStderr() async throws {
        let fixture = try StreamingCondaFixture()
        defer { fixture.cleanup() }
        let pipeline = ManagedMappingPipeline(condaManager: fixture.condaManager)
        let stdoutURL = fixture.root.appendingPathComponent("fast-exit.sam")

        let result = try await pipeline.runCondaToolStreamingStdoutForTesting(
            executable: "mapper",
            arguments: ["fast-stderr"],
            environment: "mapper",
            workingDirectory: fixture.root,
            stdoutURL: stdoutURL,
            timeout: 2
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "fast-exit stderr\n")
    }

    func testStreamingCondaStdoutUserCancellationThrowsCancellationError() async throws {
        let fixture = try StreamingCondaFixture()
        defer { fixture.cleanup() }
        let pipeline = ManagedMappingPipeline(condaManager: fixture.condaManager)
        let stdoutURL = fixture.root.appendingPathComponent("cancelled.sam")
        let readyURL = fixture.root.appendingPathComponent("ready")

        let task = Task {
            try await pipeline.runCondaToolStreamingStdoutForTesting(
                executable: "mapper",
                arguments: ["ready", readyURL.path],
                environment: "mapper",
                workingDirectory: fixture.root,
                stdoutURL: stdoutURL,
                timeout: 10
            )
        }
        try await waitForFile(readyURL)

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    private func makeRequest(
        tool: MappingTool,
        modeID: String? = nil,
        advancedArguments: [String] = [],
        readGroup: MappingReadGroup? = nil
    ) -> MappingRunRequest {
        MappingRunRequest(
            tool: tool,
            modeID: modeID ?? (tool == .bbmap ? MappingMode.bbmapStandard.id : MappingMode.defaultShortRead.id),
            inputFASTQURLs: [
                URL(fileURLWithPath: "/tmp/R1.fastq.gz"),
                URL(fileURLWithPath: "/tmp/R2.fastq.gz"),
            ],
            referenceFASTAURL: URL(fileURLWithPath: "/tmp/reference.fa"),
            outputDirectory: URL(fileURLWithPath: "/tmp/mapping-output"),
            sampleName: "sample",
            readGroup: readGroup,
            pairedEnd: true,
            threads: 8,
            advancedArguments: advancedArguments
        )
    }
}

private struct StreamingCondaFixture {
    let root: URL
    let condaManager: CondaManager

    init() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent(
            "mapping-streaming-conda-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let bundledMicromamba = root.appendingPathComponent("bundled-micromamba")
        try Self.scriptBody().write(to: bundledMicromamba, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledMicromamba.path)

        condaManager = CondaManager(
            rootPrefix: root.appendingPathComponent("conda", isDirectory: true),
            bundledMicromambaProvider: { bundledMicromamba },
            bundledMicromambaVersionProvider: { "2.0.0" }
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func scriptBody() -> String {
        """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo "2.0.0"
          exit 0
        fi
        if [ "$1" = "run" ]; then
          shift
          if [ "$1" = "-n" ]; then
            shift
            shift
          fi
          tool="$1"
          shift
          case "$1" in
            sleep)
              echo "starting timeout path" >&2
              sleep 30
              ;;
            fast-stderr)
              echo "fast-exit stderr" >&2
              exit 0
              ;;
            ready)
              touch "$2"
              sleep 30
              ;;
            *)
              echo "unknown mode for $tool" >&2
              exit 64
              ;;
          esac
        fi
        """
    }
}

private func waitForFile(_ url: URL, timeout: TimeInterval = 2) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: url.path) {
            return
        }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    XCTFail("Timed out waiting for \(url.path)")
}

private func XCTAssertArgumentPair(
    _ arguments: [String],
    _ flag: String,
    _ value: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    for index in arguments.indices where arguments[index] == flag && index + 1 < arguments.endIndex {
        if arguments[index + 1] == value {
            return
        }
    }
    XCTFail("Expected argument pair \(flag) \(value) in \(arguments)", file: file, line: line)
}

private struct SamtoolsFixture {
    let tempRoot: URL
    let runner: NativeToolRunner
    let logURL: URL

    init(failingSubcommand: String? = nil) throws {
        let fm = FileManager.default
        tempRoot = fm.temporaryDirectory.appendingPathComponent(
            "mapping-samtools-fixture-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let homeDirectory = tempRoot.appendingPathComponent("home", isDirectory: true)
        let samtoolsDir = homeDirectory
            .appendingPathComponent(".lungfish/conda/envs/samtools/bin", isDirectory: true)
        try fm.createDirectory(at: samtoolsDir, withIntermediateDirectories: true)

        logURL = tempRoot.appendingPathComponent("samtools.log")
        let scriptURL = samtoolsDir.appendingPathComponent("samtools")
        try Self.scriptBody(
            logURL: logURL,
            failingSubcommand: failingSubcommand
        ).write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        runner = NativeToolRunner(toolsDirectory: nil, homeDirectory: homeDirectory)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func recordedSubcommands() throws -> [String] {
        guard FileManager.default.fileExists(atPath: logURL.path) else { return [] }
        return try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                String(line.split(separator: "\t", omittingEmptySubsequences: false).first ?? "")
            }
    }

    private static func scriptBody(logURL: URL, failingSubcommand: String?) -> String {
        let failingSubcommandCheck: String
        if let failingSubcommand {
            failingSubcommandCheck = """
            if [ "$subcommand" = "\(failingSubcommand)" ]; then
              exit 42
            fi

            """
        } else {
            failingSubcommandCheck = ""
        }

        return """
        #!/bin/sh
        subcommand="$1"
        printf '%s' "$subcommand" >> "\(logURL.path)"
        shift
        for arg in "$@"; do
            printf '\\t%s' "$arg" >> "\(logURL.path)"
        done
        printf '\\n' >> "\(logURL.path)"

        \(failingSubcommandCheck)
        case "$subcommand" in
          sort)
            out=""
            while [ "$#" -gt 0 ]; do
              if [ "$1" = "-o" ]; then
                out="$2"
                shift 2
              else
                shift
              fi
            done
            : > "$out"
            ;;
          view)
            out=""
            while [ "$#" -gt 0 ]; do
              if [ "$1" = "-o" ]; then
                out="$2"
                shift 2
              else
                shift
              fi
            done
            if [ -n "$out" ]; then
              : > "$out"
            fi
            ;;
          index)
            bam="$1"
            : > "${bam}.bai"
            ;;
          flagstat)
            printf '%s\\n' '10 + 0 in total (QC-passed reads + QC-failed reads)'
            printf '%s\\n' '8 + 0 mapped (80.00% : N/A)'
            ;;
        esac

        exit 0
        """
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail(message(), file: file, line: line)
    } catch {
    }
}

private struct MappingFASTQFixture {
    let root: URL
    let referenceURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mapping-validation-fixture-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        referenceURL = root.appendingPathComponent("reference.fa")
        try ">ref\nACGT\n".write(to: referenceURL, atomically: true, encoding: .utf8)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeFASTQ(name: String, header: String, sequenceLength: Int) throws -> URL {
        let url = root.appendingPathComponent(name)
        let sequence = String(repeating: "A", count: sequenceLength)
        let quality = String(repeating: "I", count: sequenceLength)
        let text = "\(header)\n\(sequence)\n+\n\(quality)\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func writeFASTA(name: String, identifier: String, sequenceLength: Int) throws -> URL {
        try writeFASTA(
            name: name,
            records: [(identifier: identifier, sequenceLength: sequenceLength)]
        )
    }

    func writeFASTA(
        name: String,
        records: [(identifier: String, sequenceLength: Int)]
    ) throws -> URL {
        let url = root.appendingPathComponent(name)
        let text = records.map { record in
            let sequence = String(repeating: "A", count: record.sequenceLength)
            return ">\(record.identifier)\n\(sequence)\n"
        }.joined()
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func wrapInBundle(fastqURL: URL, bundleName: String) throws -> URL {
        let bundleURL = root.appendingPathComponent("\(bundleName).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fastqURL,
            to: bundleURL.appendingPathComponent(fastqURL.lastPathComponent)
        )
        return bundleURL
    }

    func writeReferenceBundle(
        name: String,
        fastaText: String,
        chromosomes: [ChromosomeInfo]
    ) throws -> URL {
        let bundleURL = root.appendingPathComponent(name, isDirectory: true)
        let genomeDirectory = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDirectory, withIntermediateDirectories: true)
        try fastaText.write(
            to: genomeDirectory.appendingPathComponent("sequence.fa"),
            atomically: true,
            encoding: .utf8
        )

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: name,
            identifier: "org.lungfish.tests.\(UUID().uuidString)",
            source: SourceInfo(organism: "Virus", assembly: "Test", database: "Test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: chromosomes.reduce(Int64(0)) { $0 + $1.length },
                chromosomes: chromosomes
            )
        )
        try manifest.save(to: bundleURL)
        return bundleURL
    }
}
