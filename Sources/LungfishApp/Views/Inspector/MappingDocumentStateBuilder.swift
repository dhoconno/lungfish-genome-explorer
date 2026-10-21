import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension MappingDocumentState {
    /// What the shown commands are built from, so the section builds them again only when a record's commands or its
    /// project change.
    var shownCommandsID: [String] {
        [projectURL?.path ?? ""] + steps.map(\.command)
    }
}

enum MappingDocumentStateBuilder {

    /// Each step's command as its Run Settings row shows it, by the recorded command: each project path relative to
    /// the project and a tool under `toolRoot` by its name, through the mapper the Provenance tab's Command row uses
    /// (Phase 2.12 lane 12.25, PF6 Q-U7). Copy Command, Copy Step, the tooltip and VoiceOver keep the recorded command.
    /// The mapper asks `fileExists` about each path argument, so this runs off the main actor. Each command first moves
    /// through `renames`, the relocation the Inspector's Command row reads (lane 13.45, ARCH C6).
    nonisolated static func shownCommands(
        of steps: [MappingDocumentStep],
        projectURL: URL?,
        fileExists: (String) -> Bool,
        toolRoot: URL?,
        renames: [ProvenanceFolderRename] = []
    ) -> [String: String] {
        var shown: [String: String] = [:]
        for step in steps where shown[step.command] == nil {
            let moved = ProvenanceCommandPresentation.movingRenamedPaths(step.command, renames: renames, projectURL: projectURL)
            shown[step.command] = ProvenanceCommandPresentation.display(
                renames.isEmpty ? step.command : moved, projectURL: projectURL, fileExists: fileExists, toolRoot: toolRoot
            )
        }
        return shown
    }

    /// The shown commands of `state`, built in a detached task, so neither a stat, the read of the canonical record
    /// beside the result nor the read of the storage configuration that names the tool root runs on the main actor.
    /// The mapping Document section's task awaits it once for each record it shows.
    static func shownCommands(
        for state: MappingDocumentState,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        toolRoot: @escaping @Sendable () -> URL? = { PortablePath.defaultManagedRoots.toolRoot }
    ) async -> [String: String] {
        let steps = state.steps
        let projectURL = state.projectURL
        // `build` makes the Sorted BAM row first, from the BAM in the result's folder, where the canonical record lies.
        let folder = state.artifactRows.first { $0.label == "Sorted BAM" }?.fileURL?.deletingLastPathComponent()
        return await Task.detached(priority: .userInitiated) {
            let recordURL = folder?.appendingPathComponent(".lungfish-provenance.json")
            let renames = recordURL.flatMap { url in
                (try? ProvenanceEnvelopeReader.loadCanonical(fromSidecar: url)).map {
                    ProvenanceCommandPresentation.folderRenames(of: $0, recordURL: url)
                }
            } ?? []
            return shownCommands(of: steps, projectURL: projectURL, fileExists: fileExists, toolRoot: toolRoot(), renames: renames)
        }.value
    }

    /// The Run Settings "Paired End" value.
    ///
    /// A run recorded under the read-layout contract carries the resolved
    /// input layout and the handling the mapper applied, which is the whole
    /// answer (`MappingReadLayoutPlan.pairedEndDescription`). Older runs fall
    /// back to the request flag and the input's `.lungfish-meta.json`
    /// pairing mode through the legacy overload.
    static func pairedEndDescription(for provenance: MappingProvenance) -> String {
        if let layout = provenance.inputLayout, let handling = provenance.readLayoutHandling {
            return MappingReadLayoutPlan(layout: layout, handling: handling).pairedEndDescription
        }
        return pairedEndDescription(
            pairedEnd: provenance.pairedEnd,
            mapper: provenance.mapper,
            inputPairingMode: inputPairingMode(for: provenance)
        )
    }

    /// Legacy label for runs recorded before the read-layout contract.
    /// `pairedEnd` is the request flag, which is only ever true for a split
    /// R1/R2 file pair. An interleaved single file reached the mapper as one
    /// input, so the flag stays false even though minimap2 (`-x sr`) and
    /// BBMap (`interleaved=auto`) paired consecutive same-name records on
    /// their own; the label says so instead of reporting "No" for a BAM that
    /// is properly paired. bwa-mem2 and bowtie2 received no interleave flag
    /// back then, so for them an interleaved file really was mapped as
    /// single-end reads.
    static func pairedEndDescription(
        pairedEnd: Bool,
        mapper: MappingTool,
        inputPairingMode: IngestionMetadata.PairingMode?
    ) -> String {
        if pairedEnd { return "Yes" }
        guard inputPairingMode == .interleaved else { return "No" }
        switch mapper {
        case .minimap2, .bbmap:
            return "Yes (interleaved)"
        case .bwaMem2, .bowtie2:
            return "No (interleaved input mapped as single-end)"
        }
    }

    /// The recorded pairing mode of the run's FASTQ input, from the
    /// `.lungfish-meta.json` sidecar next to the first input that has one.
    static func inputPairingMode(for provenance: MappingProvenance) -> IngestionMetadata.PairingMode? {
        provenance.inputFASTQPaths.lazy.compactMap { path in
            FASTQMetadataStore.load(for: URL(fileURLWithPath: path))?.ingestion?.pairingMode
        }.first
    }
    static func build(
        result: MappingResult,
        provenance: MappingProvenance?,
        projectURL: URL?
    ) -> MappingDocumentState {
        let outputDirectory = result.bamURL.deletingLastPathComponent()
        let modeDisplayName = provenance?.modeDisplayName
            ?? MappingMode(rawValue: result.modeID)?.displayName
            ?? result.modeID

        return MappingDocumentState(
            title: outputDirectory.lastPathComponent,
            subtitle: subtitle(
                mapperDisplayName: result.mapper.displayName,
                modeDisplayName: modeDisplayName,
                mappedReads: result.mappedReads,
                totalReads: result.totalReads
            ),
            summary: summary(mappedReads: result.mappedReads, totalReads: result.totalReads),
            sourceData: sourceRows(
                result: result,
                provenance: provenance,
                projectURL: projectURL
            ),
            contextRows: contextRows(
                result: result,
                provenance: provenance
            ),
            steps: steps(provenance: provenance),
            projectURL: projectURL,
            artifactRows: artifactRows(
                result: result,
                outputDirectory: outputDirectory
            )
        )
    }

    private static func subtitle(
        mapperDisplayName: String,
        modeDisplayName: String,
        mappedReads: Int,
        totalReads: Int
    ) -> String {
        let mappedPercent = totalReads > 0
            ? (Double(mappedReads) / Double(totalReads) * 100)
            : 0
        return "\(mapperDisplayName) • \(modeDisplayName) • \(String(format: "%.1f%%", mappedPercent)) mapped"
    }

    private static func summary(mappedReads: Int, totalReads: Int) -> String {
        guard totalReads > 0 else { return "0/0 reads mapped" }
        return "\(mappedReads)/\(totalReads) reads mapped"
    }

    private static func sourceRows(
        result: MappingResult,
        provenance: MappingProvenance?,
        projectURL: URL?
    ) -> [MappingDocumentSourceRow] {
        var rows: [MappingDocumentSourceRow] = []

        if let provenance {
            if provenance.inputFASTQPaths.isEmpty {
                rows.append(.missing(name: "FASTQ Inputs", originalPath: nil))
            } else {
                rows.append(contentsOf: provenance.inputFASTQPaths.map { path in
                    MappingInspectorSourceResolver.resolve(
                        name: URL(fileURLWithPath: path).lastPathComponent,
                        path: path,
                        projectURL: projectURL
                    )
                })
            }
            rows.append(
                MappingInspectorSourceResolver.resolve(
                    name: "Source Reference Bundle",
                    path: provenance.sourceReferenceBundlePath ?? result.sourceReferenceBundleURL?.path,
                    projectURL: projectURL
                )
            )
            rows.append(
                MappingInspectorSourceResolver.resolve(
                    name: "Reference FASTA",
                    path: provenance.referenceFASTAPath,
                    projectURL: projectURL
                )
            )
        } else {
            rows.append(.missing(name: "FASTQ Inputs", originalPath: nil))
            rows.append(
                MappingInspectorSourceResolver.resolve(
                    name: "Source Reference Bundle",
                    path: result.sourceReferenceBundleURL?.path,
                    projectURL: projectURL
                )
            )
            rows.append(.missing(name: "Reference FASTA", originalPath: nil))
        }

        return rows
    }

    private static func contextRows(
        result: MappingResult,
        provenance: MappingProvenance?
    ) -> [(String, String)] {
        var rows: [(String, String)] = []

        if provenance == nil {
            rows.append(("Provenance", "Unavailable"))
        }

        rows.append(("Mapper", provenance?.mapperDisplayName ?? result.mapper.displayName))
        rows.append(("Preset", provenance?.modeDisplayName ?? (MappingMode(rawValue: result.modeID)?.displayName ?? result.modeID)))
        rows.append(("Mapped Reads", "\(result.mappedReads)"))
        rows.append(("Unmapped Reads", "\(result.unmappedReads)"))
        rows.append(("Total Reads", "\(result.totalReads)"))
        rows.append(("Mapped Rate", Self.percentageString(mappedReads: result.mappedReads, totalReads: result.totalReads)))
        rows.append(("Runtime", Self.runtimeString(result.wallClockSeconds)))

        guard let provenance else {
            return rows
        }

        rows.append(("Sample Name", provenance.sampleName))
        rows.append(("Read Class Hints", provenance.readClassHints.isEmpty ? "None recorded" : provenance.readClassHints.joined(separator: ", ")))
        rows.append(("Paired End", pairedEndDescription(for: provenance)))
        if let layout = provenance.inputLayout {
            rows.append(("Read Layout", layout.displayName))
        }
        rows.append(("Threads", String(provenance.threads)))
        rows.append(("Minimum MAPQ", String(provenance.minimumMappingQuality)))
        rows.append(("Include Secondary", provenance.includeSecondary ? "Yes" : "No"))
        rows.append(("Include Supplementary", provenance.includeSupplementary ? "Yes" : "No"))
        rows.append(("Extra arguments", provenance.advancedArguments.isEmpty ? "None" : AdvancedCommandLineOptions.join(provenance.advancedArguments)))
        rows.append(("Mapper Version", provenance.mapperVersion))
        rows.append(("Samtools Version", provenance.samtoolsVersion))
        rows.append(("Recorded", Self.recordedString(provenance.recordedAt)))

        return rows
    }

    /// The run's commands as Run Settings step rows, in invocation order,
    /// each with the Recorded row's text.
    private static func steps(provenance: MappingProvenance?) -> [MappingDocumentStep] {
        guard let provenance else { return [] }
        let recorded = recordedString(provenance.recordedAt)
        return provenance.commandInvocations.enumerated().map { index, invocation in
            MappingDocumentStep(
                label: invocation.label,
                command: invocation.commandLine,
                version: stepVersion(of: invocation, at: index, in: provenance),
                recorded: recorded
            )
        }
    }

    /// The run-level version the Run Settings rows show for a step's tool.
    /// The mapper is always the first invocation and takes the Mapper
    /// Version, a command whose program is samtools takes the Samtools
    /// Version, and any other tool has none.
    private static func stepVersion(
        of invocation: MappingCommandInvocation,
        at index: Int,
        in provenance: MappingProvenance
    ) -> String? {
        if index == 0 { return provenance.mapperVersion }
        guard let program = invocation.argv.first,
              (program as NSString).lastPathComponent == "samtools"
        else { return nil }
        return provenance.samtoolsVersion
    }

    private static func artifactRows(
        result: MappingResult,
        outputDirectory: URL
    ) -> [MappingDocumentArtifactRow] {
        var rows = [
            MappingDocumentArtifactRow(label: "Sorted BAM", fileURL: result.bamURL),
            MappingDocumentArtifactRow(label: "BAM Index", fileURL: result.baiURL),
            MappingDocumentArtifactRow(label: "Viewer Bundle", fileURL: result.viewerBundleURL),
        ]

        if let viewerBundleURL = result.viewerBundleURL {
            let filteredAlignmentsDirectory = viewerBundleURL
                .appendingPathComponent("alignments/filtered", isDirectory: true)
            if FileManager.default.fileExists(atPath: filteredAlignmentsDirectory.path) {
                rows.append(
                    MappingDocumentArtifactRow(
                        label: "Filtered Alignments",
                        fileURL: filteredAlignmentsDirectory
                    )
                )
            }
        }

        rows.append(
            contentsOf: [
                MappingDocumentArtifactRow(label: "Mapping Result", fileURL: outputDirectory.appendingPathComponent("mapping-result.json")),
                MappingDocumentArtifactRow(label: "Legacy Alignment Result", fileURL: outputDirectory.appendingPathComponent("alignment-result.json")),
                MappingDocumentArtifactRow(label: "Mapping Provenance", fileURL: outputDirectory.appendingPathComponent(MappingProvenance.filename))
            ]
        )

        return rows
    }

    private static func percentageString(mappedReads: Int, totalReads: Int) -> String {
        guard totalReads > 0 else { return "0.0%" }
        let value = Double(mappedReads) / Double(totalReads) * 100
        return String(format: "%.1f%%", value)
    }

    private static func runtimeString(_ seconds: Double) -> String {
        String(format: "%.2f s", seconds)
    }

    private static func recordedString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
