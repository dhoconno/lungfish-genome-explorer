import XCTest
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

    func testShortReadMappersRejectLongReadClasses() {
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
            .blocked("BWA-MEM2 is only available for Illumina-style short-read mapping in v1.")
        )
        XCTAssertEqual(
            bowtie2Evaluation.state,
            .blocked("Bowtie2 is only available for Illumina-style short-read mapping in v1.")
        )
    }
}
