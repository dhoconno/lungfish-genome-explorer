// ViralReconReadPairing+Bundles.swift - Plan a samplesheet row that names a bundle, and stage its reads as gzip rows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A paired derivative, a merge or repair derivative, a virtual derivative
// and a chunked root hold their reads in more than one file, or in no file
// at all until they are materialized. Their samplesheet row names the bundle
// the user chose, so the recorded command plans it again. Inside the run
// ReadSetResolver plans the bundle under the viralrecon.illumina capability
// (docs/contracts/READ-PAIRING.md, Phase 1.5 lane A6b), and the reads are
// staged as the gzip files viralrecon reads.

import Foundation
import LungfishIO

extension ViralReconReadPairingDecision {

    /// How the run staged a row that names a bundle.
    public struct BundleStaging: Codable, Sendable, Equatable {
        /// The gzip files viralrecon reads, in samplesheet order.
        public let stagedFASTQURLs: [URL]
        /// The capability the plan used.
        public let capability: String
        /// Where the plan found the reads (``ReadSetSourceLayout``).
        public let sourceLayout: String
        /// Whether a virtual bundle was materialized first.
        public let materialized: Bool
        /// The reads written to a single-end row, nil for a paired row.
        public let singleReadCount: Int?
        /// Why the mates run as single reads, nil when they run as pairs.
        public let singleReadReason: String?

        public init(
            stagedFASTQURLs: [URL],
            capability: String,
            sourceLayout: String,
            materialized: Bool,
            singleReadCount: Int?,
            singleReadReason: String?
        ) {
            self.stagedFASTQURLs = stagedFASTQURLs
            self.capability = capability
            self.sourceLayout = sourceLayout
            self.materialized = materialized
            self.singleReadCount = singleReadCount
            self.singleReadReason = singleReadReason
        }

        /// The staging as the run's provenance records it.
        var provenanceValue: ParameterValue {
            var fields: [String: ParameterValue] = [
                "stagedFASTQs": .array(stagedFASTQURLs.map { .file($0) }),
                "capability": .string(capability),
                "sourceLayout": .string(sourceLayout),
                "materialized": .boolean(materialized),
            ]
            if let singleReadCount { fields["singleReads"] = .integer(singleReadCount) }
            if let singleReadReason { fields["singleReadReason"] = .string(singleReadReason) }
            return .dictionary(fields)
        }
    }
}

extension ViralReconReadPairing {

    /// Whether `urls` is one `.lungfishfastq` bundle, which a samplesheet
    /// row names for the run to plan.
    public static func namesBundle(_ urls: [URL]) -> Bool {
        urls.count == 1 && FASTQBundle.isBundleURL(urls[0])
    }

    /// Whether the run plans `bundleURL` with ``ReadSetResolver``, so the
    /// samplesheet names the bundle itself: a paired, mixed or virtual
    /// derivative, or a root of more than one file. A root of one file and a
    /// `full` derivative keep naming their one file, so their rows stay as
    /// they were.
    public static func plansBundle(_ bundleURL: URL) -> Bool {
        guard FASTQBundle.isBundleURL(bundleURL) else { return false }
        guard let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) else {
            return FASTQBundle.isMultiFileBundle(bundleURL)
                && (FASTQBundle.resolveAllFASTQURLs(for: bundleURL)?.count ?? 0) > 1
        }
        switch manifest.payload {
        case .full, .fullFASTA, .demuxGroup:
            return false
        case .fullPaired, .fullMixed, .subset, .trim, .orientMap, .demuxedVirtual:
            return true
        }
    }

    /// Whether `url` is a virtual derivative, whose reads exist only as a
    /// list or table over the bundle it derives from.
    static func isVirtualBundle(_ url: URL) -> Bool {
        switch FASTQBundle.loadDerivedManifest(in: url)?.payload {
        case .subset?, .trim?, .orientMap?, .demuxedVirtual?:
            return true
        default:
            return false
        }
    }

    /// The decision for a row that names `bundleURL` before the run plans
    /// it, read from the bundle's manifest alone, so the wizard and a
    /// prepared run can say what to expect without reading the reads. The
    /// plan the run makes replaces it.
    static func expectedDecision(forBundle bundleURL: URL, sampleName: String) -> ViralReconReadPairingDecision {
        let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL)
        let expected: (layout: FASTQInputLayout, reason: String)
        switch manifest?.payload {
        case .fullPaired?:
            expected = (.pairedFiles, "The paired derivative names its R1 and R2 files.")
        case .fullMixed(let roles)?:
            let holdsPairs = roles.files.contains { $0.role == .pairedR1 }
            let holdsSingles = roles.files.contains { $0.role == .merged || $0.role == .unpaired }
            expected = holdsPairs && holdsSingles
                ? (.mixedMergedAndPairs, "The derivative records read pairs and single reads by role.")
                : (holdsPairs ? .pairedFiles : .singleEnd, "The derivative records its files by role.")
        case nil:
            let platform = ReadSetResolver.recordedPlatform(of: bundleURL)
            let files = FASTQBundle.resolveAllFASTQURLs(for: bundleURL) ?? []
            expected = ReadSetResolver.isKnownShortRead(platform)
                && MatePairFileNaming.matePair(in: files, sequencingPlatform: platform) != nil
                ? (.pairedFiles, "The bundle's two files are named as R1 and R2 of one sample.")
                : (.singleEnd, "The bundle holds \(files.count) files, each read as single reads.")
        case .some:
            if ReadSetResolver.lineageEvidence(of: bundleURL).evidence != nil {
                expected = (.mixedMergedAndPairs, "The virtual derivative comes from read pairs and single reads.")
            } else if manifest?.pairingMode == .interleaved {
                expected = (.strictlyInterleaved, "The virtual derivative comes from interleaved pairs.")
            } else {
                expected = (.singleEnd, "The virtual derivative comes from single reads.")
            }
        }
        return ViralReconReadPairingDecision(
            sampleName: sampleName,
            sourceFASTQURLs: [bundleURL],
            layout: expected.layout,
            handling: handling(for: expected.layout),
            reason: expected.reason + " The run plans the bundle's reads when it starts."
        )
    }

    /// Plans the bundle a row names with ``ReadSetResolver`` under the
    /// `viralrecon.illumina` capability and writes the gzip files
    /// viralrecon reads into `directory`.
    ///
    /// A sample of pairs gives one R1 and R2 row per mate pair. A sample of
    /// single reads, or one that mixes pairs and single reads, gives one
    /// single-end row of every read: R1 records, then R2 records, then the
    /// single reads. The decision then records why the mates run as single
    /// reads. A virtual bundle is materialized first. The files the plan
    /// wrote are removed once the gzip files exist.
    static func stageBundle(
        of sample: ViralReconSample,
        bundleURL: URL,
        into directory: URL,
        materializer: any CLISequenceInputMaterializing & Sendable,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> (sample: ViralReconSample, decision: ViralReconReadPairingDecision) {
        progress?("Planning the reads of \(sample.sampleName) for viralrecon...")
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: directory)
        let planDirectory = directory.appendingPathComponent(".read-set-plan", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: planDirectory) }
            let capability = ReadPairingCapabilityRegistry.capability(for: consumerID) ?? .pairsOnlyWhenAllPaired
            let plan = try await ReadSetResolver(materializationDirectory: planDirectory, materializer: materializer)
                .plan(for: bundleURL, capability: capability, progress: progress)
            let runsPaired = !plan.matePairs.isEmpty && plan.singleReads.isEmpty && plan.mixedStreams.isEmpty
            var staged: [URL] = []
            var pairCount: Int?
            var singleReadCount: Int?
            if runsPaired {
                pairCount = try await stagePairs(plan.matePairs, sampleName: sample.sampleName, into: directory, staged: &staged)
            } else {
                let output = directory.appendingPathComponent("\(directory.lastPathComponent).fastq.gz")
                singleReadCount = try await writeGzipFASTQ(plan.executionURLs, to: output)
                staged = [output]
            }
            let layout: FASTQInputLayout
            if plan.singleReadReason != nil {
                layout = .mixedMergedAndPairs
            } else if let pair = plan.matePairs.first, runsPaired {
                if case .interleaved = pair.files { layout = .strictlyInterleaved } else { layout = .pairedFiles }
            } else {
                layout = .singleEnd
            }
            let decision = ViralReconReadPairingDecision(
                sampleName: sample.sampleName,
                sourceFASTQURLs: [bundleURL],
                layout: layout,
                handling: handling(for: layout),
                reason: plan.layoutReason,
                pairCount: pairCount,
                splitR1URL: runsPaired ? staged.first : nil,
                splitR2URL: runsPaired ? staged.dropFirst().first : nil,
                bundleStaging: ViralReconReadPairingDecision.BundleStaging(
                    stagedFASTQURLs: staged,
                    capability: plan.capability.provenanceName,
                    sourceLayout: plan.sourceLayout.rawValue,
                    materialized: plan.wasMaterialized,
                    singleReadCount: singleReadCount,
                    singleReadReason: plan.singleReadReason
                )
            )
            let stagedSample = ViralReconSample(
                sampleName: sample.sampleName,
                sourceBundleURL: sample.sourceBundleURL,
                fastqURLs: staged,
                barcode: sample.barcode,
                sequencingSummaryURL: sample.sequencingSummaryURL
            )
            return (stagedSample, decision)
        } catch {
            try? fileManager.removeItem(at: directory)
            if error is CancellationError || error is PairingError { throw error }
            throw PairingError.bundleStagingFailed(sampleName: sample.sampleName, reason: error.localizedDescription)
        }
    }

    /// Writes each mate pair as a gzip R1 and R2 file in `directory`,
    /// appends them to `staged` and returns the pairs written.
    private static func stagePairs(
        _ pairs: [ReadSetMatePair],
        sampleName: String,
        into directory: URL,
        staged: inout [URL]
    ) async throws -> Int {
        var written = 0
        for (index, pair) in pairs.enumerated() {
            let name = pairs.count > 1 ? "\(directory.lastPathComponent)-\(index + 1)" : directory.lastPathComponent
            switch pair.files {
            case .separate(let r1, let r2):
                let stagedR1 = directory.appendingPathComponent("\(name)_R1.fastq.gz")
                let stagedR2 = directory.appendingPathComponent("\(name)_R2.fastq.gz")
                let r1Records = try await writeGzipFASTQ([r1], to: stagedR1)
                let r2Records = try await writeGzipFASTQ([r2], to: stagedR2)
                guard r1Records == r2Records else {
                    throw PairingError.bundleStagingFailed(
                        sampleName: sampleName,
                        reason: "its R1 file holds \(r1Records) reads and its R2 file holds \(r2Records)"
                    )
                }
                written += r1Records
                staged += [stagedR1, stagedR2]
            case .interleaved(let url):
                let split = try await splitInterleavedInput(url, into: directory.appendingPathComponent(name, isDirectory: true))
                written += split.counts.r1Records
                staged += [split.r1, split.r2]
            }
        }
        return written
    }

    /// How viralrecon takes a row of `layout`.
    private static func handling(for layout: FASTQInputLayout) -> FASTQReadLayoutHandling {
        switch layout {
        case .pairedFiles: return .asPairs
        case .strictlyInterleaved: return .splitToR1R2
        case .singleEnd, .mixedMergedAndPairs: return .asSingle
        }
    }

    /// Writes every record of `sources`, plain or gzip, one file after
    /// another, into the gzip file `destination` through `/usr/bin/gzip -c`,
    /// and returns the record count. A partial record stops the write and
    /// removes the file.
    static func writeGzipFASTQ(_ sources: [URL], to destination: URL) async throws -> Int {
        let worker = Task.detached(priority: .utility) { () throws -> Int in
            let sink = try GzipFileSink(destination: destination)
            do {
                var records = 0
                for source in sources {
                    try Task.checkCancellation()
                    records += try ReadSetResolver.copyRecords(of: source, to: sink.writeHandle)
                }
                try sink.finish()
                return records
            } catch {
                sink.abort()
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
