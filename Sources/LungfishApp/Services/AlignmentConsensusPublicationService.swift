import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

enum AlignmentConsensusPublicationDestination: Sendable, Equatable {
    case referenceBundle(URL)
    case fasta(URL)

    var finalURL: URL {
        switch self {
        case .referenceBundle(let url), .fasta(let url): url.standardizedFileURL
        }
    }
}

struct AlignmentConsensusPublicationRequest: Sendable {
    let context: AlignmentActionContext
    let region: ResolvedAlignmentRegion
    let consensusRequest: AlignmentConsensusRequest
    let result: AlignmentConsensusResult
    let recordName: String
    let destination: AlignmentConsensusPublicationDestination
}

struct AlignmentConsensusPublicationResult: Sendable, Equatable {
    let finalURL: URL
    let payloadURL: URL
    let provenanceURL: URL
}

enum AlignmentConsensusPublicationError: LocalizedError {
    case invalidRegion
    case invalidResultLength
    case destinationExists(URL)

    var errorDescription: String? {
        switch self {
        case .invalidRegion: "The consensus publication region is invalid."
        case .invalidResultLength: "The consensus result does not cover the requested region."
        case .destinationExists(let url): "A file already exists at \(url.path)."
        }
    }
}

struct AlignmentConsensusPublicationAttempt: Sendable, Equatable {
    enum Stage: String, Sendable { case validation, destinationCheck, payloadWrite, manifestWrite, provenanceWrite, sidecarPublication, payloadPublication }
    let stage: Stage
    let argv: [String]
    let reproducibleCommand: String
    let explicitOptions: [String: String]
    let resolvedDefaults: [String: String]
    let destinationPath: String
    let evidence: [AlignmentEvidenceFileSnapshot]
    let startedAt: Date
    let endedAt: Date
    let exitStatus: Int32
    let stderr: String

    var durableLogMessage: String {
        let inputs = evidence.map { "\($0.url.path) size=\($0.byteCount) sha256=\($0.sha256)" }.joined(separator: "; ")
        let explicit = explicitOptions.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        let defaults = resolvedDefaults.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        return "publication-stage=\(stage.rawValue) exit=\(exitStatus) wall=\(endedAt.timeIntervalSince(startedAt))s\nargv=\(argv.joined(separator: " "))\ncommand=\(reproducibleCommand)\ndestination=\(destinationPath)\nexplicit-options=\(explicit)\nresolved-defaults=\(defaults)\ninputs=\(inputs)\nstderr=\(stderr)"
    }
}

struct AlignmentConsensusPublicationFailure: LocalizedError, Sendable {
    let attempt: AlignmentConsensusPublicationAttempt
    let underlyingDescription: String
    var errorDescription: String? { underlyingDescription }
}

/// Publishes evidence-only consensus through a hidden sibling staging target.
/// Every durable descriptor is constructed from its final path; staging paths
/// survive only as `originPath`/the explicit staging-to-final audit mapping.
struct AlignmentConsensusPublicationService {
    typealias Mover = (URL, URL) throws -> Void
    typealias FailureInjector = (AlignmentConsensusPublicationAttempt.Stage) throws -> Void
    private let moveItem: Mover
    private let failureInjector: FailureInjector

    init(
        moveItem: @escaping Mover = { source, destination in
            try FileManager.default.moveItem(at: source, to: destination)
        },
        failureInjector: @escaping FailureInjector = { _ in }
    ) {
        self.moveItem = moveItem
        self.failureInjector = failureInjector
    }

    func publish(_ request: AlignmentConsensusPublicationRequest) throws -> AlignmentConsensusPublicationResult {
        let startedAt = Date()
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
            guard !FileManager.default.fileExists(atPath: finalURL.path),
              isBundle(request.destination) || !FileManager.default.fileExists(atPath: finalSidecarURL.path) else {
                throw AlignmentConsensusPublicationError.destinationExists(finalURL)
            }
            let stagingURL = finalURL.deletingLastPathComponent().appendingPathComponent(
                ".\(finalURL.lastPathComponent).staging-\(UUID().uuidString)",
                isDirectory: isBundle(request.destination)
            )
            do {
                let prepared = try prepare(request, at: stagingURL, finalURL: finalURL, stage: &stage)
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
                    try moveItem(prepared.physicalProvenanceURL, prepared.finalProvenanceURL)
                    stage = .payloadPublication
                    try failureInjector(stage)
                    try moveItem(stagingURL, finalURL)
                } catch {
                    try? FileManager.default.removeItem(at: finalURL)
                    try? FileManager.default.removeItem(at: prepared.finalProvenanceURL)
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
            let endedAt = Date()
            throw AlignmentConsensusPublicationFailure(
                attempt: publicationAttempt(request, stage: stage, startedAt: startedAt, endedAt: endedAt, error: error),
                underlyingDescription: error.localizedDescription
            )
        }
    }

    private func prepare(
        _ request: AlignmentConsensusPublicationRequest,
        at stagingURL: URL,
        finalURL: URL,
        stage: inout AlignmentConsensusPublicationAttempt.Stage
    ) throws -> (finalPayloadURL: URL, physicalProvenanceURL: URL, finalProvenanceURL: URL) {
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
        try ProvenanceWriter(signingProvider: nil).write(envelope, toSidecar: physicalProvenanceURL)
        return (finalPayloadURL, physicalProvenanceURL, finalProvenanceURL)
    }

    private func publicationAttempt(
        _ request: AlignmentConsensusPublicationRequest,
        stage: AlignmentConsensusPublicationAttempt.Stage,
        startedAt: Date,
        endedAt: Date,
        error: Error
    ) -> AlignmentConsensusPublicationAttempt {
        let filters = request.consensusRequest.filters
        let argv = replayArgv(request)
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
                "runtime": "Lungfish.app \(WorkflowRun.currentAppVersion)"
            ],
            destinationPath: request.destination.finalURL.path,
            evidence: evidence,
            startedAt: startedAt,
            endedAt: endedAt,
            exitStatus: 1,
            stderr: error.localizedDescription
        )
    }

    private func replayArgv(_ request: AlignmentConsensusPublicationRequest) -> [String] {
        let filters = request.consensusRequest.filters
        var argv = [
            "Lungfish.app", "alignment", "consensus",
            "--alignment", request.context.alignmentURL.path,
            "--index", request.context.indexURL.path
        ]
        if let referenceURL = request.context.decodingReferenceURL {
            argv += ["--decoding-reference", referenceURL.path]
        }
        argv += [
            "--scope", request.region.scope.rawValue,
            "--region", "\(request.region.contig):\(request.region.start)-\(request.region.end)",
            "--min-depth", "\(filters.minimumDepth)",
            "--min-mapq", "\(filters.minimumMapQ)",
            "--min-baseq", "\(filters.minimumBaseQuality)",
            "--exclude-flags", "\(filters.excludedFlags)"
        ]
        for readGroup in filters.readGroups.sorted() {
            argv += ["--read-group", readGroup]
        }
        argv += [
            "--caller-mode", request.consensusRequest.mode.rawValue,
            "--use-ambiguity", "\(request.consensusRequest.useAmbiguity)",
            "--insertion-policy", request.consensusRequest.insertionPolicy.rawValue,
            "--deletion-policy", request.consensusRequest.deletionPolicy.rawValue,
            "--reference-fill", "never",
            "--output", request.destination.finalURL.path
        ]
        return argv
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
        let filters = request.consensusRequest.filters
        let mapping: [String: ParameterValue] = [physicalPayloadURL.path: .string(finalPayloadURL.path)]
        let explicit: [String: ParameterValue] = [
            "scope": .string(request.region.scope.rawValue),
            "zeroBasedHalfOpen": .string("\(request.region.contig):\(request.region.start)-\(request.region.end)"),
            "oneBasedInclusive": .string("\(request.region.contig):\(request.region.start + 1)-\(request.region.end)"),
            "minimumDepth": .integer(filters.minimumDepth),
            "minimumMapQ": .integer(filters.minimumMapQ),
            "minimumBaseQuality": .integer(filters.minimumBaseQuality),
            "excludedFlags": .integer(Int(filters.excludedFlags)),
            "readGroups": .array(filters.readGroups.sorted().map(ParameterValue.string)),
            "callerMode": .string(request.consensusRequest.mode.rawValue),
            "useAmbiguity": .boolean(request.consensusRequest.useAmbiguity),
            "insertionPolicy": .string(request.consensusRequest.insertionPolicy.rawValue),
            "deletionPolicy": .string(request.consensusRequest.deletionPolicy.rawValue)
        ]
        let resolved: [String: ParameterValue] = [
            "lowDepthPolicy": .string("N"),
            "referenceFillPolicy": .string("never"),
            "allLowDepth": .boolean(request.result.allLowDepth),
            "stagingToFinalMapping": .dictionary(mapping),
            "finalProvenancePath": .string(finalProvenanceURL.path)
        ]
        let argv = replayArgv(request)
        let stderr = request.result.executionRecords.compactMap(\.stderr).filter { !$0.isEmpty }.joined(separator: "\n")
        return ProvenanceEnvelope(
            workflowName: "lungfish alignment consensus",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "Lungfish.app",
            toolVersion: WorkflowRun.currentAppVersion,
            tool: .init(name: "Lungfish.app", version: WorkflowRun.currentAppVersion, kind: "app"),
            argv: argv,
            durableReplayArgv: argv,
            options: .init(explicit: explicit, resolvedDefaults: resolved),
            runtimeIdentity: .init(),
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
