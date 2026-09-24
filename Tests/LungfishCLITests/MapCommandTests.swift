import XCTest
import LungfishIO
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
            "--rg-sm", "sample-rg",
            "--rg-lb", "lib-1",
            "--rg-pl", "ILLUMINA",
            "--rg-pu", "unit-1",
        ])

        XCTAssertEqual(command.sampleName, "sample-1")
        XCTAssertEqual(command.readGroupID, "rg-1")
        XCTAssertEqual(command.readGroupSampleName, "sample-rg")
        XCTAssertEqual(command.readGroupLibrary, "lib-1")
        XCTAssertEqual(command.readGroupPlatform, "ILLUMINA")
        XCTAssertEqual(command.readGroupPlatformUnit, "unit-1")
    }

    func testReadLayoutDefaultsToAutoAndMapsToTheSharedLayout() throws {
        let auto = try MapCommand.parse(["/tmp/reads.lungfishfastq", "--reference", "/tmp/reference.fa"])
        XCTAssertEqual(auto.readLayout, .auto)
        XCTAssertNil(auto.readLayout.explicitLayout)

        let expectations: [(String, MapCommand.MapReadLayoutArgument, FASTQInputLayout)] = [
            ("single-end", .singleEnd, .singleEnd),
            ("interleaved", .interleaved, .strictlyInterleaved),
            ("mixed", .mixed, .mixedMergedAndPairs),
        ]
        for (argument, expectedArgument, expectedLayout) in expectations {
            let command = try MapCommand.parse([
                "/tmp/reads.lungfishfastq",
                "--reference", "/tmp/reference.fa",
                "--read-layout", argument,
            ])
            XCTAssertEqual(command.readLayout, expectedArgument, argument)
            XCTAssertEqual(command.readLayout.explicitLayout, expectedLayout, argument)
        }
        XCTAssertThrowsError(try MapCommand.parse([
            "/tmp/reads.lungfishfastq",
            "--reference", "/tmp/reference.fa",
            "--read-layout", "paired",
        ]))
    }
}
