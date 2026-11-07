// FastqDemultiplexSubcommand+OutputFolder.swift - The output-folder refusals of `fastq demultiplex`
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension FastqDemultiplexSubcommand {
    /// Refuses to write into a directory that already holds files unless
    /// `replace` is set, in which case the directory is deleted first. A
    /// rerun used to overwrite the earlier barcode bundles in place.
    static func prepareOutputDirectory(_ outputURL: URL, replace: Bool) throws {
        if try checkOutputDirectory(outputURL, replace: replace) {
            try FileManager.default.removeItem(at: outputURL)
        }
    }

    /// The refusals of ``prepareOutputDirectory(_:replace:)`` without the
    /// delete. Returns whether the directory holds earlier results that
    /// `replace` deletes, so `run` deletes them only after the input and
    /// every argument have passed and a refused run keeps them (R3, final
    /// review B2).
    static func checkOutputDirectory(_ outputURL: URL, replace: Bool) throws -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: outputURL.path, isDirectory: &isDirectory) else { return false }
        guard isDirectory.boolValue else {
            throw ValidationError("Output path \(outputURL.path) is a file, not a directory")
        }
        let contents = (try? fm.contentsOfDirectory(atPath: outputURL.path))?.filter { !$0.hasPrefix(".") } ?? []
        guard !contents.isEmpty else { return false }
        guard replace else {
            let preview = contents.sorted().prefix(5).joined(separator: ", ")
            let more = contents.count > 5 ? ", ..." : ""
            throw ValidationError(
                "Output directory \(outputURL.path) already holds \(contents.count) item(s) (\(preview)\(more)). "
                + "Choose a new --output to keep them, or pass --replace to delete them first."
            )
        }
        return true
    }

    /// Refuses a `--replace` run that would delete a file it reads, such as the
    /// input, its bundle, the bundles its reads come from, or a custom kit
    /// inside the output folder. The folder used to be deleted with them.
    static func refuseReadFiles(inside outputURL: URL, _ readFiles: [URL]) throws {
        for file in readFiles where CanonicalFilePath.isPath(file, within: outputURL) {
            throw CLIError.outputWriteFailed(
                path: outputURL.path,
                reason: "--replace would delete \(file.path), which this run reads. Choose an --output folder that does not hold it."
            )
        }
    }
}
