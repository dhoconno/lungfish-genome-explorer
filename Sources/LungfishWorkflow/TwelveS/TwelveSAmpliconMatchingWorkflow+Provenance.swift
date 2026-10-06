// TwelveSAmpliconMatchingWorkflow+Provenance.swift - The provenance a 12S matching run writes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Moved from TwelveSAmpliconMatchingWorkflow.swift in Phase 2.1 lane L4,
// so the workflow file stays within its file-size baseline.

import Foundation
import CryptoKit
import LungfishCore
import LungfishIO

extension TwelveSAmpliconMatchingWorkflow {

    func writeProvenance(
        config: TwelveSAmpliconMatchingConfiguration,
        bundleURL: URL,
        resolvedInputs: [ResolvedInput],
        readSetSteps: [ProvenanceStep],
        classified: ClassifiedReads,
        chimeraResult: TwelveSChimeraReviewResult,
        scratchDirectory: URL,
        startedAt: Date,
        completedAt: Date
    ) throws {
        let argv: [String]
        if config.argv.isEmpty {
            argv = replayArgv(for: config)
        } else {
            argv = config.argv
        }
        let referenceOptionURL = config.referenceBundleURL ?? config.referenceFASTA
        var explicitOptions: [String: ParameterValue] = [
            "inputs": .array(config.inputFASTQs.map { .file($0) }),
            "reference": .file(referenceOptionURL),
            "outputDirectory": .file(config.outputDirectory),
            "outputName": .string(config.outputName),
            "minimumSoftClipBases": .integer(config.minimumSoftClipBases),
            "maximumIndelBases": .integer(config.maximumIndelBases),
            "matchingMode": .string(config.matchingMode.rawValue),
            "threads": .integer(config.threads),
            "runChimeraReview": .boolean(config.runChimeraReview),
            "forceOverwrite": .boolean(config.forceOverwrite),
            "ambiguityResolution": .string(config.ambiguityResolution.cliValue),
        ]
        var resolvedOptions: [String: ParameterValue] = [
            "minimumSoftClipBases": .integer(config.minimumSoftClipBases),
            "maximumIndelBases": .integer(config.maximumIndelBases),
            "matchingMode": .string(config.matchingMode.rawValue),
            "threads": .integer(config.threads),
            "runChimeraReview": .boolean(config.runChimeraReview),
            "forceOverwrite": .boolean(config.forceOverwrite),
            "ambiguityResolution": .string(config.ambiguityResolution.cliValue),
        ]
        // A run of merged or single reads only records nothing new, so earlier
        // runs compare byte for byte. A run that read pairs records how each
        // input was read and what became of its fragments.
        if classified.sawPairs || resolvedInputs.contains(where: { !$0.plan.recordsNothingNew }) {
            resolvedOptions["readSetPlans"] = .array(resolvedInputs.map { input in
                var plan: [String: ParameterValue] = [
                    "input": .file(input.sourceURL),
                    "capability": .string(input.plan.capability.provenanceName),
                    "sourceLayout": .string(input.plan.sourceLayout.rawValue),
                    "layoutReason": .string(input.plan.layoutReason),
                    "steps": .integer(input.plan.steps.count),
                ]
                if let recorded = input.plan.provenanceParameters["readSetPlan"] {
                    plan["readSetPlan"] = recorded
                }
                return .dictionary(plan)
            })
            resolvedOptions["fragmentCounts"] = .dictionary(Dictionary(
                uniqueKeysWithValues: classified.sampleOrder.map { sampleID in
                    let byReason = classified.discordantPairsByReasonBySample[sampleID, default: [:]]
                    return (sampleID, ParameterValue.dictionary([
                        "inputFragments": .integer(classified.inputReadsBySample[sampleID, default: 0]),
                        "singleReadFragments": .integer(classified.singleReadFragmentsBySample[sampleID, default: 0]),
                        "pairedFragments": .integer(classified.pairedFragmentsBySample[sampleID, default: 0]),
                        "discordantPairs": .integer(classified.discordantPairsBySample[sampleID, default: 0]),
                        "discordantPairsByReason": .dictionary(Dictionary(
                            uniqueKeysWithValues: byReason.filter { $0.value > 0 }.map { ($0.key.rawValue, ParameterValue.integer($0.value)) }
                        )),
                    ]))
                }
            ))
        }
        if let referenceBundleURL = config.referenceBundleURL {
            explicitOptions["referenceBundle"] = .file(referenceBundleURL)
            resolvedOptions["referenceBundle"] = .file(referenceBundleURL)
            resolvedOptions["referenceFASTA"] = .file(config.referenceFASTA)
        }
        if let referenceMetadata = config.referenceMetadata {
            explicitOptions["referenceMetadata"] = .file(referenceMetadata)
            resolvedOptions["referenceMetadata"] = .file(referenceMetadata)
        }
        if let sampleMetadata = config.sampleMetadata {
            explicitOptions["sampleMetadata"] = .file(sampleMetadata)
            resolvedOptions["sampleMetadata"] = .file(sampleMetadata)
        }
        let fastqMetadataURLs = Self.fastqMetadataInputURLs(for: config.inputFASTQs)
        if !fastqMetadataURLs.isEmpty {
            resolvedOptions["fastqMetadataInputs"] = .array(fastqMetadataURLs.map { .file($0) })
        }
        var builder = ProvenanceRunBuilder(
            workflowName: "lungfish fastq 12s-match",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: CLICommandIdentity.executableName,
            toolVersion: WorkflowRun.currentAppVersion
        )
        .argv(argv)
        .durableReplayArgv(argv)
        .reproducibleCommand(Self.commandLine(from: argv))
        .options(
            explicit: explicitOptions,
            defaults: [
                "minimumSoftClipBases": .integer(1),
                "maximumIndelBases": .integer(3),
                "matchingMode": .string(TwelveSAmpliconMatchingMode.illuminaExact.rawValue),
                "threads": .integer(1),
                "runChimeraReview": .boolean(true),
                "forceOverwrite": .boolean(false),
                "ambiguityResolution": .string(TwelveSAbundanceReassigner.ResolutionPolicy.strictCLIValue),
            ],
            resolved: resolvedOptions
        )
        .runtime(ProvenanceRuntimeIdentity(user: WorkflowRun.currentUser))
        for step in readSetSteps {
            builder = builder.step(step)
        }

        let inputDescriptors = try config.inputFASTQs.map { input in
            if FASTQBundle.isBundleURL(input) {
                return try Self.directoryDescriptor(url: input, format: .unknown, role: .input)
            }
            return try ProvenanceFileDescriptor.file(url: input, format: .fastq, role: .input)
        }
        let referenceDescriptor = try ProvenanceFileDescriptor.file(
            url: config.referenceFASTA,
            format: .fasta,
            role: .reference
        )
        var matchingStepInputs = inputDescriptors
        if let referenceBundleURL = config.referenceBundleURL {
            matchingStepInputs.append(
                try Self.directoryDescriptor(url: referenceBundleURL, format: .unknown, role: .reference)
            )
        }
        matchingStepInputs.append(referenceDescriptor)
        if let referenceMetadata = config.referenceMetadata {
            matchingStepInputs.append(
                try ProvenanceFileDescriptor.file(url: referenceMetadata, format: .text, role: .reference)
            )
        }
        if let sampleMetadata = config.sampleMetadata {
            matchingStepInputs.append(
                try ProvenanceFileDescriptor.file(url: sampleMetadata, format: .text, role: .input)
            )
        }
        for metadataURL in fastqMetadataURLs {
            matchingStepInputs.append(
                try ProvenanceFileDescriptor.file(url: metadataURL, format: .text, role: .input)
            )
        }

        let payloadDescriptors = try bundlePayloadURLs(in: bundleURL).map {
            try ProvenanceFileDescriptor.file(url: $0, format: Self.fileFormat(for: $0), role: .output)
        }
        let matchingStepOutputs = [
            try Self.directoryDescriptor(url: bundleURL, format: .unknown, role: .output)
        ] + payloadDescriptors
        let matchingStep = ProvenanceStep(
            toolName: CLICommandIdentity.executableName,
            toolVersion: WorkflowRun.currentAppVersion,
            argv: argv,
            durableReplayArgv: argv,
            reproducibleCommand: Self.commandLine(from: argv),
            inputs: matchingStepInputs,
            outputs: matchingStepOutputs,
            exitStatus: 0,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            startedAt: startedAt,
            completedAt: completedAt
        )
        builder = builder.step(matchingStep)

        if !chimeraResult.argv.isEmpty {
            let step = ProvenanceStep(
                toolName: NativeTool.vsearch.executableName,
                toolVersion: chimeraResult.toolVersion ?? "unknown",
                argv: chimeraResult.argv,
                durableReplayArgv: chimeraResult.argv,
                reproducibleCommand: Self.commandLine(from: chimeraResult.argv),
                inputs: try chimeraResult.inputs.map {
                    try ProvenanceFileDescriptor.file(url: $0, format: Self.fileFormat(for: $0), role: .input)
                },
                outputs: try chimeraResult.outputs.map {
                    try ProvenanceFileDescriptor.file(url: $0, format: Self.fileFormat(for: $0), role: .output)
                },
                exitStatus: Int(chimeraResult.exitStatus),
                wallTimeSeconds: zip(chimeraResult.startedAt, chimeraResult.completedAt).map { $1.timeIntervalSince($0) },
                stderr: chimeraResult.stderr,
                startedAt: chimeraResult.startedAt,
                completedAt: chimeraResult.completedAt
            )
            builder = builder.step(step)
        }

        // The read-set steps keep their records of the files they wrote. The
        // run-level roll-up leaves those files out, since the scratch folder
        // is removed when the run ends.
        let envelope = Self.droppingScratchFiles(
            from: try builder.complete(
                exitStatus: 0,
                stderr: chimeraResult.stderr,
                startedAt: startedAt,
                endedAt: completedAt
            ),
            under: scratchDirectory
        )
        try ProvenanceWriter().write(envelope, to: bundleURL)
    }

    static func fastqMetadataInputURLs(for inputURLs: [URL]) -> [URL] {
        var seen = Set<String>()
        var urls: [URL] = []
        for inputURL in inputURLs where FASTQBundle.isBundleURL(inputURL) {
            let candidate: URL?
            if FASTQBundleCSVMetadata.exists(in: inputURL) {
                candidate = FASTQBundleCSVMetadata.metadataURL(in: inputURL)
            } else {
                let folderURL = inputURL.deletingLastPathComponent()
                candidate = FASTQFolderMetadata.exists(in: folderURL)
                    ? FASTQFolderMetadata.metadataURL(in: folderURL)
                    : nil
            }
            guard let candidate = candidate?.standardizedFileURL,
                  FileManager.default.fileExists(atPath: candidate.path),
                  seen.insert(candidate.path).inserted else {
                continue
            }
            urls.append(candidate)
        }
        return urls
    }

    func replayArgv(for config: TwelveSAmpliconMatchingConfiguration) -> [String] {
        let referenceURL = config.referenceBundleURL ?? config.referenceFASTA
        var argv = [
            CLICommandIdentity.executableName, "fastq", "12s-match",
        ] + config.inputFASTQs.map(\.path) + [
            "--reference", referenceURL.path,
        ]
        if let referenceMetadata = config.referenceMetadata,
           !isBundledReferenceMetadata(referenceMetadata, for: config.referenceBundleURL) {
            argv += ["--reference-metadata", referenceMetadata.path]
        }
        if let sampleMetadata = config.sampleMetadata {
            argv += ["--sample-metadata", sampleMetadata.path]
        }
        argv += [
            "--output-dir", config.outputDirectory.path,
            "--output-name", config.outputName,
        ]
        if config.minimumSoftClipBases != 1 {
            argv += ["--min-soft-clip", String(config.minimumSoftClipBases)]
        }
        if config.maximumIndelBases != 3 {
            argv += ["--max-indels", String(config.maximumIndelBases)]
        }
        argv += ["--matching-mode", config.matchingMode.rawValue]
        if config.threads != 1 {
            argv += ["--threads", String(config.threads)]
        }
        if !config.runChimeraReview {
            argv.append("--no-chimera-review")
        }
        if config.ambiguityResolution != .anyNonzeroLead {
            argv += ["--ambiguity-resolution", config.ambiguityResolution.cliValue]
        }
        if config.forceOverwrite {
            argv.append("--force")
        }
        return argv
    }

    func isBundledReferenceMetadata(_ metadataURL: URL, for bundleURL: URL?) -> Bool {
        guard let bundleURL,
              let bundledURL = TwelveSReferenceBundle.targetMetadataURL(in: bundleURL) else {
            return false
        }
        return metadataURL.standardizedFileURL == bundledURL.standardizedFileURL
    }

    func bundlePayloadURLs(in bundleURL: URL) -> [URL] {
        var urls = [
            TwelveSAmpliconResultBundle.manifestURL(in: bundleURL),
            bundleURL.appendingPathComponent("reference.fa"),
            bundleURL.appendingPathComponent("targets.tsv"),
            bundleURL.appendingPathComponent("target-alternate-matches.tsv"),
            bundleURL.appendingPathComponent("sample-target-counts.tsv"),
            bundleURL.appendingPathComponent("samples.tsv"),
            bundleURL.appendingPathComponent("read-fate.json"),
            bundleURL.appendingPathComponent("unresolved-sequences.tsv"),
            bundleURL.appendingPathComponent("unresolved-sequences.fasta"),
        ]
        let metadataDirectory = bundleURL.appendingPathComponent("metadata", isDirectory: true)
        if let metadataPayloads = try? FileManager.default.contentsOfDirectory(
            at: metadataDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            urls.append(contentsOf: metadataPayloads.filter {
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            })
        }
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func fileFormat(for url: URL) -> FileFormat {
        switch url.pathExtension.lowercased() {
        case "fa", "fasta", "fna":
            return .fasta
        case "fastq", "fq":
            return .fastq
        case "json":
            return .json
        case "tsv", "txt":
            return .text
        default:
            return .unknown
        }
    }

    static func directoryDescriptor(
        url: URL,
        format: FileFormat?,
        role: FileRole
    ) throws -> ProvenanceFileDescriptor {
        let manifest = try ProvenanceFileHasher.directoryManifest(for: url, role: role)
        return ProvenanceFileDescriptor(
            path: url.standardizedFileURL.path,
            checksumSHA256: directoryChecksum(from: manifest),
            fileSize: directorySize(from: manifest),
            format: format,
            role: role
        )
    }

    static func directoryChecksum(from manifest: ProvenanceDirectoryManifest) -> String {
        let canonical = manifest.files
            .sorted { $0.path < $1.path }
            .map { descriptor in
                [
                    descriptor.path,
                    descriptor.checksumSHA256 ?? "",
                    descriptor.fileSize.map(String.init) ?? "0",
                ].joined(separator: "\t")
            }
            .joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func directorySize(from manifest: ProvenanceDirectoryManifest) -> UInt64 {
        manifest.files.reduce(UInt64(0)) { total, descriptor in
            total + (descriptor.fileSize ?? 0)
        }
    }

    static func commandLine(from argv: [String]) -> String {
        argv.map(shellEscape).joined(separator: " ")
    }
}

private func zip<T, U>(_ first: T?, _ second: U?) -> (T, U)? {
    guard let first, let second else { return nil }
    return (first, second)
}
