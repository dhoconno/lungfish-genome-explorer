// FetchNCBIBundleRecord.swift - The provenance record of a bundle that lungfish-cli fetch ncbi --bundle built
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishWorkflow

/// The record of one `fetch ncbi --bundle` bundle (Phase 2.10 lane A45, BIO B-3 and B-5).
///
/// `GenBankDownloadBundleBuilder` writes the record while it builds, and names every file of the
/// bundle at the place it built it. The CLI builds in a staging folder and moves the bundle into
/// the output folder, so the record is rewritten once the bundle is in its final place: the same
/// run, the same steps and digests, with the staging path replaced by the final one and the layout
/// the writer gives a bundle. The record names the accession as requested and as NCBI resolved it,
/// with its version, each fetched file under its source URL with the digest it arrived with, and
/// the time of the fetch. The run's argument vector is the CLI's own, so the record replays the
/// command that made it.
enum FetchNCBIBundleRecord {
    /// Rewrites the record of `bundle`, which was built at `staged` and now sits at `bundle`. It
    /// does nothing when the bundle holds no record.
    ///
    /// - Parameters:
    ///   - resolved: Entries added to the record's resolved defaults, such as the Pathoplexus
    ///     record a `fetch pathoplexus` bundle was built for.
    ///   - names: Files of the bundle, by their name inside it, that changed after the builder
    ///     wrote its record, such as the manifest once Pathoplexus's metadata is appended. The
    ///     record states their digest and size as they stand now (B-5).
    static func rebase(
        bundle: URL,
        from staged: URL,
        adding resolved: [String: ParameterValue] = [:],
        refreshingDigestsOf names: [String] = []
    ) throws {
        guard let envelope = ProvenanceRecorder.loadEnvelope(from: bundle) else { return }
        // The builder keeps the spelling of the path it was given, and a reader may resolve it, so
        // `relocated` replaces every spelling of the staged path (ruling A45-M3 section 3).
        var rebased = envelope.relocated(from: staged, to: bundle)
        if !resolved.isEmpty {
            rebased.options = ProvenanceOptions(
                explicit: rebased.options.explicit,
                defaults: rebased.options.defaults,
                resolvedDefaults: rebased.options.resolvedDefaults.merging(resolved) { _, added in added })
        }
        if !names.isEmpty {
            try refreshDigests(of: Set(names.map { bundle.appendingPathComponent($0).path }), in: &rebased)
        }
        try FetchGenomeRun.removeBuilderRecord(of: bundle)
        try ProvenanceWriter(signingProvider: nil).write(rebased, to: bundle)
    }

    /// States the digest and size of each file of `paths` as the file stands, wherever the record
    /// lists it. `fetch sra download --bundle` uses it for the metadata sidecar (lane A45 M3c).
    static func refreshDigests(of paths: Set<String>, in envelope: inout ProvenanceEnvelope) throws {
        func refreshed(_ descriptor: ProvenanceFileDescriptor) throws -> ProvenanceFileDescriptor {
            guard paths.contains(descriptor.path) else { return descriptor }
            let current = try ProvenanceFileDescriptor.file(url: URL(fileURLWithPath: descriptor.path), role: descriptor.role)
            return ProvenanceFileDescriptor(
                path: descriptor.path,
                checksumSHA256: current.checksumSHA256,
                fileSize: current.fileSize,
                format: descriptor.format,
                role: descriptor.role,
                originPath: descriptor.originPath,
                sourceProvenancePath: descriptor.sourceProvenancePath)
        }
        envelope.files = try envelope.files.map(refreshed)
        envelope.outputs = try envelope.outputs.map(refreshed)
        envelope.output = try envelope.output.map(refreshed)
        for index in envelope.steps.indices {
            envelope.steps[index].inputs = try envelope.steps[index].inputs.map(refreshed)
            envelope.steps[index].outputs = try envelope.steps[index].outputs.map(refreshed)
        }
    }
}
