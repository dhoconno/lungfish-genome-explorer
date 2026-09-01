// NFCoreLaunchStaging.swift - Stage nf-core inputs onto whitespace-free paths
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

/// Copies file-valued nf-core inputs onto whitespace-free paths before launch.
///
/// nf-core schemas validate path parameters with patterns anchored on `\S`
/// (`^\S+\.csv$`, `^\S+\.bed(\.gz)?$`, and so on), so any path containing a
/// space is rejected outright with "Validation of pipeline parameters failed".
/// Lungfish projects are named by the user and routinely contain spaces
/// ("My Genome Project.lungfish"), which puts every bundled input on such a
/// path. The engine is therefore handed copies under the run's local scratch,
/// while the request's own record keeping (results directory, expected
/// outputs, provenance) keeps pointing at the real project paths.
enum NFCoreLaunchStaging {
    enum StagingError: LocalizedError {
        case stagingRootContainsWhitespace(URL)

        var errorDescription: String? {
            switch self {
            case .stagingRootContainsWhitespace(let url):
                return "Cannot stage nf-core inputs under '\(url.path)': the staging directory itself contains whitespace."
            }
        }
    }

    /// Parameters whose values are paths the pipeline schema pattern-matches.
    /// Directory-valued parameters are excluded: they are passed to the
    /// pipeline as roots to glob, and copying a whole run directory is not
    /// something a launch step should do silently.
    static let stagedFileParameters: Set<String> = [
        "primer_bed",
        "primer_fasta",
        "fasta",
        "gff",
        "additional_annotation",
        "sequencing_summary",
    ]

    /// Returns a request whose engine-facing file paths contain no whitespace.
    ///
    /// When nothing needs staging the request is returned unchanged and no
    /// directory is created.
    static func stage(_ request: NFCoreRunRequest, in stagingRoot: URL) throws -> NFCoreRunRequest {
        let needsStaging = request.inputURLs.contains(where: containsWhitespace)
            || request.params.contains { key, value in
                stagedFileParameters.contains(key) && containsWhitespace(URL(fileURLWithPath: value))
            }
        guard needsStaging else { return request }

        guard !containsWhitespace(stagingRoot) else {
            throw StagingError.stagingRootContainsWhitespace(stagingRoot)
        }
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        var usedNames: Set<String> = []
        let inputURLs = try request.inputURLs.map { url -> URL in
            guard containsWhitespace(url) else { return url }
            return try copy(url, into: stagingRoot, usedNames: &usedNames)
        }
        var params = request.params
        for (key, value) in request.params where stagedFileParameters.contains(key) {
            let url = URL(fileURLWithPath: value)
            guard containsWhitespace(url) else { continue }
            params[key] = try copy(url, into: stagingRoot, usedNames: &usedNames).path
        }

        return NFCoreRunRequest(
            workflow: request.workflow,
            version: request.version,
            executor: request.executor,
            inputURLs: inputURLs,
            outputDirectory: request.outputDirectory,
            expectedOutputURLs: request.expectedOutputURLs,
            params: params,
            resume: request.resume,
            workDirectory: request.workDirectory,
            presentationMode: request.presentationMode
        )
    }

    private static func containsWhitespace(_ url: URL) -> Bool {
        url.standardizedFileURL.path.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
    }

    /// Copies `url` into `stagingRoot` under a whitespace-free, unique name.
    private static func copy(
        _ url: URL,
        into stagingRoot: URL,
        usedNames: inout Set<String>
    ) throws -> URL {
        var name = sanitized(url.lastPathComponent)
        if usedNames.contains(name) {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            var index = 2
            repeat {
                name = ext.isEmpty ? "\(base)_\(index)" : "\(base)_\(index).\(ext)"
                index += 1
            } while usedNames.contains(name)
        }
        usedNames.insert(name)

        let destination = stagingRoot.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination.standardizedFileURL
    }

    private static func sanitized(_ name: String) -> String {
        let replaced = name.unicodeScalars.map { scalar -> Character in
            CharacterSet.whitespacesAndNewlines.contains(scalar) ? "_" : Character(scalar)
        }
        return String(replaced)
    }
}
