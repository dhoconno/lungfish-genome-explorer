import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class MappingCompatibilityTests: XCTestCase {

    func testBBMapStandardBlocksReadsLongerThan500Bases() {
        let evaluation = MappingCompatibility.evaluate(
            tool: .bbmap,
            mode: .bbmapStandard,
            readClass: .ontReads,
            observedMaxReadLength: 1_200
        )

        XCTAssertEqual(
            evaluation.state,
            .blocked("Standard BBMap mode supports reads up to 500 bases. Switch to PacBio mode or choose another mapper.")
        )
    }

    func testBBMapPacBioBlocksReadsLongerThan6000Bases() {
        let evaluation = MappingCompatibility.evaluate(
            tool: .bbmap,
            mode: .bbmapPacBio,
            readClass: .pacBioCLR,
            observedMaxReadLength: 7_001
        )

        XCTAssertEqual(
            evaluation.state,
            .blocked("BBMap PacBio mode supports reads up to 6000 bases. Choose another mapper for longer reads.")
        )
    }

    /// Short-read mappers on long reads used to be refused. The owner ruled
    /// that read class only sets defaults, so these run with a warning.
    func testShortReadMappersWarnOnLongReadClasses() {
        let bwaMem2Evaluation = MappingCompatibility.evaluate(
            tool: .bwaMem2,
            mode: .defaultShortRead,
            readClass: .ontReads,
            observedMaxReadLength: 5_000
        )
        let bowtie2Evaluation = MappingCompatibility.evaluate(
            tool: .bowtie2,
            mode: .defaultShortRead,
            readClass: .pacBioHiFi,
            observedMaxReadLength: 2_000
        )

        XCTAssertEqual(
            bwaMem2Evaluation.state,
            .warning("BWA-MEM2 is designed for Illumina-style short reads, and these are ONT reads. The run uses the settings you chose.")
        )
        XCTAssertEqual(
            bowtie2Evaluation.state,
            .warning("Bowtie2 is designed for Illumina-style short reads, and these are PacBio HiFi. The run uses the settings you chose.")
        )
        XCTAssertFalse(bwaMem2Evaluation.isBlocked)
    }

    func testAMinimap2PresetThatDoesNotSuitTheReadClassIsAWarning() {
        let evaluation = MappingCompatibility.evaluate(tool: .minimap2, mode: .defaultShortRead, readClass: .ontReads)
        XCTAssertEqual(evaluation.warningMessage, "The minimap2 Short-read preset is tuned for Illumina short reads, and these are ONT reads. The run uses the settings you chose.")
        XCTAssertEqual(
            MappingCompatibility.evaluate(tool: .minimap2, mode: .minimap2MapONT, readClass: .ontReads).state,
            .allowed
        )
    }

    func testAnUnknownReadClassRunsWithTheUntunedNote() {
        let evaluation = MappingCompatibility.evaluate(tool: .minimap2, mode: .minimap2MapONT, readClass: nil)
        XCTAssertEqual(evaluation.state, .warning(PlatformInference.untunedDefaultsNote))
        XCTAssertFalse(
            MappingCompatibility.evaluate(tool: .bbmap, mode: .bbmapPacBio, readClass: nil, observedMaxReadLength: 2_000).isBlocked
        )
    }

    func testAModeTheToolCannotRunStaysBlocked() {
        XCTAssertTrue(MappingCompatibility.evaluate(tool: .bowtie2, mode: .minimap2MapONT, readClass: .ontReads).isBlocked)
    }

    func testPreferredModesSelectCompatibleLongReadPresets() {
        XCTAssertEqual(
            MappingMode.preferredMode(for: .minimap2, readClass: .ontReads),
            .minimap2MapONT
        )
        XCTAssertEqual(
            MappingMode.preferredMode(for: .minimap2, readClass: .pacBioHiFi),
            .minimap2MapHiFi
        )
        XCTAssertEqual(
            MappingMode.preferredMode(for: .minimap2, readClass: .pacBioCLR),
            .minimap2MapPB
        )
        XCTAssertEqual(
            MappingMode.preferredMode(for: .bbmap, readClass: .pacBioCLR),
            .bbmapPacBio
        )
    }

    func testReadClassDetectionDoesNotTreatIncidentalCCSTextAsPacBioHiFi() {
        XCTAssertNil(MappingReadClass.detect(fromFASTQHeader: "@sample_ccs_like_generic_read"))
        XCTAssertEqual(MappingReadClass.detect(fromFASTQHeader: "@movie/12345/ccs"), .pacBioHiFi)
    }
}
