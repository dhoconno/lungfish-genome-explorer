import XCTest
@testable import LungfishWorkflow

final class ConsensusCoordinateMapTests: XCTestCase {
    func testIdentityWhenNoIndels() {
        let map = ConsensusCoordinateMap(indels: [])
        XCTAssertEqual(map.consensusPosition(forReference: 1), 1)
        XCTAssertEqual(map.consensusPosition(forReference: 29_903), 29_903)
    }

    func testPositionsBeforeAnIndelAreUnshifted() {
        let map = ConsensusCoordinateMap(indels: [
            .init(position: 20_297, referenceLength: 4, alternateLength: 1)
        ])
        XCTAssertEqual(map.consensusPosition(forReference: 100), 100)
        XCTAssertEqual(map.consensusPosition(forReference: 20_297), 20_297)
    }

    // The real deletion from the reference dataset: AATT -> A at 20,297 removes
    // three bases, so everything after it shifts back by three.
    func testPositionsAfterADeletionShiftBack() {
        let map = ConsensusCoordinateMap(indels: [
            .init(position: 20_297, referenceLength: 4, alternateLength: 1)
        ])
        XCTAssertEqual(map.consensusPosition(forReference: 20_301), 20_298)
        XCTAssertEqual(map.consensusPosition(forReference: 29_903), 29_900)
    }

    func testDeletedBasesHaveNoConsensusPosition() {
        let map = ConsensusCoordinateMap(indels: [
            .init(position: 20_297, referenceLength: 4, alternateLength: 1)
        ])
        XCTAssertNil(map.consensusPosition(forReference: 20_298))
        XCTAssertNil(map.consensusPosition(forReference: 20_300))
    }

    func testInsertionShiftsForward() {
        let map = ConsensusCoordinateMap(indels: [
            .init(position: 100, referenceLength: 1, alternateLength: 3)
        ])
        XCTAssertEqual(map.consensusPosition(forReference: 101), 103)
    }

    func testMultipleIndelsAccumulate() {
        let map = ConsensusCoordinateMap(indels: [
            .init(position: 100, referenceLength: 4, alternateLength: 1),
            .init(position: 200, referenceLength: 4, alternateLength: 1),
        ])
        XCTAssertEqual(map.consensusPosition(forReference: 300), 294)
    }
}
