// SRAToolkitRecordedRunner.swift - An SRA Toolkit double that writes recorded fasterq-dump output
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// A scripted SRA Toolkit whose `fasterq-dump` writes the files the real
/// tool wrote for a run, from `Tests/Fixtures/sra/fasterq-dump-split-3`.
///
/// `prefetch` writes a stand-in archive under `<output>/<accession>/`.
/// `fasterq-dump` copies the run's recorded files into its `-O` folder. The
/// runner keeps every argument list it was given, so a test can check the
/// split mode. No tool is spawned and no network is reached.
public final class SRAToolkitRecordedRunner: @unchecked Sendable {
    /// The accession of the recorded paired run with spots that hold one
    /// read: 129 pairs and 6 reads without a mate.
    public static let pairedRunWithSingletons = "ERR12390094"
    /// The accession of the recorded single-end run: 53 reads.
    public static let singleEndRun = "ERR10019355"

    private let lock = NSLock()
    private var recordedFasterqArguments: [[String]] = []
    private let fixtures: URL

    /// - Parameter testFile: The calling test's `#filePath`. The first
    ///   folder above it with a `Package.swift` holds the recorded files.
    public init(testFile: String) {
        var folder = URL(fileURLWithPath: testFile).deletingLastPathComponent()
        while folder.path != "/",
              !FileManager.default.fileExists(atPath: folder.appendingPathComponent("Package.swift").path) {
            folder = folder.deletingLastPathComponent()
        }
        fixtures = folder.appendingPathComponent("Tests/Fixtures/sra/fasterq-dump-split-3", isDirectory: true)
    }

    /// Every argument list `fasterq-dump` was run with, in order.
    public var fasterqArguments: [[String]] {
        lock.withLock { recordedFasterqArguments }
    }

    /// The recorded files of `accession`, sorted by name.
    public func recordedFiles(of accession: String) throws -> [URL] {
        let folder = fixtures.appendingPathComponent(accession, isDirectory: true)
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "fastq" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The runner `SRAService(toolkitRunner:)` takes.
    public var runner: SRAToolkitRunner {
        let prefetch = URL(fileURLWithPath: "/managed/sra-tools/bin/prefetch")
        return SRAToolkitRunner(
            prefetch: prefetch,
            fasterqDump: URL(fileURLWithPath: "/managed/sra-tools/bin/fasterq-dump")
        ) { [self] executable, arguments in
            guard let outputIndex = arguments.firstIndex(of: "-O"), outputIndex + 1 < arguments.count else {
                return SRAToolkitRunner.Result(exitCode: 2, stderr: "no -O folder")
            }
            let outputDirectory = URL(fileURLWithPath: arguments[outputIndex + 1], isDirectory: true)
            if executable == prefetch {
                let archiveFolder = outputDirectory.appendingPathComponent(arguments[0], isDirectory: true)
                try FileManager.default.createDirectory(at: archiveFolder, withIntermediateDirectories: true)
                try Data("archive".utf8).write(to: archiveFolder.appendingPathComponent("\(arguments[0]).sra"))
                return SRAToolkitRunner.Result(exitCode: 0)
            }
            lock.withLock { recordedFasterqArguments.append(arguments) }
            let accession = URL(fileURLWithPath: arguments[0]).deletingPathExtension().lastPathComponent
            for file in try recordedFiles(of: accession) {
                let destination = outputDirectory.appendingPathComponent(file.lastPathComponent)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: file, to: destination)
            }
            return SRAToolkitRunner.Result(exitCode: 0)
        }
    }
}
