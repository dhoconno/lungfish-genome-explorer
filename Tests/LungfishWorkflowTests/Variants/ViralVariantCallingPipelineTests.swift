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

    func testIVarPipelineEmitsTSVAndUsesLungfishConverter() async throws {
        // Phase 6 of the reads-to-variants chapter work replaced iVar's broken
        // `--output-format vcf` flag with a TSV emit + in-process Swift
        // conversion. The command-line preserved on the bundle's variant track
        // therefore reflects iVar writing to a TSV prefix and never carries
        // the bogus `--output-format vcf` flag iVar 1.4.x has never accepted.
        let pipeline = try makePipeline(caller: .ivar)

        let plan = try await pipeline.buildExecutionPlan()

        XCTAssertFalse(plan.commandLine.contains("--output-format vcf"))
        XCTAssertTrue(plan.commandLine.contains("ivar variants"))
        XCTAssertTrue(plan.commandLine.contains("ivar.tsv-prefix"))
    }

    func testLoFreqCommandLineIncludesAdvancedArguments() async throws {
        let pipeline = try makePipeline(caller: .lofreq, advancedArguments: ["--call-indels"])

        let plan = try await pipeline.buildExecutionPlan()

        XCTAssertTrue(plan.commandLine.contains("--call-indels"))
    }

    func testLoFreqIndelCallingPreprocessesAndIndexesBAMBeforeCall() async throws {
        let toolRunner = try makeFakeVariantToolRunner()
        let pipeline = try makePipeline(
            caller: .lofreq,
            advancedArguments: ["--call-indels"],
            toolRunner: toolRunner
        )

        let result = try await pipeline.run()

        let indelqualStep = try XCTUnwrap(result.provenanceSteps.first { step in
            step.toolName == "lofreq" && step.command.contains("indelqual")
        })
        let indexStep = try XCTUnwrap(result.provenanceSteps.first { step in
            step.toolName == "lofreq" && step.command.contains("index")
        })
        let callStep = try XCTUnwrap(result.provenanceSteps.first { step in
            step.toolName == "lofreq" && step.command.contains("call")
        })
        let indelqualOutput = try XCTUnwrap(indelqualStep.outputs.first { record in
            record.path.hasSuffix("lofreq.indelqual.bam")
        })
        let indelqualIndexOutput = try XCTUnwrap(indexStep.outputs.first { record in
            record.path.hasSuffix("lofreq.indelqual.bam.bai")
        })

        XCTAssertTrue(indelqualStep.command.contains("--dindel"))
        XCTAssertTrue(indelqualStep.command.contains("-f"))
        XCTAssertEqual(indelqualOutput.format, .bam)
        XCTAssertTrue(indexStep.inputs.contains { $0.path == indelqualOutput.path && $0.sha256 != nil && $0.sizeBytes != nil })
        XCTAssertTrue(callStep.command.contains("--call-indels"))
        XCTAssertTrue(callStep.inputs.contains { $0.path == indelqualOutput.path && $0.sha256 != nil && $0.sizeBytes != nil })
        XCTAssertTrue(callStep.inputs.contains { $0.path == indelqualIndexOutput.path && $0.sha256 != nil && $0.sizeBytes != nil })
        XCTAssertTrue(result.commandLine.contains("lofreq indelqual"))
        XCTAssertTrue(result.commandLine.contains("lofreq index"))
        XCTAssertTrue(result.commandLine.contains("lofreq call"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.normalizedVCFURL.path))
    }

    func testCallerVCFIsReheaderedFromStagedReferenceBeforeSorting() async throws {
        let toolRunner = try makeFakeVariantToolRunner()
        let pipeline = try makePipeline(
            caller: .lofreq,
            advancedArguments: ["--call-indels"],
            toolRunner: toolRunner
        )

        let result = try await pipeline.run()

        let reheaderStep = try XCTUnwrap(result.provenanceSteps.first { step in
            step.toolName == "bcftools" && step.command.contains("reheader")
        })
        XCTAssertTrue(reheaderStep.command.contains("-f"))
        XCTAssertTrue(reheaderStep.inputs.contains { $0.path.hasSuffix("reference.fa.fai") })

        let normalizedVCF = try String(contentsOf: result.normalizedVCFURL, encoding: .utf8)
        XCTAssertTrue(normalizedVCF.contains("##contig=<ID=chr1,length=20>"))
        let sortStep = try XCTUnwrap(result.provenanceSteps.first { step in
            step.toolName == "bcftools" && step.command.contains("sort")
        })
        XCTAssertTrue(sortStep.inputs.contains { $0.path.hasSuffix("caller-with-reference-contigs.vcf") })
    }

    func testIVarCommandLineIncludesAdvancedArguments() async throws {
        let pipeline = try makePipeline(caller: .ivar, advancedArguments: ["-g", "primers.gff"])

        let plan = try await pipeline.buildExecutionPlan()

        XCTAssertTrue(plan.commandLine.contains("ivar variants"))
        XCTAssertTrue(plan.commandLine.contains("-g primers.gff"))
    }

    func testIVarCommandLineIncludesPlannedBundleGFFWhenAnnotationsArePresent() async throws {
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

        let plan = try await pipeline.buildExecutionPlan()

        XCTAssertTrue(plan.commandLine.contains("-g \(plan.workingDirectory.appendingPathComponent("ivar-annotations.gff3").path)"))
    }

    // MARK: - Medaka 2.x invocation

    func testMedakaCommandLineRunsMedakaVariantWrapperWithModelThreadsAndAdvancedArguments() async throws {
        // medaka 2.x dropped the `medaka variant` subcommand. Haploid calling
        // is the `medaka_variant` wrapper, which takes the reads (-i), the
        // reference (-r), an output folder (-o), the model (-m) and threads
        // (-t) and writes <folder>/medaka.annotated.vcf.
        let pipeline = try makePipeline(
            caller: .medaka,
            medakaModel: "r941_prom_sup_variant_g507",
            advancedArguments: ["-b", "200"]
        )

        let plan = try await pipeline.buildExecutionPlan()
        let fastq = try XCTUnwrap(plan.medakaFASTQURL)
        let outputDirectory = plan.rawVCFURL.deletingLastPathComponent().appendingPathComponent("medaka").path

        XCTAssertTrue(plan.commandLine.hasPrefix("medaka_variant "), plan.commandLine)
        XCTAssertFalse(plan.commandLine.contains("medaka variant"))
        XCTAssertTrue(plan.commandLine.contains("-b 200"))
        XCTAssertTrue(plan.commandLine.contains("-i \(fastq.path)"))
        XCTAssertTrue(plan.commandLine.contains("-r \(plan.referenceURL.path)"))
        XCTAssertTrue(plan.commandLine.contains("-o \(outputDirectory)"))
        XCTAssertTrue(plan.commandLine.contains("-m r941_prom_sup_variant_g507"))
        XCTAssertTrue(plan.commandLine.contains("-t 2"))
        XCTAssertTrue(plan.commandLine.contains(" -f"), "medaka_variant must overwrite a stale output folder")
    }

    func testMedakaPipelineAdoptsAnnotatedVCFAndRecordsWrapperProvenance() async throws {
        let toolRunner = try makeFakeVariantToolRunner()
        let pipeline = try makePipeline(
            caller: .medaka,
            medakaModel: "r941_prom_sup_variant_g507",
            toolRunner: toolRunner,
            bamToFASTQConverter: { _, outputFASTQ, _, _, _, _, _, _ in
                try "@read-1\nACGT\n+\n!!!!\n".write(to: outputFASTQ, atomically: true, encoding: .utf8)
            }
        )

        let result = try await pipeline.run()

        let step = try XCTUnwrap(result.provenanceSteps.first { $0.toolName == "medaka_variant" })
        XCTAssertTrue(step.command[0].hasSuffix("/envs/medaka/bin/medaka_variant"), step.command[0])
        XCTAssertTrue(step.command.contains("-m"))
        XCTAssertTrue(step.command.contains("r941_prom_sup_variant_g507"))
        XCTAssertTrue(step.toolVersion.hasPrefix("2.2.2"), "version must come from `medaka --version`, got \(step.toolVersion)")
        XCTAssertTrue(step.outputs.contains { $0.path.hasSuffix("medaka/medaka.annotated.vcf") })
        XCTAssertTrue(result.commandLine.contains("medaka_variant"))
        XCTAssertEqual(result.callerVersion, "2.2.2")

        // The wrapper calls `medaka`, `mini_align` and `bcftools` by bare
        // name, so the medaka environment's bin must lead PATH.
        let observedPath = try String(contentsOf: tempDir.appendingPathComponent("medaka-observed-path.txt"), encoding: .utf8)
        XCTAssertTrue(observedPath.hasPrefix(fakeEnvironmentBinPath("medaka")), observedPath)

        let normalized = try String(contentsOf: result.normalizedVCFURL, encoding: .utf8)
        XCTAssertTrue(normalized.contains("chr1\t5\tmedaka-1"), "annotated VCF must feed the normalized track")
    }

    // MARK: - Clair3 platform and model

    func testClair3CommandLineUsesDetectedPlatformShippedModelAndAllContigs() async throws {
        let toolRunner = try makeFakeVariantToolRunner()
        let pipeline = try makePipeline(
            caller: .clair3,
            medakaModel: "r941_prom_sup_g5014",
            advancedArguments: ["--enable_phasing"],
            toolRunner: toolRunner,
            detectedPlatform: .ont
        )

        let plan = try await pipeline.buildExecutionPlan()
        let outputDirectory = plan.rawVCFURL.deletingLastPathComponent().appendingPathComponent("clair3").path

        XCTAssertTrue(plan.commandLine.hasPrefix("run_clair3.sh "), plan.commandLine)
        XCTAssertTrue(plan.commandLine.contains("--bam_fn=\(plan.alignmentURL.path)"))
        XCTAssertTrue(plan.commandLine.contains("--ref_fn=\(plan.referenceURL.path)"))
        XCTAssertTrue(plan.commandLine.contains("--output=\(outputDirectory)"))
        XCTAssertTrue(plan.commandLine.contains("--platform=ont"))
        XCTAssertTrue(plan.commandLine.contains("--model_path=\(fakeEnvironmentBinPath("clair3"))/models/r941_prom_sup_g5014"))
        XCTAssertTrue(plan.commandLine.contains("--threads=2"))
        XCTAssertTrue(plan.commandLine.contains("--include_all_ctgs"))
        XCTAssertTrue(plan.commandLine.contains("--enable_phasing"))
        XCTAssertEqual(plan.platform, .ont)
    }

    func testClair3PlatformComesFromRequestBeforeReadGroupsAndPicksThePlatformDefaultModel() async throws {
        let toolRunner = try makeFakeVariantToolRunner()

        let hifi = try makePipeline(caller: .clair3, medakaModel: nil, toolRunner: toolRunner, platform: .hifi, detectedPlatform: .ont)
        let hifiPlan = try await hifi.buildExecutionPlan()
        XCTAssertTrue(hifiPlan.commandLine.contains("--platform=hifi"), hifiPlan.commandLine)
        XCTAssertTrue(hifiPlan.commandLine.contains("--model_path=\(fakeEnvironmentBinPath("clair3"))/models/hifi"))

        let illumina = try makePipeline(caller: .clair3, medakaModel: nil, toolRunner: toolRunner, detectedPlatform: .ilmn)
        let illuminaPlan = try await illumina.buildExecutionPlan()
        XCTAssertTrue(illuminaPlan.commandLine.contains("--platform=ilmn"), illuminaPlan.commandLine)
        XCTAssertTrue(illuminaPlan.commandLine.contains("--model_path=\(fakeEnvironmentBinPath("clair3"))/models/ilmn"))
    }

    func testClair3RefusesToGuessThePlatform() async throws {
        let toolRunner = try makeFakeVariantToolRunner()
        let pipeline = try makePipeline(caller: .clair3, medakaModel: nil, toolRunner: toolRunner, detectedPlatform: nil)

        do {
            _ = try await pipeline.buildExecutionPlan()
            XCTFail("Expected Clair3 to require a platform")
        } catch let error as ViralVariantCallingPipelineError {
            guard case .platformUnknown = error else {
                return XCTFail("Unexpected error \(error)")
            }
        }
    }

    func testClair3UnknownModelNameFailsBeforeRunningWithShippedModelsListed() async throws {
        let toolRunner = try makeFakeVariantToolRunner()
        let pipeline = try makePipeline(
            caller: .clair3,
            medakaModel: "r1041_e82_400bps_sup_v5.0.0",
            toolRunner: toolRunner,
            detectedPlatform: .ont
        )

        do {
            _ = try await pipeline.buildExecutionPlan()
            XCTFail("Expected an unknown Clair3 model name to be refused")
        } catch let error as ViralVariantCallingPipelineError {
            guard case .clair3ModelUnavailable(let message) = error else {
                return XCTFail("Unexpected error \(error)")
            }
            XCTAssertTrue(message.contains("r941_prom_sup_g5014"), message)
            XCTAssertTrue(message.contains("r1041_e82_400bps_sup_v5.0.0"), message)
        }
    }

    func testClair3PipelineDecompressesMergeOutputAndAppliesThresholds() async throws {
        let toolRunner = try makeFakeVariantToolRunner()
        let pipeline = try makePipeline(
            caller: .clair3,
            medakaModel: "r941_prom_sup_g5014",
            toolRunner: toolRunner,
            minimumAlleleFrequency: 0.5,
            minimumDepth: 10,
            detectedPlatform: .ont
        )

        let result = try await pipeline.run()

        let clair3Step = try XCTUnwrap(result.provenanceSteps.first { $0.toolName == "run_clair3.sh" })
        XCTAssertTrue(clair3Step.command.contains("--platform=ont"))
        XCTAssertTrue(clair3Step.outputs.contains { $0.path.hasSuffix("clair3/merge_output.vcf.gz") })
        let observedPath = try String(contentsOf: tempDir.appendingPathComponent("clair3-observed-path.txt"), encoding: .utf8)
        XCTAssertTrue(observedPath.hasPrefix(fakeEnvironmentBinPath("clair3")), observedPath)

        // merge_output.vcf.gz is bgzipped; the raw VCF the threshold filter
        // and reheader read must be plain text or the AF/DP header check
        // silently skips both thresholds.
        let filterStep = try XCTUnwrap(result.provenanceSteps.first { $0.toolName == "bcftools" && $0.command.contains("view") })
        XCTAssertTrue(filterStep.command.contains("FORMAT/AF>=0.5 && FORMAT/DP>=10"), filterStep.command.joined(separator: " "))
        XCTAssertTrue(result.callerParametersJSON.contains("\"minimumAlleleFrequency\":0.5"))
        XCTAssertTrue(result.callerParametersJSON.contains("\"platform\":\"ont\""), result.callerParametersJSON)
        XCTAssertTrue(result.callerParametersJSON.contains("\"clair3ModelPath\":\""), result.callerParametersJSON)
        XCTAssertTrue(result.callerParametersJSON.contains("r941_prom_sup_g5014\""), result.callerParametersJSON)

        let normalized = try String(contentsOf: result.normalizedVCFURL, encoding: .utf8)
        XCTAssertTrue(normalized.contains("chr1\t5\tclair3-1"), "the decompressed Clair3 call must reach the normalized VCF")
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

    func testBcftoolsCommandLineUsesMpileupCallAndAdvancedArguments() async throws {
        let pipeline = try makePipeline(caller: .bcftools, advancedArguments: ["-P", "0.001"])

        let plan = try await pipeline.buildExecutionPlan()

        XCTAssertTrue(plan.commandLine.contains("bcftools mpileup"))
        XCTAssertTrue(plan.commandLine.contains(" | bcftools call -P 0.001"))
        XCTAssertTrue(plan.commandLine.contains("--ploidy 1"))
    }

    // MARK: - SCI-04: bcftools haploid calling and amplicon depth cap

    func testBcftoolsCommandLineIsHaploidWithUncappedAmpliconDepth() async throws {
        // SCI-04: bcftools previously ran with implicit diploid genotyping
        // and the tool's default 250-read max-depth, which is far below
        // typical amplicon coverage. The mpileup stage must request AD/DP
        // tags and an effectively unlimited depth, and the call stage must
        // request haploid genotypes for this viral fixture bundle.
        let pipeline = try makePipeline(caller: .bcftools)

        let plan = try await pipeline.buildExecutionPlan()

        XCTAssertTrue(plan.commandLine.contains("bcftools mpileup"))
        XCTAssertTrue(plan.commandLine.contains("-d 0"))
        XCTAssertTrue(plan.commandLine.contains("-a FORMAT/AD,FORMAT/DP,INFO/AD"))
        XCTAssertTrue(plan.commandLine.contains("--ploidy 1"))
        XCTAssertEqual(pipeline.resolvedPloidy, .haploid)
    }

    // MARK: - bcftools ploidy follows the reference organism

    func testBcftoolsCommandLineIsDiploidForHumanReferenceBundle() async throws {
        // Regression: SCI-04 made `--ploidy 1` unconditional, which on the
        // manual's HG002 chromosome 20 example dropped 623 heterozygous
        // sites and wrote every genotype as `1`. A human bundle must call
        // diploid by default.
        let pipeline = try makePipeline(caller: .bcftools, sourceOrganism: "Homo sapiens")

        let plan = try await pipeline.buildExecutionPlan()

        XCTAssertTrue(plan.commandLine.contains("--ploidy 2"))
        XCTAssertFalse(plan.commandLine.contains("--ploidy 1"))
        XCTAssertEqual(pipeline.resolvedPloidy, .diploid)
    }

    func testBcftoolsCommandLineIsDiploidForFASTASliceNamedAfterGRCh38() async throws {
        // The manual's fixture is imported from `GRCh38.chr20.10.0-10.5Mb.fasta`,
        // so the organism field holds the bundle name rather than a species.
        let pipeline = try makePipeline(caller: .bcftools, sourceOrganism: "GRCh38.chr20.10.0-10.5Mb")

        XCTAssertEqual(pipeline.resolvedPloidy, .diploid)
        let plan = try await pipeline.buildExecutionPlan()
        XCTAssertTrue(plan.commandLine.contains("--ploidy 2"))
    }

    func testExplicitPloidyOverridesManifestDefault() async throws {
        let viralAsDiploid = try makePipeline(caller: .bcftools, ploidy: .diploid)
        let humanAsHaploid = try makePipeline(caller: .bcftools, sourceOrganism: "Homo sapiens", ploidy: .haploid)

        let diploidPlan = try await viralAsDiploid.buildExecutionPlan()
        let haploidPlan = try await humanAsHaploid.buildExecutionPlan()
        XCTAssertTrue(diploidPlan.commandLine.contains("--ploidy 2"))
        XCTAssertTrue(haploidPlan.commandLine.contains("--ploidy 1"))
    }

    func testBcftoolsRejectsPloidyInAdvancedArguments() async throws {
        // A `--ploidy` typed into Extra arguments used to be silently
        // overridden by LGE's own flag. It is now refused outright so the
        // Ploidy setting is the single source of truth.
        let pipeline = try makePipeline(caller: .bcftools, advancedArguments: ["--ploidy", "2"])

        do {
            _ = try await pipeline.buildExecutionPlan()
            XCTFail("Expected the reserved --ploidy argument to be refused")
        } catch {
            XCTAssertEqual(
                error as? ViralVariantCallingPipelineError,
                .reservedAdvancedArgument(VariantCallingPloidy.reservedExtraArgumentMessage)
            )
        }
    }

    func testNonBcftoolsCallersIgnorePloidyInAdvancedArguments() async throws {
        // Only bcftools owns the reserved flag. LoFreq's arguments are passed
        // through untouched, as before.
        let pipeline = try makePipeline(caller: .lofreq, advancedArguments: ["--ploidy", "2"])

        _ = try await pipeline.buildExecutionPlan()
    }

    func testBcftoolsCallerParametersJSONRecordsPloidyAndBasis() async throws {
        let toolRunner = try makeFakeVariantToolRunner()
        let derived = try makePipeline(caller: .bcftools, toolRunner: toolRunner, sourceOrganism: "Homo sapiens")
        let explicit = try makePipeline(caller: .bcftools, toolRunner: toolRunner, ploidy: .diploid)

        let derivedResult = try await derived.run()
        let explicitResult = try await explicit.run()

        let derivedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(derivedResult.callerParametersJSON.data(using: .utf8))) as? [String: Any])
        XCTAssertEqual(derivedJSON["ploidy"] as? Int, 2)
        XCTAssertEqual(derivedJSON["ploidyBasis"] as? String, "organismName")
        XCTAssertTrue(derivedResult.commandLine.contains("--ploidy 2"))
        XCTAssertTrue(derivedResult.provenanceSteps.contains { step in
            step.toolName == "bcftools" && step.command.contains("call") && step.command.contains("--ploidy") && step.command.contains("2")
        })

        let explicitJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(explicitResult.callerParametersJSON.data(using: .utf8))) as? [String: Any])
        XCTAssertEqual(explicitJSON["ploidy"] as? Int, 2)
        XCTAssertEqual(explicitJSON["ploidyBasis"] as? String, "explicit")
    }

    func testNonBcftoolsCallerParametersJSONOmitsPloidy() async throws {
        let toolRunner = try makeFakeVariantToolRunner()
        let pipeline = try makePipeline(caller: .lofreq, advancedArguments: ["--call-indels"], toolRunner: toolRunner)

        let result = try await pipeline.run()

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(result.callerParametersJSON.data(using: .utf8))) as? [String: Any])
        XCTAssertNil(json["ploidy"])
        XCTAssertNil(json["ploidyBasis"])
    }

    // MARK: - SCI-03: minimum AF and depth thresholds applied for non-iVar callers

    func testLoFreqBelowThresholdVariantIsFilteredAndProvenanceRecordsAppliedThreshold() async throws {
        // SCI-03: min-AF and min-depth were silently ignored for LoFreq,
        // bcftools, Medaka and Clair3, while provenance claimed they were
        // applied. A 4% variant with the dialog's default 0.05 threshold
        // must be filtered out, and the applied threshold recorded.
        let pipeline = try makePipeline(
            caller: .lofreq,
            callerExecutor: { plan, _ in
                try """
                ##fileformat=VCFv4.2
                ##contig=<ID=chr1,length=20>
                ##INFO=<ID=AF,Number=1,Type=Float,Description="Allele frequency">
                ##INFO=<ID=DP,Number=1,Type=Integer,Description="Depth">
                #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
                chr1\t5\tlofreq-below\tA\tG\t80\tPASS\tAF=0.040000;DP=2000
                chr1\t6\tlofreq-above\tA\tG\t80\tPASS\tAF=0.300000;DP=2000
                """.write(to: plan.rawVCFURL, atomically: true, encoding: .utf8)
            }
        )

        let result = try await pipeline.run()

        let normalizedVCF = try String(contentsOf: result.normalizedVCFURL, encoding: .utf8)
        XCTAssertFalse(normalizedVCF.contains("lofreq-below"), "4% variant should be filtered at the 0.05 default threshold")
        XCTAssertTrue(normalizedVCF.contains("lofreq-above"), "30% variant should pass the 0.05 default threshold")

        let data = try XCTUnwrap(result.callerParametersJSON.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["minimumAlleleFrequency"] as? Double, 0.05)
        XCTAssertEqual(json["minimumDepth"] as? Int, 10)

        XCTAssertTrue(result.provenanceSteps.contains { step in
            step.toolName == "bcftools" && step.command.contains("view") && step.command.contains("-i")
        })
    }

    func testLoFreqPassingLowerThresholdKeepsFourPercentVariant() async throws {
        let pipeline = try makePipeline(
            caller: .lofreq,
            callerExecutor: { plan, _ in
                try """
                ##fileformat=VCFv4.2
                ##contig=<ID=chr1,length=20>
                ##INFO=<ID=AF,Number=1,Type=Float,Description="Allele frequency">
                ##INFO=<ID=DP,Number=1,Type=Integer,Description="Depth">
                #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
                chr1\t5\tlofreq-below\tA\tG\t80\tPASS\tAF=0.040000;DP=2000
                """.write(to: plan.rawVCFURL, atomically: true, encoding: .utf8)
            },
            minimumAlleleFrequency: 0.03
        )

        let result = try await pipeline.run()
        let normalizedVCF = try String(contentsOf: result.normalizedVCFURL, encoding: .utf8)
        XCTAssertTrue(normalizedVCF.contains("lofreq-below"), "4% variant should pass a 0.03 threshold")
    }

    func testThresholdsSkippedWhenRawVCFHeaderDoesNotDeclareTags() async throws {
        // A caller output that never declares AF/DP in its header (an
        // unusual but possible tool-output shape) must not be silently
        // claimed as filtered: bcftools would fail closed on an undeclared
        // tag, so the pipeline must skip that threshold and say so in
        // provenance rather than throwing.
        let pipeline = try makePipeline(
            caller: .lofreq,
            callerExecutor: { plan, _ in
                try """
                ##fileformat=VCFv4.2
                ##contig=<ID=chr1,length=20>
                #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
                chr1\t5\tno-tags\tA\tG\t80\tPASS\t.
                """.write(to: plan.rawVCFURL, atomically: true, encoding: .utf8)
            }
        )

        let result = try await pipeline.run()
        let normalizedVCF = try String(contentsOf: result.normalizedVCFURL, encoding: .utf8)
        XCTAssertTrue(normalizedVCF.contains("no-tags"))

        let data = try XCTUnwrap(result.callerParametersJSON.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["minimumAlleleFrequency"] as? Double)
        XCTAssertNil(json["minimumDepth"] as? Int)
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

    func testAllCallersUseStagedUncompressedReference() async throws {
        let toolRunner = try makeFakeVariantToolRunner()
        for caller in ViralVariantCaller.allCases {
            // Clair3 resolves its shipped model while planning, so it needs a
            // platform and an installation to look in.
            let pipeline = try makePipeline(
                caller: caller,
                medakaModel: nil,
                toolRunner: toolRunner,
                detectedPlatform: .ont
            )
            let plan = try await pipeline.buildExecutionPlan()
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
        callerExecutor: ViralVariantCallingPipeline.CallerExecutor? = nil,
        minimumAlleleFrequency: Double? = 0.05,
        minimumDepth: Int? = 10,
        sourceOrganism: String = "Virus",
        ploidy: VariantCallingPloidy? = nil,
        platform: VariantCallingPlatform? = nil,
        detectedPlatform: VariantCallingPlatform? = nil
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
            source: SourceInfo(organism: sourceOrganism, assembly: "TestAssembly", database: "Test"),
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
            contigValidation: .exactMatch,
            detectedPlatform: detectedPlatform
        )

        let request = BundleVariantCallingRequest(
            bundleURL: bundleURL,
            alignmentTrackID: "aln-1",
            caller: caller,
            outputTrackName: "Sample BAM • \(caller.displayName)",
            threads: 2,
            minimumAlleleFrequency: minimumAlleleFrequency,
            minimumDepth: minimumDepth,
            ivarPrimerTrimConfirmed: true,
            medakaModel: (caller == .medaka || caller == .clair3) ? medakaModel : nil,
            advancedArguments: advancedArguments,
            ploidy: ploidy,
            platform: platform
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
        try writeFakeTool(home: home, environment: "lofreq", executable: "lofreq", script: """
        #!/bin/sh
        if [ "$1" = "--version" ] || [ "$1" = "version" ]; then echo "version: 2.1.5"; exit 0; fi
        if [ "$1" = "indelqual" ]; then
          output=""
          input=""
          while [ "$#" -gt 0 ]; do
            if [ "$1" = "-o" ]; then shift; output="$1"; else input="$1"; fi
            shift
          done
          cp "$input" "$output"
          exit 0
        fi
        if [ "$1" = "index" ]; then
          touch "$2.bai"
          exit 0
        fi
        if [ "$1" = "call" ]; then
          output=""
          input=""
          while [ "$#" -gt 0 ]; do
            if [ "$1" = "-o" ]; then shift; output="$1"; else input="$1"; fi
            shift
          done
          case "$input" in
            *lofreq.indelqual.bam) ;;
            *) echo "expected indelqual BAM input, got $input" >&2; exit 2 ;;
          esac
          cat > "$output" <<'EOF'
        ##fileformat=VCFv4.3
        #CHROM	POS	ID	REF	ALT	QUAL	FILTER	INFO
        chr1	5	lofreq-1	A	G	80	PASS	.
        EOF
          exit 0
        fi
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
        if [ "$1" = "reheader" ]; then
          output=""
          input=""
          while [ "$#" -gt 0 ]; do
            if [ "$1" = "-o" ]; then shift; output="$1"; else input="$1"; fi
            shift
          done
          awk 'BEGIN { added=0 } /^##fileformat=/ { print; print "##contig=<ID=chr1,length=20>"; added=1; next } { print }' "$input" > "$output"
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
        // medaka 2.2.2: `medaka` answers --version; the `medaka_variant`
        // wrapper takes -i/-r/-o/-m/-t and writes <out>/medaka.annotated.vcf.
        // Both record the PATH they ran under so the test can prove the
        // environment's bin directory led it.
        try writeFakeTool(home: home, environment: "medaka", executable: "medaka", script: """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "medaka 2.2.2"; exit 0; fi
        exit 0
        """)
        try writeFakeTool(home: home, environment: "medaka", executable: "medaka_variant", script: """
        #!/bin/sh
        printf '%s' "$PATH" > "\(tempDir.path)/medaka-observed-path.txt"
        output="medaka"
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-o" ]; then shift; output="$1"; fi
          shift
        done
        mkdir -p "$output"
        cat > "$output/medaka.annotated.vcf" <<'EOF'
        ##fileformat=VCFv4.3
        ##contig=<ID=chr1,length=20>
        ##INFO=<ID=DP,Number=1,Type=Integer,Description="Depth">
        ##INFO=<ID=AF,Number=A,Type=Float,Description="Allele frequency">
        #CHROM	POS	ID	REF	ALT	QUAL	FILTER	INFO
        chr1	5	medaka-1	A	G	80	PASS	DP=30;AF=0.9
        EOF
        """)
        // Clair3 2.0.2: run_clair3.sh, with the shipped models beside it in
        // bin/models/<name>/{pileup.pt,full_alignment.pt}, writing a
        // bgzipped merge_output.vcf.gz into --output.
        try writeFakeTool(home: home, environment: "clair3", executable: "run_clair3.sh", script: """
        #!/bin/sh
        if [ "$1" = "--version" ] || [ "$1" = "-v" ]; then echo "Clair3 v2.0.2"; exit 0; fi
        printf '%s' "$PATH" > "\(tempDir.path)/clair3-observed-path.txt"
        output=""
        for arg in "$@"; do
          case "$arg" in
            --output=*) output="${arg#--output=}" ;;
          esac
        done
        mkdir -p "$output"
        cat <<'EOF' | gzip -c > "$output/merge_output.vcf.gz"
        ##fileformat=VCFv4.2
        ##contig=<ID=chr1,length=20>
        ##FORMAT=<ID=GT,Number=1,Type=String,Description="Genotype">
        ##FORMAT=<ID=DP,Number=1,Type=Integer,Description="Read depth">
        ##FORMAT=<ID=AF,Number=1,Type=Float,Description="Allele frequency">
        #CHROM	POS	ID	REF	ALT	QUAL	FILTER	INFO	FORMAT	SAMPLE
        chr1	5	clair3-1	A	G	30	PASS	.	GT:DP:AF	1:30:0.95
        EOF
        """)
        for model in ["ont", "hifi", "ilmn", "r941_prom_sup_g5014", "r1041_e82_400bps_sup_v500"] {
            let modelDirectory = home
                .appendingPathComponent(".lungfish/conda/envs/clair3/bin/models", isDirectory: true)
                .appendingPathComponent(model, isDirectory: true)
            try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
            for weights in Clair3ModelResolver.requiredWeightFiles {
                try Data("weights".utf8).write(to: modelDirectory.appendingPathComponent(weights))
            }
        }
        return NativeToolRunner(toolsDirectory: nil, homeDirectory: home, appIdentity: .preview)
    }

    /// The bin directory of a fake managed environment created by
    /// `makeFakeVariantToolRunner`.
    private func fakeEnvironmentBinPath(_ environment: String) -> String {
        tempDir
            .appendingPathComponent("fake-home", isDirectory: true)
            .appendingPathComponent(".lungfish/conda/envs", isDirectory: true)
            .appendingPathComponent(environment, isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .path
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
