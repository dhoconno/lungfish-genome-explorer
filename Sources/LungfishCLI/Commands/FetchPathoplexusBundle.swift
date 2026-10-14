// FetchPathoplexusBundle.swift - The bundles and the record of lungfish-cli fetch pathoplexus
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension FetchPathoplexusRun {
    /// Moves a bundle built from a GenBank record into the output folder and rewrites its record to
    /// the final place. The record keeps the GenBank builder's steps and K7's `fetchedRecord` entry,
    /// names the Pathoplexus record with its version, and states the manifest's digest as it stands
    /// now, since Pathoplexus's metadata was added after the builder wrote it (B-5). A bundle that
    /// cannot get its record is removed.
    func publishGenBankBundle(_ built: URL, meta: PathoplexusMetadata?, accession: String) throws -> FetchGenomeOutput {
        try Task.checkCancellation()
        let bundle = try FetchGenomeRun.publish(built, into: request.outputURL)
        do {
            try FetchNCBIBundleRecord.rebase(
                bundle: bundle,
                from: built,
                adding: FetchPathoplexusRecord.pathoplexusRecord(
                    organism: request.organism, accession: accession, meta: meta, version: nil),
                refreshingDigestsOf: ["manifest.json"]
            )
        } catch {
            try? FileManager.default.removeItem(at: bundle)
            throw error
        }
        return .bundle(bundle, record: FetchGenomeRun.rootRecord(of: bundle))
    }

    /// Builds the bundle from the Pathoplexus FASTA, keeps the FASTA the server sent as
    /// `sources/record.fasta`, and writes the record the builder does not write. A bundle that cannot
    /// get its record is removed.
    func buildFromFASTA(
        _ accession: String,
        meta: PathoplexusMetadata?,
        notes: String,
        services: Services,
        staging: URL,
        runClock: ProvenanceRunClock,
        progress: @escaping Progress
    ) async throws -> FetchGenomeOutput {
        progress(0, "Building bundle from Pathoplexus sequence for \(accession)...")
        let fetched = try await services.pathoplexus.fetchKeepingSource(accession: accession, organism: request.organism)
        let fetchedAt = Date()
        let record = fetched.record
        let built = try await GenBankDownloadBundleBuilder(ncbiService: services.ncbi).buildBundleFromSequence(
            accession: record.accession,
            title: record.title,
            sequence: record.sequence,
            outputDirectory: staging,
            sourceDatabase: "Pathoplexus",
            sourceURL: URL(string: "https://pathoplexus.org/\(request.organism)/search?accession=\(record.accession)"),
            notes: notes,
            progressHandler: progress
        )
        try Task.checkCancellation()
        if let meta {
            appendPathoplexusMetadata(meta, organism: request.organism, toBundleAt: built)
        }
        try FetchPathoplexusRecord.keep(fasta: fetched.fasta, in: built)
        try Task.checkCancellation()
        let bundle = try FetchGenomeRun.publish(built, into: request.outputURL)
        do {
            try await FetchPathoplexusRecord.write(
                bundle: bundle,
                request: request,
                accession: accession,
                pathoplexusRecord: FetchPathoplexusRecord.pathoplexusRecord(
                    organism: request.organism, accession: accession, meta: meta, version: record.version),
                fetchedAt: fetchedAt,
                runClock: runClock
            )
        } catch {
            try? FileManager.default.removeItem(at: bundle)
            throw error
        }
        return .bundle(bundle, record: FetchGenomeRun.rootRecord(of: bundle))
    }
}

/// The record of a `fetch pathoplexus` bundle (Phase 2.10 lane A45 M2, BIO B-3 and B-5).
///
/// - Every bundle's record has a `pathoplexusRecord` entry that names the organism, the accession as
///   Pathoplexus resolved it, its version, the INSDC accession and the data use terms.
/// - A bundle built from a GenBank record keeps the GenBank builder's record, with its
///   `fetchedRecord` entry (`FetchNCBIBundleRecord`).
/// - A bundle built from the Pathoplexus FASTA gets the record here, since the builder writes none. The
///   FASTA is kept as `sources/record.fasta`, listed by the `fetchedRecord` entry with the date of the
///   fetch, and stated as the run's input under Pathoplexus's own address with the digest it arrived
///   with, whatever origin served the run.
enum FetchPathoplexusRecord {
    static let keptFASTAName = "sources/record.fasta"

    static func pathoplexusRecord(
        organism: String, accession: String, meta: PathoplexusMetadata?, version: String?
    ) -> [String: ParameterValue] {
        var entry: [String: ParameterValue] = [
            "organism": .string(organism),
            "accession": .string(meta?.accession ?? accession),
        ]
        if let version = meta?.accessionVersion ?? version { entry["accessionVersion"] = .string(version) }
        if let insdc = meta?.bestINSDCAccession, !insdc.isEmpty { entry["insdcAccession"] = .string(insdc) }
        if let terms = meta?.dataUseTerms { entry["dataUseTerms"] = .string(terms) }
        return ["pathoplexusRecord": .dictionary(entry)]
    }

    /// Writes the FASTA the server sent into `bundle` as ``keptFASTAName``.
    static func keep(fasta: String, in bundle: URL) throws {
        let kept = bundle.appendingPathComponent(keptFASTAName)
        try FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(fasta.utf8).write(to: kept, options: .atomic)
    }

    /// The address of the FASTA Pathoplexus serves for `accession`, which a record names whatever
    /// origin answered the run.
    static func fastaURL(organism: String, accession: String) -> URL {
        var components = URLComponents(
            url: PathoplexusServiceEndpoints.pathoplexus.baseURL.appendingPathComponent(
                "\(organism)/sample/unalignedNucleotideSequences"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "accession", value: accession)]
        return components.url!
    }

    /// Writes the record of a bundle built from the Pathoplexus FASTA, in its final place.
    static func write(
        bundle: URL,
        request: FetchPathoplexusRequest,
        accession: String,
        pathoplexusRecord: [String: ParameterValue],
        fetchedAt: Date,
        runClock: ProvenanceRunClock
    ) async throws {
        let kept = bundle.appendingPathComponent(keptFASTAName)
        let keptFile = ProvenanceRecorder.fileRecord(url: kept, format: .fasta, role: .reference)
        let input = FileRecord(
            path: fastaURL(organism: request.organism, accession: accession).absoluteString,
            sha256: keptFile.sha256,
            sizeBytes: keptFile.sizeBytes,
            format: .fasta,
            role: .reference
        )
        let parameters: [String: ParameterValue] = [
            "accession": .string(accession),
            "organism": .string(request.organism),
            "outputDirectory": .file(request.outputURL),
            "includeGFF3Annotations": .boolean(request.includeGFF3Annotations),
            "outputBundle": .file(bundle),
            "outputFormat": .string(request.outputFormat.rawValue),
            "quiet": .boolean(request.quiet),
        ]
        let defaults: [String: ParameterValue] = [
            "outputDirectory": .string("."),
            "includeGFF3Annotations": .boolean(true),
            "outputFormat": .string(OutputFormat.text.rawValue),
            "quiet": .boolean(false),
        ]
        let fetchedRecord = NextflowDatabaseEntry(
            role: "fetchedRecord", status: .liveSnapshot, fetchedAt: fetchedAt, listingFiles: [kept]
        ).resolvedDefaults
        let resolved = parameters
            .merging(fetchedRecord) { _, entry in entry }
            .merging(pathoplexusRecord) { _, entry in entry }
        _ = try await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish fetch pathoplexus",
            parameters: parameters,
            defaults: defaults,
            resolved: resolved,
            toolName: "lungfish fetch pathoplexus",
            toolVersion: WorkflowRun.currentAppVersion,
            command: request.command(for: accession),
            inputs: [input],
            outputs: CLIProvenanceSupport.bundlePayloadURLs(in: bundle).map {
                ProvenanceRecorder.fileRecord(url: $0, role: .output)
            },
            exitCode: 0,
            wallTime: runClock.elapsed,
            stderr: nil,
            status: .completed,
            outputDirectory: bundle
        )
    }
}
