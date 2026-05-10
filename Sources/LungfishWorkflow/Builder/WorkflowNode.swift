// WorkflowNode.swift - Workflow node model for visual builder
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CoreGraphics

// MARK: - WorkflowNodeType

/// The type of workflow node, representing different analysis steps.
///
/// Each node type has predefined input and output ports with specific data types.
public enum WorkflowNodeType: String, Sendable, Codable, CaseIterable {
    /// FASTQ file input node
    case fastqInput = "fastq_input"
    /// FASTA file input node
    case fastaInput = "fasta_input"
    /// BAM/CRAM alignment file input node
    case bamInput = "bam_input"
    /// Sample sheet input node (CSV/TSV with sample metadata)
    case sampleSheet = "sample_sheet"
    /// Quality control analysis (FastQC, MultiQC)
    case qualityControl = "quality_control"
    /// Read trimming and filtering (Trimmomatic, fastp)
    case trimming = "trimming"
    /// Sequence alignment (BWA, Bowtie2, STAR)
    case alignment = "alignment"
    /// Variant calling (GATK, bcftools, freebayes)
    case variantCalling = "variant_calling"
    /// Gene/transcript quantification (featureCounts, Salmon)
    case quantification = "quantification"
    /// Genome/transcriptome assembly
    case assembly = "assembly"
    /// Report generation (HTML/PDF output)
    case report = "report"
    /// Export/output node for final results
    case export = "export"

    // MARK: - Display Properties

    /// Human-readable display name for the node type
    public var displayName: String {
        switch self {
        case .fastqInput: return "FASTQ Input"
        case .fastaInput: return "FASTA Input"
        case .bamInput: return "BAM Input"
        case .sampleSheet: return "Sample Sheet"
        case .qualityControl: return "Quality Control"
        case .trimming: return "Trimming"
        case .alignment: return "Alignment"
        case .variantCalling: return "Variant Calling"
        case .quantification: return "Quantification"
        case .assembly: return "Assembly"
        case .report: return "Report"
        case .export: return "Export"
        }
    }

    /// SF Symbol name for the node type icon
    public var iconName: String {
        switch self {
        case .fastqInput: return "doc.text.fill"
        case .fastaInput: return "doc.fill"
        case .bamInput: return "chart.bar.doc.horizontal.fill"
        case .sampleSheet: return "tablecells.fill"
        case .qualityControl: return "checkmark.seal.fill"
        case .trimming: return "scissors"
        case .alignment: return "arrow.left.arrow.right"
        case .variantCalling: return "waveform.path.ecg"
        case .quantification: return "chart.bar.fill"
        case .assembly: return "puzzlepiece.extension.fill"
        case .report: return "doc.richtext.fill"
        case .export: return "square.and.arrow.up.fill"
        }
    }

    /// Category for grouping in the palette
    public var category: NodeCategory {
        switch self {
        case .fastqInput, .fastaInput, .bamInput, .sampleSheet:
            return .input
        case .qualityControl, .trimming:
            return .preprocessing
        case .alignment, .variantCalling, .quantification, .assembly:
            return .analysis
        case .report, .export:
            return .output
        }
    }

    /// Default input ports for this node type
    public var inputPorts: [NodePort] {
        switch self {
        case .fastqInput, .fastaInput, .bamInput, .sampleSheet:
            return []
        case .qualityControl:
            return [
                NodePort(id: "reads", name: "Reads", dataType: .fastqBundle, direction: .input)
            ]
        case .trimming:
            return [
                NodePort(id: "reads", name: "Reads", dataType: .fastqBundle, direction: .input)
            ]
        case .alignment:
            return [
                NodePort(id: "reads", name: "Reads", dataType: .fastqBundle, direction: .input),
                NodePort(id: "reference", name: "Reference", dataType: .referenceBundle, direction: .input)
            ]
        case .variantCalling:
            return [
                NodePort(id: "alignments", name: "Alignments", dataType: .bamTrack, direction: .input),
                NodePort(id: "reference", name: "Reference", dataType: .referenceBundle, direction: .input)
            ]
        case .quantification:
            return [
                NodePort(id: "alignments", name: "Alignments", dataType: .bamTrack, direction: .input),
                NodePort(id: "annotation", name: "Annotation", dataType: .any, direction: .input)
            ]
        case .assembly:
            return [
                NodePort(id: "reads", name: "Reads", dataType: .fastqBundle, direction: .input)
            ]
        case .report:
            return [
                NodePort(id: "input", name: "Input", dataType: .any, direction: .input)
            ]
        case .export:
            return [
                NodePort(id: "input", name: "Input", dataType: .any, direction: .input)
            ]
        }
    }

    /// Default output ports for this node type
    public var outputPorts: [NodePort] {
        switch self {
        case .fastqInput:
            return [
                NodePort(id: "reads", name: "Reads", dataType: .fastqBundle, direction: .output)
            ]
        case .fastaInput:
            return [
                NodePort(id: "sequence", name: "Sequence", dataType: .referenceBundle, direction: .output)
            ]
        case .bamInput:
            return [
                NodePort(id: "alignments", name: "Alignments", dataType: .bamTrack, direction: .output)
            ]
        case .sampleSheet:
            return [
                NodePort(id: "samples", name: "Samples", dataType: .sampleSheet, direction: .output)
            ]
        case .qualityControl:
            return [
                NodePort(id: "report", name: "Report", dataType: .reportFile, direction: .output)
            ]
        case .trimming:
            return [
                NodePort(id: "trimmed", name: "Trimmed", dataType: .fastqBundle, direction: .output),
                NodePort(id: "report", name: "Report", dataType: .reportFile, direction: .output)
            ]
        case .alignment:
            return [
                NodePort(id: "alignments", name: "Alignments", dataType: .bamTrack, direction: .output),
                NodePort(id: "stats", name: "Stats", dataType: .tsvFile, direction: .output)
            ]
        case .variantCalling:
            return [
                NodePort(id: "variants", name: "Variants", dataType: .variantTrack, direction: .output)
            ]
        case .quantification:
            return [
                NodePort(id: "counts", name: "Counts", dataType: .tsvFile, direction: .output)
            ]
        case .assembly:
            return [
                NodePort(id: "contigs", name: "Contigs", dataType: .assemblyBundle, direction: .output)
            ]
        case .report:
            return [
                NodePort(id: "report", name: "Report", dataType: .reportFile, direction: .output)
            ]
        case .export:
            return []
        }
    }
}

// MARK: - NodeCategory

/// Category for grouping node types in the palette.
public enum NodeCategory: String, Sendable, Codable, CaseIterable {
    case input = "Input"
    case preprocessing = "Preprocessing"
    case analysis = "Analysis"
    case output = "Output"

    /// Human-readable display name
    public var displayName: String {
        rawValue
    }

    /// SF Symbol name for the category icon
    public var iconName: String {
        switch self {
        case .input: return "arrow.down.doc"
        case .preprocessing: return "wand.and.stars"
        case .analysis: return "cpu"
        case .output: return "arrow.up.doc"
        }
    }
}

// MARK: - PortDataType

/// Data types that can flow through workflow connections.
public enum PortDataType: String, Sendable, Codable, CaseIterable {
    case accession = "accession"
    case referenceBundle = "reference_bundle"
    case fastqBundle = "fastq_bundle"
    case fastaBundle = "fasta_bundle"
    case bamTrack = "bam_track"
    case variantTrack = "variant_track"
    case primerSchemeBundle = "primer_scheme_bundle"
    case assemblyBundle = "assembly_bundle"
    case taxonomyBundle = "taxonomy_bundle"
    case msaBundle = "msa_bundle"
    case treeBundle = "tree_bundle"
    case sampleSheet = "sample_sheet"
    case bedFile = "bed_file"
    case gff3File = "gff3_file"
    case tsvFile = "tsv_file"
    case reportFile = "report_file"
    case any = "any"

    /// Human-readable display name
    public var displayName: String {
        switch self {
        case .accession: return "Accession"
        case .referenceBundle: return "Reference Bundle"
        case .fastqBundle: return "FASTQ Bundle"
        case .fastaBundle: return "FASTA Bundle"
        case .bamTrack: return "BAM Track"
        case .variantTrack: return "Variant Track"
        case .primerSchemeBundle: return "Primer Scheme Bundle"
        case .assemblyBundle: return "Assembly Bundle"
        case .taxonomyBundle: return "Taxonomy Bundle"
        case .msaBundle: return "MSA Bundle"
        case .treeBundle: return "Tree Bundle"
        case .sampleSheet: return "Sample Sheet"
        case .bedFile: return "BED File"
        case .gff3File: return "GFF3 File"
        case .tsvFile: return "TSV File"
        case .reportFile: return "Report File"
        case .any: return "Any"
        }
    }

    /// Color for the port (NSColor is not Sendable, so we use RGB values)
    public var colorComponents: (red: Double, green: Double, blue: Double) {
        switch self {
        case .accession: return (0.6, 0.6, 0.6)
        case .referenceBundle, .fastaBundle, .assemblyBundle: return (0.2, 0.8, 0.4)
        case .fastqBundle: return (0.2, 0.6, 0.9)
        case .bamTrack: return (0.8, 0.4, 0.8)
        case .variantTrack: return (0.9, 0.5, 0.2)
        case .primerSchemeBundle, .bedFile, .gff3File: return (0.7, 0.5, 0.2)
        case .taxonomyBundle: return (0.3, 0.7, 0.6)
        case .msaBundle, .treeBundle: return (0.4, 0.5, 0.9)
        case .sampleSheet, .tsvFile: return (0.5, 0.5, 0.7)
        case .reportFile: return (0.9, 0.3, 0.3)
        case .any: return (0.7, 0.7, 0.7)
        }
    }

    /// Check if this type is compatible with another type for connection
    public func isCompatible(with other: PortDataType) -> Bool {
        if self == .any || other == .any {
            return true
        }
        if self == .referenceBundle && other == .assemblyBundle {
            return true
        }
        if self == .assemblyBundle && other == .referenceBundle {
            return true
        }
        return self == other
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        if let value = PortDataType(rawValue: rawValue) {
            self = value
            return
        }
        if let value = PortDataType.legacyValue(for: rawValue) {
            self = value
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Cannot initialize PortDataType from invalid String value \(rawValue)"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    fileprivate static func legacyValue(
        for rawValue: String,
        portID: String? = nil,
        portName: String? = nil,
        direction: PortDirection? = nil
    ) -> PortDataType? {
        switch rawValue {
        case "fastq":
            return .fastqBundle
        case "fasta":
            let context = [portID, portName]
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")
            return context.contains("contig") ? .assemblyBundle : .referenceBundle
        case "bam":
            return .bamTrack
        case "vcf":
            return .variantTrack
        case "csv":
            return .sampleSheet
        case "tsv":
            return .tsvFile
        case "html":
            return .reportFile
        default:
            return nil
        }
    }
}

// MARK: - PortDirection

/// Direction of a port (input or output).
public enum PortDirection: String, Sendable, Codable {
    case input
    case output
}

// MARK: - NodePort

/// A port on a workflow node for connecting data flow.
public struct NodePort: Sendable, Codable, Identifiable, Hashable {
    /// Unique identifier within the node
    public let id: String

    /// Human-readable name
    public let name: String

    /// The data type this port accepts/provides
    public let dataType: PortDataType

    /// Direction of the port
    public let direction: PortDirection

    /// Whether this port is required (for input ports)
    public var isRequired: Bool

    /// Whether this port allows multiple connections
    public var allowsMultiple: Bool

    /// Creates a new port.
    ///
    /// - Parameters:
    ///   - id: Unique identifier within the node
    ///   - name: Human-readable name
    ///   - dataType: The data type this port accepts/provides
    ///   - direction: Direction of the port
    ///   - isRequired: Whether this port is required (default: true for input)
    ///   - allowsMultiple: Whether this port allows multiple connections
    public init(
        id: String,
        name: String,
        dataType: PortDataType,
        direction: PortDirection,
        isRequired: Bool? = nil,
        allowsMultiple: Bool = false
    ) {
        self.id = id
        self.name = name
        self.dataType = dataType
        self.direction = direction
        self.isRequired = isRequired ?? (direction == .input)
        self.allowsMultiple = allowsMultiple
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case dataType
        case direction
        case isRequired
        case allowsMultiple
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        direction = try container.decode(PortDirection.self, forKey: .direction)

        let rawDataType = try container.decode(String.self, forKey: .dataType)
        if let value = PortDataType(rawValue: rawDataType) {
            dataType = value
        } else if let legacyValue = PortDataType.legacyValue(
            for: rawDataType,
            portID: id,
            portName: name,
            direction: direction
        ) {
            dataType = legacyValue
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .dataType,
                in: container,
                debugDescription: "Cannot initialize PortDataType from invalid String value \(rawDataType)"
            )
        }

        isRequired = try container.decodeIfPresent(Bool.self, forKey: .isRequired) ?? (direction == .input)
        allowsMultiple = try container.decodeIfPresent(Bool.self, forKey: .allowsMultiple) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(dataType.rawValue, forKey: .dataType)
        try container.encode(direction, forKey: .direction)
        try container.encode(isRequired, forKey: .isRequired)
        try container.encode(allowsMultiple, forKey: .allowsMultiple)
    }
}

// MARK: - WorkflowNode

/// A node in a workflow graph representing a processing step.
///
/// Each node has a type that determines its input/output ports and behavior.
/// Nodes can be connected to form a directed acyclic graph (DAG).
///
/// ## Example
/// ```swift
/// let inputNode = WorkflowNode(
///     type: .fastqInput,
///     position: CGPoint(x: 100, y: 100)
/// )
/// inputNode.label = "Sample Reads"
/// ```
public struct WorkflowNode: Sendable, Codable, Identifiable, Hashable {
    /// Unique identifier for this node
    public let id: UUID

    /// The type of this node
    public let type: WorkflowNodeType

    /// Custom label for the node (defaults to type's displayName)
    public var label: String

    /// Position in the canvas (x, y coordinates)
    public var position: CGPoint

    /// Input ports for this node
    public var inputPorts: [NodePort]

    /// Output ports for this node
    public var outputPorts: [NodePort]

    /// Custom parameters for this node
    public var parameters: [String: String]

    /// Notes/comments for this node
    public var notes: String?

    /// Whether this node is currently selected
    public var isSelected: Bool = false

    /// Creates a new workflow node.
    ///
    /// - Parameters:
    ///   - id: Unique identifier (auto-generated if not provided)
    ///   - type: The type of this node
    ///   - label: Custom label (defaults to type's displayName)
    ///   - position: Position in the canvas
    ///   - parameters: Custom parameters
    ///   - notes: Notes/comments
    public init(
        id: UUID = UUID(),
        type: WorkflowNodeType,
        label: String? = nil,
        position: CGPoint = .zero,
        parameters: [String: String] = [:],
        notes: String? = nil
    ) {
        self.id = id
        self.type = type
        self.label = label ?? type.displayName
        self.position = position
        self.inputPorts = type.inputPorts
        self.outputPorts = type.outputPorts
        self.parameters = parameters
        self.notes = notes
    }

    // MARK: - Port Access

    /// Finds an input port by its ID.
    public func inputPort(withId portId: String) -> NodePort? {
        inputPorts.first { $0.id == portId }
    }

    /// Finds an output port by its ID.
    public func outputPort(withId portId: String) -> NodePort? {
        outputPorts.first { $0.id == portId }
    }

    /// Finds any port by its ID.
    public func port(withId portId: String) -> NodePort? {
        inputPort(withId: portId) ?? outputPort(withId: portId)
    }

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: WorkflowNode, rhs: WorkflowNode) -> Bool {
        lhs.id == rhs.id
    }
}

// Note: CGPoint is already Codable in CoreGraphics (macOS 10.9+)
