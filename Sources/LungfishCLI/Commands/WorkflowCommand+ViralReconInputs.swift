// WorkflowCommand+ViralReconInputs.swift - Build the viralrecon samplesheet from the same inputs the app uses
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `lungfish-cli workflow run nf-core/viralrecon` takes either a finished
// samplesheet (what the app hands it) or the `.lungfishfastq` bundles and
// FASTQ files themselves, in which case it builds the samplesheet the app
// would have built (ViralReconInputResolver + ViralReconSamplesheetBuilder).
// Either way the Illumina rows are read back into samples so the read
// pairing decisions (ViralReconReadPairing) are made from the same data in
// both entry points.

import Foundation
import LungfishIO
import LungfishWorkflow

enum ViralReconCLIInputs {
    struct Resolved: Sendable {
        /// The samplesheet the run records as its input.
        let samplesheetURL: URL
        /// Illumina rows as samples, for the read pairing step; nil on Nanopore.
        let illuminaSamples: [ViralReconSample]?
        let platform: ViralReconPlatform?
    }

    enum InputError: LocalizedError, Equatable {
        case mixedSamplesheetAndReads
        case platformMismatch(requested: String, detected: ViralReconPlatform)
        case unresolvedInput(URL, reason: String)

        var errorDescription: String? {
            switch self {
            case .mixedSamplesheetAndReads:
                return "Pass either one --input samplesheet.csv or one or more --input FASTQ bundles, not both."
            case .platformMismatch(let requested, let detected):
                return "--param platform=\(requested) contradicts the reads, which are \(detected.rawValue)."
            case .unresolvedInput(let url, let reason):
                return "Cannot use \(url.path) as a viralrecon input: \(reason)"
            }
        }
    }

    static func isSamplesheet(_ url: URL) -> Bool {
        ["csv", "tsv"].contains(url.pathExtension.lowercased())
    }

    /// Resolves the caller's inputs into a samplesheet and, for Illumina,
    /// the samples behind its rows.
    ///
    /// Bundle inputs write the samplesheet (and the Nanopore `fastq_pass`
    /// staging) under the run bundle's `inputs/` directory, and set the
    /// `platform` parameter from the reads when the caller did not.
    static func resolve(
        inputURLs: [URL],
        runBundleURL: URL,
        params: inout [String: String]
    ) throws -> Resolved {
        let samplesheets = inputURLs.filter(isSamplesheet)
        if !samplesheets.isEmpty {
            guard samplesheets.count == inputURLs.count, inputURLs.count == 1,
                  let samplesheetURL = samplesheets.first else {
                throw InputError.mixedSamplesheetAndReads
            }
            let platform = params["platform"].flatMap(ViralReconPlatform.init(rawValue:))
            let illuminaSamples: [ViralReconSample]? = platform == .nanopore
                ? nil
                : try ViralReconReadPairing.parseIlluminaSamplesheet(at: samplesheetURL)
            return Resolved(samplesheetURL: samplesheetURL, illuminaSamples: illuminaSamples, platform: platform)
        }

        let resolvedInputs: [ViralReconResolvedInput]
        do {
            resolvedInputs = try ViralReconInputResolver.resolveInputs(from: inputURLs)
        } catch let error as ViralReconInputResolver.ResolveError {
            throw InputError.unresolvedInput(inputURLs[0], reason: describe(error))
        }
        let samples = try ViralReconInputResolver.makeSamples(from: resolvedInputs)
        guard let platform = resolvedInputs.first?.platform else {
            throw InputError.unresolvedInput(inputURLs[0], reason: "no reads were resolved")
        }
        if let requested = params["platform"], requested != platform.rawValue {
            throw InputError.platformMismatch(requested: requested, detected: platform)
        }
        params["platform"] = platform.rawValue

        let inputsDirectory = runBundleURL.appendingPathComponent("inputs", isDirectory: true)
        switch platform {
        case .illumina:
            let samplesheetURL = try ViralReconSamplesheetBuilder.writeIlluminaSamplesheet(
                samples: samples,
                in: inputsDirectory
            )
            return Resolved(samplesheetURL: samplesheetURL, illuminaSamples: samples, platform: platform)
        case .nanopore:
            let staged = try ViralReconSamplesheetBuilder.stageNanoporeInputs(samples: samples, in: inputsDirectory)
            params["fastq_dir"] = staged.fastqPassDirectory.path
            if params["sequencing_summary"] == nil,
               let summary = samples.compactMap(\.sequencingSummaryURL).first {
                params["sequencing_summary"] = summary.path
            }
            return Resolved(samplesheetURL: staged.samplesheetURL, illuminaSamples: nil, platform: platform)
        }
    }

    private static func describe(_ error: ViralReconInputResolver.ResolveError) -> String {
        switch error {
        case .noInputs:
            return "no inputs"
        case .noFASTQ(let url):
            return "\(url.lastPathComponent) is not a FASTQ file or .lungfishfastq bundle"
        case .unsupportedPlatform(let url):
            return "the sequencing platform of \(url.lastPathComponent) is not Illumina or Nanopore, or could not be detected"
        case .mixedPlatforms:
            return "the inputs mix sequencing platforms"
        }
    }
}
