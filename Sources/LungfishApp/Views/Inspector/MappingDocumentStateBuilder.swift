import Foundation
import LungfishIO
import LungfishWorkflow

enum MappingDocumentStateBuilder {

    /// The Run Settings "Paired End" value. `pairedEnd` is the request flag,
    /// which is only ever true for a split R1/R2 file pair. An interleaved
    /// single file reaches the mapper as one input, so the flag stays false
    /// even though minimap2 (`-x sr`) and BBMap (`interleaved=auto`) pair
    /// consecutive same-name records on their own; the label says so instead
    /// of reporting "No" for a BAM that is properly paired. bwa-mem2 and
    /// bowtie2 receive no interleave flag from `MappingCommandBuilder`, so for
    /// them an interleaved file really is mapped as single-end reads.
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
        rows.append((
            "Paired End",
            pairedEndDescription(
                pairedEnd: provenance.pairedEnd,
                mapper: provenance.mapper,
                inputPairingMode: inputPairingMode(for: provenance)
            )
        ))
        rows.append(("Threads", String(provenance.threads)))
        rows.append(("Minimum MAPQ", String(provenance.minimumMappingQuality)))
        rows.append(("Include Secondary", provenance.includeSecondary ? "Yes" : "No"))
        rows.append(("Include Supplementary", provenance.includeSupplementary ? "Yes" : "No"))
        rows.append(("Extra arguments", provenance.advancedArguments.isEmpty ? "None" : AdvancedCommandLineOptions.join(provenance.advancedArguments)))
        rows.append(("Mapper Version", provenance.mapperVersion))
        rows.append(("Samtools Version", provenance.samtoolsVersion))
        rows.append(("Recorded", Self.recordedString(provenance.recordedAt)))

        rows.append(contentsOf: provenance.commandInvocations.map { invocation in
            (invocation.label, invocation.commandLine)
        })

        return rows
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
