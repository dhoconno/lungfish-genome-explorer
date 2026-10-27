// IlluminaKitDemuxTests.swift - Built-in Illumina kits search for their own barcodes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Demultiplex Barcodes built the adapter file of every built-in Illumina kit from a context whose 5' spec is
// empty, because that context exists to trim read-through. cutadapt got the line `^`, or a linked adapter with an
// empty side, and stopped with "Adapter sequence is empty" (Phase 3.0 lane DEMUX-ILLUMINA, re-walk finding S2).
// The preflight counted such a line as a sequence. These tests build the adapter file without running cutadapt.
// The run against the real tool is in IlluminaKitDemuxConformanceTests.

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class IlluminaKitDemuxTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "illumina-kit-demux")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// One sequence line of an adapter file, with the name of the header above it.
    private struct AdapterLine: Hashable {
        let name: String
        let text: String
    }

    private struct AdapterFile {
        let flag: String
        let lines: [AdapterLine]
    }

    /// The adapter file a run of `kit` hands to cutadapt, built without running cutadapt.
    private func adapterFile(_ kit: BarcodeKitDefinition, location: BarcodeLocation) async throws -> AdapterFile {
        let config = DemultiplexConfig(
            inputURL: root.appendingPathComponent("reads.fastq"),
            barcodeKit: kit,
            outputDirectory: root.appendingPathComponent("demux-out", isDirectory: true),
            barcodeLocation: location,
            errorRate: 0.15,
            threads: 1
        )
        let work = root.appendingPathComponent("work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let adapters = try await DemultiplexingPipeline().createAdapterConfiguration(for: config, workDirectory: work)
        var name = ""
        var lines: [AdapterLine] = []
        for line in try String(contentsOf: adapters.adapterFASTA, encoding: .utf8).split(separator: "\n") {
            if line.hasPrefix(">") {
                name = String(line.dropFirst())
            } else {
                lines.append(AdapterLine(name: name, text: String(line)))
            }
        }
        return AdapterFile(flag: adapters.adapterFlag, lines: lines)
    }

    /// Every pair of a dual kit has its own lines, each holding that pair's i7 and the reverse complement of its i5,
    /// and no line is shared by two pairs. A line shared by two pairs puts the reads of both in the first.
    private func assertEveryPairHasItsOwnLines(_ kit: BarcodeKitDefinition, _ file: AdapterFile) {
        for barcode in kit.barcodes {
            let own = file.lines.filter { $0.name == barcode.id }
            XCTAssertFalse(own.isEmpty, "\(barcode.id) has no line")
            let i5 = PlatformAdapters.reverseComplement(barcode.i5Sequence ?? "")
            for line in own {
                XCTAssertTrue(line.text.contains(barcode.i7Sequence), "\(barcode.id) line \(line.text) lacks its i7 \(barcode.i7Sequence)")
                XCTAssertTrue(line.text.contains(i5), "\(barcode.id) line \(line.text) lacks its i5 \(i5)")
            }
        }
        let shared = Dictionary(grouping: file.lines, by: \.text).filter { Set($0.value.map(\.name)).count > 1 }
        XCTAssertTrue(shared.isEmpty, "\(shared.count) lines are shared by two pairs, for example \(shared.keys.sorted().first ?? "")")
    }

    // MARK: - The context the barcode search uses

    func testDemuxAdapterContextIsBareForIlluminaFamilyKitsAndLeavesTheTrimContextAlone() {
        func config(_ kit: BarcodeKitDefinition, adapterContext: (any PlatformAdapterContext)? = nil) -> DemultiplexConfig {
            DemultiplexConfig(
                inputURL: URL(fileURLWithPath: "/tmp/test.fastq"),
                barcodeKit: kit,
                outputDirectory: URL(fileURLWithPath: "/tmp/output"),
                adapterContext: adapterContext
            )
        }
        let illumina: [BarcodeKitDefinition] = [
            BarcodeKitRegistry.truseqSingleA, BarcodeKitRegistry.truseqSingleB, BarcodeKitRegistry.truseqHTDual,
            BarcodeKitRegistry.nexteraXTv2, BarcodeKitRegistry.idtUDIndexes,
        ]
        for kit in illumina {
            XCTAssertTrue(config(kit).demuxAdapterContext is BareAdapterContext, "\(kit.id) is searched with its bare index")
        }
        // Read-through trimming keeps the contexts it relies on.
        XCTAssertTrue(config(BarcodeKitRegistry.truseqSingleA).resolvedAdapterContext is IlluminaTruSeqAdapterContext)
        XCTAssertTrue(config(BarcodeKitRegistry.nexteraXTv2).resolvedAdapterContext is IlluminaNexteraAdapterContext)
        // A kit whose barcode sits in the read keeps the context of its kit, and an override wins.
        XCTAssertTrue(config(BarcodeKitRegistry.ontNativeBarcoding24).demuxAdapterContext is ONTNativeAdapterContext)
        XCTAssertTrue(config(BarcodeKitRegistry.fluidigmAccessArray).demuxAdapterContext is BareAdapterContext)
        XCTAssertTrue(
            config(BarcodeKitRegistry.truseqSingleA, adapterContext: IlluminaTruSeqAdapterContext())
                .demuxAdapterContext is IlluminaTruSeqAdapterContext
        )
    }

    // MARK: - The adapter file carries each barcode

    func testTruSeqSingleIndexAdapterFASTACarriesEachBareIndex() async throws {
        let kit = BarcodeKitRegistry.truseqSingleA
        let fivePrime = try await adapterFile(kit, location: .fivePrime)
        XCTAssertEqual(fivePrime.flag, "-g")
        XCTAssertEqual(fivePrime.lines.map(\.name), kit.barcodes.map(\.id), "one line under each of D701 to D712")
        XCTAssertEqual(fivePrime.lines.map(\.text), kit.barcodes.map { "^\($0.i7Sequence)" })
        XCTAssertEqual(fivePrime.lines.first?.text, "^ATTACTCG")
        XCTAssertEqual(fivePrime.lines.dropFirst().first?.text, "^TCCGGAGA")

        let threePrime = try await adapterFile(kit, location: .threePrime)
        XCTAssertEqual(threePrime.flag, "-a")
        XCTAssertEqual(threePrime.lines.first?.text, "ATTACTCG$")

        let setB = try await adapterFile(BarcodeKitRegistry.truseqSingleB, location: .fivePrime)
        XCTAssertEqual(setB.lines.first?.text, "^TATAGCCT")
    }

    func testTruSeqHTDualAdapterFASTACarriesBothIndexes() async throws {
        let kit = BarcodeKitRegistry.truseqHTDual
        let file = try await adapterFile(kit, location: .fivePrime)
        XCTAssertEqual(file.flag, "-g")
        XCTAssertTrue(
            file.lines.contains(AdapterLine(name: "D701-D501", text: "^ATTACTCG...AGGCTATA")),
            "D701-D501 holds \(file.lines.filter { $0.name == "D701-D501" }.map(\.text))"
        )
        assertEveryPairHasItsOwnLines(kit, file)
    }

    func testNexteraXTv2AdapterFASTACarriesBothIndexes() async throws {
        let kit = BarcodeKitRegistry.nexteraXTv2
        let file = try await adapterFile(kit, location: .fivePrime)
        XCTAssertEqual(file.flag, "-g")
        XCTAssertTrue(
            file.lines.contains(AdapterLine(name: "N701-S502", text: "^TAAGGCGA...ATAGAGAG")),
            "N701-S502 holds \(file.lines.filter { $0.name == "N701-S502" }.map(\.text))"
        )
        XCTAssertFalse(
            file.lines.contains { $0.text.contains("CTGTCTCTTATACACATCT") },
            "the read-through adapter is not a barcode"
        )
        assertEveryPairHasItsOwnLines(kit, file)
    }

    // MARK: - The kit whose table is being checked

    func testIDTUDIndexesRefusedBeforeCutadaptAndNamed() async throws {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let input = project.appendingPathComponent("reads.fastq")
        try "@r1\nACGTACGTACGTACGT\n+\nIIIIIIIIIIIIIIII\n".write(to: input, atomically: true, encoding: .utf8)
        let config = DemultiplexConfig(
            inputURL: input,
            barcodeKit: BarcodeKitRegistry.idtUDIndexes,
            outputDirectory: project.appendingPathComponent("demux-out", isDirectory: true),
            barcodeLocation: .fivePrime,
            threads: 1
        )

        do {
            try await DemultiplexingPipeline().preflight(config: config)
            XCTFail("the preflight must refuse a kit whose sequences are being checked")
        } catch {
            let words = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(words.contains("IDT for Illumina UD Indexes (96 pairs)"), "the refusal names the kit, got: \(words)")
            XCTAssertTrue(words.contains("Custom Definition"), "the refusal gives the way out, got: \(words)")
        }
    }

    // MARK: - The preflight refuses what cutadapt cannot use

    func testPreflightRefusesAnAdapterLineWithoutBasesAndNamesTheKit() throws {
        for (index, line) in ["^", "$", "^...ACGTACGT", "ACGTACGT...", "^ACGT...$", "X"].enumerated() {
            let fasta = root.appendingPathComponent("empty-side-\(index).fasta")
            try ">a\n\(line)\n".write(to: fasta, atomically: true, encoding: .utf8)

            XCTAssertThrowsError(
                try DemultiplexingPipeline().requireAdapterSequences(in: fasta, kitName: "Test Kit"),
                "the line \(line) has no bases on one side"
            ) { error in
                guard case DemultiplexError.emptyAdapterSequences(let kitName) = error else {
                    return XCTFail("the line \(line) threw \(error)")
                }
                XCTAssertEqual(kitName, "Test Kit")
            }
        }

        let words = DemultiplexError.emptyAdapterSequences(kitName: "Test Kit").errorDescription ?? ""
        XCTAssertTrue(words.contains("Test Kit"), "the words name the kit, got: \(words)")
        XCTAssertTrue(words.contains("Custom Definition"), "the words give the way out, got: \(words)")
        XCTAssertFalse(words.contains("Adapter FASTA"), "the words do not quote the tool's file, got: \(words)")
    }

    func testPreflightRefusesTwoBarcodesWithOneAdapterLine() throws {
        let fasta = root.appendingPathComponent("twins.fasta")
        try ">a\n^ACGTACGT\n>b\n^ACGTACGT\n".write(to: fasta, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try DemultiplexingPipeline().requireAdapterSequences(in: fasta, kitName: "Test Kit")
        ) { error in
            guard case DemultiplexError.ambiguousAdapterSequences(let kitName) = error else {
                return XCTFail("two barcodes with one line must throw ambiguousAdapterSequences, got \(error)")
            }
            XCTAssertEqual(kitName, "Test Kit")
            let words = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(words.contains("Test Kit"), "the words name the kit, got: \(words)")
            XCTAssertTrue(words.contains("Custom Definition"), "the words give the way out, got: \(words)")
        }
    }

    /// The strict check stands in front of every built-in kit, so a kit that repeats a sequence under two names, or
    /// builds a line with an empty side, would stop running. IDT UD is refused by id and a combinatorial kit needs
    /// sample assignments, so both are left out.
    func testEveryOtherBuiltInKitStillBuildsAnUnambiguousAdapterFile() async throws {
        for kit in BarcodeKitRegistry.builtinKits()
        where kit.id != BarcodeKitRegistry.idtUDIndexes.id && kit.pairingMode != .combinatorialDual {
            for location in [BarcodeLocation.bothEnds, .fivePrime, .threePrime] {
                do {
                    let file = try await adapterFile(kit, location: location)
                    XCTAssertFalse(file.lines.isEmpty, "\(kit.id) at \(location) builds no line")
                } catch {
                    XCTFail("\(kit.id) at \(location) builds no usable adapter file: \(error)")
                }
            }
        }
    }
}
