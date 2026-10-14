// ProvenanceInspectorViewModel+StepTools.swift - The Tool and Step Tools rows of the Run Summary
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishWorkflow

extension ProvenanceInspectorViewModel {
    /// The run-level tool of a record written by the command line. It runs other tools and records them
    /// as steps, so its own name says little about the science.
    private static let commandLineToolName = CLICommandIdentity.executableName

    /// The Tool row of the Run Summary, for the view and the Copy text alike.
    var toolText: String {
        summary.toolVersion.isEmpty ? summary.toolName : "\(summary.toolName) \(summary.toolVersion)"
    }

    /// The Step Tools row of the Run Summary, or nil when the row does not show (Phase 2.8 decision P3).
    ///
    /// A classifier that runs through `lungfish-cli` records that program as its tool, so the Tool row never
    /// names Kraken2 or EsViritu. The row lists the tool and version of each step of the selected record that
    /// ran a program other than LGE, in step order, once each, spelt as the Lineage spells them. A step LGE ran
    /// itself, such as `lungfish-cli fastq materialize` or `Lungfish EsViritu Result Sidecar`, is left out, and
    /// the Lineage still lists it. Both come from the step's own record and never from the managed tool lock,
    /// so the row says what ran and not what LGE pins today. A step that names no tool adds nothing, and a step
    /// with no known version adds its tool alone. The row shows only when the run-level tool is `lungfish-cli`,
    /// because any other run-level tool already names itself. A step that recorded a commit and the release tag of
    /// that commit reads `<tool> <tag> (<7 chars>)` (Phase 2.9 decision W5), see ``releaseLabel(of:named:)``.
    var stepToolsText: String? {
        guard summary.toolName.trimmingCharacters(in: .whitespacesAndNewlines) == Self.commandLineToolName,
              let steps = lineageRuns.last?.steps else { return nil }
        let recorded = Dictionary(
            (resolvedEnvelope?.steps ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        var seen: Set<String> = []
        let tools = steps.compactMap { step -> String? in
            let name = step.toolName.trimmingCharacters(in: .whitespacesAndNewlines)
            let version = step.toolVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !Self.namesNothing(name), !Self.isLGEsOwnStep(name) else { return nil }
            let tool = Self.releaseLabel(of: recorded[step.id], named: name)
                ?? (Self.namesNothing(version) ? name : "\(name) \(version)")
            return seen.insert(tool).inserted ? tool : nil
        }
        return tools.isEmpty ? nil : tools.joined(separator: ", ")
    }

    /// A step that recorded a full commit as its version and a release tag beside it reads `<tool> <tag> (<7 chars>)`,
    /// the tag as recorded and the first seven characters of the commit. A scientist reads the release, and the
    /// whole commit stays in the Lineage and the Copy text. Any other step is nil here and reads as recorded, so a
    /// commit with no tag keeps its 40 characters and nothing is guessed (BIO 4). The row shows for a record whose own
    /// tool is `lungfish-cli`, so a Viral Recon or pbAA record, which names its pipeline as its own tool, shows as before.
    private static func releaseLabel(of step: ProvenanceStep?, named name: String) -> String? {
        guard let step, let tag = step.githubReleaseVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !namesNothing(tag), !ProvenanceToolIdentityText.isCommit(tag) else { return nil }
        let identity = ProvenanceToolIdentityText.parse(toolName: step.toolName, toolVersion: step.toolVersion)
        guard identity.versionIsCommit else { return nil }
        return "\(name) \(tag) (\(identity.version.prefix(7)))"
    }

    /// True for a blank text or the word a record uses when it does not know.
    private static func namesNothing(_ text: String) -> Bool {
        text.isEmpty || text.lowercased() == "unknown"
    }

    /// The helper steps LGE records for a library or system call it makes itself, whose names do not start with
    /// `lungfish` or `LGE ` (Phase 2.10 lane U35, row 273 of Phase 2.8). They are lower case, and a name matches
    /// whole, so a program whose name only contains one of them still shows. The writers are `DatabaseRegistry`
    /// (`URLSession`, `CryptoKit`, `clonefile`), `ProjectTempDirectory`, `FetchCommand` (`ncbi-efetch` and
    /// `ena-fetch-fasta`) and the SRA read download (`https-download`).
    private static let lgeHelperSteps: Set<String> = [
        "urlsession", "cryptokit", "clonefile", "projecttempdirectory", "ncbi-efetch", "ena-fetch-fasta", "https-download",
    ]

    /// True for a step LGE ran itself, such as `lungfish-cli fastq materialize`, `lungfish-kraken2-index`,
    /// `Lungfish Classification Result Sidecar`, `LGE primer ordering` or a named helper such as `URLSession`.
    /// Lineage lists such a step, and the row keeps to the programs LGE ran. LGE names its own steps `lungfish...`
    /// or `LGE ...` in an open family of names, so the prefix test stays beside the named set.
    private static func isLGEsOwnStep(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.hasPrefix("lungfish") || lowered.hasPrefix("lge ") || lgeHelperSteps.contains(lowered)
    }
}
