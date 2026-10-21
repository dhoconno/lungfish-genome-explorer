// TranslateFramePinTests.swift - The six frame headers of translate and fastq translate, pinned at the base
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.27 (decision [9]), milestone M1. Part A of the decision keeps the signed header
// `>{name}_frame{label} [{code name}] [{n} aa]` in both commands, where the label is the reading frame's
// own text from `+1` to `-3`, so `--frame 4` prints `_frame-1`. Before this file only `_frame+1` was pinned.
// These cases pin all six frames of both commands, the bytes of four `fastq translate` inputs and what
// `--compress` writes. They passed at the base, before any Sources edit. Milestone M2 moved two of the four
// inputs (a loose interleaved Casava file and a bundle recorded `interleaved`) by prediction and no other byte,
// and `FastqTranslateMateIdTests` holds their new bytes.
//
// The proteins below come from a six-frame table worked out apart from the engine (standard code, the
// reverse frames read on the reverse complement from the last base), not from `TranslationEngine`.

import ArgumentParser
import Foundation
import XCTest
@testable import LungfishCLI
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

/// The reads both commands translate in the six-frame pins. `r3` holds two bases, so no frame gives it a
/// protein and both commands skip it.
enum TranslateFramePinFixture {
    static let fasta = ">r1\nATGGCTAGCAAAGGAGAA\n>r2\nATGAAACCCGGGTTT\n>r3\nAC\n"
    static let fastq = [
        "@r1", "ATGGCTAGCAAAGGAGAA", "+", "IIIIIIIIIIIIIIIIII",
        "@r2", "ATGAAACCCGGGTTT", "+", "IIIIIIIIIIIIIII",
        "@r3", "AC", "+", "II",
    ].joined(separator: "\n") + "\n"

    /// One `--frame` number with the header and protein each command writes for `r1` and `r2`.
    struct Frame {
        let option: Int
        let r1Header: String
        let r1Protein: String
        let r2Header: String
        let r2Protein: String

        var text: String { "\(r1Header)\n\(r1Protein)\n\(r2Header)\n\(r2Protein)\n" }
    }

    static let frames: [Frame] = [
        Frame(option: 1, r1Header: ">r1_frame+1 [Standard] [6 aa]", r1Protein: "MASKGE",
              r2Header: ">r2_frame+1 [Standard] [5 aa]", r2Protein: "MKPGF"),
        Frame(option: 2, r1Header: ">r1_frame+2 [Standard] [5 aa]", r1Protein: "WLAKE",
              r2Header: ">r2_frame+2 [Standard] [4 aa]", r2Protein: "*NPG"),
        Frame(option: 3, r1Header: ">r1_frame+3 [Standard] [5 aa]", r1Protein: "G*QRR",
              r2Header: ">r2_frame+3 [Standard] [4 aa]", r2Protein: "ETRV"),
        Frame(option: 4, r1Header: ">r1_frame-1 [Standard] [6 aa]", r1Protein: "FSFASH",
              r2Header: ">r2_frame-1 [Standard] [5 aa]", r2Protein: "KPGFH"),
        Frame(option: 5, r1Header: ">r1_frame-2 [Standard] [5 aa]", r1Protein: "SPLLA",
              r2Header: ">r2_frame-2 [Standard] [4 aa]", r2Protein: "NPGF"),
        Frame(option: 6, r1Header: ">r1_frame-3 [Standard] [5 aa]", r1Protein: "LLC*P",
              r2Header: ">r2_frame-3 [Standard] [4 aa]", r2Protein: "TRVS"),
    ]
}

/// Runs `fastq translate` on `input` and returns the file it wrote.
func runFastqTranslatePin(
    _ input: URL,
    frame: Int,
    output: URL,
    extra: [String] = []
) async throws -> Data {
    let command = try FastqTranslateSubcommand.parse(
        [input.path, "--frame", "\(frame)", "-o", output.path] + extra
    )
    try await command.run()
    return try Data(contentsOf: output)
}

/// The layout the read-pairing contract's resolver gives `input`, which M2 reads before it numbers any mate.
func resolvedLayoutPin(_ input: URL) -> FASTQInputLayout {
    FASTQInputLayoutResolver.resolve(inputURLs: [input]).layout
}

/// A `.lungfishfastq` bundle in `folder` holding `reads.fastq` and a sidecar that records `pairingMode`.
func writeFASTQBundlePin(
    _ text: String,
    named name: String,
    in folder: URL,
    pairingMode: IngestionMetadata.PairingMode
) throws -> URL {
    let bundle = folder.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    let file = bundle.appendingPathComponent("reads.fastq")
    try Data(text.utf8).write(to: file)
    FASTQMetadataStore.save(
        PersistedFASTQMetadata(ingestion: IngestionMetadata(pairingMode: pairingMode, pairingSource: .detected)),
        for: file
    )
    return bundle
}

final class TranslateFramePinTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try TestTempDirectory.make(prefix: "translate-frame-pins")
        let captured = folder!
        addTeardownBlock { TestTempDirectory.cleanup(captured) }
    }

    // MARK: translate

    func testTranslateWritesTheHeaderOfEachOfTheSixFrames() async throws {
        let input = folder.appendingPathComponent("reads.fasta")
        try Data(TranslateFramePinFixture.fasta.utf8).write(to: input)
        for pin in TranslateFramePinFixture.frames {
            let output = folder.appendingPathComponent("frame-\(pin.option).fa")
            let command = try TranslateCommand.parse(
                [input.path, "--frame", "\(pin.option)", "-o", output.path, "--quiet", "--no-color"]
            )
            try await command.run()
            XCTAssertEqual(
                try String(contentsOf: output, encoding: .utf8), pin.text,
                "translate --frame \(pin.option)"
            )
        }
    }

    func testTranslateWithoutFrameWritesTheSixFramesOfEachSequenceInOrder() async throws {
        let input = folder.appendingPathComponent("reads.fasta")
        try Data(TranslateFramePinFixture.fasta.utf8).write(to: input)
        let output = folder.appendingPathComponent("all-frames.fa")
        let command = try TranslateCommand.parse([input.path, "-o", output.path, "--quiet", "--no-color"])

        try await command.run()

        let frames = TranslateFramePinFixture.frames
        let expected = frames.map { "\($0.r1Header)\n\($0.r1Protein)\n" }.joined()
            + frames.map { "\($0.r2Header)\n\($0.r2Protein)\n" }.joined()
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), expected)
    }

    // MARK: fastq translate

    func testFastqTranslateWritesTheHeaderOfEachOfTheSixFrames() async throws {
        let input = folder.appendingPathComponent("reads.fastq")
        try Data(TranslateFramePinFixture.fastq.utf8).write(to: input)
        XCTAssertEqual(resolvedLayoutPin(input), .singleEnd)
        for pin in TranslateFramePinFixture.frames {
            let output = folder.appendingPathComponent("frame-\(pin.option).fa")
            let written = try await runFastqTranslatePin(input, frame: pin.option, output: output)
            XCTAssertEqual(String(decoding: written, as: UTF8.self), pin.text, "fastq translate --frame \(pin.option)")
        }
    }

    func testFastqTranslateSkipsAReadThatGivesNoProtein() async throws {
        let input = folder.appendingPathComponent("reads.fastq")
        try Data(TranslateFramePinFixture.fastq.utf8).write(to: input)
        let output = folder.appendingPathComponent("skip.fa")

        let written = try await runFastqTranslatePin(input, frame: 1, output: output)

        XCTAssertFalse(String(decoding: written, as: UTF8.self).contains(">r3"))
        XCTAssertEqual(String(decoding: written, as: UTF8.self).split(separator: "\n").count, 4)
    }

    // MARK: the recorded frame

    /// The header prints the label, and the record keeps the number the person typed.
    func testBothCommandsRecordTheFrameOptionNumberWhileTheHeaderPrintsTheLabel() async throws {
        let fasta = folder.appendingPathComponent("reads.fasta")
        try Data(TranslateFramePinFixture.fasta.utf8).write(to: fasta)
        let fastq = folder.appendingPathComponent("reads.fastq")
        try Data(TranslateFramePinFixture.fastq.utf8).write(to: fastq)
        let translated = folder.appendingPathComponent("translated.fa")
        let fastqTranslated = folder.appendingPathComponent("fastq-translated.fa")

        let translate = try TranslateCommand.parse(
            [fasta.path, "--frame", "4", "-o", translated.path, "--quiet", "--no-color"]
        )
        try await translate.run()
        let written = try await runFastqTranslatePin(fastq, frame: 4, output: fastqTranslated)

        XCTAssertTrue(try String(contentsOf: translated, encoding: .utf8).hasPrefix(">r1_frame-1 "))
        XCTAssertTrue(String(decoding: written, as: UTF8.self).hasPrefix(">r1_frame-1 "))
        for output in [translated, fastqTranslated] {
            let sidecar = ProvenanceRecorder.fileSidecarURL(for: output)
            let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(fromSidecar: sidecar))
            XCTAssertEqual(envelope.options.explicit["frame"]?.integerValue, 4, output.lastPathComponent)
        }
    }
}

/// The inputs and the base bytes of the `fastq translate` input pins. M2 reuses the Casava fixture.
enum FastqTranslateInputFixture {
    private static let mate1Reads = "ATGGCTAGCAAAGGAGAA"
    private static let mate2Reads = "ATGAAACCCGGGTTT"
    private static let quality1 = String(repeating: "I", count: 18)
    private static let quality2 = String(repeating: "I", count: 15)

    /// BIO's fixture. Two Casava 1.8 fragments whose mates share an id and differ after the first space.
    static let casava = [
        "@A00123:8:H7KJ2DSXX:1:1101:10004:1000 1:N:0:ACGTACGT", mate1Reads, "+", quality1,
        "@A00123:8:H7KJ2DSXX:1:1101:10004:1000 2:N:0:ACGTACGT", mate2Reads, "+", quality2,
        "@A00123:8:H7KJ2DSXX:1:1101:10005:1000 1:N:0:ACGTACGT", mate1Reads, "+", quality1,
        "@A00123:8:H7KJ2DSXX:1:1101:10005:1000 2:N:0:ACGTACGT", mate2Reads, "+", quality2,
    ].joined(separator: "\n") + "\n"

    /// The mate 1 records of that fixture alone, so no two ids are equal.
    static let casavaMate1Alone = [
        "@A00123:8:H7KJ2DSXX:1:1101:10004:1000 1:N:0:ACGTACGT", mate1Reads, "+", quality1,
        "@A00123:8:H7KJ2DSXX:1:1101:10005:1000 1:N:0:ACGTACGT", mate1Reads, "+", quality1,
    ].joined(separator: "\n") + "\n"

    /// One pair whose mates already differ, as in the older `/1` and `/2` convention.
    static let slashMates = [
        "@M00123:1:000000000-A1B2C:1:1101:15589:1331/1", mate1Reads, "+", quality1,
        "@M00123:1:000000000-A1B2C:1:1101:15589:1331/2", mate2Reads, "+", quality2,
    ].joined(separator: "\n") + "\n"

    /// What `--frame 1` writes for `casava`. M1 pinned both mates of a fragment under one id, and M2 gives
    /// them `.1` and `.2` right after the id (decision [9] part B).
    static let casavaFrame1 = [
        ">A00123:8:H7KJ2DSXX:1:1101:10004:1000.1_frame+1 [Standard] [6 aa]", "MASKGE",
        ">A00123:8:H7KJ2DSXX:1:1101:10004:1000.2_frame+1 [Standard] [5 aa]", "MKPGF",
        ">A00123:8:H7KJ2DSXX:1:1101:10005:1000.1_frame+1 [Standard] [6 aa]", "MASKGE",
        ">A00123:8:H7KJ2DSXX:1:1101:10005:1000.2_frame+1 [Standard] [5 aa]", "MKPGF",
    ].joined(separator: "\n") + "\n"

    /// What `--frame 4` writes for `casava`. The header says `-1` and the marks stay before `_frame`.
    static let casavaFrame4 = [
        ">A00123:8:H7KJ2DSXX:1:1101:10004:1000.1_frame-1 [Standard] [6 aa]", "FSFASH",
        ">A00123:8:H7KJ2DSXX:1:1101:10004:1000.2_frame-1 [Standard] [5 aa]", "KPGFH",
        ">A00123:8:H7KJ2DSXX:1:1101:10005:1000.1_frame-1 [Standard] [6 aa]", "FSFASH",
        ">A00123:8:H7KJ2DSXX:1:1101:10005:1000.2_frame-1 [Standard] [5 aa]", "KPGFH",
    ].joined(separator: "\n") + "\n"

    static let casavaMate1AloneFrame1 = [
        ">A00123:8:H7KJ2DSXX:1:1101:10004:1000_frame+1 [Standard] [6 aa]", "MASKGE",
        ">A00123:8:H7KJ2DSXX:1:1101:10005:1000_frame+1 [Standard] [6 aa]", "MASKGE",
    ].joined(separator: "\n") + "\n"

    static let slashMatesFrame1 = [
        ">M00123:1:000000000-A1B2C:1:1101:15589:1331/1_frame+1 [Standard] [6 aa]", "MASKGE",
        ">M00123:1:000000000-A1B2C:1:1101:15589:1331/2_frame+1 [Standard] [5 aa]", "MKPGF",
    ].joined(separator: "\n") + "\n"
}

/// The bytes `fastq translate` writes for the two M1 inputs that keep them, and for `--compress`. The other two
/// M1 inputs, a loose interleaved Casava file and a bundle recorded `interleaved`, moved in M2 and are checked
/// in `FastqTranslateMateIdTests`.
final class FastqTranslateInputPinTests: XCTestCase {
    private typealias Fixture = FastqTranslateInputFixture
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try TestTempDirectory.make(prefix: "fastq-translate-input-pins")
        let captured = folder!
        addTeardownBlock { TestTempDirectory.cleanup(captured) }
    }

    private func writeFASTQ(_ text: String, named name: String = "reads.fastq") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    // MARK: Inputs that keep their bytes through M2

    /// Input 3, a single-end file. These are the mate 1 records of the Casava fixture alone, no two ids equal.
    func testSingleEndFileKeepsItsBytes() async throws {
        let input = try writeFASTQ(Fixture.casavaMate1Alone, named: "single.fastq")
        XCTAssertEqual(resolvedLayoutPin(input), .singleEnd)

        let written = try await runFastqTranslatePin(input, frame: 1, output: folder.appendingPathComponent("single-1.fa"))

        XCTAssertEqual(String(decoding: written, as: UTF8.self), Fixture.casavaMate1AloneFrame1)
    }

    /// Input 4, mates that already differ. The older `/1` and `/2` ids give two different FASTA ids today.
    func testSlashMatesKeepTheirBytes() async throws {
        let input = try writeFASTQ(Fixture.slashMates, named: "slash.fastq")
        XCTAssertEqual(resolvedLayoutPin(input), .strictlyInterleaved)

        let written = try await runFastqTranslatePin(input, frame: 1, output: folder.appendingPathComponent("slash-1.fa"))

        XCTAssertEqual(String(decoding: written, as: UTF8.self), Fixture.slashMatesFrame1)
    }

    // MARK: --compress

    /// Lane 13.39 moved this pin. At the base `--compress` was accepted, the writer was a plain FileHandle, the
    /// bytes were the same plain FASTA at the same path and the record said `compress` was true. The writer
    /// still has no gzip step, so the command now refuses the flag when it parses its arguments (exit 64),
    /// before the output file or its record exist.
    func testCompressFlagIsRefusedBeforeAnyFileOrRecordIsWritten() throws {
        let input = try writeFASTQ(TranslateFramePinFixture.fastq, named: "compress.fastq")
        let output = folder.appendingPathComponent("refused.fa")

        XCTAssertThrowsError(
            try FastqTranslateSubcommand.parse([input.path, "--frame", "1", "-o", output.path, "--compress"])
        ) { error in
            XCTAssertEqual(
                FastqTranslateSubcommand.message(for: error),
                "--compress is not supported by fastq translate. Remove it to write plain output."
            )
            XCTAssertEqual(FastqTranslateSubcommand.exitCode(for: error).rawValue, 64)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: output).path))
    }

    /// Without the flag the run writes the same plain FASTA, and its record names `compress` nowhere, neither
    /// in the argv nor in the options.
    func testPlainRunRecordNamesNoCompress() async throws {
        let input = try writeFASTQ(TranslateFramePinFixture.fastq, named: "plain.fastq")
        let output = folder.appendingPathComponent("plain.fa")

        let plain = try await runFastqTranslatePin(input, frame: 1, output: output)

        XCTAssertEqual(String(decoding: plain, as: UTF8.self), TranslateFramePinFixture.frames[0].text)
        XCTAssertNotEqual(Array(plain.prefix(2)), [0x1f, 0x8b], "gzip magic")
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: output)
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(fromSidecar: sidecar))
        XCTAssertFalse(envelope.argv.contains("--compress"))
        XCTAssertNil(envelope.options.explicit["compress"])
        XCTAssertNil(envelope.options.resolvedDefaults["compress"])
    }
}
