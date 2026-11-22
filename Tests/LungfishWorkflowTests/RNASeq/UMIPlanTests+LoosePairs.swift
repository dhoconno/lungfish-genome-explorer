// UMIPlanTests+LoosePairs.swift - A UMI plan refuses a pair of read files on this Mac that do not pair
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishIO
import LungfishPortable
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

/// BIO ruling BIO-ROUTES-2, binding items 5 and 7 (S1 provisional). A sample's pairs became the plan's R1 and R2, and
/// umi_tools, STAR and salmon pair two files by position, so a cut or shuffled pair on this Mac was planned with no
/// word. The reads frame, which the UMI, salmon, STAR and Solo plans share, now checks each pair of files on this Mac
/// with the loose-pair check before a plan is written, with the run words B1 and B2 as they are.
extension UMIPlanTests {

    /// The C9 sample with one pair of read files on this Mac in place of its staged reads.
    func localSample(r1: URL, r2: URL) -> SalmonPlanSample {
        func read(_ url: URL) -> SalmonPlanRead {
            SalmonPlanRead(name: url.lastPathComponent, sha256: String(repeating: "1", count: 64), size: 1000, source: url)
        }
        var sample = c9Sample()
        sample.pairs = [SalmonPlanSample.Pair(r1: read(r1), r2: read(r2))]
        sample.stagedPaths = nil
        return sample
    }

    func planRefusal(r1: URL, r2: URL) async -> String? {
        do {
            _ = try await made(sample: localSample(r1: r1, r2: r2))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func writeLooseMates(_ name: String, names: [String]) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(ReadSetFixtures.fastq(names).utf8).write(to: url)
        return url
    }

    func testAUMIPlanRefusesA200ReadR1WithA120ReadR2() async throws {
        let r1 = try writeLooseMates("S_R1.fastq", names: (1...200).map { "frag\($0)/1" })
        let r2 = try writeLooseMates("S_R2.fastq", names: (1...120).map { "frag\($0)/2" })

        let refusal = await planRefusal(r1: r1, r2: r2)
        XCTAssertEqual(refusal, "Paired FASTQ mates do not match. S_R1.fastq has 200 reads, but S_R2.fastq has 120. Nothing ran. Check that both files are complete or run each as single reads.")
    }

    func testAUMIPlanRefusesAShuffledR2() async throws {
        let r1 = try writeLooseMates("S_R1.fastq", names: (1...200).map { "frag\($0)/1" })
        var names = (1...200).map { "frag\($0)/2" }
        names.swapAt(1, 2)
        let r2 = try writeLooseMates("S_R2.fastq", names: names)

        let refusal = await planRefusal(r1: r1, r2: r2)
        XCTAssertEqual(refusal, "Paired FASTQ mates are out of step at read 2. S_R1.fastq has 'frag2/1', but S_R2.fastq has 'frag3/2'. Nothing ran. Check that both files are from the same run and neither was sorted or subsampled on its own, or run each file as single reads.")
    }

    /// Guard: an equal pair on this Mac is planned as before.
    func testAUMIPlanOfAnEqualPairIsWritten() async throws {
        let r1 = try writeLooseMates("S_R1.fastq", names: (1...200).map { "frag\($0)/1" })
        let r2 = try writeLooseMates("S_R2.fastq", names: (1...200).map { "frag\($0)/2" })

        let refusal = await planRefusal(r1: r1, r2: r2)
        XCTAssertEqual(refusal, nil)
    }
}
