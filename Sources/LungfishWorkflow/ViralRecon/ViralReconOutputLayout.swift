// ViralReconOutputLayout.swift - Where viralrecon 3.0.0 publishes a sample's outputs for a run's params
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The folders nf-core/viralrecon 3.0.0 publishes one sample's outputs to, read from the run's effective params
/// (VR-INVENTORY). `ViralReconRunOutcome.caller` and `ViralReconResultInventory` both read their paths here, so a run
/// with `--variant_caller bcftools`, `--consensus_caller ivar` or the Nanopore platform is read from the folders it
/// wrote.
///
/// - Illumina: the caller is `variant_caller`, or iVar for an amplicon run and BCFtools otherwise
///   (`conf/modules_illumina.config:13-14`). Its VCF is `variants/<caller>/<sample>.vcf.gz` (`:395-470`). The
///   consensus is `variants/<caller>/consensus/<consensus_caller>/<sample>.consensus.fa` (`:575-662`), and the
///   Pangolin and Nextclade tables sit in that folder's `pangolin` and `nextclade` (`:670-698`).
/// - Nanopore: ARTIC minion publishes the VCF, the consensus and the lineage tables under `artic_minion`
///   (`conf/modules_nanopore.config:44-50,185-251`).
public struct ViralReconOutputLayout: Sendable, Equatable {
    /// The params of the run a new wizard starts: an Illumina amplicon run with the callers left to viralrecon
    /// (iVar, then a BCFtools consensus, `nextflow.config:76`) and the steps Lungfish never runs skipped.
    public static var defaultRunParams: [String: String] {
        var params = ["platform": ViralReconPlatform.illumina.rawValue, "protocol": ViralReconProtocol.amplicon.rawValue]
        for option in ViralReconSkipOption.alwaysSkipped {
            params[option.rawValue] = "true"
        }
        return params
    }

    /// Whether the run is a Nanopore run, whose outputs ARTIC minion writes.
    public let isNanopore: Bool
    /// `ivar` or `bcftools` for an Illumina run, `artic` for a Nanopore run, or nil when the run calls no variants or
    /// names a caller viralrecon 3.0.0 does not have.
    public let variantCaller: String?
    /// `ivar` or `bcftools` for an Illumina run, `artic` for a Nanopore run, or nil when the run makes no consensus.
    public let consensusCaller: String?
    /// The lineage tools whose tables the run makes, in `ViralReconLineageTool` order.
    public let lineageTools: [ViralReconLineageTool]

    public init(params: [String: String]) {
        func value(_ key: String) -> String? {
            let text = params[key]?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            return text.isEmpty ? nil : text
        }
        func skips(_ key: String) -> Bool { value(key) == "true" }
        isNanopore = value("platform") == "nanopore"
        if skips("skip_variants") {
            variantCaller = nil
        } else if isNanopore {
            variantCaller = "artic"
        } else {
            let caller = value("variant_caller") ?? (value("protocol") == "amplicon" ? "ivar" : "bcftools")
            variantCaller = ["ivar", "bcftools"].contains(caller) ? caller : nil
        }
        if variantCaller == nil || (!isNanopore && skips("skip_consensus")) {
            consensusCaller = nil
        } else if isNanopore {
            consensusCaller = "artic"
        } else {
            let caller = value("consensus_caller") ?? "bcftools"
            consensusCaller = ["ivar", "bcftools"].contains(caller) ? caller : nil
        }
        let makesConsensus = consensusCaller != nil
        let callsVariants = variantCaller != nil
        lineageTools = ViralReconLineageTool.allCases.filter { tool in
            switch tool {
            case .pangolin, .nextclade: return makesConsensus && !skips("skip_\(tool.rawValue)")
            case .freyja: return callsVariants && !skips("skip_freyja")
            }
        }
    }

    /// The folder of the variant calls: `variants/<caller>` or `artic_minion`.
    public var variantsFolder: String? {
        guard let variantCaller else { return nil }
        return isNanopore ? "artic_minion" : "variants/\(variantCaller)"
    }

    /// The VCF of `sample`, relative to the results folder.
    public func variantFile(forSample sample: String) -> String? {
        guard let variantsFolder else { return nil }
        return isNanopore ? "\(variantsFolder)/\(sample).pass.vcf.gz" : "\(variantsFolder)/\(sample).vcf.gz"
    }

    /// The folder of the consensus: `variants/<caller>/consensus/<consensus_caller>` or `artic_minion`.
    public var consensusFolder: String? {
        guard let variantsFolder, let consensusCaller else { return nil }
        return isNanopore ? variantsFolder : "\(variantsFolder)/consensus/\(consensusCaller)"
    }

    /// The consensus FASTA of `sample`, relative to the results folder.
    public func consensusFile(forSample sample: String) -> String? {
        guard let consensusFolder else { return nil }
        return isNanopore ? "\(consensusFolder)/\(sample).consensus.fasta" : "\(consensusFolder)/\(sample).consensus.fa"
    }

    /// The folder that holds `tool`'s per-sample tables, whether or not the run makes them, so a table a run wrote is
    /// taken however its params read.
    public func lineageFolder(_ tool: ViralReconLineageTool) -> String? {
        switch tool {
        case .pangolin, .nextclade:
            return consensusFolder.map { "\($0)/\(tool.rawValue)" }
        case .freyja:
            return isNanopore ? "artic_minion/freyja/demix" : "variants/freyja/demix"
        }
    }

    /// The caller's files that show it reached a sample, with `@SAMPLE@` for the sample, and the last part of the
    /// process path of its task for one sample (`conf/modules_illumina.config:395-470`,
    /// `conf/modules_nanopore.config:44-51`). iVar keeps `<sample>.tsv` for every sample it calls.
    var callerEvidence: (fileTemplates: [String], processName: String)? {
        guard let variantCaller, let template = variantFile(forSample: "@SAMPLE@") else { return nil }
        switch variantCaller {
        case "artic": return ([template], "ARTIC_MINION")
        case "ivar": return (["variants/ivar/@SAMPLE@.tsv", template], "IVAR_VARIANTS")
        default: return ([template], "BCFTOOLS_MPILEUP")
        }
    }
}
