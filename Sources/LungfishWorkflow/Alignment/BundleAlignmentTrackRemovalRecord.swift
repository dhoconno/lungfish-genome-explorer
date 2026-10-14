// BundleAlignmentTrackRemovalRecord.swift - The record of a derived alignment track removal
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import LungfishCore

/// The record of one removal of a derived alignment track (Phase 2.10 lane A51, 2.7 E7, BIO 6).
///
/// It lives in the bundle at `provenance/removals/<track ID>.lungfish-provenance.json`, beside the
/// bundle's own records, so it stays when the track's files and their sidecars go and when a later
/// edit rewrites the bundle's root record. A completed record names the manifest the removal saved
/// as its output, and a removal step names each removed file once with the digest and size of the
/// bytes that went (`RecordedRemovalStep`). A cancelled record names the command and claims no
/// result, because a cancel stops the removal before the manifest changes. Both name the command
/// that reproduces the run, `lungfish-cli bam remove-track`, whichever route ran it.
public struct BundleAlignmentTrackRemovalRecord: Sendable {
    /// The workflow and tool a removal record names.
    public static let workflowName = "lungfish bam remove-track"
    /// The call that removes the files, which the removal step names.
    public static let removalAPI = "BundleAlignmentTrackRemovalService.removeDerivedAlignmentTrack"
    /// The folder of the bundle that holds removal records.
    public static let folder = "\(ProvenanceWriter.bundleProvenanceDirectoryName)/removals"
    /// The exit status a cancelled `lungfish-cli` command reports, `CLIExitCode.cancelled`.
    static let cancelledExitStatus = 125
    /// The version every part of the record names, `LungfishAppVersion.short`, as the `lungfish-cli`
    /// leaves record it. In the app and its bundled CLI it is the app's stamped version. A host such
    /// as xctest never lends its own, so every route that runs this service records one version.
    static let version = LungfishAppVersion.short

    let bundleURL: URL
    let track: AlignmentTrackInfo
    let clock: ProvenanceRunClock

    /// Where the record of a removal of `trackID` from `bundleURL` lives.
    public static func recordURL(bundleURL: URL, trackID: String) -> URL {
        let name = trackID.replacingOccurrences(of: "/", with: "_")
        return bundleURL
            .appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent("\(name)\(ProvenanceRecorder.provenanceFilename)")
    }

    var recordURL: URL { Self.recordURL(bundleURL: bundleURL, trackID: track.id) }

    /// `lungfish-cli bam remove-track --bundle <bundle> --track <id>`.
    static func cliArgv(bundleURL: URL, trackID: String) -> [String] {
        [
            CLICommandIdentity.executableName, "bam", "remove-track",
            "--bundle", bundleURL.standardizedFileURL.path,
            "--track", trackID,
        ]
    }

    /// Writes `envelope` to `url`, signed when a signing key is set, as `bam filter` writes its record.
    public static func write(_ envelope: ProvenanceEnvelope, to url: URL) throws {
        try ProvenanceWriter().write(envelope, toSidecar: url)
    }

    /// The descriptor of a file the removal will remove, with the digest and size of its bytes from
    /// one read. It checks for a cancel before each megabyte, so a cancel stops the hash of a large BAM.
    static func removedFileDescriptor(for url: URL) throws -> ProvenanceFileDescriptor {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: UInt64 = 0
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            size += UInt64(chunk.count)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return ProvenanceFileDescriptor(
            path: url.standardizedFileURL.path,
            checksumSHA256: digest,
            fileSize: size,
            format: format(of: url),
            role: .input
        )
    }

    private static func format(of url: URL) -> FileFormat {
        let name = url.lastPathComponent
        if name.hasSuffix(".bam") { return .bam }
        if name.hasSuffix(".db") { return .sqlite }
        if name.hasSuffix(".json") { return .json }
        return .unknown
    }

    /// The record of a removal that saved the manifest without the track and will remove `files`.
    func completed(removing files: [ProvenanceFileDescriptor]) throws -> ProvenanceEnvelope {
        let manifestURL = bundleURL.appendingPathComponent(BundleManifest.filename)
        let argv = Self.cliArgv(bundleURL: bundleURL, trackID: track.id)
        let manifestStep = ProvenanceStep(
            toolName: Self.workflowName,
            toolVersion: Self.version,
            argv: argv,
            inputs: [],
            outputs: [try ProvenanceFileDescriptor.file(url: manifestURL, format: .json, role: .output)],
            exitStatus: 0,
            wallTimeSeconds: clock.elapsed,
            startedAt: clock.startedAt,
            completedAt: clock.now
        )
        var builder = try builder(argv: argv)
            .output(manifestURL, format: .json, role: .output)
            .step(manifestStep)
        if let removal = removalStep(removing: files, after: manifestStep) {
            builder = builder.step(removal)
        }
        return try builder.complete(exitStatus: 0, status: .completed, startedAt: clock.startedAt, endedAt: clock.now)
    }

    /// The step that removes `files`, each path once and in order, after `manifestStep`, or nil when
    /// there are none. It has the shape `RecordedRemovalStep.step` gives, the API, the paths and its
    /// resolved options, and names this record's `version` where that helper names the host's.
    private func removalStep(removing files: [ProvenanceFileDescriptor], after manifestStep: ProvenanceStep) -> ProvenanceStep? {
        var seen: Set<String> = []
        let removed = files.filter { seen.insert($0.path).inserted }
        guard !removed.isEmpty else { return nil }
        var step = ProvenanceStep(
            toolName: Self.workflowName,
            toolVersion: Self.version,
            argv: [Self.removalAPI] + removed.map(\.path),
            resolvedOptions: RecordedRemovalStep.resolvedOptions,
            inputs: removed,
            outputs: [],
            exitStatus: 0,
            wallTimeSeconds: clock.elapsed,
            startedAt: clock.startedAt,
            completedAt: clock.now
        )
        step.dependsOn = [manifestStep.id]
        return step
    }

    /// The record of a removal a cancel stopped before the manifest changed.
    func cancelled() throws -> ProvenanceEnvelope {
        try builder(argv: Self.cliArgv(bundleURL: bundleURL, trackID: track.id)).complete(
            exitStatus: Self.cancelledExitStatus,
            status: .cancelled,
            stderr: "Cancelled before the manifest changed. No file was removed.",
            startedAt: clock.startedAt,
            endedAt: clock.now
        )
    }

    private func builder(argv: [String]) -> ProvenanceRunBuilder {
        ProvenanceRunBuilder(
            workflowName: Self.workflowName,
            workflowVersion: Self.version,
            toolName: Self.workflowName,
            toolVersion: Self.version
        )
        .argv(argv)
        .durableReplayArgv(argv)
        .options(
            explicit: [
                "bundle": .string(bundleURL.standardizedFileURL.path),
                "track": .string(track.id),
            ],
            defaults: [:],
            resolved: [
                "trackName": .string(track.name),
                "trackSourcePath": .string(track.sourcePath),
            ]
        )
        .runtime(ProvenanceRuntimeIdentity(appVersion: Self.version))
    }
}
