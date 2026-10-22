// DatabaseBuildSpec.swift - How LGE built a database file it hosts, kept in the lock as data
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// How LGE built a database file that it hosts and the lock pins by SHA-256 and size.
///
/// `deacon-ribokmers` is built once with the pinned deacon from BBMap's `ribokmers.fa.gz` and hosted on the LGE
/// large-files folder, and every install downloads those bytes (CHTC lane C2-RIBOPIN, owner answers Q10 and
/// option B). A deacon build with more than one thread writes the same minimizers in a different order on each
/// run, so a build on the user's Mac with the registry's old `-t 0` argv could never match a pinned digest. The
/// pinned file is a one-thread build, which writes the same bytes on every run, so the lock's `argv` rebuilds the
/// pinned file from its source (`byteReproducible`). An entry with a build pins what an install downloads, and an
/// index that an earlier install built on its own host is reported as differing from the pin, never refused at
/// run time. The version label names the content (source, k, w), the hosted folder and `releaseDate` name the build,
/// the `sha256` names the file, and the minimizer set names what the file holds: a file with the same source and the
/// same set digest is a rebuild of the pinned build, whatever order its minimizers are in, and it filters the same
/// reads.
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
    /// True when the same tool, source and `argv` write the same bytes on every run, so anyone can rebuild the
    /// pinned file. The lock sets it only for a build that two runs gave with equal digests.
    public let byteReproducible: Bool?
    /// How many distinct minimizers the built index holds.
    public let minimizerCount: Int?
    /// SHA-256 of the built index's minimizer set, lowercase hex, computed as `minimizerSetMethod` says.
    public let minimizerSetSha256: String?
    /// How `minimizerSetSha256` is computed, so anyone can recompute it from an index.
    public let minimizerSetMethod: String?
    /// What a reader needs to know about the build that its fields do not say.
    public let note: String?

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
        if let byteReproducible {
            parameters["buildByteReproducible"] = .boolean(byteReproducible)
        }
        if let minimizerCount {
            parameters["buildMinimizerCount"] = .integer(minimizerCount)
        }
        if let minimizerSetSha256 {
            parameters["buildMinimizerSetSHA256"] = .string(minimizerSetSha256)
        }
        if let minimizerSetMethod {
            parameters["buildMinimizerSetMethod"] = .string(minimizerSetMethod)
        }
        if let note {
            parameters["buildNote"] = .string(note)
        }
        return parameters
    }
}
