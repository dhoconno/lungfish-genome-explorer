// BBToolsOutOfMemorySentenceTests.swift - What the out-of-memory sentence claims about the sample (CHTC lane C2-EOOM)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
@testable import LungfishWorkflow

/// `import fastq` goes on to the next sample after one fails, so earlier samples can already be imported when this
/// sentence shows. It may speak only of the sample whose tool ran out of memory, and it names the option with the
/// command that has it, since the `fastq ingest` leaf has no `--clumpify-heap-gb`.
final class BBToolsOutOfMemorySentenceTests: XCTestCase {

    /// Every branch of the sentence: a storage launch whose heap the option sets, a recipe launch whose heap the
    /// policy sets, and a recipe launch whose heap BBTools sized itself.
    private let launches: [(arguments: [String], optionPinsHeap: Bool)] = [
        (["in=/work/reads.fastq", "-Xmx4g", "-eoom"], true),
        (["in1=/work/R1.fastq", "-Xmx4g", "-eoom"], false),
        (["in=/work/reads.fastq", "-eoom"], false),
    ]

    func testTheSentenceSpeaksOfThisSampleAndNeverClaimsNothingWasImported() {
        for launch in launches {
            let sentence = BBToolsOutOfMemory.message(
                tool: "clumpify.sh", arguments: launch.arguments, optionPinsHeap: launch.optionPinsHeap)
            XCTAssertTrue(sentence.contains("this sample was not imported and its original files were kept"), sentence)
            XCTAssertFalse(sentence.contains("nothing was imported"), sentence)
        }
    }

    func testTheOptionIsNamedWithTheCommandThatHasIt() {
        let sentence = BBToolsOutOfMemory.message(
            tool: "clumpify.sh", arguments: ["in=/work/reads.fastq", "-Xmx4g", "-eoom"], optionPinsHeap: true)
        XCTAssertTrue(sentence.contains("import fastq --clumpify-heap-gb 8"), sentence)
    }

    /// The Import FASTQ sheet has no heap control, so the storage sentence leads with what a person in the sheet can
    /// do and names the option last, as a command line step (narrowed review O29-UX finding 1, UX 1 and UX 4).
    func testStorageSentenceLeadsWithAnActionTheSheetHas() throws {
        let sentence = BBToolsOutOfMemory.message(
            tool: "clumpify.sh", arguments: ["in=/work/reads.fastq", "-Xmx4g", "-eoom"], optionPinsHeap: true)
        let action = try XCTUnwrap(sentence.range(of: "Close other apps"), sentence)
        let option = try XCTUnwrap(sentence.range(of: "--clumpify-heap-gb"), sentence)
        XCTAssertLessThan(action.lowerBound, option.lowerBound, sentence)
        XCTAssertFalse(sentence.hasSuffix("--clumpify-heap-gb 8."), "the sentence must not end on the flag: \(sentence)")
        XCTAssertTrue(
            sentence.contains("On the command line, import fastq --clumpify-heap-gb 8 sets a larger heap."), sentence)
    }
}
