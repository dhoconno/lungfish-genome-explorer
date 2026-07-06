// FASTQDerivativeService+FastpTrim.swift - Fastp trim operations
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

extension FASTQDerivativeService {

    // MARK: - Fastp Trim Operations

    struct FastpResult {
        let toolCommand: String
    }

    func runFastpQualityTrim(
        sourceFASTQ: URL,
        outputFASTQ: URL,
        threshold: Int,
        windowSize: Int,
        mode: FASTQQualityTrimMode,
        isInterleaved: Bool = false,
        provenanceCollector: FASTQDerivativeNativeProvenanceCollector? = nil
    ) async throws -> FastpResult {
        // For interleaved PE data, fastp needs separate R1/R2 outputs
        let r1Output: URL
        let r2Output: URL?
        if isInterleaved {
            r1Output = outputFASTQ.deletingLastPathComponent().appendingPathComponent("fastp_R1.fastq")
            r2Output = outputFASTQ.deletingLastPathComponent().appendingPathComponent("fastp_R2.fastq")
        } else {
            r1Output = outputFASTQ
            r2Output = nil
        }

        var args = [
            "-i", sourceFASTQ.path,
            "-o", r1Output.path,
            "-w", String(toolThreadCount),
            "-W", String(windowSize),
            "-M", String(threshold),
            "--disable_adapter_trimming",
            "--disable_quality_filtering",
            "--disable_length_filtering",
            "--json", "/dev/null",
            "--html", "/dev/null",
        ]
        if isInterleaved, let r2 = r2Output {
            args.append("--interleaved_in")
            args += ["--out2", r2.path]
        }

        switch mode {
        case .cutRight: args.append("--cut_right")
        case .cutFront: args.append("--cut_front")
        case .cutTail: args.append("--cut_tail")
        case .cutBoth:
            args.append("--cut_front")
            args.append("--cut_right")
        }

        let result = try await runNativeTool(.fastp, arguments: args, provenanceCollector: provenanceCollector)
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("fastp quality trim failed: \(result.stderr)")
        }

        // Re-interleave R1+R2 into the final output
        if isInterleaved, let r2 = r2Output {
            try await reinterleaveFastpOutput(
                r1: r1Output,
                r2: r2,
                output: outputFASTQ,
                provenanceCollector: provenanceCollector
            )
        }

        return FastpResult(toolCommand: "fastp \(args.joined(separator: " "))")
    }

    func runFastpCombinedTrim(
        sourceFASTQ: URL,
        outputFASTQ: URL,
        threshold: Int,
        windowSize: Int,
        mode: FASTQQualityTrimMode,
        adapterMode: FASTQAdapterMode,
        adapterSequence: String?,
        isInterleaved: Bool = false,
        provenanceCollector: FASTQDerivativeNativeProvenanceCollector? = nil
    ) async throws -> FastpResult {
        let r1Output: URL
        let r2Output: URL?
        if isInterleaved {
            r1Output = outputFASTQ.deletingLastPathComponent().appendingPathComponent("fastp_R1.fastq")
            r2Output = outputFASTQ.deletingLastPathComponent().appendingPathComponent("fastp_R2.fastq")
        } else {
            r1Output = outputFASTQ
            r2Output = nil
        }

        var args = [
            "-i", sourceFASTQ.path,
            "-o", r1Output.path,
            "-w", String(toolThreadCount),
            "-W", String(windowSize),
            "-M", String(threshold),
            "--disable_quality_filtering",
            "--disable_length_filtering",
            "--json", "/dev/null",
            "--html", "/dev/null",
        ]
        if isInterleaved, let r2 = r2Output {
            args.append("--interleaved_in")
            args += ["--out2", r2.path]
        }

        switch adapterMode {
        case .autoDetect:
            break
        case .specified:
            if let adapterSequence {
                args += ["--adapter_sequence", adapterSequence]
            }
        case .fastaFile:
            args.append("--disable_adapter_trimming")
        }

        switch mode {
        case .cutRight: args.append("--cut_right")
        case .cutFront: args.append("--cut_front")
        case .cutTail: args.append("--cut_tail")
        case .cutBoth:
            args.append("--cut_front")
            args.append("--cut_right")
        }

        let result = try await runNativeTool(.fastp, arguments: args, provenanceCollector: provenanceCollector)
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("fastp combined trim failed: \(result.stderr)")
        }

        if isInterleaved, let r2 = r2Output {
            try await reinterleaveFastpOutput(
                r1: r1Output,
                r2: r2,
                output: outputFASTQ,
                provenanceCollector: provenanceCollector
            )
        }

        return FastpResult(toolCommand: "fastp \(args.joined(separator: " "))")
    }

    func runFastpAdapterTrim(
        sourceFASTQ: URL,
        outputFASTQ: URL,
        mode: FASTQAdapterMode,
        sequence: String?,
        sequenceR2: String?,
        fastaFilename: String?,
        sourceBundleURL: URL,
        isInterleaved: Bool = false,
        provenanceCollector: FASTQDerivativeNativeProvenanceCollector? = nil
    ) async throws -> FastpResult {
        let r1Output: URL
        let r2Output: URL?
        if isInterleaved {
            r1Output = outputFASTQ.deletingLastPathComponent().appendingPathComponent("fastp_R1.fastq")
            r2Output = outputFASTQ.deletingLastPathComponent().appendingPathComponent("fastp_R2.fastq")
        } else {
            r1Output = outputFASTQ
            r2Output = nil
        }

        var args = [
            "-i", sourceFASTQ.path,
            "-o", r1Output.path,
            "-w", String(toolThreadCount),
            "--disable_quality_filtering",
            "--disable_length_filtering",
            "--json", "/dev/null",
            "--html", "/dev/null",
        ]
        if isInterleaved, let r2 = r2Output {
            args.append("--interleaved_in")
            args += ["--out2", r2.path]
        }

        switch mode {
        case .autoDetect:
            break // fastp auto-detects by default
        case .specified:
            if let sequence {
                args += ["--adapter_sequence", sequence]
            }
            if let sequenceR2 {
                args += ["--adapter_sequence_r2", sequenceR2]
            }
        case .fastaFile:
            if let fastaFilename,
               let fastaURL = try? FASTQBundle.validatedBundleMemberURL(
                for: fastaFilename,
                in: sourceBundleURL,
                field: "adapterTrim.fastaFilename"
               ) {
                args += ["--adapter_fasta", fastaURL.path]
            }
        }

        let result = try await runNativeTool(.fastp, arguments: args, provenanceCollector: provenanceCollector)
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("fastp adapter trim failed: \(result.stderr)")
        }

        if isInterleaved, let r2 = r2Output {
            try await reinterleaveFastpOutput(
                r1: r1Output,
                r2: r2,
                output: outputFASTQ,
                provenanceCollector: provenanceCollector
            )
        }

        return FastpResult(toolCommand: "fastp \(args.joined(separator: " "))")
    }

    func runFastpFixedTrim(
        sourceFASTQ: URL,
        outputFASTQ: URL,
        from5Prime: Int,
        from3Prime: Int,
        isInterleaved: Bool = false,
        provenanceCollector: FASTQDerivativeNativeProvenanceCollector? = nil
    ) async throws -> FastpResult {
        let r1Output: URL
        let r2Output: URL?
        if isInterleaved {
            r1Output = outputFASTQ.deletingLastPathComponent().appendingPathComponent("fastp_R1.fastq")
            r2Output = outputFASTQ.deletingLastPathComponent().appendingPathComponent("fastp_R2.fastq")
        } else {
            r1Output = outputFASTQ
            r2Output = nil
        }

        var args = [
            "-i", sourceFASTQ.path,
            "-o", r1Output.path,
            "-w", String(toolThreadCount),
            "--disable_adapter_trimming",
            "--disable_quality_filtering",
            "--disable_length_filtering",
            "--json", "/dev/null",
            "--html", "/dev/null",
        ]
        if isInterleaved, let r2 = r2Output {
            args.append("--interleaved_in")
            args += ["--out2", r2.path]
        }

        if from5Prime > 0 {
            args += ["--trim_front1", String(from5Prime)]
        }
        if from3Prime > 0 {
            args += ["--trim_tail1", String(from3Prime)]
        }

        let result = try await runNativeTool(.fastp, arguments: args, provenanceCollector: provenanceCollector)
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("fastp fixed trim failed: \(result.stderr)")
        }

        if isInterleaved, let r2 = r2Output {
            try await reinterleaveFastpOutput(
                r1: r1Output,
                r2: r2,
                output: outputFASTQ,
                provenanceCollector: provenanceCollector
            )
        }

        return FastpResult(toolCommand: "fastp \(args.joined(separator: " "))")
    }

    /// Re-interleaves split R1/R2 fastp output back into a single interleaved file
    /// using reformat.sh, then cleans up the temp files.
    func reinterleaveFastpOutput(
        r1: URL,
        r2: URL,
        output: URL,
        provenanceCollector: FASTQDerivativeNativeProvenanceCollector? = nil
    ) async throws {
        let env = await bbToolsEnvironment()
        let result = try await runNativeTool(
            .reformat,
            arguments: [
                "in1=\(r1.path)",
                "in2=\(r2.path)",
                "out=\(output.path)",
                "interleaved=t",
            ],
            environment: env,
            timeout: 1800,
            provenanceCollector: provenanceCollector
        )
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("reformat.sh re-interleave failed: \(result.stderr)")
        }
        try? FileManager.default.removeItem(at: r1)
        try? FileManager.default.removeItem(at: r2)
    }

    /// Splits an interleaved FASTQ into separate R1/R2 files using reformat.sh.
    func deinterleaveFASTQ(
        source: URL,
        outputR1: URL,
        outputR2: URL,
        provenanceCollector: FASTQDerivativeNativeProvenanceCollector? = nil
    ) async throws {
        let env = await bbToolsEnvironment()
        let result = try await runNativeTool(
            .reformat,
            arguments: [
                "in=\(source.path)",
                "out1=\(outputR1.path)",
                "out2=\(outputR2.path)",
                "interleaved=t",
            ],
            environment: env,
            timeout: 1800,
            provenanceCollector: provenanceCollector
        )
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("reformat.sh deinterleave failed: \(result.stderr)")
        }
    }

}
