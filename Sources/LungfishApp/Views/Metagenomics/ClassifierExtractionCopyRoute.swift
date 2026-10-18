// ClassifierExtractionCopyRoute.swift - The command behind the extraction sheet's clipboard and share destinations
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow

/// A clipboard or share extraction of the classifier extraction sheet (Phase 2.12 lane 12.11, decision C13
/// of 2.10).
///
/// The row runs `lungfish-cli extract reads --by-classifier` on ``CLIBundleBuildRunner`` and records that
/// command, so Copy CLI Command replays the extraction. The command writes the selection into
/// ``scratchFile``. For the clipboard that file sits in a folder of the project's `.tmp`. For a share it
/// sits in a new folder of `<project>/.lungfish/.tmp/shares`, where the share picker reads it after the
/// sheet closes, beside the command's own record.
///
/// The only step in the app is the copy, ``deliver()``, which runs off the main actor. It counts the
/// file's reads, refuses a clipboard copy over the cap with
/// ``ClassifierExtractionError/clipboardCapExceeded(requested:cap:)``, and returns the pasteboard text or
/// the file to share. ``run(operationID:cliURLOverride:environmentAdditions:)`` removes the clipboard's
/// folder after the copy, a refusal, a failure and a cancel, and a share's folder after a refusal, a
/// failure and a cancel.
struct ClassifierExtractionCopyRoute: Sendable {
    /// What the copy hands the person.
    enum Delivery: Sendable, Equatable {
        /// The file's text on the pasteboard, refused over `cap` reads.
        case clipboard(cap: Int)
        /// The file itself, for the share picker.
        case share
    }

    let delivery: Delivery
    /// The format the command writes.
    let format: CopyFormat
    /// The folder the command writes into, which holds nothing else.
    let scratchDirectory: URL
    /// The file the command's `-o` names.
    let scratchFile: URL
    /// The argv after `lungfish-cli` that the row records and the runner runs.
    let arguments: [String]

    /// The route for `destination` with a new folder for the command, or nil for a file or bundle,
    /// which the resolver writes in process.
    @MainActor
    static func make(
        destination: ExtractionDestination,
        context: TaxonomyReadExtractionAction.Context,
        options: ExtractionOptions
    ) throws -> ClassifierExtractionCopyRoute? {
        let delivery: Delivery
        let scratchDirectory: URL
        switch destination {
        case .file, .bundle:
            return nil
        case .clipboard(_, let cap):
            delivery = .clipboard(cap: cap)
            let projectRoot = ClassifierReadResolver.resolveProjectRoot(from: context.resultPath)
            scratchDirectory = try ProjectTempDirectory.create(prefix: "classifier-clipboard-", in: projectRoot)
        case .share(let shareRoot):
            delivery = .share
            scratchDirectory = shareRoot.appendingPathComponent("shares/\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        }
        let scratchFile = scratchDirectory.appendingPathComponent(fileName(tool: context.tool, format: options.format))
        let arguments = ["extract", "reads"] + TaxonomyReadExtractionAction.cliArguments(
            context: context,
            options: options,
            destination: destination,
            scratchFile: scratchFile
        )
        return ClassifierExtractionCopyRoute(
            delivery: delivery,
            format: options.format,
            scratchDirectory: scratchDirectory,
            scratchFile: scratchFile,
            arguments: arguments
        )
    }

    /// The name of the file the command writes, the name the resolver gave the file it shared before
    /// lane 12.11, so a shared file keeps its name (R-A1).
    static func fileName(tool: ClassifierTool, format: CopyFormat) -> String {
        "\(tool == .kraken2 ? "kraken2-concat" : "concatenated").\(format.rawValue)"
    }

    /// Runs the command for the row `operationID`, then the copy. A cancel of the calling task stops the
    /// command through the transport, as the row's Cancel does.
    ///
    /// - Parameters:
    ///   - cliURLOverride: The `lungfish-cli` to run, for a test. Nil finds the bundled one.
    ///   - environmentAdditions: Variables for this run only, such as a test's stand-in conda root.
    /// - Throws: `CancellationError` after a cancel, the runner's error when the command fails, or the
    ///   copy's refusal.
    @concurrent
    func run(
        operationID: UUID,
        cliURLOverride: URL? = nil,
        environmentAdditions: [String: String] = [:]
    ) async throws -> ExtractionOutcome {
        var shared = false
        defer {
            if !shared { try? FileManager.default.removeItem(at: scratchDirectory) }
        }
        let runner = CLIBundleBuildRunner(cliURLOverride: cliURLOverride)
        let arguments = arguments
        _ = try await withTaskCancellationHandler {
            try await runner.run(arguments: arguments, operationID: operationID, environmentAdditions: environmentAdditions)
        } onCancel: {
            runner.cancel()
        }
        try Task.checkCancellation()
        let outcome = try await deliver()
        shared = delivery == .share
        return outcome
    }

    /// The copy, off the main actor. It reads the command's file and returns what the person gets.
    @concurrent
    func deliver() async throws -> ExtractionOutcome {
        let readCount = try Self.countRecords(in: scratchFile, format: format)
        switch delivery {
        case .clipboard(let cap):
            if readCount > cap {
                throw ClassifierExtractionError.clipboardCapExceeded(requested: readCount, cap: cap)
            }
            let data = try Data(contentsOf: scratchFile)
            return .clipboard(payload: String(decoding: data, as: UTF8.self), byteCount: data.count, readCount: readCount)
        case .share:
            return .share(scratchFile, readCount: readCount)
        }
    }

    /// The reads of `file`, four lines a FASTQ record as the resolver counts them, or one `>` line a
    /// FASTA record. It reads the file in pieces and stops at a cancel.
    static func countRecords(in file: URL, format: CopyFormat) throws -> Int {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var lines = 0
        var headers = 0
        var atLineStart = true
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            for byte in chunk {
                if atLineStart, byte == UInt8(ascii: ">") { headers += 1 }
                atLineStart = byte == UInt8(ascii: "\n")
                if atLineStart { lines += 1 }
            }
        }
        if !atLineStart { lines += 1 }
        return format == .fasta ? headers : lines / 4
    }
}
