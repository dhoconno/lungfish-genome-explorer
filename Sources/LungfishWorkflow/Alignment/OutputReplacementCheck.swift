// OutputReplacementCheck.swift - The checks a command runs before it replaces an existing output
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// Why a command refuses to replace an existing output. Every refusal runs
/// before anything is deleted, so a refused run leaves every file as it was.
public enum OutputReplacementRefusal: LocalizedError, Sendable, Equatable {
    /// An input is the output or sits inside it, so replacing the output
    /// would delete the input.
    case inputInsideOutput(input: String, output: String)
    /// The output sits inside an input that the run copies whole, so the
    /// output would be written into that input.
    case outputInsideInput(output: String, input: String)

    public var errorDescription: String? {
        switch self {
        case .inputInsideOutput(let input, let output) where input == output:
            return "Refusing to write \(output), which is also an input of this run."
        case .inputInsideOutput(let input, let output):
            return "Refusing to replace \(output), because the input \(input) sits inside it and would be deleted."
        case .outputInsideInput(let output, let input):
            return "Refusing to write \(output) inside the input \(input), which this run copies."
        }
    }
}

/// The checks a command that writes a new output runs before it replaces an
/// existing one (`bundle extract-annotations`, `bam annotate-best` and
/// `bam annotate-cds-best` with `--replace`). Paths are compared on their
/// physical form (``CanonicalFilePath``), so `/tmp/x` and `/private/tmp/x`
/// name one file.
public enum OutputReplacementCheck {

    /// Throws ``OutputReplacementRefusal/inputInsideOutput(input:output:)``
    /// when any of `inputs` is `output` or sits inside it.
    public static func refuseInputs(_ inputs: [URL], inside output: URL) throws {
        for input in inputs where CanonicalFilePath.isPath(input, within: output) {
            throw OutputReplacementRefusal.inputInsideOutput(
                input: input.standardizedFileURL.path,
                output: output.standardizedFileURL.path
            )
        }
    }

    /// Throws ``OutputReplacementRefusal/outputInsideInput(output:input:)``
    /// when `output` sits inside `input`, a folder the run copies whole.
    /// An output that is the input itself is left to the caller's own check.
    public static func refuseOutput(_ output: URL, inside input: URL) throws {
        guard let relative = CanonicalFilePath.relativePath(of: output, within: input), !relative.isEmpty else { return }
        throw OutputReplacementRefusal.outputInsideInput(
            output: output.standardizedFileURL.path,
            input: input.standardizedFileURL.path
        )
    }

    /// The `.lungfishref` bundle `NativeBundleBuilder` publishes for a build
    /// named `name` in `outputDirectory`. Spaces become underscores and
    /// slashes hyphens, as the builder writes it.
    public static func publishedReferenceBundleURL(outputDirectory: URL, name: String) -> URL {
        let bundleName = name
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "-")
        return outputDirectory.appendingPathComponent("\(bundleName).lungfishref", isDirectory: true)
    }
}

/// An earlier output moved aside under a hidden name in its own folder while
/// its replacement is built. The earlier output is deleted only once the new
/// one is in place, and it is moved back when the build fails.
public struct SetAsideOutput: Sendable {
    /// Where the earlier output waits.
    public let asideURL: URL
    /// Where the earlier output was, and where the new output is written.
    public let outputURL: URL

    /// Moves `output` aside, or returns nil when nothing is there.
    public static func setAside(_ output: URL) throws -> SetAsideOutput? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: output.path) else { return nil }
        let aside = output.deletingLastPathComponent()
            .appendingPathComponent(".\(output.lastPathComponent).replaced-\(UUID().uuidString)", isDirectory: true)
        try fileManager.moveItem(at: output, to: aside)
        return SetAsideOutput(asideURL: aside, outputURL: output)
    }

    /// Moves the earlier output back. A path the failed run left behind is
    /// removed first, since the earlier output is the one to keep.
    public func restore() throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        try fileManager.moveItem(at: asideURL, to: outputURL)
    }

    /// Deletes the earlier output once its replacement is in place.
    public func discard() {
        try? FileManager.default.removeItem(at: asideURL)
    }
}
