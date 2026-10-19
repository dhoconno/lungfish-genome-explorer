// AlignmentReadExtractionInvocation.swift - Every choice of one lungfish-cli extract reads run on alignment evidence
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// Every choice of one `lungfish-cli extract reads` run on alignment evidence, the viewer's Extract
/// Reads in Selected Region and Extract Selected Reads (Phase 2.10 lane A51, census row 22).
///
/// The row records ``arguments``, the leaf runs them and the record names ``replayArgv``, so the
/// three agree by construction. The run takes the evidence's explicit index, hashes the evidence
/// before it stages the reads, checks it again before it publishes, and publishes one
/// `.lungfishfastq` bundle with its record. Selected reads reach the run as a file of read names,
/// which the app writes beside the bundle before the row begins (``readNamesFileURL(forBundle:)``),
/// so the record and the copied command name a file that stays.
package struct AlignmentReadExtractionInvocation: Sendable, Equatable {
    /// Reads named in a file, one a line, taken from the alignment or from its run's original FASTQs.
    package struct ReadNames: Sendable, Equatable {
        package let file: URL
        /// The original FASTQs the reads are taken from, or none to take them from the alignment.
        package let sourceFASTQs: [URL]
        /// Whether both mates of a named pair are kept, for original FASTQs.
        package let keepReadPairs: Bool
        /// Whether secondary and supplementary records are kept, for the alignment.
        package let includeSecondary: Bool
        /// Whether duplicate records are left out, for the alignment.
        package let excludeDuplicates: Bool
        /// How many of the alignment records the user selected held no sequence, kept in the record.
        package let recordsWithoutSequence: Int

        package init(
            file: URL,
            sourceFASTQs: [URL] = [],
            keepReadPairs: Bool = true,
            includeSecondary: Bool = false,
            excludeDuplicates: Bool = false,
            recordsWithoutSequence: Int = 0
        ) {
            self.file = file.standardizedFileURL
            self.sourceFASTQs = sourceFASTQs.map(\.standardizedFileURL)
            self.keepReadPairs = keepReadPairs
            self.includeSecondary = includeSecondary
            self.excludeDuplicates = excludeDuplicates
            self.recordsWithoutSequence = recordsWithoutSequence
        }
    }

    /// Which reads the run takes.
    package enum Selection: Sendable, Equatable {
        /// The reads in regions as samtools takes them, `contig:start-end`, 1-based and inclusive,
        /// that pass the evidence's filters.
        case regions([String], minimumMapQ: Int?, excludedFlags: Int?, readGroups: [String])
        case readNames(ReadNames)
    }

    package let alignmentURL: URL
    package let indexURL: URL
    package let decodingReferenceURL: URL?
    package let selection: Selection
    /// The name of the reads file in the bundle, without its extension.
    package let readsName: String
    /// The `.lungfishfastq` bundle the run publishes.
    package let outputURL: URL

    package init(
        alignmentURL: URL,
        indexURL: URL,
        decodingReferenceURL: URL?,
        selection: Selection,
        readsName: String,
        outputURL: URL
    ) {
        self.alignmentURL = alignmentURL.standardizedFileURL
        self.indexURL = indexURL.standardizedFileURL
        self.decodingReferenceURL = decodingReferenceURL?.standardizedFileURL
        if case .regions(let regions, let minimumMapQ, let excludedFlags, let readGroups) = selection {
            self.selection = .regions(regions, minimumMapQ: minimumMapQ, excludedFlags: excludedFlags, readGroups: readGroups.sorted())
        } else {
            self.selection = selection
        }
        self.readsName = readsName
        self.outputURL = outputURL.standardizedFileURL
    }

    package static let workflowName = "lungfish alignment read extraction"
    /// The exit status a cancelled `lungfish-cli` command reports, `CLIExitCode.cancelled`.
    package static let cancelledExitStatus = 125

    /// The words the record keeps for selected records without sequence, as the viewer gave them.
    package var missingSequenceMessage: String? {
        guard case .readNames(let names) = selection, names.recordsWithoutSequence > 0 else { return nil }
        return "\(names.recordsWithoutSequence) selected alignment record(s) did not contain sequence."
    }

    /// The argv after the binary, `extract reads` with every choice of the run.
    package var arguments: [String] {
        var argv = ["extract", "reads"]
        switch selection {
        case .regions(let regions, let minimumMapQ, let excludedFlags, let readGroups):
            argv += ["--by-region", "--bam", alignmentURL.path, "--index", indexURL.path]
            if let decodingReferenceURL { argv += ["--decoding-reference", decodingReferenceURL.path] }
            for region in regions { argv += ["--region", region] }
            if let minimumMapQ { argv += ["--min-mapq", "\(minimumMapQ)"] }
            if let excludedFlags { argv += ["--exclude-flags", "\(excludedFlags)"] }
            for readGroup in readGroups { argv += ["--read-group", readGroup] }
        case .readNames(let names):
            argv += ["--by-id", "--ids", names.file.path]
            for source in names.sourceFASTQs { argv += ["--source", source.path] }
            argv += ["--bam", alignmentURL.path, "--index", indexURL.path]
            if let decodingReferenceURL { argv += ["--decoding-reference", decodingReferenceURL.path] }
            if names.sourceFASTQs.isEmpty {
                if names.includeSecondary { argv.append("--include-secondary") }
                if names.excludeDuplicates { argv.append("--exclude-duplicates") }
            } else {
                argv.append(names.keepReadPairs ? "--keep-read-pairs" : "--no-keep-read-pairs")
            }
            if names.recordsWithoutSequence > 0 {
                argv += ["--records-without-sequence", "\(names.recordsWithoutSequence)"]
            }
        }
        return argv + ["--bundle-name", readsName, "--output", outputURL.path]
    }

    /// The command the record names and a replay runs.
    package var replayArgv: [String] { [CLICommandIdentity.executableName] + arguments }

    /// The choices the record names as explicit options, the evidence's filters among them (BIO g22).
    package var explicitOptions: [String: ParameterValue] {
        var options: [String: ParameterValue] = [
            "alignment": .file(alignmentURL),
            "index": .file(indexURL),
            "decodingReference": decodingReferenceURL.map(ParameterValue.file) ?? .null,
            "readsName": .string(readsName),
            "output": .file(outputURL),
        ]
        switch selection {
        case .regions(let regions, let minimumMapQ, let excludedFlags, let readGroups):
            options["regionsOneBasedInclusive"] = .array(regions.map(ParameterValue.string))
            options["minimumMapQ"] = minimumMapQ.map(ParameterValue.integer) ?? .null
            options["excludedFlags"] = excludedFlags.map(ParameterValue.integer) ?? .null
            options["readGroups"] = .array(readGroups.map(ParameterValue.string))
        case .readNames(let names):
            options["readNames"] = .file(names.file)
            options["sourceFASTQs"] = .array(names.sourceFASTQs.map(ParameterValue.file))
            if names.sourceFASTQs.isEmpty {
                options["includeSecondary"] = .boolean(names.includeSecondary)
                options["excludeDuplicates"] = .boolean(names.excludeDuplicates)
            } else {
                options["keepReadPairs"] = .boolean(names.keepReadPairs)
            }
            options["recordsWithoutSequence"] = .integer(names.recordsWithoutSequence)
        }
        return options
    }

    /// The files the run reads: the evidence, and the read names with their FASTQs.
    package var inputURLs: [URL] {
        var urls = [alignmentURL, indexURL] + (decodingReferenceURL.map { [$0] } ?? [])
        if case .readNames(let names) = selection {
            urls += [names.file] + names.sourceFASTQs
        }
        return urls
    }

    /// The record's facts, which the publisher writes into the bundle.
    package var provenance: AlignmentReadExtractionProvenance {
        AlignmentReadExtractionProvenance(
            workflowName: Self.workflowName,
            workflowVersion: LungfishAppVersion.short,
            toolName: CLICommandIdentity.executableName,
            toolVersion: LungfishAppVersion.short,
            toolKind: "cli",
            argv: replayArgv,
            durableReplayArgv: replayArgv,
            explicitOptions: explicitOptions,
            inputURLs: inputURLs,
            runtimeIdentity: .init(appVersion: LungfishAppVersion.short)
        )
    }

    /// `<bundle without its extension>.read-names.txt`, beside the bundle, where the app writes the
    /// selected read names before the row begins. It is no scratch file, so the copied command
    /// replays, and it sits where the user or the project put the bundle.
    package static func readNamesFileURL(forBundle bundleURL: URL) -> URL {
        let bundle = bundleURL.standardizedFileURL
        return bundle.deletingLastPathComponent()
            .appendingPathComponent("\(bundle.deletingPathExtension().lastPathComponent).read-names.txt")
    }

    /// Writes `names`, sorted and each once, one a line, as the file `url` names, through
    /// `DurableReplace`, so the file is whole or absent.
    package static func writeReadNames(_ names: [String], to url: URL) throws {
        let text = Set(names).sorted().joined(separator: "\n") + "\n"
        try DurableReplace.replace(
            Data(text.utf8),
            named: url.lastPathComponent,
            in: url.deletingLastPathComponent()
        )
    }

    /// Writes the record of a run that a cancel stopped before it published, beside the bundle,
    /// and returns where.
    @discardableResult
    package static func recordCancelledRun(_ invocation: AlignmentReadExtractionInvocation, startedAt: Date) throws -> URL {
        let recordURL = ProvenanceRecorder.fileSidecarURL(for: invocation.outputURL)
        let argv = invocation.replayArgv
        let envelope = try ProvenanceRunBuilder(
            workflowName: workflowName,
            workflowVersion: LungfishAppVersion.short,
            toolName: CLICommandIdentity.executableName,
            toolVersion: LungfishAppVersion.short
        )
        .argv(argv)
        .durableReplayArgv(argv)
        .options(explicit: invocation.explicitOptions, defaults: [:], resolved: [:])
        .runtime(ProvenanceRuntimeIdentity(appVersion: LungfishAppVersion.short))
        .complete(
            exitStatus: cancelledExitStatus,
            status: .cancelled,
            stderr: "Cancelled before the reads were published. No bundle was written.",
            startedAt: startedAt,
            endedAt: Date()
        )
        try ProvenanceWriter().write(envelope, toSidecar: recordURL)
        return recordURL
    }

    /// Whether `url` holds the record of a cancelled run, which the next published run removes.
    package static func isCancelledRecord(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return (try? ProvenanceEnvelopeReader.load(fromSidecar: url))??.status == .cancelled
    }
}
