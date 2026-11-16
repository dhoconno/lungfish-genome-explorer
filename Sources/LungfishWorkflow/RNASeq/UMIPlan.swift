// UMIPlan.swift - The UMI branch of the RNA-seq plan on Linux: the kit preset table, its settings and the layout check
// step (Phase 5.3 lane EX-UMI, milestone 1)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable

/// One kit the UMI branch knows: where its motif and UMI sit, the read it keeps, its adapter, the argv of
/// `umi_tools extract` and `umi_tools count` it fixes (ADJ-BULK C9 Q1 and Q3) and the layout check's pairs and bars
/// (ADJ-BULK G1, BIO-UMI-SHARE). The sample sheet's kit column names a preset by its id.
package struct UMIKitPreset: Sendable, Equatable {
    package var id: String
    package var label: String
    package var motif: String
    package var umiLength: Int
    /// The read that starts with the motif and the UMI.
    package var umiRead: Int
    /// The one read the chain keeps and counts, with the UMI in its name.
    package var keptRead: Int
    /// The adapter the kit names, passed on both routes, or nil to leave it to the trimmer (BIO-PLAN-ADAPTER item 6).
    package var adapter: String?
    package var checkPairs: Int
    package var checkChoice: UMILayoutCheck.Choice
    package var bars: UMILayoutCheck.Bars

    /// `umi_tools extract`'s mode: the motif must match exactly, and the next `umiLength` bases are the UMI
    /// (`scripts/repro/rnaseq/gse163196/sample.sh:32-35`).
    package var extractArguments: [String] {
        ["extract", "--extract-method=regex", "--bc-pattern=^(?P<discard_1>\(motif))(?P<umi_1>.{\(umiLength)})"]
    }

    /// `umi_tools count` per gene by featureCounts' tags, directional (`sample.sh:67`, ADJ-BULK C9 Q3 and G2).
    package var countArguments: [String] {
        ["count", "--per-gene", "--gene-tag=XT", "--assigned-status-tag=XS", "--method=directional"]
    }
}

package enum UMIPlan {
    package static let pipelineID = "umi-counts"
    package static let pipelineVersion = 1
    /// The `home` file of each pair's check.
    package static func checkOutput(pair: Int) -> String { "umi-check/pair\(pair)-layout-check.json" }
    package static func checkStepID(pair: Int) -> String { "umi-layout-check-pair\(pair)" }

    /// The source each preset value enters `pipeline.settings` with. The brief names `preset`, which
    /// `ImportSettingSource` does not hold yet (EX-UMI report, Findings), so the values read `default` until it does.
    package static let presetSource = ImportSettingSource.default

    /// C9's kit: a Quartz-Seq2 style primer X910, whose Read 1 starts with ATCAATC and then a 16-nt UMI, with the
    /// transcript on Read 2 (`scripts/repro/rnaseq/gse163196/README.md:9-10`). It names no adapter.
    package static let quartzSeq2X910 = UMIKitPreset(
        id: "quartz-seq2-x910", label: "Quartz-Seq2 primer X910 (ATCAATC then a 16-nt UMI on Read 1)", motif: "ATCAATC",
        umiLength: 16, umiRead: 1, keptRead: 2, adapter: nil, checkPairs: 1000, checkChoice: .even,
        bars: UMILayoutCheck.Bars(withinOneMismatchPass: 90, exactWarn: 90, distinctFail: 50, distinctWarn: 80))

    package static let presets = [quartzSeq2X910]

    /// The preset the sheet's kit column names, by id, or a refusal that names the kits LGE knows.
    package static func preset(kit: String) throws -> UMIKitPreset {
        let named = kit.trimmingCharacters(in: .whitespaces)
        guard let preset = presets.first(where: { $0.id == named.lowercased() }) else {
            let known = presets.map { "\($0.id) (\($0.label))" }.joined(separator: ", ")
            throw SalmonPlanError("The sample sheet names the kit \(named), which LGE has no UMI preset for. The kits LGE "
                + "knows are \(known).")
        }
        return preset
    }

    /// Each value of the preset, as `pipeline.settings` states it, sorted by id. The check's settings state the motif,
    /// the UMI's length and read, the pairs and how they are chosen, and the bars (executor-plan.md:194).
    package static func settings(_ preset: UMIKitPreset) -> [PlanPipelineSetting] {
        func setting(_ id: String, _ label: String, _ value: String) -> PlanPipelineSetting {
            PlanPipelineSetting(id: id, label: label, value: value, source: presetSource)
        }
        let bars = preset.bars
        let choice = preset.checkChoice == .even
            ? "spread evenly through the file after counting its reads (--choice even)" : "the first in the file (--choice first)"
        var settings = [
            setting("umiKit", "UMI kit", "\(preset.label), preset \(preset.id)"),
            setting("umiMotif", "UMI motif", "Read \(preset.umiRead) starts with \(preset.motif)"),
            setting("umiLength", "UMI length", "\(preset.umiLength) bases after the motif"),
            setting("umiRead", "UMI read", "Read \(preset.umiRead) holds the UMI, and only Read \(preset.keptRead) is kept, with the UMI in its name"),
            setting("umiExtraction", "UMI extraction", "umi_tools " + preset.extractArguments.joined(separator: " ")),
            setting("umiGrouping", "UMI grouping", "umi_tools " + preset.countArguments.joined(separator: " ")),
            setting("umiCheckPairs", "UMI layout check pairs", "\(UMILayoutCheck.grouped(preset.checkPairs)) pairs, \(choice)"),
            setting("umiCheckBars", "UMI layout check bars", "fails when under \(bars.withinOneMismatchPass)% of the pairs read "
                + "start within one mismatch of \(preset.motif) or under \(bars.distinctFail)% hold a distinct UMI, and warns "
                + "when under \(bars.exactWarn)% start with it exactly or under \(bars.distinctWarn)% hold a distinct UMI"),
        ]
        if let adapter = preset.adapter {
            settings.append(setting("adapter", "Adapter", adapter))
        }
        return settings.sorted { $0.id < $1.id }
    }

    /// The check of one pair, the first `tool` step of the branch, run by the plan's own executor build (ARCH-UMI-CHECKER
    /// items 1 and 4). It reads gzip through the image's `pigz`, which the plan pins, and its report comes home.
    package static func checkStep(
        _ preset: UMIKitPreset, pair: Int, r1: String, r2: String, decompressor: PlanToolPin, executor: PlanExecutorBuild,
        deadline: Double
    ) -> PlanStep {
        let output = checkOutput(pair: pair)
        let arguments = UMILayoutCheck.Arguments(
            read1: r1, read2: r2, decompressor: decompressor.id, kit: preset.label, motif: preset.motif,
            umiLength: preset.umiLength, umiRead: preset.umiRead, pairs: preset.checkPairs, choice: preset.checkChoice,
            bars: preset.bars, output: output)
        return PlanStep(
            id: checkStepID(pair: pair), title: "Check the UMI layout of pair \(pair) for the \(preset.id) preset", kind: .tool,
            tool: executorPin(executor), arguments: arguments.argv, deadlineSeconds: deadline, inputs: [r1, r2],
            outputs: [output], outputPolicy: [output: .home])
    }

    /// The pin of the plan's own executor build, which `tools` holds as well (ARCH-UMI-CHECKER item 4).
    package static func executorPin(_ build: PlanExecutorBuild) -> PlanToolPin {
        PlanToolPin(id: "lungfish-executor", version: build.lgeVersion, build: build.lgeCommit)
    }
}
