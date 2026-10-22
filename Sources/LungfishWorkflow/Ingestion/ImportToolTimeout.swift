// ImportToolTimeout.swift - How long a whole-sample tool call on the FASTQ import path may run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The timeout of a tool call that reads a whole sample on the FASTQ import path.
///
/// A sample's reads can run to tens of gigabytes, so the wall time of a call
/// over them is not known when the call is written. The recipe engine sizes
/// every step's timeout from its input files with
/// ``StepContext/recipeToolTimeout(for:inputBytes:)``, which removes the limit
/// from an input of 1 GB or more. The legacy recipe path, the BAM
/// materialization before it and the statistics pass after it follow that same
/// rule. A call also keeps the limit it had before as a floor, so no input waits
/// less than it did.
enum ImportToolTimeout {
    /// The timeout, in seconds, of `tool` over `inputBytes` bytes of reads.
    ///
    /// - Parameters:
    ///   - tool: The tool the call launches.
    ///   - atLeast: The limit the call had before it was sized. A call with no
    ///     limit of its own had the runner's default of 300 seconds.
    ///   - inputBytes: The summed size of the files the tool reads.
    static func seconds(for tool: NativeTool, atLeast: TimeInterval, inputBytes: Int64) -> TimeInterval {
        max(atLeast, StepContext.recipeToolTimeout(for: tool, inputBytes: inputBytes))
    }

    /// The timeout, in seconds, of `tool` over the files at `inputs`.
    static func seconds(for tool: NativeTool, atLeast: TimeInterval, inputs: [URL]) -> TimeInterval {
        seconds(for: tool, atLeast: atLeast, inputBytes: totalBytes(of: inputs))
    }

    /// The summed size of the files at `urls`. A symbolic link is sized by the
    /// file it points at, because `attributesOfItem(atPath:)` does not follow a
    /// final link and would size it by the length of its target path. A file that
    /// cannot be read adds nothing.
    static func totalBytes(of urls: [URL]) -> Int64 {
        urls.reduce(Int64(0)) { total, url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path))?[.size] as? Int64
            return total + (size ?? 0)
        }
    }
}
