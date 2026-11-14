// FastpTrimStep.swift
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// Recipe step that trims adapters and low-quality bases using fastp.
///
/// Conforms to `FastpFusible` so the recipe engine can merge consecutive fastp
/// steps into a single invocation.
public struct FastpTrimStep: FastpFusible {

    // MARK: - RecipeStepExecutor

    public static let typeID: String = "fastp-trim"
    public static let displayName: String = "Adapter + Quality Trim"

    public var inputFormat: RecipeFileFormat { .pairedR1R2 }
    public var outputFormat: RecipeFileFormat { .pairedR1R2 }

    // MARK: - Parameters

    /// Whether the trim removes the adapter pair of ``adapterKit`` by name (`--adapter_sequence`,
    /// `--adapter_sequence_r2`) as well as by mate overlap, never by fastp's guess from read order (ruling
    /// ARCH-BIO-RECIPE-TRIM). The key keeps its name so older recipes still open, and `false` trims by mate overlap
    /// only, whatever the kit.
    public let detectAdapter: Bool

    /// The kit whose adapter pair the trim names, `truseq` (the default) or `nextera`, read from `adapterKit` (ruling
    /// BIO-NEXTERA N1). A recipe or preset names `nextera` only where the library's kit is fixed, as VSP2's Illumina RNA
    /// Prep with Enrichment is, since the wrong kit's pair leaves more adapter than either pair removes. Any other value
    /// is refused.
    public let adapterKit: String

    /// Qualified-base threshold of the read filter (`-q`), read from `qualifiedQuality` or, in older recipes,
    /// `quality`. It is not the window threshold, which is ``cutMeanQuality``.
    public let quality: Int

    /// Percent of bases a read may hold under ``quality`` before the filter drops it (`-u`), nil to leave fastp's
    /// own value.
    public let unqualifiedPercent: Int?

    /// N bases a read may hold before the filter drops it (`-n`), nil to leave fastp's own value.
    public let nBaseLimit: Int?

    /// Shortest read the filter keeps (`-l`), nil to leave fastp's own value.
    public let minLength: Int?

    /// Sliding-window size for quality trimming (`-W`).
    public let window: Int

    /// End(s) of the read to trim. Valid values: "right", "front", "tail", "both".
    public let cutMode: String

    /// Mean quality the window must reach (`-M`), nil to leave fastp's own value.
    public let cutMeanQuality: Int?

    /// Whether to trim 3' poly-G runs whatever the instrument (`-g --poly_g_min_len`).
    public let trimPolyG: Bool

    /// Shortest poly-G run ``trimPolyG`` trims.
    public let polyGMinLength: Int

    // MARK: - Init

    /// Every value a recipe names reaches the argv, and one it leaves out is left to fastp, so an older recipe's
    /// argv does not move (ruling BIO-PRESET P1).
    public init(params: [String: AnyCodableValue]?) throws {
        detectAdapter      = params?["detectAdapter"]?.boolValue ?? true
        if let kit = params?["adapterKit"] {
            guard let name = kit.stringValue, Self.adapterPair(kit: name) != nil else {
                throw RecipeEngineError.invalidParam(
                    step: Self.typeID, param: "adapterKit", value: kit.stringValue ?? "\(kit)")
            }
            adapterKit = name
        } else {
            adapterKit = "truseq"
        }
        quality            = params?["qualifiedQuality"]?.intValue ?? params?["quality"]?.intValue ?? 20
        unqualifiedPercent = params?["unqualifiedPercent"]?.intValue
        nBaseLimit         = params?["nBaseLimit"]?.intValue
        minLength          = params?["minLength"]?.intValue
        window             = params?["window"]?.intValue        ?? 4
        cutMode            = params?["cutMode"]?.stringValue    ?? "right"
        cutMeanQuality     = params?["cutMeanQuality"]?.intValue
        trimPolyG          = params?["trimPolyG"]?.boolValue ?? false
        polyGMinLength     = params?["polyGMinLength"]?.intValue ?? 10

        let validModes: Set<String> = ["right", "front", "tail", "both"]
        guard validModes.contains(cutMode) else {
            throw RecipeEngineError.invalidParam(
                step: Self.typeID, param: "cutMode", value: cutMode)
        }
        let ranges: [(String, Int?, ClosedRange<Int>)] = [
            ("unqualifiedPercent", unqualifiedPercent, 0...100),
            ("nBaseLimit", nBaseLimit, 0...1_000),
            ("minLength", minLength, 0...1_000_000),
            ("cutMeanQuality", cutMeanQuality, 1...36),
            ("polyGMinLength", polyGMinLength, 1...1_000),
        ]
        for (name, value, range) in ranges {
            if let value, !range.contains(value) {
                throw RecipeEngineError.invalidParam(step: Self.typeID, param: name, value: "\(value)")
            }
        }
    }

    /// The read 1 and read 2 adapters of a kit the trim can name, nil for a kit it does not know.
    static func adapterPair(kit: String) -> (r1: String, r2: String)? {
        switch kit {
        case "truseq": return (PlatformAdapters.truseqR1, PlatformAdapters.truseqR2)
        case "nextera": return (PlatformAdapters.nexteraR1, PlatformAdapters.nexteraR2)
        default: return nil
        }
    }

    // MARK: - FastpFusible

    public func fastpArgs() -> [String] {
        var args: [String] = []

        if detectAdapter, let pair = Self.adapterPair(kit: adapterKit) {
            args += ["--adapter_sequence", pair.r1, "--adapter_sequence_r2", pair.r2]
        }
        if trimPolyG {
            args += ["-g", "--poly_g_min_len", "\(polyGMinLength)"]
        }

        args += ["-q", "\(quality)"]
        if let unqualifiedPercent { args += ["-u", "\(unqualifiedPercent)"] }
        if let nBaseLimit { args += ["-n", "\(nBaseLimit)"] }
        if let minLength { args += ["-l", "\(minLength)"] }
        args += ["-W", "\(window)"]

        switch cutMode {
        case "front":
            args.append("--cut_front")
        case "tail":
            args.append("--cut_tail")
        case "both":
            args += ["--cut_front", "--cut_right"]
        default: // "right"
            args.append("--cut_right")
        }
        if let cutMeanQuality { args += ["-M", "\(cutMeanQuality)"] }

        return args
    }

    // MARK: - Execute

    public func execute(input: StepInput, context: StepContext) async throws -> StepOutput {
        guard let r2 = input.r2 else {
            throw RecipeEngineError.formatMismatch(
                expected: .pairedR1R2, got: input.format, step: Self.typeID)
        }

        let outR1 = context.workspace.appendingPathComponent("\(context.sampleName)_trim_R1.fq.gz")
        let outR2 = context.workspace.appendingPathComponent("\(context.sampleName)_trim_R2.fq.gz")
        // A run that keeps duplicates runs this step alone, so it writes the report the fused call writes and
        // takes its pair counts from it, never from the lines of its reads.
        let report = context.workspace.appendingPathComponent(
            "\(context.sampleName)_trim_fastp_report_\(UUID().uuidString).json")

        var args = [
            "-i", input.r1.path,
            "-I", r2.path,
            "-o", outR1.path,
            "-O", outR2.path,
        ]
        args += fastpArgs()
        args += [
            "-w", "\(context.threads)",
            "-j", report.path,
            "-h", "/dev/null",
        ]

        let result = try await context.runner.run(
            .fastp,
            arguments: args,
            timeout: context.recipeToolTimeout(for: .fastp, input: input)
        )
        if result.exitCode != 0 {
            try? FileManager.default.removeItem(at: report)
            throw RecipeEngineError.toolFailed(
                tool: "fastp", step: Self.typeID, stderr: result.stderr)
        }

        let counts = RecipeToolReportCounts.fastpPairs(reportAt: report)
        let reportExists = FileManager.default.fileExists(atPath: report.path)
        return StepOutput(
            r1: outR1, r2: outR2, format: .pairedR1R2,
            readCount: counts?.output, inputReadCount: counts?.input,
            tool: .fastp, arguments: result.arguments,
            auxiliaryOutputs: reportExists ? [report] : [],
            exitStatus: Int(result.exitCode), stderr: result.stderr
        )
    }
}
