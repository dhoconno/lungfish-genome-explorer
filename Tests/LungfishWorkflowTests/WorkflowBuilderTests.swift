// WorkflowBuilderTests.swift - Tests for workflow builder components
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class WorkflowBuilderTests: XCTestCase {

    // MARK: - WorkflowGraph Tests

    func testWorkflowGraphCreation() {
        let graph = WorkflowGraph(
            name: "Test Pipeline",
            description: "A test workflow",
            version: "1.0.0",
            author: "Test Author"
        )

        XCTAssertEqual(graph.name, "Test Pipeline")
        XCTAssertEqual(graph.description, "A test workflow")
        XCTAssertEqual(graph.version, "1.0.0")
        XCTAssertEqual(graph.author, "Test Author")
        XCTAssertEqual(graph.allNodes.filter(\.isPinned).count, 2)
        XCTAssertTrue(graph.allConnections.isEmpty)
    }

    func testWorkflowGraphCreatesPinnedInputAndOutputAnchorsAutomatically() {
        let graph = WorkflowGraph(name: "Anchored Pipeline")

        XCTAssertEqual(graph.sampleInput.type, .sampleInput)
        XCTAssertEqual(graph.sampleInput.label, "Sample input")
        XCTAssertEqual(graph.sampleInput.outputPort(withId: "sample")?.dataType, .any)
        XCTAssertTrue(graph.sampleInput.isPinned)
        XCTAssertFalse(graph.sampleInput.isDraggable)
        XCTAssertFalse(graph.sampleInput.isRemovable)

        XCTAssertEqual(graph.projectOutput.type, .projectOutput)
        XCTAssertEqual(graph.projectOutput.label, "Project output")
        XCTAssertEqual(graph.projectOutput.inputPort(withId: "input")?.dataType, .any)
        XCTAssertTrue(graph.projectOutput.isPinned)
        XCTAssertFalse(graph.projectOutput.isDraggable)
        XCTAssertFalse(graph.projectOutput.isRemovable)

        XCTAssertEqual(graph.nodeCount, 2)
    }

    func testWorkflowGraphDoesNotRemovePinnedAnchors() {
        var graph = WorkflowGraph(name: "Anchored Pipeline")
        let sampleInputID = graph.sampleInput.id
        let projectOutputID = graph.projectOutput.id

        XCTAssertNil(graph.removeNode(id: sampleInputID))
        XCTAssertNil(graph.removeNode(id: projectOutputID))

        XCTAssertNotNil(graph.getNode(sampleInputID))
        XCTAssertNotNil(graph.getNode(projectOutputID))
        XCTAssertEqual(graph.nodeCount, 2)
    }

    func testWorkflowGraphRoundTripsPinnedAnchors() throws {
        var graph = WorkflowGraph(name: "Anchored Pipeline")
        let trimming = graph.addNode(type: .trimming, position: CGPoint(x: 360, y: 120))
        _ = try graph.addConnection(
            sourceNodeId: graph.sampleInput.id,
            sourcePortId: "sample",
            targetNodeId: trimming.id,
            targetPortId: "reads"
        )
        _ = try graph.addConnection(
            sourceNodeId: trimming.id,
            sourcePortId: "trimmed",
            targetNodeId: graph.projectOutput.id,
            targetPortId: "input"
        )

        let data = try JSONEncoder().encode(graph)
        let decoded = try JSONDecoder().decode(WorkflowGraph.self, from: data)

        XCTAssertEqual(decoded.sampleInput.id, graph.sampleInput.id)
        XCTAssertEqual(decoded.projectOutput.id, graph.projectOutput.id)
        XCTAssertEqual(decoded.sampleInput.outputPort(withId: "sample")?.dataType, .any)
        XCTAssertEqual(decoded.projectOutput.inputPort(withId: "input")?.dataType, .any)
        XCTAssertEqual(decoded.connectionCount, 2)
    }

    func testWorkflowGraphVersionDefaultsAndRoundTripsAsSemver() throws {
        var graph = WorkflowGraph(name: "Versioned Pipeline")
        graph.version = "1.2.3"

        XCTAssertTrue(WorkflowVersion.isValidSemVer(graph.version))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(graph)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains(#""version":"1.2.3""#), json)

        let decoded = try JSONDecoder().decode(WorkflowGraph.self, from: data)
        XCTAssertEqual(decoded.version, "1.2.3")
    }

    func testWorkflowGraphLegacyFilesWithoutVersionDecodeToDefaultSemver() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000020",
          "name": "Legacy Pipeline",
          "nodes": [],
          "connections": [],
          "createdAt": 0,
          "modifiedAt": 0
        }
        """

        let decoded = try JSONDecoder().decode(WorkflowGraph.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.version, "1.0.0")
        XCTAssertTrue(WorkflowVersion.isValidSemVer(decoded.version))
    }

    func testWorkflowDiffReportsVersionNodeAndParameterChanges() throws {
        var original = WorkflowGraph(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
            name: "Audit Pipeline",
            version: "1.0.0"
        )
        let input = try original.addStableNode(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000022")!,
            type: .fastqInput,
            label: "Reads",
            position: .zero
        )
        let trim = try original.addStableNode(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000023")!,
            type: .trimming,
            label: "Trim",
            position: CGPoint(x: 200, y: 0),
            parameters: ["minimum_length": "20"]
        )
        _ = try original.addConnection(
            sourceNodeId: input.id,
            sourcePortId: "reads",
            targetNodeId: trim.id,
            targetPortId: "reads"
        )

        var revised = original
        revised.version = "1.1.0"
        var revisedTrim = try XCTUnwrap(revised.getNode(trim.id))
        revisedTrim.parameters["minimum_length"] = "35"
        try revised.updateNode(revisedTrim)
        _ = try revised.addStableNode(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000024")!,
            type: .qualityControl,
            label: "QC",
            position: CGPoint(x: 400, y: 0)
        )

        let diff = WorkflowGraphDiff.compare(original, revised)
        let text = diff.textDescription

        XCTAssertTrue(diff.hasChanges)
        XCTAssertTrue(text.contains("Version: 1.0.0 -> 1.1.0"), text)
        XCTAssertTrue(text.contains("Added nodes"), text)
        XCTAssertTrue(text.contains("QC"), text)
        XCTAssertTrue(text.contains("minimum_length: 20 -> 35"), text)
    }

    func testWorkflowDiffJSONReportIsCodable() throws {
        let original = WorkflowGraph(name: "Same", version: "1.0.0")
        var revised = original
        revised.version = "1.0.1"

        let report = WorkflowGraphDiff.compare(original, revised).jsonReport
        let data = try JSONEncoder().encode(report)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(object?["fromVersion"] as? String, "1.0.0")
        XCTAssertEqual(object?["toVersion"] as? String, "1.0.1")
    }

    func testAddNode() {
        var graph = WorkflowGraph(name: "Test")

        let node = graph.addNode(
            type: .fastqInput,
            position: CGPoint(x: 100, y: 100)
        )

        XCTAssertEqual(graph.nodeCount, 3)
        XCTAssertEqual(node.type, .fastqInput)
        XCTAssertEqual(node.position, CGPoint(x: 100, y: 100))
        XCTAssertNotNil(graph.getNode(node.id))
    }

    func testRemoveNode() {
        var graph = WorkflowGraph(name: "Test")
        let node = graph.addNode(type: .fastqInput, position: .zero)

        let removed = graph.removeNode(node.id)

        XCTAssertNotNil(removed)
        XCTAssertEqual(removed?.id, node.id)
        XCTAssertEqual(graph.nodeCount, 2)
        XCTAssertNil(graph.getNode(node.id))
    }

    func testAddConnection() throws {
        var graph = WorkflowGraph(name: "Test")
        let inputNode = graph.addNode(type: .fastqInput, position: CGPoint(x: 100, y: 100))
        let qcNode = graph.addNode(type: .qualityControl, position: CGPoint(x: 300, y: 100))

        let connection = try graph.addConnection(
            sourceNodeId: inputNode.id,
            sourcePortId: "reads",
            targetNodeId: qcNode.id,
            targetPortId: "reads"
        )

        XCTAssertEqual(graph.connectionCount, 1)
        XCTAssertEqual(connection.sourceNodeId, inputNode.id)
        XCTAssertEqual(connection.targetNodeId, qcNode.id)
    }

    func testRemoveNodeRemovesConnections() throws {
        var graph = WorkflowGraph(name: "Test")
        let inputNode = graph.addNode(type: .fastqInput, position: .zero)
        let qcNode = graph.addNode(type: .qualityControl, position: .zero)

        _ = try graph.addConnection(
            sourceNodeId: inputNode.id,
            sourcePortId: "reads",
            targetNodeId: qcNode.id,
            targetPortId: "reads"
        )

        XCTAssertEqual(graph.connectionCount, 1)

        _ = graph.removeNode(inputNode.id)

        XCTAssertEqual(graph.connectionCount, 0)
    }

    func testCycleDetection() throws {
        var graph = WorkflowGraph(name: "Test")
        let inputNode = graph.addNode(type: .fastqInput, position: .zero)
        let trimmingNode = graph.addNode(type: .trimming, position: .zero)
        let qcNode = graph.addNode(type: .qualityControl, position: .zero)

        // Add connection: input -> trimming (compatible types: fastq -> fastq)
        _ = try graph.addConnection(
            sourceNodeId: inputNode.id,
            sourcePortId: "reads",
            targetNodeId: trimmingNode.id,
            targetPortId: "reads"
        )

        // Add connection: trimming -> qc (compatible types: fastq -> fastq)
        _ = try graph.addConnection(
            sourceNodeId: trimmingNode.id,
            sourcePortId: "trimmed",
            targetNodeId: qcNode.id,
            targetPortId: "reads"
        )

        // Try to add connection from qcNode back to trimmingNode (would create cycle)
        XCTAssertTrue(graph.wouldCreateCycle(from: qcNode.id, to: trimmingNode.id))

        // Try to add connection from qcNode back to inputNode (would create cycle)
        XCTAssertTrue(graph.wouldCreateCycle(from: qcNode.id, to: inputNode.id))

        // Self-connection should also be detected as cycle
        XCTAssertTrue(graph.wouldCreateCycle(from: inputNode.id, to: inputNode.id))
    }

    func testTopologicalSort() throws {
        var graph = WorkflowGraph(name: "Test")
        let inputNode = graph.addNode(type: .fastqInput, position: .zero)
        let trimmingNode = graph.addNode(type: .trimming, position: .zero)
        let qcNode = graph.addNode(type: .qualityControl, position: .zero)

        // Create chain: input -> trimming -> qc
        _ = try graph.addConnection(
            sourceNodeId: inputNode.id,
            sourcePortId: "reads",
            targetNodeId: trimmingNode.id,
            targetPortId: "reads"
        )
        _ = try graph.addConnection(
            sourceNodeId: trimmingNode.id,
            sourcePortId: "trimmed",
            targetNodeId: qcNode.id,
            targetPortId: "reads"
        )

        let sorted = try graph.topologicalSort()

        XCTAssertEqual(sorted.count, 3)
        XCTAssertEqual(sorted[0].id, inputNode.id)
        XCTAssertEqual(sorted[1].id, trimmingNode.id)
        XCTAssertEqual(sorted[2].id, qcNode.id)
    }

    func testValidation() {
        var graph = WorkflowGraph(name: "Test")

        // Empty graph should have validation issue
        var issues = graph.validate()
        XCTAssertTrue(issues.contains(.emptyWorkflow))

        // Add disconnected input node
        let inputNode = graph.addNode(type: .fastqInput, position: .zero)
        issues = graph.validate()
        XCTAssertTrue(issues.contains { issue in
            if case .disconnectedInput(let nodeId, _) = issue {
                return nodeId == inputNode.id
            }
            return false
        })
    }

    // MARK: - WorkflowNode Tests

    func testNodeCreation() {
        let node = WorkflowNode(
            type: .alignment,
            label: "BWA Alignment",
            position: CGPoint(x: 200, y: 300)
        )

        XCTAssertEqual(node.type, .alignment)
        XCTAssertEqual(node.label, "BWA Alignment")
        XCTAssertEqual(node.position, CGPoint(x: 200, y: 300))
    }

    func testNodeInputPorts() {
        let node = WorkflowNode(type: .alignment, position: .zero)

        XCTAssertEqual(node.inputPorts.count, 2)
        XCTAssertNotNil(node.inputPort(withId: "reads"))
        XCTAssertNotNil(node.inputPort(withId: "reference"))
    }

    func testNodeOutputPorts() {
        let node = WorkflowNode(type: .alignment, position: .zero)

        XCTAssertEqual(node.outputPorts.count, 2)
        XCTAssertNotNil(node.outputPort(withId: "alignments"))
        XCTAssertNotNil(node.outputPort(withId: "stats"))
    }

    func testSampleSheetNodeFansOutFASTQSamples() {
        let node = WorkflowNode(type: .sampleSheet, position: .zero)

        XCTAssertEqual(node.outputPorts.count, 1)
        let samples = node.outputPort(withId: "samples")
        XCTAssertEqual(samples?.dataType, .fastqBundle)
        XCTAssertTrue(samples?.allowsMultiple ?? false)
        XCTAssertEqual(node.parameters["sample_sheet_mode"], "paired_illumina_fastq")
        XCTAssertEqual(node.parameters["fan_out"], "true")
    }

    func testNodeCategories() {
        XCTAssertEqual(WorkflowNodeType.fastqInput.category, .input)
        XCTAssertEqual(WorkflowNodeType.trimming.category, .preprocessing)
        XCTAssertEqual(WorkflowNodeType.alignment.category, .analysis)
        XCTAssertEqual(WorkflowNodeType.export.category, .output)
    }

    // MARK: - WorkflowConnection Tests

    func testConnectionValidation() {
        let sourceNode = WorkflowNode(type: .fastqInput, position: .zero)
        let targetNode = WorkflowNode(type: .qualityControl, position: .zero)

        let connection = WorkflowConnection(
            sourceNodeId: sourceNode.id,
            sourcePortId: "reads",
            targetNodeId: targetNode.id,
            targetPortId: "reads"
        )

        let error = connection.validate(sourceNode: sourceNode, targetNode: targetNode)
        XCTAssertNil(error)
    }

    func testConnectionSelfConnectionError() {
        let node = WorkflowNode(type: .trimming, position: .zero)

        let connection = WorkflowConnection(
            sourceNodeId: node.id,
            sourcePortId: "trimmed",
            targetNodeId: node.id,
            targetPortId: "reads"
        )

        let error = connection.validate(sourceNode: node, targetNode: node)
        XCTAssertEqual(error, .selfConnection)
    }

    func testConnectionIncompatibleTypes() {
        let bamNode = WorkflowNode(type: .bamInput, position: .zero)
        let trimmingNode = WorkflowNode(type: .trimming, position: .zero)

        let connection = WorkflowConnection(
            sourceNodeId: bamNode.id,
            sourcePortId: "alignments",
            targetNodeId: trimmingNode.id,
            targetPortId: "reads"
        )

        let error = connection.validate(sourceNode: bamNode, targetNode: trimmingNode)
        if case .incompatibleTypes(let source, let target) = error {
            XCTAssertEqual(source, .bamTrack)
            XCTAssertEqual(target, .fastqBundle)
        } else {
            XCTFail("Expected incompatibleTypes error")
        }
    }

    func testWorkflowPortTypeCatalogStableIdentifiers() {
        XCTAssertEqual(PortDataType.accession.rawValue, "accession")
        XCTAssertEqual(PortDataType.referenceBundle.rawValue, "reference_bundle")
        XCTAssertEqual(PortDataType.fastqBundle.rawValue, "fastq_bundle")
        XCTAssertEqual(PortDataType.fastaBundle.rawValue, "fasta_bundle")
        XCTAssertEqual(PortDataType.bamTrack.rawValue, "bam_track")
        XCTAssertEqual(PortDataType.variantTrack.rawValue, "variant_track")
        XCTAssertEqual(PortDataType.primerSchemeBundle.rawValue, "primer_scheme_bundle")
        XCTAssertEqual(PortDataType.assemblyBundle.rawValue, "assembly_bundle")
        XCTAssertEqual(PortDataType.taxonomyBundle.rawValue, "taxonomy_bundle")
        XCTAssertEqual(PortDataType.msaBundle.rawValue, "msa_bundle")
        XCTAssertEqual(PortDataType.treeBundle.rawValue, "tree_bundle")
        XCTAssertEqual(PortDataType.sampleSheet.rawValue, "sample_sheet")
        XCTAssertEqual(PortDataType.bedFile.rawValue, "bed_file")
        XCTAssertEqual(PortDataType.gff3File.rawValue, "gff3_file")
        XCTAssertEqual(PortDataType.any.rawValue, "any")
    }

    func testGraphRejectsMismatchedCatalogPortConnection() {
        var graph = WorkflowGraph(name: "Typed ports")
        let bamNode = graph.addNode(type: .bamInput, position: .zero)
        let trimmingNode = graph.addNode(type: .trimming, position: .zero)

        XCTAssertThrowsError(try graph.addConnection(
            sourceNodeId: bamNode.id,
            sourcePortId: "alignments",
            targetNodeId: trimmingNode.id,
            targetPortId: "reads"
        )) { error in
            guard case WorkflowGraphError.invalidConnection(.incompatibleTypes(let source, let target)) = error else {
                return XCTFail("Expected incompatibleTypes error, got \(error)")
            }
            XCTAssertEqual(source, .bamTrack)
            XCTAssertEqual(target, .fastqBundle)
        }
    }

    func testReferenceBundlePromotesToAssemblyBundleCompatibleInput() {
        var referenceNode = WorkflowNode(type: .fastaInput, position: .zero)
        referenceNode.outputPorts = [
            NodePort(id: "reference", name: "Reference", dataType: .referenceBundle, direction: .output)
        ]

        var assemblyConsumer = WorkflowNode(type: .assembly, position: .zero)
        assemblyConsumer.inputPorts = [
            NodePort(id: "assembly", name: "Assembly", dataType: .assemblyBundle, direction: .input)
        ]

        let connection = WorkflowConnection(
            sourceNodeId: referenceNode.id,
            sourcePortId: "reference",
            targetNodeId: assemblyConsumer.id,
            targetPortId: "assembly"
        )

        XCTAssertNil(connection.validate(sourceNode: referenceNode, targetNode: assemblyConsumer))
    }

    func testNodeParameterValidationRejectsInvalidTypedValue() throws {
        var graph = WorkflowGraph(name: "Typed parameters")
        let inputNode = graph.addNode(type: .fastqInput, position: .zero)
        let trimmingNode = WorkflowNode(
            type: .trimming,
            position: .zero,
            parameters: ["minimum_length": "not-an-integer"]
        )
        try graph.addNode(trimmingNode)

        _ = try graph.addConnection(
            sourceNodeId: inputNode.id,
            sourcePortId: "reads",
            targetNodeId: trimmingNode.id,
            targetPortId: "reads"
        )

        let issues = graph.validate()
        XCTAssertTrue(issues.contains { issue in
            if case .invalidNodeParameter(let nodeId, _, let parameter, let reason) = issue {
                return nodeId == trimmingNode.id
                    && parameter == "minimum_length"
                    && reason.contains("integer")
            }
            return false
        })

        XCTAssertThrowsError(try NextflowExporter().export(graph: graph)) { error in
            let description = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            XCTAssertTrue(description.contains("minimum_length"))
            XCTAssertTrue(description.contains("integer"))
        }
    }

    func testNodeParameterResolvedDefaultsAreTypedAndExported() throws {
        var graph = WorkflowGraph(name: "Trim defaults")
        let inputNode = graph.addNode(type: .fastqInput, position: .zero, label: "Reads")
        let trimmingNode = graph.addNode(type: .trimming, position: .zero, label: "Trim")

        _ = try graph.addConnection(
            sourceNodeId: inputNode.id,
            sourcePortId: "reads",
            targetNodeId: trimmingNode.id,
            targetPortId: "reads"
        )

        let resolved = try trimmingNode.resolvedParameters()
        XCTAssertEqual(resolved["minimum_length"], .integer(20))
        XCTAssertEqual(resolved["qualified_quality_phred"], .integer(15))

        let script = try NextflowExporter().export(graph: graph)
        XCTAssertTrue(script.contains("--length_required 20"))
        XCTAssertTrue(script.contains("--qualified_quality_phred 15"))
    }

    func testNodeParameterValidationRejectsUnknownExporterParameter() throws {
        var graph = WorkflowGraph(name: "Unknown parameters")
        let inputNode = graph.addNode(type: .fastqInput, position: .zero)
        let trimmingNode = WorkflowNode(
            type: .trimming,
            position: .zero,
            parameters: ["min-len": "30"]
        )
        try graph.addNode(trimmingNode)

        _ = try graph.addConnection(
            sourceNodeId: inputNode.id,
            sourcePortId: "reads",
            targetNodeId: trimmingNode.id,
            targetPortId: "reads"
        )

        let issues = graph.validate()
        XCTAssertTrue(issues.contains { issue in
            if case .unknownNodeParameter(_, _, let parameter) = issue {
                return parameter == "min-len"
            }
            return false
        })
    }

    // MARK: - PortDataType Tests

    func testPortDataTypeCompatibility() {
        XCTAssertTrue(PortDataType.fastqBundle.isCompatible(with: .fastqBundle))
        XCTAssertFalse(PortDataType.fastqBundle.isCompatible(with: .bamTrack))
        XCTAssertTrue(PortDataType.any.isCompatible(with: .fastqBundle))
        XCTAssertTrue(PortDataType.fastqBundle.isCompatible(with: .any))
    }

    // MARK: - Serialization Tests

    func testGraphEncodingDecoding() throws {
        var graph = WorkflowGraph(name: "Test Pipeline")
        let node1 = graph.addNode(type: .fastqInput, position: CGPoint(x: 100, y: 100))
        let node2 = graph.addNode(type: .qualityControl, position: CGPoint(x: 300, y: 100))
        _ = try graph.addConnection(
            sourceNodeId: node1.id,
            sourcePortId: "reads",
            targetNodeId: node2.id,
            targetPortId: "reads"
        )

        // Encode
        let encoder = JSONEncoder()
        let data = try encoder.encode(graph)

        // Decode
        let decoder = JSONDecoder()
        let decodedGraph = try decoder.decode(WorkflowGraph.self, from: data)

        XCTAssertEqual(decodedGraph.name, graph.name)
        XCTAssertEqual(decodedGraph.nodeCount, graph.nodeCount)
        XCTAssertEqual(decodedGraph.connectionCount, graph.connectionCount)
    }

    func testGraphDecodingMigratesLegacyPortDataTypeIdentifiers() throws {
        var graph = WorkflowGraph(name: "Legacy Pipeline")
        let reads = graph.addNode(type: .fastqInput, position: CGPoint(x: 100, y: 100))
        let reference = graph.addNode(type: .fastaInput, position: CGPoint(x: 100, y: 220))
        let align = graph.addNode(type: .alignment, position: CGPoint(x: 320, y: 120))
        let variants = graph.addNode(type: .variantCalling, position: CGPoint(x: 540, y: 120))
        let report = graph.addNode(type: .report, position: CGPoint(x: 760, y: 120))
        _ = try graph.addConnection(
            sourceNodeId: reads.id,
            sourcePortId: "reads",
            targetNodeId: align.id,
            targetPortId: "reads"
        )
        _ = try graph.addConnection(
            sourceNodeId: reference.id,
            sourcePortId: "sequence",
            targetNodeId: align.id,
            targetPortId: "reference"
        )
        _ = try graph.addConnection(
            sourceNodeId: align.id,
            sourcePortId: "alignments",
            targetNodeId: variants.id,
            targetPortId: "alignments"
        )
        _ = try graph.addConnection(
            sourceNodeId: variants.id,
            sourcePortId: "variants",
            targetNodeId: report.id,
            targetPortId: "input"
        )

        let encoded = try JSONEncoder().encode(graph)
        var json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        [
            #""fastq_bundle""#: #""fastq""#,
            #""reference_bundle""#: #""fasta""#,
            #""bam_track""#: #""bam""#,
            #""variant_track""#: #""vcf""#,
            #""tsv_file""#: #""tsv""#,
            #""report_file""#: #""html""#,
        ].forEach { json = json.replacingOccurrences(of: $0.key, with: $0.value) }

        let decoded = try JSONDecoder().decode(WorkflowGraph.self, from: Data(json.utf8))
        let decodedAlignment = try XCTUnwrap(decoded.allNodes.first { $0.type == .alignment })
        XCTAssertEqual(decodedAlignment.inputPorts.first { $0.id == "reads" }?.dataType, .fastqBundle)
        XCTAssertEqual(decodedAlignment.inputPorts.first { $0.id == "reference" }?.dataType, .referenceBundle)
        XCTAssertEqual(decodedAlignment.outputPorts.first { $0.id == "alignments" }?.dataType, .bamTrack)

        let decodedVariantCaller = try XCTUnwrap(decoded.allNodes.first { $0.type == .variantCalling })
        XCTAssertEqual(decodedVariantCaller.outputPorts.first { $0.id == "variants" }?.dataType, .variantTrack)
    }
}

// MARK: - Exporter Tests

final class WorkflowExporterTests: XCTestCase {

    func testNextflowExport() throws {
        var graph = WorkflowGraph(
            name: "RNA-Seq Pipeline",
            description: "Basic RNA-Seq analysis",
            author: "Test"
        )

        let fastqNode = graph.addNode(type: .fastqInput, position: .zero, label: "Sample Reads")
        let qcNode = graph.addNode(type: .qualityControl, position: .zero, label: "FastQC")
        let trimmingNode = graph.addNode(type: .trimming, position: .zero, label: "Fastp")

        _ = try graph.addConnection(
            sourceNodeId: fastqNode.id,
            sourcePortId: "reads",
            targetNodeId: qcNode.id,
            targetPortId: "reads"
        )
        _ = try graph.addConnection(
            sourceNodeId: fastqNode.id,
            sourcePortId: "reads",
            targetNodeId: trimmingNode.id,
            targetPortId: "reads"
        )

        let exporter = NextflowExporter()
        let script = try exporter.export(graph: graph)

        // Verify key elements are present
        XCTAssertTrue(script.contains("nextflow.enable.dsl"))
        XCTAssertTrue(script.contains("process fastqc"))
        XCTAssertTrue(script.contains("process fastp"))
        XCTAssertTrue(script.contains("workflow"))
    }

    func testNextflowExportCanReferenceLocalContainerAndCondaLockfile() throws {
        var graph = WorkflowGraph(name: "Containerized Pipeline")
        let fastqNode = graph.addNode(type: .fastqInput, position: .zero, label: "Reads")
        let qcNode = graph.addNode(type: .qualityControl, position: .zero, label: "FastQC")

        _ = try graph.addConnection(
            sourceNodeId: fastqNode.id,
            sourcePortId: "reads",
            targetNodeId: qcNode.id,
            targetPortId: "reads"
        )

        var configuration = NextflowExporter.Configuration()
        configuration.containerReference = "oras://example.invalid/lungfish/bundle@sha256:abc123"
        configuration.condaLockfile = "locks/read-mapping-lock.yml"
        let script = try NextflowExporter(configuration: configuration).export(graph: graph)

        XCTAssertTrue(script.contains("container 'oras://example.invalid/lungfish/bundle@sha256:abc123'"))
        XCTAssertTrue(script.contains("params.conda_lockfile = 'locks/read-mapping-lock.yml'"))
    }

    func testSnakemakeExport() throws {
        var graph = WorkflowGraph(
            name: "Variant Pipeline",
            description: "Variant calling workflow"
        )

        let fastqNode = graph.addNode(type: .fastqInput, position: .zero)
        let fastaNode = graph.addNode(type: .fastaInput, position: .zero, label: "Reference")
        let alignmentNode = graph.addNode(type: .alignment, position: .zero, label: "BWA")

        _ = try graph.addConnection(
            sourceNodeId: fastqNode.id,
            sourcePortId: "reads",
            targetNodeId: alignmentNode.id,
            targetPortId: "reads"
        )
        _ = try graph.addConnection(
            sourceNodeId: fastaNode.id,
            sourcePortId: "sequence",
            targetNodeId: alignmentNode.id,
            targetPortId: "reference"
        )

        let exporter = SnakemakeExporter()
        let snakefile = try exporter.export(graph: graph)

        // Verify key elements are present
        XCTAssertTrue(snakefile.contains("rule all:"))
        XCTAssertTrue(snakefile.contains("rule bwa:"))
        XCTAssertTrue(snakefile.contains("input:"))
        XCTAssertTrue(snakefile.contains("output:"))
        XCTAssertTrue(snakefile.contains("shell:"))
    }

    func testSnakemakeExportDefaultsToLockfileAndContainerReferencesWhenConfigured() throws {
        var graph = WorkflowGraph(name: "Portable Pipeline")
        let fastqNode = graph.addNode(type: .fastqInput, position: .zero)
        let qcNode = graph.addNode(type: .qualityControl, position: .zero, label: "FastQC")

        _ = try graph.addConnection(
            sourceNodeId: fastqNode.id,
            sourcePortId: "reads",
            targetNodeId: qcNode.id,
            targetPortId: "reads"
        )

        var configuration = SnakemakeExporter.Configuration()
        configuration.containerReference = "oras://example.invalid/lungfish/bundle@sha256:def456"
        configuration.condaLockfile = "locks/read-mapping-lock.yml"
        let snakefile = try SnakemakeExporter(configuration: configuration).export(graph: graph)

        XCTAssertTrue(snakefile.contains("\"oras://example.invalid/lungfish/bundle@sha256:def456\""))
        XCTAssertTrue(snakefile.contains("CONDA_LOCKFILE = config.get(\"conda_lockfile\", \"locks/read-mapping-lock.yml\")"))
    }

    func testExportWithCycleError() {
        // Can't easily create a cycle since addConnection validates,
        // but we can test that the exporter handles validation errors
        let graph = WorkflowGraph(name: "Empty")

        let exporter = NextflowExporter()
        XCTAssertThrowsError(try exporter.export(graph: graph)) { error in
            if case NextflowExportError.invalidGraph(let issues) = error {
                XCTAssertTrue(issues.contains { $0.contains("no nodes") })
            } else {
                XCTFail("Expected invalidGraph error")
            }
        }
    }
}
