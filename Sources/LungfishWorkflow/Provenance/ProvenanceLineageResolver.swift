// ProvenanceLineageResolver.swift - Walks a record upstream through the records of its inputs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A variant track's record names the BAM it read; the BAM's record names
// the reads it mapped; the reads' record names the files that were
// imported. Each of those inputs has a sidecar of its own somewhere in the
// project. This resolver follows the links so an export and the Inspector
// both start at the reads: by path first (the reader has already re-rooted
// a path recorded under another project root), then by SHA-256 against an
// index of every sidecar in the enclosing project when the recorded path
// resolves nothing. Cycles, duplicate records (the three copies of a
// mapping record) and unreadable sidecars are all survived: what is known
// is shown and nothing crashes. Every walk of a project shares one index
// (`ProvenanceSidecarIndex`), and a caller that cancels stops the walk at
// its next record, index entry or sidecar read.

import Foundation
import LungfishCore
import LungfishIO

public struct ProvenanceLineageResolver: Sendable {
    public struct ResolvedRun: Sendable {
        /// The sidecar the record was read from; nil for a record synthesized
        /// from a reference bundle's manifest.
        public let sidecarURL: URL?
        public let envelope: ProvenanceEnvelope
        /// Manifests and other files that document the record beside its sidecar.
        public let supportingURLs: [URL]
    }

    /// What a walk did, reported as it happens.
    public enum Event: Sendable, Equatable {
        /// The project index read this sidecar for the checksums of what it produced.
        case indexedSidecar(URL)
        /// The walk ended, early when its caller cancelled it.
        case walkEnded(cancelled: Bool)
    }

    /// The index of project sidecars a walk falls back to. Every walk shares one by default.
    public let sidecarIndex: ProvenanceSidecarIndex
    /// The most records one chain is allowed to gather.
    private let maximumRuns: Int
    /// The most files the project index reads before giving up on checksums.
    private let maximumIndexedFiles: Int
    private let observer: (@Sendable (Event) -> Void)?

    public init(
        maximumRuns: Int = 64,
        maximumIndexedFiles: Int = 4_000,
        sidecarIndex: ProvenanceSidecarIndex = .shared,
        observer: (@Sendable (Event) -> Void)? = nil
    ) {
        self.maximumRuns = maximumRuns
        self.maximumIndexedFiles = maximumIndexedFiles
        self.sidecarIndex = sidecarIndex
        self.observer = observer
    }

    /// The records that fed `envelope`, upstream first, ending with
    /// `envelope` itself. `sourceRootURL` is the file or folder the caller
    /// selected, whose mapping record may name a source reference bundle.
    /// The walk checks `isCancelled` before each record it visits, each file
    /// the project index enumerates and each sidecar it reads. A cancelled
    /// walk returns what it gathered by then.
    public func resolve(
        envelope: ProvenanceEnvelope,
        sidecarURL: URL?,
        sourceRootURL: URL? = nil,
        isCancelled: @escaping () -> Bool = { Task.isCancelled }
    ) -> [ResolvedRun] {
        var walker = Walker(
            resolver: self,
            projectURL: PortablePath.anchors(for: sidecarURL ?? sourceRootURL ?? URL(fileURLWithPath: "/")).project,
            isCancelled: isCancelled
        )
        walker.visit(envelope: envelope, sidecarURL: sidecarURL, sourceRootURL: sourceRootURL)
        observer?(.walkEnded(cancelled: walker.wasCancelled))
        return walker.ordered
    }

    // MARK: - Walker

    private struct Walker {
        let resolver: ProvenanceLineageResolver
        let projectURL: URL?
        let isCancelled: () -> Bool
        var ordered: [ResolvedRun] = []
        /// Whether a check found the caller had cancelled. Every later step returns at once.
        private(set) var wasCancelled = false
        private var visitedKeys = Set<String>()
        private var visitedSignatures = Set<String>()
        private var visitedReferenceBundles = Set<String>()
        /// The project index as this walk sees it, fetched on first need.
        private var index: ProvenanceSidecarIndex.Snapshot?

        init(resolver: ProvenanceLineageResolver, projectURL: URL?, isCancelled: @escaping () -> Bool) {
            self.resolver = resolver
            self.projectURL = projectURL
            self.isCancelled = isCancelled
        }

        /// Asks the caller once more whether to stop, and remembers a yes.
        private mutating func stopped() -> Bool {
            if !wasCancelled, isCancelled() {
                wasCancelled = true
            }
            return wasCancelled
        }

        mutating func visit(
            envelope current: ProvenanceEnvelope,
            sidecarURL: URL?,
            sourceRootURL: URL? = nil,
            syntheticKey: String? = nil
        ) {
            guard !stopped(), ordered.count < resolver.maximumRuns else { return }
            let key = syntheticKey
                ?? sidecarURL?.standardizedFileURL.path
                ?? "envelope:\(current.id.uuidString)"
            let idKey = "envelope:\(current.id.uuidString)"
            guard !visitedKeys.contains(key), !visitedKeys.contains(idKey) else { return }
            visitedKeys.insert(key)
            visitedKeys.insert(idKey)
            let signature = ProvenanceLineageResolver.signature(of: current)
            guard visitedSignatures.insert(signature).inserted else { return }

            var supporting: [URL] = []
            for dependency in Self.dependencyDescriptors(of: current) {
                guard !stopped() else { break }
                visitDependency(dependency, from: current, supporting: &supporting)
            }
            if !stopped(), let sourceRootURL,
               let mappingProvenance = MappingProvenance.load(fromFolderOrRecord: sourceRootURL),
               let sourceReferenceBundlePath = mappingProvenance.sourceReferenceBundlePath {
                visitReferenceBundle(URL(fileURLWithPath: sourceReferenceBundlePath), from: current, supporting: &supporting)
            }

            ordered.append(ResolvedRun(sidecarURL: sidecarURL, envelope: current, supportingURLs: supporting))
        }

        private mutating func visitDependency(
            _ descriptor: ProvenanceFileDescriptor,
            from current: ProvenanceEnvelope,
            supporting: inout [URL]
        ) {
            // By path, when the recorded file is here and a record names it.
            var url: URL?
            if descriptor.path.hasPrefix("/") {
                let candidate = URL(fileURLWithPath: descriptor.path).standardizedFileURL
                if FileManager.default.fileExists(atPath: candidate.path) {
                    url = candidate
                    guard !stopped() else { return }
                    if let resolved = ProvenanceRecorder.findProvenanceEnvelope(for: candidate),
                       resolved.envelope.id != current.id,
                       Self.adopts(
                           resolved.envelope,
                           candidate: candidate,
                           checksum: descriptor.checksumSHA256,
                           projectURL: projectURL
                       ) {
                        visit(envelope: resolved.envelope, sidecarURL: resolved.sidecarURL)
                        return
                    }
                }
            }
            // By checksum, against every sidecar in the project.
            // A producer ran before its consumer: a later run that
            // decompressed the same reference holds the same bytes but
            // is not where this record got them.
            if let checksum = descriptor.checksumSHA256, !checksum.isEmpty,
               let producers = producers(ofChecksum: checksum),
               visitProducers(producers.filter { $0.recordID != current.id && $0.createdAt <= current.createdAt }) {
                return
            }
            // A file inside a reference bundle with no record of its own:
            // the bundle's manifest says where the reference came from.
            if !stopped(), let url, let referenceBundleURL = Self.enclosingReferenceBundleURL(for: url) {
                visitReferenceBundle(referenceBundleURL, from: current, supporting: &supporting)
            }
        }

        private mutating func visitReferenceBundle(
            _ bundleURL: URL,
            from current: ProvenanceEnvelope,
            supporting: inout [URL]
        ) {
            let standardized = bundleURL.standardizedFileURL
            guard visitedReferenceBundles.insert(standardized.path).inserted else { return }
            let manifestURL = standardized.appendingPathComponent("manifest.json")
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                supporting.append(manifestURL)
            }
            // A record found for the bundle folder must be the record of the
            // bundle itself (its manifest or genome), not of a track inside it.
            guard !stopped() else { return }
            if let resolved = ProvenanceRecorder.findProvenanceEnvelope(for: standardized),
               Self.produces(resolved.envelope, path: manifestURL.path, checksum: nil)
                || Self.producesDescendant(resolved.envelope, of: standardized.appendingPathComponent("genome")) {
                visit(envelope: resolved.envelope, sidecarURL: resolved.sidecarURL)
                return
            }
            // A copy of a reference inside an analysis has no record of its
            // own, but the import that made the original does: find it by
            // the genome's checksum before inventing a download step.
            if projectURL != nil, !stopped(),
               let manifest = try? BundleManifest.load(from: standardized),
               let genomePath = manifest.genome?.path,
               !stopped(),
               let genome = try? ProvenanceFileDescriptor.file(
                   url: standardized.appendingPathComponent(genomePath), format: .fasta, role: .reference
               ),
               let checksum = genome.checksumSHA256,
               let producers = producers(ofChecksum: checksum),
               visitProducers(producers.filter { $0.createdAt <= current.createdAt }) {
                return
            }
            guard !stopped() else { return }
            if let synthesized = Self.synthesizedReferenceProvenanceEnvelope(for: standardized) {
                visit(envelope: synthesized, sidecarURL: nil, syntheticKey: "reference:\(standardized.path)")
            }
        }

        /// The producers of `checksum` in the project, from the shared index. Nil without a
        /// project, or when the walk stopped before or while the index was read.
        private mutating func producers(ofChecksum checksum: String) -> [ProvenanceSidecarIndex.Producer]? {
            guard let projectURL, !stopped() else { return nil }
            if index == nil {
                index = resolver.sidecarIndex.snapshot(
                    projectURL: projectURL,
                    maximumFiles: resolver.maximumIndexedFiles,
                    isCancelled: isCancelled,
                    observer: resolver.observer
                )
                guard index != nil else {
                    wasCancelled = true
                    return nil
                }
            }
            return index?.producers(ofChecksum: checksum)
        }

        /// Reads each producer in full and visits it, canonical sidecars first. True when one was
        /// read, or when the walk stopped, so the caller looks no further.
        private mutating func visitProducers(_ producers: [ProvenanceSidecarIndex.Producer]) -> Bool {
            var visitedOne = false
            for producer in producers {
                guard !stopped() else { return true }
                guard let envelope = ProvenanceSidecarIndex.readRecord(at: producer.sidecarURL) else { continue }
                visitedOne = true
                visit(envelope: envelope, sidecarURL: producer.sidecarURL)
            }
            return visitedOne
        }

        // MARK: Helpers

        static func dependencyDescriptors(of envelope: ProvenanceEnvelope) -> [ProvenanceFileDescriptor] {
            var seen = Set<String>()
            return (envelope.files + envelope.steps.flatMap(\.inputs)).filter { descriptor in
                (descriptor.role == .input || descriptor.role == .reference)
                    && !descriptor.path.hasPrefix("pipe:")
                    && seen.insert("\(descriptor.path)\u{0}\(descriptor.checksumSHA256 ?? "")").inserted
            }
        }

        /// A record found by walking up from a path must actually name that
        /// file (or its checksum) among its outputs; a parent folder's
        /// unrelated record is not lineage.
        static func produces(_ envelope: ProvenanceEnvelope, path: String, checksum: String?) -> Bool {
            ProvenanceLineageResolver.allOutputs(of: envelope).contains { output in
                URL(fileURLWithPath: output.path).standardizedFileURL.path == path
                    || (checksum != nil && output.checksumSHA256 == checksum)
            }
        }

        /// Whether the record the sidecar lookup found for an input is the record of that input. Inside the
        /// walk's project `produces` is enough, a path or a checksum match. Outside it files at one path get
        /// replaced (a second download into Downloads, a rerun into the same output folder), so the record
        /// of the old bytes would be adopted as the producer of bytes it never wrote. There the record
        /// counts only when the input's recorded checksum is not empty and equals the checksum of one of
        /// its outputs. The input's project is the nearest `.lungfish` folder at or above it, found by
        /// path with no listing, and with no project in the walk every input counts as outside.
        static func adopts(
            _ envelope: ProvenanceEnvelope,
            candidate: URL,
            checksum: String?,
            projectURL: URL?
        ) -> Bool {
            if let projectURL,
               let root = ProjectTempDirectory.findProjectRoot(candidate),
               root.resolvingSymlinksInPath().path == projectURL.resolvingSymlinksInPath().path {
                return produces(envelope, path: candidate.path, checksum: checksum)
            }
            guard let checksum, !checksum.isEmpty else { return false }
            return ProvenanceLineageResolver.allOutputs(of: envelope).contains { $0.checksumSHA256 == checksum }
        }

        static func producesDescendant(_ envelope: ProvenanceEnvelope, of directory: URL) -> Bool {
            let prefix = directory.standardizedFileURL.path + "/"
            return ProvenanceLineageResolver.allOutputs(of: envelope).contains {
                URL(fileURLWithPath: $0.path).standardizedFileURL.path.hasPrefix(prefix)
            }
        }

        static func isDirectory(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }

        static func enclosingReferenceBundleURL(for url: URL) -> URL? {
            var candidate = url.standardizedFileURL
            if !isDirectory(candidate) {
                candidate = candidate.deletingLastPathComponent()
            }
            var seen = Set<String>()
            while true {
                let path = candidate.path
                guard !path.isEmpty, seen.insert(path).inserted else { return nil }
                if candidate.pathExtension.lowercased() == "lungfishref", isDirectory(candidate) {
                    return candidate
                }
                let parent = candidate.deletingLastPathComponent().standardizedFileURL
                guard parent.path != path else { return nil }
                candidate = parent
            }
        }

        static func synthesizedReferenceProvenanceEnvelope(for bundleURL: URL) -> ProvenanceEnvelope? {
            guard let manifest = try? BundleManifest.load(from: bundleURL) else { return nil }

            let sourcePath = manifest.source.sourceURL?.absoluteString
                ?? manifest.source.assemblyAccession
                ?? manifest.identifier
            let sourceDescriptor = ProvenanceFileDescriptor(path: sourcePath, format: .fasta, role: .input)

            var outputDescriptors: [ProvenanceFileDescriptor] = []
            let manifestURL = bundleURL.appendingPathComponent("manifest.json")
            if let descriptor = try? ProvenanceFileDescriptor.file(url: manifestURL, format: .json, role: .output) {
                outputDescriptors.append(descriptor)
            }
            if let genomePath = manifest.genome?.path,
               let descriptor = try? ProvenanceFileDescriptor.file(
                   url: bundleURL.appendingPathComponent(genomePath), format: .fasta, role: .output
               ) {
                outputDescriptors.append(descriptor)
            }
            guard !outputDescriptors.isEmpty else { return nil }

            let startedAt = manifest.source.downloadDate ?? manifest.createdDate
            let toolName = manifest.source.database ?? "reference download"
            let argv = [CLICommandIdentity.executableName, "reference", "download", sourcePath, "--output", bundleURL.path]
            let step = ProvenanceStep(
                toolName: toolName,
                toolVersion: "unknown",
                argv: argv,
                inputs: [sourceDescriptor],
                outputs: outputDescriptors,
                exitStatus: 0,
                wallTimeSeconds: 0,
                startedAt: startedAt,
                completedAt: startedAt
            )
            // This record is made while reading, so it holds no fact of the Mac that reads it.
            return ProvenanceEnvelope(
                createdAt: startedAt,
                workflowName: "lungfish reference acquisition",
                workflowVersion: nil,
                toolName: toolName,
                toolVersion: "unknown",
                tool: ProvenanceToolIdentity(name: toolName, version: "unknown", kind: "download"),
                argv: argv,
                options: ProvenanceOptions(
                    explicit: [
                        "bundle": .file(bundleURL),
                        "database": manifest.source.database.map(ParameterValue.string) ?? .null,
                        "assembly": .string(manifest.source.assembly),
                        "assemblyAccession": manifest.source.assemblyAccession.map(ParameterValue.string) ?? .null,
                        "sourceURL": manifest.source.sourceURL.map { .string($0.absoluteString) } ?? .null,
                    ]
                ),
                runtimeIdentity: ProvenanceRuntimeIdentity(
                    appVersion: nil,
                    executablePath: nil,
                    processIdentifier: nil,
                    operatingSystemVersion: nil,
                    architecture: nil,
                    user: nil,
                    dependencySet: nil
                ),
                files: [sourceDescriptor] + outputDescriptors,
                output: outputDescriptors.first,
                outputs: outputDescriptors,
                steps: [step],
                wallTimeSeconds: 0,
                exitStatus: 0
            )
        }
    }
}

// MARK: - Run identity, shared with the sidecar index

extension ProvenanceLineageResolver {
    static func allOutputs(of envelope: ProvenanceEnvelope) -> [ProvenanceFileDescriptor] {
        envelope.outputs + (envelope.output.map { [$0] } ?? [])
            + envelope.steps.flatMap(\.outputs) + envelope.files.filter { $0.role == .output }
    }

    /// Two records of one run (a mapping record and its copies) share
    /// their steps' tools, commands and outputs.
    static func signature(of envelope: ProvenanceEnvelope) -> String {
        let steps = envelope.steps.map { step in
            stepSignature(
                toolName: step.toolName,
                argv: step.argv,
                outputs: step.outputs.map { $0.checksumSHA256 ?? $0.path }
            )
        }
        if steps.isEmpty {
            return envelope.workflowName + "\u{1}" + envelope.argv.joined(separator: "\u{2}") + "\u{1}"
                + envelope.outputs.map { $0.checksumSHA256 ?? $0.path }.joined(separator: "\u{2}")
        }
        return runSignature(workflowName: envelope.workflowName, steps: steps)
    }

    /// One step of a signature. `outputs` holds each output's checksum, or its path without one.
    static func stepSignature(toolName: String, argv: [String], outputs: [String]) -> String {
        toolName + "\u{1}" + argv.joined(separator: "\u{2}") + "\u{1}" + outputs.joined(separator: "\u{2}")
    }

    static func runSignature(workflowName: String, steps: [String]) -> String {
        workflowName + "\u{1}" + steps.joined(separator: "\u{3}")
    }
}
