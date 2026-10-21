// RouteParityHarnessTests.swift - The route parity harness's compare and declared list, with no CLI run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q30, review fixes 1 to 3. Each test builds the roots of side A and side C from
// text and calls the harness's compare or declared list directly. No test launches a CLI, so the
// class stays in the unit tier. RouteParityHarnessReplayTests runs the built CLI on all three sides.

import Foundation
import Synchronization
import XCTest
import LungfishKitTestSupport
import LungfishTestSupport

/// Counts the calls of a stand-in descriptor call, from any thread.
private final class DescriptorCallCounter: Sendable {
    private let count = Mutex(0)

    /// The number of this call, from 1.
    func next() -> Int {
        count.withLock { value in
            value += 1
            return value
        }
    }
}

final class RouteParityHarnessTests: XCTestCase {
    /// 13.43-M3 review Fix 1, ruling 1 (M-1, M-2, M-4 and M-5 of the Masks rows of docs/contracts/CLI-EQUIVALENCE.md).
    /// Each mask hides the clock, the record digest or the own root and nothing else. Two texts that differ only there
    /// compare equal under the standard masks, and the same texts with one other value changed compare unequal.
    func testTheCaptureTimeMasksHideOnlyTheTimestamp() throws {
        let context = OutputEquivalence.MaskContext(
            rootA: URL(fileURLWithPath: "/tmp/side-a"), rootB: URL(fileURLWithPath: "/tmp/side-b"))
        let policy = OutputEquivalence.MaskPolicy.standard
        func payload(_ text: String) -> String {
            policy.payloads.reduce(text) { partial, mask in mask(partial, context: context) }
        }
        func record(_ text: String) -> String {
            policy.records.reduce(text) { partial, mask in mask(partial, context: context) }
        }
        func order(_ capturedAt: Double, sequence: String = "ACGT", pool: Int = 1) -> String {
            #"{"metadata":{"name":"Pair order"},"oligos":[{"pool":\#(pool),"sequence":"\#(sequence)"}],"selection":{"capturedAt":\#(capturedAt),"selectedPrimerIDs":["p1"]}}"#
        }
        func sheet(_ stamp: String, sequence: String = "ACGT") -> String {
            "<worksheet><sheetData><row><c><is><t>Captured at</t></is></c><c><is><t>\(stamp)</t></is></c></row>"
                + "<row><c><is><t>\(sequence)</t></is></c></row></sheetData></worksheet>"
        }
        func provenance(_ file: String, digest: String, size: Int) -> String {
            #"{"outputs":[{"path":"\#(file)","checksumSHA256":"\#(digest)","fileSize":\#(size)}]}"#
        }
        func manifest(_ folder: String, name: String = "source") -> String {
            #"{"name":"pool","source":{"source_url":"file:///tmp/case/\#(folder)/\#(name).lungfishprimeranalysis/"}}"#
        }
        func sourced(_ url: String) -> String {
            #"{"name":"pool","source":{"source_url":"\#(url)"}}"#
        }

        XCTAssertEqual(payload(order(814269159.3)), payload(order(814269160.8)), "M-1 hides the capture time")
        XCTAssertNotEqual(
            payload(order(814269159.3)), payload(order(814269159.3, sequence: "ACGA")), "M-1 keeps a primer sequence")
        XCTAssertNotEqual(payload(order(814269159.3)), payload(order(814269159.3, pool: 2)), "M-1 keeps a pool number")

        XCTAssertEqual(
            payload(sheet("2026-10-21T04:44:22Z")), payload(sheet("2026-10-21T04:44:25Z")), "M-2 hides the capture time")
        XCTAssertNotEqual(
            payload(sheet("2026-10-21T04:44:22Z")), payload(sheet("2026-10-21T04:44:22Z", sequence: "ACGA")),
            "M-2 keeps every other cell")

        for file in ["order/order.json", "order/primer-order.xlsx", "order/workbook-parts/xl/worksheets/sheet1.xml"] {
            XCTAssertEqual(
                record(provenance(file, digest: "aa", size: 10)), record(provenance(file, digest: "bb", size: 11)),
                "M-4 hides the digest and size of \(file)")
        }
        XCTAssertNotEqual(
            record(provenance("order/ordering.csv", digest: "aa", size: 10)),
            record(provenance("order/ordering.csv", digest: "bb", size: 10)), "M-4 keeps the digest of any other file")

        XCTAssertEqual(record(manifest("A-route")), record(manifest("C-route")), "M-5 hides a side's own root")
        XCTAssertNotEqual(
            record(manifest("A-route")), record(manifest("A-route", name: "other")), "M-5 keeps the source folder's name")
        XCTAssertNotEqual(
            record(sourced("https://example.org/a/ref.fa")), record(sourced("https://example.net/b/ref.fa")),
            "M-5 keeps a remote source_url")
        XCTAssertNotEqual(
            record(sourced("/Users/lab/a/ref.fa")), record(sourced("/Users/lab/b/ref.fa")),
            "M-5 keeps a local path that is not a primer analysis folder")
    }

    /// M-3. The order workbook is compared through its parts and not by its own bytes, and a changed part still differs.
    func testTheOrderWorkbookIsComparedThroughItsParts() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appendingPathComponent("order-workbook-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: base) }
        func tree(_ name: String, archive: [UInt8], sheet: String) throws -> URL {
            let root = base.appendingPathComponent(name)
            try fileManager.createDirectory(
                at: root.appendingPathComponent("workbook-parts"), withIntermediateDirectories: true)
            try Data([0x50, 0x4B, 0x03, 0x04] + archive).write(to: root.appendingPathComponent("primer-order.xlsx"))
            try Data(sheet.utf8).write(to: root.appendingPathComponent("workbook-parts/sheet1.xml"))
            return root
        }
        let stamped = "<worksheet><t>Captured at</t><t>2026-10-21T04:44:22Z</t><t>ACGT</t></worksheet>"
        let later = "<worksheet><t>Captured at</t><t>2026-10-21T04:44:25Z</t><t>ACGT</t></worksheet>"
        let changed = "<worksheet><t>Captured at</t><t>2026-10-21T04:44:22Z</t><t>ACGA</t></worksheet>"
        let first = try tree("a", archive: [1, 2], sheet: stamped)
        let second = try tree("b", archive: [3, 4, 5], sheet: later)
        let third = try tree("c", archive: [1, 2], sheet: changed)
        XCTAssertEqual(
            try OutputEquivalence.compare(first, second, kind: .files, masks: .standard).differences, [],
            "archives with other bytes and a later capture time are the same workbook")
        XCTAssertFalse(
            try OutputEquivalence.compare(first, third, kind: .files, masks: .standard).differences.isEmpty,
            "a changed cell of a part is a difference")
    }

    private var scratch: URL!
    private let harness = RouteParityHarness(cliBinary: URL(fileURLWithPath: "/usr/bin/false"), kind: .bundle)

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "route-parity-harness-unit")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    /// Completed sides A and C, each a root holding `files` by relative name.
    private func sides(_ filesA: [String: String], _ filesC: [String: String]) throws -> (RouteParitySideRun, RouteParitySideRun) {
        func side(_ side: RouteParitySide, _ files: [String: String]) throws -> RouteParitySideRun {
            let root = scratch.appendingPathComponent(side.folderName, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for (name, text) in files {
                try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            return RouteParitySideRun(side: side, root: root, outcome: RouteParitySideOutcome(end: .completed))
        }
        return (try side(.a, filesA), try side(.c, filesC))
    }

    /// A side fact, such as side C recording no command, cannot be declared, so no case skips side C'.
    func testOnlyAAgainstCDeclares() {
        let missing = RouteParityDifference(id: "command: side C records no command")
        let entry = RouteParityDeclaredDifference<String>(
            ["case": 1], missing.id, scope: .side(.c), reason: "an entry that tries to skip the replay", closedBy: "Q30"
        )
        XCTAssertEqual(
            RouteParityHarness.failures(found: [.side(.c): [missing]], parityCase: "case", declared: [entry]),
            [
                "side C declares nothing, delete the entry (closed by Q30): command: side C records no command",
                "side C: not declared: command: side C records no command",
            ]
        )
    }

    /// A `*` in an id is data, such as a stop codon, and only `<ANY>` matches any run of characters.
    func testAStarInAnIdMatchesOnlyAStar() {
        let stop = RouteParityDeclaredDifference<String>(
            ["case": 1], "differs: proteins.fasta: only in C: MAKFGP*MR", reason: "a stop codon", closedBy: "Q30"
        )
        XCTAssertTrue(stop.matches(RouteParityDifference(id: "differs: proteins.fasta: only in C: MAKFGP*MR")))
        XCTAssertFalse(stop.matches(RouteParityDifference(id: "differs: proteins.fasta: only in C: MAKFGPQQMR")))
        let any = RouteParityDeclaredDifference<String>(
            ["case": 1], "differs: proteins.fasta: <ANY>", reason: "any line", closedBy: "Q30"
        )
        XCTAssertTrue(any.matches(RouteParityDifference(id: "differs: proteins.fasta: only in C: MAKFGPQQMR")))
    }

    /// One changed line and a reorder in one file give the line and the order, so a declared line cannot cover the reorder.
    func testAReorderBesideAnExplainedLineIsFound() throws {
        let (a, c) = try sides(["rows.tsv": "head\nx\ny\n"], ["rows.tsv": "head2\ny\nx\n"])
        XCTAssertEqual(try harness.differences(a, c).map(\.id), [
            "differs: rows.tsv: only in A: head",
            "differs: rows.tsv: only in C: head2",
            "differs: rows.tsv: line order",
        ])
    }

    /// Side C's record swaps its input and output links beside a value that differs anyway. The
    /// explanation reads the record as the comparison did, with UUIDs numbered across each tree,
    /// so the swapped links are found beside the value and cannot hide under its entry (review fix 4).
    func testASwappedRecordLinkBesideADeclaredValueIsFound() throws {
        let (u1, u2, v1, v2) = (UUID().uuidString, UUID().uuidString, UUID().uuidString, UUID().uuidString)
        let (a, c) = try sides(
            ["in-\(u1).txt": "x\n", "out-\(u2).txt": "y\n",
             "run.lungfish-provenance.json": #"{"input":"\#(u1)","output":"\#(u2)","tool":"a"}"#],
            ["in-\(v1).txt": "x\n", "out-\(v2).txt": "y\n",
             "run.lungfish-provenance.json": #"{"input":"\#(v2)","output":"\#(v1)","tool":"c"}"#]
        )
        XCTAssertEqual(try harness.differences(a, c).map(\.id), [
            "differs: run.lungfish-provenance.json at input",
            "differs: run.lungfish-provenance.json at output",
            "differs: run.lungfish-provenance.json at tool",
        ])
    }

    // MARK: - What stays one difference

    /// A gzip file is explained by its decompressed lines, as the comparison reads it (BIO B-1).
    func testAGzipFileIsExplainedByItsDecompressedLines() throws {
        let (a, c) = try sides(["reads.txt": "head\nx\n"], ["reads.txt": "head\ny\n"])
        for root in [a.root, c.root] {
            try Self.gzip(root.appendingPathComponent("reads.txt"))
        }
        XCTAssertEqual(try harness.differences(a, c).map(\.id), [
            "differs: reads.txt.gz: only in A: x",
            "differs: reads.txt.gz: only in C: y",
        ])
    }

    /// A file whose lines differ only in order is that one difference, which an entry may declare.
    func testAFileThatDiffersOnlyInOrderIsOneLineOrderDifference() throws {
        let (a, c) = try sides(["rows.tsv": "x\ny\n"], ["rows.tsv": "y\nx\n"])
        XCTAssertEqual(try harness.differences(a, c).map(\.id), ["differs: rows.tsv: line order"])
    }

    /// A binary file and a file with more lines changed than the explanation lists each stay one
    /// whole-file difference, and an entry that matches one fails (panel G5, BIO B-7).
    func testAWholeFileDifferenceCannotBeDeclared() throws {
        let many = (1...51).map { "row \($0)" }
        let (a, c) = try sides(
            ["rows.tsv": many.joined(separator: "\n"), "notes.txt": "kept\n"],
            ["rows.tsv": many.map { $0 + " changed" }.joined(separator: "\n"), "notes.txt": "kept\n"]
        )
        try Data([0xff, 0xfe, 0x00, 0x01]).write(to: a.root.appendingPathComponent("blob.bin"))
        try Data([0xff, 0xfe, 0x00, 0x02]).write(to: c.root.appendingPathComponent("blob.bin"))
        let found = try harness.differences(a, c)
        XCTAssertEqual(found.map(\.id), ["differs: blob.bin", "differs: rows.tsv"])
        XCTAssertEqual(found.map(\.wholeFile), [true, true])

        let entry = RouteParityDeclaredDifference<String>(
            ["case": 1], "differs: rows.tsv<ANY>", reason: "an entry that tries to declare a whole file", closedBy: "Q30"
        )
        let failures = RouteParityHarness.failures(found: [.aAgainstC: found], parityCase: "case", declared: [entry])
        XCTAssertEqual(failures.map { $0.components(separatedBy: "\n")[0] }, [
            "A against C: not declared: differs: blob.bin",
            "A against C: not declared: differs: rows.tsv",
            "A against C: a whole file cannot be declared, narrow the entry or show the file the same (closed by Q30): differs: rows.tsv<ANY>",
        ])
    }

    /// A provenance envelope holds the host's and the tools' argument vectors and the paths of every
    /// step, so one record legitimately differs in more than `explainedLimit` values. The harness
    /// explains it up to 1,000 values, and each value keeps its own difference with an exact count
    /// (lane A45 M1 ruling, section 3). A JSON payload that is no envelope keeps the limit of 50.
    func testAProvenanceEnvelopeIsExplainedPastFiftyValues() throws {
        func record(_ value: String) -> String {
            "{" + (0..<60).map { #""option\#(String(format: "%02d", $0))":"\#(value)""# }.joined(separator: ",") + "}"
        }
        let (a, c) = try sides(
            ["run.lungfish-provenance.json": record("a"), "payload.json": record("a")],
            ["run.lungfish-provenance.json": record("c"), "payload.json": record("c")]
        )
        let found = try harness.differences(a, c)
        let envelope = found.filter { $0.id.hasPrefix("differs: run.lungfish-provenance.json") }
        XCTAssertEqual(envelope.count, 60, "one difference for each value")
        XCTAssertEqual(envelope.filter(\.wholeFile).count, 0, "none of them stands for a whole file")
        XCTAssertEqual(envelope.first?.id, "differs: run.lungfish-provenance.json at option00")
        XCTAssertEqual(
            found.filter { $0.id == "differs: payload.json" }.map(\.wholeFile), [true],
            "a JSON file that is no provenance envelope stays one whole-file difference past 50 values")

        // An entry declares the envelope's values with an exact count, so one more or one fewer fails.
        func entry(_ count: Int) -> RouteParityDeclaredDifference<String> {
            RouteParityDeclaredDifference(
                ["case": count], "differs: run.lungfish-provenance.json at <ANY>", reason: "every option of the record", closedBy: "Q30")
        }
        XCTAssertEqual(
            RouteParityHarness.failures(found: [.aAgainstC: envelope], parityCase: "case", declared: [entry(60)]), [])
        XCTAssertEqual(
            RouteParityHarness.failures(found: [.aAgainstC: envelope], parityCase: "case", declared: [entry(59)])
                .map { $0.components(separatedBy: "\n")[0] },
            ["A against C: 60 differences match, 59 declared for case (closed by Q30): differs: run.lungfish-provenance.json at <ANY>"])
    }

    /// Past 1,000 values a provenance envelope is a different record, and stays one whole-file difference.
    func testAProvenanceEnvelopePastAThousandValuesStaysOneWholeFileDifference() throws {
        func record(_ value: String) -> String {
            "{" + (0..<1_001).map { #""option\#($0)":"\#(value)""# }.joined(separator: ",") + "}"
        }
        let (a, c) = try sides(["run.lungfish-provenance.json": record("a")], ["run.lungfish-provenance.json": record("c")])
        let found = try harness.differences(a, c)
        XCTAssertEqual(found.map(\.id), ["differs: run.lungfish-provenance.json"])
        XCTAssertEqual(found.map(\.wholeFile), [true])
    }

    // MARK: - Each side's own facts

    /// A file a side wrote that names another side's root is a fact of that side, which no entry
    /// declares. A fixture file that names root A and that no side changed is left out.
    @MainActor
    func testAFileThatNamesAnotherSidesRootIsAFact() async throws {
        let runs = try await harness.run(
            in: scratch.appendingPathComponent("case", isDirectory: true),
            fixture: { root in
                try "built in \(root.path)\n".write(to: root.appendingPathComponent("fixture.txt"), atomically: true, encoding: .utf8)
            },
            sideA: { _ in RouteParitySideOutcome(end: .completed) },
            sideC: { root in
                let rootA = RouteParityHarness.root(of: .a, in: root.deletingLastPathComponent())
                try #"{"input":"\#(rootA.path)/fixture.txt"}"#
                    .write(to: root.appendingPathComponent("run.lungfish-provenance.json"), atomically: true, encoding: .utf8)
                return RouteParitySideOutcome(end: .completed)
            }
        )
        let found = try harness.differences(of: runs)
        XCTAssertEqual(found[.side(.a)], [])
        XCTAssertEqual(found[.side(.c)]?.map(\.id), [
            "fact: run.lungfish-provenance.json names the root of side A",
            "command: side C records no command",
        ])
        XCTAssertEqual(found[.side(.cPrime)], [])
    }

    // MARK: - The dump

    /// The dump keeps the case's roots and a report of each side's end, the recorded command, every
    /// difference by scope and every failure, which is where a family reads its counts (review note 3).
    func testTheDumpKeepsTheRootsAndAReport() throws {
        let (a, c) = try sides(["rows.tsv": "x\n"], ["rows.tsv": "y\n"])
        let cPrimeRoot = scratch.appendingPathComponent(RouteParitySide.cPrime.folderName, isDirectory: true)
        try FileManager.default.copyItem(at: c.root, to: cPrimeRoot)
        let runs = RouteParityRuns(
            caseRoot: scratch,
            a: a,
            c: RouteParitySideRun(side: .c, root: c.root, outcome: RouteParitySideOutcome(end: .completed, recordedCommand: "lungfish-cli x")),
            cPrime: RouteParitySideRun(side: .cPrime, root: cPrimeRoot, outcome: RouteParitySideOutcome(end: .completed))
        )
        let dump = try TestTempDirectory.make(prefix: "route-parity-dump")
        defer { TestTempDirectory.cleanup(dump) }

        let result = try harness.evaluate("rows", declared: [RouteParityDeclaredDifference<String>](), runs: runs, dumpingTo: dump)
        XCTAssertEqual(result.failures.count, 2)
        let report = try String(contentsOf: dump.appendingPathComponent("rows/report.txt"), encoding: .utf8)
        for expected in [
            "side C: Completed, \nrecorded command:\nlungfish-cli x\n",
            "A against C: 2\n  differs: rows.tsv: only in A: x\n  differs: rows.tsv: only in C: y\nC against C': 0\n",
            "failures: 2\n  A against C: not declared: differs: rows.tsv: only in A: x\n",
        ] {
            XCTAssertTrue(report.contains(expected), "report.txt lacks \(expected) in:\n\(report)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dump.appendingPathComponent("rows/A-route/rows.tsv").path))
    }

    // MARK: - Standard output in process (2.8 Q4, the second half of 2.10 Q14)

    /// `dup` fails, so standard output cannot be saved. The capture throws before the body runs
    /// and leaves standard output where it was.
    func testAFailedDupThrowsBeforeTheBodyRuns() async throws {
        try await assertCaptureFails(.notSaved, bodyRuns: false) { system, _ in
            RouteParityHarness.DescriptorCalls(dup: { _ in -1 }, dup2: system.dup2)
        }
    }

    /// The `dup2` that sends standard output to the file fails. The capture puts standard output
    /// back and throws before the body runs.
    func testAFailedRedirectPutsStandardOutputBackAndThrows() async throws {
        try await assertCaptureFails(.notMoved, bodyRuns: false) { system, calls in
            RouteParityHarness.DescriptorCalls(dup: system.dup, dup2: { calls.next() == 1 ? -1 : system.dup2($0, $1) })
        }
    }

    /// The `dup2` that puts standard output back fails after the body ran. The capture throws, and
    /// the test puts standard output back itself.
    func testAFailedRestoreThrows() async throws {
        try await assertCaptureFails(.notRestored, bodyRuns: true) { system, calls in
            RouteParityHarness.DescriptorCalls(dup: system.dup, dup2: { calls.next() == 2 ? -1 : system.dup2($0, $1) })
        }
    }

    /// Runs a capture with the calls `make` builds and asserts it throws `expected`, ran its body
    /// or not, and, unless the restore failed, left standard output where it was. Standard output
    /// is put back before any assertion, whatever the capture did, so every failure shows.
    private func assertCaptureFails(
        _ expected: RouteParityHarness.StandardOutputError,
        bodyRuns: Bool,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ make: (RouteParityHarness.DescriptorCalls, DescriptorCallCounter) -> RouteParityHarness.DescriptorCalls
    ) async throws {
        let original = dup(STDOUT_FILENO)
        defer {
            dup2(original, STDOUT_FILENO)
            close(original)
        }
        let before = try Self.standardOutputIdentity()
        var ran = false
        var thrown: (any Error)?
        do {
            _ = try await RouteParityHarness.capturingStandardOutput(
                in: scratch, descriptors: make(.system, DescriptorCallCounter())
            ) { ran = true }
        } catch {
            thrown = error
        }
        let after = try Self.standardOutputIdentity()
        dup2(original, STDOUT_FILENO)
        XCTAssertEqual(thrown as? RouteParityHarness.StandardOutputError, expected, "\(String(describing: thrown))", file: file, line: line)
        XCTAssertEqual(ran, bodyRuns, "whether the body ran", file: file, line: line)
        if expected != .notRestored {
            XCTAssertEqual(after, before, "standard output stays where it was", file: file, line: line)
        }
    }

    /// The device and inode standard output points at.
    private static func standardOutputIdentity() throws -> [Int64] {
        var info = stat()
        guard fstat(STDOUT_FILENO, &info) == 0 else { throw POSIXError(.EBADF) }
        return [Int64(info.st_dev), Int64(bitPattern: info.st_ino)]
    }

    /// Compresses `file` in place with gzip, which leaves `<file>.gz`.
    private static func gzip(_ file: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-n", file.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "gzip \(file.lastPathComponent)")
    }
}
