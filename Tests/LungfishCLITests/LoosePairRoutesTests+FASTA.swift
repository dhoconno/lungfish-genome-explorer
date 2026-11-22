// LoosePairRoutesTests+FASTA.swift - A loose FASTA R1 and R2 that do not pair are refused by map and assemble
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

/// BIO ruling BIO-ROUTES-2, binding items 3 and 7 (S1). `map --paired` and `assemble --paired` take a loose FASTA pair
/// as they are (`FASTQBundle.resolvePrimarySequenceURL`), and the loose-pair check skipped FASTA, so minimap2 dropped
/// the reads past a cut R2 and paired a shuffled R2 by position, with no word. The check now counts the `>` records of
/// both files and compares each pair's names, and refuses with the FASTA form of the run words B1 and B2.
extension LoosePairRoutesTests {

    static let fastaShortMateWords = "Paired FASTA mates do not match. S_R1.fasta has 200 reads, but S_R2.fasta has 120. Nothing ran. Check that both files are complete or run each as single reads."
    static let fastaOutOfStepWords = "Paired FASTA mates are out of step at read 2. S_R1.fasta has 'frag2/1', but S_R2.fasta has 'frag3/2'. Nothing ran. Check that both files are from the same run and neither was sorted or subsampled on its own, or run each file as single reads."

    /// The map and assemble routes, which take a loose FASTA pair.
    static var fastaRoutes: [Route] {
        Route.allCases.filter {
            if case .viralReconSamplesheet = $0 { return false }
            return true
        }
    }

    func testA200ReadFASTAR1WithA120ReadR2IsRefusedByMapAndAssemble() async throws {
        let r1 = try writeFASTA("S_R1.fasta", names: (1...200).map { "frag\($0)/1" })
        let r2 = try writeFASTA("S_R2.fasta", names: (1...120).map { "frag\($0)/2" })

        for route in Self.fastaRoutes {
            let refusal = await planRefusal(route, r1: r1, r2: r2)
            XCTAssertEqual(refusal.words, route.frame + Self.fastaShortMateWords, route.name)
            XCTAssertEqual(refusal.exitCode, 3, route.name)
        }
    }

    func testAShuffledFASTAR2IsRefusedByMapAndAssemble() async throws {
        let r1 = try writeFASTA("S_R1.fasta", names: (1...200).map { "frag\($0)/1" })
        var names = (1...200).map { "frag\($0)/2" }
        names.swapAt(1, 2)
        let r2 = try writeFASTA("S_R2.fasta", names: names)

        for route in Self.fastaRoutes {
            let refusal = await planRefusal(route, r1: r1, r2: r2)
            XCTAssertEqual(refusal.words, route.frame + Self.fastaOutOfStepWords, route.name)
            XCTAssertEqual(refusal.exitCode, 3, route.name)
        }
    }

    /// Guard: an equal FASTA pair, with descriptions after the names, plans as before.
    func testAnEqualFASTAPairPlansOnMapAndAssemble() async throws {
        let r1 = try writeFASTA("S_R1.fasta", names: (1...200).map { "frag\($0)/1 sample=S" })
        let r2 = try writeFASTA("S_R2.fasta", names: (1...200).map { "frag\($0)/2 sample=S" })

        for route in Self.fastaRoutes {
            let refusal = await planRefusal(route, r1: r1, r2: r2)
            XCTAssertEqual(refusal.words, nil, route.name)
            XCTAssertEqual(refusal.exitCode, nil, route.name)
        }
    }

    func testAViralReconRowOfACutFASTAPairAndOfABz2PairIsRefused() async throws {
        let route = Route.viralReconSamplesheet
        let fasta1 = try writeFASTA("S_R1.fasta", names: (1...200).map { "frag\($0)/1" })
        let fasta2 = try writeFASTA("S_R2.fasta", names: (1...120).map { "frag\($0)/2" })
        let bz2R1 = try writeMates("T_R1.fastq.bz2", mate: 1, count: 100)
        let bz2R2 = try writeMates("T_R2.fastq.bz2", mate: 2, count: 100)
        var observed: [String] = []
        for (r1, r2) in [(fasta1, fasta2), (bz2R1, bz2R2)] {
            let refusal = await planRefusal(route, r1: r1, r2: r2)
            observed.append("\(refusal.words ?? "nil") | \(refusal.exitCode.map(String.init) ?? "nil")")
        }
        XCTAssertEqual(observed, [
            route.frame + Self.fastaShortMateWords + " | 3",
            route.frame + "Paired reads need FASTQ files (.fastq or .fq) or FASTA files (.fasta, .fa, .fna or .fsa), with or without .gz. T_R1.fastq.bz2 has an unsupported name. Nothing ran. Decompress or rename it, or run each file as single reads. | 3",
        ])
    }

    /// Writes one record of 100 bases, over two lines, for each name to `name` in the loose folder.
    func writeFASTA(_ name: String, names: [String]) throws -> URL {
        let url = loose.appendingPathComponent(name)
        let bases = String(String(repeating: "ACGT", count: 25).prefix(100))
        let text = names.map { ">\($0)\n\(bases.prefix(60))\n\(bases.dropFirst(60))\n" }.joined()
        try Data(text.utf8).write(to: url)
        return url
    }
}
