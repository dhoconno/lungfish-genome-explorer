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
        XCTAssertTrue(graph.allNodes.isEmpty)
        XCTAssertTrue(graph.allConnections.isEmpty)
    }

    func testAddNode() {
        var graph = WorkflowGraph(name: "Test")

        let node = graph.addNode(
            type: .fastqInput,
            position: CGPoint(x: 100, y: 100)
        )

        XCTAssertEqual(graph.nodeCount, 1)
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
        XCTAssertEqual(graph.nodeCount, 0)
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
            XCTAssertEqual(source, .bam)
            XCTAssertEqual(target, .fastq)
        } else {
            XCTFail("Expected incompatibleTypes error")
        }
    }

    // MARK: - PortDataType Tests

    func testPortDataTypeCompatibility() {
        XCTAssertTrue(PortDataType.fastq.isCompatible(with: .fastq))
        XCTAssertFalse(PortDataType.fastq.isCompatible(with: .bam))
        XCTAssertTrue(PortDataType.any.isCompatible(with: .fastq))
        XCTAssertTrue(PortDataType.fastq.isCompatible(with: .any))
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
