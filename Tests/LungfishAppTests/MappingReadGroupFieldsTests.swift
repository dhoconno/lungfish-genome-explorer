import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

final class MappingReadGroupFieldsTests: XCTestCase {
    func testDefaultsUseSampleNameAndPresetPlatform() {
        let fields = MappingReadGroupFields.defaults(
            sampleName: "SampleA",
            modeID: MappingMode.minimap2MapONT.id
        )

        XCTAssertEqual(fields.id, "SampleA")
        XCTAssertEqual(fields.sampleName, "SampleA")
        XCTAssertEqual(fields.library, "SampleA")
        XCTAssertEqual(fields.platform, "ONT")
        XCTAssertEqual(fields.platformUnit, "SampleA")
    }

    func testResolvedReadGroupPreservesCustomValues() {
        let fields = MappingReadGroupFields(
            id: "rg-custom",
            sampleName: "sm-custom",
            library: "lb-custom",
            platform: "PACBIO",
            platformUnit: "pu-custom"
        )

        let readGroup = fields.resolvedReadGroup(
            sampleName: "SampleA",
            modeID: MappingMode.minimap2MapONT.id
        )

        XCTAssertEqual(readGroup.id, "rg-custom")
        XCTAssertEqual(readGroup.sampleName, "sm-custom")
        XCTAssertEqual(readGroup.library, "lb-custom")
        XCTAssertEqual(readGroup.platform, "PACBIO")
        XCTAssertEqual(readGroup.platformUnit, "pu-custom")
    }
}
