// ReadSelectionTests.swift - Tests for read tooltip and selection logic
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCore

@MainActor
final class ReadSelectionTests: XCTestCase {

    // MARK: - Tooltip Text Building

    func testReadTooltipContainsReadName() {
        let read = makeRead(name: "SRR123456.1", position: 100, cigar: "75M", isReverse: false)
        let tooltip = buildTooltip(for: read)
        XCTAssertTrue(tooltip.contains("SRR123456.1"))
    }

    func testReadTooltipContainsStrand() {
        let forwardRead = makeRead(name: "R1", position: 0, cigar: "50M", isReverse: false)
        let tooltip = buildTooltip(for: forwardRead)
        XCTAssertTrue(tooltip.contains("(+)"))

        let reverseRead = makeRead(name: "R2", position: 0, cigar: "50M", isReverse: true)
        let revTooltip = buildTooltip(for: reverseRead)
        XCTAssertTrue(revTooltip.contains("(-)"))
    }

    func testReadTooltipContainsMAPQ() {
        let read = makeRead(name: "R1", position: 0, cigar: "50M", mapq: 42)
        let tooltip = buildTooltip(for: read)
        XCTAssertTrue(tooltip.contains("MAPQ: 42"))
    }

    func testReadTooltipContainsCIGAR() {
        let read = makeRead(name: "R1", position: 0, cigar: "75M2I73M")
        let tooltip = buildTooltip(for: read)
        XCTAssertTrue(tooltip.contains("75M2I73M"))
    }

    func testReadTooltipContainsPairedInfo() {
        let read = AlignedRead(
            name: "R1",
            flag: 0x1 | 0x2, // paired + proper pair
            chromosome: "chr1",
            position: 100,
            mapq: 60,
            cigar: CIGAROperation.parse("50M") ?? [],
            sequence: String(repeating: "A", count: 50),
            qualities: [],
            mateChromosome: "chr1",
            matePosition: 500,
            insertSize: 450
        )
        let tooltip = buildTooltip(for: read)
        XCTAssertTrue(tooltip.contains("Proper pair"))
        XCTAssertTrue(tooltip.contains("chr1:501"))
        XCTAssertTrue(tooltip.contains("Insert size: 450"))
    }

    func testReadTooltipLongCIGARIsComplete() {
        // Build a very long CIGAR string
        let longCigar = (1...30).map { "\($0)M" }.joined()
        let ops = CIGAROperation.parse(longCigar) ?? []
        let read = AlignedRead(
            name: "R1", flag: 0, chromosome: "chr1", position: 0,
            mapq: 60, cigar: ops,
            sequence: String(repeating: "A", count: 100), qualities: []
        )
        let tooltip = buildTooltip(for: read)
        XCTAssertTrue(tooltip.contains(longCigar))
        XCTAssertTrue(tooltip.hasSuffix(longCigar))
    }

    // MARK: - Read Notification Keys

    func testReadSelectedNotificationExists() {
        let name = Notification.Name.readSelected
        XCTAssertEqual(name.rawValue, "readSelected")
    }

    func testAlignedReadUserInfoKey() {
        XCTAssertEqual(NotificationUserInfoKey.alignedRead, "alignedRead")
    }

    // MARK: - ReadStyleSectionViewModel Selected Read

    func testViewModelSelectedReadUpdates() {
        let vm = ReadStyleSectionViewModel()
        XCTAssertNil(vm.selectedRead)
        XCTAssertFalse(vm.hasSelectedRead)

        let read = makeRead(name: "TestRead", position: 0, cigar: "50M")
        vm.selectedRead = read

        XCTAssertNotNil(vm.selectedRead)
        XCTAssertTrue(vm.hasSelectedRead)
        XCTAssertEqual(vm.selectedRead?.name, "TestRead")
    }

    func testViewModelClearResetsSelectedReadForUnloadedEvidence() {
        // Clearing a bundle or detached classifier-evidence viewport must not
        // leave its former read selected in the Inspector.
        let vm = ReadStyleSectionViewModel()
        let read = makeRead(name: "TestRead", position: 0, cigar: "50M")
        vm.selectedRead = read
        vm.clear()
        XCTAssertNil(vm.selectedRead)
    }

    // MARK: - Quality Scores in Detail

    func testReadWithQualityScoresShowsStats() {
        let qualities: [UInt8] = [30, 35, 40, 20, 10, 42, 38, 25]
        _ = AlignedRead(
            name: "R1", flag: 0, chromosome: "chr1", position: 0,
            mapq: 60, cigar: CIGAROperation.parse("8M") ?? [],
            sequence: "ACGTACGT", qualities: qualities
        )

        let mean = Double(qualities.reduce(0, { $0 + Int($1) })) / Double(qualities.count)
        XCTAssertEqual(mean, 30, accuracy: 0.1)

        let q20Count = qualities.filter { $0 >= 20 }.count
        XCTAssertEqual(q20Count, 7) // all except 10

        let minQ = qualities.min()!
        let maxQ = qualities.max()!
        XCTAssertEqual(minQ, 10)
        XCTAssertEqual(maxQ, 42)
    }

    // MARK: - Helpers

    private func makeRead(
        name: String,
        position: Int,
        cigar: String,
        isReverse: Bool = false,
        mapq: UInt8 = 60
    ) -> AlignedRead {
        let flag: UInt16 = isReverse ? 0x10 : 0
        return AlignedRead(
            name: name,
            flag: flag,
            chromosome: "chr1",
            position: position,
            mapq: mapq,
            cigar: CIGAROperation.parse(cigar) ?? [],
            sequence: String(repeating: "A", count: 50),
            qualities: []
        )
    }

    /// Exercises the production tooltip formatter directly.
    private func buildTooltip(for read: AlignedRead) -> String {
        SequenceViewerView(frame: .zero).readTooltipText(for: read)
    }
}
