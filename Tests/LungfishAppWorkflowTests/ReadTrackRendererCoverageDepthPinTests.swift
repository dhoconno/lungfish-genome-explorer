// ReadTrackRendererCoverageDepthPinTests.swift - Pins coverage across a spliced or deleted read to samtools depth
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

/// Pins that coverage across a skipped (`N`) or deleted (`D`) stretch of a read is zero, which is
/// what `samtools depth` prints (Phase 4 lane L4C-PIN, BIO's D2).
///
/// Every number comes from `samtools depth -a -d 0` run on a hand-made SAM with the golden lock's
/// samtools, never from the code under test. The app's three `samtools depth` argvs pass no `-J`,
/// so samtools leaves `N` and `D` out. The text is 1-based and `AlignedRead.position` is 0-based,
/// so POS 3 is 2 and POS 5 is 4.
///
/// Two facts the pins rest on. First, `drawCoverage(reads:)` has no production caller, since the
/// live strip and the graphic export call only `drawCoverage(depthPoints:)`, so the rule that
/// walks a read's CIGAR reaches tests alone. Second, `opEnd` in that overload is inclusive of the
/// column at a block's end, so it paints one extra column past each aligned block. At one point a
/// base that is a whole base of false depth. The centre columns read here leave it alone and no
/// user can meet it today. Do not fix it here. A later lane that gives the overload a caller
/// makes the end exclusive first.
@MainActor
final class ReadTrackRendererCoverageDepthPinTests: XCTestCase {

    // MARK: - Fixtures

    private struct DepthCase {
        let name: String
        /// The `samtools depth -a -d 0` lines of the case, one a base.
        let samtoolsText: String
        /// The third column of that text, at 0-based positions 0 to 13.
        let depths: [Int]
        /// The deepest base. It sets the strip's scale at `(60 - 16) / maxDepth` points a read.
        let maxDepth: Int
        let reads: [AlignedRead]
    }

    private static func read(
        _ name: String, flag: UInt16 = 0, at position: Int, cigar: [(CIGAROperation.Op, Int)]
    ) -> AlignedRead {
        let ops = cigar.map { CIGAROperation(op: $0.0, length: $0.1) }
        let queryLength = ops.filter { [.match, .insertion, .softClip, .seqMatch, .seqMismatch].contains($0.op) }
            .reduce(0) { $0 + $1.length }
        return AlignedRead(
            name: name, flag: flag, chromosome: "chr1", position: position, mapq: 60, cigar: ops,
            sequence: String(repeating: "A", count: queryLength),
            qualities: Array(repeating: 30, count: queryLength)
        )
    }

    /// One read, `3M4N3M` at POS 3.
    private static let splicedDepthText = """
        chr1\t1\t0
        chr1\t2\t0
        chr1\t3\t1
        chr1\t4\t1
        chr1\t5\t1
        chr1\t6\t0
        chr1\t7\t0
        chr1\t8\t0
        chr1\t9\t0
        chr1\t10\t1
        chr1\t11\t1
        chr1\t12\t1
        chr1\t13\t0
        chr1\t14\t0
        """

    /// One reverse read, `3M2D3M` at POS 3.
    private static let deletedDepthText = """
        chr1\t1\t0
        chr1\t2\t0
        chr1\t3\t1
        chr1\t4\t1
        chr1\t5\t1
        chr1\t6\t0
        chr1\t7\t0
        chr1\t8\t1
        chr1\t9\t1
        chr1\t10\t1
        chr1\t11\t0
        chr1\t12\t0
        chr1\t13\t0
        chr1\t14\t0
        """

    /// Three reads, R1 `3M4N3M` at POS 3, R2 reverse `3M2D3M` at POS 3 and R3 `2S2M1I2M` at POS 5.
    private static let togetherDepthText = """
        chr1\t1\t0
        chr1\t2\t0
        chr1\t3\t2
        chr1\t4\t2
        chr1\t5\t3
        chr1\t6\t1
        chr1\t7\t1
        chr1\t8\t2
        chr1\t9\t1
        chr1\t10\t2
        chr1\t11\t1
        chr1\t12\t1
        chr1\t13\t0
        chr1\t14\t0
        """

    private var cases: [DepthCase] {
        let spliced = Self.read("spliced", at: 2, cigar: [(.match, 3), (.skip, 4), (.match, 3)])
        let deleted = Self.read("deleted", flag: 16, at: 2, cigar: [(.match, 3), (.deletion, 2), (.match, 3)])
        let r1 = Self.read("R1", at: 2, cigar: [(.match, 3), (.skip, 4), (.match, 3)])
        let r2 = Self.read("R2", flag: 16, at: 2, cigar: [(.match, 3), (.deletion, 2), (.match, 3)])
        let r3 = Self.read("R3", at: 4, cigar: [(.softClip, 2), (.match, 2), (.insertion, 1), (.match, 2)])
        return [
            DepthCase(
                name: "spliced", samtoolsText: Self.splicedDepthText,
                depths: [0, 0, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 0, 0], maxDepth: 1, reads: [spliced]
            ),
            DepthCase(
                name: "deleted", samtoolsText: Self.deletedDepthText,
                depths: [0, 0, 1, 1, 1, 0, 0, 1, 1, 1, 0, 0, 0, 0], maxDepth: 1, reads: [deleted]
            ),
            DepthCase(
                name: "together", samtoolsText: Self.togetherDepthText,
                depths: [0, 0, 2, 2, 3, 1, 1, 2, 1, 2, 1, 1, 0, 0], maxDepth: 3, reads: [r1, r2, r3]
            ),
        ]
    }

    // MARK: - The path a user sees

    /// The live strip and the graphic export draw depth points, so this is the coverage a person
    /// reads. The literal `samtools depth` text goes through the parser and the column binning,
    /// and at one point a base each column holds one base.
    func testDepthPathEqualsSamtoolsDepthPerBase() {
        let frame = ViewerFigureFrame(chromosome: "chr1", start: 0, end: 14, pixelWidth: 14)
        let rect = CGRect(x: 0, y: 0, width: 14, height: 60)
        for depthCase in cases {
            let parsed = AlignmentDataProvider.parseDepthOutput(depthCase.samtoolsText)
            XCTAssertEqual(parsed.map(\.position), Array(0..<14), "\(depthCase.name) positions, 0-based")
            XCTAssertEqual(parsed.map(\.depth), depthCase.depths, "\(depthCase.name) parsed depths")
            let points = parsed.map { ReadTrackRenderer.CoveragePoint(position: $0.position, depth: $0.depth) }
            let columns = ReadTrackRenderer.binnedDepthColumns(
                depthPoints: points, regionStart: 0, regionEnd: 14, frame: frame, rect: rect
            )
            XCTAssertEqual(columns, depthCase.depths, "\(depthCase.name) columns, one base each")
        }
    }

    // MARK: - The read-walking rule

    /// Draws each case with `drawCoverage(reads:)` into a 140 by 60 bitmap with the frame at 0 to
    /// 14, so 10 points a base. At each base's centre column the run of drawn pixels up from the
    /// bottom row is `depth * 44 / maxDepth` points, within 1.5, since the outline paints about a pixel.
    /// A skipped or deleted stretch adds nothing, as in the samtools text.
    func testReadWalkingCoverageIgnoresSkipAndDeletionAtEachBaseCentre() {
        for depthCase in cases {
            let heights = centreColumnHeights(of: depthCase.reads)
            XCTAssertEqual(heights.count, 14, "\(depthCase.name) centre columns read")
            for (base, depth) in depthCase.depths.enumerated() where base < heights.count {
                let expected = Double(depth) * 44.0 / Double(depthCase.maxDepth)
                XCTAssertEqual(
                    Double(heights[base]), expected, accuracy: 1.5,
                    "\(depthCase.name) base \(base) at depth \(depth) should rise \(expected) points"
                )
            }
        }
    }

    // MARK: - Drawing and sampling

    /// Draws into an sRGB bitmap whose origin is the top left, as in the live flipped view, and
    /// returns for each of the 14 bases the count of pixels with alpha above 0 at the base's centre
    /// column (`10 * base + 5`), counted up from the bottom row until the first clear pixel.
    private func centreColumnHeights(of reads: [AlignedRead]) -> [Int] {
        let width = 140
        let height = 60
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        let appearance = NSAppearance(named: .aqua)!
        let theme = ViewerFigureTheme.resolved(for: appearance)
        let frame = ViewerFigureFrame(chromosome: "chr1", start: 0, end: 14, pixelWidth: width)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                XCTFail("The sRGB bitmap context could not be made")
                return
            }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            appearance.performAsCurrentDrawingAppearance {
                ReadTrackRenderer.drawCoverage(
                    reads: reads, frame: frame, context: context, figureTheme: theme,
                    rect: CGRect(x: 0, y: 0, width: width, height: height)
                )
            }
            NSGraphicsContext.current = previous
        }
        return (0..<14).map { base in
            let column = 10 * base + 5
            var count = 0
            for row in stride(from: height - 1, through: 0, by: -1) {
                if bytes[row * bytesPerRow + column * 4 + 3] == 0 { break }
                count += 1
            }
            return count
        }
    }
}
