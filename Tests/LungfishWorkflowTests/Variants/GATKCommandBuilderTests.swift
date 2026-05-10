import XCTest
@testable import LungfishWorkflow

final class GATKCommandBuilderTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/gatk-foundation")

    func testBuildsHaplotypeCallerGVCFCommandWithDefaults() throws {
        let command = GATKCommandBuilder.haplotypeCallerCommand(
            GATKHaplotypeCallerConfiguration(
                referenceFASTAURL: root.appendingPathComponent("reference.fa"),
                inputBAMURL: root.appendingPathComponent("sample.sorted.bam"),
                outputVCFURL: root.appendingPathComponent("sample.g.vcf.gz")
            )
        )

        XCTAssertEqual(command.executable, "gatk")
        XCTAssertEqual(command.environment, "gatk-core")
        XCTAssertEqual(command.arguments.prefix(1), ["HaplotypeCaller"])
        XCTAssertArgumentPair(command.arguments, "-R", root.appendingPathComponent("reference.fa").path)
        XCTAssertArgumentPair(command.arguments, "-I", root.appendingPathComponent("sample.sorted.bam").path)
        XCTAssertArgumentPair(command.arguments, "-O", root.appendingPathComponent("sample.g.vcf.gz").path)
        XCTAssertArgumentPair(command.arguments, "-ERC", "GVCF")
        XCTAssertArgumentPair(command.arguments, "--sample-ploidy", "2")
        XCTAssertArgumentPair(command.arguments, "--max-alternate-alleles", "6")
        XCTAssertArgumentPair(command.arguments, "--pcr-indel-model", "CONSERVATIVE")
        XCTAssertArgumentPair(command.arguments, "--native-pair-hmm-threads", "4")
    }

    func testRoutesJointGenotypingAutoStrategyAtThreshold() {
        XCTAssertEqual(
            GATKCommandBuilder.resolvedJointGenotypingStrategy(sampleCount: 50, requested: .auto),
            .combineGVCFs
        )
        XCTAssertEqual(
            GATKCommandBuilder.resolvedJointGenotypingStrategy(sampleCount: 51, requested: .auto),
            .genomicsDB
        )
    }

    func testBuildsCombineGVCFsJointGenotypingCommands() throws {
        let config = GATKJointGenotypingConfiguration(
            referenceFASTAURL: root.appendingPathComponent("reference.fa"),
            inputGVCFURLs: [
                root.appendingPathComponent("s1.g.vcf.gz"),
                root.appendingPathComponent("s2.g.vcf.gz"),
            ],
            outputVCFURL: root.appendingPathComponent("cohort.vcf.gz"),
            intermediateURL: root.appendingPathComponent("cohort.combined.g.vcf.gz"),
            strategy: .combineGVCFs
        )

        let commands = GATKCommandBuilder.jointGenotypingCommands(config)

        XCTAssertEqual(commands.map(\.arguments.first), ["CombineGVCFs", "GenotypeGVCFs"])
        XCTAssertArgumentPair(commands[0].arguments, "-O", root.appendingPathComponent("cohort.combined.g.vcf.gz").path)
        XCTAssertArgumentPair(commands[0].arguments, "--variant", root.appendingPathComponent("s1.g.vcf.gz").path)
        XCTAssertArgumentPair(commands[0].arguments, "--variant", root.appendingPathComponent("s2.g.vcf.gz").path)
        XCTAssertArgumentPair(commands[1].arguments, "-V", root.appendingPathComponent("cohort.combined.g.vcf.gz").path)
        XCTAssertArgumentPair(commands[1].arguments, "--standard-min-confidence-threshold-for-calling", "30.0")
    }

    func testVariantFiltrationBestPracticePresetExpressions() {
        XCTAssertEqual(
            GATKVariantFiltrationPreset.bestPracticesSNP.filters,
            [
                GATKVariantFilter(name: "QD2", expression: "QD < 2.0"),
                GATKVariantFilter(name: "FS60", expression: "FS > 60.0"),
                GATKVariantFilter(name: "MQ40", expression: "MQ < 40.0"),
                GATKVariantFilter(name: "MQRankSum-12.5", expression: "MQRankSum < -12.5"),
                GATKVariantFilter(name: "ReadPosRankSum-8", expression: "ReadPosRankSum < -8.0"),
                GATKVariantFilter(name: "SOR3", expression: "SOR > 3.0"),
            ]
        )
        XCTAssertEqual(
            GATKVariantFiltrationPreset.bestPracticesIndel.filters,
            [
                GATKVariantFilter(name: "QD2", expression: "QD < 2.0"),
                GATKVariantFilter(name: "FS200", expression: "FS > 200.0"),
                GATKVariantFilter(name: "ReadPosRankSum-20", expression: "ReadPosRankSum < -20.0"),
                GATKVariantFilter(name: "SOR10", expression: "SOR > 10.0"),
            ]
        )
    }

    func testBuildsSelectVariantsAndVariantsToTableCommands() {
        let select = GATKCommandBuilder.selectVariantsCommand(
            GATKSelectVariantsConfiguration(
                inputVCFURL: root.appendingPathComponent("cohort.vcf.gz"),
                outputVCFURL: root.appendingPathComponent("sample.snp.vcf.gz"),
                sampleID: "HG00096",
                variantType: .snp,
                intervalsURL: root.appendingPathComponent("targets.interval_list")
            )
        )
        XCTAssertEqual(select.arguments.first, "SelectVariants")
        XCTAssertArgumentPair(select.arguments, "-sn", "HG00096")
        XCTAssertArgumentPair(select.arguments, "-select-type", "SNP")
        XCTAssertArgumentPair(select.arguments, "-L", root.appendingPathComponent("targets.interval_list").path)

        let table = GATKCommandBuilder.variantsToTableCommand(
            GATKVariantsToTableConfiguration(
                inputVCFURL: root.appendingPathComponent("cohort.vcf.gz"),
                outputTableURL: root.appendingPathComponent("cohort.tsv"),
                fields: ["CHROM", "POS", "REF", "ALT", "QUAL", "AF", "DP"]
            )
        )
        XCTAssertEqual(table.arguments.first, "VariantsToTable")
        XCTAssertArgumentPair(table.arguments, "-O", root.appendingPathComponent("cohort.tsv").path)
        XCTAssertArgumentPair(table.arguments, "-F", "CHROM")
        XCTAssertArgumentPair(table.arguments, "-F", "DP")
    }

    func testBuildsBQSRCommandsWithKnownSitesAndPassthroughArguments() {
        let commands = GATKCommandBuilder.baseQualityScoreRecalibrationCommands(
            GATKBaseQualityScoreRecalibrationConfiguration(
                referenceFASTAURL: root.appendingPathComponent("reference.fa"),
                inputBAMURL: root.appendingPathComponent("sample.sorted.bam"),
                outputBAMURL: root.appendingPathComponent("sample.recalibrated.bam"),
                knownSitesVCFURLs: [
                    root.appendingPathComponent("dbsnp.vcf.gz"),
                    root.appendingPathComponent("mills.vcf.gz"),
                ],
                recalibrationTableURL: root.appendingPathComponent("sample.recal.table"),
                intervalsURL: root.appendingPathComponent("targets.interval_list"),
                extraArguments: ["--disable-sequence-dictionary-validation"]
            )
        )

        XCTAssertEqual(commands.map(\.arguments.first), ["BaseRecalibrator", "ApplyBQSR"])
        XCTAssertArgumentPair(commands[0].arguments, "-R", root.appendingPathComponent("reference.fa").path)
        XCTAssertArgumentPair(commands[0].arguments, "-I", root.appendingPathComponent("sample.sorted.bam").path)
        XCTAssertArgumentPair(commands[0].arguments, "-O", root.appendingPathComponent("sample.recal.table").path)
        XCTAssertArgumentPair(commands[0].arguments, "--known-sites", root.appendingPathComponent("dbsnp.vcf.gz").path)
        XCTAssertArgumentPair(commands[0].arguments, "--known-sites", root.appendingPathComponent("mills.vcf.gz").path)
        XCTAssertArgumentPair(commands[0].arguments, "-L", root.appendingPathComponent("targets.interval_list").path)
        XCTAssertTrue(commands[0].arguments.contains("--disable-sequence-dictionary-validation"))

        XCTAssertArgumentPair(commands[1].arguments, "--bqsr-recal-file", root.appendingPathComponent("sample.recal.table").path)
        XCTAssertArgumentPair(commands[1].arguments, "-O", root.appendingPathComponent("sample.recalibrated.bam").path)
        XCTAssertArgumentPair(commands[1].arguments, "--create-output-bam-index", "true")
        XCTAssertTrue(commands[1].arguments.contains("--disable-sequence-dictionary-validation"))
    }

    func testBuildsWrappedTierPicardAndVariantUtilityCommands() {
        let markdup = GATKCommandBuilder.markDuplicatesCommand(
            GATKMarkDuplicatesConfiguration(
                inputBAMURLs: [
                    root.appendingPathComponent("lane1.bam"),
                    root.appendingPathComponent("lane2.bam"),
                ],
                outputBAMURL: root.appendingPathComponent("sample.markdup.bam"),
                metricsURL: root.appendingPathComponent("sample.markdup.metrics.txt"),
                removeDuplicates: true,
                validationStringency: "LENIENT",
                extraArguments: ["--ASSUME_SORT_ORDER", "coordinate"]
            )
        )
        XCTAssertEqual(markdup.arguments.first, "MarkDuplicates")
        XCTAssertArgumentPair(markdup.arguments, "-I", root.appendingPathComponent("lane1.bam").path)
        XCTAssertArgumentPair(markdup.arguments, "-I", root.appendingPathComponent("lane2.bam").path)
        XCTAssertArgumentPair(markdup.arguments, "-M", root.appendingPathComponent("sample.markdup.metrics.txt").path)
        XCTAssertArgumentPair(markdup.arguments, "--CREATE_INDEX", "true")
        XCTAssertArgumentPair(markdup.arguments, "--REMOVE_DUPLICATES", "true")
        XCTAssertArgumentPair(markdup.arguments, "--VALIDATION_STRINGENCY", "LENIENT")
        XCTAssertArgumentPair(markdup.arguments, "--ASSUME_SORT_ORDER", "coordinate")

        let validate = GATKCommandBuilder.validateSamFileCommand(
            GATKValidateSamFileConfiguration(
                inputBAMURL: root.appendingPathComponent("sample.markdup.bam"),
                outputReportURL: root.appendingPathComponent("sample.validate.txt"),
                referenceFASTAURL: root.appendingPathComponent("reference.fa"),
                mode: .summary,
                ignoreWarnings: true
            )
        )
        XCTAssertEqual(validate.arguments.first, "ValidateSamFile")
        XCTAssertArgumentPair(validate.arguments, "-I", root.appendingPathComponent("sample.markdup.bam").path)
        XCTAssertArgumentPair(validate.arguments, "-O", root.appendingPathComponent("sample.validate.txt").path)
        XCTAssertArgumentPair(validate.arguments, "--MODE", "SUMMARY")
        XCTAssertArgumentPair(validate.arguments, "--IGNORE_WARNINGS", "true")

        let leftalign = GATKCommandBuilder.leftAlignAndTrimVariantsCommand(
            GATKLeftAlignAndTrimVariantsConfiguration(
                referenceFASTAURL: root.appendingPathComponent("reference.fa"),
                inputVCFURL: root.appendingPathComponent("raw.vcf.gz"),
                outputVCFURL: root.appendingPathComponent("leftaligned.vcf.gz"),
                splitMultiAllelics: true,
                extraArguments: ["--dont-trim-alleles"]
            )
        )
        XCTAssertEqual(leftalign.arguments.first, "LeftAlignAndTrimVariants")
        XCTAssertArgumentPair(leftalign.arguments, "-V", root.appendingPathComponent("raw.vcf.gz").path)
        XCTAssertArgumentPair(leftalign.arguments, "-O", root.appendingPathComponent("leftaligned.vcf.gz").path)
        XCTAssertArgumentPair(leftalign.arguments, "--split-multi-allelics", "true")
        XCTAssertTrue(leftalign.arguments.contains("--dont-trim-alleles"))

        let metrics = GATKCommandBuilder.collectVariantCallingMetricsCommand(
            GATKCollectVariantCallingMetricsConfiguration(
                inputVCFURL: root.appendingPathComponent("cohort.vcf.gz"),
                outputMetricsPrefixURL: root.appendingPathComponent("metrics/cohort"),
                dbSNPVCFURL: root.appendingPathComponent("dbsnp.vcf.gz"),
                sequenceDictionaryURL: root.appendingPathComponent("reference.dict"),
                extraArguments: ["--THREAD_COUNT", "4"]
            )
        )
        XCTAssertEqual(metrics.arguments.first, "CollectVariantCallingMetrics")
        XCTAssertArgumentPair(metrics.arguments, "-I", root.appendingPathComponent("cohort.vcf.gz").path)
        XCTAssertArgumentPair(metrics.arguments, "-O", root.appendingPathComponent("metrics/cohort").path)
        XCTAssertArgumentPair(metrics.arguments, "--DBSNP", root.appendingPathComponent("dbsnp.vcf.gz").path)
        XCTAssertArgumentPair(metrics.arguments, "--SEQUENCE_DICTIONARY", root.appendingPathComponent("reference.dict").path)
        XCTAssertArgumentPair(metrics.arguments, "--THREAD_COUNT", "4")
    }
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
