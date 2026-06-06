// FASTQDerivativeService+BBTools.swift - BBTools operations
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

extension FASTQDerivativeService {

    // MARK: - BBTools Operations

    struct BBToolResult {
        let toolCommand: String
    }

    /// Builds environment variables required by BBTools shell scripts.
    ///
    /// Result is cached after first call since the managed environment path is stable.
    func bbToolsEnvironment() async -> [String: String] {
        if let cached = cachedBBToolsEnv {
            return cached
        }
        let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let env = CoreToolLocator.bbToolsEnvironment(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            existingPath: existingPath
        )
        cachedBBToolsEnv = env
        return env
    }

    /// Runs bbduk.sh for contaminant/reference-based filtering.
    ///
    /// PhiX mode uses the reference bundled within bbtools. Custom mode requires
    /// a user-provided FASTA file path.
    func runBBDukContaminantFilter(
        sourceFASTQ: URL,
        outputFASTQ: URL,
        mode: FASTQContaminantFilterMode,
        referenceFasta: String?,
        kmerSize: Int,
        hammingDistance: Int,
        sourceBundleURL: URL,
        isInterleaved: Bool = false,
        provenanceCollector: FASTQDerivativeNativeProvenanceCollector? = nil
    ) async throws -> BBToolResult {
        var args = [
            "in=\(sourceFASTQ.path)",
            "out=\(outputFASTQ.path)",
            "k=\(kmerSize)",
            "hdist=\(hammingDistance)",
        ]
        if isInterleaved {
            args.append("interleaved=t")
        }

        switch mode {
        case .phix:
            guard let phixReference = CoreToolLocator.bbToolsPhiXReferenceURL(
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            ) else {
                throw FASTQDerivativeError.invalidOperation(
                    "PhiX reference not found in managed BBTools resources: \(CoreToolLocator.bbToolsPhiXReferenceFileName)"
                )
            }
            args.append("ref=\(phixReference.path)")
        case .custom:
            guard let refPath = referenceFasta else {
                throw FASTQDerivativeError.invalidOperation("Custom contaminant filter requires a reference FASTA path")
            }
            // Resolve relative to bundle or treat as absolute
            let refURL: URL
            if refPath.hasPrefix("/") {
                refURL = URL(fileURLWithPath: refPath)
            } else {
                refURL = sourceBundleURL.appendingPathComponent(refPath)
            }
            guard FileManager.default.fileExists(atPath: refURL.path) else {
                throw FASTQDerivativeError.invalidOperation("Reference FASTA not found: \(refURL.path)")
            }
            args.append("ref=\(refURL.path)")
        }

        let env = await bbToolsEnvironment()
        let result = try await runNativeTool(
            .bbduk,
            arguments: args,
            environment: env,
            timeout: 1800,
            provenanceCollector: provenanceCollector
        )
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("bbduk contaminant filter failed: \(result.stderr)")
        }
        return BBToolResult(toolCommand: "bbduk.sh \(args.joined(separator: " "))")
    }

    /// Runs bbmerge.sh to merge overlapping paired-end reads.
    ///
    /// Requires interleaved input. bbmerge emits merged reads plus a single
    /// interleaved unmerged stream, which we then split back into R1/R2 files.
    func runBBMerge(
        sourceFASTQ: URL,
        outputBundleURL: URL,
        strictness: FASTQMergeStrictness,
        minOverlap: Int,
        countDuplicateMergedReads: Bool = true,
        provenanceCollector: FASTQDerivativeNativeProvenanceCollector? = nil
    ) async throws -> (BBToolResult, ReadClassification) {
        let mergedURL = outputBundleURL.appendingPathComponent("merged.fastq")
        let countedMergedURL = outputBundleURL.appendingPathComponent("merged.counted.fastq")
        let unmergedInterleavedURL = outputBundleURL.appendingPathComponent("unmerged.fastq")
        let unmergedR1URL = outputBundleURL.appendingPathComponent("unmerged_R1.fastq")
        let unmergedR2URL = outputBundleURL.appendingPathComponent("unmerged_R2.fastq")

        var args = [
            "in=\(sourceFASTQ.path)",
            "out=\(mergedURL.path)",
            "outu=\(unmergedInterleavedURL.path)",
            "minoverlap=\(minOverlap)",
        ]

        if strictness == .strict {
            args.append("strict=t")
        }

        let env = await bbToolsEnvironment()
        let result = try await runNativeTool(
            .bbmerge,
            arguments: args,
            environment: env,
            timeout: 1800,
            provenanceCollector: provenanceCollector
        )
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("bbmerge failed: \(result.stderr)")
        }

        if FileManager.default.fileExists(atPath: unmergedInterleavedURL.path) {
            try await deinterleaveFASTQ(
                source: unmergedInterleavedURL,
                outputR1: unmergedR1URL,
                outputR2: unmergedR2URL,
                provenanceCollector: provenanceCollector
            )
            try? FileManager.default.removeItem(at: unmergedInterleavedURL)
        }

        var mergedCount = 0
        var countedMergedSummary: CountedFASTQMaterializationResult?
        if FileManager.default.fileExists(atPath: mergedURL.path) {
            if countDuplicateMergedReads {
                let summary = try await CountedFASTQMaterializer().materialize(
                    inputs: [mergedURL],
                    outputURL: countedMergedURL,
                    normalization: .uppercase
                )
                try? FileManager.default.removeItem(at: mergedURL)
                try FileManager.default.moveItem(at: countedMergedURL, to: mergedURL)
                countedMergedSummary = summary
                mergedCount = summary.totalReadCount
            } else {
                mergedCount = try countFASTQReads(at: mergedURL)
            }
        }
        let r1Count =
            FileManager.default.fileExists(atPath: unmergedR1URL.path)
            ? try countFASTQReads(at: unmergedR1URL)
            : 0
        let r2Count =
            FileManager.default.fileExists(atPath: unmergedR2URL.path)
            ? try countFASTQReads(at: unmergedR2URL)
            : 0

        // Remove empty output files
        var files: [ReadClassification.FileEntry] = []
        if r1Count > 0 {
            files.append(.init(filename: "unmerged_R1.fastq", role: .pairedR1, readCount: r1Count))
        } else {
            try? FileManager.default.removeItem(at: unmergedR1URL)
        }
        if r2Count > 0 {
            files.append(.init(filename: "unmerged_R2.fastq", role: .pairedR2, readCount: r2Count))
        } else {
            try? FileManager.default.removeItem(at: unmergedR2URL)
        }
        if mergedCount > 0 {
            files.append(.init(filename: "merged.fastq", role: .merged, readCount: mergedCount))
        } else {
            try? FileManager.default.removeItem(at: mergedURL)
        }

        let classification = ReadClassification(files: files)
        return (
            BBToolResult(
                toolCommand: "bbmerge.sh \(args.joined(separator: " ")); reformat.sh out1=unmerged_R1.fastq out2=unmerged_R2.fastq"
                    + (countDuplicateMergedReads
                       ? "; lungfish counted-fastq merged.fastq duplicateCountEncoding=size=N uniqueMergedRecords=\(countedMergedSummary?.uniqueSequenceCount ?? 0)"
                       : "")
            ),
            classification
        )
    }

    /// Runs repair.sh to fix desynchronized paired-end FASTQ files.
    ///
    /// Reads an interleaved FASTQ and outputs repaired R1/R2 pairs
    /// plus singletons (reads with no mate) as separate files.
    func runBBRepair(
        sourceFASTQ: URL,
        outputBundleURL: URL,
        provenanceCollector: FASTQDerivativeNativeProvenanceCollector? = nil
    ) async throws -> (BBToolResult, ReadClassification) {
        // repair.sh writes repaired pairs to out1/out2, singletons to outs
        let repairedR1URL = outputBundleURL.appendingPathComponent("repaired_R1.fastq")
        let repairedR2URL = outputBundleURL.appendingPathComponent("repaired_R2.fastq")
        let singletonsURL = outputBundleURL.appendingPathComponent("singletons.fastq")

        let args = [
            "in=\(sourceFASTQ.path)",
            "out1=\(repairedR1URL.path)",
            "out2=\(repairedR2URL.path)",
            "outs=\(singletonsURL.path)",
        ]

        let env = await bbToolsEnvironment()
        let result = try await runNativeTool(
            .repair,
            arguments: args,
            environment: env,
            timeout: 1800,
            provenanceCollector: provenanceCollector
        )
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("repair.sh failed: \(result.stderr)")
        }

        // Count reads in each output
        let r1Count = try countFASTQReads(at: repairedR1URL)
        let r2Count = try countFASTQReads(at: repairedR2URL)
        let singletonsCount = try countFASTQReads(at: singletonsURL)

        var files: [ReadClassification.FileEntry] = []
        if r1Count > 0 {
            files.append(.init(filename: "repaired_R1.fastq", role: .pairedR1, readCount: r1Count))
        } else {
            try? FileManager.default.removeItem(at: repairedR1URL)
        }
        if r2Count > 0 {
            files.append(.init(filename: "repaired_R2.fastq", role: .pairedR2, readCount: r2Count))
        } else {
            try? FileManager.default.removeItem(at: repairedR2URL)
        }
        if singletonsCount > 0 {
            files.append(.init(filename: "singletons.fastq", role: .unpaired, readCount: singletonsCount))
        } else {
            try? FileManager.default.removeItem(at: singletonsURL)
        }

        let classification = ReadClassification(files: files)
        return (BBToolResult(toolCommand: "repair.sh \(args.joined(separator: " "))"), classification)
    }

    /// Runs cutadapt for PCR primer trimming.
    func runCutadaptPrimerTrim(
        sourceFASTQ: URL,
        outputFASTQ: URL,
        configuration: FASTQPrimerTrimConfiguration,
        sourceBundleURL: URL,
        isInterleaved: Bool = false,
        provenanceCollector: FASTQDerivativeNativeProvenanceCollector? = nil
    ) async throws -> BBToolResult {
        try validatePrimerTrimConfiguration(configuration)
        let primerSpec = try await resolvePrimerTrimSpecification(
            configuration: configuration,
            sourceBundleURL: sourceBundleURL
        )

        var args: [String] = [
            "-e", String(configuration.errorRate),
            "--overlap", String(configuration.minimumOverlap),
            "--action", "trim",
            "--cores", "1",
        ]
        if !configuration.allowIndels {
            args.append("--no-indels")
        }
        if !configuration.keepUntrimmed {
            args.append("--discard-untrimmed")
        }

        switch configuration.readMode {
        case .single:
            if configuration.searchReverseComplement {
                args.append("--revcomp")
            }
            switch configuration.mode {
            case .fivePrime:
                guard let forward = primerSpec.forward else {
                    throw FASTQDerivativeError.invalidOperation("Primer trimming requires a 5' primer sequence")
                }
                args += ["-g", cutadaptFivePrimeAdapter(forward, anchored: configuration.anchored5Prime)]
            case .threePrime:
                guard let forward = primerSpec.forward else {
                    throw FASTQDerivativeError.invalidOperation("Primer trimming requires a 3' primer sequence")
                }
                args += ["-a", cutadaptThreePrimeAdapter(forward, anchored: configuration.anchored3Prime)]
            case .linked:
                guard let forward = primerSpec.forward, let reverse = primerSpec.reverse else {
                    throw FASTQDerivativeError.invalidOperation("Linked primer trimming requires both 5' and 3' primers")
                }
                args += ["-g", cutadaptLinkedAdapter(
                    forward: forward,
                    reverse: reverse,
                    anchored5Prime: configuration.anchored5Prime,
                    anchored3Prime: configuration.anchored3Prime
                )]
            case .paired:
                throw FASTQDerivativeError.invalidOperation("Paired primer mode requires paired/interleaved reads")
            }
            args += ["-o", outputFASTQ.path, sourceFASTQ.path]

        case .paired:
            guard isInterleaved else {
                throw FASTQDerivativeError.invalidOperation("Paired primer trimming currently requires interleaved input")
            }
            guard configuration.mode == .paired else {
                throw FASTQDerivativeError.invalidOperation("Paired read mode supports only paired R1/R2 primer trimming")
            }
            guard let forward = primerSpec.forward, let reverse = primerSpec.reverse else {
                throw FASTQDerivativeError.invalidOperation("Paired primer trimming requires both R1 and R2 primer sequences")
            }
            args.append("--interleaved")
            args += ["--pair-filter", configuration.pairFilter.rawValue]
            args += ["-g", cutadaptFivePrimeAdapter(forward, anchored: configuration.anchored5Prime)]
            args += ["-G", cutadaptFivePrimeAdapter(reverse, anchored: configuration.anchored5Prime)]
            args += ["-o", outputFASTQ.path, sourceFASTQ.path]
        }

        let result = try await runNativeTool(
            .cutadapt,
            arguments: args,
            timeout: 1800,
            provenanceCollector: provenanceCollector
        )
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("cutadapt primer trimming failed: \(result.stderr)")
        }
        return BBToolResult(toolCommand: "cutadapt \(args.joined(separator: " "))")
    }

    func resolvePrimerTrimSpecification(
        configuration: FASTQPrimerTrimConfiguration,
        sourceBundleURL: URL
    ) async throws -> (forward: String?, reverse: String?) {
        switch configuration.source {
        case .literal:
            let forward = configuration.forwardSequence
            let reverse = configuration.reverseSequence
            return (forward, reverse)
        case .reference:
            guard let refPath = configuration.referenceFasta, !refPath.isEmpty else {
                throw FASTQDerivativeError.invalidOperation("Primer trimming requires a reference FASTA path")
            }
            let refURL: URL
            if refPath.hasPrefix("/") {
                refURL = URL(fileURLWithPath: refPath)
            } else {
                refURL = sourceBundleURL.appendingPathComponent(refPath)
            }
            guard FileManager.default.fileExists(atPath: refURL.path) else {
                throw FASTQDerivativeError.invalidOperation("Primer reference FASTA not found: \(refURL.path)")
            }
            let reader = try FASTAReader(url: refURL)
            let sequences = try await reader.readAll()
            guard let first = sequences.first?.asString(), !first.isEmpty else {
                throw FASTQDerivativeError.invalidOperation("Primer reference FASTA did not contain any primer sequences")
            }
            let second = sequences.count > 1 ? sequences[1].asString() : nil
            return (first.uppercased(), second?.uppercased())
        }
    }

    func validatePrimerTrimConfiguration(_ configuration: FASTQPrimerTrimConfiguration) throws {
        guard configuration.minimumOverlap > 0 else {
            throw FASTQDerivativeError.invalidOperation("Primer minimum overlap must be > 0.")
        }
        guard configuration.errorRate >= 0.0, configuration.errorRate <= 1.0 else {
            throw FASTQDerivativeError.invalidOperation("Primer error rate must be between 0.0 and 1.0.")
        }
    }

    func cutadaptFivePrimeAdapter(_ sequence: String, anchored: Bool) -> String {
        anchored ? "^\(sequence)" : sequence
    }

    func cutadaptThreePrimeAdapter(_ sequence: String, anchored: Bool) -> String {
        anchored ? "\(sequence)$" : sequence
    }

    func cutadaptLinkedAdapter(
        forward: String,
        reverse: String,
        anchored5Prime: Bool,
        anchored3Prime: Bool
    ) -> String {
        let left = cutadaptFivePrimeAdapter(forward, anchored: anchored5Prime)
        let right = cutadaptThreePrimeAdapter(reverse, anchored: anchored3Prime)
        return "\(left)...\(right)"
    }

    /// Runs bbduk.sh for k-mer-based primer trimming.
    ///
    /// BBDuk uses exact k-mer matching (with Hamming distance tolerance) to find
    /// primer sequences and trim everything to the left (ktrim=l) or right (ktrim=r).
    /// This matches the Snakemake workflow's approach:
    ///   bbduk.sh ref=primers k=15 mink=11 hdist=1 ktrim=l rcomp=t  (5' trim)
    ///   bbduk.sh ref=primers k=15 mink=11 hdist=1 ktrim=r rcomp=t  (3' trim)
    func runBBDukPrimerTrim(
        sourceFASTQ: URL,
        outputFASTQ: URL,
        configuration: FASTQPrimerTrimConfiguration,
        sourceBundleURL: URL,
        isInterleaved: Bool = false,
        provenanceCollector: FASTQDerivativeNativeProvenanceCollector? = nil
    ) async throws -> BBToolResult {
        // Resolve primer reference
        let refPath: String
        switch configuration.source {
        case .reference:
            guard let rp = configuration.referenceFasta, !rp.isEmpty else {
                throw FASTQDerivativeError.invalidOperation("BBDuk primer trim requires a reference FASTA path")
            }
            if rp.hasPrefix("/") {
                refPath = rp
            } else {
                refPath = sourceBundleURL.appendingPathComponent(rp).path
            }
            guard FileManager.default.fileExists(atPath: refPath) else {
                throw FASTQDerivativeError.invalidOperation("Primer reference FASTA not found: \(refPath)")
            }
        case .literal:
            // Write literal sequences to a temp FASTA for bbduk
            let tmpDir = try ProjectTempDirectory.createFromContext(
                prefix: "bbduk-primer-",
                contextURL: sourceBundleURL
            )
            let tmpFasta = tmpDir.appendingPathComponent("primers.fasta")
            var fastaContent = ""
            if let fwd = configuration.forwardSequence {
                fastaContent += ">forward_primer\n\(fwd)\n"
            }
            if let rev = configuration.reverseSequence {
                fastaContent += ">reverse_primer\n\(rev)\n"
            }
            guard !fastaContent.isEmpty else {
                throw FASTQDerivativeError.invalidOperation("BBDuk primer trim requires at least one primer sequence")
            }
            try fastaContent.write(to: tmpFasta, atomically: true, encoding: .utf8)
            refPath = tmpFasta.path
        }

        var args = [
            "in=\(sourceFASTQ.path)",
            "out=\(outputFASTQ.path)",
            "ref=\(refPath)",
            "k=\(configuration.kmerSize)",
            "mink=\(configuration.minKmer)",
            "hdist=\(configuration.hammingDistance)",
            "ktrim=\(configuration.ktrimDirection == .left ? "l" : "r")",
            "rcomp=\(configuration.searchReverseComplement ? "t" : "f")",
        ]

        if isInterleaved {
            args.append("interleaved=t")
        }

        let env = await bbToolsEnvironment()
        let result = try await runNativeTool(
            .bbduk,
            arguments: args,
            environment: env,
            timeout: 1800,
            provenanceCollector: provenanceCollector
        )
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("bbduk primer trim failed: \(result.stderr)")
        }
        return BBToolResult(toolCommand: "bbduk.sh \(args.joined(separator: " "))")
    }

    /// Runs cutadapt for adapter presence filtering (no trimming).
    ///
    /// Uses `--action=none` to pass reads through without modification and
    /// `--discard-untrimmed` (or `--discard-trimmed`) to filter by adapter presence.
    /// This matches the Snakemake workflow's ONT barcode filtering:
    ///   cutadapt -g "BARCODE;min_overlap=16" --action=none --discard-untrimmed -e 0.15
    func runCutadaptAdapterPresenceFilter(
        sourceFASTQ: URL,
        outputFASTQ: URL,
        sequence: String?,
        fastaPath: String?,
        searchEnd: FASTQAdapterSearchEnd,
        minOverlap: Int,
        errorRate: Double,
        keepMatched: Bool,
        searchReverseComplement: Bool = false,
        sourceBundleURL: URL,
        isInterleaved: Bool = false,
        provenanceCollector: FASTQDerivativeNativeProvenanceCollector? = nil
    ) async throws -> BBToolResult {
        var args: [String] = [
            "-e", String(errorRate),
            "--overlap", String(minOverlap),
            "--action", "none",
            "--cores", "1",
        ]

        if isInterleaved {
            args.append("--interleaved")
        }

        // Keep matched reads = discard untrimmed; Discard matched = discard trimmed
        if keepMatched {
            args.append("--discard-untrimmed")
        } else {
            args.append("--discard-trimmed")
        }

        // Build adapter specification.
        // When searching reverse complement: if the original adapter is at the 5' end,
        // reads in the opposite orientation will carry its revcomp at the 3' end, and vice versa.
        let adapterFlag = searchEnd == .fivePrime ? "-g" : "-a"
        let oppositeFlag = searchEnd == .fivePrime ? "-a" : "-g"

        if let seq = sequence, !seq.isEmpty {
            args += [adapterFlag, seq]
            if searchReverseComplement {
                args += [oppositeFlag, PlatformAdapters.reverseComplement(seq)]
            }
        } else if let fp = fastaPath, !fp.isEmpty {
            let resolvedPath: String
            if fp.hasPrefix("/") {
                resolvedPath = fp
            } else {
                resolvedPath = sourceBundleURL.appendingPathComponent(fp).path
            }
            guard FileManager.default.fileExists(atPath: resolvedPath) else {
                throw FASTQDerivativeError.invalidOperation("Adapter FASTA not found: \(resolvedPath)")
            }
            args += [adapterFlag, "file:\(resolvedPath)"]
        } else {
            throw FASTQDerivativeError.invalidOperation("Adapter presence filter requires a sequence or FASTA file")
        }

        args += ["-o", outputFASTQ.path, sourceFASTQ.path]

        let result = try await runNativeTool(
            .cutadapt,
            arguments: args,
            timeout: 1800,
            provenanceCollector: provenanceCollector
        )
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("cutadapt adapter presence filter failed: \(result.stderr)")
        }
        return BBToolResult(toolCommand: "cutadapt \(args.joined(separator: " "))")
    }

    /// Runs tadpole.sh for k-mer-based error correction.
    func runTadpole(
        sourceFASTQ: URL,
        outputFASTQ: URL,
        kmerSize: Int,
        isInterleaved: Bool = false,
        provenanceCollector: FASTQDerivativeNativeProvenanceCollector? = nil
    ) async throws -> BBToolResult {
        var args = [
            "in=\(sourceFASTQ.path)",
            "out=\(outputFASTQ.path)",
            "mode=correct",
            "ecc=t",
            "k=\(kmerSize)",
        ]
        if isInterleaved {
            args.append("interleaved=t")
        }

        let env = await bbToolsEnvironment()
        let result = try await runNativeTool(
            .tadpole,
            arguments: args,
            environment: env,
            timeout: 1800,
            provenanceCollector: provenanceCollector
        )
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("tadpole error correction failed: \(result.stderr)")
        }
        return BBToolResult(toolCommand: "tadpole.sh \(args.joined(separator: " "))")
    }

    /// Runs reformat.sh for interleaving or deinterleaving paired-end reads.
    func runReformat(
        sourceFASTQ: URL,
        outputFASTQ: URL,
        direction: FASTQInterleaveDirection,
        sourceBundleURL: URL,
        provenanceCollector: FASTQDerivativeNativeProvenanceCollector? = nil
    ) async throws -> BBToolResult {
        var args: [String]

        switch direction {
        case .interleave:
            // Interleave requires a fullPaired source bundle — source has already been
            // materialized as interleaved by materializeDatasetFASTQ, so this is a no-op copy.
            // However, if the user wants to interleave from a fullPaired bundle, the
            // materialization already interleaves via reformat.sh. We just pass through.
            guard let pairedURLs = FASTQBundle.pairedFASTQURLs(forDerivedBundle: sourceBundleURL) else {
                throw FASTQDerivativeError.invalidOperation(
                    "Interleave requires a deinterleaved (paired R1/R2) input bundle."
                )
            }
            args = [
                "in1=\(pairedURLs.r1.path)",
                "in2=\(pairedURLs.r2.path)",
                "out=\(outputFASTQ.path)",
            ]

        case .deinterleave:
            guard isInterleavedBundle(sourceBundleURL) else {
                throw FASTQDerivativeError.invalidOperation(
                    "Deinterleave requires interleaved paired-end input. This dataset is not interleaved."
                )
            }
            // Deinterleave into the output file (will be split into R1/R2 in createDerivative)
            // For the transformation step, we just copy through; the actual split happens
            // when creating the bundle payload.
            try FileManager.default.copyItem(at: sourceFASTQ, to: outputFASTQ)
            return BBToolResult(toolCommand: "reformat.sh in=\(sourceFASTQ.path) out1=R1.fastq out2=R2.fastq")
        }

        let env = await bbToolsEnvironment()
        let result = try await runNativeTool(
            .reformat,
            arguments: args,
            environment: env,
            timeout: 1800,
            provenanceCollector: provenanceCollector
        )
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("reformat.sh failed: \(result.stderr)")
        }
        return BBToolResult(toolCommand: "reformat.sh \(args.joined(separator: " "))")
    }

    /// Concatenates multiple FASTQ files into one output file.
    func concatenateFASTQFiles(_ inputFiles: [URL], to outputURL: URL) throws {
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }

        for inputURL in inputFiles {
            guard FileManager.default.fileExists(atPath: inputURL.path) else { continue }
            let inputHandle = try FileHandle(forReadingFrom: inputURL)
            defer { try? inputHandle.close() }

            // Stream in chunks to avoid loading entire files into memory
            while true {
                let chunk = inputHandle.readData(ofLength: 1_048_576) // 1 MB chunks
                if chunk.isEmpty { break }
                outputHandle.write(chunk)
            }
        }
    }

    /// Counts FASTQ reads in a file by counting lines and dividing by 4.
    func countFASTQReads(at url: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var lineCount = 0
        while true {
            let chunk = handle.readData(ofLength: 1_048_576)
            if chunk.isEmpty { break }
            lineCount += chunk.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        }
        return lineCount / 4
    }

}
