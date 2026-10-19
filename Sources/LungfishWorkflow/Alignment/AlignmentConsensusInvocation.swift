// AlignmentConsensusInvocation.swift - Every choice of one lungfish-cli bam consensus run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import LungfishCore
import LungfishIO

/// Every choice of one `lungfish-cli bam consensus` run, the viewer's Generate Consensus (Phase 2.10
/// lane A51, census row 27).
///
/// The row records ``AlignmentConsensusPublicationService/replayArgv(_:)`` of it, the leaf runs that
/// argv and the record names it, so the three agree by construction. The region is zero-based and
/// half-open, as the alignment provider takes it, and the argv gives it 1-based and inclusive, as
/// samtools and `extract reads --region` take it.
package struct AlignmentConsensusInvocation: Sendable, Equatable {
    package let alignmentURL: URL
    package let indexURL: URL
    package let decodingReferenceURL: URL?
    package let region: ResolvedAlignmentRegion
    package let consensusRequest: AlignmentConsensusRequest
    package let recordName: String
    /// The analysis result the alignment belongs to, which a bundle's manifest names as its source assembly.
    package let resultID: String
    /// `--output` as the run is given it, a path, or for a clipboard or share destination a file name
    /// relative to the folder the leaf runs in.
    package let output: String
    /// Whether the user accepted a consensus whose every position is below the minimum depth.
    package let allowAllLowDepth: Bool

    package init(
        alignmentURL: URL,
        indexURL: URL,
        decodingReferenceURL: URL?,
        region: ResolvedAlignmentRegion,
        consensusRequest: AlignmentConsensusRequest,
        recordName: String,
        resultID: String,
        output: String,
        allowAllLowDepth: Bool = false
    ) {
        self.alignmentURL = alignmentURL.standardizedFileURL
        self.indexURL = indexURL.standardizedFileURL
        self.decodingReferenceURL = decodingReferenceURL?.standardizedFileURL
        self.region = region
        self.consensusRequest = consensusRequest
        self.recordName = recordName
        self.resultID = resultID
        self.output = output
        self.allowAllLowDepth = allowAllLowDepth
    }

    /// The run of the viewer's evidence `context` that writes `output`.
    package init(
        context: AlignmentActionContext,
        region: ResolvedAlignmentRegion,
        consensusRequest: AlignmentConsensusRequest,
        recordName: String,
        output: String,
        allowAllLowDepth: Bool = false
    ) {
        self.init(
            alignmentURL: context.alignmentURL,
            indexURL: context.indexURL,
            decodingReferenceURL: context.decodingReferenceURL,
            region: region,
            consensusRequest: consensusRequest,
            recordName: recordName,
            resultID: context.identity.resultID,
            output: output,
            allowAllLowDepth: allowAllLowDepth
        )
    }

    /// The same run with the user's acceptance of an all-N consensus.
    package func allowingAllLowDepth() -> Self {
        Self(
            alignmentURL: alignmentURL, indexURL: indexURL, decodingReferenceURL: decodingReferenceURL,
            region: region, consensusRequest: consensusRequest, recordName: recordName,
            resultID: resultID, output: output, allowAllLowDepth: true
        )
    }
}

extension AlignmentConsensusPublicationDestination {
    /// Whether the destination is a reference bundle, whose record lives inside it.
    package var isBundle: Bool {
        if case .referenceBundle = self { return true }
        return false
    }
}

extension AlignmentConsensusPublicationService {
    /// The workflow every consensus record names, the command that reproduces it.
    package static let workflowName = "lungfish bam consensus"
    /// The version every part of the record names, `LungfishAppVersion.short`, as the leaves record
    /// it, so a host such as xctest lends the record no version of its own.
    package static let version = LungfishAppVersion.short
    /// The exit status a cancelled `lungfish-cli` command reports, `CLIExitCode.cancelled`.
    package static let cancelledExitStatus = 125
    /// The failed message of a run whose every position is below the minimum depth and that was
    /// not given `--allow-all-low-depth`. The app matches it to show its all-N sheet.
    package static let allLowDepthRefusal = "Every position in the region is below the minimum depth, so the consensus holds only N. Pass --allow-all-low-depth to write it."

    /// `lungfish-cli bam consensus` with every choice of `invocation`, the one builder of the row's
    /// command and the record's argv.
    package static func replayArgv(_ invocation: AlignmentConsensusInvocation) -> [String] {
        let request = invocation.consensusRequest
        let filters = request.filters
        let region = invocation.region
        var argv = [
            CLICommandIdentity.executableName, "bam", "consensus",
            "--alignment", invocation.alignmentURL.path,
            "--index", invocation.indexURL.path,
        ]
        if let referenceURL = invocation.decodingReferenceURL {
            argv += ["--decoding-reference", referenceURL.path]
        }
        argv += [
            "--scope", region.scope.rawValue,
            "--region", "\(region.contig):\(region.start + 1)-\(region.end)",
            "--min-depth", "\(filters.minimumDepth)",
            "--min-mapq", "\(filters.minimumMapQ)",
            "--min-baseq", "\(filters.minimumBaseQuality)",
            "--exclude-flags", "\(filters.excludedFlags)",
        ]
        for readGroup in filters.readGroups.sorted() {
            argv += ["--read-group", readGroup]
        }
        argv += [
            "--caller-mode", request.mode.rawValue,
            "--use-ambiguity", "\(request.useAmbiguity)",
            "--insertion-policy", request.insertionPolicy.rawValue,
            "--deletion-policy", request.deletionPolicy.rawValue,
            "--reference-fill", "never",
            "--name", invocation.recordName,
            "--result-id", invocation.resultID,
            "--output", invocation.output,
        ]
        if invocation.allowAllLowDepth {
            argv.append("--allow-all-low-depth")
        }
        return argv
    }

    /// The choices the record names as explicit options, the thresholds among them (BIO).
    static func explicitOptions(_ invocation: AlignmentConsensusInvocation) -> [String: ParameterValue] {
        let request = invocation.consensusRequest
        let filters = request.filters
        let region = invocation.region
        return [
            "scope": .string(region.scope.rawValue),
            "zeroBasedHalfOpen": .string("\(region.contig):\(region.start)-\(region.end)"),
            "oneBasedInclusive": .string("\(region.contig):\(region.start + 1)-\(region.end)"),
            "minimumDepth": .integer(filters.minimumDepth),
            "minimumMapQ": .integer(filters.minimumMapQ),
            "minimumBaseQuality": .integer(filters.minimumBaseQuality),
            "excludedFlags": .integer(Int(filters.excludedFlags)),
            "readGroups": .array(filters.readGroups.sorted().map(ParameterValue.string)),
            "callerMode": .string(request.mode.rawValue),
            "useAmbiguity": .boolean(request.useAmbiguity),
            "insertionPolicy": .string(request.insertionPolicy.rawValue),
            "deletionPolicy": .string(request.deletionPolicy.rawValue),
            "allowAllLowDepth": .boolean(invocation.allowAllLowDepth),
        ]
    }

    /// Writes the record of a run that a cancel stopped before it wrote anything, beside `outputURL`
    /// where a FASTA's record goes, and returns where. ``publish(_:)`` replaces it on the next run.
    @discardableResult
    package static func recordCancelledRun(
        _ invocation: AlignmentConsensusInvocation,
        outputURL: URL,
        startedAt: Date
    ) throws -> URL {
        let recordURL = ProvenanceRecorder.fileSidecarURL(for: outputURL.standardizedFileURL)
        let argv = replayArgv(invocation)
        let envelope = try ProvenanceRunBuilder(
            workflowName: workflowName,
            workflowVersion: version,
            toolName: CLICommandIdentity.executableName,
            toolVersion: version
        )
        .argv(argv)
        .durableReplayArgv(argv)
        .options(explicit: explicitOptions(invocation), defaults: [:], resolved: [:])
        .runtime(ProvenanceRuntimeIdentity(appVersion: version))
        .complete(
            exitStatus: cancelledExitStatus,
            status: .cancelled,
            stderr: "Cancelled before the consensus was written. No file was written.",
            startedAt: startedAt,
            endedAt: Date()
        )
        try ProvenanceWriter().write(envelope, toSidecar: recordURL)
        return recordURL
    }

    /// Whether `url` holds the record of a cancelled run, which a later run may replace.
    package static func isCancelledRecord(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return (try? ProvenanceEnvelopeReader.load(fromSidecar: url))??.status == .cancelled
    }

    /// Renames `source` to `destination` without replacing anything there, through `PortableRename`
    /// with `RENAME_EXCL`, which takes its reservation fallback on a volume without the flag, such
    /// as ExFAT (the contract's Writes row, SWIFT 4).
    static func renameExclusively(_ source: URL, _ destination: URL) throws {
        let sourceParent = Darwin.open(source.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard sourceParent >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(sourceParent) }
        let destinationParent = Darwin.open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard destinationParent >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(destinationParent) }
        let status = source.lastPathComponent.withCString { sourceName in
            destination.lastPathComponent.withCString { destinationName in
                PortableRename.renameatxNP(sourceParent, sourceName, destinationParent, destinationName, UInt32(RENAME_EXCL))
            }
        }
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
