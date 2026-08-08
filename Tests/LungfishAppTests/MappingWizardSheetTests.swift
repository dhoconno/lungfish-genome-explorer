import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow
@testable import LungfishKit

@MainActor
final class MappingWizardSheetTests: XCTestCase {
    func testReadGroupDefaultsUseSampleNameAndModePlatform() {
        let readGroup = MappingWizardSheet.defaultReadGroup(
            sampleName: "SRR123456",
            modeID: MappingMode.minimap2MapONT.id
        )

        XCTAssertEqual(readGroup.id, "SRR123456")
        XCTAssertEqual(readGroup.sampleName, "SRR123456")
        XCTAssertEqual(readGroup.library, "SRR123456")
        XCTAssertEqual(readGroup.platform, "ONT")
        XCTAssertEqual(readGroup.platformUnit, "SRR123456")
    }

    func testReadGroupFieldsForwardVerbatimIntoRequestModel() {
        let readGroup = MappingWizardSheet.makeReadGroup(
            sampleName: "SRR123456",
            modeID: MappingMode.defaultShortRead.id,
            idText: "rg-custom",
            sampleText: "sample-custom",
            libraryText: "library-custom",
            platformText: "IONTORRENT",
            platformUnitText: "unit-custom"
        )

        XCTAssertEqual(
            readGroup,
            MappingReadGroup(
                id: "rg-custom",
                sampleName: "sample-custom",
                library: "library-custom",
                platform: "IONTORRENT",
                platformUnit: "unit-custom"
            )
        )
    }

    func testMappingSheetLabelsExposeReadGroupAndExtraArgumentsContract() {
        XCTAssertEqual(MappingWizardSheet.readGroupSectionTitle, "Read Group")
        XCTAssertEqual(MappingWizardSheet.advancedSectionTitle, "Advanced Settings")
        XCTAssertEqual(MappingWizardSheet.extraArgumentsFieldTitle, "Extra arguments")
    }

    func testAdvancedOptionsPlaceholderUsesRealToolSpecificOptions() {
        XCTAssertEqual(
            MappingWizardSheet.advancedOptionsPlaceholder(for: .minimap2),
            "--eqx -N 5"
        )
        XCTAssertEqual(
            MappingWizardSheet.advancedOptionsPlaceholder(for: .bwaMem2),
            "-M -Y"
        )
        XCTAssertEqual(
            MappingWizardSheet.advancedOptionsPlaceholder(for: .bowtie2),
            "--very-sensitive -N 1"
        )
        XCTAssertEqual(
            MappingWizardSheet.advancedOptionsPlaceholder(for: .bbmap),
            "minid=0.97 local=t"
        )

        XCTAssertFalse(
            MappingWizardSheet.advancedOptionsPlaceholder(for: .minimap2).contains("minid="),
            "minid is BBMap-specific and should not be shown for minimap2"
        )
    }

    // MARK: - Multi-bundle grouping (MB-1)

    func testGroupBundlesPairsR1R2FilesTogether() {
        let sampleA1 = URL(fileURLWithPath: "/tmp/proj/SampleA_R1.fastq.gz")
        let sampleA2 = URL(fileURLWithPath: "/tmp/proj/SampleA_R2.fastq.gz")
        let sampleB1 = URL(fileURLWithPath: "/tmp/proj/SampleB_R1.fastq.gz")
        let sampleB2 = URL(fileURLWithPath: "/tmp/proj/SampleB_R2.fastq.gz")

        let bundles = MappingWizardSheet.groupBundles(
            inputFiles: [sampleA1, sampleA2, sampleB1, sampleB2]
        )

        XCTAssertEqual(bundles.count, 2)
        XCTAssertEqual(bundles[0], [sampleA1, sampleA2])
        XCTAssertEqual(bundles[1], [sampleB1, sampleB2])
    }

    func testGroupBundlesTreatsUnpairedSingleFilesAsIndividualBundles() {
        let sampleA = URL(fileURLWithPath: "/tmp/proj/SampleA.fastq.gz")
        let sampleB = URL(fileURLWithPath: "/tmp/proj/SampleB.fastq.gz")

        let bundles = MappingWizardSheet.groupBundles(inputFiles: [sampleA, sampleB])

        XCTAssertEqual(bundles.count, 2)
        XCTAssertEqual(bundles[0], [sampleA])
        XCTAssertEqual(bundles[1], [sampleB])
    }

    func testBuildRunRequestsPerBundleYieldsOneRequestPerBundleWithDistinctSampleTags() {
        let sampleA = URL(fileURLWithPath: "/tmp/proj/SampleA.fastq")
        let sampleB = URL(fileURLWithPath: "/tmp/proj/SampleB.fastq")
        let referenceURL = URL(fileURLWithPath: "/tmp/proj/reference.fa")
        let outputDir = URL(fileURLWithPath: "/tmp/proj/mapping-out", isDirectory: true)

        let plan = MappingWizardSheet.buildRunPlan(
            bundles: [[sampleA], [sampleB]],
            mode: .perBundle,
            tool: .bowtie2,
            modeID: MappingMode.defaultShortRead.id,
            referenceFASTAURL: referenceURL,
            sourceReferenceBundleURL: nil,
            projectURL: nil,
            outputDirectory: outputDir,
            readGroupIDText: "",
            readGroupSampleText: "",
            readGroupLibraryText: "",
            readGroupPlatformText: "",
            readGroupPlatformUnitText: "",
            threads: 4,
            includeSecondary: false,
            includeSupplementary: true,
            minimumMappingQuality: 0,
            advancedArguments: []
        )

        XCTAssertEqual(plan.requests.count, 2)
        XCTAssertNil(plan.warning)

        XCTAssertEqual(plan.requests[0].inputFASTQURLs, [sampleA])
        XCTAssertEqual(plan.requests[0].sampleName, "SampleA")
        XCTAssertEqual(plan.requests[0].readGroup?.sampleName, "SampleA")
        XCTAssertEqual(plan.requests[0].readGroup?.id, "SampleA")

        XCTAssertEqual(plan.requests[1].inputFASTQURLs, [sampleB])
        XCTAssertEqual(plan.requests[1].sampleName, "SampleB")
        XCTAssertEqual(plan.requests[1].readGroup?.sampleName, "SampleB")
        XCTAssertEqual(plan.requests[1].readGroup?.id, "SampleB")

        XCTAssertNotEqual(plan.requests[0].readGroup?.sampleName, plan.requests[1].readGroup?.sampleName)
    }

    func testBuildRunRequestsCombinedYieldsOnePooledRequestWithWarning() {
        let sampleA = URL(fileURLWithPath: "/tmp/proj/SampleA.fastq")
        let sampleB = URL(fileURLWithPath: "/tmp/proj/SampleB.fastq")
        let referenceURL = URL(fileURLWithPath: "/tmp/proj/reference.fa")
        let outputDir = URL(fileURLWithPath: "/tmp/proj/mapping-out", isDirectory: true)

        let plan = MappingWizardSheet.buildRunPlan(
            bundles: [[sampleA], [sampleB]],
            mode: .combined,
            tool: .bowtie2,
            modeID: MappingMode.defaultShortRead.id,
            referenceFASTAURL: referenceURL,
            sourceReferenceBundleURL: nil,
            projectURL: nil,
            outputDirectory: outputDir,
            readGroupIDText: "",
            readGroupSampleText: "",
            readGroupLibraryText: "",
            readGroupPlatformText: "",
            readGroupPlatformUnitText: "",
            threads: 4,
            includeSecondary: false,
            includeSupplementary: true,
            minimumMappingQuality: 0,
            advancedArguments: []
        )

        XCTAssertEqual(plan.requests.count, 1)
        XCTAssertEqual(plan.requests[0].inputFASTQURLs, [sampleA, sampleB])
        XCTAssertEqual(plan.requests[0].sampleName, "pooled-2-bundles")
        XCTAssertEqual(plan.requests[0].readGroup?.sampleName, "pooled-2-bundles")
        XCTAssertNotNil(plan.warning)
        XCTAssertTrue(
            plan.warning?.localizedCaseInsensitiveContains("2 bundles") ?? false,
            "Warning should mention the number of pooled bundles: \(plan.warning ?? "nil")"
        )
    }

    func testBuildRunRequestsSingleBundleHasNoWarningRegardlessOfMode() {
        let sampleA = URL(fileURLWithPath: "/tmp/proj/SampleA.fastq")
        let referenceURL = URL(fileURLWithPath: "/tmp/proj/reference.fa")
        let outputDir = URL(fileURLWithPath: "/tmp/proj/mapping-out", isDirectory: true)

        let plan = MappingWizardSheet.buildRunPlan(
            bundles: [[sampleA]],
            mode: .combined,
            tool: .bowtie2,
            modeID: MappingMode.defaultShortRead.id,
            referenceFASTAURL: referenceURL,
            sourceReferenceBundleURL: nil,
            projectURL: nil,
            outputDirectory: outputDir,
            readGroupIDText: "",
            readGroupSampleText: "",
            readGroupLibraryText: "",
            readGroupPlatformText: "",
            readGroupPlatformUnitText: "",
            threads: 4,
            includeSecondary: false,
            includeSupplementary: true,
            minimumMappingQuality: 0,
            advancedArguments: []
        )

        XCTAssertEqual(plan.requests.count, 1)
        XCTAssertNil(plan.warning)
        XCTAssertEqual(plan.requests[0].sampleName, "SampleA")
    }
}
