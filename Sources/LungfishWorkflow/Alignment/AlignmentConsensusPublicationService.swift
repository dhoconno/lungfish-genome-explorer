import Foundation
import LungfishCore
import LungfishIO

package enum AlignmentConsensusPublicationDestination: Sendable, Equatable {
    case referenceBundle(URL)
    case fasta(URL)

    package var finalURL: URL {
        switch self {
        case .referenceBundle(let url), .fasta(let url): url.standardizedFileURL
        }
    }
}

package struct AlignmentConsensusPublicationRequest: Sendable {
    package let context: AlignmentActionContext
    package let region: ResolvedAlignmentRegion
    package let consensusRequest: AlignmentConsensusRequest
    package let result: AlignmentConsensusResult
    package let recordName: String
    package let destination: AlignmentConsensusPublicationDestination
    /// Whether the user accepted a result whose every position is below the minimum depth.
    package let allowAllLowDepth: Bool

    package init(
        context: AlignmentActionContext,
        region: ResolvedAlignmentRegion,
        consensusRequest: AlignmentConsensusRequest,
        result: AlignmentConsensusResult,
        recordName: String,
        destination: AlignmentConsensusPublicationDestination,
        allowAllLowDepth: Bool = false
    ) {
        self.context = context
        self.region = region
        self.consensusRequest = consensusRequest
        self.result = result
        self.recordName = recordName
        self.destination = destination
        self.allowAllLowDepth = allowAllLowDepth
    }

    /// The `lungfish-cli bam consensus` run this publication records, whose `--output` is the destination.
    package var invocation: AlignmentConsensusInvocation {
        AlignmentConsensusInvocation(
            context: context,
            region: region,
            consensusRequest: consensusRequest,
            recordName: recordName,
            output: destination.finalURL.path,
            allowAllLowDepth: allowAllLowDepth
        )
    }
}

package struct AlignmentConsensusPublicationResult: Sendable, Equatable {
    package let finalURL: URL
    package let payloadURL: URL
    package let provenanceURL: URL

    package init(finalURL: URL, payloadURL: URL, provenanceURL: URL) {
        self.finalURL = finalURL
        self.payloadURL = payloadURL
        self.provenanceURL = provenanceURL
    }
}

package enum AlignmentConsensusPublicationError: LocalizedError {
    case invalidRegion
    case invalidResultLength
    case destinationExists(URL)

    package var errorDescription: String? {
        switch self {
        case .invalidRegion: "The consensus publication region is invalid."
        case .invalidResultLength: "The consensus result does not cover the requested region."
        case .destinationExists(let url): "A file already exists at \(url.path)."
        }
    }
}

package struct AlignmentConsensusPublicationAttempt: Sendable, Equatable {
    package enum Stage: String, Sendable { case validation, destinationCheck, payloadWrite, manifestWrite, provenanceWrite, sidecarPublication, payloadPublication }
    package let stage: Stage
    package let argv: [String]
    package let reproducibleCommand: String
    package let explicitOptions: [String: String]
    package let resolvedDefaults: [String: String]
    package let destinationPath: String
    package let evidence: [AlignmentEvidenceFileSnapshot]
    package let startedAt: Date
    package let endedAt: Date
    package let exitStatus: Int32
    package let stderr: String

    package var durableLogMessage: String {
        let inputs = evidence.map { "\($0.url.path) size=\($0.byteCount) sha256=\($0.sha256)" }.joined(separator: "; ")
        let explicit = explicitOptions.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        let defaults = resolvedDefaults.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        return "publication-stage=\(stage.rawValue) exit=\(exitStatus) wall=\(endedAt.timeIntervalSince(startedAt))s\nargv=\(argv.joined(separator: " "))\ncommand=\(reproducibleCommand)\ndestination=\(destinationPath)\nexplicit-options=\(explicit)\nresolved-defaults=\(defaults)\ninputs=\(inputs)\nstderr=\(stderr)"
    }
}

package struct AlignmentConsensusPublicationFailure: LocalizedError, Sendable {
    package let attempt: AlignmentConsensusPublicationAttempt
    package let underlyingDescription: String
    package var errorDescription: String? { underlyingDescription }
}

/// Publishes evidence-only consensus through a hidden sibling staging target.
/// Every durable descriptor is constructed from its final path; staging paths
/// survive only as `originPath`/the explicit staging-to-final audit mapping.
package struct AlignmentConsensusPublicationService {
    package typealias Mover = (URL, URL) throws -> Void
    package typealias FailureInjector = (AlignmentConsensusPublicationAttempt.Stage) throws -> Void
    private let moveItem: Mover
    private let failureInjector: FailureInjector

    package init(
        moveItem: @escaping Mover = { source, destination in
            try Self.renameExclusively(source, destination)
        },
        failureInjector: @escaping FailureInjector = { _ in }
    ) {
        self.moveItem = moveItem
        self.failureInjector = failureInjector
    }

    package func publish(_ request: AlignmentConsensusPublicationRequest) throws -> AlignmentConsensusPublicationResult {
        let runClock = ProvenanceRunClock()
        var stage = AlignmentConsensusPublicationAttempt.Stage.validation
        do {
            try failureInjector(stage)
            guard request.region.contig == request.context.contig,
              request.region.contig == request.consensusRequest.chromosome,
              request.region.start == request.consensusRequest.start,
              request.region.end == request.consensusRequest.end,
              request.region.start >= 0,
              request.region.start < request.region.end,
              request.region.end <= request.context.contigLength else {
                throw AlignmentConsensusPublicationError.invalidRegion
            }
            guard request.result.referenceLength == request.region.end - request.region.start,
              request.result.sequence.count == request.result.referenceLength else {
                throw AlignmentConsensusPublicationError.invalidResultLength
            }
            stage = .destinationCheck
            try failureInjector(stage)
            let finalURL = request.destination.finalURL
            let finalSidecarURL = ProvenanceRecorder.fileSidecarURL(for: finalURL)
            // A cancelled run leaves its record beside the output and no output, and this run
            // replaces that record. Any other record keeps the destination taken.
            let replacesCancelledRecord = Self.isCancelledRecord(at: finalSidecarURL)
            guard !FileManager.default.fileExists(atPath: finalURL.path),
              isBundle(request.destination) || replacesCancelledRecord
                || !FileManager.default.fileExists(atPath: finalSidecarURL.path) else {
                throw AlignmentConsensusPublicationError.destinationExists(finalURL)
            }
            let stagingURL = finalURL.deletingLastPathComponent().appendingPathComponent(
                ".\(finalURL.lastPathComponent).staging-\(UUID().uuidString)",
                isDirectory: isBundle(request.destination)
            )
            do {
                let prepared = try prepare(request, at: stagingURL, finalURL: finalURL, stage: &stage)
                if replacesCancelledRecord {
                    // The signature and public key of a signed cancelled record go with it.
                    try ProvenancePublicationArtifacts.removeSidecarArtifacts(for: finalSidecarURL)
                }
            if isBundle(request.destination) {
                stage = .payloadPublication
                try failureInjector(stage)
                try moveItem(stagingURL, finalURL)
            } else {
                do {
                    // The FASTA rename is the publication point. Install its
                    // final-path sidecar first so no durable payload can ever
                    // be observed without provenance, even across a crash.
                    stage = .sidecarPublication
                    try failureInjector(stage)
                    if let envelope = prepared.unwrittenEnvelope {
                        _ = try ProvenanceWriter().writeNew(envelope, toSidecar: prepared.finalProvenanceURL)
                    } else {
                        try moveItem(prepared.physicalProvenanceURL, prepared.finalProvenanceURL)
                    }
                    stage = .payloadPublication
                    try failureInjector(stage)
                    try moveItem(stagingURL, finalURL)
                } catch {
                    try? FileManager.default.removeItem(at: finalURL)
                    // The signature and public key of a record signed at its final name go with the record.
                    try? ProvenancePublicationArtifacts.removeSidecarArtifacts(for: prepared.finalProvenanceURL)
                    throw error
                }
            }
                return .init(
                finalURL: finalURL,
                payloadURL: prepared.finalPayloadURL,
                provenanceURL: prepared.finalProvenanceURL
                )
            } catch {
                try? FileManager.default.removeItem(at: stagingURL)
                try? FileManager.default.removeItem(at: ProvenanceRecorder.fileSidecarURL(for: stagingURL))
                throw error
            }
        } catch let failure as AlignmentConsensusPublicationFailure {
            throw failure
        } catch {
            let endedAt = runClock.now
            throw AlignmentConsensusPublicationFailure(
                attempt: publicationAttempt(request, stage: stage, startedAt: runClock.startedAt, endedAt: endedAt, error: error),
                underlyingDescription: error.localizedDescription
            )
        }
    }

    private func prepare(
        _ request: AlignmentConsensusPublicationRequest,
        at stagingURL: URL,
        finalURL: URL,
        stage: inout AlignmentConsensusPublicationAttempt.Stage
    ) throws -> (
        finalPayloadURL: URL, physicalProvenanceURL: URL, finalProvenanceURL: URL, unwrittenEnvelope: ProvenanceEnvelope?
    ) {
        let fasta = ">\(sanitizedHeader(request.recordName))\n\(request.result.sequence)\n"
        let physicalPayloadURL: URL
        let finalPayloadURL: URL
        let physicalProvenanceURL: URL
        let finalProvenanceURL: URL
        switch request.destination {
        case .fasta:
            try FileManager.default.createDirectory(at: stagingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            stage = .payloadWrite
            try failureInjector(stage)
            try Data(fasta.utf8).write(to: stagingURL, options: .atomic)
            physicalPayloadURL = stagingURL
            finalPayloadURL = finalURL
            physicalProvenanceURL = ProvenanceRecorder.fileSidecarURL(for: stagingURL)
            finalProvenanceURL = ProvenanceRecorder.fileSidecarURL(for: finalURL)
        case .referenceBundle:
            let genome = stagingURL.appendingPathComponent("genome", isDirectory: true)
            try FileManager.default.createDirectory(at: genome, withIntermediateDirectories: true)
            physicalPayloadURL = genome.appendingPathComponent("consensus.fasta")
            finalPayloadURL = finalURL.appendingPathComponent("genome/consensus.fasta")
            stage = .payloadWrite
            try failureInjector(stage)
            try Data(fasta.utf8).write(to: physicalPayloadURL, options: .atomic)
            stage = .manifestWrite
            try failureInjector(stage)
            try writeManifest(request, to: stagingURL)
            physicalProvenanceURL = stagingURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
            finalProvenanceURL = finalURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        }
        let envelope = try provenanceEnvelope(
            request,
            physicalPayloadURL: physicalPayloadURL,
            finalPayloadURL: finalPayloadURL,
            finalProvenanceURL: finalProvenanceURL
        )
        stage = .provenanceWrite
        try failureInjector(stage)
        let writer = ProvenanceWriter()
        if case .fasta = request.destination, writer.signingProvider != nil {
            // A signature made at the staged sibling name names that file inside the record, and renaming the record
            // could not make it verify. With a key set, `publish` writes and signs the record at the name it keeps.
            return (finalPayloadURL, physicalProvenanceURL, finalProvenanceURL, envelope)
        }
        try writer.write(envelope, toSidecar: physicalProvenanceURL)
        return (finalPayloadURL, physicalProvenanceURL, finalProvenanceURL, nil)
    }

    private func publicationAttempt(
        _ request: AlignmentConsensusPublicationRequest,
        stage: AlignmentConsensusPublicationAttempt.Stage,
        startedAt: Date,
        endedAt: Date,
        error: Error
    ) -> AlignmentConsensusPublicationAttempt {
        let filters = request.consensusRequest.filters
        let argv = Self.replayArgv(request.invocation)
        var evidence = [request.context.alignmentSnapshot, request.context.indexSnapshot]
        if let snapshot = request.context.decodingReferenceSnapshot { evidence.append(snapshot) }
        return .init(
            stage: stage,
            argv: argv,
            reproducibleCommand: argv.map(Self.shellQuote).joined(separator: " "),
            explicitOptions: [
                "scope": request.region.scope.rawValue,
                "region": "\(request.region.contig):\(request.region.start)-\(request.region.end)",
                "minimumDepth": "\(filters.minimumDepth)",
                "minimumMapQ": "\(filters.minimumMapQ)",
                "minimumBaseQuality": "\(filters.minimumBaseQuality)",
                "excludedFlags": "\(filters.excludedFlags)",
                "readGroups": filters.readGroups.sorted().joined(separator: ","),
                "callerMode": request.consensusRequest.mode.rawValue,
                "useAmbiguity": "\(request.consensusRequest.useAmbiguity)",
                "insertionPolicy": request.consensusRequest.insertionPolicy.rawValue,
                "deletionPolicy": request.consensusRequest.deletionPolicy.rawValue
            ],
            resolvedDefaults: [
                "lowDepthPolicy": "N",
                "referenceFillPolicy": "never",
                "runtime": "\(CLICommandIdentity.executableName) \(Self.version)"
            ],
            destinationPath: request.destination.finalURL.path,
            evidence: evidence,
            startedAt: startedAt,
            endedAt: endedAt,
            exitStatus: 1,
            stderr: error.localizedDescription
        )
    }

    private static func shellQuote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/:"))
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func writeManifest(_ request: AlignmentConsensusPublicationRequest, to bundleURL: URL) throws {
        let length = Int64(request.result.referenceLength)
        let chromosome = ChromosomeInfo(
            name: request.region.contig,
            length: length,
            offset: Int64(">\(sanitizedHeader(request.recordName))\n".utf8.count),
            lineBases: Int(length),
            lineWidth: Int(length) + 1
        )
        let manifest = BundleManifest(
            name: request.recordName,
            identifier: "org.lungfish.consensus.\(UUID().uuidString.lowercased())",
            description: "Evidence-only BAM/CRAM consensus; low-depth positions are N and reference fill is never used.",
            source: SourceInfo(organism: "Derived consensus", assembly: request.context.identity.resultID),
            genome: GenomeInfo(
                path: "genome/consensus.fasta",
                indexPath: "genome/consensus.fasta.fai",
                totalLength: length,
                chromosomes: [chromosome]
            ),
            annotations: [], variants: [], tracks: [], alignments: [],
            browserSummary: .init(
                schemaVersion: 1,
                aggregate: .init(annotationTrackCount: 0, variantTrackCount: 0, alignmentTrackCount: 0, totalMappedReads: nil),
                sequences: [.init(name: request.region.contig, displayDescription: nil, length: length, aliases: [], isPrimary: true, isMitochondrial: false, metrics: nil)]
            )
        )
        try manifest.save(to: bundleURL)
        let fastaOffset = chromosome.offset
        try "\(request.region.contig)\t\(length)\t\(fastaOffset)\t\(length)\t\(length + 1)\n"
            .write(to: bundleURL.appendingPathComponent("genome/consensus.fasta.fai"), atomically: true, encoding: .utf8)
    }

    private func provenanceEnvelope(
        _ request: AlignmentConsensusPublicationRequest,
        physicalPayloadURL: URL,
        finalPayloadURL: URL,
        finalProvenanceURL: URL
    ) throws -> ProvenanceEnvelope {
        let output = ProvenanceFileDescriptor(
            path: finalPayloadURL.path,
            checksumSHA256: try ProvenanceFileHasher.sha256(of: physicalPayloadURL),
            fileSize: try ProvenanceFileHasher.fileSize(of: physicalPayloadURL),
            format: .fasta,
            role: .output,
            originPath: physicalPayloadURL.path
        )
        let inputs = try evidenceDescriptors(request.context)
        let steps = request.result.executionRecords.map { execution in
            ProvenanceStep(
                toolName: "samtools",
                toolVersion: execution.executableVersion,
                argv: [execution.executablePath] + execution.argv,
                reproducibleCommand: execution.reproducibleCommand,
                resolvedOptions: execution.resolvedDefaults.mapValues(ParameterValue.string),
                runtimeIdentity: .init(appVersion: execution.executableVersion, executablePath: execution.executablePath),
                inputs: execution.inputs.compactMap { descriptor in
                    // Request-scoped filtered BAMs are temporary intermediates;
                    // retain their evidence in the step without pretending they
                    // are durable final payloads.
                    ProvenanceFileDescriptor(
                        path: descriptor.path,
                        checksumSHA256: descriptor.checksumSHA256,
                        fileSize: descriptor.fileSize,
                        format: descriptor.path.hasSuffix(".bam") ? .bam : .unknown,
                        role: .input
                    )
                },
                outputs: [],
                exitStatus: execution.exitStatus.map(Int.init),
                wallTimeSeconds: execution.wallTimeSeconds,
                stderr: execution.stderr,
                startedAt: execution.startedAt,
                completedAt: execution.endedAt
            )
        }
        let mapping: [String: ParameterValue] = [physicalPayloadURL.path: .string(finalPayloadURL.path)]
        let explicit = Self.explicitOptions(request.invocation)
        let resolved: [String: ParameterValue] = [
            "lowDepthPolicy": .string("N"),
            "referenceFillPolicy": .string("never"),
            "allLowDepth": .boolean(request.result.allLowDepth),
            "stagingToFinalMapping": .dictionary(mapping),
            "finalProvenancePath": .string(finalProvenanceURL.path)
        ]
        let argv = Self.replayArgv(request.invocation)
        let stderr = request.result.executionRecords.compactMap(\.stderr).filter { !$0.isEmpty }.joined(separator: "\n")
        return ProvenanceEnvelope(
            workflowName: Self.workflowName,
            workflowVersion: Self.version,
            toolName: CLICommandIdentity.executableName,
            toolVersion: Self.version,
            tool: .init(name: CLICommandIdentity.executableName, version: Self.version, kind: "cli"),
            argv: argv,
            durableReplayArgv: argv,
            options: .init(explicit: explicit, resolvedDefaults: resolved),
            runtimeIdentity: .init(appVersion: Self.version),
            files: inputs + [output],
            output: output,
            outputs: [output],
            steps: steps,
            wallTimeSeconds: request.result.executionRecords.reduce(0) { $0 + $1.wallTimeSeconds },
            exitStatus: 0,
            stderr: stderr.isEmpty ? nil : stderr
        )
    }

    private func evidenceDescriptors(_ context: AlignmentActionContext) throws -> [ProvenanceFileDescriptor] {
        var descriptors = [
            ProvenanceFileDescriptor(path: context.alignmentURL.path, checksumSHA256: context.alignmentSnapshot.sha256, fileSize: context.alignmentSnapshot.byteCount, format: context.alignmentURL.pathExtension.lowercased() == "cram" ? .cram : .bam, role: .input),
            ProvenanceFileDescriptor(path: context.indexURL.path, checksumSHA256: context.indexSnapshot.sha256, fileSize: context.indexSnapshot.byteCount, format: .unknown, role: .index)
        ]
        if let url = context.decodingReferenceURL, let snapshot = context.decodingReferenceSnapshot {
            descriptors.append(.init(path: url.path, checksumSHA256: snapshot.sha256, fileSize: snapshot.byteCount, format: .fasta, role: .reference))
        }
        return descriptors
    }

    private func sanitizedHeader(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    private func isBundle(_ destination: AlignmentConsensusPublicationDestination) -> Bool {
        if case .referenceBundle = destination { return true }
        return false
    }
}
