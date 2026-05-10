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
