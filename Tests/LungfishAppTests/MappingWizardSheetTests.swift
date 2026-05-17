import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

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

    func testMappingSheetLabelsUseReadGroupAndExtraArgumentsText() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/Views/Mapping/MappingWizardSheet.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(#"DisclosureGroup("Read Group""#))
        XCTAssertTrue(source.contains(#"Text("Extra arguments")"#))
        XCTAssertFalse(source.contains(#"Text("Advanced Options")"#))
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
}
