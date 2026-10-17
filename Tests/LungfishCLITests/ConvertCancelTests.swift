// ConvertCancelTests.swift - A SIGTERM cancels convert before it publishes and leaves no recovery folder
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A49 M3, fix F3 of review A49-M3. The Import Center's Cancel sends SIGTERM to
// `lungfish-cli convert` and gives it `CLIProcessLauncher.operationGrace` (6 seconds) before SIGKILL. `convert`
// copies the files it may replace into `lungfish-publication-recovery-<UUID>` in the temporary folder before it
// writes anything, and only a commit or a rollback removes that folder. A SIGTERM that ended the process left the
// folder, with a copy of the earlier export it was asked to overwrite, and the hidden stage entries beside the
// output. The command now turns SIGTERM into a cancel of the conversion, so the rollback and the stage cleanup run,
// and it exits 125 with nothing on standard output.

import Foundation
import XCTest
import LungfishTestSupport

final class ConvertCancelTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "convert-cancel")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testSIGTERMDuringCompressionExits125AndLeavesTheEarlierExport() async throws {
        let inputs = root.appendingPathComponent("inputs", isDirectory: true)
        let folder = root.appendingPathComponent("out", isDirectory: true)
        for directory in [inputs, folder] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let input = inputs.appendingPathComponent("records.fa")
        try Self.writeFASTA(to: input)
        let output = folder.appendingPathComponent("out.fa.gz")
        // The bytes are unique to this run, so the recovery folder that holds a copy of them is this run's.
        let earlier = Data("an earlier export \(UUID().uuidString)".utf8)
        try earlier.write(to: output)
        let before = Self.recoveryFolderNames()

        let run = try CLISIGTERMHarness.launchCLI(
            ["convert", input.path, "--to", output.path, "--compress", "gzip", "--force", "--format", "json", "--quiet"],
            workingDirectory: root,
            testClass: Self.self
        )
        defer { run.stop() }

        // The stage folder appears a moment before the command builds its publication transaction, and the first
        // place the command looks for a cancel is the compression, so the signal arrives while the command holds
        // its recovery folder and its stage entries, at the write or at the compression. The window is short in
        // the debug build, so the wait polls often and reads only the small output folder.
        let atWork = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(2)) {
            !Self.convertEntries(in: folder).isEmpty
        }
        guard atWork else {
            let stop = await CLISIGTERMHarness.cancel(run)
            return XCTFail("The command never made its stage.\(stop.diagnostics)")
        }

        // The grace is the 6 seconds of CLIProcessLauncher.operationGrace, which the harness repeats.
        let stop = await CLISIGTERMHarness.cancel(run)
        CLISIGTERMHarness.assertCancelledExit(stop)
        CLISIGTERMHarness.assertNoProcessLeft(stop)
        XCTAssertEqual(try Data(contentsOf: output), earlier, "a cancel keeps the earlier export")
        XCTAssertEqual(Self.convertEntries(in: folder), [], "no stage file or folder is left beside the output")
        XCTAssertEqual(
            Self.recoveryFolders(holding: earlier, since: before), [], "no recovery folder is left in the temporary folder"
        )
        XCTAssertEqual(stop.standardOutput, "", "a result leaf prints no event line, and no result for a cancel")
    }

    // MARK: - Helpers

    /// The hidden stage entries of `convert` in `folder`, whose names start with a dot and hold `.convert.`.
    private static func convertEntries(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix(".") && $0.contains(".convert.") }
            .sorted()
    }

    /// The names of the recovery folders now in the temporary folder.
    private static func recoveryFolderNames() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return Set(names.filter { $0.hasPrefix("lungfish-publication-recovery-") })
    }

    /// The recovery folders made since `before` that hold a copy of `earlier`. The temporary folder of `FileManager`
    /// does not follow a changed `TMPDIR` on macOS, so the command's folder lands beside the folders of other runs.
    /// The unique bytes of the earlier export tell it from them, and only a folder made since `before` is opened.
    private static func recoveryFolders(holding earlier: Data, since before: Set<String>) -> [String] {
        let temporary = FileManager.default.temporaryDirectory
        return recoveryFolderNames().subtracting(before).filter { name in
            let folder = temporary.appendingPathComponent(name, isDirectory: true)
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            return entries.contains { entry in
                let url = folder.appendingPathComponent(entry)
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                return (attributes?[.size] as? NSNumber)?.intValue == earlier.count && (try? Data(contentsOf: url)) == earlier
            }
        }.sorted()
    }

    /// A FASTA of 4 records of 64 KB of pseudo-random bases in 80-column lines. The debug build of lungfish-cli
    /// reads and writes a FASTA slowly (64 MB took over two minutes), so the file is small enough for the write
    /// to end well inside the 6 seconds the app gives a cancel, and large enough to hold the command at work for
    /// longer than a poll.
    private static func writeFASTA(to url: URL, records: Int = 4, bytesPerRecord: Int = 64 << 10) throws {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        let letters = Array("ACGT".utf8)
        var text = ""
        for index in 0..<records {
            var bases: [UInt8] = []
            bases.reserveCapacity(bytesPerRecord)
            for _ in 0..<bytesPerRecord {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                bases.append(letters[Int((state >> 33) & 3)])
            }
            text += ">record\(index)\n"
            var start = 0
            while start < bases.count {
                let end = min(start + 80, bases.count)
                text += String(decoding: bases[start..<end], as: UTF8.self) + "\n"
                start = end
            }
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
