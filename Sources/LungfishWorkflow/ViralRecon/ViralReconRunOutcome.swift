// ViralReconRunOutcome.swift - The samples a finished Viral Recon run dropped before it called variants
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The failed samples of a Viral Recon run that exited 0 (Phase 2.10 lane A30 M3, BIO's definition in ARCH's
/// ruling on M3).
///
/// nf-core/viralrecon 3.0.0 drops a sample that had no reads after fastp (`workflows/viralrecon.nf:262-291`) or
/// fewer mapped reads than `min_mapped_reads` (`:355-372`), and a Nanopore sample below its read floors
/// (`nextflow.config:30-31`), before it calls variants, and prints no line for it. Only MultiQC's input names such a
/// sample, and `skip_multiqc` drops that. So after exit 0 a sample of the effective samplesheet failed when its
/// caller never reached it. A sample the caller reached with no variants did not fail. The caller reached a sample
/// when one of the caller's files for it is in the results or the run's trace has a COMPLETED or CACHED row of the
/// caller's task for it. iVar keeps `<sample>.tsv` for a sample with no variants, and BCFtools publishes no file for
/// such a sample (`subworkflows/local/variants_bcftools/main.nf:40`), so its trace row is the evidence.
package enum ViralReconRunOutcome {
    /// The variant caller of a run and the evidence that it called a sample.
    package struct Caller: Sendable, Equatable {
        /// The caller's files for a sample, relative to the results folder, with `@SAMPLE@` for the sample. Any one
        /// of them shows the caller reached the sample.
        package let fileTemplates: [String]
        /// The last part of the process path of the caller's task for one sample, whose tag is the sample.
        package let processName: String

        package init(fileTemplates: [String], processName: String) {
            self.fileTemplates = fileTemplates
            self.processName = processName
        }
    }

    /// The run's variant caller, as the release picks it (`workflows/viralrecon.nf:55-56`), or nil when the run calls
    /// no variants. The files are the ones `conf/modules_illumina.config:395-470` and
    /// `conf/modules_nanopore.config:44-51` publish.
    package static func caller(params: [String: String]) -> Caller? {
        func value(_ key: String) -> String? {
            let text = params[key]?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            return text.isEmpty ? nil : text
        }
        guard value("skip_variants") != "true" else { return nil }
        if value("platform") == "nanopore" {
            return Caller(fileTemplates: ["artic_minion/@SAMPLE@.pass.vcf.gz"], processName: "ARTIC_MINION")
        }
        switch value("variant_caller") ?? (value("protocol") == "amplicon" ? "ivar" : "bcftools") {
        case "ivar":
            // The table iVar writes for every sample it calls, and the VCF it makes when the table has a variant.
            return Caller(fileTemplates: ["variants/ivar/@SAMPLE@.tsv", "variants/ivar/@SAMPLE@.vcf.gz"], processName: "IVAR_VARIANTS")
        case "bcftools":
            return Caller(fileTemplates: ["variants/bcftools/@SAMPLE@.vcf.gz"], processName: "BCFTOOLS_MPILEUP")
        default:
            return nil
        }
    }

    /// The samples of `samples` that the run's caller never reached, in their order. `traceText` is the run's own
    /// trace, or nil when it has none, and then a BCFtools sample with no variants reads as failed.
    package static func failedSamples(
        _ samples: [String],
        resultsDirectory: URL,
        params: [String: String],
        traceText: String?
    ) -> [String] {
        guard let caller = caller(params: params) else { return [] }
        let called = Set(
            NextflowTraceTask.succeeded(inTrace: traceText ?? "")
                .filter { $0.processName == caller.processName }
                .map(\.tag)
        )
        return samples.filter { sample in
            guard !called.contains(sample) else { return false }
            return !caller.fileTemplates.contains { template in
                let relative = template.replacingOccurrences(of: "@SAMPLE@", with: sample)
                return FileManager.default.fileExists(atPath: resultsDirectory.appendingPathComponent(relative).path)
            }
        }
    }

    /// The names of a samplesheet's `sample` column, each once, in the order of their first row. A file that cannot
    /// be read or holds no such column names none.
    package static func sampleNames(inSamplesheetAt url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = text.split(whereSeparator: \.isNewline)
        guard let column = lines.first.map(fields(of:))?.firstIndex(of: "sample") else { return [] }
        var seen = Set<String>()
        var names: [String] = []
        for line in lines.dropFirst() {
            let values = fields(of: line)
            guard values.count > column, !values[column].isEmpty else { continue }
            if seen.insert(values[column]).inserted {
                names.append(values[column])
            }
        }
        return names
    }

    private static func fields(of line: Substring) -> [String] {
        line.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
    }

    /// The one warning line for the failed samples of a run, UX's words under rules 1 and 5 of the contract's
    /// section 5, or nil when no sample failed.
    package static func failedSamplesLine(_ samples: [String]) -> String? {
        guard !samples.isEmpty else { return nil }
        let noun = samples.count == 1 ? "sample" : "samples"
        return "\(samples.count) failed \(noun): \(samples.joined(separator: ", ")). "
            + "Too few reads were left after trimming or mapping to call variants."
    }
}
