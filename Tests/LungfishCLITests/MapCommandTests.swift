import XCTest
@testable import LungfishCLI

final class MapCommandTests: XCTestCase {
    func testParsesExpandedReadGroupFlags() throws {
        let command = try MapCommand.parse([
            "/tmp/reads_R1.fastq.gz",
            "/tmp/reads_R2.fastq.gz",
            "--reference", "/tmp/reference.fa",
            "--paired",
            "--sample-name", "sample-1",
            "--rg-id", "rg-1",
            "--rg-lb", "lib-1",
            "--rg-pl", "ILLUMINA",
            "--rg-pu", "unit-1",
        ])

        XCTAssertEqual(command.sampleName, "sample-1")
        XCTAssertEqual(command.readGroupID, "rg-1")
        XCTAssertEqual(command.readGroupLibrary, "lib-1")
        XCTAssertEqual(command.readGroupPlatform, "ILLUMINA")
        XCTAssertEqual(command.readGroupPlatformUnit, "unit-1")
    }
}
