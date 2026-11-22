import AppKit
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
        XCTAssertEqual(MappingWizardSheet.outputTrackSectionTitle, "Output Track")
        XCTAssertEqual(MappingWizardSheet.outputTrackFieldLabel, "Track name (--track-name)")
    }

    /// "Track name (--track-name)" wrapped over two lines in the 150pt label
    /// column. The flag-bearing labels (the dialog shows CLI flags in labels,
    /// as the Read Group fields do) must fit their column on one line.
    func testFlagLabelsFitTheirColumnOnOneLine() {
        let font = NSFont.systemFont(ofSize: MappingWizardSheet.labelFontSize)
        let column = MappingWizardSheet.flagLabelColumnWidth
        XCTAssertGreaterThanOrEqual(column, MappingWizardSheet.standardLabelColumnWidth)
        for label in [MappingWizardSheet.outputTrackFieldLabel] + MappingWizardSheet.readGroupFieldLabels {
            let width = (label as NSString).size(withAttributes: [.font: font]).width
            XCTAssertLessThanOrEqual(width + 4, column, "\(label) must fit on one line")
        }
        XCTAssertEqual(MappingWizardSheet.readGroupFieldLabels.last, "Platform unit (--rg-pu)")
    }

    /// The Output Track Name field: blank or the tool's default leaves the
    /// request's `outputTrackName` nil (so the run and its copied CLI
    /// command keep the default "<Tool> Mapping"); any other text is carried
    /// on every request of the plan and surfaces as `--track-name`.
    func testOutputTrackNameFieldFlowsIntoRequestsAndTheCLICommand() {
        XCTAssertNil(MappingWizardSheet.explicitOutputTrackName("", tool: .minimap2))
        XCTAssertNil(MappingWizardSheet.explicitOutputTrackName("   ", tool: .minimap2))
        XCTAssertNil(MappingWizardSheet.explicitOutputTrackName("minimap2 Mapping", tool: .minimap2))
        XCTAssertEqual(MappingWizardSheet.explicitOutputTrackName("minimap2 Mapping", tool: .bowtie2), "minimap2 Mapping")
        XCTAssertEqual(MappingWizardSheet.explicitOutputTrackName("  HG002 minimap2 ", tool: .minimap2), "HG002 minimap2")

        let plan = MappingWizardSheet.buildRunPlan(
            bundleURLs: [bundleURL("SampleA"), bundleURL("SampleB")],
            mode: .perBundle,
            tool: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            referenceFASTAURL: URL(fileURLWithPath: "/tmp/proj/Reference Sequences/ref.lungfishref/genome/sequence.fa"),
            sourceReferenceBundleURL: URL(fileURLWithPath: "/tmp/proj/Reference Sequences/ref.lungfishref"),
            projectURL: URL(fileURLWithPath: "/tmp/proj"),
            outputDirectory: URL(fileURLWithPath: "/tmp/proj/mapping-out", isDirectory: true),
            runToken: "abc123",
            readGroupIDText: "",
            readGroupSampleText: "",
            readGroupLibraryText: "",
            readGroupPlatformText: "",
            readGroupPlatformUnitText: "",
            threads: 4,
            includeSecondary: false,
            includeSupplementary: true,
            minimumMappingQuality: 0,
            advancedArguments: [],
            outputTrackName: "HG002 minimap2"
        )
        XCTAssertEqual(plan.requests.count, 2)
        for request in plan.requests {
            XCTAssertEqual(request.outputTrackName, "HG002 minimap2")
            XCTAssertEqual(MappingResultLayoutService.trackName(for: request), "HG002 minimap2")
            XCTAssertEqual(request.summaryParameters()["outputTrackName"], .string("HG002 minimap2"))
            let arguments = MappingCLIInvocationBuilder.arguments(for: request)
            XCTAssertEqual(arguments[arguments.firstIndex(of: "--track-name")! + 1], "HG002 minimap2")
            XCTAssertEqual(arguments[arguments.firstIndex(of: "--project")! + 1], "/tmp/proj")
        }

        let defaultPlan = MappingWizardSheet.buildRunPlan(
            bundleURLs: [bundleURL("SampleA")],
            mode: .perBundle,
            tool: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            referenceFASTAURL: URL(fileURLWithPath: "/tmp/proj/reference.fa"),
            sourceReferenceBundleURL: nil,
            projectURL: nil,
            outputDirectory: URL(fileURLWithPath: "/tmp/proj/mapping-out", isDirectory: true),
            runToken: "abc123",
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
        let request = defaultPlan.requests[0]
        XCTAssertNil(request.outputTrackName)
        XCTAssertEqual(MappingResultLayoutService.trackName(for: request), "minimap2 Mapping")
        XCTAssertFalse(MappingCLIInvocationBuilder.arguments(for: request).contains("--track-name"))
        XCTAssertFalse(MappingCLIInvocationBuilder.arguments(for: request).contains("--project"))
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

    // MARK: - Multi-bundle fan-out (MB-1, fix round 1)
    //
    // These tests use `.lungfishfastq` BUNDLE URLs -- the real shape
    // `MappingWizardSheet.inputFiles` receives from the sidebar selection
    // pipeline (`AppDelegate+ToolsMenu.resolveFASTQOperationInputURL`), NOT
    // raw FASTQ files. `buildRunPlan` never resolves bundle contents or
    // infers R1/R2 pairing from these URLs -- see F1/F2 in the fix-round-1
    // review. `pairedEnd` is `false` for bundles in the plan; how a
    // bundle's reads pair is decided post-resolve by
    // `MappingInputResolver` (MappingInputResolverTests, MapReadSetStandInTests).

    private func bundleURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/proj/\(name).lungfishfastq", isDirectory: true)
    }

    func testBuildRunPlanPerBundleYieldsOneRequestPerBundleWithDistinctSampleTags() {
        let bundleA = bundleURL("SampleA")
        let bundleB = bundleURL("SampleB")
        let referenceURL = URL(fileURLWithPath: "/tmp/proj/reference.fa")
        let outputDir = URL(fileURLWithPath: "/tmp/proj/mapping-out", isDirectory: true)

        let plan = MappingWizardSheet.buildRunPlan(
            bundleURLs: [bundleA, bundleB],
            mode: .perBundle,
            tool: .bowtie2,
            modeID: MappingMode.defaultShortRead.id,
            referenceFASTAURL: referenceURL,
            sourceReferenceBundleURL: nil,
            projectURL: nil,
            outputDirectory: outputDir,
            runToken: "abc123",
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

        // Each request's inputFASTQURLs is still the single UNRESOLVED
        // bundle URL -- resolution to actual files happens later, in
        // AppDelegate, not in the wizard.
        XCTAssertEqual(plan.requests[0].inputFASTQURLs, [bundleA])
        XCTAssertEqual(plan.requests[0].sampleName, "SampleA")
        XCTAssertEqual(plan.requests[0].readGroup?.sampleName, "SampleA")
        XCTAssertEqual(plan.requests[0].readGroup?.id, "SampleA")

        XCTAssertEqual(plan.requests[1].inputFASTQURLs, [bundleB])
        XCTAssertEqual(plan.requests[1].sampleName, "SampleB")
        XCTAssertEqual(plan.requests[1].readGroup?.sampleName, "SampleB")
        XCTAssertEqual(plan.requests[1].readGroup?.id, "SampleB")

        XCTAssertNotEqual(plan.requests[0].readGroup?.sampleName, plan.requests[1].readGroup?.sampleName)

        // F2: the wizard-layer plan never claims pairedEnd -- it can't know
        // a bundle's contents without resolving it.
        XCTAssertFalse(plan.requests[0].pairedEnd)
        XCTAssertFalse(plan.requests[1].pairedEnd)
    }

    /// F1 regression: two DISTINCT paired-end bundles whose directory names
    /// happen to contain "_R1"/"_R2" substrings must NOT be merged into one
    /// "pair" by the wizard -- each selected bundle URL is its own bundle,
    /// full stop, regardless of what its name contains.
    func testBuildRunPlanPerBundleDoesNotMergeBundlesWhoseNamesLookLikeAnRPair() {
        let run1R1 = bundleURL("Run1_R1")
        let run1R2 = bundleURL("Run1_R2")
        let referenceURL = URL(fileURLWithPath: "/tmp/proj/reference.fa")
        let outputDir = URL(fileURLWithPath: "/tmp/proj/mapping-out", isDirectory: true)

        let plan = MappingWizardSheet.buildRunPlan(
            bundleURLs: [run1R1, run1R2],
            mode: .perBundle,
            tool: .bowtie2,
            modeID: MappingMode.defaultShortRead.id,
            referenceFASTAURL: referenceURL,
            sourceReferenceBundleURL: nil,
            projectURL: nil,
            outputDirectory: outputDir,
            runToken: "abc123",
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

        // Two distinct bundles -> two distinct requests, each with exactly
        // one (its own) bundle URL -- never pooled into a fabricated pair.
        XCTAssertEqual(plan.requests.count, 2)
        XCTAssertEqual(plan.requests[0].inputFASTQURLs, [run1R1])
        XCTAssertEqual(plan.requests[1].inputFASTQURLs, [run1R2])
        XCTAssertNotEqual(plan.requests[0].readGroup?.id, plan.requests[1].readGroup?.id)
    }

    /// F3 regression: two bundles with the same sanitized leaf name must
    /// not collide on @RG ID.
    func testBuildRunPlanDeduplicatesReadGroupIDsForDuplicateLeafNames() {
        let bundleA = URL(fileURLWithPath: "/tmp/proj/folderA/sample.lungfishfastq", isDirectory: true)
        let bundleB = URL(fileURLWithPath: "/tmp/proj/folderB/sample.lungfishfastq", isDirectory: true)
        let referenceURL = URL(fileURLWithPath: "/tmp/proj/reference.fa")
        let outputDir = URL(fileURLWithPath: "/tmp/proj/mapping-out", isDirectory: true)

        let plan = MappingWizardSheet.buildRunPlan(
            bundleURLs: [bundleA, bundleB],
            mode: .perBundle,
            tool: .bowtie2,
            modeID: MappingMode.defaultShortRead.id,
            referenceFASTAURL: referenceURL,
            sourceReferenceBundleURL: nil,
            projectURL: nil,
            outputDirectory: outputDir,
            runToken: "abc123",
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
        let readGroupIDs = plan.requests.compactMap(\.readGroup?.id)
        XCTAssertEqual(readGroupIDs.count, 2)
        XCTAssertEqual(Set(readGroupIDs).count, 2, "Duplicate leaf names must not collide on @RG ID: \(readGroupIDs)")
    }

    func testBuildRunPlanCombinedYieldsOnePooledRequestWithWarningAndRunTokenInSampleName() {
        let bundleA = bundleURL("SampleA")
        let bundleB = bundleURL("SampleB")
        let referenceURL = URL(fileURLWithPath: "/tmp/proj/reference.fa")
        let outputDir = URL(fileURLWithPath: "/tmp/proj/mapping-out", isDirectory: true)

        let plan = MappingWizardSheet.buildRunPlan(
            bundleURLs: [bundleA, bundleB],
            mode: .combined,
            tool: .bowtie2,
            modeID: MappingMode.defaultShortRead.id,
            referenceFASTAURL: referenceURL,
            sourceReferenceBundleURL: nil,
            projectURL: nil,
            outputDirectory: outputDir,
            runToken: "abc123",
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
        // Still the unresolved bundle URLs, pooled -- resolution +
        // concatenation of underlying files happens later in AppDelegate.
        XCTAssertEqual(plan.requests[0].inputFASTQURLs, [bundleA, bundleB])
        XCTAssertEqual(plan.requests[0].sampleName, "pooled-2-bundles-abc123")
        XCTAssertEqual(plan.requests[0].readGroup?.sampleName, "pooled-2-bundles-abc123")
        XCTAssertFalse(plan.requests[0].pairedEnd)
        XCTAssertNotNil(plan.warning)
        XCTAssertTrue(
            plan.warning?.localizedCaseInsensitiveContains("2 bundles") ?? false,
            "Warning should mention the number of pooled bundles: \(plan.warning ?? "nil")"
        )
    }

    func testBuildRunPlanSingleBundleHasNoWarningRegardlessOfMode() {
        let bundleA = bundleURL("SampleA")
        let referenceURL = URL(fileURLWithPath: "/tmp/proj/reference.fa")
        let outputDir = URL(fileURLWithPath: "/tmp/proj/mapping-out", isDirectory: true)

        let plan = MappingWizardSheet.buildRunPlan(
            bundleURLs: [bundleA],
            mode: .combined,
            tool: .bowtie2,
            modeID: MappingMode.defaultShortRead.id,
            referenceFASTAURL: referenceURL,
            sourceReferenceBundleURL: nil,
            projectURL: nil,
            outputDirectory: outputDir,
            runToken: "abc123",
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
