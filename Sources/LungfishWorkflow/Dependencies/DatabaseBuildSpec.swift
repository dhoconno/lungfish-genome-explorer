// DatabaseBuildSpec.swift - How LGE built a database file it hosts, kept in the lock as data
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// How LGE built a database file that it hosts and the lock pins by SHA-256 and size.
///
/// `deacon-ribokmers` is built once with the pinned deacon from BBMap's `ribokmers.fa.gz` and hosted on the LGE
/// large-files folder, and every install downloads those bytes (CHTC lane C2-RIBOPIN, owner answer Q10). A deacon
/// build with more than one thread writes the same minimizers in a different order on each run, so a build on the
/// user's Mac could never match a pinned digest. An entry with a build pins what an install downloads, and an index
/// that an earlier install built on its own host is reported as differing from the pin, never refused at run time.
public struct DatabaseBuildSpec: Sendable, Codable, Hashable {
    /// The tool that built the file, such as `deacon`.
    public let tool: String
    /// The tool's version, such as `0.16.0`.
    public let toolVersion: String
    /// The public source the file was built from.
    public let sourceUrl: String
    /// SHA-256 of the source file, lowercase hex.
    public let sourceSha256: String
    /// Size of the source file in bytes.
    public let sourceSizeBytes: Int64?
    /// The build's argv, with the source and output named by their file names.
    public let argv: [String]

    /// The build as install-record parameters.
    var provenanceParameters: [String: ParameterValue] {
        var parameters: [String: ParameterValue] = [
            "buildTool": .string(tool),
            "buildToolVersion": .string(toolVersion),
            "buildSourceUrl": .string(sourceUrl),
            "buildSourceSHA256": .string(sourceSha256),
            "buildArgv": .array(argv.map { .string($0) }),
        ]
        if let sourceSizeBytes {
            parameters["buildSourceSizeBytes"] = .integer(Int(sourceSizeBytes))
        }
        return parameters
    }
}
