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
// is shown and nothing crashes.

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

    /// The most records one chain is allowed to gather.
    private let maximumRuns: Int
    /// The most files the project index reads before giving up on checksums.
    private let maximumIndexedFiles: Int

    public init(maximumRuns: Int = 64, maximumIndexedFiles: Int = 4_000) {
        self.maximumRuns = maximumRuns
        self.maximumIndexedFiles = maximumIndexedFiles
    }

    /// The records that fed `envelope`, upstream first, ending with
    /// `envelope` itself. `sourceRootURL` is the file or folder the caller
    /// selected, whose mapping record may name a source reference bundle.
    public func resolve(
        envelope: ProvenanceEnvelope,
        sidecarURL: URL?,
        sourceRootURL: URL? = nil
    ) -> [ResolvedRun] {
        var walker = Walker(
            resolver: self,
            projectURL: PortablePath.anchors(for: sidecarURL ?? sourceRootURL ?? URL(fileURLWithPath: "/")).project
        )
        walker.visit(envelope: envelope, sidecarURL: sidecarURL, sourceRootURL: sourceRootURL)
        return walker.ordered
    }

    // MARK: - Walker

    private struct Walker {
        let resolver: ProvenanceLineageResolver
        let projectURL: URL?
        var ordered: [ResolvedRun] = []
        private var visitedKeys = Set<String>()
        private var visitedSignatures = Set<String>()
        private var visitedReferenceBundles = Set<String>()
        private var index: ProjectSidecarIndex?

        init(resolver: ProvenanceLineageResolver, projectURL: URL?) {
            self.resolver = resolver
            self.projectURL = projectURL
        }

        mutating func visit(
            envelope current: ProvenanceEnvelope,
            sidecarURL: URL?,
            sourceRootURL: URL? = nil,
            syntheticKey: String? = nil
        ) {
            guard ordered.count < resolver.maximumRuns else { return }
            let key = syntheticKey
                ?? sidecarURL?.standardizedFileURL.path
                ?? "envelope:\(current.id.uuidString)"
            let idKey = "envelope:\(current.id.uuidString)"
            guard !visitedKeys.contains(key), !visitedKeys.contains(idKey) else { return }
            visitedKeys.insert(key)
            visitedKeys.insert(idKey)
            let signature = Self.signature(of: current)
            guard visitedSignatures.insert(signature).inserted else { return }

            var supporting: [URL] = []
            for dependency in Self.dependencyDescriptors(of: current) {
                visitDependency(dependency, from: current, supporting: &supporting)
            }
            if let sourceRootURL, Self.isDirectory(sourceRootURL),
               let mappingProvenance = MappingProvenance.load(from: sourceRootURL),
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
                    if let resolved = ProvenanceRecorder.findProvenanceEnvelope(for: candidate),
                       resolved.envelope.id != current.id,
                       Self.produces(resolved.envelope, path: candidate.path, checksum: descriptor.checksumSHA256) {
                        visit(envelope: resolved.envelope, sidecarURL: resolved.sidecarURL)
                        return
                    }
                }
            }
            // By checksum, against every sidecar in the project.
            if let checksum = descriptor.checksumSHA256, !checksum.isEmpty, let projectURL {
                if index == nil {
                    index = ProjectSidecarIndex(projectURL: projectURL, maximumFiles: resolver.maximumIndexedFiles)
                }
                // A producer ran before its consumer: a later run that
                // decompressed the same reference holds the same bytes but
                // is not where this record got them.
                let matches = (index?.producers(ofChecksum: checksum) ?? []).filter {
                    $0.envelope.id != current.id && $0.envelope.createdAt <= current.createdAt
                }
                if !matches.isEmpty {
                    for match in matches {
                        visit(envelope: match.envelope, sidecarURL: match.sidecarURL)
                    }
                    return
                }
            }
            // A file inside a reference bundle with no record of its own:
            // the bundle's manifest says where the reference came from.
            if let url, let referenceBundleURL = Self.enclosingReferenceBundleURL(for: url) {
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
            if let resolved = ProvenanceRecorder.findProvenanceEnvelope(for: standardized),
               Self.produces(resolved.envelope, path: manifestURL.path, checksum: nil)
                || Self.producesDescendant(resolved.envelope, of: standardized.appendingPathComponent("genome")) {
                visit(envelope: resolved.envelope, sidecarURL: resolved.sidecarURL)
                return
            }
            // A copy of a reference inside an analysis has no record of its
            // own, but the import that made the original does: find it by
            // the genome's checksum before inventing a download step.
            if let projectURL,
               let manifest = try? BundleManifest.load(from: standardized),
               let genomePath = manifest.genome?.path,
               let genome = try? ProvenanceFileDescriptor.file(
                   url: standardized.appendingPathComponent(genomePath), format: .fasta, role: .reference
               ),
               let checksum = genome.checksumSHA256 {
                if index == nil {
                    index = ProjectSidecarIndex(projectURL: projectURL, maximumFiles: resolver.maximumIndexedFiles)
                }
                let matches = (index?.producers(ofChecksum: checksum) ?? []).filter { $0.envelope.createdAt <= current.createdAt }
                if !matches.isEmpty {
                    for match in matches {
                        visit(envelope: match.envelope, sidecarURL: match.sidecarURL)
                    }
                    return
                }
            }
            if let synthesized = Self.synthesizedReferenceProvenanceEnvelope(for: standardized) {
                visit(envelope: synthesized, sidecarURL: nil, syntheticKey: "reference:\(standardized.path)")
            }
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
            allOutputs(of: envelope).contains { output in
                URL(fileURLWithPath: output.path).standardizedFileURL.path == path
                    || (checksum != nil && output.checksumSHA256 == checksum)
            }
        }

        static func producesDescendant(_ envelope: ProvenanceEnvelope, of directory: URL) -> Bool {
            let prefix = directory.standardizedFileURL.path + "/"
            return allOutputs(of: envelope).contains {
                URL(fileURLWithPath: $0.path).standardizedFileURL.path.hasPrefix(prefix)
            }
        }

        static func allOutputs(of envelope: ProvenanceEnvelope) -> [ProvenanceFileDescriptor] {
            envelope.outputs + (envelope.output.map { [$0] } ?? [])
                + envelope.steps.flatMap(\.outputs) + envelope.files.filter { $0.role == .output }
        }

        /// Two records of one run (a mapping record and its copies) share
        /// their steps' tools, commands and outputs.
        static func signature(of envelope: ProvenanceEnvelope) -> String {
            let steps = envelope.steps.map { step in
                step.toolName + "\u{1}" + step.argv.joined(separator: "\u{2}") + "\u{1}"
                    + step.outputs.map { $0.checksumSHA256 ?? $0.path }.joined(separator: "\u{2}")
            }
            if steps.isEmpty {
                return envelope.workflowName + "\u{1}" + envelope.argv.joined(separator: "\u{2}") + "\u{1}"
                    + envelope.outputs.map { $0.checksumSHA256 ?? $0.path }.joined(separator: "\u{2}")
            }
            return envelope.workflowName + "\u{1}" + steps.joined(separator: "\u{3}")
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
            return ProvenanceEnvelope(
                createdAt: startedAt,
                workflowName: "lungfish reference acquisition",
                workflowVersion: WorkflowRun.currentAppVersion,
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
                    appVersion: WorkflowRun.currentAppVersion,
                    operatingSystemVersion: WorkflowRun.currentHostOS
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

    // MARK: - Project index

    /// Every readable provenance sidecar under a project, keyed by the
    /// checksums of the files it produced. Built once per resolution, only
    /// when a recorded path resolves nothing.
    private struct ProjectSidecarIndex {
        struct Entry {
            let sidecarURL: URL
            let envelope: ProvenanceEnvelope
        }

        private var byChecksum: [String: [Entry]] = [:]

        init(projectURL: URL, maximumFiles: Int) {
            let fileManager = FileManager.default
            // Bundles (`.lungfishref`, `.lungfishfastq`) are document packages
            // in the app's process, so the enumerator must not skip package
            // descendants: their sidecars are the records being indexed.
            guard let enumerator = fileManager.enumerator(
                at: projectURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: []
            ) else { return }
            var candidates: [URL] = []
            var visited = 0
            for case let url as URL in enumerator {
                visited += 1
                if visited > maximumFiles { break }
                let name = url.lastPathComponent
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    if name == ".tmp" || name == ".build" || name == "node_modules" {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                if Self.isSidecarName(name) {
                    candidates.append(url.standardizedFileURL)
                }
            }
            // Canonical sidecars first so a mapping record's copies never
            // shadow the record they were copied from.
            candidates.sort { lhs, rhs in
                let l = Self.rank(lhs), r = Self.rank(rhs)
                return l == r ? lhs.path < rhs.path : l < r
            }
            var seenIDs = Set<UUID>()
            var seenSignatures = Set<String>()
            for sidecarURL in candidates {
                guard let envelope = Self.load(sidecarURL) else { continue }
                guard seenIDs.insert(envelope.id).inserted,
                      seenSignatures.insert(Walker.signature(of: envelope)).inserted else { continue }
                let entry = Entry(sidecarURL: sidecarURL, envelope: envelope)
                // A step that writes a byte copy of its own input (a staging
                // symlink, an adopted BAM) did not make those bytes; the step
                // that did is the producer. A later step in the same record
                // reading the file (samtools faidx after bgzip) does not
                // disqualify the record, so the rule is per step.
                var checksums = Set<String>()
                func index(_ outputs: [ProvenanceFileDescriptor], inputs: [ProvenanceFileDescriptor]) {
                    let inputChecksums = Set(inputs.compactMap(\.checksumSHA256))
                    for output in outputs {
                        guard let checksum = output.checksumSHA256, !checksum.isEmpty,
                              !inputChecksums.contains(checksum), checksums.insert(checksum).inserted else { continue }
                        byChecksum[checksum, default: []].append(entry)
                    }
                }
                if envelope.steps.isEmpty {
                    index(Walker.allOutputs(of: envelope), inputs: envelope.files.filter { $0.role != .output })
                } else {
                    for step in envelope.steps {
                        index(step.outputs, inputs: step.inputs)
                    }
                }
            }
        }

        func producers(ofChecksum checksum: String) -> [Entry] {
            byChecksum[checksum] ?? []
        }

        private static func isSidecarName(_ name: String) -> Bool {
            name == ProvenanceRecorder.provenanceFilename
                || name == MappingProvenance.filename
                || name.hasSuffix(".lungfish-provenance.json")
                || name.hasSuffix("-provenance.json")
        }

        private static func rank(_ url: URL) -> Int {
            let name = url.lastPathComponent
            if name == ProvenanceRecorder.provenanceFilename { return 0 }
            if name.hasSuffix(".lungfish-provenance.json") { return 1 }
            if name == MappingProvenance.filename { return 3 }
            return 2
        }

        private static func load(_ url: URL) -> ProvenanceEnvelope? {
            if url.lastPathComponent == MappingProvenance.filename {
                let directory = url.deletingLastPathComponent()
                return MappingProvenance.load(from: directory)?.canonicalEnvelope(sourceDirectory: directory)
            }
            return ProvenanceRecorder.loadEnvelope(fromSidecar: url)
        }
    }
}
