// AlignmentMeanDepth.swift - The mean depth of one sequence in a BAM, as samtools measures it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The mean depth of one reference sequence in a BAM, as samtools coverage measures it with the filter flags of the
/// mapping table (MappingSummaryBuilder.primaryMappedReadExclusionFlags), so it equals the table's Mean Depth for the
/// same BAM. The Inspector shows it for a one-sequence bundle. No read length is assumed: where the file is not a BAM,
/// is missing or the run fails, the answer is nil and the caller shows nothing (EST-COVERAGE-150BP).
public enum AlignmentMeanDepth {
    public static func measure(
        alignmentURL: URL,
        chromosome: String,
        runner: NativeToolRunner = .shared,
        timeout: TimeInterval? = nil
    ) async -> Double? {
        guard alignmentURL.pathExtension.lowercased() == "bam",
              FileManager.default.fileExists(atPath: alignmentURL.path),
              let result = try? await runner.run(
                  .samtools,
                  arguments: ["coverage", "--ff", MappingSummaryBuilder.primaryMappedReadExclusionFlags, alignmentURL.path],
                  timeout: timeout
              ),
              result.exitCode == 0 else { return nil }
        return meanDepth(ofChromosome: chromosome, inCoverageOutput: result.stdout)
    }

    /// The `meandepth` column of the row for `chromosome` in `samtools coverage` output.
    static func meanDepth(ofChromosome chromosome: String, inCoverageOutput output: String) -> Double? {
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 7, fields[0] == chromosome, let depth = Double(fields[6]) else { continue }
            return depth
        }
        return nil
    }
}
