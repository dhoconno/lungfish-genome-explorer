// MetagenomicsImportError.swift - Errors thrown while importing classifier outputs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import SQLite3
import os.log

/// Errors thrown while importing classifier outputs.
public enum MetagenomicsImportError: Error, LocalizedError, Sendable {
    case inputNotFound(URL)
    case outputDirectoryCreationFailed(URL, String)
    case copyFailed(source: URL, destination: URL, reason: String)
    case parseFailed(URL, String)
    case toolUnavailable(String)
    case outputAlreadyExists(URL)
    case importAborted(resultDirectory: URL, underlying: Error)
    /// A TaxTriage folder that holds no report, metrics or Krona file, which is usually the wrong folder.
    case noTaxTriageReports(URL)
    /// Writing the BAM of one NAO-MGS sample failed, so the import stopped. `reason` is the writer's last word.
    case naoMgsBAMNotWritten(sample: String, reason: String?)
    /// A NAO-MGS sample has hits and there was no samtools to write its BAM.
    case naoMgsSamtoolsMissing(sample: String)

    public var errorDescription: String? {
        switch self {
        case .inputNotFound(let url):
            return "Input path not found: \(url.path)"
        case .outputDirectoryCreationFailed(let url, let reason):
            return "Could not create output directory at \(url.path): \(reason)"
        case .copyFailed(let source, let destination, let reason):
            return "Failed to copy \(source.lastPathComponent) to \(destination.path): \(reason)"
        case .parseFailed(let url, let reason):
            return "Failed to parse \(url.lastPathComponent): \(reason)"
        case .toolUnavailable(let tool):
            return "Required tool is unavailable: \(tool)"
        case .outputAlreadyExists(let url):
            return "Output already exists: \(url.path)"
        case .importAborted(_, let underlying):
            return "Import aborted: \(underlying.localizedDescription)"
        case .noTaxTriageReports(let url):
            return "No TaxTriage reports were found in \(url.path). Nothing was imported. Choose the run's output folder."
        case .naoMgsBAMNotWritten(let sample, _):
            return "Lungfish could not write the alignment file for sample \(sample), so the import stopped and kept no result. Try the import again. If it stops again, check that the results file is complete."
        case .naoMgsSamtoolsMissing(let sample):
            return "Lungfish could not write the alignment file for sample \(sample), since samtools could not be found, so the import stopped and kept no result. samtools is part of Lungfish's Required Setup: in the app, open the Welcome window and click Install, or run `\(CLICommandIdentity.executableName) tools update --apply --yes --required-only`, then import the file again."
        }
    }

    /// What the BAM writer last said when it could not write a sample's BAM. It is for the log and not for the words.
    public var failureReason: String? {
        if case .naoMgsBAMNotWritten(_, let reason) = self { return reason }
        return nil
    }
}
