// FastqDemultiplexSubcommand+Definition.swift - The copy of its custom barcode definition a demultiplexing run keeps
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.3 lane DEMUXPLAN (D1b, L8 with QA's round 2 line). The Demux tab's plan reaches the run as a custom
// definition in the project. So the run reads the definition once, keeps those bytes in its result folder, and the
// recorded command and the record name the copy with its digest, so a replay reads the definition the run read and
// not the project's file as it is now.

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO

/// The bytes of the custom barcode definition a demultiplexing run read.
struct DemultiplexDefinitionCopy {
    let sourceURL: URL
    let data: Data

    /// The copy's name in the result folder, the definition's own file name.
    var fileName: String { sourceURL.lastPathComponent }

    /// The copy of a run's definition, or nil for a built-in kit. A definition whose file name is one the run writes
    /// in its result folder refuses before the run starts, so the copy never takes an output's name.
    static func make(sourceURL: URL?, data: Data?) throws -> Self? {
        guard let sourceURL, let data else { return nil }
        let copy = Self(sourceURL: sourceURL, data: data)
        let name = copy.fileName
        if name.hasPrefix(".") || name == DemultiplexManifest.filename
            || name.hasSuffix(".\(FASTQBundle.directoryExtension)") || name.hasSuffix("provenance.json") {
            throw ValidationError(
                "The barcode definition \(sourceURL.path) is named \(name), a name the run writes in its result "
                    + "folder. Rename the definition and run again."
            )
        }
        return copy
    }

    /// Writes the bytes into `outputURL` under the definition's file name through the durable writer, and returns the
    /// copy. A name already in the folder refuses, so the copy never replaces an output.
    func keep(in outputURL: URL) throws -> URL {
        let copyURL = outputURL.appendingPathComponent(fileName)
        guard !FileManager.default.fileExists(atPath: copyURL.path) else {
            throw CLIError.outputWriteFailed(
                path: copyURL.path,
                reason: "the result folder already holds \(fileName), so the run kept no copy of its barcode "
                    + "definition. Rename the definition and run again."
            )
        }
        try DurableReplace.replace(data, named: fileName, in: outputURL)
        return copyURL
    }
}
