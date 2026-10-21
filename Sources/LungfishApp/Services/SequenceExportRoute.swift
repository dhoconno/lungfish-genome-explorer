// SequenceExportRoute.swift - The Import Center's sequence export, run as lungfish-cli convert
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishKit
import LungfishWorkflow

/// Runs the Import Center's sequence export as `lungfish-cli convert` (Phase 2.11 lane A49 M3, plan decisions
/// C4, C5 and C6), so the command the row records is the command that runs, and the compression happens in the
/// command, on ``SequenceExportCompressor``, not in the app.
///
/// `convert` reads one or more files and writes one output, compressed when `--compress` is given. A captured
/// document snapshot (sequences held in memory with no file) and a file `convert` cannot read are staged as
/// files first by ``SequenceExportStaging`` (Phase 2.12 lane 12.13), so every selection runs here.
///
/// A cancel of the calling task goes through ``CLIRunCancellation``. The command gets SIGTERM and
/// ``CLIProcessLauncher/operationGrace`` before SIGKILL, and the route then removes the stage files a stopped
/// command leaves beside the output.
enum SequenceExportRoute {
    /// A run of the command that ended with a nonzero status, or printed no count.
    struct RouteError: LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }

    /// The extensions `convert` reads, after a trailing `.gz`.
    private static let convertExtensions: Set<String> = [
        "fa", "fasta", "fna", "faa", "gb", "gbk", "genbank", "gbff", "fastq", "fq", "lungfishref",
    ]

    /// Whether `convert` can read `url`.
    static func convertReads(_ url: URL) -> Bool {
        var base = url
        if base.pathExtension.lowercased() == "gz" { base = base.deletingPathExtension() }
        return convertExtensions.contains(base.pathExtension.lowercased())
    }

    /// The argv, `convert` first, that exports `inputs` to `outputURL`. The run and the row's command are this.
    /// A GenBank export and a reference bundle carry their annotations, as the in-app export did. `--format json`
    /// with `--quiet` leaves the count of sequences alone on standard output.
    static func arguments(
        inputs: [URL],
        outputURL: URL,
        format: SequenceExportFormat,
        compression: SequenceExportCompression
    ) -> [String] {
        var arguments = ["convert"] + inputs.map(\.path) + ["--to", outputURL.path, "--to-format", format.cliFormat]
        if format == .genbank || inputs.contains(where: { $0.pathExtension.lowercased() == "lungfishref" }) {
            arguments.append("--include-annotations")
        }
        if let kind = compression.compressorKind {
            arguments += ["--compress", kind.rawValue]
        }
        return arguments + ["--force", "--format", "json", "--quiet"]
    }

    /// Runs `arguments` and returns the count of sequences the command wrote.
    ///
    /// - Throws: `CancellationError` once a cancel of the calling task has stopped the command,
    ///   ``RouteError`` when the command fails, with what it printed on standard error.
    static func run(arguments: [String], outputURL: URL) async throws -> Int {
        guard let cli = LungfishCLIRunner.findCLI() else { throw LungfishCLIRunner.RunError.cliNotFound }
        let spec = CLIProcessLauncher.spec(
            executableURL: cli,
            arguments: arguments,
            standardOutput: .captured,
            terminationGracePeriod: CLIProcessLauncher.operationGrace,
            drainGracePeriod: CLIProcessLauncher.operationDrain
        )
        let outcome = await CLIProcessLauncher.run(spec, cancellation: CLIRunCancellation())
        switch outcome {
        case .exited(let exit) where exit.succeeded:
            return try count(in: exit.stdout)
        case .cancelled(let exit?) where exit.succeeded:
            // A command that exits 0 had published before the cancel reached it.
            return try count(in: exit.stdout)
        case .exited(let exit):
            removeStages(beside: outputURL)
            let detail = exit.failureDetail.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RouteError(
                detail: detail.isEmpty
                    ? "lungfish-cli convert exited with status \(exit.status)"
                    : plainWords(in: namingChosenFiles(in: detail, arguments: arguments))
            )
        case .cancelled:
            removeStages(beside: outputURL)
            throw CancellationError()
        case .launchFailed(let reason):
            throw LungfishCLIRunner.RunError.launchFailed(reason)
        }
    }

    /// `detail` with each staged input of `arguments` named as the file the person chose (2.13 decision MD59), so
    /// the Export Failed alert for `empty.seq` names `empty.seq` and not its copy `1-empty.seq.fa`. Staging writes
    /// ``SequenceExportStaging/selectionFileName`` beside the staged files, one entry for each input in the order
    /// of the run, so an input that is not the chosen file maps back to the chosen file's path and name. A whole
    /// path or name is replaced, never a part of a longer one, and a run that staged nothing keeps its text.
    static func namingChosenFiles(in detail: String, arguments: [String]) -> String {
        guard arguments.first == "convert" else { return detail }
        let inputs = arguments.dropFirst().prefix { $0 != "--to" }.map { URL(fileURLWithPath: $0) }
        var chosenFor: [String: String] = [:]
        for folder in Set(inputs.map { $0.deletingLastPathComponent() }) {
            let selection = folder.appendingPathComponent(SequenceExportStaging.selectionFileName)
            guard let data = try? Data(contentsOf: selection),
                  let chosen = try? JSONDecoder().decode([SequenceExportSourceResolver.Metadata].self, from: data),
                  chosen.count == inputs.count else { continue }
            for (input, source) in zip(inputs, chosen.map(\.url))
            where input.deletingLastPathComponent() == folder && input.path != source.path {
                chosenFor[input.path] = source.path
                chosenFor[input.lastPathComponent] = source.lastPathComponent
            }
        }
        guard !chosenFor.isEmpty else { return detail }
        let names = chosenFor.keys.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:))
        let pattern = "(?<![A-Za-z0-9._/-])(?:" + names.joined(separator: "|") + ")(?![A-Za-z0-9_/-]|\\.[A-Za-z0-9])"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return detail }
        var named = detail
        for match in expression.matches(in: detail, range: NSRange(detail.startIndex..., in: detail)).reversed() {
            guard let range = Range(match.range, in: named), let chosen = chosenFor[String(named[range])] else { continue }
            named.replaceSubrange(range, with: chosen)
        }
        return named
    }

    /// `detail` without the command's own markers `Error: ` and `Conversion failed: ` at its start. The alert's
    /// title Export Failed already says the export failed, and the person chose Export Sequences, not a
    /// conversion (2.13 lane 13.41, UX ruling on MD59). The cause that follows stays whole, and a cause with its
    /// own words, such as `Input file not found: /path`, keeps them. Terminal text keeps both markers.
    static func plainWords(in detail: String) -> String {
        var words = Substring(detail)
        for marker in ["Error: ", "Conversion failed: "] where words.hasPrefix(marker) {
            words = words.dropFirst(marker.count)
        }
        return String(words)
    }

    /// The `sequenceCount` of the JSON result `convert --format json` prints.
    private static func count(in standardOutput: String) throws -> Int {
        struct Summary: Decodable { let sequenceCount: Int }
        let text = standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = text.data(using: .utf8), let summary = try? JSONDecoder().decode(Summary.self, from: data) else {
            throw RouteError(detail: "The export finished without reporting how many sequences it wrote.")
        }
        return summary.sequenceCount
    }

    /// Removes the hidden stage files and folders of `convert` that a stopped run left beside `outputURL`.
    /// Each name starts with a dot and holds the output's name and `.convert.`.
    static func removeStages(beside outputURL: URL) {
        let folder = outputURL.deletingLastPathComponent()
        let marker = ".\(outputURL.lastPathComponent)."
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix(".") && name.contains(marker) && name.contains(".convert.") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}

extension SequenceExportCompression {
    /// The compressor the export runs, or nil when the export is not compressed.
    var compressorKind: SequenceExportCompressor.Kind? {
        switch self {
        case .none: return nil
        case .gzip: return .gzip
        case .zstd: return .zstd
        }
    }
}
