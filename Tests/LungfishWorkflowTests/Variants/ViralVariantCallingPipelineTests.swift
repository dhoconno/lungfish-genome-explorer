import XCTest
@testable import LungfishWorkflow
@testable import LungfishCore
@testable import LungfishIO

final class ViralVariantCallingPipelineTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ViralVariantCallingPipelineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testIVarPipelineEmitsTSVAndUsesLungfishConverter() throws {
        // Phase 6 of the reads-to-variants chapter work replaced iVar's broken
        // `--output-format vcf` flag with a TSV emit + in-process Swift
        // conversion. The command-line preserved on the bundle's variant track
        // therefore reflects iVar writing to a TSV prefix and never carries
        // the bogus `--output-format vcf` flag iVar 1.4.x has never accepted.
        let pipeline = try makePipeline(caller: .ivar)

        let plan = try pipeline.buildExecutionPlan()

        XCTAssertFalse(plan.commandLine.contains("--output-format vcf"))
        XCTAssertTrue(plan.commandLine.contains("ivar variants"))
        XCTAssertTrue(plan.commandLine.contains("ivar.tsv-prefix"))
    }

    func testLoFreqCommandLineIncludesAdvancedArguments() throws {
        let pipeline = try makePipeline(caller: .lofreq, advancedArguments: ["--call-indels"])

        let plan = try pipeline.buildExecutionPlan()

        XCTAssertTrue(plan.commandLine.contains("--call-indels"))
    }

    func testIVarCommandLineIncludesAdvancedArguments() throws {
        let pipeline = try makePipeline(caller: .ivar, advancedArguments: ["-g", "primers.gff"])

        let plan = try pipeline.buildExecutionPlan()

        XCTAssertTrue(plan.commandLine.contains("ivar variants"))
        XCTAssertTrue(plan.commandLine.contains("-g primers.gff"))
    }

    func testIVarCommandLineIncludesPlannedBundleGFFWhenAnnotationsArePresent() throws {
        let pipeline = try makePipeline(
            caller: .ivar,
            annotations: [
                AnnotationTrackInfo(
                    id: "genes",
                    name: "Genes",
                    path: "annotations/genes.bb",
                    databasePath: "annotations/genes.db"
                )
            ]
        )

        let plan = try pipeline.buildExecutionPlan()

        XCTAssertTrue(plan.commandLine.contains("-g \(plan.workingDirectory.appendingPathComponent("ivar-annotations.gff3").path)"))
    }

    func testMedakaCommandLineIncludesAdvancedArguments() throws {
        let pipeline = try makePipeline(
            caller: .medaka,
            medakaModel: "r1041_e82_400bps_sup_v5.0.0",
            advancedArguments: ["--chunk_len", "1000"]
        )

        let plan = try pipeline.buildExecutionPlan()

        XCTAssertTrue(plan.commandLine.contains("--chunk_len 1000"))
    }

    func testClair3CommandLineUsesModelThreadsAndAdvancedArguments() throws {
        let pipeline = try makePipeline(
            caller: .clair3,
            medakaModel: "r1041_e82_400bps_sup_v5.0.0",
            advancedArguments: ["--enable_phasing"]
        )

        let plan = try pipeline.buildExecutionPlan()

        XCTAssertTrue(plan.commandLine.contains("run_clair3.sh"))
        XCTAssertTrue(plan.commandLine.contains("--bam_fn=\(plan.alignmentURL.path)"))
        XCTAssertTrue(plan.commandLine.contains("--ref_fn=\(plan.referenceURL.path)"))
        XCTAssertTrue(plan.commandLine.contains("--output=\(plan.rawVCFURL.deletingLastPathComponent().path)"))
        XCTAssertTrue(plan.commandLine.contains("--model_path=r1041_e82_400bps_sup_v5.0.0"))
        XCTAssertTrue(plan.commandLine.contains("--threads=2"))
        XCTAssertTrue(plan.commandLine.contains("--enable_phasing"))
    }

    func testPhasedVariantPlanBuildsGATKAndWhatsHapCommandsWithResolvedDefaults() throws {
        let plan = PhasedVariantCallingPlan(
            configuration: PhasedVariantCallingConfiguration(
                referenceFASTAURL: URL(fileURLWithPath: "/tmp/ref.fa"),
                inputBAMURL: URL(fileURLWithPath: "/tmp/sample.bam"),
                outputVCFURL: URL(fileURLWithPath: "/tmp/phased.vcf.gz"),
                outputDirectory: URL(fileURLWithPath: "/tmp/phased-plan", isDirectory: true),
                threads: 4,
                extraGATKArguments: ["--sample-ploidy", "1"],
                extraWhatsHapArguments: ["--ignore-read-groups"]
            ),
            gatkVersion: "4.6.2.0",
            whatsHapVersion: "2.3",
            runtimeIdentity: PhasedVariantRuntimeIdentity(
                gatkCondaEnvironment: "/tmp/conda/envs/gatk-core",
                whatsHapCondaEnvironment: "/tmp/conda/envs/phasing"
            )
        )

        XCTAssertEqual(plan.workflowName, "lungfish variants phase")
        XCTAssertEqual(plan.commands.map(\.executable), ["gatk", "whatshap"])
        XCTAssertTrue(plan.commands[0].shellCommand.contains("HaplotypeCaller"))
        XCTAssertTrue(plan.commands[1].shellCommand.contains("whatshap phase"))
        XCTAssertEqual(plan.options["threads"], "4")
        XCTAssertEqual(plan.resolvedDefaults["emitReferenceConfidence"], "NONE")
        XCTAssertEqual(plan.packIDs, ["gatk-core", "phasing"])
    }

    func testBcftoolsCommandLineUsesMpileupCallAndAdvancedArguments() throws {
        let pipeline = try makePipeline(caller: .bcftools, advancedArguments: ["--ploidy", "1"])

        let plan = try pipeline.buildExecutionPlan()

        XCTAssertTrue(plan.commandLine.contains("bcftools mpileup"))
        XCTAssertTrue(plan.commandLine.contains(" | bcftools call"))
        XCTAssertTrue(plan.commandLine.contains("--ploidy 1"))
    }

    func testBcftoolsPipelineProvenanceCapturesMpileupPipeInputsAndChecksums() async throws {
        let toolRunner = try makeFakeVariantToolRunner()
        let pipeline = try makePipeline(caller: .bcftools, toolRunner: toolRunner)

        let result = try await pipeline.run()

        let mpileupStep = try XCTUnwrap(result.provenanceSteps.first { step in
            step.toolName == "bcftools" && step.command.contains("mpileup")
        })
        let callStep = try XCTUnwrap(result.provenanceSteps.first { step in
            step.toolName == "bcftools" && step.command.contains("call")
        })
        let pipeRecord = try XCTUnwrap(mpileupStep.outputs.first { $0.path == "pipe:stdout:bcftools-mpileup" })

        XCTAssertEqual(pipeRecord.format, .bcf)
        XCTAssertEqual(pipeRecord.role, .output)
        XCTAssertTrue(callStep.inputs.contains { $0.path == pipeRecord.path && $0.role == .input })
        XCTAssertTrue(mpileupStep.inputs.contains { $0.path == mpileupStep.inputs[0].path && $0.sha256 != nil && $0.sizeBytes != nil })
        XCTAssertTrue(mpileupStep.inputs.contains { $0.path == mpileupStep.inputs[1].path && $0.sha256 != nil && $0.sizeBytes != nil })
        XCTAssertTrue(callStep.outputs.contains { $0.path == result.normalizedVCFURL.deletingLastPathComponent().appendingPathComponent("bcftools.raw.vcf").path })
        XCTAssertTrue(result.commandLine.contains(" | "))
        XCTAssertTrue(result.commandLine.contains("/envs/bcftools/bin/bcftools"))
    }

    func testCallerParametersJSONIncludesExtraArgs() async throws {
        let pipeline = try makePipeline(
            caller: .lofreq,
            advancedArguments: ["--call-indels", "--tag", "sample 1"],
            callerExecutor: { plan, _ in
                try """
                ##fileformat=VCFv4.3
                ##contig=<ID=chr1,length=20>
                #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
                chr1\t5\tadvanced-1\tA\tG\t80\tPASS\t.
                """.write(to: plan.rawVCFURL, atomically: true, encoding: .utf8)
            }
        )

        let result = try await pipeline.run()
        let data = try XCTUnwrap(result.callerParametersJSON.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["extraArgs"] as? String, "--call-indels --tag 'sample 1'")
        XCTAssertEqual(json["advancedOptions"] as? String, "--call-indels --tag 'sample 1'")
        XCTAssertEqual(json["advancedArguments"] as? [String], ["--call-indels", "--tag", "sample 1"])
        XCTAssertTrue(result.commandLine.contains("--call-indels --tag 'sample 1'"))
        assertNativeProvenanceStep(
            in: result.provenanceSteps,
            toolName: "samtools",
            environment: "samtools",
            executable: "samtools",
            commandContains: "faidx"
        )
        assertNativeProvenanceStep(
            in: result.provenanceSteps,
            toolName: "bcftools",
            environment: "bcftools",
            executable: "bcftools",
            commandContains: "sort"
        )
        assertNativeProvenanceStep(
            in: result.provenanceSteps,
            toolName: "bgzip",
            environment: "htslib",
            executable: "bgzip",
            commandContains: "-k"
        )
        assertNativeProvenanceStep(
            in: result.provenanceSteps,
            toolName: "tabix",
            environment: "htslib",
            executable: "tabix",
            commandContains: "-p"
        )
    }

    func testAllCallersUseStagedUncompressedReference() throws {
        for caller in ViralVariantCaller.allCases {
            let pipeline = try makePipeline(caller: caller)
            let plan = try pipeline.buildExecutionPlan()
            XCTAssertTrue(plan.referenceURL.path.hasSuffix(".fa"), "Expected \(caller.rawValue) to stage an uncompressed FASTA")
            XCTAssertFalse(plan.referenceURL.path.hasSuffix(".fa.gz"), "Expected \(caller.rawValue) not to point callers at the bundle's compressed FASTA")
        }
    }

    func testMedakaPipelineUsesSharedBamToFastqConverterAndRejectsMissingMetadata() async throws {
        let converterCalled = LockedFlag()
        let pipeline = try makePipeline(
            caller: .medaka,
            medakaModel: nil,
            bamToFASTQConverter: { _, _, _, _, _, _, _, _ in
                converterCalled.setTrue()
            }
        )

        do {
            _ = try await pipeline.run()
            XCTFail("Expected Medaka pipeline to reject missing model metadata")
        } catch let error as ViralVariantCallingPipelineError {
            XCTAssertEqual(error, .medakaRequiresModelMetadata)
        }

        XCTAssertFalse(converterCalled.value)
    }

    func testMedakaPipelineInvokesSharedBamToFastqConverterBeforeCallerExecution() async throws {
        let converterCalled = LockedFlag()
        let pipeline = try makePipeline(
            caller: .medaka,
            medakaModel: "r1041_e82_400bps_sup_v5.0.0",
            bamToFASTQConverter: { _, outputFASTQ, _, _, _, _, _, _ in
                converterCalled.setTrue()
                try """
                @read-1
                ACGT
                +
                !!!!
                """.write(to: outputFASTQ, atomically: true, encoding: .utf8)
            },
            callerExecutor: { plan, _ in
                try """
                ##fileformat=VCFv4.3
                ##contig=<ID=chr1,length=20>
                ##INFO=<ID=AF,Number=1,Type=Float,Description="Allele frequency">
                ##INFO=<ID=DP,Number=1,Type=Integer,Description="Read depth">
                #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
                chr1\t5\tmedaka-1\tA\tG\t80\tPASS\tAF=0.6;DP=30
                """.write(to: plan.rawVCFURL, atomically: true, encoding: .utf8)
            }
        )

        let result = try await pipeline.run()

        XCTAssertTrue(converterCalled.value)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.normalizedVCFURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.stagedVCFGZURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.stagedTabixURL.path))
    }

    func testIVarPipelineProvenanceCapturesMpileupPipeInputsAndChecksums() async throws {
        let toolRunner = try makeFakeVariantToolRunner()
        let pipeline = try makePipeline(caller: .ivar, toolRunner: toolRunner)

        let result = try await pipeline.run()

        let samtoolsStep = try XCTUnwrap(result.provenanceSteps.first { step in
            step.toolName == "samtools" && step.command.contains("mpileup")
        })
        let ivarStep = try XCTUnwrap(result.provenanceSteps.first { step in
            step.toolName == "ivar" && step.command.contains("variants")
        })
        let pipeRecord = try XCTUnwrap(samtoolsStep.outputs.first { $0.path == "pipe:stdout:samtools-mpileup" })

        XCTAssertEqual(pipeRecord.format, .text)
        XCTAssertEqual(pipeRecord.role, .output)
        XCTAssertTrue(ivarStep.inputs.contains { $0.path == pipeRecord.path && $0.role == .input })
        XCTAssertTrue(samtoolsStep.inputs.contains { $0.path == samtoolsStep.inputs[0].path && $0.sha256 != nil && $0.sizeBytes != nil })
        XCTAssertTrue(samtoolsStep.inputs.contains { $0.path == samtoolsStep.inputs[1].path && $0.sha256 != nil && $0.sizeBytes != nil })
        XCTAssertTrue(samtoolsStep.inputs.contains { $0.path == samtoolsStep.inputs[2].path && $0.sha256 != nil && $0.sizeBytes != nil })
        XCTAssertTrue(ivarStep.inputs.contains { $0.path == samtoolsStep.inputs[0].path && $0.sha256 != nil && $0.sizeBytes != nil })
        XCTAssertTrue(result.commandLine.contains(" | "))
        XCTAssertTrue(result.commandLine.contains("/envs/samtools/bin/samtools"))
        XCTAssertTrue(result.commandLine.contains("/envs/ivar/bin/ivar"))
    }

    func testAliasMatchedBamIsReheaderedToBundleChromosomesBeforeCallerExecution() async throws {
        let bundleURL = tempDir.appendingPathComponent("alias-bundle.lungfishref", isDirectory: true)
        let referenceURL = tempDir.appendingPathComponent("alias-reference.fa")
        let referenceFAIURL = tempDir.appendingPathComponent("alias-reference.fa.fai")
        let alignmentURL = tempDir.appendingPathComponent("alias.sorted.bam")
        let alignmentIndexURL = tempDir.appendingPathComponent("alias.sorted.bam.bai")

        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try """
        >chr1
        ACGTACGTACGTACGTACGT
        """.write(to: referenceURL, atomically: true, encoding: .utf8)
        try "chr1\t20\t6\t20\t21\n".write(to: referenceFAIURL, atomically: true, encoding: .utf8)
        try await writeIndexedBAM(referenceName: "1", outputBAM: alignmentURL)

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Alias Bundle",
            identifier: "alias.bundle",
            source: SourceInfo(organism: "Virus", assembly: "TestAssembly", database: "Test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                totalLength: 20,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 20, offset: 6, lineBases: 20, lineWidth: 21, aliases: ["1"])
                ],
                md5Checksum: nil
            ),
            alignments: [
                AlignmentTrackInfo(
                    id: "aln-1",
                    name: "Alias BAM",
                    format: .bam,
                    sourcePath: "alignments/alias.sorted.bam",
                    indexPath: "alignments/alias.sorted.bam.bai",
                    checksumSHA256: "alias-bam-sha-256"
                )
            ]
        )

        let preflight = BAMVariantCallingPreflightResult(
            manifest: manifest,
            alignmentTrack: manifest.alignments[0],
            genome: try XCTUnwrap(manifest.genome),
            alignmentURL: alignmentURL,
            alignmentIndexURL: alignmentIndexURL,
            referenceFASTAURL: referenceURL,
            referenceFAIURL: referenceFAIURL,
            bamReferenceSequences: [
                SAMParser.ReferenceSequence(name: "1", length: 20, md5: nil, assembly: nil, uri: nil, species: nil)
            ],
            referenceNameMap: ["1": "chr1"],
            contigValidation: .matchedByAlias
        )

        let request = BundleVariantCallingRequest(
            bundleURL: bundleURL,
            alignmentTrackID: "aln-1",
            caller: .lofreq,
            outputTrackName: "Alias BAM • LoFreq",
            threads: 1,
            minimumAlleleFrequency: 0.05,
            minimumDepth: 10,
            ivarPrimerTrimConfirmed: true,
            medakaModel: nil
        )
        let stagingRoot = tempDir.appendingPathComponent("alias-staging-\(UUID().uuidString)", isDirectory: true)
        let pipeline = ViralVariantCallingPipeline(
            request: request,
            preflight: preflight,
            stagingRoot: stagingRoot,
            callerExecutor: { plan, runner in
                let headerResult = try await runner.run(
                    .samtools,
                    arguments: ["view", "-H", plan.alignmentURL.path],
                    timeout: 60
                )
                XCTAssertTrue(headerResult.isSuccess)
                XCTAssertTrue(headerResult.stdout.contains("SN:chr1"))
                XCTAssertFalse(headerResult.stdout.contains("SN:1\t"))
                try """
                ##fileformat=VCFv4.3
                ##contig=<ID=chr1,length=20>
                #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
                chr1\t5\talias-1\tA\tG\t80\tPASS\t.
                """.write(to: plan.rawVCFURL, atomically: true, encoding: .utf8)
            }
        )

        _ = try await pipeline.run()
    }

    private func makePipeline(
        caller: ViralVariantCaller,
        medakaModel: String? = "unused",
        advancedArguments: [String] = [],
        annotations: [AnnotationTrackInfo] = [],
        toolRunner: NativeToolRunner = .shared,
        bamToFASTQConverter: @escaping ViralVariantCallingPipeline.BAMToFASTQConverter = convertBAMToSingleFASTQ,
        callerExecutor: ViralVariantCallingPipeline.CallerExecutor? = nil
    ) throws -> ViralVariantCallingPipeline {
        let bundleURL = tempDir.appendingPathComponent("test.lungfishref", isDirectory: true)
        let referenceURL = tempDir.appendingPathComponent("reference.fa")
        let referenceFAIURL = tempDir.appendingPathComponent("reference.fa.fai")
        let alignmentURL = tempDir.appendingPathComponent("sample.sorted.bam")
        let alignmentIndexURL = tempDir.appendingPathComponent("sample.sorted.bam.bai")

        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try """
        >chr1
        ACGTACGTACGTACGTACGT
        """.write(to: referenceURL, atomically: true, encoding: .utf8)
        try "chr1\t20\t6\t20\t21\n".write(to: referenceFAIURL, atomically: true, encoding: .utf8)
        try Data("bam".utf8).write(to: alignmentURL)
        try Data("bai".utf8).write(to: alignmentIndexURL)

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Test Bundle",
            identifier: "test.bundle",
            source: SourceInfo(organism: "Virus", assembly: "TestAssembly", database: "Test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                totalLength: 20,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 20, offset: 6, lineBases: 20, lineWidth: 21, aliases: [])
                ],
                md5Checksum: nil
                ),
                annotations: annotations,
                alignments: [
                AlignmentTrackInfo(
                    id: "aln-1",
                    name: "Sample BAM",
                    format: .bam,
                    sourcePath: "alignments/sample.sorted.bam",
                    indexPath: "alignments/sample.sorted.bam.bai",
                    checksumSHA256: "bam-sha-256"
                )
            ]
        )
        try manifest.save(to: bundleURL)

        let preflight = BAMVariantCallingPreflightResult(
            manifest: manifest,
            alignmentTrack: manifest.alignments[0],
            genome: try XCTUnwrap(manifest.genome),
            alignmentURL: alignmentURL,
            alignmentIndexURL: alignmentIndexURL,
            referenceFASTAURL: referenceURL,
            referenceFAIURL: referenceFAIURL,
            bamReferenceSequences: [
                SAMParser.ReferenceSequence(name: "chr1", length: 20, md5: nil, assembly: nil, uri: nil, species: nil)
            ],
            referenceNameMap: ["chr1": "chr1"],
            contigValidation: .exactMatch
        )

        let request = BundleVariantCallingRequest(
            bundleURL: bundleURL,
            alignmentTrackID: "aln-1",
            caller: caller,
            outputTrackName: "Sample BAM • \(caller.displayName)",
            threads: 2,
            minimumAlleleFrequency: 0.05,
            minimumDepth: 10,
            ivarPrimerTrimConfirmed: true,
            medakaModel: (caller == .medaka || caller == .clair3) ? medakaModel : nil,
            advancedArguments: advancedArguments
        )

        let stagingRoot = tempDir.appendingPathComponent("staging-\(caller.rawValue)-\(UUID().uuidString)", isDirectory: true)
        return ViralVariantCallingPipeline(
            request: request,
            preflight: preflight,
            stagingRoot: stagingRoot,
            toolRunner: toolRunner,
            bamToFASTQConverter: bamToFASTQConverter,
            callerExecutor: callerExecutor
        )
    }

    private func makeFakeVariantToolRunner() throws -> NativeToolRunner {
        let home = tempDir.appendingPathComponent("fake-home", isDirectory: true)
        try writeFakeTool(home: home, environment: "samtools", executable: "samtools", script: """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "samtools 1.20"; exit 0; fi
        if [ "$1" = "faidx" ]; then printf "chr1\\t20\\t6\\t20\\t21\\n" > "$2.fai"; exit 0; fi
        if [ "$1" = "mpileup" ]; then echo "chr1\t1\tA\t1\t.\tI"; exit 0; fi
        exit 0
        """)
        try writeFakeTool(home: home, environment: "ivar", executable: "ivar", script: """
        #!/bin/sh
        if [ "$1" = "version" ]; then echo "iVar version 1.4.4"; exit 0; fi
        prefix=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-p" ]; then shift; prefix="$1"; fi
          shift
        done
        cat > /dev/null
        cat > "${prefix}.tsv" <<'EOF'
        REGION	POS	REF	ALT	REF_DP	REF_RV	REF_QUAL	ALT_DP	ALT_RV	ALT_QUAL	ALT_FREQ	TOTAL_DP	PVAL	PASS	GFF_FEATURE	REF_CODON	REF_AA	ALT_CODON	ALT_AA	POS_AA
        chr1	5	A	G	10	0	30	10	0	30	0.5	20	0	TRUE	NA	NA	NA	NA	NA	NA
        EOF
        """)
        try writeFakeTool(home: home, environment: "bcftools", executable: "bcftools", script: """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "bcftools 1.20"; exit 0; fi
        if [ "$1" = "mpileup" ]; then echo "BCF"; exit 0; fi
        if [ "$1" = "call" ]; then
          output=""
          while [ "$#" -gt 0 ]; do
            if [ "$1" = "-o" ]; then shift; output="$1"; fi
            shift
          done
          cat > /dev/null
          cat > "$output" <<'EOF'
        ##fileformat=VCFv4.3
        ##contig=<ID=chr1,length=20>
        #CHROM	POS	ID	REF	ALT	QUAL	FILTER	INFO
        chr1	5	bcftools-1	A	G	80	PASS	.
        EOF
          exit 0
        fi
        output=""
        input=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-o" ]; then shift; output="$1"; else input="$1"; fi
          shift
        done
        cp "$input" "$output"
        """)
        try writeFakeTool(home: home, environment: "htslib", executable: "bgzip", script: """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "bgzip 1.20"; exit 0; fi
        for arg in "$@"; do input="$arg"; done
        cp "$input" "$input.gz"
        """)
        try writeFakeTool(home: home, environment: "htslib", executable: "tabix", script: """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "tabix 1.20"; exit 0; fi
        for arg in "$@"; do input="$arg"; done
        touch "$input.tbi"
        """)
        return NativeToolRunner(toolsDirectory: nil, homeDirectory: home)
    }

    private func writeFakeTool(home: URL, environment: String, executable: String, script: String) throws {
        let binDir = home
            .appendingPathComponent(".lungfish/conda/envs", isDirectory: true)
            .appendingPathComponent(environment, isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let toolURL = binDir.appendingPathComponent(executable)
        try script.write(to: toolURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: toolURL.path)
    }

    private func assertNativeProvenanceStep(
        in steps: [VariantCallingProvenanceStep],
        toolName: String,
        environment: String,
        executable: String,
        commandContains commandArgument: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let step = steps.first(where: { step in
            step.toolName == toolName && step.command.contains(commandArgument)
        }) else {
            XCTFail("Missing \(toolName) provenance step containing \(commandArgument)", file: file, line: line)
            return
        }

        let executableSuffix = "/envs/\(environment)/bin/\(executable)"
        XCTAssertTrue(
            step.command.first?.hasSuffix(executableSuffix) == true,
            "Expected resolved executable path ending in \(executableSuffix), got \(step.command.first ?? "<nil>")",
            file: file,
            line: line
        )
        XCTAssertTrue(
            step.toolVersion.contains("managed conda environment \(environment)"),
            "Expected managed runtime identity in \(step.toolVersion)",
            file: file,
            line: line
        )
        XCTAssertTrue(
            step.toolVersion.contains("executable \(executable)"),
            "Expected executable identity in \(step.toolVersion)",
            file: file,
            line: line
        )
    }
}

private extension ViralVariantCallingPipelineTests {
    func writeIndexedBAM(referenceName: String, outputBAM: URL) async throws {
        let samURL = tempDir.appendingPathComponent("alias-input.sam")
        try """
        @HD\tVN:1.6\tSO:coordinate
        @SQ\tSN:\(referenceName)\tLN:20
        @RG\tID:rg1\tPL:ONT\tDS:basecall_model=r1041_e82_400bps_sup_v5.0.0
        read1\t0\t\(referenceName)\t1\t60\t4M\t*\t0\t0\tACGT\t!!!!
        """.write(to: samURL, atomically: true, encoding: .utf8)

        let bamResult = try await NativeToolRunner.shared.run(
            .samtools,
            arguments: ["view", "-b", "-o", outputBAM.path, samURL.path],
            timeout: 60
        )
        XCTAssertTrue(bamResult.isSuccess, bamResult.combinedOutput)

        let indexResult = try await NativeToolRunner.shared.run(
            .samtools,
            arguments: ["index", outputBAM.path],
            timeout: 60
        )
        XCTAssertTrue(indexResult.isSuccess, indexResult.combinedOutput)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var state = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func setTrue() {
        lock.lock()
        state = true
        lock.unlock()
    }
}
